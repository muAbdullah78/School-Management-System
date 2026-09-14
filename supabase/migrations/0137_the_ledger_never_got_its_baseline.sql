-- =============================================================================
-- 0137  The ledger never got its baseline
--
-- FOUND ON THE VENDOR'S OWN DATABASE, which reported 69 migrations applied when
-- it had 136. Every object of all thirty-nine bundles was present and correct.
-- The schema was right; the record of it was wrong.
--
-- WHAT 0069 DOES, AND THE ONE ORDER IT CANNOT RECOVER FROM
--
-- 0069 created public.schema_migrations and, for a database that already had
-- the schema but no ledger, seeded rows for 0001 to 0069 labelled 'baseline'.
-- It seeds only when the ledger is EMPTY, which is correct: the interesting
-- date is when a file first landed, and re-seeding would overwrite it.
--
-- It also refuses to seed when its own probes say the chain is incomplete,
-- which is also correct: recording a migration a database does not have is
-- worse than recording nothing, because an operator reading "69 of 69 applied"
-- skips a repair the database needs.
--
-- Those two rules meet badly exactly once. If the probes refuse on the paste
-- that carries 0069, the block returns having seeded nothing, and then the SAME
-- bundle's closing block records its own twenty-two files. The ledger is now
-- non-empty for ever, so the first rule makes 0069 return early on every later
-- paste and the baseline can never arrive. 0001 to 0067 are absent
-- permanently, and nothing says so.
--
-- The signature is exact and it is what the vendor's database showed: rows for
-- 0068 to 0136 and no row anywhere labelled 'baseline'.
--
-- WHY THIS IS NOT COSMETIC. fn_platform_schema_state reports applied_count, the
-- latest file and any GAP in the numeric sequence, and the operator console
-- reads it to answer "what state is this database in". With sixty-seven files
-- missing it reports a database that is complete as one that is missing more
-- than half its migrations, which is an alarm that sends somebody to repair
-- what is already right.
--
-- WHAT THIS MIGRATION DOES
--
-- Records 0001 to 0067 as 'baseline', and only those: 0068 upward are carried
-- by bundles that record themselves, so they are already there or they are
-- genuinely absent, and either way this must not speak for them.
--
-- It asserts before it writes, with the SAME six probes 0069 uses, because the
-- range is exactly bundles 1 to 6 (bundle 6 ends at 0067 and bundle 7 begins at
-- 0068). If any probe fails, nothing is recorded and the notice names the
-- bundle. A back-fill that cannot be wrong about what it claims is the only
-- kind worth shipping.
--
-- It is a no-op on every database that is not in this state:
--
--   fresh install      bundles 1 to 6 record 0001 to 0067 as they go, so
--                      fn_record_migration does nothing on conflict and leaves
--                      every row and its original date alone
--   adopted database   0069 seeded them already, same outcome
--   behind on bundles  a probe fails, nothing is written, the notice says which
--
-- supabase/check-ledger-baseline.sh guards this list against drift the same way
-- it guards 0069's, so a migration added below 0068 cannot go unrecorded here.
-- =============================================================================

do $backfill$
declare
  v_missing text[] := '{}';
  v_files   text[] := array[
    '0001_core_schema.sql', '0002_fees.sql', '0003_attendance.sql',
    '0004_admissions.sql', '0005_exams.sql', '0006_settings.sql',
    '0007_certificates.sql', '0008_dashboard.sql', '0009_assessments.sql',
    '0010_staff.sql', '0011_auth.sql', '0012_import.sql',
    '0013_fee_import.sql', '0014_rollover.sql', '0015_exam_papers.sql',
    '0016_staff_import.sql', '0017_fee_ops.sql',
    '0018_fee_reconciliation.sql',
    '0019_student_links_and_admission_fee.sql', '0020_fee_month_ops.sql',
    '0021_fee_fixes.sql', '0022_teacher_portal.sql',
    '0023_test_scoping.sql', '0024_teacher_portal_hardening.sql',
    '0025_multi_tenancy.sql', '0026_subscriptions.sql',
    '0027_platform_admin.sql', '0028_pricing.sql', '0029_families.sql',
    '0030_expenses.sql', '0031_till.sql', '0032_parent_role.sql',
    '0033_portal.sql', '0034_outbox.sql', '0035_fee_ops.sql',
    '0036_family_linkage.sql', '0037_parent_access.sql',
    '0038_counter.sql', '0039_challan.sql', '0040_bulk_fees.sql',
    '0041_student_list.sql', '0042_dashboard_truth.sql',
    '0043_message_settings.sql', '0044_reports.sql',
    '0045_balance_sheet.sql', '0046_enquiries.sql',
    '0047_reachability.sql', '0048_corrections.sql',
    '0049_remarks_and_positions.sql', '0050_search_and_birthdays.sql',
    '0051_like_escaping.sql', '0052_recent_payments_order.sql',
    '0053_staff_leaving.sql', '0054_student_leaving.sql',
    '0055_rollover_scoping.sql', '0056_importer_scoping.sql',
    '0057_photos_and_logo.sql', '0058_exam_computation.sql',
    '0059_readonly_boundary.sql', '0060_refundable_deposits.sql',
    '0061_certificates.sql', '0062_staff_checkin.sql',
    '0063_constraint_function_grants.sql', '0064_operator_billing.sql',
    '0065_invite_only_provisioning.sql', '0066_fee_setup.sql',
    '0067_live_student_count.sql'
  ];
  f text;
  v_n integer := 0;
begin
  if to_regclass('public.schema_migrations') is null
     or to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice '0137: no migration ledger yet, nothing to back-fill';
    return;
  end if;

  -- Nothing to do: the baseline range is already complete.
  if not exists (
    select 1 from unnest(v_files) g(filename)
     where not exists (select 1 from public.schema_migrations m
                        where m.filename = g.filename)) then
  -- A MARKER THE CATALOGUE CAN SEE, and it is not decoration.
  -- supabase/repair/detect.sql is ONE statement, so Postgres resolves every
  -- relation in it at parse time: a row that read schema_migrations would make
  -- the whole report raise and print nothing on a database that has not
  -- reached bundle 7, which is exactly the database most likely to be running
  -- it. So this migration leaves evidence in the catalogue instead, and detect
  -- reads that. Set only on the two paths that end with the range complete,
  -- never on the refusal path, so it cannot claim a back-fill that did not
  -- happen.
  comment on table public.schema_migrations is
    'The deployment record for this database. 0137 has confirmed it records '
    'the 67 migrations that came before the ledger itself existed.';
    raise notice '0137: the ledger already records 0001 to 0067, nothing added';
    return;
  end if;

  -- array_append rather than the || form, for the reason 0069 writes out at
  -- length: Postgres resolves an untyped literal to anyarray||anyarray and dies
  -- with 'malformed array literal' on the one branch that protects a school.
  if not exists (select 1 from information_schema.tables
                  where table_schema = 'public' and table_name = 'till_sessions') then
    v_missing := array_append(v_missing, 'bundle 1 (0001-0031): till_sessions is absent');
  end if;

  if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                  where t.typname = 'user_role' and e.enumlabel = 'parent') then
    v_missing := array_append(v_missing, 'bundle 2 (0032): user_role has no parent value');
  end if;

  if not exists (select 1 from pg_proc where proname = 'fn_challan'
                  and pronamespace = 'public'::regnamespace) then
    v_missing := array_append(v_missing, 'bundle 3 (0033-0039): fn_challan is absent');
  end if;

  if not exists (select 1 from information_schema.tables
                  where table_schema = 'public' and table_name = 'exam_remarks') then
    v_missing := array_append(v_missing, 'bundle 4 (0040-0049): exam_remarks is absent');
  end if;

  -- Bundle 5 only REWROTE importers that date from 0015 and 0016, so its
  -- signature is the ABSENCE of the unscoped lookup, exactly as 0069 has it.
  if exists (select 1 from pg_proc
              where proname in ('fn_import_students', 'fn_import_opening_balances')
                and pronamespace = 'public'::regnamespace
                and prosrc not like '%school_id = public.current_school_id()%') then
    v_missing := array_append(v_missing, 'bundle 5 (0050-0056): an importer is still unscoped');
  end if;

  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'subscriptions'
                    and column_name = 'student_count') then
    v_missing := array_append(v_missing, 'bundle 6 (0057-0067): subscriptions.student_count is absent');
  end if;

  if array_length(v_missing, 1) is not null then
    raise notice '0137: NOT back-filling the ledger. This database is behind: %',
      array_to_string(v_missing, '; ');
    raise notice '0137: run supabase/repair/detect.sql and apply what it names, then paste this bundle again';
    return;
  end if;

  foreach f in array v_files
  loop
    if not exists (select 1 from public.schema_migrations m where m.filename = f) then
      perform public.fn_record_migration(
        f, 'baseline',
        'recorded by 0137: applied before the ledger existed, or before 0069 could seed it');
      v_n := v_n + 1;
    end if;
  end loop;

  -- A MARKER THE CATALOGUE CAN SEE, and it is not decoration.
  -- supabase/repair/detect.sql is ONE statement, so Postgres resolves every
  -- relation in it at parse time: a row that read schema_migrations would make
  -- the whole report raise and print nothing on a database that has not
  -- reached bundle 7, which is exactly the database most likely to be running
  -- it. So this migration leaves evidence in the catalogue instead, and detect
  -- reads that. Set only on the two paths that end with the range complete,
  -- never on the refusal path, so it cannot claim a back-fill that did not
  -- happen.
  comment on table public.schema_migrations is
    'The deployment record for this database. 0137 has confirmed it records '
    'the 67 migrations that came before the ledger itself existed.';

  raise notice '0137: back-filled % baseline row(s); the ledger now records % file(s)',
    v_n, (select count(*) from public.schema_migrations);
end $backfill$;
