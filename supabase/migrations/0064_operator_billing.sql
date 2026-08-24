-- =============================================================================
-- 0064 — The operator had no books
--
-- This product's central promise to a school is that every rupee has a row. The
-- person SELLING the software kept no such rows about the schools.
--
-- Reproduced on a real database. Three customer schools; Al-Noor renews twelve
-- months of `growth`:
--
--   select fn_activate_subscription(<al-noor>, 'growth', 12);
--   → {"period_start": "2027-07-26", "period_end": "2028-07-25", ...}
--
--   what was Al-Noor charged? ......... no table records a charge to a school
--   how much has Al-Noor ever paid? ... no function answers it
--   which schools owe us money? ....... unanswerable
--   what did we invoice this month? ... `plans` holds a price list, nothing else
--   who granted it, and when? ......... nothing records the actor; audit_log had
--                                       zero rows for the renewal
--
-- The subtle one is "which schools owe us money". The console shows `days_left`,
-- so it LOOKS like it answers that — but a school that renewed on trust and
-- never paid is indistinguishable from one that paid in full. Both show 335 days
-- left. The receivable is invisible precisely because the screen looks like it is
-- showing it.
--
-- And a revenue leak found in the same probe: Al-Noor is on `growth` (limit 300)
-- with 420 students. The console itself computes limit_state = 'over' and
-- suggested_plan = 'institution' — and the renewal put it back on `growth` for
-- another year at the 300-student price. The screen knew; the renewal path never
-- asked.
--
-- Design and the argument against each decision: docs/OPERATOR-BILLING-DESIGN.md
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The two tables
--
-- Keyed on school_id and readable ONLY by is_platform_admin(). No policy here
-- mentions current_school_id(): the operator's reach stays exactly what it was
-- — schools, subscriptions, plans, counts — and a school user must see none of
-- this. See D5.
-- ---------------------------------------------------------------------------
create table if not exists public.platform_invoices (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  plan_code     text not null references public.plans(code),
  cycle         public.billing_cycle not null,
  months        integer not null check (months >= 1),
  period_start  date not null,
  period_end    date not null,
  -- What we asked for, and what the price list said at the time. Keeping both
  -- is what makes a discount visible five years later: `amount` alone cannot
  -- distinguish a cheap plan from a generous one.
  amount        numeric(12,2) not null check (amount >= 0),
  list_amount   numeric(12,2) not null check (list_amount >= 0),
  issued_on     date not null default current_date,
  due_on        date,
  note          text,
  -- The operator has no profiles row, so this is the auth user id with no FK to
  -- profiles. A FK to auth.users would be right but auth.users is not ours to
  -- constrain against from a migration.
  created_by    uuid,
  created_at    timestamptz not null default now(),
  check (period_end >= period_start)
);

create index if not exists idx_platform_invoices_school
  on public.platform_invoices(school_id, issued_on desc);

create table if not exists public.platform_payments (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references public.schools(id) on delete cascade,
  -- Nullable on purpose. The school side needs a real allocation engine because
  -- a parent's payment must be split oldest-month-first across several
  -- children; here one customer pays a handful of invoices a year and netting
  -- per school is both correct and checkable by eye. See D2.
  invoice_id  uuid references public.platform_invoices(id) on delete set null,
  amount      numeric(12,2) not null check (amount > 0),
  paid_on     date not null default current_date,
  method      text not null default 'bank'
                check (method in ('bank', 'cash', 'cheque', 'online', 'other')),
  reference   text,
  note        text,
  created_by  uuid,
  created_at  timestamptz not null default now()
);

create index if not exists idx_platform_payments_school
  on public.platform_payments(school_id, paid_on desc);

alter table public.platform_invoices enable row level security;
alter table public.platform_payments enable row level security;

-- Read-only through RLS even for the operator: every write goes through a
-- SECURITY DEFINER function, so there is one place that decides what a valid
-- charge or receipt looks like. An UPDATE path would let an invoice be edited
-- into something it never was, which is the same argument 0061 made about
-- certificates.
drop policy if exists platform_invoices_select on public.platform_invoices;
create policy platform_invoices_select on public.platform_invoices
  for select to authenticated using (public.is_platform_admin());

drop policy if exists platform_payments_select on public.platform_payments;
create policy platform_payments_select on public.platform_payments
  for select to authenticated using (public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- 2. What a plan costs for a given number of months
--
-- One place, because "months >= 12 means yearly" is already decided by
-- fn_activate_subscription and the two must not disagree about the price of the
-- same renewal.
-- ---------------------------------------------------------------------------
create or replace function public.fn__plan_price(p_plan_code text, p_months integer)
returns numeric language sql stable as $$
  select case
    when p_months >= 12
      then round(p.price_yearly * (p_months::numeric / 12), 2)
      else round(p.price_monthly * p_months, 2)
  end
  from public.plans p where p.code = p_plan_code;
$$;

revoke all on function public.fn__plan_price(text, integer) from public;

-- ---------------------------------------------------------------------------
-- 3. What one school owes us
--
-- DERIVED, never stored. A stored balance drifts from the rows that produced it
-- and then two screens disagree about what a customer owes — the rule the
-- school-facing side already follows.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_outstanding(p_school_id uuid)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare v_inv numeric; v_paid numeric;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select coalesce(sum(amount), 0) into v_inv
    from public.platform_invoices where school_id = p_school_id;
  select coalesce(sum(amount), 0) into v_paid
    from public.platform_payments where school_id = p_school_id;
  return v_inv - v_paid;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Granting time now writes the charge
--
-- DROP first: `create or replace` cannot add parameters. The old 3-argument form
-- must not survive as an overload — leaving it would mean the app could still
-- call the version that grants a year and records no money, which is the whole
-- defect.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_activate_subscription(uuid, text, integer);
drop function if exists public.fn_activate_subscription(uuid, text, integer, numeric, text, boolean);

create function public.fn_activate_subscription(
  p_school_id uuid,
  p_plan_code text,
  p_months integer default 12,
  -- Null means "charge the list price". An explicit amount that differs from
  -- list REQUIRES a note, so a discount is always one somebody wrote a reason
  -- for. Zero is a legitimate charge — a pilot, a favour, an apology — and
  -- recording it is the point: a free year that leaves no trace is how a
  -- business loses track of what it has given away.
  p_amount numeric default null,
  p_note text default null,
  -- Renewing a school onto a plan it has outgrown is refused unless the operator
  -- says so on purpose. The information was already on the screen and the
  -- renewal ignored it.
  p_allow_over_limit boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_start date; v_end date; v_cycle public.billing_cycle;
  v_list numeric; v_amount numeric;
  v_count integer; v_limit integer; v_margin integer; v_suggest text;
  v_inv uuid; v_actor uuid := auth.uid();
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not exists (select 1 from public.plans where code = p_plan_code) then
    raise exception 'Unknown plan %', p_plan_code;
  end if;
  if p_months is null or p_months < 1 then
    raise exception 'Months must be at least 1';
  end if;

  -- ---- the over-limit refusal -------------------------------------------
  -- Counted fresh rather than trusting the stored count, because the whole
  -- decision turns on it and a stale count would wave the renewal through.
  perform public.fn_refresh_student_count(p_school_id);
  select sub.student_count, p.student_limit
    into v_count, v_limit
    from public.subscriptions sub
    join public.plans p on p.code = p_plan_code
   where sub.school_id = p_school_id;

  if v_count is null then
    raise exception 'No subscription for school %', p_school_id;
  end if;

  v_margin := public.plan_margin_limit(v_limit);
  if v_limit is not null and v_count > v_margin then
    select p2.code into v_suggest from public.plans p2
     where p2.active and (p2.student_limit is null or p2.student_limit >= v_count)
     order by p2.sort_order limit 1;
    if not coalesce(p_allow_over_limit, false) then
      raise exception
        '% has % students; % allows % (% with the margin). Put them on % instead, '
        'or renew on % on purpose.',
        (select name from public.schools where id = p_school_id),
        v_count, p_plan_code, v_limit, v_margin,
        coalesce(v_suggest, 'a custom plan'), p_plan_code;
    end if;
    -- Renewed over the limit deliberately: the fact goes ON the invoice, not
    -- into a log nobody reads.
    v_note := btrim(coalesce(v_note || ' — ', '')
      || format('renewed on %s with %s students against a limit of %s',
                p_plan_code, v_count, v_limit));
  end if;

  -- ---- the period --------------------------------------------------------
  -- Renewing early extends from the existing end date rather than from today,
  -- so a school that pays a week ahead does not lose that week.
  select case
    when period_end is not null and period_end >= current_date
      then period_end + 1 else current_date end
  into v_start
  from public.subscriptions where school_id = p_school_id;

  v_end   := (v_start + (p_months || ' months')::interval)::date - 1;
  v_cycle := case when p_months >= 12 then 'yearly' else 'monthly' end::public.billing_cycle;

  -- ---- the money --------------------------------------------------------
  v_list   := coalesce(public.fn__plan_price(p_plan_code, p_months), 0);
  v_amount := coalesce(p_amount, v_list);
  if v_amount < 0 then
    raise exception 'An amount cannot be negative';
  end if;
  if v_amount <> v_list and v_note is null then
    raise exception
      'Charging % where the price list says % needs a reason — it is recorded on '
      'the invoice.', to_char(v_amount, 'FM999999999.00'),
      to_char(v_list, 'FM999999999.00');
  end if;

  update public.subscriptions
     set plan_code     = p_plan_code,
         status        = 'active',
         cycle         = v_cycle,
         period_start  = v_start,
         period_end    = v_end,
         grace_ends_on = v_end + public.grace_days()
   where school_id = p_school_id;

  insert into public.platform_invoices
    (school_id, plan_code, cycle, months, period_start, period_end,
     amount, list_amount, due_on, note, created_by)
  values
    (p_school_id, p_plan_code, v_cycle, p_months, v_start, v_end,
     v_amount, v_list, current_date + 14, v_note, v_actor)
  returning id into v_inv;

  -- Against the school it concerns, so the school's own owner can see "your
  -- subscription was activated until ___". That is their subscription, not a
  -- leak. actor_role stays null: the operator has no profiles row and therefore
  -- no user_role, and inventing one would put a non-school identity into a
  -- school-scoped enum. Written explicitly rather than by audit_trigger(),
  -- which reads current_school_id() and would fail the NOT NULL for an operator.
  insert into public.audit_log(school_id, actor, action, entity, entity_id, after, reason)
  values (p_school_id, v_actor, 'subscription_activated', 'subscriptions',
          p_school_id::text,
          jsonb_build_object('plan_code', p_plan_code, 'months', p_months,
                             'period_start', v_start, 'period_end', v_end,
                             'amount', v_amount, 'list_amount', v_list,
                             'invoice_id', v_inv),
          v_note);

  return jsonb_build_object(
    'school_id', p_school_id, 'plan_code', p_plan_code,
    'period_start', v_start, 'period_end', v_end,
    'grace_ends_on', v_end + public.grace_days(),
    'invoice_id', v_inv, 'amount', v_amount, 'list_amount', v_list,
    'outstanding', public.fn_platform_outstanding(p_school_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Recording what a school paid us
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_record_payment(
  p_school_id uuid,
  p_amount numeric,
  p_paid_on date default null,
  p_method text default 'bank',
  p_reference text default null,
  p_invoice_id uuid default null,
  p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_actor uuid := auth.uid();
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'A payment must be more than zero';
  end if;
  if not exists (select 1 from public.schools where id = p_school_id) then
    raise exception 'Unknown school %', p_school_id;
  end if;
  -- An invoice from ANOTHER school would silently move that school's balance.
  if p_invoice_id is not null
     and not exists (select 1 from public.platform_invoices
                      where id = p_invoice_id and school_id = p_school_id) then
    raise exception 'That invoice does not belong to this school';
  end if;

  insert into public.platform_payments
    (school_id, invoice_id, amount, paid_on, method, reference, note, created_by)
  values (p_school_id, p_invoice_id, p_amount,
          coalesce(p_paid_on, current_date), coalesce(p_method, 'bank'),
          nullif(btrim(coalesce(p_reference, '')), ''),
          nullif(btrim(coalesce(p_note, '')), ''), v_actor)
  returning id into v_id;

  insert into public.audit_log(school_id, actor, action, entity, entity_id, after, reason)
  values (p_school_id, v_actor, 'platform_payment_recorded', 'platform_payments',
          v_id::text,
          jsonb_build_object('amount', p_amount, 'method', coalesce(p_method, 'bank'),
                             'paid_on', coalesce(p_paid_on, current_date),
                             'invoice_id', p_invoice_id),
          nullif(btrim(coalesce(p_note, '')), ''));

  return jsonb_build_object(
    'payment_id', v_id, 'school_id', p_school_id, 'amount', p_amount,
    'outstanding', public.fn_platform_outstanding(p_school_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. One school's history, invoices and payments interleaved
-- ---------------------------------------------------------------------------
drop function if exists public.fn_platform_ledger(uuid);
create function public.fn_platform_ledger(p_school_id uuid)
returns table (
  entry_date date, kind text, description text,
  charged numeric, paid numeric, note text, reference text
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
  select i.issued_on, 'invoice'::text,
         format('%s · %s month%s · %s to %s', i.plan_code, i.months,
                case when i.months = 1 then '' else 's' end,
                i.period_start, i.period_end),
         i.amount, null::numeric,
         -- A discount only reads as a discount next to the list price.
         case when i.amount <> i.list_amount
              then format('list %s — %s', to_char(i.list_amount, 'FM999999999.00'),
                          coalesce(i.note, 'no reason recorded'))
              else i.note end,
         null::text
    from public.platform_invoices i
   where i.school_id = p_school_id
  union all
  select p.paid_on, 'payment'::text,
         format('%s payment', p.method),
         null::numeric, p.amount, p.note, p.reference
    from public.platform_payments p
   where p.school_id = p_school_id
   order by 1, 2 desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. What we invoiced and collected over a period
-- ---------------------------------------------------------------------------
drop function if exists public.fn_platform_revenue(date, date);
create function public.fn_platform_revenue(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_invoiced numeric; v_collected numeric; v_discounted numeric;
  v_outstanding numeric; v_by_plan jsonb; v_owing jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Give a start date and an end date, the end not before the start';
  end if;

  select coalesce(sum(amount), 0), coalesce(sum(list_amount - amount), 0)
    into v_invoiced, v_discounted
    from public.platform_invoices
   where issued_on between p_from and p_to;

  select coalesce(sum(amount), 0) into v_collected
    from public.platform_payments
   where paid_on between p_from and p_to;

  select coalesce(jsonb_agg(x order by x->>'plan_code'), '[]'::jsonb) into v_by_plan
    from (
      select jsonb_build_object('plan_code', plan_code,
                                'invoices', count(*),
                                'amount', sum(amount)) as x
        from public.platform_invoices
       where issued_on between p_from and p_to
       group by plan_code) g;

  -- Everything ever invoiced minus everything ever paid: a receivable does not
  -- belong to the month it was raised in.
  select coalesce(sum(i), 0), coalesce(jsonb_agg(j order by j->>'school_name'), '[]'::jsonb)
    into v_outstanding, v_owing
    from (
      select bal.owed as i,
             jsonb_build_object('school_id', bal.school_id,
                                'school_name', bal.name,
                                'outstanding', bal.owed) as j
        from (
          select s.id as school_id, s.name,
                 coalesce((select sum(amount) from public.platform_invoices
                            where school_id = s.id), 0)
               - coalesce((select sum(amount) from public.platform_payments
                            where school_id = s.id), 0) as owed
            from public.schools s) bal
       where bal.owed > 0) o;

  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    'invoiced', v_invoiced, 'collected', v_collected,
    'discounted', v_discounted,
    'outstanding_total', v_outstanding,
    'by_plan', v_by_plan,
    'schools_owing', v_owing);
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. The console list, with the receivable on it
--
-- DROP first: the return type gains a column, which `create or replace` cannot
-- do. `outstanding` is the column that turns "who expires soon" into "who owes
-- me money" — the two looked identical before, which was defect 1c.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_platform_schools();
create function public.fn_platform_schools()
returns table (
  school_id uuid, school_name text, city text,
  contact_name text, contact_phone text,
  plan_code text, status public.subscription_status,
  expires_on date, days_left integer,
  student_count integer, student_limit integer,
  limit_state text, suggested_plan text, needs_upgrade boolean,
  outstanding numeric, last_paid_on date
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
    select
      s.id, s.name, s.city, s.contact_name, s.contact_phone,
      sub.plan_code,
      public.fn_effective_status(s.id),
      case when sub.status = 'trialing' then sub.trial_ends_on else sub.period_end end,
      (case when sub.status = 'trialing' then sub.trial_ends_on else sub.period_end end
        - current_date)::integer,
      sub.student_count,
      p.student_limit,
      case
        when p.student_limit is null then 'ok'
        when sub.student_count <= p.student_limit then 'ok'
        when sub.student_count <= public.plan_margin_limit(p.student_limit) then 'within_margin'
        else 'over' end,
      sug.code,
      sug.code is distinct from sub.plan_code,
      coalesce((select sum(i.amount) from public.platform_invoices i
                 where i.school_id = s.id), 0)
        - coalesce((select sum(pm.amount) from public.platform_payments pm
                     where pm.school_id = s.id), 0),
      (select max(pm.paid_on) from public.platform_payments pm
        where pm.school_id = s.id)
    from public.schools s
    join public.subscriptions sub on sub.school_id = s.id
    join public.plans p on p.code = sub.plan_code
    cross join lateral (
      select p2.code from public.plans p2
       where p2.active and (p2.student_limit is null or p2.student_limit >= sub.student_count)
       order by p2.sort_order limit 1
    ) sug
    order by s.name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Grants
--
-- Every one of these gates on is_platform_admin() as its first statement, so
-- granting to `authenticated` is what lets the operator's own signed-in session
-- call them. A school user calling any of them gets 42501.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_platform_outstanding(uuid) to authenticated;
grant execute on function public.fn_platform_ledger(uuid) to authenticated;
grant execute on function public.fn_platform_revenue(date, date) to authenticated;
grant execute on function public.fn_platform_schools() to authenticated;
grant execute on function
  public.fn_activate_subscription(uuid, text, integer, numeric, text, boolean)
  to authenticated;
grant execute on function
  public.fn_platform_record_payment(uuid, numeric, date, text, text, uuid, text)
  to authenticated;
