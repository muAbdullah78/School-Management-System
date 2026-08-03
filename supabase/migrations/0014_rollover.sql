-- =============================================================================
-- Academic-year rollover / promotion.
--
-- The spec flags this as the feature whose absence "breaks the product within
-- 12 months": at year end the whole roster must move to the next session —
-- promoted a class up, detained (retained) in place, or graduated to alumni —
-- with new roll numbers, arrears carried across the boundary, and a way to UNDO
-- a mistake. It is owner/principal only.
--
-- Model (see docs/02-DATA-MODEL.md): identity (Student) is lifelong; a new
-- Enrollment is created for the target session, linked to the source via
-- enrollments.promoted_from, and the source enrollment is stamped
-- promoted/retained/graduated. Arrears need NO copying — student_balance() is
-- global (all non-void invoices − payments), so last year's dues follow the
-- student automatically and surface on the new session's defaulter list as soon
-- as the student has an active enrollment there.
--
--   fn_rollover(from, to, rules, commit) — preview (commit=false, no writes) or
--     apply (commit=true). `rules` is a jsonb array of per-class instructions:
--       [{ "from_class_id": uuid, "action": "promote"|"retain"|"graduate",
--          "to_class_id": uuid|null }]
--     A class with no rule defaults to promote → next class by level_order, or
--     graduate if it is already the top class.
--   fn_rollover_undo(to) — reverse the promotions/retentions of a rollover, but
--     only while the target session has no activity yet (safe undo).
-- =============================================================================

create or replace function public.fn_rollover(
  p_from uuid, p_to uuid, p_rules jsonb default '[]'::jsonb, p_commit boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_promoted  int := 0;
  v_retained  int := 0;
  v_graduated int := 0;
  v_unmapped  int := 0;
  v_skipped   int := 0;
  v_rows      jsonb;
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only the owner or principal may run a year-end rollover';
  end if;
  if p_from is null or p_to is null then raise exception 'Both sessions are required'; end if;
  if p_from = p_to then raise exception 'The target session must differ from the source'; end if;
  if not exists (select 1 from public.academic_sessions where id = p_from) then
    raise exception 'Source session does not exist'; end if;
  if not exists (select 1 from public.academic_sessions where id = p_to) then
    raise exception 'Target session does not exist'; end if;
  if exists (select 1 from public.academic_sessions where id = p_to and is_closed) then
    raise exception 'Target session is closed'; end if;
  if p_rules is null or jsonb_typeof(p_rules) <> 'array' then
    raise exception 'rules must be a JSON array'; end if;

  -- Build the plan for every active enrolment in the source session. A student
  -- who already has an enrolment in the target session is left out (skipped).
  drop table if exists _rollover_plan;
  create temp table _rollover_plan on commit drop as
  with eff as (   -- effective rule per source class (explicit rule, else default)
    select c.id as from_class, c.name as from_class_name,
      coalesce(pr.action, case when nx.id is not null then 'promote' else 'graduate' end) as action,
      case
        when pr.action = 'retain'  then c.id
        when pr.action = 'promote' then pr.to_class_id
        when pr.action = 'graduate' then null
        when pr.action is null and nx.id is not null then nx.id
        else null
      end as to_class
    from public.classes c
    left join lateral (
      select r->>'action' as action, nullif(r->>'to_class_id','')::uuid as to_class_id
      from jsonb_array_elements(p_rules) r
      where (r->>'from_class_id')::uuid = c.id
      limit 1
    ) pr on true
    left join lateral (
      select id from public.classes c2
      where c2.active and c2.level_order > c.level_order
      order by c2.level_order limit 1
    ) nx on true
    where c.active
  ),
  plan as (
    select e.id as from_enr, e.student_id, s.full_name as name, s.gr_no as gr,
           e.class_id as from_class, eff.from_class_name,
           eff.action, eff.to_class, e.section_id as from_section, e.roll_no as old_roll,
           public.student_balance(e.student_id) as balance,
           exists (select 1 from public.enrollments e2
                   where e2.student_id = e.student_id and e2.session_id = p_to) as already
    from public.enrollments e
    join public.students s on s.id = e.student_id
    join eff on eff.from_class = e.class_id
    where e.session_id = p_from and e.status = 'active'
  )
  select
    p.from_enr, p.student_id, p.name, p.gr, p.from_class, p.from_class_name,
    p.action, p.to_class,
    (select tc.name from public.classes tc where tc.id = p.to_class) as to_class_name,
    p.from_section,
    -- carry the section by NAME into the target class, if such a section exists
    (select sec2.id from public.sections sec2
       join public.sections sec1 on sec1.id = p.from_section
      where sec2.class_id = p.to_class and lower(sec2.name) = lower(sec1.name)
      limit 1) as to_section,
    p.old_roll, p.balance, p.already,
    null::text as proposed_roll
  from plan p;

  -- Assign roll numbers per target (class, section), continuing from any existing
  -- rolls already in the target session.
  with r as (
    select pl.from_enr,
      (seed.maxroll + row_number() over (
         partition by pl.to_class, pl.to_section
         order by nullif(regexp_replace(coalesce(pl.old_roll,''),'[^0-9]','','g'),'')::int nulls last, pl.name
       ))::text as roll
    from _rollover_plan pl
    join lateral (
      select coalesce(max(nullif(regexp_replace(coalesce(e.roll_no,''),'[^0-9]','','g'),'')::int), 0) as maxroll
      from public.enrollments e
      where e.session_id = p_to and e.class_id = pl.to_class
        and e.section_id is not distinct from pl.to_section
    ) seed on true
    where not pl.already and pl.action in ('promote','retain') and pl.to_class is not null
  )
  update _rollover_plan pl set proposed_roll = r.roll from r where r.from_enr = pl.from_enr;

  -- Tally
  select
    count(*) filter (where not already and action = 'promote'  and to_class is not null),
    count(*) filter (where not already and action = 'retain'),
    count(*) filter (where not already and action = 'graduate'),
    count(*) filter (where not already and action = 'promote'  and to_class is null),
    count(*) filter (where already)
  into v_promoted, v_retained, v_graduated, v_unmapped, v_skipped
  from _rollover_plan;

  if p_commit then
    -- 1. create the new enrolments (promote + retain)
    insert into public.enrollments(student_id, session_id, class_id, section_id, roll_no, status, promoted_from)
    select student_id, p_to, to_class, to_section, proposed_roll, 'active', from_enr
    from _rollover_plan
    where not already and action in ('promote','retain') and to_class is not null;

    -- 2. stamp the source enrolments
    update public.enrollments e set status = 'promoted'
      from _rollover_plan pl where pl.from_enr = e.id
        and not pl.already and pl.action = 'promote' and pl.to_class is not null;
    update public.enrollments e set status = 'retained'
      from _rollover_plan pl where pl.from_enr = e.id
        and not pl.already and pl.action = 'retain';
    update public.enrollments e set status = 'graduated'
      from _rollover_plan pl where pl.from_enr = e.id
        and not pl.already and pl.action = 'graduate';

    -- 3. graduates become alumni at the identity level
    update public.students s set status = 'graduated'
      from _rollover_plan pl where pl.student_id = s.id
        and not pl.already and pl.action = 'graduate';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'student_id', student_id, 'name', name, 'gr_no', gr,
    'from_class', from_class_name, 'to_class', to_class_name,
    'action', case when already then 'skipped'
                   when action = 'promote' and to_class is null then 'unmapped'
                   else action end,
    'roll_no', proposed_roll, 'balance', balance,
    'message', case when already then 'Already enrolled in the target session'
                    when action = 'promote' and to_class is null then 'No target class chosen'
                    else null end
  ) order by from_class_name, name), '[]'::jsonb)
  into v_rows from _rollover_plan;

  return jsonb_build_object(
    'commit', p_commit, 'from_session', p_from, 'to_session', p_to,
    'promoted', v_promoted, 'retained', v_retained, 'graduated', v_graduated,
    'unmapped', v_unmapped, 'skipped', v_skipped,
    'total', v_promoted + v_retained + v_graduated + v_unmapped + v_skipped,
    'rows', v_rows);
end;
$$;

-- Undo the promotions/retentions of a rollover into p_to — but only while nothing
-- has happened in the target session yet, so the reversal is always safe. Graduated
-- (alumni) students are left as-is and reported, to avoid reactivating a student who
-- was graduated deliberately; reinstate those individually from the profile.
create or replace function public.fn_rollover_undo(p_to uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_undone   int := 0;
  v_grads    int;
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only the owner or principal may undo a rollover';
  end if;
  if p_to is null then raise exception 'Target session is required'; end if;

  -- Guard: refuse if any real work already exists in the target session.
  if exists (select 1 from public.invoices where session_id = p_to)
     or exists (select 1 from public.assessments where session_id = p_to)
     or exists (select 1 from public.exam_terms where session_id = p_to)
     or exists (select 1 from public.attendance_daily ad
                join public.enrollments e on e.id = ad.enrollment_id
                where e.session_id = p_to)
  then
    raise exception 'Cannot undo: attendance, fees or exams already recorded in the target session';
  end if;

  -- Reactivate the source enrolments, then remove the rollover-created ones.
  update public.enrollments old set status = 'active'
    from public.enrollments new
    where new.session_id = p_to and new.promoted_from is not null
      and old.id = new.promoted_from and old.status in ('promoted','retained');

  select count(*) into v_undone from public.enrollments
    where session_id = p_to and promoted_from is not null;
  delete from public.enrollments
    where session_id = p_to and promoted_from is not null;

  select count(*) into v_grads from public.students where status = 'graduated';

  return jsonb_build_object(
    'undone', v_undone,
    'note', 'Promotions and retentions reversed. Graduated (alumni) students, if any, were left as-is — reinstate individually from the student profile.',
    'graduated_total', v_grads);
end;
$$;

grant execute on function public.fn_rollover(uuid, uuid, jsonb, boolean) to authenticated;
grant execute on function public.fn_rollover_undo(uuid) to authenticated;
