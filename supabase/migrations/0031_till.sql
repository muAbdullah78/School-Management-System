-- =============================================================================
-- Till sessions — per-collector cash control and end-of-day settlement.
--
-- The Day Book answers "what did the SCHOOL collect today". That is the weaker
-- question. This answers "what did YOU collect today, and does the cash in
-- your drawer match it" — which is how physical cash is actually controlled in
-- a school office, and it makes each clerk personally accountable for a number
-- at 4pm rather than accountable to a report nobody runs.
--
-- DESIGN RULE: taking money is NEVER blocked.
--
-- The obvious design is "a cash payment requires an open till". That is wrong
-- here: it means a clerk who forgot the morning ritual cannot accept a fee,
-- and a parent standing at the counter gets turned away by our software. So a
-- till is opened automatically, with a zero float, on the first cash payment
-- of the day. The discipline lives at CLOSING time, where it belongs — count
-- the drawer, explain any difference.
--
-- The variance is STORED, not recomputed. If it were derived, a later
-- correction to the day's payments would silently change history and a
-- shortfall that was explained on Tuesday could quietly disappear on Friday.
-- =============================================================================

create table public.till_sessions (
  id              uuid primary key default gen_random_uuid(),
  school_id       uuid not null references public.schools(id) on delete cascade,
  opened_by       uuid not null references public.profiles(id),
  opened_at       timestamptz not null default now(),
  opening_float   numeric(12,2) not null default 0,

  closed_at       timestamptz,
  counted_cash    numeric(12,2),          -- what was physically counted
  expected_cash   numeric(12,2),          -- float + cash taken in this session
  variance        numeric(12,2),          -- counted - expected, frozen at close
  variance_reason text,

  approved_by     uuid references public.profiles(id),
  approved_at     timestamptz,

  status          text not null default 'open'
                  check (status in ('open', 'closed', 'approved')),
  created_at      timestamptz not null default now()
);

create index idx_till_school_opened on public.till_sessions (school_id, opened_at desc);
-- One open till per person. Not per person per day: a session spans whatever
-- period the clerk works, and two open drawers for one human is meaningless.
create unique index uq_till_one_open_per_user
  on public.till_sessions (opened_by) where status = 'open';

alter table public.payments
  add column till_session_id uuid references public.till_sessions(id);
create index idx_payments_till on public.payments (till_session_id);

create trigger trg_till_sessions_school before insert or update on public.till_sessions
  for each row execute function public.enforce_school_id();
create trigger trg_audit_till after insert or update or delete on public.till_sessions
  for each row execute function public.audit_trigger();

alter table public.till_sessions enable row level security;

-- A clerk sees their own drawer; owner/principal see every drawer.
create policy till_select on public.till_sessions for select to authenticated
  using (school_id = public.current_school_id()
         and (opened_by = auth.uid() or public.has_role('owner', 'principal')));
-- Writes go through the functions below only, so status transitions and the
-- frozen variance cannot be sidestepped.

-- ===========================================================================
-- Opening, and the automatic open that keeps the counter moving
-- ===========================================================================

create or replace function public.fn_open_till(p_opening_float numeric default 0)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to open a till';
  end if;
  if coalesce(p_opening_float, 0) < 0 then
    raise exception 'Opening float cannot be negative';
  end if;

  select id into v_id from public.till_sessions
  where opened_by = auth.uid() and status = 'open';
  if found then return v_id; end if;

  insert into public.till_sessions (opened_by, opening_float)
  values (auth.uid(), coalesce(p_opening_float, 0))
  returning id into v_id;
  return v_id;
end;
$$;

-- Internal: returns the caller's open till, creating a zero-float one if there
-- is none. Called from the payment path, which must never fail for this.
create or replace function public.fn__ensure_till()
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then return null; end if;
  select id into v_id from public.till_sessions
  where opened_by = auth.uid() and status = 'open';
  if found then return v_id; end if;

  insert into public.till_sessions (opened_by, opening_float)
  values (auth.uid(), 0)
  returning id into v_id;
  return v_id;
exception when others then
  -- Never let till bookkeeping stop a payment being recorded.
  return null;
end;
$$;

create or replace function public.fn_current_till()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_t record; v_cash numeric; v_all numeric; v_n integer;
begin
  select * into v_t from public.till_sessions
  where opened_by = auth.uid() and status = 'open';
  if not found then return null; end if;

  select coalesce(sum(p.amount), 0), count(*)
    into v_cash, v_n
  from public.payments p
  where p.till_session_id = v_t.id and p.status = 'verified' and p.method = 'cash';

  select coalesce(sum(p.amount), 0) into v_all
  from public.payments p
  where p.till_session_id = v_t.id and p.status = 'verified';

  return jsonb_build_object(
    'till_id', v_t.id,
    'opened_at', v_t.opened_at,
    'opening_float', v_t.opening_float,
    'cash_taken', v_cash,
    'all_taken', v_all,
    'receipts', v_n,
    'expected_cash', v_t.opening_float + v_cash);
end;
$$;

-- ===========================================================================
-- Closing: count the drawer, explain the difference
-- ===========================================================================

create or replace function public.fn_close_till(
  p_counted_cash numeric, p_reason text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_t record; v_cash numeric; v_expected numeric; v_var numeric;
begin
  select * into v_t from public.till_sessions
  where opened_by = auth.uid() and status = 'open'
  for update;
  if not found then raise exception 'You have no open till'; end if;
  if p_counted_cash is null or p_counted_cash < 0 then
    raise exception 'Count the drawer before closing it';
  end if;

  select coalesce(sum(p.amount), 0) into v_cash
  from public.payments p
  where p.till_session_id = v_t.id and p.status = 'verified' and p.method = 'cash';

  v_expected := v_t.opening_float + v_cash;
  v_var := p_counted_cash - v_expected;

  -- A difference in either direction needs an explanation. Extra cash in the
  -- drawer is as much a red flag as missing cash — it usually means a receipt
  -- was never written.
  if v_var <> 0 and (p_reason is null or btrim(p_reason) = '') then
    raise exception 'The drawer is off by %. A reason is required to close it.', v_var;
  end if;

  update public.till_sessions set
    closed_at = now(), counted_cash = p_counted_cash,
    expected_cash = v_expected, variance = v_var,
    variance_reason = nullif(btrim(coalesce(p_reason, '')), ''),
    status = 'closed'
  where id = v_t.id;

  return jsonb_build_object(
    'till_id', v_t.id, 'expected_cash', v_expected,
    'counted_cash', p_counted_cash, 'variance', v_var);
end;
$$;

create or replace function public.fn_approve_till(p_till_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_t record;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may sign off a till';
  end if;
  perform public.assert_own('till_sessions', p_till_id);
  select * into v_t from public.till_sessions where id = p_till_id;
  if not found then raise exception 'Till not found'; end if;
  if v_t.status <> 'closed' then
    raise exception 'Only a closed till can be signed off';
  end if;
  update public.till_sessions
     set status = 'approved', approved_by = auth.uid(), approved_at = now()
   where id = p_till_id;
end;
$$;

-- The owner's settlement view: who collected what, and whose drawer was off.
create or replace function public.fn_till_report(p_from date, p_to date)
returns table (
  till_id uuid, collector text, opened_at timestamptz, closed_at timestamptz,
  opening_float numeric, cash_taken numeric, all_taken numeric,
  expected_cash numeric, counted_cash numeric, variance numeric,
  variance_reason text, status text
) language sql stable security definer set search_path = public as $$
  select t.id,
         coalesce(pr.full_name, 'Unknown'),
         t.opened_at, t.closed_at, t.opening_float,
         coalesce((select sum(p.amount) from public.payments p
                   where p.till_session_id = t.id and p.status = 'verified'
                     and p.method = 'cash'), 0),
         coalesce((select sum(p.amount) from public.payments p
                   where p.till_session_id = t.id and p.status = 'verified'), 0),
         t.expected_cash, t.counted_cash, t.variance, t.variance_reason, t.status
  from public.till_sessions t
  left join public.profiles pr on pr.id = t.opened_by
  where t.school_id = public.current_school_id()
    and public.has_role('owner', 'principal', 'accountant')
    and t.opened_at::date between p_from and p_to
  order by t.opened_at desc;
$$;

-- ===========================================================================
-- Attach cash payments to the collector's drawer
--
-- Both payment entry points are re-created with one added line. Everything
-- else about them is unchanged from 0029.
-- ===========================================================================

create or replace function public.fn_record_family_payment(
  p_family_id uuid, p_amount numeric, p_method public.payment_method,
  p_note text default null, p_pending boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor    uuid := auth.uid();
  v_receipt  bigint;
  v_pay      uuid;
  v_students uuid[];
  v_left     numeric;
  v_till     uuid;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to record payments';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  perform public.assert_own('families', p_family_id);

  select array_agg(id) into v_students from public.students where family_id = p_family_id;
  if v_students is null then raise exception 'This family has no students'; end if;

  if p_method = 'cash' and not p_pending then v_till := public.fn__ensure_till(); end if;

  v_receipt := public.next_counter('receipt');
  insert into public.payments(family_id, student_id, amount, method, receipt_no,
                              status, received_by, note, till_session_id)
  values (p_family_id, null, p_amount, p_method, v_receipt,
          case when p_pending then 'pending' else 'verified' end, v_actor, p_note, v_till)
  returning id into v_pay;

  if p_pending then
    return jsonb_build_object('payment_id', v_pay, 'receipt_no', v_receipt,
      'allocated', 0, 'credit', 0, 'pending', true);
  end if;

  v_left := public.fn__allocate_payment(v_pay, v_students, p_amount);

  return jsonb_build_object(
    'payment_id', v_pay, 'receipt_no', v_receipt,
    'allocated', p_amount - v_left,
    'credit', v_left,
    'family_outstanding', public.family_outstanding(p_family_id),
    'pending', false);
end;
$$;

create or replace function public.fn_record_payment(
  p_student_id uuid, p_amount numeric, p_method public.payment_method,
  p_note text default null, p_pending boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor   uuid := auth.uid();
  v_receipt bigint;
  v_pay     uuid;
  v_family  uuid;
  v_left    numeric;
  v_till    uuid;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to record payments';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  perform public.assert_own('students', p_student_id);

  select family_id into v_family from public.students where id = p_student_id;

  if p_method = 'cash' and not p_pending then v_till := public.fn__ensure_till(); end if;

  v_receipt := public.next_counter('receipt');
  insert into public.payments(student_id, family_id, amount, method, receipt_no,
                              status, received_by, note, till_session_id)
  values (p_student_id, v_family, p_amount, p_method, v_receipt,
          case when p_pending then 'pending' else 'verified' end, v_actor, p_note, v_till)
  returning id into v_pay;

  if p_pending then
    return jsonb_build_object('payment_id', v_pay, 'receipt_no', v_receipt,
      'allocated', 0, 'unallocated', p_amount, 'pending', true);
  end if;

  v_left := public.fn__allocate_payment(v_pay, array[p_student_id], p_amount);

  return jsonb_build_object(
    'payment_id', v_pay, 'receipt_no', v_receipt,
    'allocated', p_amount - v_left, 'unallocated', v_left, 'pending', false);
end;
$$;

grant execute on function public.fn_open_till(numeric)              to authenticated;
grant execute on function public.fn_current_till()                  to authenticated;
grant execute on function public.fn_close_till(numeric, text)       to authenticated;
grant execute on function public.fn_approve_till(uuid)              to authenticated;
grant execute on function public.fn_till_report(date, date)         to authenticated;

-- Internal: it creates a till row for whoever calls it.
revoke all on function public.fn__ensure_till() from public, anon, authenticated;
