-- =====================================================================
-- 0002_functions.sql — rollups, duplicate detection, stats, search
-- =====================================================================

-- ---------------------------------------------------------------------
-- updated_at
-- ---------------------------------------------------------------------
create or replace function touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create or replace trigger participants_touch before update on participants
  for each row execute function touch_updated_at();
create or replace trigger payments_touch before update on payments
  for each row execute function touch_updated_at();
create or replace trigger programmes_touch before update on programmes
  for each row execute function touch_updated_at();
create or replace trigger app_users_touch before update on app_users
  for each row execute function touch_updated_at();

-- ---------------------------------------------------------------------
-- Participant rollup.
-- Only VERIFIED payments contribute to amount_paid. Called from a trigger
-- on payments, and re-runnable at any time to rebuild a row from source.
-- ---------------------------------------------------------------------
create or replace function recalculate_participant(p_participant_id uuid)
returns void language plpgsql as $$
declare
  v_paid      numeric(12,2);
  v_due       numeric(12,2);
  v_pops      integer;
  v_last      date;
  v_open      integer;   -- payments still in the verification pipeline
  v_rejected  integer;
  v_status    participant_status;
  v_override  participant_status;
begin
  -- Lock the participant row so concurrent verifications serialise.
  select amount_due, status_override into v_due, v_override
    from participants where id = p_participant_id for update;
  if not found then return; end if;

  select
    coalesce(sum(amount) filter (where status = 'verified'), 0),
    count(*),
    max(payment_date) filter (where status = 'verified'),
    count(*) filter (where status in ('pending_review','under_review','requires_clarification')),
    count(*) filter (where status = 'rejected')
  into v_paid, v_pops, v_last, v_open, v_rejected
  from payments where participant_id = p_participant_id;

  if v_due > 0 and v_paid >= v_due then
    v_status := 'fully_paid';
  elsif v_paid > 0 then
    v_status := 'partially_paid';
  elsif v_open > 0 then
    v_status := 'verification_pending';
  elsif v_rejected > 0 then
    v_status := 'payment_issue';
  else
    v_status := 'not_paid';
  end if;

  update participants set
    amount_paid       = v_paid,
    pop_count         = v_pops,
    last_payment_date = v_last,
    payment_status    = coalesce(v_override, v_status),
    updated_at        = now()
  where id = p_participant_id;
end $$;

create or replace function payments_rollup_trigger() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    perform recalculate_participant(old.participant_id);
    return old;
  end if;
  perform recalculate_participant(new.participant_id);
  if tg_op = 'UPDATE' and old.participant_id is distinct from new.participant_id then
    perform recalculate_participant(old.participant_id);
  end if;
  return new;
end $$;

create or replace trigger payments_rollup
  after insert or update of amount, status, participant_id or delete on payments
  for each row execute function payments_rollup_trigger();

-- Keep the payment's programme aligned with the participant's, so
-- programme reports never depend on what the submitter typed.
create or replace function payments_set_programme() returns trigger
language plpgsql as $$
begin
  select programme_id into new.programme_id
    from participants where id = new.participant_id;
  return new;
end $$;

create or replace trigger payments_programme before insert or update of participant_id on payments
  for each row execute function payments_set_programme();

-- ---------------------------------------------------------------------
-- Duplicate detection.
-- Flags, never deletes. A flagged payment still enters the queue so an
-- administrator sees and decides on it.
-- ---------------------------------------------------------------------
create or replace function detect_duplicate_payment(p_payment_id uuid)
returns void language plpgsql as $$
declare
  v_pay    payments%rowtype;
  v_reasons text[] := '{}';
  v_match  uuid;
  v_hash   text;
begin
  select * into v_pay from payments where id = p_payment_id;
  if not found then return; end if;

  -- Same participant, same amount, same payment date.
  select id into v_match from payments
   where id <> v_pay.id
     and participant_id = v_pay.participant_id
     and amount = v_pay.amount
     and payment_date = v_pay.payment_date
     and status <> 'rejected'
   order by submitted_at limit 1;
  if v_match is not null then
    v_reasons := v_reasons || 'Same participant, amount and payment date'::text;
  end if;

  -- Same bank reference anywhere in the system.
  if v_pay.reference is not null and length(trim(v_pay.reference)) > 3 then
    select id into v_match from payments
     where id <> v_pay.id
       and upper(trim(reference)) = upper(trim(v_pay.reference))
       and status <> 'rejected'
     order by submitted_at limit 1;
    if v_match is not null then
      v_reasons := v_reasons || 'Payment reference already used'::text;
    end if;
  end if;

  -- Byte-identical document uploaded before.
  select p.file_hash into v_hash from pops p
   where p.payment_id = v_pay.id and p.file_hash is not null limit 1;
  if v_hash is not null then
    select pm.id into v_match
      from pops po join payments pm on pm.id = po.payment_id
     where po.file_hash = v_hash and pm.id <> v_pay.id and pm.status <> 'rejected'
     order by pm.submitted_at limit 1;
    if v_match is not null then
      v_reasons := v_reasons || 'Identical document already submitted'::text;
    end if;
  end if;

  if array_length(v_reasons, 1) > 0 then
    update payments
       set duplicate_flag = true,
           duplicate_reason = array_to_string(v_reasons, '; '),
           duplicate_of = coalesce(duplicate_of, v_match)
     where id = v_pay.id;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Transaction-safe submission. One call creates the payment, attaches the
-- PoP metadata, runs duplicate detection and queues a notification.
-- ---------------------------------------------------------------------
create or replace function submit_payment(
  p_participant_ref text,
  p_amount          numeric,
  p_payment_date    date,
  p_reference       text,
  p_method          payment_method,
  p_bank            text,
  p_storage_path    text,
  p_file_name       text,
  p_mime_type       text,
  p_file_size       bigint,
  p_file_hash       text,
  p_channel         text default 'participant_portal'
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_participant participants%rowtype;
  v_payment_id  uuid;
  v_ref         text;
begin
  select * into v_participant from participants
   where participant_ref = upper(trim(p_participant_ref));
  if not found then
    raise exception 'PARTICIPANT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'INVALID_AMOUNT' using errcode = 'P0001';
  end if;

  insert into payments (participant_id, programme_id, amount, payment_date,
                        reference, method, bank, submitted_channel)
  values (v_participant.id, v_participant.programme_id, p_amount, p_payment_date,
          nullif(trim(p_reference), ''), p_method, nullif(trim(p_bank), ''), p_channel)
  returning id, payment_ref into v_payment_id, v_ref;

  if p_storage_path is not null then
    insert into pops (payment_id, storage_path, file_name, mime_type, file_size, file_hash)
    values (v_payment_id, p_storage_path, p_file_name, p_mime_type, p_file_size, p_file_hash);
  end if;

  perform detect_duplicate_payment(v_payment_id);

  insert into notifications (participant_id, payment_id, template, recipient, payload)
  values (v_participant.id, v_payment_id, 'pop_received', v_participant.email,
          jsonb_build_object('payment_ref', v_ref, 'amount', p_amount));

  insert into audit_logs (action, entity_type, entity_id, summary, metadata)
  values ('pop.submitted', 'payment', v_payment_id::text,
          format('PoP %s submitted for %s', v_ref, v_participant.participant_ref),
          jsonb_build_object('amount', p_amount, 'channel', p_channel));

  return jsonb_build_object(
    'payment_id', v_payment_id,
    'payment_ref', v_ref,
    'participant_name', v_participant.full_name,
    'programme_id', v_participant.programme_id
  );
end $$;

-- ---------------------------------------------------------------------
-- Verification decision, recorded atomically with its history entry.
-- ---------------------------------------------------------------------
create or replace function decide_payment(
  p_payment_id uuid,
  p_to_status  payment_status,
  p_actor_id   uuid,
  p_reason     text default null,
  p_note       text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_from  payment_status;
  v_email text;
  v_pref  text;
  v_part  uuid;
begin
  select status, participant_id, payment_ref into v_from, v_part, v_pref
    from payments where id = p_payment_id for update;
  if not found then raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0002'; end if;

  if p_to_status = 'rejected' and coalesce(trim(p_reason), '') = '' then
    raise exception 'REJECTION_REASON_REQUIRED' using errcode = 'P0001';
  end if;

  select email into v_email from app_users where id = p_actor_id;

  update payments set
    status           = p_to_status,
    verified_by      = case when p_to_status = 'verified' then p_actor_id else verified_by end,
    verified_at      = case when p_to_status = 'verified' then now() else verified_at end,
    rejection_reason = case when p_to_status = 'rejected' then p_reason else rejection_reason end,
    admin_notes      = coalesce(nullif(trim(p_note), ''), admin_notes)
  where id = p_payment_id;

  insert into payment_verifications (payment_id, actor_id, actor_email, from_status, to_status, reason, note)
  values (p_payment_id, p_actor_id, v_email, v_from, p_to_status, p_reason, p_note);

  insert into audit_logs (actor_id, actor_email, action, entity_type, entity_id, summary, metadata)
  values (p_actor_id, v_email, 'payment.' || p_to_status::text, 'payment', p_payment_id::text,
          format('%s moved from %s to %s', v_pref, v_from, p_to_status),
          jsonb_build_object('reason', p_reason));

  if p_to_status in ('verified','rejected') then
    insert into notifications (participant_id, payment_id, template, recipient, payload)
    select v_part, p_payment_id,
           case when p_to_status = 'verified' then 'payment_verified' else 'payment_rejected' end,
           pt.email, jsonb_build_object('payment_ref', v_pref, 'reason', p_reason)
      from participants pt where pt.id = v_part;
  end if;

  return jsonb_build_object('payment_id', p_payment_id, 'from', v_from, 'to', p_to_status);
end $$;

-- ---------------------------------------------------------------------
-- Dashboard statistics. One round trip, all aggregates.
-- ---------------------------------------------------------------------
create or replace function dashboard_stats(p_programme_id uuid default null)
returns jsonb language sql stable as $$
  with pt as (
    select * from participants
     where p_programme_id is null or programme_id = p_programme_id
  ), pm as (
    select * from payments
     where p_programme_id is null or programme_id = p_programme_id
  )
  select jsonb_build_object(
    'participants_total',      (select count(*) from pt),
    'pops_total',              (select count(*) from pm),
    'pops_pending',            (select count(*) from pm where status in ('pending_review','under_review')),
    'pops_verified',           (select count(*) from pm where status = 'verified'),
    'pops_rejected',           (select count(*) from pm where status = 'rejected'),
    'pops_attention',          (select count(*) from pm where status in ('requires_clarification','duplicate') or duplicate_flag),
    'amount_declared',         (select coalesce(sum(amount),0) from pm),
    'amount_verified',         (select coalesce(sum(amount),0) from pm where status = 'verified'),
    'received_today',          (select coalesce(sum(amount),0) from pm where status = 'verified' and payment_date = current_date),
    'received_month',          (select coalesce(sum(amount),0) from pm where status = 'verified' and payment_date >= date_trunc('month', current_date)),
    'submitted_today',         (select count(*) from pm where submitted_at >= current_date),
    'participants_fully_paid', (select count(*) from pt where payment_status = 'fully_paid'),
    'participants_outstanding',(select count(*) from pt where outstanding > 0),
    'outstanding_total',       (select coalesce(sum(outstanding),0) from pt where outstanding > 0),
    'status_breakdown',        (select coalesce(jsonb_object_agg(payment_status, n), '{}'::jsonb)
                                  from (select payment_status, count(*) n from pt group by 1) s),
    'verification_breakdown',  (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
                                  from (select status, count(*) n from pm group by 1) s),
    'payments_over_time',      (select coalesce(jsonb_agg(row_to_json(d) order by d.day), '[]'::jsonb)
                                  from (select payment_date::text as day,
                                               count(*) as count,
                                               sum(amount) filter (where status='verified') as verified_amount
                                          from pm
                                         where payment_date >= current_date - interval '30 days'
                                         group by payment_date) d),
    'by_programme',            (select coalesce(jsonb_agg(row_to_json(g) order by g.name), '[]'::jsonb)
                                  from (select pr.name,
                                               count(distinct p.id) as participants,
                                               coalesce(sum(p.amount_paid),0) as paid,
                                               coalesce(sum(p.outstanding),0) as outstanding
                                          from programmes pr
                                          left join pt p on p.programme_id = pr.id
                                         group by pr.name) g)
  );
$$;

-- ---------------------------------------------------------------------
-- Global search. Participant ref / name / email / mobile / payment ref /
-- bank reference, in one call, capped and index-backed.
-- ---------------------------------------------------------------------
create or replace function global_search(p_query text, p_limit int default 10)
returns jsonb language sql stable as $$
  -- Each branch is written so exactly one index serves it and stops at
  -- p_limit. A single OR-ed WHERE with an ORDER BY over it cannot use the
  -- trigram indexes and degrades into a full scan as the table grows.
  with q as (select trim(p_query) as t),
  pmatch as (
    (select id, 1 as rank from participants, q where participant_ref ilike q.t || '%' limit p_limit)
    union
    (select id, 2      from participants, q where full_name ilike '%' || q.t || '%' limit p_limit)
    union
    (select id, 3      from participants, q where email::text ilike q.t || '%' limit p_limit)
    union
    (select id, 4      from participants, q where mobile ilike '%' || q.t || '%' limit p_limit)
  ),
  xmatch as (
    (select id, 1 as rank from payments, q where payment_ref ilike q.t || '%' limit p_limit)
    union
    (select id, 2      from payments, q where reference ilike '%' || q.t || '%' limit p_limit)
  )
  select jsonb_build_object(
    'participants', (
      select coalesce(jsonb_agg(row_to_json(r) order by r.rank), '[]'::jsonb) from (
        select distinct on (p.id)
               m.rank, p.id, p.participant_ref, p.full_name, p.email, p.mobile,
               pr.name as programme, p.payment_status, p.outstanding
          from pmatch m
          join participants p on p.id = m.id
          join programmes pr on pr.id = p.programme_id
         order by p.id, m.rank
         limit p_limit) r),
    'payments', (
      select coalesce(jsonb_agg(row_to_json(r) order by r.rank), '[]'::jsonb) from (
        select distinct on (pm.id)
               m.rank, pm.id, pm.payment_ref, pm.reference, pm.amount, pm.payment_date,
               pm.status, p.full_name, p.participant_ref
          from xmatch m
          join payments pm on pm.id = m.id
          join participants p on p.id = pm.participant_id
         order by pm.id, m.rank
         limit p_limit) r)
  );
$$;

-- ---------------------------------------------------------------------
-- Reports
-- ---------------------------------------------------------------------
create or replace function programme_report(p_from date default null, p_to date default null)
returns table (
  programme text, code text, participants bigint, pops_submitted bigint,
  verified_payments bigint, pending_payments bigint,
  total_verified numeric, outstanding numeric
) language sql stable as $$
  select pr.name, pr.code,
         count(distinct p.id),
         count(pm.id),
         count(pm.id) filter (where pm.status = 'verified'),
         count(pm.id) filter (where pm.status in ('pending_review','under_review','requires_clarification')),
         coalesce(sum(pm.amount) filter (where pm.status = 'verified'), 0),
         coalesce((select sum(outstanding) from participants x where x.programme_id = pr.id and x.outstanding > 0), 0)
    from programmes pr
    left join participants p on p.programme_id = pr.id
    left join payments pm on pm.participant_id = p.id
         and (p_from is null or pm.payment_date >= p_from)
         and (p_to   is null or pm.payment_date <= p_to)
   group by pr.id, pr.name, pr.code
   order by pr.name;
$$;

create or replace function monthly_payment_report(p_months int default 12)
returns table (
  month text, payments bigint, total numeric,
  verified numeric, pending numeric, rejected numeric
) language sql stable as $$
  select to_char(date_trunc('month', payment_date), 'YYYY-MM'),
         count(*),
         coalesce(sum(amount), 0),
         coalesce(sum(amount) filter (where status = 'verified'), 0),
         coalesce(sum(amount) filter (where status in ('pending_review','under_review','requires_clarification')), 0),
         coalesce(sum(amount) filter (where status = 'rejected'), 0)
    from payments
   where payment_date >= date_trunc('month', current_date) - (p_months || ' months')::interval
   group by 1 order by 1 desc;
$$;

create or replace function daily_payment_report(p_days int default 30)
returns table (day date, submitted bigint, verified bigint, total numeric, verified_total numeric)
language sql stable as $$
  select payment_date, count(*),
         count(*) filter (where status = 'verified'),
         coalesce(sum(amount), 0),
         coalesce(sum(amount) filter (where status = 'verified'), 0)
    from payments
   where payment_date >= current_date - p_days
   group by payment_date order by payment_date desc;
$$;
