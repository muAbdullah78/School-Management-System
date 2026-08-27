-- =============================================================================
-- 0069 — Nothing records what this database has actually had applied
--
-- This is the highest-value change in the super-admin design and it is not a
-- screen. See docs/SUPER-ADMIN-DESIGN.md §2.4.
--
-- THE PROBLEM
--
-- Production gets its schema by a human pasting supabase/bundles/*.sql into the
-- Supabase SQL editor. Nothing anywhere records which files that actually
-- applied. The order lives in SETUP.md and in somebody's memory.
--
-- With one school, a wrong paste is an evening's annoyance. With fifty it is
-- fifty schools down, with no rollback and — worse — no way to even determine
-- which state the database is in before deciding what to do. And it happens on
-- a Monday morning, because that is when maintenance happens.
--
-- This is not hypothetical on this project. It has already gone wrong twice:
--
--   * Bundle 3 shipped matching {0033, 0034}. Its glob was 003[3-9]*, so as
--     0035-0039 were written the SAME file silently absorbed them. A school that
--     had already pasted bundle 3 could not re-paste it (0033 fails on "column
--     family_id already exists"), and because a bundle is one transaction the
--     whole thing rolled back — so 0035-0039 never arrived, and bundle 4 could
--     not apply either because it needed a column from 0035. Fifteen migrations
--     went missing from a live school.
--
--   * When that school reported the breakage, the state had to be GUESSED from
--     the error message. The guess was wrong — fifteen missing, when it was two
--     — and the repair file handed over failed on its first statement because it
--     began with a migration they already had. supabase/repair/detect.sql exists
--     because of that, and its own header says it plainly: "There is no
--     migration ledger in this project."
--
-- Bundle 6 is in the same position right now: it has been pasted into a live
-- database and has since grown from {0057..0063} to {0057..0067}, and it is not
-- in supabase/bundles/MANIFEST, so the freeze guard that exists to catch exactly
-- this is not covering it.
--
-- WHAT THIS DOES
--
-- One table, one row per migration file, and a helper the generated bundles call
-- so that from here on a paste records itself. After this, "what does production
-- have?" is a SELECT rather than an archaeology exercise.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The ledger
--
-- RLS is on with a read policy for the operator and no write policy for anybody.
-- Both halves matter:
--
--   * RLS must be ON because 0001:704 grants SELECT/INSERT/UPDATE/DELETE on all
--     tables in public to `authenticated`, and 0025:768 makes that the default
--     for tables created afterwards — including this one. Without RLS every
--     signed-in clerk at every school could rewrite the deployment record.
--     tenant_isolation.sql check 4d fails CI if any table in public arrives
--     without it.
--
--   * No write policy at all, so nothing reachable from a browser session can
--     insert, update or delete a row — not even the operator. Rows arrive only
--     through fn_record_migration below, which is SECURITY DEFINER, or from the
--     service role / SQL editor, which is how a migration is applied in the
--     first place. A deployment record a signed-in user can edit is a record
--     that proves nothing.
--
-- No school_id: this describes the database, not a tenant. That is why check 4d
-- had to exist — 4a and 4c only look at tables carrying a school_id, so a
-- platform table like this one would have passed them without RLS at all.
-- ---------------------------------------------------------------------------
create table if not exists public.schema_migrations (
  filename    text primary key,
  applied_at  timestamptz not null default now(),
  -- Which bundle carried it, when it came through one. Null for a file applied
  -- on its own, and 'baseline' for the adoption below.
  bundle      text,
  note        text
);

alter table public.schema_migrations enable row level security;

drop policy if exists schema_migrations_read on public.schema_migrations;
create policy schema_migrations_read on public.schema_migrations
  for select using (public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- 2. Recording
--
-- `on conflict do nothing`, because re-applying a migration is normal on this
-- project — every file is written to be re-runnable — and the interesting date
-- is when it FIRST landed, not when it was last replayed.
--
-- SECURITY DEFINER so a bundle pasted in the SQL editor can call it without any
-- grant juggling, and revoked from the browser roles so nothing in the app can
-- write a row claiming a migration was applied when it was not.
-- ---------------------------------------------------------------------------
create or replace function public.fn_record_migration(
  p_filename text, p_bundle text default null, p_note text default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.schema_migrations (filename, bundle, note)
  values (p_filename, p_bundle, p_note)
  on conflict (filename) do nothing;
end;
$$;

revoke all on function public.fn_record_migration(text, text, text) from public;

-- ---------------------------------------------------------------------------
-- 3. What state is this database in?
--
-- For the operator console. Returns the count, the highest file applied, and
-- anything applied out of numeric order — which is the shape a botched paste
-- leaves behind and the thing a human reading a list would miss.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_schema_state()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'applied_count', count(*),
    'latest',        max(filename),
    'latest_at',     max(applied_at),
    -- A gap in the numeric sequence. 0001..0069 with 0044 missing means a
    -- bundle rolled back halfway and nobody noticed, which is precisely the
    -- failure this table exists to make visible.
    --
    -- Two guards, both learned by watching this return 9,930 entries:
    --
    --   * Only filenames shaped like a migration count. A single row named
    --     something else — a fixture, a hand-typed correction — drove
    --     max(left(filename,4)::int) to 9999 and the series enumerated every
    --     number below it as "missing". A `where filename ~ '^[0-9]{4}_'` costs
    --     nothing and stops one bad row making the report useless.
    --
    --   * The list is CAPPED, with the true count reported separately. A
    --     console tile cannot render nine thousand numbers, and a report that
    --     floods the screen is one an operator learns to skip — which is the
    --     same outcome as not having it.
    'gaps', (
      select coalesce(jsonb_agg(g order by g), '[]'::jsonb) from (
        select lpad(n::text, 4, '0') as g
        from generate_series(
               (select min(left(filename, 4)::int) from public.schema_migrations
                 where filename ~ '^[0-9]{4}_'),
               (select max(left(filename, 4)::int) from public.schema_migrations
                 where filename ~ '^[0-9]{4}_')) n
        where not exists (
          select 1 from public.schema_migrations m
           where m.filename ~ '^[0-9]{4}_'
             and left(m.filename, 4) = lpad(n::text, 4, '0'))
        order by n
        limit 25
      ) x
    ),
    'gaps_total', (
      select count(*) from generate_series(
               (select min(left(filename, 4)::int) from public.schema_migrations
                 where filename ~ '^[0-9]{4}_'),
               (select max(left(filename, 4)::int) from public.schema_migrations
                 where filename ~ '^[0-9]{4}_')) n
       where not exists (
         select 1 from public.schema_migrations m
          where m.filename ~ '^[0-9]{4}_'
            and left(m.filename, 4) = lpad(n::text, 4, '0'))
    ),
    'bundles', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'bundle', b, 'files', c, 'applied_at', t) order by b), '[]'::jsonb)
      from (select coalesce(bundle, '(single files)') as b,
                   count(*) as c, min(applied_at) as t
              from public.schema_migrations group by 1) y
    )
  ) into v from public.schema_migrations;

  return v;
end;
$$;

grant execute on function public.fn_platform_schema_state() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Adoption — seed the ledger for a database that is already up to date
--
-- The awkward case, and the one that has to be right: production has had
-- bundles 1-6 pasted into it and has no ledger. Doing nothing would leave the
-- table empty and the console would report a database with no schema, which is
-- worse than no table at all.
--
-- So this records 0001..0069 as applied — but ONLY after proving the chain is
-- really there. Six probes, one per shipped bundle, each looking for an object
-- that the LAST migration in that bundle creates. If any is missing, nothing is
-- recorded and the notice says which: an empty ledger on a half-migrated
-- database is a true statement, while a full one would be a lie that then
-- justifies skipping the repair.
--
-- The probes are the same signatures supabase/repair/detect.sql uses, chosen the
-- same way and for the same reasons — several of these migrations only REPLACED
-- an existing function, so presence of the function proves nothing and the
-- signature has to be a string inside its body. Never `::regproc` or
-- `::regclass`: both RAISE on a missing object, which would abort this block on
-- exactly the incomplete database it is meant to assess. (detect.sql learned
-- that the hard way; its 0067 row carries the comment.)
--
-- The filename list is written out in full rather than derived, because a
-- database cannot see the repo. It is checked against the directory by
-- supabase/check-ledger-baseline.sh, so it cannot drift.
-- ---------------------------------------------------------------------------
do $adopt$
declare
  v_missing text[] := '{}';
  v_files   text[] := array[
    '0001_core_schema.sql', '0002_fees.sql', '0003_attendance.sql',
    '0004_admissions.sql', '0005_exams.sql', '0006_settings.sql',
    '0007_certificates.sql', '0008_dashboard.sql', '0009_assessments.sql',
    '0010_staff.sql', '0011_auth.sql', '0012_import.sql', '0013_fee_import.sql',
    '0014_rollover.sql', '0015_exam_papers.sql', '0016_staff_import.sql',
    '0017_fee_ops.sql', '0018_fee_reconciliation.sql',
    '0019_student_links_and_admission_fee.sql', '0020_fee_month_ops.sql',
    '0021_fee_fixes.sql', '0022_teacher_portal.sql', '0023_test_scoping.sql',
    '0024_teacher_portal_hardening.sql', '0025_multi_tenancy.sql',
    '0026_subscriptions.sql', '0027_platform_admin.sql', '0028_pricing.sql',
    '0029_families.sql', '0030_expenses.sql', '0031_till.sql',
    '0032_parent_role.sql', '0033_portal.sql', '0034_outbox.sql',
    '0035_fee_ops.sql', '0036_family_linkage.sql', '0037_parent_access.sql',
    '0038_counter.sql', '0039_challan.sql', '0040_bulk_fees.sql',
    '0041_student_list.sql', '0042_dashboard_truth.sql',
    '0043_message_settings.sql', '0044_reports.sql', '0045_balance_sheet.sql',
    '0046_enquiries.sql', '0047_reachability.sql', '0048_corrections.sql',
    '0049_remarks_and_positions.sql', '0050_search_and_birthdays.sql',
    '0051_like_escaping.sql', '0052_recent_payments_order.sql',
    '0053_staff_leaving.sql', '0054_student_leaving.sql',
    '0055_rollover_scoping.sql', '0056_importer_scoping.sql',
    '0057_photos_and_logo.sql', '0058_exam_computation.sql',
    '0059_readonly_boundary.sql', '0060_refundable_deposits.sql',
    '0061_certificates.sql', '0062_staff_checkin.sql',
    '0063_constraint_function_grants.sql', '0064_operator_billing.sql',
    '0065_invite_only_provisioning.sql', '0066_fee_setup.sql',
    '0067_live_student_count.sql', '0068_limit_notice_timing.sql',
    '0069_migration_ledger.sql'
  ];
  f text;
  v_n integer;
begin
  -- array_append, not `v_missing || '...'`. The concatenation form is ambiguous
  -- between anyarray||anyarray and anyarray||anyelement, and Postgres resolves
  -- an untyped string literal to the FORMER — so it tries to parse the message
  -- as an array and dies with 'malformed array literal: "bundle 6 ..."'.
  --
  -- Which only happens on the branch that reports an INCOMPLETE database. The
  -- happy path never touches v_missing, so this passed every run against a
  -- fully-migrated database and would have failed on the one path that exists
  -- to protect a school from a half-applied schema. Found by deleting a trigger
  -- and re-running, not by reading.
  -- Already seeded (or already recording itself through a bundle): leave it be.
  -- The interesting date is when a file FIRST landed.
  if exists (select 1 from public.schema_migrations) then
    raise notice '0069: ledger already has % row(s) — not re-seeding',
      (select count(*) from public.schema_migrations);
    return;
  end if;

  -- Bundle 1 ends at 0031_till.
  if not exists (select 1 from information_schema.tables
                  where table_schema = 'public' and table_name = 'till_sessions') then
    v_missing := array_append(v_missing, 'bundle 1 (0001-0031): till_sessions is absent');
  end if;

  -- Bundle 2 is 0032 alone: it added 'parent' to the user_role enum.
  if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                  where t.typname = 'user_role' and e.enumlabel = 'parent') then
    v_missing := array_append(v_missing, 'bundle 2 (0032): user_role has no ''parent'' value');
  end if;

  -- Bundle 3 ends at 0039_challan.
  if not exists (select 1 from pg_proc where proname = 'fn_challan'
                  and pronamespace = 'public'::regnamespace) then
    v_missing := array_append(v_missing, 'bundle 3 (0033-0039): fn_challan is absent');
  end if;

  -- Bundle 4 ends at 0049_remarks_and_positions.
  if not exists (select 1 from information_schema.tables
                  where table_schema = 'public' and table_name = 'exam_remarks') then
    v_missing := array_append(v_missing, 'bundle 4 (0040-0049): exam_remarks is absent');
  end if;

  -- Bundle 5 ends at 0056_importer_scoping, which only REWROTE importers that
  -- date from 0015/0016 — so the signature is the ABSENCE of the unscoped
  -- lookup, exactly as detect.sql has it.
  if exists (select 1 from pg_proc
              where proname in ('fn_import_students', 'fn_import_opening_balances')
                and pronamespace = 'public'::regnamespace
                and (prosrc ~ 'from public\.students where gr_no'
                  or prosrc ~ 'from public\.students where admission_no')) then
    v_missing := array_append(v_missing, 'bundle 5 (0050-0056): the student importers are still unscoped');
  end if;

  -- Bundle 6 ends at 0067, whose signature is the SIX statement-level count
  -- triggers, counted exactly. A threshold (>= 1) would pass over a partial
  -- application, which on this project is a mistake that has been made four
  -- times; the exact count is the only form that means anything.
  if (select count(*) from pg_trigger t
        join pg_proc pr on pr.oid = t.tgfoid
        join pg_namespace nr on nr.oid = pr.pronamespace
       where not t.tgisinternal and nr.nspname = 'public'
         and pr.proname = 'fn__refresh_counts_touched'
         and t.tgrelid in ('public.students'::regclass,
                           'public.enrollments'::regclass)) <> 6 then
    v_missing := array_append(v_missing, 'bundle 6 (0057-0067): the six student-count triggers are not all present');
  end if;

  if array_length(v_missing, 1) > 0 then
    raise notice '0069: NOT seeding the ledger — this database is incomplete:';
    foreach f in array v_missing loop
      raise notice '0069:   %', f;
    end loop;
    raise notice '0069: run supabase/repair/detect.sql, apply what it names, then re-run this file.';
    return;
  end if;

  foreach f in array v_files loop
    perform public.fn_record_migration(f, 'baseline',
      'adopted by 0069 after proving bundles 1-6 are present');
  end loop;
  select count(*) into v_n from public.schema_migrations;
  raise notice '0069: ledger seeded with % migration(s)', v_n;
end $adopt$;
