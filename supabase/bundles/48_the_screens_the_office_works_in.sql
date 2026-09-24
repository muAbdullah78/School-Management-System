-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0147_the_screens_the_office_works_in.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0147: the screens the office works in all day.
--
-- Step 2 of the redraw covers Attendance, Tests, Exams and Results, Fees and
-- Accounts. Reading them for the redraw found faults that no amount of colour
-- would have fixed, so this migration carries those first and the chart reads
-- second.
--
-- THE FAULTS
--
--   1. ACCOUNTS COUNTED A PAYMENT ON THE WRONG DAY. fn_finance_summary dated a
--      payment with created_at::date, which is the server's date, and Supabase
--      runs on UTC. A fee taken at 02:00 on the 1st in Karachi landed on the
--      last day of the previous month, so "this month" on Accounts was short
--      by every early-morning receipt on the 1st and long by the ones on the
--      1st of last month. fn_profit_snapshot measured "today" and "this month"
--      with current_date, the same UTC clock. 0107 and 0140 fixed this for
--      the register and the counter and these two were missed.
--
--   2. AN EXPENSE COULD BE DATED NEXT MONTH. Nothing refused a date after
--      today, so 24-10 typed for 24-09 moved Rs 40,000 of salaries into a
--      month that had not happened, and this month's profit rose by it.
--
--   3. A TEACHER COULD READ EVERY FAMILY'S FEES. Nine fee reads were gated on
--      is_staff(), which is every login that is not a parent. A class teacher
--      never sees the Fees screen, but the functions answered them directly:
--      the whole school's dues, the day's receipts, every father's phone
--      number. They now admit the roles that can open Fees and Students.
--
--   4. THE DUE DAY COULD FALL BEFORE THE BILLING DAY. "Raise on the 15th, due
--      on the 10th" was accepted, and every challan of every month was
--      overdue five days before it was issued.
--
--   5. A TEST COULD BE LOCKED WITH HALF THE CLASS UNMARKED. fn_lock_assessment
--      locked whatever was there, and a locked test cannot be edited, so the
--      three children the teacher had not reached yet were left with no mark
--      for ever. It now refuses and says how many are missing.
--
--   6. A LOCKED TEST COULD NEVER BE REOPENED, by anybody. The register has had
--      a reopen for the head since 0121. fn_unlock_assessment is the same
--      thing for a test: owner or principal, with a reason, recorded.
--
--   7. "SET BY: UNKNOWN" ON EVERY TEST. assessments.created_by has no default
--      and the screen that creates a test never sent it, so the head's
--      oversight list could not say whose test was late. A trigger now fills
--      it from the login that created the row. Old tests keep their null,
--      because inventing an author for them would be worse than saying so.
--
-- THE READS, all new objects beside the existing ones:
--
--   fn_attendance_overview(session, date)  each section's register for any
--                                          day, the school days before it,
--                                          and the children below 75 per cent
--                                          this session (the board-exam line).
--   fn_tests_marks(session, from, to)      how each test went: sat, absent,
--                                          class average, below the pass mark.
--   fn_paper_marks_count(exam_subject)     marks already entered on a paper,
--                                          so Remove can say what it deletes.
--   fn_fees_today()                        the day at the counter by method,
--                                          cleared and waiting.
--   fn_discounts_month(session, month)     what the month's concessions cost.
--   fn_finance_months(months)              income and spending month by month,
--                                          each computed by fn_finance_summary
--                                          itself, so no chart has its own
--                                          arithmetic.
--
-- Re-runnable: every object is create or replace, the trigger is dropped
-- before it is made, and the gate rewrite only touches a gate still written
-- the old way.
-- =============================================================================

-- ============================================== 1. accounts, in Karachi time ==

create or replace function public.fn_finance_summary(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_fee     numeric;
  v_dep     numeric;
  v_other   numeric;
  v_exp     numeric;
  v_by_cat  jsonb;
  v_school  uuid := public.current_school_id();
begin
  if not public.may_view('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to view finances';
  end if;

  -- Gross receipts: verified payments in the window. Reversals carry a negative
  -- amount, so a reversed payment removes itself automatically.
  --
  -- KARACHI, NOT THE SERVER (0147). created_at::date is the UTC date, and a
  -- fee taken before 05:00 in Pakistan belongs to the Pakistani day.
  select coalesce(sum(p.amount), 0) into v_fee
  from public.payments p
  where p.school_id = v_school and p.status = 'verified'
    and (p.created_at at time zone 'Asia/Karachi')::date between p_from and p_to;

  -- Of which REFUNDABLE: money the school holds and must give back. Counting
  -- it as income is what made a Rs 5,000 deposit into Rs 5,000 of profit.
  -- Matched by ALLOCATION against a deposit invoice, not by payment: a payment
  -- is not intrinsically a deposit, the invoice it settles is.
  select coalesce(sum(al.amount), 0) into v_dep
  from public.payment_allocations al
  join public.payments p on p.id = al.payment_id
  join public.invoices i on i.id = al.invoice_id
  where p.school_id = v_school and p.status = 'verified'
    and (p.created_at at time zone 'Asia/Karachi')::date between p_from and p_to
    and i.school_id = v_school and i.status <> 'void'
    and exists (
      select 1 from public.invoice_lines l
      join public.fee_heads h on h.id = l.fee_head_id
      where l.invoice_id = i.id and h.is_refundable);

  select coalesce(sum(o.amount), 0) into v_other
  from public.other_income o
  where o.school_id = v_school and o.received_on between p_from and p_to;

  select coalesce(sum(e.amount), 0) into v_exp
  from public.expenses e
  where e.school_id = v_school and e.spent_on between p_from and p_to;

  select coalesce(jsonb_agg(x order by x.total desc), '[]'::jsonb) into v_by_cat
  from (
    select coalesce(c.name, 'Uncategorised') as category,
           sum(e.amount) as total
    from public.expenses e
    left join public.expense_categories c on c.id = e.category_id
    where e.school_id = v_school and e.spent_on between p_from and p_to
    group by 1
    having sum(e.amount) <> 0
  ) x;

  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    'fee_income', v_fee - v_dep,
    'fee_receipts_gross', v_fee,
    'deposits_collected', v_dep,
    'other_income', v_other,
    'total_income', v_fee - v_dep + v_other,
    'expenses', v_exp,
    'profit', v_fee - v_dep + v_other - v_exp,
    'expenses_by_category', v_by_cat);
end;
$$;
revoke all on function public.fn_finance_summary(date, date) from public, anon;
grant execute on function public.fn_finance_summary(date, date) to authenticated;

create or replace function public.fn_profit_snapshot()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Karachi')::date;
  v_t jsonb; v_m jsonb; v_y jsonb;
begin
  if not public.may_view('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to view finances';
  end if;
  v_t := public.fn_finance_summary(v_today, v_today);
  v_m := public.fn_finance_summary(date_trunc('month', v_today)::date, v_today);
  v_y := public.fn_finance_summary(date_trunc('year', v_today)::date, v_today);
  return jsonb_build_object('today', v_t, 'month', v_m, 'year', v_y);
end;
$$;
revoke all on function public.fn_profit_snapshot() from public, anon;
grant execute on function public.fn_profit_snapshot() to authenticated;

-- Month by month, for the chart on Accounts. Each month IS fn_finance_summary
-- for that month, so a bar cannot disagree with the tile above it.
create or replace function public.fn_finance_months(p_months integer default 12)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Karachi')::date;
  v_n     integer := greatest(1, least(coalesce(p_months, 12), 24));
  v_start date;
  v_end   date;
  v_s     jsonb;
  v_out   jsonb := '[]'::jsonb;
  v_i     integer;
begin
  if not public.may_view('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to view finances' using errcode = '42501';
  end if;
  for v_i in reverse (v_n - 1) .. 0 loop
    v_start := (date_trunc('month', v_today) - make_interval(months => v_i))::date;
    v_end   := least((v_start + interval '1 month' - interval '1 day')::date, v_today);
    v_s     := public.fn_finance_summary(v_start, v_end);
    v_out   := v_out || jsonb_build_array(jsonb_build_object(
                 'month',        v_start,
                 'fee_income',   v_s->'fee_income',
                 'other_income', v_s->'other_income',
                 'total_income', v_s->'total_income',
                 'expenses',     v_s->'expenses',
                 'profit',       v_s->'profit'));
  end loop;
  return v_out;
end;
$$;
revoke all on function public.fn_finance_months(integer) from public, anon;
grant execute on function public.fn_finance_months(integer) to authenticated;

-- Money cannot have been spent or received tomorrow. Everything else about
-- these two is as 0130 left it.
create or replace function public.fn_record_expense(
  p_amount numeric, p_category_id uuid, p_spent_on date default null,
  p_payee text default null, p_method public.payment_method default 'cash',
  p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_no bigint;
  v_today date := (now() at time zone 'Asia/Karachi')::date;
  v_on    date := coalesce(p_spent_on, (now() at time zone 'Asia/Karachi')::date);
begin
  if not public.has_role('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to record expenses';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Expense amount must be positive (use a reversal to correct a mistake)';
  end if;
  if p_category_id is not null then
    perform public.assert_own('expense_categories', p_category_id);
  end if;
  -- The calendar check FIRST: a mistyped 2062 is told the school's own span
  -- of years (0130), which says what went wrong better than "after today".
  perform public.fn__assert_date_in_calendar(v_on, 'Recording an expense');
  if v_on > v_today then
    raise exception 'An expense cannot be dated after today (%). Record it on the day the money is paid.',
      to_char(v_today, 'DD Mon YYYY')
      using errcode = '22008';
  end if;
  v_no := public.next_counter('expense_voucher');
  insert into public.expenses (spent_on, category_id, amount, payee, method, note,
                               voucher_no, recorded_by)
  values (v_on, p_category_id, p_amount, p_payee,
          coalesce(p_method, 'cash'), p_note, v_no, auth.uid())
  returning id into v_id;

  return jsonb_build_object('expense_id', v_id, 'voucher_no', v_no);
end;
$$;
revoke all on function public.fn_record_expense(numeric, uuid, date, text, public.payment_method, text) from public, anon;
grant execute on function public.fn_record_expense(numeric, uuid, date, text, public.payment_method, text) to authenticated;

create or replace function public.fn_record_other_income(
  p_amount numeric, p_source text, p_received_on date default null,
  p_method public.payment_method default 'cash', p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_no bigint;
  v_today date := (now() at time zone 'Asia/Karachi')::date;
  v_on    date := coalesce(p_received_on, (now() at time zone 'Asia/Karachi')::date);
begin
  if not public.has_role('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to record income';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Income amount must be positive';
  end if;
  if p_source is null or btrim(p_source) = '' then
    raise exception 'Non-fee income needs a source (this is not fee collection)';
  end if;
  perform public.fn__assert_date_in_calendar(v_on, 'Recording income');
  if v_on > v_today then
    raise exception 'Income cannot be dated after today (%). Record it on the day the money arrives.',
      to_char(v_today, 'DD Mon YYYY')
      using errcode = '22008';
  end if;
  v_no := public.next_counter('income_voucher');
  insert into public.other_income (received_on, source, amount, method, note,
                                   voucher_no, recorded_by)
  values (v_on, btrim(p_source), p_amount,
          coalesce(p_method, 'cash'), p_note, v_no, auth.uid())
  returning id into v_id;

  return jsonb_build_object('income_id', v_id, 'voucher_no', v_no);
end;
$$;
revoke all on function public.fn_record_other_income(numeric, text, date, public.payment_method, text) from public, anon;
grant execute on function public.fn_record_other_income(numeric, text, date, public.payment_method, text) to authenticated;

-- ===================================== 2. the fee reads, for the fee office ==
-- REWRITTEN IN PLACE, NOT RETYPED. Retyping nine bodies to change one line is
-- how a stack of earlier fixes gets reverted, so each definition is read from
-- the catalogue and only its gate is replaced. The pattern uses \s+ rather
-- than any newline, per supabase/check-patch-anchors.py.
--
-- The roles admitted are the ones that can open Fees or Students
-- (web/src/navigation.ts), through may_view so an observer keeps reading, per
-- 0059. A gate already rewritten is left alone, so this re-runs as a no-op.
do $gate$
declare
  v_names text[] := array[
    'fn_class_dues', 'fn_recent_payments', 'fn_counter_summary',
    'fn_report_unpaid_invoices', 'fn_challan', 'fn_challans_for_class',
    'fn_challan_months', 'fn_student_list'];
  v_name text;
  v_oid  oid;
  v_def  text;
  v_new  text;
  v_done integer := 0;
begin
  foreach v_name in array v_names loop
    for v_oid in
      select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = v_name
    loop
      v_def := pg_get_functiondef(v_oid);
      if v_def !~ 'if\s+not\s+public\.is_staff\(\)\s+then' then
        continue;
      end if;
      v_new := regexp_replace(
        v_def,
        'if\s+not\s+public\.is_staff\(\)\s+then',
        'if not public.may_view(''owner'', ''principal'', ''admin_clerk'', ''accountant'') then');
      execute v_new;
      v_done := v_done + 1;
    end loop;
  end loop;
  raise notice '0147: % fee read(s) now answer only the fee office', v_done;
end
$gate$;

-- ================================================ 3. the billing and due day ==
create or replace function public.fn_set_billing_days(
  p_billing_day integer, p_due_day integer, p_auto_bill boolean
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Not permitted to change fee settings' using errcode = '42501';
  end if;
  if p_billing_day is null or p_billing_day < 1 or p_billing_day > 31
     or p_due_day is null or p_due_day < 1 or p_due_day > 31 then
    raise exception 'The billing day and the due day are days of the month, 1 to 31.'
      using errcode = '22023';
  end if;
  -- 0147. Due before it is raised means every challan is overdue on the day it
  -- is issued, every month, for every family.
  if p_due_day < p_billing_day then
    raise exception 'The fee cannot fall due (day %) before it is raised (day %). Make the due day the same as the billing day or later.',
      p_due_day, p_billing_day
      using errcode = '22023';
  end if;

  update public.school_settings
     set billing_day = p_billing_day, due_day = p_due_day,
         auto_bill = coalesce(p_auto_bill, true)
   where school_id = v_school;

  return jsonb_build_object('billing_day', p_billing_day, 'due_day', p_due_day,
                            'auto_bill', coalesce(p_auto_bill, true));
end;
$$;

-- ================================================ 4. the day at the counter ==
-- Cleared money by method, and what is waiting on a bank. "Today" is Karachi's.
create or replace function public.fn_fees_today()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_today  date := (now() at time zone 'Asia/Karachi')::date;
  v_by     jsonb;
  v_total  numeric;
  v_count  integer;
  v_pend_n integer;
  v_pend   numeric;
begin
  if v_school is null
     or not public.may_view('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to view fee records' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'method', x.method, 'receipts', x.receipts, 'amount', x.amount)
           order by x.amount desc), '[]'::jsonb),
         coalesce(sum(x.amount), 0), coalesce(sum(x.receipts), 0)
    into v_by, v_total, v_count
    from (
      select p.method::text as method,
             count(*) filter (where p.reversal_of is null)::int as receipts,
             sum(p.amount) as amount
        from public.payments p
       where p.school_id = v_school and p.status = 'verified'
         and (p.created_at at time zone 'Asia/Karachi')::date = v_today
       group by p.method
    ) x;

  select count(*)::int, coalesce(sum(p.amount), 0) into v_pend_n, v_pend
    from public.payments p
   where p.school_id = v_school and p.status = 'pending';

  return jsonb_build_object(
    'today', v_today,
    'cleared_total', v_total, 'cleared_receipts', v_count,
    'by_method', v_by,
    'pending_count', v_pend_n, 'pending_total', v_pend);
end;
$$;
revoke all on function public.fn_fees_today() from public, anon;
grant execute on function public.fn_fees_today() to authenticated;

-- What the concessions cost this month, in rupees: the discount lines on the
-- month's challans. This is the figure the head asks for, "what am I giving
-- away", which a list of percentages cannot answer.
create or replace function public.fn_discounts_month(p_session_id uuid, p_month date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_month  date := date_trunc('month', coalesce(p_month, (now() at time zone 'Asia/Karachi')::date))::date;
  v_amount numeric;
  v_kids   integer;
  v_gross  numeric;
begin
  if v_school is null
     or not public.may_view('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to view fee records' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  select coalesce(sum(l.amount) filter (where l.is_discount), 0),
         count(distinct i.student_id) filter (where l.is_discount),
         coalesce(sum(l.amount) filter (where not l.is_discount), 0)
    into v_amount, v_kids, v_gross
    from public.invoices i
    join public.invoice_lines l on l.invoice_id = i.id
   where i.school_id = v_school and i.session_id = p_session_id
     and i.period_month = v_month and i.status <> 'void';

  return jsonb_build_object('month', v_month, 'amount', v_amount,
                            'children', v_kids, 'gross', v_gross);
end;
$$;
revoke all on function public.fn_discounts_month(uuid, date) from public, anon;
grant execute on function public.fn_discounts_month(uuid, date) to authenticated;

-- =========================================================== 5. attendance ==
create or replace function public.fn_attendance_overview(p_session_id uuid, p_date date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school   uuid := public.current_school_id();
  v_today    date := (now() at time zone 'Asia/Karachi')::date;
  v_date     date := coalesce(p_date, (now() at time zone 'Asia/Karachi')::date);
  v_starts   date;
  v_sections jsonb;
  v_trend    jsonb;
  v_watch    jsonb;
begin
  if v_school is null or not public.may_view('owner', 'principal') then
    raise exception 'Only the head, the owner or an observer may read the whole school''s register at once'
      using errcode = '42501';
  end if;
  select s.starts_on into v_starts
    from public.academic_sessions s
   where s.id = p_session_id and s.school_id = v_school;
  if not found then
    raise exception 'Unknown academic year for this school' using errcode = '42501';
  end if;
  if v_date > v_today then
    raise exception 'That day has not happened yet' using errcode = '22008';
  end if;

  -- Each section on the day, with the tally. Same roll as fn_attendance_day
  -- (active enrolments in the session), so the counts on a class card and the
  -- "12 of 30 marked" beside them are one set of children.
  select coalesce(jsonb_agg(jsonb_build_object(
           'class_id', x.class_id, 'section_id', x.section_id,
           'pupils', x.pupils, 'marked', x.marked,
           'present', x.present, 'late', x.late, 'half_day', x.half_day,
           'leave', x.leave, 'absent', x.absent,
           'pct', public.fn__attendance_pct(x.present, x.late, x.half_day, x.marked))
         order by x.level_order, x.class_name, x.section_name nulls first), '[]'::jsonb)
    into v_sections
    from (
      select c.id as class_id, c.name as class_name, c.level_order,
             sec.id as section_id, sec.name as section_name,
             count(*)::int as pupils,
             count(ad.id)::int as marked,
             count(*) filter (where ad.status = 'present')::int  as present,
             count(*) filter (where ad.status = 'late')::int     as late,
             count(*) filter (where ad.status = 'half_day')::int as half_day,
             count(*) filter (where ad.status = 'leave')::int    as leave,
             count(*) filter (where ad.status = 'absent')::int   as absent
        from public.enrollments e
        join public.classes c on c.id = e.class_id
        left join public.sections sec on sec.id = e.section_id
        left join public.attendance_daily ad on ad.enrollment_id = e.id
                                            and ad.attendance_date = v_date
       where e.school_id = v_school and e.session_id = p_session_id
         and e.status = 'active'
       group by c.id, c.name, c.level_order, sec.id, sec.name
    ) x;

  -- The twenty school days up to and including the day asked about. A school
  -- day is a date with any register marked, so a Sunday is not a zero.
  select coalesce(jsonb_agg(jsonb_build_object(
           'date', d.attendance_date, 'marked', d.marked,
           'present', d.present, 'late', d.late, 'half_day', d.half_day,
           'leave', d.leave, 'absent', d.absent,
           'pct', public.fn__attendance_pct(d.present, d.late, d.half_day, d.marked))
         order by d.attendance_date), '[]'::jsonb)
    into v_trend
    from (
      select ad.attendance_date,
             count(*)::int as marked,
             count(*) filter (where ad.status = 'present')::int  as present,
             count(*) filter (where ad.status = 'late')::int     as late,
             count(*) filter (where ad.status = 'half_day')::int as half_day,
             count(*) filter (where ad.status = 'leave')::int    as leave,
             count(*) filter (where ad.status = 'absent')::int   as absent
        from public.attendance_daily ad
        join public.enrollments e on e.id = ad.enrollment_id
                                 and e.school_id = v_school
                                 and e.session_id = p_session_id
                                 and e.status = 'active'
       where ad.school_id = v_school
         and ad.attendance_date <= v_date
       group by ad.attendance_date
       order by ad.attendance_date desc
       limit 20
    ) d;

  -- Below 75 per cent this session, the line a board exam draws. Ten marked
  -- days at least, or one absence in the first week puts a child on a list
  -- the office will act on.
  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id', w.student_id, 'full_name', w.full_name, 'gr_no', w.gr_no,
           'class_name', w.class_name, 'section_name', w.section_name,
           'marked', w.marked, 'present', w.present, 'late', w.late,
           'half_day', w.half_day, 'leave', w.leave, 'absent', w.absent,
           'pct', w.pct)
         order by w.pct, w.full_name), '[]'::jsonb)
    into v_watch
    from (
      select s.id as student_id, s.full_name, s.gr_no,
             c.name as class_name, sec.name as section_name,
             count(*)::int as marked,
             count(*) filter (where ad.status = 'present')::int  as present,
             count(*) filter (where ad.status = 'late')::int     as late,
             count(*) filter (where ad.status = 'half_day')::int as half_day,
             count(*) filter (where ad.status = 'leave')::int    as leave,
             count(*) filter (where ad.status = 'absent')::int   as absent,
             public.fn__attendance_pct(
               count(*) filter (where ad.status = 'present')::int,
               count(*) filter (where ad.status = 'late')::int,
               count(*) filter (where ad.status = 'half_day')::int,
               count(*)::int) as pct
        from public.enrollments e
        join public.students s on s.id = e.student_id and s.school_id = v_school
                              and s.status = 'active' and s.deleted_at is null
        join public.classes c on c.id = e.class_id
        left join public.sections sec on sec.id = e.section_id
        join public.attendance_daily ad on ad.enrollment_id = e.id
                                       and ad.attendance_date <= v_date
                                       and (v_starts is null or ad.attendance_date >= v_starts)
       where e.school_id = v_school and e.session_id = p_session_id
         and e.status = 'active'
       group by s.id, s.full_name, s.gr_no, c.name, sec.name
      having count(*) >= 10
    ) w
   where w.pct < 75
   limit 50;

  return jsonb_build_object(
    'date', v_date, 'today', v_today,
    'sections', v_sections, 'trend', v_trend, 'watchlist', v_watch);
end;
$$;
revoke all on function public.fn_attendance_overview(uuid, date) from public, anon;
grant execute on function public.fn_attendance_overview(uuid, date) to authenticated;

-- ================================================================ 6. tests ==

-- Who set it. Filled from the login that made the row, and only when the
-- caller did not say, so an import that carries its own author keeps it.
create or replace function public.fn__assessment_set_by()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.created_by is null then
    new.created_by := auth.uid();
  end if;
  return new;
end;
$$;
revoke all on function public.fn__assessment_set_by() from public, anon, authenticated;

drop trigger if exists trg_assessment_set_by on public.assessments;
create trigger trg_assessment_set_by
  before insert on public.assessments
  for each row execute function public.fn__assessment_set_by();

create or replace function public.fn_lock_assessment(p_assessment_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session uuid; v_class uuid; v_section uuid; v_subject uuid;
  v_marks integer; v_missing integer;
begin
  if not public.has_role('owner','class_teacher','subject_teacher') then
    raise exception 'A test is locked by the teacher who marked it.'
      using errcode = '42501';
  end if;
  perform public.assert_own('assessments', p_assessment_id);
  select session_id, class_id, section_id, subject_id
    into v_session, v_class, v_section, v_subject
  from public.assessments where id = p_assessment_id;
  if v_session is null then raise exception 'Assessment not found'; end if;
  -- fn_may_set_a_test, not fn_may_manage_class: locking a test is finishing
  -- it, and the person who may finish it is the person who could mark it.
  if not public.fn_may_set_a_test(v_session, v_class, v_section, v_subject) then
    raise exception 'You can only lock a test for a class and subject you teach';
  end if;

  -- 0147. Every child on the class list has a mark or is marked absent, or it
  -- is not finished. Counted over the same roll the head's overview counts,
  -- so "25 of 25 marked" and "lockable" are one fact.
  select count(*) into v_missing
    from public.enrollments e
   where e.school_id = public.current_school_id()
     and e.session_id = v_session
     and e.class_id = v_class
     and (v_section is null or e.section_id = v_section)
     and e.status = 'active'
     and not exists (
       select 1 from public.mark_entries me
        where me.assessment_id = p_assessment_id and me.enrollment_id = e.id
          and (me.marks is not null or me.is_absent));
  if v_missing > 0 then
    raise exception 'This test cannot be locked yet: % child(ren) on the class list have no mark and are not marked absent. Give each a mark or tick Absent, then lock it.',
      v_missing
      using errcode = '22023';
  end if;

  select count(*) into v_marks from public.mark_entries
   where assessment_id = p_assessment_id and not is_locked;

  update public.mark_entries set is_locked = true where assessment_id = p_assessment_id;
  update public.assessments set is_locked = true where id = p_assessment_id;

  if v_marks > 0 then
    insert into public.audit_log (
      school_id, actor, actor_role, action, entity, entity_id, before, after)
    values (
      public.current_school_id(), auth.uid(),
      (select role from public.profiles where id = auth.uid()),
      'ASSESSMENT_LOCK', 'assessments', p_assessment_id::text,
      jsonb_build_object('locked', false),
      jsonb_build_object('locked', true, 'marks', v_marks,
                         'session_id', v_session, 'class_id', v_class,
                         'section_id', v_section));
  end if;
end;
$$;
revoke all on function public.fn_lock_assessment(uuid) from public, anon;
grant execute on function public.fn_lock_assessment(uuid) to authenticated;

-- The head's reopen, the register's twin (0121). With a reason, on the record.
create or replace function public.fn_unlock_assessment(p_assessment_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_marks integer;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or the principal can reopen a locked test'
      using errcode = '42501';
  end if;
  perform public.assert_own('assessments', p_assessment_id);
  if p_reason is null or length(btrim(p_reason)) < 4 then
    raise exception 'Say in a few words why the test is being reopened. It is kept with the test.'
      using errcode = '22023';
  end if;
  if not exists (select 1 from public.assessments
                  where id = p_assessment_id and is_locked) then
    raise exception 'This test is not locked, so there is nothing to reopen'
      using errcode = '22023';
  end if;

  update public.mark_entries set is_locked = false
   where assessment_id = p_assessment_id and is_locked;
  get diagnostics v_marks = row_count;
  update public.assessments set is_locked = false where id = p_assessment_id;

  insert into public.audit_log (
    school_id, actor, actor_role, action, entity, entity_id, before, after)
  values (
    public.current_school_id(), auth.uid(),
    (select role from public.profiles where id = auth.uid()),
    'ASSESSMENT_UNLOCK', 'assessments', p_assessment_id::text,
    jsonb_build_object('locked', true),
    jsonb_build_object('locked', false, 'marks', v_marks, 'reason', btrim(p_reason)));

  return jsonb_build_object('assessment_id', p_assessment_id, 'marks', v_marks);
end;
$$;
revoke all on function public.fn_unlock_assessment(uuid, text) from public, anon;
grant execute on function public.fn_unlock_assessment(uuid, text) to authenticated;

-- How each test went. Same window and same gate as fn_tests_overview, and the
-- same roll, so a test reads "25 of 25 marked, average 64" off one set.
create or replace function public.fn_tests_marks(p_session_id uuid, p_from date, p_to date)
returns table(assessment_id uuid, sat integer, absent integer, avg_pct numeric,
              below_pass integer, top_pct numeric, pass_pct numeric)
language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_pass   numeric;
begin
  if not public.may_view('owner', 'principal') then
    raise exception 'Only the head, the owner or an observer may see every teacher''s tests'
      using errcode = '42501';
  end if;
  if not exists (select 1 from public.academic_sessions s
                  where s.id = p_session_id and s.school_id = v_school) then
    raise exception 'Unknown academic year for this school' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Give a start date and an end date, in that order';
  end if;
  if p_to - p_from > 400 then
    raise exception 'Ask for a year at a time or less';
  end if;
  select ss.pass_percent into v_pass from public.school_settings ss where ss.school_id = v_school;
  v_pass := coalesce(v_pass, 33);

  return query
  select a.id,
         count(*) filter (where me.marks is not null and not me.is_absent)::int,
         count(*) filter (where me.is_absent)::int,
         case when a.max_marks <= 0 then null
              else round(100.0 * avg(me.marks) filter (where me.marks is not null and not me.is_absent)
                         / a.max_marks, 1) end,
         case when a.max_marks <= 0 then 0
              else count(*) filter (where me.marks is not null and not me.is_absent
                                      and me.marks < a.max_marks * v_pass / 100.0)::int end,
         case when a.max_marks <= 0 then null
              else round(100.0 * max(me.marks) filter (where me.marks is not null and not me.is_absent)
                         / a.max_marks, 1) end,
         v_pass
    from public.assessments a
    join public.enrollments e on e.school_id = a.school_id
                             and e.session_id = a.session_id
                             and e.class_id = a.class_id
                             and (a.section_id is null or e.section_id = a.section_id)
                             and e.status = 'active'
    left join public.mark_entries me on me.assessment_id = a.id and me.enrollment_id = e.id
   where a.school_id = v_school
     and a.session_id = p_session_id
     and a.assessment_date between p_from and p_to
   group by a.id, a.max_marks;
end;
$$;
revoke all on function public.fn_tests_marks(uuid, date, date) from public, anon;
grant execute on function public.fn_tests_marks(uuid, date, date) to authenticated;

-- ================================================================ 7. exams ==
-- What Remove on a paper would take with it. Deleting a paper cascades its
-- unlocked marks (0129 refuses only locked ones), and the button used to say
-- nothing about that.
create or replace function public.fn_paper_marks_count(p_exam_subject_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_marks integer; v_locked integer;
begin
  if not public.may_view('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('exam_subjects', p_exam_subject_id);
  select count(*) filter (where me.marks is not null or me.is_absent)::int,
         count(*) filter (where me.is_locked)::int
    into v_marks, v_locked
    from public.mark_entries me
   where me.exam_subject_id = p_exam_subject_id
     and me.school_id = public.current_school_id();
  return jsonb_build_object('marks', v_marks, 'locked', v_locked);
end;
$$;
revoke all on function public.fn_paper_marks_count(uuid) from public, anon;
grant execute on function public.fn_paper_marks_count(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0147_the_screens_the_office_works_in.sql', '48_the_screens_the_office_works_in.sql');
end $ledger$;
