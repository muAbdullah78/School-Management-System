-- =============================================================================
-- 0103 — The school holds the family's deposit and told the family nothing
--
-- A security deposit is the one sum on this system that is NOT the school's
-- money. The balance sheet knows that and shows it as a liability, removed from
-- retained earnings, with a comment saying so in as many words.
--
-- The family it belongs to is never told.
--
-- Asked of the running code: where does a deposit appear?
--
--   Fees > Deposits              the office screen, opened when somebody leaves
--   Settings > Fee heads         the setup
--   the balance sheet            as a liability
--
--   the child's own profile      NOWHERE
--   the parent portal            NOWHERE
--   the printed statement        NOWHERE
--
-- fn_deposit_held exists, is granted, and has a wrapper in the app that no
-- screen calls. So the school holds Rs 5,000 of a family's money, and the only
-- place that says so is a screen the family cannot open and the office opens
-- once a year.
--
-- This is the same shape as the hand-keyed adjustment 0098 fixed, and worse in
-- one respect. An adjustment is the school's claim ON the family, and the school
-- has every reason to remember it. A deposit is the family's claim on the
-- SCHOOL, and the only party with a reason to remember it is the one who cannot
-- see it. A parent whose child leaves and who was never shown the deposit is
-- relying on the office to volunteer money back.
--
-- It is also why the parent's own page did not add up in a second way. 0098
-- made the challans plus the hand-keyed charges equal the balance. A deposit is
-- neither: it is paid, it is not owed, and it is held. Without a line for it a
-- parent who paid Rs 5,000 into a deposit sees it leave their pocket and appear
-- in no total anywhere.
--
-- WHAT THIS ADDS
--
-- `deposit_held` on fn_portal_child_fees, which the portal and the printed
-- statement now show, and which the office profile reads through the wrapper
-- that already existed. One figure, one function, three screens: the same
-- arrangement as the fee statement.
--
-- Re-runnable.
-- =============================================================================

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
    -- Refundable money the school is HOLDING for this child. Not part of the
    -- balance, which is what is owed: this is the other direction, and a parent
    -- who is never shown it has no way to ask for it back.
    'deposit_held', public.fn__deposit_held(p_student_id),
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
    'adjustments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'on', a.created_at::date,
        'amount', a.amount,
        'reason', coalesce(nullif(btrim(a.reason), ''), 'Adjustment')
      ) order by a.created_at desc)
      from public.adjustments a
      where a.student_id = p_student_id
    ), '[]'::jsonb),
    'charges_not_on_a_challan', coalesce((
      select sum(a.amount) from public.adjustments a where a.student_id = p_student_id
    ), 0),
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

revoke all on function public.fn_portal_child_fees(uuid) from public, anon;
grant execute on function public.fn_portal_child_fees(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- fn_deposit_held is now staff only
--
-- Found while wiring the line above, by asking who could already call it: it is
-- SECURITY DEFINER, granted to `authenticated`, and gated by NOTHING but
-- current_school_id(). Every signed-in account in a school could ask it for any
-- student id in that school, including a parent account, which is supposed to
-- have no reach beyond its own children.
--
-- Not enumerable in practice, because a student id is a uuid and a parent is
-- only ever handed their own. That is a reason it has not been exploited, not a
-- reason to leave it: 0033's whole design is that a parent's reach is decided by
-- fn__assert_my_child and not by which ids they happen to know.
--
-- The gate is is_staff() rather than the finance roles, matching fn_deposits_held
-- next to it: a class teacher asked whether a leaving pupil has money to collect
-- is answering a normal question, and the figure carries no other family's data.
--
-- The portal is unaffected. fn_portal_child_fees is SECURITY DEFINER and reaches
-- this as the owner after asserting the child, which is the same arrangement
-- fn__student_ledger uses.
-- ---------------------------------------------------------------------------
create or replace function public.fn_deposit_held(p_student_id uuid)
returns numeric language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);
  return public.fn__deposit_held(p_student_id);
end;
$$;

-- The arithmetic, unchanged, with no gate: the portal reaches it as the owner
-- after asserting the child, and the staff wrapper above carries the gate.
create or replace function public.fn__deposit_held(p_student_id uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select greatest(
    coalesce((
      select sum(al.amount)
        from public.payment_allocations al
        join public.payments p on p.id = al.payment_id
        join public.invoices i on i.id = al.invoice_id
       where i.school_id = public.current_school_id()
         and i.student_id = p_student_id
         and i.status <> 'void'
         and p.status = 'verified'
         and exists (
           select 1 from public.invoice_lines l
           join public.fee_heads h on h.id = l.fee_head_id
           where l.invoice_id = i.id and h.is_refundable)
    ), 0)
    - coalesce((
      select sum(r.amount) from public.deposit_refunds r
       where r.school_id = public.current_school_id()
         and r.student_id = p_student_id
    ), 0),
    0);
$$;

revoke all on function public.fn__deposit_held(uuid) from public, anon, authenticated;
revoke all on function public.fn_deposit_held(uuid) from public, anon;
grant execute on function public.fn_deposit_held(uuid) to authenticated;

do $assert$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'fn_portal_child_fees'
      and p.prosrc like '%deposit_held%')
  then
    raise exception '0103: fn_portal_child_fees does not report the deposit';
  end if;
  if has_function_privilege('anon', 'public.fn__deposit_held(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.fn__deposit_held(uuid)', 'execute') then
    raise exception '0103: the ungated deposit arithmetic is reachable by a client role';
  end if;
end $assert$;
