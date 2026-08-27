-- =============================================================================
-- 0087 — A challan raised by mistake could never be cancelled
--
-- WHAT WAS THERE
--
-- `invoice_status` has had the value `void` since the first migration, and
-- TWENTY functions honour it — student_balance, the dashboard, the defaulters
-- list, head-wise dues, the balance sheet, the unpaid-challan report, the
-- voucher scan, every one of them excludes a void invoice, and
-- `invoice_balances` filters it out at the view. The read side is complete and
-- consistent.
--
-- Nothing has ever written it. Asked directly:
--
--     select proname from pg_proc
--      where prosrc ~* 'status\s*=\s*''void''' and prosrc ~* 'update';
--     → 0 rows
--
-- So a clerk who generated April's challans for Class 5 with the wrong due date,
-- or billed a child who had already left, or ran the generator twice against two
-- different fee structures, had no way to undo it. The workarounds are all
-- worse than the problem:
--
--   * A negative adjustment cancels the money but leaves the wrong challan
--     sitting in Unpaid Challans, in Dues by Fee Head and in the defaulters
--     list for ever, and the parent portal keeps showing it. The books balance
--     and every screen still accuses the family.
--   * Deleting the row over the REST API worked until 0086 closed it, and left
--     no trace that the charge had ever existed.
--
-- WHY THE READ SIDE BEING RIGHT IS NOT ENOUGH
--
-- Twenty readers excluding void was never tested against a void invoice,
-- because none could exist. Introducing the writer means auditing every reader
-- that does NOT exclude it. Six were found by asking which function bodies name
-- `public.invoices` without naming `'void'`, and each was judged rather than
-- patched:
--
--   fn_challan            THE ONE THAT MATTERS. It prints the bank-payable
--                         voucher. A cancelled challan that still prints is the
--                         whole loophole reopened from the other end: cancel the
--                         charge, print the slip, collect the cash off-book.
--                         Now refuses, by name.
--   fn_undo_defer         updated any invoice regardless of status, while its
--                         twin fn_defer_invoice already refused a void one.
--                         Made symmetric.
--   fn_global_search      showed `initcap(status)` — a clerk searching a
--                         voucher code saw "Void", which is database jargon, not
--                         an answer. Now says "Cancelled".
--   fn_report_ledger      touches invoices only to label which months a RECEIPT
--                         covered. A cancelled month can appear there and
--                         should: the receipt is a historical fact. Left alone.
--   fn__payment_applied   same reasoning — it describes a payment that happened.
--   fn_rollover_undo      LEFT ALONE DELIBERATELY, and this one is worth the
--                         paragraph. It refuses to undo a rollover when the
--                         target session already has invoices, and excluding
--                         void there looks like an obvious improvement. It is
--                         not: the undo then proceeds to DELETE the enrolments,
--                         and a void invoice still references enrollment_id, so
--                         the delete fails on the foreign key and the school
--                         gets a constraint error instead of a clear refusal. A
--                         cancelled challan is evidence that somebody billed in
--                         that session; refusing is right.
--   fn_platform_school_detail  LEFT ALONE, and checked rather than waved
--                         through. It touches invoices twice, and both are
--                         USAGE signals rather than receivables: "has this
--                         school ever billed anybody" and "when did they last
--                         raise a challan". A school that raised a challan and
--                         cancelled it has still used the billing module, so
--                         counting the cancelled one is the right answer to
--                         both questions. The first draft of this migration
--                         carried a do-block that printed a notice about it on
--                         every deployment; a control that only complains is
--                         noise, and the finding belongs here instead.
--
-- THE RULES, AND THE ARGUMENT AGAINST EACH
--
--   1. OWNER OR PRINCIPAL ONLY. The objection is practical: the clerk generates
--      the challans, so the clerk makes the mistakes, and making them fetch the
--      principal is friction on a busy morning. It stands anyway. A front-office
--      login that can cancel a charge can make a family's dues disappear and
--      take the cash informally, and that is the oldest fraud in a Pakistani
--      school office. A clerk can already SEE the register, and asking for the
--      cancellation takes a minute.
--
--   2. A REASON IS REQUIRED, and a one-character reason is not a reason. Four
--      characters minimum. The register is read months later by somebody who was
--      not there.
--
--   3. AN INVOICE WITH MONEY ON IT IS REFUSED, naming the amount. Cancelling a
--      charge that has been paid would orphan the payment: the receipt stays,
--      the allocation points at a charge that no longer counts, and the family's
--      balance moves by the paid amount with no receipt reversed. The correct
--      order is to reverse the payment first — fn_reverse_payment writes a
--      contra receipt, so the money movement stays visible — and then cancel.
--      A payment that has ALREADY been reversed nets to zero and does not block,
--      which is why the check sums the allocations instead of counting them.
--
--   4. IT IS A STATUS CHANGE, NOT A DELETE. The row, its lines, its voucher code
--      and its serial history all stay. "Deleted Fees" in the competitor's
--      product is a register of exactly this, and a register whose entries can be
--      erased is not one.
--
--   5. NOTHING IS ALLOCATED TO IT AFTERWARDS. Already true and worth stating:
--      fn__allocate_payment only considers invoices with status `issued` or
--      `partial`, so a payment arriving later becomes family credit rather than
--      settling a cancelled charge. A pending payment verified after the
--      cancellation behaves the same way.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Who cancelled it, when, and why
--
-- On the invoice rather than in a side table, because unlike a certificate an
-- invoice is not an issued document — it is a live position, and `status`
-- already lives here. The three columns are read by fn_voided_invoices below,
-- which is what keeps check-columns-used.sh satisfied that they are not
-- decoration.
-- ---------------------------------------------------------------------------
alter table public.invoices add column if not exists voided_at  timestamptz;
alter table public.invoices add column if not exists voided_by  uuid references public.profiles(id);
alter table public.invoices add column if not exists void_reason text;

-- 0086 revoked every direct write on public.invoices, so no column-level grant
-- is needed or wanted here: the only writer is the definer function below.

-- ---------------------------------------------------------------------------
-- 2. Cancelling one
-- ---------------------------------------------------------------------------
create or replace function public.fn_void_invoice(p_invoice_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_actor  uuid := auth.uid();
  v_inv    record;
  v_alloc  numeric;
  v_charge numeric;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.has_role('owner', 'principal') then
    raise exception
      'Only the owner or principal may cancel a charge. A clerk who can cancel '
      'a challan can make a family''s dues disappear.'
      using errcode = '42501';
  end if;
  if v_reason is null or length(v_reason) < 4 then
    raise exception
      'A reason is required, and it is read months later by somebody who was '
      'not there — say what was wrong with the challan.';
  end if;
  perform public.assert_own('invoices', p_invoice_id);

  select i.id, i.status, i.period_month, i.notes, i.student_id, s.full_name
    into v_inv
  from public.invoices i
  join public.students s on s.id = i.student_id
  where i.id = p_invoice_id and i.school_id = v_school;
  if not found then
    raise exception 'No such challan' using errcode = '42704';
  end if;
  if v_inv.status = 'void' then
    raise exception 'That challan is already cancelled.';
  end if;

  -- Sum, not count: a payment that has been reversed leaves its original and
  -- its contra allocation behind, and those net to zero. Counting rows would
  -- refuse for ever after any reversal.
  select coalesce(sum(a.amount), 0) into v_alloc
  from public.payment_allocations a
  where a.invoice_id = p_invoice_id;

  if v_alloc <> 0 then
    raise exception
      'Rs % has been paid against this challan. Reverse the payment first — '
      'Fees → the receipt → Reverse — so the money movement stays on the '
      'record, then cancel the charge.', trim(to_char(v_alloc, 'FM999,999,990'));
  end if;

  select coalesce(sum(case when l.is_discount then -l.amount else l.amount end), 0)
         + coalesce((select fine from public.invoices where id = p_invoice_id), 0)
    into v_charge
  from public.invoice_lines l where l.invoice_id = p_invoice_id;

  update public.invoices
     set status = 'void',
         voided_at = now(),
         voided_by = v_actor,
         void_reason = v_reason
   where id = p_invoice_id;

  insert into public.audit_log (
    school_id, actor, actor_role, action, entity, entity_id, before, after, reason)
  values (
    v_school, v_actor,
    (select role from public.profiles where id = v_actor),
    'INVOICE_VOID', 'invoices', p_invoice_id::text,
    jsonb_build_object('status', v_inv.status, 'charge', v_charge),
    jsonb_build_object('status', 'void'),
    v_reason);

  return jsonb_build_object(
    'invoice_id', p_invoice_id,
    'student_name', v_inv.full_name,
    'cancelled', v_charge,
    'period', coalesce(to_char(v_inv.period_month, 'FMMonth YYYY'),
                       coalesce(v_inv.notes, 'One-off charge')));
end;
$$;

grant  execute on function public.fn_void_invoice(uuid, text) to authenticated;
revoke execute on function public.fn_void_invoice(uuid, text) from public, anon;

-- ---------------------------------------------------------------------------
-- 3. The register — the competitor's "Deleted Fees", which is the right screen
--
-- A clerk may READ it even though they may not cancel. Same reasoning as
-- fn_message_settings: somebody working the counter should be able to see why
-- the challan they are looking for is not there, and being able to see a
-- control you cannot operate is how a boundary gets understood rather than
-- worked around.
-- ---------------------------------------------------------------------------
create or replace function public.fn_voided_invoices(p_from date, p_to date)
returns table (
  invoice_id    uuid,
  voided_at     timestamptz,
  student_id    uuid,
  student_name  text,
  gr_no         text,
  class_name    text,
  section_name  text,
  period_label  text,
  voucher_code  text,
  amount        numeric,
  voided_by     text,
  reason        text
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.may_view('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p_from is null or p_to is null then
    raise exception 'A date range is required';
  end if;
  if p_to < p_from then
    raise exception 'The end date is before the start date';
  end if;

  return query
  select i.id,
         i.voided_at,
         i.student_id,
         s.full_name,
         s.gr_no,
         c.name,
         sec.name,
         coalesce(to_char(i.period_month, 'FMMonth YYYY'),
                  coalesce(i.notes, 'One-off charge')),
         i.voucher_code,
         coalesce((select sum(case when l.is_discount then -l.amount else l.amount end)
                     from public.invoice_lines l where l.invoice_id = i.id), 0)
           + coalesce(i.fine, 0),
         coalesce(pr.full_name, '—'),
         coalesce(i.void_reason, '—')
    from public.invoices i
    join public.students s on s.id = i.student_id and s.school_id = v_school
    left join public.enrollments e on e.id = i.enrollment_id
    left join public.classes c   on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
    left join public.profiles pr on pr.id = i.voided_by
   where i.school_id = v_school
     and i.status = 'void'
     -- A challan voided before this migration existed has no voided_at. Those
     -- are impossible today (nothing could write `void`) but a database
     -- restored from elsewhere might carry one, and dropping it silently would
     -- make the register lie about what it contains.
     and coalesce(i.voided_at::date, i.created_at::date) between p_from and p_to
   order by i.voided_at desc nulls last, s.full_name;
end;
$$;

grant  execute on function public.fn_voided_invoices(date, date) to authenticated;
revoke execute on function public.fn_voided_invoices(date, date) from public, anon;

-- ---------------------------------------------------------------------------
-- 4. A cancelled challan does not print
--
-- Rewritten programmatically from pg_get_functiondef rather than restated: the
-- body is sixty lines that have nothing to do with this change, and retyping
-- them is how an unrelated fix gets silently reverted.
-- ---------------------------------------------------------------------------
do $rewrite$
declare
  v_src    text;
  v_anchor text := '  perform public.assert_own(''invoices'', p_invoice_id);';
  v_guard  text :=
    '  perform public.assert_own(''invoices'', p_invoice_id);' || E'\n' ||
    '  -- 0087. A cancelled challan must not print: the slip is bank-payable, so' || E'\n' ||
    '  -- printing one after the charge was cancelled is a way to collect cash' || E'\n' ||
    '  -- that the books will never expect.' || E'\n' ||
    '  if exists (select 1 from public.invoices' || E'\n' ||
    '              where id = p_invoice_id and status = ''void'') then' || E'\n' ||
    '    raise exception ''This challan was cancelled and cannot be printed. See ''' || E'\n' ||
    '      ''Fees → Cancelled charges for who cancelled it and why.''' || E'\n' ||
    '      using errcode = ''42501'';' || E'\n' ||
    '  end if;';
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_challan';

  if v_src is null then
    raise exception '0087: public.fn_challan does not exist';
  end if;

  if position('status = ''void''' in v_src) > 0 then
    raise notice '0087: fn_challan already refuses a cancelled challan';
  else
    if position(v_anchor in v_src) = 0 then
      raise exception
        '0087: cannot find the assert_own line in fn_challan. The body has '
        'changed; insert the void guard by hand rather than guessing.';
    end if;
    execute replace(v_src, v_anchor, v_guard);
    -- create or replace preserves the ACL, so no re-grant is needed. Stated
    -- because the opposite was assumed once and cost an afternoon.
  end if;
end $rewrite$;

-- ---------------------------------------------------------------------------
-- 5. "Cancelled", not "Void", in the global search
-- ---------------------------------------------------------------------------
do $rewrite$
declare
  v_src text;
  v_old text := 'initcap(i.status::text)';
  v_new text := 'case when i.status = ''void'' then ''Cancelled'' else initcap(i.status::text) end';
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_global_search';

  if v_src is null then
    raise exception '0087: public.fn_global_search does not exist';
  end if;

  if position('''Cancelled''' in v_src) > 0 then
    raise notice '0087: fn_global_search already says Cancelled';
  elsif position(v_old in v_src) = 0 then
    raise exception
      '0087: cannot find initcap(i.status::text) in fn_global_search — the '
      'challan branch has changed.';
  else
    execute replace(v_src, v_old, v_new);
  end if;
end $rewrite$;

-- ---------------------------------------------------------------------------
-- 6. fn_undo_defer, made symmetric with fn_defer_invoice
--
-- Short enough to restate in full, so it is.
-- ---------------------------------------------------------------------------
create or replace function public.fn_undo_defer(p_invoice_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted';
  end if;
  perform public.assert_own('invoices', p_invoice_id);
  update public.invoices set deferred_until = null, defer_reason = null
   where id = p_invoice_id and status <> 'void';
  if not found then
    -- One message covering both, because the caller cannot tell them apart from
    -- the outside and either way there is nothing to undo.
    raise exception 'Invoice not found, or it was cancelled';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. The end state, asserted
-- ---------------------------------------------------------------------------
do $assert$
declare v_src text;
begin
  if to_regclass('public.invoices') is null then
    raise exception '0087: public.invoices is missing';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'invoices'
                    and column_name = 'void_reason') then
    raise exception '0087: invoices.void_reason was not added';
  end if;

  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'fn_void_invoice') then
    raise exception '0087: fn_void_invoice was not created';
  end if;
  if not has_function_privilege('authenticated',
        'public.fn_void_invoice(uuid, text)', 'execute') then
    raise exception '0087: authenticated cannot execute fn_void_invoice';
  end if;
  if not has_function_privilege('authenticated',
        'public.fn_voided_invoices(date, date)', 'execute') then
    raise exception '0087: authenticated cannot execute fn_voided_invoices';
  end if;

  -- The rewrite, checked by what the body now SAYS rather than by whether the
  -- statement ran. This is the fourth time in this project that a signature
  -- based on a function merely EXISTING proved nothing.
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_challan';
  if position('status = ''void''' in v_src) = 0 then
    raise exception
      '0087: fn_challan does not refuse a cancelled challan. The bank-payable '
      'slip would still print for a charge the school has withdrawn.';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_global_search';
  if position('''Cancelled''' in v_src) = 0 then
    raise exception '0087: fn_global_search still shows raw status text';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_undo_defer';
  if position('status <> ''void''' in v_src) = 0 then
    raise exception '0087: fn_undo_defer still touches a cancelled invoice';
  end if;
end $assert$;
