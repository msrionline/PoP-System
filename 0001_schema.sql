-- =====================================================================
-- 0001_schema.sql — Course Payment & Proof of Payment Management System
-- Target: PostgreSQL 15+ (Supabase). Designed for 20 000+ participants.
-- =====================================================================

create extension if not exists "pgcrypto";
create extension if not exists "pg_trgm";
create extension if not exists "citext";

-- ---------------------------------------------------------------------
-- Enumerated types
-- ---------------------------------------------------------------------
create type user_role as enum (
  'super_admin', 'finance_admin', 'course_admin', 'viewer'
);

create type payment_status as enum (
  'pending_review', 'under_review', 'verified',
  'rejected', 'duplicate', 'requires_clarification'
);

create type participant_status as enum (
  'not_paid', 'partially_paid', 'fully_paid',
  'verification_pending', 'payment_issue', 'refund_adjustment'
);

create type payment_method as enum (
  'eft', 'cash_deposit', 'card', 'mobile_money', 'payroll_deduction', 'other'
);

-- ---------------------------------------------------------------------
-- Administrators. id mirrors auth.users.id (Supabase Auth owns credentials,
-- so password hashing, session management and reset flows are not
-- re-implemented here.)
-- ---------------------------------------------------------------------
create table app_users (
  id            uuid primary key references auth.users(id) on delete cascade,
  email         citext not null unique,
  full_name     text   not null,
  role          user_role not null default 'viewer',
  is_active     boolean not null default true,
  -- COURSE ADMIN scoping: empty array = all programmes.
  programme_ids uuid[] not null default '{}',
  -- Grants a course admin the right to verify within their scope.
  can_verify    boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Programmes and cohorts
-- ---------------------------------------------------------------------
create table programmes (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  name        text not null,
  amount_due  numeric(12,2) not null default 0 check (amount_due >= 0),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table cohorts (
  id           uuid primary key default gen_random_uuid(),
  programme_id uuid not null references programmes(id) on delete cascade,
  code         text not null,
  name         text not null,
  start_date   date,
  end_date     date,
  created_at   timestamptz not null default now(),
  unique (programme_id, code)
);
create index cohorts_programme_idx on cohorts (programme_id);

-- ---------------------------------------------------------------------
-- Participants
-- amount_paid / pop_count / payment_status are maintained by trigger from
-- the payments table (see 0002). They are rollups, never a second source
-- of truth: recalculate_participant() can rebuild any row from payments.
-- ---------------------------------------------------------------------
create sequence participant_ref_seq start 1000;

create table participants (
  id                uuid primary key default gen_random_uuid(),
  participant_ref   text not null unique
                    default 'MSRI-' || lpad(nextval('participant_ref_seq')::text, 6, '0'),
  first_name        text not null,
  surname           text not null,
  full_name         text generated always as (first_name || ' ' || surname) stored,
  email             citext,
  mobile            text,
  programme_id      uuid not null references programmes(id) on delete restrict,
  cohort_id         uuid references cohorts(id) on delete set null,
  registration_date date not null default current_date,
  amount_due        numeric(12,2) not null default 0 check (amount_due >= 0),
  amount_paid       numeric(12,2) not null default 0,
  outstanding       numeric(12,2) generated always as (amount_due - amount_paid) stored,
  pop_count         integer not null default 0,
  payment_status    participant_status not null default 'not_paid',
  status_override   participant_status,
  last_payment_date date,
  notes             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  search_vector     tsvector generated always as (
                      to_tsvector('simple',
                        coalesce(participant_ref,'') || ' ' ||
                        coalesce(first_name,'')      || ' ' ||
                        coalesce(surname,'')         || ' ' ||
                        coalesce(email::text,'')     || ' ' ||
                        coalesce(mobile,''))
                    ) stored
);

create index participants_search_idx     on participants using gin (search_vector);
create index participants_name_trgm_idx  on participants using gin (full_name gin_trgm_ops);
create index participants_email_idx      on participants (email);
-- Trigram indexes back the global search bar: every field it queries must be
-- index-backed or the search degrades to a sequential scan at 20k+ rows.
create index participants_ref_trgm_idx   on participants using gin (participant_ref gin_trgm_ops);
create index participants_mobile_trgm_idx on participants using gin (mobile gin_trgm_ops);
create index participants_email_trgm_idx on participants using gin ((email::text) gin_trgm_ops);
create index participants_programme_idx  on participants (programme_id);
create index participants_cohort_idx     on participants (cohort_id);
create index participants_status_idx     on participants (payment_status);
create index participants_created_idx    on participants (created_at desc);
-- Supports the default "recently registered" listing with a stable tiebreak.
create index participants_reg_idx        on participants (registration_date desc, id);

-- ---------------------------------------------------------------------
-- Payments
-- ---------------------------------------------------------------------
create sequence payment_ref_seq start 1000;

create table payments (
  id                uuid primary key default gen_random_uuid(),
  payment_ref       text not null unique
                    default 'PAY-' || lpad(nextval('payment_ref_seq')::text, 7, '0'),
  participant_id    uuid not null references participants(id) on delete cascade,
  programme_id      uuid not null references programmes(id) on delete restrict,
  amount            numeric(12,2) not null check (amount > 0),
  payment_date      date not null,
  reference         text,                       -- bank/transaction reference
  method            payment_method not null default 'eft',
  bank              text,
  status            payment_status not null default 'pending_review',
  duplicate_flag    boolean not null default false,
  duplicate_reason  text,
  duplicate_of      uuid references payments(id) on delete set null,
  verified_by       uuid references app_users(id) on delete set null,
  verified_at       timestamptz,
  rejection_reason  text,
  admin_notes       text,
  submitted_at      timestamptz not null default now(),
  submitted_channel text not null default 'participant_portal',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index payments_participant_idx on payments (participant_id, payment_date desc);
create index payments_status_idx      on payments (status, submitted_at desc);
create index payments_programme_idx   on payments (programme_id, status);
create index payments_date_idx        on payments (payment_date desc);
create index payments_submitted_idx   on payments (submitted_at desc, id);
create index payments_ref_trgm_idx    on payments using gin (reference gin_trgm_ops);
create index payments_payref_trgm_idx on payments using gin (payment_ref gin_trgm_ops);
create index payments_dupe_idx        on payments (duplicate_flag) where duplicate_flag;
-- Duplicate detection runs on every submission, so both of its lookups are
-- index-backed rather than sequential scans.
create index payments_dupe_match_idx on payments (participant_id, amount, payment_date);
create index payments_ref_exact_idx  on payments (upper(btrim(reference))) where reference is not null;
-- Verification queue: partial index keeps the admin worklist fast regardless
-- of how many historical payments accumulate.
create index payments_queue_idx on payments (submitted_at)
  where status in ('pending_review','under_review','requires_clarification');

-- ---------------------------------------------------------------------
-- Proof of payment files. A payment may carry more than one document.
-- Bytes live in Supabase Storage (private bucket); this table is the
-- metadata + access-control record.
-- ---------------------------------------------------------------------
create table pops (
  id           uuid primary key default gen_random_uuid(),
  payment_id   uuid not null references payments(id) on delete cascade,
  storage_path text not null unique,
  file_name    text not null,
  mime_type    text not null,
  file_size    bigint not null check (file_size > 0),
  file_hash    text,                 -- sha256 of the bytes, for duplicate detection
  uploaded_at  timestamptz not null default now(),
  uploaded_by  uuid references app_users(id) on delete set null
);
create index pops_payment_idx on pops (payment_id);
create index pops_hash_idx    on pops (file_hash) where file_hash is not null;

-- ---------------------------------------------------------------------
-- Verification history: every status transition, append-only.
-- ---------------------------------------------------------------------
create table payment_verifications (
  id          bigserial primary key,
  payment_id  uuid not null references payments(id) on delete cascade,
  actor_id    uuid references app_users(id) on delete set null,
  actor_email text,
  from_status payment_status,
  to_status   payment_status not null,
  reason      text,
  note        text,
  created_at  timestamptz not null default now()
);
create index payment_verifications_payment_idx on payment_verifications (payment_id, created_at desc);

-- ---------------------------------------------------------------------
-- Audit log: append-only (see 0003 for the immutability rules).
-- ---------------------------------------------------------------------
create table audit_logs (
  id          bigserial primary key,
  actor_id    uuid,
  actor_email text,
  action      text not null,
  entity_type text not null,
  entity_id   text,
  summary     text,
  metadata    jsonb not null default '{}'::jsonb,
  ip_address  inet,
  user_agent  text,
  created_at  timestamptz not null default now()
);
create index audit_logs_created_idx on audit_logs (created_at desc);
create index audit_logs_actor_idx   on audit_logs (actor_id, created_at desc);
create index audit_logs_entity_idx  on audit_logs (entity_type, entity_id, created_at desc);

-- ---------------------------------------------------------------------
-- Notification outbox. Nothing here sends anything: a worker or Edge
-- Function can be attached later without touching the write paths.
-- ---------------------------------------------------------------------
create type notification_channel as enum ('email','sms','whatsapp');
create type notification_state   as enum ('queued','sent','failed','skipped');

create table notifications (
  id             bigserial primary key,
  participant_id uuid references participants(id) on delete cascade,
  payment_id     uuid references payments(id) on delete cascade,
  channel        notification_channel not null default 'email',
  template       text not null,
  recipient      text,
  payload        jsonb not null default '{}'::jsonb,
  state          notification_state not null default 'queued',
  error          text,
  created_at     timestamptz not null default now(),
  sent_at        timestamptz
);
create index notifications_state_idx on notifications (state, created_at) where state = 'queued';
