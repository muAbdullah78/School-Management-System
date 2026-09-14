-- =============================================================================
-- 0134  The register belongs to the teacher, and the head reads it
--
-- -----------------------------------------------------------------------------
-- WHAT WAS WRONG
--
-- A principal could mark attendance. Not correct it, not reopen it: MARK it,
-- from an empty register, exactly as the class teacher would.
--
-- That is not a permissions detail, it is the register losing its meaning. The
-- daily register is a statement by the person who stood in front of the class
-- and looked. When the head can also make that statement, nothing on the
-- record distinguishes "the teacher marked Bilal absent" from "the office
-- decided Bilal was absent", and the attendance percentage that ends up on a
-- result card, on the parent portal and in a fee decision is no longer
-- evidence of anything.
--
-- It also made the head's screen useless for the job the head actually has.
-- A principal opening Attendance got a class picker and a list of pupils: a
-- tool for marking one section. What a head needs at 9.40am is the opposite
-- shape. Which classes have marked? Which have not? Which said they were done
-- and never locked it? That question could not be asked of this software at
-- all, by anybody, in one screen.
--
-- -----------------------------------------------------------------------------
-- WHO MAY WRITE A REGISTER AFTER THIS
--
--   class_teacher    yes, for their class. The daily register is theirs.
--   subject_teacher  yes, for the classes they are assigned to.
--   principal        NO.
--   readonly         no, and never could.
--   owner            yes, and this is deliberate. See below.
--
-- THE OWNER IS LEFT ALONE ON PURPOSE, and it is the one loose thread in this
-- file, so it is stated rather than hidden.
--
-- 'owner' is not a job title, it is the account signup created: it holds the
-- subscription and the billing screens, and there is exactly one per school.
-- In a school of this size the head usually holds it, which means a head who
-- wants to mark a register can still do so by signing in as the owner. The
-- school's own instruction for a teacher who is off sick is to hand their
-- login to somebody else for the day, so an escape hatch of this kind is in
-- keeping with how these schools work, and closing it would mean a school with
-- one account and nobody able to mark.
--
-- No SCREEN offers it. The attendance page gives the owner the same oversight
-- dashboard as the principal, with marking one deliberate click away. If that
-- turns out to be too loose, the fix is to delete 'owner' from
-- fn_may_write_register below and from nothing else.
--
-- -----------------------------------------------------------------------------
-- WHAT THE PRINCIPAL KEEPS, WHICH IS THE POINT OF THE WHOLE CHANGE
--
--   * fn_unlock_attendance (0121). Reopening a finalised day is an APPROVAL,
--     not a marking. A child marked absent by mistake stays absent on every
--     result card ever printed unless somebody senior can reopen the day, and
--     that somebody is the head. Unchanged.
--   * Reading every register in the school, which they always had.
--   * fn_attendance_day, below, which is new and is the screen they never had.
--
-- -----------------------------------------------------------------------------
-- SUBJECT ATTENDANCE, AND WHY IT IS A SEPARATE AND DELIBERATELY WEAKER THING
--
-- The second half of this file adds a register a SUBJECT teacher may keep for
-- their own subject. It is optional, it is not locked, it is not finalised, it
-- does not feed the attendance percentage, and nothing anywhere asks for it.
--
-- Every one of those is a decision, not an omission. The daily register is the
-- school's legal record of who was present; making a second register that
-- behaves like it would mean two answers to one question, which is the exact
-- failure 0097 and 0100 were written to end. This one answers a different
-- question, for one reader: the head, wondering whether the children who were
-- in school at 8am were still in the chemistry lab at 11.
--
-- So a subject that nobody marked is NOT shown as outstanding, anywhere. There
-- is no "not done" for subject attendance, because nobody was ever asked to do
-- it. A panel listing forty unmarked subjects every morning would train the
-- head to ignore the screen that also tells them a class register is missing.
-- =============================================================================

-- ================================================= who may write a register ==
-- ONE predicate, named, called from the two functions and the two policies
-- that decide this. It used to be the same list of five roles written out in
-- four places, which is how three of them get updated.
--
-- NAMED fn_may_ AND NOT fn__, which is not a style choice. An fn__ helper is
-- revoked from `authenticated` by convention and by a guard, and a predicate
-- used inside a row-level policy is evaluated AS THE QUERYING USER: revoked,
-- it would make every insert into attendance_daily fail with a permission
-- error on the helper rather than a refusal from the policy. It sits with
-- fn_may_manage_class and fn_may_mark_subject, which are the same kind of
-- thing for the same reason.
create or replace function public.fn_may_write_register()
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role('owner', 'class_teacher', 'subject_teacher');
$$;

-- Revoked from anon and granted to authenticated explicitly: Postgres grants
-- EXECUTE to PUBLIC on every new function, and anon is the role a request
-- carries when it holds only the anonymous key from the browser bundle. The
-- grant to authenticated is required, not optional: this runs inside row-level
-- policies, which are evaluated as the querying user.
revoke all on function public.fn_may_write_register() from public, anon;
grant execute on function public.fn_may_write_register() to authenticated;

comment on function public.fn_may_write_register() is
  'Who may mark or finalise a daily register. The principal is deliberately '
  'absent: the register is a statement by the person who stood in front of '
  'the class. See 0134.';

-- fn_mark_attendance, byte for byte as 0130 left it apart from the two role
-- guards. Reproduced whole rather than patched because there is one of it and
-- a reader needs to see the order the checks run in.
create or replace function public.fn_mark_attendance(
  p_date date, p_marks jsonb, p_reason text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_total  integer;
  v_marked integer;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.fn_may_write_register() then
    raise exception 'The daily register is marked by the class teacher. A '
                    'principal can read it, and can reopen a finalised day, '
                    'but cannot mark it.'
      using errcode = '42501';
  end if;
  perform public.fn__only_these_keys(p_marks, '{enrollment_id,status}'::text[], 'Attendance marking');
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;

  -- Tenant scope: every enrolment must be in THIS school. Checked for all
  -- roles, because the teacher-scope check below is skipped for the owner,
  -- leaving them able to mark attendance against another school's enrolment ids.
  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where not exists (
      select 1 from public.enrollments en
      where en.id = (e->>'enrollment_id')::uuid
        and en.school_id = public.current_school_id()
    )
  ) then
    raise exception 'Unknown enrolment in this school' using errcode = '42501';
  end if;

  -- The owner is the only role left that is not scoped to an assignment, and
  -- it is the only one that ever was other than the two now removed.
  if not public.has_role('owner') then
    if exists (
      select 1 from jsonb_array_elements(p_marks) e
      join public.enrollments en on en.id = (e->>'enrollment_id')::uuid
      where not public.fn_may_manage_class(en.session_id, en.class_id, en.section_id)
    ) then
      raise exception 'You can only mark attendance for your assigned class';
    end if;
  end if;

  -- THE DATE (0130). Nothing bounded it: two calls put a school's
  -- register between 1900 and 2099. Two rules, both about a person
  -- mistyping a year rather than about an attacker.
  --
  -- Pakistan time for "today", the same expression fn_set_staff_attendance
  -- uses, because the two must agree about which day it is: from midnight
  -- to 5am in Karachi, UTC still says yesterday.
  if p_date > (now() at time zone 'Asia/Karachi')::date then
    raise exception 'Attendance cannot be marked for %, which has not '
      'happened yet.', to_char(p_date, 'DD Mon YYYY')
      using errcode = '22008';
  end if;
  -- And inside the academic year the enrolment belongs to. Checked per
  -- session rather than against the CURRENT one, because reopening last
  -- year's register to correct it is a thing fn_unlock_attendance exists
  -- to allow.
  perform public.fn__assert_date_in_session(en.session_id, p_date,
            'Marking attendance')
    from public.enrollments en
   where en.id in (select (e->>'enrollment_id')::uuid
                     from jsonb_array_elements(p_marks) e)
     and en.school_id = public.current_school_id();

  select count(distinct (e->>'enrollment_id')) into v_total
  from jsonb_array_elements(p_marks) e;

  with input as (
    select distinct on (enrollment_id) enrollment_id, status
    from (
      select (e->>'enrollment_id')::uuid as enrollment_id,
             (e->>'status')::public.attendance_status as status
      from jsonb_array_elements(p_marks) e
    ) q
    order by enrollment_id
  ),
  upserted as (
    insert into public.attendance_daily as ad
      (enrollment_id, attendance_date, status, marked_by)
    select enrollment_id, p_date, status, v_actor from input
    on conflict (enrollment_id, attendance_date) do update
      set status = excluded.status,
          marked_by = excluded.marked_by,
          corrected_from = case when ad.status is distinct from excluded.status
                                then ad.status else ad.corrected_from end,
          correction_reason = case when ad.status is distinct from excluded.status
                                   then v_reason else ad.correction_reason end
      where not ad.is_locked
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

-- Finalising is CLOSING YOUR OWN REGISTER, not an approval of somebody else's,
-- so it moves with marking. A principal who could finalise could lock a class
-- as complete at 9.00 with three pupils marked, and the class teacher would
-- then need the principal again to reopen what the principal shut.
create or replace function public.fn_finalize_attendance(
  p_session_id uuid, p_class_id uuid, p_section_id uuid, p_date date
) returns integer language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  if not public.fn_may_write_register() then
    raise exception 'A register is finalised by the teacher who marked it.'
      using errcode = '42501';
  end if;
  if not public.fn_may_manage_class(p_session_id, p_class_id, p_section_id) then
    raise exception 'You can only finalize your assigned class';
  end if;
  -- `and not ad.is_locked`, from 0126: without it the statement rewrites every
  -- row of the section-day whether it was open or not, so the number it
  -- returns is "pupils in this section-day" while the screen prints it as
  -- "Finalized & locked 34 rows".
  update public.attendance_daily ad
    set is_locked = true
    from public.enrollments e
    where ad.enrollment_id = e.id
      and ad.attendance_date = p_date
      and e.session_id = p_session_id
      and e.class_id = p_class_id
      and e.section_id is not distinct from p_section_id
      and not ad.is_locked;
  get diagnostics v_count = row_count;

  if v_count > 0 then
    insert into public.audit_log (
      school_id, actor, actor_role, action, entity, entity_id, before, after)
    values (
      public.current_school_id(), auth.uid(),
      (select role from public.profiles where id = auth.uid()),
      'ATTENDANCE_FINALIZE', 'attendance_daily', p_date::text,
      jsonb_build_object('locked', false),
      jsonb_build_object('locked', true, 'rows', v_count,
                         'session_id', p_session_id, 'class_id', p_class_id,
                         'section_id', p_section_id));
  end if;

  begin
    perform public.fn_queue_absent_today(p_session_id, p_class_id, p_section_id, p_date);
  exception when others then
    raise notice 'attendance finalised; absence messages could not be queued: %', sqlerrm;
  end;

  return v_count;
end;
$$;

-- The policies, so a direct table write cannot do what the function refuses.
-- These two are the actual enforcement; the functions above are SECURITY
-- DEFINER and bypass them, which is why both have to change together.
drop policy if exists attendance_insert on public.attendance_daily;
create policy attendance_insert on public.attendance_daily for insert
  with check (school_id = public.current_school_id()
              and public.fn_may_write_register()
              and public.fn_may_manage_enrollment(enrollment_id));

drop policy if exists attendance_update on public.attendance_daily;
create policy attendance_update on public.attendance_daily for update
  using (school_id = public.current_school_id()
         and public.fn_may_write_register()
         and public.fn_may_manage_enrollment(enrollment_id))
  with check (school_id = public.current_school_id()
              and public.fn_may_write_register()
              and public.fn_may_manage_enrollment(enrollment_id));

-- ======================================================== the head's screen ==
-- One row per class-section for one day, with enough to sort them into the
-- three piles the head thinks in: done and locked, done and not locked, not
-- done.
--
-- IT COUNTS ENROLMENTS, NOT ATTENDANCE ROWS, and that distinction is the
-- entire value of it. A class with 34 pupils and 34 marks is done. A class with
-- 34 pupils and 12 marks is NOT done, and the old software had no way to say
-- so: the register looked marked to anybody who opened it, because the 22
-- unmarked children simply were not rows.
--
-- SECTIONS WITH NO PUPILS ARE OMITTED. A school that made a section in
-- September and never put anybody in it would otherwise show a permanent red
-- entry that can never be cleared.
-- DROPPED FIRST, because `create or replace function` REFUSES to change a
-- function's return type: "cannot change return type of existing function".
-- These return a table, and a column added to one later is exactly that
-- change. Without the drop, a school re-pasting a corrected bundle would hit
-- that error, and because a bundle is one transaction the whole bundle would
-- roll back. None of these is referenced by a policy, so nothing depends on
-- them; the grants below are reapplied straight afterwards.
drop function if exists public.fn_attendance_day(uuid, date);
create or replace function public.fn_attendance_day(p_session_id uuid, p_date date)
returns table(
  class_id uuid, class_name text, level_order integer,
  section_id uuid, section_name text,
  pupils integer, marked integer, locked integer,
  state text
) language plpgsql stable security definer set search_path = public as $$
begin
  -- Read-only and school-scoped, but it hands over the WHOLE school at once,
  -- which is a different thing from a teacher reading their own class. Kept to
  -- the three roles whose job is oversight.
  -- may_view, not has_role, which is 0059's rule: an observer is MEANT to see
  -- the oversight screens and is stopped from writing by having no write
  -- function to call. Gating a read on has_role is how `readonly` ended up
  -- with screens that rendered and returned nothing.
  if not public.may_view('owner', 'principal') then
    raise exception 'Only the head, the owner or an observer may read the '
                    'whole school''s register at once'
      using errcode = '42501';
  end if;
  if not exists (select 1 from public.academic_sessions s
                  where s.id = p_session_id
                    and s.school_id = public.current_school_id()) then
    raise exception 'Unknown academic year for this school' using errcode = '42501';
  end if;

  return query
  select c.id, c.name, c.level_order,
         sec.id, sec.name,
         count(*)::integer as pupils,
         count(ad.enrollment_id)::integer as marked,
         count(ad.enrollment_id) filter (where ad.is_locked)::integer as locked,
         case
           when count(ad.enrollment_id) = 0 then 'none'
           when count(ad.enrollment_id) < count(*) then 'partial'
           -- Every pupil marked. Locked only if EVERY row is locked: a
           -- half-locked section is the result of finalising, then admitting a
           -- child, and it is not finished.
           when count(*) filter (where ad.is_locked) = count(*) then 'locked'
           else 'unlocked'
         end as state
    from public.enrollments e
    join public.classes c on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
    left join public.attendance_daily ad
           on ad.enrollment_id = e.id and ad.attendance_date = p_date
   where e.school_id = public.current_school_id()
     and e.session_id = p_session_id
     and e.status = 'active'
   group by c.id, c.name, c.level_order, sec.id, sec.name
   order by c.level_order, c.name, sec.name nulls first;
end;
$$;
revoke all on function public.fn_attendance_day(uuid, date) from public, anon;
grant execute on function public.fn_attendance_day(uuid, date) to authenticated;

-- ====================================================== subject attendance ==
create table if not exists public.attendance_subject (
  id              uuid primary key default gen_random_uuid(),
  school_id       uuid not null references public.schools(id) on delete cascade,
  enrollment_id   uuid not null references public.enrollments(id) on delete cascade,
  subject_id      uuid not null references public.subjects(id) on delete cascade,
  attendance_date date not null,
  status          public.attendance_status not null,
  marked_by       uuid references public.profiles(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  -- One mark per child per subject per day. There is no timetable in this
  -- product, so "the chemistry period" is not a thing that can be named; the
  -- honest unit is the day.
  constraint attendance_subject_once unique (enrollment_id, subject_id, attendance_date)
);

create index if not exists attendance_subject_day
  on public.attendance_subject (school_id, attendance_date);

drop trigger if exists trg_attendance_subject_updated on public.attendance_subject;
create trigger trg_attendance_subject_updated before update on public.attendance_subject
  for each row execute function public.set_updated_at();

alter table public.attendance_subject enable row level security;

-- WHO MAY READ IT. The head, the owner, an observer, and the teacher who wrote
-- it. Not the rest of the staff room, and not parents: the school asked for
-- this to be something the head can see, and a second attendance figure
-- reaching a parent is precisely the confusion that must not happen.
drop policy if exists attendance_subject_select on public.attendance_subject;
create policy attendance_subject_select on public.attendance_subject for select
  using (school_id = public.current_school_id()
         and (public.has_role('owner', 'principal', 'readonly')
              or marked_by = auth.uid()));

-- Written only through the function below, which is SECURITY DEFINER. No
-- insert, update or delete policy exists at all, so a direct table write from
-- a browser session affects nothing whatever the caller's role.
--
-- That is stricter than attendance_daily, on purpose: there is one way in, so
-- there is one place the rules live.

/**
 * The roster for one subject on one day.
 *
 * Returns the same pupils the daily register would, plus this subject's mark
 * and, for context, what the class teacher recorded. A subject teacher looking
 * at an empty row wants to know whether the child is absent from school
 * altogether before they mark them absent from chemistry.
 */
drop function if exists public.fn_subject_roster(uuid, uuid, uuid, uuid, date);
create or replace function public.fn_subject_roster(
  p_session_id uuid, p_class_id uuid, p_section_id uuid, p_subject_id uuid, p_date date
) returns table(
  enrollment_id uuid, student_id uuid, full_name text, roll_no text,
  status public.attendance_status, day_status public.attendance_status
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.fn_may_mark_subject(p_session_id, p_class_id, p_section_id, p_subject_id)
     and not public.may_view('owner', 'principal') then
    raise exception 'You can only see subject attendance for a class and '
                    'subject you teach'
      using errcode = '42501';
  end if;

  return query
  select e.id, e.student_id, s.full_name, e.roll_no,
         asub.status, ad.status
    from public.enrollments e
    join public.students s on s.id = e.student_id
    left join public.attendance_subject asub
           on asub.enrollment_id = e.id
          and asub.subject_id = p_subject_id
          and asub.attendance_date = p_date
    left join public.attendance_daily ad
           on ad.enrollment_id = e.id and ad.attendance_date = p_date
   where e.school_id = public.current_school_id()
     and e.session_id = p_session_id
     and e.class_id = p_class_id
     and e.section_id is not distinct from p_section_id
     and e.status = 'active'
   order by
     -- Same order as every other roster in the product: by roll number read as
     -- a number where it is one, so 10 comes after 9 and not after 1.
     nullif(regexp_replace(coalesce(e.roll_no, ''), '\D', '', 'g'), '')::bigint
       nulls last,
     s.full_name;
end;
$$;
revoke all on function public.fn_subject_roster(uuid, uuid, uuid, uuid, date) from public, anon;
grant execute on function public.fn_subject_roster(uuid, uuid, uuid, uuid, date) to authenticated;

/**
 * Mark a subject's attendance for a day.
 *
 * Deliberately thinner than fn_mark_attendance: no locking, no correction
 * trail, no absence messages to parents. This register is optional and
 * informal, and dressing it in the daily register's machinery would make two
 * things look equally binding when only one of them is.
 *
 * THE PRINCIPAL IS REFUSED HERE TOO, for the same reason as the daily one.
 */
create or replace function public.fn_mark_subject_attendance(
  p_session_id uuid, p_class_id uuid, p_section_id uuid,
  p_subject_id uuid, p_date date, p_marks jsonb
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := auth.uid();
  v_school uuid := public.current_school_id();
  v_marked integer;
begin
  if not public.fn_may_write_register() then
    raise exception 'Subject attendance is marked by the subject teacher.'
      using errcode = '42501';
  end if;
  if not public.fn_may_mark_subject(p_session_id, p_class_id, p_section_id, p_subject_id) then
    raise exception 'You can only mark a subject you are assigned to teach in '
                    'this class'
      using errcode = '42501';
  end if;
  perform public.fn__only_these_keys(p_marks, '{enrollment_id,status}'::text[],
            'Subject attendance marking');
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;

  -- The same date rules as the daily register, and for the same reason: a
  -- mistyped year is the realistic failure, not an attacker.
  if p_date > (now() at time zone 'Asia/Karachi')::date then
    raise exception 'Attendance cannot be marked for %, which has not '
      'happened yet.', to_char(p_date, 'DD Mon YYYY')
      using errcode = '22008';
  end if;
  perform public.fn__assert_date_in_session(p_session_id, p_date,
            'Marking subject attendance');

  -- Every enrolment must be in this school AND in the class being marked.
  -- Without the second half, a subject teacher assigned to 9-A could pass 10-B
  -- enrolment ids and mark them.
  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where not exists (
      select 1 from public.enrollments en
       where en.id = (e->>'enrollment_id')::uuid
         and en.school_id = v_school
         and en.session_id = p_session_id
         and en.class_id = p_class_id
         and en.section_id is not distinct from p_section_id
    )
  ) then
    raise exception 'A pupil in that list is not in this class'
      using errcode = '42501';
  end if;

  with input as (
    select distinct on (enrollment_id) enrollment_id, status
    from (
      select (e->>'enrollment_id')::uuid as enrollment_id,
             (e->>'status')::public.attendance_status as status
      from jsonb_array_elements(p_marks) e
    ) q
    order by enrollment_id
  ),
  upserted as (
    insert into public.attendance_subject
      (school_id, enrollment_id, subject_id, attendance_date, status, marked_by)
    select v_school, enrollment_id, p_subject_id, p_date, status, v_actor from input
    on conflict (enrollment_id, subject_id, attendance_date) do update
      set status = excluded.status, marked_by = excluded.marked_by
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked);
end;
$$;
revoke all on function public.fn_mark_subject_attendance(uuid, uuid, uuid, uuid, date, jsonb)
  from public, anon;
grant execute on function public.fn_mark_subject_attendance(uuid, uuid, uuid, uuid, date, jsonb)
  to authenticated;

/**
 * What the head sees under "Subject attendance" for a day.
 *
 * ONLY WHAT WAS ACTUALLY MARKED. There is no row for a subject nobody touched,
 * and that is the single most important line in this function. Subject
 * attendance is optional; listing every unmarked subject as outstanding would
 * put forty red rows on the head's screen every morning and teach them to stop
 * reading the panel that also tells them a class register is missing.
 */
drop function if exists public.fn_subject_attendance_day(uuid, date);
create or replace function public.fn_subject_attendance_day(p_session_id uuid, p_date date)
returns table(
  class_id uuid, class_name text, level_order integer,
  section_id uuid, section_name text,
  subject_id uuid, subject_name text,
  marked_by_name text,
  pupils integer, present integer, absent integer, other integer
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.may_view('owner', 'principal') then
    raise exception 'Subject attendance is shown to the head'
      using errcode = '42501';
  end if;

  return query
  select c.id, c.name, c.level_order,
         sec.id, sec.name,
         sub.id, sub.name,
         coalesce(pr.full_name, 'Unknown'),
         count(*)::integer,
         count(*) filter (where a.status = 'present')::integer,
         count(*) filter (where a.status = 'absent')::integer,
         count(*) filter (where a.status not in ('present', 'absent'))::integer
    from public.attendance_subject a
    join public.enrollments e on e.id = a.enrollment_id
    join public.classes c on c.id = e.class_id
    join public.subjects sub on sub.id = a.subject_id
    left join public.sections sec on sec.id = e.section_id
    left join public.profiles pr on pr.id = a.marked_by
   where a.school_id = public.current_school_id()
     and a.attendance_date = p_date
     and e.session_id = p_session_id
   group by c.id, c.name, c.level_order, sec.id, sec.name, sub.id, sub.name, pr.full_name
   order by c.level_order, c.name, sec.name nulls first, sub.name;
end;
$$;
revoke all on function public.fn_subject_attendance_day(uuid, date) from public, anon;
grant execute on function public.fn_subject_attendance_day(uuid, date) to authenticated;
