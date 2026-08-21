-- =============================================================================
-- The printed challan: does the paper agree with the ledger?
--
-- This is the file that matters most in the fee area, because a challan is the
-- only artefact a parent can hold up and argue with. A slip that disagrees with
-- the balance is worse than no slip at all.
--
-- The rules it defends:
--
--  1. total_payable equals student_balance() exactly. The paper and the ledger
--     are the same number or the feature is broken.
--  2. this_month_due + previous_dues = total_payable, always. The two halves a
--     parent reads must add up to the figure they are asked to pay.
--  3. previous_dues is computed LIVE. invoices.arrears_brought_forward is a
--     snapshot taken at generation and is deliberately not in the ledger;
--     printing it would demand money a parent has already paid.
--  4. A payment moves the numbers on a REPRINT of the same challan.
--  5. Void challans never print. A cancelled slip in a clerk's hand gets
--     collected against.
--  6. The voucher code is on the paper, and it is the code the counter's
--     scanner resolves.
--  7. Batch print covers a whole class, in roll-number order, and does not
--     leak another school's children.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/challan.sql
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

-- The invoice for a given student in the current month.
create or replace function pg_temp.inv(p_name text) returns uuid language sql as $$
  select i.id from public.invoices i
  join public.students s on s.id = i.student_id
  where s.full_name = p_name and i.period_month = date_trunc('month', current_date)::date
  order by i.created_at desc limit 1
$$;

create or replace function pg_temp.ch(p_name text) returns jsonb language sql as $$
  select public.fn_challan(pg_temp.inv(p_name))
$$;

-- --- Fixture -----------------------------------------------------------------
-- One school, one class, three children of one father at Rs 1,200/month, plus a
-- second school whose challans must never appear in the batch.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa uuid := '00000000-0000-0000-0000-0000000cba01';
  v_ob uuid := '00000000-0000-0000-0000-0000000cba02';
  v_sess uuid; v_class uuid; v_sec uuid; v_head uuid;
  v_names text[] := array['CH Ayesha', 'CH Bilal', 'CH Danish'];
  v_n text; v_i int := 1;
begin
  insert into public.schools (name) values ('Challan School') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'starter', 'active', current_date + 30);
  insert into public.schools (name) values ('Challan Other') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'starter', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_oa, 'cha@challan.test'), (v_ob, 'chb@challan.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_oa, 'Challan Owner', 'owner', v_a),
    (v_ob, 'Other Owner',   'owner', v_b)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role      = excluded.role,
                                   full_name = excluded.full_name,
                                   active    = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_oa::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_a) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Class 5', 5, v_a) returning id into v_class;
  insert into public.sections (class_id, name, school_id)
    values (v_class, 'A', v_a) returning id into v_sec;
  insert into public.fee_heads (name, type, is_recurring, sort_order, school_id)
    values ('Tuition', 'monthly', true, 10, v_a) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_class, v_head, 1200, v_a);

  -- Roll numbers deliberately out of alphabetical order, and crossing ten, so
  -- the batch's numeric sort is actually exercised.
  foreach v_n in array v_names loop
    perform public.fn_admit_student(jsonb_build_object(
      'full_name', v_n, 'father_name', 'CH Father', 'father_cnic', '35201-5656565-5',
      'session_id', v_sess, 'class_id', v_class, 'section_id', v_sec,
      'roll_no', (case v_i when 1 then '12' when 2 then '3' else '7' end),
      'links', '[]'::jsonb));
    v_i := v_i + 1;
  end loop;

  perform public.fn_generate_class_invoices(v_sess, v_class,
    date_trunc('month', current_date)::date, current_date + 10);

  -- The other school, same month.
  perform set_config('test.uid', v_ob::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_b) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Class 5', 5, v_b) returning id into v_class;
  insert into public.fee_heads (name, type, is_recurring, sort_order, school_id)
    values ('Tuition', 'monthly', true, 10, v_b) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_class, v_head, 9999, v_b);
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'CH Foreign', 'father_name', 'Other Father',
    'session_id', v_sess, 'class_id', v_class, 'links', '[]'::jsonb));
  perform public.fn_generate_class_invoices(v_sess, v_class,
    date_trunc('month', current_date)::date, current_date + 10);
end $seed$;

-- =============================================================================
-- 1-6: a fresh challan
-- =============================================================================
do $t$
declare c jsonb; v_bal numeric;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000cba01', false);
  c := pg_temp.ch('CH Ayesha');

  perform pg_temp.ok((c->>'this_month')::numeric = 1200,
    '1. this month is the class fee (' || (c->>'this_month') || ')');
  perform pg_temp.ok((c->>'previous_dues')::numeric = 0,
    '2. a first-ever challan carries no previous dues');
  perform pg_temp.ok((c->>'total_payable')::numeric = 1200,
    '3. total payable is this month alone');

  select public.student_balance((c->>'student_id')::uuid) into v_bal;
  perform pg_temp.ok((c->>'total_payable')::numeric = v_bal,
    '4. the paper equals the ledger — total_payable = student_balance');

  perform pg_temp.ok(
    (c->>'this_month_due')::numeric + (c->>'previous_dues')::numeric
      = (c->>'total_payable')::numeric,
    '5. the two halves a parent reads add up to what they are asked to pay');

  perform pg_temp.ok(nullif(c->>'voucher_code', '') is not null,
    '6. the voucher code is on the paper (' || coalesce(c->>'voucher_code', 'NULL') || ')');
end $t$;

-- =============================================================================
-- 7-8: the code on the paper is the one the counter's scanner resolves
-- =============================================================================
do $t$
declare c jsonb; hit jsonb;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000cba01', false);
  c := pg_temp.ch('CH Bilal');

  hit := public.fn_find_by_voucher(c->>'voucher_code');
  perform pg_temp.ok(hit is not null, '7. scanning the printed code finds the challan');
  perform pg_temp.ok(hit->>'student_id' = c->>'student_id',
    '8. and it resolves to the right child');
end $t$;

-- =============================================================================
-- 9-12: a payment must change a REPRINT of the same challan
-- =============================================================================
do $t$
declare c jsonb; v_fam uuid;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000cba01', false);
  select family_id into v_fam from public.students where full_name = 'CH Ayesha';

  -- Part payment from the father. Allocation is oldest-first across the family,
  -- so this lands somewhere in the three challans.
  perform public.fn_record_family_payment(v_fam, 1200, 'cash', 'one child settled', false);

  perform pg_temp.ok(
    (select count(*) from public.students s
      where s.family_id = v_fam
        and (public.fn_challan(pg_temp.inv(s.full_name))->>'total_payable')::numeric
            = public.student_balance(s.id)) = 3,
    '9. after a payment every child''s challan still equals their ledger balance');

  -- Whichever child was cleared must show it as already_paid, not as a
  -- silently smaller total.
  perform pg_temp.ok(exists (
    select 1 from public.students s
     where s.family_id = v_fam
       and (public.fn_challan(pg_temp.inv(s.full_name))->>'already_paid')::numeric = 1200),
    '10. the settled challan reports the money against it');

  perform pg_temp.ok(exists (
    select 1 from public.students s
     where s.family_id = v_fam
       and (public.fn_challan(pg_temp.inv(s.full_name))->>'this_month_due')::numeric = 0),
    '11. and shows nothing further due this month');

  -- The stale snapshot is still returned, and still zero, which is the point:
  -- printing it instead of the live figure is the bug this avoids.
  c := pg_temp.ch('CH Ayesha');
  perform pg_temp.ok((c->>'arrears_snapshot_at_generation')::numeric = 0,
    '12. the generation-time snapshot is returned separately and is not the printed figure');
end $t$;

-- =============================================================================
-- 13-15: previous dues appear once a second month is billed
--
-- Written against the INVARIANT, not against a named child. A first draft
-- checked CH Danish specifically and failed intermittently, because which
-- sibling a family payment clears is a tie-break the allocator does not
-- promise when every challan is for the same month — the same mistake this
-- suite's sibling file already made once.
-- =============================================================================
do $t$
declare
  v_sess uuid; v_class uuid; v_fam uuid;
  v_still_owing text; c jsonb; v_prev numeric; v_n int;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000cba01', false);
  select id into v_sess from public.academic_sessions
   where school_id = public.current_school_id() and is_current;
  select id into v_class from public.classes where school_id = public.current_school_id() limit 1;
  select family_id into v_fam from public.students where full_name = 'CH Ayesha';

  perform public.fn_generate_class_invoices(v_sess, v_class,
    (date_trunc('month', current_date) + interval '1 month')::date, current_date + 40);

  -- Pick a child who demonstrably still owes for the current month, whichever
  -- one that turned out to be.
  select s.full_name into v_still_owing
  from public.students s
  where s.family_id = v_fam
    and (public.fn_challan(pg_temp.inv(s.full_name))->>'this_month_due')::numeric > 0
  order by s.full_name
  limit 1;

  perform pg_temp.ok(v_still_owing is not null,
    '13. two of the three children are still owing this month');

  select public.fn_challan(i.id) into c
  from public.invoices i
  join public.students s on s.id = i.student_id
  where s.full_name = v_still_owing
    and i.period_month = (date_trunc('month', current_date) + interval '1 month')::date;

  v_prev := (c->>'previous_dues')::numeric;
  perform pg_temp.ok(v_prev > 0,
    '14. next month''s slip carries their unpaid month as previous dues (' || v_prev || ')');

  -- And the identity has to hold for EVERY slip of both months, not just this one.
  select count(*) into v_n
  from public.invoices i
  join public.students s on s.id = i.student_id
  where s.family_id = v_fam
    and i.status <> 'void'
    and (public.fn_challan(i.id)->>'this_month_due')::numeric
      + (public.fn_challan(i.id)->>'previous_dues')::numeric
      = (public.fn_challan(i.id)->>'total_payable')::numeric;
  perform pg_temp.ok(v_n = 6,
    '15. the halves add up on all six slips across both months (' || v_n || ')');
end $t$;

-- =============================================================================
-- 16-19: the batch print
-- =============================================================================
do $t$
declare v_sess uuid; v_class uuid; v_sec uuid; b jsonb; v_rolls text;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000cba01', false);
  select id into v_sess from public.academic_sessions
   where school_id = public.current_school_id() and is_current;
  select id into v_class from public.classes where school_id = public.current_school_id() limit 1;
  select id into v_sec from public.sections where class_id = v_class limit 1;

  b := public.fn_challans_for_class(v_sess, v_class, null,
                                    date_trunc('month', current_date)::date);
  perform pg_temp.ok(jsonb_array_length(b) = 3,
    '16. the whole class comes out in one batch (' || jsonb_array_length(b) || ')');

  -- Roll order, and specifically that "12" sorts after "3" and "7" rather than
  -- lexically before them.
  select string_agg(e->>'roll_no', ',') into v_rolls
  from jsonb_array_elements(b) e;
  perform pg_temp.ok(v_rolls = '3,7,12',
    '17. in roll-number order, numerically not lexically (' || v_rolls || ')');

  perform pg_temp.ok(not exists (
    select 1 from jsonb_array_elements(b) e where e->>'student_name' = 'CH Foreign'),
    '18. and the other school''s child is not in it');

  -- Naming a section must narrow it, not widen it.
  b := public.fn_challans_for_class(v_sess, v_class, v_sec,
                                    date_trunc('month', current_date)::date);
  perform pg_temp.ok(jsonb_array_length(b) = 3,
    '19. asking for the one section returns that section');
end $t$;

-- =============================================================================
-- 20-21: a void challan must never print
-- =============================================================================
do $t$
declare v_sess uuid; v_class uuid; b jsonb; v_inv uuid;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000cba01', false);
  select id into v_sess from public.academic_sessions
   where school_id = public.current_school_id() and is_current;
  select id into v_class from public.classes where school_id = public.current_school_id() limit 1;

  v_inv := pg_temp.inv('CH Bilal');
  update public.invoices set status = 'void' where id = v_inv;

  b := public.fn_challans_for_class(v_sess, v_class, null,
                                    date_trunc('month', current_date)::date);
  perform pg_temp.ok(jsonb_array_length(b) = 2,
    '20. a voided challan is left out of the batch (' || jsonb_array_length(b) || ')');
  perform pg_temp.ok(not exists (
    select 1 from jsonb_array_elements(b) e where e->>'student_name' = 'CH Bilal'),
    '21. specifically that child''s');
end $t$;

-- =============================================================================
-- 22-23: the month list drives the screen's choices
-- =============================================================================
do $t$
declare v_sess uuid; v_class uuid; v_months int;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000cba01', false);
  select id into v_sess from public.academic_sessions
   where school_id = public.current_school_id() and is_current;
  select id into v_class from public.classes where school_id = public.current_school_id() limit 1;

  select count(*) into v_months from public.fn_challan_months(v_sess, v_class);
  perform pg_temp.ok(v_months = 2,
    '22. both billed months are offered (' || v_months || ')');

  perform pg_temp.ok((select unpaid from public.fn_challan_months(v_sess, v_class)
                       order by period_month desc limit 1) > 0,
    '23. with a live unpaid count, so the clerk knows which month still matters');
end $t$;

-- =============================================================================
-- 24-26: the guards
-- =============================================================================
do $t$
declare v_foreign uuid; v_sess uuid; v_class uuid;
begin
  select i.id into v_foreign
  from public.invoices i join public.students s on s.id = i.student_id
  where s.full_name = 'CH Foreign' limit 1;

  perform set_config('test.uid', '00000000-0000-0000-0000-0000000cba01', false);
  begin
    perform public.fn_challan(v_foreign);
    raise exception 'FAIL  24. printed another school''s challan';
  exception
    when others then
      if sqlerrm like 'FAIL%' then raise; end if;
      raise notice 'PASS  24. fn_challan refuses a foreign invoice (%)', sqlerrm;
  end;

  -- And the other school's own class must not be printable from here either.
  select id into v_sess from public.academic_sessions
   where school_id = (select id from public.schools where name = 'Challan Other') limit 1;
  select id into v_class from public.classes
   where school_id = (select id from public.schools where name = 'Challan Other') limit 1;
  begin
    perform public.fn_challans_for_class(v_sess, v_class, null,
                                         date_trunc('month', current_date)::date);
    raise exception 'FAIL  25. batch-printed another school''s class';
  exception
    when others then
      if sqlerrm like 'FAIL%' then raise; end if;
      raise notice 'PASS  25. fn_challans_for_class refuses a foreign class (%)', sqlerrm;
  end;

  perform pg_temp.ok((select count(*) from information_schema.routine_privileges
                       where routine_schema = 'public'
                         and routine_name in ('fn_challan','fn_challans_for_class','fn_challan_months')
                         and grantee = 'anon') = 0,
    '26. none of the challan functions are reachable by anon');
end $t$;

do $$ begin raise notice '--- challan.sql: all assertions passed'; end $$;

rollback;
