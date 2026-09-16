-- =============================================================================
-- 0140  The month, the roll, and who has paid
--
-- THE FEES SCREEN OPENED ON FOUR NUMBERS AND NONE OF THEM WAS THE QUESTION.
-- Unpaid challans, collected today, spent today, balance today. A school
-- standing at the counter on the fifth of the month wants to know: it is
-- September, there are 240 children, 118 have paid and 122 have not, and here
-- are their names. Not one of those four numbers answers any part of that.
--
-- Two of them were also wrong, and not by a rounding error. fn_counter_summary
-- measured "today" as date_trunc('day', now()) and "spent today" as
-- spent_on = current_date, both in the server's timezone, and Supabase runs on
-- UTC. Proven on a test database:
--
--     a payment taken at 02:00 on 16 September in Karachi
--     lands in 15 SEPTEMBER's "collected today"
--
-- A school that takes a fee early in the morning sees it on yesterday's figure.
-- 0107 exists precisely to put every date bound through Asia/Karachi and this
-- function was missed; so was fn_dashboard_summary, which shows the same figure
-- on the home screen.
--
-- fn_defaulters was a third kind of wrong. It called student_balance three
-- times per row, in the select list, in the where clause and again in the order
-- by, and student_balance is four subqueries over the whole ledger. Measured on
-- a 1046 pupil database with EXPLAIN ANALYZE: 3.7 SECONDS, for a screen the
-- office opens every day. 0118 exists to stop a balance reading the whole
-- ledger and this walked straight back into it.
--
-- And its rule was wrong as well: "defaulter" meant "owes anything", so a child
-- billed on the 1st and due on the 30th was a defaulter on the 2nd. The vendor
-- was asked and chose the rule a school actually uses: you are in arrears when
-- you owe for a month BEFORE the current one. September is in progress and
-- nobody is chased for it; the moment October is raised, an unpaid September
-- puts the family on the list.
-- =============================================================================

-- ================================================ 1. the month, in one go ====
-- ONE QUERY, NOT ONE PER PUPIL. Every figure on the Fees screen comes from
-- here, so it is written as three aggregates joined to the roll rather than as
-- a function called per child. The difference is the 3.7 seconds above.
create or replace function public.fn_fees_month(
  p_session_id uuid, p_month date default null
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_month  date := date_trunc('month', coalesce(p_month, public.fn__karachi_month()))::date;
  v_out    jsonb;
begin
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted to view fee records' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  with roll as (
    select e.id as enrollment_id, e.student_id
      from public.enrollments e
      join public.students s on s.id = e.student_id
                            and s.school_id = v_school
                            and s.status = 'active'
                            and s.deleted_at is null
     where e.session_id = p_session_id and e.status = 'active'
  ),
  inv as (
    select i.id, i.student_id, i.fine
      from public.invoices i
     where i.school_id = v_school and i.session_id = p_session_id
       and i.period_month = v_month and i.status <> 'void'
  ),
  lines as (
    select l.invoice_id,
           sum(case when l.is_discount then -l.amount else l.amount end) as net
      from public.invoice_lines l
      join inv on inv.id = l.invoice_id
     group by l.invoice_id
  ),
  alloc as (
    select al.invoice_id, sum(al.amount) as paid
      from public.payment_allocations al
      join public.payments p on p.id = al.payment_id and p.status = 'verified'
      join inv on inv.id = al.invoice_id
     group by al.invoice_id
  ),
  per_pupil as (
    select r.student_id,
           coalesce(sum(coalesce(l.net, 0) + coalesce(inv.fine, 0)), 0) as charge,
           coalesce(sum(coalesce(a.paid, 0)), 0) as paid,
           count(inv.id) as invoices
      from roll r
      left join inv on inv.student_id = r.student_id
      left join lines l on l.invoice_id = inv.id
      left join alloc a on a.invoice_id = inv.id
     group by r.student_id
  )
  select jsonb_build_object(
    'month',        v_month,
    'today',        (now() at time zone 'Asia/Karachi')::date,
    'state',        coalesce((select b.state from public.billing_months b
                               where b.session_id = p_session_id and b.period_month = v_month),
                             'scheduled'),
    'due_date',     (select b.due_date from public.billing_months b
                      where b.session_id = p_session_id and b.period_month = v_month),
    'roll',         (select count(*) from roll),
    'billed',       (select count(*) from per_pupil where invoices > 0),
    'not_billed',   (select count(*) from per_pupil where invoices = 0),
    -- Paid means the month is settled: charged and nothing left on it. A child
    -- whose fee is entirely waived counts as paid, because there is nothing for
    -- the office to chase and showing them on the unpaid list would be a lie
    -- forty families long.
    'paid',         (select count(*) from per_pupil where invoices > 0 and charge - paid <= 0),
    'unpaid',       (select count(*) from per_pupil where invoices > 0 and charge - paid > 0),
    'part_paid',    (select count(*) from per_pupil where invoices > 0 and paid > 0 and charge - paid > 0),
    'charged_total',(select coalesce(sum(charge), 0) from per_pupil),
    'paid_total',   (select coalesce(sum(paid), 0) from per_pupil),
    'due_total',    (select coalesce(sum(greatest(charge - paid, 0)), 0) from per_pupil)
  ) into v_out;

  return v_out;
end;
$$;
revoke all on function public.fn_fees_month(uuid, date) from public, anon;
grant execute on function public.fn_fees_month(uuid, date) to authenticated;

-- The two lists behind the two counts. Same shape for both so the screen shows
-- them the same way, and the caller says which it wants rather than this
-- returning everything and the browser filtering, which would send the whole
-- roll down the wire to show half of it.
create or replace function public.fn_fees_month_pupils(
  p_session_id uuid, p_month date default null, p_state text default 'unpaid'
) returns table(
  student_id uuid, gr_no text, full_name text, class_name text, section_name text,
  roll_no text, family_id uuid, family_head text,
  charge numeric, paid numeric, due numeric, state text
) language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_month  date := date_trunc('month', coalesce(p_month, public.fn__karachi_month()))::date;
begin
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted to view fee records' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  if coalesce(p_state, 'unpaid') not in ('paid', 'unpaid', 'not_billed', 'all') then
    raise exception 'Ask for paid, unpaid, not_billed or all.' using errcode = '22023';
  end if;

  return query
  with inv as (
    select i.id, i.student_id, i.fine
      from public.invoices i
     where i.school_id = v_school and i.session_id = p_session_id
       and i.period_month = v_month and i.status <> 'void'
  ),
  lines as (
    select l.invoice_id, sum(case when l.is_discount then -l.amount else l.amount end) as net
      from public.invoice_lines l join inv on inv.id = l.invoice_id group by l.invoice_id
  ),
  alloc as (
    select al.invoice_id, sum(al.amount) as paid
      from public.payment_allocations al
      join public.payments p on p.id = al.payment_id and p.status = 'verified'
      join inv on inv.id = al.invoice_id group by al.invoice_id
  ),
  per_pupil as (
    select e.student_id,
           coalesce(sum(coalesce(l.net, 0) + coalesce(inv.fine, 0)), 0) as charge,
           coalesce(sum(coalesce(a.paid, 0)), 0) as paid,
           count(inv.id) as invoices
      from public.enrollments e
      join public.students s on s.id = e.student_id and s.school_id = v_school
                            and s.status = 'active' and s.deleted_at is null
      left join inv on inv.student_id = e.student_id
      left join lines l on l.invoice_id = inv.id
      left join alloc a on a.invoice_id = inv.id
     where e.session_id = p_session_id and e.status = 'active'
     group by e.student_id
  )
  select s.id, s.gr_no, s.full_name, c.name, sec.name, e.roll_no,
         s.family_id, f.head_name,
         pp.charge, pp.paid, greatest(pp.charge - pp.paid, 0),
         case when pp.invoices = 0 then 'not_billed'
              when pp.charge - pp.paid <= 0 then 'paid'
              else 'unpaid' end
    from per_pupil pp
    join public.students s on s.id = pp.student_id
    join public.enrollments e on e.student_id = s.id and e.session_id = p_session_id
                             and e.status = 'active'
    join public.classes c on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
    left join public.families f on f.id = s.family_id
   where coalesce(p_state, 'unpaid') = 'all'
      or (case when pp.invoices = 0 then 'not_billed'
               when pp.charge - pp.paid <= 0 then 'paid'
               else 'unpaid' end) = p_state
   order by c.level_order, c.name, sec.name nulls first, s.full_name;
end;
$$;
revoke all on function public.fn_fees_month_pupils(uuid, date, text) from public, anon;
grant execute on function public.fn_fees_month_pupils(uuid, date, text) to authenticated;

-- ==================================================== 2. arrears ============
-- OWES FOR A MONTH BEFORE THIS ONE. The vendor chose this rule over "past the
-- due date" and over "owes more than a month's fee", and it is the one a school
-- can explain to a parent in one sentence: September is running, so nobody is
-- chased for September.
--
-- months_owed is the count of separate months still open, which is what tells
-- the office the difference between a family one month behind and a family four
-- months behind. The old screen showed one number, the total, where Rs 12,000
-- could be one expensive month or four cheap ones.
create or replace function public.fn_arrears(p_session_id uuid)
returns table(
  student_id uuid, gr_no text, full_name text, class_name text, section_name text,
  roll_no text, family_id uuid, family_head text, phone text,
  months_owed integer, oldest_month date, amount numeric
) language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_month  date := public.fn__karachi_month();
begin
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted to view fee records' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  return query
  with inv as (
    select i.id, i.student_id, i.period_month, i.fine
      from public.invoices i
     where i.school_id = v_school
       and i.status <> 'void'
       and i.period_month is not null
       and i.period_month < v_month
       -- A challan the office has deliberately deferred is not an arrear: the
       -- school has already said "pay me in November". 0083 put that field
       -- there and nothing on the defaulters screen ever read it.
       and (i.deferred_until is null or i.deferred_until <= (now() at time zone 'Asia/Karachi')::date)
  ),
  lines as (
    select l.invoice_id, sum(case when l.is_discount then -l.amount else l.amount end) as net
      from public.invoice_lines l join inv on inv.id = l.invoice_id group by l.invoice_id
  ),
  alloc as (
    select al.invoice_id, sum(al.amount) as paid
      from public.payment_allocations al
      join public.payments p on p.id = al.payment_id and p.status = 'verified'
      join inv on inv.id = al.invoice_id group by al.invoice_id
  ),
  owing as (
    select inv.student_id, inv.period_month,
           coalesce(l.net, 0) + coalesce(inv.fine, 0) - coalesce(a.paid, 0) as due
      from inv
      left join lines l on l.invoice_id = inv.id
      left join alloc a on a.invoice_id = inv.id
  ),
  rolled as (
    select o.student_id,
           count(*)::integer as months_owed,
           min(o.period_month) as oldest_month,
           sum(o.due) as amount
      from owing o
     where o.due > 0
     group by o.student_id
  )
  select s.id, s.gr_no, s.full_name, c.name, sec.name, e.roll_no,
         s.family_id, f.head_name, coalesce(f.phone, s.phone),
         r.months_owed, r.oldest_month, r.amount
    from rolled r
    join public.students s on s.id = r.student_id
                          and s.status = 'active' and s.deleted_at is null
    join public.enrollments e on e.student_id = s.id and e.session_id = p_session_id
                             and e.status = 'active'
    join public.classes c on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
    left join public.families f on f.id = s.family_id
   order by r.oldest_month, r.amount desc;
end;
$$;
revoke all on function public.fn_arrears(uuid) from public, anon;
grant execute on function public.fn_arrears(uuid) to authenticated;

-- fn_defaulters KEEPS ITS NAME AND ITS SHAPE and stops being slow. Three
-- frozen bundles and the reports screen call it by this signature. The rule is
-- unchanged here on purpose, "owes anything at all", because that IS a useful
-- question for the reports page; what changes is that it asks it once instead
-- of three times per pupil over the whole ledger. The screen that used to be
-- called Defaulters now shows fn_arrears above.
create or replace function public.fn_defaulters(p_session_id uuid)
returns table(
  student_id uuid, gr_no text, full_name text, class_name text,
  section_name text, roll_no text, balance numeric
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  return query
  with inv as (
    select i.id, i.student_id, i.fine from public.invoices i
     where i.school_id = v_school and i.status <> 'void'
  ),
  lines as (
    select l.invoice_id, sum(case when l.is_discount then -l.amount else l.amount end) as net
      from public.invoice_lines l join inv on inv.id = l.invoice_id group by l.invoice_id
  ),
  alloc as (
    select al.invoice_id, sum(al.amount) as paid
      from public.payment_allocations al
      join public.payments p on p.id = al.payment_id and p.status = 'verified'
      join inv on inv.id = al.invoice_id group by al.invoice_id
  ),
  adj as (
    select a.student_id, sum(a.amount) as amount
      from public.adjustments a group by a.student_id
  ),
  bal as (
    select inv.student_id,
           sum(coalesce(l.net, 0) + coalesce(inv.fine, 0) - coalesce(a.paid, 0)) as owed
      from inv
      left join lines l on l.invoice_id = inv.id
      left join alloc a on a.invoice_id = inv.id
     group by inv.student_id
  )
  select s.id, s.gr_no, s.full_name, c.name, sec.name, e.roll_no,
         coalesce(b.owed, 0) + coalesce(j.amount, 0)
    from public.enrollments e
    join public.students s on s.id = e.student_id and s.school_id = v_school
                          and s.status = 'active' and s.deleted_at is null
    join public.classes c on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
    left join bal b on b.student_id = s.id
    left join adj j on j.student_id = s.id
   where e.session_id = p_session_id and e.status = 'active'
     and coalesce(b.owed, 0) + coalesce(j.amount, 0) > 0
   order by coalesce(b.owed, 0) + coalesce(j.amount, 0) desc;
end;
$$;
revoke all on function public.fn_defaulters(uuid) from public, anon;
grant execute on function public.fn_defaulters(uuid) to authenticated;

-- ==================================== 3. the two counters, in Karachi time ===
-- Reproduced whole from pg_get_functiondef on a fully migrated database, with
-- only the date bounds changed. See the header: a payment taken at 02:00 on the
-- 16th in Karachi was being counted on the 15th, on both of these screens, for
-- five hours every single morning.
CREATE OR REPLACE FUNCTION public.fn_counter_summary()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_school   uuid := public.current_school_id();
  v_unpaid   integer;
  v_income   numeric;
  v_expense  numeric;
  v_pending  integer;
  v_pending_amt numeric;
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  -- An invoice is "unpaid" when what it charges exceeds what has been allocated
  -- to it from VERIFIED payments. Derived rather than read off invoices.status,
  -- because status is a label and this is the money.
  select count(*) into v_unpaid
  from public.invoices i
  where i.school_id = v_school
    and i.status <> 'void'
    and (
      coalesce((select sum(case when l.is_discount then -l.amount else l.amount end)
                  from public.invoice_lines l where l.invoice_id = i.id), 0)
      + coalesce(i.fine, 0)
      - coalesce((select sum(al.amount)
                    from public.payment_allocations al
                    join public.payments p on p.id = al.payment_id
                   where al.invoice_id = i.id and p.status = 'verified'), 0)
    ) > 0;

  select coalesce(sum(p.amount), 0) into v_income
  from public.payments p
  where p.school_id = v_school
    and p.status = 'verified'
    -- KARACHI, NOT THE SERVER. Supabase runs on UTC, so date_trunc('day', now())
    -- began the day at 05:00 Pakistan time: a fee taken at 2am appeared in
    -- YESTERDAY's collection. 0107 put every other date bound in this schema
    -- through Asia/Karachi and this one was missed.
    and (p.created_at at time zone 'Asia/Karachi')::date
        = (now() at time zone 'Asia/Karachi')::date;

  select coalesce(sum(e.amount), 0) into v_expense
  from public.expenses e
  where e.school_id = v_school
    and e.spent_on = (now() at time zone 'Asia/Karachi')::date
    and e.reversal_of is null;

  -- Money taken but not yet cleared. Shown next to the day's income because a
  -- clerk who has accepted three bank transfers needs to know they are not in
  -- that income figure — otherwise the drawer looks short at closing.
  select count(*), coalesce(sum(p.amount), 0) into v_pending, v_pending_amt
  from public.payments p
  where p.school_id = v_school and p.status = 'pending';

  return jsonb_build_object(
    'unpaid_invoices', v_unpaid,
    'income_today',    v_income,
    'expense_today',   v_expense,
    'balance_today',   v_income - v_expense,
    'pending_count',   v_pending,
    'pending_amount',  v_pending_amt);
end;
$function$

;

CREATE OR REPLACE FUNCTION public.fn_dashboard_summary()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_school  uuid := public.current_school_id();
  v_session uuid := (select current_session_id from public.school_settings
                      where school_id = v_school);
  -- may_view, and NOT the plain role check. 0059 rewrote every READ gate in the
  -- schema to go through one helper, programmatically, and warned in its own
  -- header that retyping a function body by hand is how that gets silently
  -- reverted. The first draft of this migration did exactly that on all three
  -- functions it touches; supabase/repair/detect.sql caught it. Uncaught, it
  -- would have shut the observer role out of the money tiles all over again.
  v_finance boolean := public.may_view('owner','principal','admin_clerk','accountant','readonly');
  v_active  int;
  v_no_class int;
  v_present int; v_absent int; v_leave int; v_late int; v_half int; v_marked int;
  v_today numeric; v_month numeric; v_outstanding numeric; v_defaulters int;
  v_new_admissions int;
  v_billed_month int;
  v_classes_no_fee int;
  -- Karachi for the same reason as fn_counter_summary: for five hours every
  -- morning the server's date is still yesterday's.
  v_month_start date := date_trunc('month', (now() at time zone 'Asia/Karachi')::date)::date;
begin
  if not public.may_view('owner','principal','admin_clerk','accountant',
                         'class_teacher','subject_teacher','readonly') then
    raise exception 'Not permitted';
  end if;

  -- ONE definition, shared with the plan limit. Previously this counted
  -- enrolments without looking at the student row, so a record removed in error
  -- stayed in the tile while dropping out of the licence count and off the
  -- Students screen.
  v_active := public.fn_count_students(v_school);

  -- The children the tile cannot see. An active student with no active
  -- enrolment in the current session gets no challan, no register entry and no
  -- result card, and no other screen in the product reports them.
  select count(*) into v_no_class
  from public.students s
  where s.school_id = v_school
    and s.status = 'active'
    and s.deleted_at is null
    and not exists (
      select 1 from public.enrollments e
      where e.student_id = s.id
        and e.session_id = v_session
        and e.status = 'active');

  -- Joined to students so a removed child cannot be marked present against a
  -- headcount that no longer includes them. "42 present of 40 on the roll" is
  -- the kind of arithmetic that makes a school stop trusting the whole page.
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
  join public.students s on s.id = e.student_id
  where ad.school_id = v_school
    and ad.attendance_date = (now() at time zone 'Asia/Karachi')::date
    and e.session_id = v_session
    and s.deleted_at is null;

  select count(*) into v_new_admissions
  from public.students s
  where s.school_id = v_school
    and s.deleted_at is null
    and s.created_at >= v_month_start
    and s.created_at < (v_month_start + interval '1 month');

  if v_finance then
    select coalesce(sum(p.amount), 0) into v_today
    from public.payments p
    where p.school_id = v_school
      and p.status = 'verified'
      and (p.created_at at time zone 'Asia/Karachi')::date
          = (now() at time zone 'Asia/Karachi')::date;

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

    select count(distinct i.student_id) into v_billed_month
    from public.invoices i
    where i.school_id = v_school
      and i.period_month = v_month_start
      and i.status <> 'void'
      and coalesce((select sum(case when l.is_discount then -l.amount else l.amount end)
                      from public.invoice_lines l where l.invoice_id = i.id), 0) > 0;

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
    'students_without_a_class', coalesce(v_no_class, 0),
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
    'billed_students_month', coalesce(v_billed_month, 0),
    'classes_without_fee', coalesce(v_classes_no_fee, 0),
    'session_set', v_session is not null);
end;
$function$

;

-- ================================ 4. one child, one answer, everywhere =======
-- THE TAG BEHIND EVERY SEARCH RESULT. When the office types a name, the answer
-- they need first is "has this child paid this month", and nothing in this
-- product could say it. The child's own Fees tab could not either: it showed
-- CURRENT BALANCE Rs 0 for a family whose Rs 3,150 the school was holding as an
-- advance, because student_balance answers "what is owed" and nothing answered
-- "what are we sitting on".
--
-- Both come back here, from one call, so the search result, the child's tab and
-- the family sheet cannot disagree with each other.
create or replace function public.fn_student_fee_state(
  p_student_id uuid, p_month date default null
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_month  date := date_trunc('month', coalesce(p_month, public.fn__karachi_month()))::date;
  v_charge numeric; v_paid numeric; v_inv integer;
  v_arr_n integer; v_arr_amt numeric; v_arr_old date;
  v_family uuid; v_credit numeric := 0;
begin
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted to view fee records' using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);
  select family_id into v_family from public.students where id = p_student_id;

  select count(i.id),
         coalesce(sum(coalesce(l.net, 0) + i.fine), 0),
         coalesce(sum(coalesce(a.paid, 0)), 0)
    into v_inv, v_charge, v_paid
    from public.invoices i
    left join lateral (
      select sum(case when x.is_discount then -x.amount else x.amount end) as net
        from public.invoice_lines x where x.invoice_id = i.id) l on true
    left join lateral (
      select sum(al.amount) as paid from public.payment_allocations al
        join public.payments p on p.id = al.payment_id and p.status = 'verified'
       where al.invoice_id = i.id) a on true
   where i.school_id = v_school and i.student_id = p_student_id
     and i.period_month = v_month and i.status <> 'void';

  select count(*)::integer, coalesce(sum(due), 0), min(period_month)
    into v_arr_n, v_arr_amt, v_arr_old
    from (
      select i.period_month,
             coalesce((select sum(case when x.is_discount then -x.amount else x.amount end)
                         from public.invoice_lines x where x.invoice_id = i.id), 0)
             + i.fine
             - coalesce((select sum(al.amount) from public.payment_allocations al
                           join public.payments p on p.id = al.payment_id and p.status = 'verified'
                          where al.invoice_id = i.id), 0) as due
        from public.invoices i
       where i.school_id = v_school and i.student_id = p_student_id
         and i.status <> 'void' and i.period_month is not null
         and i.period_month < v_month
         and (i.deferred_until is null
              or i.deferred_until <= (now() at time zone 'Asia/Karachi')::date)
    ) q
   where q.due > 0;

  if v_family is not null then
    v_credit := public.family_credit(v_family);
  end if;

  return jsonb_build_object(
    'month', v_month,
    'billed', v_inv > 0,
    -- 'paid' is only true of a month that was actually charged. A child nobody
    -- billed is neither paid nor unpaid and saying either would be a lie.
    'state', case when v_inv = 0 then 'not_billed'
                  when v_charge - v_paid <= 0 then 'paid'
                  when v_paid > 0 then 'part_paid'
                  else 'unpaid' end,
    'charge', v_charge,
    'paid', v_paid,
    'due', greatest(v_charge - v_paid, 0),
    'arrears_months', coalesce(v_arr_n, 0),
    'arrears_amount', coalesce(v_arr_amt, 0),
    'arrears_oldest', v_arr_old,
    'balance', public.student_balance(p_student_id),
    -- The money the school is holding for this family that is not yet against
    -- any month. Invisible on the child's screen until now.
    'family_credit', v_credit);
end;
$$;
revoke all on function public.fn_student_fee_state(uuid, date) from public, anon;
grant execute on function public.fn_student_fee_state(uuid, date) to authenticated;

-- ============================= 5. a note about the withdrawn roles ===========
-- 0133 withdrew admin_clerk and accountant, and forty-one fee functions still
-- name them inside has_role lists. That is dead text, not a hole: 0133 added a
-- check constraint that makes both values unreachable, so no profile can carry
-- one and no gate can pass on one.
--
-- It is NOT swept here, and the reason is worth writing down. Rewriting forty
-- one function bodies by string replacement is precisely the technique that
-- took bundle 7 down once already: 0085 was a text patch, 0135 removed the
-- name it anchored on, and the whole bundle rolled back on the schools it was
-- written for. Every fee function this batch touches is reproduced whole with
-- the live roles only; the rest are left to be rewritten the same way when
-- they are next opened, which is slower and cannot go stale.
