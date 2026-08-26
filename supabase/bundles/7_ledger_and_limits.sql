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
end $ledger$;
