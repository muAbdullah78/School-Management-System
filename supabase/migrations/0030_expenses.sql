-- =============================================================================
-- Expenses, other income, and the profit figure.
--
-- Until now the system tracked money coming IN and nothing going OUT, so it
-- could not answer the first question a school owner asks: "did we make money
-- this month?" An owner-focused product that cannot show profit is a
-- contradiction, so this closes it.
--
-- THE RULE THAT MAKES THIS TRUSTWORTHY:
--
--   Fee income is DERIVED from verified payments and can never be typed in.
--
-- There is deliberately no "add fee income" function. The only way fee income
-- exists is that a receipt was issued against a real invoice, which means the
-- income line on a profit report cannot be inflated by anyone — including the
-- owner. `other_income` exists for genuinely non-fee money (canteen rent, a
-- van hire, a book sale) and is reported on its own line, never merged into
-- fee income, so the two can always be told apart.
--
-- Salaries are an expense CATEGORY, not a payroll module. That gives an honest
-- profit number — salaries are 60-70% of a school's costs — without building
-- payroll, which is out of scope.
--
-- Append-only, like payments: nothing is edited or deleted. A mistake is
-- corrected by a reversal that writes a compensating row with a reason. The
-- competitor's product has a "Deleted Fees" screen and a recycle bin; a
-- deletable financial record is a hole in an accounting system and we are not
-- copying it.
-- =============================================================================

-- ===========================================================================
-- 1. Categories
-- ===========================================================================

create table public.expense_categories (
  id         uuid primary key default gen_random_uuid(),
  school_id  uuid not null references public.schools(id) on delete cascade,
  name       text not null,
  sort_order integer not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index uq_expense_cat_school_name on public.expense_categories (school_id, lower(name));
create index idx_expense_cat_school on public.expense_categories (school_id);

-- ===========================================================================
-- 2. The ledgers
-- ===========================================================================

create table public.expenses (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references public.schools(id) on delete cascade,
  spent_on    date not null default current_date,
  category_id uuid references public.expense_categories(id),
  amount      numeric(12,2) not null,
  payee       text,
  method      public.payment_method not null default 'cash',
  note        text,
  voucher_no  bigint,                                    -- gapless, per school
  recorded_by uuid references public.profiles(id),
  reversal_of uuid references public.expenses(id),
  created_at  timestamptz not null default now()
);
create index idx_expenses_school_date on public.expenses (school_id, spent_on);
create index idx_expenses_category on public.expenses (category_id);

create table public.other_income (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references public.schools(id) on delete cascade,
  received_on date not null default current_date,
  source      text not null,
  amount      numeric(12,2) not null,
  method      public.payment_method not null default 'cash',
  note        text,
  voucher_no  bigint,
  recorded_by uuid references public.profiles(id),
  reversal_of uuid references public.other_income(id),
  created_at  timestamptz not null default now()
);
create index idx_other_income_school_date on public.other_income (school_id, received_on);

-- ===========================================================================
-- 3. Tenant plumbing
-- ===========================================================================

do $$
declare t text;
begin
  foreach t in array array['expense_categories', 'expenses', 'other_income'] loop
    execute format(
      'create trigger trg_%1$s_school before insert or update on public.%1$s
         for each row execute function public.enforce_school_id();', t);
    execute format(
      'create trigger trg_audit_%1$s after insert or update or delete on public.%1$s
         for each row execute function public.audit_trigger();', t);
    execute format('alter table public.%I enable row level security;', t);
  end loop;
end $$;

-- Money out is finance-only to read and owner/principal/accountant to write.
-- Teachers have no business seeing the school's cost base.
create policy expense_cat_select on public.expense_categories for select to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'accountant', 'admin_clerk'));
create policy expense_cat_write on public.expense_categories for all to authenticated
  using (school_id = public.current_school_id() and public.has_role('owner', 'principal'))
  with check (school_id = public.current_school_id() and public.has_role('owner', 'principal'));

create policy expenses_select on public.expenses for select to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'accountant'));
-- No INSERT/UPDATE/DELETE policy at all: writes go exclusively through the
-- SECURITY DEFINER functions below, so every row gets a gapless voucher number
-- and an audit trail. A direct insert would bypass both.

create policy other_income_select on public.other_income for select to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'accountant'));

-- ===========================================================================
-- 4. Default categories for every school, existing and future
-- ===========================================================================

create or replace function public.fn__seed_expense_categories(p_school uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.expense_categories (school_id, name, sort_order)
  values
    (p_school, 'Salaries',       1),
    (p_school, 'Rent',           2),
    (p_school, 'Utilities',      3),
    (p_school, 'Maintenance',    4),
    (p_school, 'Stationery',     5),
    (p_school, 'Examination',    6),
    (p_school, 'Marketing',      7),
    (p_school, 'Other',          99)
  on conflict do nothing;
end;
$$;

do $$
declare s record;
begin
  for s in select id from public.schools loop
    perform public.fn__seed_expense_categories(s.id);
  end loop;
end $$;

-- New schools get them at provisioning time.
create or replace function public.fn_provision_expense_categories() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.fn__seed_expense_categories(new.id);
  return new;
end;
$$;

create trigger trg_schools_expense_cats after insert on public.schools
  for each row execute function public.fn_provision_expense_categories();

-- ===========================================================================
-- 5. Recording money out / non-fee money in
-- ===========================================================================

create or replace function public.fn_record_expense(
  p_amount numeric, p_category_id uuid, p_spent_on date default current_date,
  p_payee text default null, p_method public.payment_method default 'cash',
  p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_no bigint;
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

  v_no := public.next_counter('expense_voucher');
  insert into public.expenses (spent_on, category_id, amount, payee, method, note,
                               voucher_no, recorded_by)
  values (coalesce(p_spent_on, current_date), p_category_id, p_amount, p_payee,
          coalesce(p_method, 'cash'), p_note, v_no, auth.uid())
  returning id into v_id;

  return jsonb_build_object('expense_id', v_id, 'voucher_no', v_no);
end;
$$;

create or replace function public.fn_reverse_expense(p_expense_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_orig record; v_id uuid; v_no bigint;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may reverse an expense';
  end if;
  perform public.assert_own('expenses', p_expense_id);
  select * into v_orig from public.expenses where id = p_expense_id;
  if not found then raise exception 'Expense not found'; end if;
  if v_orig.reversal_of is not null then raise exception 'Cannot reverse a reversal'; end if;
  if exists (select 1 from public.expenses where reversal_of = p_expense_id) then
    raise exception 'Expense already reversed';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reversal needs a reason';
  end if;

  v_no := public.next_counter('expense_voucher');
  insert into public.expenses (spent_on, category_id, amount, payee, method, note,
                               voucher_no, recorded_by, reversal_of)
  values (current_date, v_orig.category_id, -v_orig.amount, v_orig.payee, v_orig.method,
          p_reason, v_no, auth.uid(), p_expense_id)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.fn_record_other_income(
  p_amount numeric, p_source text, p_received_on date default current_date,
  p_method public.payment_method default 'cash', p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_no bigint;
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

  v_no := public.next_counter('income_voucher');
  insert into public.other_income (received_on, source, amount, method, note,
                                   voucher_no, recorded_by)
  values (coalesce(p_received_on, current_date), btrim(p_source), p_amount,
          coalesce(p_method, 'cash'), p_note, v_no, auth.uid())
  returning id into v_id;

  return jsonb_build_object('income_id', v_id, 'voucher_no', v_no);
end;
$$;

create or replace function public.fn_reverse_other_income(p_income_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_orig record; v_id uuid; v_no bigint;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may reverse income';
  end if;
  perform public.assert_own('other_income', p_income_id);
  select * into v_orig from public.other_income where id = p_income_id;
  if not found then raise exception 'Income entry not found'; end if;
  if v_orig.reversal_of is not null then raise exception 'Cannot reverse a reversal'; end if;
  if exists (select 1 from public.other_income where reversal_of = p_income_id) then
    raise exception 'Income entry already reversed';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reversal needs a reason';
  end if;

  v_no := public.next_counter('income_voucher');
  insert into public.other_income (received_on, source, amount, method, note,
                                   voucher_no, recorded_by, reversal_of)
  values (current_date, v_orig.source, -v_orig.amount, v_orig.method, p_reason,
          v_no, auth.uid(), p_income_id)
  returning id into v_id;
  return v_id;
end;
$$;

-- ===========================================================================
-- 6. The profit picture
--
-- Cash basis, which is what a school owner means. "Income today" is money that
-- physically arrived today, not fees that were billed today — a challan issued
-- is not money.
-- ===========================================================================

create or replace function public.fn_finance_summary(p_from date, p_to date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_fee     numeric;
  v_other   numeric;
  v_exp     numeric;
  v_by_cat  jsonb;
  v_school  uuid := public.current_school_id();
begin
  if not public.has_role('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to view finances';
  end if;

  -- Fee income: verified payments in the window. Reversals carry a negative
  -- amount, so a reversed payment removes itself from income automatically.
  select coalesce(sum(p.amount), 0) into v_fee
  from public.payments p
  where p.school_id = v_school and p.status = 'verified'
    and p.created_at::date between p_from and p_to;

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
    'fee_income', v_fee,
    'other_income', v_other,
    'total_income', v_fee + v_other,
    'expenses', v_exp,
    'profit', v_fee + v_other - v_exp,
    'by_category', v_by_cat);
end;
$$;

-- The three figures a dashboard shows without asking for a date range.
create or replace function public.fn_profit_snapshot()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_today jsonb; v_month jsonb; v_year jsonb;
begin
  if not public.has_role('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to view finances';
  end if;
  v_today := public.fn_finance_summary(current_date, current_date);
  v_month := public.fn_finance_summary(date_trunc('month', current_date)::date, current_date);
  v_year  := public.fn_finance_summary(date_trunc('year', current_date)::date, current_date);
  return jsonb_build_object('today', v_today, 'month', v_month, 'year', v_year);
end;
$$;

-- ===========================================================================
-- 7. Grants
-- ===========================================================================

grant execute on function public.fn_record_expense(numeric, uuid, date, text, public.payment_method, text) to authenticated;
grant execute on function public.fn_reverse_expense(uuid, text) to authenticated;
grant execute on function public.fn_record_other_income(numeric, text, date, public.payment_method, text) to authenticated;
grant execute on function public.fn_reverse_other_income(uuid, text) to authenticated;
grant execute on function public.fn_finance_summary(date, date) to authenticated;
grant execute on function public.fn_profit_snapshot() to authenticated;

-- Seeding is internal: it takes a school_id and writes rows into it.
revoke all on function public.fn__seed_expense_categories(uuid) from public, anon, authenticated;
