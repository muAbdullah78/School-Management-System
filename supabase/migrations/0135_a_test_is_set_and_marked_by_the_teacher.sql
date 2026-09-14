-- =============================================================================
-- 0135  A test is set and marked by the teacher, and the head watches it happen
--
-- -----------------------------------------------------------------------------
-- THE SAME MISTAKE AS THE REGISTER, IN THE OTHER MODULE
--
-- A principal could create a class test, enter its marks and lock it. 0134
-- gives the reasoning at length for the daily register and it transfers whole:
-- a mark is a statement about a child's work by the person who set the paper
-- and read it. A head who can enter marks can produce a result nobody taught.
--
-- What the head needs instead, and did not have in any form:
--
--   * what tests my teachers have set, and for when
--   * which of them are marked and which are not
--   * and the ability to ask that question about LAST Tuesday, or about next
--     week, instead of only about today
--
-- -----------------------------------------------------------------------------
-- SCHEDULING A TEST FOR A DATE THAT HAS NOT HAPPENED
--
-- The database always allowed it: nothing bounded assessment_date in either
-- direction. That is not the same as supporting it. A test dated next Saturday
-- sat in the same list as a test held last Tuesday, with nothing to say which
-- was which, and the marks grid opened for both. A teacher could enter marks
-- for a paper that had not been sat.
--
-- So this file gives the date a meaning:
--
--   * a test may be dated in the future. That is scheduling, and it is what the
--     teachers asked for.
--   * MARKS MAY NOT BE ENTERED BEFORE THAT DATE. Refused in words, because the
--     alternative is a mark against a paper nobody has written.
--   * the date must fall inside the academic year, and no more than a year
--     ahead. Both are about somebody typing 2027 for 2026, and the second one
--     matters more than it looks: a test mistyped four years out never appears
--     in the unmarked list and is never noticed again.
--
-- -----------------------------------------------------------------------------
-- WHAT "UNMARKED" MEANS, WHICH IS THE ONLY SUBTLE THING IN THIS FILE
--
-- A test is unmarked when its date has PASSED and at least one pupil in it has
-- no mark and is not recorded absent. Not "has no marks at all": the common
-- failure is a teacher who marked twenty of thirty-four and was interrupted,
-- and a reminder that only fires on a completely blank test misses exactly
-- that case. A locked test is never unmarked, because locking is the teacher
-- saying they are finished.
--
-- A test dated TODAY is not chased. The paper may be sat this afternoon.
-- =============================================================================

-- ==================================================== who may set a test ====
-- The narrower cousin of fn_may_mark_subject.
--
-- fn_may_mark_subject itself is NOT changed and must not be: it also gates
-- fn_enter_marks, which is the formal EXAM path, and the school's exam process
-- is a different thing with a different chain of responsibility. Widening this
-- change into exams was not asked for and would be a surprise.
-- fn_may_ and not fn__, for the reason given at fn_may_write_register in 0134:
-- it is used inside a row-level policy and so must be executable by the
-- querying user.
create or replace function public.fn_may_set_a_test(
  p_session uuid, p_class uuid, p_section uuid, p_subject uuid
) returns boolean language sql stable security definer set search_path = public as $$
  select not public.has_role('principal')
     and public.fn_may_mark_subject(p_session, p_class, p_section, p_subject);
$$;

revoke all on function public.fn_may_set_a_test(uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.fn_may_set_a_test(uuid, uuid, uuid, uuid) to authenticated;

comment on function public.fn_may_set_a_test(uuid, uuid, uuid, uuid) is
  'Who may create, edit, mark or lock a class test. fn_may_mark_subject minus '
  'the principal, who oversees tests rather than setting them. Exams are '
  'unaffected and still use fn_may_mark_subject. See 0135.';

drop policy if exists assessments_insert on public.assessments;
create policy assessments_insert on public.assessments for insert
  with check (school_id = public.current_school_id()
              and public.has_role('owner', 'class_teacher', 'subject_teacher')
              and public.fn_may_set_a_test(session_id, class_id, section_id, subject_id));

drop policy if exists assessments_update on public.assessments;
create policy assessments_update on public.assessments for update
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'class_teacher', 'subject_teacher')
         and public.fn_may_set_a_test(session_id, class_id, section_id, subject_id))
  with check (school_id = public.current_school_id()
              and public.has_role('owner', 'class_teacher', 'subject_teacher')
              and public.fn_may_set_a_test(session_id, class_id, section_id, subject_id));

-- ------------------------------------------------------------- the date -----
-- A trigger rather than a check constraint, because both bounds need the
-- academic year the test belongs to, and a check constraint may not read
-- another table.
create or replace function public.guard_assessment_date() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_starts date;
  v_ends   date;
begin
  if new.assessment_date is null then
    return new;   -- Allowed, and always was: an undated test is a draft.
  end if;

  -- Karachi, not UTC, for the same reason every other date bound in this
  -- product uses it: between midnight and 5am local, UTC still says yesterday.
  if new.assessment_date > (now() at time zone 'Asia/Karachi')::date + 365 then
    raise exception 'A test cannot be scheduled for %, which is more than a '
                    'year away. Check the year.', to_char(new.assessment_date, 'DD Mon YYYY')
      using errcode = '22008';
  end if;

  -- SCHOOL-SCOPED, and it has to be said out loud because this function is
  -- SECURITY DEFINER and RLS does not apply inside one. Reading
  -- academic_sessions by id alone would let a row naming ANOTHER school's
  -- session be validated against that school's dates. The row's own school_id
  -- is authoritative where it is set (a BEFORE trigger stamps it), and
  -- current_school_id() covers the ordering case where it is not yet.
  select starts_on, ends_on into v_starts, v_ends
    from public.academic_sessions
   where id = new.session_id
     and school_id = coalesce(new.school_id, public.current_school_id());
  if not found then
    raise exception 'That academic year does not belong to this school'
      using errcode = '42501';
  end if;
  -- A year with no dates on it is left alone. 0130 reports those separately
  -- and refusing here would block a school from working until somebody fills
  -- in a settings screen they do not know about.
  if v_starts is not null and new.assessment_date < v_starts then
    raise exception 'A test on % falls before the academic year began on %.',
      to_char(new.assessment_date, 'DD Mon YYYY'), to_char(v_starts, 'DD Mon YYYY')
      using errcode = '22008';
  end if;
  if v_ends is not null and new.assessment_date > v_ends then
    raise exception 'A test on % falls after the academic year ended on %.',
      to_char(new.assessment_date, 'DD Mon YYYY'), to_char(v_ends, 'DD Mon YYYY')
      using errcode = '22008';
  end if;
  return new;
end;
$$;

-- A trigger function is called by Postgres, never by a client, so nothing
-- needs execute on it.
revoke all on function public.guard_assessment_date() from public, anon, authenticated;

drop trigger if exists trg_assessment_date on public.assessments;
create trigger trg_assessment_date before insert or update on public.assessments
  for each row execute function public.guard_assessment_date();

-- ================================================== marking and locking =====
create or replace function public.fn_enter_assessment_marks(
  p_assessment_id uuid, p_marks jsonb, p_reason text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_a      record;
  v_total  integer;
  v_marked integer;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.has_role('owner','class_teacher','subject_teacher') then
    raise exception 'A test is marked by the teacher who set it. A principal '
                    'can see which tests are marked and which are not, on the '
                    'Tests screen.'
      using errcode = '42501';
  end if;
  perform public.fn__only_these_keys(p_marks, '{enrollment_id,marks,is_absent}'::text[], 'Class test mark entry');
  perform public.assert_own('assessments', p_assessment_id);
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;

  select * into v_a from public.assessments
  where id = p_assessment_id and school_id = public.current_school_id();
  if not found then raise exception 'Assessment not found'; end if;
  if v_a.is_locked then raise exception 'This assessment is locked'; end if;

  -- A PAPER THAT HAS NOT BEEN SAT HAS NO MARKS. New in 0135, and the reason
  -- scheduling needed more than letting the date field hold a future value.
  if v_a.assessment_date is not null
     and v_a.assessment_date > (now() at time zone 'Asia/Karachi')::date then
    raise exception 'This test is scheduled for %. Marks can be entered from '
                    'that day onwards.', to_char(v_a.assessment_date, 'DD Mon YYYY')
      using errcode = '22008';
  end if;

  -- Teacher scope. The owner is the one unscoped role left; see 0134 for why
  -- that is deliberate and where to change it.
  if not public.has_role('owner') then
    -- 0085: class AND subject. The class check alone let the Physics
    -- teacher of Class 9 enter Class 9's Islamiat marks.
    --
    -- WRITTEN AS TWO CHECKS RATHER THAN ONE CALL TO fn_may_set_a_test, AND
    -- BOTH REASONS MATTER.
    --
    -- The first is the school's. fn_may_set_a_test is fn_may_mark_subject with
    -- the principal taken out, so one call collapses two quite different
    -- refusals into one sentence. A principal needs to be told that marking is
    -- the teacher's, and a Physics teacher who opened the Islamiat paper needs
    -- to be told to ask the office about their subject assignment. Telling
    -- either of them the other's sentence sends them to the wrong person.
    --
    -- The second is this repository's, and it cost a red CI run to learn.
    -- MIGRATION 0085 IS A TEXT PATCH ON THIS FUNCTION, it is frozen inside
    -- bundle 7, and its idempotency guard is
    --
    --     if v_old like '%fn_may_mark_subject%' then  (skip, already done)
    --
    -- A body that no longer contains that name is one the guard does not
    -- recognise, so 0085 tries its regexp, matches nothing, and raises. Because
    -- a bundle is ONE transaction that rolls back all of bundle 7, and
    -- verify.sql tells a school in several of its FAIL messages to "re-run
    -- bundle 7". The repair path would have been a dead end on exactly the
    -- databases that needed it.
    --
    -- So the reference below is load bearing twice over: it is the check this
    -- function genuinely needs, and it is the anchor a frozen migration reads.
    -- Do not collapse it back into one call.
    if not public.fn_may_mark_subject(
             v_a.session_id, v_a.class_id, v_a.section_id, v_a.subject_id) then
      raise exception 'You can only enter marks for a class and subject you teach. '
        'Ask the office to add you under Settings, Staff, Subject Teachers.'
        using errcode = '42501';
    end if;
    if not public.fn_may_set_a_test(
             v_a.session_id, v_a.class_id, v_a.section_id, v_a.subject_id) then
      raise exception 'A test is marked by the teacher who set it. A principal '
                      'can see which tests are marked and which are not, on the '
                      'Tests screen.'
        using errcode = '42501';
    end if;
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where coalesce((e->>'is_absent')::boolean, false) = false
      and nullif(e->>'marks', '') is not null
      and ((e->>'marks')::numeric < 0 or (e->>'marks')::numeric > v_a.max_marks)
  ) then
    raise exception 'Marks must be between 0 and %', v_a.max_marks;
  end if;

  -- Every enrolment must be in this school.
  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where not exists (
      select 1 from public.enrollments en
      where en.id = (e->>'enrollment_id')::uuid
        and en.school_id = public.current_school_id())
  ) then
    raise exception 'Unknown enrolment in this school' using errcode = '42501';
  end if;

  select count(distinct (e->>'enrollment_id')) into v_total from jsonb_array_elements(p_marks) e;

  with input as (
    select distinct on (enrollment_id) enrollment_id, marks, is_absent
    from (
      select (e->>'enrollment_id')::uuid as enrollment_id,
             nullif(e->>'marks', '')::numeric as marks,
             coalesce((e->>'is_absent')::boolean, false) as is_absent
      from jsonb_array_elements(p_marks) e
    ) q
    order by enrollment_id
  ),
  upserted as (
    insert into public.mark_entries as me
      (assessment_id, enrollment_id, marks, max_marks, is_absent, marked_by)
    select p_assessment_id, enrollment_id, marks, v_a.max_marks, is_absent, v_actor from input
    on conflict (assessment_id, enrollment_id) where assessment_id is not null
    do update set marks = excluded.marks, is_absent = excluded.is_absent,
                  marked_by = excluded.marked_by,
                  corrected_from = case when me.marks is distinct from excluded.marks
                                        then me.marks else me.corrected_from end,
                  correction_reason = case when me.marks is distinct from excluded.marks
                                           then v_reason else me.correction_reason end
    where not me.is_locked
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

create or replace function public.fn_lock_assessment(p_assessment_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_session uuid; v_class uuid; v_section uuid; v_subject uuid; v_marks integer;
begin
  if not public.has_role('owner','class_teacher','subject_teacher') then
    raise exception 'A test is locked by the teacher who marked it.'
      using errcode = '42501';
  end if;
  perform public.assert_own('assessments', p_assessment_id);
  select session_id, class_id, section_id, subject_id
    into v_session, v_class, v_section, v_subject
  from public.assessments where id = p_assessment_id;
  if v_session is null then raise exception 'Assessment not found'; end if;
  -- fn_may_set_a_test, not fn_may_manage_class: locking a test is finishing
  -- it, and the person who may finish it is the person who could mark it. The
  -- class check alone let the Physics teacher lock the Islamiat paper.
  if not public.fn_may_set_a_test(v_session, v_class, v_section, v_subject) then
    raise exception 'You can only lock a test for a class and subject you teach';
  end if;

  select count(*) into v_marks from public.mark_entries
   where assessment_id = p_assessment_id and not is_locked;

  update public.mark_entries set is_locked = true where assessment_id = p_assessment_id;
  update public.assessments set is_locked = true where id = p_assessment_id;

  if v_marks > 0 then
    insert into public.audit_log (
      school_id, actor, actor_role, action, entity, entity_id, before, after)
    values (
      public.current_school_id(), auth.uid(),
      (select role from public.profiles where id = auth.uid()),
      'ASSESSMENT_LOCK', 'assessments', p_assessment_id::text,
      jsonb_build_object('locked', false),
      jsonb_build_object('locked', true, 'marks', v_marks,
                         'session_id', v_session, 'class_id', v_class,
                         'section_id', v_section));
  end if;
end;
$$;

-- ================================================== the teacher's reminder ==
/**
 * Tests this teacher set, whose day has passed, that are not finished.
 *
 * Scoped to the CALLER: a teacher is reminded about their own papers and
 * nobody else's. The head's version is fn_tests_overview below, and it is a
 * different question with a different answer.
 */
-- DROPPED FIRST, because `create or replace function` REFUSES to change a
-- function's return type: "cannot change return type of existing function".
-- These return a table, and a column added to one later is exactly that
-- change. Without the drop, a school re-pasting a corrected bundle would hit
-- that error, and because a bundle is one transaction the whole bundle would
-- roll back. None of these is referenced by a policy, so nothing depends on
-- them; the grants below are reapplied straight afterwards.
drop function if exists public.fn_my_unmarked_tests(uuid);
create or replace function public.fn_my_unmarked_tests(p_session_id uuid)
returns table(
  assessment_id uuid, title text, assessment_date date,
  -- class_id as well as class_name, so the screen can OPEN the test rather
  -- than only naming it. A reminder you cannot act on from where it is shown
  -- is half a feature: the teacher reads "Weekly Test 3, four days ago" and
  -- then has to go and find it in a dropdown.
  class_id uuid, class_name text, section_name text, subject_name text,
  pupils integer, marked integer, days_late integer
) language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Karachi')::date;
begin
  if not public.has_role('owner','class_teacher','subject_teacher') then
    -- Not an error for a principal so much as the wrong question: they have no
    -- tests of their own. Returning nothing would be a silent lie about it.
    raise exception 'This is a teacher''s own list of papers to mark'
      using errcode = '42501';
  end if;

  return query
  select a.id, a.title, a.assessment_date,
         c.id, c.name, sec.name, sub.name,
         cnt.pupils, cnt.marked,
         (v_today - a.assessment_date)::integer
    from public.assessments a
    join public.classes c on c.id = a.class_id
    left join public.sections sec on sec.id = a.section_id
    left join public.subjects sub on sub.id = a.subject_id
    cross join lateral (
      select count(*)::integer as pupils,
             count(*) filter (
               where me.id is not null
                 and (me.marks is not null or me.is_absent)
             )::integer as marked
        from public.enrollments e
        left join public.mark_entries me
               on me.assessment_id = a.id and me.enrollment_id = e.id
       where e.school_id = a.school_id
         and e.session_id = a.session_id
         and e.class_id = a.class_id
         and (a.section_id is null or e.section_id = a.section_id)
         and e.status = 'active'
    ) cnt
   where a.school_id = public.current_school_id()
     and a.session_id = p_session_id
     and not a.is_locked
     -- Strictly before today. A paper dated today may be sat this afternoon,
     -- and a reminder that fires the morning of the test is noise.
     and a.assessment_date is not null
     and a.assessment_date < v_today
     -- At least one pupil with neither a mark nor an absence. "No marks at
     -- all" would miss the common case: twenty of thirty-four done, then the
     -- bell went.
     and cnt.marked < cnt.pupils
     and public.fn_may_set_a_test(a.session_id, a.class_id, a.section_id, a.subject_id)
   order by a.assessment_date, c.name, sub.name;
end;
$$;
revoke all on function public.fn_my_unmarked_tests(uuid) from public, anon;
grant execute on function public.fn_my_unmarked_tests(uuid) to authenticated;

-- ==================================================== the head's overview ===
/**
 * Every test in a date range, with who set it and whether it is marked.
 *
 * A RANGE and not a day, which is what makes the calendar on the screen work.
 * The head looks back to audit last week and forward to see what is coming,
 * and both are the same question asked of a different pair of dates.
 *
 * `state` is computed here rather than in the browser so that the screen, a
 * future report and anybody reading the database by hand agree about what
 * "marked" means:
 *
 *   scheduled  the day has not come
 *   unmarked   the day has passed and nobody has entered anything
 *   partial    some pupils marked, some not
 *   marked     every pupil has a mark or an absence, not locked
 *   locked     the teacher has finished with it
 */
drop function if exists public.fn_tests_overview(uuid, date, date);
create or replace function public.fn_tests_overview(
  p_session_id uuid, p_from date, p_to date
) returns table(
  assessment_id uuid, title text, assessment_date date,
  class_id uuid, class_name text, level_order integer,
  section_name text, subject_name text,
  set_by_name text, max_marks numeric, is_locked boolean,
  pupils integer, marked integer, state text
) language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Karachi')::date;
begin
  -- may_view, per 0059: an observer sees the oversight screens.
  if not public.may_view('owner', 'principal') then
    raise exception 'Only the head, the owner or an observer may see every '
                    'teacher''s tests'
      using errcode = '42501';
  end if;
  if not exists (select 1 from public.academic_sessions s
                  where s.id = p_session_id
                    and s.school_id = public.current_school_id()) then
    raise exception 'Unknown academic year for this school' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Give a start date and an end date, in that order';
  end if;
  -- A year at a time. Without a cap the screen can ask for a decade and the
  -- head waits for a spinner on a school connection.
  if p_to - p_from > 400 then
    raise exception 'Ask for a year at a time or less';
  end if;

  return query
  select a.id, a.title, a.assessment_date,
         c.id, c.name, c.level_order,
         sec.name, sub.name,
         coalesce(pr.full_name, 'Unknown'),
         a.max_marks, a.is_locked,
         cnt.pupils, cnt.marked,
         case
           when a.is_locked then 'locked'
           when a.assessment_date is null then 'undated'
           when a.assessment_date > v_today then 'scheduled'
           when cnt.marked = 0 then 'unmarked'
           when cnt.marked < cnt.pupils then 'partial'
           else 'marked'
         end
    from public.assessments a
    join public.classes c on c.id = a.class_id
    left join public.sections sec on sec.id = a.section_id
    left join public.subjects sub on sub.id = a.subject_id
    left join public.profiles pr on pr.id = a.created_by
    cross join lateral (
      select count(*)::integer as pupils,
             count(*) filter (
               where me.id is not null
                 and (me.marks is not null or me.is_absent)
             )::integer as marked
        from public.enrollments e
        left join public.mark_entries me
               on me.assessment_id = a.id and me.enrollment_id = e.id
       where e.school_id = a.school_id
         and e.session_id = a.session_id
         and e.class_id = a.class_id
         and (a.section_id is null or e.section_id = a.section_id)
         and e.status = 'active'
    ) cnt
   where a.school_id = public.current_school_id()
     and a.session_id = p_session_id
     and a.assessment_date between p_from and p_to
   order by a.assessment_date, c.level_order, c.name, sub.name;
end;
$$;
revoke all on function public.fn_tests_overview(uuid, date, date) from public, anon;
grant execute on function public.fn_tests_overview(uuid, date, date) to authenticated;
