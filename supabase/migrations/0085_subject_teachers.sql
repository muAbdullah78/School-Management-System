-- =============================================================================
-- 0085 — Any teacher could write any class's exam marks
--
-- THE DEFECT, found by comparing the two mark-entry functions rather than by
-- reading either one.
--
-- fn_enter_assessment_marks (weekly tests) has scoped its caller since 0048:
--
--     if not public.has_role('owner','principal','admin_clerk') then
--       if not public.fn_may_manage_class(v_a.session_id, v_a.class_id, v_a.section_id) then
--         raise exception 'You can only enter marks for your assigned class';
--
-- fn_enter_marks (EXAM marks — the ones that go on the result card, the
-- certificate and the tabulation sheet sent to the board) has never had that
-- check. Not in 0005, not in 0048, not in 0058. Its only gate is has_role, so
-- ANY class_teacher or subject_teacher in the school could enter or overwrite
-- the exam marks of ANY class in ANY subject.
--
-- The asymmetry is what makes it indefensible: the guarded path is the one whose
-- marks nobody keeps, and the unguarded path is the one a family frames. A
-- teacher with a grudge, or simply the wrong class selected in a dropdown, could
-- rewrite a Class 10 board result. mark_entries records corrected_from and a
-- reason, so the change would be visible afterwards — but only if somebody knew
-- to look, and the marks would already have been printed.
--
-- WHAT SUBJECT-LEVEL ASSIGNMENT ADDS
--
-- The user_role enum has carried `subject_teacher` since 0001 and nothing has
-- ever recorded WHICH subjects. So even after the class gate above, the Physics
-- teacher of Class 9 could enter Class 9's Islamiat marks. `subject_teachers`
-- closes that, and gives the school the register it has to keep anyway: who
-- teaches what, this session.
--
-- THE RULE, stated once here and implemented in exactly one function:
--
--   owner / principal / admin_clerk    any class, any subject
--   anybody else                       a class they are the class teacher of
--                                      (teacher_assignments), OR a class+subject
--                                      they are the subject teacher of
--                                      (subject_teachers)
--
-- Deliberately NOT keyed on which of the two teaching roles the person holds.
-- profiles.role is a single value, and the class teacher of 5-B who also teaches
-- Maths to Class 8 is the normal case in a Pakistani school, not an exception.
-- Keying on the role name would have locked that person out of one of their two
-- jobs depending on which label the office happened to pick.
--
-- WHY THIS IS SAFE TO TIGHTEN NOW. No school is live yet (verify.sql still
-- reports "no schools yet, as expected"), so nobody loses a working path. On a
-- populated database the effect would be that a teacher with no assignment can
-- no longer enter marks — which is the intended behaviour and is why the error
-- message names the screen that fixes it instead of saying "permission denied".
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Who teaches what
-- ---------------------------------------------------------------------------
create table if not exists public.subject_teachers (
  id          uuid primary key default gen_random_uuid(),
  staff_id    uuid not null references public.staff(id) on delete cascade,
  session_id  uuid not null references public.academic_sessions(id) on delete cascade,
  class_id    uuid not null references public.classes(id) on delete cascade,
  -- Null means every section of the class, which is how a single-section school
  -- and a subject taught across all sections both work without ceremony.
  section_id  uuid          references public.sections(id) on delete cascade,
  subject_id  uuid not null references public.subjects(id) on delete cascade,
  created_by  uuid          references public.profiles(id),
  created_at  timestamptz not null default now(),
  school_id   uuid not null references public.schools(id) on delete cascade
);

-- Two teachers CAN share a subject (a split section, a maternity cover), so the
-- key is the whole tuple rather than the class+subject.
create unique index if not exists uq_subject_teacher
  on public.subject_teachers (staff_id, session_id, class_id, subject_id, section_id)
  where section_id is not null;
-- Postgres treats NULLs as distinct in a unique index, so the section-wide row
-- needs its own partial index or the same teacher could be added twice.
create unique index if not exists uq_subject_teacher_allsections
  on public.subject_teachers (staff_id, session_id, class_id, subject_id)
  where section_id is null;

create index if not exists idx_subject_teacher_staff
  on public.subject_teachers (staff_id, session_id);
create index if not exists idx_subject_teacher_class
  on public.subject_teachers (session_id, class_id, subject_id);
create index if not exists idx_subject_teachers_school
  on public.subject_teachers (school_id);

alter table public.subject_teachers enable row level security;

-- school_id is stamped by the same trigger every other tenant table uses, so a
-- client cannot insert a row into another school by supplying its id.
do $stamp$
begin
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.subject_teachers'::regclass
                    and tgname = 'trg_subject_teachers_school') then
    execute 'create trigger trg_subject_teachers_school
               before insert or update on public.subject_teachers
               for each row execute function public.enforce_school_id()';
  end if;
end $stamp$;

drop policy if exists subject_teachers_select on public.subject_teachers;
create policy subject_teachers_select on public.subject_teachers
  for select to authenticated
  using (school_id = public.current_school_id() and public.is_staff());

drop policy if exists subject_teachers_write on public.subject_teachers;
create policy subject_teachers_write on public.subject_teachers
  for all to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'admin_clerk'))
  with check (school_id = public.current_school_id()
              and public.has_role('owner', 'principal', 'admin_clerk'));

-- ---------------------------------------------------------------------------
-- 2. The one function that decides
--
-- fn_may_manage_class already answers "is this my class". This is its
-- subject-aware sibling, and every caller below uses THIS one so the rule cannot
-- drift between the exam path and the assessment path — which is exactly how the
-- defect in the header came to exist.
-- ---------------------------------------------------------------------------
create or replace function public.fn_may_mark_subject(
  p_session uuid, p_class uuid, p_section uuid, p_subject uuid
) returns boolean language sql stable security definer set search_path = public as $$
  -- Every id must belong to the caller's school first. Without this the
  -- existence checks below could be satisfied by another school's rows.
  select exists (select 1 from public.academic_sessions s
                  where s.id = p_session and s.school_id = public.current_school_id())
     and exists (select 1 from public.classes c
                  where c.id = p_class and c.school_id = public.current_school_id())
     and (p_section is null or exists (select 1 from public.sections sec
                  where sec.id = p_section and sec.school_id = public.current_school_id()))
     and (p_subject is null or exists (select 1 from public.subjects sub
                  where sub.id = p_subject and sub.school_id = public.current_school_id()))
     and (
       public.has_role('owner', 'principal', 'admin_clerk')
       -- The class teacher of the class: every subject in it. A class teacher
       -- fills in the whole card when a colleague is away, and a school that
       -- could not do that would keep the office password on a sticky note.
       or exists (
         select 1
         from public.teacher_assignments ta
         join public.profiles pr on pr.staff_id = ta.staff_id
         where pr.id = auth.uid()
           and ta.school_id = public.current_school_id()
           and ta.session_id = p_session
           and ta.class_id = p_class
           -- NULL MEANS "ANY" ON BOTH SIDES, and getting this wrong is what the
           -- first version did. An assignment with no section covers the whole
           -- class; a QUERY with no section is asking about the whole class —
           -- which is exactly what the exam path asks, because an exam_subject
           -- is set for a class and not for a section. Written as
           -- `ta.section_id is not distinct from p_section` it meant only the
           -- first of those, so the class teacher of 9-A could not mark 9's own
           -- exam paper. Caught by assertion 2 of subject_teachers.sql, not by
           -- reading this back.
           and (p_section is null or ta.section_id is null or ta.section_id = p_section)
       )
       -- Or the subject teacher of this class and subject.
       or exists (
         select 1
         from public.subject_teachers st
         join public.profiles pr on pr.staff_id = st.staff_id
         where pr.id = auth.uid()
           and st.school_id = public.current_school_id()
           and st.session_id = p_session
           and st.class_id = p_class
           and st.subject_id = p_subject
           and (p_section is null or st.section_id is null or st.section_id = p_section)
       )
     );
$$;

grant  execute on function public.fn_may_mark_subject(uuid, uuid, uuid, uuid) to authenticated;
revoke execute on function public.fn_may_mark_subject(uuid, uuid, uuid, uuid) from public, anon;

-- ---------------------------------------------------------------------------
-- 3. Close the hole in fn_enter_marks
--
-- Rewritten programmatically from its own current definition rather than
-- restated. A restatement copied out of 0058 would silently revert anything
-- changed since, and that has happened in this repository before.
-- ---------------------------------------------------------------------------
do $rw$
declare v_old text; v_new text;
begin
  v_old := pg_get_functiondef('public.fn_enter_marks(uuid, jsonb, text)'::regprocedure);

  if v_old like '%fn_may_mark_subject%' then
    raise notice '0085: fn_enter_marks already checks the teacher''s subject';
  else
    v_new := replace(v_old,
      '  perform public.assert_own(''exam_subjects'', p_exam_subject_id);',
      '  perform public.assert_own(''exam_subjects'', p_exam_subject_id);

  -- 0085. THE HOLE: this function had no class scope at all, while its sibling
  -- fn_enter_assessment_marks has had one since 0048 — so the marks nobody keeps
  -- were guarded and the marks that go on the result card were not.
  --
  -- Section is deliberately null here: an exam_subject is set for a CLASS, not a
  -- section, so the paper covers every section of it. fn_may_mark_subject treats
  -- a null on EITHER side as "any section", so a teacher assigned to 9-A still
  -- matches a paper set for the whole of Class 9.
  if not public.has_role(''owner'', ''principal'', ''admin_clerk'') then
    if not public.fn_may_mark_subject(
             (select et.session_id from public.exam_subjects es
                join public.exam_terms et on et.id = es.exam_term_id
               where es.id = p_exam_subject_id),
             (select es.class_id   from public.exam_subjects es where es.id = p_exam_subject_id),
             null,
             (select es.subject_id from public.exam_subjects es where es.id = p_exam_subject_id))
    then
      raise exception ''You can only enter marks for a class and subject you teach. ''
        ''Ask the office to add you under Settings, Staff, Subject Teachers.''
        using errcode = ''42501'';
    end if;
  end if;');

    if v_new = v_old then
      raise exception
        '0085: could not find the assert_own line in fn_enter_marks. It has been '
        'edited — add the fn_may_mark_subject gate by hand rather than letting '
        'this migration report success on a function it did not change.';
    end if;
    execute v_new;
  end if;

  if pg_get_functiondef('public.fn_enter_marks(uuid, jsonb, text)'::regprocedure)
     not like '%fn_may_mark_subject%' then
    raise exception '0085: fn_enter_marks still has no subject scope';
  end if;
end $rw$;

grant  execute on function public.fn_enter_marks(uuid, jsonb, text) to authenticated;
revoke execute on function public.fn_enter_marks(uuid, jsonb, text) from public, anon;

-- ---------------------------------------------------------------------------
-- 4. And narrow the assessment path from class to class+subject
--
-- It was already scoped to the class. This upgrades it to the same rule as the
-- exam path so there is one answer to "may I mark this", not two.
-- ---------------------------------------------------------------------------
do $rw$
declare v_old text; v_new text;
begin
  v_old := pg_get_functiondef(
    'public.fn_enter_assessment_marks(uuid, jsonb, text)'::regprocedure);

  if v_old like '%fn_may_mark_subject%' then
    raise notice '0085: fn_enter_assessment_marks already checks the subject';
  else
    v_new := replace(v_old,
      '    if not public.fn_may_manage_class(v_a.session_id, v_a.class_id, v_a.section_id) then
      raise exception ''You can only enter marks for your assigned class'';
    end if;',
      '    -- 0085: class AND subject. The class check alone let the Physics
    -- teacher of Class 9 enter Class 9''s Islamiat marks.
    if not public.fn_may_mark_subject(
             v_a.session_id, v_a.class_id, v_a.section_id, v_a.subject_id) then
      raise exception ''You can only enter marks for a class and subject you teach. ''
        ''Ask the office to add you under Settings, Staff, Subject Teachers.''
        using errcode = ''42501'';
    end if;');

    if v_new = v_old then
      raise exception
        '0085: could not find the class-scope check in fn_enter_assessment_marks.';
    end if;
    execute v_new;
  end if;

  if pg_get_functiondef('public.fn_enter_assessment_marks(uuid, jsonb, text)'::regprocedure)
     not like '%fn_may_mark_subject%' then
    raise exception '0085: fn_enter_assessment_marks still has no subject scope';
  end if;
end $rw$;

grant  execute on function public.fn_enter_assessment_marks(uuid, jsonb, text) to authenticated;
revoke execute on function public.fn_enter_assessment_marks(uuid, jsonb, text) from public, anon;

-- ---------------------------------------------------------------------------
-- 5. The direct-table backstop
--
-- 0001 grants INSERT/UPDATE on every table in public to `authenticated`, held
-- shut only by RLS. The two functions above are the app's path, but a signed-in
-- teacher with the anon key can POST straight at /rest/v1/mark_entries — so the
-- policy has to carry the same rule, or the gate is a suggestion.
--
-- The parent row supplies the class and subject; a mark row on its own does not
-- know either.
-- ---------------------------------------------------------------------------
-- NOT named fn__ and NOT revoked, unlike most helpers in this schema — and the
-- reason is worth stating because the first version got it wrong and the test
-- caught it. A policy expression is evaluated AS THE QUERYING USER, so a policy
-- that calls a function `authenticated` cannot execute does not fail closed: it
-- fails with `permission denied for function`, and the table becomes unusable
-- the moment somebody grants INSERT on it. fn_may_manage_class and
-- fn_may_mark_subject are granted for exactly the same reason. They are safe to
-- grant because they answer only about the CALLER's own permissions and return a
-- boolean — no row from any table reaches the caller through them.
create or replace function public.fn_may_mark_row(
  p_assessment_id uuid, p_exam_subject_id uuid
) returns boolean language sql stable security definer set search_path = public as $$
  -- Every subselect carries `school_id = current_school_id()`. Not belt and
  -- braces: without it a foreign assessment id would resolve to THAT school's
  -- session, class and subject, and this function would be handing another
  -- school's row identifiers to fn_may_mark_subject. It would still answer
  -- false — fn_may_mark_subject checks the ids belong to the caller's school —
  -- so the door stays shut, but the reads themselves would be unscoped inside a
  -- SECURITY DEFINER function, which is precisely what dashboard.sql's assertion
  -- 20 refuses. Failing closed by accident is not the same as being scoped.
  select case
    when p_assessment_id is not null then
      public.fn_may_mark_subject(
        (select a.session_id from public.assessments a
          where a.id = p_assessment_id and a.school_id = public.current_school_id()),
        (select a.class_id   from public.assessments a
          where a.id = p_assessment_id and a.school_id = public.current_school_id()),
        (select a.section_id from public.assessments a
          where a.id = p_assessment_id and a.school_id = public.current_school_id()),
        (select a.subject_id from public.assessments a
          where a.id = p_assessment_id and a.school_id = public.current_school_id()))
    when p_exam_subject_id is not null then
      public.fn_may_mark_subject(
        (select et.session_id from public.exam_subjects es
           join public.exam_terms et on et.id = es.exam_term_id
          where es.id = p_exam_subject_id
            and es.school_id = public.current_school_id()
            and et.school_id = public.current_school_id()),
        (select es.class_id   from public.exam_subjects es
          where es.id = p_exam_subject_id and es.school_id = public.current_school_id()),
        null,
        (select es.subject_id from public.exam_subjects es
          where es.id = p_exam_subject_id and es.school_id = public.current_school_id()))
    -- Neither parent set. mark_one_parent forbids it, so this is unreachable —
    -- and it returns false rather than true, because an unreachable branch that
    -- grants access is how an unreachable branch becomes reachable.
    else false
  end;
$$;

grant  execute on function public.fn_may_mark_row(uuid, uuid) to authenticated;
revoke execute on function public.fn_may_mark_row(uuid, uuid) from public, anon;


drop policy if exists marks_insert on public.mark_entries;
create policy marks_insert on public.mark_entries
  for insert to authenticated
  with check (
    school_id = public.current_school_id()
    and (
      public.has_role('owner', 'principal', 'admin_clerk')
      or (public.has_role('class_teacher', 'subject_teacher')
          and public.fn_may_mark_row(assessment_id, exam_subject_id))
    ));

drop policy if exists marks_update on public.mark_entries;
create policy marks_update on public.mark_entries
  for update to authenticated
  using (
    school_id = public.current_school_id()
    and not is_locked
    and (
      public.has_role('owner', 'principal', 'admin_clerk')
      or (public.has_role('class_teacher', 'subject_teacher')
          and public.fn_may_mark_row(assessment_id, exam_subject_id))
    ))
  with check (
    school_id = public.current_school_id()
    and (
      public.has_role('owner', 'principal', 'admin_clerk')
      or (public.has_role('class_teacher', 'subject_teacher')
          and public.fn_may_mark_row(assessment_id, exam_subject_id))
    ));

-- The misnamed first version of the helper, if a copy of this migration with the
-- fn__ name was ever applied.
--
-- AFTER the policies, not before, and that ordering is load-bearing: a policy
-- records a hard dependency on every function its expression names, so dropping
-- it first fails with "cannot drop function because other objects depend on it"
-- and takes the rest of this file down with it. DROP ... CASCADE would have
-- "fixed" that by silently deleting both policies and leaving the table open.
drop function if exists public.fn__may_mark_row(uuid, uuid);

-- ---------------------------------------------------------------------------
-- 6. Setting and reading the register
-- ---------------------------------------------------------------------------

-- Replace-set for ONE class+subject+section. Replace rather than add, because
-- the screen shows the current holders and sends back the list it wants — an
-- add-only function would make removing a teacher impossible from that screen,
-- which is how the class-teacher UI would have gone wrong too.
create or replace function public.fn_set_subject_teachers(
  p_session_id uuid, p_class_id uuid, p_section_id uuid,
  p_subject_id uuid, p_staff_ids uuid[]
) returns integer language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_n integer := 0;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Only the office may assign subject teachers';
  end if;
  -- Every id guarded: the DELETE below is scoped by session/class/subject, so
  -- another school's ids would clear THEIR register.
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);
  perform public.assert_own('subjects', p_subject_id);
  if p_section_id is not null then
    perform public.assert_own('sections', p_section_id);
  end if;

  -- The subject must belong to the class it is being taught in. subjects.class_id
  -- exists, so a mismatch here is a typo the office cannot see the consequence
  -- of: marks would be enterable for a paper that class never sits.
  if not exists (select 1 from public.subjects s
                  where s.id = p_subject_id and s.class_id = p_class_id) then
    raise exception 'That subject does not belong to that class';
  end if;

  delete from public.subject_teachers
   where session_id = p_session_id
     and class_id = p_class_id
     and subject_id = p_subject_id
     and section_id is not distinct from p_section_id
     and school_id = public.current_school_id();

  if p_staff_ids is not null then
    foreach v_id in array p_staff_ids loop
      perform public.assert_own('staff', v_id);
      insert into public.subject_teachers
        (staff_id, session_id, class_id, section_id, subject_id, created_by)
      values (v_id, p_session_id, p_class_id, p_section_id, p_subject_id, auth.uid())
      on conflict do nothing;
      v_n := v_n + 1;
    end loop;
  end if;

  return v_n;
end;
$$;

grant  execute on function public.fn_set_subject_teachers(uuid, uuid, uuid, uuid, uuid[]) to authenticated;
revoke execute on function public.fn_set_subject_teachers(uuid, uuid, uuid, uuid, uuid[]) from public, anon;

-- The whole register for a session: one row per class+subject, with whoever
-- teaches it. Returned even for subjects with nobody assigned, because the empty
-- rows are the work list — a screen that only showed filled rows would hide the
-- thing the office opened it to do.
create or replace function public.fn_subject_teachers(p_session_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  if not public.is_staff() then
    raise exception 'Not permitted';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  select coalesce(jsonb_agg(x order by x.level_order, x.class_name, x.sort_order, x.subject_name), '[]'::jsonb)
    into v_out
  from (
    select c.id            as class_id,
           c.name          as class_name,
           c.level_order   as level_order,
           sub.id          as subject_id,
           sub.name        as subject_name,
           sub.sort_order  as sort_order,
           coalesce((
             select jsonb_agg(jsonb_build_object(
                      'assignment_id', st.id,
                      'staff_id', st.staff_id,
                      'staff_name', stf.full_name,
                      'section_id', st.section_id,
                      'section_name', sec.name)
                    order by stf.full_name)
             from public.subject_teachers st
             join public.staff stf on stf.id = st.staff_id
             left join public.sections sec on sec.id = st.section_id
             where st.session_id = p_session_id
               and st.class_id = c.id
               and st.subject_id = sub.id
               and st.school_id = public.current_school_id()
           ), '[]'::jsonb) as teachers
    from public.classes c
    join public.subjects sub on sub.class_id = c.id
                            and sub.school_id = public.current_school_id()
    where c.school_id = public.current_school_id()
      and c.active
  ) x;

  return jsonb_build_object('session_id', p_session_id, 'rows', v_out);
end;
$$;

grant  execute on function public.fn_subject_teachers(uuid) to authenticated;
revoke execute on function public.fn_subject_teachers(uuid) from public, anon;
