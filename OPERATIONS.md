# Operations

## 1. Measured performance

Run against PostgreSQL 16 with **20 000 participants and 52 387 payments**, the
full seed rather than a demo set. Times are from `psql` on a single container,
so treat them as a floor: managed Postgres on real hardware is faster.

| Operation | Time | Notes |
| --- | --- | --- |
| Full seed, 20 000 participants and 52 387 payments | 8 s | Rollup triggers disabled for the load, aggregates rebuilt in one pass. |
| `dashboard_stats()`, every dashboard figure | 159 ms | One round trip, twelve aggregates. |
| Global search by participant ID | 1 to 5 ms | Trigram index. |
| Global search by name | 2.4 ms | |
| Global search by bank reference | 1.8 ms | |
| Payments page 50 (offset 1 250), joined and filtered | 3.5 ms | Partial index on the open-status queue. |
| Participant payment history | 0.2 ms | |
| `programme_report()` | 22 ms | |
| `monthly_payment_report()` over 12 months | 44 ms | |

### Bottlenecks found and fixed

Two real problems surfaced during testing, both now corrected in the migrations:

1. **Search was 70 to 100 ms.** `mobile`, `participant_ref` and `email` had only
   btree indexes, which a case-insensitive `ILIKE` cannot use. Worse, the single
   `WHERE a OR b OR c OR d` with an `ORDER BY` over it forced the planner to
   evaluate every matching row before sorting. Rewritten as four separately
   indexed branches, each with its own `LIMIT`, plus trigram indexes on the
   remaining fields. Bank-reference search went from 36 ms to 3 ms; the rest
   now run in single-digit milliseconds.

2. **Seeding took minutes.** The rollup trigger fired once per inserted payment,
   each firing locking a participant row and re-aggregating. The seed now
   disables the trigger for the bulk load and rebuilds every rollup in one
   statement. This is also the pattern to use for any future bulk migration.

### The remaining ceiling

`dashboard_stats()` scans both tables. At 20 000 participants that is 159 ms,
which is fine. At roughly 200 000 participants it will be noticeably slower, and
the fix at that point is a `dashboard_daily` summary table refreshed every few
minutes, with the function reading the summary and adding only today's rows.
The function signature does not change, so no page needs rewriting.

---

## 2. Testing that was run

```
Migrations 0001, 0002, 0003          applied clean, first attempt
Seed at 20 000 participants           8 s, 52 387 payments, 130 flagged duplicates
Submit a PoP                          payment created, file metadata attached,
                                      notification queued, audit line written
Pending does not count as income       amount_paid unchanged at R0.00 after submission
Duplicate submission                   flagged on all three signals at once:
                                      same participant/amount/date, reused
                                      reference, identical document hash
Reject with no reason                  refused: REJECTION_REASON_REQUIRED
Verify                                 amount_paid R0 to R1 500, outstanding
                                      R12 000 to R10 500, status moved to
                                      Partially paid, history and audit written
Unknown participant ID                 refused: PARTICIPANT_NOT_FOUND
Edit the audit log                     refused: audit_logs is append-only
Delete from the audit log              refused: audit_logs is append-only
TypeScript                             tsc --noEmit clean
Production build                       19 routes compiled, admin routes dynamic
```

### Re-running these

```bash
psql "$DATABASE_URL" -c "select dashboard_stats(null);"
psql "$DATABASE_URL" -c "select global_search('MSRI-001284', 10);"
```

For the workflow, use `/submit` with a participant ID from the seed, then work it
through `/verification` and confirm the participant profile figures move.

---

## 3. Deployment

1. Create the Supabase project. Apply the three migrations in order, either with
   `psql` or the SQL editor. `0003` creates the private storage bucket.
2. Push to GitHub and import the repository into Vercel.
3. Set the environment variables in Vercel. `SUPABASE_SERVICE_ROLE_KEY` goes in
   as a server-side variable only; it must never carry the `NEXT_PUBLIC_` prefix.
4. Deploy, then run `scripts/create-admin.mjs` from your own machine against the
   production project to create the first super administrator.
5. Confirm before announcing the link: sign in, open a seeded PoP, verify one
   payment, and check the audit log recorded it.

Rotate the service role key from the Supabase dashboard if it is ever pasted
anywhere it should not be, and redeploy.

---

## 4. Backup

| What | How | Frequency |
| --- | --- | --- |
| Database | Supabase automatic backups. Point-in-time recovery on Pro. | Daily, retained 7 days |
| Database, independent copy | `pg_dump "$DATABASE_URL" -Fc -f pop-$(date +%F).dump` to storage outside Supabase | Weekly |
| Documents | Bucket copy to separate object storage | Weekly |
| Schema | The migration files, in version control | Every change |

Two points that matter for a payments system. First, keep at least one copy
outside the provider: a backup that can be deleted by the same credentials that
can delete the data is not a backup. Second, restore to a scratch project once a
quarter and confirm a participant's verified total matches the sum of their
verified payments. An untested backup is an assumption.

Retention: keep payment and audit records for at least five years, in line with
the South African Revenue Service's requirement to retain records supporting a
return. Do not prune `audit_logs` with `DELETE`; the append-only triggers block
it by design. When the volume justifies it, partition by month and drop old
partitions.

---

## 5. Security

Built in:

- Supabase Auth for credentials. No password handling in this codebase.
- Row level security on every table, default deny. An authenticated user with no
  `app_users` row sees nothing.
- Role-based access: super admin, finance admin, course admin (optionally granted
  verification, optionally scoped to programmes), viewer.
- Uploads validated by magic number, not by the browser's claimed MIME type.
  PDF, JPEG and PNG only, 10 MB ceiling, enforced at the bucket as well.
- Documents are never publicly reachable. `/api/pop/[popId]` authenticates the
  request, lets RLS decide whether that administrator may see that participant's
  file, then streams it through a five-minute signed link that is never given to
  the browser. Served with `nosniff` and a sandboxing content security policy.
- Storage paths are keyed by UUID, so nothing can be enumerated, and the bucket
  is private regardless.
- Rate limiting on the public submission route.
- CSV export escapes leading `=`, `+`, `-` and `@`, so an exported field cannot
  become a formula when the file is opened in Excel.
- Audit logging on views, downloads, exports, decisions and imports, with IP
  address, immutable at the database level.
- Parameterised queries throughout; no string-built SQL.
- Security headers: HSTS, `X-Frame-Options: DENY`, `nosniff`, restrictive
  referrer and permissions policies.
- The participant form gives the same message for an unknown ID as for a mistyped
  one, so it cannot be used to discover which participant IDs exist.

Worth adding before heavy use: two-factor authentication for finance
administrators (Supabase supports TOTP), and moving the rate limiter into
Postgres or Redis so it holds across multiple server instances rather than one.

---

## 6. Scaling beyond 20 000 participants

The architecture already holds to roughly 100 000 participants without change.
Beyond that, in the order the pressure actually arrives:

1. **Dashboard aggregates.** Add the `dashboard_daily` summary table described
   above. This is the first thing that will slow down.
2. **Deep pagination.** `OFFSET` on page 500 makes Postgres walk every preceding
   row. Switch the payments and participants tables to keyset pagination
   (`where (submitted_at, id) < (:last_at, :last_id)`); the composite indexes to
   support it are already in place.
3. **Partition `payments` and `audit_logs` by month.** Keeps indexes small,
   makes retention a partition drop rather than a mass delete.
4. **Read replica** for reports and exports, so a large export cannot slow down
   the verification queue.
5. **Connection pooling.** Use Supabase's pooler endpoint for serverless
   functions; direct connections exhaust Postgres slots under load.
6. **Move exports to a background job** writing to storage, with a link emailed
   when ready, once exports regularly exceed 100 000 rows.
7. **Storage lifecycle.** At 20 000 participants and three PoPs each, expect
   roughly 30 GB. Move documents older than two years to cold storage; the
   metadata rows stay, so history is unaffected.

The thing not to do is denormalise participant details into `payments` to avoid
joins. The joins are indexed and cost under 4 ms at this scale; duplicated
participant data would cost correctness, which is the one thing a payments
system cannot trade.
