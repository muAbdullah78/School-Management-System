-- =============================================================================
-- 0055 — The year-end rollover promoted children into OTHER SCHOOLS' classrooms.
--
-- This is the most serious defect found in this project.
--
-- WHAT HAPPENED
--
-- fn_rollover decides where each class promotes to. With no explicit rule it
-- takes "the next class up", which it found like this:
--
--     select id from public.classes c2
--     where c2.active and c2.level_order > c.level_order
--     order by c2.level_order limit 1
--
-- There is no school in that query, and the function is SECURITY DEFINER, so
-- RLS never applies. It therefore searched the classes of EVERY SCHOOL on the
-- platform and returned the globally-lowest class above the current level.
--
-- It is not an edge case. Proven by running it:
--
--   * School A tops out at Class 10 and has no class above it, so its leavers
--     should GRADUATE. School B has a Class 11. A's rollover reported
--     "promoted: 1" and enrolled A's child in
--     "B ELEVEN — SHOULD NEVER BE REACHED FROM SCHOOL A".
--
--   * Worse, the ORDINARY case. School A has Class 5 and Class 6; school B also
--     has a Class 6. Both sixes carry level_order 6, so the `order by
--     c2.level_order limit 1` tie is settled by whichever row the heap hands
--     back first — school B's. Five consecutive runs put A's child in B's
--     classroom every time.
--
-- So on a live deployment with more than one school, a school's year-end
-- rollover — the one operation that touches every child, once a year — scatters
-- its pupils into other schools' classes. The enrolment carries school A's
-- school_id while pointing at school B's class, which means A's own screens
-- print another school's class names, no fee structure exists for that class so
-- the child is billed nothing, and a child who should be an alumnus is not.
--
-- WHY THE EXISTING GUARD MISSED IT
--
-- dashboard.sql assertion 20 checks that every SECURITY DEFINER function
-- reading a tenant table mentions current_school_id / assert_own / school_id
-- somewhere in its body. fn_rollover calls assert_own on both session ids, so
-- the whole function was treated as scoped and its individual queries were
-- never examined. One correct check exempted eight incorrect ones. That
-- coarseness is recorded here rather than quietly fixed: a per-query analysis
-- is not something to bolt on in a hurry, and the honest statement is that the
-- guard proves a function was CONSIDERED, not that every query in it is scoped.
--
-- WHAT IS FIXED
--
-- Every query in both functions is now scoped to the caller's school:
-- the class ladder, the class list, the "already enrolled" probe, the source
-- enrolments, the displayed target name, the section carry-over, the roll-number
-- seed, and all four writes. Rule-supplied class ids go through assert_own, so
-- naming another school's class is refused outright instead of honoured.
--
-- Two further changes, each with its own reason:
--
--   * A tie-break on the class ladder (order by level_order, id). Two classes at
--     the same level_order inside ONE school were still undefined, which could
--     make a dry run disagree with the commit — the worst possible property for
--     a screen whose whole purpose is "check this before you commit".
--
--   * The rollover now stamps students.left_on and leaving_reason when it
--     graduates a year group, because 0054 made those the fields a leaving is
--     recorded in. Without it the largest leaving event in the school year —
--     an entire final-year class — would be missing from the leavers report.
--
-- fn_rollover_undo had its own unscoped query: it counted graduated children
-- across every tenant and returned the total to this school's principal.
--
-- Both bodies below are pg_get_functiondef() output with only these changes
-- applied, then diffed against the originals. 0052 and 0054 both say why:
-- copy, never retype.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_rollover(p_from uuid, p_to uuid, p_rules jsonb DEFAULT '[]'::jsonb, p_commit boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_school    uuid := public.current_school_id();
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
  perform public.assert_own('academic_sessions', p_from);
  perform public.assert_own('academic_sessions', p_to);
  if p_from = p_to then raise exception 'The target session must differ from the source'; end if;
  if not exists (select 1 from public.academic_sessions where id = p_from) then
    raise exception 'Source session does not exist'; end if;
  if not exists (select 1 from public.academic_sessions where id = p_to) then
    raise exception 'Target session does not exist'; end if;
  if exists (select 1 from public.academic_sessions where id = p_to and is_closed) then
    raise exception 'Target session is closed'; end if;
  if p_rules is null or jsonb_typeof(p_rules) <> 'array' then
    raise exception 'rules must be a JSON array'; end if;
  -- Every class id a RULE names is caller input and must be checked. Without
  -- this, passing another school's class id put this school's children in it.
  perform public.assert_own('classes', nullif(r->>'from_class_id','')::uuid)
     from jsonb_array_elements(p_rules) r;
  perform public.assert_own('classes', nullif(r->>'to_class_id','')::uuid)
     from jsonb_array_elements(p_rules) r;

  -- Build the plan for every active enrolment in the source session. A student
  -- who already has an enrolment in the target session is left out (skipped).
  drop table if exists _rollover_plan;
  create temp table _rollover_plan on commit drop as
  with eff as (   -- effective rule per source class (explicit rule, else default)
    select c.id as from_class, c.name as from_class_name,
      -- 'promote' with a null to_class is what the tally already reports as
      -- `unmapped`, message "No target class chosen" — so an ambiguous rung
      -- surfaces on the dry run and asks the school for a rule, instead of
      -- either guessing a classroom or graduating a whole middle year.
      coalesce(pr.action,
               case when nx.id is not null then 'promote'
                    when nx.has_level_above then 'promote'
                    else 'graduate' end) as action,
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
      -- THE BUG. This picked the next class up ACROSS EVERY SCHOOL, so on a
      -- live multi-tenant deployment a school's year-end rollover promoted its
      -- children into another school's classroom. Not an edge case: with two
      -- schools sharing a normal ladder the level_order values tie and the
      -- winner is whichever row the heap returns first.
      -- Only when the next level up holds EXACTLY ONE class. An id or name
      -- tie-break was the first attempt and it is the wrong answer: a school
      -- with "Class 8" and "Class 8 Science" would have its children silently
      -- funnelled into whichever the sort happened to favour, and nothing on
      -- screen would say a choice had been made on their behalf.
      --
      -- Returning null instead makes the class come out as `unmapped` — a state
      -- the plan already has, with the message "No target class chosen" — so the
      -- dry run shows the school the ambiguity and asks for a rule. It also
      -- removes the last source of nondeterminism between a dry run and its
      -- commit.
      -- Returns the resolved class AND whether a level above exists at all.
      -- Those are different facts and the old code could not tell them apart:
      -- `nx.id is null` meant both "this is the top class, graduate them" and
      -- "the next level is ambiguous". Collapsing the two would mark a Class 7
      -- with two Class 8s above it as having FINISHED SCHOOL.
      select
        -- Aggregated on purpose: `having count(*) = 1` makes the subquery
        -- return NO ROW (hence null) unless exactly one class sits at that
        -- level, and an aggregate is the only shape where a bare column and a
        -- HAVING can coexist.
        (select (array_agg(c2.id))[1] from public.classes c2
          where c2.school_id = v_school and c2.active
            and c2.level_order = lv.next_level
          having count(*) = 1) as id,
        lv.next_level is not null as has_level_above
      from (select min(c3.level_order) as next_level
              from public.classes c3
             where c3.school_id = v_school and c3.active
               and c3.level_order > c.level_order) lv
    ) nx on true
    where c.school_id = v_school and c.active
  ),
  plan as (
    select e.id as from_enr, e.student_id, s.full_name as name, s.gr_no as gr,
           e.class_id as from_class, eff.from_class_name,
           eff.action, eff.to_class, e.section_id as from_section, e.roll_no as old_roll,
           public.student_balance(e.student_id) as balance,
           exists (select 1 from public.enrollments e2
                   where e2.school_id = v_school
                     and e2.student_id = e.student_id and e2.session_id = p_to) as already
    from public.enrollments e
    join public.students s on s.id = e.student_id and s.school_id = v_school
    join eff on eff.from_class = e.class_id
    where e.school_id = v_school and e.session_id = p_from and e.status = 'active'
  )
  select
    p.from_enr, p.student_id, p.name, p.gr, p.from_class, p.from_class_name,
    p.action, p.to_class,
    (select tc.name from public.classes tc
      where tc.id = p.to_class and tc.school_id = v_school) as to_class_name,
    p.from_section,
    -- carry the section by NAME into the target class, if such a section exists
    (select sec2.id from public.sections sec2
       join public.sections sec1 on sec1.id = p.from_section
                                and sec1.school_id = v_school
      where sec2.school_id = v_school
        and sec2.class_id = p.to_class and lower(sec2.name) = lower(sec1.name)
      order by sec2.id
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
      where e.school_id = v_school
        and e.session_id = p_to and e.class_id = pl.to_class
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
      from _rollover_plan pl where pl.from_enr = e.id and e.school_id = v_school
        and not pl.already and pl.action = 'promote' and pl.to_class is not null;
    update public.enrollments e set status = 'retained'
      from _rollover_plan pl where pl.from_enr = e.id and e.school_id = v_school
        and not pl.already and pl.action = 'retain';
    update public.enrollments e set status = 'graduated'
      from _rollover_plan pl where pl.from_enr = e.id and e.school_id = v_school
        and not pl.already and pl.action = 'graduate';

    -- 3. graduates become alumni at the identity level. left_on is stamped
    --    because 0054 made it the field a leaving is recorded in, and a
    --    graduation reached through the rollover is still a leaving — without
    --    it, a whole year group would be absent from the leavers report.
    update public.students s
       set status = 'graduated',
           -- least(): a rollover run BEFORE the session officially ends would
           -- otherwise stamp a leaving date in the future, which
           -- fn_set_student_status refuses outright and which a direct UPDATE
           -- here would sneak past. A child cannot have left tomorrow.
           left_on = coalesce(s.left_on,
                              least((select ses.ends_on from public.academic_sessions ses
                                      where ses.id = p_from and ses.school_id = v_school),
                                    current_date),
                              current_date),
           leaving_reason = coalesce(s.leaving_reason, 'Graduated at the end of the session')
      from _rollover_plan pl where pl.student_id = s.id and s.school_id = v_school
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
$function$;

CREATE OR REPLACE FUNCTION public.fn_rollover_undo(p_to uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_school   uuid := public.current_school_id();
  v_undone   int := 0;
  v_grads    int;
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only the owner or principal may undo a rollover';
  end if;
  if p_to is null then raise exception 'Target session is required'; end if;
  perform public.assert_own('academic_sessions', p_to);

  -- Guard: refuse if any real work already exists in the target session.
  if exists (select 1 from public.invoices
              where school_id = v_school and session_id = p_to)
     or exists (select 1 from public.assessments
                 where school_id = v_school and session_id = p_to)
     or exists (select 1 from public.exam_terms
                 where school_id = v_school and session_id = p_to)
     or exists (select 1 from public.attendance_daily ad
                join public.enrollments e on e.id = ad.enrollment_id
                where ad.school_id = v_school
                  and e.school_id = v_school and e.session_id = p_to)
  then
    raise exception 'Cannot undo: attendance, fees or exams already recorded in the target session';
  end if;

  -- Reactivate the source enrolments, then remove the rollover-created ones.
  update public.enrollments old set status = 'active'
    from public.enrollments new
    where new.school_id = v_school
      and new.session_id = p_to and new.promoted_from is not null
      and old.school_id = v_school
      and old.id = new.promoted_from and old.status in ('promoted','retained');

  select count(*) into v_undone from public.enrollments
    where school_id = v_school and session_id = p_to and promoted_from is not null;
  delete from public.enrollments
    where school_id = v_school and session_id = p_to and promoted_from is not null;

  -- Was `from public.students where status = 'graduated'` with NO school
  -- filter, inside a SECURITY DEFINER function: it counted graduated children
  -- across every tenant on the platform and returned the total to this school's
  -- principal. A count is a small leak, and it is still a leak.
  select count(*) into v_grads from public.students
   where school_id = v_school and status = 'graduated';

  return jsonb_build_object(
    'undone', v_undone,
    'note', 'Promotions and retentions reversed. Graduated (alumni) students, if any, were left as-is — reinstate individually from the student profile.',
    'graduated_total', v_grads);
end;
$function$;
