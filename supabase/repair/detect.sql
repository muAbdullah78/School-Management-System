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
              -- fn_checkin_display gates on has_role on purpose: a live
              -- check-in token is a key to the gate, not a read of the records.
              -- fn_pending_invites: access management, not a school record.
              and proname not in ('fn_may_manage_class', 'fn_may_write_school_file',
                                  'fn_pending_invites',
                                  'fn_checkin_display', 'may_view')))),
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
                        and table_name = 'certificate_cancellations'))),
  -- 0062's signature is an ABSENCE, because the defect was a PERMISSION, not a
  -- missing object. staff_att_insert allowed `staff_id = my_staff_id()`, so a
  -- teacher wrote her own attendance row — source 'qr', no code, from home — and
  -- the whole QR mechanism was decorative. A row that checked for the new table
  -- or fn_checkin_display would pass on a database where that branch had been
  -- put back.
  ('0062_staff_checkin',        'a teacher cannot write her own attendance row',
     (select not exists (select 1 from pg_policy pol
                          where pol.polname = 'staff_att_insert'
                            and pol.polrelid = 'public.staff_attendance'::regclass
                            and coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), '')
                                like '%my_staff_id%')
         and exists (select 1 from pg_proc where proname = 'fn_checkin_display'
                      and pronamespace = 'public'::regnamespace)
         and exists (select 1 from pg_constraint
                      where conname = 'staff_attendance_not_future'
                        and conrelid = 'public.staff_attendance'::regclass))),
  -- 0063 is a GRANT, so the signature is the privilege itself and not any object.
  -- A CHECK constraint's function runs as the writing user; fn_photo_path_ok was
  -- revoked from PUBLIC and never granted to authenticated, which made students,
  -- staff and school_settings unwritable by every signed-in user. Nobody could
  -- admit a child. Asked as a question about privileges, so it also covers a
  -- constraint function some later migration adds and forgets to grant.
  ('0063_constraint_function_grants', 'constraint functions executable by authenticated',
     (select not exists (
        select 1
          from pg_constraint con
          join pg_class rel on rel.oid = con.conrelid
          join pg_namespace n on n.oid = rel.relnamespace
          join pg_proc f on f.pronamespace = 'public'::regnamespace
         where n.nspname = 'public' and con.contype = 'c' and rel.relkind = 'r'
           and pg_get_constraintdef(con.oid) like '%' || f.proname || '(%'
           and not has_function_privilege('authenticated', f.oid, 'EXECUTE')))),
  -- 0064 REWROTE fn_activate_subscription (0026) and fn_platform_schools (0027),
  -- so neither name proves anything. The signature is the two facts that were
  -- missing: granting time writes a charge, and the console carries the
  -- receivable. Without the second, "who owes me money" and "who expires soon"
  -- are the same screen — which was the defect.
  ('0064_operator_billing',     'granting time writes the charge',
     (select exists (select 1 from pg_proc where proname = 'fn_activate_subscription'
                      and pronamespace = 'public'::regnamespace
                      and prosrc like '%platform_invoices%')
         and exists (select 1 from pg_proc where proname = 'fn_platform_schools'
                      and pronamespace = 'public'::regnamespace
                      and pg_get_function_result(oid) like '%outstanding%')
         and exists (select 1 from information_schema.tables
                      where table_schema = 'public'
                        and table_name = 'platform_payments'))),
  -- 0065's signature is a NEGATIVE plus two positives. handle_new_user dates
  -- from 0011, so "does it exist" proves nothing; what must be true is that it
  -- no longer reads a ROLE or a SCHOOL from the field the browser writes, and
  -- that both trusted channels are wired. A database missing 0065 lets any
  -- parent sign up again as 'principal'.
  ('0065_invite_only_provisioning', 'signup cannot choose its own role',
     (select exists (select 1 from pg_proc where proname = 'handle_new_user'
                      and pronamespace = 'public'::regnamespace
                      and prosrc like '%raw_app_meta_data%'
                      and prosrc like '%user_invites%'
                      and strpos(prosrc, 'raw_user_meta_data->>''role''') = 0)
         and exists (select 1 from information_schema.tables
                      where table_schema = 'public' and table_name = 'user_invites'))),
  -- 0066 REWROTE two billers that date from 0017 and 0020, so presence proves
  -- nothing. The signature is that both honour effective_from: without it, a
  -- scheduled fee rise bills the old price AND the new one on the same challan.
  ('0066_fee_setup',            'both billers honour effective_from',
     (select exists (select 1 from pg_proc where proname = 'fn_bill_student_month'
                      and pronamespace = 'public'::regnamespace
                      and prosrc like '%effective_from <=%')
         and exists (select 1 from pg_proc where proname = 'fn_student_monthly_fee'
                      and pronamespace = 'public'::regnamespace
                      and prosrc like '%effective_from <=%')
         and exists (select 1 from pg_proc where proname = 'fn_set_fee_amount'
                      and pronamespace = 'public'::regnamespace))),
  -- 0067's signature is the SIX triggers, counted exactly. A partial set leaves
  -- the count stale through whichever verb is missing, which is the same
  -- invisible-revenue defect in a narrower window.
  ('0067_live_student_count',   'six count triggers on students and enrollments',
     -- By NAME, never ::regproc. That cast raises on a missing function, and
     -- detect.sql must survive being run against a database missing anything —
     -- the first version aborted the entire file with 'function
     -- public.fn__refresh_counts_touched does not exist', taking every other
     -- row's answer with it.
     (select (select count(*) from pg_trigger t
               join pg_proc pr on pr.oid = t.tgfoid
               join pg_namespace nr on nr.oid = pr.pronamespace
               where not t.tgisinternal
                 and nr.nspname = 'public'
                 and pr.proname = 'fn__refresh_counts_touched'
                 and t.tgrelid in ('public.students'::regclass,
                                   'public.enrollments'::regclass)) = 6)),
  -- 0068 gated fn_my_licence's limit_notice on the renewal being close. The
  -- function has existed since 0026, so the signature is the gate variable.
  -- Without it, 0067's live count means a principal is told they have outgrown
  -- their plan the same afternoon they admit the 101st child.
  ('0068_limit_notice_timing',  'the over-limit banner is timed, not immediate',
     (select exists (select 1 from pg_proc where proname = 'fn_my_licence'
                      and pronamespace = 'public'::regnamespace
                      and prosrc like '%v_tell%'))),
  -- 0069 is the migration ledger — the thing whose absence is the reason this
  -- whole file exists. Its own header says it: "There is no migration ledger in
  -- this project, so nothing recorded what a given database had already
  -- applied."
  --
  -- The signature is the table AND the recording function, not just the table: a
  -- ledger nothing writes to is no better than no ledger, and the generated
  -- block at the end of every bundle calls fn_record_migration by name.
  ('0069_migration_ledger',     'schema_migrations + fn_record_migration',
     (select exists (select 1 from information_schema.tables
                      where table_schema = 'public' and table_name = 'schema_migrations')
         and exists (select 1 from pg_proc where proname = 'fn_record_migration'
                      and pronamespace = 'public'::regnamespace))),
  -- 0070 closed TWO cross-tenant defects, so the signature is all three of its
  -- parts. A database missing it lets one school read another school's family
  -- head name, phone, child's name and debt through fn_queue_message, AND write
  -- a discount line onto another school's invoice through
  -- fn__apply_discount_lines. Both functions predate it, so presence proves
  -- nothing — the tells are the school predicates inside them and the revoked
  -- grant that made the second one reachable.
  --
  -- has_function_privilege() is called through a pg_proc JOIN, never with a text
  -- signature: the text form RAISES on a missing function, and this file must
  -- survive being run against a database missing anything.
  ('0070_queue_message_scoping', 'family and invoice lookups are scoped',
     (select exists (select 1 from pg_proc where proname = 'fn_queue_message'
                      and pronamespace = 'public'::regnamespace
                      and prosrc like '%id = p_family_id and school_id = v_school%')
         and exists (select 1 from pg_proc where proname = 'fn__apply_discount_lines'
                      and pronamespace = 'public'::regnamespace
                      and prosrc like '%d.school_id = v_school%')
         and not exists (select 1 from pg_proc p
                          join pg_namespace n on n.oid = p.pronamespace
                          where n.nspname = 'public' and p.proname like 'fn\_\_%'
                            and has_function_privilege('authenticated', p.oid, 'execute')))),
  -- 0071 closed the PUBLIC grant. Postgres hands EXECUTE to PUBLIC on every new
  -- function, and 0001:702 gives `anon` usage on the schema, so all 212
  -- functions were callable by an unauthenticated request. Every one refused on
  -- its own gate, so this was inert — but it meant a future function that forgot
  -- its gate would be exposed to the internet rather than to signed-in staff.
  --
  -- The signature is the outcome, not the statement: anon can execute nothing in
  -- public, AND the signup Edge Function's entry point is reachable by
  -- service_role (0071 grants that explicitly; before it, signup worked only
  -- because Supabase's project bootstrap had granted routines to service_role by
  -- accident).
  ('0071_function_grants',      'anon can execute nothing in public',
     (select not exists (select 1 from pg_proc p
                          join pg_namespace n on n.oid = p.pronamespace
                          where n.nspname = 'public'
                            and has_function_privilege('anon', p.oid, 'execute'))
         and exists (select 1 from pg_proc p
                      join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname = 'public' and p.proname = 'fn_signup_school'
                        and has_function_privilege('service_role', p.oid, 'execute')))),
  -- 0072 scoped two lookups that searched every school. Both functions long
  -- predate it — fn_admit_student from 0004, fn_import_students from 0012 — so
  -- presence proves nothing and the signature has to be the predicate inside.
  -- Without it, the first admission at any new school attaches another school's
  -- fee head to the invoice, and the go-live importer refuses rows for a class
  -- the school owns because another school registered the same name first.
  ('0072_name_lookups_scoped',  'class names and fee-head types are per-school',
     (select exists (select 1 from pg_proc where proname = 'fn_admit_student'
                      and pronamespace = 'public'::regnamespace
                      and prosrc like '%type = ''admission'' and active and school_id = public.current_school_id()%')
         and exists (select 1 from pg_proc where proname = 'fn_import_students'
                      and pronamespace = 'public'::regnamespace
                      and prosrc like '%active and school_id = public.current_school_id() and lower(btrim(name))%')))
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
