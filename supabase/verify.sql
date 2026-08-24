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
                 -- 0051. 0041 wrote '\\' where it meant '\', so the student
                 -- roster could not find a roll number containing an underscore
                 -- — "A_1" is an ordinary roll number here. strpos rather than
                 -- LIKE because LIKE adds its own backslash escaping on top of
                 -- the literal's, and getting that wrong is how the first
                 -- version of this check passed on the broken body.
                 and exists (
                   select 1 from pg_proc p
                   join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname = 'fn_student_list'
                     and strpos(p.prosrc, $q$, '\%'$q$) > 0)
                 -- 0052. A tie-break on an ORDER BY that had none, so the
                 -- counter's "recent payments" list stopped reshuffling rows
                 -- taken in the same second.
                 and exists (
                   select 1 from pg_proc p
                   join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname = 'fn_recent_payments'
                     and p.prosrc like '%order by p.created_at desc, p.receipt_no desc%')
       then 'PASS' else 'FAIL — re-run bundle 5 (5_search.sql)' end

union all
select 'photographs and school logo (0057)',
       case when (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname in
                     ('fn_set_student_photo', 'fn_set_staff_photo', 'fn_set_school_logo',
                      'fn_class_photo_paths', 'fn_photo_path_ok',
                      'fn_may_read_school_file', 'fn_may_write_school_file')) = 7
                 -- The RENAMED columns, not the old ones. 0057 renames
                 -- photo_url → photo_path and logo_url → logo_path, because the
                 -- column holds a storage path and never a URL; finding the old
                 -- name means the rename did not happen and every read in the
                 -- app is looking at a column that is not there.
                 and exists (select 1 from information_schema.columns
                              where table_schema='public' and table_name='students'
                                and column_name='photo_path')
                 and exists (select 1 from information_schema.columns
                              where table_schema='public' and table_name='staff'
                                and column_name='photo_path')
                 and exists (select 1 from information_schema.columns
                              where table_schema='public' and table_name='school_settings'
                                and column_name='logo_path')
                 and not exists (select 1 from information_schema.columns
                                  where table_schema='public' and table_name='students'
                                    and column_name='photo_url')
                 -- The three CHECK constraints. Without them a path is whatever
                 -- a client sends, and a path is a folder — so their absence is
                 -- the difference between per-school isolation and none.
                 and (select count(*) from pg_constraint
                       where conname in ('students_photo_path_chk', 'staff_photo_path_chk',
                                         'school_settings_logo_path_chk')) = 3
       then 'PASS' else 'FAIL — run migrations/0057_photos_and_logo.sql' end

union all
select 'exam computation (0058)',
       case when (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname in
                     ('fn_takes_subject', 'fn_result_readiness', 'fn_upsert_exam_subject',
                      'fn_set_enrollment_stream', 'fn_class_streams',
                      'fn_set_subject_details')) = 6
                 and exists (select 1 from information_schema.columns
                              where table_schema='public' and table_name='mark_entries'
                                and column_name='practical_marks')
                 and exists (select 1 from information_schema.columns
                              where table_schema='public' and table_name='exam_terms'
                                and column_name='assessment_weight_pct')
                 -- The generator must be the THREE-argument version. The two-arg
                 -- one had no completeness check at all: it printed a pupil
                 -- nobody had marked as 0%, grade F, ranked. If the old
                 -- signature is still present the app can still call it.
                 and exists (select 1 from pg_proc p
                              join pg_namespace n on n.oid = p.pronamespace
                              where n.nspname='public' and p.proname='fn_generate_result_cards'
                                and p.pronargs = 3)
                 and not exists (select 1 from pg_proc p
                                  join pg_namespace n on n.oid = p.pronamespace
                                  where n.nspname='public' and p.proname='fn_generate_result_cards'
                                    and p.pronargs = 2)
                 -- And it must actually consult the stream rule. The function has
                 -- existed since 0005; its presence proves nothing, exactly as
                 -- with 0055's rollover fix.
                 and exists (select 1 from pg_proc p
                              join pg_namespace n on n.oid = p.pronamespace
                              where n.nspname='public' and p.proname='fn_generate_result_cards'
                                and p.prosrc like '%fn_takes_subject%')
       then 'PASS' else 'FAIL — run migrations/0058_exam_computation.sql' end

union all
select 'the observer role (0059)',
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                          where n.nspname='public' and p.proname='may_view'
                            and p.provolatile in ('s','i'))
                 -- EXACT, not a threshold. Every STABLE security-definer
                 -- function that gates on a role must use may_view — the two
                 -- write-authorising predicates below excepted.
                 --
                 -- A count threshold was the first version of this line and it
                 -- was not good enough. Proven, not guessed: on the upgrade path,
                 -- re-applying bundle 5 after 0059 restores SEVEN has_role read
                 -- gates from migrations 0050-0056, and a `>= 20` check passes
                 -- happily on the remaining forty. Those seven screens would
                 -- silently return zero rows to an observer again — the exact
                 -- defect 0059 exists to remove, reintroduced with verify.sql
                 -- reporting PASS. Only an exact check sees a PARTIAL revert.
                 and not exists (
                   select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname='public' and p.prosecdef and p.provolatile in ('s','i')
                     and p.prosrc like '%has_role(%'
                     and p.proname not in ('fn_may_manage_class',
                                           'fn_may_write_school_file', 'may_view'))
                 -- THE ONE THAT MATTERS. An observer must not be able to write.
                 -- A write policy consulting may_view would let one change a
                 -- child's record, and RLS would let it through with nothing
                 -- looking different.
                 and not exists (
                   select 1 from pg_policy pol
                   join pg_class c on c.oid = pol.polrelid
                   join pg_namespace n on n.oid = c.relnamespace
                   where n.nspname='public' and pol.polcmd <> 'r'
                     and (coalesce(pg_get_expr(pol.polqual, pol.polrelid), '')
                       || coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), ''))
                        like '%may_view(%')
                 and not exists (
                   select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname='public' and p.provolatile='v'
                     and p.prosrc like '%may_view(%')
                 -- The two permission predicates that LOOK like reads but
                 -- authorise writes elsewhere must still gate on has_role.
                 and not exists (
                   select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname='public'
                     and p.proname in ('fn_may_manage_class','fn_may_write_school_file')
                     and p.prosrc like '%may_view(%')
       then 'PASS' else 'FAIL — run migrations/0059_readonly_boundary.sql' end

union all
select 'refundable deposits (0060)',
       case when (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname='public' and p.proname in
                     ('fn_deposit_held', 'fn_charge_deposit', 'fn_refund_deposit',
                      'fn_deposits_held', 'fn_invoice_no_mixed_refundable')) = 5
                 and exists (select 1 from information_schema.tables
                              where table_schema='public' and table_name='deposit_refunds')
                 -- The trigger, without which a deposit can share a challan with
                 -- tuition and "how much of this payment was the deposit" stops
                 -- being answerable at all.
                 and exists (select 1 from pg_trigger
                              where tgname = 'trg_invoice_no_mixed_refundable'
                                and tgrelid = 'public.invoice_lines'::regclass
                                and not tgisinternal)
                 -- THE ONE THAT MATTERS. Both money functions must actually
                 -- exclude deposits; their mere presence proves nothing, since
                 -- both have existed since 0030/0045.
                 and exists (select 1 from pg_proc p
                              join pg_namespace n on n.oid = p.pronamespace
                              where n.nspname='public' and p.proname='fn_finance_summary'
                                and p.prosrc like '%deposits_collected%')
                 and exists (select 1 from pg_proc p
                              join pg_namespace n on n.oid = p.pronamespace
                              where n.nspname='public' and p.proname='fn_report_balance_sheet'
                                and p.prosrc like '%deposits_held%')
       then 'PASS' else 'FAIL — run migrations/0060_refundable_deposits.sql' end

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
