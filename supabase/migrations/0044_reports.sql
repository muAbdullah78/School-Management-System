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
