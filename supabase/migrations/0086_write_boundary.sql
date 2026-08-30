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
