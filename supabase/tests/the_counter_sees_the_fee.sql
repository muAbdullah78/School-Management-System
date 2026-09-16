-- =============================================================================
-- The counter sees the fee (0141).
--
-- ASSERTION 5 IS THE ONE THAT MATTERS MOST, and it is not about the screen at
-- all. 0138's fn_student_fee_for_month has a fallback branch for a child whose
-- active enrolment belongs to no session covering the month asked about, and the
-- branch ordered by
--
--     abs(extract(epoch from (s.starts_on - v_month)))
--
-- Subtracting one date from another in Postgres gives an INTEGER, and
-- extract(epoch from <integer>) does not exist, so that branch raised the
-- instant it was reached. Nothing ever reached it: PL/pgSQL does not parse a
-- statement until it runs one, and every test had a child whose session covered
-- the month. It shipped in bundle 41. This asserts it works.
--
-- ASSERTIONS 1 TO 4 are the complaint the vendor made: the counter showed a
-- name, a GR number and one balance, while the same child's page in Students
-- showed the class, the fee before the concession, the concession, its rate and
-- its reason. The two screens agree now because the counter CALLS the child
-- page's functions rather than working the same numbers out again.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/the_counter_sees_the_fee.sql
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

-- ONE SCHOOL. Two sessions inside it, because the case assertion 5 exists for is
-- a child left in a year the school has moved on from, which is what the gap
-- before a rollover looks like in every school that has one.
do $seed$
declare
  sch uuid := gen_random_uuid(); own uuid := gen_random_uuid();
  ses uuid; old_ses uuid; c1 uuid; c4 uuid; fh uuid; fam uuid;
  s1 uuid; s2 uuid; s3 uuid; d1 uuid;
  today date := (now() at time zone 'Asia/Karachi')::date;
  start date := date_trunc('month', today - interval '3 months')::date;
begin
  insert into public.schools(id, name, city) values (sch, 'Counter Fee School', 'Sialkot');
  insert into public.subscriptions(school_id, plan_code, status, trial_ends_on)
    values (sch, 'growth', 'active', today + 90);
  insert into auth.users(id, email) values (own, 'head@counterfee.test') on conflict (id) do nothing;
  alter table public.profiles disable trigger user;
  insert into public.profiles(id, school_id, full_name, role) values (own, sch, 'Head', 'owner');
  alter table public.profiles enable trigger user;
  perform set_config('test.uid', own::text, false);

  insert into public.academic_sessions(school_id, name, starts_on, ends_on, is_current)
    values (sch, 'This year', start, (start + interval '11 months' + interval '27 days')::date, true)
    returning id into ses;
  -- Finished two years ago and nowhere near the month anything below asks about.
  insert into public.academic_sessions(school_id, name, starts_on, ends_on, is_current)
    values (sch, 'A year they have moved on from',
            (start - interval '24 months')::date,
            (start - interval '13 months')::date, false)
    returning id into old_ses;
  update public.school_settings set current_session_id = ses, billing_day = 1, due_day = 10
   where school_id = sch;

  insert into public.classes(school_id, name, level_order) values (sch, 'Class 1', 1) returning id into c1;
  insert into public.classes(school_id, name, level_order) values (sch, 'Class 4', 4) returning id into c4;
  insert into public.fee_heads(school_id, name, type, is_refundable, is_recurring, sort_order, active)
    values (sch, 'Monthly Fee', 'monthly', false, true, 1, true) returning id into fh;
  insert into public.fee_structures(school_id, session_id, class_id, fee_head_id, amount, effective_from)
    values (sch, ses, c1, fh, 4500, start), (sch, ses, c4, fh, 5500, start);

  insert into public.families(school_id, head_name, head_cnic, phone)
    values (sch, 'Shahid Anwar', '1101000000099', '03331234567') returning id into fam;

  insert into public.students(school_id, family_id, gr_no, full_name, father_name, admission_date, status)
    values (sch, fam, 'C-1', 'Abdullah', 'Shahid Anwar', start, 'active') returning id into s1;
  insert into public.students(school_id, family_id, gr_no, full_name, father_name, admission_date, status)
    values (sch, fam, 'C-2', 'Ayesha', 'Shahid Anwar', start, 'active') returning id into s2;
  -- The child nobody moved forward. Active enrolment, in a session that ended.
  insert into public.students(school_id, family_id, gr_no, full_name, father_name, admission_date, status)
    values (sch, fam, 'C-3', 'Bilal', 'Shahid Anwar', (start - interval '24 months')::date, 'active')
    returning id into s3;

  insert into public.enrollments(school_id, student_id, session_id, class_id, roll_no)
    values (sch, s1, ses, c1, '01'), (sch, s2, ses, c4, '07'),
           (sch, s3, old_ses, c4, '11');

  d1 := public.fn_add_discount(s1, 'hardship', 40, true, 'father out of work',
                               date_trunc('month', today)::date, null);
  perform public.fn_set_discount_status(d1, 'approved');
  perform public.fn_ensure_billing_current(ses);
end $seed$;

-- =============================================================================
-- 1-4. What the counter now knows, and could not say before
-- =============================================================================
do $sheet$
declare
  sch uuid; own uuid; fam uuid; s1 uuid; s2 uuid; j jsonb; kid jsonb; sib jsonb;
  fee jsonb;
  today date := (now() at time zone 'Asia/Karachi')::date;
  thismon date := date_trunc('month', today)::date;
begin
  select id into sch from public.schools where name = 'Counter Fee School';
  select id into own from public.profiles where school_id = sch and role = 'owner';
  select id into fam from public.families where school_id = sch;
  select id into s1 from public.students where school_id = sch and gr_no = 'C-1';
  select id into s2 from public.students where school_id = sch and gr_no = 'C-2';
  perform set_config('test.uid', own::text, false);

  j := public.fn_family_sheet(fam);
  select x into kid from jsonb_array_elements(j->'children') x where x->>'gr_no' = 'C-1';
  select x into sib from jsonb_array_elements(j->'children') x where x->>'gr_no' = 'C-2';

  perform pg_temp.ok(kid->>'class_name' = 'Class 1' and kid->>'roll_no' = '01',
    '1. the counter names the class and roll the fee belongs to, got '
    || coalesce(kid->>'class_name', 'nothing'));

  perform pg_temp.ok(
    (kid->>'gross')::numeric = 4500 and (kid->>'discount')::numeric = 1800
    and (kid->>'net')::numeric = 2700,
    '2. and the fee BEFORE the concession, what came off, and what is left: got '
    || (kid->>'gross') || ' less ' || (kid->>'discount') || ' is ' || (kid->>'net'));

  perform pg_temp.ok(
    jsonb_array_length(kid->'discount_lines') = 1
    and kid->'discount_lines'->0->>'type' = 'hardship'
    and (kid->'discount_lines'->0->>'rate')::numeric = 40
    and (kid->'discount_lines'->0->>'amount')::numeric = 1800
    and kid->'discount_lines'->0->>'reason' = 'father out of work',
    '3. THE COMPLAINT THIS FILE ANSWERS: the concession is named at the till, '
    || 'with its kind, its rate, what it is worth in rupees and why it was given');

  -- The same question, asked the way the child's page asks it. The two must be
  -- the same numbers because they are now the same function.
  fee := public.fn_student_fee_for_month(s1, thismon);
  perform pg_temp.ok(
    (fee->>'gross')::numeric = (kid->>'gross')::numeric
    and (fee->>'net')::numeric = (kid->>'net')::numeric
    and fee->>'class_name' = kid->>'class_name',
    '4. and it agrees with the child''s own page to the rupee, because the sheet '
    || 'calls that page''s function rather than working the figures out again');

  perform pg_temp.ok(
    (sib->>'gross')::numeric = 5500 and (sib->>'net')::numeric = 5500
    and jsonb_array_length(sib->'discount_lines') = 0,
    '4b. a sibling with no concession shows the plain fee and no discount line, '
    || 'which is how a parent is told the brothers are on different rates');
end $sheet$;

-- =============================================================================
-- 5. The branch that had never run
-- =============================================================================
do $fallback$
declare
  sch uuid; own uuid; fam uuid; s3 uuid; j jsonb; kid jsonb; fee jsonb;
  today date := (now() at time zone 'Asia/Karachi')::date;
begin
  select id into sch from public.schools where name = 'Counter Fee School';
  select id into own from public.profiles where school_id = sch and role = 'owner';
  select id into fam from public.families where school_id = sch;
  select id into s3 from public.students where school_id = sch and gr_no = 'C-3';
  perform set_config('test.uid', own::text, false);

  fee := public.fn_student_fee_for_month(s3, date_trunc('month', today)::date);
  perform pg_temp.ok(fee->>'class_name' = 'Class 4',
    '5. THE ONE THIS FILE EXISTS FOR: a child whose only active enrolment is in a '
    || 'session that ended does not raise. Until 0141 this branch ordered by '
    || 'extract(epoch from (date - date)), which is not a function, and it '
    || 'shipped in bundle 41 having never once been executed');

  -- And the whole sheet survives having such a child in the family, which is
  -- how a school would actually meet it: at the counter, mid-payment.
  j := public.fn_family_sheet(fam);
  select x into kid from jsonb_array_elements(j->'children') x where x->>'gr_no' = 'C-3';
  perform pg_temp.ok(kid is not null and kid->>'class_name' = 'Class 4',
    '6. and the family sheet renders with that child on it rather than failing '
    || 'the whole payment screen for the other two');
end $fallback$;

-- =============================================================================
-- 7-11. This month, kept apart from the months behind it
-- =============================================================================
do $months$
declare
  sch uuid; own uuid; fam uuid; s1 uuid; j jsonb; kid jsonb; sib jsonb; r jsonb;
  today date := (now() at time zone 'Asia/Karachi')::date;
  thismon date := date_trunc('month', today)::date;
begin
  select id into sch from public.schools where name = 'Counter Fee School';
  select id into own from public.profiles where school_id = sch and role = 'owner';
  select id into fam from public.families where school_id = sch;
  select id into s1 from public.students where school_id = sch and gr_no = 'C-1';
  perform set_config('test.uid', own::text, false);

  j := public.fn_family_sheet(fam);
  select x into kid from jsonb_array_elements(j->'children') x where x->>'gr_no' = 'C-1';

  perform pg_temp.ok(kid->>'month_state' = 'unpaid' and (kid->>'month_due')::numeric = 2700,
    '7. this month stands on its own at Rs 2,700, not folded into the arrears. '
    || 'One combined figure is what makes a clerk quote Rs 16,200 to a parent who '
    || 'came to pay September');

  perform pg_temp.ok((kid->>'arrears_months')::int = 3
                     and (kid->>'arrears_amount')::numeric = 13500,
    '8. and the months behind it are counted separately: got '
    || (kid->>'arrears_months') || ' months, ' || (kid->>'arrears_amount'));

  perform pg_temp.ok((j->>'month')::date = thismon,
    '8b. the sheet says which month every figure on it is for, in Karachi time, '
    || 'so the browser never has to guess it from its own clock');

  -- Take money and watch the tags move. Rs 10,000 is exactly the two oldest
  -- challans in this family, Rs 4,500 and Rs 5,500 for the same month, so the
  -- result does not depend on which sibling the allocator reaches first.
  r := public.fn_record_family_payment(fam, 10000, 'cash', null, false);
  j := public.fn_family_sheet(fam);
  select x into kid from jsonb_array_elements(j->'children') x where x->>'gr_no' = 'C-1';
  select x into sib from jsonb_array_elements(j->'children') x where x->>'gr_no' = 'C-2';
  perform pg_temp.ok((kid->>'arrears_months')::int = 2 and (sib->>'arrears_months')::int = 2,
    '9. a family payment goes oldest month first across every child, so Rs 10,000 '
    || 'clears the oldest month for both and each arrears count drops to 2, got '
    || (kid->>'arrears_months') || ' and ' || (sib->>'arrears_months'));

  perform pg_temp.ok(kid->>'month_state' = 'unpaid' and (kid->>'month_due')::numeric = 2700,
    '10. and this month is untouched by it, which is the point of keeping the two '
    || 'apart: money paid against the summer does not make September look settled');

  -- The rest of it. Rs 28,200 is what is left of the family's Rs 38,200.
  r := public.fn_record_family_payment(fam, 28200, 'cash', null, false);
  j := public.fn_family_sheet(fam);
  select x into kid from jsonb_array_elements(j->'children') x where x->>'gr_no' = 'C-1';
  perform pg_temp.ok(kid->>'month_state' = 'paid' and (kid->>'month_due')::numeric = 0
                     and (kid->>'arrears_months')::int = 0,
    '11. paying the family off turns the tag to Paid and empties the arrears, '
    || 'got ' || (kid->>'month_state') || ' with ' || (kid->>'arrears_months') || ' behind');
end $months$;

-- =============================================================================
-- 12. A readonly trustee reads it.
-- =============================================================================
do $gate$
declare
  sch uuid; fam uuid; obs uuid := gen_random_uuid(); v_ok boolean;
begin
  select id into sch from public.schools where name = 'Counter Fee School';
  select id into fam from public.families where school_id = sch;

  insert into auth.users(id, email) values (obs, 'trustee@counterfee.test') on conflict (id) do nothing;
  alter table public.profiles disable trigger user;
  insert into public.profiles(id, school_id, full_name, role) values (obs, sch, 'Trustee', 'readonly');
  alter table public.profiles enable trigger user;
  perform set_config('test.uid', obs::text, false);

  v_ok := false;
  begin perform public.fn_family_sheet(fam); v_ok := true;
  exception when others then null; end;
  perform pg_temp.ok(v_ok,
    '12. a readonly trustee still reads the sheet. 0141 narrowed the gate to the '
    || 'roles that exist and this is the one that is easy to lose doing that');
end $gate$;

-- =============================================================================
-- 13-14. The report that counted every concession twice
-- =============================================================================
do $report$
declare
  sch uuid; own uuid; s1 uuid; c1 uuid; old_ses uuid; n int; r record;
  today date := (now() at time zone 'Asia/Karachi')::date;
begin
  select id into sch from public.schools where name = 'Counter Fee School';
  select id into own from public.profiles where school_id = sch and role = 'owner';
  select id into s1  from public.students where school_id = sch and gr_no = 'C-1';
  select id into c1  from public.classes where school_id = sch and name = 'Class 1';
  select id into old_ses from public.academic_sessions
   where school_id = sch and name = 'A year they have moved on from';
  perform set_config('test.uid', own::text, false);

  select count(*) into n from public.fn_report_discounts(null, null);
  perform pg_temp.ok(n = 1, '13a. one concession, one row, before the child has a second year');

  -- The child has been at the school before. That is all it takes.
  insert into public.enrollments(school_id, student_id, session_id, class_id, roll_no)
    values (sch, s1, old_ses, c1, '01');

  select count(*) into n from public.fn_report_discounts(null, null);
  perform pg_temp.ok(n = 1,
    '13. THE ONE THAT WAS COSTING A NUMBER: the discount report joined every '
    || 'ACTIVE enrolment with nothing pinning it to a session, so one rollover '
    || 'listed every concession twice and "money the school chose not to '
    || 'collect" was wrong by a multiple. Got ' || n || ' rows for one discount');

  -- AND IT STILL HAS THE SHAPE 0044 AND 0138 DEFINED. The first draft of the
  -- fix added starts_on, ends_on and live, which needs a drop because create or
  -- replace refuses a new return type, and preflight caught what that costs: two
  -- frozen bundles could no longer be re-applied, and re-applying a bundle is
  -- what verify.sql tells a school to do. The months live on
  -- fn_discounts_register instead.
  select * into r from public.fn_report_discounts(null, null) limit 1;
  perform pg_temp.ok(r.class_name = 'Class 1' and r.reason_type = 'hardship'
                     and r.amount = 40,
    '14. and the row still carries what it always did, on the return type two '
    || 'frozen bundles define with create or replace');

  select count(*) into n from public.fn_discounts_register(true);
  perform pg_temp.ok(n = 1,
    '15. the months and the in-force state are on fn_discounts_register, which '
    || 'is new and can have any shape it likes, and its live-only filter answers '
    || 'the question a head actually asks: what am I giving away this month');
end $report$;

rollback;
\echo 'THE COUNTER SEES THE FEE: ALL TESTS PASSED'
