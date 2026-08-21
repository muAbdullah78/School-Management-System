-- =============================================================================
-- Bulk collection: taking a class's fees in one pass.
--
-- The rules this file defends:
--
--  1. The worklist returns the WHOLE class, paid and unpaid. A clerk working
--     down a list with a cash box needs to see "Ahmed: paid" to know they have
--     not skipped him.
--  2. A batch is ONE transaction. Ten good rows and a bad eleventh must leave
--     nothing behind — a clerk who cannot tell which of forty rows went through
--     has no way to recover.
--  3. Bulk payments allocate identically to counter payments, because they go
--     through the same function. A second allocator is the worst bug this
--     system could have.
--  4. Receipt numbers stay gapless across a batch.
--  5. Reminders go out once per FAMILY, not once per child, and escalate.
--  6. Nothing crosses a school boundary, and a parent can call none of it.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/bulk_fees.sql
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

create or replace function pg_temp.sid(p_name text) returns uuid language sql as $$
  select id from public.students where full_name = p_name limit 1
$$;

create or replace function pg_temp.ctx(p_which text)
returns uuid language sql as $$
  select case p_which
    when 'session' then (select id from public.academic_sessions
                          where school_id = public.current_school_id() and is_current limit 1)
    when 'class'   then (select id from public.classes
                          where school_id = public.current_school_id() limit 1)
  end
$$;

-- --- Fixture -----------------------------------------------------------------
-- One class of four, two of them siblings, at Rs 1,000/month. Plus a second
-- school that must never appear.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa uuid := '00000000-0000-0000-0000-000000bf0001';
  v_cl uuid := '00000000-0000-0000-0000-000000bf0002';
  v_pa uuid := '00000000-0000-0000-0000-000000bf0003';
  v_ob uuid := '00000000-0000-0000-0000-000000bf0004';
  v_sess uuid; v_class uuid; v_head uuid;
begin
  insert into public.schools (name) values ('Bulk School') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);
  insert into public.schools (name) values ('Bulk Other') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'growth', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_oa, 'bfa@bulk.test'), (v_cl, 'bfc@bulk.test'),
    (v_pa, 'bfp@bulk.test'), (v_ob, 'bfo@bulk.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_oa, 'Bulk Owner', 'owner',       v_a),
    (v_cl, 'Bulk Clerk', 'admin_clerk', v_a),
    (v_pa, 'Bulk Parent','parent',      v_a),
    (v_ob, 'Other Owner','owner',       v_b)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role      = excluded.role,
                                   full_name = excluded.full_name,
                                   active    = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_oa::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_a) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Class 8', 8, v_a) returning id into v_class;
  insert into public.fee_heads (name, type, is_recurring, sort_order, school_id)
    values ('Tuition', 'monthly', true, 10, v_a) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_class, v_head, 1000, v_a);

  -- Two siblings on one CNIC, two unrelated children.
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'BF Sibling One', 'father_name', 'BF Father', 'father_cnic', '35201-2323232-3',
    'phone', '0300-1111111', 'session_id', v_sess, 'class_id', v_class,
    'roll_no', '1', 'links', '[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'BF Sibling Two', 'father_name', 'BF Father', 'father_cnic', '35201-2323232-3',
    'phone', '0300-1111111', 'session_id', v_sess, 'class_id', v_class,
    'roll_no', '2', 'links', '[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'BF Solo', 'father_name', 'Solo Father', 'father_cnic', '35201-4545454-4',
    'phone', '0300-2222222', 'session_id', v_sess, 'class_id', v_class,
    'roll_no', '3', 'links', '[]'::jsonb));
  -- No phone at all, to prove one unreachable family does not abandon the rest.
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'BF NoPhone', 'father_name', 'Quiet Father', 'father_cnic', '35201-6767676-6',
    'session_id', v_sess, 'class_id', v_class,
    'roll_no', '4', 'links', '[]'::jsonb));

  perform public.fn_generate_class_invoices(v_sess, v_class,
    date_trunc('month', current_date)::date, current_date + 10);

  perform set_config('test.uid', v_ob::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_b) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Class 8', 8, v_b) returning id into v_class;
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'BF Foreign', 'father_name', 'Foreign Father',
    'session_id', v_sess, 'class_id', v_class, 'links', '[]'::jsonb));
end $seed$;

-- =============================================================================
-- 1-5: the worklist
-- =============================================================================
do $t$
declare v_n int; r record; v_rolls text;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-000000bf0001', false);

  select count(*) into v_n from public.fn_class_dues(
    pg_temp.ctx('session'), pg_temp.ctx('class'), null,
    date_trunc('month', current_date)::date);
  perform pg_temp.ok(v_n = 4, '1. the whole class is listed (' || v_n || ')');

  select string_agg(roll_no, ',') into v_rolls from public.fn_class_dues(
    pg_temp.ctx('session'), pg_temp.ctx('class'), null,
    date_trunc('month', current_date)::date);
  perform pg_temp.ok(v_rolls = '1,2,3,4',
    '2. in roll order, so it can be worked down a register (' || v_rolls || ')');

  select * into r from public.fn_class_dues(
    pg_temp.ctx('session'), pg_temp.ctx('class'), null,
    date_trunc('month', current_date)::date) where full_name = 'BF Sibling One';
  perform pg_temp.ok(r.month_due = 1000,
    '3. this month''s due is the class fee (' || r.month_due || ')');
  perform pg_temp.ok(r.phone = '0300-1111111',
    '4. a phone number comes back, so a reminder can actually be sent');
  perform pg_temp.ok(r.last_paid_at is null,
    '5. and nothing has been paid yet');

  perform pg_temp.ok(not exists (
    select 1 from public.fn_class_dues(pg_temp.ctx('session'), pg_temp.ctx('class'), null,
      date_trunc('month', current_date)::date) where full_name = 'BF Foreign'),
    '6. the other school''s child is not in the list');
end $t$;

-- =============================================================================
-- 7-9: a bad batch must leave NOTHING behind
--
-- The most important assertion in this file. A clerk who submits forty rows and
-- gets a half-applied batch cannot tell which twenty went through.
-- =============================================================================
do $t$
declare v_before int; v_after int; v_ok boolean := false;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-000000bf0001', false);
  select count(*) into v_before from public.payments
   where school_id = public.current_school_id();

  begin
    perform public.fn_record_bulk_payments(jsonb_build_array(
      jsonb_build_object('student_id', pg_temp.sid('BF Sibling One'), 'amount', 1000),
      jsonb_build_object('student_id', pg_temp.sid('BF Solo'),        'amount', 1000),
      -- the poison row
      jsonb_build_object('student_id', pg_temp.sid('BF NoPhone'),     'amount', 0)
    ), 'cash', 'bad batch', false);
  exception when others then
    v_ok := true;
    raise notice 'PASS  7. a zero amount rejects the batch (%)', sqlerrm;
  end;
  if not v_ok then raise exception 'FAIL  7. a zero-amount row was accepted'; end if;

  select count(*) into v_after from public.payments
   where school_id = public.current_school_id();
  perform pg_temp.ok(v_after = v_before,
    '8. and the two GOOD rows before it were rolled back too (' || v_before || ' -> ' || v_after || ')');

  -- The error has to name the row, or a clerk cannot find it in forty.
  begin
    perform public.fn_record_bulk_payments(jsonb_build_array(
      jsonb_build_object('student_id', pg_temp.sid('BF Solo'), 'amount', -5)
    ), 'cash', null, false);
    raise exception 'FAIL  9. a negative amount was accepted';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    perform pg_temp.ok(sqlerrm like '%BF Solo%',
      '9. the error names the student, not just "invalid amount" (' || sqlerrm || ')');
  end;
end $t$;

-- =============================================================================
-- 10-14: a good batch
-- =============================================================================
do $t$
declare v_res jsonb; v_n int; r record; v_receipts int;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-000000bf0001', false);

  v_res := public.fn_record_bulk_payments(jsonb_build_array(
    jsonb_build_object('student_id', pg_temp.sid('BF Sibling One'), 'amount', 1000),
    jsonb_build_object('student_id', pg_temp.sid('BF Solo'),        'amount', 600)
  ), 'cash', 'first ten days', false);

  perform pg_temp.ok((v_res->>'count')::int = 2, '10. two payments recorded');
  perform pg_temp.ok((v_res->>'total')::numeric = 1600,
    '11. and the batch total is reported back for the drawer (' || (v_res->>'total') || ')');

  -- Every receipt number must be present and distinct — a batch that reuses one
  -- breaks the gapless series the whole audit story rests on.
  select count(distinct (e->>'receipt_no')) into v_receipts
  from jsonb_array_elements(v_res->'receipts') e;
  perform pg_temp.ok(v_receipts = 2, '12. each payment got its own receipt number');

  -- And allocation happened exactly as it would at the counter.
  perform pg_temp.ok(public.student_balance(pg_temp.sid('BF Sibling One')) = 0,
    '13. a full payment clears the child''s balance');

  select * into r from public.fn_class_dues(
    pg_temp.ctx('session'), pg_temp.ctx('class'), null,
    date_trunc('month', current_date)::date) where full_name = 'BF Solo';
  perform pg_temp.ok(r.month_due = 400 and r.month_paid = 600,
    '14. a part payment shows as part paid, not as cleared (due ' || r.month_due
      || ', paid ' || r.month_paid || ')');
end $t$;

-- =============================================================================
-- 15-18: reminders
-- =============================================================================
do $t$
declare v_res jsonb; v_fam uuid; v_n int; v_keys text;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-000000bf0001', false);

  v_res := public.fn_queue_class_reminders(pg_temp.ctx('session'), pg_temp.ctx('class'), null);

  -- Sibling One is paid up; Sibling Two, Solo and NoPhone still owe. Sibling Two
  -- shares a family with One, so that family still owes and gets ONE message.
  perform pg_temp.ok((v_res->>'queued')::int >= 1,
    '15. reminders were queued (' || (v_res->>'queued') || ' queued, '
      || (v_res->>'skipped') || ' skipped)');

  -- One message per family, never one per child.
  select family_id into v_fam from public.students where full_name = 'BF Sibling Two';
  select count(*) into v_n from public.message_outbox
   where family_id = v_fam
     and template_key in ('fee_reminder', 'fee_reminder_final')
     and created_at >= date_trunc('month', now());
  perform pg_temp.ok(v_n = 1,
    '16. a father with two children owing gets ONE message, not two (' || v_n || ')');

  -- A family that is paid up must not be chased.
  perform pg_temp.ok(
    (select count(*) from public.message_outbox m
      join public.students s on s.family_id = m.family_id
     where s.full_name = 'BF Solo' and m.template_key like 'fee_reminder%') = 1,
    '17. the part-paying family is still reminded of the remainder');

  -- Escalation: press it twice more and the third one is the final warning.
  perform public.fn_queue_class_reminders(pg_temp.ctx('session'), pg_temp.ctx('class'), null);
  perform public.fn_queue_class_reminders(pg_temp.ctx('session'), pg_temp.ctx('class'), null);
  select string_agg(distinct template_key, ',') into v_keys
  from public.message_outbox
  where family_id = v_fam and created_at >= date_trunc('month', now());
  perform pg_temp.ok(v_keys like '%fee_reminder_final%',
    '18. the third reminder escalates to the final warning (' || v_keys || ')');
end $t$;

-- =============================================================================
-- 19-23: the guards
-- =============================================================================
do $t$
declare v_foreign uuid; v_sess uuid; v_class uuid;
begin
  -- A clerk SHOULD be able to run the counter, including in bulk.
  perform set_config('test.uid', '00000000-0000-0000-0000-000000bf0002', false);
  perform pg_temp.ok(
    (public.fn_record_bulk_payments(jsonb_build_array(
       jsonb_build_object('student_id', pg_temp.sid('BF NoPhone'), 'amount', 100)
     ), 'cash', 'clerk batch', false)->>'count')::int = 1,
    '19. a clerk can take a bulk payment');

  -- A parent must not.
  perform set_config('test.uid', '00000000-0000-0000-0000-000000bf0003', false);
  begin
    perform public.fn_record_bulk_payments(jsonb_build_array(
      jsonb_build_object('student_id', pg_temp.sid('BF Solo'), 'amount', 100)
    ), 'cash', null, false);
    raise exception 'FAIL  20. a parent recorded payments';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  20. a parent cannot record payments (%)', sqlerrm;
  end;

  begin
    perform count(*) from public.fn_class_dues(
      pg_temp.ctx('session'), pg_temp.ctx('class'), null, current_date);
    raise exception 'FAIL  21. a parent read a class''s dues';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  21. a parent cannot read class dues (%)', sqlerrm;
  end;

  -- Cross-school: paying another school's student must be refused, and that
  -- refusal comes from fn_record_payment's own assert_own rather than from
  -- anything this migration added — which is exactly why it delegates.
  perform set_config('test.uid', '00000000-0000-0000-0000-000000bf0001', false);
  begin
    perform public.fn_record_bulk_payments(jsonb_build_array(
      jsonb_build_object('student_id', pg_temp.sid('BF Foreign'), 'amount', 100)
    ), 'cash', null, false);
    raise exception 'FAIL  22. paid another school''s student';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  22. a foreign student is refused (%)', sqlerrm;
  end;

  perform pg_temp.ok((select count(*) from information_schema.routine_privileges
                       where routine_schema = 'public'
                         and routine_name in ('fn_class_dues','fn_record_bulk_payments',
                                              'fn_queue_class_reminders')
                         and grantee = 'anon') = 0,
    '23. none of the bulk functions are reachable by anon');
end $t$;

do $$ begin raise notice '--- bulk_fees.sql: all assertions passed'; end $$;

rollback;
