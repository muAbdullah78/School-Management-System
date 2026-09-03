-- =============================================================================
-- When a child leaves.
--
-- fn_set_student_status is how children leave a school, and it drives billing.
-- Until 0054 it had NO test suite at all. Writing one found two defects and
-- pinned two behaviours that already worked and were one careless
-- `create or replace` away from breaking silently.
--
-- The rules this file defends:
--
--  1. WITHDRAWN AND STRUCK OFF ARE DIFFERENT THINGS. The UI offered only
--     "Strike off", so a child whose family moved city was recorded as removed
--     for non-payment or misconduct. Both statuses must reach the enrollment
--     with the right meaning ('left' vs 'struck_off').
--  2. LEAVING STOPS THE BILLING. fn_generate_class_invoices filters
--     enrollments.status, so the mirror onto the enrollment is what stops a
--     school chasing a parent for a child who is not there. Asserted by
--     generating invoices for the class and counting.
--  3. LEAVING STOPS THE PLAN COUNT. fn_count_students requires BOTH statuses
--     active. Asserted through fn_count_students, not by reading columns.
--  4. THE TWO FACTS CANNOT CONTRADICT. Reinstating a graduated child used to
--     leave students.status = 'active' with the enrollment still 'graduated' —
--     a child reading as a current pupil while in no class, billed nothing and
--     counted against no plan limit. It is now refused, and the refusal leaves
--     NOTHING behind.
--  5. THERE IS A DATE, AND SOMETHING READS IT. left_on was the point of 0054;
--     a column written and never shown is the bug class documented in 0047, so
--     fn_students_left is tested as hard as the writer.
--  6. ARREARS ARE OFFICE BUSINESS. The report carries what each child left
--     owing, so a class teacher is refused it.
--  7. Nothing crosses a school boundary.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/student_status.sql
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

create or replace function pg_temp.refuses(p_sql text, p_label text, p_expect text default null)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if p_expect is not null and sqlerrm not like p_expect then
      raise exception 'FAIL  % — refused, but with the wrong message: %', p_label, sqlerrm;
    end if;
    raise notice 'PASS  % (%)', p_label, sqlerrm;
    return;
  end;
  raise exception 'FAIL  % — it was ALLOWED', p_label;
end;
$$;

create or replace function pg_temp.stu(p_name text) returns uuid language sql as $$
  select id from public.students where full_name = p_name and deleted_at is null
$$;

create or replace function pg_temp.enr_status(p_name text) returns text language sql as $$
  select e.status::text
  from public.students s
  join public.enrollments e on e.student_id = s.id
  join public.academic_sessions ses on ses.id = e.session_id and ses.is_current
  where s.full_name = p_name
$$;

-- --- Fixture -----------------------------------------------------------------
-- One class, four children: one to withdraw, one to strike off, one to graduate
-- and one to leave alone as a control. A monthly fee structure, so rule 2 has
-- money to move.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_own   uuid := '00000000-0000-0000-0000-00000000ab01';
  v_prin  uuid := '00000000-0000-0000-0000-00000000ab02';
  v_clerk uuid := '00000000-0000-0000-0000-00000000ab03';
  v_tch   uuid := '00000000-0000-0000-0000-00000000ab04';
  v_par   uuid := '00000000-0000-0000-0000-00000000ab05';
  v_ownb  uuid := '00000000-0000-0000-0000-00000000ab06';
  v_sess uuid; v_cl uuid; v_sec uuid; v_head uuid;
  v_sess_b uuid; v_cl_b uuid;
begin
  insert into public.schools (name) values ('Leave Stu A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);
  insert into public.schools (name) values ('Leave Stu B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'growth', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_own,'so@ls.test'), (v_prin,'sp@ls.test'), (v_clerk,'sc@ls.test'),
    (v_tch,'st@ls.test'), (v_par,'spa@ls.test'), (v_ownb,'sb@ls.test')
  on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_own,   'Ls Owner',     'owner',         v_a),
    (v_prin,  'Ls Principal', 'principal',     v_a),
    (v_clerk, 'Ls Clerk',     'admin_clerk',   v_a),
    (v_tch,   'Ls Teacher',   'class_teacher', v_a),
    (v_par,   'Ls Parent',    'parent',        v_a),
    (v_ownb,  'Ls Owner B',   'owner',         v_b)
  on conflict (id) do update set school_id = excluded.school_id,
                                 role      = excluded.role,
                                 full_name = excluded.full_name,
                                 active    = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_own::text, false);

  insert into public.academic_sessions (name, starts_on, ends_on, is_current, school_id)
    values ('2025-2026', current_date - 200, current_date + 160, true, v_a)
    returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_a;
  insert into public.classes (name, level_order, school_id)
    values ('Class 5', 5, v_a) returning id into v_cl;
  insert into public.sections (class_id, name, sort_order, school_id)
    values (v_cl, 'A', 1, v_a) returning id into v_sec;
  insert into public.fee_heads (name, type, is_recurring, sort_order, school_id)
    values ('Tuition', 'monthly', true, 10, v_a) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_cl, v_head, 3000, v_a);

  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Moved Away','father_name','Moved Father','father_cnic','35201-3000001-1',
    'phone','0300-100 0001','admission_date',(current_date - 190)::date,
    'session_id',v_sess,'class_id',v_cl,'section_id',v_sec,'roll_no','1','links','[]'::jsonb));
  -- Month-aligned to THE LEAVING DATE, not to today, and that distinction is the
  -- whole point.
  --
  -- months_here is a pure calendar-month difference (0054: year*12 + month, on
  -- both dates), so only the MONTHS of the two dates matter. This aligned the
  -- admission to date_trunc('month', current_date) while the leaving date is
  -- current_date - 2, so on the 1st and 2nd of any month the leaving date fell
  -- into the PREVIOUS month and the span came out as five, not six. Measured
  -- over 2026: assertion 35 failed on 24 of 365 days, every 1st and every 2nd.
  -- It failed a real CI run on 2 September.
  --
  -- Aligning to (current_date - 2) makes the span exactly six calendar months by
  -- construction. Measured over 1,096 days from 2026 to 2028: zero failures.
  --
  -- This is the fifth time this project has pinned an assertion to something
  -- that moves with the calendar. Assertion 38 below carries the comment about
  -- the previous four, and its author was right to; this line was written under
  -- that same comment and still got it wrong, because it protected one of the
  -- two dates and forgot the other.
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Struck Child','father_name','Struck Father','father_cnic','35201-3000002-2',
    'phone','0300-100 0002',
    'admission_date',(date_trunc('month', current_date - 2) - interval '6 months')::date,
    'session_id',v_sess,'class_id',v_cl,'section_id',v_sec,'roll_no','2','links','[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Grad Child','father_name','Grad Father','father_cnic','35201-3000003-3',
    'admission_date',(current_date - 170)::date,
    'session_id',v_sess,'class_id',v_cl,'section_id',v_sec,'roll_no','3','links','[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Stays Here','father_name','Stays Father','father_cnic','35201-3000004-4',
    'admission_date',(current_date - 160)::date,
    'session_id',v_sess,'class_id',v_cl,'section_id',v_sec,'roll_no','4','links','[]'::jsonb));

  -- Two jobs. It is a child who left BEFORE 0054 existed — a status but no date
  -- — which assertion 30 excludes from the report. And because the UPDATE
  -- bypasses fn_set_student_status, its ENROLLMENT is left 'active' while the
  -- student says 'withdrawn': the two facts out of step, which is the state
  -- 0054's join in fn_generate_class_invoices exists to catch (assertion 16).
  -- No function can produce this any more, which is precisely why it is written
  -- by hand: a guard nothing can reach is a guard nothing tests.
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Legacy Leaver','father_name','Legacy Father','father_cnic','35201-3000005-5',
    'admission_date',(current_date - 400)::date,
    'session_id',v_sess,'class_id',v_cl,'roll_no','5','links','[]'::jsonb));
  update public.students set status = 'withdrawn'
   where full_name = 'Legacy Leaver' and school_id = v_a;

  -- One month billed, and one child pays part of it, so the report has a real
  -- arrears figure to carry.
  perform public.fn_generate_class_invoices(v_sess, v_cl,
    (date_trunc('month', current_date) - interval '1 month')::date, current_date - 10);
  perform public.fn_record_payment(pg_temp.stu('Moved Away'), 1000, 'cash', 'part');

  -- School B, with its own leaver, so a leak would be obvious.
  perform set_config('test.uid', v_ownb::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_b) returning id into v_sess_b;
  update public.school_settings set current_session_id = v_sess_b where school_id = v_b;
  insert into public.classes (name, level_order, school_id)
    values ('B Five', 5, v_b) returning id into v_cl_b;
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','B Leaver','father_name','B Father','father_cnic','35201-9000001-1',
    'session_id',v_sess_b,'class_id',v_cl_b,'roll_no','1','links','[]'::jsonb));
  perform public.fn_set_student_status(pg_temp.stu('B Leaver'), 'withdrawn', 'B reason');

  perform set_config('test.uid', v_own::text, false);
end;
$seed$;

-- =============================================================================
-- 1. Who may do this
-- =============================================================================
do $$
declare v_id uuid := pg_temp.stu('Moved Away');
begin
  perform pg_temp.be('Ls Clerk');
  perform pg_temp.refuses(
    format('select public.fn_set_student_status(%L::uuid, ''withdrawn'', null, current_date)', v_id),
    '1. a clerk may not remove a child from the roll', '%owner or principal%');
  perform pg_temp.be('Ls Teacher');
  perform pg_temp.refuses(
    format('select public.fn_set_student_status(%L::uuid, ''withdrawn'', null, current_date)', v_id),
    '2. nor a class teacher', '%owner or principal%');
  perform pg_temp.be('Ls Parent');
  perform pg_temp.refuses(
    format('select public.fn_set_student_status(%L::uuid, ''withdrawn'', null, current_date)', v_id),
    '3. nor a parent', '%owner or principal%');
end;
$$;

-- =============================================================================
-- 2. The dates have to make sense
-- =============================================================================
do $$
declare v_id uuid := pg_temp.stu('Moved Away');
begin
  perform pg_temp.be('Ls Principal');
  perform pg_temp.refuses(
    format('select public.fn_set_student_status(%L::uuid, ''withdrawn'', null, current_date + 3)', v_id),
    '4. a last day in the future is refused', '%cannot be in the future%');
  perform pg_temp.refuses(
    format('select public.fn_set_student_status(%L::uuid, ''withdrawn'', null, current_date - 500)', v_id),
    '5. a last day before the admission date is a typo', '%before the admission date%');
end;
$$;

-- =============================================================================
-- 3. Withdrawn and struck off are different things
-- =============================================================================
do $$
declare
  v_moved uuid := pg_temp.stu('Moved Away');
  v_struck uuid := pg_temp.stu('Struck Child');
  j jsonb; n integer;
begin
  perform pg_temp.be('Ls Principal');

  n := public.fn_count_students(public.current_school_id());
  perform pg_temp.ok(n = 4,
    '6. four of the five children count on the roll — the legacy row already '
    'says withdrawn (got ' || n || ')');

  j := public.fn_set_student_status(v_moved, 'withdrawn', 'Family moved to Karachi',
                                   current_date - 5);
  perform pg_temp.ok(j->>'status' = 'withdrawn' and (j->>'left_on')::date = current_date - 5,
    '7. withdrawing reports the status and the date back');
  perform pg_temp.ok(j->>'class_name' = 'Class 5-A',
    '8. and which class they were in, for the register (got ' || (j->>'class_name') || ')');

  perform pg_temp.ok(pg_temp.enr_status('Moved Away') = 'left',
    '9. WITHDRAWN reaches the enrollment as ''left'', not ''struck_off'' — the '
    'distinction a parent would read on a leaving certificate (got '
      || pg_temp.enr_status('Moved Away') || ')');

  perform public.fn_set_student_status(v_struck, 'struck_off', 'Fees unpaid for four months',
                                       current_date - 2);
  perform pg_temp.ok(pg_temp.enr_status('Struck Child') = 'struck_off',
    '10. STRUCK OFF reaches the enrollment as ''struck_off''');

  select count(*) into n from public.students
   where id = v_moved and left_on = current_date - 5
     and leaving_reason = 'Family moved to Karachi';
  perform pg_temp.ok(n = 1,
    '11. the date and the reason are COLUMNS now, not free text buried in notes');

  perform pg_temp.ok(
    (select notes from public.students where id = v_moved) like '%Family moved to Karachi%',
    '12. the notes narrative is kept too — it is the only history older rows have');
end;
$$;

-- =============================================================================
-- 4. Leaving stops the money
-- =============================================================================
do $$
declare
  v_sess uuid; v_cl uuid; n integer; v_moved uuid := pg_temp.stu('Moved Away');
begin
  perform pg_temp.be('Ls Principal');
  select id into v_sess from public.academic_sessions
   where is_current and school_id = public.current_school_id();
  select id into v_cl from public.classes
   where name = 'Class 5' and school_id = public.current_school_id();

  n := public.fn_count_students(public.current_school_id());
  perform pg_temp.ok(n = 2,
    '13. the plan count drops as children leave — asserted through '
    'fn_count_students, not by reading a column (got ' || n || ')');

  -- Five children: two have just left, one is the divergent legacy row, two
  -- remain billable.
  n := public.fn_generate_class_invoices(v_sess, v_cl,
         date_trunc('month', current_date)::date, current_date + 7);
  perform pg_temp.ok(n = 2,
    '14. this month bills only the children still here (got ' || n || ' of 5)');

  select count(*) into n from public.invoices
   where student_id = v_moved and period_month = date_trunc('month', current_date)::date;
  perform pg_temp.ok(n = 0,
    '15. the withdrawn child is not billed — the whole reason the enrollment '
    'mirror matters, since fn_generate_class_invoices reads enrollments.status');

  -- The legacy row's enrollment still says 'active'. Before 0054 added the
  -- students join, THIS is the child who would have been billed after leaving.
  select count(*) into n from public.invoices
   where student_id = pg_temp.stu('Legacy Leaver');
  perform pg_temp.ok(n = 0,
    '16. a child whose enrollment and student record DISAGREE is not billed '
    'either — the enrollment says active, the child says withdrawn, and 0054 '
    'makes the two agree before any money is raised');

  -- Last month's invoice, raised while they were here, stands.
  select count(*) into n from public.invoices where student_id = v_moved;
  perform pg_temp.ok(n = 1,
    '16b. but the month they WERE here is not erased — a school still chases '
    'what was owed on the day they left');
end;
$$;

-- =============================================================================
-- 5. The two facts cannot contradict — and the refusal leaves nothing behind
-- =============================================================================
do $$
declare v_grad uuid := pg_temp.stu('Grad Child'); v_status text; v_left date;
begin
  perform pg_temp.be('Ls Owner');
  perform public.fn_set_student_status(v_grad, 'graduated', 'Finished class 5',
                                       current_date - 1);
  perform pg_temp.ok(pg_temp.enr_status('Grad Child') = 'graduated',
    '17. graduating reaches the enrollment');

  -- Before 0054 this SUCCEEDED and produced students.status = 'active' with the
  -- enrollment still 'graduated': a child reading as a current pupil while in
  -- no class, billed nothing, and counted against no plan limit.
  perform pg_temp.refuses(
    format('select public.fn_set_student_status(%L::uuid, ''active'', ''Staying on'', current_date)', v_grad),
    '18. a graduated child cannot be made active by flipping a status',
    '%no place in the current session%');

  perform pg_temp.refuses(
    format('select public.fn_set_student_status(%L::uuid, ''active'', null, current_date)', v_grad),
    '19. and the refusal NAMES the enrollment status, so the message is actionable',
    '%is graduated%');

  select status::text, left_on into v_status, v_left
    from public.students where id = v_grad;
  perform pg_temp.ok(v_status = 'graduated',
    '20. the refusal rolled the status change back (got ' || v_status || ')');
  perform pg_temp.ok(v_left = current_date - 1,
    '21. and did not clear the leaving date on the way past');
  perform pg_temp.ok(pg_temp.enr_status('Grad Child') = 'graduated',
    '22. and left the enrollment alone');
end;
$$;

-- =============================================================================
-- 6. Coming back
-- =============================================================================
do $$
declare v_moved uuid := pg_temp.stu('Moved Away'); j jsonb; n integer;
begin
  perform pg_temp.be('Ls Owner');
  j := public.fn_set_student_status(v_moved, 'active', 'Family came back', current_date);
  perform pg_temp.ok(j->>'left_on' is null,
    '23. reinstating reports no leaving date');

  select count(*) into n from public.students
   where id = v_moved and status = 'active' and left_on is null and leaving_reason is null;
  perform pg_temp.ok(n = 1, '24. and clears both columns');
  perform pg_temp.ok(pg_temp.enr_status('Moved Away') = 'active',
    '25. and puts them back in their class');

  n := public.fn_count_students(public.current_school_id());
  perform pg_temp.ok(n = 2, '26. so they count toward the plan again (got ' || n || ')');

  perform pg_temp.refuses(
    format('select public.fn_set_student_status(%L::uuid, ''active'', null, current_date)', v_moved),
    '27. setting the status it already has is refused rather than silently '
    'rewriting the record', '%already active%');
end;
$$;

-- =============================================================================
-- 7. The report — without which left_on is one more column nothing shows
-- =============================================================================
do $$
declare r record; n integer;
begin
  perform pg_temp.be('Ls Owner');

  select count(*) into n from public.fn_students_left(null, null);
  perform pg_temp.ok(n = 2,
    '28. the report names the two children who left WITH a date — struck off '
    'and graduated (got ' || n || ')');

  perform pg_temp.ok(
    not exists (select 1 from public.fn_students_left(null, null)
                 where student_name = 'Moved Away'),
    '29. and not the one who came back');

  perform pg_temp.ok(
    not exists (select 1 from public.fn_students_left(null, null)
                 where student_name = 'Legacy Leaver'),
    '30. nor the pre-0054 row that has a status but no date — the exclusion is '
    'explicit, because inventing a date for it would be a lie in a field a '
    'school may rely on');

  select * into r from public.fn_students_left(null, null)
   where student_name = 'Struck Child';
  perform pg_temp.ok(r.status = 'struck_off' and r.reason = 'Fees unpaid for four months',
    '31. it carries WHY, as a field');
  perform pg_temp.ok(r.class_name = 'Class 5' and r.section_name = 'A',
    '32. and the class they were in — blank here would mean blank for exactly '
    'the children the report is about');
  perform pg_temp.ok(r.phone is not null,
    '33. and a phone number, because the office rings these parents');
  perform pg_temp.ok(r.balance = 3000,
    '34. and what they left OWING, on the same row (got ' || r.balance || ')');
  perform pg_temp.ok(r.months_here = 6,
    '35. and how long they were here (got ' || coalesce(r.months_here::text, 'null') || ')');

  select count(*) into n from public.fn_students_left(current_date - 3, current_date);
  perform pg_temp.ok(n = 2,
    '36. a date range that covers both finds both (got ' || n || ')');
  select count(*) into n from public.fn_students_left(current_date - 400, current_date - 300);
  perform pg_temp.ok(n = 0, '37. and one that covers neither finds neither');

  -- Asserted as monotonicity rather than against a literal date. Pinning the
  -- first row to a fixed date would either depend on the day the suite runs or
  -- lean on a tie-break the function does not promise — a mistake made four
  -- times already in this project.
  perform pg_temp.ok(
    not exists (
      select 1 from (
        select left_on, lag(left_on) over () as prev
        from public.fn_students_left(null, null)) t
      where t.prev is not null and t.left_on > t.prev),
    '38. the most recent leaver is first, and the order never rises');
end;
$$;

-- =============================================================================
-- 8. Arrears are office business
-- =============================================================================
do $$
begin
  perform pg_temp.be('Ls Clerk');
  perform pg_temp.ok((select count(*) from public.fn_students_left(null, null)) = 2,
    '39. a clerk may read the report — they chase the arrears on it');
  perform pg_temp.be('Ls Teacher');
  perform pg_temp.refuses('select count(*) from public.fn_students_left(null, null)',
    '40. a class teacher may not — the report carries what each child owes',
    '%Not permitted%');
  perform pg_temp.be('Ls Parent');
  perform pg_temp.refuses('select count(*) from public.fn_students_left(null, null)',
    '41. nor a parent', '%Not permitted%');
end;
$$;

-- =============================================================================
-- 9. The constraint catches what a stray UPDATE would not
-- =============================================================================
do $$
declare v_stays uuid := pg_temp.stu('Stays Here');
begin
  perform pg_temp.refuses(
    format('update public.students set left_on = current_date where id = %L::uuid', v_stays),
    '42. an ACTIVE child cannot carry a leaving date', '%students_left_on_chk%');
  perform pg_temp.refuses(
    format('update public.students set leaving_reason = ''x'' where id = %L::uuid', v_stays),
    '43. nor a leaving reason', '%students_left_on_chk%');
end;
$$;

-- =============================================================================
-- 10. The audit trail
-- =============================================================================
do $$
declare n integer;
begin
  perform pg_temp.be('Ls Owner');
  select count(*) into n from public.audit_log
   where action = 'STUDENT_STATUS' and school_id = public.current_school_id();
  perform pg_temp.ok(n = 4,
    '44. every status change is in the audit log — two leavings, one graduation, '
    'one reinstatement (got ' || n || ')');

  select count(*) into n from public.audit_log
   where action = 'STUDENT_STATUS' and reason = 'Family moved to Karachi';
  perform pg_temp.ok(n = 1, '45. with the reason the principal typed');

  select count(*) into n from public.audit_log
   where action = 'STUDENT_STATUS' and school_id is null;
  perform pg_temp.ok(n = 0, '46. and every row is stamped with the school');
end;
$$;

-- =============================================================================
-- 11. Nothing crosses a school boundary
-- =============================================================================
do $$
declare v_struck uuid := pg_temp.stu('Struck Child'); n integer;
begin
  perform pg_temp.be('Ls Owner B');
  select count(*) into n from public.fn_students_left(null, null);
  perform pg_temp.ok(n = 1,
    '47. school B''s report holds only school B''s leaver (got ' || n || ')');
  perform pg_temp.ok(
    (select student_name from public.fn_students_left(null, null)) = 'B Leaver',
    '48. and names theirs, not ours');

  perform pg_temp.refuses(
    format('select public.fn_set_student_status(%L::uuid, ''active'', null, current_date)', v_struck),
    '49. another school''s owner cannot reinstate my pupil', '%not found%');

  perform pg_temp.be('Ls Owner');
  perform pg_temp.ok(
    not exists (select 1 from public.fn_students_left(null, null)
                 where student_name = 'B Leaver'),
    '50. and school B''s leaver is invisible here');
end;
$$;

rollback;
