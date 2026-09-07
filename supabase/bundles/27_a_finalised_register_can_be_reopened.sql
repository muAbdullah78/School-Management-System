-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0121_a_finalised_register_can_be_reopened.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0121 - A finalised register can be reopened
--
-- A class teacher marks a child absent by mistake, presses Finalize, and that
-- is permanent. Not "hard to change": permanent. Nothing in this schema, at any
-- privilege level, could clear attendance_daily.is_locked.
--
-- REPRODUCED as the school's OWNER, on their own school, with a reason, on a
-- day thirty days old:
--
--   day 2026-09-05 : the register says "present", locked = t
--   the OWNER, with a reason, gets: {"total": 1, "marked": 0, "skipped": 1}
--   the register now says "present"   <-- unchanged
--
-- WHY IT HAPPENS. fn_finalize_attendance sets is_locked = true, and
-- fn_mark_attendance's upsert carries `where not ad.is_locked`. A search of
-- every function body in the schema for `is_locked = false` returns nothing.
-- There is no unlock, no override, and no owner exception.
--
-- WHAT IT COSTS. Three things, in increasing order of seriousness.
--
--   * The register is wrong for ever, and the register is a legal document in
--     a Pakistani school.
--   * The attendance percentage on the RESULT CARD is computed from
--     attendance_daily by fn_generate_result_cards, so a wrong mark is printed
--     and sent home, every term, for the rest of the child's time there.
--   * A class teacher can finalise their own class, so the LEAST privileged
--     user in the product can create a state the owner cannot undo. That
--     inverts the privilege ordering everywhere else in this schema, where an
--     owner can always reach further than a teacher.
--
-- The application is not silent about it, to its credit: the Attendance screen
-- already says "1 locked, skipped". So the school is told what happened. They
-- are simply given no way to put it right.
--
-- WHAT THIS DOES NOT DO, and the restraint is the design.
--
--   * It does NOT let the class teacher unlock. Owner and principal only. If
--     the person who finalised could reopen it, finalisation would mean
--     nothing, and the point of it (a teacher cannot quietly rewrite last
--     Tuesday) is worth keeping.
--   * It does NOT change the mark. It reopens the day, and the correction then
--     goes through fn_mark_attendance exactly as a same-day correction does,
--     which is what records corrected_from and correction_reason on the row so
--     fn_attendance_corrections can report it.
--   * It is NOT bounded to recent days. A school that discovers a mistake at
--     the end of term must be able to fix it; a limit would just move the trap
--     to a different distance. The accountability is the audit row and the
--     required reason, not a date window.
--
-- Re-runnable.
-- =============================================================================

create or replace function public.fn_unlock_attendance(
  p_session_id uuid,
  p_class_id   uuid,
  p_section_id uuid,
  p_date       date,
  p_reason     text)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_n      integer;
  v_before jsonb;
begin
  -- OWNER AND PRINCIPAL ONLY. Deliberately not admin_clerk and deliberately
  -- not the class teacher who locked it: see the header.
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or the principal can reopen a finalised '
      'register. Ask them: the day is locked so that a mark cannot be changed '
      'quietly after the fact.'
      using errcode = '42501';
  end if;

  -- All three ids, not just the class. Without the session check a foreign
  -- session id simply matched no rows and the caller was told "that day is not
  -- finalised for this class", which is a misleading answer to a question about
  -- a school they do not own. assert_own treats null as a no-op, so the
  -- optional section stays optional.
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);
  perform public.assert_own('sections', p_section_id);

  -- A reason, like every other correction path in this schema. Reopening a
  -- register is the kind of thing somebody will be asked about later, and an
  -- audit row with no reason on it cannot answer them.
  if v_reason is null or length(v_reason) < 8 then
    raise exception 'Say why the register is being reopened: it goes on the '
      'record and it is what answers the question later.';
  end if;

  select jsonb_agg(jsonb_build_object(
           'enrollment_id', ad.enrollment_id, 'status', ad.status))
    into v_before
    from public.attendance_daily ad
    join public.enrollments e on e.id = ad.enrollment_id
   where ad.school_id = v_school
     and ad.attendance_date = p_date
     and e.session_id = p_session_id
     and e.class_id   = p_class_id
     and e.section_id is not distinct from p_section_id
     and ad.is_locked;

  -- `is not distinct from`, matching fn_finalize_attendance EXACTLY, and the
  -- first version of this did not. It read `p_section_id is null or ...`, which
  -- means "the whole class" where finalize means "the pupils in this class who
  -- are in no section at all". Reopening more than the button that closed it is
  -- how an owner fixing one child's mark quietly reopens four other sections.
  update public.attendance_daily ad
     set is_locked = false
    from public.enrollments e
   where e.id = ad.enrollment_id
     and ad.school_id = v_school
     and ad.attendance_date = p_date
     and e.session_id = p_session_id
     and e.class_id   = p_class_id
     and e.section_id is not distinct from p_section_id
     and ad.is_locked;
  get diagnostics v_n = row_count;

  if v_n = 0 then
    raise exception 'Nothing to reopen: that day is not finalised for this '
      'class. Check the date and the section.';
  end if;

  -- AUDITED, and this one genuinely belongs in the audit log. Marking a
  -- register is routine and the row carries its own marked_by; reopening one is
  -- an exercise of authority over a document that had been closed.
  insert into public.audit_log (
    school_id, actor, actor_role, action, entity, entity_id, before, after, reason)
  values (
    v_school, auth.uid(),
    (select role from public.profiles where id = auth.uid()),
    'ATTENDANCE_UNLOCK', 'attendance_daily', p_date::text,
    jsonb_build_object('locked', true, 'rows', v_n, 'marks', v_before),
    jsonb_build_object('locked', false, 'class_id', p_class_id,
                       'section_id', p_section_id, 'session_id', p_session_id),
    v_reason);

  return v_n;
end;
$$;

revoke execute on function public.fn_unlock_attendance(uuid, uuid, uuid, date, text)
  from public, anon;
grant  execute on function public.fn_unlock_attendance(uuid, uuid, uuid, date, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- THE GUARD, and it asserts the BEHAVIOUR: that a locked day can be reopened
-- by an owner, that the correction then takes, and that a class teacher cannot.
-- A grep for the function's existence would pass on a body that returned 0 and
-- changed nothing, which is exactly the state this migration is fixing.
--
-- IT NEEDS A SIMULATED SIGNED-IN USER, which most databases this file runs on
-- cannot provide: auth.uid() on a bare shim returns null, and in the Supabase
-- SQL editor there is no JWT either. So the first thing it does is find out
-- whether a session can be simulated at all, and say so plainly if not. The
-- first version instead ran the probe regardless and printed
--
--   WARNING: 0121: the behaviour check could not run (Only the owner or the
--            principal can reopen a finalised register...)
--
-- to a school pasting bundle 27, which reads like a refusal of the very thing
-- they just installed. The durable proof lives in
-- supabase/tests/corrections.sql, where a session IS simulated and where CI and
-- scripts/preflight.sh both run it, forwards and in reverse.
--
-- The whole probe runs in a subtransaction that is rolled back either way.
-- ---------------------------------------------------------------------------
do $check$
declare
  v_probe      uuid := gen_random_uuid();
  v_ok_owner   boolean := false;
  v_ok_teacher boolean := false;   -- true means the teacher was REFUSED
  v_corrected  boolean := false;
begin
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_probe::text, 'role', 'authenticated')::text, true);
  if auth.uid() is distinct from v_probe then
    raise notice '0121: fn_unlock_attendance installed. Its behaviour check '
      'needs a signed-in user and this database cannot simulate one, so it was '
      'skipped here rather than guessed at. supabase/tests/corrections.sql '
      'proves it, and supabase/verify.sql confirms the function is present, '
      'clears the lock and is callable.';
    return;
  end if;

  begin
    declare
      v_school uuid; v_sess uuid; v_class uuid; v_sec uuid;
      v_stu uuid; v_enr uuid; v_owner uuid; v_teacher uuid; v_staff uuid;
      v_n int; v_status text;
    begin
      insert into public.schools (name) values ('0121 probe') returning id into v_school;
      insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
        values (v_school, (select code from public.plans limit 1), 'active', current_date + 30);

      v_owner := gen_random_uuid();
      insert into auth.users (id, email) values (v_owner, '0121owner@probe.invalid');
      insert into public.profiles (id, full_name, role, active, school_id)
        values (v_owner, '0121 owner', 'owner', true, v_school);

      insert into public.academic_sessions (school_id, name, starts_on, ends_on, is_current)
        values (v_school, '0121', current_date - 200, current_date + 100, true)
        returning id into v_sess;
      insert into public.classes (school_id, name, level_order, active)
        values (v_school, '0121 class', 1, true) returning id into v_class;
      insert into public.sections (school_id, class_id, name, sort_order)
        values (v_school, v_class, 'A', 1) returning id into v_sec;
      insert into public.staff (school_id, full_name, designation, employee_no, status, joined_on)
        values (v_school, '0121 teacher', 'Class Teacher', 'P-1', 'active', current_date - 200)
        returning id into v_staff;
      v_teacher := gen_random_uuid();
      insert into auth.users (id, email) values (v_teacher, '0121teacher@probe.invalid');
      insert into public.profiles (id, full_name, role, active, school_id, staff_id)
        values (v_teacher, '0121 teacher', 'class_teacher', true, v_school, v_staff);

      insert into public.students (school_id, full_name, admission_date, status)
        values (v_school, '0121 pupil', current_date - 200, 'active') returning id into v_stu;
      insert into public.enrollments
        (school_id, student_id, session_id, class_id, section_id, status, roll_no)
        values (v_school, v_stu, v_sess, v_class, v_sec, 'active', '1')
        returning id into v_enr;
      insert into public.attendance_daily
        (school_id, enrollment_id, attendance_date, status, marked_by, is_locked)
        values (v_school, v_enr, current_date - 10, 'absent', v_teacher, true);

      -- 1. The class teacher must be refused. They are the one who locked it.
      perform set_config('request.jwt.claims',
        jsonb_build_object('sub', v_teacher::text, 'role', 'authenticated')::text, true);
      begin
        perform public.fn_unlock_attendance(v_sess, v_class, v_sec, current_date - 10,
                                            'I want to change my own mark');
        v_ok_teacher := false;
      exception when others then
        v_ok_teacher := true;
      end;

      -- 2. The owner must be able to, and the correction must then take. Both
      -- halves matter: an unlock that leaves fn_mark_attendance still skipping
      -- the row has changed a flag and fixed nothing.
      perform set_config('request.jwt.claims',
        jsonb_build_object('sub', v_owner::text, 'role', 'authenticated')::text, true);
      v_n := public.fn_unlock_attendance(v_sess, v_class, v_sec, current_date - 10,
               'Father brought the leave application the next day');
      v_ok_owner := v_n = 1;

      perform public.fn_mark_attendance(current_date - 10,
        jsonb_build_array(jsonb_build_object('enrollment_id', v_enr, 'status', 'leave')),
        'Leave application produced');
      select status::text into v_status from public.attendance_daily
       where enrollment_id = v_enr and attendance_date = current_date - 10;
      v_corrected := v_status = 'leave';
    end;
    raise exception 'rollback the probe';
  exception
    when others then
      if sqlerrm <> 'rollback the probe' then
        raise warning '0121: the behaviour check could not finish (%). The '
          'function is installed; supabase/verify.sql says whether it is '
          'correct.', sqlerrm;
        return;
      end if;
  end;

  if not v_ok_teacher then
    raise exception '0121: a class teacher was allowed to reopen a register '
      'they had finalised, which makes finalising meaningless.';
  end if;
  if not v_ok_owner then
    raise exception '0121: the owner still cannot reopen a finalised register.';
  end if;
  if not v_corrected then
    raise exception '0121: the register reopened but the correction did not '
      'take, so the mistake is still on the record.';
  end if;
  raise notice '0121: an owner can reopen a finalised register and correct it; '
    'a class teacher cannot';
end $check$;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0121_a_finalised_register_can_be_reopened.sql', '27_a_finalised_register_can_be_reopened.sql');
end $ledger$;
