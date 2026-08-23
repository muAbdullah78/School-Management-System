-- =============================================================================
-- 0058 — The result card was wrong, and confidently wrong.
--
-- Demonstrated on a live database before anything here was written. One class of
-- three in class 9, English for everybody, Physics for Science, Civics for Arts,
-- everyone who sat a paper doing well:
--
--   Arts Child     card said 180/275 = 65.45%  grade C  position 1
--                  truth    180/200 = 90.00%  grade A+
--   Science Child  card said 160/275 = 58.18%  grade D  position 2
--                  truth    160/175 = 91.43%  grade A+
--   Unmarked Child card said   0/275 =  0.00%  grade F  position 3
--                  truth    nobody had entered their marks yet
--
-- Three defects, each sufficient on its own to lose a school:
--
--  1. STREAMS WERE IGNORED. total_max summed every paper in the class, so a
--     Science pupil was marked out of the Arts syllabus too and a zero was
--     silently supplied for a paper they were never meant to sit. Two A+ pupils
--     became a C and a D. subjects.stream and enrollments.stream had existed
--     since the schema was written and nothing read either.
--
--  2. IT INVERTED THE RANKING. On the true figures the Science pupil comes
--     first. The card had them second, because the wrong denominator punished
--     them harder — Physics is out of 75, so a missing Civics 100 costs more.
--     Prize day would have gone to the wrong child.
--
--  3. A PUPIL NOBODY HAD MARKED WAS PRINTED AS HAVING FAILED. Not blank, not
--     pending: 0.00%, grade F, ranked. One coalesce(sum(...), 0) made "no mark
--     exists" and "a mark of zero" the same thing.
--
-- And two dead features that are the same bug in slower motion:
--
--  4. exam_subjects.practical_max reached nothing — mark_entries had a single
--     marks column, so a school could set Physics theory 75 + practical 25 and
--     had nowhere to enter the practical.
--  5. exam_subjects.pass_marks was frozen onto every card and never used. No
--     card said Pass or Fail. Pakistani result cards say Pass or Fail.
--
-- The design, with the argument against each decision, is in
-- docs/EXAM-COMPUTATION-DESIGN.md. The assertions are in
-- supabase/tests/exam_computation.sql.
--
-- THE RULE THAT SHAPES ALL OF IT: a refusal is recoverable, a plausible wrong
-- card is not. Where this migration cannot know the answer it raises and names
-- what is missing, rather than supplying a zero.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Practical marks get somewhere to live
-- ---------------------------------------------------------------------------
alter table public.mark_entries
  add column if not exists practical_marks numeric;

comment on column public.mark_entries.practical_marks is
  'The practical half of a subject mark, against exam_subjects.practical_max. '
  'NULL when the subject has no practical component. Kept separate from marks '
  'because a result card shows theory and practical in their own columns.';

-- ---------------------------------------------------------------------------
-- 2. Class assessments can contribute to a term, if the term says so
--
-- Zero is the default and zero is exactly today's behaviour. An engine that
-- silently started reweighting a school's result cards mid-session would be
-- indefensible however correct its arithmetic.
-- ---------------------------------------------------------------------------
alter table public.exam_terms
  add column if not exists assessment_weight_pct numeric not null default 0;

alter table public.exam_terms drop constraint if exists exam_terms_assessment_weight_chk;
alter table public.exam_terms add constraint exam_terms_assessment_weight_chk
  check (assessment_weight_pct >= 0 and assessment_weight_pct <= 100);

comment on column public.exam_terms.assessment_weight_pct is
  'Share of the term result carried by class assessments rather than the term '
  'papers. 0 (the default) means the papers carry all of it, which is what every '
  'term did before 0058.';

-- ---------------------------------------------------------------------------
-- 3. Does this pupil take this subject?
--
-- The single rule the whole stream fix rests on, in one place so it cannot drift
-- between the marksheet, the generator and the tabulation sheet.
--
-- Compared case-insensitively and trimmed: a school that types 'science' in one
-- place and 'Science' in another would otherwise silently exclude every pupil
-- from every streamed paper, which looks exactly like defect 1 and would be
-- blamed on the software, correctly.
-- ---------------------------------------------------------------------------
create or replace function public.fn_takes_subject(
  p_subject_stream text, p_enrollment_stream text
) returns boolean language sql immutable as $$
  select case
    -- No stream on the subject: everybody in the class takes it.
    when nullif(btrim(coalesce(p_subject_stream, '')), '') is null then true
    -- A streamed subject and a pupil with no stream: NOT taken. Generation
    -- refuses in this case rather than relying on this answer (see
    -- fn_generate_result_cards), because a pupil quietly missing half their
    -- subjects is the same silent wrongness in a new place.
    when nullif(btrim(coalesce(p_enrollment_stream, '')), '') is null then false
    else lower(btrim(p_subject_stream)) = lower(btrim(p_enrollment_stream))
  end;
$$;

comment on function public.fn_takes_subject(text, text) is
  'Whether a pupil in a given stream sits a given subject. The one place the '
  'stream rule lives, so the marksheet and the result card cannot disagree.';

-- ---------------------------------------------------------------------------
-- 4. The marksheet stops listing pupils who never sat the paper
--
-- Previously the Physics marksheet listed the Arts pupils too. A teacher either
-- leaves them blank — which used to produce a zero on the card — or types
-- something, and typing something is worse.
--
-- Gains a practical column, and reports whether the subject has one, so the
-- screen can show the right number of boxes.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_exam_marksheet(uuid);
create or replace function public.fn_exam_marksheet(p_exam_subject_id uuid)
returns table (
  enrollment_id uuid, student_id uuid, full_name text, roll_no text,
  section_name text, marks numeric, practical_marks numeric,
  is_absent boolean, is_locked boolean, max_marks numeric, practical_max numeric
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_session uuid; v_class uuid; v_max numeric; v_pmax numeric; v_stream text;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to view the marksheet';
  end if;
  perform public.assert_own('exam_subjects', p_exam_subject_id);

  select t.session_id, es.class_id, es.max_marks, es.practical_max, sub.stream
    into v_session, v_class, v_max, v_pmax, v_stream
  from public.exam_subjects es
  join public.exam_terms t on t.id = es.exam_term_id and t.school_id = v_school
  join public.subjects sub on sub.id = es.subject_id and sub.school_id = v_school
  where es.id = p_exam_subject_id and es.school_id = v_school;
  if v_session is null then raise exception 'Exam subject not found'; end if;

  return query
    select e.id, s.id, s.full_name, e.roll_no, sec.name,
           me.marks, me.practical_marks,
           coalesce(me.is_absent, false), coalesce(me.is_locked, false),
           v_max, coalesce(v_pmax, 0)
    from public.enrollments e
    join public.students s on s.id = e.student_id and s.school_id = v_school
    left join public.sections sec on sec.id = e.section_id and sec.school_id = v_school
    left join public.mark_entries me
      on me.exam_subject_id = p_exam_subject_id and me.enrollment_id = e.id
    where e.school_id = v_school
      and e.session_id = v_session and e.class_id = v_class
      and e.status = 'active' and s.deleted_at is null
      -- The fix for defect 5.
      and public.fn_takes_subject(v_stream, e.stream)
    order by sec.sort_order nulls first,
             coalesce(nullif(regexp_replace(coalesce(e.roll_no, ''), '[^0-9]', '', 'g'), '')::int, 2147483647),
             s.full_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Mark entry accepts a practical mark, and validates it
-- ---------------------------------------------------------------------------
create or replace function public.fn_enter_marks(
  p_exam_subject_id uuid, p_marks jsonb, p_reason text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_actor  uuid := auth.uid();
  v_max    numeric;
  v_pmax   numeric;
  v_total  integer;
  v_marked integer;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to enter marks';
  end if;
  perform public.assert_own('exam_subjects', p_exam_subject_id);
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;
  select max_marks, coalesce(practical_max, 0) into v_max, v_pmax
    from public.exam_subjects where id = p_exam_subject_id and school_id = v_school;
  if v_max is null then raise exception 'Exam subject not found'; end if;

  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where coalesce((e->>'is_absent')::boolean, false) = false
      and nullif(e->>'marks', '') is not null
      and ((e->>'marks')::numeric < 0 or (e->>'marks')::numeric > v_max)
  ) then
    raise exception 'Marks must be between 0 and %', v_max;
  end if;

  -- The practical is validated against its OWN maximum. Checking it against
  -- max_marks would let a 25-mark practical be entered as 70 whenever the theory
  -- paper happened to be out of 75.
  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where coalesce((e->>'is_absent')::boolean, false) = false
      and nullif(e->>'practical_marks', '') is not null
      and ((e->>'practical_marks')::numeric < 0
        or (e->>'practical_marks')::numeric > v_pmax)
  ) then
    if v_pmax = 0 then
      raise exception 'This subject has no practical component, so a practical mark cannot be entered';
    end if;
    raise exception 'Practical marks must be between 0 and %', v_pmax;
  end if;

  select count(distinct (e->>'enrollment_id')) into v_total from jsonb_array_elements(p_marks) e;

  with input as (
    select distinct on (enrollment_id) enrollment_id, marks, practical_marks, is_absent
    from (
      select (e->>'enrollment_id')::uuid as enrollment_id,
             nullif(e->>'marks', '')::numeric as marks,
             nullif(e->>'practical_marks', '')::numeric as practical_marks,
             coalesce((e->>'is_absent')::boolean, false) as is_absent
      from jsonb_array_elements(p_marks) e
    ) q
    order by enrollment_id
  ),
  upserted as (
    insert into public.mark_entries as me
      (exam_subject_id, enrollment_id, marks, practical_marks, max_marks, is_absent, marked_by)
    select p_exam_subject_id, enrollment_id, marks, practical_marks, v_max, is_absent, v_actor
      from input
    on conflict (exam_subject_id, enrollment_id) where exam_subject_id is not null
    do update set marks = excluded.marks,
                  practical_marks = excluded.practical_marks,
                  is_absent = excluded.is_absent,
                  marked_by = excluded.marked_by,
                  corrected_from = case when me.marks is distinct from excluded.marks
                                        then me.marks else me.corrected_from end,
                  -- Only on the rows that actually CHANGED. Stamping the reason
                  -- on an unchanged mark would fill the corrections report with
                  -- rows where nothing happened, which is how a report stops
                  -- being read.
                  correction_reason = case when me.marks is distinct from excluded.marks
                                           then v_reason else me.correction_reason end
    where not me.is_locked
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Setting up a paper, with the practical rule enforced
--
-- Replaces a direct upsert from the client. practical_max > 0 is refused unless
-- subjects.is_practical is set, because two columns that can disagree are how a
-- practical mark ends up somewhere nobody looks.
-- ---------------------------------------------------------------------------
create or replace function public.fn_upsert_exam_subject(
  p_exam_term_id uuid, p_class_id uuid, p_subject_id uuid,
  p_max_marks numeric, p_pass_marks numeric,
  p_practical_max numeric default 0,
  p_exam_date date default null, p_paper_time text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_id uuid; v_is_practical boolean; v_locked boolean;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to set up exam papers' using errcode = '42501';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('classes', p_class_id);
  perform public.assert_own('subjects', p_subject_id);

  select is_locked into v_locked from public.exam_terms
   where id = p_exam_term_id and school_id = v_school;
  if coalesce(v_locked, false) then
    raise exception 'This exam term is locked. Unlock it before changing papers.';
  end if;

  if coalesce(p_max_marks, 0) <= 0 then
    raise exception 'A paper must be out of more than zero marks';
  end if;
  if coalesce(p_pass_marks, 0) < 0
     or coalesce(p_pass_marks, 0) > coalesce(p_max_marks, 0) + coalesce(p_practical_max, 0) then
    raise exception 'The pass mark cannot be more than the total the paper is out of';
  end if;

  select is_practical into v_is_practical from public.subjects
   where id = p_subject_id and school_id = v_school;
  if coalesce(p_practical_max, 0) > 0 and not coalesce(v_is_practical, false) then
    raise exception 'Mark this subject as having a practical before giving it practical marks';
  end if;

  insert into public.exam_subjects
    (school_id, exam_term_id, class_id, subject_id, max_marks, pass_marks,
     practical_max, exam_date, paper_time)
  values (v_school, p_exam_term_id, p_class_id, p_subject_id, p_max_marks, p_pass_marks,
          coalesce(p_practical_max, 0), p_exam_date, nullif(btrim(coalesce(p_paper_time,'')), ''))
  on conflict (exam_term_id, class_id, subject_id)
  do update set max_marks = excluded.max_marks, pass_marks = excluded.pass_marks,
                practical_max = excluded.practical_max,
                exam_date = excluded.exam_date, paper_time = excluded.paper_time
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. What is stopping this class's result cards?
--
-- Called before generation so a screen can show the problem rather than an
-- exception, and called again INSIDE generation so the rule cannot be bypassed
-- by calling the generator directly.
--
-- Returns one row per problem, empty when there is none.
-- ---------------------------------------------------------------------------
create or replace function public.fn_result_readiness(p_exam_term_id uuid, p_class_id uuid)
returns table (problem text, detail text, affected integer)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_session uuid; v_streamed integer;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('classes', p_class_id);

  select session_id into v_session from public.exam_terms
   where id = p_exam_term_id and school_id = v_school;
  if v_session is null then raise exception 'Exam term not found'; end if;

  select count(*) into v_streamed
    from public.exam_subjects es
    join public.subjects sub on sub.id = es.subject_id and sub.school_id = v_school
   where es.school_id = v_school and es.exam_term_id = p_exam_term_id
     and es.class_id = p_class_id
     and nullif(btrim(coalesce(sub.stream, '')), '') is not null;

  -- No papers at all. Worth its own row: without it the "no marks" row below
  -- would be empty too and the screen would say everything is fine.
  return query
  select 'no papers',
         'This class has no papers set up for this term. Add them under Exam Setup.',
         0
  where not exists (
    select 1 from public.exam_subjects
     where school_id = v_school and exam_term_id = p_exam_term_id and class_id = p_class_id);

  -- A streamed class with pupils who have no stream. These pupils would
  -- otherwise get a card carrying only the common subjects, which is the same
  -- silent wrongness this migration exists to remove.
  return query
  select 'pupils without a stream',
         'This class has stream subjects, but these pupils have no stream set: '
           || string_agg(s.full_name || coalesce(' (roll ' || e.roll_no || ')', ''), ', '
                         order by s.full_name),
         count(*)::integer
    from public.enrollments e
    join public.students s on s.id = e.student_id and s.school_id = v_school
   where v_streamed > 0
     and e.school_id = v_school and e.session_id = v_session
     and e.class_id = p_class_id and e.status = 'active' and s.deleted_at is null
     and nullif(btrim(coalesce(e.stream, '')), '') is null
  having count(*) > 0;

  -- Marks not entered. Absent is NOT missing: a pupil marked absent has a fact
  -- recorded about them and scores zero. Only a row that does not exist counts.
  return query
  select 'marks not entered',
         sub.name || ' — ' || count(*)::text || ' pupil'
           || case when count(*) = 1 then '' else 's' end,
         count(*)::integer
    from public.exam_subjects es
    join public.subjects sub on sub.id = es.subject_id and sub.school_id = v_school
    join public.enrollments e
      on e.school_id = v_school and e.session_id = v_session
     and e.class_id = p_class_id and e.status = 'active'
     and public.fn_takes_subject(sub.stream, e.stream)
    join public.students s on s.id = e.student_id and s.school_id = v_school
                          and s.deleted_at is null
    left join public.mark_entries me
      on me.exam_subject_id = es.id and me.enrollment_id = e.id
   where es.school_id = v_school and es.exam_term_id = p_exam_term_id
     and es.class_id = p_class_id
     and me.id is null
   group by sub.name, sub.sort_order
   order by sub.sort_order, sub.name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. The generator, rewritten
--
-- Every change from the previous version is a defect from the header. What has
-- NOT changed: it still INSERTS a new version rather than updating, so a remark
-- in exam_remarks survives regeneration, and the frozen snapshot is still the
-- only thing a reprint reads.
-- ---------------------------------------------------------------------------
create or replace function public.fn_generate_result_cards(
  p_exam_term_id uuid, p_class_id uuid, p_allow_incomplete boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_actor   uuid := auth.uid();
  v_session uuid; v_from date; v_to date; v_withhold boolean; v_aw numeric;
  v_pass_pct numeric;
  v_count   integer := 0;
  v_blockers text;
  v_incomplete integer := 0;
  r         record;
  v_ver integer; v_att numeric; v_grade text; v_frozen jsonb;
  v_bal numeric; v_withheld boolean;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to generate result cards';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('classes', p_class_id);

  select session_id, starts_on, ends_on, result_withheld_for_defaulters,
         coalesce(assessment_weight_pct, 0)
    into v_session, v_from, v_to, v_withhold, v_aw
  from public.exam_terms where id = p_exam_term_id and school_id = v_school;
  if v_session is null then raise exception 'Exam term not found'; end if;

  select coalesce(pass_percent, 33) into v_pass_pct
    from public.school_settings where school_id = v_school;
  v_pass_pct := coalesce(v_pass_pct, 33);

  -- ---- The refusal ---------------------------------------------------------
  -- "No papers" and "pupils without a stream" are ALWAYS fatal: neither can be
  -- rescued by treating the card as provisional, and both produce a card that
  -- is wrong rather than incomplete.
  select string_agg(detail, '; ')
    into v_blockers
    from public.fn_result_readiness(p_exam_term_id, p_class_id)
   where problem in ('no papers', 'pupils without a stream');
  if v_blockers is not null then
    raise exception '%', v_blockers;
  end if;

  select coalesce(sum(affected), 0) into v_incomplete
    from public.fn_result_readiness(p_exam_term_id, p_class_id)
   where problem = 'marks not entered';

  if v_incomplete > 0 and not coalesce(p_allow_incomplete, false) then
    select string_agg(detail, '; ' order by detail)
      into v_blockers
      from public.fn_result_readiness(p_exam_term_id, p_class_id)
     where problem = 'marks not entered';
    -- Named, not counted. "Chemistry is missing for 12 pupils" tells the
    -- principal who to chase; the zero this used to produce told them nothing
    -- and printed those pupils as having failed.
    raise exception 'Marks are missing: %. Enter them, or generate provisional cards on purpose.',
      v_blockers;
  end if;

  for r in
    -- Per pupil, over ONLY the subjects that pupil takes.
    with paper as (
      select es.id, es.subject_id, es.max_marks, es.pass_marks,
             coalesce(es.practical_max, 0) as practical_max,
             sub.name as subject_name, sub.stream, sub.sort_order
        from public.exam_subjects es
        join public.subjects sub on sub.id = es.subject_id and sub.school_id = v_school
       where es.school_id = v_school and es.exam_term_id = p_exam_term_id
         and es.class_id = p_class_id
    ),
    pupil as (
      select e.id as enrollment_id, e.student_id, e.stream, e.bise_reg_no
        from public.enrollments e
        join public.students s on s.id = e.student_id and s.school_id = v_school
                             and s.deleted_at is null
       where e.school_id = v_school and e.session_id = v_session
         and e.class_id = p_class_id and e.status = 'active'
    ),
    -- One row per (pupil, paper they take), with the mark if there is one.
    cell as (
      select p.enrollment_id, p.student_id, p.stream, p.bise_reg_no,
             pa.subject_name, pa.sort_order, pa.max_marks, pa.pass_marks, pa.practical_max,
             me.id is not null           as marked,
             coalesce(me.is_absent, false) as is_absent,
             me.marks                    as theory,
             me.practical_marks          as practical
        from pupil p
        join paper pa on public.fn_takes_subject(pa.stream, p.stream)
        left join public.mark_entries me
          on me.exam_subject_id = pa.id and me.enrollment_id = p.enrollment_id
    ),
    -- Obtained and out-of, per cell. A cell with no mark at all contributes to
    -- NEITHER — that is what makes a provisional card honest instead of a card
    -- full of zeros.
    scored as (
      select c.*,
             case when not c.marked then null
                  when c.is_absent then 0
                  else coalesce(c.theory, 0) + coalesce(c.practical, 0) end as obtained,
             (c.max_marks + c.practical_max) as out_of
        from cell c
    ),
    agg as (
      select enrollment_id, student_id, stream, bise_reg_no,
             coalesce(sum(obtained), 0)                             as exam_marks,
             coalesce(sum(case when marked then out_of end), 0)     as exam_max,
             count(*) filter (where not marked)                     as unmarked,
             count(*) filter (where marked and obtained < pass_marks) as failed_subjects
        from scored
       group by enrollment_id, student_id, stream, bise_reg_no
    ),
    -- The assessment component. Only assessments carrying a weight count, so
    -- every assessment that exists today contributes nothing until somebody
    -- deliberately weights one.
    assess as (
      select me.enrollment_id,
             sum(a.weightage * case when me.is_absent then 0
                                    else coalesce(me.marks, 0) end / nullif(a.max_marks, 0))
               as num,
             sum(a.weightage) as den
        from public.assessments a
        join public.mark_entries me
          on me.assessment_id = a.id and me.enrollment_id in (select enrollment_id from agg)
       where a.school_id = v_school and a.session_id = v_session
         and a.class_id = p_class_id
         and coalesce(a.weightage, 0) > 0
         and coalesce(a.max_marks, 0) > 0
       group by me.enrollment_id
    ),
    pct as (
      select g.*,
             case when g.exam_max > 0 then g.exam_marks / g.exam_max * 100 end as exam_pct,
             case when coalesce(s.den, 0) > 0 then s.num / s.den * 100 end     as assess_pct
        from agg g left join assess s on s.enrollment_id = g.enrollment_id
    ),
    final as (
      select p.*,
             -- When a pupil has no weighted assessment the exam carries the
             -- whole result. NEVER a zero for a component that does not exist.
             case
               when p.exam_pct is null then null
               when v_aw > 0 and p.assess_pct is not null
                 then round(p.exam_pct * (100 - v_aw) / 100 + p.assess_pct * v_aw / 100, 2)
               else round(p.exam_pct, 2)
             end as pct,
             (v_aw > 0 and p.assess_pct is not null) as assessments_counted
        from pct p
    )
    select enrollment_id, student_id, stream, bise_reg_no,
           exam_marks, exam_max, unmarked, failed_subjects,
           exam_pct, assess_pct, pct, assessments_counted,
           -- Ranked on the FINAL percentage, and a pupil with nothing marked at
           -- all is not ranked: nulls last keeps them out of the top of the
           -- order, and the position is left null below.
           case when pct is not null and unmarked = 0
                then rank() over (order by case when unmarked = 0 then pct end desc nulls last)
           end as position
      from final
  loop
    select coalesce(max(version), 0) + 1 into v_ver from public.result_cards
      where enrollment_id = r.enrollment_id and exam_term_id = p_exam_term_id
        and school_id = v_school;

    select case when count(*) = 0 then null else
      round(100.0 * (count(*) filter (where status in ('present','late'))
                     + 0.5 * count(*) filter (where status = 'half_day')) / count(*), 1) end
      into v_att
    from public.attendance_daily
    where enrollment_id = r.enrollment_id and school_id = v_school
      and (v_from is null or attendance_date >= v_from)
      and (v_to   is null or attendance_date <= v_to);

    v_grade    := public.fn_grade_for(r.pct);
    v_bal      := public.student_balance(r.student_id);
    v_withheld := coalesce(v_withhold, false) and coalesce(v_bal, 0) > 0;

    -- The per-subject rows, over only this pupil's subjects, with theory and
    -- practical kept apart so the print can show either.
    select jsonb_build_object(
      'subjects', coalesce(jsonb_agg(jsonb_build_object(
          'subject',   x.subject_name,
          'max',       x.max_marks,
          'practical_max', x.practical_max,
          'pass',      x.pass_marks,
          'marks',     x.theory,
          'practical', x.practical,
          'obtained',  x.obtained,
          'out_of',    x.out_of,
          'is_absent', x.is_absent,
          'marked',    x.marked,
          'passed',    case when x.marked then x.obtained >= x.pass_marks end,
          'grade',     public.fn_grade_for(
                         case when x.marked and x.out_of > 0
                              then round(x.obtained / x.out_of * 100, 2) end)
        ) order by x.sort_order, x.subject_name), '[]'::jsonb),
      'total_marks', r.exam_marks, 'total_max', r.exam_max,
      'exam_percentage', case when r.exam_pct is not null then round(r.exam_pct, 2) end,
      'assessment_percentage', case when r.assess_pct is not null then round(r.assess_pct, 2) end,
      'assessment_weight_pct', case when r.assessments_counted then v_aw else 0 end,
      'percentage', r.pct, 'grade', v_grade, 'position', r.position,
      'attendance_pct', v_att,
      'stream', nullif(btrim(coalesce(r.stream, '')), ''),
      'bise_reg_no', nullif(btrim(coalesce(r.bise_reg_no, '')), ''),
      'failed_subjects', r.failed_subjects,
      -- The verdict. Both facts are recorded, not just the conclusion, so a
      -- school whose promotion rule differs has the numbers in front of them.
      'result', case
                  when r.pct is null then 'PENDING'
                  when r.failed_subjects = 0 and r.pct >= v_pass_pct then 'PASS'
                  else 'FAIL' end,
      'pass_percent', v_pass_pct,
      -- A provisional card SAYS it is provisional, and its denominator excludes
      -- what has not been marked. Both together, or it is the old defect with a
      -- label on it.
      'provisional', r.unmarked > 0,
      'unmarked_subjects', r.unmarked,
      'withheld', v_withheld, 'balance', v_bal,
      'generated_at', now(), 'version', v_ver)
      into v_frozen
    from (
      select sub.name as subject_name, sub.sort_order, es.max_marks, es.pass_marks,
             coalesce(es.practical_max, 0) as practical_max,
             me.id is not null as marked,
             coalesce(me.is_absent, false) as is_absent,
             me.marks as theory, me.practical_marks as practical,
             case when me.id is null then null
                  when coalesce(me.is_absent, false) then 0
                  else coalesce(me.marks, 0) + coalesce(me.practical_marks, 0) end as obtained,
             (es.max_marks + coalesce(es.practical_max, 0)) as out_of
        from public.exam_subjects es
        join public.subjects sub on sub.id = es.subject_id and sub.school_id = v_school
        left join public.mark_entries me
          on me.exam_subject_id = es.id and me.enrollment_id = r.enrollment_id
       where es.school_id = v_school and es.exam_term_id = p_exam_term_id
         and es.class_id = p_class_id
         and public.fn_takes_subject(sub.stream, r.stream)
    ) x;

    insert into public.result_cards(school_id, student_id, enrollment_id, exam_term_id,
      total_marks, total_max, percentage, grade, position, attendance_pct, version,
      frozen, generated_by)
    values (v_school, r.student_id, r.enrollment_id, p_exam_term_id,
      r.exam_marks, r.exam_max, r.pct, v_grade, r.position, v_att, v_ver,
      v_frozen, v_actor);
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object(
    'generated', v_count,
    'provisional', v_incomplete > 0,
    'missing_marks', v_incomplete);
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Board registration numbers and streams, set from the app
--
-- Both columns have existed since the schema was written with no way to fill
-- them in, which is why the stream defect could not even be worked around by
-- hand: there was no screen that could set a pupil's stream.
-- ---------------------------------------------------------------------------
create or replace function public.fn_set_enrollment_stream(
  p_enrollment_id uuid, p_stream text, p_bise_reg_no text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_name text;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('enrollments', p_enrollment_id);

  update public.enrollments
     set stream = nullif(btrim(coalesce(p_stream, '')), ''),
         bise_reg_no = nullif(btrim(coalesce(p_bise_reg_no, '')), ''),
         updated_at = now()
   where id = p_enrollment_id and school_id = v_school;

  select s.full_name into v_name
    from public.enrollments e
    join public.students s on s.id = e.student_id and s.school_id = v_school
   where e.id = p_enrollment_id and e.school_id = v_school;

  return jsonb_build_object(
    'student_name', coalesce(v_name, ''),
    'stream', nullif(btrim(coalesce(p_stream, '')), ''),
    'bise_reg_no', nullif(btrim(coalesce(p_bise_reg_no, '')), ''));
end;
$$;

-- The class list a school works down when setting streams, and the list it fills
-- board forms from. One call, because doing it pupil by pupil is why these
-- columns stayed empty.
create or replace function public.fn_class_streams(p_class_id uuid, p_session_id uuid default null)
returns table (
  enrollment_id uuid, student_id uuid, full_name text, father_name text,
  gr_no text, roll_no text, section_name text, stream text, bise_reg_no text
)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_session uuid;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('classes', p_class_id);

  if p_session_id is null then
    select current_session_id into v_session from public.school_settings
     where school_id = v_school;
  else
    perform public.assert_own('academic_sessions', p_session_id);
    v_session := p_session_id;
  end if;
  if v_session is null then raise exception 'No current session'; end if;

  return query
    select e.id, s.id, s.full_name, s.father_name, s.gr_no, e.roll_no, sec.name,
           e.stream, e.bise_reg_no
      from public.enrollments e
      join public.students s on s.id = e.student_id and s.school_id = v_school
                           and s.deleted_at is null
      left join public.sections sec on sec.id = e.section_id and sec.school_id = v_school
     where e.school_id = v_school and e.session_id = v_session
       and e.class_id = p_class_id and e.status = 'active'
     order by sec.sort_order nulls first,
              coalesce(nullif(regexp_replace(coalesce(e.roll_no, ''), '[^0-9]', '', 'g'), '')::int, 2147483647),
              s.full_name;
end;
$$;

-- Subjects with their stream and practical flag, so the setup screen can show
-- and set both. listSubjects previously selected neither, which is the other
-- half of why the columns stayed empty.
create or replace function public.fn_set_subject_details(
  p_subject_id uuid, p_stream text, p_is_practical boolean
) returns void language plpgsql security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('subjects', p_subject_id);

  -- Turning the practical flag OFF while papers still carry practical marks
  -- would leave those marks unreachable and silently out of every total.
  if not coalesce(p_is_practical, false) and exists (
    select 1 from public.exam_subjects
     where school_id = v_school and subject_id = p_subject_id and coalesce(practical_max, 0) > 0
  ) then
    raise exception 'This subject has papers with practical marks. Set those to zero first.';
  end if;

  update public.subjects
     set stream = nullif(btrim(coalesce(p_stream, '')), ''),
         is_practical = coalesce(p_is_practical, false)
   where id = p_subject_id and school_id = v_school;
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Grants
-- ---------------------------------------------------------------------------
revoke all on function public.fn_takes_subject(text, text) from public;
revoke all on function public.fn_result_readiness(uuid, uuid) from public;
revoke all on function public.fn_upsert_exam_subject(uuid, uuid, uuid, numeric, numeric, numeric, date, text) from public;
revoke all on function public.fn_set_enrollment_stream(uuid, text, text) from public;
revoke all on function public.fn_class_streams(uuid, uuid) from public;
revoke all on function public.fn_set_subject_details(uuid, text, boolean) from public;
revoke all on function public.fn_generate_result_cards(uuid, uuid, boolean) from public;

grant execute on function public.fn_takes_subject(text, text) to authenticated;
grant execute on function public.fn_result_readiness(uuid, uuid) to authenticated;
grant execute on function public.fn_upsert_exam_subject(uuid, uuid, uuid, numeric, numeric, numeric, date, text) to authenticated;
grant execute on function public.fn_set_enrollment_stream(uuid, text, text) to authenticated;
grant execute on function public.fn_class_streams(uuid, uuid) to authenticated;
grant execute on function public.fn_set_subject_details(uuid, text, boolean) to authenticated;
grant execute on function public.fn_generate_result_cards(uuid, uuid, boolean) to authenticated;

-- The two-argument generator is GONE, not left as an overload. Leaving it would
-- mean the app could still call the version with no completeness check, which is
-- the entire defect this migration removes.
drop function if exists public.fn_generate_result_cards(uuid, uuid);
