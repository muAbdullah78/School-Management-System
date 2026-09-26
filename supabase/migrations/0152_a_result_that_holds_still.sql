-- =============================================================================
-- 0152. A result that holds still.
--
-- Exams & Results was read end to end, the screens and every function behind
-- them, and these are the faults. Each is a card that says something untrue, or
-- a door that should have been shut.
--
--  1. A BLANK BOX WAS SAVED AS A ZERO. The marks screen sends every pupil on the
--     sheet, blank ones too, and fn_enter_marks stored a row for each. The
--     generator counts any row as "marked", so a box left blank scored nothing,
--     failed the pupil in that subject, and took them off the "marks are still
--     missing" list. The screen said the opposite in bold: "a blank box means
--     not marked yet". It is the 0058 defect again, arriving by the save button.
--     A blank row now clears the mark (or stores nothing), and the rows it left
--     behind are removed below.
--
--  2. A MARK COULD BE WRITTEN FOR A CHILD WHO IS NOT ON THE PAPER. Any enrolment
--     id was accepted: a pupil of another class, a Science pupil on the Arts
--     paper. Every row must now be on the paper's own sheet.
--
--  3. A SECTION'S TEACHER COULD MARK THE WHOLE CLASS. The paper is set for the
--     class, so the check asked about "any section", and the Maths teacher of
--     5 A could overwrite 5 B's marks. Each row is now checked against the
--     pupil's own section.
--
--  4. NOTHING EVER LOCKED. mark_entries.is_locked and exam_terms.is_locked were
--     read in five places and set in none, so every "locked" branch on this
--     side of the product was dead. After results were released to parents the
--     marks, the papers and the remarks could all still change underneath them.
--     Releasing a class now locks its marks; withdrawing unlocks them. A
--     trigger refuses any write to a released class's marks or papers, whatever
--     path it comes by, and a remark cannot change once its result is out.
--
--  5. A CARD COULD BE RELEASED THAT NO LONGER MATCHED THE MARKS. Marks changed
--     after the cards were made left the cards as they were, silently. The
--     readiness check now says so, and release refuses until they are made
--     again.
--
--  6. AN EXAM TERM COULD NOT BE CORRECTED. No edit, no delete, and
--     result_withheld_for_defaulters defaulted to true with no switch anywhere:
--     every pupil owing a single rupee had their result withheld and the school
--     could not turn it off. fn_save_exam_term and fn_delete_exam_term.
--
--  7. THE REMARK REACHED NOBODY. It printed on no card and appeared in no
--     portal. The card now prints it (the screen change), and the portal shows
--     it with the released result. The remark list also stops listing deleted
--     pupils and sorts roll 10 after roll 9.
--
-- Plus two reads the rebuilt screens need: a term overview (every class's
-- progress in one read) and each paper's progress by section, so a section's
-- teacher sees their own count.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Has this class's result been released?
--
-- "Released" means a parent can see a card: any card of this term and class
-- with published_at set. Not "the newest card is published": after a
-- re-generation the newest card is unpublished and the parent still sees the
-- older one, which is exactly when a change must stay out.
-- ---------------------------------------------------------------------------
create or replace function public.fn__exam_results_released(
  p_exam_term_id uuid, p_class_id uuid, p_school_id uuid
) returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1
      from public.result_cards rc
      join public.enrollments e on e.id = rc.enrollment_id and e.school_id = p_school_id
     where rc.school_id = p_school_id
       and rc.exam_term_id = p_exam_term_id
       and e.class_id = p_class_id
       and rc.published_at is not null);
$$;

revoke all on function public.fn__exam_results_released(uuid, uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. When a mark last CHANGED, which is not when its row was last touched
--
-- updated_at moves on every update, and releasing a class now updates every
-- mark in it (the lock). Asking updated_at "did this change after the card was
-- made?" would answer yes for the whole class the moment it was released. So a
-- mark carries the time its value last changed, kept by a trigger so that
-- every path that writes a mark keeps it.
-- ---------------------------------------------------------------------------
alter table public.mark_entries add column if not exists changed_at timestamptz;
update public.mark_entries set changed_at = updated_at where changed_at is null;
alter table public.mark_entries alter column changed_at set default now();

comment on column public.mark_entries.changed_at is
  'When the mark''s value (theory, practical or absence) last changed. Unlike '
  'updated_at it does not move when only the lock moves, so it can say whether a '
  'result card was made before or after a change.';

create or replace function public.fn__mark_changed_at()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.changed_at := now();
  elsif (new.marks, new.practical_marks, new.is_absent)
        is distinct from (old.marks, old.practical_marks, old.is_absent) then
    new.changed_at := now();
  else
    new.changed_at := old.changed_at;
  end if;
  return new;
end;
$$;

revoke all on function public.fn__mark_changed_at() from public, anon, authenticated;

drop trigger if exists trg_marks_changed_at on public.mark_entries;
create trigger trg_marks_changed_at
  before insert or update on public.mark_entries
  for each row execute function public.fn__mark_changed_at();

-- ---------------------------------------------------------------------------
-- 1, 2, 3. Entering exam marks
--
-- Started from the live definition (0085). What changed:
--   * a row with no theory, no practical and no absence CLEARS the mark
--   * every row must be a pupil on this paper's sheet
--   * a teacher's rows are checked against each pupil's own section
--   * a released class is refused, by name, before anything is written
--   * an absent pupil stores no marks, rather than marks that are then ignored
--   * an unchanged row is not rewritten, so updated_at means "changed", which
--     is what the readiness check below relies on
--   * a changed practical is recorded as a correction too
-- ---------------------------------------------------------------------------
create or replace function public.fn_enter_marks(
  p_exam_subject_id uuid, p_marks jsonb, p_reason text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_actor   uuid := auth.uid();
  v_term    uuid; v_session uuid; v_class uuid; v_subject uuid; v_stream text;
  v_max     numeric;
  v_pmax    numeric;
  v_office  boolean;
  v_total   integer;
  v_saved   integer := 0;
  v_written integer := 0;
  v_cleared integer := 0;
  v_skipped integer := 0;
  v_bad     text;
  v_badn    integer;
  v_reason  text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to enter marks' using errcode = '42501';
  end if;
  perform public.fn__only_these_keys(p_marks, '{enrollment_id,marks,practical_marks,is_absent}'::text[], 'Mark entry');
  perform public.assert_own('exam_subjects', p_exam_subject_id);
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;

  select es.exam_term_id, et.session_id, es.class_id, es.subject_id, sub.stream,
         es.max_marks, coalesce(es.practical_max, 0)
    into v_term, v_session, v_class, v_subject, v_stream, v_max, v_pmax
    from public.exam_subjects es
    join public.exam_terms et on et.id = es.exam_term_id and et.school_id = v_school
    join public.subjects sub on sub.id = es.subject_id and sub.school_id = v_school
   where es.id = p_exam_subject_id and es.school_id = v_school;
  if v_max is null then raise exception 'Exam subject not found'; end if;

  v_office := public.has_role('owner', 'principal', 'admin_clerk');
  if not v_office
     and not public.fn_may_mark_subject(v_session, v_class, null, v_subject) then
    raise exception 'You can only enter marks for a class and subject you teach. '
      'Ask the office to add you under Settings, Staff, Subject Teachers.'
      using errcode = '42501';
  end if;

  if public.fn__exam_results_released(v_term, v_class, v_school) then
    raise exception 'These results have been released to parents, so the marks cannot '
      'change. The owner or principal can withdraw them under Result Cards first.'
      using errcode = '42501';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where coalesce((e->>'is_absent')::boolean, false) = false
      and nullif(e->>'marks', '') is not null
      and ((e->>'marks')::numeric < 0 or (e->>'marks')::numeric > v_max)
  ) then
    raise exception 'Marks must be between 0 and %', v_max;
  end if;

  -- The practical against its OWN maximum (0058).
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

  -- 2. On this paper's sheet: this school, this session, this class, a pupil
  -- the marksheet lists, and one who takes the subject.
  select count(*), string_agg(i.enrollment_id::text, ', ')
    into v_badn, v_bad
    from (select distinct (e->>'enrollment_id')::uuid as enrollment_id
            from jsonb_array_elements(p_marks) e) i
   where not exists (
     select 1
       from public.enrollments en
       join public.students s on s.id = en.student_id and s.school_id = v_school
                             and s.deleted_at is null
      where en.id = i.enrollment_id and en.school_id = v_school
        and en.session_id = v_session and en.class_id = v_class
        and en.status in ('active', 'promoted', 'retained', 'graduated')
        and public.fn_takes_subject(v_stream, en.stream));
  if v_badn > 0 then
    raise exception '% of these pupils % not on this paper''s sheet, so no mark can be entered for them. '
      'Reload the marksheet.', v_badn, case when v_badn = 1 then 'is' else 'are' end
      using errcode = '22023';
  end if;

  -- 3. A teacher's rows, each against the pupil's own section.
  if not v_office then
    select string_agg(s.full_name, ', ' order by s.full_name)
      into v_bad
      from (select distinct (e->>'enrollment_id')::uuid as enrollment_id
              from jsonb_array_elements(p_marks) e) i
      join public.enrollments en on en.id = i.enrollment_id and en.school_id = v_school
      join public.students s on s.id = en.student_id and s.school_id = v_school
     where not public.fn_may_mark_subject(v_session, v_class, en.section_id, v_subject);
    if v_bad is not null then
      raise exception 'You can only enter marks for the sections you teach. Not yours: %', v_bad
        using errcode = '42501';
    end if;
  end if;

  -- 1. A blank row clears the mark. Locked rows are left as they are.
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
  cleared as (
    delete from public.mark_entries me
     using input i
     where me.exam_subject_id = p_exam_subject_id
       and me.enrollment_id = i.enrollment_id
       and me.school_id = v_school
       and not me.is_locked
       and not i.is_absent and i.marks is null and i.practical_marks is null
    returning 1
  )
  select count(*) into v_cleared from cleared;

  with input as (
    select distinct on (enrollment_id) enrollment_id,
           -- An absent pupil stores no marks. Absent scores zero on the card,
           -- and a stored 45 beside an absence is a number nobody can explain.
           case when is_absent then null else marks end as marks,
           case when is_absent then null else practical_marks end as practical_marks,
           is_absent
    from (
      select (e->>'enrollment_id')::uuid as enrollment_id,
             nullif(e->>'marks', '')::numeric as marks,
             nullif(e->>'practical_marks', '')::numeric as practical_marks,
             coalesce((e->>'is_absent')::boolean, false) as is_absent
      from jsonb_array_elements(p_marks) e
    ) q
    where is_absent or marks is not null or practical_marks is not null
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
                                          or me.practical_marks is distinct from excluded.practical_marks
                                        then me.marks else me.corrected_from end,
                  correction_reason = case when me.marks is distinct from excluded.marks
                                             or me.practical_marks is distinct from excluded.practical_marks
                                             or me.is_absent is distinct from excluded.is_absent
                                           then v_reason else me.correction_reason end
    -- Unchanged rows are not rewritten: updated_at is how the readiness check
    -- knows a card is out of date, and re-saving the same sheet is not a change.
    where not me.is_locked
      and (me.marks, me.practical_marks, me.is_absent)
          is distinct from (excluded.marks, excluded.practical_marks, excluded.is_absent)
    returning 1
  )
  select count(*) into v_written from upserted;

  -- What is on the sheet now, for the message: every non-blank row that is not
  -- locked, whether or not it needed writing.
  select count(*) filter (where not coalesce(me.is_locked, false)),
         count(*) filter (where coalesce(me.is_locked, false))
    into v_saved, v_skipped
    from (select distinct (e->>'enrollment_id')::uuid as enrollment_id,
                 coalesce((e->>'is_absent')::boolean, false) as is_absent,
                 nullif(e->>'marks', '') as marks,
                 nullif(e->>'practical_marks', '') as practical_marks
            from jsonb_array_elements(p_marks) e) i
    left join public.mark_entries me
      on me.exam_subject_id = p_exam_subject_id and me.enrollment_id = i.enrollment_id
     and me.school_id = v_school
   where i.is_absent or i.marks is not null or i.practical_marks is not null;

  return jsonb_build_object(
    'marked', v_saved, 'written', v_written, 'cleared', v_cleared,
    'skipped', v_skipped, 'total', v_total);
end;
$$;

revoke all on function public.fn_enter_marks(uuid, jsonb, text) from public, anon;
grant execute on function public.fn_enter_marks(uuid, jsonb, text) to authenticated;

-- The rows the old save left behind: no theory, no practical, not absent. Each
-- one is a pupil the generator scored as zero. Nothing was ever locked, so
-- none of them is a finalised mark; cards already made keep their own copy.
do $repair$
declare v_n integer;
begin
  delete from public.mark_entries
   where exam_subject_id is not null
     and marks is null and practical_marks is null
     and not is_absent and not is_locked;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    raise notice '0152: removed % blank exam mark row(s) that were being counted as zero', v_n;
  end if;
end $repair$;

-- ---------------------------------------------------------------------------
-- 4. The marksheet carries each pupil's section id
--
-- So the screen can show a section's teacher their own pupils. Same body as
-- 0058's, one column more, which needs a drop: a return type cannot change in
-- place.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_exam_marksheet(uuid);
create function public.fn_exam_marksheet(p_exam_subject_id uuid)
returns table (
  enrollment_id uuid, student_id uuid, full_name text, roll_no text,
  section_name text, marks numeric, practical_marks numeric,
  is_absent boolean, is_locked boolean, max_marks numeric, practical_max numeric,
  section_id uuid
) language plpgsql stable security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_session uuid; v_class uuid; v_max numeric; v_pmax numeric; v_stream text;
begin
  if not public.may_view('owner','principal','admin_clerk','class_teacher','subject_teacher') then
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
           v_max, coalesce(v_pmax, 0),
           e.section_id
    from public.enrollments e
    join public.students s on s.id = e.student_id and s.school_id = v_school
    left join public.sections sec on sec.id = e.section_id and sec.school_id = v_school
    left join public.mark_entries me
      on me.exam_subject_id = p_exam_subject_id and me.enrollment_id = e.id
     and me.school_id = v_school
    where e.school_id = v_school
      and e.session_id = v_session and e.class_id = v_class
      and e.status in ('active', 'promoted', 'retained', 'graduated') and s.deleted_at is null
      and public.fn_takes_subject(v_stream, e.stream)
    order by sec.sort_order nulls first, sec.name nulls first,
             coalesce(nullif(regexp_replace(coalesce(e.roll_no, ''), '[^0-9]', '', 'g'), '')::int, 2147483647),
             s.full_name;
end;
$$;

revoke all on function public.fn_exam_marksheet(uuid) from public, anon;
grant execute on function public.fn_exam_marksheet(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Releasing locks, withdrawing unlocks
--
-- Release publishes the newest card of every pupil in the class, as before,
-- and now locks the class's marks for the term. It refuses when the cards are
-- out of date: a card that no longer matches the marks must not reach a parent.
-- ---------------------------------------------------------------------------
create or replace function public.fn_publish_results(p_exam_term_id uuid, p_class_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_n integer;
  v_stale integer;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may release results to parents';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('classes', p_class_id);

  select coalesce(sum(affected), 0) into v_stale
    from public.fn_result_readiness(p_exam_term_id, p_class_id)
   where problem = 'cards out of date';
  if v_stale > 0 then
    raise exception 'Marks have changed for % pupil(s) since these cards were made. Generate '
      'them again, check them, then release.', v_stale
      using errcode = '22023';
  end if;

  update public.mark_entries me
     set is_locked = true
    from public.exam_subjects es
   where es.id = me.exam_subject_id and es.school_id = v_school
     and me.school_id = v_school
     and es.exam_term_id = p_exam_term_id and es.class_id = p_class_id
     and not me.is_locked;

  with latest as (
    select distinct on (rc.enrollment_id) rc.id
    from public.result_cards rc
    join public.enrollments e on e.id = rc.enrollment_id and e.school_id = v_school
    where rc.school_id = v_school
      and rc.exam_term_id = p_exam_term_id and e.class_id = p_class_id
    order by rc.enrollment_id, rc.version desc
  )
  update public.result_cards rc
     set published_at = now()
    from latest l
   where rc.id = l.id and rc.school_id = v_school and rc.published_at is null;

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

create or replace function public.fn_unpublish_results(p_exam_term_id uuid, p_class_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_n integer;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may withdraw results';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('classes', p_class_id);

  update public.result_cards rc
     set published_at = null
    from public.enrollments e
   where e.id = rc.enrollment_id and e.school_id = v_school
     and rc.school_id = v_school
     and rc.exam_term_id = p_exam_term_id and e.class_id = p_class_id
     and rc.published_at is not null;
  get diagnostics v_n = row_count;

  -- Nothing but a release ever locks an exam mark, so withdrawing the release
  -- unlocks every mark of the class and term.
  update public.mark_entries me
     set is_locked = false
    from public.exam_subjects es
   where es.id = me.exam_subject_id and es.school_id = v_school
     and me.school_id = v_school
     and es.exam_term_id = p_exam_term_id and es.class_id = p_class_id
     and me.is_locked;

  return v_n;
end;
$$;

revoke all on function public.fn_publish_results(uuid, uuid) from public, anon;
grant execute on function public.fn_publish_results(uuid, uuid) to authenticated;
revoke all on function public.fn_unpublish_results(uuid, uuid) from public, anon;
grant execute on function public.fn_unpublish_results(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. The door, whatever path the write takes
--
-- fn_enter_marks refuses by name, but marks can also be written through the
-- table's own policies. These triggers are the backstop: a released class's
-- marks and papers do not change. The lock flag itself may always move, which
-- is how release sets it and withdraw clears it. Clearing a whole school sets
-- app.clearing_school and passes, as fn__refuse_destroying_locked_marks does.
-- ---------------------------------------------------------------------------
create or replace function public.fn__released_exam_marks_hold()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_term uuid; v_class uuid;
begin
  if new.exam_subject_id is null then return new; end if;
  if current_setting('app.clearing_school', true) = 'on' then return new; end if;
  if tg_op = 'UPDATE'
     and (new.marks, new.practical_marks, new.is_absent, new.exam_subject_id,
          new.enrollment_id, new.max_marks)
         is not distinct from
         (old.marks, old.practical_marks, old.is_absent, old.exam_subject_id,
          old.enrollment_id, old.max_marks) then
    return new;
  end if;
  select es.exam_term_id, es.class_id into v_term, v_class
    from public.exam_subjects es
   where es.id = new.exam_subject_id
     and es.school_id = coalesce(new.school_id, public.current_school_id());
  if v_term is not null
     and public.fn__exam_results_released(v_term, v_class,
           coalesce(new.school_id, public.current_school_id())) then
    raise exception 'These results have been released to parents, so the marks cannot '
      'change. The owner or principal can withdraw them under Result Cards first.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke all on function public.fn__released_exam_marks_hold() from public, anon, authenticated;

drop trigger if exists trg_marks_released_hold on public.mark_entries;
create trigger trg_marks_released_hold
  before insert or update on public.mark_entries
  for each row execute function public.fn__released_exam_marks_hold();

create or replace function public.fn__released_exam_papers_hold()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_row public.exam_subjects;
begin
  if current_setting('app.clearing_school', true) = 'on' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  v_row := case when tg_op = 'DELETE' then old else new end;
  if public.fn__exam_results_released(v_row.exam_term_id, v_row.class_id, v_row.school_id)
     or (tg_op = 'UPDATE'
         and public.fn__exam_results_released(old.exam_term_id, old.class_id, old.school_id)) then
    raise exception 'These results have been released to parents, so this class''s papers '
      'cannot change. The owner or principal can withdraw them under Result Cards first.'
      using errcode = '42501';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke all on function public.fn__released_exam_papers_hold() from public, anon, authenticated;

drop trigger if exists trg_exam_papers_released_hold on public.exam_subjects;
create trigger trg_exam_papers_released_hold
  before insert or update or delete on public.exam_subjects
  for each row execute function public.fn__released_exam_papers_hold();

-- The advice this guard gives had to name the real way to unlock an exam mark,
-- which until now was no way at all. Same body as 0126's otherwise.
create or replace function public.fn__refuse_destroying_locked_marks()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_locked   integer := 0;
  v_unlocked integer := 0;
  v_what     text;
  v_advice   text;
begin
  if tg_table_name = 'assessments' then
    v_what := format('the assessment "%s"', old.title);
    v_advice := 'Unlock it first from the assessment itself, which asks for a '
             || 'reason and is recorded.';
    select count(*) filter (where is_locked), count(*) filter (where not is_locked)
      into v_locked, v_unlocked
      from public.mark_entries
     where assessment_id = old.id and school_id = old.school_id;

  elsif tg_table_name = 'exam_subjects' then
    v_what := 'this exam paper';
    v_advice := 'Its results have been released to parents, which locked them. '
             || 'The owner or principal can withdraw the results under Result Cards first.';
    select count(*) filter (where is_locked), count(*) filter (where not is_locked)
      into v_locked, v_unlocked
      from public.mark_entries
     where exam_subject_id = old.id and school_id = old.school_id;

  elsif tg_table_name = 'exam_terms' then
    v_what := format('the exam "%s"', old.name);
    v_advice := 'Results in it have been released to parents, which locked those marks. '
             || 'Deleting a whole term is rarely what is wanted: a term with results '
             || 'in it is the record of those results.';
    select count(*) filter (where m.is_locked), count(*) filter (where not m.is_locked)
      into v_locked, v_unlocked
      from public.mark_entries m
      join public.exam_subjects es on es.id = m.exam_subject_id
                                  and es.school_id = old.school_id
     where es.exam_term_id = old.id and m.school_id = old.school_id;
  else
    raise exception 'fn__refuse_destroying_locked_marks has no rule for table '
      '%. Add one, or do not attach the trigger.', tg_table_name;
  end if;

  if current_setting('app.clearing_school', true) = 'on' then
    return old;
  end if;

  if v_locked > 0 then
    raise exception
      'Deleting % would destroy % finalised mark(s), and finalised marks cannot '
      'be deleted. %',
      v_what, v_locked, v_advice
      using errcode = '42501';
  end if;

  if v_unlocked > 0 then
    insert into public.audit_log
      (school_id, actor, actor_role, action, entity, entity_id, before, reason)
    values (old.school_id, auth.uid(),
            (select role from public.profiles where id = auth.uid()),
            'MARKS_DESTROYED_BY_DELETE', tg_table_name, old.id::text,
            jsonb_build_object('marks_deleted', v_unlocked, 'what', v_what),
            format('%s mark(s) went with it. None were finalised.', v_unlocked));
  end if;

  return old;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. A paper of a released class cannot be changed through the screen either
--
-- Same body as 0130's, with the release check beside the term lock.
-- ---------------------------------------------------------------------------
create or replace function public.fn_upsert_exam_subject(
  p_exam_term_id uuid, p_class_id uuid, p_subject_id uuid,
  p_max_marks numeric, p_pass_marks numeric, p_practical_max numeric default 0,
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
  perform public.fn__assert_date_in_session(
            (select et.session_id from public.exam_terms et
              where et.id = p_exam_term_id and et.school_id = v_school),
            p_exam_date, 'Setting an exam paper''s date', false);

  select is_locked into v_locked from public.exam_terms
   where id = p_exam_term_id and school_id = v_school;
  if coalesce(v_locked, false) then
    raise exception 'This exam term is locked. Unlock it before changing papers.';
  end if;
  if public.fn__exam_results_released(p_exam_term_id, p_class_id, v_school) then
    raise exception 'These results have been released to parents, so this class''s papers '
      'cannot change. The owner or principal can withdraw them under Result Cards first.'
      using errcode = '42501';
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

revoke all on function public.fn_upsert_exam_subject(uuid, uuid, uuid, numeric, numeric, numeric, date, text) from public, anon;
grant execute on function public.fn_upsert_exam_subject(uuid, uuid, uuid, numeric, numeric, numeric, date, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4, 7. Remarks: written by the class teacher, frozen once the result is out
-- ---------------------------------------------------------------------------
create or replace function public.fn_set_exam_remark(
  p_exam_term_id uuid, p_student_id uuid, p_remark text
) returns void language plpgsql security definer set search_path = public as $$
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
  if v_term.is_locked then
    raise exception 'This exam term is locked; the remark can no longer be changed';
  end if;

  select e.* into v_enr from public.enrollments e
  where e.student_id = p_student_id and e.session_id = v_term.session_id
    and e.school_id = v_school and e.status in ('active', 'promoted', 'retained', 'graduated')
  limit 1;
  if not found then
    raise exception 'That student is not enrolled in this exam term''s session';
  end if;

  if not public.has_role('owner', 'principal', 'admin_clerk') then
    if not public.fn_may_manage_class(v_enr.session_id, v_enr.class_id, v_enr.section_id) then
      raise exception 'You can only write remarks for your own class'
        using errcode = '42501';
    end if;
    if public.has_role('subject_teacher') and not public.has_role('class_teacher') then
      raise exception 'Only the class teacher writes the report-card remark'
        using errcode = '42501';
    end if;
  end if;

  -- A released result is what the parent was shown, remark and all.
  if public.fn__exam_results_released(p_exam_term_id, v_enr.class_id, v_school) then
    raise exception 'This result has been released to parents, so its remark cannot change. '
      'The owner or principal can withdraw the results under Result Cards first.'
      using errcode = '42501';
  end if;

  if v_text is null then
    delete from public.exam_remarks
    where school_id = v_school and exam_term_id = p_exam_term_id
      and student_id = p_student_id;
    return;
  end if;
  if length(v_text) > 500 then
    raise exception 'A remark is at most 500 characters; this one is %', length(v_text)
      using errcode = '22001';
  end if;

  insert into public.exam_remarks (school_id, exam_term_id, student_id, remark, remark_by)
  values (v_school, p_exam_term_id, p_student_id, v_text, auth.uid())
  on conflict (school_id, exam_term_id, student_id) do update
    set remark = excluded.remark,
        remark_by = excluded.remark_by,
        updated_at = now();
end;
$$;

revoke all on function public.fn_set_exam_remark(uuid, uuid, text) from public, anon;
grant execute on function public.fn_set_exam_remark(uuid, uuid, text) to authenticated;

drop function if exists public.fn_exam_remarks(uuid, uuid);
create function public.fn_exam_remarks(p_exam_term_id uuid, p_class_id uuid)
returns table (
  student_id uuid, student_name text, gr_no text, roll_no text, section_name text,
  remark text, remark_by_name text, updated_at timestamptz,
  percentage numeric, grade text, class_position integer,
  section_id uuid, released boolean
) language plpgsql stable security definer set search_path = public as $$
declare
  v_school   uuid := public.current_school_id();
  v_session  uuid;
  v_released boolean;
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('classes', p_class_id);

  select session_id into v_session from public.exam_terms
  where id = p_exam_term_id and school_id = v_school;
  if v_session is null then raise exception 'Exam term not found'; end if;
  v_released := public.fn__exam_results_released(p_exam_term_id, p_class_id, v_school);

  return query
  select s.id, s.full_name, s.gr_no, e.roll_no, sec.name,
         r.remark, coalesce(p.full_name, '-'), r.updated_at,
         rc.percentage, rc.grade, rc.position,
         e.section_id, v_released
  from public.enrollments e
  join public.students s on s.id = e.student_id and s.school_id = v_school
                        and s.deleted_at is null
  left join public.sections sec on sec.id = e.section_id and sec.school_id = v_school
  left join public.exam_remarks r
         on r.exam_term_id = p_exam_term_id and r.student_id = s.id
        and r.school_id = v_school
  left join public.profiles p on p.id = r.remark_by
  left join lateral (
    select c.percentage, c.grade, c.position
    from public.result_cards c
    where c.enrollment_id = e.id and c.exam_term_id = p_exam_term_id
      and c.school_id = v_school
    order by c.version desc
    limit 1
  ) rc on true
  where e.school_id = v_school and e.session_id = v_session
    and e.class_id = p_class_id and e.status in ('active', 'promoted', 'retained', 'graduated')
  order by sec.sort_order nulls first, sec.name nulls first,
           coalesce(nullif(regexp_replace(coalesce(e.roll_no, ''), '[^0-9]', '', 'g'), '')::int, 2147483647),
           s.full_name;
end;
$$;

revoke all on function public.fn_exam_remarks(uuid, uuid) from public, anon;
grant execute on function public.fn_exam_remarks(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. The readiness check says when the cards are out of date
--
-- Same three rows as 0058, and a fourth: pupils whose marks changed after
-- their newest card was made, or who have marks and no card at all. Not fatal
-- to generating (generating is the cure); fatal to releasing.
-- ---------------------------------------------------------------------------
create or replace function public.fn_result_readiness(p_exam_term_id uuid, p_class_id uuid)
returns table (problem text, detail text, affected integer)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_session uuid; v_streamed integer;
begin
  if not public.may_view('owner','principal','admin_clerk','class_teacher') then
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

  return query
  select 'no papers',
         'This class has no papers set up for this term. Add them under Exam Setup.',
         0
  where not exists (
    select 1 from public.exam_subjects
     where school_id = v_school and exam_term_id = p_exam_term_id and class_id = p_class_id);

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
     and e.class_id = p_class_id and e.status in ('active', 'promoted', 'retained', 'graduated') and s.deleted_at is null
     and nullif(btrim(coalesce(e.stream, '')), '') is null
  having count(*) > 0;

  return query
  select 'marks not entered',
         sub.name || ': ' || count(*)::text || ' pupil'
           || case when count(*) = 1 then '' else 's' end,
         count(*)::integer
    from public.exam_subjects es
    join public.subjects sub on sub.id = es.subject_id and sub.school_id = v_school
    join public.enrollments e
      on e.school_id = v_school and e.session_id = v_session
     and e.class_id = p_class_id and e.status in ('active', 'promoted', 'retained', 'graduated')
     and public.fn_takes_subject(sub.stream, e.stream)
    join public.students s on s.id = e.student_id and s.school_id = v_school
                          and s.deleted_at is null
    left join public.mark_entries me
      on me.exam_subject_id = es.id and me.enrollment_id = e.id
     and me.school_id = v_school
   where es.school_id = v_school and es.exam_term_id = p_exam_term_id
     and es.class_id = p_class_id
     and me.id is null
   group by sub.name, sub.sort_order
   order by sub.sort_order, sub.name;

  -- Only once some card exists: before the first generation every pupil is
  -- "without a card" and saying so is noise.
  --
  -- Out of date means any of: marks and no card; a mark whose value changed
  -- after the newest card was made; or a different number of papers marked now
  -- than the card carries, which is how a mark CLEARED after the card shows up
  -- (a deleted row has no changed_at to compare).
  return query
  with latest as (
    select distinct on (rc.enrollment_id) rc.enrollment_id, rc.generated_at,
           (select count(*)::int
              from jsonb_array_elements(coalesce(rc.frozen->'subjects', '[]'::jsonb)) x
             where coalesce((x->>'marked')::boolean, true)) as marked_on_card
      from public.result_cards rc
      join public.enrollments e on e.id = rc.enrollment_id and e.school_id = v_school
      join public.students s on s.id = e.student_id and s.school_id = v_school
                            and s.deleted_at is null
     where rc.school_id = v_school and rc.exam_term_id = p_exam_term_id
       and e.class_id = p_class_id
       and e.status in ('active', 'promoted', 'retained', 'graduated')
     order by rc.enrollment_id, rc.version desc
  ),
  marked as (
    select me.enrollment_id, max(me.changed_at) as changed_at, count(*)::int as marked_now
      from public.mark_entries me
      join public.exam_subjects es on es.id = me.exam_subject_id and es.school_id = v_school
      join public.subjects sub on sub.id = es.subject_id and sub.school_id = v_school
      join public.enrollments e on e.id = me.enrollment_id and e.school_id = v_school
      join public.students s on s.id = e.student_id and s.school_id = v_school
                            and s.deleted_at is null
     where me.school_id = v_school
       and es.exam_term_id = p_exam_term_id and es.class_id = p_class_id
       and e.status in ('active', 'promoted', 'retained', 'graduated')
       and public.fn_takes_subject(sub.stream, e.stream)
     group by me.enrollment_id
  ),
  stale as (
    select coalesce(m.enrollment_id, l.enrollment_id) as enrollment_id
      from marked m
      full join latest l on l.enrollment_id = m.enrollment_id
     where (l.enrollment_id is null and m.marked_now > 0)
        or m.changed_at > l.generated_at
        or coalesce(m.marked_now, 0) <> coalesce(l.marked_on_card, 0)
  )
  select 'cards out of date',
         'Marks have changed for ' || count(*)::text || ' pupil'
           || case when count(*) = 1 then '' else 's' end
           || ' since the cards were made. Generate them again to include the changes.',
         count(*)::integer
    from stale
   where exists (select 1 from latest)
  having count(*) > 0;
end;
$$;

revoke all on function public.fn_result_readiness(uuid, uuid) from public, anon;
grant execute on function public.fn_result_readiness(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. An exam term can be corrected
--
-- One writer for create and edit, so the rules live once: a name, unique in its
-- year; both dates or neither, in order, inside the year; and the switch for
-- withholding results over unpaid fees, which defaulted to on and could not be
-- turned off.
-- ---------------------------------------------------------------------------
create or replace function public.fn_save_exam_term(
  p_id uuid, p_session_id uuid, p_name text, p_term_type text,
  p_starts_on date, p_ends_on date, p_withhold boolean
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_session uuid;
  v_name    text := btrim(coalesce(p_name, ''));
  v_type    public.term_type;
  v_id      uuid;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted to set up exam terms' using errcode = '42501';
  end if;

  if p_id is null then
    perform public.assert_own('academic_sessions', p_session_id);
    v_session := p_session_id;
  else
    perform public.assert_own('exam_terms', p_id);
    select session_id into v_session from public.exam_terms
     where id = p_id and school_id = v_school;
  end if;

  if v_name = '' then
    raise exception 'Give the term a name, for example First Term' using errcode = '22023';
  end if;
  if length(v_name) > 80 then
    raise exception 'A term name is at most 80 characters' using errcode = '22001';
  end if;
  if exists (select 1 from public.exam_terms t
              where t.school_id = v_school and t.session_id = v_session
                and lower(btrim(t.name)) = lower(v_name)
                and t.id is distinct from p_id) then
    raise exception 'This year already has a term called %. Give this one another name.', v_name
      using errcode = '23505';
  end if;

  begin
    v_type := coalesce(nullif(btrim(coalesce(p_term_type, '')), ''), 'other')::public.term_type;
  exception when invalid_text_representation then
    raise exception 'Unknown term type %', p_term_type using errcode = '22023';
  end;

  if (p_starts_on is null) <> (p_ends_on is null) then
    raise exception 'Give both the start and the end date, or neither' using errcode = '22023';
  end if;
  if p_ends_on < p_starts_on then
    raise exception 'The term cannot end before it starts' using errcode = '22023';
  end if;
  perform public.fn__assert_date_in_session(v_session, p_starts_on, 'The term''s start date', false);
  perform public.fn__assert_date_in_session(v_session, p_ends_on, 'The term''s end date', false);

  if p_id is null then
    insert into public.exam_terms
      (school_id, session_id, name, term_type, starts_on, ends_on, result_withheld_for_defaulters)
    values (v_school, v_session, v_name, v_type, p_starts_on, p_ends_on, coalesce(p_withhold, true))
    returning id into v_id;
  else
    update public.exam_terms
       set name = v_name, term_type = v_type, starts_on = p_starts_on, ends_on = p_ends_on,
           result_withheld_for_defaulters = coalesce(p_withhold, result_withheld_for_defaulters)
     where id = p_id and school_id = v_school
    returning id into v_id;
  end if;
  return v_id;
end;
$$;

revoke all on function public.fn_save_exam_term(uuid, uuid, text, text, date, date, boolean) from public, anon;
grant execute on function public.fn_save_exam_term(uuid, uuid, text, text, date, date, boolean) to authenticated;

-- Only an empty term goes. A term with marks, result cards or remarks in it is
-- work somebody did, and removing its papers first (each of which asks) is the
-- deliberate way to empty it.
create or replace function public.fn_delete_exam_term(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_name   text;
  v_marks  integer;
  v_cards  integer;
  v_notes  integer;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted to delete exam terms' using errcode = '42501';
  end if;
  perform public.assert_own('exam_terms', p_id);
  select name into v_name from public.exam_terms where id = p_id and school_id = v_school;

  select count(*) into v_cards from public.result_cards
   where exam_term_id = p_id and school_id = v_school;
  if v_cards > 0 then
    raise exception '% has % result card(s), and a term with results in it is the record of '
      'those results. It cannot be deleted.', v_name, v_cards using errcode = '23503';
  end if;

  select count(*) into v_marks
    from public.mark_entries me
    join public.exam_subjects es on es.id = me.exam_subject_id and es.school_id = v_school
   where es.exam_term_id = p_id and me.school_id = v_school;
  if v_marks > 0 then
    raise exception '% has % mark(s) entered. Remove its papers under Setup first (each one '
      'says what it would delete), then the term.', v_name, v_marks using errcode = '23503';
  end if;

  select count(*) into v_notes from public.exam_remarks
   where exam_term_id = p_id and school_id = v_school;
  if v_notes > 0 then
    raise exception '% has % teacher remark(s) written. Clear them under Remarks first, then the term.',
      v_name, v_notes using errcode = '23503';
  end if;

  delete from public.exam_terms where id = p_id and school_id = v_school;
end;
$$;

revoke all on function public.fn_delete_exam_term(uuid) from public, anon;
grant execute on function public.fn_delete_exam_term(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- The term at a glance: every class, one read
--
-- What the office needs before result day: which classes have papers, how many
-- marks are in, whether the cards are made, whether they are out, and whether
-- they are out of date. Counted on the same rules the generator uses: pupils
-- by the marksheet's statuses, a paper counted only for the pupils who take it.
-- ---------------------------------------------------------------------------
create or replace function public.fn_exam_term_overview(p_exam_term_id uuid)
returns table (
  class_id uuid, class_name text, level_order integer,
  papers integer, pupils integer, marks_expected integer, marks_entered integer,
  cards integer, released integer, older_released integer,
  generated_at timestamptz, out_of_date integer
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_session uuid;
begin
  if not public.may_view('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  select session_id into v_session from public.exam_terms
   where id = p_exam_term_id and school_id = v_school;

  return query
  with pupil as (
    select e.id as enrollment_id, e.class_id, e.stream
      from public.enrollments e
      join public.students s on s.id = e.student_id and s.school_id = v_school
                            and s.deleted_at is null
     where e.school_id = v_school and e.session_id = v_session
       and e.status in ('active', 'promoted', 'retained', 'graduated')
  ),
  paper as (
    select es.id, es.class_id, sub.stream
      from public.exam_subjects es
      join public.subjects sub on sub.id = es.subject_id and sub.school_id = v_school
     where es.school_id = v_school and es.exam_term_id = p_exam_term_id
  ),
  cell as (
    select pa.class_id, p.enrollment_id, me.id as mark_id
      from paper pa
      join pupil p on p.class_id = pa.class_id and public.fn_takes_subject(pa.stream, p.stream)
      left join public.mark_entries me
        on me.exam_subject_id = pa.id and me.enrollment_id = p.enrollment_id
       and me.school_id = v_school
  ),
  latest as (
    select distinct on (rc.enrollment_id)
           rc.enrollment_id, rc.generated_at, rc.published_at, e.class_id
      from public.result_cards rc
      join public.enrollments e on e.id = rc.enrollment_id and e.school_id = v_school
     where rc.school_id = v_school and rc.exam_term_id = p_exam_term_id
     order by rc.enrollment_id, rc.version desc
  ),
  ever_released as (
    select distinct rc.enrollment_id
      from public.result_cards rc
     where rc.school_id = v_school and rc.exam_term_id = p_exam_term_id
       and rc.published_at is not null
  )
  select cl.id, cl.name, cl.level_order,
         (select count(*)::int from paper pa where pa.class_id = cl.id),
         (select count(*)::int from pupil p where p.class_id = cl.id),
         (select count(*)::int from cell c where c.class_id = cl.id),
         (select count(*)::int from cell c where c.class_id = cl.id and c.mark_id is not null),
         (select count(*)::int from latest l where l.class_id = cl.id),
         (select count(*)::int from latest l where l.class_id = cl.id and l.published_at is not null),
         (select count(*)::int from latest l
            join ever_released r on r.enrollment_id = l.enrollment_id
           where l.class_id = cl.id and l.published_at is null),
         (select max(l.generated_at) from latest l where l.class_id = cl.id),
         -- The readiness check's own count, so the overview and the class
         -- screen cannot disagree about which cards are out of date.
         case when exists (select 1 from latest l where l.class_id = cl.id)
              then (select coalesce(sum(r.affected), 0)::int
                      from public.fn_result_readiness(p_exam_term_id, cl.id) r
                     where r.problem = 'cards out of date')
              else 0 end
    from public.classes cl
   where cl.school_id = v_school
     and (exists (select 1 from pupil p where p.class_id = cl.id)
          or exists (select 1 from paper pa where pa.class_id = cl.id))
   order by cl.level_order, cl.name;
end;
$$;

revoke all on function public.fn_exam_term_overview(uuid) from public, anon;
grant execute on function public.fn_exam_term_overview(uuid) to authenticated;

-- Each paper's progress, split by section, so the marks screen can show a
-- section's teacher their own count and the office the whole class's.
create or replace function public.fn_exam_paper_progress(p_exam_term_id uuid, p_class_id uuid)
returns table (
  exam_subject_id uuid, section_id uuid, pupils integer, entered integer,
  absent integer, locked integer
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_session uuid;
begin
  if not public.may_view('owner', 'principal', 'admin_clerk', 'class_teacher', 'subject_teacher') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('classes', p_class_id);
  select session_id into v_session from public.exam_terms
   where id = p_exam_term_id and school_id = v_school;

  return query
  select es.id, e.section_id,
         count(*)::int,
         count(me.id)::int,
         count(me.id) filter (where me.is_absent)::int,
         count(me.id) filter (where me.is_locked)::int
    from public.exam_subjects es
    join public.subjects sub on sub.id = es.subject_id and sub.school_id = v_school
    join public.enrollments e
      on e.school_id = v_school and e.session_id = v_session and e.class_id = es.class_id
     and e.status in ('active', 'promoted', 'retained', 'graduated')
     and public.fn_takes_subject(sub.stream, e.stream)
    join public.students s on s.id = e.student_id and s.school_id = v_school
                          and s.deleted_at is null
    left join public.mark_entries me
      on me.exam_subject_id = es.id and me.enrollment_id = e.id and me.school_id = v_school
   where es.school_id = v_school and es.exam_term_id = p_exam_term_id
     and es.class_id = p_class_id
   group by es.id, e.section_id;
end;
$$;

revoke all on function public.fn_exam_paper_progress(uuid, uuid) from public, anon;
grant execute on function public.fn_exam_paper_progress(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. The remark reaches the parent
--
-- Same body as 0089's, with the class teacher's remark beside the released
-- result. It cannot change after release (above), so the portal and the
-- printed card say the same thing.
-- ---------------------------------------------------------------------------
create or replace function public.fn_portal_child_results(p_student_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  perform public.fn__assert_my_child(p_student_id);

  select coalesce(jsonb_agg(
           case when x.withheld then
             jsonb_build_object(
               'result_card_id', x.id, 'term', x.term, 'withheld', true,
               'message', 'Result withheld until outstanding fees are cleared.',
               'issued_at', x.issued_at)
           else
             jsonb_build_object(
               'result_card_id', x.id, 'term', x.term, 'withheld', false,
               'obtained_marks', x.total_marks, 'total_marks', x.total_max,
               'percentage', x.percentage, 'grade', x.grade,
               'grade_scale', coalesce(x.frozen->>'grade_scale', 'letter'),
               'position', x.position, 'attendance_pct', x.attendance_pct,
               'result', x.frozen->>'result',
               'failed_subjects', (x.frozen->>'failed_subjects')::integer,
               'pass_percent', (x.frozen->>'pass_percent')::numeric,
               'provisional', coalesce((x.frozen->>'provisional')::boolean, false),
               'unmarked_subjects', coalesce((x.frozen->>'unmarked_subjects')::integer, 0),
               'stream', x.frozen->>'stream',
               'bise_reg_no', x.frozen->>'bise_reg_no',
               'subjects', coalesce(x.frozen->'subjects', '[]'::jsonb),
               'remark', x.remark,
               'issued_at', x.issued_at)
           end
           order by x.issued_at desc), '[]'::jsonb)
    into v_out
  from (
    select distinct on (rc.exam_term_id)
           rc.id, et.name as term, rc.total_marks, rc.total_max, rc.percentage,
           rc.grade, rc.position, rc.attendance_pct, rc.frozen,
           rc.published_at as issued_at,
           coalesce((rc.frozen->>'withheld')::boolean, false) as withheld,
           (select r.remark from public.exam_remarks r
             where r.school_id = rc.school_id and r.exam_term_id = rc.exam_term_id
               and r.student_id = rc.student_id) as remark
    from public.result_cards rc
    join public.exam_terms et on et.id = rc.exam_term_id and et.school_id = rc.school_id
    where rc.student_id = p_student_id
      and rc.published_at is not null
    order by rc.exam_term_id, rc.version desc
  ) x;

  return coalesce(v_out, '[]'::jsonb);
end;
$$;

revoke all on function public.fn_portal_child_results(uuid) from public, anon;
grant execute on function public.fn_portal_child_results(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Did it take?
--
-- A WARNING and not an exception, for the reason recorded in 0100: a bundle
-- runs as ONE transaction and raising here would revert everything else in it.
-- supabase/tests/a_result_that_holds_still.sql walks it as real logins.
-- ---------------------------------------------------------------------------
do $assert$
declare v_bad text[] := '{}';
begin
  if to_regprocedure('public.fn_save_exam_term(uuid,uuid,text,text,date,date,boolean)') is null then
    v_bad := v_bad || 'fn_save_exam_term is missing';
  end if;
  if to_regprocedure('public.fn_exam_term_overview(uuid)') is null then
    v_bad := v_bad || 'fn_exam_term_overview is missing';
  end if;
  if not exists (select 1 from pg_trigger t where t.tgrelid = 'public.mark_entries'::regclass
                  and t.tgname = 'trg_marks_released_hold' and not t.tgisinternal) then
    v_bad := v_bad || 'the released-marks trigger is missing';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'fn_enter_marks'
                    and p.prosrc like '%cleared%') then
    v_bad := v_bad || 'fn_enter_marks still stores a blank box';
  end if;
  if exists (select 1 from public.mark_entries
              where exam_subject_id is not null and marks is null
                and practical_marks is null and not is_absent) then
    v_bad := v_bad || 'blank exam mark rows remain';
  end if;
  if array_length(v_bad, 1) > 0 then
    raise warning '0152 did not fully apply: %', array_to_string(v_bad, '; ');
  end if;
end $assert$;
