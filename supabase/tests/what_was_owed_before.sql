-- =============================================================================
-- What was owed before (0153).
--
-- A school moving onto the software brings children who already owe: months of
-- fee, an admission fee, stationery, a picnic. This file walks every way that
-- money comes in and every place it must then show up.
--
-- ASSERTION 1 IS THE ONE THIS FILE EXISTS FOR. "This month's fee is already
-- collected" with dues on the same row used to pay the oldest due and leave
-- this month on the unpaid list. The parent who had paid was chased on day one
-- and the debt the school had just typed in was marked settled.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/what_was_owed_before.sql
-- =============================================================================
\set ON_ERROR_STOP on
begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if coalesce(p_cond, false) then raise notice 'PASS  %', p_label;
  else raise exception 'FAIL  %', p_label; end if;
end;
$$;

create or replace function pg_temp.raises(p_sql text, p_label text, p_like text default null)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if p_like is not null and sqlerrm not like p_like then
      raise exception 'FAIL  % (refused, but with: %)', p_label, sqlerrm;
    end if;
    raise notice 'PASS  % (refused: %)', p_label, left(sqlerrm, 90);
    return;
  end;
  raise exception 'FAIL  % (it was ALLOWED)', p_label;
end;
$$;

create or replace function pg_temp.be(p_name text) returns void language sql as $$
  select set_config('test.uid',
    (select id::text from public.profiles where full_name = p_name), false);
$$;

-- --- Fixture -----------------------------------------------------------------
-- Owed Before School: last year and this year, Class 3 at Rs 3,000 a month and
-- Class 7 with no fee set. Other Dues School, with one child, for isolation.
do $seed$
declare
  v_school uuid; v_other uuid;
  v_own uuid := '00000000-0000-0000-0000-00000000d001';
  v_pr  uuid := '00000000-0000-0000-0000-00000000d002';
  v_ro  uuid := '00000000-0000-0000-0000-00000000d003';
  v_ct  uuid := '00000000-0000-0000-0000-00000000d004';
  v_oth uuid := '00000000-0000-0000-0000-00000000d005';
  v_today date := (now() at time zone 'Asia/Karachi')::date;
  v_start date := date_trunc('month', v_today - interval '3 months')::date;
  v_sess uuid; v_last uuid; v_c3 uuid; v_c7 uuid; v_3a uuid; v_fh uuid;
  v_kid uuid; v_osess uuid; v_oc uuid;
begin
  insert into public.schools (name) values ('Owed Before School') returning id into v_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'growth', 'active', v_today + 30);
  insert into public.schools (name) values ('Other Dues School') returning id into v_other;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_other, 'growth', 'active', v_today + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_own, 'own@owed.test'), (v_pr, 'pr@owed.test'), (v_ro, 'ro@owed.test'),
    (v_ct, 'ct@owed.test'), (v_oth, 'own@otherdues.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_own, 'Owed Owner',     'owner',         v_school),
    (v_pr,  'Owed Principal', 'principal',     v_school),
    (v_ro,  'Owed Observer',  'readonly',      v_school),
    (v_ct,  'Owed Teacher',   'class_teacher', v_school),
    (v_oth, 'Other Owner',    'owner',         v_other)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role,
                                   full_name = excluded.full_name, active = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_own::text, false);
  insert into public.academic_sessions (school_id, name, starts_on, ends_on, is_current)
    values (v_school, 'Last year', (v_start - interval '12 months')::date, v_start - 1, false)
    returning id into v_last;
  insert into public.academic_sessions (school_id, name, starts_on, ends_on, is_current)
    values (v_school, 'This year', v_start, (v_start + interval '12 months')::date - 1, true)
    returning id into v_sess;
  update public.school_settings set current_session_id = v_sess, billing_day = 1, due_day = 10
   where school_id = v_school;

  insert into public.classes (school_id, name, level_order) values (v_school, 'Class 3', 3) returning id into v_c3;
  insert into public.classes (school_id, name, level_order) values (v_school, 'Class 7', 7) returning id into v_c7;
  insert into public.sections (school_id, class_id, name) values (v_school, v_c3, 'A') returning id into v_3a;
  insert into public.fee_heads (school_id, name, type, is_refundable, is_recurring, sort_order, active)
    values (v_school, 'Monthly Fee', 'monthly', false, true, 1, true) returning id into v_fh;
  insert into public.fee_structures (school_id, session_id, class_id, fee_head_id, amount, effective_from)
    values (v_school, v_sess, v_c3, v_fh, 3000, v_start),
           (v_school, v_last, v_c3, v_fh, 2500, (v_start - interval '12 months')::date);

  -- A child who has been on the software since last year: enrolled in both.
  insert into public.students (school_id, full_name, status, admission_date)
    values (v_school, 'Old Hand', 'active', (v_start - interval '12 months')::date)
    returning id into v_kid;
  insert into public.enrollments (school_id, student_id, session_id, class_id, status)
    values (v_school, v_kid, v_last, v_c3, 'promoted'),
           (v_school, v_kid, v_sess, v_c3, 'active');

  perform set_config('test.uid', v_oth::text, false);
  insert into public.academic_sessions (school_id, name, starts_on, ends_on, is_current)
    values (v_other, 'Theirs', v_start, (v_start + interval '12 months')::date - 1, true)
    returning id into v_osess;
  insert into public.classes (school_id, name, level_order) values (v_other, 'Their Class', 1) returning id into v_oc;
  insert into public.students (school_id, full_name, status) values (v_other, 'Their Child', 'active')
    returning id into v_kid;
  insert into public.enrollments (school_id, student_id, session_id, class_id, status)
    values (v_other, v_kid, v_osess, v_oc, 'active');
  raise notice 'fixture ok';
end $seed$;

create or replace function pg_temp.school() returns uuid language sql stable as
  $$ select id from public.schools where name = 'Owed Before School' $$;
create or replace function pg_temp.sess() returns uuid language sql stable as
  $$ select id from public.academic_sessions where school_id = pg_temp.school() and name = 'This year' $$;
create or replace function pg_temp.last_year() returns uuid language sql stable as
  $$ select id from public.academic_sessions where school_id = pg_temp.school() and name = 'Last year' $$;
create or replace function pg_temp.cls(p_name text) returns uuid language sql stable as
  $$ select id from public.classes where school_id = pg_temp.school() and name = p_name $$;
create or replace function pg_temp.sec() returns uuid language sql stable as
  $$ select id from public.sections where school_id = pg_temp.school() and name = 'A' $$;
create or replace function pg_temp.kid(p_name text) returns uuid language sql stable as
  $$ select id from public.students where full_name = p_name $$;
-- The months, from today in Karachi, as 'YYYY-MM' the way the screen sends them.
create or replace function pg_temp.mon(p_back integer) returns text language sql stable as
  $$ select to_char(date_trunc('month', (now() at time zone 'Asia/Karachi')::date
                    - make_interval(months => p_back)), 'YYYY-MM') $$;
create or replace function pg_temp.first(p_back integer) returns date language sql stable as
  $$ select date_trunc('month', (now() at time zone 'Asia/Karachi')::date
                    - make_interval(months => p_back))::date $$;
create or replace function pg_temp.owed(p_inv uuid) returns numeric language sql stable as
  $$ select charge - allocated from public.invoice_balances where invoice_id = p_inv $$;
create or replace function pg_temp.row_of(j jsonb, p_row integer) returns jsonb language sql immutable as
  $$ select x from jsonb_array_elements(j->'results') x where (x->>'row')::int = p_row $$;
create or replace function pg_temp.add(p_rows jsonb, p_class text default 'Class 3',
                                       p_request uuid default null)
returns jsonb language sql as $$
  select public.fn_rde_add_students(jsonb_build_object(
    'session_id', pg_temp.sess(), 'class_id', pg_temp.cls(p_class),
    'section_id', case when p_class = 'Class 3' then pg_temp.sec() end,
    'request_id', p_request, 'rows', p_rows))
$$;

select pg_temp.be('Owed Owner');

-- =============================================================================
-- 1-6. One child with every kind of due, and this month already paid
-- =============================================================================
do $t$
declare j jsonb; r jsonb; v_kid uuid; v_this uuid; v_aug uuid; n int;
begin
  j := pg_temp.add(jsonb_build_array(jsonb_build_object(
    'full_name', 'Zara Owes', 'father_name', 'Tariq', 'gender', 'female',
    'paid_this_month', true,
    'dues', jsonb_build_array(
      jsonb_build_object('kind', 'month', 'month', pg_temp.mon(1), 'amount', 3000),
      jsonb_build_object('kind', 'month', 'month', pg_temp.mon(5), 'amount', 'Rs 2,500'),
      jsonb_build_object('kind', 'stationery', 'amount', 800),
      jsonb_build_object('kind', 'other', 'label', 'Picnic', 'amount', 500)))));
  r := pg_temp.row_of(j, 1);
  v_kid := pg_temp.kid('Zara Owes');

  perform pg_temp.ok(r->>'status' = 'created' and (r->>'dues_recorded')::int = 4
                     and (r->>'dues_total')::numeric = 6800 and (r->>'arrears_months')::int = 2,
    '1a. the child, four dues and Rs 6,800 are recorded, and nothing is reported missing: '
    || coalesce(r::text, 'no row'));

  select id into v_this from public.invoices
   where student_id = v_kid and period_month = pg_temp.first(0) and status <> 'void';
  select id into v_aug from public.invoices
   where student_id = v_kid and period_month = pg_temp.first(1) and status <> 'void';
  perform pg_temp.ok(pg_temp.owed(v_this) = 0 and pg_temp.owed(v_aug) = 3000,
    '1b. THE ONE THIS FILE EXISTS FOR: the payment cleared THIS month and last month''s '
    || 'due is still owed in full (this month owes ' || pg_temp.owed(v_this)
    || ', last month owes ' || pg_temp.owed(v_aug) || ')');

  perform pg_temp.ok(
    (select count(*) from public.invoices where student_id = v_kid and carried_kind is not null) = 4
    and (select carried_kind from public.invoices where id = v_aug) = 'month'
    and (select carried_kind from public.invoices where id = v_this) is null,
    '2. every typed due is marked as typed in, and the bill the software raised is not');

  perform pg_temp.ok(
    (select session_id from public.invoices
      where student_id = v_kid and period_month = pg_temp.first(5)) = pg_temp.sess()
    and (select l.amount from public.invoices i join public.invoice_lines l on l.invoice_id = i.id
          where i.student_id = v_kid and i.period_month = pg_temp.first(5)) = 2500,
    '3. a month from before this school year is accepted, on the only enrolment the new '
    || 'child has, and "Rs 2,500" is read as 2500');

  perform pg_temp.ok(
    (select string_agg(label || '=' || (select l.amount from public.invoice_lines l
                                         where l.invoice_id = i.id)::int, ',' order by label)
       from public.invoices i where i.student_id = v_kid and i.period_month is null)
      = 'Picnic=500,Stationery=800',
    '4. a named due carries its name, and "other" carries the name the clerk typed');

  perform pg_temp.ok(
    (select due_date from public.invoices where id = v_aug)
      = (pg_temp.first(1) + interval '1 month' - interval '1 day')::date
    and (select (issued_at at time zone 'Asia/Karachi')::date from public.invoices where id = v_aug)
      = pg_temp.first(1),
    '5. a month due is dated in its own month, so the statement reads in order');

  select count(*) into n from public.audit_log
   where entity = 'students' and entity_id = v_kid::text and action = 'DUES_RECORDED';
  perform pg_temp.ok(n = 1, '6. typing money in by hand leaves an audit row');
end $t$;

-- =============================================================================
-- 7-11. One bad line costs only itself
-- =============================================================================
do $t$
declare j jsonb; r jsonb; v_kid uuid;
begin
  j := pg_temp.add(jsonb_build_array(jsonb_build_object(
    'full_name', 'Bad Lines',
    'dues', jsonb_build_array(
      jsonb_build_object('kind', 'month', 'month', 'Aug', 'amount', 3000),
      jsonb_build_object('kind', 'month', 'month', pg_temp.mon(0), 'amount', 3000),
      jsonb_build_object('kind', 'month', 'month', pg_temp.mon(2), 'amount', 1000),
      jsonb_build_object('kind', 'month', 'month', pg_temp.mon(2), 'amount', 2500),
      jsonb_build_object('kind', 'month', 'month', pg_temp.mon(40), 'amount', 900),
      jsonb_build_object('kind', 'other', 'amount', 700),
      jsonb_build_object('kind', 'books', 'amount', 'abc'),
      jsonb_build_object('kind', 'books', 'amount', 1200)))));
  r := pg_temp.row_of(j, 1);
  v_kid := pg_temp.kid('Bad Lines');

  perform pg_temp.ok(r->>'status' = 'partial' and (r->>'dues_recorded')::int = 2,
    '7. two good dues are kept beside six bad ones, and the row says it is partial: '
    || coalesce(r->>'dues_recorded', '?') || ' recorded');
  perform pg_temp.ok(
    (select l.amount from public.invoices i join public.invoice_lines l on l.invoice_id = i.id
      where i.student_id = v_kid and i.period_month = pg_temp.first(2)) = 1000,
    '8. a month listed twice keeps the first amount, once');
  perform pg_temp.ok(r->>'message' like '%has not finished%'
                     and r->>'message' like '%more than three years%'
                     and r->>'message' like '%listed twice%'
                     and r->>'message' like '%no name%'
                     and r->>'message' like '%"abc" is not an amount%'
                     and r->>'message' like '%no month%',
    '9. each refusal is a sentence about that line: ' || coalesce(r->>'message', ''));
  perform pg_temp.ok(r->>'message' not like '%invalid input syntax%',
    '10. and no Postgres error text reaches the clerk');
  perform pg_temp.ok(
    (select count(*) from public.invoices
      where student_id = v_kid and period_month = pg_temp.first(0) and carried_kind is not null) = 0,
    '11. no due is written for this month, which the software bills itself');
end $t$;

-- =============================================================================
-- 12-15. Paying part, paying more, and a class with no fee
-- =============================================================================
do $t$
declare j jsonb; r jsonb; v_inv uuid;
begin
  j := pg_temp.add(jsonb_build_array(
    jsonb_build_object('full_name', 'Part Payer', 'paid_this_month', true, 'paid_amount', '1,000'),
    jsonb_build_object('full_name', 'Over Payer', 'paid_this_month', true, 'paid_amount', 5000)));

  select id into v_inv from public.invoices
   where student_id = pg_temp.kid('Part Payer') and period_month = pg_temp.first(0);
  perform pg_temp.ok(pg_temp.owed(v_inv) = 2000
                     and (pg_temp.row_of(j, 1)->>'paid_amount')::numeric = 1000
                     and pg_temp.row_of(j, 1)->>'status' = 'created',
    '12. a part payment is recorded as the part, and the rest is still owed');

  select id into v_inv from public.invoices
   where student_id = pg_temp.kid('Over Payer') and period_month = pg_temp.first(0);
  r := pg_temp.row_of(j, 2);
  perform pg_temp.ok(pg_temp.owed(v_inv) = 0 and (r->>'paid_amount')::numeric = 3000
                     and r->>'status' = 'partial' and r->>'message' like '%Rs 5,000 was typed%',
    '13. more than the fee records the fee and says so, rather than leaving credit nobody asked for');

  j := pg_temp.add(jsonb_build_array(jsonb_build_object(
         'full_name', 'No Fee Class', 'paid_this_month', true)), 'Class 7');
  r := pg_temp.row_of(j, 1);
  perform pg_temp.ok(r->>'status' = 'partial' and r->>'message' like '%no monthly fee set yet%'
                     and (select count(*) from public.payments
                           where student_id = pg_temp.kid('No Fee Class')) = 0,
    '14. "already collected" in a class with no fee says so, instead of a silent nothing');

  j := pg_temp.add(jsonb_build_array(jsonb_build_object(
         'full_name', 'Old Shape', 'arrears', jsonb_build_array(
           jsonb_build_object('month', pg_temp.first(1), 'amount', 3000)))));
  perform pg_temp.ok((pg_temp.row_of(j, 1)->>'arrears_months')::int = 1
                     and pg_temp.row_of(j, 1)->>'status' = 'created',
    '15. a browser that has not reloaded still sends arrears the old way, and they are kept');
end $t$;

-- =============================================================================
-- 16-18. A save that arrives twice, and a key nobody reads
-- =============================================================================
do $t$
declare j1 jsonb; j2 jsonb; v_req uuid := gen_random_uuid(); n int;
begin
  j1 := pg_temp.add(jsonb_build_array(jsonb_build_object(
          'full_name', 'Twice Sent', 'dues', jsonb_build_array(
            jsonb_build_object('kind', 'uniform', 'amount', 1500)))), 'Class 3', v_req);
  j2 := pg_temp.add(jsonb_build_array(jsonb_build_object(
          'full_name', 'Twice Sent', 'dues', jsonb_build_array(
            jsonb_build_object('kind', 'uniform', 'amount', 1500)))), 'Class 3', v_req);
  select count(*) into n from public.students where full_name = 'Twice Sent';
  perform pg_temp.ok(n = 1 and (j2->>'replayed')::boolean
                     and j2->'results' = j1->'results',
    '16. the same save twice admits the child once and gives the first answer back');
  perform pg_temp.ok(
    (select count(*) from public.invoices i
      where i.student_id = pg_temp.kid('Twice Sent') and i.carried_kind = 'uniform') = 1,
    '17. and the uniform is owed once');
end $t$;

select pg_temp.raises(
  $q$ select pg_temp.add(jsonb_build_array(jsonb_build_object(
        'full_name', 'Misspelt', 'arears', jsonb_build_array()))) $q$,
  '18. a row key the function does not read is refused, not dropped with the money in it',
  '%does not understand arears%');

-- =============================================================================
-- 19-25. Dues for a child already on the software
-- =============================================================================
do $t$
declare j jsonb; v_kid uuid := pg_temp.kid('Old Hand'); v_last_enr uuid; v_inv uuid;
begin
  select id into v_last_enr from public.enrollments
   where student_id = v_kid and session_id = pg_temp.last_year();

  -- Last year's month on last year's enrolment, and this year's on this year's.
  j := public.fn_record_dues(v_kid, jsonb_build_array(
         jsonb_build_object('kind', 'month', 'month', pg_temp.mon(5), 'amount', 2500),
         jsonb_build_object('kind', 'month', 'month', pg_temp.mon(1), 'amount', 3000),
         jsonb_build_object('kind', 'admission', 'amount', 5000)));
  perform pg_temp.ok((j->>'recorded')::int = 3,
    '19. three dues recorded for a child already in the software: ' || j::text);
  perform pg_temp.ok(
    (select enrollment_id from public.invoices
      where student_id = v_kid and period_month = pg_temp.first(5)) = v_last_enr
    and (select session_id from public.invoices
          where student_id = v_kid and period_month = pg_temp.first(5)) = pg_temp.last_year(),
    '20. a month of last year goes on last year''s enrolment, so last year''s reports have it');

  -- The same month again, through the other enrolment, is refused: the unique
  -- index is per enrolment and would not have seen it.
  j := public.fn_record_dues(v_kid, jsonb_build_array(
         jsonb_build_object('kind', 'month', 'month', pg_temp.mon(5), 'amount', 999),
         jsonb_build_object('kind', 'admission', 'amount', 5000)));
  perform pg_temp.ok((j->>'recorded')::int = 0
                     and j->'items'->0->>'message' like '%already has a charge of Rs 2,500%'
                     and j->'items'->1->>'status' = 'skipped',
    '21. a month already charged on any enrolment is left alone, and the same named due '
    || 'twice is a retry, not a second debt');

  -- This month's regular bill blocks a typed due for a month that has one.
  perform public.fn_bill_student_month(
    (select id from public.enrollments where student_id = v_kid and session_id = pg_temp.sess()),
    pg_temp.first(2), null);
  j := public.fn_record_dues(v_kid, jsonb_build_array(
         jsonb_build_object('kind', 'month', 'month', pg_temp.mon(2), 'amount', 3000)));
  perform pg_temp.ok(j->'items'->0->>'status' = 'skipped',
    '22. a month the software already billed is not billed again by hand');

  -- One challan per month, whatever day is named.
  v_inv := public.fn_bill_student_month(
    (select id from public.enrollments where student_id = v_kid and session_id = pg_temp.sess()),
    (pg_temp.first(2) + 14), null);
  perform pg_temp.ok(
    (select count(*) from public.invoices
      where student_id = v_kid and date_trunc('month', period_month) = pg_temp.first(2)
        and status <> 'void') = 1,
    '23. the 15th of a month is the same month: no second challan');
end $t$;

select pg_temp.be('Owed Observer');
select pg_temp.raises(
  format($q$ select public.fn_record_dues(%L, '[]'::jsonb) $q$, pg_temp.kid('Old Hand')),
  '24. an observer cannot type in money', '%Not permitted%');
select pg_temp.be('Owed Teacher');
select pg_temp.raises(
  format($q$ select public.fn_record_dues(%L, '[]'::jsonb) $q$, pg_temp.kid('Old Hand')),
  '24b. nor can a teacher', '%Not permitted%');
select pg_temp.be('Other Owner');
select pg_temp.raises(
  format($q$ select public.fn_record_dues(%L, jsonb_build_array(jsonb_build_object(
           'kind', 'books', 'amount', 100))) $q$, pg_temp.kid('Old Hand')),
  '25. another school''s owner cannot add a due to this school''s child');
select pg_temp.raises(
  format($q$ select public.fn_student_dues(%L) $q$, pg_temp.kid('Old Hand')),
  '25b. nor read them');
select pg_temp.be('Owed Owner');

-- =============================================================================
-- 26-29. The dues are where the school looks for them
-- =============================================================================
do $t$
declare j jsonb; v_kid uuid := pg_temp.kid('Zara Owes'); r record;
begin
  perform pg_temp.be('Owed Observer');
  set local role authenticated;
  j := public.fn_student_dues(v_kid);
  reset role;
  perform pg_temp.be('Owed Owner');
  perform pg_temp.ok(jsonb_array_length(j->'dues') = 4 and (j->>'outstanding')::numeric = 6800
                     and (select count(*) from jsonb_array_elements(j->'dues') x
                           where x->>'label' in ('Stationery', 'Picnic')) = 2,
    '26. the child''s page lists all four dues with their names and Rs 6,800 owed, '
    || 'read as an observer');

  select * into r from public.fn_arrears(pg_temp.sess()) a where a.student_id = v_kid;
  perform pg_temp.ok(r.months_owed = 2 and r.amount = 6800
                     and r.oldest_month = pg_temp.first(5),
    '27. Fees, Arrears counts two months and Rs 6,800 with the named dues in it (got '
    || coalesce(r.months_owed::text, 'no row') || ' months, Rs ' || coalesce(r.amount::text, '-') || ')');

  j := public.fn_student_fee_state(v_kid, null);
  perform pg_temp.ok((j->>'other_dues_amount')::numeric = 1300
                     and (j->>'other_dues_count')::int = 2
                     and (j->>'arrears_amount')::numeric = 5500,
    '28. the fee state names Rs 1,300 of other dues beside Rs 5,500 of earlier months');

  perform pg_temp.ok(
    (select (public.fn_challan(i.id))->>'period_label' from public.invoices i
      where i.student_id = v_kid and i.label = 'Picnic') = 'Picnic',
    '29. a challan for a named due prints its name where the month goes');
end $t$;

-- =============================================================================
-- 30-33. A typed due is not discounted, and a holiday can still be skipped
-- =============================================================================
do $t$
declare v_kid uuid := pg_temp.kid('Zara Owes'); v_d uuid; v_due date := pg_temp.first(1);
begin
  -- A holiday month with only typed dues in it can still be skipped.
  perform public.fn_set_month_state(pg_temp.sess(), pg_temp.first(1), 'skipped', null, 'Holiday');
  perform pg_temp.ok(
    (select state from public.billing_months
      where session_id = pg_temp.sess() and period_month = pg_temp.first(1)) = 'skipped',
    '30. a month whose only charges were typed in can still be marked a holiday');
  perform pg_temp.ok(
    (select count(*) from public.invoices
      where student_id = v_kid and period_month = v_due and status <> 'void') = 1,
    '31. and the child''s typed due for it stays on their account');

  -- A half concession, backdated to the start of the year.
  v_d := public.fn_add_discount(v_kid, 'hardship', 50, true, 'test', pg_temp.first(3), null);
  perform public.fn_set_discount_status(v_d, 'approved');
  perform pg_temp.ok(
    (select pg_temp.owed(id) from public.invoices
      where student_id = v_kid and period_month = v_due and status <> 'void') = 3000,
    '32. a backdated concession does not halve a due the school typed from its paper');

  -- And the billing run for a month with a typed due and a live concession.
  perform public.fn_bill_month(pg_temp.sess(), pg_temp.first(1), null);
  perform pg_temp.ok(
    not exists (select 1 from public.invoices i
                  join public.invoice_lines l on l.invoice_id = i.id and l.is_discount
                 where i.carried_kind is not null and i.school_id = pg_temp.school()),
    '33. no typed due anywhere in the school has a discount line on it');
end $t$;

-- =============================================================================
-- 34-36. Labels, the statement, and the CSV opening balance beside it
-- =============================================================================
do $t$
declare v_kid uuid := pg_temp.kid('Old Hand'); j jsonb; v_inv uuid; v_first text;
begin
  perform public.fn_import_opening_balances(pg_temp.sess(),
    jsonb_build_array(jsonb_build_object('full_name', 'Old Hand', 'amount', 4000)), false);
  select id into v_inv from public.invoices
   where student_id = v_kid and split_part(coalesce(notes, ''), E'\n', 1) = 'opening_balance';
  perform pg_temp.ok((public.fn_challan(v_inv))->>'period_label' = 'Opening balance'
                     and (select period_label from public.fn_report_unpaid_invoices(pg_temp.sess())
                           where invoice_id = v_inv) = 'Opening balance',
    '34. an imported opening balance is called that on the challan and the unpaid list, '
    || 'not opening_balance');

  j := public.fn_student_dues(v_kid);
  perform pg_temp.ok(
    (select count(*) from jsonb_array_elements(j->'dues') x where x->>'kind' = 'opening') = 1,
    '35. and the child''s page lists it beside the typed dues');

  select particulars into v_first from public.fn__student_ledger(v_kid)
   where kind = 'charge' order by seq limit 1;
  perform pg_temp.ok(v_first = 'Monthly fee for ' || to_char(pg_temp.first(5), 'Mon YYYY'),
    '36. the statement opens with the oldest due, named once: ' || coalesce(v_first, '-'));
end $t$;

-- =============================================================================
-- 37-38. Walked as real logins
-- =============================================================================
do $t$
declare n int; v_err text;
begin
  perform pg_temp.be('Owed Owner');
  set local role authenticated;
  select count(*) into n from public.invoices where carried_kind is not null;
  begin
    perform 1 from public.rde_saves limit 1;
    v_err := null;
  exception when others then
    v_err := sqlerrm;
  end;
  reset role;
  perform pg_temp.ok(n > 0, '37. the owner reads the typed dues through the ordinary invoice policy');
  perform pg_temp.ok(v_err like '%permission denied%',
    '38. and nobody in a browser can read the stored save answers');
end $t$;

do $t$
declare n int;
begin
  perform pg_temp.be('Other Owner');
  set local role authenticated;
  select count(*) into n from public.invoices where carried_kind is not null;
  reset role;
  perform pg_temp.be('Owed Owner');
  perform pg_temp.ok(n = 0, '39. another school sees none of them');
end $t$;

rollback;
\echo 'WHAT WAS OWED BEFORE: ALL TESTS PASSED'
