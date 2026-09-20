-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0145_subjects_you_can_manage_and_a_month_of_defaulters.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0145: subjects you can manage anywhere, and a defaulters list for any month.
--
-- Two gaps a launch found, both about a screen sending you somewhere else to do
-- the obvious thing.
--
-- SUBJECTS. The subjects table has been per-class since 0001 -- a row is
-- (school_id, class_id, name), which is already the class-to-subject mapping a
-- normalized schema would build with a join table. exam_subjects, assessments,
-- mark_entries, subject_teachers and result-card generation all reference
-- subjects.id. So this migration does NOT introduce a global catalogue plus a
-- class_subjects join: that would be a large, high-blast-radius rewrite of the
-- exam and results engine for no behaviour a school can see. It builds the CRUD
-- the table always deserved -- create (deduped), rename/reorder, delete (only
-- when nothing is built on it), and a copy-to-other-classes convenience that
-- gives the "one Physics across classes" feel without the schema churn.
--
-- DEFAULTERS. fn_defaulters(session) is a lifetime running balance and stays
-- exactly that. fn_defaulters_month(session, month) is new: who owes on ONE
-- billing month's challan, for any month the principal picks -- June's list
-- while it is September. fn_billed_months(session) feeds the picker.
--
-- Nothing here changes a return TYPE of an existing function, so every object
-- is a fresh create or a create-or-replace of a brand-new name. Re-pasting is a
-- no-op. Verified in the harness.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- fn_create_subject: one door for adding a subject, with a duplicate check.
--
-- createSubject in the app used to raw-insert, so "Maths" and "maths" and a
-- second "Maths" all landed side by side and the Subject Teachers screen showed
-- three rows nobody could tell apart. This dedupes on a case-folded, trimmed
-- name within the class and returns the id either way, so a double click or a
-- re-add is idempotent rather than a mess.
-- -----------------------------------------------------------------------------
create or replace function public.fn_create_subject(
  p_class_id uuid, p_name text, p_sort_order integer default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_name   text := btrim(coalesce(p_name, ''));
  v_id     uuid;
  v_order  integer;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('classes', p_class_id);
  if v_name = '' then
    raise exception 'A subject needs a name.';
  end if;
  if char_length(v_name) > 60 then
    raise exception 'That subject name is too long (60 characters at most).';
  end if;

  -- Already there under any casing? Hand back the existing row rather than a
  -- second one. lower(), not a citext column: adding a type to a shipped table
  -- is a bigger change than this needs.
  select id into v_id from public.subjects
   where school_id = v_school and class_id = p_class_id
     and lower(name) = lower(v_name)
   limit 1;
  if v_id is not null then
    return v_id;
  end if;

  v_order := coalesce(p_sort_order,
    (select coalesce(max(sort_order), 0) + 10 from public.subjects
      where school_id = v_school and class_id = p_class_id));

  insert into public.subjects (school_id, class_id, name, sort_order)
  values (v_school, p_class_id, v_name, v_order)
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.fn_create_subject(uuid, text, integer) from public, anon;
grant execute on function public.fn_create_subject(uuid, text, integer) to authenticated;

-- -----------------------------------------------------------------------------
-- fn_update_subject: rename and reorder, with the same duplicate guard.
-- -----------------------------------------------------------------------------
create or replace function public.fn_update_subject(
  p_subject_id uuid, p_name text, p_sort_order integer default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_name   text := btrim(coalesce(p_name, ''));
  v_class  uuid;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('subjects', p_subject_id);
  if v_name = '' then
    raise exception 'A subject needs a name.';
  end if;
  if char_length(v_name) > 60 then
    raise exception 'That subject name is too long (60 characters at most).';
  end if;

  select class_id into v_class from public.subjects
   where id = p_subject_id and school_id = v_school;

  if exists (
    select 1 from public.subjects
     where school_id = v_school and class_id = v_class
       and lower(name) = lower(v_name) and id <> p_subject_id) then
    raise exception 'That class already has a subject called %.', v_name;
  end if;

  update public.subjects
     set name = v_name,
         sort_order = coalesce(p_sort_order, sort_order)
   where id = p_subject_id and school_id = v_school;
end;
$$;
revoke all on function public.fn_update_subject(uuid, text, integer) from public, anon;
grant execute on function public.fn_update_subject(uuid, text, integer) to authenticated;

-- -----------------------------------------------------------------------------
-- fn_delete_subject: only when nothing is built on it.
--
-- A subject that carries exam papers or a test is part of somebody's marks and
-- a result card, and deleting it would pull marks out of a total silently. So
-- it is refused with the reason, in words the office can act on. A subject with
-- only teacher assignments deletes cleanly -- subject_teachers is ON DELETE
-- CASCADE and an assignment is not a record of anything that happened.
-- -----------------------------------------------------------------------------
create or replace function public.fn_delete_subject(p_subject_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_name   text;
  v_papers integer;
  v_tests  integer;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('subjects', p_subject_id);

  select name into v_name from public.subjects
   where id = p_subject_id and school_id = v_school;

  select count(*) into v_papers from public.exam_subjects
   where school_id = v_school and subject_id = p_subject_id;
  select count(*) into v_tests from public.assessments
   where school_id = v_school and subject_id = p_subject_id;

  if v_papers > 0 or v_tests > 0 then
    return jsonb_build_object(
      'deleted', false,
      'message', format(
        '%s cannot be deleted: it has %s exam paper(s) and %s test(s) with marks '
        'attached. Remove those first, or just rename the subject.',
        coalesce(v_name, 'This subject'), v_papers, v_tests));
  end if;

  delete from public.subjects where id = p_subject_id and school_id = v_school;
  return jsonb_build_object('deleted', true,
    'message', format('%s deleted.', coalesce(v_name, 'Subject')));
end;
$$;
revoke all on function public.fn_delete_subject(uuid) from public, anon;
grant execute on function public.fn_delete_subject(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- fn_copy_subjects_to_classes: the "one Physics everywhere" convenience.
--
-- Copies the subject NAMES (with stream and practical flag) from one class into
-- others, skipping any a target class already has under the same name. This is
-- what the user's "global subjects" ask really wants at the screen -- set the
-- list once, apply to Class 1 through 10 -- without a catalogue table underneath.
-- Returns how many were created and how many were skipped as already present.
-- -----------------------------------------------------------------------------
create or replace function public.fn_copy_subjects_to_classes(
  p_from_class uuid, p_to_class_ids uuid[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_target  uuid;
  v_created integer := 0;
  v_skipped integer := 0;
  r record;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('classes', p_from_class);
  if p_to_class_ids is null or array_length(p_to_class_ids, 1) is null then
    raise exception 'Choose at least one class to copy the subjects into.';
  end if;

  foreach v_target in array p_to_class_ids loop
    perform public.assert_own('classes', v_target);
    if v_target = p_from_class then
      continue;  -- copying a class onto itself is a no-op, not an error
    end if;
    for r in
      select name, stream, is_practical, sort_order
        from public.subjects
       where school_id = v_school and class_id = p_from_class
       order by sort_order, name
    loop
      if exists (select 1 from public.subjects
                  where school_id = v_school and class_id = v_target
                    and lower(name) = lower(r.name)) then
        v_skipped := v_skipped + 1;
        continue;
      end if;
      insert into public.subjects (school_id, class_id, name, stream, is_practical, sort_order)
      values (v_school, v_target, r.name, r.stream, r.is_practical, r.sort_order);
      v_created := v_created + 1;
    end loop;
  end loop;

  return jsonb_build_object('created', v_created, 'skipped', v_skipped);
end;
$$;
revoke all on function public.fn_copy_subjects_to_classes(uuid, uuid[]) from public, anon;
grant execute on function public.fn_copy_subjects_to_classes(uuid, uuid[]) to authenticated;

-- -----------------------------------------------------------------------------
-- fn_billed_months: the months that actually have challans, for the picker.
-- Newest first. Only real billing months (period_month not null, not void).
-- -----------------------------------------------------------------------------
create or replace function public.fn_billed_months(p_session_id uuid)
returns table(period_month date, invoice_count integer) language plpgsql
stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.may_view('owner', 'principal', 'readonly', 'accountant') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  -- EXISTS, not a join: a student with two enrollments in one session would
  -- otherwise count their challan twice. The count is "how many challans that
  -- month", so each invoice must be counted once.
  return query
    select i.period_month, count(*)::integer
      from public.invoices i
     where i.school_id = v_school
       and i.status <> 'void'
       and i.period_month is not null
       and exists (select 1 from public.enrollments e
                    where e.student_id = i.student_id
                      and e.session_id = p_session_id)
     group by i.period_month
     order by i.period_month desc;
end;
$$;
revoke all on function public.fn_billed_months(uuid) from public, anon;
grant execute on function public.fn_billed_months(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- fn_defaulters_month: who owes on ONE month's challan.
--
-- Same shape as fn_defaulters plus the month's own numbers, so the report can
-- show "charged 4,500, paid 2,000, owes 2,500 for June". Balance is that
-- month's invoices net of the payments ALLOCATED to those invoices -- not the
-- student's global balance, which is the whole point of a per-month view.
-- Adjustments are deliberately NOT folded in here: an adjustment is a running
-- account correction with no month, and adding it would make a single-month
-- figure depend on things that did not happen that month.
-- -----------------------------------------------------------------------------
create or replace function public.fn_defaulters_month(p_session_id uuid, p_month date)
returns table(
  student_id uuid, gr_no text, full_name text, class_name text,
  section_name text, roll_no text, charged numeric, paid numeric, balance numeric
) language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_month  date := date_trunc('month', p_month)::date;
begin
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  return query
  with inv as (
    select i.id, i.student_id, i.fine
      from public.invoices i
     where i.school_id = v_school and i.status <> 'void'
       and i.period_month = v_month
  ),
  lines as (
    select l.invoice_id,
           sum(case when l.is_discount then -l.amount else l.amount end) as net
      from public.invoice_lines l join inv on inv.id = l.invoice_id
     group by l.invoice_id
  ),
  alloc as (
    select al.invoice_id, sum(al.amount) as paid
      from public.payment_allocations al
      join public.payments p on p.id = al.payment_id and p.status = 'verified'
      join inv on inv.id = al.invoice_id
     group by al.invoice_id
  ),
  bal as (
    select inv.student_id,
           sum(coalesce(l.net, 0) + coalesce(inv.fine, 0)) as charged,
           sum(coalesce(a.paid, 0)) as paid
      from inv
      left join lines l on l.invoice_id = inv.id
      left join alloc a on a.invoice_id = inv.id
     group by inv.student_id
  )
  -- The active enrollment for the class/section/roll columns, pinned so a
  -- student with an old inactive enrollment in the same session is not listed
  -- twice. Matches fn_defaulters, which also joins on status = 'active'.
  select s.id, s.gr_no, s.full_name, c.name, sec.name, e.roll_no,
         b.charged, b.paid, b.charged - b.paid
    from bal b
    join public.students s on s.id = b.student_id and s.school_id = v_school
                          and s.deleted_at is null
    join public.enrollments e on e.student_id = s.id and e.session_id = p_session_id
                             and e.status = 'active'
    join public.classes c on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
   where b.charged - b.paid > 0
   order by b.charged - b.paid desc;
end;
$$;
revoke all on function public.fn_defaulters_month(uuid, date) from public, anon;
grant execute on function public.fn_defaulters_month(uuid, date) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0145_subjects_you_can_manage_and_a_month_of_defaulters.sql', '46_subjects_you_can_manage_and_a_month_of_defaulters.sql');
end $ledger$;
