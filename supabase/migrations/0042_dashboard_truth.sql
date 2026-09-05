-- =============================================================================
-- 0042 — The dashboard was leaking other schools' money, and lying about dues.
--
-- ── BUG 1: A CROSS-TENANT LEAK ──────────────────────────────────────────────
--
-- fn_dashboard_summary is SECURITY DEFINER, so it runs as the function owner
-- and Row Level Security does not apply to it. Most of its queries were safe by
-- accident, because they join enrollments and filter on the caller's current
-- session id. Three were not, and had no school filter at all:
--
--     select count(*) from public.students
--      where date_trunc('month', s.created_at) = date_trunc('month', current_date);
--
--     select coalesce(sum(amount), 0) from public.payments
--      where status = 'verified' and created_at::date = current_date;
--
--     ...and the same for the month.
--
-- So "New this month", "Collected today" and "Collected this month" were
-- computed across EVERY SCHOOL IN THE DATABASE. Measured on a test database: a
-- school with one student and no payments was shown 271 new admissions and
-- Rs 24,577 collected today — the platform's totals, on the first three numbers
-- an owner reads every morning.
--
-- This is a tenant reading another tenant's financial position. The existing
-- tenant_isolation suite did not catch it because it tests table access, and
-- this leak is inside a SECURITY DEFINER function where RLS is not consulted.
-- supabase/tests/dashboard.sql now asserts every figure this function returns.
--
-- The lesson worth writing down: in a SECURITY DEFINER function, "the policy
-- will handle it" is never true. Every query needs its own school_id filter.
--
-- ── BUG 2: "NOTHING OWED" WHEN NOTHING WAS BILLED ───────────────────────────
--
-- Outstanding and the defaulter count derive only from invoice rows, so a
-- school that has never generated a challan is told it is owed Rs 0 by 0
-- students — rendered as good news, in green, while the attendance tile beside
-- it correctly shows "not marked yet today".
--
-- Worse, fn_generate_class_invoices on a class with no fee_structures rows
-- creates invoices with ZERO lines and status 'issued'. So a school can press
-- "Generate monthly challans", be told it succeeded, bill every student Rs 0,
-- and still see Outstanding Rs 0.
--
-- Numbers are not enough to fix this: Rs 0 owed and Rs 0 billed look identical.
-- So the function now also returns HOW MANY students were billed this month and
-- how many classes have no fee structure at all, and the UI leads with that
-- when there is nothing billed.
-- =============================================================================

create or replace function public.fn_dashboard_summary()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_session uuid := (select current_session_id from public.school_settings
                      where school_id = v_school);
  v_finance boolean := public.has_role('owner','principal','admin_clerk','accountant','readonly');
  v_active  int;
  v_present int; v_absent int; v_leave int; v_late int; v_half int; v_marked int;
  v_today numeric; v_month numeric; v_outstanding numeric; v_defaulters int;
  v_new_admissions int;
  v_billed_month int;
  v_classes_no_fee int;
  v_month_start date := date_trunc('month', current_date)::date;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant',
                         'class_teacher','subject_teacher','readonly') then
    raise exception 'Not permitted';
  end if;

  select count(*) into v_active
  from public.enrollments e
  where e.school_id = v_school and e.session_id = v_session and e.status = 'active';

  select
    count(*) filter (where ad.status = 'present'),
    count(*) filter (where ad.status = 'absent'),
    count(*) filter (where ad.status = 'leave'),
    count(*) filter (where ad.status = 'late'),
    count(*) filter (where ad.status = 'half_day'),
    count(*)
  into v_present, v_absent, v_leave, v_late, v_half, v_marked
  from public.attendance_daily ad
  join public.enrollments e on e.id = ad.enrollment_id
  where ad.school_id = v_school
    and ad.attendance_date = current_date
    and e.session_id = v_session;

  -- WAS THE LEAK. Now scoped to this school, and soft-deleted students are
  -- excluded — a record removed in error was still inflating the admissions
  -- figure it had been counted in.
  select count(*) into v_new_admissions
  from public.students s
  where s.school_id = v_school
    and s.deleted_at is null
    and s.created_at >= v_month_start
    and s.created_at < (v_month_start + interval '1 month');

  if v_finance then
    -- WAS THE LEAK. Both of these summed every school's payments.
    select coalesce(sum(p.amount), 0) into v_today
    from public.payments p
    where p.school_id = v_school
      and p.status = 'verified'
      and p.created_at >= date_trunc('day', now())
      and p.created_at <  date_trunc('day', now()) + interval '1 day';

    select coalesce(sum(p.amount), 0) into v_month
    from public.payments p
    where p.school_id = v_school
      and p.status = 'verified'
      and p.created_at >= v_month_start
      and p.created_at <  (v_month_start + interval '1 month');

    select coalesce(sum(b.bal), 0), count(*) into v_outstanding, v_defaulters
    from public.enrollments e
    join lateral (select public.student_balance(e.student_id) as bal) b on true
    where e.school_id = v_school
      and e.session_id = v_session
      and e.status = 'active'
      and b.bal > 0;

    -- The two figures that let the UI tell "paid up" from "never billed".
    --
    -- A challan with no lines is NOT billing: fn_generate_class_invoices on a
    -- class with no fee structure produces exactly that, reports success, and
    -- leaves Outstanding at zero. So a student counts as billed only if their
    -- challan actually charges something.
    select count(distinct i.student_id) into v_billed_month
    from public.invoices i
    where i.school_id = v_school
      and i.period_month = v_month_start
      and i.status <> 'void'
      and coalesce((select sum(case when l.is_discount then -l.amount else l.amount end)
                      from public.invoice_lines l where l.invoice_id = i.id), 0) > 0;

    -- Classes with active students and no fee structure for this session. This
    -- is the root cause behind a Rs 0 challan, so it is worth naming rather
    -- than leaving the school to work out why the numbers look wrong.
    select count(*) into v_classes_no_fee
    from public.classes c
    where c.school_id = v_school
      and exists (select 1 from public.enrollments e
                   where e.class_id = c.id and e.session_id = v_session and e.status = 'active')
      and not exists (select 1 from public.fee_structures fs
                       where fs.class_id = c.id and fs.session_id = v_session and fs.amount > 0);
  end if;

  return jsonb_build_object(
    'active_students', coalesce(v_active, 0),
    'new_admissions_month', coalesce(v_new_admissions, 0),
    'attendance', jsonb_build_object(
      'marked', coalesce(v_marked, 0), 'present', coalesce(v_present, 0),
      'absent', coalesce(v_absent, 0), 'leave', coalesce(v_leave, 0),
      'late', coalesce(v_late, 0), 'half_day', coalesce(v_half, 0)),
    'finance_visible', v_finance,
    'collected_today', coalesce(v_today, 0),
    'collected_month', coalesce(v_month, 0),
    'outstanding', coalesce(v_outstanding, 0),
    'defaulters', coalesce(v_defaulters, 0),
    -- New. The UI leads with these when they say nothing has been billed,
    -- instead of showing a green Rs 0.
    'billed_students_month', coalesce(v_billed_month, 0),
    'classes_without_fee', coalesce(v_classes_no_fee, 0),
    -- A null current session made every session-scoped figure silently zero.
    -- Saying so lets the UI show a setup prompt rather than a school that looks
    -- empty.
    'session_set', v_session is not null);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. One more of the same kind, found by sweeping for it.
--
-- Having established that a SECURITY DEFINER function without its own school
-- filter is a cross-tenant read, I swept every such function in the schema for
-- the pattern. Almost all were safe — they scope by auth.uid(), or delegate to
-- a gate that scopes (fn_may_manage_class checks the session, class AND section
-- all belong to current_school_id(); fn__assert_my_child does the equivalent
-- for the portal) — but fn_fee_amount had no scoping whatsoever:
--
--     select fs.amount from public.fee_structures fs
--      where fs.session_id = p_session_id and fs.class_id = p_class_id ...
--
-- Three uuids and you read another school's fee schedule. Far less serious than
-- the dashboard — a fee amount, and you would have to know the ids — but it is
-- the same hole and it costs one line to close.
-- ---------------------------------------------------------------------------
create or replace function public.fn_fee_amount(
  p_session_id uuid, p_class_id uuid, p_fee_head_id uuid, p_on date
) returns numeric language sql stable security definer set search_path = public as $$
  select fs.amount
  from public.fee_structures fs
  where fs.school_id = public.current_school_id()
    and fs.session_id = p_session_id
    and fs.class_id = p_class_id
    and fs.fee_head_id = p_fee_head_id
    and fs.effective_from <= coalesce(p_on, current_date)
  order by fs.effective_from desc
  limit 1;
$$;

-- ---------------------------------------------------------------------------
-- 4. fn_apply_family_credit — an unscoped cross-tenant WRITE.
--
-- The same sweep found this, and it is the worst of the set because it mutates.
-- It took any family_id, had NO role check and NO assert_own, and was granted to
-- `authenticated` — so any signed-in user, a parent included, could pass another
-- school's family id and have that family's payments reallocated across their
-- children's invoices.
--
-- It has no callers in the app (migration 0029 granted it speculatively), so
-- nothing is broken by locking it down now.
-- ---------------------------------------------------------------------------
create or replace function public.fn_apply_family_credit(p_family_id uuid)
returns numeric language plpgsql security definer set search_path = public as $$
declare
  v_students uuid[];
  v_pay      record;
  v_left     numeric;
  v_applied  numeric := 0;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to apply family credit';
  end if;
  perform public.assert_own('families', p_family_id);

  select array_agg(id) into v_students
  from public.students
  where family_id = p_family_id and school_id = public.current_school_id();
  if v_students is null then return 0; end if;

  for v_pay in
    select p.id, p.amount - coalesce((
             select sum(al.amount) from public.payment_allocations al
             where al.payment_id = p.id), 0) as unallocated
    from public.payments p
    where p.family_id = p_family_id
      and p.school_id = public.current_school_id()
      and p.status = 'verified'
    order by p.created_at, p.id
  loop
    if v_pay.unallocated > 0 then
      v_left := public.fn__allocate_payment(v_pay.id, v_students, v_pay.unallocated);
      v_applied := v_applied + (v_pay.unallocated - v_left);
    end if;
  end loop;

  return v_applied;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. fn_import_staff — duplicate checks that spanned every school.
--
-- Also from the sweep:
--
--     exists (select 1 from public.staff where employee_no = v_emp ...)
--     exists (select 1 from public.staff where cnic = v_cnic ...)
--
-- No school filter, so importing staff rejected rows as duplicates because
-- ANOTHER school already used that employee number — and a teacher who works at
-- two schools on the platform could never be added to the second, because their
-- CNIC was "taken". It also told the importing school, by implication, that
-- some other school holds that number.
--
-- Only the two exists() clauses change; the rest of the function is untouched.
-- ---------------------------------------------------------------------------
--
-- THE GUARD AND THE ASSERTION WERE BOTH MISSING, and each absence was its own
-- fault. Measured by pasting the bundles a second time, which is what a school
-- does when it is not sure the first paste took:
--
--   * without the guard, the clause was appended AGAIN, giving
--     `... and school_id = current_school_id() and school_id = current_school_id()`
--     and one more copy on every paste after that. Harmless to the answer and
--     unbounded in the text, which is how a function body becomes unreadable
--     to the next person who has to patch it.
--   * without the assertion, a `replace()` that matches nothing succeeds
--     silently. This is the only thing that scopes two SECURITY DEFINER
--     lookups to the importing school, so the failure mode was a tenant
--     isolation hole reporting success.
--
-- supabase/check-patch-anchors.py now refuses a whitespace-dependent pattern,
-- and the bundles are re-pasted in CI with every function body compared, which
-- is what found this.
do $$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_import_staff';

  if v_def is null then
    raise exception '0042: fn_import_staff is not present; apply the earlier bundles first';
  end if;

  if v_def like '%employee_no = v_emp and deleted_at is null and school_id = public.current_school_id()%' then
    raise notice '0042: fn_import_staff already scopes its duplicate checks';
  else
    v_new := replace(v_def,
      'from public.staff where employee_no = v_emp and deleted_at is null',
      'from public.staff where employee_no = v_emp and deleted_at is null'
        || ' and school_id = public.current_school_id()');
    v_new := replace(v_new,
      'from public.staff where cnic = v_cnic and deleted_at is null',
      'from public.staff where cnic = v_cnic and deleted_at is null'
        || ' and school_id = public.current_school_id()');

    if v_new = v_def then
      raise exception '0042: could not find the duplicate-employee and '
        'duplicate-CNIC lookups in fn_import_staff. It has been reworded, so '
        'nothing was changed and the import would keep reading other schools'' '
        'staff. Update the patterns in this migration.';
    end if;
    execute v_new;
  end if;

  -- The end state, not the edit. Both lookups, or neither counts.
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_import_staff';
  if v_def not like '%employee_no = v_emp and deleted_at is null and school_id = public.current_school_id()%'
     or v_def not like '%cnic = v_cnic and deleted_at is null and school_id = public.current_school_id()%' then
    raise exception '0042: fn_import_staff still checks for duplicates across '
      'every school on the platform';
  end if;
end $$;
