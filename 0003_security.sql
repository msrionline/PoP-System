-- =====================================================================
-- 0003_security.sql — role helpers, RLS, audit immutability, storage
-- Default posture: deny. Nothing is readable by anon or by an
-- authenticated user who has no app_users row.
-- =====================================================================

create or replace function current_role_of() returns user_role
language sql stable security definer set search_path = public as $$
  select role from app_users where id = auth.uid() and is_active;
$$;

create or replace function is_admin() returns boolean
language sql stable as $$ select current_role_of() is not null; $$;

create or replace function is_super() returns boolean
language sql stable as $$ select current_role_of() = 'super_admin'; $$;

create or replace function can_verify_payments() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from app_users
     where id = auth.uid() and is_active
       and (role in ('super_admin','finance_admin') or (role = 'course_admin' and can_verify))
  );
$$;

-- Programme scoping for course admins. Empty programme_ids = unrestricted.
create or replace function in_programme_scope(p_programme_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from app_users u
     where u.id = auth.uid() and u.is_active
       and (u.role <> 'course_admin'
            or cardinality(u.programme_ids) = 0
            or p_programme_id = any(u.programme_ids))
  );
$$;

alter table app_users             enable row level security;
alter table programmes            enable row level security;
alter table cohorts               enable row level security;
alter table participants          enable row level security;
alter table payments              enable row level security;
alter table pops                  enable row level security;
alter table payment_verifications enable row level security;
alter table audit_logs            enable row level security;
alter table notifications         enable row level security;

-- app_users ------------------------------------------------------------
create policy app_users_self on app_users for select to authenticated
  using (id = auth.uid() or is_admin());
create policy app_users_manage on app_users for all to authenticated
  using (is_super()) with check (is_super());

-- programmes / cohorts --------------------------------------------------
create policy programmes_read on programmes for select to authenticated using (is_admin());
create policy programmes_write on programmes for all to authenticated
  using (is_super()) with check (is_super());
create policy cohorts_read on cohorts for select to authenticated using (is_admin());
create policy cohorts_write on cohorts for all to authenticated
  using (is_super()) with check (is_super());

-- participants ----------------------------------------------------------
create policy participants_read on participants for select to authenticated
  using (is_admin() and in_programme_scope(programme_id));
create policy participants_write on participants for insert to authenticated
  with check (current_role_of() in ('super_admin','finance_admin'));
create policy participants_update on participants for update to authenticated
  using (current_role_of() in ('super_admin','finance_admin'))
  with check (current_role_of() in ('super_admin','finance_admin'));
create policy participants_delete on participants for delete to authenticated
  using (is_super());

-- payments --------------------------------------------------------------
create policy payments_read on payments for select to authenticated
  using (is_admin() and in_programme_scope(programme_id));
create policy payments_update on payments for update to authenticated
  using (can_verify_payments() and in_programme_scope(programme_id))
  with check (can_verify_payments() and in_programme_scope(programme_id));
create policy payments_insert on payments for insert to authenticated
  with check (current_role_of() in ('super_admin','finance_admin'));
create policy payments_delete on payments for delete to authenticated
  using (is_super());

-- pops ------------------------------------------------------------------
create policy pops_read on pops for select to authenticated
  using (exists (select 1 from payments pm
                  where pm.id = pops.payment_id and in_programme_scope(pm.programme_id)) and is_admin());
create policy pops_write on pops for all to authenticated
  using (current_role_of() in ('super_admin','finance_admin'))
  with check (current_role_of() in ('super_admin','finance_admin'));

-- verification history ---------------------------------------------------
create policy verifications_read on payment_verifications for select to authenticated
  using (is_admin());

-- audit log: readable by admins, append-only for everyone -----------------
create policy audit_read on audit_logs for select to authenticated using (is_admin());
create policy audit_append on audit_logs for insert to authenticated with check (is_admin());

create or replace function block_audit_mutation() returns trigger
language plpgsql as $$
begin
  raise exception 'audit_logs is append-only';
end $$;

create trigger audit_no_update before update on audit_logs
  for each row execute function block_audit_mutation();
create trigger audit_no_delete before delete on audit_logs
  for each row execute function block_audit_mutation();
-- The triggers fire for the service role too, so a leaked server key still
-- cannot rewrite history. Retention is handled by partition drop, not DELETE.

create policy notifications_read on notifications for select to authenticated using (is_admin());

-- ---------------------------------------------------------------------
-- Function grants. The participant portal calls submit_payment through a
-- server action holding the service role key, never from the browser, so
-- anon gets no execute rights anywhere.
-- ---------------------------------------------------------------------
revoke all on function submit_payment(text, numeric, date, text, payment_method, text, text, text, text, bigint, text, text) from public, anon;
revoke all on function decide_payment(uuid, payment_status, uuid, text, text) from public, anon;
grant execute on function decide_payment(uuid, payment_status, uuid, text, text) to authenticated;
grant execute on function dashboard_stats(uuid) to authenticated;
grant execute on function global_search(text, int) to authenticated;
grant execute on function programme_report(date, date) to authenticated;
grant execute on function monthly_payment_report(int) to authenticated;
grant execute on function daily_payment_report(int) to authenticated;

-- ---------------------------------------------------------------------
-- Storage. Private bucket, no public URL, 10 MB ceiling, fixed MIME list.
-- Objects are reached only through short-lived signed URLs minted by the
-- server after a role check.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('proof-of-payment', 'proof-of-payment', false, 10485760,
        array['application/pdf','image/jpeg','image/png'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

create policy pop_objects_read on storage.objects for select to authenticated
  using (bucket_id = 'proof-of-payment' and is_admin());
create policy pop_objects_write on storage.objects for insert to authenticated
  with check (bucket_id = 'proof-of-payment' and current_role_of() in ('super_admin','finance_admin'));
