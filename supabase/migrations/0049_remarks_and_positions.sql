-- =============================================================================
-- 0049 — Teacher remarks, and a position-holders screen.
--
-- Item 7 of the build order in docs/PARITY.md. Two things their software has and
-- ours did not:
--
--   Teacher Remarks   `missing` — nothing in the schema stored one at all.
--   Position Holders  `partial` — position is computed and printed on the result
--                     card and the tabulation sheet, but there was no "top three
--                     in each class" view, which is what a prize distribution
--                     and the notice board actually need.
--
-- WHY REMARKS ARE NOT A COLUMN ON result_cards
--
-- The obvious place for a remark is result_cards.teacher_remark. That would be a
-- trap. fn_generate_result_cards does not update rows — it INSERTS a new one
-- with version + 1 every time it runs. So a remark written on version 1 would
-- silently vanish from the printed card the moment anybody regenerated the
-- class, and the teacher would have no idea it had gone.
--
-- Keying the remark on (exam_term_id, student_id) instead makes it immune:
-- regeneration cannot touch it, however many versions are produced, and nothing
-- in fn_generate_result_cards needs changing.
--
-- POSITION AND TIES
--
-- fn_generate_result_cards already uses rank(), not row_number(), so two
-- children on the same percentage genuinely SHARE a position and the next one
-- down is third. That is the right behaviour for a prize-giving, and the
-- position-holders view preserves it: if three children tie for first, all
-- three are listed as first.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The remark
--
-- One per student per exam term, not per result card version. `remark_by` and
-- `updated_at` matter: a remark is a signed opinion that goes home to a parent,
-- and "who wrote this" is the first question when one is disputed.
-- ---------------------------------------------------------------------------
create table if not exists public.exam_remarks (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  exam_term_id  uuid not null references public.exam_terms(id) on delete cascade,
  student_id    uuid not null references public.students(id) on delete cascade,
  remark        text not null,
  remark_by     uuid references public.profiles(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint uq_exam_remark unique (school_id, exam_term_id, student_id)
);

create index if not exists idx_exam_remarks_term
  on public.exam_remarks (school_id, exam_term_id);

do $$
begin
  if not exists (select 1 from pg_trigger
                 where tgname = 'trg_exam_remarks_school'
                   and tgrelid = 'public.exam_remarks'::regclass) then
    create trigger trg_exam_remarks_school before insert or update
      on public.exam_remarks for each row execute function public.enforce_school_id();
  end if;
  if not exists (select 1 from pg_trigger
                 where tgname = 'trg_audit_exam_remarks'
                   and tgrelid = 'public.exam_remarks'::regclass) then
    create trigger trg_audit_exam_remarks after insert or update or delete
      on public.exam_remarks for each row execute function public.audit_trigger();
  end if;
end $$;

alter table public.exam_remarks enable row level security;

-- Staff may read remarks for their own school. Writes go through the function
-- below so the class-teacher scope is enforced in one place.
drop policy if exists exam_remarks_select on public.exam_remarks;
create policy exam_remarks_select on public.exam_remarks for select to authenticated
  using (school_id = public.current_school_id() and public.is_staff());

-- ---------------------------------------------------------------------------
-- 2. Write a remark
--
-- A class teacher may write one for their own class, which is the whole point —
-- the remark is theirs. Owner, principal and clerk may write any. A SUBJECT
-- teacher may not: they see one subject, and the remark on a report card is a
-- judgement about the whole child.
-- ---------------------------------------------------------------------------
create or replace function public.fn_set_exam_remark(
  p_exam_term_id uuid, p_student_id uuid, p_remark text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_term   record;
  v_enr    record;
  v_text   text := nullif(btrim(coalesce(p_remark, '')), '');
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('students', p_student_id);

  select * into v_term from public.exam_terms
  where id = p_exam_term_id and school_id = v_school;
  if not found then raise exception 'Exam term not found'; end if;
  -- A locked term is a published result. Editing the remark afterwards changes
  -- what a parent was already shown.
  if v_term.is_locked then
    raise exception 'This exam term is locked; the remark can no longer be changed';
  end if;

  select e.* into v_enr from public.enrollments e
  where e.student_id = p_student_id and e.session_id = v_term.session_id
    and e.school_id = v_school and e.status = 'active'
  limit 1;
  if not found then
    raise exception 'That student is not enrolled in this exam term''s session';
  end if;

  if not public.has_role('owner', 'principal', 'admin_clerk') then
    if not public.fn_may_manage_class(v_enr.session_id, v_enr.class_id, v_enr.section_id) then
      raise exception 'You can only write remarks for your own class'
        using errcode = '42501';
    end if;
    -- fn_may_manage_class is true for a subject teacher assigned to the class,
    -- so the role itself has to be excluded: a remark is a judgement about the
    -- whole child, and a subject teacher sees one subject.
    if public.has_role('subject_teacher') and not public.has_role('class_teacher') then
      raise exception 'Only the class teacher writes the report-card remark'
        using errcode = '42501';
    end if;
  end if;

  -- Blank means "remove it", rather than storing an empty string that prints as
  -- a mysterious gap on the card.
  if v_text is null then
    delete from public.exam_remarks
    where school_id = v_school and exam_term_id = p_exam_term_id
      and student_id = p_student_id;
    return;
  end if;

  insert into public.exam_remarks (school_id, exam_term_id, student_id, remark, remark_by)
  values (v_school, p_exam_term_id, p_student_id, v_text, auth.uid())
  on conflict (school_id, exam_term_id, student_id) do update
    set remark = excluded.remark,
        remark_by = excluded.remark_by,
        updated_at = now();
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The class list a teacher fills in
--
-- Every student in the class, with the remark if there is one — not only the
-- ones already written. A screen that shows only existing remarks gives a
-- teacher no way to find the children they have not done yet.
-- ---------------------------------------------------------------------------
create or replace function public.fn_exam_remarks(p_exam_term_id uuid, p_class_id uuid)
-- `class_position`, not `position`: the latter is a reserved word in a
-- `returns table` list (Postgres reads it as the position(x in y) function), and
-- the longer name says what it actually means anyway.
returns table (
  student_id uuid, student_name text, gr_no text, roll_no text,
  section_name text, remark text, remark_by_name text, updated_at timestamptz,
  percentage numeric, grade text, class_position int)
language plpgsql stable security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_session uuid;
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('classes', p_class_id);

  select session_id into v_session from public.exam_terms
  where id = p_exam_term_id and school_id = v_school;
  if v_session is null then raise exception 'Exam term not found'; end if;

  return query
  select s.id, s.full_name, s.gr_no, e.roll_no, sec.name,
         r.remark, coalesce(p.full_name, '—'), r.updated_at,
         -- The teacher's own marks, alongside, because a remark written without
         -- seeing the result is a remark about nothing.
         rc.percentage, rc.grade, rc.position
  from public.enrollments e
  join public.students s on s.id = e.student_id and s.school_id = v_school
  left join public.sections sec on sec.id = e.section_id and sec.school_id = v_school
  left join public.exam_remarks r
         on r.exam_term_id = p_exam_term_id and r.student_id = s.id
        and r.school_id = v_school
  left join public.profiles p on p.id = r.remark_by
  -- The LATEST version only. Older versions are superseded and showing them
  -- beside a remark would put two different percentages on one row.
  left join lateral (
    select c.percentage, c.grade, c.position
    from public.result_cards c
    where c.enrollment_id = e.id and c.exam_term_id = p_exam_term_id
      and c.school_id = v_school
    order by c.version desc
    limit 1
  ) rc on true
  where e.school_id = v_school and e.session_id = v_session
    and e.class_id = p_class_id and e.status = 'active'
  order by e.roll_no nulls last, s.full_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Position holders
--
-- Top N in every class for one exam term, which is what a prize distribution
-- and the notice board need. Ties are preserved: three children tied for first
-- are all first, and the next is fourth — rank() semantics, matching what is
-- already printed on the result cards so the two can never disagree.
--
-- `withheld` is carried through deliberately. A school about to announce a
-- position holder whose fees are unpaid, and whose result is therefore withheld,
-- needs to know BEFORE the announcement rather than after.
-- ---------------------------------------------------------------------------
create or replace function public.fn_position_holders(
  p_exam_term_id uuid, p_top int default 3)
returns table (
  class_id uuid, class_name text, level_order int,
  class_position int, student_id uuid, student_name text, gr_no text,
  roll_no text, section_name text,
  total_marks numeric, total_max numeric, percentage numeric, grade text,
  withheld boolean, remark text, tied_with int)
language plpgsql stable security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_session uuid;
  v_top     int := greatest(coalesce(p_top, 3), 1);
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);

  select session_id into v_session from public.exam_terms
  where id = p_exam_term_id and school_id = v_school;
  if v_session is null then raise exception 'Exam term not found'; end if;

  return query
  with latest as (
    -- One row per student: the newest result-card version for this term.
    -- Mixing versions would rank a student's old total against another's new
    -- one, which is the sort of thing nobody notices until prize day.
    select distinct on (rc.enrollment_id)
           rc.enrollment_id, rc.student_id, rc.total_marks, rc.total_max,
           rc.percentage, rc.grade, rc.position, rc.frozen
    from public.result_cards rc
    where rc.exam_term_id = p_exam_term_id and rc.school_id = v_school
    order by rc.enrollment_id, rc.version desc
  ),
  with_class as (
    select l.*, e.class_id, e.section_id, e.roll_no
    from latest l
    join public.enrollments e on e.id = l.enrollment_id and e.school_id = v_school
    where e.session_id = v_session and e.status = 'active'
  ),
  counted as (
    -- How many share this position in this class. A "1" that is really a
    -- three-way tie should say so on the notice.
    select w.*, count(*) over (partition by w.class_id, w.position) as tied
    from with_class w
  )
  select c.class_id, cl.name, cl.level_order,
         c.position, c.student_id, s.full_name, s.gr_no,
         c.roll_no, sec.name,
         c.total_marks, c.total_max, c.percentage, c.grade,
         coalesce((c.frozen->>'withheld')::boolean, false),
         r.remark,
         c.tied::int
  from counted c
  join public.students s on s.id = c.student_id and s.school_id = v_school
  join public.classes cl on cl.id = c.class_id and cl.school_id = v_school
  left join public.sections sec on sec.id = c.section_id and sec.school_id = v_school
  left join public.exam_remarks r
         on r.exam_term_id = p_exam_term_id and r.student_id = c.student_id
        and r.school_id = v_school
  where c.position is not null
    and c.position <= v_top
    -- A child who was never marked at all must not be a position holder, and
    -- `percentage` cannot tell you: fn_generate_result_cards coalesces the mark
    -- sum to 0, so "never entered" and "sat and scored nothing" both come out as
    -- 0.00. In a small class — and senior classes here can be tiny — that would
    -- put a child with no marks to their name inside the top three.
    --
    -- So the distinction is drawn where it actually exists: does the child have
    -- ANY mark row for this term? A child who sat and scored zero does have one,
    -- and stays in the ranking, because they are genuinely part of the order.
    and exists (
      select 1
      from public.mark_entries me
      join public.exam_subjects es2 on es2.id = me.exam_subject_id
      where me.enrollment_id = c.enrollment_id
        and me.school_id = v_school
        and es2.exam_term_id = p_exam_term_id
    )
  order by cl.level_order, cl.name, c.position, s.full_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Grants
-- ---------------------------------------------------------------------------
grant execute on function public.fn_set_exam_remark(uuid, uuid, text) to authenticated;
grant execute on function public.fn_exam_remarks(uuid, uuid) to authenticated;
grant execute on function public.fn_position_holders(uuid, int) to authenticated;

revoke all on function public.fn_set_exam_remark(uuid, uuid, text) from anon;
revoke all on function public.fn_exam_remarks(uuid, uuid) from anon;
revoke all on function public.fn_position_holders(uuid, int) from anon;
