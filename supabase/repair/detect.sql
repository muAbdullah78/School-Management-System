-- =============================================================================
-- WHICH MIGRATIONS IS THIS DATABASE MISSING?
--
-- Read-only. Safe to run any time. Run it BEFORE any repair file.
--
-- WHY THIS EXISTS
--
-- There is no migration ledger in this project, so nothing recorded what a
-- given database had already applied. When a school reported a broken install I
-- guessed their history from the error message, guessed WRONG (I said fifteen
-- migrations were missing; it was two), and handed them a repair file that
-- failed on its first statement because it began with a migration they already
-- had.
--
-- Guessing was the mistake. This asks the database instead.
--
-- Each row names one migration and looks for an object that migration and only
-- that migration creates. A missing object means the migration never applied.
--
-- 0035-0049 is the range where the SCATTERED kind of gap happened: bundle 3's
-- file pattern kept absorbing new migrations after it had already shipped, so
-- different schools stopped at different points inside it. Those rows each have
-- a repair file.
--
-- 0050 onward are listed too, without repair files, because "is my database up
-- to date?" is a question a school asks every time it upgrades and the answer
-- should not stop at 0049. For those rows the action is to run the migration
-- itself, which is safe: every one of them is written to be re-runnable.
-- =============================================================================

with sig(migration, object, present) as (values
  ('0035_fee_ops',              'fn_fee_amount',
     (select exists (select 1 from pg_proc where proname = 'fn_fee_amount'
                      and pronamespace = 'public'::regnamespace))),
  ('0036_family_linkage',       'fn_merge_families',
     (select exists (select 1 from pg_proc where proname = 'fn_merge_families'
                      and pronamespace = 'public'::regnamespace))),
  ('0037_parent_access',        'fn_family_parents',
     (select exists (select 1 from pg_proc where proname = 'fn_family_parents'
                      and pronamespace = 'public'::regnamespace))),
  ('0038_counter',              'fn_counter_summary',
     (select exists (select 1 from pg_proc where proname = 'fn_counter_summary'
                      and pronamespace = 'public'::regnamespace))),
  ('0039_challan',              'fn_challan',
     (select exists (select 1 from pg_proc where proname = 'fn_challan'
                      and pronamespace = 'public'::regnamespace))),
  ('0040_bulk_fees',            'fn_record_bulk_payments',
     (select exists (select 1 from pg_proc where proname = 'fn_record_bulk_payments'
                      and pronamespace = 'public'::regnamespace))),
  ('0041_student_list',         'fn_student_list',
     (select exists (select 1 from pg_proc where proname = 'fn_student_list'
                      and pronamespace = 'public'::regnamespace))),
  -- 0042 replaced EXISTING functions rather than adding one, so its signature
  -- has to be a change INSIDE a body: it scoped the staff importer's duplicate
  -- checks to one school. fn_dashboard_summary would be the obvious pick and is
  -- wrong — it has existed since 0008.
  ('0042_dashboard_truth',      'scoped staff import',
     (select exists (select 1 from pg_proc where proname = 'fn_import_staff'
                      and pronamespace = 'public'::regnamespace
                      and prosrc like '%employee_no = v_emp and deleted_at is null and school_id%'))),
  ('0043_message_settings',     'fn_message_settings',
     (select exists (select 1 from pg_proc where proname = 'fn_message_settings'
                      and pronamespace = 'public'::regnamespace))),
  ('0044_reports',              'fn_report_ledger',
     (select exists (select 1 from pg_proc where proname = 'fn_report_ledger'
                      and pronamespace = 'public'::regnamespace))),
  ('0045_balance_sheet',        'fn_report_balance_sheet',
     (select exists (select 1 from pg_proc where proname = 'fn_report_balance_sheet'
                      and pronamespace = 'public'::regnamespace))),
  ('0046_enquiries',            'admission_enquiries table',
     (select exists (select 1 from information_schema.tables
                      where table_schema = 'public' and table_name = 'admission_enquiries'))),
  -- 0047 DROPPED two dead functions, so its signature is an absence.
  ('0047_reachability',         'auth_role() removed',
     (select not exists (select 1 from pg_proc where proname = 'auth_role'
                          and pronamespace = 'public'::regnamespace))),
  ('0048_corrections',          'fn_mark_corrections',
     (select exists (select 1 from pg_proc where proname = 'fn_mark_corrections'
                      and pronamespace = 'public'::regnamespace))),
  ('0049_remarks_and_positions','exam_remarks table',
     (select exists (select 1 from information_schema.tables
                      where table_schema = 'public' and table_name = 'exam_remarks'))),

  -- ---------------------------------------------------------------------------
  -- 0050 onward. No repair files: run the migration itself.
  --
  -- Several of these REPLACED existing functions rather than adding new ones, so
  -- their signature has to be a fact about a body — the same trap 0042 set. A
  -- row that checks for a function which has existed since 0014 proves nothing
  -- and would report a broken database as healthy, which is exactly the failure
  -- verify.sql already made once.
  -- ---------------------------------------------------------------------------
  ('0050_search_and_birthdays', 'fn_global_search',
     (select exists (select 1 from pg_proc where proname = 'fn_global_search'
                      and pronamespace = 'public'::regnamespace))),
  -- 0051 fixed OVER-escaping in fn_student_list: 0041 wrote '\\' where it meant
  -- '\', so a roll number containing an underscore could not be found. Nothing
  -- new was created, so the signature is the corrected literal itself.
  --
  -- Dollar-quoted, and matched with strpos rather than LIKE, because LIKE has its
  -- own backslash escaping on top of the string literal's and the first version
  -- of this row got that wrong twice over: it looked at fn_global_search, which
  -- 0051 never touched, and matched a pattern 0041's body satisfies too. It
  -- reported a database missing 0051 as healthy — the same false-PASS this whole
  -- file exists to prevent.
  ('0051_like_escaping',        'fn_student_list escapes LIKE correctly',
     (select exists (select 1 from pg_proc where proname = 'fn_student_list'
                      and pronamespace = 'public'::regnamespace
                      and strpos(prosrc, $q$, '\%'$q$) > 0))),
  -- 0052 added a TIE-BREAK to an ORDER BY, so the signature is that second sort
  -- key. fn_recent_payments has existed since 0038; its presence proves nothing,
  -- and the first version of this row looked for a 'nulls last' clause 0052 does
  -- not contain, which reported a complete database as broken.
  ('0052_recent_payments_order','recent payments order has a tie-break',
     (select exists (select 1 from pg_proc where proname = 'fn_recent_payments'
                      and pronamespace = 'public'::regnamespace
                      and prosrc like '%order by p.created_at desc, p.receipt_no desc%'))),
  ('0053_staff_leaving',        'fn_staff_leave',
     (select exists (select 1 from pg_proc where proname = 'fn_staff_leave'
                      and pronamespace = 'public'::regnamespace))),
  ('0054_student_leaving',      'students.left_on',
     (select exists (select 1 from information_schema.columns
                      where table_schema = 'public' and table_name = 'students'
                        and column_name = 'left_on'))),
  -- 0055 scoped fn_rollover, which has existed since 0014. Its presence proves
  -- nothing; the missing school filter WAS the defect.
  ('0055_rollover_scoping',     'rollover scoped to one school',
     (select exists (select 1 from pg_proc where proname = 'fn_rollover'
                      and pronamespace = 'public'::regnamespace
                      and prosrc like '%c2.school_id = v_school%'))),
  -- 0056 likewise: the importers date from 0015/0016, so the signature is the
  -- ABSENCE of the unscoped lookup.
  ('0056_importer_scoping',     'importers scoped on GR / admission no',
     (select not exists (select 1 from pg_proc
                          where proname in ('fn_import_students', 'fn_import_opening_balances')
                            and pronamespace = 'public'::regnamespace
                            and (prosrc ~ 'from public\.students where gr_no'
                              or prosrc ~ 'from public\.students where admission_no')))),
  -- 0057 RENAMED two columns, so the old name still being there is the tell.
  ('0057_photos_and_logo',      'students.photo_path (renamed from photo_url)',
     (select exists (select 1 from information_schema.columns
                      where table_schema = 'public' and table_name = 'students'
                        and column_name = 'photo_path')
         and exists (select 1 from pg_proc where proname = 'fn_set_student_photo'
                      and pronamespace = 'public'::regnamespace))),
  -- 0058 REWROTE fn_generate_result_cards, which has existed since 0005. Its
  -- presence proves nothing; what has to be true is that it reads the stream
  -- rule, because without that a class-9 card was computed over every paper in
  -- the class and turned two A+ pupils into a C and a D.
  ('0058_exam_computation',     'result cards read the stream rule',
     (select exists (select 1 from pg_proc where proname = 'fn_generate_result_cards'
                      and pronamespace = 'public'::regnamespace
                      and prosrc like '%fn_takes_subject%')
         and exists (select 1 from information_schema.columns
                      where table_schema = 'public' and table_name = 'mark_entries'
                        and column_name = 'practical_marks'))),
  -- 0059's signature is that NO read gate is left on has_role — exact, not a
  -- count. A threshold was the first version and it misses a PARTIAL revert:
  -- re-applying bundle 5 after 0059 restores seven has_role gates from
  -- migrations 0050-0056, and a `>= 20` check passes on the remaining forty
  -- while those seven screens silently return zero rows to an observer again.
  -- 0060 REWROTE two money functions that date from 0030 and 0045, so the
  -- signature must be a fact about a body: does the profit calculation know that
  -- a refundable deposit is not income? Without it, a Rs 5,000 deposit counts as
  -- Rs 5,000 of profit.
  ('0060_refundable_deposits',  'deposits are excluded from profit',
     (select exists (select 1 from pg_proc where proname = 'fn_finance_summary'
                      and pronamespace = 'public'::regnamespace
                      and prosrc like '%deposits_collected%')
         and exists (select 1 from information_schema.tables
                      where table_schema = 'public' and table_name = 'deposit_refunds'))),
  ('0059_readonly_boundary',    'no read gate left on has_role',
     (select exists (select 1 from pg_proc where proname = 'may_view'
                      and pronamespace = 'public'::regnamespace)
         and not exists (
           select 1 from pg_proc
            where pronamespace = 'public'::regnamespace
              and prosecdef and provolatile in ('s','i')
              and prosrc like '%has_role(%'
              and proname not in ('fn_may_manage_class', 'fn_may_write_school_file',
                                  'may_view')))),
  -- 0061 REWROTE fn_issue_certificate, which has existed since 0021. Its
  -- presence proves nothing at all, and neither does the new table: the
  -- signature has to be a fact about the body. Two facts, because the two
  -- defects are independent. It must record the leaving through
  -- fn_set_student_status — without that a child holds a leaving certificate
  -- while still on the attendance register and in next month's billing — and it
  -- must strip the reserved keys, or the caller's free-form data can forge the
  -- pupil's name, the DUPLICATE stamp and the dues position on the document.
  ('0061_certificates',         'issuing records the leaving, snapshot not forgeable',
     (select exists (select 1 from pg_proc where proname = 'fn_issue_certificate'
                      and pronamespace = 'public'::regnamespace
                      and prosrc like '%fn_set_student_status%'
                      -- What goes into the ROW, not what the function computes
                      -- on the way there. Two earlier versions of this line were
                      -- both too loose and were caught by reverting the fix and
                      -- watching the check still pass: `v_reserved` alone matches
                      -- the declaration, and `- v_reserved` matches the
                      -- assignment to v_extra — both of which a revert leaves in
                      -- place, doing nothing. Only the insert expression is
                      -- evidence that the stripped copy is what gets stored.
                      and strpos(prosrc, '|| v_extra') > 0
                      and strpos(prosrc, '|| coalesce(p_data') = 0)
         and exists (select 1 from pg_proc where proname = 'fn_certificate_readiness'
                      and pronamespace = 'public'::regnamespace)
         and exists (select 1 from information_schema.tables
                      where table_schema = 'public'
                        and table_name = 'certificate_cancellations')))
)
select migration,
       object                                   as looked_for,
       case when present then 'present' else 'MISSING' end as status,
       case when present then ''
            when migration < '0050'
              then 'run supabase/repair/' || migration || '.sql'
            else 'run supabase/migrations/' || migration || '.sql' end as action
from sig
order by migration;
