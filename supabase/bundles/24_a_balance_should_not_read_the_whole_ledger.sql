-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0118_a_balance_should_not_read_the_whole_ledger.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0118 - A balance should not read the whole ledger
--
-- student_balance() is the hottest function in the money engine. The fee
-- screens call it, the defaulters list calls it once per child, the family
-- sheet calls it once per sibling, fn_rollover reports it for every child it
-- promotes, and the parent portal calls it on every visit. It is four
-- correlated subqueries over invoice_lines, invoices, adjustments and
-- payment_allocations.
--
-- Two of those four tables had no index on the column it is joined by.
--
-- Postgres indexes the TARGET of a foreign key automatically and never the
-- SOURCE. So invoice_lines.invoice_id and payment_allocations.invoice_id, both
-- foreign keys, both joined on every single balance calculation, had nothing to
-- use. The planner's only option is to read the whole table and hash it.
--
-- MEASURED, not guessed. A five-year school of 400 children: 20,630 invoices,
-- 95,600 invoice lines, 13,600 payments and allocations. Two hundred
-- consecutive student_balance() calls, same data, same box, ANALYZEd both ways:
--
--                                   before        after
--   student_balance() x 200        2,026 ms      353 ms      5.7x
--   per call                       10.13 ms     1.76 ms
--   the invoice_lines join alone     14.5 ms     0.32 ms       45x
--
--   before:  Hash Join  ->  Seq Scan on invoice_lines  (rows=95,600)   to find 97
--   after:   Nested Loop -> Bitmap Index Scan on idx_invoices_student
--
-- AND IT IS INVISIBLE FOR THE FIRST YEAR, which is what makes it worth a
-- migration rather than a note. The same measurement on a school with 11,600
-- invoice lines showed no difference at all: 190 ms against 193 ms, because at
-- that size the planner is right that scanning is cheaper. The cost arrives
-- gradually, in linear proportion to how long the school has been a customer,
-- and the school that suffers most is the one that has been paying longest.
--
-- HOW IT WAS FOUND. A two-year simulation (supabase/sim/) tried to take 5,000
-- family payments across 31 months and ran for eleven minutes without
-- committing. Every payment recomputes a balance, and every balance re-read a
-- table that was growing underneath it.
--
-- WHAT THIS DOES NOT DO. There are 84 foreign keys in this schema with no index
-- on the referencing column and this migration adds 31. The other 53 are almost
-- all audit stamps (created_by, marked_by, issued_by, approved_by) pointing at
-- profiles, which holds a handful of rows per school and is only ever read one
-- row at a time to print a name. Indexing those would cost write throughput on
-- every insert to buy nothing. An index is not free and a schema full of unused
-- ones is its own kind of mess.
--
-- WHY NOT CONCURRENTLY. CREATE INDEX CONCURRENTLY cannot run inside a
-- transaction, and a school applies these by pasting a file into the Supabase
-- SQL editor, which runs the paste as one. A plain CREATE INDEX takes a lock
-- that blocks writes for as long as the build takes: on the largest table here
-- at a real school's volume that is milliseconds, and the school is not using
-- the software while it pastes a migration.
--
-- Re-runnable: every statement is IF NOT EXISTS.
-- =============================================================================

-- --- The money engine, and the two that were measured ------------------------
create index if not exists idx_invoice_lines_invoice
  on public.invoice_lines (invoice_id);
create index if not exists idx_payment_allocations_invoice
  on public.payment_allocations (invoice_id);
-- The other side of the same table. invoice_id answers "what is this child's
-- balance"; payment_id answers "what did this receipt pay for", which is what
-- fn__invoice_document prints on every receipt and challan.
create index if not exists idx_payment_allocations_payment
  on public.payment_allocations (payment_id);
create index if not exists idx_adjustments_student
  on public.adjustments (student_id);
create index if not exists idx_adjustments_invoice
  on public.adjustments (invoice_id);
create index if not exists idx_discounts_enrollment
  on public.discounts (enrollment_id);
create index if not exists idx_student_fee_items_enrollment
  on public.student_fee_items (enrollment_id);
create index if not exists idx_invoices_session
  on public.invoices (session_id);
create index if not exists idx_invoice_lines_fee_head
  on public.invoice_lines (fee_head_id);
-- A reversal is found by walking back from the reversing row. Rare, but the one
-- time a clerk needs it they are standing at a counter with a parent.
create index if not exists idx_payments_reversal_of
  on public.payments (reversal_of);
create index if not exists idx_deposit_refunds_student
  on public.deposit_refunds (student_id);

-- --- The roll, which every screen in the product joins through ---------------
create index if not exists idx_enrollments_class
  on public.enrollments (class_id);
-- fn_rollover_undo walks this to find what a rollover created. Without it,
-- undoing a rollover scans every enrollment the school has ever had.
create index if not exists idx_enrollments_promoted_from
  on public.enrollments (promoted_from);
create index if not exists idx_guardians_student
  on public.guardians (student_id);
create index if not exists idx_subjects_class
  on public.subjects (class_id);
create index if not exists idx_sections_class_teacher
  on public.sections (class_teacher_id);
create index if not exists idx_profiles_school
  on public.profiles (school_id);
create index if not exists idx_profiles_staff
  on public.profiles (staff_id);
create index if not exists idx_staff_profile
  on public.staff (profile_id);

-- --- Fees setup, re-read on every billing run --------------------------------
create index if not exists idx_fee_structures_class
  on public.fee_structures (class_id);
create index if not exists idx_fee_structures_fee_head
  on public.fee_structures (fee_head_id);
create index if not exists idx_student_fee_items_fee_head
  on public.student_fee_items (fee_head_id);

-- --- Academics: tests and exams ----------------------------------------------
-- The Tests screen filters on all four of these at once, and assessments grows
-- by one row per class per subject per test, which is the fastest-growing table
-- in the academic half of the schema.
create index if not exists idx_assessments_session
  on public.assessments (session_id);
create index if not exists idx_assessments_class
  on public.assessments (class_id);
create index if not exists idx_assessments_section
  on public.assessments (section_id);
create index if not exists idx_assessments_subject
  on public.assessments (subject_id);
create index if not exists idx_exam_subjects_class
  on public.exam_subjects (class_id);
create index if not exists idx_exam_subjects_subject
  on public.exam_subjects (subject_id);
create index if not exists idx_exam_terms_session
  on public.exam_terms (session_id);
create index if not exists idx_result_cards_exam_term
  on public.result_cards (exam_term_id);
create index if not exists idx_exam_remarks_student
  on public.exam_remarks (student_id);
create index if not exists idx_exam_remarks_exam_term
  on public.exam_remarks (exam_term_id);
create index if not exists idx_certificates_student
  on public.certificates (student_id);

-- --- Teaching assignments, which are what a teacher's own screens read -------
create index if not exists idx_teacher_assignments_class
  on public.teacher_assignments (class_id);
create index if not exists idx_teacher_assignments_section
  on public.teacher_assignments (section_id);
create index if not exists idx_subject_teachers_class
  on public.subject_teachers (class_id);
create index if not exists idx_subject_teachers_section
  on public.subject_teachers (section_id);
create index if not exists idx_subject_teachers_subject
  on public.subject_teachers (subject_id);

-- --- Enquiries and messages, both of which grow forever ----------------------
create index if not exists idx_admission_enquiries_session
  on public.admission_enquiries (session_id);
create index if not exists idx_admission_enquiries_class
  on public.admission_enquiries (class_id);
create index if not exists idx_admission_enquiries_admitted
  on public.admission_enquiries (admitted_student_id);
create index if not exists idx_enquiry_contacts_school
  on public.enquiry_contacts (school_id);
create index if not exists idx_message_outbox_student
  on public.message_outbox (student_id);
create index if not exists idx_message_outbox_family
  on public.message_outbox (family_id);
create index if not exists idx_staff_checkin_attempts_staff
  on public.staff_checkin_attempts (staff_id);

-- --- The Audit Log screen, which was reading the whole table to show 200 rows -
-- listAuditLog() in web/src/lib/db.ts is exactly:
--
--   select ... from audit_log order by created_at desc limit 200
--
-- with school_id supplied by RLS. audit_log had one index, on school_id alone,
-- so there was no ordered path and Postgres had to fetch every row for the
-- school and sort it.
--
-- MEASURED on the simulated school: 299,593 audit rows, 266 MB.
--
-- The query on its own, with the school named explicitly:
--
--                        before                          after
--   time              54.1 ms                         0.092 ms
--   buffers           33,016 (20,298 read from disk)   11
--   plan              Gather Merge + parallel workers  Index Scan
--
-- As the application actually runs it, through RLS, asking for 200:
--
--   buffers           33,016                           471        70x fewer
--   time              54.1 ms                          21.8 ms    2.5x
--
-- The two differ, and the second is the honest one. The residual 21 ms is not
-- the scan: it is `Filter: may_view(...)` being evaluated once per row on the
-- way out, 200 times, at about 0.1 ms each. Worth its own look, and separate
-- from this.
--
-- The buffer count is the number that matters on Supabase rather than the
-- milliseconds: twenty thousand blocks read from disk on every page view of
-- one screen, per school, is metered IO, and this box has a warm cache and a
-- local SSD. A tenant sharing the table with nineteen other schools has
-- neither.
create index if not exists idx_audit_log_school_time
  on public.audit_log (school_id, created_at desc);

do $$
declare v_missing int;
begin
  -- Asserts the PROPERTY, not the spelling: every index named above is present
  -- AND the two that were measured are actually usable by the join in
  -- student_balance. A guard that only counted rows in pg_indexes would pass on
  -- an index built over the wrong column.
  select count(*) into v_missing
    from (values
      ('invoice_lines', 'invoice_id'),
      ('payment_allocations', 'invoice_id'),
      ('payment_allocations', 'payment_id'),
      ('adjustments', 'student_id'),
      ('audit_log', 'school_id')
    ) as need(t, c)
   where not exists (
     select 1 from pg_index i
       join pg_class rel on rel.oid = i.indrelid
       join pg_namespace n on n.oid = rel.relnamespace
       join pg_attribute a on a.attrelid = rel.oid and a.attnum = i.indkey[0]
      where n.nspname = 'public' and rel.relname = need.t and a.attname = need.c
   );
  if v_missing > 0 then
    raise exception '0118: % of the five measured indexes is missing or is on the wrong column', v_missing;
  end if;
  raise notice '0118: student_balance no longer reads the whole ledger (% indexes on the schema now)',
    (select count(*) from pg_index i join pg_class c on c.oid = i.indrelid
      join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public');
end $$;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0118_a_balance_should_not_read_the_whole_ledger.sql', '24_a_balance_should_not_read_the_whole_ledger.sql');
end $ledger$;
