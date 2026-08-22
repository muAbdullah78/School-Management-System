-- =============================================================================
-- 0054 — When a child leaves.
--
-- The staff side of this was 0053. Pulling the same thread on the student side
-- found four things, three of them defects.
--
-- 1. THE ONLY BUTTON WAS "STRIKE OFF". student_status has four values —
--    active, struck_off, withdrawn, graduated — and the student profile offered
--    exactly one action. 'graduated' is set by the year-end rollover, which is
--    right. 'withdrawn' was UNREACHABLE. So a child whose family moves to
--    Karachi was *struck off*, which in Pakistan means removed for
--    non-payment or misconduct. It is what goes in the register and what a
--    parent would read on a leaving certificate. The most ordinary reason a
--    child leaves a school could not be recorded correctly.
--
-- 2. REINSTATING A GRADUATED CHILD LEFT THE TWO FACTS CONTRADICTING. The old
--    function reactivated enrollments only where status was 'struck_off' or
--    'left'. Set a graduated child back to active and you got
--    students.status = 'active' with enrollment status still 'graduated' —
--    proven by running it, not by reading it:
--
--        GRADUATED:       student=graduated enrollment=graduated
--        REINSTATED GRAD: student=active    enrollment=graduated
--
--    That child then shows as a current pupil on every student screen while
--    being in no class, billed nothing, and counted against no plan limit
--    (fn_count_students requires BOTH statuses active). Nothing on any screen
--    could reveal it.
--
-- 3. THERE WAS NO DATE. The only trace of a leaving was free text appended to
--    students.notes — "Status → withdrawn: Family moved to Karachi". No date, a
--    reason only if the clerk happened to type one, and both buried in a blob
--    that also holds every other note. A school could not answer "when did
--    Bilal leave" or "how many children left this term", and the date of
--    leaving is exactly what a government return and a leaving certificate ask
--    for.
--
-- 4. What DOES work, and is now pinned by tests because one careless
--    `create or replace` would silently break it: withdrawing a child stops
--    next month's invoice (fn_generate_class_invoices filters
--    enrollments.status) and stops them counting toward the plan limit.
-- =============================================================================

-- --- The two facts a register needs ------------------------------------------
alter table public.students add column if not exists left_on date;
alter table public.students add column if not exists leaving_reason text;

comment on column public.students.left_on is
  'Last day at the school. Written by fn_set_student_status, cleared on reinstatement.';
comment on column public.students.leaving_reason is
  'Why they left, as a field rather than buried in notes.';

-- An ACTIVE child with a leaving date is always a bug, and until now nothing
-- would have said so. The other direction is deliberately allowed: rows that
-- left before this migration have no date, and inventing one would be a lie.
alter table public.students drop constraint if exists students_left_on_chk;
alter table public.students add constraint students_left_on_chk
  check (status <> 'active' or (left_on is null and leaving_reason is null));

-- ---------------------------------------------------------------------------
-- fn_set_student_status — same name and same first three arguments, so every
-- existing caller keeps working; p_left_on is new and defaults to today.
--
-- Not `create or replace`: adding a parameter to a replaced function creates a
-- second overload rather than changing the first, and `fn_set_student_status(a,
-- b, c)` would then be ambiguous. The old signature has to go first.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_set_student_status(uuid, public.student_status, text);

create or replace function public.fn_set_student_status(
  p_student_id uuid,
  p_status     public.student_status,
  p_reason     text default null,
  p_left_on    date default current_date
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_before  public.students;
  v_on      date;
  v_active  integer;
  v_sess    uuid;
  v_cls     text;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only an owner or principal may change a student''s status'
      using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);

  select * into v_before from public.students
   where id = p_student_id and school_id = v_school and deleted_at is null;
  if not found then
    raise exception 'Student record not found';
  end if;
  if v_before.status = p_status then
    raise exception '% is already %', v_before.full_name, p_status::text;
  end if;

  select id into v_sess from public.academic_sessions
   where school_id = v_school and is_current;

  -- ---------------------------------------------------------------- leaving --
  if p_status <> 'active' then
    v_on := coalesce(p_left_on, current_date);

    -- A future last day would be a record saying the child was on the roll on a
    -- day the school had already stopped billing them.
    if v_on > current_date then
      raise exception 'The last day cannot be in the future';
    end if;
    if v_before.admission_date is not null and v_on < v_before.admission_date then
      raise exception 'Last day (%) is before the admission date (%)',
        v_on, v_before.admission_date;
    end if;

    update public.students
       set status         = p_status,
           left_on        = v_on,
           leaving_reason = nullif(p_reason, ''),
           -- The notes append is kept: it is the human narrative shown on the
           -- profile, and removing it would erase the only history older rows
           -- have. The columns above are for everything that needs to READ it.
           notes = case when nullif(p_reason, '') is null then notes
                        else coalesce(notes || E'\n', '')
                             || 'Status → ' || p_status::text || ' on '
                             || v_on::text || ': ' || p_reason end
     where id = p_student_id and school_id = v_school;

    update public.enrollments e
       set status = (case p_status
                       when 'struck_off' then 'struck_off'
                       when 'graduated'  then 'graduated'
                       when 'withdrawn'  then 'left'
                       else 'active' end)::public.enrollment_status
     where e.school_id = v_school
       and e.student_id = p_student_id
       and e.session_id = v_sess;

  -- ------------------------------------------------------------ coming back --
  else
    update public.students
       set status         = 'active',
           left_on        = null,
           leaving_reason = null,
           notes = case when nullif(p_reason, '') is null then notes
                        else coalesce(notes || E'\n', '')
                             || 'Reinstated on ' || current_date::text || ': ' || p_reason end
     where id = p_student_id and school_id = v_school;

    update public.enrollments e
       set status = 'active'
     where e.school_id = v_school
       and e.student_id = p_student_id
       and e.session_id = v_sess
       and e.status in ('struck_off', 'left');

    -- The check that was missing. A child marked active with no active
    -- enrollment in the current session is a child who reads as a current pupil
    -- everywhere and is in no class, billed nothing, and counted against no
    -- plan limit. Written as "is there an active enrollment" rather than as a
    -- list of enum values, so a new enrollment status cannot slip past it.
    select count(*) into v_active
      from public.enrollments e
     where e.school_id = v_school and e.student_id = p_student_id
       and e.session_id = v_sess and e.status = 'active';

    if v_active = 0 then
      raise exception
        '% cannot simply be made active again: they have no place in the current '
        'session (their last enrollment is %). Admit them into a class for this '
        'session instead.',
        v_before.full_name,
        coalesce((select e.status::text from public.enrollments e
                   where e.school_id = v_school and e.student_id = p_student_id
                   order by e.created_at desc, e.id desc limit 1), 'missing');
    end if;
  end if;

  select c.name || coalesce('-' || sec.name, '') into v_cls
    from public.enrollments e
    join public.classes c on c.id = e.class_id and c.school_id = v_school
    left join public.sections sec on sec.id = e.section_id
   where e.school_id = v_school and e.student_id = p_student_id
     and e.session_id = v_sess;

  insert into public.audit_log (
    school_id, actor, actor_role, action, entity, entity_id, before, after, reason)
  values (
    v_school, auth.uid(),
    (select role from public.profiles where id = auth.uid()),
    'STUDENT_STATUS', 'students', p_student_id::text,
    jsonb_build_object('status', v_before.status, 'left_on', v_before.left_on),
    jsonb_build_object('status', p_status, 'left_on',
                       case when p_status = 'active' then null else v_on end),
    p_reason);

  return jsonb_build_object(
    'student_name', v_before.full_name,
    'status',       p_status,
    'left_on',      case when p_status = 'active' then null else v_on end,
    'class_name',   coalesce(v_cls, '—'));
end;
$$;

-- ---------------------------------------------------------------------------
-- fn_students_left — the read, without which left_on would be one more column
-- written and never shown. That is the bug class this project keeps producing,
-- and it is documented in 0047.
-- ---------------------------------------------------------------------------
create or replace function public.fn_students_left(p_from date, p_to date)
returns table (
  left_on      date,
  student_id   uuid,
  student_name text,
  gr_no        text,
  father_name  text,
  phone        text,
  class_name   text,
  section_name text,
  status       text,
  reason       text,
  admitted_on  date,
  months_here  integer,
  balance      numeric
)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  -- An office report, not is_staff(). It carries what each child left OWING,
  -- and a class teacher has no business with arrears — the balance sheet and
  -- the finance summary draw the line in the same place. Widening it to every
  -- member of staff to save a role check would put the fee ledger in front of
  -- subject teachers by the side door.
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select
    s.left_on, s.id, s.full_name, s.gr_no, s.father_name, s.phone,
    c.name, sec.name, s.status::text, s.leaving_reason,
    s.admission_date,
    case when s.admission_date is not null and s.left_on is not null
         then (extract(year  from s.left_on) * 12 + extract(month from s.left_on)
             - extract(year  from s.admission_date) * 12 - extract(month from s.admission_date))::integer
    end,
    -- What they left owing. A school chasing arrears after a child has gone
    -- needs this on the same row as the phone number, not two screens away.
    public.student_balance(s.id)
  from public.students s
  -- The enrollment they held when they left, whatever its status is now, so the
  -- report can say WHICH class rather than leaving the column blank for exactly
  -- the children it is about.
  left join public.enrollments e
         on e.student_id = s.id and e.school_id = v_school
        and e.session_id = (select id from public.academic_sessions
                             where school_id = v_school and is_current)
  left join public.classes  c   on c.id = e.class_id   and c.school_id = v_school
  left join public.sections sec on sec.id = e.section_id and sec.school_id = v_school
  where s.school_id = v_school
    and s.deleted_at is null
    and s.status <> 'active'
    -- No `left_on is not null` here: BETWEEN already excludes it, because
    -- `null between x and y` is null rather than true. Writing it as well would
    -- be a line no test could defend — removing it changed no assertion, which
    -- is how it was found. What DOES defend the behaviour is the test's
    -- pre-0054 fixture row (a status with no date), which any null-tolerant
    -- rewrite of this range check would wrongly let through.
    and s.left_on between coalesce(p_from, '1900-01-01'::date)
                      and coalesce(p_to,   '2999-12-31'::date)
  order by s.left_on desc, s.full_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- Hardening, not a bug fix. Say so plainly.
--
-- fn_generate_class_invoices decides who to bill from enrollments.status alone.
-- fn_count_students — which decides who counts toward the paid plan — requires
-- students.status = 'active' AND enrollments.status = 'active' AND
-- students.deleted_at is null. Two functions answering "who is a current pupil"
-- with different conditions is a disagreement waiting for a reason.
--
-- Today it cannot bite: fn_set_student_status keeps both statuses in step, and
-- NOTHING in the entire codebase writes students.deleted_at, so that column is
-- read everywhere and written nowhere. This is therefore defence in depth, and
-- claiming otherwise would be overclaiming.
--
-- It is still worth having, because the failure mode is billing a child who has
-- left, and the change is one-directional: adding these conditions can only
-- ever bill FEWER children, and only ones whose own record says they are not
-- here. It cannot skip a child who is.
--
-- The body below is the LIVE definition with only the WHERE clause extended,
-- copied from pg_get_functiondef() so nothing else can drift in the copying.
CREATE OR REPLACE FUNCTION public.fn_generate_class_invoices(p_session_id uuid, p_class_id uuid, p_period_month date, p_due_date date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_actor    uuid := auth.uid();
  v_school   uuid := public.current_school_id();
  v_enr      record;
  v_inv      uuid;
  v_count    integer := 0;
  v_arrears  numeric;
  v_tuition  numeric;
  v_families uuid[] := '{}';
  v_fam      uuid;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to generate invoices';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);

  for v_enr in
    select e.id as enrollment_id, e.student_id
    from public.enrollments e
    -- The join added in 0054. See the note above: the student's own record must
    -- agree that they are here, not just the enrollment. This is the ONLY change
    -- to this function; everything else is pg_get_functiondef() output verbatim.
    join public.students s
      on s.id = e.student_id
     and s.school_id = v_school
     and s.status = 'active'
     and s.deleted_at is null
    where e.session_id = p_session_id and e.class_id = p_class_id and e.status = 'active'
      and not exists (
        select 1 from public.invoices i
        where i.enrollment_id = e.id and i.period_month = p_period_month and i.status <> 'void'
      )
  loop
    v_arrears := public.student_balance(v_enr.student_id);
    begin
      insert into public.invoices(
        student_id, enrollment_id, session_id, period_month, status,
        arrears_brought_forward, due_date, issued_at, created_by)
      values (
        v_enr.student_id, v_enr.enrollment_id, p_session_id, p_period_month, 'issued',
        v_arrears, p_due_date, now(), v_actor)
      returning id into v_inv;
    exception when unique_violation then
      continue;
    end;

    -- A per-student override (student_fee_items) still wins over the class
    -- amount; the class amount is now the one in force for the billed month.
    insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
    select v_inv, fh.id, fh.name, coalesce(sfi.amount, amt.amount), false
    from public.fee_heads fh
    join lateral (
      select fs.amount
      from public.fee_structures fs
      where fs.session_id = p_session_id
        and fs.class_id = p_class_id
        and fs.fee_head_id = fh.id
        and fs.effective_from <= coalesce(p_period_month, current_date)
      order by fs.effective_from desc
      limit 1
    ) amt on true
    left join public.student_fee_items sfi
      on sfi.enrollment_id = v_enr.enrollment_id and sfi.fee_head_id = fh.id and sfi.active
    where fh.school_id = v_school and fh.is_recurring and fh.active;

    select coalesce(sum(amount), 0) into v_tuition
    from public.invoice_lines where invoice_id = v_inv and not is_discount;

    perform public.fn__apply_discount_lines(v_inv, v_enr.enrollment_id, v_tuition);
    v_count := v_count + 1;

    select family_id into v_fam from public.students where id = v_enr.student_id;
    if v_fam is not null and not (v_fam = any(v_families)) then
      v_families := v_families || v_fam;
    end if;
  end loop;

  foreach v_fam in array v_families loop
    perform public.fn_apply_family_credit(v_fam);
  end loop;

  return v_count;
end;
$function$;

revoke all on function public.fn_set_student_status(uuid, public.student_status, text, date) from public;
revoke all on function public.fn_students_left(date, date) from public;

grant execute on function public.fn_set_student_status(uuid, public.student_status, text, date) to authenticated;
grant execute on function public.fn_students_left(date, date) to authenticated;
