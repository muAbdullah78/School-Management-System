-- =============================================================================
-- 0084 — A family receipt that does not say which child it paid for
--
-- FamilyCollect.tsx's own header has said this since it was written:
--
--     "Allocation is oldest-month-first across siblings and is NOT silent: the
--      result panel names every invoice the money cleared. Silent allocation is
--      what causes arguments at the counter."
--
-- It was not true. fn_record_family_payment returns four numbers — payment_id,
-- receipt_no, allocated, credit — and nothing about WHERE the money went. The
-- panel showed "Rs 9,000 applied to outstanding fees" and the printed receipt
-- said the same. A father paying for three children could not tell from it which
-- child's dues had moved, which is exactly the argument the comment claims to
-- have prevented.
--
-- The data was always there. fn__allocate_payment writes a row into
-- payment_allocations for every invoice it touches; nothing read them back.
--
-- WHAT THIS CHANGES
--
-- Both payment functions now return an `applied` array: one entry per invoice
-- the money cleared, carrying the student, the GR number, the month and the
-- amount. Ordered the way the allocator walks — oldest month first — so the
-- receipt reads in the order the clerk can explain.
--
-- Adding a key to a jsonb result is safe for every existing caller: the web
-- client destructures the keys it knows and ignores the rest, and both functions
-- keep their signature, so no grant or policy moves.
--
-- WHY NOT COMPUTE IT IN THE BROWSER
--
-- Because it would have to guess. The allocator's order is
-- `period_month nulls first, student_id, invoice_id` and its "paid vs partial"
-- decision reads invoice_balances, a view. A second implementation in
-- TypeScript would agree with it until the day it did not, and the day it did
-- not would be visible only on a printed receipt in a parent's hand.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- The shared reader.
--
-- Internal, and revoked from everyone — but SCOPED ANYWAY, on the caller's own
-- school. The first version filtered on the payment id alone, reasoning that
-- both callers had just created the payment themselves so the id could not be
-- anyone else's. dashboard.sql's assertion 20 rejected it, and the assertion is
-- right: a SECURITY DEFINER function bypasses RLS, so "the id is trustworthy
-- because of who calls it today" is a property of today's callers, not of this
-- function. Pass a foreign payment id and it would have handed back another
-- school's children's names, GR numbers and the exact amounts their parents
-- paid. It now returns an empty array instead.
-- ---------------------------------------------------------------------------
create or replace function public.fn__payment_applied(p_payment_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x.period_month nulls first, x.student_name, x.amount), '[]'::jsonb)
  from (
    select s.id            as student_id,
           s.full_name     as student_name,
           s.gr_no         as gr_no,
           i.period_month  as period_month,
           pa.amount       as amount
    from public.payment_allocations pa
    join public.invoices i on i.id = pa.invoice_id
    join public.students s on s.id = i.student_id
    where pa.payment_id = p_payment_id
      and i.school_id = public.current_school_id()
      and s.school_id = public.current_school_id()
  ) x;
$$;

revoke all on function public.fn__payment_applied(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Single student.
--
-- Rewritten programmatically rather than restated, so that a change made to
-- this function between 0031 and today cannot be silently reverted by a copy
-- pasted out of an old migration. That has happened in this repository before.
-- ---------------------------------------------------------------------------
do $rw$
declare v_old text; v_new text;
begin
  v_old := pg_get_functiondef(
    'public.fn_record_payment(uuid, numeric, public.payment_method, text, boolean)'::regprocedure);

  -- Already carries it: nothing to do, and the assertions below still run.
  if v_old like '%fn__payment_applied%' then
    raise notice '0084: fn_record_payment already returns the allocation detail';
  else
    v_new := replace(v_old,
      $q$    'allocated', p_amount - v_left, 'unallocated', v_left, 'pending', false);$q$,
      $q$    'allocated', p_amount - v_left, 'unallocated', v_left, 'pending', false,
    'applied', public.fn__payment_applied(v_pay));$q$);

    if v_new = v_old then
      raise exception
        '0084: could not find the return statement in fn_record_payment. It has '
        'been edited since 0031 — read it and place the applied key by hand '
        'rather than letting this migration report success.';
    end if;
    execute v_new;
  end if;

  -- The END STATE, asserted. A rewrite that silently matched nothing is the
  -- failure mode this guards.
  if pg_get_functiondef(
       'public.fn_record_payment(uuid, numeric, public.payment_method, text, boolean)'::regprocedure)
     not like '%fn__payment_applied%' then
    raise exception '0084: fn_record_payment still does not return the allocation detail';
  end if;
end $rw$;

-- ---------------------------------------------------------------------------
-- The family. Same treatment.
-- ---------------------------------------------------------------------------
do $rw$
declare v_old text; v_new text;
begin
  v_old := pg_get_functiondef(
    'public.fn_record_family_payment(uuid, numeric, public.payment_method, text, boolean)'::regprocedure);

  if v_old like '%fn__payment_applied%' then
    raise notice '0084: fn_record_family_payment already returns the allocation detail';
  else
    v_new := replace(v_old,
      $q$    'family_outstanding', public.family_outstanding(p_family_id),
    'pending', false);$q$,
      $q$    'family_outstanding', public.family_outstanding(p_family_id),
    'applied', public.fn__payment_applied(v_pay),
    'pending', false);$q$);

    if v_new = v_old then
      raise exception
        '0084: could not find the return statement in fn_record_family_payment. '
        'It has been edited since 0031 — place the applied key by hand.';
    end if;
    execute v_new;
  end if;

  if pg_get_functiondef(
       'public.fn_record_family_payment(uuid, numeric, public.payment_method, text, boolean)'::regprocedure)
     not like '%fn__payment_applied%' then
    raise exception '0084: fn_record_family_payment still does not return the allocation detail';
  end if;
end $rw$;

-- `create or replace` PRESERVES an existing ACL, and these two were rewritten
-- through pg_get_functiondef which restates the definition without its grants.
-- Restated explicitly so a future reader does not have to work out which of
-- those two facts applied here.
grant  execute on function public.fn_record_payment(uuid, numeric, public.payment_method, text, boolean) to authenticated;
revoke execute on function public.fn_record_payment(uuid, numeric, public.payment_method, text, boolean) from public, anon;
grant  execute on function public.fn_record_family_payment(uuid, numeric, public.payment_method, text, boolean) to authenticated;
revoke execute on function public.fn_record_family_payment(uuid, numeric, public.payment_method, text, boolean) from public, anon;
