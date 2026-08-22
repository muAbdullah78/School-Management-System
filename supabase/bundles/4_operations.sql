-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0040_bulk_fees.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0040 — Collecting from a class, not one family at a time.
--
-- WHY
--
-- A Pakistani school takes 100–400 fee payments in the first ten days of a
-- month. Until now every one of them meant a separate search: type a name or a
-- CNIC, wait, pick the family, enter an amount, submit, start again. Four
-- hundred searches.
--
-- And the screen that already knew who owed money — Fees > Defaulters — was a
-- read-only dead end. It rendered bare table rows with no Collect action, no
-- reminder, and no link to the student. The fee_reminder and fee_reminder_final
-- templates have existed since 0034 and nothing has ever sent one.
--
-- Their product calls this "Bulk Fee Payment" and "SMS To Fee Defaulters". This
-- migration is the data layer for both, adapted to WhatsApp.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--
-- It does not reimplement allocation. fn_record_bulk_payments loops and calls
-- fn_record_payment, which is the one function that knows how money is applied
-- to invoices. A second allocator that drifted from the first would be the
-- worst bug this system could have, and "it was faster in a loop" is not worth
-- that risk.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The worklist: everyone in a class and what they owe.
--
-- This is the screen a clerk works down with a cash box, so it returns the
-- whole class — not just the defaulters. A clerk needs to see "Ahmed: paid" to
-- know they have not skipped him, and a list that hides the paid students makes
-- that impossible.
--
-- month_due is what THIS month's challan still needs; total_due is everything
-- the student owes. Both, because a parent hands over money for one month while
-- the clerk needs to know the real position.
-- ---------------------------------------------------------------------------
create or replace function public.fn_class_dues(
  p_session_id   uuid,
  p_class_id     uuid,
  p_section_id   uuid,
  p_period_month date
) returns table (
  student_id   uuid,
  full_name    text,
  gr_no        text,
  roll_no      text,
  father_name  text,
  phone        text,
  family_id    uuid,
  family_head  text,
  invoice_id   uuid,
  voucher_code text,
  month_charge numeric,
  month_paid   numeric,
  month_due    numeric,
  total_due    numeric,
  last_paid_at timestamptz
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);
  perform public.assert_own('sections', p_section_id);

  return query
  select
    s.id,
    s.full_name,
    s.gr_no,
    e.roll_no,
    s.father_name,
    coalesce(nullif(s.whatsapp, ''), nullif(s.phone, ''), f.whatsapp, f.phone),
    s.family_id,
    f.head_name,
    i.id,
    i.voucher_code,
    coalesce(ch.charge, 0),
    coalesce(pd.paid, 0),
    coalesce(ch.charge, 0) - coalesce(pd.paid, 0),
    public.student_balance(s.id),
    lp.last_at
  from public.enrollments e
  join public.students s on s.id = e.student_id
  left join public.families f on f.id = s.family_id
  -- The challan for the month being collected, if one was generated.
  left join public.invoices i
    on i.enrollment_id = e.id
   and i.period_month = p_period_month
   and i.status <> 'void'
  left join lateral (
    select coalesce(sum(case when l.is_discount then -l.amount else l.amount end), 0)
             + coalesce(i.fine, 0) as charge
      from public.invoice_lines l where l.invoice_id = i.id
  ) ch on true
  left join lateral (
    select coalesce(sum(al.amount), 0) as paid
      from public.payment_allocations al
      join public.payments p on p.id = al.payment_id
     where al.invoice_id = i.id and p.status = 'verified'
  ) pd on true
  -- When this student last paid anything. A clerk uses it to spot the family
  -- that has not been seen for three months, which a balance alone hides.
  left join lateral (
    select max(p2.created_at) as last_at
      from public.payments p2
     where p2.status = 'verified'
       and (p2.student_id = s.id
            or exists (select 1
                         from public.payment_allocations al2
                         join public.invoices i2 on i2.id = al2.invoice_id
                        where al2.payment_id = p2.id and i2.student_id = s.id))
  ) lp on true
  where e.session_id = p_session_id
    and e.class_id = p_class_id
    and (p_section_id is null or e.section_id = p_section_id)
    and e.status = 'active'
    and s.deleted_at is null
    and s.school_id = public.current_school_id()
  order by coalesce(nullif(regexp_replace(coalesce(e.roll_no, ''), '[^0-9]', '', 'g'), '')::int, 999999),
           s.full_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Take many payments in one go.
--
-- p_items is [{"student_id": "...", "amount": 1200}, ...].
--
-- ONE TRANSACTION on purpose. If the eleventh row is bad the whole batch rolls
-- back, so a clerk never ends up with ten receipts issued and no idea which of
-- the forty rows they typed went through. Refusing the batch and showing the
-- bad row is recoverable; a half-applied batch is not.
--
-- Every payment goes through fn_record_payment, so allocation, receipt
-- numbering, the till, and the WhatsApp receipt trigger all behave exactly as
-- they do for a single payment at the counter.
-- ---------------------------------------------------------------------------
create or replace function public.fn_record_bulk_payments(
  p_items  jsonb,
  p_method public.payment_method default 'cash',
  p_note   text default null,
  p_pending boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_item    jsonb;
  v_student uuid;
  v_amount  numeric;
  v_res     jsonb;
  v_out     jsonb := '[]'::jsonb;
  v_total   numeric := 0;
  v_count   int := 0;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to take payments';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'Nothing to record';
  end if;
  if jsonb_array_length(p_items) = 0 then
    raise exception 'Nothing to record — no students were ticked';
  end if;
  -- A guard against a runaway client, not a real limit: the largest class in a
  -- Pakistani school is nowhere near this.
  if jsonb_array_length(p_items) > 500 then
    raise exception 'Too many rows in one batch (%). Split it by section.',
      jsonb_array_length(p_items);
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_student := nullif(v_item->>'student_id', '')::uuid;
    v_amount  := nullif(v_item->>'amount', '')::numeric;

    if v_student is null then
      raise exception 'A row has no student';
    end if;
    -- Named in the error so the clerk can find the row, rather than being told
    -- "invalid amount" about a batch of forty.
    if v_amount is null or v_amount <= 0 then
      raise exception 'Amount for % must be more than zero',
        coalesce((select full_name from public.students where id = v_student), 'a student');
    end if;

    -- fn_record_payment asserts ownership of the student itself, which is what
    -- stops a crafted payload writing a receipt into another school.
    v_res := public.fn_record_payment(v_student, v_amount, p_method, p_note, p_pending);

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'student_id', v_student,
      'amount',     v_amount,
      'receipt_no', v_res->'receipt_no'));
    v_total := v_total + v_amount;
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('count', v_count, 'total', v_total, 'receipts', v_out);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Queue a fee reminder for every family in a class that owes money.
--
-- Their product sends three escalating reminders — polite, firmer, then a
-- warning that the child will not be allowed to attend. That escalation is the
-- part worth copying: one identical message sent three times gets ignored.
--
-- The escalation level is derived from how many reminders this family has
-- ALREADY been sent for the current month, so a clerk pressing the button twice
-- in an afternoon does not jump a family straight to the final warning.
--
-- One message per FAMILY, not per child. A father with three children owing
-- fees gets one WhatsApp, which is the difference between a reminder and
-- spam — and the reason he will still read the next one.
-- ---------------------------------------------------------------------------
create or replace function public.fn_queue_class_reminders(
  p_session_id uuid,
  p_class_id   uuid,
  p_section_id uuid
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_fam    record;
  v_sent   int;
  v_key    text;
  v_queued int := 0;
  v_skipped int := 0;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to send reminders';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);
  perform public.assert_own('sections', p_section_id);

  for v_fam in
    select s.family_id,
           max(f.head_name)                            as head_name,
           string_agg(distinct s.full_name, ', ')       as children,
           sum(public.student_balance(s.id))            as owed
    from public.enrollments e
    join public.students s on s.id = e.student_id
    left join public.families f on f.id = s.family_id
    where e.session_id = p_session_id
      and e.class_id = p_class_id
      and (p_section_id is null or e.section_id = p_section_id)
      and e.status = 'active'
      and s.deleted_at is null
      and s.school_id = public.current_school_id()
      and s.family_id is not null
    group by s.family_id
    having sum(public.student_balance(s.id)) > 0
  loop
    -- How many reminders have already gone out to this family this month.
    select count(*) into v_sent
    from public.message_outbox m
    where m.family_id = v_fam.family_id
      and m.template_key in ('fee_reminder', 'fee_reminder_final')
      and m.created_at >= date_trunc('month', now());

    v_key := case when v_sent >= 2 then 'fee_reminder_final' else 'fee_reminder' end;

    -- fn_queue_message respects message_templates.enabled, so a school that has
    -- switched reminders off is not overridden by a bulk action.
    begin
      perform public.fn_queue_message(
        v_key,
        v_fam.family_id,
        jsonb_build_object(
          'parent',   coalesce(v_fam.head_name, 'Parent'),
          'children', v_fam.children,
          'amount',   to_char(v_fam.owed, 'FM999999990')),
        null,
        null);
      v_queued := v_queued + 1;
    exception when others then
      -- One family with no phone number must not abandon the other thirty-nine.
      v_skipped := v_skipped + 1;
    end;
  end loop;

  return jsonb_build_object('queued', v_queued, 'skipped', v_skipped);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Grants.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_class_dues(uuid, uuid, uuid, date)                        to authenticated;
grant execute on function public.fn_record_bulk_payments(jsonb, public.payment_method, text, boolean) to authenticated;
grant execute on function public.fn_queue_class_reminders(uuid, uuid, uuid)                   to authenticated;

revoke all on function public.fn_class_dues(uuid, uuid, uuid, date)                        from anon;
revoke all on function public.fn_record_bulk_payments(jsonb, public.payment_method, text, boolean) from anon;
revoke all on function public.fn_queue_class_reminders(uuid, uuid, uuid)                   from anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0041_student_list.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0041 — A student list that can hold a real school.
--
-- WHAT WAS WRONG
--
-- listStudents() hard-coded `.limit(50)` with no count and no "showing 50 of
-- N". An 800-student school saw the first fifty names alphabetically and was
-- never told the other 750 existed. Silent truncation on the flagship list of
-- the product.
--
-- It was not even a table: a <ul> of buttons showing name, father's name and GR
-- number. No class, no section, no roll number, and no BALANCE — on a product
-- whose entire purpose is students and money.
--
-- WHY THIS IS SQL AND NOT A BIGGER LIMIT
--
-- Adding a balance column is what forces this into the database. Calling
-- student_balance() once per row from the client would be 800 round trips, and
-- calling it 800 times inside one query is 800 correlated subqueries. This
-- computes charges and payments set-based, aggregated once, then joins — so the
-- cost is the same whether the class has 20 students or 2,000.
--
-- The exact total comes back with the page, because "showing 50 of 812" is the
-- difference between a list a school trusts and one that quietly lies.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. One page of students, with everything a school actually looks for.
--
-- Filters are all optional and compose: a text term (name, GR, admission no,
-- father's name), a class, a section, and whether to include struck-off
-- students. That last one matters — a struck-off child still has a balance and
-- a school still needs to find them, but they must not clutter the daily list.
-- ---------------------------------------------------------------------------
create or replace function public.fn_student_list(
  p_term      text default null,
  p_class_id  uuid default null,
  p_section_id uuid default null,
  p_include_inactive boolean default false,
  p_limit     integer default 50,
  p_offset    integer default 0
) returns table (
  student_id   uuid,
  full_name    text,
  gr_no        text,
  admission_no text,
  father_name  text,
  gender       text,
  phone        text,
  status       text,
  class_name   text,
  section_name text,
  roll_no      text,
  family_id    uuid,
  balance      numeric,
  total_count  bigint
) language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_term   text := nullif(btrim(coalesce(p_term, '')), '');
  v_like   text;
  v_limit  int  := greatest(1, least(coalesce(p_limit, 50), 500));
  v_offset int  := greatest(0, coalesce(p_offset, 0));
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('classes', p_class_id);
  perform public.assert_own('sections', p_section_id);

  -- ESCAPE the LIKE metacharacters rather than stripping them.
  --
  -- A first version replaced %, _ and backslash with a SPACE, which quietly
  -- widened every search: typing a single "%" became the pattern '% %', which
  -- matches any name containing a space — i.e. the entire school. Escaping
  -- makes them match literally, so "%" finds the students whose name actually
  -- contains a percent sign, which is none of them.
  --
  -- Backslash first, or the escapes added afterwards get escaped in turn.
  v_like := case when v_term is null then null
                 else '%' ||
                      replace(replace(replace(v_term, '\\', '\\\\'), '%', '\\%'), '_', '\\_')
                      || '%' end;

  return query
  with base as (
    select s.id, s.full_name, s.gr_no, s.admission_no, s.father_name,
           s.gender::text as gender,
           coalesce(nullif(s.whatsapp, ''), s.phone) as phone,
           s.status::text as status, s.family_id,
           c.name as class_name, sec.name as section_name, e.roll_no
    from public.students s
    left join public.enrollments e
      on e.student_id = s.id and e.status = 'active'
    left join public.classes c   on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
    where s.school_id = v_school
      and s.deleted_at is null
      and (p_include_inactive or s.status = 'active')
      and (p_class_id is null or e.class_id = p_class_id)
      and (p_section_id is null or e.section_id = p_section_id)
      and (v_like is null
           or s.full_name    ilike v_like
           or s.gr_no        ilike v_like
           or s.admission_no ilike v_like
           or s.father_name  ilike v_like)
  ),
  -- Charges and payments aggregated ONCE over the whole filtered set, rather
  -- than student_balance() called per row. Same arithmetic as student_balance:
  -- lines (discounts negative) + fines + adjustments − verified allocations.
  charges as (
    select i.student_id,
           sum(case when l.is_discount then -l.amount else l.amount end) as amt
    from public.invoices i
    join public.invoice_lines l on l.invoice_id = i.id
    where i.student_id in (select id from base) and i.status <> 'void'
    group by i.student_id
  ),
  fines as (
    select i.student_id, sum(coalesce(i.fine, 0)) as amt
    from public.invoices i
    where i.student_id in (select id from base) and i.status <> 'void'
    group by i.student_id
  ),
  adjust as (
    select a.student_id, sum(a.amount) as amt
    from public.adjustments a
    where a.student_id in (select id from base)
    group by a.student_id
  ),
  paid as (
    select i.student_id, sum(al.amount) as amt
    from public.payment_allocations al
    join public.invoices i on i.id = al.invoice_id
    join public.payments p on p.id = al.payment_id
    where i.student_id in (select id from base) and p.status = 'verified'
    group by i.student_id
  ),
  counted as (select count(*) as n from base)
  select
    b.id, b.full_name, b.gr_no, b.admission_no, b.father_name, b.gender,
    b.phone, b.status, b.class_name, b.section_name, b.roll_no, b.family_id,
    coalesce(ch.amt, 0) + coalesce(fi.amt, 0) + coalesce(ad.amt, 0) - coalesce(pa.amt, 0),
    counted.n
  from base b
  cross join counted
  left join charges ch on ch.student_id = b.id
  left join fines   fi on fi.student_id = b.id
  left join adjust  ad on ad.student_id = b.id
  left join paid    pa on pa.student_id = b.id
  order by b.full_name, b.id
  limit v_limit offset v_offset;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Index support.
--
-- The list filters by school and sorts by name on every page, and the previous
-- implementation never had to because it only ever fetched fifty rows. At 2,000
-- students across 40 pages that ordering is the whole cost.
-- ---------------------------------------------------------------------------
create index if not exists ix_students_school_name
  on public.students (school_id, full_name)
  where deleted_at is null;

-- ---------------------------------------------------------------------------
-- 3. Grants.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_student_list(text, uuid, uuid, boolean, integer, integer)
  to authenticated;
revoke all on function public.fn_student_list(text, uuid, uuid, boolean, integer, integer)
  from anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0042_dashboard_truth.sql
-- ─────────────────────────────────────────────────────────────────────────
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
do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_import_staff';

  v_def := replace(v_def,
    'from public.staff where employee_no = v_emp and deleted_at is null',
    'from public.staff where employee_no = v_emp and deleted_at is null'
      || ' and school_id = public.current_school_id()');
  v_def := replace(v_def,
    'from public.staff where cnic = v_cnic and deleted_at is null',
    'from public.staff where cnic = v_cnic and deleted_at is null'
      || ' and school_id = public.current_school_id()');

  execute v_def;
end $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 0043_message_settings.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0043 — Let a school edit and switch off what its parents receive.
--
-- WHY
--
-- message_templates has existed since 0034 with a `body` and an `enabled` flag,
-- seeded per school, and NOTHING in the app has ever read or written it. So the
-- wording a school sends to three hundred parents was fixed by a migration, and
-- a school that wanted to stop one of the five message types had no way to.
--
-- The RLS policy on the table already permits owner/principal to write, so the
-- app can edit these directly — no RPC is needed for that half. What is missing
-- is a way BACK: a school that deletes half a template and sends it out needs to
-- restore the original, and the originals live here in SQL.
--
-- This mirrors OurSchoolSoftware's "Automation Settings", where every event has
-- an editable body, a visible list of supported merge tags, and an Enabled
-- toggle so a school can silence any single one. Theirs is SMS; ours is
-- WhatsApp click-to-chat, so the same workflow costs nothing to run.
--
-- WHAT THIS AVOIDS
--
-- The default bodies were written out once inside fn__seed_message_templates.
-- Adding a reset would have meant a second copy of the same five paragraphs,
-- which would drift. They are extracted here into one function that both the
-- seed and the reset call, so there is exactly one place the wording lives.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The defaults, in one place, with the merge tags each one may use.
--
-- The tag list is a FACT ABOUT THE CALL SITE, not decoration: {receipt} only
-- resolves for payment_received because fn__queue_payment_receipt is the only
-- caller that passes it. Showing a school a tag that will never resolve means
-- they put it in a message and a parent receives the literal "{receipt}".
--
-- Universal tags, filled in by fn_queue_message for every template:
--   {parent} {children} {school} {date} {balance}
-- ---------------------------------------------------------------------------
create or replace function public.fn__default_message_templates()
returns table (template_key text, label text, body text, tags text[])
language sql immutable set search_path = public as $$
  values
    ('payment_received', 'Payment received',
     'Assalam-o-Alaikum {parent}. We have received Rs {amount} for {children} on {date}. '
     || 'Receipt #{receipt}. Remaining balance: Rs {balance}. Received by {received_by}. '
     || 'Thank you — {school}.',
     array['parent','children','school','date','balance','amount','receipt','received_by']),

    ('fee_reminder', 'Fee reminder',
     'Assalam-o-Alaikum {parent}. A balance of Rs {balance} is outstanding for {children}. '
     || 'Kindly clear it at the school office at your convenience. Thank you — {school}.',
     array['parent','children','school','date','balance','amount']),

    ('fee_reminder_final', 'Fee reminder (final)',
     'Assalam-o-Alaikum {parent}. Rs {balance} remains outstanding for {children} despite '
     || 'earlier reminders. Please visit the school office this week so we can sort it out '
     || 'together. Thank you — {school}.',
     array['parent','children','school','date','balance','amount']),

    ('absent_today', 'Absent today',
     'Assalam-o-Alaikum {parent}. {children} was marked absent today, {date}. '
     || 'If this is a mistake please contact the office. — {school}.',
     array['parent','children','school','date','balance']),

    ('result_published', 'Result published',
     'Assalam-o-Alaikum {parent}. The result for {children} has been published and can be '
     || 'viewed in the parent portal. — {school}.',
     array['parent','children','school','date','balance'])
$$;

-- ---------------------------------------------------------------------------
-- 2. Seeding, now reading from the single source above.
--
-- Same behaviour as before — on conflict do nothing, so an existing school's
-- edited wording is never overwritten by a re-run.
-- ---------------------------------------------------------------------------
create or replace function public.fn__seed_message_templates(p_school uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.message_templates (school_id, template_key, label, body)
  select p_school, d.template_key, d.label, d.body
  from public.fn__default_message_templates() d
  on conflict (school_id, template_key) do nothing;
end;
$$;

-- Any school created before this migration is missing nothing, but a school
-- created between 0034 and here could be missing a template if the list ever
-- grew. Cheap to make certain.
do $$
declare s record;
begin
  for s in select id from public.schools loop
    perform public.fn__seed_message_templates(s.id);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 3. What the settings screen reads.
--
-- Returns the school's current wording alongside the tags each template may
-- use, so the editor can show them without the client holding its own copy of
-- facts that live at the call sites.
--
-- is_staff() rather than owner/principal: a clerk should be able to SEE what
-- goes out over their name. The table's own policy still stops them editing.
-- ---------------------------------------------------------------------------
create or replace function public.fn_message_settings()
returns table (
  template_key text,
  label        text,
  body         text,
  enabled      boolean,
  tags         text[],
  is_default   boolean
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select t.template_key, t.label, t.body, t.enabled,
         coalesce(d.tags, array['parent','children','school','date','balance']),
         -- So the editor can offer "Restore default" only where it would do
         -- something, rather than on every row.
         t.body = d.body
  from public.message_templates t
  left join public.fn__default_message_templates() d on d.template_key = t.template_key
  where t.school_id = public.current_school_id()
  order by t.label;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Restore one template's original wording.
--
-- owner/principal only, matching the table's write policy — this changes what
-- every parent receives.
-- ---------------------------------------------------------------------------
create or replace function public.fn_reset_message_template(p_template_key text)
returns text language plpgsql security definer set search_path = public as $$
declare v_body text;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal can change message wording';
  end if;

  select d.body into v_body
  from public.fn__default_message_templates() d
  where d.template_key = p_template_key;

  if v_body is null then
    raise exception 'No such message template: %', p_template_key;
  end if;

  update public.message_templates
     set body = v_body
   where school_id = public.current_school_id()
     and template_key = p_template_key;

  return v_body;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Grants.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_message_settings()             to authenticated;
grant execute on function public.fn_reset_message_template(text)   to authenticated;
grant execute on function public.fn__default_message_templates()   to authenticated;

revoke all on function public.fn_message_settings()           from anon;
revoke all on function public.fn_reset_message_template(text) from anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0044_reports.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0044 — The reporting area a head teacher actually reads.
--
-- OurSchoolSoftware's Reporting Area lists thirteen reports. We had five:
-- class-wise basics, defaulters, income & expense, day book, reconciliation.
-- Missing were the eight that answer questions an owner asks at month end —
-- debit & credit statement, list of unpaid invoices, fee discount report,
-- accounts summary, detailed income, detailed expense, balance sheet, admission
-- date report — plus head-wise dues, which existed in SQL with no screen.
--
-- WHY FOUR FUNCTIONS AND NOT EIGHT
--
-- Six of those eight are the same data asked different ways. A detailed income
-- report is the ledger filtered to income; a detailed expense report is the
-- ledger filtered to expenses; a debit & credit statement is both, in date
-- order, with a running balance; an accounts summary is that grouped. Writing
-- them as separate functions would mean six places to fix when the definition
-- of "income" changes — and it will, because fee income must always derive from
-- receipts and never be hand-entered.
--
-- So: one ledger function with a filter, plus three genuinely different reports.
--
-- WHAT EVERY ONE OF THESE HAS IN COMMON
--
-- All are SECURITY DEFINER, so RLS does not apply and each carries its own
-- school_id filter — the lesson from 0042, where three unscoped queries in the
-- dashboard were reporting the platform's totals to every tenant. The
-- structural guard in supabase/tests/dashboard.sql enforces it.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The ledger: every rupee in and out, in date order, with a running balance.
--
-- Serves three of their reports at once (Debit & Credit Statement, Detailed
-- Income, Detailed Expense) via p_kind.
--
-- Income is fee receipts plus recorded other-income. Fee receipts are read from
-- payments and CANNOT be typed in anywhere, which is the property that makes
-- this statement worth trusting: a school cannot inflate its collections
-- without a receipt existing.
--
-- Reversals appear as their own negative rows rather than being netted away.
-- A statement that silently hides a reversed receipt is exactly what a
-- dishonest clerk would want.
-- ---------------------------------------------------------------------------
create or replace function public.fn_report_ledger(
  p_from date,
  p_to   date,
  p_kind text default 'all'          -- 'all' | 'income' | 'expense'
) returns table (
  entry_date   date,
  kind         text,                 -- 'income' | 'expense'
  category     text,                 -- fee head group, or expense category
  particulars  text,
  reference    text,                 -- receipt or voucher number
  party        text,                 -- who paid, or who was paid
  method       text,
  debit        numeric,              -- money in
  credit       numeric,              -- money out
  recorded_by  text,
  is_reversal  boolean
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  -- Matches fn_finance_summary's boundary (owner / principal / accountant)
  -- rather than inventing a third one. Note a PRE-EXISTING inconsistency this
  -- deliberately does not paper over: fn_dashboard_summary shows the money
  -- tiles to `readonly` too, while fn_finance_summary refuses it. A full
  -- debit-and-credit statement naming every payer and payee is more sensitive
  -- than a tile, so it follows the stricter of the two. Whether `readonly`
  -- should see money at all is a decision for the school to make, not one to
  -- settle silently here.
  if not public.has_role('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to read the accounts' using errcode = '42501';
  end if;
  if p_from is null or p_to is null then
    raise exception 'A date range is required';
  end if;
  if p_to < p_from then
    raise exception 'The end date is before the start date';
  end if;

  return query
  with rows_in as (
    -- Fee receipts. Verified only: a pending bank transfer is not income yet.
    select p.created_at::date               as entry_date,
           'income'::text                   as kind,
           'Fee collection'::text           as category,
           coalesce(
             (select string_agg(distinct
                       coalesce(to_char(i.period_month, 'Mon YYYY'), 'Other'), ', ')
                from public.payment_allocations al
                join public.invoices i on i.id = al.invoice_id
               where al.payment_id = p.id),
             'On account')                  as particulars,
           coalesce('#' || p.receipt_no::text, '—') as reference,
           coalesce(f.head_name, s.full_name, '—')  as party,
           p.method::text                   as method,
           -- A reversal is stored as a payment with a NEGATIVE amount. Putting
           -- it straight into `debit` gave a "money in" column containing
           -- -300, and made the two sides net out so a reversed receipt looked
           -- like it had never happened. A contra entry belongs on the opposite
           -- side as a positive figure, which is how a ledger is read and how
           -- the totals stay meaningful.
           case when p.amount >= 0 then p.amount else 0 end   as debit,
           case when p.amount <  0 then -p.amount else 0 end  as credit,
           coalesce(pr.full_name, '—')      as recorded_by,
           p.reversal_of is not null        as is_reversal
    from public.payments p
    left join public.families f on f.id = p.family_id
    left join public.students s on s.id = p.student_id
    left join public.profiles pr on pr.id = p.received_by
    where p.school_id = v_school
      and p.status = 'verified'
      and p.created_at::date between p_from and p_to

    union all

    -- Non-fee income: hall rent, a van hire, a book sale.
    select oi.received_on, 'income', 'Other income',
           oi.source, '—', '—', oi.method::text,
           oi.amount, 0::numeric,
           coalesce(pr.full_name, '—'),
           false
    from public.other_income oi
    left join public.profiles pr on pr.id = oi.recorded_by
    where oi.school_id = v_school
      and oi.received_on between p_from and p_to

    union all

    select e.spent_on, 'expense', coalesce(ec.name, 'Uncategorised'),
           coalesce(e.note, coalesce(ec.name, 'Expense')),
           coalesce('V' || e.voucher_no::text, '—'),
           coalesce(e.payee, '—'), e.method::text,
           0::numeric, e.amount,
           coalesce(pr.full_name, '—'),
           e.reversal_of is not null
    from public.expenses e
    left join public.expense_categories ec on ec.id = e.category_id
    left join public.profiles pr on pr.id = e.recorded_by
    where e.school_id = v_school
      and e.spent_on between p_from and p_to
  )
  select r.entry_date, r.kind, r.category, r.particulars, r.reference,
         r.party, r.method, r.debit, r.credit, r.recorded_by, r.is_reversal
  from rows_in r
  where p_kind = 'all' or r.kind = p_kind
  order by r.entry_date, r.kind desc, r.reference;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. List of unpaid invoices.
--
-- Per CHALLAN, not per student — which is the point, and why the defaulter
-- report does not answer it. "Ahmed owes Rs 3,600" does not tell a clerk which
-- three months are outstanding or which slip to reprint; this does.
--
-- Age in days is included because a challan two weeks past due and one eight
-- months past due need different conversations.
-- ---------------------------------------------------------------------------
create or replace function public.fn_report_unpaid_invoices(p_session_id uuid)
returns table (
  invoice_id   uuid,
  voucher_code text,
  period_label text,
  due_date     date,
  days_overdue integer,
  student_id   uuid,
  student_name text,
  gr_no        text,
  class_name   text,
  section_name text,
  father_name  text,
  charge       numeric,
  paid         numeric,
  due          numeric
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  return query
  select i.id, i.voucher_code,
         coalesce(to_char(i.period_month, 'Mon YYYY'), coalesce(i.notes, 'One-off')),
         i.due_date,
         case when i.due_date is null or i.due_date >= current_date then 0
              else (current_date - i.due_date) end::int,
         s.id, s.full_name, s.gr_no, c.name, sec.name, s.father_name,
         ch.charge, coalesce(pd.paid, 0), ch.charge - coalesce(pd.paid, 0)
  from public.invoices i
  join public.students s on s.id = i.student_id
  left join public.enrollments e on e.id = i.enrollment_id
  left join public.classes c   on c.id = e.class_id
  left join public.sections sec on sec.id = e.section_id
  cross join lateral (
    select coalesce((select sum(case when l.is_discount then -l.amount else l.amount end)
                       from public.invoice_lines l where l.invoice_id = i.id), 0)
           + coalesce(i.fine, 0) as charge
  ) ch
  left join lateral (
    select sum(al.amount) as paid
      from public.payment_allocations al
      join public.payments p on p.id = al.payment_id
     where al.invoice_id = i.id and p.status = 'verified'
  ) pd on true
  where i.school_id = v_school
    and i.session_id = p_session_id
    and i.status <> 'void'
    and s.deleted_at is null
    and ch.charge - coalesce(pd.paid, 0) > 0
  order by i.due_date nulls last, s.full_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Fee discount report.
--
-- The most audit-relevant report in the set, and the reason it is worth having
-- separately: a discount is money the school chose not to collect. Who granted
-- it, who approved it, and why are the columns that matter — a discount register
-- without an approver is just a list of holes in the income.
-- ---------------------------------------------------------------------------
create or replace function public.fn_report_discounts(p_from date, p_to date)
returns table (
  granted_on   date,
  student_id   uuid,
  student_name text,
  gr_no        text,
  class_name   text,
  reason_type  text,      -- sibling / merit / staff_child / hardship / ...
  is_percent   boolean,
  amount       numeric,
  reason       text,
  status       text,
  proposed_by  text,
  approved_by  text,
  approved_at  timestamptz
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to read discounts' using errcode = '42501';
  end if;

  -- discounts key on ENROLMENT, not student, so the join goes through
  -- enrollments. That also means a discount is scoped to one session, which is
  -- correct — last year's hardship waiver should not silently continue.
  return query
  select d.created_at::date, s.id, s.full_name, s.gr_no, c.name,
         d.type::text, d.is_percent, d.amount, d.reason, d.status::text,
         coalesce(pb.full_name, '—'), coalesce(ab.full_name, '—'), d.approved_at
  from public.discounts d
  join public.enrollments e on e.id = d.enrollment_id
  join public.students s    on s.id = e.student_id
  left join public.classes c on c.id = e.class_id
  left join public.profiles pb on pb.id = d.created_by
  left join public.profiles ab on ab.id = d.approved_by
  where d.school_id = v_school
    and s.deleted_at is null
    and (p_from is null or d.created_at::date >= p_from)
    and (p_to   is null or d.created_at::date <= p_to)
  order by d.created_at desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Admission date report.
--
-- Who joined, when, and whether they are still here. The last column is what
-- makes it useful beyond a headcount: a month with twelve admissions and nine
-- of them already struck off is a different fact from a month with twelve that
-- stayed.
-- ---------------------------------------------------------------------------
create or replace function public.fn_report_admissions(p_from date, p_to date)
returns table (
  admitted_on  date,
  student_id   uuid,
  student_name text,
  gr_no        text,
  admission_no text,
  father_name  text,
  gender       text,
  class_name   text,
  section_name text,
  status       text,
  admitted_by  text
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select coalesce(s.admission_date, s.created_at::date),
         s.id, s.full_name, s.gr_no, s.admission_no, s.father_name,
         s.gender::text, c.name, sec.name, s.status::text,
         '—'::text          -- students carries no created_by; see note below
  from public.students s
  left join public.enrollments e on e.student_id = s.id and e.status = 'active'
  left join public.classes c   on c.id = e.class_id
  left join public.sections sec on sec.id = e.section_id
  where s.school_id = v_school
    and s.deleted_at is null
    and coalesce(s.admission_date, s.created_at::date)
        between coalesce(p_from, '1900-01-01'::date) and coalesce(p_to, '2999-12-31'::date)
  order by coalesce(s.admission_date, s.created_at::date) desc, s.full_name;
end;
$$;

-- A limitation stated rather than faked: public.students has no created_by
-- column, so "admitted by" cannot be filled without a schema change plus a
-- backfill that would be guesswork for existing rows. The column is returned as
-- '—' so the report's shape is stable if that is added later. The audit_log does
-- record the actor for every student insert, which is where the answer lives
-- today.

-- ---------------------------------------------------------------------------
-- 5. Grants.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_report_ledger(date, date, text)   to authenticated;
grant execute on function public.fn_report_unpaid_invoices(uuid)      to authenticated;
grant execute on function public.fn_report_discounts(date, date)      to authenticated;
grant execute on function public.fn_report_admissions(date, date)     to authenticated;

revoke all on function public.fn_report_ledger(date, date, text)  from anon;
revoke all on function public.fn_report_unpaid_invoices(uuid)     from anon;
revoke all on function public.fn_report_discounts(date, date)     from anon;
revoke all on function public.fn_report_admissions(date, date)    from anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0045_balance_sheet.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0045 — The balance sheet, as at a date.
--
-- The last of their eight missing money reports, and the only one that could
-- not be served by filtering the ledger — because it is not a RANGE, it is a
-- position AS AT one day. "What did the school stand at on 30 June?" is a
-- different question from "what happened in June?", and answering it with a
-- range is how a year-end figure ends up wrong.
--
-- WHY THIS IS HARDER THAN IT LOOKS
--
-- student_balance() gives the CURRENT balance. It cannot answer "what was owed
-- on 30 June?", because it counts every charge and every payment regardless of
-- date. So this reconstructs the position from the dated rows:
--
--   receivable  = charges on invoices ISSUED on or before the date
--                 + fines on those
--                 + adjustments made on or before the date
--                 − allocations from payments TAKEN on or before the date
--
--   advance     = verified payments taken on or before the date
--                 − everything those payments have been allocated to,
--                 counting only allocations against invoices issued by then
--
--   cash moved  = verified receipts + other income − expenses, all up to the
--                 date, from the beginning
--
-- The awkward term is `advance`. A payment can be allocated to an invoice
-- issued AFTER the as-at date — a parent paying August's fee in July. On 31
-- July that money is an advance the school is holding, not income against a
-- charge that does not exist yet, so the allocation is excluded by the
-- invoice's issue date rather than the payment's. Getting that wrong makes a
-- school with advance fees look like it has no liability.
--
-- WHAT THIS IS NOT
--
-- Not double-entry bookkeeping. There is no chart of accounts, no bank
-- reconciliation and no fixed assets, because none of that exists in this
-- schema and inventing it would be worse than omitting it. It is the four
-- figures a Pakistani school principal actually asks for: what we are owed,
-- what we are holding for parents, what has come in, what has gone out.
-- =============================================================================

create or replace function public.fn_report_balance_sheet(p_as_at date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school     uuid := public.current_school_id();
  v_as_at      date := coalesce(p_as_at, current_date);
  v_charges    numeric;
  v_fines      numeric;
  v_adjust     numeric;
  v_allocated  numeric;
  v_receivable numeric;
  v_from_off   numeric;
  v_receipts   numeric;
  v_other_in   numeric;
  v_expenses   numeric;
  v_advance    numeric;
  v_students   int;
  v_owing      int;
begin
  if not public.has_role('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to read the accounts' using errcode = '42501';
  end if;

  -- ---- the position, reconstructed one student at a time ----
  --
  -- Done PER STUDENT rather than as four school-wide sums, for one reason: the
  -- headcount of who owes money and the total owed must come out of the same
  -- arithmetic. The first cut of this function summed the money as-at but took
  -- the headcount from student_balance(), which is a CURRENT figure — so a
  -- balance sheet as at a date before the school billed anything reported
  -- "receivable 0, students owing 1". A statement that contradicts itself in
  -- two adjacent numbers is worse than no statement.
  --
  -- Grouping allocations by the INVOICE's student, not the payment's, is also
  -- what makes family payments land on the right child: a payment row for a
  -- family has no student_id at all.
  with inv as (
    -- issued_at, not created_at: a challan prepared on the 28th and issued on
    -- the 1st is not a receivable on the 30th.
    select i.id, i.student_id, i.status, coalesce(i.fine, 0) as fine
    from public.invoices i
    where i.school_id = v_school
      and coalesce(i.issued_at::date, i.created_at::date) <= v_as_at
  ),
  charge as (
    select v.student_id,
           sum(case when l.is_discount then -l.amount else l.amount end) as amt
    from inv v
    join public.invoice_lines l on l.invoice_id = v.id
    where v.status <> 'void'
    group by 1
  ),
  fine as (
    select v.student_id, sum(v.fine) as amt
    from inv v where v.status <> 'void' group by 1
  ),
  adj as (
    select a.student_id, sum(a.amount) as amt
    from public.adjustments a
    where a.school_id = v_school and a.created_at::date <= v_as_at
    group by 1
  ),
  alloc as (
    -- `inv` is already filtered to invoices ISSUED by the as-at date, and that
    -- is the subtle part of the whole report: an allocation against an invoice
    -- issued AFTER the date is a parent paying next month early. On this date
    -- that money is an advance the school is holding, not a settled charge.
    --
    -- Note there is deliberately no `status <> 'void'` here, even though the
    -- charge sums have it. student_balance() omits it too, and the two must
    -- agree — a clerk checking this against a student ledger has to see the
    -- same money. Nothing in this schema ever sets an invoice to 'void' today
    -- (there is no void function), so the case is unreachable; aligning now is
    -- what stops the two screens diverging if one is ever added.
    select v.student_id, sum(al.amount) as amt
    from public.payment_allocations al
    join inv v on v.id = al.invoice_id
    join public.payments p on p.id = al.payment_id
    where p.school_id = v_school
      and p.status = 'verified'
      and p.created_at::date <= v_as_at
    group by 1
  ),
  per_student as (
    -- Every student the school has ever had, not just those on the roll: a
    -- withdrawn child's unpaid arrears are still money owed to the school, and
    -- dropping them would quietly shrink the receivable.
    select s.id,
           coalesce(c.amt, 0)  as charges,
           coalesce(f.amt, 0)  as fines,
           coalesce(j.amt, 0)  as adjust,
           coalesce(al.amt, 0) as allocated,
           coalesce(c.amt, 0) + coalesce(f.amt, 0) + coalesce(j.amt, 0)
             - coalesce(al.amt, 0) as bal,
           -- On the roll AS AT the date. admission_date is a real date, so
           -- "had they joined yet" is answerable; `status` however has no
           -- history, so a child who has since left is counted as off-roll
           -- even for a date when they were present. Stated in `basis`.
           (coalesce(s.admission_date, s.created_at::date) <= v_as_at
            and (s.deleted_at is null or s.deleted_at::date > v_as_at)
            and s.status = 'active') as on_roll
    from public.students s
    left join charge c  on c.student_id  = s.id
    left join fine   f  on f.student_id  = s.id
    left join adj    j  on j.student_id  = s.id
    left join alloc  al on al.student_id = s.id
    where s.school_id = v_school
  )
  select coalesce(sum(charges), 0),
         coalesce(sum(fines), 0),
         coalesce(sum(adjust), 0),
         coalesce(sum(allocated), 0),
         coalesce(sum(bal), 0),
         coalesce(sum(bal) filter (where bal > 0 and not on_roll), 0),
         count(*) filter (where on_roll),
         count(*) filter (where bal > 0 and on_roll)
    into v_charges, v_fines, v_adjust, v_allocated,
         v_receivable, v_from_off, v_students, v_owing
  from per_student;

  -- ---- cash movement from the beginning up to the date ----
  select coalesce(sum(p.amount), 0) into v_receipts
  from public.payments p
  where p.school_id = v_school
    and p.status = 'verified'
    and p.created_at::date <= v_as_at;

  select coalesce(sum(oi.amount), 0) into v_other_in
  from public.other_income oi
  where oi.school_id = v_school and oi.received_on <= v_as_at;

  select coalesce(sum(e.amount), 0) into v_expenses
  from public.expenses e
  where e.school_id = v_school and e.spent_on <= v_as_at;

  -- ---- money held that is not against a charge yet ----
  v_advance := v_receipts - v_allocated;
  -- Cannot be negative: if allocations somehow exceed receipts the honest thing
  -- is to show zero advance and let the receivable carry the difference, rather
  -- than print a negative liability nobody can interpret.
  if v_advance < 0 then v_advance := 0; end if;

  return jsonb_build_object(
    'as_at',              v_as_at,
    -- Assets side
    'receivable',         v_receivable,
    'cash_in',            v_receipts + v_other_in,
    'cash_out',           v_expenses,
    'cash_position',      v_receipts + v_other_in - v_expenses,
    -- Liability side
    'advance_held',       v_advance,
    -- Context, so the figures can be sanity-checked at a glance
    'fee_receipts',       v_receipts,
    'other_income',       v_other_in,
    'charges_raised',     v_charges + v_fines + v_adjust,
    'allocated',          v_allocated,
    -- Named separately rather than hidden inside `receivable`, because the
    -- headcount below excludes these children and a principal comparing the
    -- two would otherwise be looking at an unexplained gap. Schools here do
    -- chase leavers' arrears, so it is a figure they want, not a footnote.
    'receivable_off_roll', v_from_off,
    'students_on_roll',   v_students,
    'students_owing',     v_owing,
    -- Stated in the payload rather than only in a comment, because a reader of
    -- the raw JSON deserves to know what it does not include.
    'basis',             'Cumulative from the first record up to the as-at date. '
                      || 'Receivable counts charges on invoices ISSUED by that date, less '
                      || 'payments taken by that date against those invoices, for every '
                      || 'student the school has ever had. Money paid early for a later '
                      || 'month is shown as advance held, not as income. Roll counts use '
                      || 'the student''s CURRENT status, which is not kept historically, '
                      || 'so a child who has since left is counted off-roll even for a '
                      || 'date when they were present; their arrears still appear in '
                      || 'receivable. Not double-entry: no chart of accounts, no bank '
                      || 'reconciliation, no fixed assets.');
end;
$$;

grant execute on function public.fn_report_balance_sheet(date) to authenticated;
revoke all on function public.fn_report_balance_sheet(date) from anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0046_enquiries.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0046 — Admission enquiries. Their "Admission Inquiries", which is how a
--        Pakistani private school actually wins the admission season.
--
-- WHAT THIS IS FOR
--
-- A parent walks in during February and asks whether there is space in Class 3.
-- They are not admitting a child today. If nobody writes that down, and nobody
-- rings them back in a week, they go to the school down the road. Every school
-- of this size loses admissions this way and does not know it, because the loss
-- leaves no record anywhere.
--
-- So this is not a CRM. It is four things:
--
--   1. Write the enquiry down in fifteen seconds, with only a name and a phone
--      number required — a clerk taking a call cannot stop to fill a form.
--   2. Say who to ring TODAY. A lead list nobody calls is a list nobody reads,
--      the same way a defaulter list full of families who have already paid is
--      a list nobody reads.
--   3. Keep the follow-up history append-only, so "we called twice and they
--      said the fee was too high" survives the clerk who leaves.
--   4. Convert to a real admission in one action, WITHOUT retyping anything,
--      and keep the enquiry afterwards — the conversion record is the only
--      marketing data a school of this size will ever have.
--
-- TWO THINGS THIS DELIBERATELY DOES NOT DO
--
-- It does not delete. A lost enquiry becomes status 'lost' with a reason,
-- because "why did we not get these thirty children" is the whole value of the
-- table and a DELETE throws it away.
--
-- It does not reimplement admission. fn_enquiry_admit delegates to
-- fn_admit_student, so the GR number, the family linkage from 0036, the
-- admission fee and the subscription student limit all behave identically
-- whether a child arrives through an enquiry or straight off the street. A
-- second admission path that drifts from the first is a bug factory.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Vocabulary
--
-- `source` exists so a school can answer "where do our admissions come from" at
-- the end of a season. A banner on the main road costs real money; knowing that
-- it produced four enquiries and one admission is worth having.
-- ---------------------------------------------------------------------------
do $$ begin
  if not exists (select 1 from pg_type where typname = 'enquiry_status') then
    create type public.enquiry_status as enum
      ('new', 'contacted', 'visited', 'admitted', 'lost');
  end if;
  if not exists (select 1 from pg_type where typname = 'enquiry_source') then
    create type public.enquiry_source as enum
      ('walk_in', 'phone', 'referral', 'banner', 'social_media', 'other');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. The enquiry
--
-- Only child_name and phone are required. Everything else is optional on
-- purpose: a clerk on the phone gets a name and a number, and being forced to
-- invent a date of birth is how a record ends up not being made at all.
--
-- class_id is nullable and NOT a foreign-key requirement of the workflow — a
-- parent asking "what classes do you have" has not chosen one yet.
-- ---------------------------------------------------------------------------
create table if not exists public.admission_enquiries (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  -- Per-school and gapless, like the GR number, so a school can say "enquiry
  -- 47" on the phone and both sides find the same row.
  enquiry_no    bigint not null,
  child_name    text not null,
  father_name   text,
  father_cnic   text,
  phone         text not null,
  whatsapp      text,
  address       text,
  dob           date,
  gender        text,
  -- What they asked about. Kept as ids where known so conversion can prefill,
  -- and as free text where not.
  session_id    uuid references public.academic_sessions(id),
  class_id      uuid references public.classes(id),
  class_wanted  text,
  source        public.enquiry_source not null default 'walk_in',
  source_note   text,
  status        public.enquiry_status not null default 'new',
  -- The single most important column in the table: who do I ring today.
  follow_up_on  date,
  notes         text,
  -- Set only when status = 'lost'. Not free-form-optional: the whole point of
  -- recording a loss is knowing why.
  lost_reason   text,
  -- Set by fn_enquiry_admit. The enquiry is never deleted on conversion.
  admitted_student_id uuid references public.students(id),
  admitted_at   timestamptz,
  created_by    uuid references public.profiles(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint uq_enquiry_no unique (school_id, enquiry_no),
  -- A lost enquiry must say why, and an open one must not claim a student.
  constraint ck_enquiry_lost_reason
    check (status <> 'lost' or nullif(btrim(coalesce(lost_reason, '')), '') is not null),
  constraint ck_enquiry_admitted
    check ((status = 'admitted') = (admitted_student_id is not null))
);

create index if not exists idx_enquiries_school_followup
  on public.admission_enquiries (school_id, follow_up_on)
  where status in ('new', 'contacted', 'visited');
create index if not exists idx_enquiries_school_status
  on public.admission_enquiries (school_id, status, created_at desc);
create index if not exists idx_enquiries_school_phone
  on public.admission_enquiries (school_id, phone);

-- ---------------------------------------------------------------------------
-- 3. The follow-up log — append only
--
-- Overwriting a `notes` column loses the history, and the history is the
-- product: "rang 3 Feb, no answer; rang 6 Feb, wants to see the science lab;
-- visited 9 Feb" is what lets whoever is on duty pick up the thread. Same
-- reasoning as payments: never edit, always append.
-- ---------------------------------------------------------------------------
create table if not exists public.enquiry_contacts (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references public.schools(id) on delete cascade,
  enquiry_id  uuid not null references public.admission_enquiries(id) on delete cascade,
  contacted_at timestamptz not null default now(),
  -- What happened, in the school's words. Free text on purpose: a fixed
  -- outcome list would be guessing at how these conversations go.
  outcome     text not null,
  note        text,
  contacted_by uuid references public.profiles(id),
  created_at  timestamptz not null default now()
);

create index if not exists idx_enquiry_contacts_enquiry
  on public.enquiry_contacts (enquiry_id, contacted_at desc);

-- ---------------------------------------------------------------------------
-- 4. Tenant plumbing — the same shape every other tenant table uses
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['admission_enquiries', 'enquiry_contacts'] loop
    if not exists (select 1 from pg_trigger
                   where tgname = format('trg_%s_school', t)
                     and tgrelid = format('public.%I', t)::regclass) then
      execute format(
        'create trigger trg_%1$s_school before insert or update on public.%1$s
           for each row execute function public.enforce_school_id();', t);
    end if;
    if not exists (select 1 from pg_trigger
                   where tgname = format('trg_audit_%s', t)
                     and tgrelid = format('public.%I', t)::regclass) then
      execute format(
        'create trigger trg_audit_%1$s after insert or update or delete on public.%1$s
           for each row execute function public.audit_trigger();', t);
    end if;
    execute format('alter table public.%I enable row level security;', t);
  end loop;
end $$;

-- Front-office data. A clerk on reception is exactly who takes these calls, so
-- admin_clerk reads and writes; teachers have no business in the enquiry book.
drop policy if exists enquiries_select on public.admission_enquiries;
create policy enquiries_select on public.admission_enquiries for select to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'admin_clerk'));

drop policy if exists enquiry_contacts_select on public.enquiry_contacts;
create policy enquiry_contacts_select on public.enquiry_contacts for select to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'admin_clerk'));

-- No INSERT/UPDATE/DELETE policy on either table. Every write goes through the
-- SECURITY DEFINER functions below so that the enquiry number stays gapless,
-- the status transitions stay legal, and a conversion cannot happen twice. A
-- direct insert would bypass all three.

-- ---------------------------------------------------------------------------
-- 5. Two more message templates
--
-- Their SMS list has "Inquiry Add" and "Inquiry Admit". Same triggers, same
-- merge tags, WhatsApp instead of SMS — the rule recorded in docs/PARITY.md.
--
-- These two are the first templates addressed to somebody who is NOT a family:
-- an enquiry has no family and no student yet, just a name and a phone number.
-- So {children} and {balance} would never resolve and are deliberately absent
-- from their tag lists; {child} and {enquiry_no} take their place.
-- ---------------------------------------------------------------------------
create or replace function public.fn__default_message_templates()
returns table (template_key text, label text, body text, tags text[])
language sql immutable set search_path = public as $$
  values
    ('payment_received', 'Payment received',
     'Assalam-o-Alaikum {parent}. We have received Rs {amount} for {children} on {date}. '
     || 'Receipt #{receipt}. Remaining balance: Rs {balance}. Received by {received_by}. '
     || 'Thank you — {school}.',
     array['parent','children','school','date','balance','amount','receipt','received_by']),

    ('fee_reminder', 'Fee reminder',
     'Assalam-o-Alaikum {parent}. A balance of Rs {balance} is outstanding for {children}. '
     || 'Kindly clear it at the school office at your convenience. Thank you — {school}.',
     array['parent','children','school','date','balance','amount']),

    ('fee_reminder_final', 'Fee reminder (final)',
     'Assalam-o-Alaikum {parent}. Rs {balance} remains outstanding for {children} despite '
     || 'earlier reminders. Please visit the school office this week so we can sort it out '
     || 'together. Thank you — {school}.',
     array['parent','children','school','date','balance','amount']),

    ('absent_today', 'Absent today',
     'Assalam-o-Alaikum {parent}. {children} was marked absent today, {date}. '
     || 'If this is a mistake please contact the office. — {school}.',
     array['parent','children','school','date','balance']),

    ('result_published', 'Result published',
     'Assalam-o-Alaikum {parent}. The result for {children} has been published and can be '
     || 'viewed in the parent portal. — {school}.',
     array['parent','children','school','date','balance']),

    ('enquiry_received', 'Admission enquiry received',
     'Assalam-o-Alaikum {parent}. Thank you for your interest in {school} for {child}. '
     || 'Your enquiry number is {enquiry_no}. We will contact you shortly. '
     || 'For anything urgent please call the school office.',
     array['parent','child','school','date','enquiry_no','class_wanted']),

    ('enquiry_admitted', 'Enquiry admitted',
     'Assalam-o-Alaikum {parent}. We are pleased to confirm the admission of {child} '
     || 'at {school}. GR number {gr_no}. Please visit the office to complete the '
     || 'remaining formalities. — {school}.',
     array['parent','child','school','date','enquiry_no','gr_no','class_wanted'])
$$;

-- ---------------------------------------------------------------------------
-- 5b. message_outbox needs to point at an enquiry
--
-- The table already links a queued message to a family, a student or a payment.
-- An enquiry message could link to none of them, so a clerk looking at the
-- WhatsApp queue would see "Thank you for your interest in..." with no way to
-- open the enquiry it came from, and nothing could report which enquiries had
-- actually been acknowledged.
-- ---------------------------------------------------------------------------
alter table public.message_outbox
  add column if not exists enquiry_id uuid references public.admission_enquiries(id)
    on delete set null;

create index if not exists idx_outbox_enquiry
  on public.message_outbox (enquiry_id) where enquiry_id is not null;

-- ---------------------------------------------------------------------------
-- 6. Queue a message to an enquiry rather than a family
--
-- Mirrors fn_queue_message, including the `enabled` check that makes the
-- Automation Settings toggle mean something, but resolves the recipient from
-- the enquiry. It cannot reuse fn_queue_message because that function looks up
-- a family and returns null when it does not find one — which is every enquiry.
-- ---------------------------------------------------------------------------
create or replace function public.fn_queue_enquiry_message(
  p_template_key text, p_enquiry_id uuid, p_vars jsonb default '{}'::jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_t      record;
  v_e      record;
  v_id     uuid;
  v_vars   jsonb;
  v_school uuid := public.current_school_id();
begin
  select * into v_t from public.message_templates
  where school_id = v_school and template_key = p_template_key;
  -- Not an error. A school that has switched this message off gets no message,
  -- and the action that triggered it still succeeds.
  if not found or not v_t.enabled then return null; end if;

  select * into v_e from public.admission_enquiries
  where id = p_enquiry_id and school_id = v_school;
  if not found then return null; end if;

  -- No phone, no message — and emphatically not an error. Losing an enquiry
  -- because a parent did not leave a number would be absurd.
  if nullif(btrim(coalesce(v_e.phone, '')), '') is null
     and nullif(btrim(coalesce(v_e.whatsapp, '')), '') is null then
    return null;
  end if;

  v_vars := jsonb_build_object(
    'parent',       coalesce(nullif(btrim(coalesce(v_e.father_name, '')), ''), 'Parent'),
    'child',        v_e.child_name,
    'school',       coalesce((select name from public.school_settings
                              where school_id = v_school), 'the school'),
    'date',         to_char(current_date, 'DD Mon YYYY'),
    'enquiry_no',   v_e.enquiry_no::text,
    'class_wanted', coalesce(
                      (select c.name from public.classes c
                        where c.id = v_e.class_id and c.school_id = v_school),
                      nullif(btrim(coalesce(v_e.class_wanted, '')), ''),
                      'the class you asked about')
  ) || coalesce(p_vars, '{}'::jsonb);

  insert into public.message_outbox (
    template_key, to_name, to_phone, enquiry_id, rendered_text)
  values (
    p_template_key,
    coalesce(nullif(btrim(coalesce(v_e.father_name, '')), ''), v_e.child_name),
    -- WhatsApp number wins over the landline, the same precedence
    -- fn_queue_message uses for a family.
    coalesce(nullif(btrim(coalesce(v_e.whatsapp, '')), ''), v_e.phone),
    p_enquiry_id,
    public.fn__render_template(v_t.body, v_vars))
  returning id into v_id;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Record an enquiry
--
-- Returns the new row plus a `possible_duplicate` hint. It WARNS rather than
-- blocks: the same phone number enquiring twice is usually a second child, and
-- refusing the second one would be wrong. But a clerk who has just taken the
-- same call twice should be told.
-- ---------------------------------------------------------------------------
create or replace function public.fn_add_enquiry(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_actor  uuid := auth.uid();
  v_no     bigint;
  v_id     uuid;
  v_phone  text := nullif(btrim(coalesce(p->>'phone', '')), '');
  v_child  text := nullif(btrim(coalesce(p->>'child_name', '')), '');
  v_dup    jsonb := 'null'::jsonb;
  v_msg    uuid;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted to record an enquiry' using errcode = '42501';
  end if;
  if v_child is null then
    raise exception 'The child''s name is required';
  end if;
  if v_phone is null then
    raise exception 'A phone number is required — an enquiry nobody can ring is not an enquiry';
  end if;

  -- The warning, computed before the insert so the new row cannot match itself.
  select jsonb_build_object('id', e.id, 'enquiry_no', e.enquiry_no,
                            'child_name', e.child_name, 'status', e.status,
                            'created_at', e.created_at)
    into v_dup
  from public.admission_enquiries e
  where e.school_id = v_school
    and e.phone = v_phone
    and lower(btrim(e.child_name)) = lower(v_child)
  order by e.created_at desc
  limit 1;

  v_no := public.next_counter('enquiry');

  insert into public.admission_enquiries (
    school_id, enquiry_no, child_name, father_name, father_cnic, phone, whatsapp,
    address, dob, gender, session_id, class_id, class_wanted, source, source_note,
    follow_up_on, notes, created_by)
  values (
    v_school, v_no, v_child,
    nullif(btrim(coalesce(p->>'father_name', '')), ''),
    nullif(btrim(coalesce(p->>'father_cnic', '')), ''),
    v_phone,
    nullif(btrim(coalesce(p->>'whatsapp', '')), ''),
    nullif(btrim(coalesce(p->>'address', '')), ''),
    nullif(p->>'dob', '')::date,
    nullif(btrim(coalesce(p->>'gender', '')), ''),
    nullif(p->>'session_id', '')::uuid,
    nullif(p->>'class_id', '')::uuid,
    nullif(btrim(coalesce(p->>'class_wanted', '')), ''),
    coalesce(nullif(p->>'source', '')::public.enquiry_source, 'walk_in'),
    nullif(btrim(coalesce(p->>'source_note', '')), ''),
    -- Default the follow-up to three days out rather than leaving it null. An
    -- enquiry with no follow-up date never appears on anybody's list, which is
    -- the exact failure this table exists to prevent.
    coalesce(nullif(p->>'follow_up_on', '')::date, current_date + 3),
    nullif(btrim(coalesce(p->>'notes', '')), ''),
    v_actor)
  returning id into v_id;

  v_msg := public.fn_queue_enquiry_message('enquiry_received', v_id);

  return jsonb_build_object(
    'enquiry_id',        v_id,
    'enquiry_no',        v_no,
    'message_queued',    v_msg is not null,
    'possible_duplicate', v_dup);
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Log a follow-up
--
-- Appends to the history AND moves the next follow-up date, in one call,
-- because doing one without the other is how an enquiry falls off the list.
-- Advancing 'new' to 'contacted' here too: a clerk who has just rung somebody
-- should not also have to remember to change a dropdown.
-- ---------------------------------------------------------------------------
create or replace function public.fn_log_enquiry_contact(
  p_enquiry_id uuid, p_outcome text, p_note text default null,
  p_next_follow_up date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_e      record;
  v_id     uuid;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_outcome, '')), '') is null then
    raise exception 'Say what happened — an empty follow-up tells the next person nothing';
  end if;

  select * into v_e from public.admission_enquiries
  where id = p_enquiry_id and school_id = v_school;
  if not found then raise exception 'Enquiry not found'; end if;
  if v_e.status in ('admitted', 'lost') then
    raise exception 'Enquiry % is already closed as %', v_e.enquiry_no, v_e.status;
  end if;

  insert into public.enquiry_contacts (school_id, enquiry_id, outcome, note, contacted_by)
  values (v_school, p_enquiry_id, btrim(p_outcome),
          nullif(btrim(coalesce(p_note, '')), ''), auth.uid())
  returning id into v_id;

  update public.admission_enquiries
     set status       = case when status = 'new' then 'contacted' else status end,
         follow_up_on = coalesce(p_next_follow_up, follow_up_on),
         updated_at   = now()
   where id = p_enquiry_id and school_id = v_school;

  return jsonb_build_object('contact_id', v_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Change status by hand
--
-- 'visited' when they come and see the school; 'lost' when they do not come.
-- Admission goes through fn_enquiry_admit, never through here — otherwise an
-- enquiry could be marked admitted with no student behind it, which the
-- ck_enquiry_admitted constraint refuses anyway.
-- ---------------------------------------------------------------------------
create or replace function public.fn_set_enquiry_status(
  p_enquiry_id uuid, p_status text, p_lost_reason text default null,
  p_next_follow_up date default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_new    public.enquiry_status := p_status::public.enquiry_status;
  v_e      record;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_new = 'admitted' then
    raise exception 'Use fn_enquiry_admit to admit — it creates the student record too';
  end if;
  if v_new = 'lost' and nullif(btrim(coalesce(p_lost_reason, '')), '') is null then
    -- RAISE takes a format literal, not an expression, so this cannot be a
    -- concatenation however long the sentence gets.
    raise exception 'Say why it was lost. "Why did we not get these children" is the only question this table exists to answer';
  end if;

  select * into v_e from public.admission_enquiries
  where id = p_enquiry_id and school_id = v_school;
  if not found then raise exception 'Enquiry not found'; end if;
  if v_e.status = 'admitted' then
    raise exception 'Enquiry % is already admitted; reopening it would orphan the student',
      v_e.enquiry_no;
  end if;

  update public.admission_enquiries
     set status      = v_new,
         lost_reason = case when v_new = 'lost' then btrim(p_lost_reason) else null end,
         -- A closed enquiry drops off the follow-up list; a reopened one needs
         -- a date or it silently vanishes from every screen.
         follow_up_on = case when v_new = 'lost' then null
                            else coalesce(p_next_follow_up, follow_up_on,
                                          current_date + 3) end,
         updated_at  = now()
   where id = p_enquiry_id and school_id = v_school;
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Convert an enquiry into a student
--
-- Delegates to fn_admit_student so there is exactly one admission path. The
-- enquiry's own details prefill anything the caller does not override, so the
-- clerk retypes nothing — that is the whole reason to convert rather than
-- admit fresh.
-- ---------------------------------------------------------------------------
create or replace function public.fn_enquiry_admit(
  p_enquiry_id uuid, p_overrides jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_e       record;
  v_payload jsonb;
  v_res     jsonb;
  v_student uuid;
  v_msg     uuid;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  select * into v_e from public.admission_enquiries
  where id = p_enquiry_id and school_id = v_school;
  if not found then raise exception 'Enquiry not found'; end if;
  -- The guard that matters. Without it a double-click admits the same child
  -- twice, burning a GR number and creating a duplicate the school then has to
  -- find and unpick.
  if v_e.admitted_student_id is not null then
    raise exception 'Enquiry % was already admitted', v_e.enquiry_no;
  end if;
  if v_e.status = 'lost' then
    raise exception 'Enquiry % is marked lost. Reopen it first, so the record shows what happened', v_e.enquiry_no;
  end if;

  -- Enquiry details first, caller's overrides second, so the override wins.
  -- Nulls are stripped: a null in the payload would otherwise beat a real value
  -- from the enquiry.
  v_payload := jsonb_strip_nulls(jsonb_build_object(
    'full_name',   v_e.child_name,
    'father_name', v_e.father_name,
    'father_cnic', v_e.father_cnic,
    'phone',       v_e.phone,
    'whatsapp',    v_e.whatsapp,
    'address',     v_e.address,
    'dob',         v_e.dob,
    'gender',      v_e.gender,
    -- Fall back to the school's CURRENT session when the enquiry never named
    -- one. Most enquiries do not: a parent asking in February about "next year"
    -- has not picked a session, and the clerk taking the call should not have to
    -- either. Without this fallback conversion failed with fn_admit_student's
    -- bare "Academic session is required", which tells a clerk nothing about
    -- what to do next.
    'session_id',  coalesce(v_e.session_id,
                     (select ss.current_session_id from public.school_settings ss
                       where ss.school_id = v_school)),
    'class_id',    v_e.class_id
  )) || jsonb_strip_nulls(coalesce(p_overrides, '{}'::jsonb));

  -- Check what is still missing HERE, naming the thing the clerk has to supply.
  -- fn_admit_student's own guards are correct but speak about a payload the
  -- clerk never saw.
  if nullif(v_payload->>'session_id', '') is null then
    raise exception 'This school has no current academic session set, so there is nothing to admit into. Set one in Settings first, or pass a session explicitly';
  end if;
  if nullif(v_payload->>'class_id', '') is null then
    raise exception 'Enquiry % does not say which class. Choose one when admitting', v_e.enquiry_no;
  end if;

  -- One admission path. The GR number, the family linkage from 0036, the
  -- admission fee and the subscription student limit all apply here exactly as
  -- they do for a walk-in.
  v_res := public.fn_admit_student(v_payload);
  v_student := nullif(v_res->>'student_id', '')::uuid;
  if v_student is null then
    raise exception 'Admission did not return a student for enquiry %', v_e.enquiry_no;
  end if;

  update public.admission_enquiries
     set status              = 'admitted',
         admitted_student_id = v_student,
         admitted_at         = now(),
         lost_reason         = null,
         follow_up_on        = null,
         updated_at          = now()
   where id = p_enquiry_id and school_id = v_school;

  v_msg := public.fn_queue_enquiry_message('enquiry_admitted', p_enquiry_id,
    jsonb_build_object('gr_no', coalesce(v_res->>'gr_no', '')));

  return v_res || jsonb_build_object(
    'enquiry_id',     p_enquiry_id,
    'enquiry_no',     v_e.enquiry_no,
    'message_queued', v_msg is not null);
end;
$$;

-- ---------------------------------------------------------------------------
-- 11. The list
--
-- Ordered by how overdue the follow-up is, not by when the enquiry arrived. A
-- list sorted newest-first buries the parent who has been waiting nine days
-- under the one who called this morning, which is backwards.
-- ---------------------------------------------------------------------------
create or replace function public.fn_enquiry_list(
  p_status text default null,
  p_from   date default null,
  p_to     date default null,
  p_search text default null,
  p_due_only boolean default false,
  p_limit  int  default 200,
  p_offset int  default 0)
returns table (
  id uuid, enquiry_no bigint, child_name text, father_name text, phone text,
  whatsapp text, class_name text, class_wanted text, session_name text,
  source text, status text, follow_up_on date, days_overdue int,
  contacts int, last_contact_at timestamptz, last_outcome text,
  lost_reason text, notes text, created_at timestamptz, created_by_name text,
  admitted_student_id uuid, admitted_gr_no text, total_count bigint)
language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_term   text := nullif(btrim(coalesce(p_search, '')), '');
  v_like   text;
  v_status public.enquiry_status := nullif(p_status, '')::public.enquiry_status;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  -- Backslash FIRST, then the wildcards. Doing it the other way round escapes
  -- the escapes. Getting this wrong once meant searching "%" returned the whole
  -- school; see 0041.
  v_like := case when v_term is null then null
                 else '%' || replace(replace(replace(v_term, '\', '\\'),
                                             '%', '\%'), '_', '\_') || '%' end;

  return query
  with base as (
    select e.*
    from public.admission_enquiries e
    where e.school_id = v_school
      and (v_status is null or e.status = v_status)
      and (p_from is null or e.created_at::date >= p_from)
      and (p_to   is null or e.created_at::date <= p_to)
      and (v_like is null
           or e.child_name  ilike v_like
           or coalesce(e.father_name, '') ilike v_like
           or e.phone       ilike v_like
           or coalesce(e.whatsapp, '')    ilike v_like
           or e.enquiry_no::text = v_term)
      -- "Due" means today or earlier, and only for an OPEN enquiry: a closed
      -- one has no follow-up to be late for.
      and (not p_due_only
           or (e.status in ('new', 'contacted', 'visited')
               and e.follow_up_on is not null
               and e.follow_up_on <= current_date))
  ),
  counted as (select count(*) as n from base)
  select b.id, b.enquiry_no, b.child_name, b.father_name, b.phone, b.whatsapp,
         c.name, b.class_wanted, s.name,
         b.source::text, b.status::text, b.follow_up_on,
         case when b.status in ('new', 'contacted', 'visited')
                   and b.follow_up_on is not null
                   and b.follow_up_on < current_date
              then (current_date - b.follow_up_on)::int else 0 end,
         coalesce(k.n, 0)::int, k.last_at, k.last_outcome,
         b.lost_reason, b.notes, b.created_at,
         coalesce(p.full_name, '—'),
         b.admitted_student_id, st.gr_no,
         counted.n
  from base b
  cross join counted
  left join public.classes c
         on c.id = b.class_id and c.school_id = v_school
  left join public.academic_sessions s
         on s.id = b.session_id and s.school_id = v_school
  left join public.profiles p on p.id = b.created_by
  left join public.students st
         on st.id = b.admitted_student_id and st.school_id = v_school
  left join lateral (
    select count(*) as n,
           max(ec.contacted_at) as last_at,
           (array_agg(ec.outcome order by ec.contacted_at desc))[1] as last_outcome
    from public.enquiry_contacts ec
    where ec.enquiry_id = b.id and ec.school_id = v_school
  ) k on true
  order by
    -- Open and overdue first, longest wait at the top. Then open and due
    -- later. Then everything closed.
    case when b.status in ('new', 'contacted', 'visited') then 0 else 1 end,
    b.follow_up_on asc nulls last,
    b.created_at desc
  limit greatest(coalesce(p_limit, 200), 1)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

-- The follow-up history for one enquiry.
create or replace function public.fn_enquiry_contacts(p_enquiry_id uuid)
returns table (id uuid, contacted_at timestamptz, outcome text, note text, by_name text)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('admission_enquiries', p_enquiry_id);

  return query
  select ec.id, ec.contacted_at, ec.outcome, ec.note, coalesce(p.full_name, '—')
  from public.enquiry_contacts ec
  left join public.profiles p on p.id = ec.contacted_by
  where ec.enquiry_id = p_enquiry_id and ec.school_id = v_school
  order by ec.contacted_at desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- 12. The summary
--
-- The conversion rate is the figure a school owner actually wants, and it is
-- the easiest one to state dishonestly. An enquiry taken this morning is not a
-- failure — it has no outcome yet. So the rate counts only DECIDED enquiries:
-- admitted / (admitted + lost). Dividing by all enquiries would make a school
-- in the middle of a busy admission week look like it is failing.
-- ---------------------------------------------------------------------------
create or replace function public.fn_enquiry_summary()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school   uuid := public.current_school_id();
  v_open     int;
  v_due      int;
  v_overdue  int;
  v_no_date  int;
  v_month    int;
  v_admitted int;
  v_lost     int;
  v_decided  int;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  select
    count(*) filter (where status in ('new', 'contacted', 'visited')),
    count(*) filter (where status in ('new', 'contacted', 'visited')
                       and follow_up_on = current_date),
    count(*) filter (where status in ('new', 'contacted', 'visited')
                       and follow_up_on < current_date),
    -- An open enquiry with no follow-up date is invisible on every list. It
    -- should be impossible — fn_add_enquiry defaults the date — but if one
    -- exists the school needs to be told, not have it quietly hidden.
    count(*) filter (where status in ('new', 'contacted', 'visited')
                       and follow_up_on is null),
    count(*) filter (where created_at >= date_trunc('month', current_date)),
    count(*) filter (where status = 'admitted'),
    count(*) filter (where status = 'lost')
    into v_open, v_due, v_overdue, v_no_date, v_month, v_admitted, v_lost
  from public.admission_enquiries
  where school_id = v_school;

  v_decided := v_admitted + v_lost;

  return jsonb_build_object(
    'open',            v_open,
    'due_today',       v_due,
    'overdue',         v_overdue,
    'open_no_date',    v_no_date,
    'this_month',      v_month,
    'admitted',        v_admitted,
    'lost',            v_lost,
    'decided',         v_decided,
    -- Null, not zero, when nothing has been decided yet. A "0%" conversion
    -- rate on a school's first day is a lie; "—" is the truth.
    'conversion_rate', case when v_decided = 0 then null
                            else round(v_admitted::numeric * 100 / v_decided, 1) end);
end;
$$;

-- Where the enquiries came from, and which sources actually convert. A banner
-- costs money; four enquiries and one admission from it is worth knowing.
create or replace function public.fn_enquiry_sources(
  p_from date default null, p_to date default null)
returns table (source text, enquiries bigint, admitted bigint, lost bigint,
               open bigint, conversion_rate numeric)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select e.source::text,
         count(*),
         count(*) filter (where e.status = 'admitted'),
         count(*) filter (where e.status = 'lost'),
         count(*) filter (where e.status in ('new', 'contacted', 'visited')),
         case when count(*) filter (where e.status in ('admitted', 'lost')) = 0
              then null
              else round(count(*) filter (where e.status = 'admitted')::numeric * 100
                         / count(*) filter (where e.status in ('admitted', 'lost')), 1)
         end
  from public.admission_enquiries e
  where e.school_id = v_school
    and (p_from is null or e.created_at::date >= p_from)
    and (p_to   is null or e.created_at::date <= p_to)
  group by e.source
  order by count(*) desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- 13. Grants
-- ---------------------------------------------------------------------------
grant execute on function public.fn_add_enquiry(jsonb) to authenticated;
grant execute on function public.fn_log_enquiry_contact(uuid, text, text, date) to authenticated;
grant execute on function public.fn_set_enquiry_status(uuid, text, text, date) to authenticated;
grant execute on function public.fn_enquiry_admit(uuid, jsonb) to authenticated;
grant execute on function public.fn_enquiry_list(text, date, date, text, boolean, int, int) to authenticated;
grant execute on function public.fn_enquiry_contacts(uuid) to authenticated;
grant execute on function public.fn_enquiry_summary() to authenticated;
grant execute on function public.fn_enquiry_sources(date, date) to authenticated;

revoke all on function public.fn_add_enquiry(jsonb) from anon;
revoke all on function public.fn_log_enquiry_contact(uuid, text, text, date) from anon;
revoke all on function public.fn_set_enquiry_status(uuid, text, text, date) from anon;
revoke all on function public.fn_enquiry_admit(uuid, jsonb) from anon;
revoke all on function public.fn_enquiry_list(text, date, date, text, boolean, int, int) from anon;
revoke all on function public.fn_enquiry_contacts(uuid) from anon;
revoke all on function public.fn_enquiry_summary() from anon;
revoke all on function public.fn_enquiry_sources(date, date) from anon;

-- Internal: only ever called by the functions above.
revoke all on function public.fn_queue_enquiry_message(text, uuid, jsonb) from public;
revoke all on function public.fn_queue_enquiry_message(text, uuid, jsonb) from anon;
revoke all on function public.fn_queue_enquiry_message(text, uuid, jsonb) from authenticated;

-- Give every existing school the two new templates. on-conflict-do-nothing, so
-- a school that has edited its wording keeps it.
do $$
declare s uuid;
begin
  for s in select id from public.schools loop
    perform public.fn__seed_message_templates(s);
  end loop;
end $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 0047_reachability.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0047 — Close the "declared but unreachable" class of bug.
--
-- WHY THIS MIGRATION EXISTS
--
-- The single most common defect in this codebase has not been wrong logic. It
-- has been CORRECT logic that nothing could reach. Every one of these shipped,
-- passed CI, and did nothing:
--
--   * fn_link_parent          — the only writer of profiles.family_id, no callers,
--                               so the whole parent portal threw for every parent
--   * profiles.active         — written by the Settings screen, read by nothing,
--                               so "Deactivate" left a dismissed clerk full access
--   * fn_family_for           — no callers, so siblings never shared a family and
--                               family billing had never worked in production
--   * fn_find_by_voucher      — no callers, so a printed challan could not be scanned
--   * message_templates.enabled — no writer, so the WhatsApp toggle was decorative
--   * result_cards.published_at — never selected, so no result could reach a parent
--   * students.photo_url      — still dead
--   * supabase/bundles/       — stopped at migration 0039, so seven migrations
--                               never reached any real school at all
--
-- Each was found by hand, late, one at a time. supabase/check-reachable.sh now
-- finds them by query on every CI run. This migration fixes what that check
-- turned up on its first run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. THE BUG: other income could be recorded but never reversed
--
-- 0030 built expenses and other income as mirror images, both append-only:
-- never edit, never delete, correct with a reversing entry. fn_reverse_expense
-- got a db.ts wrapper and a button on the Accounts screen. Its twin,
-- fn_reverse_other_income, got neither — so a clerk who typed Rs 50,000 of hall
-- rent instead of Rs 5,000 had NO way to correct it, ever. The error sat in the
-- income figure, the profit figure, the day book and the balance sheet
-- permanently.
--
-- The function itself was correct all along. Only the wiring was missing, which
-- is exactly the pattern above. Nothing to change here — the fix is the db.ts
-- wrapper and the Accounts screen button in this same commit. This comment
-- records WHY a function that already existed suddenly appears in a changelog,
-- so nobody later "cleans up" the apparently-redundant reversal path.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 2. Two genuinely dead helpers, dropped
--
-- Both were confirmed unreferenced by querying the live catalogue, not by
-- reading: no function body, no trigger, no RLS policy (USING or WITH CHECK),
-- no column default, no check constraint, no index expression, no view — and no
-- mention anywhere in web/src or supabase/functions.
--
--   auth_role()  — from 0001. Superseded by has_role()/is_staff(), which every
--                  policy and guard actually uses.
--   is_parent()  — from 0033. The portal gates on my_family_id() and
--                  fn__assert_my_child() instead.
--
-- Dropped rather than left in place, because a dead function that `authenticated`
-- may EXECUTE is attack surface for no benefit, and because a reviewed-exceptions
-- list should hold deliberate exceptions rather than things nobody got round to.
-- If either is ever wanted again it is four lines of git history away.
-- ---------------------------------------------------------------------------
drop function if exists public.auth_role();
drop function if exists public.is_parent();

-- ─────────────────────────────────────────────────────────────────────────
-- 0048_corrections.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0048 — Make the mark and attendance audit trail visible.
--
-- WHAT WAS WRONG
--
-- mark_entries and attendance_daily both carry `corrected_from` and
-- `correction_reason`. The three entry functions diligently write
-- `corrected_from` — the previous mark, the previous attendance status —
-- whenever a value actually changes.
--
-- Nothing has ever READ either column. Not one function, not one screen. And
-- `correction_reason` was never written at all.
--
-- So the system quietly records that a teacher changed a mark from 45 to 40 the
-- night before results, and no principal can see it, no parent disputing that
-- mark can be answered, and nobody was ever asked why. An audit trail nobody
-- can read is not an audit trail; it is a database column that makes the
-- software look trustworthy without being trustworthy.
--
-- Found by supabase/check-columns-used.sh, which now fails CI for any new
-- column nothing reads or writes.
--
-- WHAT THIS DOES
--
--   1. The three entry functions take an optional reason, and record it ONLY on
--      the rows whose value actually changed. A reason attached to an unchanged
--      mark would be noise in the very report this exists to make readable.
--   2. Two read paths — fn_mark_corrections and fn_attendance_corrections —
--      gated on owner/principal, because this is an oversight tool. A subject
--      teacher auditing colleagues is not what it is for, and the person most
--      likely to want it hidden is the person who changed the mark.
--
-- WHY THE SIGNATURES ARE DROPPED AND RECREATED
--
-- `create or replace` cannot add a parameter: it creates an OVERLOAD instead,
-- and then a two-argument call matches both the old function and the new one's
-- default, which Postgres rejects as ambiguous. So the two-argument forms are
-- dropped first. Existing two-argument callers — the app included — keep
-- working through the new default.
-- =============================================================================

drop function if exists public.fn_enter_marks(uuid, jsonb);
drop function if exists public.fn_enter_assessment_marks(uuid, jsonb);
drop function if exists public.fn_mark_attendance(date, jsonb);

-- ---------------------------------------------------------------------------
-- 1. Exam marks
-- ---------------------------------------------------------------------------
create or replace function public.fn_enter_marks(
  p_exam_subject_id uuid, p_marks jsonb, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_max    numeric;
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
  select max_marks into v_max from public.exam_subjects where id = p_exam_subject_id;
  if v_max is null then raise exception 'Exam subject not found'; end if;

  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where coalesce((e->>'is_absent')::boolean, false) = false
      and nullif(e->>'marks', '') is not null
      and ((e->>'marks')::numeric < 0 or (e->>'marks')::numeric > v_max)
  ) then
    raise exception 'Marks must be between 0 and %', v_max;
  end if;

  select count(distinct (e->>'enrollment_id')) into v_total from jsonb_array_elements(p_marks) e;

  with input as (
    select distinct on (enrollment_id) enrollment_id, marks, is_absent
    from (
      select (e->>'enrollment_id')::uuid as enrollment_id,
             nullif(e->>'marks', '')::numeric as marks,
             coalesce((e->>'is_absent')::boolean, false) as is_absent
      from jsonb_array_elements(p_marks) e
    ) q
    order by enrollment_id
  ),
  upserted as (
    insert into public.mark_entries as me
      (exam_subject_id, enrollment_id, marks, max_marks, is_absent, marked_by)
    select p_exam_subject_id, enrollment_id, marks, v_max, is_absent, v_actor from input
    on conflict (exam_subject_id, enrollment_id) where exam_subject_id is not null
    do update set marks = excluded.marks, is_absent = excluded.is_absent,
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
-- 2. Assessment (class test) marks
-- ---------------------------------------------------------------------------
create or replace function public.fn_enter_assessment_marks(
  p_assessment_id uuid, p_marks jsonb, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_a      record;
  v_total  integer;
  v_marked integer;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to enter marks';
  end if;
  perform public.assert_own('assessments', p_assessment_id);
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;

  select * into v_a from public.assessments
  where id = p_assessment_id and school_id = public.current_school_id();
  if not found then raise exception 'Assessment not found'; end if;
  if v_a.is_locked then raise exception 'This assessment is locked'; end if;

  -- Teacher scope, as before: a subject teacher may only mark their own class.
  if not public.has_role('owner','principal','admin_clerk') then
    if not public.fn_may_manage_class(v_a.session_id, v_a.class_id, v_a.section_id) then
      raise exception 'You can only enter marks for your assigned class';
    end if;
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where coalesce((e->>'is_absent')::boolean, false) = false
      and nullif(e->>'marks', '') is not null
      and ((e->>'marks')::numeric < 0 or (e->>'marks')::numeric > v_a.max_marks)
  ) then
    raise exception 'Marks must be between 0 and %', v_a.max_marks;
  end if;

  -- Every enrolment must be in this school.
  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where not exists (
      select 1 from public.enrollments en
      where en.id = (e->>'enrollment_id')::uuid
        and en.school_id = public.current_school_id())
  ) then
    raise exception 'Unknown enrolment in this school' using errcode = '42501';
  end if;

  select count(distinct (e->>'enrollment_id')) into v_total from jsonb_array_elements(p_marks) e;

  with input as (
    select distinct on (enrollment_id) enrollment_id, marks, is_absent
    from (
      select (e->>'enrollment_id')::uuid as enrollment_id,
             nullif(e->>'marks', '')::numeric as marks,
             coalesce((e->>'is_absent')::boolean, false) as is_absent
      from jsonb_array_elements(p_marks) e
    ) q
    order by enrollment_id
  ),
  upserted as (
    insert into public.mark_entries as me
      (assessment_id, enrollment_id, marks, max_marks, is_absent, marked_by)
    select p_assessment_id, enrollment_id, marks, v_a.max_marks, is_absent, v_actor from input
    on conflict (assessment_id, enrollment_id) where assessment_id is not null
    do update set marks = excluded.marks, is_absent = excluded.is_absent,
                  marked_by = excluded.marked_by,
                  corrected_from = case when me.marks is distinct from excluded.marks
                                        then me.marks else me.corrected_from end,
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
-- 3. Attendance
-- ---------------------------------------------------------------------------
create or replace function public.fn_mark_attendance(
  p_date date, p_marks jsonb, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_total  integer;
  v_marked integer;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to mark attendance';
  end if;
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;

  -- Tenant scope: every enrolment must be in THIS school. Checked for all
  -- roles, because the teacher-scope check below is skipped for admins —
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

  if not public.has_role('owner','principal','admin_clerk') then
    if exists (
      select 1 from jsonb_array_elements(p_marks) e
      join public.enrollments en on en.id = (e->>'enrollment_id')::uuid
      where not public.fn_may_manage_class(en.session_id, en.class_id, en.section_id)
    ) then
      raise exception 'You can only mark attendance for your assigned class';
    end if;
  end if;

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

-- ---------------------------------------------------------------------------
-- 4. The read path that did not exist
--
-- Every mark that has been changed since it was first entered, across exams and
-- class tests, with what it was, what it is, who changed it and why. This is
-- the answer to "my son got 45, you have written 40", and it is the report a
-- head teacher wants the week before results go out.
--
-- Owner and principal only. This is an oversight tool, and the person most
-- likely to want it hidden is the person who changed the mark.
-- ---------------------------------------------------------------------------
create or replace function public.fn_mark_corrections(
  p_from date default null, p_to date default null)
returns table (
  changed_at timestamptz, kind text, student_name text, gr_no text,
  class_name text, section_name text, subject_name text, paper text,
  was numeric, now_is numeric, max_marks numeric, is_absent boolean,
  reason text, changed_by text, is_locked boolean)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may review mark corrections'
      using errcode = '42501';
  end if;

  return query
  select
    me.updated_at,
    case when me.exam_subject_id is not null then 'Exam' else 'Class test' end,
    s.full_name, s.gr_no, c.name, sec.name,
    coalesce(subj_x.name, subj_a.name),
    coalesce(et.name, a.title),
    me.corrected_from, me.marks, me.max_marks, me.is_absent,
    me.correction_reason,
    coalesce(p.full_name, '—'),
    me.is_locked
  from public.mark_entries me
  join public.enrollments en on en.id = me.enrollment_id and en.school_id = v_school
  join public.students s on s.id = en.student_id and s.school_id = v_school
  left join public.classes c on c.id = en.class_id and c.school_id = v_school
  left join public.sections sec on sec.id = en.section_id and sec.school_id = v_school
  left join public.exam_subjects es on es.id = me.exam_subject_id and es.school_id = v_school
  left join public.exam_terms et on et.id = es.exam_term_id and et.school_id = v_school
  left join public.subjects subj_x on subj_x.id = es.subject_id and subj_x.school_id = v_school
  left join public.assessments a on a.id = me.assessment_id and a.school_id = v_school
  left join public.subjects subj_a on subj_a.id = a.subject_id and subj_a.school_id = v_school
  left join public.profiles p on p.id = me.marked_by
  where me.school_id = v_school
    -- corrected_from is only set when a mark actually changed, so its presence
    -- IS the definition of a correction.
    and me.corrected_from is not null
    and (p_from is null or me.updated_at::date >= p_from)
    and (p_to   is null or me.updated_at::date <= p_to)
  order by me.updated_at desc;
end;
$$;

-- Attendance changes. Lower stakes than marks, but the same principle: an
-- attendance record altered after the fact, with no reason, is how a disputed
-- absence becomes unanswerable.
create or replace function public.fn_attendance_corrections(
  p_from date default null, p_to date default null)
returns table (
  changed_at timestamptz, attendance_date date, student_name text, gr_no text,
  class_name text, section_name text, was text, now_is text,
  reason text, changed_by text)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may review attendance corrections'
      using errcode = '42501';
  end if;

  return query
  select
    ad.updated_at, ad.attendance_date, s.full_name, s.gr_no, c.name, sec.name,
    ad.corrected_from::text, ad.status::text,
    ad.correction_reason, coalesce(p.full_name, '—')
  from public.attendance_daily ad
  join public.enrollments en on en.id = ad.enrollment_id and en.school_id = v_school
  join public.students s on s.id = en.student_id and s.school_id = v_school
  left join public.classes c on c.id = en.class_id and c.school_id = v_school
  left join public.sections sec on sec.id = en.section_id and sec.school_id = v_school
  left join public.profiles p on p.id = ad.marked_by
  where ad.school_id = v_school
    and ad.corrected_from is not null
    and (p_from is null or ad.updated_at::date >= p_from)
    and (p_to   is null or ad.updated_at::date <= p_to)
  order by ad.updated_at desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Grants. The three entry functions were granted under their old
--    two-argument signatures, which no longer exist.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_enter_marks(uuid, jsonb, text) to authenticated;
grant execute on function public.fn_enter_assessment_marks(uuid, jsonb, text) to authenticated;
grant execute on function public.fn_mark_attendance(date, jsonb, text) to authenticated;
grant execute on function public.fn_mark_corrections(date, date) to authenticated;
grant execute on function public.fn_attendance_corrections(date, date) to authenticated;

revoke all on function public.fn_enter_marks(uuid, jsonb, text) from anon;
revoke all on function public.fn_enter_assessment_marks(uuid, jsonb, text) from anon;
revoke all on function public.fn_mark_attendance(date, jsonb, text) from anon;
revoke all on function public.fn_mark_corrections(date, date) from anon;
revoke all on function public.fn_attendance_corrections(date, date) from anon;
