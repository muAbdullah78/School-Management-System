-- =============================================================================
-- The portal — one login, role decides everything.
--
-- Parents and teachers sign in at the same place. A teacher gets their classes;
-- a parent gets their own children and nothing else.
--
-- ==========================  THE DANGER  ====================================
--
-- Twenty-five tables carried a policy of the form
--
--     using (school_id = public.current_school_id())
--
-- with NO role check — students, enrollments, attendance, marks, result cards,
-- guardians, families, staff, and more. Those were written when every account
-- in a school belonged to a member of staff, and under that assumption they
-- were correct.
--
-- Adding a 'parent' role to that world would have handed every parent the
-- entire school: every child's name, every mark, every attendance record, and
-- the contact details of every other family. Not through a bug — through the
-- policies working exactly as written.
--
-- So this migration does two independent things, and either one alone would
-- be enough to be nervous about:
--
--   1. Every one of those policies is rewritten to require public.is_staff().
--      A parent account has NO table-level read access anywhere. If a portal
--      function is buggy tomorrow, the tables are still shut.
--
--   2. The portal is served exclusively by SECURITY DEFINER functions that
--      filter to the caller's own family. Parents never touch a table.
--
-- The test suite proves both halves: that a parent cannot read the tables
-- directly, AND that they cannot reach another family through the functions.
-- =============================================================================

-- ===========================================================================
-- 1. The role
-- ===========================================================================

alter type public.user_role add value if not exists 'parent';

-- Which family a parent account speaks for. Null for every member of staff.
alter table public.profiles add column family_id uuid references public.families(id);
create index idx_profiles_family on public.profiles (family_id);

-- ===========================================================================
-- 2. The helper every policy now leans on
-- ===========================================================================

-- SECURITY DEFINER for the same reason as has_role(): policies call it, so it
-- must not recurse through profiles' own RLS. STABLE so the planner evaluates
-- it once per statement rather than once per row.
create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role from public.profiles where id = auth.uid()) <> 'parent', false);
$$;

create or replace function public.is_parent() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role from public.profiles where id = auth.uid()) = 'parent', false);
$$;

-- The family this caller speaks for. Null unless they are a parent account.
create or replace function public.my_family_id() returns uuid
language sql stable security definer set search_path = public as $$
  select family_id from public.profiles
  where id = auth.uid()
    and role = 'parent';
$$;

grant execute on function public.is_staff()     to authenticated;
grant execute on function public.is_parent()    to authenticated;
grant execute on function public.my_family_id() to authenticated;

-- ===========================================================================
-- 3. Shut every table to parent accounts
--
-- Generated from an explicit list rather than swept from the catalogue: a
-- sweep would silently "fix" a policy someone deliberately wrote differently,
-- and a security change should be readable in the diff.
-- ===========================================================================

-- DROP BY CATALOGUE, NOT BY GUESSED NAME.
--
-- RLS policies are permissive and OR together, so adding a restrictive policy
-- beside an existing one restricts nothing. The first version of this block
-- dropped `<table>_select` and created `<table>_select` — but 0025 had named
-- three of them `attendance_select`, `marks_select` and `teacher_assign_select`.
-- The drop matched nothing, the create added a SECOND policy, and parents could
-- still read attendance and marks through the surviving one.
--
-- So every SELECT policy on each table is enumerated from pg_policies and
-- dropped by its real name before the single correct policy is created. Naming
-- conventions are not a security boundary.
do $$
declare t text; p record;
begin
  foreach t in array array[
    'academic_sessions', 'assessments', 'attendance_daily', 'campuses',
    'classes', 'enrollments', 'exam_subjects', 'exam_terms', 'families',
    'fee_heads', 'fee_structures', 'guardians', 'mark_entries',
    'result_cards', 'sections', 'shifts', 'staff', 'student_links',
    'students', 'subjects', 'teacher_assignments'
  ] loop
    for p in
      select policyname from pg_policies
      where schemaname = 'public' and tablename = t and cmd = 'SELECT'
    loop
      execute format('drop policy %I on public.%I;', p.policyname, t);
    end loop;

    execute format($f$create policy %1$s_select on public.%1$s for select to authenticated
      using (school_id = public.current_school_id() and public.is_staff());$f$, t);
  end loop;
end $$;

-- school_settings: staff read it directly; the portal gets the school name
-- through fn_portal_me() instead, so parents need no table access here.
drop policy if exists settings_select on public.school_settings;
create policy settings_select on public.school_settings for select to authenticated
  using (school_id = public.current_school_id() and public.is_staff());

-- profiles: a parent may read exactly one row — their own. AuthProvider needs
-- it to know who is signed in.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (school_id = public.current_school_id()
         and (public.is_staff() or id = auth.uid()));

-- schools / subscriptions: licence state is a staff concern. A parent has no
-- business seeing what the school pays us, and the portal must keep working
-- for a family whether or not the school has paid this month.
drop policy if exists schools_select_own on public.schools;
create policy schools_select_own on public.schools for select to authenticated
  using (id = public.current_school_id() and public.is_staff());

drop policy if exists subscriptions_select_own on public.subscriptions;
create policy subscriptions_select_own on public.subscriptions for select to authenticated
  using (school_id = public.current_school_id() and public.is_staff());

-- ===========================================================================
-- 4. Guards
-- ===========================================================================

-- Raises unless this student is genuinely one of the caller's children.
-- Every portal function that takes a student_id goes through this first.
create or replace function public.fn__assert_my_child(p_student_id uuid)
returns void language plpgsql stable security definer set search_path = public as $$
declare v_fam uuid;
begin
  v_fam := public.my_family_id();
  if v_fam is null then
    raise exception 'Not a parent account' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.students s
    where s.id = p_student_id
      and s.family_id = v_fam
      and s.school_id = public.current_school_id()
  ) then
    -- Deliberately the same message whether the student does not exist or
    -- belongs to someone else: a distinguishable error is an enumeration
    -- oracle for guessing other families' student ids.
    raise exception 'Not your child' using errcode = '42501';
  end if;
end;
$$;

-- Linking a parent account to a family is an owner/principal act. It is the
-- single most sensitive write in the portal: point it at the wrong family and
-- a stranger sees a child's records.
create or replace function public.fn_link_parent(p_profile_id uuid, p_family_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may link a parent account';
  end if;
  perform public.assert_own('families', p_family_id);
  perform public.assert_own('profiles', p_profile_id);
  if (select role from public.profiles where id = p_profile_id) <> 'parent' then
    raise exception 'That account is not a parent account';
  end if;
  update public.profiles set family_id = p_family_id where id = p_profile_id;
end;
$$;

grant execute on function public.fn_link_parent(uuid, uuid) to authenticated;
revoke all on function public.fn__assert_my_child(uuid) from public, anon;

-- ===========================================================================
-- 5. The portal API
--
-- Everything a parent sees comes through these. They are SECURITY DEFINER, so
-- they carry the whole burden of scoping — which is why each one starts by
-- resolving my_family_id() rather than trusting an id from the client.
-- ===========================================================================

-- Who am I, and what am I allowed to look at.
create or replace function public.fn_portal_me()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_p record; v_school text; v_children jsonb; v_classes jsonb;
begin
  select p.*, s.name as school_name into v_p
  from public.profiles p
  left join public.schools s on s.id = p.school_id
  where p.id = auth.uid();
  if not found then raise exception 'Not signed in' using errcode = '42501'; end if;

  v_school := coalesce(
    (select ss.name from public.school_settings ss where ss.school_id = v_p.school_id),
    v_p.school_name);

  if v_p.role = 'parent' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'student_id', s.id, 'full_name', s.full_name, 'gr_no', s.gr_no,
             'class_name', c.name, 'section_name', sec.name, 'status', s.status
           ) order by s.full_name), '[]'::jsonb)
      into v_children
    from public.students s
    left join public.enrollments e on e.student_id = s.id and e.status = 'active'
    left join public.classes c on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
    where s.family_id = v_p.family_id and s.deleted_at is null;
  else
    v_children := '[]'::jsonb;
  end if;

  if v_p.role in ('class_teacher', 'subject_teacher') then
    select coalesce(jsonb_agg(to_jsonb(a)), '[]'::jsonb) into v_classes
    from public.fn_my_assignments() a;
  else
    v_classes := '[]'::jsonb;
  end if;

  return jsonb_build_object(
    'profile_id', v_p.id,
    'full_name', v_p.full_name,
    'role', v_p.role,
    'school_name', v_school,
    'children', v_children,
    'classes', v_classes);
end;
$$;

-- A child's fee position: what is owed, and every receipt the family holds.
create or replace function public.fn_portal_child_fees(p_student_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_fam uuid; v_out jsonb;
begin
  perform public.fn__assert_my_child(p_student_id);
  v_fam := public.my_family_id();

  select jsonb_build_object(
    'student_id', p_student_id,
    'balance', public.student_balance(p_student_id),
    'family_outstanding', public.family_outstanding(v_fam),
    'family_credit', public.family_credit(v_fam),
    'invoices', coalesce((
      select jsonb_agg(jsonb_build_object(
        'period_month', i.period_month, 'due_date', i.due_date,
        'charge', b.charge, 'paid', b.allocated,
        'outstanding', b.charge - b.allocated, 'status', b.status
      ) order by i.period_month desc nulls last)
      from public.invoice_balances b
      join public.invoices i on i.id = b.invoice_id
      where b.student_id = p_student_id
    ), '[]'::jsonb),
    'receipts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'receipt_no', p.receipt_no, 'amount', p.amount,
        'method', p.method, 'paid_on', p.created_at,
        'received_by', pr.full_name
      ) order by p.created_at desc)
      from public.payments p
      left join public.profiles pr on pr.id = p.received_by
      where p.family_id = v_fam and p.status = 'verified'
    ), '[]'::jsonb)
  ) into v_out;

  return v_out;
end;
$$;

create or replace function public.fn_portal_child_attendance(
  p_student_id uuid, p_from date, p_to date
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb; v_present integer; v_total integer;
begin
  perform public.fn__assert_my_child(p_student_id);

  select count(*) filter (where a.status in ('present', 'late', 'half_day')),
         count(*)
    into v_present, v_total
  from public.attendance_daily a
  join public.enrollments e on e.id = a.enrollment_id
  where e.student_id = p_student_id
    and a.attendance_date between p_from and p_to;

  select jsonb_build_object(
    'from', p_from, 'to', p_to,
    'present', coalesce(v_present, 0),
    'marked', coalesce(v_total, 0),
    'percent', case when coalesce(v_total, 0) = 0 then null
                    else round((v_present::numeric / v_total) * 100) end,
    'days', coalesce((
      select jsonb_agg(jsonb_build_object('date', a.attendance_date, 'status', a.status)
             order by a.attendance_date desc)
      from public.attendance_daily a
      join public.enrollments e on e.id = a.enrollment_id
      where e.student_id = p_student_id
        and a.attendance_date between p_from and p_to
    ), '[]'::jsonb)
  ) into v_out;
  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------
-- Results need a release switch, which did not exist before the portal.
--
-- `result_cards.frozen` is a jsonb reprint snapshot, not a publish flag — it
-- is written on every generation. So the moment a clerk generated cards to
-- check them, every parent would have seen the marks. Schools release results
-- deliberately, often at a parent meeting, and a mark a parent saw and then
-- saw change turns every correction into an accusation.
--
-- Generation also VERSIONS: regenerating writes version 2, 3, ... and leaves
-- the old rows. The portal must show only the newest version per term, or a
-- parent sees a superseded result sitting next to the real one.
-- ---------------------------------------------------------------------------

alter table public.result_cards add column published_at timestamptz;
create index idx_result_cards_published on public.result_cards (student_id, published_at);

create or replace function public.fn_publish_results(p_exam_term_id uuid, p_class_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may release results to parents';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('classes', p_class_id);

  with latest as (
    select distinct on (rc.enrollment_id) rc.id
    from public.result_cards rc
    join public.enrollments e on e.id = rc.enrollment_id
    where rc.exam_term_id = p_exam_term_id and e.class_id = p_class_id
    order by rc.enrollment_id, rc.version desc
  )
  update public.result_cards rc
     set published_at = now()
    from latest l
   where rc.id = l.id and rc.published_at is null;

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- Pulling a result back is a real need — a mistake spotted an hour later.
create or replace function public.fn_unpublish_results(p_exam_term_id uuid, p_class_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may withdraw results';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('classes', p_class_id);

  update public.result_cards rc
     set published_at = null
    from public.enrollments e
   where e.id = rc.enrollment_id
     and rc.exam_term_id = p_exam_term_id and e.class_id = p_class_id
     and rc.published_at is not null;

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- Results the parent may see: published, newest version per term, and honouring
-- the term's withhold-from-defaulters setting. A withheld card still appears —
-- silently hiding it looks like the school lost the result — but it carries the
-- reason instead of the marks.
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
               'position', x.position, 'attendance_pct', x.attendance_pct,
               'subjects', coalesce(x.frozen->'subjects', '[]'::jsonb),
               'issued_at', x.issued_at)
           end
           order by x.issued_at desc), '[]'::jsonb)
    into v_out
  from (
    select distinct on (rc.exam_term_id)
           rc.id, et.name as term, rc.total_marks, rc.total_max, rc.percentage,
           rc.grade, rc.position, rc.attendance_pct, rc.frozen,
           rc.published_at as issued_at,
           coalesce((rc.frozen->>'withheld')::boolean, false) as withheld
    from public.result_cards rc
    join public.exam_terms et on et.id = rc.exam_term_id
    where rc.student_id = p_student_id
      and rc.published_at is not null
    order by rc.exam_term_id, rc.version desc
  ) x;

  return coalesce(v_out, '[]'::jsonb);
end;
$$;

grant execute on function public.fn_publish_results(uuid, uuid)   to authenticated;
grant execute on function public.fn_unpublish_results(uuid, uuid) to authenticated;

grant execute on function public.fn_portal_me()                                to authenticated;
grant execute on function public.fn_portal_child_fees(uuid)                    to authenticated;
grant execute on function public.fn_portal_child_attendance(uuid, date, date)  to authenticated;
grant execute on function public.fn_portal_child_results(uuid)                 to authenticated;
