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
-- 0035-0049 is the range where this can happen: bundle 3's file pattern kept
-- absorbing new migrations after it had already shipped, so different schools
-- stopped at different points inside it. Bundles 1, 2 and 5 have fixed contents
-- and are checked by verify.sql.
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
                      where table_schema = 'public' and table_name = 'exam_remarks')))
)
select migration,
       object                                   as looked_for,
       case when present then 'present' else 'MISSING' end as status,
       case when present then ''
            else 'run supabase/repair/' || migration || '.sql' end as action
from sig
order by migration;
