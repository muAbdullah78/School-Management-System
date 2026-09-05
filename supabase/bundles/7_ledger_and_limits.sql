-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0068_limit_notice_timing.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0068 — The software told a school it had outgrown its plan the same afternoon
--
-- This is a regression I introduced in 0067 and it is the school-facing half of
-- it, so it goes in on its own rather than waiting for a phase of work.
--
-- WHAT 0067 CHANGED
--
-- Before 0067, subscriptions.student_count only moved when a human pressed
-- "Refresh counts" in the operator console. So the school's own licence banner
-- said "you have N students, above the M your plan covers" whenever the
-- operator happened to have clicked recently — which was rarely, and by then
-- the renewal was usually the reason they had clicked.
--
-- 0067 put statement-level triggers on students and enrollments. That was
-- right: a school on Starter (Rs 9,500) that had quietly grown to 420 pupils
-- was Rs 25,500/year of revenue nobody could see. But it also means the count
-- now moves the instant a child is admitted.
--
-- And LicenceBanner.tsx shows fn_my_licence's `limit_notice` to the owner and
-- principal. So after 0067:
--
--   A principal admits the 101st child in October. Before the admission form
--   has closed, a banner appears telling them they have outgrown the plan they
--   paid for in April.
--
-- That does not read as a helpful notice. It reads as a meter running, on the
-- one screen where the school is earning money, at the moment it is earning it.
-- The comment in 0026 already says admission must never be where we apply
-- pressure — "putting a locked door there would make us the reason a parent
-- walked out". A banner is a softer door but it is a door.
--
-- WHAT THIS CHANGES
--
-- Split what the OPERATOR sees from what the SCHOOL sees. They need different
-- timing, not different truth:
--
--   * The operator keeps everything, immediately. fn_platform_schools still
--     returns limit_state, needs_upgrade and suggested_plan the moment the count
--     crosses, and over_limit_flagged_at still records since when. Catching
--     growth early is the entire point of 0067 and none of it is touched.
--
--   * The school is told when the renewal conversation is actually live —
--     inside 30 days of expiry, or already in grace / locked / cancelled. Then
--     the number is a fact about a decision being made this week rather than an
--     accusation about one made in April.
--
-- Two further points, both deliberate:
--
--   * The 'within_margin' notice is now never shown to the school at all. Its
--     own text was "You are still inside the allowance — nothing to do today."
--     A banner whose content is "nothing to do" is noise, and noise is how a
--     banner that will one day matter gets ignored. The operator still sees the
--     state.
--
--   * Nothing is being hidden that would otherwise explain a failure. The
--     student limit is advisory in this schema — 0026 blocks no INSERT on
--     students at any count, and 0068 does not change that. There is no case
--     where a school hits a refused Save and needs this banner to understand
--     why. If a hard limit is ever added, this rule must be revisited, and the
--     test below is where that will show up.
--
-- limit_state stays truthful in every response. Only limit_notice — which
-- exists solely to be rendered to the school — is gated. So anything that reads
-- the state programmatically is unaffected.
--
-- Re-runnable.
-- =============================================================================

create or replace function public.fn_my_licence()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_sub    record;
  v_plan   record;
  v_status public.subscription_status;
  v_margin integer;
  v_state  text;
  v_expiry date;
  v_days   integer;
  v_tell   boolean;
begin
  if v_school is null then
    return jsonb_build_object('ok', false, 'reason', 'no_school');
  end if;

  select * into v_sub from public.subscriptions where school_id = v_school;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_subscription');
  end if;

  select * into v_plan from public.plans where code = v_sub.plan_code;
  v_status := public.fn_effective_status(v_school);
  v_margin := public.plan_margin_limit(v_plan.student_limit);

  -- Days remaining against whichever clock is running.
  v_expiry := case
    when v_status = 'trialing' then v_sub.trial_ends_on
    when v_status = 'active'   then v_sub.period_end
    when v_status = 'grace'    then v_sub.period_end + public.grace_days()
    else null end;
  v_days := case when v_expiry is null then null else (v_expiry - current_date) end;

  v_state := case
    when v_plan.student_limit is null then 'ok'          -- custom: no limit
    when v_sub.student_count <= v_plan.student_limit then 'ok'
    when v_sub.student_count <= v_margin then 'within_margin'
    else 'over' end;

  -- Is the renewal conversation live? Only then does the school hear about the
  -- limit. grace/locked/cancelled qualify because in those states the school and
  -- the operator are already talking about money; a trial or an active licence
  -- more than 30 days from expiry does not.
  v_tell := v_status in ('grace', 'locked', 'cancelled')
         or (v_days is not null and v_days <= 30);

  return jsonb_build_object(
    'ok',             true,
    'school_id',      v_school,
    'status',         v_status,
    'locked',         v_status = 'locked',
    -- Reading and exporting are never withdrawn, in any state.
    'can_read',       true,
    'can_export',     true,
    'can_operate',    v_status in ('trialing', 'active', 'grace'),
    'plan_code',      v_plan.code,
    'plan_name',      v_plan.name,
    'cycle',          v_sub.cycle,
    'price_monthly',  v_plan.price_monthly,
    'price_yearly',   v_plan.price_yearly,
    'expires_on',     v_expiry,
    'days_left',      v_days,
    'student_count',  v_sub.student_count,
    'student_limit',  v_plan.student_limit,
    'margin_limit',   v_margin,
    -- The truth, always, whatever we choose to say out loud. The operator
    -- console reads its own copy of this from fn_platform_schools and is never
    -- gated.
    'limit_state',    v_state,
    -- Advisory, and only while the renewal is actually being discussed. Null at
    -- every other moment, so no consumer can render it early by accident — the
    -- rule lives here rather than in the banner, because a rule in one screen is
    -- a rule the next screen will not have.
    'limit_notice',   case
      when not v_tell then null
      when v_state = 'over' then
        format('You have %s students, above the %s your plan covers. We will move you to the right plan at your next renewal — nothing stops working.',
               v_sub.student_count, v_plan.student_limit)
      -- 'within_margin' says nothing worth a banner. Its old text was
      -- literally "nothing to do today".
      else null end
  );
end;
$$;

grant execute on function public.fn_my_licence() to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0069_migration_ledger.sql
-- ─────────────────────────────────────────────────────────────────────────
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

-- ─────────────────────────────────────────────────────────────────────────
-- 0070_queue_message_scoping.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0070 — One school could read another school's families, and edit their fees
--
-- TWO cross-tenant defects, both proven on live two-school fixtures before this
-- file was written, both now permanent assertions in
-- supabase/tests/tenant_isolation.sql TEST 6:
--
--   1. fn_queue_message handed over another school's family head name, phone
--      number, child's name and exact outstanding balance. A READ leak.
--
--   2. fn__apply_discount_lines let one school write a discount line onto
--      ANOTHER school's invoice, cutting what that school charges its parent
--      from Rs 5,000 to Rs 4,000. A WRITE, and the worse of the two: the
--      victim school's own fee report shows a discount it never granted.
--
-- Both are the same bug class: a SECURITY DEFINER function — where RLS does not
-- apply — looking up a tenant row by a CALLER-SUPPLIED id with no school filter.
-- The plainest IDOR there is. This codebase already has the answer to it,
-- public.assert_own(table, id), and 33 of the 38 functions taking an id use it.
-- These two did not.
--
-- WHAT HAPPENED — 1. THE READ LEAK
--
-- public.fn_queue_message(p_template_key, p_family_id, ...) is SECURITY DEFINER,
-- so RLS does not apply to anything inside it. It looked up the family like
-- this:
--
--     select * into v_f from public.families where id = p_family_id;
--
-- No school filter. No assert_own. The children's names were gathered the same
-- way, and the balance came from family_outstanding(p_family_id), which sums
-- students by family_id with no school filter of its own.
--
-- So School A's owner passed School B's family id and got this row in School A's
-- OWN message_outbox, which School A can read:
--
--     to_name : Haji Abdul Rehman VICTIMHEAD
--     to_phone: 0300-9998887
--     text    : "Assalam-o-Alaikum Haji Abdul Rehman VICTIMHEAD. A balance of
--                Rs 7,777 is outstanding for Fatima Rehman VICTIMCHILD. ..."
--
-- Another school's family head name, their phone number, their child's name, and
-- their exact debt. Enumerable one uuid at a time, and it lands in a table the
-- attacker is entitled to read, so nothing looks wrong afterwards.
--
-- WHY TWO CI GUARDS BOTH MISSED IT
--
-- Worth stating precisely, because the answer is what the new guard is built on.
--
--   * check-definer-queries.py hunts a DIFFERENT shape on purpose: inequality
--     comparisons between two table columns. That is the fn_rollover bug, where
--     "the next class up" was chosen without a school filter and a school's
--     year-end rollover promoted its children into another school's classroom.
--     Its own header says it is deliberately narrow, because a broad version
--     flagged 65 functions and was wrong about nearly all of them.
--
--   * dashboard.sql assertion 20 checks only that a definer function MENTIONS
--     scoping SOMEWHERE in its body. fn_queue_message mentions
--     current_school_id() twice — for the template lookup and for the school's
--     name — so it passed with flying colours while the families lookup sat
--     wide open. One correct mention exempted three incorrect queries. Exactly
--     the failure that made check-definer-queries.py necessary in the first
--     place, in a shape it does not cover.
--
-- Neither guard looks at the shape above. supabase/check-definer-idor.py now
-- does, judging it per QUERY rather than per function, so the next one fails CI
-- instead of shipping. It also fails if any fn__ helper becomes callable by
-- `authenticated` again, which is how defect 2 was reachable at all.
--
-- Note what is NOT wrong here, since it shows the standard exists:
-- fn_queue_enquiry_message, written later for the same job, scopes every single
-- lookup by `school_id = v_school`. fn_queue_message dates from 0034 and was
-- simply never brought up to the standard the rest of the schema holds to.
-- These were outliers, not a convention.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. fn_queue_message, scoped
--
-- Every lookup now carries the school. Kept as explicit `school_id = v_school`
-- predicates rather than assert_own calls, because this function's contract is
-- to return NULL and let the triggering action succeed — a school that has
-- switched a message off still gets its payment recorded. assert_own RAISES,
-- which would turn "we did not send a WhatsApp" into "your payment failed".
-- The same reason fn_queue_enquiry_message returns null rather than raising.
-- ---------------------------------------------------------------------------
create or replace function public.fn_queue_message(
  p_template_key text,
  p_family_id uuid,
  p_vars jsonb default '{}'::jsonb,
  p_payment_id uuid default null,
  p_student_id uuid default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_t record; v_f record; v_id uuid; v_vars jsonb; v_kids text;
  v_school uuid := public.current_school_id();
begin
  -- No school context, no message. Reached when a service-role job calls this
  -- with no session; queuing a message to a family we cannot attribute is worse
  -- than queuing none.
  if v_school is null then return null; end if;

  select * into v_t from public.message_templates
  where school_id = v_school and template_key = p_template_key;
  -- Not an error. A school that has switched this message off gets no message,
  -- and the action that triggered it still succeeds.
  if not found or not v_t.enabled then return null; end if;

  -- THE LEAK. Was `where id = p_family_id` with no school filter, inside a
  -- SECURITY DEFINER function where RLS does not apply — so any signed-in user
  -- at any school could name any family in the database.
  select * into v_f from public.families
  where id = p_family_id and school_id = v_school;
  if not found then return null; end if;

  -- Same fix, same reason: this is where the victim child's NAME came from.
  select string_agg(s.full_name, ', ' order by s.full_name) into v_kids
  from public.students s
  where s.family_id = p_family_id and s.school_id = v_school
    and s.deleted_at is null;

  -- The two optional foreign keys were written into the outbox row without ever
  -- being checked. enforce_school_id stamps the ROW's school_id, so the row
  -- looked native to the caller's school while pointing at another school's
  -- payment or pupil — and the portal and receipt screens join through them.
  -- Silently dropped rather than raised, for the same reason as above: a
  -- mis-supplied reference must not fail the payment that triggered the message.
  if p_payment_id is not null and not exists (
       select 1 from public.payments where id = p_payment_id and school_id = v_school) then
    p_payment_id := null;
  end if;
  if p_student_id is not null and not exists (
       select 1 from public.students where id = p_student_id and school_id = v_school) then
    p_student_id := null;
  end if;

  v_vars := jsonb_build_object(
    'parent',   coalesce(v_f.head_name, 'Parent'),
    'children', coalesce(v_kids, 'your child'),
    'school',   coalesce((select name from public.school_settings
                          where school_id = v_school), 'the school'),
    'date',     to_char(current_date, 'DD Mon YYYY'),
    'balance',  trim(to_char(public.family_outstanding(p_family_id), 'FM999,999,990'))
  ) || coalesce(p_vars, '{}'::jsonb);

  insert into public.message_outbox (
    template_key, to_name, to_phone, family_id, student_id, payment_id, rendered_text)
  values (
    p_template_key, v_f.head_name,
    coalesce(nullif(btrim(coalesce(v_f.whatsapp, '')), ''), v_f.phone),
    p_family_id, p_student_id, p_payment_id,
    public.fn__render_template(v_t.body, v_vars))
  returning id into v_id;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Take it off the browser's reach entirely
--
-- Defence in depth, and it costs nothing: the app never calls this function.
-- The only RPC in web/src is fn_queue_class_reminders (db.ts:3949); the other
-- two callers are fn__queue_payment_receipt and fn_queue_enquiry_message. All
-- three are SECURITY DEFINER, so they invoke this one as the definer and are
-- unaffected by the revoke.
--
-- check-reachable.sh still counts it as reachable — "another function's body"
-- is one of the things it accepts — so this does not make it look like dead
-- weight.
--
-- The scoping above is the fix. This is the second lock: if a future edit
-- reintroduces an unscoped lookup, a browser session cannot get at it directly.
-- ---------------------------------------------------------------------------
revoke execute on function
  public.fn_queue_message(text, uuid, jsonb, uuid, uuid) from authenticated;
revoke execute on function
  public.fn_queue_message(text, uuid, jsonb, uuid, uuid) from anon;
revoke execute on function
  public.fn_queue_message(text, uuid, jsonb, uuid, uuid) from public;

-- ---------------------------------------------------------------------------
-- 3. family_outstanding: a family's balance is its own school's children
--
-- This is the function that produced the leaked Rs 7,777. It sums
-- student_balance() over `students where family_id = p_family_id` with no school
-- predicate.
--
-- It is SECURITY INVOKER, so when a school user calls it directly RLS filters
-- the students and it is safe. It is only dangerous inside a SECURITY DEFINER
-- caller, where RLS is off — and its callers must therefore be trusted to have
-- scoped the family id. fn_queue_message was not, which is how the figure got
-- out. The other four callers do scope (fn_family_sheet, fn_record_family_payment
-- via assert_own; fn_portal_child_fees via fn__assert_my_child, which checks
-- family AND school; fn_find_family via current_school_id).
--
-- Relying on every future caller remembering is the arrangement that just
-- failed. Joining families and requiring the child to be in the family's own
-- school makes the function correct on its own terms: a pupil in a different
-- school than their family is not a real state, so this changes no legitimate
-- answer and removes the hazard for every caller at once.
-- ---------------------------------------------------------------------------
create or replace function public.family_outstanding(p_family_id uuid)
returns numeric language sql stable set search_path = public as $$
  select coalesce((
    select sum(public.student_balance(s.id))
    from public.students s
    join public.families f on f.id = s.family_id
    where s.family_id = p_family_id
      and s.school_id = f.school_id
  ), 0) - public.family_credit(p_family_id);
$$;

-- ---------------------------------------------------------------------------
-- 4. fn__apply_discount_lines — one school could edit another school's fees
--
-- THE SECOND DEFECT, and the more serious one, because it is a WRITE.
--
-- The function is SECURITY DEFINER, so RLS does not apply, and it did two
-- unscoped things with caller-supplied ids:
--
--     select * from public.discounts d
--     where d.enrollment_id = p_enrollment_id and d.status = 'approved'
--     ...
--     insert into public.invoice_lines(invoice_id, ...) values (p_invoice_id, ...)
--
-- Neither the enrolment nor the invoice was checked against the caller's school.
-- And despite the fn__ prefix, which in this schema means "internal, revoked
-- from the browser", 0021:286 granted EXECUTE on it to `authenticated`.
--
-- Proven: School A's owner called
--     fn__apply_discount_lines(<School B's invoice>, <School B's enrolment>, 5000)
-- and got
--     line: Tuition Fee       | amount=5000 | discount=f | school_id is ATTACKER's: f
--     line: Discount: sibling | amount=1000 | discount=t | school_id is ATTACKER's: t
--     VICTIM invoice net charge now: 4000.00
--
-- So a stranger reduced what another school charges a parent by Rs 1,000, and
-- the line they inserted carries THEIR school_id while sitting on the victim's
-- invoice — which means the victim's fee reports and the attacker's both now
-- disagree with the invoice a parent is holding. Repeatable per invoice.
--
-- Three fixes, because any one of them alone leaves the shape intact:
-- ---------------------------------------------------------------------------
create or replace function public.fn__apply_discount_lines(
  p_invoice_id uuid, p_enrollment_id uuid, p_tuition numeric
) returns void language plpgsql security definer set search_path = public as $$
declare
  v_drec record;
  v_room numeric := p_tuition;
  v_amt  numeric;
  v_school uuid := public.current_school_id();
begin
  -- Raised, not skipped. Silently applying no discounts would over-charge a
  -- parent, which is the failure a school notices last and trusts least. Every
  -- caller (fn_bill_student_month, fn_generate_class_invoices, and the family
  -- and leaving paths) gates on has_role first, so a null school cannot occur on
  -- any real path — this is a tripwire, not a branch.
  if v_school is null then
    raise exception 'No school context for this user' using errcode = '42501';
  end if;

  -- The invoice being written to must be this school's. Was entirely unchecked:
  -- p_invoice_id went straight into the INSERT.
  if not exists (select 1 from public.invoices
                  where id = p_invoice_id and school_id = v_school) then
    raise exception 'Invoice not found in this school' using errcode = '42501';
  end if;

  for v_drec in
    select * from public.discounts d
    where d.enrollment_id = p_enrollment_id
      and d.school_id = v_school            -- was missing: read another school's discounts
      and d.status = 'approved'
    order by d.created_at
  loop
    exit when v_room <= 0;
    v_amt := case when v_drec.is_percent then round(p_tuition * v_drec.amount / 100.0, 2) else v_drec.amount end;
    v_amt := least(v_amt, v_room);
    if v_amt > 0 then
      insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
      values (p_invoice_id, null, 'Discount: ' || v_drec.type, v_amt, true);
      v_room := v_room - v_amt;
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Restore the fn__ convention
--
-- In this schema an fn__ prefix means "internal helper, revoked from the browser
-- roles". Fourteen of the eighteen fn__ functions honour that. Four did not:
--
--   fn__apply_discount_lines       granted at 0021:286 — the write above
--   fn__default_message_templates  returns static template text
--   fn__render_template            {tag} substitution on a string
--   fn__voucher_code               a random code generator
--
-- Only the first was exploitable. The other three are revoked anyway, because a
-- convention with four exceptions is not a convention — it is a thing nobody can
-- rely on when reading the next function. Confirmed first that none of the four
-- is called from web/src or supabase/functions: the single hit for
-- fn__render_template is a COMMENT in db.ts:3848 describing it, not a call.
--
-- Their real callers are all SECURITY DEFINER functions, which invoke them as
-- the definer, so the revoke changes nothing about how the product works.
-- check-reachable.sh still counts them as reachable — "another function's body"
-- is one of the things it accepts — so this does not make them look like dead
-- weight. supabase/check-definer-idor.py now fails CI if any fn__ function is
-- callable by `authenticated` again.
-- ---------------------------------------------------------------------------
revoke all on function public.fn__apply_discount_lines(uuid, uuid, numeric)
  from public, anon, authenticated;
revoke all on function public.fn__default_message_templates()
  from public, anon, authenticated;
revoke all on function public.fn__render_template(text, jsonb)
  from public, anon, authenticated;
revoke all on function public.fn__voucher_code()
  from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0071_function_grants.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0071 — Every function in public was callable by the open internet
--
-- Not a live hole. Hardening, and the reasoning for doing it now matters as much
-- as the change.
--
-- WHAT WAS TRUE
--
-- Postgres grants EXECUTE to PUBLIC on every function it creates, unless told
-- otherwise. Nothing in this schema ever told it otherwise, and 0001:702 grants
-- `usage on schema public to anon`. So all 212 functions in public were callable
-- by `anon` — the role a PostgREST request uses when it carries only the
-- anonymous key, which ships inside the browser bundle and is therefore public.
--
-- Measured, as `anon` with auth.uid() null, which is exactly an unauthenticated
-- request:
--
--   fn_provision_school  -> refused: Not permitted
--   fn_platform_schools  -> refused: Not permitted
--   fn_invite_user       -> refused: Only an owner or principal may invite a user
--   fn_dashboard_summary -> refused: Not permitted
--   fn_global_search     -> refused: Not permitted
--   fn_student_list      -> refused: Not permitted
--   next_counter         -> refused: no school context for this user
--   fn_birthdays         -> refused: Not permitted
--
-- Every one refused. So this was inert: each function gates on has_role(),
-- is_platform_admin() or current_school_id(), and an unauthenticated caller has
-- none of them. The deliberately-locked ones are locked properly too —
-- fn_signup_school, the unguarded twin of fn_provision_school, carries
-- acl={postgres=X/postgres} because 0027:236 revokes it from public, anon and
-- authenticated by name.
--
-- WHY CHANGE IT THEN
--
-- Because the only thing standing between the open internet and 212 functions
-- was that every single one remembered to gate itself. That is the same
-- arrangement that failed twice in 0070 — fn_queue_message forgot a school
-- filter, fn__apply_discount_lines forgot both — and when the next one forgets,
-- the difference between PUBLIC and `authenticated` is the difference between
-- "any of this school's staff" and "anybody on the internet".
--
-- WHY IT IS SAFE: IT IS A NARROWING, PROVABLY
--
-- The obvious version of this change — revoke from PUBLIC and hope — breaks
-- things, and I proved that before writing this: a trial revoke dropped
-- service_role from 212 executable functions to 1, and the signup Edge Function
-- calls fn_signup_school as service_role. School signup would have stopped
-- working on a live database.
--
-- So this reads the CURRENT effective privileges out of the catalogue and makes
-- them explicit BEFORE closing PUBLIC. Since PUBLIC includes both
-- `authenticated` and `anon`, granting each role exactly what it can already do
-- and then revoking PUBLIC is a strict narrowing for every role: nothing that
-- works today stops working, and `anon` — which holds no explicit grant of its
-- own — loses the lot.
--
-- Reading the catalogue rather than listing names is what makes this work in an
-- environment I cannot fully replicate locally. Supabase's own bootstrap grants
-- routines to anon, authenticated and service_role explicitly, which my test
-- harness does not do, so a hand-written list built here would be wrong there.
-- has_function_privilege() answers for whatever posture it is actually run
-- against.
--
-- A CAUTION ABOUT TESTING THIS, learned the hard way an hour ago: while probing,
-- I ran `grant execute on all functions in schema public to public` on a scratch
-- database to simulate the old state, and that silently undid 0027's deliberate
-- revoke — so fn_signup_school then "succeeded as anon" and for a moment looked
-- like a critical hole. It was not; it was my own setup. Broad grants are as
-- dangerous as broad revokes, and a probe that changes privileges is testing
-- itself.
--
-- WHAT STILL PROTECTS THE APP
--
-- check-rpc-contract.sh now asserts that `authenticated` can EXECUTE every RPC
-- web/src/lib/db.ts calls. That check is what makes this change checkable rather
-- than hopeful, and it immediately earned its place: it found that
-- fn_exam_marksheet, called from db.ts:1388 since 0015, had never been granted to
-- `authenticated` at all and worked only through the PUBLIC default. Without the
-- grant below, closing PUBLIC would have broken the exam marksheet screen at
-- runtime for every school.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The one function the app calls that never had a grant of its own
--
-- Found by check-rpc-contract.sh's new executability check, not by reading.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_exam_marksheet(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 1b. And the one the signup Edge Function calls, which has never been granted
--     to anybody
--
-- fn_signup_school carries acl={postgres=X/postgres}: 0027:236 revokes it from
-- public, anon and authenticated by name, deliberately, because it creates a
-- school with no authorisation check of its own. Its comment says "only the
-- service role can reach it".
--
-- Except nothing ever granted it to service_role either. It works in production
-- solely because Supabase's project bootstrap runs
-- `grant all on all routines in schema public to service_role` before any of
-- these migrations, so service_role picked it up by accident. A local database
-- built from supabase/migrations/ alone has never been able to run signup at
-- all — which is why this went unnoticed.
--
-- That is precisely the accidental-default arrangement this migration exists to
-- remove, so it gets stated rather than inherited. Without this line, section 2
-- below would faithfully preserve "service_role cannot call it" on any database
-- that was not blessed by the bootstrap, and school signup would be broken with
-- no obvious cause.
--
-- Guarded on the role existing: the local and CI harnesses do not always create
-- service_role, and a missing role must not fail a migration.
do $signup_grant$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function
      public.fn_signup_school(text, text, text, text, text) to service_role;
  end if;
end $signup_grant$;

-- ---------------------------------------------------------------------------
-- 2. Make the current reality explicit, then close PUBLIC
--
-- Order is load-bearing: capture and grant first, revoke second. Reversed, the
-- capture would find nothing to capture.
-- ---------------------------------------------------------------------------
do $grants$
declare
  r record;
  v_auth integer := 0;
  v_svc  integer := 0;
begin
  -- `authenticated` — the signed-in browser session.
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and has_function_privilege('authenticated', p.oid, 'execute')
  loop
    execute format('grant execute on function %s to authenticated', r.sig);
    v_auth := v_auth + 1;
  end loop;

  -- `service_role` — the Edge Functions. Skipped silently if the role does not
  -- exist: the CI harness and the local one create anon and authenticated but
  -- not always service_role, and a missing role must not fail a migration.
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    for r in
      select p.oid::regprocedure as sig
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and has_function_privilege('service_role', p.oid, 'execute')
    loop
      execute format('grant execute on function %s to service_role', r.sig);
      v_svc := v_svc + 1;
    end loop;
  end if;

  raise notice '0071: made explicit — authenticated on % function(s), service_role on %',
    v_auth, v_svc;
end $grants$;

-- Now the PUBLIC grant, and anon's own if Supabase's bootstrap gave it one.
-- Nothing in this product needs an unauthenticated caller to execute a function:
-- the marketing site is static, signup goes through an Edge Function on the
-- service role, and auth itself does not run through PostgREST.
revoke execute on all functions in schema public from public;
revoke execute on all functions in schema public from anon;

-- WHAT ABOUT FUNCTIONS ADDED LATER?
--
-- Not with ALTER DEFAULT PRIVILEGES. Two spellings were tried and measured, and
-- both are wrong for different reasons:
--
--   alter default privileges IN SCHEMA public revoke execute on functions from public;
--     Silently a no-op. No pg_default_acl row appears, and a function created
--     afterwards still carries =X/postgres. Granting first so a row exists does
--     not help: the row reads {authenticated=X/postgres} and the new function
--     still comes out with PUBLIC, because a schema-scoped entry is merged ON TOP
--     of the built-in default rather than replacing it. `for role postgres` and
--     the `routines` spelling behave identically.
--
--   alter default privileges revoke execute on functions from public;
--     Database-wide, and it DOES work — new functions come out
--     {postgres=X/postgres}. It was in this migration for an hour and then
--     removed, because "database-wide" includes pg_temp: it made pg_temp.ok
--     uncallable by `authenticated` and broke SIXTEEN test suites with
--     "permission denied for function ok". Anything that creates a temporary
--     function would hit the same wall, and the set of such things is not
--     something this migration can enumerate.
--
-- So the rule is enforced where it can be enforced precisely: each migration
-- that adds a function revokes it, and supabase/check-definer-idor.py fails CI
-- if ANY function in public is executable by `anon`. Forgetting is possible;
-- shipping the forgetting is not. That guard exists because this exact thing
-- happened — 0073 and 0074 reopened the surface six times while the
-- schema-qualified ALTER that used to sit here looked like it was handling it,
-- and verify.sql reported "6 functions still open". Which is what that verify
-- row is for.

-- ---------------------------------------------------------------------------
-- 3. Assert the result, in the same transaction that caused it
--
-- Two ways this could go wrong, both silent:
--
--   * anon keeps execute on something — the change did nothing.
--   * an RLS policy helper loses execute — then EVERY policy that calls it
--     errors for a signed-in user, and the app is dead rather than degraded.
--     These six are the ones RLS evaluates as the querying role, so they are
--     the ones whose loss is catastrophic rather than local.
--
-- Raising here rather than leaving it to a test: a half-applied grant change is
-- not a state worth debugging on a live database.
-- ---------------------------------------------------------------------------
do $verify$
declare
  v_anon integer;
  v_bad  text := '';
  f      text;
begin
  select count(*) into v_anon
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_anon > 0 then
    raise exception '0071: anon can still execute % function(s) in public', v_anon;
  end if;

  foreach f in array array[
    'current_school_id', 'is_staff', 'may_view', 'has_role',
    'is_platform_admin', 'my_staff_id', 'my_family_id'
  ] loop
    if exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = f
         and not has_function_privilege('authenticated', p.oid, 'execute'))
    then
      v_bad := v_bad || '  ' || f || chr(10);
    end if;
  end loop;
  if v_bad <> '' then
    raise exception E'0071: a signed-in user lost EXECUTE on an RLS policy helper — every policy calling it would now error:\n%', v_bad;
  end if;

  raise notice '0071: anon can execute nothing in public; every RLS helper still reachable';
end $verify$;

-- ─────────────────────────────────────────────────────────────────────────
-- 0072_name_lookups_scoped.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0072 — Two lookups that searched every school, not this one
--
-- Both found by sweeping for the shape that has already cost this project twice,
-- and both proven on a live two-school fixture before this file was written.
--
-- THE SHAPE
--
-- A SECURITY DEFINER function — where RLS does not apply — resolving a row by
-- NAME or TYPE with no school predicate. It is the fn_rollover bug: "the next
-- class up" was chosen without a school filter and a school's year-end rollover
-- promoted its children into another school's classroom, five runs out of five.
--
-- supabase/check-definer-queries.py exists because of that, and it does not
-- catch these two, because it hunts an inequality between two table columns and
-- these are plain equality on a name. supabase/check-definer-idor.py does not
-- catch them either, because neither lookup keys on a caller-supplied ID — the
-- name arrives as text and the type is a literal. So a third sweep was needed:
-- reads over a tenant table with NO school predicate and NO caller parameter at
-- all, 26 candidates out of 276 statements, of which 24 turned out to be
-- anchored on auth.uid() or on a local already derived from a scoped row.
--
-- DEFECT 1 — fn_admit_student attached another school's fee head
--
--     select id into v_af_head from public.fee_heads
--      where type = 'admission' and active
--      order by sort_order limit 1;
--
-- Whichever school's Admission Fee head sorted first, platform-wide. Then:
--
--     insert into public.invoice_lines(invoice_id, fee_head_id, ...)
--     values (v_af_inv, v_af_head, 'Admission Fee', v_af_amt, false);
--
-- Proven: an admission at School B produced an invoice line whose own school_id
-- was School B's (enforce_school_id stamps that) while fee_head_id pointed at
-- School A's fee head.
--
--     ADMIT -> invoice line uses the VICTIM school's fee head? t
--             (line.school_id says attacker: t)
--
-- Two consequences. Any report joining invoice_lines to fee_heads shows a head
-- the school does not own — or nothing, once RLS is in play — so the admission
-- fee silently disappears from head-wise dues. And the "create one if missing"
-- branch immediately below could never run for a new school, because some other
-- school always had one: the very first admission at every new school was
-- affected, which is every school's first day.
--
-- DEFECT 2 — fn_import_students resolved a class by name across all schools
--
--     select id into v_class from public.classes
--      where active and lower(btrim(name)) = lower(v_cls_in)
--      order by level_order limit 1;
--
-- This one does not leak, and that is worth being precise about: a later
-- assert_own('classes', v_class) catches it. But catching it is the problem.
-- Proven with two schools both having a 'Class 5', the other school's at a lower
-- level_order:
--
--     {"row": 1, "gr_no": "IMP-1", "status": "error",
--      "message": "classes not found in this school"}
--
-- The importing school HAS a Class 5. Its own row was refused, with a message
-- about somebody else's data. Every Pakistani school calls its classes the same
-- things — Class 5, Nursery, Prep, Matric — so at any real number of schools the
-- name collides for nearly all of them, and whichever school registered its
-- ladder first wins the sort. The go-live importer, which is how every new
-- school's roster arrives, would refuse most rows for most schools.
--
-- Not a leak. A go-live blocker that only appears once there is more than one
-- customer, which is exactly the kind of defect a single-tenant test never sees.
--
-- WHY A PROGRAMMATIC REWRITE
--
-- Both functions are long and neither is owned by this migration — fn_admit_student
-- dates from 0004 and has been rewritten by 0019, 0029 and 0036; fn_import_students
-- from 0012 and rewritten by 0056. Retyping either would silently revert whatever
-- the most recent author did. So each block reads the LIVE definition, replaces
-- exactly the one predicate, and asserts the end state — the same technique 0066
-- used on the two billers.
--
-- Re-runnable: each block checks whether the fix is already present first.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. fn_admit_student — the admission fee head must be this school's
-- ---------------------------------------------------------------------------
do $fix_admit$
declare
  src text;
  before_txt text := 'where type = ''admission'' and active';
  after_txt  text := 'where type = ''admission'' and active'
                  || ' and school_id = public.current_school_id()';
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_admit_student' and p.prokind = 'f';
  if src is null then
    raise exception '0072: fn_admit_student not found — apply the earlier migrations first';
  end if;

  if position(after_txt in src) > 0 then
    raise notice '0072: fn_admit_student already scopes the admission fee head';
    return;
  end if;
  if position(before_txt in src) = 0 then
    raise exception '0072: could not find the admission fee head lookup in '
      'fn_admit_student. It has been rewritten; re-check the predicate by hand '
      'rather than letting this migration silently do nothing.';
  end if;

  src := replace(src, before_txt, after_txt);
  execute src;

  -- Assert the END STATE, not the fact that a replace ran. A threshold or a
  -- "did something change" check passes over a partial rewrite, which on this
  -- project is a mistake that has been made four times.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'fn_admit_student'
       and p.prosrc like '%' || after_txt || '%')
  then
    raise exception '0072: the rewrite of fn_admit_student did not take';
  end if;
  raise notice '0072: fn_admit_student now takes the admission fee head from this school only';
end $fix_admit$;

-- ---------------------------------------------------------------------------
-- 2. fn_import_students — a class name means a class in THIS school
--
-- The section lookup below it needs no change: it is already scoped through
-- `class_id = v_class`, so it inherits the fix.
-- ---------------------------------------------------------------------------
do $fix_import$
declare
  src text;
  before_txt text := 'where active and lower(btrim(name)) = lower(v_cls_in)';
  after_txt  text := 'where active and school_id = public.current_school_id()'
                  || ' and lower(btrim(name)) = lower(v_cls_in)';
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_import_students' and p.prokind = 'f';
  if src is null then
    raise exception '0072: fn_import_students not found — apply the earlier migrations first';
  end if;

  if position(after_txt in src) > 0 then
    raise notice '0072: fn_import_students already scopes the class lookup';
    return;
  end if;
  if position(before_txt in src) = 0 then
    raise exception '0072: could not find the class-by-name lookup in '
      'fn_import_students. It has been rewritten; re-check the predicate by hand.';
  end if;

  src := replace(src, before_txt, after_txt);
  execute src;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'fn_import_students'
       and p.prosrc like '%' || after_txt || '%')
  then
    raise exception '0072: the rewrite of fn_import_students did not take';
  end if;
  raise notice '0072: fn_import_students now resolves a class name within this school only';
end $fix_import$;

-- ─────────────────────────────────────────────────────────────────────────
-- 0073_operator_actions.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0073 — Nothing recorded what the operator did to a school
--
-- Phase 1d of docs/SUPER-ADMIN-DESIGN.md, and the foundation the school-detail
-- screen and impersonation both need.
--
-- WHAT WAS MISSING
--
-- The operator can activate a licence, change a plan, discount a price to zero,
-- extend a trial and record a payment. Between them those decide what every
-- school pays. The only trace was the billing rows themselves: an invoice says
-- what was charged, but not who chose the price, or that a trial was extended
-- three times, or that a school was moved between plans and back.
--
-- With one customer that is recoverable from memory. With fifty it is the
-- difference between "why is this school on Starter at Rs 0" having an answer
-- and not having one — and the person asking in six months is the operator.
--
-- WHY A TRIGGER RATHER THAN A CALL IN EACH FUNCTION
--
-- The design doc said "every operator function writes one row". That is the
-- obvious shape and it is the weaker one: it can be forgotten. This project's
-- most common defect by a distance is not wrong logic, it is correct logic that
-- nothing reaches — fn_link_parent with no caller, message_templates.enabled
-- with no writer, fn_reverse_other_income with no caller. A log that a future
-- function forgets to call is worse than no log, because its gaps look like
-- inactivity.
--
-- So capture happens where the WRITE lands, on the tables only the operator
-- writes. A new operator function is logged the day it is written, by nobody
-- remembering anything. fn__log_operator_action stays available for actions that
-- touch no table at all — entering a school to help, refreshing every count —
-- which a trigger cannot see.
--
-- THE ONE HARD PART
--
-- subscriptions is not an operator-only table. 0067 put statement-level triggers
-- on students and enrollments that call fn_refresh_student_count, which UPDATEs
-- subscriptions on every admission at every school. Logging those would bury the
-- five decisions a year that matter under thousands of counter refreshes — and
-- a log nobody can read is a log nobody reads. So the trigger compares old and
-- new and ignores a change confined to the counter columns.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The log
--
-- RLS on with a read policy for the operator and NO write policy, exactly like
-- schema_migrations in 0069 and for the same reason: 0001:704 grants all four
-- verbs on every table in public to `authenticated` and 0025:768 makes that the
-- default for new tables. RLS is the only thing between a clerk and this table,
-- and tenant_isolation.sql check 4d fails CI if it is ever off.
--
-- actor_email is denormalised deliberately. platform_admins rows can be removed,
-- and "who granted this school a free year" must still have an answer afterwards.
-- ---------------------------------------------------------------------------
create table if not exists public.operator_actions (
  id          uuid primary key default gen_random_uuid(),
  at          timestamptz not null default now(),
  -- Null for a service-role or cron action, which is a real and distinguishable
  -- case rather than missing data.
  actor       uuid,
  actor_email text,
  action      text not null,
  -- Null where the action is not about one school (refreshing every count).
  school_id   uuid references public.schools(id),
  detail      jsonb not null default '{}'::jsonb
);

create index if not exists operator_actions_school_at_idx
  on public.operator_actions (school_id, at desc);
create index if not exists operator_actions_at_idx
  on public.operator_actions (at desc);

alter table public.operator_actions enable row level security;

drop policy if exists operator_actions_read on public.operator_actions;
create policy operator_actions_read on public.operator_actions
  for select using (public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- 2. Writing a row
--
-- SECURITY DEFINER so a trigger and an operator function can both reach it
-- without any grant to a browser role, and revoked from those roles so nothing
-- in the app can forge an entry.
-- ---------------------------------------------------------------------------
create or replace function public.fn__log_operator_action(
  p_action text, p_school_id uuid default null, p_detail jsonb default '{}'::jsonb
) returns void language plpgsql security definer set search_path = public as $$
declare v_email text;
begin
  select email into v_email from public.platform_admins where user_id = auth.uid();
  insert into public.operator_actions (actor, actor_email, action, school_id, detail)
  values (auth.uid(), v_email, p_action, p_school_id, coalesce(p_detail, '{}'::jsonb));
end;
$$;

revoke all on function public.fn__log_operator_action(text, uuid, jsonb)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Capture at the write
-- ---------------------------------------------------------------------------
create or replace function public.fn__log_platform_invoice()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.fn__log_operator_action('invoice_raised', new.school_id,
    jsonb_build_object(
      'invoice_id',  new.id,
      'plan_code',   new.plan_code,
      'months',      new.months,
      'amount',      new.amount,
      -- The number that makes a discount visible. 0064 records list_amount so
      -- "given away" can be computed; recording the gap here means the reason
      -- and the amount sit in one row rather than being joined back together.
      'list_amount', new.list_amount,
      'discount',    coalesce(new.list_amount, new.amount) - new.amount,
      'note',        new.note,
      'period',      new.period_start::text || ' to ' || new.period_end::text));
  return null;
end;
$$;

create or replace function public.fn__log_platform_payment()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.fn__log_operator_action('payment_recorded', new.school_id,
    jsonb_build_object(
      'payment_id', new.id,
      'invoice_id', new.invoice_id,
      'amount',     new.amount,
      'paid_on',    new.paid_on::text,
      'method',     new.method,
      'reference',  new.reference,
      'note',       new.note));
  return null;
end;
$$;

-- subscriptions, with the counter noise excluded. See the header.
create or replace function public.fn__log_subscription_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- Everything that is NOT the counter. If none of these moved, this update came
  -- from fn_refresh_student_count — which 0067 fires on every admission at every
  -- school — and is not an operator decision.
  if new.plan_code     is not distinct from old.plan_code
     and new.status        is not distinct from old.status
     and new.cycle         is not distinct from old.cycle
     and new.trial_ends_on is not distinct from old.trial_ends_on
     and new.period_start  is not distinct from old.period_start
     and new.period_end    is not distinct from old.period_end
     and new.grace_ends_on is not distinct from old.grace_ends_on
  then
    return null;
  end if;

  perform public.fn__log_operator_action('licence_changed', new.school_id,
    jsonb_build_object(
      'from', jsonb_strip_nulls(jsonb_build_object(
        'plan_code', old.plan_code, 'status', old.status::text, 'cycle', old.cycle::text,
        'trial_ends_on', old.trial_ends_on::text, 'period_end', old.period_end::text)),
      'to',   jsonb_strip_nulls(jsonb_build_object(
        'plan_code', new.plan_code, 'status', new.status::text, 'cycle', new.cycle::text,
        'trial_ends_on', new.trial_ends_on::text, 'period_end', new.period_end::text))));
  return null;
end;
$$;

create or replace function public.fn__log_school_created()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.fn__log_operator_action('school_created', new.id,
    jsonb_build_object('name', new.name, 'city', new.city,
                       'contact_name', new.contact_name,
                       'contact_phone', new.contact_phone));
  return null;
end;
$$;

revoke all on function public.fn__log_platform_invoice()      from public, anon, authenticated;
revoke all on function public.fn__log_platform_payment()      from public, anon, authenticated;
revoke all on function public.fn__log_subscription_change()   from public, anon, authenticated;
revoke all on function public.fn__log_school_created()        from public, anon, authenticated;

-- Row-level, not statement-level: unlike 0067's counter refresh these are one
-- row per human decision, and the detail IS the row. There is no bulk path.
drop trigger if exists trg_log_platform_invoice on public.platform_invoices;
create trigger trg_log_platform_invoice
  after insert on public.platform_invoices
  for each row execute function public.fn__log_platform_invoice();

drop trigger if exists trg_log_platform_payment on public.platform_payments;
create trigger trg_log_platform_payment
  after insert on public.platform_payments
  for each row execute function public.fn__log_platform_payment();

drop trigger if exists trg_log_subscription_change on public.subscriptions;
create trigger trg_log_subscription_change
  after update on public.subscriptions
  for each row execute function public.fn__log_subscription_change();

drop trigger if exists trg_log_school_created on public.schools;
create trigger trg_log_school_created
  after insert on public.schools
  for each row execute function public.fn__log_school_created();

-- ---------------------------------------------------------------------------
-- 4. Reading it back
--
-- One school's history, newest first, for the detail screen. Scoped by the
-- operator gate rather than by current_school_id(), because this describes the
-- OPERATOR's dealings with a school and a school has no business reading it.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_school_actions(
  p_school_id uuid, p_limit integer default 100
) returns table (
  at timestamptz, actor_email text, action text, detail jsonb
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
    select a.at, a.actor_email, a.action, a.detail
      from public.operator_actions a
     where a.school_id = p_school_id
     order by a.at desc
     limit greatest(1, least(coalesce(p_limit, 100), 500));
end;
$$;

-- Granted to `authenticated` because the operator's browser calls it, and
-- revoked from public and anon because Postgres hands EXECUTE to PUBLIC on every
-- new function and 0001:702 gives anon usage on this schema. 0071 closed that
-- surface for everything existing; a new function has to close its own.
-- check-definer-idor.py fails CI if this line is ever missing.
grant  execute on function public.fn_platform_school_actions(uuid, integer) to authenticated;
revoke execute on function public.fn_platform_school_actions(uuid, integer) from public, anon;

-- ---------------------------------------------------------------------------
-- 5. Backfill what the billing rows already prove
--
-- A history that starts empty makes every existing school look untouched, and
-- the console would say "no operator activity" about a school that was activated
-- and paid months ago. Invoices and payments are the two things already on
-- record, so they are replayed at their real dates.
--
-- Licence changes are NOT backfilled: nothing recorded the before-and-after, and
-- inventing one would put a fabricated row in an audit log. An absence is
-- honest; a guess is not.
-- ---------------------------------------------------------------------------
do $backfill$
declare r record; v_n integer := 0;
begin
  if exists (select 1 from public.operator_actions) then
    raise notice '0073: operator_actions already has rows — not backfilling';
    return;
  end if;

  for r in
    select 'invoice_raised' as action, i.school_id, i.created_at as at, i.created_by,
           jsonb_build_object('invoice_id', i.id, 'plan_code', i.plan_code,
             'months', i.months, 'amount', i.amount, 'list_amount', i.list_amount,
             'discount', coalesce(i.list_amount, i.amount) - i.amount,
             'note', i.note, 'backfilled', true) as detail
      from public.platform_invoices i
    union all
    select 'payment_recorded', p.school_id, p.created_at, p.created_by,
           jsonb_build_object('payment_id', p.id, 'invoice_id', p.invoice_id,
             'amount', p.amount, 'paid_on', p.paid_on::text, 'method', p.method,
             'reference', p.reference, 'backfilled', true)
      from public.platform_payments p
    order by at
  loop
    insert into public.operator_actions (at, actor, actor_email, action, school_id, detail)
    values (r.at, r.created_by,
            (select email from public.platform_admins where user_id = r.created_by),
            r.action, r.school_id, r.detail);
    v_n := v_n + 1;
  end loop;
  raise notice '0073: backfilled % action(s) from the billing rows', v_n;
end $backfill$;

-- ─────────────────────────────────────────────────────────────────────────
-- 0074_operator_support_sessions.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0074 — The operator could not see what a school was seeing
--
-- Phase 2b of docs/SUPER-ADMIN-DESIGN.md. When a principal phones and says "the
-- fee will not save", there was no way to look. This adds read-only support
-- access into any school, with every visit recorded and the record shown to the
-- school itself.
--
-- THE OWNER CHOSE FULL PERMANENT READ, over my recommendation of consented,
-- time-boxed access. That decision is built here as chosen: no consent step, no
-- approval, any school at any time. §2.1 of the design doc carries the argument
-- they overrode — the risk is commercial rather than legal, and it lands in the
-- sales meeting — and the one mitigation that costs nothing is the school-facing
-- visit log in section 6, which restricts the operator not at all and turns the
-- access into something to volunteer rather than hope is not asked about.
--
-- HOW IT WORKS, AND A CORRECTION TO THE DESIGN DOC
--
-- The doc claimed overriding current_school_id() was "the whole trick — ONE
-- function grants reach where 40 new policies would have been needed". That is
-- wrong, and measuring the policy census is what showed it. Every read policy on
-- a tenant table has one of two shapes:
--
--     school_id = current_school_id() AND is_staff()          -- 25 tables
--     school_id = current_school_id() AND may_view(…roles…)   -- 20 tables
--
-- and is_staff(), may_view() and has_role() all read public.profiles by
-- auth.uid(). An operator has NO profiles row in the target school, so all three
-- return false and the override alone would have shown them an empty console.
--
-- So three functions change, not one:
--
--     current_school_id()  falls back to the active session's school
--     is_staff()           or is_operator_session()
--     may_view(…)          or is_operator_session()
--     has_role(…)          UNTOUCHED  <-- this is the entire write refusal
--
-- That last line is the good news and it fell out of the census rather than
-- being designed: ALL 43 WRITE POLICIES gate on has_role(). Not one relies on
-- current_school_id() alone. So leaving has_role() alone refuses every operator
-- write through RLS with no new code, no new trigger, and nothing to forget.
--
-- The SECURITY DEFINER write path is covered too, and was already: 0059 built
-- the `readonly` observer on exactly this split, and check-readonly-writes.py
-- fails CI if any write policy or any VOLATILE function so much as mentions
-- may_view or readonly. That guard's pattern now includes is_operator_session,
-- so the operator inherits a boundary that already has a suite defending it.
-- Impersonation is therefore not a new security boundary — it is the observer
-- role, pointed at a school the operator has no profile in.
--
-- WHY A TABLE AND NOT A SESSION VARIABLE
--
-- The obvious implementation is set_config('app.operator_school', …). It is
-- unsafe here. Supabase pools connections through pgbouncer, so a session-level
-- GUC can outlive the request that set it and be read by whoever gets that
-- connection next — a cross-tenant leak with no attacker involved. A
-- transaction-local GUC is safe but cannot survive between the separate requests
-- a browser makes. So the active session is a row, which is also the only form
-- that can be audited.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The sessions
--
-- RLS on, and TWO read policies, which is deliberate: the operator sees every
-- visit, and a school sees the visits to itself. The second is the point of
-- section 6 and it must not be reachable through anything the operator controls.
--
-- No write policy at all. Rows arrive only through fn_operator_enter, which
-- checks is_platform_admin() — so a school user cannot manufacture a session
-- and read another school, which would be the catastrophic failure of this
-- design.
-- ---------------------------------------------------------------------------
create table if not exists public.operator_sessions (
  id         uuid primary key default gen_random_uuid(),
  admin_id   uuid not null,
  school_id  uuid not null references public.schools(id),
  -- Required, and free text. A log with no reason is a log nobody can use,
  -- including the operator reading their own six months later.
  reason     text not null,
  started_at timestamptz not null default now(),
  expires_at timestamptz not null,
  ended_at   timestamptz,
  constraint operator_sessions_reason_chk check (btrim(reason) <> ''),
  constraint operator_sessions_window_chk check (expires_at > started_at)
);

-- The index current_school_id() and is_operator_session() hit on every call.
-- Partial on the open sessions, which is the only set either one looks at.
create index if not exists operator_sessions_open_idx
  on public.operator_sessions (admin_id) where ended_at is null;
create index if not exists operator_sessions_school_idx
  on public.operator_sessions (school_id, started_at desc);

alter table public.operator_sessions enable row level security;

drop policy if exists operator_sessions_read_operator on public.operator_sessions;
create policy operator_sessions_read_operator on public.operator_sessions
  for select using (public.is_platform_admin());

-- The school's own view. Leadership only: a clerk can do nothing about it, and
-- "the software company looked at your records" is a governance fact for whoever
-- signed the contract.
--
-- has_role, NOT may_view — and that is not an oversight. may_view is true during
-- an operator session, so using it here would be circular in a confusing way;
-- more importantly this list is about accountability to the school, and the
-- readonly observer role has no business in it. Same category as
-- fn_pending_invites, which 0065 put on has_role for the same reason.
drop policy if exists operator_sessions_read_school on public.operator_sessions;
create policy operator_sessions_read_school on public.operator_sessions
  for select using (
    school_id = public.current_school_id()
    and public.has_role('owner', 'principal')
  );

-- ---------------------------------------------------------------------------
-- 2. Is there an active support session?
--
-- ONE indexed probe. The platform_admins join is not belt-and-braces: an admin
-- removed from platform_admins with a session still open would otherwise keep
-- their reach until it expired, and revoking access has to be immediate.
--
-- STABLE, and it must stay STABLE. check-readonly-writes.py asserts that of
-- may_view for the same reason: a VOLATILE predicate can be called from a write
-- path without the guard noticing.
-- ---------------------------------------------------------------------------
create or replace function public.is_operator_session()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1
      from public.operator_sessions os
      join public.platform_admins pa on pa.user_id = os.admin_id
     where os.admin_id = auth.uid()
       and os.ended_at is null
       and os.expires_at > now()
  );
$$;

grant  execute on function public.is_operator_session() to authenticated;
revoke execute on function public.is_operator_session() from public, anon;

-- ---------------------------------------------------------------------------
-- 3. current_school_id() learns about support sessions
--
-- plpgsql rather than SQL, for a reason that is about cost. This function is
-- called from 93 RLS policies and 109 other functions; it is the hottest thing
-- in the schema. Written as
--
--     select coalesce((select … from profiles …), (select … from operator_sessions …))
--
-- Postgres may evaluate BOTH subqueries, so every school user would pay an extra
-- index probe on a table that concerns only the operator. plpgsql guarantees the
-- short circuit: a school user has a profiles row, returns on the first
-- statement, and never touches operator_sessions at all.
--
-- Nothing is lost by leaving SQL behind: the function is SECURITY DEFINER, and
-- Postgres does not inline those, so it was already a real call in every plan.
-- ---------------------------------------------------------------------------
create or replace function public.current_school_id()
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  select school_id into v from public.profiles where id = auth.uid() and active;
  if v is not null then
    return v;
  end if;

  -- No profile: either nobody, or an operator who has entered a school.
  select os.school_id into v
    from public.operator_sessions os
    join public.platform_admins pa on pa.user_id = os.admin_id
   where os.admin_id = auth.uid()
     and os.ended_at is null
     and os.expires_at > now()
   order by os.started_at desc
   limit 1;
  return v;
end;
$$;

grant execute on function public.current_school_id() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. The two READ predicates, and only those
--
-- is_staff() carries 25 read policies, may_view() carries 20. has_role() carries
-- all 43 write policies and is deliberately not touched here — that is what
-- makes every operator write fail without a line of new code.
-- ---------------------------------------------------------------------------
create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
    (select p.active and p.role <> 'parent' from public.profiles p where p.id = auth.uid()),
    false)
  or public.is_operator_session();
$$;

create or replace function public.may_view(variadic p_roles public.user_role[])
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role(variadic p_roles)
      or public.has_role('readonly')
      or public.is_operator_session();
$$;

grant execute on function public.is_staff() to authenticated;
grant execute on function public.may_view(public.user_role[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Entering and leaving
-- ---------------------------------------------------------------------------
create or replace function public.fn_operator_enter(
  p_school_id uuid, p_reason text, p_minutes integer default 60
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_name text;
  v_mins integer := greatest(5, least(coalesce(p_minutes, 60), 480));
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'A reason is required to enter a school';
  end if;

  select name into v_name from public.schools where id = p_school_id;
  if v_name is null then
    raise exception 'School not found';
  end if;

  -- One session at a time. Two open sessions would make current_school_id()
  -- depend on started_at ordering, which is a coin toss dressed up as a rule.
  update public.operator_sessions
     set ended_at = now()
   where admin_id = auth.uid() and ended_at is null;

  insert into public.operator_sessions (admin_id, school_id, reason, expires_at)
  values (auth.uid(), p_school_id, btrim(p_reason),
          now() + make_interval(mins => v_mins))
  returning id into v_id;

  perform public.fn__log_operator_action('school_entered', p_school_id,
    jsonb_build_object('session_id', v_id, 'reason', btrim(p_reason),
                       'minutes', v_mins));

  return jsonb_build_object(
    'session_id', v_id, 'school_id', p_school_id, 'school_name', v_name,
    'expires_at', now() + make_interval(mins => v_mins), 'read_only', true);
end;
$$;

create or replace function public.fn_operator_leave()
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer; r record;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  for r in
    select id, school_id from public.operator_sessions
     where admin_id = auth.uid() and ended_at is null
  loop
    perform public.fn__log_operator_action('school_left', r.school_id,
      jsonb_build_object('session_id', r.id));
  end loop;

  update public.operator_sessions set ended_at = now()
   where admin_id = auth.uid() and ended_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- What the banner reads. Safe for anyone to call: it returns the CALLER's own
-- session or nothing, so it cannot be used to discover that somebody else is in
-- a school.
create or replace function public.fn_operator_current()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(
    (select jsonb_build_object(
       'session_id', os.id, 'school_id', os.school_id,
       'school_name', s.name, 'reason', os.reason,
       'started_at', os.started_at, 'expires_at', os.expires_at,
       'read_only', true)
       from public.operator_sessions os
       join public.schools s on s.id = os.school_id
       join public.platform_admins pa on pa.user_id = os.admin_id
      where os.admin_id = auth.uid() and os.ended_at is null and os.expires_at > now()
      order by os.started_at desc limit 1),
    'null'::jsonb);
$$;

-- Granted to `authenticated` for the operator's browser, and revoked from
-- public and anon because Postgres gives PUBLIC EXECUTE on every new function.
-- 0071 explains why ALTER DEFAULT PRIVILEGES cannot do this for us, and
-- check-definer-idor.py fails CI if any of these lines goes missing.
grant  execute on function public.fn_operator_enter(uuid, text, integer) to authenticated;
grant  execute on function public.fn_operator_leave() to authenticated;
grant  execute on function public.fn_operator_current() to authenticated;
revoke execute on function public.fn_operator_enter(uuid, text, integer) from public, anon;
revoke execute on function public.fn_operator_leave() from public, anon;
revoke execute on function public.fn_operator_current() from public, anon;

-- ---------------------------------------------------------------------------
-- 6. What the SCHOOL sees
--
-- The mitigation §2.1 argues for, and the reason it is worth having: it
-- restricts the operator in no way at all — they still enter any school at any
-- time without asking — it only means they cannot do it invisibly. "If you call
-- us with a problem we can enter your account to see what you are seeing, and
-- every single time we do it is recorded and you can read that record yourself"
-- is a stronger thing to say in a sales meeting than silence.
--
-- Deliberately does NOT name the individual operator. The school needs to know
-- that the vendor looked, when, and why. Which employee of the vendor is not
-- their business and publishing it invites a different argument.
-- ---------------------------------------------------------------------------
create or replace function public.fn_support_visits(p_limit integer default 50)
returns table (
  started_at timestamptz, ended_at timestamptz, reason text, minutes integer
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if v_school is null then
    raise exception 'No school context for this user' using errcode = '42501';
  end if;
  -- has_role, not may_view: see the policy comment in section 1.
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may see support visits'
      using errcode = '42501';
  end if;
  return query
    select os.started_at,
           os.ended_at,
           os.reason,
           (extract(epoch from (coalesce(os.ended_at, least(now(), os.expires_at))
                                - os.started_at)) / 60)::integer
      from public.operator_sessions os
     where os.school_id = v_school
     order by os.started_at desc
     limit greatest(1, least(coalesce(p_limit, 50), 200));
end;
$$;

grant  execute on function public.fn_support_visits(integer) to authenticated;
revoke execute on function public.fn_support_visits(integer) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0075_school_detail.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0075 — You could not open a school
--
-- Phase 2a of docs/SUPER-ADMIN-DESIGN.md. The console listed eight fields per
-- school and that was every fact it held about a customer. There was no way to
-- answer "what is going on at Al Qalam School?"
--
-- THE MOST USEFUL THING HERE IS THE READINESS CHECKLIST
--
-- A school that has paid and never used the software looks identical, in the
-- list, to one that runs on it daily — until it does not renew. And the commonest
-- reason a school stalls is not reluctance, it is being stuck one step in:
-- 0066 found that no school could create a fee head at all, so the Fee Structure
-- grid was an empty list with a Save button and every school was stuck at the
-- same place with no way to say so.
--
-- So readiness is computed, in the order a school actually has to do things, and
-- the first unfinished item is the phone call worth making. A school stuck at
-- "no fee heads" is one conversation away from being a customer for years, and
-- today there is no way to know they are stuck.
--
-- WHERE THE LINE IS ON WHAT THIS EXPOSES
--
-- This function reads tenant tables as the operator, with no support session
-- open, which is a deliberate narrow exception to the rule tenant_isolation.sql
-- TEST 5 defends. So the line has to be stated rather than assumed:
--
--   IT RETURNS       counts, dates, and the school's own staff/login list —
--                    "412 pupils, last payment Tuesday, four logins, the
--                    accountant has never signed in". These are facts about the
--                    CUSTOMER RELATIONSHIP and the operator needs them to run a
--                    business.
--
--   IT NEVER RETURNS a child's name, a guardian, a family, a mark, an individual
--                    payment, or a parent's phone number. Nothing about a person
--                    the school serves.
--
-- For those, open a support visit (0074): read-only, logged, and shown to the
-- school. The distinction is the whole point — "how many pupils" is business
-- information, "which pupils" is the school's own affair, and an operator who
-- wants the second should have to leave a record saying why.
--
-- tenant_isolation.sql asserts both halves of that: TEST 5 that the platform
-- role still reaches no tenant TABLE directly, and TEST 9 that this function's
-- output contains no pupil name even when the school is full of them.
--
-- Re-runnable.
-- =============================================================================

create or replace function public.fn_platform_school_detail(p_school_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school   record;
  v_settings record;
  v_sub      record;
  v_plan     record;
  v_status   public.subscription_status;
  v_expiry   date;
  v_margin   integer;
  v_sess     uuid;
  v_n_classes    integer; v_n_sections integer; v_n_heads integer;
  v_n_priced     integer; v_n_students integer; v_n_staff integer;
  v_n_families   integer; v_n_parents  integer;
  v_billed       boolean; v_last_pay date; v_invoiced numeric; v_paid numeric;
  v_ready jsonb := '[]'::jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  select * into v_school from public.schools where id = p_school_id;
  if not found then
    raise exception 'School not found';
  end if;

  select * into v_settings from public.school_settings where school_id = p_school_id;
  select * into v_sub      from public.subscriptions  where school_id = p_school_id;
  if v_sub.plan_code is not null then
    select * into v_plan from public.plans where code = v_sub.plan_code;
    v_status := public.fn_effective_status(p_school_id);
    v_margin := public.plan_margin_limit(v_plan.student_limit);
    v_expiry := case
      when v_status = 'trialing' then v_sub.trial_ends_on
      when v_status = 'active'   then v_sub.period_end
      when v_status = 'grace'    then v_sub.period_end + public.grace_days()
      else null end;
  end if;

  -- --- the numbers behind the checklist -----------------------------------
  select id into v_sess from public.academic_sessions
   where school_id = p_school_id and is_current limit 1;

  select count(*) into v_n_classes  from public.classes  where school_id = p_school_id and active;
  select count(*) into v_n_sections from public.sections where school_id = p_school_id;
  select count(*) into v_n_heads    from public.fee_heads where school_id = p_school_id and active;

  -- Classes with at least one fee amount on record, not rows in fee_structures:
  -- one head priced for one class is not a priced school, and the operator needs
  -- to see "3 of 11 classes priced" rather than "yes, fees are set".
  select count(distinct class_id) into v_n_priced
    from public.fee_structures where school_id = p_school_id;

  select count(*) into v_n_students from public.students
   where school_id = p_school_id and deleted_at is null and status = 'active';
  select count(*) into v_n_staff from public.staff
   where school_id = p_school_id and deleted_at is null and left_on is null;
  select count(*) into v_n_families from public.families where school_id = p_school_id;
  select count(*) into v_n_parents  from public.profiles
   where school_id = p_school_id and role = 'parent' and active;

  select exists (select 1 from public.invoices
                  where school_id = p_school_id and period_month is not null)
    into v_billed;
  select max(created_at)::date into v_last_pay from public.payments
   where school_id = p_school_id and status = 'verified';

  select coalesce(sum(amount), 0) into v_invoiced from public.platform_invoices
   where school_id = p_school_id;
  select coalesce(sum(amount), 0) into v_paid from public.platform_payments
   where school_id = p_school_id;

  -- --- the checklist, in the order a school has to do it -------------------
  -- Ordered deliberately: you cannot price a class that does not exist, or put
  -- an amount against a fee head that has not been created. The UI shows the
  -- first unfinished row as the next thing to talk to them about.
  v_ready :=
    jsonb_build_array(
      jsonb_build_object('key','session','label','An academic year is set',
        'done', v_sess is not null,
        'detail', case when v_sess is null then 'Settings → Sessions' else '' end),
      jsonb_build_object('key','classes','label','Classes created',
        'done', v_n_classes > 0, 'detail', v_n_classes || ' class(es)'),
      jsonb_build_object('key','sections','label','Sections created',
        'done', v_n_sections > 0, 'detail', v_n_sections || ' section(s)'),
      jsonb_build_object('key','feeheads','label','Fee heads created',
        'done', v_n_heads > 0,
        'detail', case when v_n_heads = 0
                       then 'Nothing to charge for yet — Settings → Fee Heads'
                       else v_n_heads || ' active' end),
      jsonb_build_object('key','prices','label','Fee amounts set per class',
        'done', v_n_priced > 0,
        'detail', v_n_priced || ' of ' || v_n_classes || ' class(es) priced'),
      jsonb_build_object('key','students','label','Students admitted',
        'done', v_n_students > 0, 'detail', v_n_students || ' on roll'),
      jsonb_build_object('key','staff','label','Staff added',
        'done', v_n_staff > 0, 'detail', v_n_staff || ' on the books'),
      jsonb_build_object('key','billed','label','A month has been billed',
        'done', v_billed,
        'detail', case when v_billed then '' else 'Fees → Generate challans' end),
      jsonb_build_object('key','collected','label','A payment has been taken',
        'done', v_last_pay is not null,
        'detail', case when v_last_pay is null then ''
                       else 'last on ' || v_last_pay::text end)
    );

  return jsonb_build_object(
    'school', jsonb_build_object(
      'id', v_school.id, 'name', v_school.name, 'city', v_school.city,
      'contact_name', v_school.contact_name, 'contact_phone', v_school.contact_phone,
      'contact_email', v_school.contact_email, 'notes', v_school.notes,
      'active', v_school.active, 'created_at', v_school.created_at,
      -- From school_settings, which is what the school itself maintains — so a
      -- mismatch with the signup details above is itself informative.
      'display_name', v_settings.name, 'address', v_settings.address,
      'phone', v_settings.phone, 'principal_name', v_settings.principal_name,
      'has_logo', v_settings.logo_path is not null),

    'licence', case when v_sub.plan_code is null then 'null'::jsonb else
      jsonb_build_object(
        'plan_code', v_sub.plan_code, 'plan_name', v_plan.name,
        'status', v_status, 'cycle', v_sub.cycle,
        'expires_on', v_expiry,
        'days_left', case when v_expiry is null then null else v_expiry - current_date end,
        'student_count', v_sub.student_count, 'student_limit', v_plan.student_limit,
        'margin_limit', v_margin,
        'counted_at', v_sub.counted_at,
        'over_limit_since', v_sub.over_limit_flagged_at,
        'limit_state', case
          when v_plan.student_limit is null then 'ok'
          when v_sub.student_count <= v_plan.student_limit then 'ok'
          when v_sub.student_count <= v_margin then 'within_margin'
          else 'over' end,
        'suggested_plan', (select p2.code from public.plans p2
                            where p2.active
                              and (p2.student_limit is null
                                or p2.student_limit >= v_sub.student_count)
                            order by p2.sort_order limit 1)) end,

    'money', jsonb_build_object(
      'invoiced', v_invoiced, 'paid', v_paid, 'outstanding', v_invoiced - v_paid,
      'last_paid_on', (select max(paid_on) from public.platform_payments
                        where school_id = p_school_id),
      'invoice_count', (select count(*) from public.platform_invoices
                         where school_id = p_school_id)),

    -- The school's own logins. NOT the children — see the header.
    --
    -- ever_signed_in is the churn signal that nothing in this product could see
    -- before: a school with one login that has not been used in three weeks is
    -- leaving, and an accountant who was invited and never signed in is a seat
    -- somebody is not using and probably does not know about.
    'people', coalesce((
      select jsonb_agg(jsonb_build_object(
               'name', pr.full_name, 'role', pr.role, 'active', pr.active,
               'added_on', pr.created_at,
               'ever_signed_in', u.last_sign_in_at is not null,
               'last_sign_in', u.last_sign_in_at)
             order by pr.role, pr.full_name)
        from public.profiles pr
        left join auth.users u on u.id = pr.id
       where pr.school_id = p_school_id and pr.role <> 'parent'), '[]'::jsonb),

    'counts', jsonb_build_object(
      'classes', v_n_classes, 'sections', v_n_sections, 'fee_heads', v_n_heads,
      'classes_priced', v_n_priced, 'students', v_n_students, 'staff', v_n_staff,
      'families', v_n_families, 'parents_linked', v_n_parents),

    'readiness', v_ready,

    -- Is anybody actually using it? Dates only, one per module. A school whose
    -- last attendance was in April is not using attendance, whatever the roll
    -- says.
    'activity', jsonb_build_object(
      'last_payment',     (select max(created_at) from public.payments
                            where school_id = p_school_id and status = 'verified'),
      'last_invoice',     (select max(created_at) from public.invoices
                            where school_id = p_school_id),
      'last_attendance',  (select max(attendance_date) from public.attendance_daily
                            where school_id = p_school_id),
      'last_mark',        (select max(created_at) from public.mark_entries
                            where school_id = p_school_id),
      'last_certificate', (select max(issued_on) from public.certificates
                            where school_id = p_school_id),
      'last_till_close',  (select max(closed_at) from public.till_sessions
                            where school_id = p_school_id),
      'last_message',     (select max(created_at) from public.message_outbox
                            where school_id = p_school_id)),

    -- Stated rather than silently absent. "Has a challan been printed" is the
    -- one readiness question this schema cannot answer: printing happens in the
    -- browser and nothing records it. Saying so beats a checklist row that is
    -- quietly always false, which would send the operator chasing a step the
    -- school had already done.
    'not_recorded', jsonb_build_array(
      'whether a challan was ever printed — printing is a browser action and '
      || 'nothing records it')
  );
end;
$$;

grant  execute on function public.fn_platform_school_detail(uuid) to authenticated;
revoke execute on function public.fn_platform_school_detail(uuid) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0076_platform_settings.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0076 — The invoices had no seller on them
--
-- Phase 3 of docs/SUPER-ADMIN-DESIGN.md, first of three.
--
-- 0064 built the books: platform_invoices records what a school was charged and
-- platform_payments what it paid. What it cannot do is produce a DOCUMENT. A
-- Pakistani school's accountant cannot pay against a row in a table. They need
-- a piece of paper with:
--
--   * the seller's registered name, address and NTN — without the NTN the
--     school cannot claim the expense, and cannot file the withholding tax it is
--     obliged by law to deduct from a services invoice
--   * an invoice number that is part of an unbroken series
--   * the amount in words, because that is what a bank counter accepts and what
--     every Pakistani invoice, challan and cheque carries
--   * the bank account to pay into
--
-- None of that exists anywhere in this schema. `fn_platform_ledger` returns
-- "growth · 12 months · 2027-07-26 to 2028-07-25" and an amount. That is a
-- record of a sale, not an invoice.
--
-- WHY A TABLE AND NOT A CONSTANT
--
-- The obvious shortcut is to hardcode the business name, NTN and bank details
-- in a migration, or to paste them into an environment variable. Both are
-- wrong for the same reason: they make the operator ask a developer to change
-- a bank account. An NTN is issued once, but a bank account changes, an address
-- changes, and a business that grows registers for sales tax and acquires an
-- STRN it did not have. Those are Settings, and Settings belong in a row a
-- screen can edit.
--
-- It also keeps the values OUT of the repository. A registered address and a
-- bank account number in a public git history is a thing you cannot take back.
--
-- SINGLE ROW, ENFORCED
--
--   id boolean primary key default true check (id)
--
-- One row, always, and it is impossible to insert a second: the only value the
-- check permits is `true`, and `true` is already taken by the primary key. This
-- is better than a `limit 1` convention, which is a rule that lives in whoever
-- remembers it.
--
-- WHAT IS DELIBERATELY NOT HERE
--
--   * No tax RATES beyond a default withholding percentage. Sales tax on
--     services in Pakistan is provincial (PRA/SRB/KPRA/BRA), the rate depends
--     on the province AND on whether the buyer is a withholding agent, and this
--     software is not going to guess that correctly. 0077 puts a tax line on
--     the invoice that the operator fills in per invoice, with the default as a
--     starting point. A wrong rate printed confidently is worse than a blank.
--
--   * No payment gateway credentials. `gateway_enabled` is a switch and
--     `gateway_provider` a name; keys belong in the Edge Function's secrets,
--     never in a table the browser can reach through a definer function.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The row
-- ---------------------------------------------------------------------------
create table if not exists public.platform_settings (
  id boolean primary key default true check (id),

  -- --- who is selling -----------------------------------------------------
  -- Defaults are empty rather than plausible. A placeholder like
  -- "Your Company (Pvt) Ltd" reads as filled in, and would be printed on a real
  -- invoice by somebody who assumed it was already configured. Blank is loud.
  business_name text not null default '',
  ntn           text,
  strn          text,
  address       text,
  city          text,
  phone         text,
  email         text,
  website       text,

  -- --- where the money goes ----------------------------------------------
  bank_name     text,
  bank_title    text,   -- the account TITLE, which is what a bank teller checks
  bank_account  text,
  bank_iban     text,

  -- --- document series ----------------------------------------------------
  -- Two series, because a credit note is not an invoice and must not consume an
  -- invoice number: an unbroken invoice series is what a tax audit looks at.
  invoice_prefix text not null default 'INV'
    check (invoice_prefix ~ '^[A-Z0-9-]{1,8}$'),
  credit_prefix  text not null default 'CN'
    check (credit_prefix ~ '^[A-Z0-9-]{1,8}$'),
  payment_terms_days integer not null default 14
    check (payment_terms_days between 0 and 180),

  -- The rate a school is expected to withhold, as a STARTING POINT for the
  -- operator to accept or change per invoice. Not applied automatically: see
  -- 0077 on why silence beats a confident guess.
  default_withholding_pct numeric(5,2) not null default 0
    check (default_withholding_pct >= 0 and default_withholding_pct <= 100),

  invoice_footer text,

  -- --- the gateway switch -------------------------------------------------
  -- Bank transfer now, a gateway later, and the switch decides which one the
  -- school-facing screen offers. Off means the school is shown bank details and
  -- an "I have paid" form; on means it is additionally shown a pay button.
  -- No credentials here — see the header.
  gateway_enabled  boolean not null default false,
  gateway_provider text
    check (gateway_provider is null
           or gateway_provider in ('jazzcash', 'easypaisa', 'stripe', 'other')),

  updated_at timestamptz not null default now(),
  updated_by uuid
);

-- The row itself. `on conflict do nothing` so re-running changes nothing.
insert into public.platform_settings (id) values (true) on conflict (id) do nothing;

alter table public.platform_settings enable row level security;

-- Operator-readable, and NOT writable through RLS: every field is validated in
-- fn_platform_save_settings, which is the same argument 0064 made for invoices.
-- A direct UPDATE could set invoice_prefix to something the document series
-- cannot represent, and the check constraint is the only thing that would catch
-- it — constraints are a floor, not a policy.
--
-- A school user must not read this table. The bank details a school needs to
-- pay reach it through fn_my_billing (0078), which returns the four bank fields
-- and nothing else — not the gateway provider, not the withholding default, not
-- the document prefixes.
drop policy if exists platform_settings_select on public.platform_settings;
create policy platform_settings_select on public.platform_settings
  for select to authenticated using (public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- 2. Amount in words
--
-- Every Pakistani invoice, cheque and fee challan carries the amount in words,
-- and it is not decoration: it is the version a bank teller and a court both
-- treat as authoritative when the figures disagree.
--
-- SOUTH ASIAN GROUPING, NOT WESTERN. 1,250,000 is "Twelve Lakh Fifty Thousand",
-- not "One Million Two Hundred Fifty Thousand". Getting this wrong is the tell
-- that a document was produced by software written for somewhere else.
--
-- Immutable and pure — no table reads, so it is safe to call from anywhere and
-- the planner can fold it.
-- ---------------------------------------------------------------------------
create or replace function public.fn__words_below_100(n integer)
returns text language sql immutable as $$
  select case
    when n is null or n <= 0 then ''
    when n < 20 then (array['Zero','One','Two','Three','Four','Five','Six','Seven',
                            'Eight','Nine','Ten','Eleven','Twelve','Thirteen',
                            'Fourteen','Fifteen','Sixteen','Seventeen','Eighteen',
                            'Nineteen'])[n + 1]
    else btrim(
      (array['','','Twenty','Thirty','Forty','Fifty','Sixty','Seventy','Eighty',
             'Ninety'])[(n / 10) + 1]
      || case when n % 10 = 0 then ''
              else ' ' || (array['Zero','One','Two','Three','Four','Five','Six',
                                 'Seven','Eight','Nine'])[(n % 10) + 1] end)
  end;
$$;

create or replace function public.fn__words_below_1000(n integer)
returns text language sql immutable as $$
  select case
    when n is null or n <= 0 then ''
    when n < 100 then public.fn__words_below_100(n)
    else btrim(public.fn__words_below_100(n / 100) || ' Hundred'
      || case when n % 100 = 0 then ''
              else ' ' || public.fn__words_below_100(n % 100) end)
  end;
$$;

create or replace function public.fn__amount_in_words(p_amount numeric)
returns text language plpgsql immutable as $$
declare
  v_amt   numeric;
  v_rup   bigint;
  v_paisa integer;
  v_rem   bigint;
  v_parts text[] := '{}';
  v_words text;
  v_neg   boolean;
begin
  if p_amount is null then
    return '';
  end if;

  v_neg := p_amount < 0;
  v_amt := round(abs(p_amount), 2);

  v_rup   := floor(v_amt)::bigint;
  -- Computed from the already-rounded value, so 0.005 cannot produce 100 paisa
  -- here. Guarded anyway: a carry that is impossible today becomes possible the
  -- day somebody changes the rounding above, and the failure would be the words
  -- "Zero Rupees and Hundred Paisa" on a customer's invoice.
  v_paisa := round((v_amt - floor(v_amt)) * 100)::integer;
  if v_paisa >= 100 then
    v_rup   := v_rup + 1;
    v_paisa := v_paisa - 100;
  end if;

  -- Crore (10^7) can exceed 99 — Rs 100 crore is a number a business can reach —
  -- so that group gets the below-1000 form. Lakh, thousand and hundred are
  -- bounded at 99, 99 and 9 by construction.
  v_rem := v_rup;
  if v_rem / 10000000 > 0 then
    v_parts := array_append(v_parts,
      public.fn__words_below_1000((v_rem / 10000000)::integer) || ' Crore');
    v_rem := v_rem % 10000000;
  end if;
  if v_rem / 100000 > 0 then
    v_parts := array_append(v_parts,
      public.fn__words_below_100((v_rem / 100000)::integer) || ' Lakh');
    v_rem := v_rem % 100000;
  end if;
  if v_rem / 1000 > 0 then
    v_parts := array_append(v_parts,
      public.fn__words_below_100((v_rem / 1000)::integer) || ' Thousand');
    v_rem := v_rem % 1000;
  end if;
  if v_rem > 0 then
    v_parts := array_append(v_parts, public.fn__words_below_1000(v_rem::integer));
  end if;

  v_words := case when array_length(v_parts, 1) is null
                  then 'Zero' else array_to_string(v_parts, ' ') end;

  return btrim(
    case when v_neg then 'Minus ' else '' end
    || 'Rupees ' || v_words
    || case when v_paisa > 0
            then ' and ' || public.fn__words_below_100(v_paisa) || ' Paisa'
            else '' end
    || ' Only');
end;
$$;

-- Internal helpers. Revoked from every browser role: nothing outside a definer
-- function has business calling them, and check-definer-idor.py fails CI if an
-- fn__* is left callable.
revoke all on function public.fn__words_below_100(integer)  from public, anon, authenticated;
revoke all on function public.fn__words_below_1000(integer) from public, anon, authenticated;
revoke all on function public.fn__amount_in_words(numeric)  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Reading and writing the settings
--
-- `missing` is the part that matters. An invoice printed with a blank NTN is
-- useless to the school receiving it and they will not tell us — they will just
-- fail to claim it, or phone about it in three weeks. So the read reports which
-- required fields are empty, and the screen shows that as a warning before the
-- first invoice is ever printed rather than after.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_settings()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v record; v_missing text[] := '{}';
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  select * into v from public.platform_settings where id;
  if not found then
    -- Cannot happen: the insert above is part of this migration. Reported rather
    -- than returning null, because a null here would render as an empty form
    -- that silently saves nothing.
    raise exception 'Platform settings row is missing';
  end if;

  if btrim(coalesce(v.business_name, '')) = '' then
    v_missing := array_append(v_missing, 'business_name');
  end if;
  if btrim(coalesce(v.ntn, '')) = '' then
    v_missing := array_append(v_missing, 'ntn');
  end if;
  if btrim(coalesce(v.address, '')) = '' then
    v_missing := array_append(v_missing, 'address');
  end if;
  -- A school cannot pay a bank transfer without an account number, and the
  -- title is what the teller matches. IBAN is optional: it is the same account.
  if btrim(coalesce(v.bank_account, '')) = '' then
    v_missing := array_append(v_missing, 'bank_account');
  end if;
  if btrim(coalesce(v.bank_title, '')) = '' then
    v_missing := array_append(v_missing, 'bank_title');
  end if;
  if btrim(coalesce(v.bank_name, '')) = '' then
    v_missing := array_append(v_missing, 'bank_name');
  end if;

  return jsonb_build_object(
    'business_name', v.business_name, 'ntn', v.ntn, 'strn', v.strn,
    'address', v.address, 'city', v.city, 'phone', v.phone, 'email', v.email,
    'website', v.website,
    'bank_name', v.bank_name, 'bank_title', v.bank_title,
    'bank_account', v.bank_account, 'bank_iban', v.bank_iban,
    'invoice_prefix', v.invoice_prefix, 'credit_prefix', v.credit_prefix,
    'payment_terms_days', v.payment_terms_days,
    'default_withholding_pct', v.default_withholding_pct,
    'invoice_footer', v.invoice_footer,
    'gateway_enabled', v.gateway_enabled, 'gateway_provider', v.gateway_provider,
    'updated_at', v.updated_at,
    -- Empty array means ready to invoice. The screen renders this list, and
    -- 0077's invoice document repeats it so a blank NTN is visible at the moment
    -- somebody is about to print.
    'missing', to_jsonb(v_missing));
end;
$$;

-- Takes a jsonb patch rather than 20 parameters. Only the keys PRESENT are
-- changed, so the settings screen can save one field without having to send —
-- and therefore risk overwriting — the other nineteen.
create or replace function public.fn_platform_save_settings(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_known text[] := array[
    'business_name','ntn','strn','address','city','phone','email','website',
    'bank_name','bank_title','bank_account','bank_iban',
    'invoice_prefix','credit_prefix','payment_terms_days',
    'default_withholding_pct','invoice_footer',
    'gateway_enabled','gateway_provider'];
  k text;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'Give an object of settings to change';
  end if;

  -- A key this function does not know is a mistake somewhere — a typo in the
  -- client, or a field renamed on one side only. Ignoring it silently means the
  -- screen shows a saved value that was never stored.
  for k in select x from jsonb_object_keys(p) x loop
    if not (k = any(v_known)) then
      raise exception 'Unknown setting: %', k;
    end if;
  end loop;

  update public.platform_settings s set
    business_name = case when p ? 'business_name'
      then btrim(coalesce(p->>'business_name', '')) else s.business_name end,
    ntn      = case when p ? 'ntn'      then nullif(btrim(coalesce(p->>'ntn', '')), '')      else s.ntn end,
    strn     = case when p ? 'strn'     then nullif(btrim(coalesce(p->>'strn', '')), '')     else s.strn end,
    address  = case when p ? 'address'  then nullif(btrim(coalesce(p->>'address', '')), '')  else s.address end,
    city     = case when p ? 'city'     then nullif(btrim(coalesce(p->>'city', '')), '')     else s.city end,
    phone    = case when p ? 'phone'    then nullif(btrim(coalesce(p->>'phone', '')), '')    else s.phone end,
    email    = case when p ? 'email'    then nullif(btrim(coalesce(p->>'email', '')), '')    else s.email end,
    website  = case when p ? 'website'  then nullif(btrim(coalesce(p->>'website', '')), '')  else s.website end,
    bank_name    = case when p ? 'bank_name'    then nullif(btrim(coalesce(p->>'bank_name', '')), '')    else s.bank_name end,
    bank_title   = case when p ? 'bank_title'   then nullif(btrim(coalesce(p->>'bank_title', '')), '')   else s.bank_title end,
    bank_account = case when p ? 'bank_account' then nullif(btrim(coalesce(p->>'bank_account', '')), '') else s.bank_account end,
    bank_iban    = case when p ? 'bank_iban'    then nullif(btrim(upper(coalesce(p->>'bank_iban', ''))), '') else s.bank_iban end,
    -- Upper-cased rather than rejected for case: an operator typing "inv" means
    -- INV, and refusing that is a form to fight rather than a form to fill.
    invoice_prefix = case when p ? 'invoice_prefix'
      then upper(btrim(coalesce(p->>'invoice_prefix', ''))) else s.invoice_prefix end,
    credit_prefix  = case when p ? 'credit_prefix'
      then upper(btrim(coalesce(p->>'credit_prefix', ''))) else s.credit_prefix end,
    payment_terms_days = case when p ? 'payment_terms_days'
      then (p->>'payment_terms_days')::integer else s.payment_terms_days end,
    default_withholding_pct = case when p ? 'default_withholding_pct'
      then (p->>'default_withholding_pct')::numeric else s.default_withholding_pct end,
    invoice_footer = case when p ? 'invoice_footer'
      then nullif(btrim(coalesce(p->>'invoice_footer', '')), '') else s.invoice_footer end,
    gateway_enabled = case when p ? 'gateway_enabled'
      then (p->>'gateway_enabled')::boolean else s.gateway_enabled end,
    gateway_provider = case when p ? 'gateway_provider'
      then nullif(btrim(lower(coalesce(p->>'gateway_provider', ''))), '') else s.gateway_provider end,
    updated_at = now(),
    updated_by = auth.uid()
  where s.id;

  -- Switching the gateway on with no provider named would give the school a pay
  -- button wired to nothing. Checked after the update so it sees the resulting
  -- state rather than the patch, which may set only one of the two.
  if exists (select 1 from public.platform_settings
              where id and gateway_enabled and gateway_provider is null) then
    raise exception 'Name the gateway provider before switching online payment on';
  end if;

  -- The keys that changed, not the values: a bank account number does not belong
  -- in an activity feed, and "who changed the bank details and when" is the
  -- question this answers. school_id null — this is not about one school.
  perform public.fn__log_operator_action('settings_changed', null,
    jsonb_build_object('fields', (select coalesce(jsonb_agg(x), '[]'::jsonb)
                                    from jsonb_object_keys(p) x)));

  return public.fn_platform_settings();
end;
$$;

grant  execute on function public.fn_platform_settings()            to authenticated;
revoke execute on function public.fn_platform_settings()          from public, anon;
grant  execute on function public.fn_platform_save_settings(jsonb)  to authenticated;
revoke execute on function public.fn_platform_save_settings(jsonb) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0077_invoice_documents.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0077 — A charge that was wrong could only be lived with
--
-- Phase 3 of docs/SUPER-ADMIN-DESIGN.md, second of three. 0076 gave the invoices
-- a seller; this gives them a NUMBER, a TAX LINE, and the two ways a real
-- business corrects a mistake.
--
-- FOUR DEFECTS, each reproduced on a real database before it was fixed.
--
-- 1. NO DOCUMENT NUMBER
--
--    platform_invoices has a uuid primary key and nothing else. A school's
--    accountant asks "which invoice is this payment for?" and the only answer
--    the software can give is 3f2504e0-4f89-11d3-9a0c-0305e82c3301. So the
--    operator invents numbers in a notebook, and the notebook becomes the real
--    system of record.
--
--    An unbroken series also matters legally. This assigns one in a trigger, so
--    EVERY insert path gets a number including 0064's fn_activate_subscription,
--    which is not touched.
--
-- 2. AN INVOICE RAISED IN ERROR IS PERMANENT
--
--    Wrong school, wrong plan, wrong number of months, raised twice by a double
--    click. There is no update path (0064 deliberately made these tables
--    read-only through RLS) and no delete path. The invoice sits in the books
--    forever and every total is wrong forever.
--
--    Reproduced: fn_activate_subscription(<school>, 'growth', 12) run twice in
--    a row raises two invoices and bills the school Rs 76,000 for one year.
--    fn_platform_outstanding then says Rs 76,000 is owed and no function in the
--    schema can say otherwise.
--
-- 3. NO WAY TO GIVE ANYTHING BACK
--
--    Void is not the answer to every mistake. If a school paid for twelve
--    months, used four, and left, the invoice was CORRECT — voiding it would
--    erase a real sale and unbalance the books against the payment that was
--    genuinely received. What is needed is a credit note: a second document
--    that says "of that invoice, Rs 25,000 is no longer due".
--
--    So both exist, and they are not interchangeable:
--
--      VOID        the document should never have existed. Excluded from every
--                  total. Refused once anything is attached to it.
--      CREDIT NOTE the document was right and part of it is being given back.
--                  Its own number, its own row, reduces the balance.
--
--    Void is refused on an invoice that has a payment or a credit note against
--    it, precisely because that is the case a credit note exists for.
--
-- 4. WITHHOLDING TAX MADE EVERY BALANCE WRONG
--
--    This is the one that would have caused real arguments. Under section
--    153(1)(b) of the Income Tax Ordinance a Pakistani buyer of services is
--    required to deduct income tax at source and pay it to the FBR on the
--    seller's behalf. So a school invoiced Rs 38,000 pays Rs 34,960 and sends a
--    CPR for the Rs 3,040 it deducted. That money HAS been paid — to the
--    government, against our tax liability — and the certificate is how we
--    claim it.
--
--    With only `amount` on platform_payments, the software records Rs 34,960 and
--    reports Rs 3,040 outstanding. Forever. Multiply by fifty schools a year and
--    the receivable is permanently, invisibly wrong, and the operator chases
--    schools for money they already paid.
--
--    Reproduced: record a payment of 34960 against a 38000 invoice and
--    fn_platform_outstanding returns 3040 with no way to close it except a fake
--    payment or a fake discount, both of which put a lie in the books.
--
--    Fixed with tax_withheld and a certificate reference on the payment, and
--    settlement redefined as amount + tax_withheld everywhere.
--
-- WHY THE TAX RATE IS NOT APPLIED AUTOMATICALLY
--
-- Two different taxes are involved and only one of them is ours to compute:
--
--   * Income tax withholding is the BUYER's obligation. The rate depends on
--     whether the school is on the Active Taxpayer List and whether it is a
--     prescribed withholding agent at all. We cannot know either. So the invoice
--     carries a NOTE telling them the rate we expect, and the payment records
--     what they actually deducted.
--
--   * Sales tax on services is provincial — PRA in Punjab, SRB in Sindh, KPRA,
--     BRA — with different rates and different registration thresholds. If this
--     software printed a confident 16% on an invoice from an unregistered
--     business it would be inventing a tax liability. So tax_pct defaults to
--     zero and the operator sets it per invoice, from a default they configured
--     themselves in 0076.
--
-- A blank tax line is a question the operator answers once. A wrong tax line is
-- a document a customer's auditor rejects.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Columns
--
-- amount stays what it always was: the charge before tax. Everything downstream
-- moves to net_total, so an existing row with no tax and no credit note keeps
-- exactly the value it had — which is what makes this migration safe to apply to
-- live books.
-- ---------------------------------------------------------------------------
alter table public.platform_invoices
  add column if not exists kind text not null default 'invoice',
  add column if not exists credits_invoice_id uuid,
  add column if not exists serial integer,
  add column if not exists doc_no text,
  add column if not exists tax_pct numeric(5,2) not null default 0,
  add column if not exists tax_amount numeric(12,2) not null default 0,
  add column if not exists voided_at timestamptz,
  add column if not exists voided_by uuid,
  add column if not exists void_reason text;

do $ddl$
begin
  if not exists (select 1 from pg_constraint where conname = 'platform_invoices_kind_chk') then
    alter table public.platform_invoices add constraint platform_invoices_kind_chk
      check (kind in ('invoice', 'credit_note'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'platform_invoices_tax_chk') then
    alter table public.platform_invoices add constraint platform_invoices_tax_chk
      check (tax_pct >= 0 and tax_pct <= 100 and tax_amount >= 0);
  end if;
  -- A credit note without a parent is a mystery document; an invoice with one is
  -- a contradiction. Both are refused by the same constraint.
  if not exists (select 1 from pg_constraint where conname = 'platform_invoices_credits_chk') then
    alter table public.platform_invoices add constraint platform_invoices_credits_chk
      check ((kind = 'credit_note') = (credits_invoice_id is not null));
  end if;
  -- Void is either fully recorded or not recorded: a voided_at with no reason is
  -- how an unexplained hole appears in a set of books.
  if not exists (select 1 from pg_constraint where conname = 'platform_invoices_void_chk') then
    alter table public.platform_invoices add constraint platform_invoices_void_chk
      check ((voided_at is null and void_reason is null)
          or (voided_at is not null and btrim(coalesce(void_reason, '')) <> ''));
  end if;
  -- ON DELETE CASCADE on the self-reference. platform_invoices already cascades
  -- from schools, and offboarding a school deletes its invoices; without a rule
  -- here that delete would be refused by a credit note pointing at one of them.
  if not exists (select 1 from pg_constraint
                  where conname = 'platform_invoices_credits_invoice_id_fkey') then
    alter table public.platform_invoices add constraint platform_invoices_credits_invoice_id_fkey
      foreign key (credits_invoice_id) references public.platform_invoices(id)
      on delete cascade;
  end if;
end $ddl$;

-- The one number every total is computed from. Generated rather than derived in
-- each query, because "invoices minus credit notes, tax included, void excluded"
-- written out by hand in six places is five chances to write it differently —
-- and 0064's own header says a balance that two screens disagree about is the
-- defect. Void is NOT folded in here: a generated column cannot be filtered on
-- for free, and every consumer must state `voided_at is null` on purpose so that
-- forgetting it is visible in the query rather than hidden in a column.
do $gen$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'platform_invoices'
                    and column_name = 'net_total') then
    alter table public.platform_invoices
      add column net_total numeric(12,2)
        generated always as (
          case when kind = 'credit_note' then -(amount + tax_amount)
               else amount + tax_amount end) stored;
  end if;
end $gen$;

alter table public.platform_payments
  add column if not exists tax_withheld numeric(12,2) not null default 0,
  add column if not exists tax_certificate text;

do $ddl2$
begin
  if not exists (select 1 from pg_constraint where conname = 'platform_payments_wht_chk') then
    alter table public.platform_payments add constraint platform_payments_wht_chk
      check (tax_withheld >= 0);
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'platform_payments'
                    and column_name = 'settled') then
    -- What the invoice was actually settled by: the cash we received plus the tax
    -- the school paid to the FBR in our name.
    alter table public.platform_payments
      add column settled numeric(12,2)
        generated always as (amount + tax_withheld) stored;
  end if;
end $ddl2$;

create unique index if not exists idx_platform_invoices_doc_no
  on public.platform_invoices(doc_no);
create unique index if not exists idx_platform_invoices_serial
  on public.platform_invoices(kind, serial);
create index if not exists idx_platform_invoices_credits
  on public.platform_invoices(credits_invoice_id)
  where credits_invoice_id is not null;

-- ---------------------------------------------------------------------------
-- 2. The document number
--
-- In a BEFORE INSERT trigger so that every path gets one — including
-- fn_activate_subscription, which is not modified by this migration and does not
-- need to know that documents are numbered.
--
-- pg_advisory_xact_lock, not just the unique index: max(serial)+1 read by two
-- concurrent transactions returns the same number to both, and one of them then
-- fails on the index. A failed renewal because somebody else renewed at the same
-- moment is the kind of fault that happens once a year and is never reproduced.
-- The lock is per kind, held to the end of the transaction, and released
-- automatically on rollback.
--
-- The prefix is read at INSERT and stored. Changing invoice_prefix in Settings
-- therefore renames nothing that has already been issued — a document a customer
-- is holding must not change its number — and the serial keeps counting, so the
-- series stays unbroken across a rename.
-- ---------------------------------------------------------------------------
create or replace function public.fn__assign_doc_no()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_prefix text; v_serial integer;
begin
  if new.doc_no is not null and new.serial is not null then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtext('platform_doc_no'), hashtext(new.kind));

  select case when new.kind = 'credit_note' then credit_prefix else invoice_prefix end
    into v_prefix from public.platform_settings where id;
  v_prefix := coalesce(v_prefix,
    case when new.kind = 'credit_note' then 'CN' else 'INV' end);

  select coalesce(max(i.serial), 0) + 1 into v_serial
    from public.platform_invoices i where i.kind = new.kind;

  new.serial := v_serial;
  new.doc_no := v_prefix || '-' || lpad(v_serial::text, 4, '0');
  return new;
end;
$$;

revoke all on function public.fn__assign_doc_no() from public, anon, authenticated;

drop trigger if exists trg_assign_doc_no on public.platform_invoices;
create trigger trg_assign_doc_no
  before insert on public.platform_invoices
  for each row execute function public.fn__assign_doc_no();

-- Numbers for whatever is already on the books, in the order they were issued.
-- Without this every existing invoice has a null doc_no and the printable
-- document has a blank where its number goes — and because the unique index
-- permits many nulls, nothing would complain.
do $backfill$
declare r record; v_n integer := 0; v_prefix text; v_serial integer;
begin
  select invoice_prefix into v_prefix from public.platform_settings where id;
  v_prefix := coalesce(v_prefix, 'INV');
  select coalesce(max(serial), 0) into v_serial
    from public.platform_invoices where kind = 'invoice';
  for r in
    select id from public.platform_invoices
     where doc_no is null and kind = 'invoice'
     order by issued_on, created_at, id
  loop
    v_serial := v_serial + 1;
    update public.platform_invoices
       set serial = v_serial,
           doc_no = v_prefix || '-' || lpad(v_serial::text, 4, '0')
     where id = r.id;
    v_n := v_n + 1;
  end loop;
  if v_n > 0 then
    raise notice '0077: numbered % existing invoice(s)', v_n;
  end if;
end $backfill$;

-- ---------------------------------------------------------------------------
-- 3. The two totals, in one place each
--
-- Every screen that shows money now calls these. Named with fn__ and revoked:
-- they take a school id and answer without checking who is asking, so they must
-- never be reachable from a browser. Their callers do the gating.
-- ---------------------------------------------------------------------------
create or replace function public.fn__platform_billed(p_school_id uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(net_total), 0)
    from public.platform_invoices
   where school_id = p_school_id and voided_at is null;
$$;

create or replace function public.fn__platform_settled(p_school_id uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(settled), 0)
    from public.platform_payments
   where school_id = p_school_id;
$$;

revoke all on function public.fn__platform_billed(uuid)  from public, anon, authenticated;
revoke all on function public.fn__platform_settled(uuid) from public, anon, authenticated;

create or replace function public.fn_platform_outstanding(p_school_id uuid)
returns numeric language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return public.fn__platform_billed(p_school_id) - public.fn__platform_settled(p_school_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Void
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_void_invoice(
  p_invoice_id uuid, p_reason text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_inv record; v_pay numeric; v_cred numeric; v_warn text;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_reason is null then
    raise exception 'Voiding a document needs a reason — it is printed on it';
  end if;

  select * into v_inv from public.platform_invoices where id = p_invoice_id;
  if not found then
    raise exception 'No such document';
  end if;
  if v_inv.voided_at is not null then
    raise exception 'That document was already voided on %', v_inv.voided_at::date;
  end if;

  -- The two refusals that keep the books consistent.
  select coalesce(sum(settled), 0) into v_pay
    from public.platform_payments where invoice_id = p_invoice_id;
  if v_pay > 0 then
    raise exception
      'Cannot void %: % has been received against it. Raise a credit note instead.',
      v_inv.doc_no, to_char(v_pay, 'FM999999999.00');
  end if;

  select coalesce(sum(amount + tax_amount), 0) into v_cred
    from public.platform_invoices
   where credits_invoice_id = p_invoice_id and voided_at is null;
  if v_cred > 0 then
    raise exception
      'Cannot void %: a credit note has already been raised against it. Void the '
      'credit note first if that was the mistake.', v_inv.doc_no;
  end if;

  -- The licence is NOT rolled back, and saying so beats leaving it to be
  -- discovered. fn_activate_subscription both charges and extends; voiding the
  -- charge is a correction to the books, not a repossession of the year. If the
  -- school should not have the time either, the operator changes the licence
  -- with the licence tools — deliberately, as a second decision.
  if exists (select 1 from public.subscriptions s
              where s.school_id = v_inv.school_id
                and s.period_start = v_inv.period_start
                and s.period_end = v_inv.period_end) then
    v_warn := format(
      'The licence still runs %s to %s. Voiding this invoice does not shorten it — '
      'change the plan or cancel separately if that was also wrong.',
      v_inv.period_start, v_inv.period_end);
  end if;

  update public.platform_invoices
     set voided_at = now(), voided_by = auth.uid(), void_reason = v_reason
   where id = p_invoice_id;

  perform public.fn__log_operator_action(
    case when v_inv.kind = 'credit_note' then 'credit_note_voided' else 'invoice_voided' end,
    v_inv.school_id,
    jsonb_build_object('invoice_id', p_invoice_id, 'doc_no', v_inv.doc_no,
                       'amount', v_inv.amount, 'tax_amount', v_inv.tax_amount,
                       'reason', v_reason, 'licence_untouched', v_warn is not null));

  insert into public.audit_log(school_id, actor, action, entity, entity_id, before, reason)
  values (v_inv.school_id, auth.uid(), 'platform_invoice_voided', 'platform_invoices',
          p_invoice_id::text,
          jsonb_build_object('doc_no', v_inv.doc_no, 'amount', v_inv.amount,
                             'tax_amount', v_inv.tax_amount),
          v_reason);

  return jsonb_build_object(
    'invoice_id', p_invoice_id, 'doc_no', v_inv.doc_no, 'voided', true,
    'warning', v_warn,
    'outstanding', public.fn_platform_outstanding(v_inv.school_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Credit note
--
-- Its own document in its own series, carrying the plan and period of the
-- invoice it credits so that "what was this about" is answerable from the credit
-- note alone. Capped at the uncredited remainder of the original: crediting more
-- than was charged turns a receivable into a liability the software cannot pay.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_credit_note(
  p_invoice_id uuid,
  p_amount numeric,
  p_reason text,
  -- Null means "credit the tax in proportion", which is right in every ordinary
  -- case. Explicit means the operator is crediting only the net, or only the
  -- tax, and knows why.
  p_tax_amount numeric default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_inv record; v_credited numeric; v_room numeric;
  v_tax numeric; v_id uuid; v_doc text;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_reason is null then
    raise exception 'A credit note needs a reason — it is printed on it';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'A credit note must be more than zero';
  end if;

  select * into v_inv from public.platform_invoices where id = p_invoice_id;
  if not found then
    raise exception 'No such invoice';
  end if;
  if v_inv.kind <> 'invoice' then
    raise exception 'Credit notes are raised against invoices, not against %', v_inv.kind;
  end if;
  if v_inv.voided_at is not null then
    raise exception 'That invoice is voided — there is nothing to credit';
  end if;

  v_tax := case
    when p_tax_amount is not null then round(p_tax_amount, 2)
    when v_inv.amount > 0 then round(v_inv.tax_amount * (p_amount / v_inv.amount), 2)
    else 0 end;
  if v_tax < 0 then
    raise exception 'A tax credit cannot be negative';
  end if;

  select coalesce(sum(amount + tax_amount), 0) into v_credited
    from public.platform_invoices
   where credits_invoice_id = p_invoice_id and voided_at is null;

  v_room := (v_inv.amount + v_inv.tax_amount) - v_credited;
  if round(p_amount + v_tax, 2) > v_room then
    raise exception
      'That would credit % against %, which is % and already has % credited. '
      'At most % remains.',
      to_char(p_amount + v_tax, 'FM999999999.00'), v_inv.doc_no,
      to_char(v_inv.amount + v_inv.tax_amount, 'FM999999999.00'),
      to_char(v_credited, 'FM999999999.00'), to_char(v_room, 'FM999999999.00');
  end if;

  insert into public.platform_invoices
    (school_id, kind, credits_invoice_id, plan_code, cycle, months,
     period_start, period_end, amount, list_amount, tax_pct, tax_amount,
     issued_on, due_on, note, created_by)
  values
    (v_inv.school_id, 'credit_note', p_invoice_id, v_inv.plan_code, v_inv.cycle,
     v_inv.months, v_inv.period_start, v_inv.period_end,
     round(p_amount, 2),
     -- list_amount equals amount on a credit note, so fn_platform_revenue's
     -- discount figure — sum(list_amount - amount) — is untouched by credits. A
     -- refund is not a discount and must not appear as one.
     round(p_amount, 2),
     v_inv.tax_pct, v_tax,
     current_date, null,
     format('Credit against %s — %s', v_inv.doc_no, v_reason),
     auth.uid())
  returning id, doc_no into v_id, v_doc;

  insert into public.audit_log(school_id, actor, action, entity, entity_id, after, reason)
  values (v_inv.school_id, auth.uid(), 'platform_credit_note', 'platform_invoices',
          v_id::text,
          jsonb_build_object('doc_no', v_doc, 'credits', v_inv.doc_no,
                             'amount', round(p_amount, 2), 'tax_amount', v_tax),
          v_reason);

  return jsonb_build_object(
    'credit_note_id', v_id, 'doc_no', v_doc,
    'credits_doc_no', v_inv.doc_no,
    'amount', round(p_amount, 2), 'tax_amount', v_tax,
    'total', round(p_amount, 2) + v_tax,
    'outstanding', public.fn_platform_outstanding(v_inv.school_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Recording a payment, with the tax the school withheld
--
-- Replaces 0064's version. DROP first: the parameter list grows, and leaving the
-- 7-argument form as an overload would mean the console could still call the one
-- that cannot record a withholding certificate — which is defect 4.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_platform_record_payment(uuid, numeric, date, text, text, uuid, text);
drop function if exists public.fn_platform_record_payment(uuid, numeric, date, text, text, uuid, text, numeric, text);

create function public.fn_platform_record_payment(
  p_school_id uuid,
  p_amount numeric,
  p_paid_on date default null,
  p_method text default 'bank',
  p_reference text default null,
  p_invoice_id uuid default null,
  p_note text default null,
  -- What the school deducted and paid to the FBR on our behalf. Zero for a
  -- school that is not a withholding agent, which is most of them.
  p_tax_withheld numeric default 0,
  p_tax_certificate text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_actor uuid := auth.uid();
  v_tax numeric := round(coalesce(p_tax_withheld, 0), 2);
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'A payment must be more than zero';
  end if;
  if v_tax < 0 then
    raise exception 'Withheld tax cannot be negative';
  end if;
  if not exists (select 1 from public.schools where id = p_school_id) then
    raise exception 'Unknown school %', p_school_id;
  end if;
  -- An invoice from ANOTHER school would silently move that school's balance.
  if p_invoice_id is not null
     and not exists (select 1 from public.platform_invoices
                      where id = p_invoice_id and school_id = p_school_id) then
    raise exception 'That invoice does not belong to this school';
  end if;
  -- Allocating cash to a document that has been cancelled is how a void invoice
  -- comes back to life as a balance nobody can explain.
  if p_invoice_id is not null
     and exists (select 1 from public.platform_invoices
                  where id = p_invoice_id and voided_at is not null) then
    raise exception 'That invoice is voided — allocate the payment elsewhere or leave it unallocated';
  end if;
  -- A certificate number with no tax against it, or tax with no certificate, is
  -- half a record. The second is a warning rather than a refusal: the CPR often
  -- arrives weeks after the transfer, and refusing the payment until it does
  -- would push the operator back to the notebook.
  if v_tax = 0 and nullif(btrim(coalesce(p_tax_certificate, '')), '') is not null then
    raise exception 'A tax certificate was given but no withheld amount';
  end if;

  insert into public.platform_payments
    (school_id, invoice_id, amount, paid_on, method, reference, note, created_by,
     tax_withheld, tax_certificate)
  values (p_school_id, p_invoice_id, p_amount,
          coalesce(p_paid_on, current_date), coalesce(p_method, 'bank'),
          nullif(btrim(coalesce(p_reference, '')), ''),
          nullif(btrim(coalesce(p_note, '')), ''), v_actor,
          v_tax, nullif(btrim(coalesce(p_tax_certificate, '')), ''))
  returning id into v_id;

  insert into public.audit_log(school_id, actor, action, entity, entity_id, after, reason)
  values (p_school_id, v_actor, 'platform_payment_recorded', 'platform_payments',
          v_id::text,
          jsonb_build_object('amount', p_amount, 'method', coalesce(p_method, 'bank'),
                             'paid_on', coalesce(p_paid_on, current_date),
                             'invoice_id', p_invoice_id,
                             'tax_withheld', v_tax,
                             'tax_certificate', nullif(btrim(coalesce(p_tax_certificate, '')), '')),
          nullif(btrim(coalesce(p_note, '')), ''));

  return jsonb_build_object(
    'payment_id', v_id, 'school_id', p_school_id, 'amount', p_amount,
    'tax_withheld', v_tax, 'settled', p_amount + v_tax,
    'awaiting_certificate', v_tax > 0
      and nullif(btrim(coalesce(p_tax_certificate, '')), '') is null,
    'outstanding', public.fn_platform_outstanding(p_school_id));
end;
$$;

-- The CPR arriving later is the normal case, so there is a way to attach it
-- without inventing a second payment.
create or replace function public.fn_platform_attach_tax_certificate(
  p_payment_id uuid, p_certificate text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_pay record; v_cert text := nullif(btrim(coalesce(p_certificate, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_cert is null then
    raise exception 'Give the certificate or CPR number';
  end if;
  select * into v_pay from public.platform_payments where id = p_payment_id;
  if not found then
    raise exception 'No such payment';
  end if;
  if v_pay.tax_withheld <= 0 then
    raise exception 'No tax was withheld on that payment';
  end if;

  update public.platform_payments set tax_certificate = v_cert where id = p_payment_id;

  perform public.fn__log_operator_action('tax_certificate_attached', v_pay.school_id,
    jsonb_build_object('payment_id', p_payment_id, 'tax_withheld', v_pay.tax_withheld,
                       'certificate', v_cert));

  return jsonb_build_object('payment_id', p_payment_id, 'tax_certificate', v_cert);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Setting the tax line on an invoice
--
-- Separate from raising it, because the operator often does not know the rate at
-- the moment they grant the licence — and a renewal must not be blocked waiting
-- for a tax question. Refused once the invoice has been paid or credited: the
-- total on the document the customer is holding must not change under them.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_set_invoice_tax(
  p_invoice_id uuid, p_tax_pct numeric, p_tax_amount numeric default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_inv record; v_pct numeric; v_amt numeric; v_touched numeric;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into v_inv from public.platform_invoices where id = p_invoice_id;
  if not found then
    raise exception 'No such invoice';
  end if;
  if v_inv.voided_at is not null then
    raise exception 'That invoice is voided';
  end if;
  if v_inv.kind <> 'invoice' then
    raise exception 'Tax is set on the invoice, not on the credit note';
  end if;

  select coalesce(sum(settled), 0) into v_touched
    from public.platform_payments where invoice_id = p_invoice_id;
  if v_touched > 0 then
    raise exception
      'Cannot change the tax on %: % has been received against it. Raise a credit '
      'note and a fresh invoice.', v_inv.doc_no, to_char(v_touched, 'FM999999999.00');
  end if;
  if exists (select 1 from public.platform_invoices
              where credits_invoice_id = p_invoice_id and voided_at is null) then
    raise exception 'Cannot change the tax on %: it has a credit note against it', v_inv.doc_no;
  end if;

  v_pct := round(coalesce(p_tax_pct, 0), 2);
  if v_pct < 0 or v_pct > 100 then
    raise exception 'A tax rate must be between 0 and 100';
  end if;
  v_amt := round(coalesce(p_tax_amount, v_inv.amount * v_pct / 100), 2);
  if v_amt < 0 then
    raise exception 'A tax amount cannot be negative';
  end if;

  update public.platform_invoices
     set tax_pct = v_pct, tax_amount = v_amt where id = p_invoice_id;

  perform public.fn__log_operator_action('invoice_tax_set', v_inv.school_id,
    jsonb_build_object('invoice_id', p_invoice_id, 'doc_no', v_inv.doc_no,
                       'tax_pct', v_pct, 'tax_amount', v_amt,
                       'was_tax_amount', v_inv.tax_amount));

  return jsonb_build_object('invoice_id', p_invoice_id, 'doc_no', v_inv.doc_no,
    'tax_pct', v_pct, 'tax_amount', v_amt, 'total', v_inv.amount + v_amt,
    'outstanding', public.fn_platform_outstanding(v_inv.school_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. The printable document
--
-- Everything needed to render one invoice or credit note, in one call, so the
-- printable page cannot be assembled from three queries that disagree.
--
-- `seller_missing` is repeated here from 0076 on purpose: the moment somebody is
-- about to print is the moment a blank NTN matters, and a warning on the Settings
-- screen they configured six months ago is a warning they will not see.
-- ---------------------------------------------------------------------------
create or replace function public.fn__invoice_document(p_invoice_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_inv record; v_s record; v_set record; v_ss record;
  v_plan text; v_credits numeric; v_paid numeric; v_missing text[] := '{}';
  v_total numeric;
begin
  select * into v_inv from public.platform_invoices where id = p_invoice_id;
  if not found then
    raise exception 'No such document';
  end if;

  select * into v_s   from public.schools         where id = v_inv.school_id;
  select * into v_ss  from public.school_settings where school_id = v_inv.school_id;
  select * into v_set from public.platform_settings where id;
  select name into v_plan from public.plans where code = v_inv.plan_code;

  if btrim(coalesce(v_set.business_name, '')) = '' then
    v_missing := array_append(v_missing, 'business_name'); end if;
  if btrim(coalesce(v_set.ntn, '')) = '' then
    v_missing := array_append(v_missing, 'ntn'); end if;
  if btrim(coalesce(v_set.address, '')) = '' then
    v_missing := array_append(v_missing, 'address'); end if;
  if btrim(coalesce(v_set.bank_account, '')) = '' then
    v_missing := array_append(v_missing, 'bank_account'); end if;

  select coalesce(sum(amount + tax_amount), 0) into v_credits
    from public.platform_invoices
   where credits_invoice_id = p_invoice_id and voided_at is null;
  select coalesce(sum(settled), 0) into v_paid
    from public.platform_payments where invoice_id = p_invoice_id;

  v_total := v_inv.amount + v_inv.tax_amount;

  return jsonb_build_object(
    'id', v_inv.id,
    'kind', v_inv.kind,
    'doc_no', v_inv.doc_no,
    'title', case when v_inv.kind = 'credit_note' then 'CREDIT NOTE' else 'INVOICE' end,
    'issued_on', v_inv.issued_on,
    'due_on', v_inv.due_on,
    'voided', v_inv.voided_at is not null,
    'voided_at', v_inv.voided_at,
    'void_reason', v_inv.void_reason,
    'credits_doc_no', (select doc_no from public.platform_invoices
                        where id = v_inv.credits_invoice_id),

    'seller', jsonb_build_object(
      'name', nullif(btrim(coalesce(v_set.business_name, '')), ''),
      'ntn', v_set.ntn, 'strn', v_set.strn,
      'address', v_set.address, 'city', v_set.city,
      'phone', v_set.phone, 'email', v_set.email, 'website', v_set.website),
    'seller_missing', to_jsonb(v_missing),

    -- The school's own registered name and address from school_settings where it
    -- has one, falling back to the signup record. An invoice addressed to
    -- "Al-Noor" when the school calls itself "Al-Noor Public School, Gujranwala"
    -- is an invoice their accountant queries.
    'buyer', jsonb_build_object(
      'school_id', v_s.id,
      'name', coalesce(nullif(btrim(coalesce(v_ss.name, '')), ''), v_s.name),
      'address', coalesce(v_ss.address, v_s.city),
      'city', v_s.city,
      'phone', coalesce(v_ss.phone, v_s.contact_phone),
      'email', coalesce(v_ss.email, v_s.contact_email),
      'attention', coalesce(v_ss.principal_name, v_s.contact_name)),

    -- One line, which is what is actually being sold: a licence for a period.
    -- An itemised breakdown of a single subscription would be invented detail.
    'lines', jsonb_build_array(jsonb_build_object(
      'description', format('%s plan — school management software licence',
                            coalesce(v_plan, v_inv.plan_code)),
      -- The RAW dates, not a formatted string. Rendering them here would put
      -- "2026-09-01" on a document whose every other date reads "26 Aug 2026",
      -- and a customer's accountant notices that before they notice the total.
      -- Formatting is the client's job, in one place, for the whole document.
      'period_start', v_inv.period_start,
      'period_end', v_inv.period_end,
      'months', v_inv.months,
      'cycle', v_inv.cycle,
      'amount', v_inv.amount,
      -- Shown only when it differs, and then it is the whole point of showing it.
      'list_amount', case when v_inv.kind = 'invoice'
                           and v_inv.list_amount <> v_inv.amount
                          then v_inv.list_amount else null end)),

    'tax', jsonb_build_object(
      'pct', v_inv.tax_pct, 'amount', v_inv.tax_amount,
      'label', case when v_inv.tax_pct > 0
                    then format('Sales tax on services @ %s%%',
                                trim(to_char(v_inv.tax_pct, 'FM999.99')))
                    else null end),

    'totals', jsonb_build_object(
      'subtotal', v_inv.amount,
      'tax', v_inv.tax_amount,
      'total', v_total,
      'credited', v_credits,
      'paid', v_paid,
      -- On this document only. The school's overall balance is a different
      -- number and putting it here would make one invoice look unpaid because
      -- another one is.
      'balance', v_total - v_credits - v_paid),

    'amount_in_words', public.fn__amount_in_words(v_total),

    'bank', case when v_inv.kind = 'credit_note' then 'null'::jsonb else
      jsonb_build_object(
        'bank_name', v_set.bank_name, 'title', v_set.bank_title,
        'account', v_set.bank_account, 'iban', v_set.bank_iban) end,

    -- The sentence that stops the argument in defect 4 before it starts. Printed
    -- only when a rate is configured, and it asks for the CPR because that is the
    -- document we need in order to claim the deduction.
    'withholding_note', case
      when v_inv.kind <> 'invoice' or coalesce(v_set.default_withholding_pct, 0) <= 0
        then null
      else format(
        'If you are required to deduct income tax at source under section 153(1)(b), '
        'please deduct %s%% (Rs %s) and remit the balance of Rs %s. Kindly send us '
        'the CPR / tax deduction certificate so the deduction can be credited to '
        'this invoice.',
        trim(to_char(v_set.default_withholding_pct, 'FM999.99')),
        to_char(round(v_total * v_set.default_withholding_pct / 100, 2), 'FM999,999,999.00'),
        to_char(round(v_total - v_total * v_set.default_withholding_pct / 100, 2),
                'FM999,999,999.00')) end,

    'note', v_inv.note,
    'footer', v_set.invoice_footer,

    'payments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'paid_on', p.paid_on, 'amount', p.amount, 'method', p.method,
               'reference', p.reference, 'tax_withheld', p.tax_withheld,
               'tax_certificate', p.tax_certificate, 'settled', p.settled)
             order by p.paid_on, p.created_at)
        from public.platform_payments p where p.invoice_id = p_invoice_id), '[]'::jsonb),

    'credit_notes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'doc_no', c.doc_no, 'issued_on', c.issued_on,
               'amount', c.amount, 'tax_amount', c.tax_amount,
               'total', c.amount + c.tax_amount, 'note', c.note,
               'voided', c.voided_at is not null)
             order by c.issued_on, c.serial)
        from public.platform_invoices c
       where c.credits_invoice_id = p_invoice_id), '[]'::jsonb));
end;
$$;

revoke all on function public.fn__invoice_document(uuid) from public, anon, authenticated;

-- The operator's door to it.
create or replace function public.fn_platform_invoice(p_invoice_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return public.fn__invoice_document(p_invoice_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. The ledger, with document numbers on it
--
-- DROP first: three columns are added, which `create or replace` cannot do.
-- Before this, the ledger's rows could not be pointed at — "the Rs 38,000 one"
-- was the only way to refer to a line, and with two renewals of the same plan in
-- a year that is ambiguous.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_platform_ledger(uuid);
create function public.fn_platform_ledger(p_school_id uuid)
returns table (
  entry_id uuid, entry_date date, kind text, doc_no text, description text,
  charged numeric, paid numeric, voided boolean, note text, reference text
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  -- Wrapped in a subquery so the sort can be an EXPRESSION. A set operation's
  -- ORDER BY may only name output columns, and the natural reading order needs
  -- "documents before the payment that settles them" on a shared date — which
  -- alphabetical order on `kind` gets backwards.
  return query
  select x.entry_id, x.entry_date, x.kind, x.doc_no, x.description,
         x.charged, x.paid, x.voided, x.note, x.reference
    from (
      select i.id as entry_id, i.issued_on as entry_date, i.kind as kind,
             i.doc_no as doc_no,
             case when i.kind = 'credit_note'
                  then format('Credit against %s',
                              coalesce((select c.doc_no from public.platform_invoices c
                                         where c.id = i.credits_invoice_id), 'an invoice'))
                  else format('%s · %s month%s · %s to %s', i.plan_code, i.months,
                              case when i.months = 1 then '' else 's' end,
                              i.period_start, i.period_end) end as description,
             -- Signed, and zero for a void document: a voided invoice stays
             -- visible as a row — deleting history is how a business loses an
             -- audit — but it must not add up to anything.
             case when i.voided_at is not null then 0::numeric
                  else i.net_total end as charged,
             null::numeric as paid,
             (i.voided_at is not null) as voided,
             case
               when i.voided_at is not null
                 then format('VOID — %s', i.void_reason)
               -- A discount only reads as a discount next to the list price.
               when i.kind = 'invoice' and i.amount <> i.list_amount
                 then format('list %s — %s', to_char(i.list_amount, 'FM999999999.00'),
                             coalesce(i.note, 'no reason recorded'))
               else i.note end as note,
             null::text as reference
        from public.platform_invoices i
       where i.school_id = p_school_id
      union all
      select p.id, p.paid_on, 'payment'::text, null::text,
             case when p.tax_withheld > 0
                  then format('%s payment + %s tax withheld', p.method,
                              to_char(p.tax_withheld, 'FM999999999.00'))
                  else format('%s payment', p.method) end,
             null::numeric,
             p.settled,
             false,
             case when p.tax_withheld > 0 and p.tax_certificate is null
                  then btrim(coalesce(p.note || ' — ', '') || 'CPR not received yet')
                  else p.note end,
             p.reference
        from public.platform_payments p
       where p.school_id = p_school_id
    ) x
   order by x.entry_date,
            case when x.kind = 'payment' then 2 else 1 end,
            x.doc_no nulls last;
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. The two roll-ups
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_revenue(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_invoiced numeric; v_collected numeric; v_discounted numeric;
  v_credited numeric; v_withheld numeric;
  v_outstanding numeric; v_by_plan jsonb; v_owing jsonb;
  v_voided numeric; v_awaiting numeric;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Give a start date and an end date, the end not before the start';
  end if;

  select coalesce(sum(amount + tax_amount), 0), coalesce(sum(list_amount - amount), 0)
    into v_invoiced, v_discounted
    from public.platform_invoices
   where issued_on between p_from and p_to and kind = 'invoice' and voided_at is null;

  select coalesce(sum(amount + tax_amount), 0) into v_credited
    from public.platform_invoices
   where issued_on between p_from and p_to and kind = 'credit_note' and voided_at is null;

  -- Voided in this window, reported rather than silently dropped: a month where
  -- three invoices were cancelled is a month somebody should look at.
  select coalesce(sum(amount + tax_amount), 0) into v_voided
    from public.platform_invoices
   where issued_on between p_from and p_to and voided_at is not null;

  -- Collected is what SETTLED, cash plus withheld tax, because the withheld part
  -- was paid — to the FBR, against our liability. Reported separately too, since
  -- it is not money in the bank and a cash-flow question needs the difference.
  select coalesce(sum(settled), 0), coalesce(sum(tax_withheld), 0)
    into v_collected, v_withheld
    from public.platform_payments
   where paid_on between p_from and p_to;

  select coalesce(sum(tax_withheld), 0) into v_awaiting
    from public.platform_payments
   where tax_withheld > 0 and tax_certificate is null;

  select coalesce(jsonb_agg(x order by x->>'plan_code'), '[]'::jsonb) into v_by_plan
    from (
      select jsonb_build_object('plan_code', plan_code,
                                'invoices', count(*),
                                'amount', sum(amount + tax_amount)) as x
        from public.platform_invoices
       where issued_on between p_from and p_to and kind = 'invoice' and voided_at is null
       group by plan_code) g;

  -- Everything ever billed minus everything ever settled: a receivable does not
  -- belong to the month it was raised in.
  select coalesce(sum(i), 0), coalesce(jsonb_agg(j order by j->>'school_name'), '[]'::jsonb)
    into v_outstanding, v_owing
    from (
      select bal.owed as i,
             jsonb_build_object('school_id', bal.school_id,
                                'school_name', bal.name,
                                'outstanding', bal.owed) as j
        from (
          select s.id as school_id, s.name,
                 public.fn__platform_billed(s.id) - public.fn__platform_settled(s.id) as owed
            from public.schools s) bal
       where bal.owed > 0) o;

  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    'invoiced', v_invoiced, 'collected', v_collected,
    'discounted', v_discounted,
    'credited', v_credited,
    'voided', v_voided,
    'net_invoiced', v_invoiced - v_credited,
    'cash_received', v_collected - v_withheld,
    'tax_withheld', v_withheld,
    'tax_certificates_awaited', v_awaiting,
    'outstanding_total', v_outstanding,
    'by_plan', v_by_plan,
    'schools_owing', v_owing);
end;
$$;

create or replace function public.fn_platform_schools()
returns table (
  school_id uuid, school_name text, city text,
  contact_name text, contact_phone text,
  plan_code text, status public.subscription_status,
  expires_on date, days_left integer,
  student_count integer, student_limit integer,
  limit_state text, suggested_plan text, needs_upgrade boolean,
  outstanding numeric, last_paid_on date
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
    select
      s.id, s.name, s.city, s.contact_name, s.contact_phone,
      sub.plan_code,
      public.fn_effective_status(s.id),
      case when sub.status = 'trialing' then sub.trial_ends_on else sub.period_end end,
      (case when sub.status = 'trialing' then sub.trial_ends_on else sub.period_end end
        - current_date)::integer,
      sub.student_count,
      p.student_limit,
      case
        when p.student_limit is null then 'ok'
        when sub.student_count <= p.student_limit then 'ok'
        when sub.student_count <= public.plan_margin_limit(p.student_limit) then 'within_margin'
        else 'over' end,
      sug.code,
      sug.code is distinct from sub.plan_code,
      public.fn__platform_billed(s.id) - public.fn__platform_settled(s.id),
      (select max(pm.paid_on) from public.platform_payments pm
        where pm.school_id = s.id)
    from public.schools s
    join public.subscriptions sub on sub.school_id = s.id
    join public.plans p on p.code = sub.plan_code
    cross join lateral (
      select p2.code from public.plans p2
       where p2.active and (p2.student_limit is null or p2.student_limit >= sub.student_count)
       order by p2.sort_order limit 1
    ) sug
    order by s.name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 11. The insert log has to know a credit note when it sees one
--
-- 0073's trigger labels every platform_invoices insert 'invoice_raised'. A
-- credit note is the opposite of raising an invoice and an activity feed that
-- calls it one is worse than an empty feed.
-- ---------------------------------------------------------------------------
create or replace function public.fn__log_platform_invoice()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.fn__log_operator_action(
    case when new.kind = 'credit_note' then 'credit_note_raised' else 'invoice_raised' end,
    new.school_id,
    jsonb_build_object(
      'invoice_id',  new.id,
      'doc_no',      new.doc_no,
      'kind',        new.kind,
      'credits_invoice_id', new.credits_invoice_id,
      'plan_code',   new.plan_code,
      'months',      new.months,
      'amount',      new.amount,
      'tax_amount',  new.tax_amount,
      'total',       new.amount + new.tax_amount,
      -- The number that makes a discount visible. 0064 records list_amount so
      -- "given away" can be computed; recording the gap here means the reason
      -- and the amount sit in one row rather than being joined back together.
      'list_amount', new.list_amount,
      'discount',    case when new.kind = 'invoice'
                          then coalesce(new.list_amount, new.amount) - new.amount
                          else 0 end,
      'note',        new.note));
  return null;
end;
$$;

revoke all on function public.fn__log_platform_invoice() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 12. The school detail screen's money block
--
-- 0075's fn_platform_school_detail computes its own invoiced/paid with two
-- inline sums, which after this migration would ignore void documents, credit
-- notes and withheld tax — three ways for the operator console to disagree with
-- the ledger about what a school owes.
--
-- Rewritten in place rather than restated: repeating two hundred lines of a
-- function to change three statements is how two versions of it end up in the
-- repository. The END STATE is asserted, so a partial match raises here rather
-- than passing quietly — a threshold check that tolerates a partial revert has
-- bitten this project more than once.
-- ---------------------------------------------------------------------------
do $rewrite$
declare
  v_src text;
  v_new text;
begin
  v_src := pg_get_functiondef('public.fn_platform_school_detail(uuid)'::regprocedure);
  v_new := v_src;

  -- Matched with regexp_replace and \s+ for the line breaks rather than on an
  -- exact string. An earlier version of this technique in 0072 matched on
  -- literal text and the indentation of the target had to be counted by hand;
  -- one wrong space and the replacement silently does not happen, which is why
  -- the end state below is asserted rather than the edit count.

  -- (a) invoiced → net of credit notes, void excluded
  v_new := regexp_replace(v_new,
    'select coalesce\(sum\(amount\), 0\) into v_invoiced from public\.platform_invoices\s+where school_id = p_school_id;',
    'v_invoiced := public.fn__platform_billed(p_school_id);');

  -- (b) paid → settled, so withheld tax counts as paid
  v_new := regexp_replace(v_new,
    'select coalesce\(sum\(amount\), 0\) into v_paid from public\.platform_payments\s+where school_id = p_school_id;',
    'v_paid := public.fn__platform_settled(p_school_id);');

  -- (c) the invoice count must not count cancelled paperwork
  v_new := regexp_replace(v_new,
    '''invoice_count'', \(select count\(\*\) from public\.platform_invoices\s+where school_id = p_school_id\)',
    '''invoice_count'', (select count(*) from public.platform_invoices'
      || E'\n                         where school_id = p_school_id'
      || E'\n                           and kind = ''invoice'' and voided_at is null)');

  if v_new <> v_src then
    execute v_new;
  end if;

  -- Assert the END STATE, not the number of edits: this is what makes the block
  -- safe to re-run and impossible to satisfy halfway. A threshold or a count
  -- would pass over a PARTIAL rewrite, which has bitten this project more than
  -- once.
  v_src := pg_get_functiondef('public.fn_platform_school_detail(uuid)'::regprocedure);
  if position('fn__platform_billed(p_school_id)' in v_src) = 0
     or position('fn__platform_settled(p_school_id)' in v_src) = 0 then
    raise exception '0077: fn_platform_school_detail still computes its own totals — the statement it was matched on has changed. Fix the rewrite above.';
  end if;
  if position('kind = ''invoice'' and voided_at is null' in v_src) = 0 then
    raise exception '0077: fn_platform_school_detail still counts voided invoices';
  end if;
  if position('into v_invoiced from public.platform_invoices' in v_src) > 0
     or position('into v_paid from public.platform_payments' in v_src) > 0 then
    raise exception '0077: the old inline sums are still in fn_platform_school_detail';
  end if;
  raise notice '0077: fn_platform_school_detail money block rewritten';
end $rewrite$;

-- ---------------------------------------------------------------------------
-- 13. Grants
-- ---------------------------------------------------------------------------
grant  execute on function public.fn_platform_void_invoice(uuid, text)   to authenticated;
revoke execute on function public.fn_platform_void_invoice(uuid, text) from public, anon;
grant  execute on function public.fn_platform_credit_note(uuid, numeric, text, numeric)   to authenticated;
revoke execute on function public.fn_platform_credit_note(uuid, numeric, text, numeric) from public, anon;
grant  execute on function public.fn_platform_set_invoice_tax(uuid, numeric, numeric)   to authenticated;
revoke execute on function public.fn_platform_set_invoice_tax(uuid, numeric, numeric) from public, anon;
grant  execute on function public.fn_platform_attach_tax_certificate(uuid, text)   to authenticated;
revoke execute on function public.fn_platform_attach_tax_certificate(uuid, text) from public, anon;
grant  execute on function public.fn_platform_invoice(uuid)   to authenticated;
revoke execute on function public.fn_platform_invoice(uuid) from public, anon;
grant  execute on function public.fn_platform_ledger(uuid)   to authenticated;
revoke execute on function public.fn_platform_ledger(uuid) from public, anon;
grant  execute on function
  public.fn_platform_record_payment(uuid, numeric, date, text, text, uuid, text, numeric, text)
  to authenticated;
revoke execute on function
  public.fn_platform_record_payment(uuid, numeric, date, text, text, uuid, text, numeric, text)
  from public, anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0078_renewals_self_serve.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0078 — Renewals were remembered, or they were not
--
-- Phase 3 of docs/SUPER-ADMIN-DESIGN.md, third of three. 0076 gave the invoices
-- a seller, 0077 gave them numbers and corrections. This is the part that decides
-- whether the business survives fifty customers.
--
-- THREE DEFECTS
--
-- 1. NOTHING TELLS THE OPERATOR A RENEWAL IS COMING
--
--    fn_platform_schools returns days_left and the console sorts by name. With
--    three schools that is fine — you know them. With fifty, a licence that
--    expired eleven days ago is row 34 of an alphabetical list, and the first
--    anyone hears of it is the principal phoning to say the software has locked.
--
--    That call is the worst possible moment for the renewal conversation: the
--    school is angry, the office is full of parents, and the vendor is the
--    reason nobody can take a fee. A renewal reminder sent 30 days earlier is
--    the same money and none of that.
--
-- 2. THE OPERATOR COULD RENEW A SCHOOL TWICE AND NOT KNOW
--
--    fn_activate_subscription extends from period_end when the licence is still
--    live, so running it twice grants two years and raises two invoices — the
--    reproduction in 0077's header.
--
--    THE FIRST VERSION OF THIS MIGRATION GOT THE FIX WRONG, and the test caught
--    it, so the reasoning is recorded rather than quietly corrected.
--
--    It reported `already_invoiced` on the worklist: an unvoided invoice whose
--    period starts after the current period ends. That column can never be
--    true. Activation raises the invoice AND extends period_end in the same
--    statement, so the newest invoice's period always ENDS at period_end, never
--    starts after it. A double renewal produces two contiguous invoices and a
--    period_end that moved twice — and no comparison between the invoices and
--    the subscription can tell that apart from one long renewal. The column
--    would have shipped reading `false` for every school on every screen and
--    looked like a working safeguard.
--
--    The fix belongs where the writing happens, not on the screen that reads it:
--    a trigger refuses an invoice that duplicates an existing one exactly — same
--    school, same plan, same period, not voided. Raising the same document twice
--    is never legitimate, so it needs no override, and a double click on Renew
--    is precisely the case where the second transaction has not seen the first
--    and computes the identical period.
--
--    What the worklist reports instead is `invoiced_to` — the furthest date any
--    unvoided invoice covers — beside `expires_on`. That comparison answers a
--    question the software genuinely could not answer before: this school has
--    licence time nobody billed for. `unbilled_days` names it, and
--    `never_invoiced` marks a school running on a trial or a favour.
--
-- 3. THE SCHOOL COULD NOT SEE ITS OWN BILL, OR TELL US IT HAD PAID
--
--    This is the defect that generates the phone calls. Today a school:
--      * cannot see what it was invoiced, or its balance
--      * cannot get a copy of an invoice for its own accounts
--      * does not know which bank account to pay into
--      * has no way to say "transferred, reference 4471" except to phone
--
--    And on our side, a bank transfer arrives with a reference and no name we
--    recognise, and matching it to a school is guesswork.
--
--    So: a Subscription screen with their own documents and our bank details,
--    and a claim path — the school reports the transfer, the operator confirms
--    it into a real payment. That is the same shape as the school's OWN parent
--    payment verification, which is deliberate: the workflow is already proven
--    inside this product, and the operator side of the business should not
--    invent a second pattern for the same problem.
--
-- WHY A CLAIM AND NOT A PAYMENT
--
-- A school-created row in platform_payments would let a school reduce its own
-- balance to zero by typing a number. The claim is a REQUEST — it changes no
-- total, appears in no revenue figure, and becomes money only when the operator
-- has seen the transfer. fn_platform_confirm_claim is the only bridge and it
-- goes through fn_platform_record_payment, so there is still exactly one place
-- that decides what a receipt looks like.
--
-- WHAT THE SCHOOL IS SHOWN OF OUR SETTINGS
--
-- Four bank fields, the business name, our phone and email, and whether online
-- payment is on. NOT the withholding default, NOT the document prefixes, NOT the
-- gateway provider's name, NOT platform_settings.updated_at. The table stays
-- operator-only in RLS and this function hand-picks what leaves it — an
-- allow-list, so a column added to platform_settings later is private until
-- somebody decides otherwise.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Raising the same document twice
--
-- A BEFORE INSERT trigger rather than a check inside fn_activate_subscription,
-- for the same reason 0077 numbered documents in a trigger: it covers every
-- path, including any future one, and fn_activate_subscription does not have to
-- know the rule exists.
--
-- "Exactly the same" is deliberately strict — school, plan, both period dates,
-- and only against invoices that are still live. A deliberate second year has a
-- different period_start and passes. A voided invoice does not block its
-- replacement, which is the whole point of voiding one.
-- ---------------------------------------------------------------------------
create or replace function public.fn__refuse_duplicate_invoice()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_doc text;
begin
  if new.kind <> 'invoice' then
    return new;
  end if;
  select i.doc_no into v_doc
    from public.platform_invoices i
   where i.school_id = new.school_id
     and i.kind = 'invoice'
     and i.voided_at is null
     and i.plan_code = new.plan_code
     and i.period_start = new.period_start
     and i.period_end = new.period_end
   limit 1;
  if v_doc is not null then
    -- One `%` per argument. A stray `%s` here would print the letter s and hide
    -- an argument, which this project has already shipped once.
    raise exception
      'Invoice % already covers % for % from % to %. Void it first if it was wrong.',
      v_doc, new.plan_code,
      (select name from public.schools where id = new.school_id),
      new.period_start, new.period_end;
  end if;
  return new;
end;
$$;

revoke all on function public.fn__refuse_duplicate_invoice() from public, anon, authenticated;

drop trigger if exists trg_refuse_duplicate_invoice on public.platform_invoices;
create trigger trg_refuse_duplicate_invoice
  before insert on public.platform_invoices
  for each row execute function public.fn__refuse_duplicate_invoice();

-- ---------------------------------------------------------------------------
-- 2. What is coming up, and how much of it was billed
--
-- Ordered by days_left so the list IS the worklist: the top of it is today's
-- phone calls and nobody has to sort anything.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_platform_due_soon(integer);
create function public.fn_platform_due_soon(p_days integer default 45)
returns table (
  school_id uuid, school_name text, city text,
  contact_name text, contact_phone text,
  plan_code text, status public.subscription_status,
  expires_on date, days_left integer, bucket text,
  student_count integer, student_limit integer,
  suggested_plan text, needs_upgrade boolean,
  renewal_amount numeric,
  outstanding numeric,
  -- The furthest date any live invoice covers, beside expires_on. See the header
  -- on why this replaced an `already_invoiced` flag that could never be true.
  invoiced_to date, unbilled_days integer, never_invoiced boolean,
  last_reminded_at timestamptz, last_reminded_stage text
) language plpgsql stable security definer set search_path = public as $$
declare v_days integer := greatest(0, least(coalesce(p_days, 45), 365));
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
    with base as (
      select s.id, s.name, s.city, s.contact_name, s.contact_phone,
             sub.plan_code, sub.status as raw_status, sub.cycle,
             sub.student_count, sub.period_end, sub.trial_ends_on,
             p.student_limit,
             public.fn_effective_status(s.id) as eff,
             case when sub.status = 'trialing' then sub.trial_ends_on
                  else sub.period_end end as expires
        from public.schools s
        join public.subscriptions sub on sub.school_id = s.id
        join public.plans p on p.code = sub.plan_code
       where s.active
    )
    select
      b.id, b.name, b.city, b.contact_name, b.contact_phone,
      b.plan_code, b.eff, b.expires,
      (b.expires - current_date)::integer,
      case
        when b.eff = 'cancelled' then 'cancelled'
        when b.eff = 'locked' then 'locked'
        when b.eff = 'grace'  then 'grace'
        when b.expires is null then 'unknown'
        when b.expires < current_date then 'overdue'
        when b.expires = current_date then 'today'
        when b.expires <= current_date + 7  then 'week'
        when b.expires <= current_date + 14 then 'fortnight'
        when b.expires <= current_date + 30 then 'month'
        else 'later' end,
      b.student_count, b.student_limit,
      sug.code,
      sug.code is distinct from b.plan_code,
      -- Priced on the plan they SHOULD be on and the cycle they are on now, so
      -- the number in the reminder is the number on the invoice. Quoting the
      -- old plan's price to a school that has outgrown it is how a renewal
      -- becomes an argument.
      public.fn__plan_price(coalesce(sug.code, b.plan_code),
                            case when b.cycle = 'yearly' then 12 else 1 end),
      public.fn__platform_billed(b.id) - public.fn__platform_settled(b.id),
      inv.covered_to,
      -- Licence time nobody billed for. A trial shows null here rather than a
      -- number, because a trial is unbilled on purpose and flagging it would put
      -- every new school on the chase list.
      case when inv.covered_to is null or b.expires is null then null
           when b.expires > inv.covered_to then (b.expires - inv.covered_to)::integer
           else 0 end,
      inv.covered_to is null,
      rem.at, rem.detail->>'stage'
      from base b
      cross join lateral (
        select p2.code from public.plans p2
         where p2.active
           and (p2.student_limit is null or p2.student_limit >= b.student_count)
         order by p2.sort_order limit 1
      ) sug
      -- How far the live invoices reach. Void excluded, because a cancelled
      -- invoice covers nothing. Null when a school has never been invoiced at
      -- all — a trial, or a year given away.
      left join lateral (
        select max(i.period_end) as covered_to
          from public.platform_invoices i
         where i.school_id = b.id and i.kind = 'invoice' and i.voided_at is null
      ) inv on true
      left join lateral (
        select a.at, a.detail
          from public.operator_actions a
         where a.school_id = b.id and a.action = 'renewal_reminder'
         order by a.at desc limit 1
      ) rem on true
     where b.eff in ('grace', 'locked', 'cancelled')
        or (b.expires is not null and b.expires <= current_date + v_days)
     order by 9 nulls last, 2;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. The reminder text
--
-- WhatsApp, not SMS and not email: it is what a Pakistani school office
-- actually reads, and this product already made that choice for parent
-- messaging. Click-to-chat, so no gateway, no per-message cost, and no delivery
-- report to pretend we have.
--
-- FIVE STAGES, and the difference between them is tone, not information:
--
--   ahead   a month out. Friendly, no urgency, gives them time to raise a
--           cheque request internally — which in a school takes weeks.
--   due     a week out. Names the date and the amount.
--   today   the last day. Still not a threat: grace has not started.
--   grace   expired, still working. This is the one that must be clear about
--           the date the software stops, because that is the only fact the
--           school needs in order to act.
--   locked  stopped. Says exactly what still works — reading and exporting
--           never stop, per 0026 — so the school is not panicking about data.
--
-- STABLE, and it does NOT record anything. Composing a message is not sending
-- one, and a function that logged "reminded" every time a screen rendered would
-- fill the history with reminders nobody sent. fn_platform_mark_reminded is the
-- separate, deliberate act.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_renewal_message(
  p_school_id uuid, p_stage text default null
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v record; v_set record; v_stage text; v_amount numeric; v_owed numeric;
  v_expiry date; v_days integer; v_stop date; v_text text; v_phone text;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  select s.name, s.contact_name, s.contact_phone, s.id,
         sub.plan_code, sub.cycle, sub.student_count, sub.period_end,
         sub.trial_ends_on, sub.status as raw_status,
         public.fn_effective_status(s.id) as eff,
         p.student_limit
    into v
    from public.schools s
    join public.subscriptions sub on sub.school_id = s.id
    join public.plans p on p.code = sub.plan_code
   where s.id = p_school_id;
  if v.name is null then
    raise exception 'Unknown school, or it has no subscription';
  end if;

  select * into v_set from public.platform_settings where id;

  v_expiry := case when v.raw_status = 'trialing' then v.trial_ends_on
                   else v.period_end end;
  v_days   := case when v_expiry is null then null else v_expiry - current_date end;
  v_stop   := case when v.period_end is null then null
                   else v.period_end + public.grace_days() end;

  v_stage := coalesce(nullif(btrim(coalesce(p_stage, '')), ''), case
    when v.eff = 'locked' then 'locked'
    when v.eff = 'grace'  then 'grace'
    when v_days is null then 'ahead'
    when v_days < 0  then 'grace'
    when v_days = 0  then 'today'
    when v_days <= 10 then 'due'
    else 'ahead' end);
  if v_stage not in ('ahead', 'due', 'today', 'grace', 'locked') then
    raise exception 'Unknown reminder stage: %', v_stage;
  end if;

  -- Priced on the plan the count fits, same as the worklist.
  select public.fn__plan_price(
           coalesce((select p2.code from public.plans p2
                      where p2.active and (p2.student_limit is null
                                        or p2.student_limit >= v.student_count)
                      order by p2.sort_order limit 1), v.plan_code),
           case when v.cycle = 'yearly' then 12 else 1 end)
    into v_amount;
  v_owed := public.fn__platform_billed(p_school_id) - public.fn__platform_settled(p_school_id);

  v_text := case v_stage
    when 'ahead' then format(
      'Assalam-o-Alaikum%s. Your %s software licence for %s runs to %s. Renewal '
      'for the next term is Rs %s. No rush — sending it now so you have time to '
      'arrange it. Bank details are on the Subscription screen inside the '
      'software (Settings → Subscription).',
      case when v.contact_name is null then '' else ' ' || v.contact_name end,
      coalesce(v_set.business_name, 'school management'), v.name,
      to_char(v_expiry, 'DD Mon YYYY'), to_char(v_amount, 'FM999,999,999'))

    when 'due' then format(
      'Assalam-o-Alaikum%s. %s''s licence expires on %s — %s day(s) from today. '
      'Renewal is Rs %s. You can see the invoice and our bank details inside the '
      'software under Settings → Subscription, and tell us the transfer reference '
      'from the same screen.',
      case when v.contact_name is null then '' else ' ' || v.contact_name end,
      v.name, to_char(v_expiry, 'DD Mon YYYY'), greatest(v_days, 0),
      to_char(v_amount, 'FM999,999,999'))

    when 'today' then format(
      'Assalam-o-Alaikum%s. %s''s licence expires today. Everything keeps working '
      'for %s more day(s) after that while we wait for the transfer, so nothing '
      'stops in the office today. Renewal is Rs %s.',
      case when v.contact_name is null then '' else ' ' || v.contact_name end,
      v.name, public.grace_days(), to_char(v_amount, 'FM999,999,999'))

    when 'grace' then format(
      'Assalam-o-Alaikum%s. %s''s licence expired on %s and is in the grace '
      'period. Everything still works until %s. Renewal is Rs %s%s. Please send '
      'the transfer reference on Settings → Subscription and we will confirm it '
      'the same day.',
      case when v.contact_name is null then '' else ' ' || v.contact_name end,
      v.name, to_char(v.period_end, 'DD Mon YYYY'),
      to_char(v_stop, 'DD Mon YYYY'), to_char(v_amount, 'FM999,999,999'),
      case when v_owed > 0
           then format(' (Rs %s is outstanding)', to_char(v_owed, 'FM999,999,999'))
           else '' end)

    else format(
      'Assalam-o-Alaikum%s. %s''s licence has expired and new entries are paused. '
      'Your data is safe and nothing has been deleted — you can still open every '
      'screen, print and export while this is sorted out. Renewal is Rs %s%s. '
      'Send us the transfer reference and we will restore it the same day.',
      case when v.contact_name is null then '' else ' ' || v.contact_name end,
      v.name, to_char(v_amount, 'FM999,999,999'),
      case when v_owed > 0
           then format(' (Rs %s outstanding)', to_char(v_owed, 'FM999,999,999'))
           else '' end)
  end;

  -- Digits only, and a bare local number gets Pakistan's country code, because
  -- wa.me refuses anything else. Same normalisation the parent outbox uses.
  v_phone := regexp_replace(coalesce(v.contact_phone, ''), '[^0-9]', '', 'g');
  v_phone := case
    when v_phone = '' then null
    when left(v_phone, 2) = '92' then v_phone
    when left(v_phone, 1) = '0'  then '92' || substr(v_phone, 2)
    else '92' || v_phone end;

  return jsonb_build_object(
    'school_id', p_school_id, 'school_name', v.name,
    'stage', v_stage,
    'contact_name', v.contact_name, 'phone', v.contact_phone,
    'expires_on', v_expiry, 'days_left', v_days,
    'stops_on', v_stop,
    'renewal_amount', v_amount, 'outstanding', v_owed,
    'text', v_text,
    -- The normalised number, NOT a finished wa.me URL. Building the link is the
    -- client's job here exactly as it is for the parent outbox — web/src/lib/
    -- whatsapp.ts owns that, has tests for the leading-zero and +92 cases, and
    -- percent-encoding a message body in SQL would be a second implementation of
    -- it that drifts.
    'phone_intl', v_phone,
    -- Null rather than an empty string when there is no number: a wa.me link
    -- built on '' opens WhatsApp at a blank contact picker, which reads as the
    -- software losing the message.
    'no_phone_reason', case when v_phone is null
      then 'No contact phone on record for this school — add one in the console'
      else null end);
end;
$$;

-- Recorded when the operator actually opens the chat, which is the honest claim:
-- we know a message was composed and WhatsApp was opened, and we do not know it
-- was read. The worklist shows this as "reminded 3 days ago" so nobody nags the
-- same school twice in one morning.
create or replace function public.fn_platform_mark_reminded(
  p_school_id uuid, p_stage text, p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not exists (select 1 from public.schools where id = p_school_id) then
    raise exception 'Unknown school %', p_school_id;
  end if;
  if coalesce(p_stage, '') not in ('ahead', 'due', 'today', 'grace', 'locked') then
    raise exception 'Unknown reminder stage: %', coalesce(p_stage, '(null)');
  end if;

  perform public.fn__log_operator_action('renewal_reminder', p_school_id,
    jsonb_build_object('stage', p_stage,
                       'note', nullif(btrim(coalesce(p_note, '')), ''),
                       'channel', 'whatsapp'));

  return jsonb_build_object('school_id', p_school_id, 'stage', p_stage, 'at', now());
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The school reports a transfer
-- ---------------------------------------------------------------------------
create table if not exists public.platform_payment_claims (
  id         uuid primary key default gen_random_uuid(),
  school_id  uuid not null references public.schools(id) on delete cascade,
  amount     numeric(12,2) not null check (amount > 0),
  paid_on    date not null,
  method     text not null default 'bank'
               check (method in ('bank', 'cash', 'cheque', 'online', 'other')),
  reference  text,
  from_bank  text,
  note       text,
  claimed_by uuid,
  claimed_at timestamptz not null default now(),
  status     text not null default 'pending'
               check (status in ('pending', 'confirmed', 'rejected')),
  decided_by uuid,
  decided_at timestamptz,
  decision_note text,
  -- Set when confirmed, so the claim and the money it became are one click apart
  -- in both directions.
  payment_id uuid references public.platform_payments(id) on delete set null,
  -- A decision is either fully recorded or not made. A rejected claim with no
  -- reason is a school being told no with nothing to act on.
  check (status = 'pending'
      or (decided_at is not null
          and (status = 'confirmed' or btrim(coalesce(decision_note, '')) <> '')))
);

create index if not exists idx_ppc_school on public.platform_payment_claims(school_id, claimed_at desc);
create index if not exists idx_ppc_pending on public.platform_payment_claims(claimed_at)
  where status = 'pending';

alter table public.platform_payment_claims enable row level security;

-- TWO read policies, the same shape 0074 used for operator_sessions: the
-- operator sees every claim, and a school sees its own. The school's own claim
-- is its own record and hiding it would mean it could report the same transfer
-- twice with no way to notice.
--
-- No write policy at all. A school INSERT here is the whole attack surface — a
-- row that says "we paid Rs 200,000" is not money, but a school that could
-- write `status = 'confirmed'` would be writing money.
drop policy if exists ppc_select_platform on public.platform_payment_claims;
create policy ppc_select_platform on public.platform_payment_claims
  for select to authenticated using (public.is_platform_admin());

drop policy if exists ppc_select_school on public.platform_payment_claims;
create policy ppc_select_school on public.platform_payment_claims
  for select to authenticated using (
    school_id = public.current_school_id()
    and public.may_view('owner'::public.user_role, 'principal'::public.user_role));

create or replace function public.fn_my_report_payment(
  p_amount numeric,
  p_paid_on date default null,
  p_method text default 'bank',
  p_reference text default null,
  p_from_bank text default null,
  p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_ref text := nullif(btrim(coalesce(p_reference, '')), '');
  v_on date := coalesce(p_paid_on, current_date);
  v_id uuid; v_pending integer;
begin
  if v_school is null then
    raise exception 'No school' using errcode = '42501';
  end if;
  -- has_role, not may_view: this is a WRITE, and an operator inside a read-only
  -- support session must not be able to report a payment on the school's behalf.
  -- 0074's whole design rests on has_role() staying untouched, and using it here
  -- is what makes that protection apply to this table too.
  if not public.has_role('owner'::public.user_role, 'principal'::public.user_role) then
    raise exception 'Only the owner or principal can report a payment'
      using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Enter the amount you transferred';
  end if;
  if v_on > current_date then
    raise exception 'That date is in the future';
  end if;
  if v_on < current_date - 365 then
    raise exception 'That date is more than a year ago — check it';
  end if;
  if coalesce(p_method, 'bank') not in ('bank', 'cash', 'cheque', 'online', 'other') then
    raise exception 'Unknown payment method';
  end if;

  -- Told us twice about the same transfer. Refused rather than deduplicated,
  -- because the school needs to know the first one arrived — a silent no-op
  -- reads as the form being broken and produces a phone call, which is the
  -- thing this whole screen exists to prevent.
  if v_ref is not null and exists (
    select 1 from public.platform_payment_claims
     where school_id = v_school and status = 'pending'
       and lower(btrim(coalesce(reference, ''))) = lower(v_ref)) then
    raise exception
      'You have already sent us reference % and we are checking it. '
      'We will confirm it shortly.', v_ref;
  end if;

  select count(*) into v_pending from public.platform_payment_claims
   where school_id = v_school and status = 'pending';
  if v_pending >= 5 then
    raise exception
      'There are already 5 payments waiting to be checked for this school. '
      'Please give us a day to work through them before adding more.';
  end if;

  insert into public.platform_payment_claims
    (school_id, amount, paid_on, method, reference, from_bank, note, claimed_by)
  values (v_school, round(p_amount, 2), v_on, coalesce(p_method, 'bank'),
          v_ref, nullif(btrim(coalesce(p_from_bank, '')), ''),
          nullif(btrim(coalesce(p_note, '')), ''), auth.uid())
  returning id into v_id;

  -- In the SCHOOL's own audit log, because it is the school's own action and
  -- their owner should be able to see that their accountant reported it.
  insert into public.audit_log(school_id, actor, actor_role, action, entity, entity_id, after)
  values (v_school, auth.uid(),
          (select role from public.profiles where id = auth.uid()),
          'subscription_payment_reported', 'platform_payment_claims', v_id::text,
          jsonb_build_object('amount', round(p_amount, 2), 'paid_on', v_on,
                             'method', coalesce(p_method, 'bank'), 'reference', v_ref));

  return jsonb_build_object(
    'claim_id', v_id, 'amount', round(p_amount, 2), 'paid_on', v_on,
    'status', 'pending',
    'message', 'Thank you. We will check it against our bank statement and '
               'confirm it here. Nothing stops working while we do.');
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The operator works through the claims
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_payment_claims(
  p_status text default 'pending', p_limit integer default 200
) returns table (
  id uuid, school_id uuid, school_name text, amount numeric, paid_on date,
  method text, reference text, from_bank text, note text,
  claimed_at timestamptz, claimed_by_name text,
  status text, decided_at timestamptz, decision_note text, payment_id uuid,
  outstanding numeric
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if coalesce(p_status, 'pending') not in ('pending', 'confirmed', 'rejected', 'all') then
    raise exception 'Unknown status filter: %', p_status;
  end if;
  return query
    select c.id, c.school_id, s.name, c.amount, c.paid_on, c.method, c.reference,
           c.from_bank, c.note, c.claimed_at,
           -- The name of the school's own staff member who reported it, which is
           -- who to ask when a reference does not match. A name and a role, not
           -- a login or an email.
           pr.full_name,
           c.status, c.decided_at, c.decision_note, c.payment_id,
           public.fn__platform_billed(c.school_id) - public.fn__platform_settled(c.school_id)
      from public.platform_payment_claims c
      join public.schools s on s.id = c.school_id
      left join public.profiles pr on pr.id = c.claimed_by
     where coalesce(p_status, 'pending') = 'all'
        or c.status = coalesce(p_status, 'pending')
     order by c.claimed_at desc
     limit greatest(1, least(coalesce(p_limit, 200), 1000));
end;
$$;

create or replace function public.fn_platform_confirm_claim(
  p_claim_id uuid,
  -- Null means "what they said". An explicit amount is for the case the bank
  -- statement disagrees, which happens when a school transfers net of the
  -- withholding tax and reports the gross.
  p_amount numeric default null,
  p_invoice_id uuid default null,
  p_tax_withheld numeric default 0,
  p_tax_certificate text default null,
  p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_c record; v_amt numeric; v_pay jsonb; v_pid uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into v_c from public.platform_payment_claims where id = p_claim_id;
  if not found then
    raise exception 'No such payment report';
  end if;
  if v_c.status <> 'pending' then
    raise exception 'That report was already % on %', v_c.status, v_c.decided_at::date;
  end if;

  v_amt := coalesce(p_amount, v_c.amount);
  if v_amt <= 0 then
    raise exception 'A payment must be more than zero';
  end if;

  -- Through the ordinary receipt path, so a confirmed claim and a payment the
  -- operator typed in are indistinguishable afterwards — one shape of truth in
  -- platform_payments, and the claim keeps the story of where it came from.
  v_pay := public.fn_platform_record_payment(
    v_c.school_id, v_amt, v_c.paid_on, v_c.method,
    -- The school's reference is the one on our bank statement, so it is what
    -- goes on the receipt.
    v_c.reference, p_invoice_id,
    btrim(coalesce('Reported by the school on ' || v_c.claimed_at::date || '. ', '')
          || coalesce(nullif(btrim(coalesce(p_note, '')), ''), '')),
    coalesce(p_tax_withheld, 0), p_tax_certificate);
  v_pid := (v_pay->>'payment_id')::uuid;

  update public.platform_payment_claims
     set status = 'confirmed', decided_by = auth.uid(), decided_at = now(),
         decision_note = nullif(btrim(coalesce(p_note, '')), ''),
         payment_id = v_pid
   where id = p_claim_id;

  perform public.fn__log_operator_action('payment_claim_confirmed', v_c.school_id,
    jsonb_build_object('claim_id', p_claim_id, 'payment_id', v_pid,
                       'claimed_amount', v_c.amount, 'confirmed_amount', v_amt,
                       'reference', v_c.reference));

  -- Into the SCHOOL's audit log too: they reported it, they should see it land.
  insert into public.audit_log(school_id, actor, action, entity, entity_id, after)
  values (v_c.school_id, auth.uid(), 'subscription_payment_confirmed',
          'platform_payment_claims', p_claim_id::text,
          jsonb_build_object('amount', v_amt, 'payment_id', v_pid));

  return jsonb_build_object(
    'claim_id', p_claim_id, 'status', 'confirmed',
    'payment_id', v_pid, 'amount', v_amt,
    'outstanding', v_pay->'outstanding');
end;
$$;

create or replace function public.fn_platform_reject_claim(
  p_claim_id uuid, p_reason text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_c record; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  -- The school is shown this sentence. "Rejected" with no reason is how a
  -- customer relationship breaks over a typo in a reference number.
  if v_reason is null then
    raise exception 'Say why — the school is shown this reason';
  end if;
  select * into v_c from public.platform_payment_claims where id = p_claim_id;
  if not found then
    raise exception 'No such payment report';
  end if;
  if v_c.status <> 'pending' then
    raise exception 'That report was already % on %', v_c.status, v_c.decided_at::date;
  end if;

  update public.platform_payment_claims
     set status = 'rejected', decided_by = auth.uid(), decided_at = now(),
         decision_note = v_reason
   where id = p_claim_id;

  perform public.fn__log_operator_action('payment_claim_rejected', v_c.school_id,
    jsonb_build_object('claim_id', p_claim_id, 'amount', v_c.amount,
                       'reference', v_c.reference, 'reason', v_reason));

  insert into public.audit_log(school_id, actor, action, entity, entity_id, after, reason)
  values (v_c.school_id, auth.uid(), 'subscription_payment_rejected',
          'platform_payment_claims', p_claim_id::text,
          jsonb_build_object('amount', v_c.amount, 'reference', v_c.reference),
          v_reason);

  return jsonb_build_object('claim_id', p_claim_id, 'status', 'rejected',
                            'reason', v_reason);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. The school's own Subscription screen
--
-- One call. Their licence, their documents, their balance, where to pay, and
-- what they have already told us about.
--
-- Gated on may_view rather than has_role: this is a READ, and an operator in a
-- read-only support session (0074) should be able to see exactly what the
-- principal is looking at when they phone about it. That is the entire purpose
-- of a support session, and check-readonly-writes.py permits may_view on a read
-- for precisely this reason.
-- ---------------------------------------------------------------------------
create or replace function public.fn_my_billing()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_set record; v_billed numeric; v_settled numeric;
begin
  if v_school is null then
    return jsonb_build_object('ok', false, 'reason', 'no_school');
  end if;
  if not public.may_view('owner'::public.user_role, 'principal'::public.user_role) then
    raise exception 'Only the owner or principal can see the subscription bill'
      using errcode = '42501';
  end if;

  select * into v_set from public.platform_settings where id;
  v_billed  := public.fn__platform_billed(v_school);
  v_settled := public.fn__platform_settled(v_school);

  return jsonb_build_object(
    'ok', true,
    -- Reused rather than restated: whatever fn_my_licence says about status,
    -- days left and the limit is what the banner says, and two screens
    -- disagreeing about whether a licence is expiring is worse than either.
    'licence', public.fn_my_licence(),

    'balance', jsonb_build_object(
      'billed', v_billed, 'paid', v_settled, 'outstanding', v_billed - v_settled),

    -- Their own documents. doc_no is what they quote back to us, which is the
    -- point of 0077.
    'documents', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', i.id, 'doc_no', i.doc_no, 'kind', i.kind,
               'issued_on', i.issued_on, 'due_on', i.due_on,
               'plan_code', i.plan_code,
               'period_start', i.period_start, 'period_end', i.period_end,
               'months', i.months,
               'amount', i.amount, 'tax_amount', i.tax_amount,
               'total', i.amount + i.tax_amount,
               'voided', i.voided_at is not null,
               'paid', coalesce((select sum(pm.settled) from public.platform_payments pm
                                  where pm.invoice_id = i.id), 0),
               'note', i.note)
             order by i.issued_on desc, i.serial desc)
        from public.platform_invoices i where i.school_id = v_school), '[]'::jsonb),

    'payments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'paid_on', p.paid_on, 'amount', p.amount, 'method', p.method,
               'reference', p.reference, 'tax_withheld', p.tax_withheld,
               'tax_certificate', p.tax_certificate)
             order by p.paid_on desc, p.created_at desc)
        from public.platform_payments p where p.school_id = v_school), '[]'::jsonb),

    -- What they have told us and what came of it, including the reason a report
    -- was rejected. A school that cannot see why is a school that phones.
    'reports', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'amount', c.amount, 'paid_on', c.paid_on,
               'method', c.method, 'reference', c.reference,
               'claimed_at', c.claimed_at, 'status', c.status,
               'decided_at', c.decided_at, 'decision_note', c.decision_note)
             order by c.claimed_at desc)
        from public.platform_payment_claims c where c.school_id = v_school), '[]'::jsonb),

    -- An ALLOW-LIST of the vendor's settings, not the row. See the header.
    'pay_to', jsonb_build_object(
      'business_name', nullif(btrim(coalesce(v_set.business_name, '')), ''),
      'bank_name', v_set.bank_name, 'title', v_set.bank_title,
      'account', v_set.bank_account, 'iban', v_set.bank_iban,
      'support_phone', v_set.phone, 'support_email', v_set.email,
      'online_available', coalesce(v_set.gateway_enabled, false)),

    -- Stated rather than implied: a screen with a bank account and no
    -- instruction is a screen somebody transfers money from and then phones
    -- about anyway.
    'how_to_pay', case when coalesce(v_set.gateway_enabled, false)
      then 'Pay online from this screen, or transfer to the account above and '
           'tell us the reference.'
      else 'Transfer to the account above from any bank or app, then use "I have '
           'paid" below to tell us the reference. We check it against our '
           'statement and confirm it here — usually the same day.' end);
end;
$$;

-- A printable copy of one of their own documents. The ownership check is the
-- whole function: fn__invoice_document takes an id and answers, so this is the
-- only thing standing between a school and another school's invoice.
create or replace function public.fn_my_platform_invoice(p_invoice_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if v_school is null then
    raise exception 'No school' using errcode = '42501';
  end if;
  if not public.may_view('owner'::public.user_role, 'principal'::public.user_role) then
    raise exception 'Only the owner or principal can see the subscription bill'
      using errcode = '42501';
  end if;
  if not exists (select 1 from public.platform_invoices
                  where id = p_invoice_id and school_id = v_school) then
    raise exception 'No such invoice' using errcode = '42501';
  end if;
  return public.fn__invoice_document(p_invoice_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------------
grant  execute on function public.fn_platform_due_soon(integer)   to authenticated;
revoke execute on function public.fn_platform_due_soon(integer) from public, anon;
grant  execute on function public.fn_platform_renewal_message(uuid, text)   to authenticated;
revoke execute on function public.fn_platform_renewal_message(uuid, text) from public, anon;
grant  execute on function public.fn_platform_mark_reminded(uuid, text, text)   to authenticated;
revoke execute on function public.fn_platform_mark_reminded(uuid, text, text) from public, anon;
grant  execute on function public.fn_platform_payment_claims(text, integer)   to authenticated;
revoke execute on function public.fn_platform_payment_claims(text, integer) from public, anon;
grant  execute on function
  public.fn_platform_confirm_claim(uuid, numeric, uuid, numeric, text, text) to authenticated;
revoke execute on function
  public.fn_platform_confirm_claim(uuid, numeric, uuid, numeric, text, text) from public, anon;
grant  execute on function public.fn_platform_reject_claim(uuid, text)   to authenticated;
revoke execute on function public.fn_platform_reject_claim(uuid, text) from public, anon;
grant  execute on function
  public.fn_my_report_payment(numeric, date, text, text, text, text) to authenticated;
revoke execute on function
  public.fn_my_report_payment(numeric, date, text, text, text, text) from public, anon;
grant  execute on function public.fn_my_billing()   to authenticated;
revoke execute on function public.fn_my_billing() from public, anon;
grant  execute on function public.fn_my_platform_invoice(uuid)   to authenticated;
revoke execute on function public.fn_my_platform_invoice(uuid) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0079_school_lifecycle.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0079 — A school could be started and never stopped
--
-- Phase 4 of docs/SUPER-ADMIN-DESIGN.md, first of two. 0080 does the ending;
-- this does everything up to it.
--
-- FOUR DEFECTS, reproduced on a real database.
--
-- 1. LOCKING IS PURELY CALENDAR-DRIVEN
--
--    fn_effective_status derives everything from trial_ends_on, period_end and
--    grace_days(). So a school that has stopped paying, stopped answering the
--    phone, and told a competitor it is switching stays fully live until its
--    renewal date — which may be eleven months away, because the operator
--    granted the year on trust.
--
--    There is no way to stop it. The only lever is fn_activate_subscription,
--    which only ever grants MORE time, and a direct UPDATE that RLS refuses.
--    Reproduced: no function in the schema can move a live school out of
--    'active' before its period_end.
--
-- 2. THE SAME CALENDAR, FOR EVERY SCHOOL
--
--    grace_days() is a global 14. Two real cases it gets wrong in opposite
--    directions: the school that has paid on time for three years and whose
--    accountant is on Hajj (14 days is not enough, and locking them is
--    self-harm), and the school that has needed chasing every single quarter
--    (14 days is a habit we are subsidising).
--
--    Per-school, with a reason recorded, or it becomes a favour nobody can
--    explain later.
--
-- 3. A SUSPENDED SCHOOL WOULD NOT KNOW WHY
--
--    This is the part that decides whether suspending is usable. A school whose
--    software stops with no explanation phones in a panic, and the person
--    answering is the person who suspended it. So `suspend_reason` is NOT an
--    operator note: fn_my_licence returns it and the banner shows it. If we are
--    going to stop somebody working, they get told why by the software, in the
--    same breath.
--
-- 4. A SCHOOL IS PERMANENT
--
--    34 tables reference public.schools with ON DELETE NO ACTION, and the
--    console lists every row in `schools` unconditionally. A demo school, a
--    school that never completed signup, a customer who left in 2027 — all
--    permanently in the list, forever, with nothing to distinguish them from
--    live customers.
--
--    Archive is the reversible half and the right default: hidden from the
--    console, licence dead, data completely intact. 0080 does the irreversible
--    half.
--
-- WHY NO NEW ENUM VALUE
--
-- The obvious modelling is `alter type subscription_status add value 'suspended'`.
-- Two reasons not to:
--
--   * ALTER TYPE ... ADD VALUE cannot be used in the same transaction that adds
--     it, and this project applies each bundle as ONE transaction (CI asserts
--     that). The migration would fail on its own next statement.
--
--   * 'locked' already means exactly the right thing: reading and exporting
--     never stop, new entries do. A suspended school needs identical BEHAVIOUR
--     and a different EXPLANATION, and an explanation is a text column, not an
--     enum member. Everything that switches on the enum keeps working untouched.
--
-- So suspension is `suspended_at` + `suspend_reason` on the subscription, and
-- fn_effective_status returns 'locked' while it is set. The operator console
-- and the school's own banner both distinguish the two, because both read the
-- reason.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------
alter table public.subscriptions
  add column if not exists suspended_at    timestamptz,
  add column if not exists suspended_by    uuid,
  add column if not exists suspend_reason  text,
  -- Null means "use grace_days()". An explicit number overrides it for this
  -- school only, and requires a reason for the same argument 0064 makes about
  -- a discount: a favour that leaves no trace is how a business loses track of
  -- what it has given away.
  add column if not exists grace_days_override integer,
  add column if not exists grace_override_reason text;

alter table public.schools
  add column if not exists archived_at    timestamptz,
  add column if not exists archived_by    uuid,
  add column if not exists archive_reason text;

do $ddl$
begin
  -- Suspended with no reason is the state this migration exists to prevent —
  -- see defect 3. Enforced rather than merely intended.
  if not exists (select 1 from pg_constraint where conname = 'subscriptions_suspend_chk') then
    alter table public.subscriptions add constraint subscriptions_suspend_chk
      check ((suspended_at is null and suspend_reason is null)
          or (suspended_at is not null and btrim(coalesce(suspend_reason, '')) <> ''));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'subscriptions_grace_override_chk') then
    alter table public.subscriptions add constraint subscriptions_grace_override_chk
      check (grace_days_override is null
          or (grace_days_override between 0 and 180
              and btrim(coalesce(grace_override_reason, '')) <> ''));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'schools_archive_chk') then
    alter table public.schools add constraint schools_archive_chk
      check ((archived_at is null and archive_reason is null)
          or (archived_at is not null and btrim(coalesce(archive_reason, '')) <> ''));
  end if;
end $ddl$;

create index if not exists idx_schools_live on public.schools(name)
  where archived_at is null;

-- ---------------------------------------------------------------------------
-- 2. The status derivation
--
-- Two changes and nothing else: a manual suspension wins over the calendar, and
-- the grace window can be per school. The trial/active/grace/locked ladder is
-- untouched — 0026 argued it carefully and this is not the migration to
-- relitigate it.
-- ---------------------------------------------------------------------------
create or replace function public.fn_effective_status(p_school_id uuid)
returns public.subscription_status
language sql stable security definer set search_path = public as $$
  select case
    -- Suspended by hand beats every date. It is the only state an operator can
    -- put a school into directly, and it must not be undone by the calendar
    -- rolling forward.
    when s.suspended_at is not null then 'locked'::public.subscription_status
    when s.status = 'cancelled' then 'cancelled'::public.subscription_status
    -- Trial: live until it ends, then straight to locked (no grace on a trial —
    -- nothing has been paid, so there is no payment in flight to wait for).
    when s.status = 'trialing' then
      case when current_date <= coalesce(s.trial_ends_on, current_date)
           then 'trialing'::public.subscription_status
           else 'locked'::public.subscription_status
      end
    -- Paid: live to period_end, then grace, then locked.
    when s.period_end is null then s.status
    when current_date <= s.period_end then 'active'::public.subscription_status
    when current_date <= s.period_end
                       + coalesce(s.grace_days_override, public.grace_days())
      then 'grace'::public.subscription_status
    else 'locked'::public.subscription_status
  end
  from public.subscriptions s
  where s.school_id = p_school_id;
$$;

-- ---------------------------------------------------------------------------
-- 3. The school is told why
--
-- Rewritten in place rather than restated: fn_my_licence is 90 lines that 0068
-- argued through in detail, and copying it here to add three keys would leave
-- two versions of that argument in the repository. The END STATE is asserted.
-- ---------------------------------------------------------------------------
do $rewrite$
declare v_src text; v_new text;
begin
  v_src := pg_get_functiondef('public.fn_my_licence()'::regprocedure);
  v_new := v_src;

  -- (a) the three new keys, inserted before limit_state so the reason sits
  --     beside the status it explains.
  v_new := replace(v_new,
    E'    -- The truth, always, whatever we choose to say out loud.',
    E'    -- Suspended by hand, and WHY. A school whose software stops with no\n'
    || E'    -- explanation phones in a panic, and the person answering is the person\n'
    || E'    -- who suspended it. 0079 makes the reason mandatory at the database so\n'
    || E'    -- this key can never be null while `suspended` is true.\n'
    || E'    ''suspended'',      v_sub.suspended_at is not null,\n'
    || E'    ''suspended_on'',   v_sub.suspended_at,\n'
    || E'    ''suspend_reason'', v_sub.suspend_reason,\n'
    || E'    -- The grace window that actually applies to THIS school, so the\n'
    || E'    -- banner can say "until the 28th" and be right for the school that\n'
    || E'    -- was given longer.\n'
    || E'    ''grace_days'',     coalesce(v_sub.grace_days_override, public.grace_days()),\n'
    || E'    -- The truth, always, whatever we choose to say out loud.');

  -- (b) the grace expiry must use the same per-school window, or the school is
  --     told a date the software will not honour.
  v_new := replace(v_new,
    'when v_status = ''grace''    then v_sub.period_end + public.grace_days()',
    'when v_status = ''grace''    then v_sub.period_end'
      || ' + coalesce(v_sub.grace_days_override, public.grace_days())');

  if v_new <> v_src then
    execute v_new;
  end if;

  v_src := pg_get_functiondef('public.fn_my_licence()'::regprocedure);
  if position('''suspend_reason''' in v_src) = 0 then
    raise exception '0079: fn_my_licence does not tell a suspended school why — the text it was matched on has changed. Fix the rewrite in 0079.';
  end if;
  if position('coalesce(v_sub.grace_days_override' in v_src) = 0 then
    raise exception '0079: fn_my_licence still uses the global grace window, so a school given longer would be told the wrong date';
  end if;
  raise notice '0079: fn_my_licence now explains a suspension';
end $rewrite$;

-- ---------------------------------------------------------------------------
-- 4. Suspend, and put it back
--
-- Deliberately NOT called "lock". Lock is what the calendar does; this is what a
-- person does, and the two need different words in the console or the operator
-- will not be able to tell why a school stopped.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_suspend_school(
  p_school_id uuid, p_reason text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_name text; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  -- The school is SHOWN this. Not an internal note.
  if v_reason is null then
    raise exception 'Give a reason — the school is shown it on their own screen';
  end if;
  select name into v_name from public.schools where id = p_school_id;
  if v_name is null then
    raise exception 'Unknown school %', p_school_id;
  end if;
  if not exists (select 1 from public.subscriptions where school_id = p_school_id) then
    raise exception '% has no subscription to suspend', v_name;
  end if;
  if exists (select 1 from public.subscriptions
              where school_id = p_school_id and suspended_at is not null) then
    raise exception '% is already suspended', v_name;
  end if;

  update public.subscriptions
     set suspended_at = now(), suspended_by = auth.uid(), suspend_reason = v_reason
   where school_id = p_school_id;

  perform public.fn__log_operator_action('school_suspended', p_school_id,
    jsonb_build_object('reason', v_reason));

  -- In the SCHOOL's own audit log too. They are entitled to a record of the
  -- vendor stopping their software, with a date and a reason, that we cannot
  -- later be vague about.
  insert into public.audit_log(school_id, actor, action, entity, entity_id, reason)
  values (p_school_id, auth.uid(), 'subscription_suspended', 'subscriptions',
          p_school_id::text, v_reason);

  return jsonb_build_object(
    'school_id', p_school_id, 'suspended', true, 'reason', v_reason,
    -- Stated in the return value so the console can say it in the confirmation
    -- rather than the operator having to remember it.
    'what_still_works', 'They can still open every screen, print and export. '
      || 'Only new entries are paused.');
end;
$$;

create or replace function public.fn_platform_unsuspend_school(
  p_school_id uuid, p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_was text; v_since timestamptz;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select suspend_reason, suspended_at into v_was, v_since
    from public.subscriptions where school_id = p_school_id;
  if v_since is null then
    raise exception 'That school is not suspended';
  end if;

  update public.subscriptions
     set suspended_at = null, suspended_by = null, suspend_reason = null
   where school_id = p_school_id;

  -- The reason it was suspended is carried into the log entry that lifts it.
  -- Clearing the column would otherwise erase the only record of why, and
  -- "unsuspended" with no context is useless six months later.
  perform public.fn__log_operator_action('school_unsuspended', p_school_id,
    jsonb_build_object('was_suspended_on', v_since, 'was_reason', v_was,
                       'note', nullif(btrim(coalesce(p_note, '')), ''),
                       'days_suspended', (current_date - v_since::date)));

  insert into public.audit_log(school_id, actor, action, entity, entity_id, before, reason)
  values (p_school_id, auth.uid(), 'subscription_unsuspended', 'subscriptions',
          p_school_id::text, jsonb_build_object('suspend_reason', v_was),
          nullif(btrim(coalesce(p_note, '')), ''));

  return jsonb_build_object('school_id', p_school_id, 'suspended', false,
                            'status', public.fn_effective_status(p_school_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Cancel, and un-cancel
--
-- Cancelled is the end of the commercial relationship while the data stays
-- exactly where it is. It is NOT archive (which hides the school) and NOT purge
-- (which destroys it) — a school that cancels in June and comes back in August
-- must find everything as it was, which happens more often than not.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_cancel_subscription(
  p_school_id uuid, p_reason text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_reason text := nullif(btrim(coalesce(p_reason, '')), ''); v_owed numeric;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_reason is null then
    raise exception 'Say why they cancelled — it is the only churn data this business will ever have';
  end if;
  if not exists (select 1 from public.subscriptions where school_id = p_school_id) then
    raise exception 'Unknown school %', p_school_id;
  end if;

  v_owed := public.fn__platform_billed(p_school_id) - public.fn__platform_settled(p_school_id);

  update public.subscriptions set status = 'cancelled' where school_id = p_school_id;

  perform public.fn__log_operator_action('subscription_cancelled', p_school_id,
    jsonb_build_object('reason', v_reason, 'outstanding_at_cancellation', v_owed));

  insert into public.audit_log(school_id, actor, action, entity, entity_id, reason)
  values (p_school_id, auth.uid(), 'subscription_cancelled', 'subscriptions',
          p_school_id::text, v_reason);

  return jsonb_build_object(
    'school_id', p_school_id, 'status', 'cancelled',
    -- Cancelling does not write off a debt, and the console must not imply it
    -- has. An invoice stays owed until it is paid, credited or voided.
    'outstanding', v_owed,
    'note', case when v_owed > 0
      then format('They still owe %s. Cancelling does not write that off — raise a '
                  || 'credit note if you are forgiving it.',
                  to_char(v_owed, 'FM999,999,999.00'))
      else 'Nothing outstanding.' end,
    'data', 'Their data is untouched and they keep read and export access. '
      || 'Archive them to hide them from this list.');
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. A different grace window for one school
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_set_grace(
  p_school_id uuid, p_days integer, p_reason text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not exists (select 1 from public.subscriptions where school_id = p_school_id) then
    raise exception 'Unknown school %', p_school_id;
  end if;
  -- Null days = back to the standard window, and that needs no justification.
  -- Anything else does: a longer grace period is a favour, a shorter one is
  -- pressure, and both should be explainable a year later.
  if p_days is not null and v_reason is null then
    raise exception 'A different grace period for one school needs a reason';
  end if;
  if p_days is not null and (p_days < 0 or p_days > 180) then
    raise exception 'A grace period must be between 0 and 180 days';
  end if;

  update public.subscriptions
     set grace_days_override = p_days,
         grace_override_reason = case when p_days is null then null else v_reason end
   where school_id = p_school_id;

  perform public.fn__log_operator_action('grace_changed', p_school_id,
    jsonb_build_object('days', p_days, 'standard', public.grace_days(),
                       'reason', v_reason));

  return jsonb_build_object(
    'school_id', p_school_id,
    'grace_days', coalesce(p_days, public.grace_days()),
    'is_override', p_days is not null,
    'status', public.fn_effective_status(p_school_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Archive: out of the list, data intact
--
-- The reversible half of offboarding and the right default. 0080 does the
-- irreversible half, and it refuses to run on a school that has not been
-- archived first — so archiving is also the deliberate pause between "we are
-- done with this customer" and "destroy their records".
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_archive_school(
  p_school_id uuid, p_reason text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_name text; v_reason text := nullif(btrim(coalesce(p_reason, '')), ''); v_owed numeric;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_reason is null then
    raise exception 'Say why this school is being archived';
  end if;
  select name into v_name from public.schools where id = p_school_id;
  if v_name is null then
    raise exception 'Unknown school %', p_school_id;
  end if;
  if exists (select 1 from public.schools
              where id = p_school_id and archived_at is not null) then
    raise exception '% is already archived', v_name;
  end if;

  v_owed := public.fn__platform_billed(p_school_id) - public.fn__platform_settled(p_school_id);

  update public.schools
     set archived_at = now(), archived_by = auth.uid(), archive_reason = v_reason,
         -- `active` is what fn_platform_due_soon already filters on, so setting
         -- it here is what stops an archived school appearing on the renewal
         -- worklist. Two flags rather than one because they answer different
         -- questions: active is "should we chase them", archived is "should we
         -- show them at all".
         active = false
   where id = p_school_id;

  -- Cancelled as well, unless they were already. An archived school with a live
  -- licence is a school still counted in the paying total.
  update public.subscriptions set status = 'cancelled'
   where school_id = p_school_id and status <> 'cancelled';

  perform public.fn__log_operator_action('school_archived', p_school_id,
    jsonb_build_object('reason', v_reason, 'outstanding', v_owed));

  insert into public.audit_log(school_id, actor, action, entity, entity_id, reason)
  values (p_school_id, auth.uid(), 'school_archived', 'schools',
          p_school_id::text, v_reason);

  return jsonb_build_object(
    'school_id', p_school_id, 'archived', true,
    'outstanding', v_owed,
    -- Every one of these is a thing somebody will assume happened. Stating them
    -- costs a sentence; discovering them costs a customer.
    'what_this_did', jsonb_build_array(
      'Hidden from the school list and the renewal worklist',
      'Licence cancelled — their staff can still sign in, read, print and export',
      'Nothing was deleted, and nothing was exported'),
    'reversible', true);
end;
$$;

create or replace function public.fn_platform_unarchive_school(p_school_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_was text; v_since timestamptz;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select archive_reason, archived_at into v_was, v_since
    from public.schools where id = p_school_id;
  if v_since is null then
    raise exception 'That school is not archived';
  end if;

  update public.schools
     set archived_at = null, archived_by = null, archive_reason = null, active = true
   where id = p_school_id;

  perform public.fn__log_operator_action('school_unarchived', p_school_id,
    jsonb_build_object('was_archived_on', v_since, 'was_reason', v_was));

  return jsonb_build_object(
    'school_id', p_school_id, 'archived', false,
    -- Deliberately NOT reactivated. Unarchiving makes a school visible again;
    -- deciding what licence they get is a separate, priced decision and doing
    -- it silently here would give away a year.
    'note', 'Visible again, and still cancelled. Activate or renew them to give '
      || 'them a licence.');
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. The console list learns about all of it
--
-- DROP first: three columns and a parameter. Archived schools are excluded by
-- DEFAULT rather than by the caller remembering to ask — a console that shows
-- last year's departed customers alongside this year's is a console whose
-- totals nobody trusts.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_platform_schools();
drop function if exists public.fn_platform_schools(boolean);
create function public.fn_platform_schools(p_include_archived boolean default false)
returns table (
  school_id uuid, school_name text, city text,
  contact_name text, contact_phone text,
  plan_code text, status public.subscription_status,
  expires_on date, days_left integer,
  student_count integer, student_limit integer,
  limit_state text, suggested_plan text, needs_upgrade boolean,
  outstanding numeric, last_paid_on date,
  suspended boolean, suspend_reason text, archived boolean
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
    select
      s.id, s.name, s.city, s.contact_name, s.contact_phone,
      sub.plan_code,
      public.fn_effective_status(s.id),
      case when sub.status = 'trialing' then sub.trial_ends_on else sub.period_end end,
      (case when sub.status = 'trialing' then sub.trial_ends_on else sub.period_end end
        - current_date)::integer,
      sub.student_count,
      p.student_limit,
      case
        when p.student_limit is null then 'ok'
        when sub.student_count <= p.student_limit then 'ok'
        when sub.student_count <= public.plan_margin_limit(p.student_limit) then 'within_margin'
        else 'over' end,
      sug.code,
      sug.code is distinct from sub.plan_code,
      public.fn__platform_billed(s.id) - public.fn__platform_settled(s.id),
      (select max(pm.paid_on) from public.platform_payments pm
        where pm.school_id = s.id),
      -- `status` reads 'locked' for a suspended school and for an expired one.
      -- These two columns are what let the console tell them apart, which is the
      -- whole reason 0079 does not add an enum value.
      sub.suspended_at is not null,
      sub.suspend_reason,
      s.archived_at is not null
    from public.schools s
    join public.subscriptions sub on sub.school_id = s.id
    join public.plans p on p.code = sub.plan_code
    cross join lateral (
      select p2.code from public.plans p2
       where p2.active and (p2.student_limit is null or p2.student_limit >= sub.student_count)
       order by p2.sort_order limit 1
    ) sug
   where coalesce(p_include_archived, false) or s.archived_at is null
   order by s.name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Provisioning from the console
--
-- fn_provision_school (0026) takes six positional text arguments, always gives
-- exactly 14 days, and cannot record a note. Replaced rather than extended: a
-- seventh positional text parameter on a function whose first six are all text
-- is a call site waiting to be got wrong.
--
-- It does NOT create the owner login — that needs the service_role key to mint
-- an auth user, which must never reach a browser. The Edge Function
-- `provision-school` calls this and then creates the owner, exactly as
-- `signup-school` does for self-signup. What this returns is the school and a
-- plain statement of what is still missing, so a school created here and left
-- without an owner cannot look finished.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_create_school(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_name text; v_plan text; v_days integer; v_trial date;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'Give the school''s details';
  end if;

  v_name := nullif(btrim(coalesce(p->>'name', '')), '');
  if v_name is null then
    raise exception 'The school name is required';
  end if;
  -- Same name twice is almost always the operator not realising it is already
  -- there. Refused with the id, so they can go and look rather than guess.
  if exists (select 1 from public.schools
              where lower(btrim(name)) = lower(v_name) and archived_at is null) then
    raise exception 'A school called "%" already exists (%). Archive it first if this is a different one.',
      v_name, (select id from public.schools
                where lower(btrim(name)) = lower(v_name) and archived_at is null limit 1);
  end if;

  v_plan := coalesce(nullif(btrim(coalesce(p->>'plan_code', '')), ''), 'starter');
  if not exists (select 1 from public.plans where code = v_plan) then
    raise exception 'Unknown plan %', v_plan;
  end if;

  v_days := coalesce((p->>'trial_days')::integer, 14);
  if v_days < 0 or v_days > 180 then
    raise exception 'A trial must be between 0 and 180 days';
  end if;
  v_trial := current_date + v_days;

  insert into public.schools (name, city, contact_name, contact_phone, contact_email, notes)
  values (v_name,
          nullif(btrim(coalesce(p->>'city', '')), ''),
          nullif(btrim(coalesce(p->>'contact_name', '')), ''),
          nullif(btrim(coalesce(p->>'contact_phone', '')), ''),
          nullif(btrim(lower(coalesce(p->>'contact_email', ''))), ''),
          nullif(btrim(coalesce(p->>'notes', '')), ''))
  returning id into v_id;

  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
  values (v_id, v_plan, 'trialing', v_trial);

  return jsonb_build_object(
    'school_id', v_id, 'name', v_name, 'plan_code', v_plan,
    'trial_ends_on', v_trial, 'trial_days', v_days,
    -- Stated, not implied. A school row with no owner login is invisible from
    -- the school's side: nobody can sign in, and the console would show it as a
    -- perfectly ordinary trialing customer.
    'still_needed', 'Nobody can sign in to this school yet. Create the owner '
      || 'login, or send them the signup link.');
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Grants
-- ---------------------------------------------------------------------------
grant  execute on function public.fn_platform_schools(boolean)   to authenticated;
revoke execute on function public.fn_platform_schools(boolean) from public, anon;
grant  execute on function public.fn_platform_suspend_school(uuid, text)   to authenticated;
revoke execute on function public.fn_platform_suspend_school(uuid, text) from public, anon;
grant  execute on function public.fn_platform_unsuspend_school(uuid, text)   to authenticated;
revoke execute on function public.fn_platform_unsuspend_school(uuid, text) from public, anon;
grant  execute on function public.fn_platform_cancel_subscription(uuid, text)   to authenticated;
revoke execute on function public.fn_platform_cancel_subscription(uuid, text) from public, anon;
grant  execute on function public.fn_platform_set_grace(uuid, integer, text)   to authenticated;
revoke execute on function public.fn_platform_set_grace(uuid, integer, text) from public, anon;
grant  execute on function public.fn_platform_archive_school(uuid, text)   to authenticated;
revoke execute on function public.fn_platform_archive_school(uuid, text) from public, anon;
grant  execute on function public.fn_platform_unarchive_school(uuid)   to authenticated;
revoke execute on function public.fn_platform_unarchive_school(uuid) from public, anon;
grant  execute on function public.fn_platform_create_school(jsonb)   to authenticated;
revoke execute on function public.fn_platform_create_school(jsonb) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0080_offboarding.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0080 — A school could never leave
--
-- Phase 4 of docs/SUPER-ADMIN-DESIGN.md, second of two, and the last thing this
-- product could not do at all.
--
-- THE DEFECT
--
-- 37 tables reference public.schools with ON DELETE NO ACTION. So
--
--   delete from public.schools where id = '…';
--
-- fails on the first foreign key it meets, and there is no function anywhere in
-- the schema that removes a school. A demo school created to show somebody the
-- software is permanent. A school that signed up, never uploaded a student and
-- went quiet is permanent. A customer who left in 2027 and asked for their data
-- to be deleted is permanent, and the answer to them is "we cannot".
--
-- Reproduced: the delete above raises
--   update or delete on table "schools" violates foreign key constraint
--   "academic_sessions_school_id_fkey" on table "academic_sessions"
--
-- THREE STEPS, AND THE ORDER IS THE SAFETY
--
--   1. ARCHIVE   0079. Hidden, licence dead, data intact, reversible.
--   2. EXPORT    everything they own, as JSON, one table at a time. Given to
--                them, and kept as our own record that it was taken.
--   3. PURGE     irreversible, and refused unless 1 and 2 have happened and the
--                operator types the school's name.
--
-- Nothing here can be reached by accident. Each step refuses until the previous
-- one is done, and the last one refuses until somebody has typed a name.
--
-- WHERE THE READ BOUNDARY MOVES, STATED PLAINLY
--
-- The export returns EVERY ROW of a school's data: children's names, guardians'
-- phone numbers, marks, payments. That is far beyond what
-- fn_platform_school_detail (0075) allows, which is counts and dates and
-- nothing about a person.
--
-- The line that keeps it defensible is that the export REFUSES on a school that
-- is not archived. Archiving is a deliberate act with a mandatory reason, logged
-- in the operator's history and in the school's own audit trail, and it is
-- reversible — so a bulk pull of a live customer's records is not something this
-- function can be used for. A live school that wants its data has its own Backup
-- screen, which is where that belongs.
--
-- Every export is recorded in platform_exports with the row counts, and that row
-- SURVIVES the purge (school_id becomes null, the name is denormalised). If a
-- school ever says "you deleted our records", the answer is a dated row saying
-- what was handed over first.
--
-- OUR OWN SALES LEDGER SURVIVES, AND THAT NEEDED A SCHEMA CHANGE
--
-- 0064 gave platform_invoices and platform_payments `on delete cascade`, so
-- purging a school would have destroyed our own invoices to it. That is wrong
-- twice over: a business keeps its sales ledger after a customer leaves, and
-- under the Income Tax Ordinance those records have to be retained for years
-- after the transaction. A purge in 2028 must not make the 2027 tax year
-- unauditable.
--
-- So both tables lose the cascade, gain a nullable school_id with ON DELETE SET
-- NULL, and carry the school's NAME denormalised — set by the same BEFORE INSERT
-- trigger that numbers the document (0077), so an orphaned invoice can still say
-- who it was for. Every total in the product filters on school_id, so an
-- orphaned row simply stops matching any school without any of them changing.
--
-- The one thing that DOES go with the school is the school's own audit_log: it
-- is their record of their own staff's actions, it is their data, and a request
-- to delete their data means it too.
--
-- WHY THE PURGE DOES NOT LIST ITS TABLES
--
-- A hardcoded delete order is wrong the day somebody adds a table. This deletes
-- from the CATALOGUE — every table in public with a school_id — and retries
-- until a pass makes no progress, because the dependency order between them
-- (payment_allocations before payments, invoice_lines before invoices) is
-- already recorded in the foreign keys. If it stalls it raises and names exactly
-- what is left, rather than half-deleting a school and reporting success.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Our own ledger must outlive the customer
--
-- See the header. Done first because the purge below depends on it.
-- ---------------------------------------------------------------------------
alter table public.platform_invoices
  add column if not exists school_name text;
alter table public.platform_payments
  add column if not exists school_name text;

do $keep$
declare r record;
begin
  -- Backfill the names before dropping the NOT NULL, so no existing row ends up
  -- orphaned AND anonymous.
  update public.platform_invoices i set school_name = s.name
    from public.schools s where s.id = i.school_id and i.school_name is null;
  update public.platform_payments p set school_name = s.name
    from public.schools s where s.id = p.school_id and p.school_name is null;

  alter table public.platform_invoices alter column school_id drop not null;
  alter table public.platform_payments alter column school_id drop not null;

  -- Replace the cascade with set-null. Named explicitly rather than looked up:
  -- if a future migration renames these constraints this block must fail loudly
  -- rather than silently leave a cascade in place, which would delete our own
  -- invoices the next time a school was purged.
  for r in
    select 'platform_invoices' as t, 'platform_invoices_school_id_fkey' as c
    union all
    select 'platform_payments', 'platform_payments_school_id_fkey'
  loop
    if not exists (select 1 from pg_constraint where conname = r.c) then
      raise exception '0080: expected constraint % on % — it has been renamed, and '
        'this migration cannot safely change what it cannot find', r.c, r.t;
    end if;
    if (select confdeltype from pg_constraint where conname = r.c) <> 'n' then
      execute format('alter table public.%I drop constraint %I', r.t, r.c);
      execute format('alter table public.%I add constraint %I foreign key (school_id) '
                     'references public.schools(id) on delete set null', r.t, r.c);
      raise notice '0080: %.school_id no longer cascades — our ledger survives a purge', r.t;
    end if;
  end loop;
end $keep$;

-- The name is stamped at INSERT by the same trigger that numbers the document.
-- Rewritten in place rather than restated, and the end state asserted.
do $stamp$
declare v_src text; v_new text;
begin
  v_src := pg_get_functiondef('public.fn__assign_doc_no()'::regprocedure);
  -- WHITESPACE-BLIND, and it was not. The pattern used to be an E'...' string
  -- carrying this file's own line endings, so it matched only a stored body
  -- that had arrived by the same route. 0101 shipped the same assumption in a
  -- form that could not agree with anything and took all seven migrations of
  -- bundle 12 down on a live school. Line breaks in the pattern are `\s+` now;
  -- supabase/check-patch-anchors.py fails the build if this is written the old
  -- way again.
  v_new := regexp_replace(v_src,
    'if new\.doc_no is not null and new\.serial is not null then\s+'
      || 'return new;\s+end if;',
    '-- The school''s name, kept on the document itself. 0080 lets an invoice'
    || chr(10) || '  -- outlive the school it was raised against, and an invoice that cannot say'
    || chr(10) || '  -- who it was for is not a business record.'
    || chr(10) || '  if new.school_name is null then'
    || chr(10) || '    select s.name into new.school_name from public.schools s where s.id = new.school_id;'
    || chr(10) || '  end if;'
    || chr(10) || '  if new.doc_no is not null and new.serial is not null then'
    || chr(10) || '    return new;'
    || chr(10) || '  end if;');
  if v_new <> v_src then
    execute v_new;
  end if;
  if position('new.school_name' in
      pg_get_functiondef('public.fn__assign_doc_no()'::regprocedure)) = 0 then
    raise exception '0080: fn__assign_doc_no does not stamp the school name — the text it was matched on has changed';
  end if;
end $stamp$;

-- Payments have no numbering trigger, so they get their own one-line one.
create or replace function public.fn__stamp_payment_school_name()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.school_name is null then
    select s.name into new.school_name from public.schools s where s.id = new.school_id;
  end if;
  return new;
end;
$$;

revoke all on function public.fn__stamp_payment_school_name() from public, anon, authenticated;

drop trigger if exists trg_stamp_payment_school_name on public.platform_payments;
create trigger trg_stamp_payment_school_name
  before insert on public.platform_payments
  for each row execute function public.fn__stamp_payment_school_name();

-- ---------------------------------------------------------------------------
-- 1. The record that survives
-- ---------------------------------------------------------------------------
create table if not exists public.platform_exports (
  id           uuid primary key default gen_random_uuid(),
  -- Nullable, and ON DELETE SET NULL. The whole point of this row is to outlive
  -- the school it describes: after a purge there is no school_id to point at,
  -- and the row must still say what was handed over and when.
  school_id    uuid references public.schools(id) on delete set null,
  school_name  text not null,
  taken_at     timestamptz not null default now(),
  taken_by     uuid,
  taken_by_email text,
  counts       jsonb not null default '{}'::jsonb,
  total_rows   integer not null default 0,
  note         text
);

create index if not exists idx_platform_exports_school
  on public.platform_exports(school_id, taken_at desc);

alter table public.platform_exports enable row level security;

-- Operator only, and read-only through RLS: the row is written by
-- fn_platform_record_export so a "we exported it" claim cannot be typed in
-- after the fact.
drop policy if exists platform_exports_select on public.platform_exports;
create policy platform_exports_select on public.platform_exports
  for select to authenticated using (public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- 2. Which tables hold this school's data
--
-- From the catalogue. Used by the manifest, the export and the purge, so all
-- three agree by construction — an export that missed a table the purge then
-- deleted would be the worst possible bug in this file.
--
-- `platform_%` tables are excluded: our invoices to the school and their reports
-- of payment are OUR business records, not the school's data. They are kept
-- after a purge for the same reason a shop keeps its own sales ledger. The purge
-- clears their school_id link instead of the rows, via the ON DELETE rules
-- already on those tables.
-- ---------------------------------------------------------------------------
create or replace function public.fn__school_data_tables()
returns table (table_name text) language sql stable as $$
  select c.relname::text
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid
   where n.nspname = 'public' and c.relkind = 'r'
     and a.attname = 'school_id' and not a.attisdropped
     and c.relname not like 'platform\_%'
     and c.relname not like 'operator\_%'
     and c.relname not in ('subscriptions', 'student_count_snapshots')
   order by c.relname;
$$;

revoke all on function public.fn__school_data_tables() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. What is there to export
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_export_manifest(p_school_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school record; r record; v_n bigint; v_total bigint := 0;
  v_tables jsonb := '[]'::jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into v_school from public.schools where id = p_school_id;
  if not found then
    raise exception 'Unknown school %', p_school_id;
  end if;
  -- The line from the header. A manifest is only counts, but it is the front
  -- door to the export, and refusing here means the console cannot even offer
  -- the button on a live school.
  if v_school.archived_at is null then
    raise exception
      'Archive % first. A full export is an offboarding step, not a way to pull a '
      'live customer''s records — and archiving is reversible.', v_school.name
      using errcode = '42501';
  end if;

  for r in select table_name from public.fn__school_data_tables() loop
    execute format('select count(*) from public.%I where school_id = $1', r.table_name)
      into v_n using p_school_id;
    v_total := v_total + v_n;
    -- Every table, including the empty ones. A manifest that silently omits
    -- what has no rows makes it impossible to tell "they never used marks" from
    -- "marks were left out of the export".
    v_tables := v_tables || jsonb_build_object('name', r.table_name, 'rows', v_n);
  end loop;

  return jsonb_build_object(
    'school_id', p_school_id,
    'school_name', v_school.name,
    'archived_at', v_school.archived_at,
    'tables', v_tables,
    'total_rows', v_total,
    'previous_exports', coalesce((
      select jsonb_agg(jsonb_build_object('taken_at', e.taken_at,
                                          'total_rows', e.total_rows,
                                          'by', e.taken_by_email)
                       order by e.taken_at desc)
        from public.platform_exports e where e.school_id = p_school_id), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. One table at a time
--
-- Paged rather than one giant jsonb. A school with three years of daily
-- attendance for 600 children is over a million rows in one table alone, and a
-- single response carrying all of it would either exhaust memory or be truncated
-- by something between here and the browser — and a truncated export that
-- reported success is how "we gave you everything" becomes untrue.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_export_table(
  p_school_id uuid, p_table text,
  p_offset integer default 0, p_limit integer default 1000
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_rows jsonb; v_lim integer := greatest(1, least(coalesce(p_limit, 1000), 5000));
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not exists (select 1 from public.schools
                  where id = p_school_id and archived_at is not null) then
    raise exception 'Archive the school first' using errcode = '42501';
  end if;
  -- The table name comes from the client and goes into dynamic SQL. Checked
  -- against the catalogue-derived list rather than quoted-and-hoped: %I would
  -- stop an injection but would still happily read `platform_payments` or
  -- another school's… no, school_id scopes that — but it would read tables that
  -- are not this school's data to give away.
  if not exists (select 1 from public.fn__school_data_tables()
                  where table_name = p_table) then
    raise exception '% is not one of this school''s data tables', coalesce(p_table, '(null)');
  end if;

  -- Ordered by ctid so paging is stable: not every one of these tables has an
  -- id, and ORDER BY on a column that does not exist everywhere would have to be
  -- guessed per table. ctid is physical and does not move under a read-only
  -- export of an archived school, which is the only thing this runs on.
  execute format(
    'select coalesce(jsonb_agg(to_jsonb(t) order by t.ctid), ''[]''::jsonb) '
    'from (select * , ctid from public.%I where school_id = $1 '
    '       order by ctid offset $2 limit $3) t', p_table)
    into v_rows using p_school_id, greatest(0, coalesce(p_offset, 0)), v_lim;

  return jsonb_build_object(
    'table', p_table, 'offset', greatest(0, coalesce(p_offset, 0)),
    'limit', v_lim, 'rows', v_rows,
    'count', jsonb_array_length(v_rows));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Recording that it was handed over
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_record_export(
  p_school_id uuid, p_counts jsonb, p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_name text; v_id uuid; v_total integer := 0; k text;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select name into v_name from public.schools where id = p_school_id;
  if v_name is null then
    raise exception 'Unknown school %', p_school_id;
  end if;
  if p_counts is null or jsonb_typeof(p_counts) <> 'object' then
    raise exception 'Give the row counts that were actually written to the file';
  end if;

  for k in select x from jsonb_object_keys(p_counts) x loop
    v_total := v_total + coalesce((p_counts->>k)::integer, 0);
  end loop;

  insert into public.platform_exports
    (school_id, school_name, taken_by, taken_by_email, counts, total_rows, note)
  values (p_school_id, v_name, auth.uid(),
          (select email from public.platform_admins where user_id = auth.uid()),
          p_counts, v_total, nullif(btrim(coalesce(p_note, '')), ''))
  returning id into v_id;

  perform public.fn__log_operator_action('school_exported', p_school_id,
    jsonb_build_object('export_id', v_id, 'total_rows', v_total));

  insert into public.audit_log(school_id, actor, action, entity, entity_id, after)
  values (p_school_id, auth.uid(), 'school_exported', 'schools', p_school_id::text,
          jsonb_build_object('total_rows', v_total, 'export_id', v_id));

  return jsonb_build_object('export_id', v_id, 'total_rows', v_total,
                            'taken_at', now());
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Purge
--
-- The only irreversible thing in this product. Five refusals stand in front of
-- it, and each one is a mistake somebody would otherwise make:
--
--   not the operator          — obvious
--   not archived              — purging a live customer
--   never exported            — destroying records nobody has a copy of
--   the phrase does not match — the wrong school in a list of fifty
--   still owes money          — writing off a debt by deleting the debtor
--
-- The last one is overridable, because "they will never pay and I want them
-- gone" is a legitimate business decision. The other four are not.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_purge_school(
  p_school_id uuid,
  -- Must equal the school's name exactly. Case and spacing included: this is
  -- the last thing standing between a mis-click and a customer's records.
  p_confirm_name text,
  p_force_despite_debt boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school record;
  v_owed   numeric;
  v_export record;
  r        record;
  v_n      bigint;
  v_deleted jsonb := '{}'::jsonb;
  v_total   bigint := 0;
  v_left    text;
  v_pass    integer := 0;
  v_progress boolean;
  v_photos  integer := 0;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  select * into v_school from public.schools where id = p_school_id;
  if not found then
    raise exception 'Unknown school %', p_school_id;
  end if;

  -- --- refusal 1: not archived ---------------------------------------------
  if v_school.archived_at is null then
    raise exception
      'Archive % first. Archiving is reversible and this is not.', v_school.name
      using errcode = '42501';
  end if;

  -- --- refusal 2: never exported -------------------------------------------
  select * into v_export from public.platform_exports
   where school_id = p_school_id order by taken_at desc limit 1;
  if v_export.id is null then
    raise exception
      'Nothing has been exported for %. Take the export first — it is what you '
      'hand them, and it is the only answer to "you deleted our records".',
      v_school.name;
  end if;

  -- --- refusal 3: the phrase ------------------------------------------------
  -- Exact, including case. A near-miss is refused with the difference named,
  -- because "confirmation failed" on a destructive action sends people back to
  -- try again harder rather than to check which school they are looking at.
  if p_confirm_name is distinct from v_school.name then
    raise exception
      'That is not the name. To purge this school, type exactly: %', v_school.name;
  end if;

  -- --- refusal 4: money still owed -----------------------------------------
  v_owed := public.fn__platform_billed(p_school_id) - public.fn__platform_settled(p_school_id);
  if v_owed > 0 and not coalesce(p_force_despite_debt, false) then
    raise exception
      '% still owes %. Deleting the school does not collect it and does not write '
      'it off — raise a credit note if you are forgiving it, or purge on purpose.',
      v_school.name, to_char(v_owed, 'FM999,999,999.00');
  end if;

  -- --- the log entry goes FIRST -------------------------------------------
  -- Written before anything is deleted, and with school_id NULL so it survives
  -- the delete of the school it describes. operator_actions.school_id has an
  -- ON DELETE NO ACTION foreign key to schools, so a row pointing at this school
  -- would either block the purge or have to be deleted with it — and a purge
  -- that erases its own record is not an audit trail.
  perform public.fn__log_operator_action('school_purged', null,
    jsonb_build_object(
      'school_id', p_school_id,
      'school_name', v_school.name,
      'city', v_school.city,
      'archived_at', v_school.archived_at,
      'archive_reason', v_school.archive_reason,
      'exported_at', v_export.taken_at,
      'exported_rows', v_export.total_rows,
      'outstanding_written_off', case when v_owed > 0 then v_owed else 0 end,
      'created_at', v_school.created_at));

  -- --- the delete, in whatever order the foreign keys allow ----------------
  -- Up to 12 passes. Each pass tries every remaining table and swallows a
  -- foreign-key violation, which simply means "something still points at this,
  -- come back next pass". The loop ends when a pass deletes nothing, and then
  -- either everything is gone or the raise below names what is left.
  loop
    v_pass := v_pass + 1;
    v_progress := false;
    for r in select table_name from public.fn__school_data_tables() loop
      begin
        execute format('delete from public.%I where school_id = $1', r.table_name)
          using p_school_id;
        get diagnostics v_n = row_count;
        if v_n > 0 then
          v_progress := true;
          v_total := v_total + v_n;
          v_deleted := v_deleted || jsonb_build_object(
            r.table_name, coalesce((v_deleted->>r.table_name)::bigint, 0) + v_n);
        end if;
      exception
        -- Only a dependency. Any OTHER error is a real fault and must not be
        -- swallowed: a permission problem or a trigger raising would otherwise
        -- look identical to "try again next pass" and the loop would report a
        -- clean purge of a school it never touched.
        when foreign_key_violation then null;
      end;
    end loop;
    exit when not v_progress or v_pass >= 12;
  end loop;

  -- Anything left is a table this function cannot reach, and the honest thing is
  -- to stop and say which. The transaction rolls back, so the school is intact.
  --
  -- Counted with count(*) rather than from pg_class.reltuples, which is an
  -- estimate and can read zero on a table that has rows.
  for r in select table_name from public.fn__school_data_tables() loop
    execute format('select count(*) from public.%I where school_id = $1', r.table_name)
      into v_n using p_school_id;
    if v_n > 0 then
      v_left := coalesce(v_left || ', ', '') || r.table_name || ' (' || v_n::text || ')';
    end if;
  end loop;
  if v_left is not null then
    raise exception
      'Could not finish: % still holds rows for this school after % passes. Nothing '
      'has been deleted — the whole purge is one transaction.', v_left, v_pass;
  end if;

  -- --- the photographs -----------------------------------------------------
  -- Storage objects are not in public and no foreign key reaches them, so
  -- deleting the school's rows leaves its children's photographs in the bucket
  -- forever. Guarded on the schema existing because the test harness has no
  -- storage schema, and a purge that fails there would be a purge that cannot be
  -- tested.
  if to_regclass('storage.objects') is not null then
    execute 'delete from storage.objects where name like $1'
      using p_school_id::text || '/%';
    get diagnostics v_photos = row_count;
  end if;

  -- --- the operator's own history ------------------------------------------
  -- operator_actions.school_id has an ON DELETE NO ACTION foreign key, so these
  -- rows would block the delete. They are UNLINKED rather than deleted: what the
  -- vendor did to a customer is the vendor's record, and it is the only thing
  -- that can answer "when did we suspend them, and why" after the fact. The
  -- name goes into the detail so an unlinked row is still readable.
  update public.operator_actions
     set school_id = null,
         detail = coalesce(detail, '{}'::jsonb)
                  || jsonb_build_object('purged_school_name', v_school.name,
                                        'purged_school_id', p_school_id)
   where school_id = p_school_id;

  -- Support VISITS go. operator_sessions.school_id is NOT NULL so it cannot be
  -- unlinked, and nothing is lost: every entry and exit is already an
  -- operator_actions row, which has just been preserved above.
  delete from public.operator_sessions where school_id = p_school_id;

  -- --- subscriptions and the snapshots ------------------------------------
  -- Excluded from fn__school_data_tables because they are the licence rather
  -- than the school's own records, but they still have to go or the school row
  -- cannot be deleted.
  delete from public.student_count_snapshots where school_id = p_school_id;
  delete from public.subscriptions where school_id = p_school_id;

  -- Our own sales ledger stays. Section 0 above changed platform_invoices and
  -- platform_payments from ON DELETE CASCADE to SET NULL and denormalised the
  -- school name onto each row, so this delete orphans them rather than
  -- destroying them — which is what retaining tax records requires.
  -- platform_payment_claims still cascades: a request to be checked is not a
  -- business record, and the payment it became survives on its own.
  delete from public.schools where id = p_school_id;

  return jsonb_build_object(
    'purged', true,
    'school_name', v_school.name,
    'rows_deleted', v_total,
    'photos_deleted', v_photos,
    'passes', v_pass,
    'by_table', v_deleted,
    'exported_at', v_export.taken_at,
    'kept', jsonb_build_object(
      'invoices', (select count(*) from public.platform_invoices
                    where school_name = v_school.name and school_id is null),
      'payments', (select count(*) from public.platform_payments
                    where school_name = v_school.name and school_id is null),
      'why', 'Your own invoices and receipts are kept, with the school''s name on '
        || 'them. A business keeps its sales ledger after a customer leaves, and '
        || 'tax records have to be retained for years after the transaction.'),
    'also_kept', 'The export record, and everything this console recorded that you '
      || 'did to them — suspensions, discounts, support visits.');
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Grants
-- ---------------------------------------------------------------------------
grant  execute on function public.fn_platform_export_manifest(uuid)   to authenticated;
revoke execute on function public.fn_platform_export_manifest(uuid) from public, anon;
grant  execute on function public.fn_platform_export_table(uuid, text, integer, integer)   to authenticated;
revoke execute on function public.fn_platform_export_table(uuid, text, integer, integer) from public, anon;
grant  execute on function public.fn_platform_record_export(uuid, jsonb, text)   to authenticated;
revoke execute on function public.fn_platform_record_export(uuid, jsonb, text) from public, anon;
grant  execute on function public.fn_platform_purge_school(uuid, text, boolean)   to authenticated;
revoke execute on function public.fn_platform_purge_school(uuid, text, boolean) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0081_platform_metrics.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0081 — The business could not say what it was worth
--
-- Phase 5 of docs/SUPER-ADMIN-DESIGN.md.
--
-- WHAT THE CONSOLE COULD ANSWER BEFORE THIS
--
--   what did we invoice in August? ....... fn_platform_revenue, yes
--   who owes us money? ................... yes
--   what is our monthly recurring revenue? nothing
--   how many trials turn into customers? . nothing
--   how many customers have we lost? ..... nothing — `cancelled` has no date
--   are our schools growing? ............. student_count_snapshots is written on
--                                          every recount and read by NOTHING
--
-- The last one is the waste worth naming: 0026 writes a row per school per day
-- recording its pupil count, 0067 made that happen automatically on every
-- admission, and no function has ever read the table. That is a daily record of
-- your customers' growth, which is your own growth, sitting unused.
--
-- WHY MRR IS NOT COMPUTED FROM THE PRICE LIST
--
-- The obvious implementation is `sum(price_yearly)/12 over active subscriptions`.
-- It is wrong in a way that flatters: a school on a discount, a school given a
-- free year as an apology, and a school paying full price all contribute the same
-- list price. 0064 exists precisely because discounts left no trace, and an MRR
-- built on list price would reintroduce the same blindness one layer up.
--
-- So each school contributes the monthly equivalent of what it was ACTUALLY
-- charged: the live invoice covering today, amount divided by months. Pre-tax,
-- because sales tax collected on somebody else's behalf is not revenue.
--
-- AND WHY A SCHOOL WITH NO INVOICE CONTRIBUTES ZERO
--
-- A school holding licence time nobody billed for contributes nothing, because
-- nothing was billed. Counting list price there would put revenue in the figure
-- that does not exist and will never arrive. But a silent zero is its own lie, so
-- `unbilled` is reported beside MRR with the count — it is the same fact 0079's
-- `unbilled_days` surfaces per school, totalled.
--
-- CHURN IS MEASURED FROM DATED EVENTS, NOT FROM A STATUS
--
-- `subscriptions.status = 'cancelled'` has no timestamp, so "how many did we lose
-- this year" was unanswerable from the subscription alone. It is computed from
-- schools.archived_at (0079) and from operator_actions rows, which 0073 dates.
-- Before those two migrations there is no history, and the function says so
-- rather than reporting a confident zero.
--
-- EVERY FIGURE CARRIES WHAT IT MEASURES. A metric on a dashboard with no
-- definition becomes whatever the person looking at it assumes, and two people
-- then argue about a number they define differently.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. What one school contributes per month, right now
--
-- fn__ and revoked: it answers for any school without asking who wants to know.
-- ---------------------------------------------------------------------------
create or replace function public.fn__school_mrr(p_school_id uuid, p_as_at date)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce((
    select round(i.amount / greatest(i.months, 1), 2)
      from public.platform_invoices i
     where i.school_id = p_school_id
       and i.kind = 'invoice'
       and i.voided_at is null
       and p_as_at between i.period_start and i.period_end
     -- The newest document covering the date, so a mid-term plan change counts
     -- at the new price rather than the one it replaced.
     order by i.issued_on desc, i.serial desc
     limit 1), 0);
$$;

revoke all on function public.fn__school_mrr(uuid, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The business, in one call
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_metrics(p_as_at date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_at date := coalesce(p_as_at, current_date);
  v_mrr numeric := 0;
  v_paying integer := 0;
  v_trial integer := 0;
  v_grace integer := 0;
  v_locked integer := 0;
  v_cancelled integer := 0;
  v_unbilled integer := 0;
  v_archived integer := 0;
  v_students integer := 0;
  v_lost integer := 0;
  v_first_history date;
  r record;
  v_by_plan jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  for r in
    select s.id, s.archived_at, sub.plan_code, sub.student_count,
           public.fn_effective_status(s.id) as eff
      from public.schools s
      join public.subscriptions sub on sub.school_id = s.id
  loop
    if r.archived_at is not null then
      v_archived := v_archived + 1;
      continue;              -- archived schools are not customers
    end if;
    case r.eff
      when 'active'    then v_paying := v_paying + 1;
      when 'grace'     then v_grace := v_grace + 1;
      when 'trialing'  then v_trial := v_trial + 1;
      when 'locked'    then v_locked := v_locked + 1;
      when 'cancelled' then v_cancelled := v_cancelled + 1;
      else null;
    end case;

    -- Counted as recurring only while the licence is LIVE. Grace counts: the
    -- money is contracted and in flight. Locked and cancelled do not, whatever
    -- an unexpired invoice might say.
    if r.eff in ('active', 'grace') then
      declare v_m numeric := public.fn__school_mrr(r.id, v_at);
      begin
        if v_m = 0 then
          v_unbilled := v_unbilled + 1;
        end if;
        v_mrr := v_mrr + v_m;
      end;
      v_students := v_students + coalesce(r.student_count, 0);
    end if;
  end loop;

  -- Per plan, and this is what 5b of the design asked for: fn_platform_revenue
  -- has returned by_plan since 0064 and nothing has ever rendered it.
  select coalesce(jsonb_agg(x order by x->>'sort'), '[]'::jsonb) into v_by_plan
    from (
      select jsonb_build_object(
               'plan_code', p.code, 'plan_name', p.name,
               'sort', lpad(p.sort_order::text, 4, '0'),
               'schools', count(s.id),
               -- FILTERED on the join having matched. Without it the sum counts
               -- subscriptions whose school failed the live-status condition, so
               -- a locked school's pupils appeared under its plan while the
               -- school itself did not. Caught by a fixture where the numbers
               -- did not add up, not by reading.
               'students', coalesce(sum(sub.student_count)
                                      filter (where s.id is not null), 0),
               'mrr', coalesce(sum(public.fn__school_mrr(s.id, v_at))
                                 filter (where s.id is not null), 0),
               'list_mrr', round(count(s.id) * p.price_yearly / 12, 2)) as x
        from public.plans p
        left join public.subscriptions sub on sub.plan_code = p.code
        left join public.schools s
               on s.id = sub.school_id
              and s.archived_at is null
              and public.fn_effective_status(s.id) in ('active', 'grace')
       group by p.code, p.name, p.sort_order, p.price_yearly) g;

  -- --- churn, from dated events ------------------------------------------
  -- The earliest thing that could have been recorded. If there is no history at
  -- all the answer is "we do not know", not zero — a confident zero churn on a
  -- database with no history is the most misleading number this screen could
  -- show.
  select least(
    (select min(at)::date from public.operator_actions),
    (select min(archived_at)::date from public.schools)
  ) into v_first_history;

  select count(*) into v_lost
    from public.schools s
   where (s.archived_at is not null and s.archived_at >= v_at - 365)
      or (s.archived_at is null and exists (
            select 1 from public.operator_actions a
             where a.school_id = s.id
               and a.action = 'subscription_cancelled'
               and a.at >= v_at - 365));

  return jsonb_build_object(
    'as_at', v_at,

    'recurring', jsonb_build_object(
      'mrr', round(v_mrr, 2),
      'arr', round(v_mrr * 12, 2),
      'paying_schools', v_paying,
      'in_grace', v_grace,
      -- Per PAYING school, not per school on the books. Dividing by trials and
      -- locked accounts makes the figure drop every time a demo is set up.
      'arps', case when v_paying + v_grace > 0
                   then round(v_mrr / (v_paying + v_grace), 2) else 0 end,
      'basis', 'What each live school was actually charged for the period covering '
        || v_at::text || ', divided by the number of months on the invoice, before '
        || 'tax. Not the price list — a discounted school counts at its discount.'),

    'unbilled', jsonb_build_object(
      'schools', v_unbilled,
      'note', case when v_unbilled = 0 then 'Every live school has an invoice covering today.'
                   else format('%s live school(s) have licence time no invoice covers, so '
                               || 'they add nothing to MRR. Raise the invoice or the figure '
                               || 'stays understated and the money never arrives.', v_unbilled)
              end),

    'counts', jsonb_build_object(
      'paying', v_paying, 'in_grace', v_grace, 'on_trial', v_trial,
      'locked', v_locked, 'cancelled', v_cancelled, 'archived', v_archived,
      'live_total', v_paying + v_grace + v_trial + v_locked,
      'students_at_paying_schools', v_students),

    -- Trials that turned into customers. Deliberately only counts trials whose
    -- 14-or-more days are OVER: a trial that started yesterday has not failed to
    -- convert, and including it makes the rate drop every time a demo is set up.
    'conversion', (
      select case when count(*) = 0 then
        jsonb_build_object('measurable', false,
          'why', 'No trial has finished yet.')
      else
        jsonb_build_object('measurable', true,
          'trials_finished', count(*),
          'converted', count(*) filter (where has_invoice),
          'rate_pct', round(100.0 * count(*) filter (where has_invoice) / count(*), 1),
          'basis', 'Schools whose trial end date has passed, and whether any live '
            || 'invoice was ever raised against them.')
      end
      from (
        select exists (select 1 from public.platform_invoices i
                        where i.school_id = s.id and i.kind = 'invoice'
                          and i.voided_at is null) as has_invoice
          from public.schools s
          join public.subscriptions sub on sub.school_id = s.id
         where sub.trial_ends_on is not null and sub.trial_ends_on < v_at) t),

    'churn', case when v_first_history is null then
      jsonb_build_object('measurable', false,
        'why', 'Nothing dated has been recorded yet. Cancellations before 0073 and '
          || '0079 left no timestamp, so there is no history to measure — which is '
          || 'not the same as no churn.')
      else
      jsonb_build_object('measurable', true,
        'lost_12m', v_lost,
        'rate_pct', case when v_paying + v_grace + v_lost > 0
          then round(100.0 * v_lost / (v_paying + v_grace + v_lost), 1) else 0 end,
        'history_starts', v_first_history,
        'basis', 'Schools archived or cancelled in the last 365 days, as a share of '
          || 'those plus the ones still paying. History only goes back to '
          || v_first_history::text || '.')
      end,

    'by_plan', v_by_plan);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The growth chart the snapshots were always for
--
-- One row per month: how many schools we had and how many pupils were inside
-- them. The last snapshot in each month, per school, so a school recounted forty
-- times in March is one point in March and not forty.
--
-- Reading student_count_snapshots for the first time since 0026 wrote it.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_growth(p_months integer default 12)
returns table (
  month date, schools integer, students integer, avg_per_school numeric
) language plpgsql stable security definer set search_path = public as $$
declare v_n integer := greatest(1, least(coalesce(p_months, 12), 60));
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
    with month_end as (
      -- The last count recorded for each school in each month. distinct on is
      -- the cheapest correct way to say "the newest row per group".
      select distinct on (date_trunc('month', s.counted_on), s.school_id)
             date_trunc('month', s.counted_on)::date as m,
             s.school_id, s.student_count
        from public.student_count_snapshots s
       where s.counted_on >= (date_trunc('month', current_date)
                              - make_interval(months => v_n - 1))::date
       order by date_trunc('month', s.counted_on), s.school_id, s.counted_on desc
    )
    select me.m,
           count(*)::integer,
           coalesce(sum(me.student_count), 0)::integer,
           round(coalesce(sum(me.student_count), 0)::numeric
                 / greatest(count(*), 1), 1)
      from month_end me
     group by me.m
     order by me.m;
end;
$$;

grant  execute on function public.fn_platform_metrics(date)   to authenticated;
revoke execute on function public.fn_platform_metrics(date) from public, anon;
grant  execute on function public.fn_platform_growth(integer)   to authenticated;
revoke execute on function public.fn_platform_growth(integer) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0082_releases_and_announcements.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0082 — The download button pointed at nothing, and a notice meant fifty
--        WhatsApp messages
--
-- Phase 6 of docs/SUPER-ADMIN-DESIGN.md. Three surfaces exist — the website, the
-- app, the console — and nothing joined them up.
--
-- THREE DEFECTS
--
-- 1. THE DESKTOP BUILD IS UNREACHABLE
--
--    desktop/ produces a Windows .msi in CI. It is uploaded as a workflow
--    artifact, which requires a GitHub login and expires in 90 days. So the one
--    thing a Pakistani school office actually wants — "give me the file, I will
--    install it on the front-desk computer" — cannot be given to them, and the
--    website has no download button because there is nothing to point it at.
--
--    A registry, not a hardcoded URL: the operator records a release and BOTH
--    the website's download button and the app's "an update is available" read
--    the same row. One place to change when a version ships.
--
-- 2. THE WEBSITE'S PRICES ARE TYPED INTO HTML
--
--    site/index.html carries Rs 950 / Rs 2,000 / Rs 3,500 as literal text and
--    `plans` carries them as data. Two copies of a price is one copy too many:
--    the day one is raised, the site quotes a figure the console does not charge
--    and a school arrives expecting the old one. `plans` becomes readable
--    WITHOUT a login so the site can read the real thing.
--
--    That is a deliberate widening and it is paid for: 4b-iii of
--    tenant_isolation.sql already requires `plans` to have no write policy, so
--    world-readable cannot become world-writable. A price list is a public
--    document — it is printed on the website either way.
--
-- 3. "MAINTENANCE ON SUNDAY 6-7AM" MEANS FIFTY WHATSAPP MESSAGES
--
--    There is no way to tell every school anything. With three customers that is
--    three messages; with fifty it is an afternoon, and the schools that most
--    need to know are the ones whose number is out of date.
--
--    platform_announcements, with an audience and a window, rendered as a banner
--    in the app. Deliberately NOT a message in message_outbox: that table is the
--    school's own outbox to its parents, and putting vendor notices in it would
--    mean a school's clerk seeing our maintenance window in a list of fee
--    reminders they are about to send.
--
-- WHY NONE OF THIS IS A FUNCTION GRANTED TO `anon`
--
-- 0071 closed the entire function surface to anon and check-definer-idor.py
-- fails CI if a single function in public is executable without a login. So the
-- public reads here are TABLE policies with an explicit grant, which is a much
-- narrower thing to reason about: a policy says which rows, and the grant says
-- which columns are reachable at all.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The price list becomes public
--
-- Only the ACTIVE plans, so a retired price cannot be quoted back at us.
-- ---------------------------------------------------------------------------
drop policy if exists plans_select_public on public.plans;
create policy plans_select_public on public.plans
  for select to anon using (active);

grant select on public.plans to anon;

-- ---------------------------------------------------------------------------
-- 2. Releases
-- ---------------------------------------------------------------------------
create table if not exists public.app_releases (
  id           uuid primary key default gen_random_uuid(),
  platform     text not null check (platform in ('windows', 'mac', 'linux', 'web')),
  channel      text not null default 'stable' check (channel in ('stable', 'beta')),
  version      text not null,
  url          text not null,
  -- The checksum a school can verify, and the reason it is NOT optional: an .msi
  -- downloaded over a Pakistani DSL line and installed on the office computer is
  -- exactly the file somebody would want to swap. Publishing the hash costs a
  -- line and is the only thing that makes "is this the real installer?"
  -- answerable.
  sha256       text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  size_bytes   bigint,
  notes        text,
  published_at timestamptz not null default now(),
  published_by uuid,
  -- Exactly one current release per platform+channel, enforced by a partial
  -- unique index below rather than by whoever remembers to clear the last one.
  is_current   boolean not null default true,
  unique (platform, channel, version)
);

create unique index if not exists idx_app_releases_current
  on public.app_releases(platform, channel) where is_current;

alter table public.app_releases enable row level security;

-- The operator sees every release including superseded ones; everybody else —
-- INCLUDING a visitor with no login, which is the whole point — sees only what
-- is current. Two policies rather than one, because "what should we offer for
-- download" and "what have we ever shipped" are different questions.
drop policy if exists app_releases_select_platform on public.app_releases;
create policy app_releases_select_platform on public.app_releases
  for select to authenticated using (public.is_platform_admin());

drop policy if exists app_releases_select_current on public.app_releases;
create policy app_releases_select_current on public.app_releases
  for select to anon, authenticated using (is_current);

grant select on public.app_releases to anon;

-- No write policy. Publishing a release is how a school gets an executable, so
-- it goes through one definer function that validates the checksum shape and the
-- URL, and records who did it.
create or replace function public.fn_platform_publish_release(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_platform text; v_channel text; v_version text;
  v_url text; v_sha text;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'Give the release details';
  end if;

  v_platform := coalesce(nullif(btrim(lower(coalesce(p->>'platform', ''))), ''), 'windows');
  v_channel  := coalesce(nullif(btrim(lower(coalesce(p->>'channel', ''))), ''), 'stable');
  v_version  := nullif(btrim(coalesce(p->>'version', '')), '');
  v_url      := nullif(btrim(coalesce(p->>'url', '')), '');
  v_sha      := nullif(btrim(lower(coalesce(p->>'sha256', ''))), '');

  if v_version is null then
    raise exception 'A version is required, e.g. 1.4.2';
  end if;
  if v_url is null or v_url !~ '^https://' then
    -- http:// refused, not merely discouraged. An installer fetched over plain
    -- HTTP on a Pakistani café connection is the easiest thing in this product
    -- to tamper with, and the school would have no way to know.
    raise exception 'The download URL must be an https:// address';
  end if;
  if v_sha is null or v_sha !~ '^[0-9a-f]{64}$' then
    raise exception
      'A SHA-256 checksum is required — 64 hex characters. On the machine that '
      'built the file: certutil -hashfile <file> SHA256';
  end if;

  -- One current release per platform and channel. Cleared first, in the same
  -- transaction, so the partial unique index can never see two.
  update public.app_releases set is_current = false
   where platform = v_platform and channel = v_channel and is_current;

  insert into public.app_releases
    (platform, channel, version, url, sha256, size_bytes, notes, published_by, is_current)
  values (v_platform, v_channel, v_version, v_url, v_sha,
          (p->>'size_bytes')::bigint,
          nullif(btrim(coalesce(p->>'notes', '')), ''), auth.uid(), true)
  on conflict (platform, channel, version) do update
    set url = excluded.url, sha256 = excluded.sha256,
        size_bytes = excluded.size_bytes, notes = excluded.notes,
        published_at = now(), published_by = excluded.published_by,
        is_current = true
  returning id into v_id;

  perform public.fn__log_operator_action('release_published', null,
    jsonb_build_object('release_id', v_id, 'platform', v_platform,
                       'channel', v_channel, 'version', v_version, 'url', v_url));

  return jsonb_build_object('release_id', v_id, 'platform', v_platform,
                            'channel', v_channel, 'version', v_version,
                            'is_current', true);
end;
$$;

create or replace function public.fn_platform_releases(p_limit integer default 50)
returns table (
  id uuid, platform text, channel text, version text, url text, sha256 text,
  size_bytes bigint, notes text, published_at timestamptz, is_current boolean
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
    select r.id, r.platform, r.channel, r.version, r.url, r.sha256,
           r.size_bytes, r.notes, r.published_at, r.is_current
      from public.app_releases r
     order by r.published_at desc
     limit greatest(1, least(coalesce(p_limit, 50), 200));
end;
$$;

create or replace function public.fn_platform_unpublish_release(
  p_release_id uuid, p_reason text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_r record; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  -- A release is pulled because it was broken. That is worth a sentence: six
  -- months later "why is 1.4.1 not the current one" has no other answer.
  if v_reason is null then
    raise exception 'Say why this release is being pulled';
  end if;
  select * into v_r from public.app_releases where id = p_release_id;
  if not found then
    raise exception 'No such release';
  end if;

  update public.app_releases set is_current = false where id = p_release_id;

  perform public.fn__log_operator_action('release_pulled', null,
    jsonb_build_object('release_id', p_release_id, 'platform', v_r.platform,
                       'version', v_r.version, 'reason', v_reason));

  return jsonb_build_object(
    'release_id', p_release_id, 'is_current', false,
    -- Said out loud: pulling the current release leaves the website's download
    -- button with nothing to offer, which is right, and silent otherwise.
    'note', case when exists (select 1 from public.app_releases
                               where platform = v_r.platform
                                 and channel = v_r.channel and is_current)
                 then 'Another release is now current for that platform.'
                 else format('There is now NO current %s release. The website''s '
                             || 'download button will say the installer is being '
                             || 'prepared.', v_r.platform) end);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Announcements
-- ---------------------------------------------------------------------------
create table if not exists public.platform_announcements (
  id         uuid primary key default gen_random_uuid(),
  -- Who sees it. 'staff' is everybody with a school login; 'parents' is the
  -- portal; 'owners' is the person who pays, for anything commercial.
  audience   text not null default 'staff'
               check (audience in ('staff', 'parents', 'owners', 'everyone')),
  severity   text not null default 'info'
               check (severity in ('info', 'warning', 'critical')),
  title      text not null check (btrim(title) <> ''),
  message    text not null check (btrim(message) <> ''),
  starts_at  timestamptz not null default now(),
  -- NOT NULL on purpose. An announcement with no end date is a banner that is
  -- still telling schools about last March's maintenance window, and a banner
  -- nobody believes is worse than no banner — the one that matters gets ignored
  -- with it.
  ends_at    timestamptz not null,
  created_by uuid,
  created_at timestamptz not null default now()
);

-- A HALF-OPEN window: [starts_at, ends_at). Named, and reconciled on every run,
-- because the first version of this table wrote `check (ends_at > starts_at)`
-- and that made retraction impossible to express.
--
-- now() is TRANSACTION-stable. A notice posted and immediately retracted —
-- because the wording was wrong, which is exactly when you retract one — has
-- starts_at = now(), so "ends now" can only mean ends_at = starts_at. With a
-- strict > that violated the constraint; with `between` in the policy it stayed
-- visible for a second. A half-open interval is both the standard way to write a
-- window and the one where "it showed, and now it does not" is expressible.
do $win$
begin
  if exists (select 1 from pg_constraint
              where conrelid = 'public.platform_announcements'::regclass
                and conname = 'platform_announcements_check') then
    alter table public.platform_announcements drop constraint platform_announcements_check;
  end if;
  if not exists (select 1 from pg_constraint
                  where conname = 'platform_announcements_window_chk') then
    alter table public.platform_announcements add constraint platform_announcements_window_chk
      check (ends_at >= starts_at);
  end if;
end $win$;

create index if not exists idx_announcements_window
  on public.platform_announcements(starts_at, ends_at);

alter table public.platform_announcements enable row level security;

drop policy if exists announcements_select_platform on public.platform_announcements;
create policy announcements_select_platform on public.platform_announcements
  for select to authenticated using (public.is_platform_admin());

-- Everybody with a login sees what is live and aimed at them. No school_id: it
-- is the same notice for every school, which is the entire point.
drop policy if exists announcements_select_live on public.platform_announcements;
create policy announcements_select_live on public.platform_announcements
  for select to authenticated using (
    -- Half-open: shows from starts_at, stops the instant ends_at is reached. See
    -- the note on the constraint above for why `between` was wrong.
    now() >= starts_at and now() < ends_at
    and (audience = 'everyone'
      or (audience = 'staff'   and public.is_staff())
      or (audience = 'owners'  and public.may_view('owner'::public.user_role,
                                                   'principal'::public.user_role))
      or (audience = 'parents' and exists (
            select 1 from public.profiles pr
             where pr.id = auth.uid() and pr.role = 'parent'))));

create or replace function public.fn_platform_announce(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_ends timestamptz; v_starts timestamptz;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'Give the announcement';
  end if;

  v_starts := coalesce((p->>'starts_at')::timestamptz, now());
  v_ends   := (p->>'ends_at')::timestamptz;
  if v_ends is null then
    -- Refused rather than defaulted, because whatever default this picked would
    -- be wrong: a maintenance window is hours and a price change is weeks.
    raise exception
      'Say when this stops showing. A banner with no end date is still telling '
      'schools about last March.';
  end if;
  if v_ends <= v_starts then
    raise exception 'It has to stop after it starts';
  end if;

  insert into public.platform_announcements
    (audience, severity, title, message, starts_at, ends_at, created_by)
  values (coalesce(nullif(btrim(lower(coalesce(p->>'audience', ''))), ''), 'staff'),
          coalesce(nullif(btrim(lower(coalesce(p->>'severity', ''))), ''), 'info'),
          btrim(coalesce(p->>'title', '')),
          btrim(coalesce(p->>'message', '')),
          v_starts, v_ends, auth.uid())
  returning id into v_id;

  perform public.fn__log_operator_action('announcement_posted', null,
    jsonb_build_object('announcement_id', v_id,
                       'audience', p->>'audience', 'severity', p->>'severity',
                       'title', p->>'title',
                       'starts_at', v_starts, 'ends_at', v_ends));

  return jsonb_build_object('announcement_id', v_id,
                            'starts_at', v_starts, 'ends_at', v_ends,
                            'live_now', now() >= v_starts and now() < v_ends);
end;
$$;

-- Ending one early is a separate act from posting it, and needs its own reason:
-- "we said the wrong thing" and "it is no longer true" are different, and the
-- log should be able to tell them apart.
create or replace function public.fn_platform_end_announcement(
  p_id uuid, p_reason text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_a record;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into v_a from public.platform_announcements where id = p_id;
  if not found then
    raise exception 'No such announcement';
  end if;
  if v_a.ends_at <= now() then
    raise exception 'That announcement has already finished';
  end if;

  -- least(starts_at, ...) is not what is wanted; greatest is. A notice retracted
  -- BEFORE it was due to start should stop at its start rather than end in the
  -- past, and one retracted while showing stops now. Either way ends_at is never
  -- less than starts_at, which the constraint requires.
  update public.platform_announcements
     set ends_at = greatest(now(), starts_at)
   where id = p_id;

  perform public.fn__log_operator_action('announcement_ended', null,
    jsonb_build_object('announcement_id', p_id, 'title', v_a.title,
                       'was_ending', v_a.ends_at,
                       'reason', nullif(btrim(coalesce(p_reason, '')), '')));

  return jsonb_build_object('announcement_id', p_id, 'ended', true);
end;
$$;

create or replace function public.fn_platform_announcements(p_limit integer default 50)
returns table (
  id uuid, audience text, severity text, title text, message text,
  starts_at timestamptz, ends_at timestamptz, live_now boolean
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
    select a.id, a.audience, a.severity, a.title, a.message,
           a.starts_at, a.ends_at,
           -- The SAME half-open test the policy uses. Two different definitions
           -- of "showing now" would have the operator's list disagree with the
           -- banner the schools are looking at.
           (now() >= a.starts_at and now() < a.ends_at)
      from public.platform_announcements a
     order by a.starts_at desc
     limit greatest(1, least(coalesce(p_limit, 50), 200));
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Grants
--
-- Nothing here goes to `anon`. The public reads are the two table policies
-- above; check-definer-idor.py fails CI if any function in public becomes
-- callable without a login, and that guard is worth more than the convenience.
-- ---------------------------------------------------------------------------
grant  execute on function public.fn_platform_publish_release(jsonb)   to authenticated;
revoke execute on function public.fn_platform_publish_release(jsonb) from public, anon;
grant  execute on function public.fn_platform_releases(integer)   to authenticated;
revoke execute on function public.fn_platform_releases(integer) from public, anon;
grant  execute on function public.fn_platform_unpublish_release(uuid, text)   to authenticated;
revoke execute on function public.fn_platform_unpublish_release(uuid, text) from public, anon;
grant  execute on function public.fn_platform_announce(jsonb)   to authenticated;
revoke execute on function public.fn_platform_announce(jsonb) from public, anon;
grant  execute on function public.fn_platform_end_announcement(uuid, text)   to authenticated;
revoke execute on function public.fn_platform_end_announcement(uuid, text) from public, anon;
grant  execute on function public.fn_platform_announcements(integer)   to authenticated;
revoke execute on function public.fn_platform_announcements(integer) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0083_portal_verdict_and_dead_tables.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0083 — A parent could see the marks and not whether their child passed
--
-- Three gaps from the ground-truth audit, all confirmed by query rather than by
-- reading a list.
--
-- 1. THE PORTAL WITHHELD THE ONE THING A PARENT OPENS IT FOR
--
--    fn_generate_result_cards (0058) freezes a complete verdict onto every
--    result card:
--
--      'result'            PASS / FAIL / PENDING
--      'failed_subjects'   how many papers were below the pass mark
--      'pass_percent'      the threshold this school actually uses
--      'provisional'       true when some papers are not marked yet
--      'unmarked_subjects' how many
--      'stream', 'bise_reg_no'
--
--    fn_portal_child_results returned NONE of them. A parent saw marks, a
--    percentage and a grade — and had to work out for themselves whether 41%
--    was a pass at a school whose threshold is 40 or 50.
--
--    Worse, `provisional` was dropped too. So a card generated while two papers
--    were unmarked showed a percentage computed over the marked papers only, and
--    the parent had no way to know it was not the final figure. The card the
--    SCHOOL prints says "provisional" on its face; the portal did not.
--
--    Per-subject practical marks were already in `frozen->subjects` — theory,
--    practical, practical_max — so the portal had them all along and rendered
--    only the total. That half is a UI fix; this makes the verdict available.
--
-- 2. AN UNLOGGED DIRECT-WRITE PATH FOR THE OPERATOR
--
--    `schools_update_platform` lets a platform admin UPDATE public.schools
--    straight over the REST API. Every operator write is supposed to go through a
--    SECURITY DEFINER function, because that is where the reason is demanded and
--    the row is written to operator_actions. A direct UPDATE writes no audit row
--    at all. Dropped.
--
--    Dropping it takes nothing away. The definer functions bypass RLS by
--    definition, so fn_platform_suspend_school and the rest are unaffected, and
--    no code anywhere issues a direct update to that table.
--
--    THIS SECTION FIRST SHIPPED WITH A GUARD BUILT ON A FALSE PREMISE, and the
--    premise was false on every real deployment. It read:
--
--        `authenticated` has no UPDATE privilege on that table at all, so the
--        policy has never been reachable
--
--        if has_table_privilege('authenticated', 'public.schools', 'update') then
--          raise exception '... Do not drop it blind ...'
--
--    That is true of a bare Postgres and FALSE of Supabase. A Supabase project is
--    created with
--
--        alter default privileges in schema public
--          grant all on tables to postgres, anon, authenticated, service_role;
--
--    so every table our migrations create there is granted to `authenticated`
--    automatically — `schools` included. The guard therefore fired on the real
--    thing and aborted the whole bundle, while passing in CI and on every local
--    stub, because neither has that default ACL.
--
--    Two lessons, both worth more than the fix:
--
--      * A guard whose condition is a PRIVILEGE is a guard that behaves
--        differently on Supabase than in CI. The question worth asking was never
--        "does the grant exist" but "is there a caller" — and there is none.
--      * The local harness must carry Supabase's default privileges or it is not
--        a faithful stub. It does now, and that is how this was reproduced.
--
-- 3. TWO TABLES AND TWO COLUMNS NOTHING HAS EVER USED
--
--    `campuses` and `shifts` were created in 0001 and are referenced by exactly
--    two things: classes.campus_id and classes.shift_id. No function reads
--    either. No screen writes either. Every install has zero rows in both,
--    because there has never been a way to create one.
--
--    They are carried by every catalogue sweep in the test suite, they appear in
--    the export list a school downloads, and they suggest a multi-campus feature
--    that does not exist. Dropped — GUARDED, so a database that somehow has rows
--    stops and says so rather than destroying them.
--
--    Multi-campus is a real request from larger schools and it will come back.
--    When it does it needs designing properly: a campus that owns sections,
--    staff, a fee structure and its own receipt series is not two nullable
--    columns on `classes`. Two empty tables are not a head start on that.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The verdict reaches the parent
--
-- Nothing new is computed. Every field here was already frozen onto the card
-- when it was generated, which matters: a portal that recomputed a pass mark
-- could disagree with the certificate the school printed, and the printed one is
-- the one the family is holding.
-- ---------------------------------------------------------------------------
create or replace function public.fn_portal_child_results(p_student_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  perform public.fn__assert_my_child(p_student_id);

  select coalesce(jsonb_agg(
           case when x.withheld then
             jsonb_build_object(
               'result_card_id', x.id, 'term', x.term, 'withheld', true,
               'message', 'Result withheld until outstanding fees are cleared.',
               'issued_at', x.issued_at)
           else
             jsonb_build_object(
               'result_card_id', x.id, 'term', x.term, 'withheld', false,
               'obtained_marks', x.total_marks, 'total_marks', x.total_max,
               'percentage', x.percentage, 'grade', x.grade,
               'position', x.position, 'attendance_pct', x.attendance_pct,
               -- THE VERDICT. Read straight out of the frozen snapshot, so the
               -- portal and the printed card cannot disagree — the printed one is
               -- what the family is holding.
               'result', x.frozen->>'result',
               'failed_subjects', (x.frozen->>'failed_subjects')::integer,
               'pass_percent', (x.frozen->>'pass_percent')::numeric,
               -- A provisional card must SAY so. Its percentage is computed over
               -- the marked papers only, and a parent shown 78% with no warning
               -- has been told something that is not the final figure.
               'provisional', coalesce((x.frozen->>'provisional')::boolean, false),
               'unmarked_subjects', coalesce((x.frozen->>'unmarked_subjects')::integer, 0),
               -- On a board class the registration number is the thing a parent
               -- checks hardest, because a wrong one is a real problem in March.
               'stream', x.frozen->>'stream',
               'bise_reg_no', x.frozen->>'bise_reg_no',
               'subjects', coalesce(x.frozen->'subjects', '[]'::jsonb),
               'issued_at', x.issued_at)
           end
           order by x.issued_at desc), '[]'::jsonb)
    into v_out
  from (
    select distinct on (rc.exam_term_id)
           rc.id, et.name as term, rc.total_marks, rc.total_max, rc.percentage,
           rc.grade, rc.position, rc.attendance_pct, rc.frozen,
           rc.published_at as issued_at,
           coalesce((rc.frozen->>'withheld')::boolean, false) as withheld
    from public.result_cards rc
    join public.exam_terms et on et.id = rc.exam_term_id
    where rc.student_id = p_student_id
      and rc.published_at is not null
    order by rc.exam_term_id, rc.version desc
  ) x;

  return coalesce(v_out, '[]'::jsonb);
end;
$$;

grant  execute on function public.fn_portal_child_results(uuid) to authenticated;
revoke execute on function public.fn_portal_child_results(uuid) from public, anon;

-- ---------------------------------------------------------------------------
-- 2. The policy that could never fire
-- ---------------------------------------------------------------------------
do $deadpolicy$
begin
  if exists (select 1 from pg_policies
              where schemaname = 'public' and tablename = 'schools'
                and policyname = 'schools_update_platform') then
    drop policy schools_update_platform on public.schools;
    raise notice
      '0083: dropped schools_update_platform — an operator UPDATE over REST '
      'writes no audit row; the definer functions bypass RLS and still work';
  end if;
end $deadpolicy$;

-- The END STATE, asserted rather than assumed.
--
-- Not "did my DROP run" but "is there any UPDATE policy on this table now" —
-- which is the property that actually matters and catches a second policy added
-- under another name. With none, an UPDATE over REST matches nothing and is
-- refused, whatever privileges the role happens to hold.
do $assert$
declare v_left text;
begin
  select string_agg(policyname, ', ') into v_left
    from pg_policies
   where schemaname = 'public' and tablename = 'schools' and cmd = 'UPDATE';
  if v_left is not null then
    raise exception
      '0083: public.schools still has an UPDATE policy (%). Every operator write '
      'must go through a SECURITY DEFINER function so the reason and the actor '
      'are recorded in operator_actions.', v_left;
  end if;
end $assert$;

-- ---------------------------------------------------------------------------
-- 3. campuses and shifts
--
-- Guarded on being empty. A destructive migration that assumes its own premise
-- is how a school loses data it turns out to have had.
-- ---------------------------------------------------------------------------
do $dead$
declare v_c bigint := 0; v_s bigint := 0; v_used bigint := 0;
begin
  if to_regclass('public.campuses') is null and to_regclass('public.shifts') is null then
    return;                                   -- already gone
  end if;

  if to_regclass('public.campuses') is not null then
    execute 'select count(*) from public.campuses' into v_c;
  end if;
  if to_regclass('public.shifts') is not null then
    execute 'select count(*) from public.shifts' into v_s;
  end if;
  select count(*) into v_used from public.classes
   where campus_id is not null or shift_id is not null;

  if v_c > 0 or v_s > 0 or v_used > 0 then
    -- NOT dropped, and the migration does not fail either: a school that somehow
    -- has campus rows must keep working, and the operator needs to know before
    -- anything is destroyed.
    raise notice
      '0083: NOT dropping campuses/shifts — % campus(es), % shift(s) and % class(es) '
      'reference them. Something created rows there. Look before removing them.',
      v_c, v_s, v_used;
    return;
  end if;

  -- The columns first: dropping the tables while classes still points at them
  -- would fail on the foreign keys.
  alter table public.classes drop column if exists campus_id;
  alter table public.classes drop column if exists shift_id;
  drop table if exists public.shifts;
  drop table if exists public.campuses;
  raise notice '0083: dropped campuses and shifts — empty, unreferenced, and no screen ever wrote to them';
end $dead$;

-- ─────────────────────────────────────────────────────────────────────────
-- 0084_receipt_allocation_detail.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0084 — A family receipt that does not say which child it paid for
--
-- FamilyCollect.tsx's own header has said this since it was written:
--
--     "Allocation is oldest-month-first across siblings and is NOT silent: the
--      result panel names every invoice the money cleared. Silent allocation is
--      what causes arguments at the counter."
--
-- It was not true. fn_record_family_payment returns four numbers — payment_id,
-- receipt_no, allocated, credit — and nothing about WHERE the money went. The
-- panel showed "Rs 9,000 applied to outstanding fees" and the printed receipt
-- said the same. A father paying for three children could not tell from it which
-- child's dues had moved, which is exactly the argument the comment claims to
-- have prevented.
--
-- The data was always there. fn__allocate_payment writes a row into
-- payment_allocations for every invoice it touches; nothing read them back.
--
-- WHAT THIS CHANGES
--
-- Both payment functions now return an `applied` array: one entry per invoice
-- the money cleared, carrying the student, the GR number, the month and the
-- amount. Ordered the way the allocator walks — oldest month first — so the
-- receipt reads in the order the clerk can explain.
--
-- Adding a key to a jsonb result is safe for every existing caller: the web
-- client destructures the keys it knows and ignores the rest, and both functions
-- keep their signature, so no grant or policy moves.
--
-- WHY NOT COMPUTE IT IN THE BROWSER
--
-- Because it would have to guess. The allocator's order is
-- `period_month nulls first, student_id, invoice_id` and its "paid vs partial"
-- decision reads invoice_balances, a view. A second implementation in
-- TypeScript would agree with it until the day it did not, and the day it did
-- not would be visible only on a printed receipt in a parent's hand.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- The shared reader.
--
-- Internal, and revoked from everyone — but SCOPED ANYWAY, on the caller's own
-- school. The first version filtered on the payment id alone, reasoning that
-- both callers had just created the payment themselves so the id could not be
-- anyone else's. dashboard.sql's assertion 20 rejected it, and the assertion is
-- right: a SECURITY DEFINER function bypasses RLS, so "the id is trustworthy
-- because of who calls it today" is a property of today's callers, not of this
-- function. Pass a foreign payment id and it would have handed back another
-- school's children's names, GR numbers and the exact amounts their parents
-- paid. It now returns an empty array instead.
-- ---------------------------------------------------------------------------
create or replace function public.fn__payment_applied(p_payment_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x.period_month nulls first, x.student_name, x.amount), '[]'::jsonb)
  from (
    select s.id            as student_id,
           s.full_name     as student_name,
           s.gr_no         as gr_no,
           i.period_month  as period_month,
           pa.amount       as amount
    from public.payment_allocations pa
    join public.invoices i on i.id = pa.invoice_id
    join public.students s on s.id = i.student_id
    where pa.payment_id = p_payment_id
      and i.school_id = public.current_school_id()
      and s.school_id = public.current_school_id()
  ) x;
$$;

revoke all on function public.fn__payment_applied(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Single student.
--
-- Rewritten programmatically rather than restated, so that a change made to
-- this function between 0031 and today cannot be silently reverted by a copy
-- pasted out of an old migration. That has happened in this repository before.
-- ---------------------------------------------------------------------------
do $rw$
declare v_old text; v_new text;
begin
  v_old := pg_get_functiondef(
    'public.fn_record_payment(uuid, numeric, public.payment_method, text, boolean)'::regprocedure);

  -- Already carries it: nothing to do, and the assertions below still run.
  if v_old like '%fn__payment_applied%' then
    raise notice '0084: fn_record_payment already returns the allocation detail';
  else
    v_new := replace(v_old,
      $q$    'allocated', p_amount - v_left, 'unallocated', v_left, 'pending', false);$q$,
      $q$    'allocated', p_amount - v_left, 'unallocated', v_left, 'pending', false,
    'applied', public.fn__payment_applied(v_pay));$q$);

    if v_new = v_old then
      raise exception
        '0084: could not find the return statement in fn_record_payment. It has '
        'been edited since 0031 — read it and place the applied key by hand '
        'rather than letting this migration report success.';
    end if;
    execute v_new;
  end if;

  -- The END STATE, asserted. A rewrite that silently matched nothing is the
  -- failure mode this guards.
  if pg_get_functiondef(
       'public.fn_record_payment(uuid, numeric, public.payment_method, text, boolean)'::regprocedure)
     not like '%fn__payment_applied%' then
    raise exception '0084: fn_record_payment still does not return the allocation detail';
  end if;
end $rw$;

-- ---------------------------------------------------------------------------
-- The family. Same treatment.
-- ---------------------------------------------------------------------------
do $rw$
declare v_old text; v_new text;
begin
  v_old := pg_get_functiondef(
    'public.fn_record_family_payment(uuid, numeric, public.payment_method, text, boolean)'::regprocedure);

  if v_old like '%fn__payment_applied%' then
    raise notice '0084: fn_record_family_payment already returns the allocation detail';
  else
    v_new := replace(v_old,
      $q$    'family_outstanding', public.family_outstanding(p_family_id),
    'pending', false);$q$,
      $q$    'family_outstanding', public.family_outstanding(p_family_id),
    'applied', public.fn__payment_applied(v_pay),
    'pending', false);$q$);

    if v_new = v_old then
      raise exception
        '0084: could not find the return statement in fn_record_family_payment. '
        'It has been edited since 0031 — place the applied key by hand.';
    end if;
    execute v_new;
  end if;

  if pg_get_functiondef(
       'public.fn_record_family_payment(uuid, numeric, public.payment_method, text, boolean)'::regprocedure)
     not like '%fn__payment_applied%' then
    raise exception '0084: fn_record_family_payment still does not return the allocation detail';
  end if;
end $rw$;

-- `create or replace` PRESERVES an existing ACL, and these two were rewritten
-- through pg_get_functiondef which restates the definition without its grants.
-- Restated explicitly so a future reader does not have to work out which of
-- those two facts applied here.
grant  execute on function public.fn_record_payment(uuid, numeric, public.payment_method, text, boolean) to authenticated;
revoke execute on function public.fn_record_payment(uuid, numeric, public.payment_method, text, boolean) from public, anon;
grant  execute on function public.fn_record_family_payment(uuid, numeric, public.payment_method, text, boolean) to authenticated;
revoke execute on function public.fn_record_family_payment(uuid, numeric, public.payment_method, text, boolean) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0085_subject_teachers.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0085 — Any teacher could write any class's exam marks
--
-- THE DEFECT, found by comparing the two mark-entry functions rather than by
-- reading either one.
--
-- fn_enter_assessment_marks (weekly tests) has scoped its caller since 0048:
--
--     if not public.has_role('owner','principal','admin_clerk') then
--       if not public.fn_may_manage_class(v_a.session_id, v_a.class_id, v_a.section_id) then
--         raise exception 'You can only enter marks for your assigned class';
--
-- fn_enter_marks (EXAM marks — the ones that go on the result card, the
-- certificate and the tabulation sheet sent to the board) has never had that
-- check. Not in 0005, not in 0048, not in 0058. Its only gate is has_role, so
-- ANY class_teacher or subject_teacher in the school could enter or overwrite
-- the exam marks of ANY class in ANY subject.
--
-- The asymmetry is what makes it indefensible: the guarded path is the one whose
-- marks nobody keeps, and the unguarded path is the one a family frames. A
-- teacher with a grudge, or simply the wrong class selected in a dropdown, could
-- rewrite a Class 10 board result. mark_entries records corrected_from and a
-- reason, so the change would be visible afterwards — but only if somebody knew
-- to look, and the marks would already have been printed.
--
-- WHAT SUBJECT-LEVEL ASSIGNMENT ADDS
--
-- The user_role enum has carried `subject_teacher` since 0001 and nothing has
-- ever recorded WHICH subjects. So even after the class gate above, the Physics
-- teacher of Class 9 could enter Class 9's Islamiat marks. `subject_teachers`
-- closes that, and gives the school the register it has to keep anyway: who
-- teaches what, this session.
--
-- THE RULE, stated once here and implemented in exactly one function:
--
--   owner / principal / admin_clerk    any class, any subject
--   anybody else                       a class they are the class teacher of
--                                      (teacher_assignments), OR a class+subject
--                                      they are the subject teacher of
--                                      (subject_teachers)
--
-- Deliberately NOT keyed on which of the two teaching roles the person holds.
-- profiles.role is a single value, and the class teacher of 5-B who also teaches
-- Maths to Class 8 is the normal case in a Pakistani school, not an exception.
-- Keying on the role name would have locked that person out of one of their two
-- jobs depending on which label the office happened to pick.
--
-- WHY THIS IS SAFE TO TIGHTEN NOW. No school is live yet (verify.sql still
-- reports "no schools yet, as expected"), so nobody loses a working path. On a
-- populated database the effect would be that a teacher with no assignment can
-- no longer enter marks — which is the intended behaviour and is why the error
-- message names the screen that fixes it instead of saying "permission denied".
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Who teaches what
-- ---------------------------------------------------------------------------
create table if not exists public.subject_teachers (
  id          uuid primary key default gen_random_uuid(),
  staff_id    uuid not null references public.staff(id) on delete cascade,
  session_id  uuid not null references public.academic_sessions(id) on delete cascade,
  class_id    uuid not null references public.classes(id) on delete cascade,
  -- Null means every section of the class, which is how a single-section school
  -- and a subject taught across all sections both work without ceremony.
  section_id  uuid          references public.sections(id) on delete cascade,
  subject_id  uuid not null references public.subjects(id) on delete cascade,
  created_by  uuid          references public.profiles(id),
  created_at  timestamptz not null default now(),
  school_id   uuid not null references public.schools(id) on delete cascade
);

-- Two teachers CAN share a subject (a split section, a maternity cover), so the
-- key is the whole tuple rather than the class+subject.
create unique index if not exists uq_subject_teacher
  on public.subject_teachers (staff_id, session_id, class_id, subject_id, section_id)
  where section_id is not null;
-- Postgres treats NULLs as distinct in a unique index, so the section-wide row
-- needs its own partial index or the same teacher could be added twice.
create unique index if not exists uq_subject_teacher_allsections
  on public.subject_teachers (staff_id, session_id, class_id, subject_id)
  where section_id is null;

create index if not exists idx_subject_teacher_staff
  on public.subject_teachers (staff_id, session_id);
create index if not exists idx_subject_teacher_class
  on public.subject_teachers (session_id, class_id, subject_id);
create index if not exists idx_subject_teachers_school
  on public.subject_teachers (school_id);

alter table public.subject_teachers enable row level security;

-- school_id is stamped by the same trigger every other tenant table uses, so a
-- client cannot insert a row into another school by supplying its id.
do $stamp$
begin
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.subject_teachers'::regclass
                    and tgname = 'trg_subject_teachers_school') then
    execute 'create trigger trg_subject_teachers_school
               before insert or update on public.subject_teachers
               for each row execute function public.enforce_school_id()';
  end if;
end $stamp$;

drop policy if exists subject_teachers_select on public.subject_teachers;
create policy subject_teachers_select on public.subject_teachers
  for select to authenticated
  using (school_id = public.current_school_id() and public.is_staff());

drop policy if exists subject_teachers_write on public.subject_teachers;
create policy subject_teachers_write on public.subject_teachers
  for all to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'admin_clerk'))
  with check (school_id = public.current_school_id()
              and public.has_role('owner', 'principal', 'admin_clerk'));

-- ---------------------------------------------------------------------------
-- 2. The one function that decides
--
-- fn_may_manage_class already answers "is this my class". This is its
-- subject-aware sibling, and every caller below uses THIS one so the rule cannot
-- drift between the exam path and the assessment path — which is exactly how the
-- defect in the header came to exist.
-- ---------------------------------------------------------------------------
create or replace function public.fn_may_mark_subject(
  p_session uuid, p_class uuid, p_section uuid, p_subject uuid
) returns boolean language sql stable security definer set search_path = public as $$
  -- Every id must belong to the caller's school first. Without this the
  -- existence checks below could be satisfied by another school's rows.
  select exists (select 1 from public.academic_sessions s
                  where s.id = p_session and s.school_id = public.current_school_id())
     and exists (select 1 from public.classes c
                  where c.id = p_class and c.school_id = public.current_school_id())
     and (p_section is null or exists (select 1 from public.sections sec
                  where sec.id = p_section and sec.school_id = public.current_school_id()))
     and (p_subject is null or exists (select 1 from public.subjects sub
                  where sub.id = p_subject and sub.school_id = public.current_school_id()))
     and (
       public.has_role('owner', 'principal', 'admin_clerk')
       -- The class teacher of the class: every subject in it. A class teacher
       -- fills in the whole card when a colleague is away, and a school that
       -- could not do that would keep the office password on a sticky note.
       or exists (
         select 1
         from public.teacher_assignments ta
         join public.profiles pr on pr.staff_id = ta.staff_id
         where pr.id = auth.uid()
           and ta.school_id = public.current_school_id()
           and ta.session_id = p_session
           and ta.class_id = p_class
           -- NULL MEANS "ANY" ON BOTH SIDES, and getting this wrong is what the
           -- first version did. An assignment with no section covers the whole
           -- class; a QUERY with no section is asking about the whole class —
           -- which is exactly what the exam path asks, because an exam_subject
           -- is set for a class and not for a section. Written as
           -- `ta.section_id is not distinct from p_section` it meant only the
           -- first of those, so the class teacher of 9-A could not mark 9's own
           -- exam paper. Caught by assertion 2 of subject_teachers.sql, not by
           -- reading this back.
           and (p_section is null or ta.section_id is null or ta.section_id = p_section)
       )
       -- Or the subject teacher of this class and subject.
       or exists (
         select 1
         from public.subject_teachers st
         join public.profiles pr on pr.staff_id = st.staff_id
         where pr.id = auth.uid()
           and st.school_id = public.current_school_id()
           and st.session_id = p_session
           and st.class_id = p_class
           and st.subject_id = p_subject
           and (p_section is null or st.section_id is null or st.section_id = p_section)
       )
     );
$$;

grant  execute on function public.fn_may_mark_subject(uuid, uuid, uuid, uuid) to authenticated;
revoke execute on function public.fn_may_mark_subject(uuid, uuid, uuid, uuid) from public, anon;

-- ---------------------------------------------------------------------------
-- 3. Close the hole in fn_enter_marks
--
-- Rewritten programmatically from its own current definition rather than
-- restated. A restatement copied out of 0058 would silently revert anything
-- changed since, and that has happened in this repository before.
-- ---------------------------------------------------------------------------
do $rw$
declare v_old text; v_new text;
begin
  v_old := pg_get_functiondef('public.fn_enter_marks(uuid, jsonb, text)'::regprocedure);

  if v_old like '%fn_may_mark_subject%' then
    raise notice '0085: fn_enter_marks already checks the teacher''s subject';
  else
    v_new := replace(v_old,
      '  perform public.assert_own(''exam_subjects'', p_exam_subject_id);',
      '  perform public.assert_own(''exam_subjects'', p_exam_subject_id);

  -- 0085. THE HOLE: this function had no class scope at all, while its sibling
  -- fn_enter_assessment_marks has had one since 0048 — so the marks nobody keeps
  -- were guarded and the marks that go on the result card were not.
  --
  -- Section is deliberately null here: an exam_subject is set for a CLASS, not a
  -- section, so the paper covers every section of it. fn_may_mark_subject treats
  -- a null on EITHER side as "any section", so a teacher assigned to 9-A still
  -- matches a paper set for the whole of Class 9.
  if not public.has_role(''owner'', ''principal'', ''admin_clerk'') then
    if not public.fn_may_mark_subject(
             (select et.session_id from public.exam_subjects es
                join public.exam_terms et on et.id = es.exam_term_id
               where es.id = p_exam_subject_id),
             (select es.class_id   from public.exam_subjects es where es.id = p_exam_subject_id),
             null,
             (select es.subject_id from public.exam_subjects es where es.id = p_exam_subject_id))
    then
      raise exception ''You can only enter marks for a class and subject you teach. ''
        ''Ask the office to add you under Settings, Staff, Subject Teachers.''
        using errcode = ''42501'';
    end if;
  end if;');

    if v_new = v_old then
      raise exception
        '0085: could not find the assert_own line in fn_enter_marks. It has been '
        'edited — add the fn_may_mark_subject gate by hand rather than letting '
        'this migration report success on a function it did not change.';
    end if;
    execute v_new;
  end if;

  if pg_get_functiondef('public.fn_enter_marks(uuid, jsonb, text)'::regprocedure)
     not like '%fn_may_mark_subject%' then
    raise exception '0085: fn_enter_marks still has no subject scope';
  end if;
end $rw$;

grant  execute on function public.fn_enter_marks(uuid, jsonb, text) to authenticated;
revoke execute on function public.fn_enter_marks(uuid, jsonb, text) from public, anon;

-- ---------------------------------------------------------------------------
-- 4. And narrow the assessment path from class to class+subject
--
-- It was already scoped to the class. This upgrades it to the same rule as the
-- exam path so there is one answer to "may I mark this", not two.
-- ---------------------------------------------------------------------------
do $rw$
declare v_old text; v_new text;
begin
  v_old := pg_get_functiondef(
    'public.fn_enter_assessment_marks(uuid, jsonb, text)'::regprocedure);

  if v_old like '%fn_may_mark_subject%' then
    raise notice '0085: fn_enter_assessment_marks already checks the subject';
  else
    -- WHITESPACE-BLIND, and this was not always so. The pattern used to be a
    -- literal string spanning three lines of THIS FILE, which means it carried
    -- this file's line endings and matched only a stored body that had arrived
    -- by the same route. 0101 shipped the same class of assumption in a form
    -- that could not agree with anything -- E'\n', which is always a bare line
    -- feed -- and it took all seven migrations of bundle 12 down on a live
    -- school. Every line break in the pattern is `\s+` now, so a space, a tab,
    -- an LF and a CRLF are all the same to it. supabase/check-patch-anchors.py
    -- fails the build if this is written the old way again.
    v_new := regexp_replace(v_old,
      'if not public\.fn_may_manage_class\(v_a\.session_id, v_a\.class_id, v_a\.section_id\) then\s+'
        || 'raise exception ''You can only enter marks for your assigned class'';\s+'
        || 'end if;',
      '-- 0085: class AND subject. The class check alone let the Physics
    -- teacher of Class 9 enter Class 9''s Islamiat marks.
    if not public.fn_may_mark_subject(
             v_a.session_id, v_a.class_id, v_a.section_id, v_a.subject_id) then
      raise exception ''You can only enter marks for a class and subject you teach. ''
        ''Ask the office to add you under Settings, Staff, Subject Teachers.''
        using errcode = ''42501'';
    end if;');

    if v_new = v_old then
      raise exception
        '0085: could not find the class-scope check in fn_enter_assessment_marks.';
    end if;
    execute v_new;
  end if;

  if pg_get_functiondef('public.fn_enter_assessment_marks(uuid, jsonb, text)'::regprocedure)
     not like '%fn_may_mark_subject%' then
    raise exception '0085: fn_enter_assessment_marks still has no subject scope';
  end if;
end $rw$;

grant  execute on function public.fn_enter_assessment_marks(uuid, jsonb, text) to authenticated;
revoke execute on function public.fn_enter_assessment_marks(uuid, jsonb, text) from public, anon;

-- ---------------------------------------------------------------------------
-- 5. The direct-table backstop
--
-- 0001 grants INSERT/UPDATE on every table in public to `authenticated`, held
-- shut only by RLS. The two functions above are the app's path, but a signed-in
-- teacher with the anon key can POST straight at /rest/v1/mark_entries — so the
-- policy has to carry the same rule, or the gate is a suggestion.
--
-- The parent row supplies the class and subject; a mark row on its own does not
-- know either.
-- ---------------------------------------------------------------------------
-- NOT named fn__ and NOT revoked, unlike most helpers in this schema — and the
-- reason is worth stating because the first version got it wrong and the test
-- caught it. A policy expression is evaluated AS THE QUERYING USER, so a policy
-- that calls a function `authenticated` cannot execute does not fail closed: it
-- fails with `permission denied for function`, and the table becomes unusable
-- the moment somebody grants INSERT on it. fn_may_manage_class and
-- fn_may_mark_subject are granted for exactly the same reason. They are safe to
-- grant because they answer only about the CALLER's own permissions and return a
-- boolean — no row from any table reaches the caller through them.
create or replace function public.fn_may_mark_row(
  p_assessment_id uuid, p_exam_subject_id uuid
) returns boolean language sql stable security definer set search_path = public as $$
  -- Every subselect carries `school_id = current_school_id()`. Not belt and
  -- braces: without it a foreign assessment id would resolve to THAT school's
  -- session, class and subject, and this function would be handing another
  -- school's row identifiers to fn_may_mark_subject. It would still answer
  -- false — fn_may_mark_subject checks the ids belong to the caller's school —
  -- so the door stays shut, but the reads themselves would be unscoped inside a
  -- SECURITY DEFINER function, which is precisely what dashboard.sql's assertion
  -- 20 refuses. Failing closed by accident is not the same as being scoped.
  select case
    when p_assessment_id is not null then
      public.fn_may_mark_subject(
        (select a.session_id from public.assessments a
          where a.id = p_assessment_id and a.school_id = public.current_school_id()),
        (select a.class_id   from public.assessments a
          where a.id = p_assessment_id and a.school_id = public.current_school_id()),
        (select a.section_id from public.assessments a
          where a.id = p_assessment_id and a.school_id = public.current_school_id()),
        (select a.subject_id from public.assessments a
          where a.id = p_assessment_id and a.school_id = public.current_school_id()))
    when p_exam_subject_id is not null then
      public.fn_may_mark_subject(
        (select et.session_id from public.exam_subjects es
           join public.exam_terms et on et.id = es.exam_term_id
          where es.id = p_exam_subject_id
            and es.school_id = public.current_school_id()
            and et.school_id = public.current_school_id()),
        (select es.class_id   from public.exam_subjects es
          where es.id = p_exam_subject_id and es.school_id = public.current_school_id()),
        null,
        (select es.subject_id from public.exam_subjects es
          where es.id = p_exam_subject_id and es.school_id = public.current_school_id()))
    -- Neither parent set. mark_one_parent forbids it, so this is unreachable —
    -- and it returns false rather than true, because an unreachable branch that
    -- grants access is how an unreachable branch becomes reachable.
    else false
  end;
$$;

grant  execute on function public.fn_may_mark_row(uuid, uuid) to authenticated;
revoke execute on function public.fn_may_mark_row(uuid, uuid) from public, anon;


drop policy if exists marks_insert on public.mark_entries;
create policy marks_insert on public.mark_entries
  for insert to authenticated
  with check (
    school_id = public.current_school_id()
    and (
      public.has_role('owner', 'principal', 'admin_clerk')
      or (public.has_role('class_teacher', 'subject_teacher')
          and public.fn_may_mark_row(assessment_id, exam_subject_id))
    ));

drop policy if exists marks_update on public.mark_entries;
create policy marks_update on public.mark_entries
  for update to authenticated
  using (
    school_id = public.current_school_id()
    and not is_locked
    and (
      public.has_role('owner', 'principal', 'admin_clerk')
      or (public.has_role('class_teacher', 'subject_teacher')
          and public.fn_may_mark_row(assessment_id, exam_subject_id))
    ))
  with check (
    school_id = public.current_school_id()
    and (
      public.has_role('owner', 'principal', 'admin_clerk')
      or (public.has_role('class_teacher', 'subject_teacher')
          and public.fn_may_mark_row(assessment_id, exam_subject_id))
    ));

-- The misnamed first version of the helper, if a copy of this migration with the
-- fn__ name was ever applied.
--
-- AFTER the policies, not before, and that ordering is load-bearing: a policy
-- records a hard dependency on every function its expression names, so dropping
-- it first fails with "cannot drop function because other objects depend on it"
-- and takes the rest of this file down with it. DROP ... CASCADE would have
-- "fixed" that by silently deleting both policies and leaving the table open.
drop function if exists public.fn__may_mark_row(uuid, uuid);

-- ---------------------------------------------------------------------------
-- 6. Setting and reading the register
-- ---------------------------------------------------------------------------

-- Replace-set for ONE class+subject+section. Replace rather than add, because
-- the screen shows the current holders and sends back the list it wants — an
-- add-only function would make removing a teacher impossible from that screen,
-- which is how the class-teacher UI would have gone wrong too.
create or replace function public.fn_set_subject_teachers(
  p_session_id uuid, p_class_id uuid, p_section_id uuid,
  p_subject_id uuid, p_staff_ids uuid[]
) returns integer language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_n integer := 0;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Only the office may assign subject teachers';
  end if;
  -- Every id guarded: the DELETE below is scoped by session/class/subject, so
  -- another school's ids would clear THEIR register.
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);
  perform public.assert_own('subjects', p_subject_id);
  if p_section_id is not null then
    perform public.assert_own('sections', p_section_id);
  end if;

  -- The subject must belong to the class it is being taught in. subjects.class_id
  -- exists, so a mismatch here is a typo the office cannot see the consequence
  -- of: marks would be enterable for a paper that class never sits.
  if not exists (select 1 from public.subjects s
                  where s.id = p_subject_id and s.class_id = p_class_id) then
    raise exception 'That subject does not belong to that class';
  end if;

  delete from public.subject_teachers
   where session_id = p_session_id
     and class_id = p_class_id
     and subject_id = p_subject_id
     and section_id is not distinct from p_section_id
     and school_id = public.current_school_id();

  if p_staff_ids is not null then
    foreach v_id in array p_staff_ids loop
      perform public.assert_own('staff', v_id);
      insert into public.subject_teachers
        (staff_id, session_id, class_id, section_id, subject_id, created_by)
      values (v_id, p_session_id, p_class_id, p_section_id, p_subject_id, auth.uid())
      on conflict do nothing;
      v_n := v_n + 1;
    end loop;
  end if;

  return v_n;
end;
$$;

grant  execute on function public.fn_set_subject_teachers(uuid, uuid, uuid, uuid, uuid[]) to authenticated;
revoke execute on function public.fn_set_subject_teachers(uuid, uuid, uuid, uuid, uuid[]) from public, anon;

-- The whole register for a session: one row per class+subject, with whoever
-- teaches it. Returned even for subjects with nobody assigned, because the empty
-- rows are the work list — a screen that only showed filled rows would hide the
-- thing the office opened it to do.
create or replace function public.fn_subject_teachers(p_session_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  if not public.is_staff() then
    raise exception 'Not permitted';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  select coalesce(jsonb_agg(x order by x.level_order, x.class_name, x.sort_order, x.subject_name), '[]'::jsonb)
    into v_out
  from (
    select c.id            as class_id,
           c.name          as class_name,
           c.level_order   as level_order,
           sub.id          as subject_id,
           sub.name        as subject_name,
           sub.sort_order  as sort_order,
           coalesce((
             select jsonb_agg(jsonb_build_object(
                      'assignment_id', st.id,
                      'staff_id', st.staff_id,
                      'staff_name', stf.full_name,
                      'section_id', st.section_id,
                      'section_name', sec.name)
                    order by stf.full_name)
             from public.subject_teachers st
             join public.staff stf on stf.id = st.staff_id
             left join public.sections sec on sec.id = st.section_id
             where st.session_id = p_session_id
               and st.class_id = c.id
               and st.subject_id = sub.id
               and st.school_id = public.current_school_id()
           ), '[]'::jsonb) as teachers
    from public.classes c
    join public.subjects sub on sub.class_id = c.id
                            and sub.school_id = public.current_school_id()
    where c.school_id = public.current_school_id()
      and c.active
  ) x;

  return jsonb_build_object('session_id', p_session_id, 'rows', v_out);
end;
$$;

grant  execute on function public.fn_subject_teachers(uuid) to authenticated;
revoke execute on function public.fn_subject_teachers(uuid) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0086_write_boundary.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0086 — Every audited function in this project was optional
--
-- WHAT WAS PROVED, ON A REAL DATABASE, BEFORE ANYTHING HERE WAS WRITTEN
--
-- One school, one child, Rs 4,500 charged and paid in full through the counter,
-- one exam paper marked 88 and the result card published. Then a signed-in
-- `admin_clerk` — an ordinary front-office login, not an owner, not a platform
-- admin — issued PLAIN TABLE WRITES. No SECURITY DEFINER function is involved
-- in any line below; these are exactly the requests supabase-js sends for
-- `sb.from('x').update(...)` and `.delete()`, which means any clerk with the
-- anon key and their own password can send them from a browser console:
--
--   delete from payment_allocations where invoice_id = …
--     → ALLOWED. Balance went from 0 back to Rs 4,500 while the receipt for
--       Rs 4,500 still sat in the payments table. The family can now be made to
--       pay twice for money the school has already taken.
--
--   insert into payment_allocations (payment_id, invoice_id, amount) values (…)
--     → ALLOWED. An unpaid challan shows settled with no money received. This
--       is the cash-theft path in full: pocket the notes, record no payment,
--       point an allocation at the challan, and the ledger balances.
--
--   update result_cards set percentage = 12, grade = 'F', frozen = …
--     → ALLOWED. A PUBLISHED card, already visible to the parent, rewritten
--       from 88% to 12% / FAIL.
--
--   delete from result_cards where id = …            → ALLOWED.
--   update invoice_lines set amount = 1              → ALLOWED (from Rs 4,500).
--   update invoices set status = 'void'              → ALLOWED. Balance to 0.
--   delete from invoices where id = …                → ALLOWED. No trace left.
--
--   select count(*) from audit_log                   → 0.
--
-- Not one of those wrote an audit row, demanded a reason, or touched a serial.
--
-- WHY IT WAS INVISIBLE
--
-- Because everything above it was built correctly. `fn_record_payment` takes a
-- till session. `fn_reverse_payment` writes a contra receipt rather than editing
-- one. `fn_issue_certificate` freezes a snapshot and burns a gapless serial.
-- `fn_add_discount` records who approved it. `fn_generate_result_cards` refuses
-- to print a plausible wrong card. Every one of those is real work and every one
-- of them was a formality, because the tables underneath carried
--
--   POLICY invoices_write FOR ALL USING (school_id = current_school_id()
--                                        AND has_role('owner','principal',
--                                                     'admin_clerk','accountant'))
--
-- and twelve more like it. The policies are tenant-correct and role-correct —
-- that is exactly why they read as finished. What they never asked is whether
-- the WRITE ITSELF should be possible outside the one function that owns it.
--
-- The project already had the right answer written down for the operator side.
-- 0083 dropped `schools_update_platform` for this precise reason: "an operator
-- UPDATE over REST writes no audit row". The same sentence was true of thirteen
-- tenant tables holding the school's money, and nobody applied it there.
--
-- THE FIX IS A PRIVILEGE, NOT A POLICY
--
-- A policy decides which rows a permitted write may touch. It cannot say "this
-- table is not writable from a session". A missing GRANT can, and it cannot be
-- worked around by adding another policy later, which is the failure mode worth
-- designing against — the next person to add a table write adds a policy, not a
-- grant.
--
-- SECURITY DEFINER functions are unaffected. Every one of them is owned by
-- `postgres`, which owns the tables too, so they keep writing exactly as before.
-- That is the whole shape of the fix: the only way in is the door that asks for
-- a reason and signs the register.
--
-- SUPABASE MAKES THIS NECESSARY AND EASY TO MISS. A Supabase project is created
-- with
--
--     alter default privileges in schema public
--       grant all on tables to postgres, anon, authenticated, service_role;
--
-- so every table these migrations create is handed to `anon` and
-- `authenticated` automatically. Nothing in this repository asked for that and
-- nothing was checking it — the lesson 0083 recorded, now applied rather than
-- noted. The assertions at the foot of this file are therefore about
-- PRIVILEGES, which is where the truth is, and they run on every deployment.
--
-- WHAT DOES NOT CHANGE
--
--   * The app. Every direct table write `web/src/lib/db.ts` performs was
--     enumerated first: academic_sessions, assessments, classes, exam_subjects,
--     exam_terms, expense_categories, message_templates, profiles,
--     school_settings, sections, staff, student_links, students, subjects,
--     teacher_assignments. NOT ONE table in the list below is among them. The
--     money already went through functions; the tables were just left open.
--   * Reading. Every SELECT policy is untouched, so no screen loses a figure.
--   * The Edge Functions, which authenticate as `service_role`.
--
-- WHAT A SCHOOL LOSES: nothing it could reach. What it gains is that the audit
-- trail is now the only trail.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The tables only a definer function may write
--
-- One list, used by the revoke, by the policy drop and by the assertions, so
-- the three cannot drift apart. Each entry names the function that owns writes
-- to it — a table with no such function does not belong here, because then the
-- revoke would make it unwritable rather than protected.
--
--   invoices, invoice_lines      fn_generate_class_invoices, fn_bill_student_month,
--                                fn_admit_student, fn_charge_deposit,
--                                fn_apply_fine, fn_waive_fine, fn_defer_invoice
--   payments, payment_allocations fn_record_payment, fn_record_family_payment,
--                                fn_record_bulk_payments, fn_verify_payment,
--                                fn_reverse_payment, fn_cancel_pending_payment
--   adjustments                  fn_add_adjustment
--   discounts                    fn_add_discount, fn_set_discount_status
--   result_cards                 fn_generate_result_cards, fn_publish_results,
--                                fn_unpublish_results
--   certificates,                fn_issue_certificate, fn_cancel_certificate
--     certificate_cancellations
--   deposit_refunds              fn_refund_deposit
--   student_fee_items            fn_generate_class_invoices, fn_bill_student_month
--   fee_heads                    fn_upsert_fee_head, fn_set_fee_head_active
--   fee_structures               fn_set_fee_amount, fn_fee_increment
--   families                     fn_admit_student, fn_merge_families,
--                                fn_student_join_family
--
-- `families` is here for a different reason from the rest: its UPDATE policy
-- was already unreachable — no screen and no function in the app writes it — so
-- it was a door with nothing behind it. When a school needs to correct a
-- payer's name or CNIC, that wants a function that records the change, not a
-- policy that does not.
--
-- DELIBERATELY NOT HERE, with the reason:
--
--   * students, staff, classes, sections, subjects, exam_terms, exam_subjects,
--     assessments, academic_sessions, expense_categories, message_templates,
--     profiles, school_settings, student_links, teacher_assignments — the app
--     writes every one of these directly. Closing them is a separate piece of
--     work that has to build the function first. Column-level cover for the
--     dangerous columns on `students` is in section 3.
--   * expenses, other_income, till_sessions, audit_log — already SELECT-only.
--     Somebody got this right and it is worth saying so.
--   * attendance_daily, mark_entries — a mark or a mark of attendance is not
--     money, both are gated per class and per subject (0085), and both record
--     the previous value for the corrections report. Left as they are on
--     purpose: a class teacher writing her own class's register is the feature.
--   * guardians — PII, not money, and its ALL policy is currently the only way
--     a guardian's phone number could ever be corrected. Closing it would
--     remove a capability rather than a loophole.
-- ---------------------------------------------------------------------------
do $boundary$
declare
  v_t   text;
  v_p   record;
  v_tables text[] := array[
    'invoices', 'invoice_lines',
    'payments', 'payment_allocations',
    'adjustments', 'discounts',
    'result_cards',
    'certificates', 'certificate_cancellations',
    'deposit_refunds',
    'student_fee_items',
    'fee_heads', 'fee_structures',
    'families'
  ];
begin
  foreach v_t in array v_tables loop
    if to_regclass('public.' || v_t) is null then
      raise exception '0086: public.% does not exist. This migration is naming a '
        'table that has been renamed or dropped, and a silent skip would leave '
        'the real table wide open.', v_t;
    end if;

    -- The privilege. `anon` as well as `authenticated`: an unauthenticated
    -- request carries the anon role, and Supabase grants it the same defaults.
    execute format(
      'revoke insert, update, delete, truncate on public.%I from authenticated, anon', v_t);

    -- The policies those privileges made reachable. A policy that can never
    -- fire is dead weight that reads as a live control — 0083's finding, and
    -- the reason for dropping rather than keeping them "for documentation".
    for v_p in
      select policyname from pg_policies
       where schemaname = 'public' and tablename = v_t
         and cmd in ('ALL', 'INSERT', 'UPDATE', 'DELETE')
    loop
      execute format('drop policy %I on public.%I', v_p.policyname, v_t);
      raise notice '0086: dropped write policy %.% — the privilege behind it is gone',
        v_t, v_p.policyname;
    end loop;
  end loop;
end $boundary$;

-- ---------------------------------------------------------------------------
-- 2. The end state, asserted by privilege
--
-- Not "did my revoke run" but "can a signed-in session write this table now",
-- which is the property that matters and the one that catches a future
-- migration creating a table and picking up Supabase's default grant again.
-- ---------------------------------------------------------------------------
do $assert$
declare
  v_t text;
  v_bad text[] := '{}';
  v_pol text[] := '{}';
  v_tables text[] := array[
    'invoices', 'invoice_lines', 'payments', 'payment_allocations',
    'adjustments', 'discounts', 'result_cards', 'certificates',
    'certificate_cancellations', 'deposit_refunds', 'student_fee_items',
    'fee_heads', 'fee_structures', 'families'
  ];
  v_role text;
begin
  foreach v_t in array v_tables loop
    foreach v_role in array array['authenticated', 'anon'] loop
      if has_table_privilege(v_role, 'public.' || v_t, 'insert')
         or has_table_privilege(v_role, 'public.' || v_t, 'update')
         or has_table_privilege(v_role, 'public.' || v_t, 'delete') then
        v_bad := v_bad || (v_t || ' (' || v_role || ')');
      end if;
    end loop;
    if exists (select 1 from pg_policies
                where schemaname = 'public' and tablename = v_t
                  and cmd in ('ALL', 'INSERT', 'UPDATE', 'DELETE')) then
      v_pol := v_pol || v_t;
    end if;
  end loop;

  if array_length(v_bad, 1) is not null then
    raise exception
      '0086: these tables can still be written from a signed-in session: %. '
      'A direct write to any of them forges money or an issued document and '
      'leaves no audit row.', array_to_string(v_bad, ', ');
  end if;
  if array_length(v_pol, 1) is not null then
    raise exception
      '0086: write policies survive on %. They cannot fire without the '
      'privilege, and a control that cannot fire reads as one that can.',
      array_to_string(v_pol, ', ');
  end if;

  -- And the other half: the definer functions must still be able to write, or
  -- this migration has locked the school out of its own books. Checked by
  -- asking about the OWNER of the functions rather than by trusting the theory.
  if not has_table_privilege('postgres', 'public.invoices', 'insert') then
    raise exception
      '0086: postgres cannot insert invoices. Every SECURITY DEFINER function '
      'runs as the owner, so the school can no longer be billed at all.';
  end if;
end $assert$;

-- ---------------------------------------------------------------------------
-- 3. students — the columns a function owns
--
-- `students` keeps its write policy, because the profile editor updates it
-- directly and closing that needs a function built first. But three groups of
-- columns on it are owned by functions that enforce rules the editor does not:
--
--   status, left_on, leaving_reason  fn_set_student_status — 0054's transition
--                                    rules and the audit row. A clerk could set
--                                    status = 'left' with a PATCH and the child
--                                    would vanish from the class strength with
--                                    no date, no reason and no audit.
--   family_id                        fn_student_join_family / fn_merge_families.
--                                    Moving a child between families moves the
--                                    money; 0036 exists because this was wrong.
--   photo_path                       fn_set_student_photo.
--   school_id                        the tenant key. Nothing should ever update
--                                    it; enforce_school_id() stamps it.
--   deleted_at                       the soft delete, which no code writes yet.
--                                    Left unwritable rather than half-open.
--
-- Column-level privilege is the exact tool: RLS cannot restrict WHICH COLUMNS
-- an update touches, and that is the same reason 0061 made certificate
-- cancellation a separate table rather than an edit.
--
-- IT HAS TO BE DONE THE OTHER WAY ROUND, and the assertion below is what
-- taught me. `revoke update (status, …)` on top of a table-wide UPDATE grant
-- changes NOTHING: a table-level privilege subsumes every column, so
-- has_column_privilege still answered true for all seven columns and the
-- assertion failed on its first run. The table grant has to go first, and then
-- the columns the editor genuinely sends are granted back by name. That is also
-- the safer shape — a column added to `students` in a later migration is
-- withheld by default rather than granted by default.
--
-- The identity columns gr_no, admission_no and admission_date ARE granted.
-- Nothing owns them and a school must be able to fix a typed GR number; a
-- certificate already issued carries its own frozen copy, so a later correction
-- cannot rewrite a document that has been handed over.
--
-- INSERT stays. A direct insert is reachable only by the same roles
-- `fn_admit_student` already serves, and — checked rather than assumed —
-- fn_admit_student enforces no subscription limit either, so closing this would
-- remove no control. It also keeps the one test in this project that writes
-- `students` as a signed-in user, which is how 0063's CHECK-constraint grant is
-- proved from the position a school actually occupies.
--
-- DELETE goes. There is a soft delete for a reason: a child with fee history
-- cannot be removed without taking the school's own accounts with them, and
-- Postgres would refuse on the foreign key anyway — but a child admitted this
-- morning by mistake would delete clean, and "it worked that once" is how a
-- school learns to do it that way.
-- ---------------------------------------------------------------------------
revoke update on public.students from authenticated, anon;
revoke delete on public.students from authenticated, anon;

grant update (gr_no, admission_no, full_name, father_name, mother_name, b_form,
              dob, gender, address, phone, whatsapp, admission_date, notes)
  on public.students to authenticated;

do $assert$
declare v_bad text[] := '{}'; v_c text; v_role text;
begin
  foreach v_role in array array['authenticated', 'anon'] loop
    foreach v_c in array array['status', 'left_on', 'leaving_reason', 'family_id',
                               'photo_path', 'school_id', 'deleted_at'] loop
      if has_column_privilege(v_role, 'public.students', v_c, 'update') then
        v_bad := v_bad || (v_c || ' (' || v_role || ')');
      end if;
    end loop;
    if has_table_privilege(v_role, 'public.students', 'delete') then
      v_bad := v_bad || ('DELETE (' || v_role || ')');
    end if;
  end loop;
  if array_length(v_bad, 1) is not null then
    raise exception '0086: students is still writable where a function owns it: %',
      array_to_string(v_bad, ', ');
  end if;

  -- The editor must still work. Asserted, because a revoke with one column name
  -- wrong would take a column the Save button needs and nothing else would say
  -- so until a clerk pressed it.
  foreach v_c in array array['full_name', 'father_name', 'mother_name', 'gender',
                             'dob', 'b_form', 'phone', 'whatsapp', 'address', 'notes'] loop
    if not has_column_privilege('authenticated', 'public.students', v_c, 'update') then
      raise exception
        '0086: authenticated can no longer update students.% — the profile editor '
        'sends that column and Save would fail for every school.', v_c;
    end if;
  end loop;
end $assert$;

-- ─────────────────────────────────────────────────────────────────────────
-- 0087_cancel_a_charge.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0087 — A challan raised by mistake could never be cancelled
--
-- WHAT WAS THERE
--
-- `invoice_status` has had the value `void` since the first migration, and
-- TWENTY functions honour it — student_balance, the dashboard, the defaulters
-- list, head-wise dues, the balance sheet, the unpaid-challan report, the
-- voucher scan, every one of them excludes a void invoice, and
-- `invoice_balances` filters it out at the view. The read side is complete and
-- consistent.
--
-- Nothing has ever written it. Asked directly:
--
--     select proname from pg_proc
--      where prosrc ~* 'status\s*=\s*''void''' and prosrc ~* 'update';
--     → 0 rows
--
-- So a clerk who generated April's challans for Class 5 with the wrong due date,
-- or billed a child who had already left, or ran the generator twice against two
-- different fee structures, had no way to undo it. The workarounds are all
-- worse than the problem:
--
--   * A negative adjustment cancels the money but leaves the wrong challan
--     sitting in Unpaid Challans, in Dues by Fee Head and in the defaulters
--     list for ever, and the parent portal keeps showing it. The books balance
--     and every screen still accuses the family.
--   * Deleting the row over the REST API worked until 0086 closed it, and left
--     no trace that the charge had ever existed.
--
-- WHY THE READ SIDE BEING RIGHT IS NOT ENOUGH
--
-- Twenty readers excluding void was never tested against a void invoice,
-- because none could exist. Introducing the writer means auditing every reader
-- that does NOT exclude it. Six were found by asking which function bodies name
-- `public.invoices` without naming `'void'`, and each was judged rather than
-- patched:
--
--   fn_challan            THE ONE THAT MATTERS. It prints the bank-payable
--                         voucher. A cancelled challan that still prints is the
--                         whole loophole reopened from the other end: cancel the
--                         charge, print the slip, collect the cash off-book.
--                         Now refuses, by name.
--   fn_undo_defer         updated any invoice regardless of status, while its
--                         twin fn_defer_invoice already refused a void one.
--                         Made symmetric.
--   fn_global_search      showed `initcap(status)` — a clerk searching a
--                         voucher code saw "Void", which is database jargon, not
--                         an answer. Now says "Cancelled".
--   fn_report_ledger      touches invoices only to label which months a RECEIPT
--                         covered. A cancelled month can appear there and
--                         should: the receipt is a historical fact. Left alone.
--   fn__payment_applied   same reasoning — it describes a payment that happened.
--   fn_rollover_undo      LEFT ALONE DELIBERATELY, and this one is worth the
--                         paragraph. It refuses to undo a rollover when the
--                         target session already has invoices, and excluding
--                         void there looks like an obvious improvement. It is
--                         not: the undo then proceeds to DELETE the enrolments,
--                         and a void invoice still references enrollment_id, so
--                         the delete fails on the foreign key and the school
--                         gets a constraint error instead of a clear refusal. A
--                         cancelled challan is evidence that somebody billed in
--                         that session; refusing is right.
--   fn_platform_school_detail  LEFT ALONE, and checked rather than waved
--                         through. It touches invoices twice, and both are
--                         USAGE signals rather than receivables: "has this
--                         school ever billed anybody" and "when did they last
--                         raise a challan". A school that raised a challan and
--                         cancelled it has still used the billing module, so
--                         counting the cancelled one is the right answer to
--                         both questions. The first draft of this migration
--                         carried a do-block that printed a notice about it on
--                         every deployment; a control that only complains is
--                         noise, and the finding belongs here instead.
--
-- THE RULES, AND THE ARGUMENT AGAINST EACH
--
--   1. OWNER OR PRINCIPAL ONLY. The objection is practical: the clerk generates
--      the challans, so the clerk makes the mistakes, and making them fetch the
--      principal is friction on a busy morning. It stands anyway. A front-office
--      login that can cancel a charge can make a family's dues disappear and
--      take the cash informally, and that is the oldest fraud in a Pakistani
--      school office. A clerk can already SEE the register, and asking for the
--      cancellation takes a minute.
--
--   2. A REASON IS REQUIRED, and a one-character reason is not a reason. Four
--      characters minimum. The register is read months later by somebody who was
--      not there.
--
--   3. AN INVOICE WITH MONEY ON IT IS REFUSED, naming the amount. Cancelling a
--      charge that has been paid would orphan the payment: the receipt stays,
--      the allocation points at a charge that no longer counts, and the family's
--      balance moves by the paid amount with no receipt reversed. The correct
--      order is to reverse the payment first — fn_reverse_payment writes a
--      contra receipt, so the money movement stays visible — and then cancel.
--      A payment that has ALREADY been reversed nets to zero and does not block,
--      which is why the check sums the allocations instead of counting them.
--
--   4. IT IS A STATUS CHANGE, NOT A DELETE. The row, its lines, its voucher code
--      and its serial history all stay. "Deleted Fees" in the competitor's
--      product is a register of exactly this, and a register whose entries can be
--      erased is not one.
--
--   5. NOTHING IS ALLOCATED TO IT AFTERWARDS. Already true and worth stating:
--      fn__allocate_payment only considers invoices with status `issued` or
--      `partial`, so a payment arriving later becomes family credit rather than
--      settling a cancelled charge. A pending payment verified after the
--      cancellation behaves the same way.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Who cancelled it, when, and why
--
-- On the invoice rather than in a side table, because unlike a certificate an
-- invoice is not an issued document — it is a live position, and `status`
-- already lives here. The three columns are read by fn_voided_invoices below,
-- which is what keeps check-columns-used.sh satisfied that they are not
-- decoration.
-- ---------------------------------------------------------------------------
alter table public.invoices add column if not exists voided_at  timestamptz;
alter table public.invoices add column if not exists voided_by  uuid references public.profiles(id);
alter table public.invoices add column if not exists void_reason text;

-- 0086 revoked every direct write on public.invoices, so no column-level grant
-- is needed or wanted here: the only writer is the definer function below.

-- ---------------------------------------------------------------------------
-- 2. Cancelling one
-- ---------------------------------------------------------------------------
create or replace function public.fn_void_invoice(p_invoice_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_actor  uuid := auth.uid();
  v_inv    record;
  v_alloc  numeric;
  v_charge numeric;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.has_role('owner', 'principal') then
    raise exception
      'Only the owner or principal may cancel a charge. A clerk who can cancel '
      'a challan can make a family''s dues disappear.'
      using errcode = '42501';
  end if;
  if v_reason is null or length(v_reason) < 4 then
    raise exception
      'A reason is required, and it is read months later by somebody who was '
      'not there — say what was wrong with the challan.';
  end if;
  perform public.assert_own('invoices', p_invoice_id);

  select i.id, i.status, i.period_month, i.notes, i.student_id, s.full_name
    into v_inv
  from public.invoices i
  join public.students s on s.id = i.student_id
  where i.id = p_invoice_id and i.school_id = v_school;
  if not found then
    raise exception 'No such challan' using errcode = '42704';
  end if;
  if v_inv.status = 'void' then
    raise exception 'That challan is already cancelled.';
  end if;

  -- Sum, not count: a payment that has been reversed leaves its original and
  -- its contra allocation behind, and those net to zero. Counting rows would
  -- refuse for ever after any reversal.
  select coalesce(sum(a.amount), 0) into v_alloc
  from public.payment_allocations a
  where a.invoice_id = p_invoice_id;

  if v_alloc <> 0 then
    raise exception
      'Rs % has been paid against this challan. Reverse the payment first — '
      'Fees → the receipt → Reverse — so the money movement stays on the '
      'record, then cancel the charge.', trim(to_char(v_alloc, 'FM999,999,990'));
  end if;

  select coalesce(sum(case when l.is_discount then -l.amount else l.amount end), 0)
         + coalesce((select fine from public.invoices where id = p_invoice_id), 0)
    into v_charge
  from public.invoice_lines l where l.invoice_id = p_invoice_id;

  update public.invoices
     set status = 'void',
         voided_at = now(),
         voided_by = v_actor,
         void_reason = v_reason
   where id = p_invoice_id;

  insert into public.audit_log (
    school_id, actor, actor_role, action, entity, entity_id, before, after, reason)
  values (
    v_school, v_actor,
    (select role from public.profiles where id = v_actor),
    'INVOICE_VOID', 'invoices', p_invoice_id::text,
    jsonb_build_object('status', v_inv.status, 'charge', v_charge),
    jsonb_build_object('status', 'void'),
    v_reason);

  return jsonb_build_object(
    'invoice_id', p_invoice_id,
    'student_name', v_inv.full_name,
    'cancelled', v_charge,
    'period', coalesce(to_char(v_inv.period_month, 'FMMonth YYYY'),
                       coalesce(v_inv.notes, 'One-off charge')));
end;
$$;

grant  execute on function public.fn_void_invoice(uuid, text) to authenticated;
revoke execute on function public.fn_void_invoice(uuid, text) from public, anon;

-- ---------------------------------------------------------------------------
-- 3. The register — the competitor's "Deleted Fees", which is the right screen
--
-- A clerk may READ it even though they may not cancel. Same reasoning as
-- fn_message_settings: somebody working the counter should be able to see why
-- the challan they are looking for is not there, and being able to see a
-- control you cannot operate is how a boundary gets understood rather than
-- worked around.
-- ---------------------------------------------------------------------------
create or replace function public.fn_voided_invoices(p_from date, p_to date)
returns table (
  invoice_id    uuid,
  voided_at     timestamptz,
  student_id    uuid,
  student_name  text,
  gr_no         text,
  class_name    text,
  section_name  text,
  period_label  text,
  voucher_code  text,
  amount        numeric,
  voided_by     text,
  reason        text
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.may_view('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p_from is null or p_to is null then
    raise exception 'A date range is required';
  end if;
  if p_to < p_from then
    raise exception 'The end date is before the start date';
  end if;

  return query
  select i.id,
         i.voided_at,
         i.student_id,
         s.full_name,
         s.gr_no,
         c.name,
         sec.name,
         coalesce(to_char(i.period_month, 'FMMonth YYYY'),
                  coalesce(i.notes, 'One-off charge')),
         i.voucher_code,
         coalesce((select sum(case when l.is_discount then -l.amount else l.amount end)
                     from public.invoice_lines l where l.invoice_id = i.id), 0)
           + coalesce(i.fine, 0),
         coalesce(pr.full_name, '—'),
         coalesce(i.void_reason, '—')
    from public.invoices i
    join public.students s on s.id = i.student_id and s.school_id = v_school
    left join public.enrollments e on e.id = i.enrollment_id
    left join public.classes c   on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
    left join public.profiles pr on pr.id = i.voided_by
   where i.school_id = v_school
     and i.status = 'void'
     -- A challan voided before this migration existed has no voided_at. Those
     -- are impossible today (nothing could write `void`) but a database
     -- restored from elsewhere might carry one, and dropping it silently would
     -- make the register lie about what it contains.
     and coalesce(i.voided_at::date, i.created_at::date) between p_from and p_to
   order by i.voided_at desc nulls last, s.full_name;
end;
$$;

grant  execute on function public.fn_voided_invoices(date, date) to authenticated;
revoke execute on function public.fn_voided_invoices(date, date) from public, anon;

-- ---------------------------------------------------------------------------
-- 4. A cancelled challan does not print
--
-- Rewritten programmatically from pg_get_functiondef rather than restated: the
-- body is sixty lines that have nothing to do with this change, and retyping
-- them is how an unrelated fix gets silently reverted.
-- ---------------------------------------------------------------------------
do $rewrite$
declare
  v_src    text;
  v_anchor text := '  perform public.assert_own(''invoices'', p_invoice_id);';
  v_guard  text :=
    '  perform public.assert_own(''invoices'', p_invoice_id);' || E'\n' ||
    '  -- 0087. A cancelled challan must not print: the slip is bank-payable, so' || E'\n' ||
    '  -- printing one after the charge was cancelled is a way to collect cash' || E'\n' ||
    '  -- that the books will never expect.' || E'\n' ||
    '  if exists (select 1 from public.invoices' || E'\n' ||
    '              where id = p_invoice_id and status = ''void'') then' || E'\n' ||
    '    raise exception ''This challan was cancelled and cannot be printed. See ''' || E'\n' ||
    '      ''Fees → Cancelled charges for who cancelled it and why.''' || E'\n' ||
    '      using errcode = ''42501'';' || E'\n' ||
    '  end if;';
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_challan';

  if v_src is null then
    raise exception '0087: public.fn_challan does not exist';
  end if;

  if position('status = ''void''' in v_src) > 0 then
    raise notice '0087: fn_challan already refuses a cancelled challan';
  else
    if position(v_anchor in v_src) = 0 then
      raise exception
        '0087: cannot find the assert_own line in fn_challan. The body has '
        'changed; insert the void guard by hand rather than guessing.';
    end if;
    execute replace(v_src, v_anchor, v_guard);
    -- create or replace preserves the ACL, so no re-grant is needed. Stated
    -- because the opposite was assumed once and cost an afternoon.
  end if;
end $rewrite$;

-- ---------------------------------------------------------------------------
-- 5. "Cancelled", not "Void", in the global search
-- ---------------------------------------------------------------------------
do $rewrite$
declare
  v_src text;
  v_old text := 'initcap(i.status::text)';
  v_new text := 'case when i.status = ''void'' then ''Cancelled'' else initcap(i.status::text) end';
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_global_search';

  if v_src is null then
    raise exception '0087: public.fn_global_search does not exist';
  end if;

  if position('''Cancelled''' in v_src) > 0 then
    raise notice '0087: fn_global_search already says Cancelled';
  elsif position(v_old in v_src) = 0 then
    raise exception
      '0087: cannot find initcap(i.status::text) in fn_global_search — the '
      'challan branch has changed.';
  else
    execute replace(v_src, v_old, v_new);
  end if;
end $rewrite$;

-- ---------------------------------------------------------------------------
-- 6. fn_undo_defer, made symmetric with fn_defer_invoice
--
-- Short enough to restate in full, so it is.
-- ---------------------------------------------------------------------------
create or replace function public.fn_undo_defer(p_invoice_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted';
  end if;
  perform public.assert_own('invoices', p_invoice_id);
  update public.invoices set deferred_until = null, defer_reason = null
   where id = p_invoice_id and status <> 'void';
  if not found then
    -- One message covering both, because the caller cannot tell them apart from
    -- the outside and either way there is nothing to undo.
    raise exception 'Invoice not found, or it was cancelled';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. The end state, asserted
-- ---------------------------------------------------------------------------
do $assert$
declare v_src text;
begin
  if to_regclass('public.invoices') is null then
    raise exception '0087: public.invoices is missing';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'invoices'
                    and column_name = 'void_reason') then
    raise exception '0087: invoices.void_reason was not added';
  end if;

  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'fn_void_invoice') then
    raise exception '0087: fn_void_invoice was not created';
  end if;
  if not has_function_privilege('authenticated',
        'public.fn_void_invoice(uuid, text)', 'execute') then
    raise exception '0087: authenticated cannot execute fn_void_invoice';
  end if;
  if not has_function_privilege('authenticated',
        'public.fn_voided_invoices(date, date)', 'execute') then
    raise exception '0087: authenticated cannot execute fn_voided_invoices';
  end if;

  -- The rewrite, checked by what the body now SAYS rather than by whether the
  -- statement ran. This is the fourth time in this project that a signature
  -- based on a function merely EXISTING proved nothing.
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_challan';
  if position('status = ''void''' in v_src) = 0 then
    raise exception
      '0087: fn_challan does not refuse a cancelled challan. The bank-payable '
      'slip would still print for a charge the school has withdrawn.';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_global_search';
  if position('''Cancelled''' in v_src) = 0 then
    raise exception '0087: fn_global_search still shows raw status text';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_undo_defer';
  if position('status <> ''void''' in v_src) = 0 then
    raise exception '0087: fn_undo_defer still touches a cancelled invoice';
  end if;
end $assert$;

-- ─────────────────────────────────────────────────────────────────────────
-- 0088_wire_the_dead_templates.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0088 — Two WhatsApp messages a school could switch on that nothing would send
--
-- WHAT WAS THERE
--
-- `fn__default_message_templates` seeds five templates into every school, and
-- Settings → Messages lets the school edit the wording, see the merge tags it
-- may use, preview it with sample values and switch it on or off. The screen is
-- good. Two of its five entries were decorative:
--
--     select proname from pg_proc
--      where prosrc like '%absent_today%' or prosrc like '%result_published%';
--     → fn__default_message_templates
--
-- The function that DEFINES them was the only function that mentioned them. No
-- trigger, no policy, no screen, nothing in web/src. A school would find
-- "Absent today" in its settings, write the wording it wanted, switch it on, and
-- no parent would ever receive one. No error, no empty state, nothing to
-- notice — the message simply did not exist.
--
-- 0043's own header states the principle this broke: "The tag list is a FACT
-- ABOUT THE CALL SITE, not decoration ... Showing a school a tag that will never
-- resolve means they put it in a message and a parent receives the literal
-- {receipt}." Two of the five entries had no call site at all.
--
-- The WhatsApp screen was already finished for both: `listOutbox` reads the
-- table without filtering by template, and MessagesPage already carries the
-- labels "Absent today" and "Result published". So this migration is the whole
-- feature — nothing in the app changes.
--
-- THREE THINGS THE OBVIOUS WIRING WOULD HAVE GOT WRONG
--
--   1. {children} IS THE WHOLE FAMILY. fn_queue_message fills it with every
--      child in the family, which is right for a fee reminder to a payer and
--      wrong for an absence: a family of three would be told "Ali, Fatima and
--      Hassan was marked absent today". Both new callers override it with the
--      one child concerned.
--
--   2. {date} IS TODAY. A register finalised on Monday morning for Friday would
--      have told the parent their child was absent today. The absence caller
--      passes the ATTENDANCE date.
--
--   3. A WITHHELD RESULT MUST NOT BE ANNOUNCED. fn_generate_result_cards
--      freezes `withheld: true` on a card when the family owes fees, and the
--      portal shows "Result withheld until outstanding fees are cleared." A
--      message saying the result "can be viewed in the parent portal" would be
--      false for exactly the families most likely to check.
--
-- IDEMPOTENCE, STRUCTURALLY
--
-- Finalising a register twice, or unpublishing and republishing a term, must not
-- message a family twice. Doing that with a heuristic — "was anything sent to
-- this student today" — breaks on a register finalised three days late, so
-- `message_outbox` gains a `ref` column and a unique index. The caller says what
-- the message is ABOUT ('absent:2026-08-27', 'result:<term_id>') and the
-- database refuses the second one. Any future template gets it for nothing.
--
-- A DELIBERATE DECISION ON REPUBLISHING: a corrected result is not announced
-- again. One message per child per term, ever. A parent who has already been
-- told to look, and then gets a second identical message, has been given a
-- reason to think something is wrong; a correction is a conversation the school
-- should have, and the office can still send a message by hand.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. What a queued message is ABOUT
--
-- Nullable, so every existing row and every existing caller is unaffected: a
-- fee receipt has no natural idempotency key and does not need one, because it
-- is queued by a trigger on the payment that is itself the unique event.
-- ---------------------------------------------------------------------------
alter table public.message_outbox add column if not exists ref text;

-- Partial, so the fee receipts and reminders that carry no ref are not forced
-- to be unique against each other.
create unique index if not exists uq_outbox_ref
  on public.message_outbox (school_id, template_key, student_id, ref)
  where ref is not null;

-- ---------------------------------------------------------------------------
-- 2. fn_queue_message learns the key
--
-- DROP then CREATE rather than `create or replace`, because adding a parameter
-- with a default makes a NEW function rather than replacing the old one — and
-- then every five-argument call becomes ambiguous and fails with "function is
-- not unique". Checked first: nothing in web/src or supabase/functions calls
-- this over RPC, and its three in-database callers are plpgsql, which resolves
-- the name at run time.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_queue_message(text, uuid, jsonb, uuid, uuid);

create or replace function public.fn_queue_message(
  p_template_key text,
  p_family_id    uuid,
  p_vars         jsonb default '{}'::jsonb,
  p_payment_id   uuid  default null,
  p_student_id   uuid  default null,
  p_ref          text  default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_t record; v_f record; v_id uuid; v_vars jsonb; v_kids text;
  v_school uuid := public.current_school_id();
begin
  -- No school context, no message. Reached when a service-role job calls this
  -- with no session; queuing a message to a family we cannot attribute is worse
  -- than queuing none.
  if v_school is null then return null; end if;

  select * into v_t from public.message_templates
  where school_id = v_school and template_key = p_template_key;
  -- Not an error. A school that has switched this message off gets no message,
  -- and the action that triggered it still succeeds.
  if not found or not v_t.enabled then return null; end if;

  -- THE LEAK (0079). Was `where id = p_family_id` with no school filter, inside
  -- a SECURITY DEFINER function where RLS does not apply — so any signed-in
  -- user at any school could name any family in the database.
  select * into v_f from public.families
  where id = p_family_id and school_id = v_school;
  if not found then return null; end if;

  -- Same fix, same reason: this is where the victim child's NAME came from.
  select string_agg(s.full_name, ', ' order by s.full_name) into v_kids
  from public.students s
  where s.family_id = p_family_id and s.school_id = v_school
    and s.deleted_at is null;

  -- The two optional foreign keys were written into the outbox row without ever
  -- being checked. enforce_school_id stamps the ROW's school_id, so the row
  -- looked native to the caller's school while pointing at another school's
  -- payment or pupil — and the portal and receipt screens join through them.
  -- Silently dropped rather than raised, for the same reason as above: a
  -- mis-supplied reference must not fail the payment that triggered the message.
  if p_payment_id is not null and not exists (
       select 1 from public.payments where id = p_payment_id and school_id = v_school) then
    p_payment_id := null;
  end if;
  if p_student_id is not null and not exists (
       select 1 from public.students where id = p_student_id and school_id = v_school) then
    p_student_id := null;
  end if;

  v_vars := jsonb_build_object(
    'parent',   coalesce(v_f.head_name, 'Parent'),
    'children', coalesce(v_kids, 'your child'),
    'school',   coalesce((select name from public.school_settings
                          where school_id = v_school), 'the school'),
    'date',     to_char(current_date, 'DD Mon YYYY'),
    'balance',  trim(to_char(public.family_outstanding(p_family_id), 'FM999,999,990'))
  ) || coalesce(p_vars, '{}'::jsonb);

  -- 0088. `ref` is the idempotency key, enforced by uq_outbox_ref. A caller
  -- that supplies one is saying "there is at most one of these" and gets null
  -- back on the second attempt rather than an error, because the ACTION that
  -- triggered the message — finalising a register, publishing a term — must
  -- still succeed on a re-run.
  begin
    insert into public.message_outbox (
      template_key, to_name, to_phone, family_id, student_id, payment_id,
      rendered_text, ref)
    values (
      p_template_key, v_f.head_name,
      coalesce(nullif(btrim(coalesce(v_f.whatsapp, '')), ''), v_f.phone),
      p_family_id, p_student_id, p_payment_id,
      public.fn__render_template(v_t.body, v_vars), p_ref)
    returning id into v_id;
  exception when unique_violation then
    return null;
  end;

  return v_id;
end;
$$;

grant  execute on function public.fn_queue_message(text, uuid, jsonb, uuid, uuid, text) to authenticated;
revoke execute on function public.fn_queue_message(text, uuid, jsonb, uuid, uuid, text) from public, anon;

-- ---------------------------------------------------------------------------
-- 3. Absence
--
-- Exposed as its own function as well as being called on finalise, because a
-- register gets corrected: a child marked absent who turns out to have been on
-- leave is fixed, the register is finalised again, and the office can re-run
-- this to catch the ones it missed the first time. The ref stops the ones
-- already messaged going out twice.
--
-- `leave` and `half_day` are NOT messaged. A parent who told the school their
-- child would be away does not need telling back, and half a day present is not
-- an absence. Only `absent`.
-- ---------------------------------------------------------------------------
create or replace function public.fn_queue_absent_today(
  p_session_id uuid, p_class_id uuid, p_section_id uuid, p_date date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_row    record;
  v_id     uuid;
  v_queued int := 0;
  v_already int := 0;
  v_nophone int := 0;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not public.fn_may_manage_class(p_session_id, p_class_id, p_section_id) then
    raise exception 'You can only message your assigned class';
  end if;
  if p_date is null then raise exception 'A date is required'; end if;

  for v_row in
    select s.id as student_id, s.family_id, s.full_name
    from public.attendance_daily ad
    join public.enrollments e on e.id = ad.enrollment_id
    join public.students s    on s.id = e.student_id
    where ad.school_id = v_school
      and ad.attendance_date = p_date
      and ad.status = 'absent'
      and e.session_id = p_session_id
      and e.class_id = p_class_id
      and (p_section_id is null or e.section_id = p_section_id)
      and e.status = 'active'
      and s.deleted_at is null
      and s.family_id is not null
    order by s.full_name
  loop
    -- `children` is the ONE child, not the family. `date` is the attendance
    -- date, not today. Both are the point of this function.
    v_id := public.fn_queue_message(
      'absent_today',
      v_row.family_id,
      jsonb_build_object(
        'children', v_row.full_name,
        'date',     to_char(p_date, 'DD Mon YYYY')),
      null,
      v_row.student_id,
      'absent:' || p_date::text);

    if v_id is null then v_already := v_already + 1;
    else v_queued := v_queued + 1;
    end if;
  end loop;

  -- Counted separately and reported, because "we queued 18 of 20" is actionable
  -- and "we queued 18" is not: the two families with no number on file are the
  -- ones the office has to phone.
  select count(*) into v_nophone
  from public.attendance_daily ad
  join public.enrollments e on e.id = ad.enrollment_id
  join public.students s    on s.id = e.student_id
  left join public.families f on f.id = s.family_id
  where ad.school_id = v_school
    and ad.attendance_date = p_date
    and ad.status = 'absent'
    and e.session_id = p_session_id
    and e.class_id = p_class_id
    and (p_section_id is null or e.section_id = p_section_id)
    and e.status = 'active'
    and s.deleted_at is null
    and (s.family_id is null
         or coalesce(nullif(btrim(coalesce(f.whatsapp, '')), ''), f.phone) is null);

  return jsonb_build_object(
    'queued', v_queued,
    'already_queued', v_already,
    'no_number', v_nophone);
end;
$$;

grant  execute on function public.fn_queue_absent_today(uuid, uuid, uuid, date) to authenticated;
revoke execute on function public.fn_queue_absent_today(uuid, uuid, uuid, date) from public, anon;

-- Finalising the register is the moment the school commits to who was absent,
-- so it is the moment the messages belong. Restated in full rather than
-- rewritten programmatically because the body is eleven lines.
--
-- Wrapped, and deliberately so: a failure in the messaging must never roll back
-- the lock. A register that would not finalise because one family's row was
-- odd would be a far worse defect than a message that did not go out, and the
-- office can re-run fn_queue_absent_today for the day.
create or replace function public.fn_finalize_attendance(
  p_session_id uuid, p_class_id uuid, p_section_id uuid, p_date date)
returns integer language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to finalize attendance';
  end if;
  if not public.fn_may_manage_class(p_session_id, p_class_id, p_section_id) then
    raise exception 'You can only finalize your assigned class';
  end if;
  update public.attendance_daily ad
    set is_locked = true
    from public.enrollments e
    where ad.enrollment_id = e.id
      and ad.attendance_date = p_date
      and e.session_id = p_session_id
      and e.class_id = p_class_id
      and e.section_id is not distinct from p_section_id;
  get diagnostics v_count = row_count;

  begin
    perform public.fn_queue_absent_today(p_session_id, p_class_id, p_section_id, p_date);
  exception when others then
    raise notice 'attendance finalised; absence messages could not be queued: %', sqlerrm;
  end;

  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Results published
-- ---------------------------------------------------------------------------
create or replace function public.fn_queue_result_published(
  p_exam_term_id uuid, p_class_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_row    record;
  v_id     uuid;
  v_queued int := 0;
  v_already int := 0;
  v_withheld int := 0;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('classes', p_class_id);

  for v_row in
    select distinct on (rc.enrollment_id)
           s.id as student_id, s.family_id, s.full_name,
           coalesce((rc.frozen->>'withheld')::boolean, false) as withheld
    from public.result_cards rc
    join public.enrollments e on e.id = rc.enrollment_id
    join public.students s    on s.id = rc.student_id
    where rc.school_id = v_school
      and rc.exam_term_id = p_exam_term_id
      and e.class_id = p_class_id
      and rc.published_at is not null
      and s.deleted_at is null
      and s.family_id is not null
    order by rc.enrollment_id, rc.version desc
  loop
    -- A withheld card shows the parent "Result withheld until outstanding fees
    -- are cleared", so telling them the result can be viewed would be false for
    -- exactly the families most likely to go and look.
    if v_row.withheld then
      v_withheld := v_withheld + 1;
      continue;
    end if;

    v_id := public.fn_queue_message(
      'result_published',
      v_row.family_id,
      jsonb_build_object('children', v_row.full_name),
      null,
      v_row.student_id,
      'result:' || p_exam_term_id::text);

    if v_id is null then v_already := v_already + 1;
    else v_queued := v_queued + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'queued', v_queued,
    'already_queued', v_already,
    'withheld', v_withheld);
end;
$$;

grant  execute on function public.fn_queue_result_published(uuid, uuid) to authenticated;
revoke execute on function public.fn_queue_result_published(uuid, uuid) from public, anon;

create or replace function public.fn_publish_results(p_exam_term_id uuid, p_class_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may release results to parents';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('classes', p_class_id);

  with latest as (
    select distinct on (rc.enrollment_id) rc.id
    from public.result_cards rc
    join public.enrollments e on e.id = rc.enrollment_id
    where rc.exam_term_id = p_exam_term_id and e.class_id = p_class_id
    order by rc.enrollment_id, rc.version desc
  )
  update public.result_cards rc
     set published_at = now()
    from latest l
   where rc.id = l.id and rc.published_at is null;

  get diagnostics v_n = row_count;

  -- Same reasoning as the attendance hook: the release must not fail because a
  -- message could not be built.
  begin
    perform public.fn_queue_result_published(p_exam_term_id, p_class_id);
  exception when others then
    raise notice 'results published; parent messages could not be queued: %', sqlerrm;
  end;

  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. The end state, asserted
--
-- The assertion that matters is not "do the functions exist" but "does every
-- template a school can switch on have something that sends it". Written as a
-- sweep over the template list rather than as two named checks, so a SIXTH
-- template added later without a caller fails here instead of shipping
-- decorative.
-- ---------------------------------------------------------------------------
do $assert$
declare
  v_key   text;
  v_dead  text[] := '{}';
  v_n     int;
begin
  for v_key in select template_key from public.fn__default_message_templates() loop
    select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname <> 'fn__default_message_templates'
      and p.prosrc like '%' || v_key || '%';
    if v_n = 0 then
      v_dead := v_dead || v_key;
    end if;
  end loop;

  if array_length(v_dead, 1) is not null then
    raise exception
      '0088: these templates are seeded into every school, editable in Settings '
      '→ Messages and switched on by a toggle, and NOTHING queues them: %. A '
      'school will write the wording, enable it, and no parent will ever '
      'receive one.', array_to_string(v_dead, ', ');
  end if;
end $assert$;

do $assert$
declare v_src text;
begin
  if not exists (select 1 from pg_indexes
                  where schemaname = 'public' and indexname = 'uq_outbox_ref') then
    raise exception '0088: uq_outbox_ref is missing, so a re-finalise would message twice';
  end if;

  -- fn_queue_message must be exactly ONE function. Two overloads would make
  -- every five-argument call ambiguous at run time, which is a failure the
  -- migration would not show.
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'fn_queue_message') <> 1 then
    raise exception
      '0088: there is more than one fn_queue_message. Adding a defaulted '
      'parameter creates an overload rather than replacing the function, and '
      'the old five-argument calls then fail with "function is not unique".';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_finalize_attendance';
  if position('fn_queue_absent_today' in v_src) = 0 then
    raise exception '0088: finalising a register no longer queues the absences';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_publish_results';
  if position('fn_queue_result_published' in v_src) = 0 then
    raise exception '0088: publishing results no longer tells the parents';
  end if;
end $assert$;

-- ─────────────────────────────────────────────────────────────────────────
-- 0089_gpa_scale.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0089 — A school could choose a GPA scale and keep getting letters
--
-- WHAT WAS THERE
--
-- Settings → School profile offers a "Grade scale" dropdown with two options:
--
--     <option value="letter">Letter (A+, A, B…)</option>
--     <option value="gpa10">GPA (10-point)</option>
--
-- `fn_grade_for` is the only grade function in the database, it is the only
-- caller of the setting's own idea, and it never reads `grade_scale` at all:
--
--     select coalesce(pass_percent, 33) into v_pass from public.school_settings …
--     if p_percent < v_pass then return 'F'; end if;
--     return case when p_percent >= 90 then 'A+' … else 'E' end;
--
-- So a school selects GPA, the form saves, "Saved." appears, and every result
-- card, every per-subject grade, the tabulation sheet and the parent portal keep
-- printing A+ / A / B / C / D / E / F. Nothing warns anybody. The school finds
-- out when a parent asks why the card does not say what the office said it would.
--
-- This was a KNOWN gap — docs/PARITY.md recorded it in the exam-computation
-- section, in as many words: "`school_settings.grade_scale` still offers `gpa10`
-- and `fn_grade_for` still always returns letters, which is its own piece of
-- work." Recording a defect honestly is not the same as fixing it, and the UI
-- went on offering the option the whole time. That is the part worth naming: a
-- setting a school can choose must do what it says, or it must not be offered.
--
-- WHAT A 10-POINT SCALE ACTUALLY MEANS, AND THE ONE DECISION THAT MATTERS
--
-- A grade point is per PAPER. A GPA is the MEAN of a pupil's grade points. Those
-- are different numbers, and the difference is the whole reason for the feature:
--
--   Two pupils, four papers each, both aggregating 70%.
--     Aisha:  70, 70, 70, 70   → points 8, 8, 8, 8   → GPA 8.0
--     Bilal:  95, 95, 45, 45   → points 10, 10, 5, 5 → GPA 7.5
--
--   Banding the AGGREGATE gives them both 8.0 and throws away exactly the
--   information a GPA exists to carry. So the card's overall figure is computed
--   as the mean of the marked papers' points, to one decimal.
--
-- The bands are the same cut points the letter scale already uses — 90 / 80 / 70
-- / 60 / 50 / 40 — so the two scales agree about which band a mark falls into and
-- a school switching between them sees a translation rather than a re-grading.
-- Below the school's own pass mark is 0, matching the letter scale returning F.
--
--   90+ → 10    80+ → 9    70+ → 8    60+ → 7    50+ → 6    40+ → 5
--   at or above the pass mark but under 40 → 4        below the pass mark → 0
--
-- WHY THE SCALE IS FROZEN ONTO THE CARD
--
-- `fn_generate_result_cards` freezes everything the print needs, for the reason
-- 0083 set out: a portal or a print that recomputed could disagree with the paper
-- the family is holding. The scale is now part of that snapshot, so a card
-- generated under `letter` still prints "Grade A" after the school switches to
-- GPA, and a card generated under `gpa10` still prints "GPA 8.5" if they switch
-- back. Without it the printed label would flip on every card ever issued the
-- moment somebody changed a dropdown.
--
-- UNMARKED PAPERS ARE EXCLUDED FROM THE MEAN, not counted as zero. This is the
-- same rule 0058 established for the percentage, and for the same reason: one
-- `coalesce(sum(…), 0)` there had made "no mark exists" and "a mark of zero" the
-- same thing, and printed two A+ pupils as a C and a D. A provisional card's GPA
-- is the mean of what has been marked, and the card says PROVISIONAL on its face.
--
-- WHAT IS STILL NOT BUILT, said plainly rather than left to be discovered:
-- credit-weighted GPA. A real 10-point system often weights each paper by credit
-- hours; ours treats every paper as one credit, because `exam_subjects` has no
-- credit column and inventing one would be a schema change nobody has asked for.
-- A school running unequal credits gets an unweighted mean, which is what a
-- Pakistani school marking out of different totals per paper generally wants
-- anyway.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. fn_grade_for reads the setting it was always supposed to read
--
-- Returns text either way, because `result_cards.grade` and the per-subject
-- `grade` in the frozen snapshot are both text — '9' is a grade point, not a
-- number to do arithmetic on downstream, and the one place that DOES average
-- them casts explicitly.
-- ---------------------------------------------------------------------------
create or replace function public.fn_grade_for(p_percent numeric)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_pass numeric; v_scale text;
begin
  if p_percent is null then return null; end if;

  select coalesce(pass_percent, 33), coalesce(nullif(btrim(grade_scale), ''), 'letter')
    into v_pass, v_scale
  from public.school_settings where school_id = public.current_school_id();
  v_pass  := coalesce(v_pass, 33);
  v_scale := coalesce(v_scale, 'letter');

  if v_scale = 'gpa10' then
    -- Same cut points as the letter scale, so the two agree about the band.
    if p_percent < v_pass then return '0'; end if;
    return case
      when p_percent >= 90 then '10'
      when p_percent >= 80 then '9'
      when p_percent >= 70 then '8'
      when p_percent >= 60 then '7'
      when p_percent >= 50 then '6'
      when p_percent >= 40 then '5'
      else '4' end;
  end if;

  if p_percent < v_pass then return 'F'; end if;
  return case
    when p_percent >= 90 then 'A+'
    when p_percent >= 80 then 'A'
    when p_percent >= 70 then 'B'
    when p_percent >= 60 then 'C'
    when p_percent >= 50 then 'D'
    else 'E' end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. The card's overall figure becomes a real GPA
--
-- Four surgical edits to fn_generate_result_cards, applied programmatically from
-- pg_get_functiondef. The body is 250 lines of exam computation that has nothing
-- to do with this change, and retyping it is how the 0058 fixes get silently
-- reverted — which is the reason 0084 and 0085 did the same thing.
--
-- Every edit asserts its own anchor first and the whole set is verified by what
-- the body SAYS at the end of the file.
-- ---------------------------------------------------------------------------
do $rewrite$
declare
  v_src text;
  v_new text;

  -- (a) two more locals
  a_old text := '  v_ver integer; v_att numeric; v_grade text; v_frozen jsonb;';
  a_new text := '  v_ver integer; v_att numeric; v_grade text; v_frozen jsonb;'
             || E'\n' || '  v_scale text; v_gpa numeric;   -- 0089';

  -- (b) read the scale once, next to the pass mark it belongs with
  b_old text := '  v_pass_pct := coalesce(v_pass_pct, 33);';
  b_new text := '  v_pass_pct := coalesce(v_pass_pct, 33);'
             || E'\n' || E'\n'
             || '  -- 0089. Read once for the whole class, not per pupil: a school that'   || E'\n'
             || '  -- changed the dropdown halfway through a generation run would otherwise' || E'\n'
             || '  -- produce two kinds of card in one class.'                              || E'\n'
             || '  select coalesce(nullif(btrim(grade_scale), ''''), ''letter'') into v_scale' || E'\n'
             || '    from public.school_settings where school_id = v_school;'               || E'\n'
             || '  v_scale := coalesce(v_scale, ''letter'');';

  -- (c) the scale travels WITH the card
  c_old text := '      ''pass_percent'', v_pass_pct,';
  c_new text := '      ''pass_percent'', v_pass_pct,'
             || E'\n'
             || '      -- 0089. Frozen, so a card printed after the school switches scale'  || E'\n'
             || '      -- still says what it said when it was issued. Without this the'      || E'\n'
             || '      -- printed label on every card ever generated would flip the moment'  || E'\n'
             || '      -- somebody changed a dropdown.'                                      || E'\n'
             || '      ''grade_scale'', v_scale,';

  -- (d) the mean of the marked papers' points, replacing the banded aggregate
  d_old text := '    insert into public.result_cards(school_id, student_id, enrollment_id, exam_term_id,';
  d_new text :=
        '    -- 0089. A GPA is the MEAN of the grade points, not the band of the'      || E'\n'
     || '    -- aggregate. Two pupils both on 70% — one with four 70s, one with two'   || E'\n'
     || '    -- 95s and two 45s — have GPAs of 8.0 and 7.5, and banding the'           || E'\n'
     || '    -- aggregate would give them both 8.0 and discard exactly what a GPA'     || E'\n'
     || '    -- is for. Unmarked papers are excluded rather than counted as zero,'     || E'\n'
     || '    -- which is the rule 0058 established for the percentage.'                || E'\n'
     || '    if v_scale = ''gpa10'' then'                                             || E'\n'
     || '      select round(avg((s->>''grade'')::numeric), 1) into v_gpa'             || E'\n'
     || '      from jsonb_array_elements(v_frozen->''subjects'') s'                    || E'\n'
     || '      where coalesce((s->>''marked'')::boolean, false)'                       || E'\n'
     || '        and s->>''grade'' is not null;'                                       || E'\n'
     || '      if v_gpa is not null then'                                              || E'\n'
     || '        v_grade := trim(to_char(v_gpa, ''FM990.0''));'                        || E'\n'
     || '        v_frozen := jsonb_set(v_frozen, ''{grade}'', to_jsonb(v_grade));'     || E'\n'
     || '      end if;'                                                                || E'\n'
     || '    end if;'                                                                  || E'\n'
     || E'\n'
     || '    insert into public.result_cards(school_id, student_id, enrollment_id, exam_term_id,';
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_generate_result_cards';

  if v_src is null then
    raise exception '0089: public.fn_generate_result_cards does not exist';
  end if;

  if position('v_scale' in v_src) > 0 then
    raise notice '0089: fn_generate_result_cards already honours the grade scale';
    return;
  end if;

  if position(a_old in v_src) = 0 then
    raise exception '0089: cannot find the local declarations in fn_generate_result_cards';
  end if;
  if position(b_old in v_src) = 0 then
    raise exception '0089: cannot find the pass-mark default in fn_generate_result_cards';
  end if;
  if position(c_old in v_src) = 0 then
    raise exception '0089: cannot find pass_percent in the frozen snapshot';
  end if;
  if position(d_old in v_src) = 0 then
    raise exception '0089: cannot find the result_cards insert in fn_generate_result_cards';
  end if;

  v_new := replace(v_src, a_old, a_new);
  v_new := replace(v_new, b_old, b_new);
  v_new := replace(v_new, c_old, c_new);
  v_new := replace(v_new, d_old, d_new);
  execute v_new;
  -- create or replace preserves the ACL, so no re-grant is needed.
end $rewrite$;

-- ---------------------------------------------------------------------------
-- 3. The parent portal has to know which scale it is showing
--
-- fn_portal_child_results (0083) returns `grade` and nothing about the scale, so
-- a portal under gpa10 would show a parent a bare badge reading "8.5" with no
-- indication of what it was out of. Read from the FROZEN snapshot for the same
-- reason as everything else on that function: the portal and the printed card
-- must not be able to disagree.
-- ---------------------------------------------------------------------------
do $rewrite$
declare
  v_src text;
  v_old text := '               ''percentage'', x.percentage, ''grade'', x.grade,';
  v_new text := '               ''percentage'', x.percentage, ''grade'', x.grade,' || E'\n'
             || '               -- 0089. Which scale that grade is on, frozen onto the card.' || E'\n'
             || '               -- Older cards carry none, and older cards are letters.' || E'\n'
             || '               ''grade_scale'', coalesce(x.frozen->>''grade_scale'', ''letter''),';
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_portal_child_results';

  if v_src is null then
    raise exception '0089: public.fn_portal_child_results does not exist';
  end if;

  if position('''grade_scale''' in v_src) > 0 then
    raise notice '0089: the portal already reports the grade scale';
  elsif position(v_old in v_src) = 0 then
    raise exception
      '0089: cannot find the percentage/grade line in fn_portal_child_results';
  else
    execute replace(v_src, v_old, v_new);
  end if;
end $rewrite$;

-- ---------------------------------------------------------------------------
-- 4. The setting can only hold a scale that exists
--
-- Not a cosmetic tidy. `grade_scale` is plain text with no constraint, so a
-- typo or a third option added to the dropdown and not to fn_grade_for would
-- silently fall through to letters — the exact defect this migration exists to
-- fix, arriving again by a different route. A constraint makes the next person
-- add the branch before they can add the option.
-- ---------------------------------------------------------------------------
do $constraint$
declare v_bad text;
begin
  select string_agg(distinct coalesce(grade_scale, '(null)'), ', ') into v_bad
    from public.school_settings
   where coalesce(nullif(btrim(grade_scale), ''), 'letter') not in ('letter', 'gpa10');
  if v_bad is not null then
    -- Never rewrite a school's setting silently. Say what is there and stop.
    raise exception
      '0089: school_settings.grade_scale holds a value no grade scale implements '
      '(%). Set it to letter or gpa10 before applying this.', v_bad;
  end if;

  if not exists (select 1 from pg_constraint
                  where conname = 'school_settings_grade_scale_known') then
    alter table public.school_settings
      add constraint school_settings_grade_scale_known
      check (grade_scale is null
             or btrim(grade_scale) = ''
             or btrim(grade_scale) in ('letter', 'gpa10'));
  end if;
end $constraint$;

-- ---------------------------------------------------------------------------
-- 5. The end state, asserted
-- ---------------------------------------------------------------------------
do $assert$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_grade_for';
  if position('gpa10' in v_src) = 0 then
    raise exception
      '0089: fn_grade_for still ignores school_settings.grade_scale, so a school '
      'that selects GPA still gets letters on every card.';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_generate_result_cards';

  -- Each of the four edits, checked by what the body says. "The statement ran"
  -- is not evidence; this project has been caught by that four times.
  if position('''grade_scale'', v_scale' in v_src) = 0 then
    raise exception '0089: the grade scale is not frozen onto the card, so a '
      'printed card would change its label when the setting changes';
  end if;
  if position('jsonb_set(v_frozen, ''{grade}''' in v_src) = 0 then
    raise exception '0089: the card''s overall grade is still the band of the '
      'aggregate rather than the mean of the papers'' grade points';
  end if;
  if position('''{subjects}''' in v_src) > 0 then
    raise exception '0089: unexpected rewrite of the subjects array';
  end if;
  if position('marked' in v_src) = 0 then
    raise exception '0089: the GPA mean is not restricted to marked papers';
  end if;

  if not exists (select 1 from pg_constraint
                  where conname = 'school_settings_grade_scale_known') then
    raise exception '0089: grade_scale can still be set to a scale nothing implements';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_portal_child_results';
  if position('''grade_scale''' in v_src) = 0 then
    raise exception
      '0089: the portal does not say which scale a grade is on, so a parent '
      'under gpa10 sees a bare "8.5" with nothing to read it against.';
  end if;
end $assert$;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0068_limit_notice_timing.sql', '7_ledger_and_limits.sql');
  perform public.fn_record_migration('0069_migration_ledger.sql', '7_ledger_and_limits.sql');
  perform public.fn_record_migration('0070_queue_message_scoping.sql', '7_ledger_and_limits.sql');
  perform public.fn_record_migration('0071_function_grants.sql', '7_ledger_and_limits.sql');
  perform public.fn_record_migration('0072_name_lookups_scoped.sql', '7_ledger_and_limits.sql');
  perform public.fn_record_migration('0073_operator_actions.sql', '7_ledger_and_limits.sql');
  perform public.fn_record_migration('0074_operator_support_sessions.sql', '7_ledger_and_limits.sql');
  perform public.fn_record_migration('0075_school_detail.sql', '7_ledger_and_limits.sql');
  perform public.fn_record_migration('0076_platform_settings.sql', '7_ledger_and_limits.sql');
  perform public.fn_record_migration('0077_invoice_documents.sql', '7_ledger_and_limits.sql');
  perform public.fn_record_migration('0078_renewals_self_serve.sql', '7_ledger_and_limits.sql');
  perform public.fn_record_migration('0079_school_lifecycle.sql', '7_ledger_and_limits.sql');
  perform public.fn_record_migration('0080_offboarding.sql', '7_ledger_and_limits.sql');
  perform public.fn_record_migration('0081_platform_metrics.sql', '7_ledger_and_limits.sql');
  perform public.fn_record_migration('0082_releases_and_announcements.sql', '7_ledger_and_limits.sql');
  perform public.fn_record_migration('0083_portal_verdict_and_dead_tables.sql', '7_ledger_and_limits.sql');
  perform public.fn_record_migration('0084_receipt_allocation_detail.sql', '7_ledger_and_limits.sql');
  perform public.fn_record_migration('0085_subject_teachers.sql', '7_ledger_and_limits.sql');
  perform public.fn_record_migration('0086_write_boundary.sql', '7_ledger_and_limits.sql');
  perform public.fn_record_migration('0087_cancel_a_charge.sql', '7_ledger_and_limits.sql');
  perform public.fn_record_migration('0088_wire_the_dead_templates.sql', '7_ledger_and_limits.sql');
  perform public.fn_record_migration('0089_gpa_scale.sql', '7_ledger_and_limits.sql');
end $ledger$;
