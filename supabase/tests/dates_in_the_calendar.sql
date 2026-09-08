-- =============================================================================
-- Nothing is recorded outside the school's own academic calendar.
--
-- WHERE THIS CAME FROM. Two calls to the app's own function, on a real school:
--
--     ACCEPTED a 2099 date: {"total": 1, "marked": 1, "skipped": 0}
--     ACCEPTED an 1900 date: {"total": 1, "marked": 1, "skipped": 0}
--     the register now runs 1900-01-01 to 2099-12-31
--
-- Five caller-supplied dates were unbounded, and fn_set_staff_attendance was
-- the only one with any guard at all: it refused the future and accepted 1900.
--
-- THE HARM IS A TYPED YEAR, not an attacker. attendance_daily is keyed on
-- (enrollment_id, attendance_date), so 2062 for 2026 creates a row that appears
-- on no screen (every attendance screen is scoped to a date or a month), is
-- counted in the percentage the parent portal shows, and can never be found
-- again. A challan with a due date in 2062 never becomes overdue, so the family
-- never appears on the defaulter list.
--
-- WHAT MUST STILL WORK is the half this suite spends most of its assertions on.
-- The bound is the school's OWN calendar, so it has to refuse nothing a school
-- does: last month's register, last year's register through an unlock, a
-- challan due after the session ends, an expense a week before the first
-- session started, a school with no session dates at all.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/dates_in_the_calendar.sql
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

create or replace function pg_temp.raises(p_sql text, p_needle text) returns boolean
language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  if position(lower(p_needle) in lower(sqlerrm)) > 0 then return true; end if;
  raise notice '  (refused, but saying: %)', sqlerrm;
  return false;
end;
$$;

create table pg_temp.ids (k text primary key, v uuid);

-- --- Fixture -----------------------------------------------------------------
-- One school with two academic years, last year's closed and this year current,
-- both dated. A class, a section, a child enrolled in each year.
do $seed$
declare
  v_sch uuid; v_last uuid; v_now uuid; v_cls uuid; v_sec uuid;
  v_owner uuid := '00000000-0000-0000-0000-0000000007a1';
  v_stu uuid; v_enr_last uuid; v_enr_now uuid; v_head uuid;
begin
  insert into public.schools (name) values ('Calendar School') returning id into v_sch;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_sch, 'growth', 'active', current_date - 1);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_owner, 'owner@calendar.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_owner, 'Calendar Owner', 'owner', v_sch)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role = excluded.role, active = true;
  alter table public.profiles enable trigger user;
  perform set_config('test.uid', v_owner::text, false);

  -- DATES RELATIVE TO TODAY, not literals. A suite with 2026-04-01 in it starts
  -- failing in April 2027 for a reason that has nothing to do with the rule.
  insert into public.academic_sessions (name, is_current, school_id, starts_on, ends_on)
    values ('Last year', false, v_sch, current_date - 400, current_date - 40)
    returning id into v_last;
  insert into public.academic_sessions (name, is_current, school_id, starts_on, ends_on)
    values ('This year', true, v_sch, current_date - 30, current_date + 330)
    returning id into v_now;
  update public.school_settings set current_session_id = v_now where school_id = v_sch;

  insert into public.classes (name, level_order, school_id)
    values ('Class 1', 1, v_sch) returning id into v_cls;
  insert into public.sections (name, class_id, school_id)
    values ('A', v_cls, v_sch) returning id into v_sec;
  insert into public.fee_heads (name, school_id) values ('Tuition', v_sch)
    returning id into v_head;

  insert into public.students (full_name, father_name, school_id)
    values ('Calendar Child', 'Calendar Father', v_sch) returning id into v_stu;
  insert into public.enrollments (school_id, session_id, class_id, section_id,
                                  student_id, status)
    values (v_sch, v_last, v_cls, v_sec, v_stu, 'left') returning id into v_enr_last;
  insert into public.enrollments (school_id, session_id, class_id, section_id,
                                  student_id, status)
    values (v_sch, v_now, v_cls, v_sec, v_stu, 'active') returning id into v_enr_now;

  insert into pg_temp.ids (k, v) values
    ('sch', v_sch), ('last', v_last), ('now', v_now), ('cls', v_cls),
    ('sec', v_sec), ('owner', v_owner), ('stu', v_stu), ('head', v_head),
    ('enr_last', v_enr_last), ('enr_now', v_enr_now);
end $seed$;

-- --- A SECOND SCHOOL, WITH NO DATES ON ITS ACADEMIC YEAR ---------------------
-- Every school created through the first-run wizard is in this state. Built
-- here rather than beside its own assertions, and the reason is worth writing
-- down: creating a school while acting as ANOTHER school's owner is refused by
-- enforce_school_id, because inserting a `schools` row seeds that school's
-- expense categories and the cross-tenant guard compares them to
-- current_school_id(). The first version of this fixture did exactly that and
-- failed with "Cross-tenant write refused on expense_categories", which is a
-- confusing way for a test about dates to fall over.
do $seed2$
declare
  v_sch uuid; v_owner uuid := '00000000-0000-0000-0000-0000000007b1';
  v_sess uuid; v_cls uuid; v_stu uuid; v_enr uuid; v_cat uuid;
begin
  perform set_config('test.uid', '', false);
  insert into public.schools (name) values ('Dateless School') returning id into v_sch;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_sch, 'starter', 'active', current_date - 1);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_owner, 'owner@dateless.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id, active)
    values (v_owner, 'Dateless Owner', 'owner', v_sch, true)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role = excluded.role, active = true;
  alter table public.profiles enable trigger user;
  perform set_config('test.uid', v_owner::text, false);

  -- Created WITH dates and then emptied, because the trigger this migration
  -- adds refuses the insert otherwise. This is exactly the state every school
  -- set up before it is in.
  insert into public.academic_sessions (name, is_current, school_id, starts_on, ends_on)
    values ('2026-2027', true, v_sch, current_date - 10, current_date + 300)
    returning id into v_sess;
  update public.academic_sessions set starts_on = null, ends_on = null
   where id = v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_sch;

  insert into public.classes (name, level_order, school_id)
    values ('Class 1', 1, v_sch) returning id into v_cls;
  -- Whatever the school was seeded with when its `schools` row was created.
  -- Naming one explicitly hit uq_expense_cat_school_name, because the seed had
  -- already put 'Utilities' there.
  select id into v_cat from public.expense_categories
   where school_id = v_sch order by name limit 1;
  insert into public.students (full_name, father_name, school_id)
    values ('Dateless Child', 'Father', v_sch) returning id into v_stu;
  insert into public.enrollments (school_id, session_id, class_id, student_id, status)
    values (v_sch, v_sess, v_cls, v_stu, 'active') returning id into v_enr;

  insert into pg_temp.ids (k, v) values
    ('d_sch', v_sch), ('d_owner', v_owner), ('d_sess', v_sess),
    ('d_enr', v_enr), ('d_cat', v_cat);
end $seed2$;

-- =============================================================================
-- 1. THE REGISTER
-- =============================================================================
do $$
declare
  v_now uuid := (select v from pg_temp.ids where k='now');
  v_enr_now uuid := (select v from pg_temp.ids where k='enr_now');
  v_enr_last uuid := (select v from pg_temp.ids where k='enr_last');
  v_marks jsonb;
begin
  perform set_config('test.uid',
    (select v::text from pg_temp.ids where k='owner'), false);
  v_marks := jsonb_build_array(
    jsonb_build_object('enrollment_id', v_enr_now, 'status', 'present'));

  -- WHAT MUST WORK, first and deliberately: today, and a day last week.
  perform public.fn_mark_attendance(current_date, v_marks);
  perform pg_temp.ok(exists (select 1 from public.attendance_daily
                              where enrollment_id = v_enr_now
                                and attendance_date = current_date),
    '1  today''s register still marks, which is what the whole product does '
    || 'every morning');
  perform public.fn_mark_attendance(current_date - 7, v_marks);
  perform pg_temp.ok(exists (select 1 from public.attendance_daily
                              where enrollment_id = v_enr_now
                                and attendance_date = current_date - 7),
    '2  and a day last week, because a register is caught up on Monday for the '
    || 'Friday nobody filled in');

  -- The two that were accepted before.
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_mark_attendance('2099-12-31'::date, %L::jsonb)$q$, v_marks),
    'has not happened yet'),
    '3  a date in 2099 is refused, and the message says why rather than naming '
    || 'a range: the year is the mistake, not the range');
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_mark_attendance('1900-01-01'::date, %L::jsonb)$q$, v_marks),
    'outside it'),
    '4  and one in 1900, which no guard anywhere refused before');
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_mark_attendance(%L::date, %L::jsonb)$q$,
           current_date + 1, v_marks),
    'has not happened yet'),
    '5  tomorrow is refused too. Marking a class present for the rest of the '
    || 'term in advance is 200 days of fiction, and the date picker''s max is '
    || 'not a rule the database knew about');

  -- THE CASE THE BOUND IS SHAPED FOR: last year's register, through last year's
  -- enrolment. The date is outside the CURRENT session and inside the one the
  -- enrolment belongs to, and correcting last year is a thing schools do.
  perform public.fn_mark_attendance(
    current_date - 100,
    jsonb_build_array(jsonb_build_object('enrollment_id', v_enr_last,
                                         'status', 'absent')));
  perform pg_temp.ok(exists (select 1 from public.attendance_daily
                              where enrollment_id = v_enr_last
                                and attendance_date = current_date - 100),
    '6  LAST YEAR''S REGISTER STILL MARKS, through last year''s enrolment. The '
    || 'check is against the session the enrolment belongs to and not against '
    || 'the current one, because reopening a closed year to correct it is what '
    || 'fn_unlock_attendance exists for');

  -- And a date in neither year is still refused for that enrolment.
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_mark_attendance(%L::date, %L::jsonb)$q$,
           current_date - 20,
           jsonb_build_array(jsonb_build_object('enrollment_id', v_enr_last,
                                                'status', 'absent'))),
    'outside it'),
    '7  but a date from THIS year cannot be marked against LAST year''s '
    || 'enrolment, which is the mistake a school makes on the day it rolls over');
end $$;

-- =============================================================================
-- 2. THE CHALLANS
--
-- The period month belongs to the session. The due date is looser, and has to
-- be: measured on the demo school, 201 of 6,189 challans fall due after their
-- session has ended, which is correct for the last month of the year.
-- =============================================================================
do $$
declare
  v_enr_now uuid := (select v from pg_temp.ids where k='enr_now');
  v_now uuid := (select v from pg_temp.ids where k='now');
  v_cls uuid := (select v from pg_temp.ids where k='cls');
  v_month date := date_trunc('month', current_date)::date;
begin
  perform set_config('test.uid',
    (select v::text from pg_temp.ids where k='owner'), false);

  -- What must work.
  perform pg_temp.ok(
    public.fn_bill_student_month(v_enr_now, v_month, v_month + 9) is not null,
    '8  this month''s challan still generates, due nine days later, which is '
    || 'what the demo school''s 6,189 challans all do');

  -- THE LAST MONTH OF THE YEAR, due after the session ends. 201 of the demo
  -- school's challans look like this and every one of them is correct.
  perform pg_temp.ok(
    public.fn_bill_student_month(
      v_enr_now,
      (select date_trunc('month', ends_on)::date from public.academic_sessions
        where id = v_now),
      (select ends_on + 10 from public.academic_sessions where id = v_now)
    ) is not null,
    '9  AND THE LAST MONTH''S CHALLAN, DUE AFTER THE YEAR ENDS. March''s fee is '
    || 'due on 10 April, which is outside the session: if the due date were '
    || 'bounded like the period month, a fifth of a school''s challans would '
    || 'be refused');

  -- A period month outside the session.
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_bill_student_month(%L, '2062-05-01'::date, '2062-05-10'::date)$q$,
           v_enr_now), 'outside it'),
    '10 a challan for May 2062 is refused. It would show in no month''s '
    || 'collection figure and on no defaulter list');

  -- A due date in the wrong year, with the period month right. This is the
  -- worse of the two mistakes: the challan looks correct everywhere except that
  -- the family never becomes a defaulter.
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_bill_student_month(%L, %L::date, '2062-05-10'::date)$q$,
           v_enr_now, v_month + 1), 'cannot be due on'),
    '11 and so is a challan for a real month due in 2062, which is the worse '
    || 'mistake: it looks right on every screen and the family is never a '
    || 'defaulter');

  -- The whole-class version, which writes a row per child.
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_generate_class_invoices(%L, %L, '2062-05-01'::date, '2062-05-10'::date)$q$,
           v_now, v_cls), 'outside it'),
    '12 the whole-class generator refuses it too, and it matters more there: '
    || 'one mistyped year is a challan for every child in the class');
end $$;

-- =============================================================================
-- 3. THE MONEY THAT IS NOT FEES
--
-- The loose bound: a year either side of the school's own span. An expense
-- belongs to the school rather than to an academic year.
-- =============================================================================
do $$
declare
  v_sch uuid := (select v from pg_temp.ids where k='sch');
  v_cat uuid;
  v_a date; v_b date;
begin
  perform set_config('test.uid',
    (select v::text from pg_temp.ids where k='owner'), false);
  select min(starts_on), max(ends_on) into v_a, v_b
    from public.academic_sessions where school_id = v_sch;
  select id into v_cat from public.expense_categories where school_id = v_sch limit 1;

  perform pg_temp.ok(
    (public.fn_record_expense(500, v_cat, current_date)->>'expense_id') is not null,
    '13 an expense today still records');

  -- BEFORE THE FIRST SESSION STARTED, which is the case the year of slack is
  -- for: a school setting up in February for an April start pays for furniture
  -- now, and has not created February's academic year because there is not one.
  perform pg_temp.ok(
    (public.fn_record_expense(500, v_cat, v_a - 60)->>'expense_id') is not null,
    '14 AND ONE FROM BEFORE THE FIRST ACADEMIC YEAR BEGAN. A school setting up '
    || 'in February for an April start buys furniture in February, and there '
    || 'is no academic year covering the day it did');

  perform pg_temp.ok(pg_temp.raises(
    'select public.fn_record_expense(500, null, ''2062-01-01''::date)',
    'more than a year outside'),
    '15 an expense in 2062 is refused, and the message says what the school''s '
    || 'own span is rather than quoting a rule');
  perform pg_temp.ok(pg_temp.raises(
    'select public.fn_record_other_income(500, ''Van hire'', ''1899-01-01''::date)',
    'more than a year outside'),
    '16 and income in 1899');

  -- AND A REFUSAL DOES NOT BURN A VOUCHER NUMBER. The check sits before
  -- next_counter for exactly this: a numbered series with gaps in it is a
  -- series somebody has to explain to an auditor.
  declare v_before bigint; v_after bigint;
  begin
    select coalesce(max(voucher_no), 0) into v_before from public.expenses
     where school_id = v_sch;
    perform pg_temp.raises(
      'select public.fn_record_expense(500, null, ''2062-01-01''::date)', 'x');
    perform public.fn_record_expense(700, v_cat, current_date);
    select coalesce(max(voucher_no), 0) into v_after from public.expenses
     where school_id = v_sch;
    perform pg_temp.ok(v_after = v_before + 1,
      '17 and a refused expense does not consume a voucher number, so the '
      || 'series has no gap in it. The check sits before next_counter for that '
      || 'reason alone');
  end;
end $$;

-- =============================================================================
-- 4. THE FEES THEMSELVES, which is where a wrong date is silent
-- =============================================================================
do $$
declare
  v_now uuid := (select v from pg_temp.ids where k='now');
  v_cls uuid := (select v from pg_temp.ids where k='cls');
  v_head uuid := (select v from pg_temp.ids where k='head');
begin
  perform set_config('test.uid',
    (select v::text from pg_temp.ids where k='owner'), false);

  perform public.fn_set_fee_amount(v_now, v_cls, v_head, 2500, current_date);
  perform pg_temp.ok(exists (select 1 from public.fee_structures
                              where session_id = v_now and class_id = v_cls
                                and fee_head_id = v_head),
    '18 a fee amount effective today still saves');

  -- fee_structures is READ BY DATE, so this is the quietest of all the wrong
  -- dates: the row is there, the screen shows it, and every challan after it
  -- is priced from a row that either has not started yet or started in 1900.
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_set_fee_amount(%L, %L, %L, 3000, '2062-04-01'::date)$q$,
           v_now, v_cls, v_head), 'outside it'),
    '19 AND ONE EFFECTIVE FROM 2062 IS REFUSED. This is the quietest of all '
    || 'the wrong dates: fee_structures is read BY DATE, so the row is there, '
    || 'the screen shows it, and not one challan is priced from it');
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_fee_increment(%L, array[%L]::uuid[], array[%L]::uuid[], 10, null, '1900-01-01'::date, true)$q$,
           v_now, v_cls, v_head), 'outside it'),
    '20 and a bulk increase effective from 1900, which would reprice every '
    || 'challan the school has ever raised');
end $$;

-- =============================================================================
-- 5. A YEAR HAS DATES, AND A SCHOOL HAS A FINITE NUMBER OF YEARS
-- =============================================================================
do $$
declare
  v_sch uuid := (select v from pg_temp.ids where k='sch');
  v_n integer;
begin
  perform set_config('test.uid',
    (select v::text from pg_temp.ids where k='owner'), false);

  -- 21 WAS "a session with no dates is refused", and the trigger that did that
  -- was removed: it broke twenty existing fixtures, because a dateless session
  -- has been legal since 0001 and the wizard created one for every school ever
  -- set up. The rule now lives on the two screens that create a session. What
  -- is asserted here instead is the consequence, which is what actually
  -- matters: a dateless year is allowed AND is not silently unbounded, because
  -- verify.sql reports it. Assertions 26 to 28 cover the behaviour.
  perform pg_temp.ok(
    (select count(*) from public.academic_sessions
      where school_id = v_sch and starts_on is null) = 0,
    '21 this fixture''s years all have dates, which is what makes 22 and 23 '
    || 'checks on the constraints rather than on a null');
  perform pg_temp.ok(pg_temp.raises(format(
    $q$insert into public.academic_sessions (name, school_id, starts_on, ends_on)
       values ('Backwards', %L, current_date, current_date - 10)$q$, v_sch),
    'academic_sessions_dates_ordered'),
    '22 and one that ends before it starts');
  perform pg_temp.ok(pg_temp.raises(format(
    $q$insert into public.academic_sessions (name, school_id, starts_on, ends_on)
       values ('A century', %L, current_date, current_date + 40000)$q$, v_sch),
    'academic_sessions_length_sane'),
    '23 and one lasting a century, which would make every bound in this file '
    || 'meaningless: the calendar is derived FROM the sessions');

  -- Eighteen months IS allowed, because a school moving between the Punjab
  -- April start and the Sindh August one has a transition year that long.
  insert into public.academic_sessions (name, school_id, starts_on, ends_on)
    values ('Transition', v_sch, current_date + 400, current_date + 400 + 548);
  perform pg_temp.ok(exists (select 1 from public.academic_sessions
                              where school_id = v_sch and name = 'Transition'),
    '24 an eighteen-month transition year IS allowed, because a school moving '
    || 'from an April start to an August one has exactly that');

  -- And the count. 60 is the cap; this school has 3.
  select count(*) into v_n from public.academic_sessions where school_id = v_sch;
  perform pg_temp.ok(v_n = 3, '25 the fixture has three years so far');
end $$;

-- =============================================================================
-- 6. A SCHOOL WITH NO DATED SESSION IS NOT BLOCKED
--
-- Every school created through the app is in this state, because the wizard
-- never asked. Refusing their ordinary work over a field nobody showed them
-- would be worse than the unbounded dates this file exists to fix.
-- =============================================================================
do $$
declare
  v_sess uuid := (select v from pg_temp.ids where k='d_sess');
  v_enr  uuid := (select v from pg_temp.ids where k='d_enr');
  v_cat  uuid := (select v from pg_temp.ids where k='d_cat');
begin
  perform set_config('test.uid',
    (select v::text from pg_temp.ids where k='d_owner'), false);

  perform public.fn_mark_attendance(current_date,
    jsonb_build_array(jsonb_build_object('enrollment_id', v_enr, 'status', 'present')));
  perform pg_temp.ok(exists (select 1 from public.attendance_daily
                              where enrollment_id = v_enr),
    '26 a school whose academic year has no dates can still mark its register. '
    || 'Every school set up through the wizard is in this state, and refusing '
    || 'their work over a field nobody ever showed them would be worse than '
    || 'the unbounded dates this file fixes');
  perform pg_temp.ok(
    (public.fn_record_expense(300, v_cat, current_date)->>'expense_id') is not null,
    '27 and record an expense, for the same reason');

  -- The bound arrives the moment they fill the dates in.
  update public.academic_sessions
     set starts_on = current_date - 10, ends_on = current_date + 300
   where id = v_sess;
  perform pg_temp.ok(pg_temp.raises(format(
    $q$select public.fn_mark_attendance('2099-01-01'::date, %L::jsonb)$q$,
    jsonb_build_array(jsonb_build_object('enrollment_id', v_enr, 'status', 'present'))),
    'has not happened yet'),
    '28 AND THE BOUND ARRIVES THE MOMENT THE DATES ARE FILLED IN, with nothing '
    || 'else to do. That is why the migration reports the schools that have '
    || 'none rather than guessing dates for them');
end $$;

rollback;
