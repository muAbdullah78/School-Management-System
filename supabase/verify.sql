-- =============================================================================
-- Did the install work? Run this in the SQL Editor after loading the bundles.
--
-- Read-only and safe to run any time, as often as you like.
-- Every row should say PASS. A failing row names what is MISSING, not a bundle to
-- re-run: run supabase/repair/detect.sql to see exactly what a database is missing, and why
-- 'just re-run the bundle' is not always the right advice.
--
-- These are structural checks, not counts of things that happen to exist today
-- — a check that says "46 tables" starts lying the moment a table is added.
--
-- IF A CHECK FAILS: each bundle is applied as one transaction, so a bundle that
-- errored applied NOTHING and is safe to run again. If you re-run it and get
-- "already exists", then that bundle DID apply and something else was changed
-- afterwards — in that case run supabase/reset.sql and start again from
-- bundle 1 rather than trying to patch it. Half-applied is not a state worth
-- repairing by hand.
-- =============================================================================

-- 1. Key tables from each bundle are present.
with expected(t, bundle) as (values
    ('students','1'), ('invoices','1'), ('payments','1'), ('attendance_daily','1'),
    ('result_cards','1'), ('families','1'), ('expenses','1'), ('till_sessions','1'),
    ('message_outbox','3'), ('message_templates','3')
),
missing as (
  select e.t, e.bundle from expected e
  where not exists (
    select 1 from information_schema.tables
     where table_schema = 'public' and table_name = e.t)
)
select 'tables present' as check,
       case when (select count(*) from missing) = 0 then 'PASS'
            else 'FAIL — missing ' || (select string_agg(t, ', ') from missing)
                 || ' — re-run bundle ' || (select min(bundle) from missing)
       end as result

union all
select 'parent role added (bundle 2)',
       case when exists (
         select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
          where t.typname = 'user_role' and e.enumlabel = 'parent')
       then 'PASS' else 'FAIL — re-run bundle 2' end

union all
select 'portal functions (bundle 3)',
       case when (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname in
                     ('fn_portal_me','fn_portal_child_fees',
                      'fn_portal_child_attendance','fn_portal_child_results')) = 4
       then 'PASS' else 'FAIL — re-run bundle 3' end

union all
-- EVERY migration from 0035 to 0049, not a hand-picked subset.
--
-- The previous version checked 0033 and then jumped to 0038-0046. A real school
-- ran it and got all PASS while migrations 0036 and 0037 were MISSING — 0036 is
-- the family-linkage fix, so verify.sql certified a database on which sibling
-- billing did not work. A check that covers a subset reports health it has not
-- measured.
--
-- 0035-0049 is the range where a gap can occur, because bundle 3's file pattern
-- kept absorbing new migrations after it had shipped and different schools
-- stopped at different points inside it. The signatures here are the same ones
-- supabase/repair/detect.sql uses, and CI asserts the two lists agree.
select 'migrations 0035-0049',
       coalesce('FAIL — missing ' || string_agg(m, ', ')
                  || ' — run supabase/repair/detect.sql, then the files it names',
                'PASS')
  from (
    select '0035' as m where not exists (select 1 from pg_proc where proname='fn_fee_amount' and pronamespace='public'::regnamespace)
    union all select '0036' where not exists (select 1 from pg_proc where proname='fn_merge_families' and pronamespace='public'::regnamespace)
    union all select '0037' where not exists (select 1 from pg_proc where proname='fn_family_parents' and pronamespace='public'::regnamespace)
    union all select '0038' where not exists (select 1 from pg_proc where proname='fn_counter_summary' and pronamespace='public'::regnamespace)
    union all select '0039' where not exists (select 1 from pg_proc where proname='fn_challan' and pronamespace='public'::regnamespace)
    union all select '0040' where not exists (select 1 from pg_proc where proname='fn_record_bulk_payments' and pronamespace='public'::regnamespace)
    union all select '0041' where not exists (select 1 from pg_proc where proname='fn_student_list' and pronamespace='public'::regnamespace)
    union all select '0042' where not exists (select 1 from pg_proc where proname='fn_import_staff' and pronamespace='public'::regnamespace
                                               and prosrc like '%employee_no = v_emp and deleted_at is null and school_id%')
    union all select '0043' where not exists (select 1 from pg_proc where proname='fn_message_settings' and pronamespace='public'::regnamespace)
    union all select '0044' where not exists (select 1 from pg_proc where proname='fn_report_ledger' and pronamespace='public'::regnamespace)
    union all select '0045' where not exists (select 1 from pg_proc where proname='fn_report_balance_sheet' and pronamespace='public'::regnamespace)
    union all select '0046' where not exists (select 1 from information_schema.tables where table_schema='public' and table_name='admission_enquiries')
    union all select '0047' where     exists (select 1 from pg_proc where proname='auth_role' and pronamespace='public'::regnamespace)
    union all select '0048' where not exists (select 1 from pg_proc where proname='fn_mark_corrections' and pronamespace='public'::regnamespace)
    union all select '0049' where not exists (select 1 from information_schema.tables where table_schema='public' and table_name='exam_remarks')
  ) gaps

union all
select 'search, birthdays, staff leaving (bundle 5)',
       case when (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname in
                     ('fn_global_search',      -- 0050 the header search box
                      'fn_birthdays',          -- 0050 birthdays
                      'fn_staff_roster',       -- 0053 staff with their login state
                      'fn_staff_leave',        -- 0053 recording a leaving
                      'fn_students_left')) = 5 -- 0054 children who have left
                 and exists (select 1 from information_schema.columns
                              where table_schema = 'public' and table_name = 'staff'
                                and column_name = 'dob')
                 -- 0053's constraint. Its absence means the migration applied
                 -- only in part, which would let 'inactive' back in.
                 and exists (select 1 from pg_constraint
                              where conname = 'staff_status_chk'
                                and conrelid = 'public.staff'::regclass)
                 -- 0054's column AND its constraint. The column alone would not
                 -- prove the migration finished.
                 and exists (select 1 from information_schema.columns
                              where table_schema = 'public' and table_name = 'students'
                                and column_name = 'left_on')
                 and exists (select 1 from pg_constraint
                              where conname = 'students_left_on_chk'
                                and conrelid = 'public.students'::regclass)
                 -- 0055. Checked by looking INSIDE fn_rollover for the school
                 -- filter on the class ladder, because the function has existed
                 -- since 0014 and its mere presence proves nothing: the whole
                 -- defect was that this one line was missing.
                 and exists (
                   select 1 from pg_proc p
                   join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname = 'fn_rollover'
                     and p.prosrc like '%c2.school_id = v_school%')
                 -- 0056. Same reasoning as 0055: these functions have existed
                 -- since 0015/0016, so their presence proves nothing. What has
                 -- to be true is that the per-school key lookups inside them
                 -- are scoped.
                 and not exists (
                   select 1 from pg_proc p
                   join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public'
                     and p.proname in ('fn_import_students', 'fn_import_opening_balances')
                     and (p.prosrc ~ 'from public\.students where gr_no'
                       or p.prosrc ~ 'from public\.students where admission_no'))
       then 'PASS' else 'FAIL — re-run bundle 5 (5_search.sql)' end

union all
select 'price plans loaded',
       case when (select count(*) from public.plans) = 4
       then 'PASS' else 'FAIL — re-run bundle 1' end

union all
-- THE ONE THAT PROTECTS CHILDREN.
-- Every table a parent must never read has to have exactly one SELECT policy,
-- and it must consult is_staff(). Policies OR together, so a second policy
-- without that check silently re-opens the table.
select 'parent lockout',
       coalesce(
         'FAIL — ' || string_agg(t, ', ') || ' — re-run bundle 3',
         'PASS')
  from (
    select t from unnest(array[
      'academic_sessions','assessments','attendance_daily','campuses','classes',
      'enrollments','exam_subjects','exam_terms','families','fee_heads',
      'fee_structures','guardians','mark_entries','result_cards','sections',
      'shifts','staff','student_links','students','subjects',
      'teacher_assignments','school_settings'
    ]) as t
    where (select count(*) from pg_policies p
            where p.schemaname='public' and p.tablename=t and p.cmd='SELECT') <> 1
       or not exists (select 1 from pg_policies p
            where p.schemaname='public' and p.tablename=t and p.cmd='SELECT'
              and p.qual like '%is_staff%')
  ) bad

union all
select 'signup trigger on auth.users',
       case when exists (select 1 from pg_trigger where tgname = 'on_auth_user_created')
       then 'PASS' else 'FAIL — re-run bundle 1' end

union all
select 'ready for first signup',
       case when (select count(*) from public.schools) = 0
            then 'PASS — no schools yet, as expected'
            else 'note: ' || (select count(*) from public.schools)::text
                 || ' school(s) already exist' end;
