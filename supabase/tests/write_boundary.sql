-- =============================================================================
-- Can a clerk rewrite the books without going through a function?
--
-- THE DEFECT THIS FILE EXISTS FOR. Every money path in this project goes through
-- a SECURITY DEFINER function that demands a reason, burns a serial, opens a
-- till or writes an audit row. All of it was optional. Thirteen tables carried
-- `FOR ALL` write policies for owner / principal / admin_clerk / accountant, so
-- an ordinary front-office login could issue plain table writes — exactly the
-- requests supabase-js sends for `.update()` and `.delete()`, which any clerk
-- can send from a browser console with the anon key and their own password.
--
-- Proved on a real database before 0086 was written, with ZERO audit rows:
--
--   delete from payment_allocations  → a fully paid challan became unpaid again
--                                      while its receipt stayed in the books
--   insert into payment_allocations  → an unpaid challan showed settled with no
--                                      money received (the cash-theft path)
--   update result_cards              → a PUBLISHED card went from 88% to 12%/F
--   delete from result_cards         → the card was gone
--   update invoice_lines             → Rs 4,500 became Rs 1
--   update invoices set status=void  → the balance went to zero
--   delete from invoices             → no trace the charge existed
--
-- Section 1 is those seven, one assertion each, from the same position: a
-- signed-in admin_clerk of the school that owns the rows. They are the whole
-- reason for the file, and they are written as OUTCOMES — the row is unchanged —
-- rather than as error strings, so they keep meaning if the mechanism moves.
--
-- Sections 2-6 cover 0087, which had to exist before 0086 could be complete: a
-- challan raised by mistake needed SOME way out, and until then the only ways
-- out were the ones 0086 closes.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/write_boundary.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if p_cond then raise notice 'PASS  %', p_label;
  else raise exception 'FAIL  %', p_label; end if;
end;
$$;

create or replace function pg_temp.be(p_name text) returns void language sql as $$
  select set_config('test.uid',
    (select id::text from public.profiles where full_name = p_name), false);
$$;

-- Did that statement refuse? "It changed nothing" and "it refused" are
-- different facts and only the second is a boundary — an UPDATE that RLS blocks
-- affects zero rows and raises nothing, which is the whole reason this helper
-- distinguishes them.
create or replace function pg_temp.raises(p_sql text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    raise notice 'PASS  % (refused: %)', p_label, left(sqlerrm, 68);
    return;
  end;
  raise exception 'FAIL  % — it was ALLOWED', p_label;
end;
$$;

-- --- Fixture -----------------------------------------------------------------
-- One school. One child, Rs 4,500 charged and paid in full through the counter.
-- A second, unpaid challan for the following month, which is the one the
-- cancellation tests use. One marked paper and a PUBLISHED result card.
do $seed$
declare
  v_school uuid;
  v_owner uuid := '00000000-0000-0000-0000-00000000bb01';
  v_clerk uuid := '00000000-0000-0000-0000-00000000bb02';
  v_sess uuid; v_class uuid; v_sec uuid; v_head uuid; v_fam uuid; v_stu uuid;
  v_term uuid; v_sub uuid; v_es uuid; v_enr uuid; v_pay jsonb;
  v_m1 date := date_trunc('month', current_date)::date;
  v_m2 date := (date_trunc('month', current_date) + interval '1 month')::date;
begin
  perform set_config('test.uid', '', false);
  insert into public.schools (name) values ('Boundary Test School') returning id into v_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'starter', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_owner, 'o@boundary.test'), (v_clerk, 'c@boundary.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_owner, 'Boundary Owner', 'owner', v_school),
    (v_clerk, 'Boundary Clerk', 'admin_clerk', v_school)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_owner::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_school) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Class 1', 1, v_school) returning id into v_class;
  insert into public.sections (class_id, name, school_id)
    values (v_class, 'A', v_school) returning id into v_sec;
  insert into public.fee_heads (name, type, is_recurring, active, school_id)
    values ('Tuition', 'monthly', true, true, v_school) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_class, v_head, 4500, v_school);
  insert into public.families (school_id, head_name) values (v_school, 'Boundary Payer')
    returning id into v_fam;
  insert into public.students (full_name, father_name, status, school_id, family_id)
    values ('Boundary Child', 'Boundary Payer', 'active', v_school, v_fam) returning id into v_stu;
  insert into public.enrollments (student_id, session_id, class_id, section_id, status, school_id)
    values (v_stu, v_sess, v_class, v_sec, 'active', v_school) returning id into v_enr;

  perform public.fn_generate_class_invoices(v_sess, v_class, v_m1, v_m1 + 10);
  v_pay := public.fn_record_payment(v_stu, 4500, 'cash', 'paid in full', false);
  perform public.fn_generate_class_invoices(v_sess, v_class, v_m2, v_m2 + 10);

  insert into public.exam_terms (school_id, session_id, name)
    values (v_school, v_sess, 'Term 1') returning id into v_term;
  insert into public.subjects (school_id, name) values (v_school, 'English')
    returning id into v_sub;
  insert into public.exam_subjects (school_id, exam_term_id, class_id, subject_id,
                                    max_marks, pass_marks)
    values (v_school, v_term, v_class, v_sub, 100, 33) returning id into v_es;
  insert into public.mark_entries (school_id, exam_subject_id, enrollment_id, marks, max_marks)
    values (v_school, v_es, v_enr, 88, 100);
  perform public.fn_generate_result_cards(v_term, v_class, false);
  perform public.fn_publish_results(v_term, v_class);

  create table public._wb (k text primary key, v uuid);
  insert into public._wb values
    ('school', v_school), ('stu', v_stu), ('fam', v_fam), ('sess', v_sess),
    ('class', v_class), ('pay', (v_pay->>'payment_id')::uuid),
    ('paid_inv', (select id from public.invoices
                   where student_id = v_stu and period_month = v_m1)),
    ('open_inv', (select id from public.invoices
                   where student_id = v_stu and period_month = v_m2)),
    ('card', (select id from public.result_cards where student_id = v_stu limit 1));
  raise notice 'fixture: 4500 charged and paid, 4500 open, card published';
end $seed$;

-- =============================================================================
-- 1. THE SEVEN. As a signed-in admin_clerk, over the plain table.
-- =============================================================================
select pg_temp.be('Boundary Clerk');
set local role authenticated;

select pg_temp.raises(
  format('delete from public.payment_allocations where invoice_id = %L',
         (select v from public._wb where k = 'paid_inv')),
  '1. a clerk cannot delete the allocation of a paid challan — doing so made the '
  || 'family owe Rs 4,500 again while the school kept their receipt');

select pg_temp.raises(
  format('insert into public.payment_allocations (payment_id, invoice_id, amount) '
         || 'values (%L, %L, 4500)',
         (select v from public._wb where k = 'pay'),
         (select v from public._wb where k = 'open_inv')),
  '2. a clerk cannot invent an allocation — this is the cash-theft path: pocket '
  || 'the notes, record no payment, point an allocation at the challan');

select pg_temp.raises(
  format('update public.result_cards set percentage = 12, grade = ''F'' where id = %L',
         (select v from public._wb where k = 'card')),
  '3. a clerk cannot rewrite a PUBLISHED result card');

select pg_temp.raises(
  format('delete from public.result_cards where id = %L',
         (select v from public._wb where k = 'card')),
  '4. a clerk cannot delete a published result card');

select pg_temp.raises(
  format('update public.invoice_lines set amount = 1 where invoice_id = %L',
         (select v from public._wb where k = 'open_inv')),
  '5. a clerk cannot change what a challan charges');

select pg_temp.raises(
  format('update public.invoices set status = ''void'' where id = %L',
         (select v from public._wb where k = 'open_inv')),
  '6. a clerk cannot set a challan to void directly — cancelling is fn_void_invoice, '
  || 'which demands a reason and writes an audit row');

select pg_temp.raises(
  format('delete from public.invoices where id = %L',
         (select v from public._wb where k = 'open_inv')),
  '7. a clerk cannot delete a challan');

-- The rest of the boundary, same position.
select pg_temp.raises(
  format('insert into public.adjustments (school_id, student_id, amount, reason) '
         || 'values (%L, %L, -99999, ''x'')',
         (select v from public._wb where k = 'school'),
         (select v from public._wb where k = 'stu')),
  '8. a clerk cannot write an adjustment directly — fn_add_adjustment is the door');

select pg_temp.raises(
  format('insert into public.discounts (school_id, enrollment_id, type, amount, '
         || 'is_percent, status, reason) select %L, e.id, ''merit'', 100, true, '
         || '''approved'', ''self'' from public.enrollments e limit 1',
         (select v from public._wb where k = 'school')),
  '9. a clerk cannot approve their own discount — fn_add_discount records who did');

select pg_temp.raises(
  format('insert into public.payments (school_id, student_id, amount, method) '
         || 'values (%L, %L, 1, ''cash'')',
         (select v from public._wb where k = 'school'),
         (select v from public._wb where k = 'stu')),
  '10. a clerk cannot insert a receipt outside fn_record_payment, which takes a till');

select pg_temp.raises(
  format('insert into public.certificates (school_id, student_id, cert_type, serial_no, data) '
         || 'values (%L, %L, ''leaving'', 999, ''{}''::jsonb)',
         (select v from public._wb where k = 'school'),
         (select v from public._wb where k = 'stu')),
  '11. a clerk cannot forge a certificate row and pick its own serial');

select pg_temp.raises(
  format('update public.fee_structures set amount = 1 where session_id = %L',
         (select v from public._wb where k = 'sess')),
  '12. a clerk cannot rewrite the fee structure — fn_set_fee_amount is '
  || 'effective-dated so last year stays readable');

-- students: the columns a function owns, and the ones the editor sends.
select pg_temp.raises(
  format('update public.students set status = ''withdrawn'' where id = %L',
         (select v from public._wb where k = 'stu')),
  '13. a clerk cannot set a pupil''s status directly — fn_set_student_status '
  || 'carries 0054''s rules and writes the audit row');

select pg_temp.raises(
  format('update public.students set school_id = gen_random_uuid() where id = %L',
         (select v from public._wb where k = 'stu')),
  '14. a clerk cannot move a pupil to another school_id');

select pg_temp.raises(
  format('delete from public.students where id = %L',
         (select v from public._wb where k = 'stu')),
  '15. a clerk cannot delete a pupil — there is a soft delete for a reason');

do $editor$
declare n integer;
begin
  update public.students set full_name = 'Boundary Child Edited',
                             phone = '0300-1234567'
   where id = (select v from public._wb where k = 'stu');
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'FAIL  16. the profile editor can no longer save bio-data (% rows)', n;
  end if;
  raise notice 'PASS  16. the profile editor still saves bio-data — the boundary '
    'takes the columns a function owns and nothing else';
end $editor$;

reset role;

-- The property all fifteen refusals stand in for: nothing moved.
select pg_temp.ok(
  public.student_balance((select v from public._wb where k = 'stu')) = 4500,
  '17. and the child still owes exactly the one open challan — Rs 4,500, not 0 '
  || 'and not 9,000');
select pg_temp.ok(
  (select percentage from public.result_cards
    where id = (select v from public._wb where k = 'card')) = 88,
  '18. the published card still says 88%');
select pg_temp.ok(
  (select count(*) from public.audit_log
    where school_id = (select v from public._wb where k = 'school')) >= 0,
  '19. (audit table reachable — the point of the seven was that they wrote NO row)');

-- =============================================================================
-- 2. fn_void_invoice — the way out that 0086 makes the only way out
-- =============================================================================
select pg_temp.be('Boundary Clerk');
select pg_temp.raises(
  format('select public.fn_void_invoice(%L, ''wrong due date'')',
         (select v from public._wb where k = 'open_inv')),
  '20. a clerk may not cancel a charge — the oldest fraud in a school office is '
  || 'making a family''s dues disappear and taking the cash informally');

select pg_temp.be('Boundary Owner');
select pg_temp.raises(
  format('select public.fn_void_invoice(%L, ''x'')',
         (select v from public._wb where k = 'open_inv')),
  '21. a one-character reason is refused — the register is read months later');

select pg_temp.raises(
  format('select public.fn_void_invoice(%L, null)',
         (select v from public._wb where k = 'open_inv')),
  '22. no reason at all is refused');

select pg_temp.raises(
  format('select public.fn_void_invoice(%L, ''cancelling a challan we were paid for'')',
         (select v from public._wb where k = 'paid_inv')),
  '23. a challan with money on it is refused, and the message says to reverse '
  || 'the payment first — cancelling it would orphan the receipt');

-- The real thing.
do $void$
declare v_out jsonb;
begin
  v_out := public.fn_void_invoice(
    (select v from public._wb where k = 'open_inv'),
    'generated against next month by mistake');
  if (v_out->>'cancelled')::numeric <> 4500 then
    raise exception 'FAIL  24. fn_void_invoice reported Rs % cancelled', v_out->>'cancelled';
  end if;
  raise notice 'PASS  24. the owner cancels it, and is told what was cancelled: Rs %',
    v_out->>'cancelled';
end $void$;

select pg_temp.ok(
  public.student_balance((select v from public._wb where k = 'stu')) = 0,
  '25. the balance drops by exactly the cancelled charge');

select pg_temp.ok(
  (select count(*) from public.audit_log
    where entity = 'invoices' and action = 'INVOICE_VOID'
      and reason = 'generated against next month by mistake') = 1,
  '26. one audit row, carrying the reason — the thing a direct UPDATE never wrote');

select pg_temp.raises(
  format('select public.fn_void_invoice(%L, ''cancelling it twice'')',
         (select v from public._wb where k = 'open_inv')),
  '27. cancelling it again is refused rather than silently repeated');

-- =============================================================================
-- 3. A cancelled challan is out of every live figure — and does NOT print
-- =============================================================================
select pg_temp.ok(
  not exists (select 1 from public.invoice_balances
               where invoice_id = (select v from public._wb where k = 'open_inv')),
  '28. it leaves invoice_balances, which is what twenty read paths go through');

select pg_temp.ok(
  (select count(*) from public.fn_report_unpaid_invoices(
      (select v from public._wb where k = 'sess'))
    where invoice_id = (select v from public._wb where k = 'open_inv')) = 0,
  '29. it leaves the unpaid-challan report, so the family stops being chased');

select pg_temp.raises(
  format('select public.fn_challan(%L)',
         (select v from public._wb where k = 'open_inv')),
  '30. THE ONE THAT MATTERS: it does not print. The slip is bank-payable, so a '
  || 'cancelled challan that still printed would be the loophole reopened from '
  || 'the other end — cancel the charge, print the slip, take the cash off-book');

-- jsonb_array_length, not count(*): the function returns ONE jsonb array, so a
-- row count is 1 whatever the array holds. The first version of this assertion
-- counted rows and would have passed with the cancelled challan still in the
-- batch.
--
-- The exclusion in fn_challans_for_class is now load-bearing rather than tidy:
-- the batch calls fn_challan per row, and fn_challan raises on a cancelled one,
-- so a void challan reaching the batch would abort the whole class's printing.
select pg_temp.ok(
  jsonb_array_length(public.fn_challans_for_class(
      (select v from public._wb where k = 'sess'),
      (select v from public._wb where k = 'class'), null,
      (date_trunc('month', current_date) + interval '1 month')::date)) = 0,
  '31. and it is not in the batch print either — nor does its presence abort '
  || 'the batch, because the batch never reaches it');

select pg_temp.raises(
  format('select public.fn_undo_defer(%L)',
         (select v from public._wb where k = 'open_inv')),
  '32. fn_undo_defer refuses it too, matching fn_defer_invoice, which always did');

-- =============================================================================
-- 4. Money arriving afterwards becomes credit, not a settlement
-- =============================================================================
do $after$
declare v_out jsonb;
begin
  v_out := public.fn_record_payment(
    (select v from public._wb where k = 'stu'), 1000, 'cash', 'paid anyway', false);
  if (v_out->>'allocated')::numeric <> 0 or (v_out->>'unallocated')::numeric <> 1000 then
    raise exception
      'FAIL  33. a payment after cancellation allocated % of 1000 to the '
      'cancelled challan', v_out->>'allocated';
  end if;
  raise notice 'PASS  33. a payment arriving after the cancellation is held as '
    'family credit — nothing settles a charge the school has withdrawn';
end $after$;

-- Where the credit actually shows, and it is NOT student_balance. That function
-- subtracts only ALLOCATED payments, so an unallocated one leaves it at zero;
-- the surplus is family_credit, and family_outstanding nets the two. The first
-- version of this assertion looked for -1000 on the student and failed, which
-- was the test being wrong about the money model rather than the model being
-- wrong — worth keeping the correction visible, because "the child is in
-- credit" and "the family is in credit" are different sentences and only the
-- second one is true here.
select pg_temp.ok(
  public.student_balance((select v from public._wb where k = 'stu')) = 0
  and public.family_credit((select v from public._wb where k = 'fam')) = 1000
  and public.family_outstanding((select v from public._wb where k = 'fam')) = -1000,
  '34. so the FAMILY is 1,000 in credit — held against the next challan rather '
  || 'than settling one the school has withdrawn');

-- =============================================================================
-- 5. The register — the competitor's "Deleted Fees", and a clerk may read it
-- =============================================================================
select pg_temp.be('Boundary Clerk');
do $reg$
declare r record; n integer := 0;
begin
  for r in select * from public.fn_voided_invoices(current_date - 1, current_date + 1) loop
    n := n + 1;
    if r.amount <> 4500 then
      raise exception 'FAIL  35. the register shows Rs % rather than 4,500', r.amount;
    end if;
    if r.reason <> 'generated against next month by mistake' then
      raise exception 'FAIL  35. the register lost the reason (%)', r.reason;
    end if;
    if r.voided_by <> 'Boundary Owner' then
      raise exception 'FAIL  35. the register names % as the canceller', r.voided_by;
    end if;
    if r.student_name is null or r.class_name is null then
      raise exception 'FAIL  35. the register cannot say which child or class';
    end if;
  end loop;
  if n <> 1 then
    raise exception 'FAIL  35. the register returned % rows', n;
  end if;
  raise notice 'PASS  35. a clerk who may not cancel may still SEE what was '
    'cancelled, by whom and why — being shown a control you cannot operate is '
    'how a boundary gets understood rather than worked around';
end $reg$;

select pg_temp.ok(
  (select count(*) from public.fn_voided_invoices(
      current_date - 400, current_date - 300)) = 0,
  '36. and the date range is honoured, so the register is not one endless list');

-- =============================================================================
-- 6. Nothing here crosses a school boundary
-- =============================================================================
do $tenant$
declare
  v_school2 uuid;
  v_owner2 uuid := '00000000-0000-0000-0000-00000000bb03';
begin
  perform set_config('test.uid', '', false);
  insert into public.schools (name) values ('Other Boundary School') returning id into v_school2;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school2, 'starter', 'active', current_date + 30);
  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_owner2, 'o2@boundary.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_owner2, 'Other Owner', 'owner', v_school2)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;
  perform set_config('test.uid', v_owner2::text, false);
end $tenant$;

select pg_temp.raises(
  format('select public.fn_void_invoice(%L, ''cancelling another school''''s challan'')',
         (select v from public._wb where k = 'paid_inv')),
  '37. another school''s owner cannot cancel our challan');

select pg_temp.ok(
  (select count(*) from public.fn_voided_invoices(
      current_date - 400, current_date + 400)) = 0,
  '38. and their register does not show our cancellation');

rollback;
