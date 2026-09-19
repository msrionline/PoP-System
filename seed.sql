-- =====================================================================
-- seed.sql — demo + performance data
--
--   Default: 20 000 participants and roughly 34 000 payments.
--   For a small demo set, change v_participants below to 120.
--
--   psql "$DATABASE_URL" -f supabase/seed/seed.sql
-- =====================================================================

begin;

-- Rollup triggers are disabled for the bulk load and the aggregates are
-- rebuilt in one pass at the end. Loading 34 000 payments row-by-row
-- through the trigger takes minutes; this takes seconds.
alter table payments disable trigger payments_rollup;
alter table payments disable trigger payments_programme;

truncate payment_verifications, notifications, pops, payments, participants, cohorts, programmes restart identity cascade;

-- participant_ref_seq and payment_ref_seq are standalone sequences, so
-- TRUNCATE ... RESTART IDENTITY does not touch them. Reset explicitly, or a
-- re-seed hands out MSRI-021000 upwards instead of starting at MSRI-001000.
alter sequence participant_ref_seq restart 1000;
alter sequence payment_ref_seq restart 1000;

insert into programmes (code, name, amount_due) values
  ('HC-AIS',   'Higher Certificate in African Indigenous Spirituality', 12000.00),
  ('HC-AFMP',  'Higher Certificate in African Family Matters and Polygamy', 12000.00),
  ('HC-SLDM',  'Higher Certificate in Spiritual Leadership Development and Management', 12500.00),
  ('SP-MASTER','Short Programme: Personal Mastery', 2000.00),
  ('SP-RESM',  'Short Programme: Research Methodology in AIS', 2500.00),
  ('OC-AGRI',  'Occupational Certificate: Plant Production', 8500.00);

insert into cohorts (programme_id, code, name, start_date, end_date)
select p.id, c.code, c.name, c.start_date, c.end_date
from programmes p
cross join (values
  ('2026-S1', 'Semester 1 2026', date '2026-02-01', date '2026-06-30'),
  ('2026-S2', 'Semester 2 2026', date '2026-07-01', date '2026-11-30'),
  ('2027-S1', 'Semester 1 2027', date '2027-02-01', date '2027-06-30')
) as c(code, name, start_date, end_date);

do $$
declare
  v_participants int := 20000;   -- <-- set to 120 for a light demo database
  v_first text[] := array['Thabo','Nomsa','Sipho','Lerato','Mandla','Zanele','Kagiso','Palesa',
                          'Bongani','Thandi','Sibusiso','Nolwazi','Tshepo','Refilwe','Musa','Ayanda',
                          'Lindiwe','Katlego','Nkosinathi','Busisiwe','Themba','Dineo','Sizwe','Nonhlanhla',
                          'Karabo','Mpho','Andile','Zodwa','Lwazi','Precious','Vusi','Gugu',
                          'Simphiwe','Boitumelo','Jabulani','Ntombi','Sandile','Phumzile','Tebogo','Naledi'];
  v_last text[] := array['Radebe','Dlamini','Nkosi','Mokoena','Khumalo','Mabaso','Zulu','Molefe',
                         'Ngcobo','Sithole','Maseko','Mthembu','Ndlovu','Mahlangu','Motaung','Cele',
                         'Shabangu','Nyathi','Mkhize','Baloyi','Mnguni','Tshabalala','Ngwenya','Sibanda',
                         'Gama','Langa','Mashaba','Ntuli','Msimang','Zwane'];
  v_banks text[] := array['FNB','Standard Bank','ABSA','Nedbank','Capitec','TymeBank'];
begin
  insert into participants (first_name, surname, email, mobile, programme_id, cohort_id,
                            registration_date, amount_due, notes)
  select
    v_first[1 + (g % array_length(v_first,1))],
    v_last[1 + ((g / 7) % array_length(v_last,1))],
    lower(v_first[1 + (g % array_length(v_first,1))] || '.' ||
          v_last[1 + ((g / 7) % array_length(v_last,1))] || g || '@example.co.za'),
    '0' || (60 + (g % 24))::text || lpad(((g * 7919) % 10000000)::text, 7, '0'),
    pr.id,
    (select c.id from cohorts c where c.programme_id = pr.id order by c.code offset (g % 3) limit 1),
    current_date - ((g % 400))::int,
    pr.amount_due,
    case when g % 250 = 0 then 'Bursary applicant. Confirm funder before invoicing.' end
  from generate_series(1, v_participants) g
  cross join lateral (
    select id, amount_due from programmes order by (g % 6), code limit 1
  ) pr;

  -- Payments. Participants fall into bands so the dashboard shows a
  -- realistic mix: fully paid, part paid, pending, rejected, unpaid.
  insert into payments (participant_id, programme_id, amount, payment_date, reference,
                        method, bank, status, submitted_at, verified_at, rejection_reason)
  select
    p.id, p.programme_id,
    round((p.amount_due / inst.total)::numeric, 2),
    p.registration_date + (inst.n * 21),
    'TRX' || lpad(((abs(hashtext(p.id::text)) + inst.n * 13) % 9000000 + 1000000)::text, 7, '0'),
    (array['eft','cash_deposit','card','mobile_money'])[1 + (inst.n % 4)]::payment_method,
    v_banks[1 + ((abs(hashtext(p.id::text)) + inst.n) % 6)],
    case
      when band.b = 0 then 'verified'
      when band.b = 1 and inst.n < inst.total then 'verified'
      when band.b = 1 then 'pending_review'
      when band.b = 2 then 'pending_review'
      when band.b = 3 and inst.n = 1 then 'rejected'
      when band.b = 3 then 'under_review'
      when band.b = 4 then 'requires_clarification'
      else 'verified'
    end::payment_status,
    p.registration_date + (inst.n * 21) + 1,
    case when band.b in (0,5) then (p.registration_date + (inst.n * 21) + 2)::timestamptz end,
    case when band.b = 3 and inst.n = 1 then 'Unclear document' end
  from participants p
  cross join lateral (select (abs(hashtext(p.id::text)) % 8) as b) band
  cross join lateral (
    select total, generate_series(1, total) as n
    from (select case when band.b = 6 then 0 else 3 end as total) t
  ) inst
  where band.b <> 6;   -- band 6 never paid

  -- A handful of genuine duplicate submissions to exercise the review path.
  insert into payments (participant_id, programme_id, amount, payment_date, reference, method, bank, status)
  select participant_id, programme_id, amount, payment_date, reference, method, bank, 'pending_review'
    from payments
   where status = 'verified'
   order by submitted_at
   limit greatest(1, (select count(*) / 400 from payments));
end $$;

-- Attach a PoP metadata record to every payment.
insert into pops (payment_id, storage_path, file_name, mime_type, file_size, file_hash)
select id,
       'participants/' || participant_id || '/payments/' || id || '/proof-of-payment.pdf',
       'proof-of-payment.pdf', 'application/pdf',
       80000 + (abs(hashtext(id::text)) % 400000),
       encode(digest(coalesce(reference, id::text), 'sha256'), 'hex')
  from payments;

-- Flag the seeded duplicates. This is the set-based equivalent of
-- detect_duplicate_payment(), which runs per row at submission time.
with ranked as (
  select id,
         first_value(id) over w as first_id,
         row_number()    over w as rn
    from payments
   where status <> 'rejected'
  window w as (partition by participant_id, amount, payment_date order by submitted_at, id)
)
update payments p
   set duplicate_flag   = true,
       duplicate_reason = 'Same participant, amount and payment date',
       duplicate_of     = r.first_id
  from ranked r
 where r.id = p.id and r.rn > 1;

alter table payments enable trigger payments_rollup;
alter table payments enable trigger payments_programme;

-- Rebuild every participant rollup in a single pass.
update participants p set
  amount_paid       = coalesce(a.paid, 0),
  pop_count         = coalesce(a.pops, 0),
  last_payment_date = a.last_date,
  payment_status    = case
    when p.amount_due > 0 and coalesce(a.paid,0) >= p.amount_due then 'fully_paid'
    when coalesce(a.paid,0) > 0 then 'partially_paid'
    when coalesce(a.open,0) > 0 then 'verification_pending'
    when coalesce(a.rejected,0) > 0 then 'payment_issue'
    else 'not_paid' end::participant_status
from (
  select participant_id,
         sum(amount) filter (where status = 'verified') as paid,
         count(*) as pops,
         max(payment_date) filter (where status = 'verified') as last_date,
         count(*) filter (where status in ('pending_review','under_review','requires_clarification')) as open,
         count(*) filter (where status = 'rejected') as rejected
    from payments group by participant_id
) a
where a.participant_id = p.id;

analyze participants;
analyze payments;
analyze pops;

commit;

select (select count(*) from participants) as participants,
       (select count(*) from payments) as payments,
       (select count(*) from payments where duplicate_flag) as flagged_duplicates,
       (select count(*) from participants where payment_status = 'fully_paid') as fully_paid;
