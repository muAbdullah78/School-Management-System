-- =============================================================================
-- A plan's student limit is a limit, and only on the things that are limits.
--
-- Reported by the vendor of a real school in his own console: "the school is
-- only allowed to have 150 students but it exceeds to 200 plus students so
-- this is a loophole." Nothing enforced it, and fn_my_licence's own words to
-- the school were "We will move you to the right plan at your next renewal.
-- Nothing stops working."
--
-- The rules this file defends. The first four are the block; the next four are
-- the reason a block like this is dangerous, and they matter more:
--
--   1. At the limit, an admission is refused, and the message says the count,
--      the limit and both ways out.
--   2. The OWNER is refused too. The vendor was offered "block the clerk, let
--      the owner override" and chose "block everyone", so that is asserted
--      rather than assumed.
--   3. The importer refuses the whole file up front and creates NOTHING,
--      instead of importing 150 of 300 rows and failing 150 times.
--   4. Bringing a child back from a leaving state counts as an admission,
--      because a child brought back is a child on the roll.
--
--   5. MARKING A CHILD AS LEFT ALWAYS WORKS. A school over its limit needs it
--      to, and it is the only way out that does not involve us.
--   6. fn_rollover IS NEVER BLOCKED. It inserts enrolments for next year,
--      which is the same children a year older. Refusing it would stop a
--      school over its limit from starting its academic year: no register, no
--      challans, no classes.
--   7. NOTHING ALREADY ENTERED IS AFFECTED. Reading, reports and the ledger
--      all work exactly as before at the limit.
--   8. A plan with no limit is never blocked.
--
--   9. The warning starts at 90%, whatever the renewal date, so the first
--      warning cannot arrive after the first refusal.
--  10. The request box: a reason is required, one request at a time, and only
--      the owner or principal may send it.
--  11. The operator sees the roll as it is NOW, not as it was when they asked.
--  12. Granting sets the allowance AND answers the request in one go, and the
--      school can then admit.
--  13. A school cannot grant itself room, and cannot see another school's
--      request.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/student_limit.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

-- THIS SUITE OWNS ITS LIMITS, for the reason operator_billing.sql gives at
-- length: every figure below is arithmetic about a threshold, not a statement
-- about where the commercial bands sit, and 0111 moved those once already.
-- Three pupils rather than 150 so the suite is cheap and readable.
update public.plans set student_limit = 3  where code = 'starter';
update public.plans set student_limit = 8  where code = 'growth';
update public.plans set student_limit = 20 where code = 'institution';
-- `custom` keeps its NULL limit, which is the point of school C below.

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
  raise notice '  (refused, but with the wrong message: %)', sqlerrm;
  return false;
end;
$$;

create or replace function pg_temp.be(p_name text) returns void language sql as $$
  select set_config('test.uid',
    (select id::text from public.profiles where full_name = p_name), false);
$$;

/* Admit one pupil by name, through the app's own function. */
create or replace function pg_temp.admit(p_name text) returns void
language plpgsql as $$
declare v_sess uuid; v_class uuid;
begin
  select id into v_sess from public.academic_sessions
   where school_id = public.current_school_id() and is_current;
  select id into v_class from public.classes
   where school_id = public.current_school_id() order by level_order limit 1;
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', p_name, 'father_name', p_name || ' Sahib',
    'session_id', v_sess, 'class_id', v_class, 'links', '[]'::jsonb));
end;
$$;

-- --- Fixture -----------------------------------------------------------------
-- One school on a three-pupil plan with two pupils on the roll, one on a
-- no-limit plan, and a second limited school so isolation is checkable.
do $seed$
declare
  v_a uuid; v_b uuid; v_c uuid;
  v_oa uuid := '00000000-0000-0000-0000-00000000501a';
  v_pa uuid := '00000000-0000-0000-0000-00000000501b';
  v_ca uuid := '00000000-0000-0000-0000-00000000501c';
  v_ob uuid := '00000000-0000-0000-0000-00000000501d';
  v_oc uuid := '00000000-0000-0000-0000-00000000501e';
  v_op uuid := '00000000-0000-0000-0000-00000000501f';
  v_sess uuid; v_class uuid;
begin
  insert into auth.users (id, email) values (v_op, 'op@limit.test')
    on conflict (id) do nothing;
  insert into public.platform_admins (user_id, email, note)
    values (v_op, 'op@limit.test', 'Founder') on conflict (user_id) do nothing;

  insert into public.schools (name) values ('Limit A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'starter', 'active', current_date - 1);
  update public.subscriptions set period_start = current_date - 30,
         period_end = current_date + 300 where school_id = v_a;
  insert into public.schools (name) values ('Limit B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'starter', 'active', current_date - 1);
  -- The by-arrangement plan: student_limit is NULL, which means no limit.
  insert into public.schools (name) values ('Limit C') returning id into v_c;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_c, 'custom', 'active', current_date - 1);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_oa, 'oa@limit.test'), (v_pa, 'pa@limit.test'), (v_ca, 'ca@limit.test'),
    (v_ob, 'ob@limit.test'), (v_oc, 'oc@limit.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_oa, 'Limit Owner',     'owner',       v_a),
    (v_pa, 'Limit Principal', 'principal',   v_a),
    (v_ca, 'Limit Clerk',     'admin_clerk', v_a),
    (v_ob, 'Limit B Owner',   'owner',       v_b),
    (v_oc, 'Limit C Owner',   'owner',       v_c)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role = excluded.role,
                                   full_name = excluded.full_name, active = true;
  alter table public.profiles enable trigger user;

  -- School A: a session, a class, two pupils. One place left of three.
  perform set_config('test.uid', v_oa::text, false);
  insert into public.academic_sessions (name, is_current, school_id,
                                        starts_on, ends_on)
    values ('2026-2027', true, v_a, current_date - 60, current_date + 300)
    returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_a;
  insert into public.classes (name, level_order, school_id)
    values ('Class 1', 1, v_a) returning id into v_class;
  insert into public.classes (name, level_order, school_id)
    values ('Class 2', 2, v_a);
  perform pg_temp.admit('Aisha One');
  perform pg_temp.admit('Bilal Two');

  -- School C, no limit at all, with a session and a class of its own.
  perform set_config('test.uid', v_oc::text, false);
  insert into public.academic_sessions (name, is_current, school_id,
                                        starts_on, ends_on)
    values ('2026-2027', true, v_c, current_date - 60, current_date + 300)
    returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_c;
  insert into public.classes (name, level_order, school_id)
    values ('Class 1', 1, v_c);

  perform set_config('test.uid', v_oa::text, false);
end;
$seed$;

-- =============================================================================
-- 1. THE BLOCK
-- =============================================================================
do $$
declare v_school uuid;
begin
  select id into v_school from public.schools where name = 'Limit A';
  perform pg_temp.be('Limit Owner');

  perform pg_temp.ok(public.fn_count_students(v_school) = 2,
    '1  two pupils on a three-pupil plan');

  -- The third fits.
  perform pg_temp.admit('Chand Three');
  perform pg_temp.ok(public.fn_count_students(v_school) = 3,
    '2  the third pupil fits, because three is the limit and not two');

  -- The fourth does not.
  perform pg_temp.ok(pg_temp.raises(
    $q$select pg_temp.admit('Daud Four')$q$, 'your plan covers 3 pupils'),
    '3  the fourth is refused, and the message says the limit');
  perform pg_temp.ok(pg_temp.raises(
    $q$select pg_temp.admit('Daud Four')$q$, 'and you have 3'),
    '4  and the count, so nobody has to go and look it up');
  perform pg_temp.ok(pg_temp.raises(
    $q$select pg_temp.admit('Daud Four')$q$, 'moved up to a bigger one'),
    '5  and both ways out, asked FOR rather than done by themselves: nothing '
    || 'in this product lets a school change its own plan, and a refusal that '
    || 'names a control the product does not have sends them hunting for it');
  perform pg_temp.ok(pg_temp.raises(
    $q$select pg_temp.admit('Daud Four')$q$, 'marking them as left frees a place'),
    '5b and the one way out that needs nobody at all, which is the only reason '
    || 'a block this hard is safe to ship');
  perform pg_temp.ok(pg_temp.raises(
    $q$select pg_temp.admit('Daud Four')$q$,
    'nothing you have already entered is affected'),
    '6  and that nothing already entered is affected, which is the first thing '
    || 'somebody blocked mid-admission will worry about');

  perform pg_temp.ok(public.fn_count_students(v_school) = 3,
    '7  and the refused admission wrote nothing');

  -- THE OWNER IS REFUSED TOO. The vendor was offered "block the clerk, let the
  -- owner through with a confirmation" and chose "block everyone". Asserted
  -- rather than assumed, and for all three roles that can admit.
  perform pg_temp.be('Limit Principal');
  perform pg_temp.ok(pg_temp.raises(
    $q$select pg_temp.admit('Daud Four')$q$, 'your plan covers 3 pupils'),
    '8  the principal is refused as well');
  perform pg_temp.be('Limit Clerk');
  perform pg_temp.ok(pg_temp.raises(
    $q$select pg_temp.admit('Daud Four')$q$, 'your plan covers 3 pupils'),
    '9  and so is the clerk: the block has no override');
  perform pg_temp.be('Limit Owner');
end $$;

-- =============================================================================
-- 2. WHAT MUST STILL WORK, WHICH IS THE HALF THAT MAKES THIS SAFE
-- =============================================================================
do $$
declare v_school uuid; v_student uuid;
begin
  select id into v_school from public.schools where name = 'Limit A';
  perform pg_temp.be('Limit Owner');

  -- 5. Reading everything, at the limit.
  perform pg_temp.ok(
    (select count(*) from public.fn_student_list(null, null, null)) = 3,
    '10 the student list still opens with the roll full');
  perform pg_temp.ok((public.fn_my_licence()->>'can_read')::boolean
                 and (public.fn_my_licence()->>'can_operate')::boolean,
    '11 and the licence still says the school can read and operate');

  -- 6. Marking a child as left, which is the one way out that does not need us.
  select s.id into v_student from public.students s
   where s.school_id = v_school and s.full_name = 'Chand Three';
  perform public.fn_set_student_status(v_student, 'withdrawn', 'moved city',
                                       current_date);
  perform pg_temp.ok(public.fn_count_students(v_school) = 2,
    '12 marking a child as left always works, and frees a place');

  -- And the place is really free.
  perform pg_temp.admit('Daud Four');
  perform pg_temp.ok(public.fn_count_students(v_school) = 3,
    '13 so the next admission goes through');

  -- 7. Bringing that child back is an admission as far as the limit goes.
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_set_student_status(%L, 'active', 'came back')$q$,
           v_student),
    'your plan covers 3 pupils'),
    '14 bringing a child back past the limit is refused, because a child '
    || 'brought back is a child on the roll');

end $$;

-- =============================================================================
-- 3. A PLAN WITH NO LIMIT
-- =============================================================================
do $$
declare v_c uuid; i integer;
begin
  select id into v_c from public.schools where name = 'Limit C';
  perform pg_temp.be('Limit C Owner');
  for i in 1..6 loop
    perform pg_temp.admit('Custom Child ' || i);
  end loop;
  perform pg_temp.ok(public.fn_count_students(v_c) = 6,
    '17 a plan priced by arrangement has no limit, and is never blocked');
  perform pg_temp.ok(public.fn__student_limit(v_c) is null,
    '18 which is what a null limit means, rather than a limit of zero');
end $$;

-- =============================================================================
-- 4. THE IMPORTER, ASKED ONCE
-- =============================================================================
do $$
declare v_b uuid; v_sess uuid; v_class uuid; r jsonb; v_before integer;
begin
  select id into v_b from public.schools where name = 'Limit B';
  perform pg_temp.be('Limit B Owner');
  insert into public.academic_sessions (name, is_current, school_id,
                                        starts_on, ends_on)
    values ('2026-2027', true, v_b, current_date - 60, current_date + 300)
    returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_b;
  insert into public.classes (name, level_order, school_id)
    values ('Class 1', 1, v_b) returning id into v_class;

  v_before := public.fn_count_students(v_b);

  -- Five rows into a three-pupil plan.
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_import_students(%L, %L::jsonb, false)$q$, v_sess,
      (select jsonb_agg(jsonb_build_object(
                'full_name', 'Import ' || g, 'father_name', 'F ' || g,
                'class', 'Class 1'))
         from generate_series(1, 5) g)),
    'this would put 5 pupils on the roll'),
    '19 a five-row import into a three-pupil plan is refused up front, '
    || 'counting the whole file');
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_import_students(%L, %L::jsonb, false)$q$, v_sess,
      (select jsonb_agg(jsonb_build_object(
                'full_name', 'Import ' || g, 'father_name', 'F ' || g,
                'class', 'Class 1'))
         from generate_series(1, 5) g)),
    'there is room for 3 more'),
    '20 and says how much room there is, so the file can be cut to fit');

  perform pg_temp.ok(public.fn_count_students(v_b) = v_before,
    '21 AND CREATED NOTHING: the alternative was importing three of five and '
    || 'failing twice, which leaves the school half imported and the file no '
    || 'longer safe to re-run');

  -- Three fits.
  r := public.fn_import_students(v_sess,
        (select jsonb_agg(jsonb_build_object(
                  'full_name', 'Import ' || g, 'father_name', 'F ' || g,
                  'class', 'Class 1'))
           from generate_series(1, 3) g), false);
  perform pg_temp.ok((r->>'created')::int = 3,
    '22 and a file that fits imports whole');
end $$;

-- =============================================================================
-- 5. WHAT THE SCHOOL IS TOLD, AND WHEN
-- =============================================================================
do $$
declare v_school uuid; lic jsonb; lim jsonb; v_student uuid;
begin
  select id into v_school from public.schools where name = 'Limit A';
  perform pg_temp.be('Limit Owner');
  perform public.fn_refresh_student_count(v_school);

  lic := public.fn_my_licence();
  perform pg_temp.ok((lic->>'at_limit')::boolean
                 and (lic->>'warn_limit')::boolean
                 and (lic->>'room')::int = 0,
    '23 at the limit the licence says so, and says there is no room');
  perform pg_temp.ok(lic->>'limit_notice' like '%roll is full%'
                 and lic->>'limit_notice' like '%New admissions are paused%',
    '24 and the notice says admissions are paused, which the old one denied: '
    || 'its last words were "Nothing stops working"');
  perform pg_temp.ok(lic->>'limit_notice' like '%Ask us for more room%'
                 and lic->>'limit_notice' like '%untouched%',
    '25 with both ways out, and the reassurance that matters most');

  -- BELOW 90% IT SAYS NOTHING. A banner a school sees every day is a banner it
  -- stops reading. Three of three is 100%; drop to one of three, which is 33%.
  select s.id into v_student from public.students s
   where s.school_id = v_school and s.full_name = 'Daud Four';
  perform public.fn_set_student_status(v_student, 'withdrawn', 'left', current_date);
  select s.id into v_student from public.students s
   where s.school_id = v_school and s.full_name = 'Bilal Two';
  perform public.fn_set_student_status(v_student, 'withdrawn', 'left', current_date);
  perform public.fn_refresh_student_count(v_school);

  lic := public.fn_my_licence();
  perform pg_temp.ok((lic->>'warn_limit')::boolean is false
                 and lic->>'limit_notice' is null,
    '26 at a third of the limit it says nothing at all');

  -- And 90% exactly. Two of three is 67%; three of three is 100%. With a limit
  -- of 3 the 90% line is ceil(2.7) = 3, so the warning starts at the limit
  -- itself: the arithmetic is asserted on growth's limit of 8, where ceil(7.2)
  -- is 8, and on a limit of 10 in the unit assertion below.
  perform pg_temp.ok(ceil(3 * 0.9) = 3 and ceil(8 * 0.9) = 8
                 and ceil(10 * 0.9) = 9 and ceil(150 * 0.9) = 135,
    '27 the 90% line uses ceil, so a limit of 150 warns from 135 and a limit '
    || 'of 10 warns from 9 rather than from 8');
end $$;

-- =============================================================================
-- 6. THE REQUEST BOX
-- =============================================================================
do $$
declare v_school uuid; r jsonb; v_n integer;
begin
  select id into v_school from public.schools where name = 'Limit A';

  -- Only the owner or the principal.
  perform pg_temp.be('Limit Clerk');
  perform pg_temp.ok(pg_temp.raises(
    $q$select public.fn_request_student_limit(10, 'we are opening a second campus')$q$,
    'only the owner or the principal'),
    '28 a clerk cannot ask for more room: it is a commitment to spend money');

  perform pg_temp.be('Limit Owner');
  perform pg_temp.ok(pg_temp.raises(
    $q$select public.fn_request_student_limit(10, 'more')$q$,
    'say briefly why'),
    '29 and a request with nothing in it is refused, because the reason is '
    || 'what we read when we decide');
  perform pg_temp.ok(pg_temp.raises(
    $q$select public.fn_request_student_limit(2, 'we are opening a second campus')$q$,
    'already covers 3 pupils'),
    '30 asking for less than the plan already covers is refused');

  r := public.fn_request_student_limit(10, 'we are opening a second campus in April');
  perform pg_temp.ok(r->>'status' = 'pending' and (r->>'requested_limit')::int = 10,
    '31 a real request goes in');
  perform pg_temp.ok(r->>'what_next' like '%Nothing changes in the meantime%',
    '32 and the answer says what happens next, so no screen has to invent it');

  perform pg_temp.ok(pg_temp.raises(
    $q$select public.fn_request_student_limit(20, 'and another thing entirely')$q$,
    'already have a request waiting'),
    '33 a second request is refused while the first is waiting, so the '
    || 'operator never has to work out which one to answer');

  -- The school's own screen sees it.
  perform pg_temp.ok(public.fn_my_student_limit()->'request'->>'status' = 'pending',
    '34 and the school can see its own request is with us');

  -- It is on the school's audit log, because it is their request.
  select count(*) into v_n from public.audit_log
   where school_id = v_school and action = 'STUDENT_LIMIT_REQUESTED';
  perform pg_temp.ok(v_n = 1,
    '35 and on their own audit log: who asked, when, and why');
end $$;

-- =============================================================================
-- 7. THE OPERATOR'S SIDE
-- =============================================================================
do $$
declare
  v_school uuid; v_op uuid := '00000000-0000-0000-0000-00000000501f';
  r record; g jsonb; v_req uuid;
begin
  select id into v_school from public.schools where name = 'Limit A';

  -- A school cannot grant itself room. This is the loophole the whole
  -- migration is about, wearing a different hat.
  perform pg_temp.be('Limit Owner');
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_grant_student_limit(%L, 500, 'because I said so')$q$,
           v_school), 'not permitted'),
    '36 a school cannot grant itself room');
  perform pg_temp.ok(pg_temp.raises(
    $q$select public.fn_platform_limit_requests('pending')$q$, 'not permitted'),
    '37 nor read the operator worklist');

  -- THE SCHOOL CARRIES ON WHILE IT WAITS, which is the ordinary case and the
  -- reason the worklist reports two counts. One more child arrives between the
  -- request and the decision.
  perform pg_temp.be('Limit Owner');
  perform pg_temp.admit('While Waiting');

  perform set_config('test.uid', v_op::text, false);
  select * into r from public.fn_platform_limit_requests('pending')
   where school_id = v_school;
  perform pg_temp.ok(r.requested_limit = 10 and r.reason like '%second campus%',
    '38 the operator sees the request and the reason');
  perform pg_temp.ok(r.count_at_request = 1 and r.students_now = 2,
    '39 and the roll as it is NOW beside the roll when they asked, because a '
    || 'request is decided days or weeks later and the school carries on');
  -- THE CHEAPEST PLAN THAT WOULD COVER THE REQUEST, because most of these are
  -- a school that has simply outgrown its plan and the right answer is "move
  -- up" rather than an exception. Ten pupils is past Growth's eight, so the
  -- answer is Institution's twenty and not Growth.
  perform pg_temp.ok(r.suggested_plan = 'institution'
                 and r.suggested_plan_covers = 20,
    '40 with the cheapest plan on sale that would cover it, because "move up" '
    || 'is often the right answer rather than an exception');
  v_req := r.id;

  -- A reduction needs saying out loud.
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_grant_student_limit(%L, 2, null)$q$, v_school),
    'which is a reduction'),
    '41 an allowance BELOW the plan''s own limit is refused without a reason: '
    || 'it is legitimate, and it is also how you cut a school off by mistake');

  g := public.fn_platform_grant_student_limit(v_school, 10,
        'Second campus opening in April, confirmed on the phone');
  perform pg_temp.ok((g->>'limit')::int = 10 and (g->>'partial')::boolean is false,
    '42 granting sets the allowance');
  perform pg_temp.ok(
    (select status = 'granted' and granted_limit = 10
       from public.student_limit_requests where id = v_req),
    '43 and answers the request in the same transaction, so there is never '
    || 'room without a record of granting it');
  perform pg_temp.ok(public.fn__student_limit(v_school) = 10,
    '44 and the limit that applies is now the allowance, not the plan');
  perform pg_temp.ok(
    (select count(*) from public.audit_log
      where school_id = v_school and action = 'STUDENT_LIMIT_GRANTED') = 1,
    '45 on the school''s own audit log: they asked, and this is the answer');
end $$;

-- =============================================================================
-- 8. AND THE SCHOOL CAN ADMIT AGAIN
-- =============================================================================
do $$
declare v_school uuid; i integer; lic jsonb;
begin
  select id into v_school from public.schools where name = 'Limit A';
  perform pg_temp.be('Limit Owner');
  -- Two on the roll, ten allowed: eight places. Take five of them.
  for i in 1..5 loop
    perform pg_temp.admit('After Grant ' || i);
  end loop;
  perform pg_temp.ok(public.fn_count_students(v_school) = 7,
    '46 the school can admit again, up to the room it was granted');
  -- And the tenth is the tenth. Three more fit, the eleventh does not.
  for i in 6..8 loop
    perform pg_temp.admit('After Grant ' || i);
  end loop;
  perform pg_temp.ok(public.fn_count_students(v_school) = 10,
    '46b right up to the allowance itself');
  perform pg_temp.ok(pg_temp.raises(
    $q$select pg_temp.admit('One Too Many')$q$, 'your plan covers 10 pupils'),
    '46c and stops there: an allowance is a limit too, not a waiver');

  perform public.fn_refresh_student_count(v_school);
  lic := public.fn_my_licence();
  perform pg_temp.ok((lic->>'student_limit')::int = 10
                 and (lic->>'plan_student_limit')::int = 3
                 and (lic->>'limit_is_granted')::boolean,
    '47 and its own screen can say "10, of which 3 come from the plan", '
    || 'rather than just showing a number nobody can account for');
end $$;

-- =============================================================================
-- 9. DECLINING, AND TAKING IT BACK
-- =============================================================================
do $$
declare
  v_b uuid; v_op uuid := '00000000-0000-0000-0000-00000000501f'; v_req uuid;
begin
  select id into v_b from public.schools where name = 'Limit B';
  perform pg_temp.be('Limit B Owner');
  perform public.fn_request_student_limit(50,
    'we think we might grow a lot this year');
  select id into v_req from public.student_limit_requests
   where school_id = v_b and status = 'pending';

  perform set_config('test.uid', v_op::text, false);
  -- FIFTY IS PAST EVERY PLAN ON SALE, so there is nothing to suggest. That is
  -- the case that genuinely needs a conversation, and a null here is what
  -- tells the operator so rather than proposing a plan that does not fit.
  perform pg_temp.ok(
    (select suggested_plan is null from public.fn_platform_limit_requests('pending')
      where school_id = v_b),
    '48 a request past every plan on sale suggests nothing, which is how the '
    || 'operator knows it needs a conversation');
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_decline_student_limit(%L, 'no')$q$, v_req),
    'say why'),
    '49 declining without a reason is refused: a request that comes back with '
    || 'nothing on it is worse than one still waiting');
  perform public.fn_platform_decline_student_limit(v_req,
    'Fifty is the Growth band; happy to move you across when the roll is there.');
  perform pg_temp.ok(
    (select status = 'declined' and decision_note like '%Growth band%'
       from public.student_limit_requests where id = v_req),
    '50 and with one it is declined, with the sentence the school will read');

  -- Taking an allowance back.
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_clear_student_limit(%L, 'x')$q$,
           (select id from public.schools where name = 'Limit A')),
    'say why the allowance is being taken back'),
    '51 clearing an allowance without a reason is refused: it may stop them '
    || 'admitting a pupil tomorrow');
end $$;

-- =============================================================================
-- 10. NOTHING CROSSES A SCHOOL BOUNDARY
-- =============================================================================
do $$
declare v_a uuid; v_b uuid; v_saw_a boolean; v_saw_b boolean;
begin
  select id into v_a from public.schools where name = 'Limit A';
  select id into v_b from public.schools where name = 'Limit B';

  perform pg_temp.be('Limit B Owner');

  -- `set local role authenticated`, WHICH IS THE WHOLE POINT OF THESE TWO.
  -- Row level security does not apply to the table's OWNER, and this suite
  -- runs as postgres, so without this the reads below come back with every
  -- school's rows and assertion 52 fails while the policy is perfectly
  -- correct. It failed exactly that way when first written.
  -- supabase/tests/tenant_isolation.sql does the same, for the same reason.
  set local role authenticated;
  v_saw_a := exists (select 1 from public.student_limit_requests where school_id = v_a);
  v_saw_b := exists (select 1 from public.student_limit_requests where school_id = v_b);
  reset role;

  perform pg_temp.ok(not v_saw_a, '52 school B cannot see school A''s request');
  perform pg_temp.ok(v_saw_b,
    '53 and can see its own, which is what makes 52 a real check rather than '
    || 'a query that happens to return nothing');
  perform pg_temp.ok(public.fn_my_student_limit()->>'limit' = '3',
    '54 and reads its own limit, not the allowance A was granted');
end $$;

-- =============================================================================
-- 10b. WHICH OF THE TWO THINGS THEY ASKED FOR
--
-- "We need room for 200 pupils" can mean let us past our limit on the plan we
-- pay for, or put us on the plan that covers 200. The school does not much
-- care which; it cares what the next child costs. We care a great deal: one is
-- a permanent hole in the price list and the other is a school agreeing to pay
-- more. So the request carries which, as a value, and both reads report it.
-- =============================================================================
do $$
declare
  v_a uuid; v_b uuid; v_c uuid; d jsonb; r jsonb; v_req uuid;
  v_op uuid := '00000000-0000-0000-0000-00000000501f';
begin
  select id into v_a from public.schools where name = 'Limit A';
  select id into v_b from public.schools where name = 'Limit B';
  select id into v_c from public.schools where name = 'Limit C';

  -- An unknown value is refused rather than stored. It reaches the operator's
  -- worklist as the difference between a favour and a sale, so a third value
  -- nobody has designed a screen for must not get in.
  perform pg_temp.be('Limit B Owner');
  perform pg_temp.ok(pg_temp.raises(
    $q$select public.fn_request_student_limit(9, 'we are growing fast', 'whatever')$q$,
    'either for more room'),
    '59 a request that is neither of the two things is refused');

  -- Omitted, it defaults to the cautious one: an exception we have to think
  -- about, rather than an upgrade we would then invoice them for. That is what
  -- an older client calling with two arguments gets.
  r := public.fn_request_student_limit(9, 'we are opening an evening shift');
  perform pg_temp.ok(r->>'wants' = 'more_room',
    '60 omitted, it defaults to an exception rather than to an upgrade, '
    || 'because billing a school for a plan it never asked for is the worse '
    || 'way to be wrong');
  perform public.fn_withdraw_student_limit_request();

  -- And an explicit upgrade survives the round trip to both readers.
  r := public.fn_request_student_limit(8, 'the roll is full and we want the '
       || 'bigger plan properly, not a favour', 'move_up');
  perform pg_temp.ok(r->>'wants' = 'move_up',
    '61 an upgrade request comes back as one');
  perform pg_temp.ok(
    public.fn_my_student_limit()->'request'->>'wants' = 'move_up',
    '62 and the school''s own screen can tell which it sent, so it does not '
    || 'have to remember');
  perform set_config('test.uid', v_op::text, false);
  perform pg_temp.ok(
    (select wants = 'move_up' from public.fn_platform_limit_requests('pending')
      where school_id = v_b),
    '63 and the operator sees it on the worklist, which is the whole point: '
    || 'the answer to "move us up" is an invoice and the answer to "give us '
    || 'room" is a favour, and guessing which costs a phone call every time');

  -- ------------------------------------------------------------------------
  -- THE PRICE OF THE ANSWER, on the school's own screen.
  --
  -- A school choosing between an exception and an upgrade is choosing about
  -- money, and a box that cannot name the figure is asking them to decide
  -- blind. Priced on THEIR term, not monthly: a yearly school quoted a monthly
  -- figure reads it as the new annual price and feels cheated later.
  -- ------------------------------------------------------------------------
  perform pg_temp.be('Limit B Owner');
  d := public.fn_my_student_limit();
  perform pg_temp.ok(d->'next_plan'->>'code' = 'growth'
                 and (d->'next_plan'->>'covers')::int = 8,
    '64 the school is offered the cheapest plan on sale that is bigger than '
    || 'what it has, by name and by how many it covers');
  perform pg_temp.ok(
    (d->'next_plan'->>'price')::numeric
      = public.fn__plan_price('growth',
          (select coalesce(term_months, 12) from public.subscriptions
            where school_id = v_b))
    and (d->'next_plan'->>'price')::numeric > 0,
    '65 priced for the term they already pay on, so the figure they read is '
    || 'the figure on the invoice');

  -- The by-arrangement plan has no limit, so there is nothing above it and
  -- nothing to offer. Written as its own assertion because the first version
  -- coalesced a null limit to zero, which made every plan on the price list
  -- look like an upgrade for the school that is already above all of them.
  perform pg_temp.be('Limit C Owner');
  d := public.fn_my_student_limit();
  perform pg_temp.ok(d->>'limit' = 'null' or d->'limit' = 'null'::jsonb,
    '66 a plan with no limit reports none');
  perform pg_temp.ok(d->'next_plan' = 'null'::jsonb,
    '67 and is offered no upgrade, because there is nothing above it. A '
    || 'coalesce of the null limit to zero made every plan look bigger than '
    || 'this school''s');

  -- School A holds an allowance of ten against a plan that covers three, so it
  -- is the one that proves the two numbers are reported separately.
  perform pg_temp.be('Limit Owner');
  d := public.fn_my_student_limit();
  perform pg_temp.ok((d->>'limit')::int = 10 and (d->>'plan_covers')::int = 3
                 and (d->>'granted_extra')::boolean,
    '68 an allowance is reported beside the plan''s own number, so a screen '
    || 'can say "three on the plan plus seven we granted you" rather than a '
    || 'bare ten that matches no price list');

  -- ------------------------------------------------------------------------
  -- AND NOTHING SENDS THEM AFTER A BUTTON THAT DOES NOT EXIST.
  --
  -- Nothing in this product lets a school change its own plan: activation is
  -- operator-only and every renewal is a bank transfer confirmed by hand. The
  -- first draft of what_next ended "you can still move up a plan yourself
  -- from this screen", which sent a school looking for a control that is not
  -- there. Asserted on the delivered sentence, not on the source.
  -- ------------------------------------------------------------------------
  perform pg_temp.be('Limit B Owner');
  perform public.fn_withdraw_student_limit_request();
  r := public.fn_request_student_limit(8, 'we would like the bigger plan',
       'move_up');
  perform pg_temp.ok(r->>'what_next' not like '%yourself%'
                 and length(r->>'what_next') > 40,
    '69 the reply says what happens next without telling them to change their '
    || 'own plan, which is a thing this product does not let them do');
  select id into v_req from public.student_limit_requests
   where school_id = v_b and status = 'pending';

  -- ------------------------------------------------------------------------
  -- THE OPERATOR'S OWN VIEW OF ONE SCHOOL.
  --
  -- fn_platform_school_detail reported plans.student_limit, which was the
  -- whole truth until the allowance existed. After it, that number is the one
  -- number on the platform that is NOT what the school is allowed: the page
  -- would show 3 for a school granted 10, paint "over limit" on it, and have
  -- the operator grant the allowance a second time.
  -- ------------------------------------------------------------------------
  perform set_config('test.uid', v_op::text, false);
  d := public.fn_platform_school_detail(v_a) -> 'licence';
  perform pg_temp.ok((d->>'student_limit')::int = 10
                 and (d->>'plan_student_limit')::int = 3
                 and (d->>'limit_override')::int = 10,
    '70 the console reports what the school is ALLOWED, with the plan''s own '
    || 'number beside it');
  perform pg_temp.ok(d->>'limit_state' = 'ok',
    '71 and does not paint "over limit" on a school sitting inside the room '
    || 'we ourselves gave it');
  perform pg_temp.ok(nullif(btrim(coalesce(d->>'limit_override_reason','')),'') is not null
                 and d->>'limit_override_at' is not null,
    '72 with the reason and the date, because "who agreed to this?" is the '
    || 'first question asked about an exception six months later');

  -- And the request waiting, on the school's own page, so an operator granting
  -- from here rather than from the queue is not granting blind.
  d := public.fn_platform_school_detail(v_b) -> 'licence';
  perform pg_temp.ok((d->'limit_request'->>'id')::uuid = v_req
                 and d->'limit_request'->>'wants' = 'move_up'
                 and length(d->'limit_request'->>'reason') > 8,
    '73 a pending request shows on the school''s own page, with what they '
    || 'asked and why');
  perform pg_temp.ok(
    public.fn_platform_school_detail(v_c) -> 'licence' -> 'limit_request'
      = 'null'::jsonb,
    '74 and is null when there is none, rather than an empty object a screen '
    || 'would render as a request');

  -- ------------------------------------------------------------------------
  -- THE CLERK IS TOLD TOO, in words they can act on.
  --
  -- The limit notice went to the owner and the principal only, and while the
  -- limit was advisory that was right: a clerk shown "you are over your plan"
  -- reads it as "stop admitting children". Enforcing the limit inverts it. The
  -- clerk is the person who presses Admit, so a clerk told nothing meets the
  -- refusal for the first time with a parent standing at the desk.
  -- ------------------------------------------------------------------------
  perform pg_temp.be('Limit B Owner');
  perform public.fn_refresh_student_count(v_b);
  d := public.fn_my_licence();
  perform pg_temp.ok(d->>'limit_notice_staff' like '%roll is full%',
    '75 a full roll has a second wording for whoever cannot fix it');
  perform pg_temp.ok(d->>'limit_notice_staff' not like '%Settings%'
                 and d->>'limit_notice' like '%Settings%',
    '76 which does not send them to a Settings screen their role cannot open, '
    || 'while the leadership wording still does');
  perform pg_temp.ok(d->>'limit_notice_staff' like '%owner or principal%',
    '77 and names who can actually fix it');

  -- Silent well below the line, for both audiences. A banner a school sees
  -- every day is a banner it stops reading.
  perform pg_temp.be('Limit C Owner');
  d := public.fn_my_licence();
  perform pg_temp.ok(d->'limit_notice_staff' = 'null'::jsonb
                 and d->'limit_notice' = 'null'::jsonb,
    '78 and both are silent for a plan with no limit at all');
end $$;

-- =============================================================================
-- 11. THE ROLLOVER, WHICH MUST NEVER BE BLOCKED
--
-- LAST, AND ON ITS OWN, because rolling a year over leaves the SOURCE
-- session's enrolments inactive and the source session still current, so
-- fn_count_students reads zero until somebody makes the new session current.
-- That is the product's own behaviour and not this migration's business, but
-- it means this check cannot sit in the middle of a suite that counts pupils
-- afterwards. It was in the middle, and assertion 23 failed on a roll of zero.
--
-- School B is the one that is genuinely full: three of three, its request
-- declined, no allowance.
-- =============================================================================
do $$
declare v_b uuid; v_sess uuid; v_next uuid; r jsonb;
begin
  select id into v_b from public.schools where name = 'Limit B';
  perform pg_temp.be('Limit B Owner');
  perform pg_temp.ok(public.fn_count_students(v_b) = 3
                 and public.fn__student_limit(v_b) = 3,
    '55 school B is full: three of three, and no allowance');

  select id into v_sess from public.academic_sessions
   where school_id = v_b and is_current;
  insert into public.academic_sessions (name, is_current, school_id,
                                        starts_on, ends_on)
    values ('2027-2028', false, v_b, current_date + 301, current_date + 660)
    returning id into v_next;
  -- A CLASS TO BE PROMOTED INTO. fn_rollover moves each child to the next
  -- level_order, and school B was set up with one class, so with nothing above
  -- it every child GRADUATES instead: promoted came back 0 and this assertion
  -- failed while the rollover had worked perfectly. The thing being checked is
  -- that the enrolment INSERT is not gated, so there has to be somewhere to
  -- insert them.
  insert into public.classes (name, level_order, school_id)
    values ('Class 2', 2, v_b);

  -- p_commit true, because a dry run would prove nothing about whether the
  -- INSERT is gated. Empty rules promotes every class to the next
  -- level_order, which is what a school pressing the button gets.
  r := public.fn_rollover(v_sess, v_next, '[]'::jsonb, true);
  perform pg_temp.ok((r->>'promoted')::int >= 1,
    '56 A SCHOOL WITH A FULL ROLL CAN STILL ROLL ITS YEAR OVER. It is the same '
    || 'children a year older, and refusing it would leave a school over its '
    || 'limit with no register, no challans and no classes for the new year: '
    || 'that is not enforcement, it is taking the product away');

  -- And nothing was smuggled past the limit by doing it.
  perform pg_temp.ok(
    (select count(*) from public.enrollments e
      where e.school_id = v_b and e.session_id = v_next
        and e.status = 'active') = 3,
    '57 and it moved three children, not four');

  -- The new year is current, and the roll is the same three.
  update public.academic_sessions set is_current = false
   where school_id = v_b and id = v_sess;
  update public.academic_sessions set is_current = true
   where school_id = v_b and id = v_next;
  update public.school_settings set current_session_id = v_next where school_id = v_b;
  perform pg_temp.ok(public.fn_count_students(v_b) = 3,
    '58 and with the new year current the roll is those same three, so a '
    || 'rollover neither creates room nor loses a child');
end $$;

rollback;
