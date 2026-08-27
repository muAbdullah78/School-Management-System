-- =============================================================================
-- 0077 — A charge that was wrong could only be lived with
--
-- Phase 3 of docs/SUPER-ADMIN-DESIGN.md, second of three. 0076 gave the invoices
-- a seller; this gives them a NUMBER, a TAX LINE, and the two ways a real
-- business corrects a mistake.
--
-- FOUR DEFECTS, each reproduced on a real database before it was fixed.
--
-- 1. NO DOCUMENT NUMBER
--
--    platform_invoices has a uuid primary key and nothing else. A school's
--    accountant asks "which invoice is this payment for?" and the only answer
--    the software can give is 3f2504e0-4f89-11d3-9a0c-0305e82c3301. So the
--    operator invents numbers in a notebook, and the notebook becomes the real
--    system of record.
--
--    An unbroken series also matters legally. This assigns one in a trigger, so
--    EVERY insert path gets a number including 0064's fn_activate_subscription,
--    which is not touched.
--
-- 2. AN INVOICE RAISED IN ERROR IS PERMANENT
--
--    Wrong school, wrong plan, wrong number of months, raised twice by a double
--    click. There is no update path (0064 deliberately made these tables
--    read-only through RLS) and no delete path. The invoice sits in the books
--    forever and every total is wrong forever.
--
--    Reproduced: fn_activate_subscription(<school>, 'growth', 12) run twice in
--    a row raises two invoices and bills the school Rs 76,000 for one year.
--    fn_platform_outstanding then says Rs 76,000 is owed and no function in the
--    schema can say otherwise.
--
-- 3. NO WAY TO GIVE ANYTHING BACK
--
--    Void is not the answer to every mistake. If a school paid for twelve
--    months, used four, and left, the invoice was CORRECT — voiding it would
--    erase a real sale and unbalance the books against the payment that was
--    genuinely received. What is needed is a credit note: a second document
--    that says "of that invoice, Rs 25,000 is no longer due".
--
--    So both exist, and they are not interchangeable:
--
--      VOID        the document should never have existed. Excluded from every
--                  total. Refused once anything is attached to it.
--      CREDIT NOTE the document was right and part of it is being given back.
--                  Its own number, its own row, reduces the balance.
--
--    Void is refused on an invoice that has a payment or a credit note against
--    it, precisely because that is the case a credit note exists for.
--
-- 4. WITHHOLDING TAX MADE EVERY BALANCE WRONG
--
--    This is the one that would have caused real arguments. Under section
--    153(1)(b) of the Income Tax Ordinance a Pakistani buyer of services is
--    required to deduct income tax at source and pay it to the FBR on the
--    seller's behalf. So a school invoiced Rs 38,000 pays Rs 34,960 and sends a
--    CPR for the Rs 3,040 it deducted. That money HAS been paid — to the
--    government, against our tax liability — and the certificate is how we
--    claim it.
--
--    With only `amount` on platform_payments, the software records Rs 34,960 and
--    reports Rs 3,040 outstanding. Forever. Multiply by fifty schools a year and
--    the receivable is permanently, invisibly wrong, and the operator chases
--    schools for money they already paid.
--
--    Reproduced: record a payment of 34960 against a 38000 invoice and
--    fn_platform_outstanding returns 3040 with no way to close it except a fake
--    payment or a fake discount, both of which put a lie in the books.
--
--    Fixed with tax_withheld and a certificate reference on the payment, and
--    settlement redefined as amount + tax_withheld everywhere.
--
-- WHY THE TAX RATE IS NOT APPLIED AUTOMATICALLY
--
-- Two different taxes are involved and only one of them is ours to compute:
--
--   * Income tax withholding is the BUYER's obligation. The rate depends on
--     whether the school is on the Active Taxpayer List and whether it is a
--     prescribed withholding agent at all. We cannot know either. So the invoice
--     carries a NOTE telling them the rate we expect, and the payment records
--     what they actually deducted.
--
--   * Sales tax on services is provincial — PRA in Punjab, SRB in Sindh, KPRA,
--     BRA — with different rates and different registration thresholds. If this
--     software printed a confident 16% on an invoice from an unregistered
--     business it would be inventing a tax liability. So tax_pct defaults to
--     zero and the operator sets it per invoice, from a default they configured
--     themselves in 0076.
--
-- A blank tax line is a question the operator answers once. A wrong tax line is
-- a document a customer's auditor rejects.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Columns
--
-- amount stays what it always was: the charge before tax. Everything downstream
-- moves to net_total, so an existing row with no tax and no credit note keeps
-- exactly the value it had — which is what makes this migration safe to apply to
-- live books.
-- ---------------------------------------------------------------------------
alter table public.platform_invoices
  add column if not exists kind text not null default 'invoice',
  add column if not exists credits_invoice_id uuid,
  add column if not exists serial integer,
  add column if not exists doc_no text,
  add column if not exists tax_pct numeric(5,2) not null default 0,
  add column if not exists tax_amount numeric(12,2) not null default 0,
  add column if not exists voided_at timestamptz,
  add column if not exists voided_by uuid,
  add column if not exists void_reason text;

do $ddl$
begin
  if not exists (select 1 from pg_constraint where conname = 'platform_invoices_kind_chk') then
    alter table public.platform_invoices add constraint platform_invoices_kind_chk
      check (kind in ('invoice', 'credit_note'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'platform_invoices_tax_chk') then
    alter table public.platform_invoices add constraint platform_invoices_tax_chk
      check (tax_pct >= 0 and tax_pct <= 100 and tax_amount >= 0);
  end if;
  -- A credit note without a parent is a mystery document; an invoice with one is
  -- a contradiction. Both are refused by the same constraint.
  if not exists (select 1 from pg_constraint where conname = 'platform_invoices_credits_chk') then
    alter table public.platform_invoices add constraint platform_invoices_credits_chk
      check ((kind = 'credit_note') = (credits_invoice_id is not null));
  end if;
  -- Void is either fully recorded or not recorded: a voided_at with no reason is
  -- how an unexplained hole appears in a set of books.
  if not exists (select 1 from pg_constraint where conname = 'platform_invoices_void_chk') then
    alter table public.platform_invoices add constraint platform_invoices_void_chk
      check ((voided_at is null and void_reason is null)
          or (voided_at is not null and btrim(coalesce(void_reason, '')) <> ''));
  end if;
  -- ON DELETE CASCADE on the self-reference. platform_invoices already cascades
  -- from schools, and offboarding a school deletes its invoices; without a rule
  -- here that delete would be refused by a credit note pointing at one of them.
  if not exists (select 1 from pg_constraint
                  where conname = 'platform_invoices_credits_invoice_id_fkey') then
    alter table public.platform_invoices add constraint platform_invoices_credits_invoice_id_fkey
      foreign key (credits_invoice_id) references public.platform_invoices(id)
      on delete cascade;
  end if;
end $ddl$;

-- The one number every total is computed from. Generated rather than derived in
-- each query, because "invoices minus credit notes, tax included, void excluded"
-- written out by hand in six places is five chances to write it differently —
-- and 0064's own header says a balance that two screens disagree about is the
-- defect. Void is NOT folded in here: a generated column cannot be filtered on
-- for free, and every consumer must state `voided_at is null` on purpose so that
-- forgetting it is visible in the query rather than hidden in a column.
do $gen$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'platform_invoices'
                    and column_name = 'net_total') then
    alter table public.platform_invoices
      add column net_total numeric(12,2)
        generated always as (
          case when kind = 'credit_note' then -(amount + tax_amount)
               else amount + tax_amount end) stored;
  end if;
end $gen$;

alter table public.platform_payments
  add column if not exists tax_withheld numeric(12,2) not null default 0,
  add column if not exists tax_certificate text;

do $ddl2$
begin
  if not exists (select 1 from pg_constraint where conname = 'platform_payments_wht_chk') then
    alter table public.platform_payments add constraint platform_payments_wht_chk
      check (tax_withheld >= 0);
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'platform_payments'
                    and column_name = 'settled') then
    -- What the invoice was actually settled by: the cash we received plus the tax
    -- the school paid to the FBR in our name.
    alter table public.platform_payments
      add column settled numeric(12,2)
        generated always as (amount + tax_withheld) stored;
  end if;
end $ddl2$;

create unique index if not exists idx_platform_invoices_doc_no
  on public.platform_invoices(doc_no);
create unique index if not exists idx_platform_invoices_serial
  on public.platform_invoices(kind, serial);
create index if not exists idx_platform_invoices_credits
  on public.platform_invoices(credits_invoice_id)
  where credits_invoice_id is not null;

-- ---------------------------------------------------------------------------
-- 2. The document number
--
-- In a BEFORE INSERT trigger so that every path gets one — including
-- fn_activate_subscription, which is not modified by this migration and does not
-- need to know that documents are numbered.
--
-- pg_advisory_xact_lock, not just the unique index: max(serial)+1 read by two
-- concurrent transactions returns the same number to both, and one of them then
-- fails on the index. A failed renewal because somebody else renewed at the same
-- moment is the kind of fault that happens once a year and is never reproduced.
-- The lock is per kind, held to the end of the transaction, and released
-- automatically on rollback.
--
-- The prefix is read at INSERT and stored. Changing invoice_prefix in Settings
-- therefore renames nothing that has already been issued — a document a customer
-- is holding must not change its number — and the serial keeps counting, so the
-- series stays unbroken across a rename.
-- ---------------------------------------------------------------------------
create or replace function public.fn__assign_doc_no()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_prefix text; v_serial integer;
begin
  if new.doc_no is not null and new.serial is not null then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtext('platform_doc_no'), hashtext(new.kind));

  select case when new.kind = 'credit_note' then credit_prefix else invoice_prefix end
    into v_prefix from public.platform_settings where id;
  v_prefix := coalesce(v_prefix,
    case when new.kind = 'credit_note' then 'CN' else 'INV' end);

  select coalesce(max(i.serial), 0) + 1 into v_serial
    from public.platform_invoices i where i.kind = new.kind;

  new.serial := v_serial;
  new.doc_no := v_prefix || '-' || lpad(v_serial::text, 4, '0');
  return new;
end;
$$;

revoke all on function public.fn__assign_doc_no() from public, anon, authenticated;

drop trigger if exists trg_assign_doc_no on public.platform_invoices;
create trigger trg_assign_doc_no
  before insert on public.platform_invoices
  for each row execute function public.fn__assign_doc_no();

-- Numbers for whatever is already on the books, in the order they were issued.
-- Without this every existing invoice has a null doc_no and the printable
-- document has a blank where its number goes — and because the unique index
-- permits many nulls, nothing would complain.
do $backfill$
declare r record; v_n integer := 0; v_prefix text; v_serial integer;
begin
  select invoice_prefix into v_prefix from public.platform_settings where id;
  v_prefix := coalesce(v_prefix, 'INV');
  select coalesce(max(serial), 0) into v_serial
    from public.platform_invoices where kind = 'invoice';
  for r in
    select id from public.platform_invoices
     where doc_no is null and kind = 'invoice'
     order by issued_on, created_at, id
  loop
    v_serial := v_serial + 1;
    update public.platform_invoices
       set serial = v_serial,
           doc_no = v_prefix || '-' || lpad(v_serial::text, 4, '0')
     where id = r.id;
    v_n := v_n + 1;
  end loop;
  if v_n > 0 then
    raise notice '0077: numbered % existing invoice(s)', v_n;
  end if;
end $backfill$;

-- ---------------------------------------------------------------------------
-- 3. The two totals, in one place each
--
-- Every screen that shows money now calls these. Named with fn__ and revoked:
-- they take a school id and answer without checking who is asking, so they must
-- never be reachable from a browser. Their callers do the gating.
-- ---------------------------------------------------------------------------
create or replace function public.fn__platform_billed(p_school_id uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(net_total), 0)
    from public.platform_invoices
   where school_id = p_school_id and voided_at is null;
$$;

create or replace function public.fn__platform_settled(p_school_id uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(settled), 0)
    from public.platform_payments
   where school_id = p_school_id;
$$;

revoke all on function public.fn__platform_billed(uuid)  from public, anon, authenticated;
revoke all on function public.fn__platform_settled(uuid) from public, anon, authenticated;

create or replace function public.fn_platform_outstanding(p_school_id uuid)
returns numeric language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return public.fn__platform_billed(p_school_id) - public.fn__platform_settled(p_school_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Void
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_void_invoice(
  p_invoice_id uuid, p_reason text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_inv record; v_pay numeric; v_cred numeric; v_warn text;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_reason is null then
    raise exception 'Voiding a document needs a reason — it is printed on it';
  end if;

  select * into v_inv from public.platform_invoices where id = p_invoice_id;
  if not found then
    raise exception 'No such document';
  end if;
  if v_inv.voided_at is not null then
    raise exception 'That document was already voided on %', v_inv.voided_at::date;
  end if;

  -- The two refusals that keep the books consistent.
  select coalesce(sum(settled), 0) into v_pay
    from public.platform_payments where invoice_id = p_invoice_id;
  if v_pay > 0 then
    raise exception
      'Cannot void %: % has been received against it. Raise a credit note instead.',
      v_inv.doc_no, to_char(v_pay, 'FM999999999.00');
  end if;

  select coalesce(sum(amount + tax_amount), 0) into v_cred
    from public.platform_invoices
   where credits_invoice_id = p_invoice_id and voided_at is null;
  if v_cred > 0 then
    raise exception
      'Cannot void %: a credit note has already been raised against it. Void the '
      'credit note first if that was the mistake.', v_inv.doc_no;
  end if;

  -- The licence is NOT rolled back, and saying so beats leaving it to be
  -- discovered. fn_activate_subscription both charges and extends; voiding the
  -- charge is a correction to the books, not a repossession of the year. If the
  -- school should not have the time either, the operator changes the licence
  -- with the licence tools — deliberately, as a second decision.
  if exists (select 1 from public.subscriptions s
              where s.school_id = v_inv.school_id
                and s.period_start = v_inv.period_start
                and s.period_end = v_inv.period_end) then
    v_warn := format(
      'The licence still runs %s to %s. Voiding this invoice does not shorten it — '
      'change the plan or cancel separately if that was also wrong.',
      v_inv.period_start, v_inv.period_end);
  end if;

  update public.platform_invoices
     set voided_at = now(), voided_by = auth.uid(), void_reason = v_reason
   where id = p_invoice_id;

  perform public.fn__log_operator_action(
    case when v_inv.kind = 'credit_note' then 'credit_note_voided' else 'invoice_voided' end,
    v_inv.school_id,
    jsonb_build_object('invoice_id', p_invoice_id, 'doc_no', v_inv.doc_no,
                       'amount', v_inv.amount, 'tax_amount', v_inv.tax_amount,
                       'reason', v_reason, 'licence_untouched', v_warn is not null));

  insert into public.audit_log(school_id, actor, action, entity, entity_id, before, reason)
  values (v_inv.school_id, auth.uid(), 'platform_invoice_voided', 'platform_invoices',
          p_invoice_id::text,
          jsonb_build_object('doc_no', v_inv.doc_no, 'amount', v_inv.amount,
                             'tax_amount', v_inv.tax_amount),
          v_reason);

  return jsonb_build_object(
    'invoice_id', p_invoice_id, 'doc_no', v_inv.doc_no, 'voided', true,
    'warning', v_warn,
    'outstanding', public.fn_platform_outstanding(v_inv.school_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Credit note
--
-- Its own document in its own series, carrying the plan and period of the
-- invoice it credits so that "what was this about" is answerable from the credit
-- note alone. Capped at the uncredited remainder of the original: crediting more
-- than was charged turns a receivable into a liability the software cannot pay.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_credit_note(
  p_invoice_id uuid,
  p_amount numeric,
  p_reason text,
  -- Null means "credit the tax in proportion", which is right in every ordinary
  -- case. Explicit means the operator is crediting only the net, or only the
  -- tax, and knows why.
  p_tax_amount numeric default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_inv record; v_credited numeric; v_room numeric;
  v_tax numeric; v_id uuid; v_doc text;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_reason is null then
    raise exception 'A credit note needs a reason — it is printed on it';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'A credit note must be more than zero';
  end if;

  select * into v_inv from public.platform_invoices where id = p_invoice_id;
  if not found then
    raise exception 'No such invoice';
  end if;
  if v_inv.kind <> 'invoice' then
    raise exception 'Credit notes are raised against invoices, not against %', v_inv.kind;
  end if;
  if v_inv.voided_at is not null then
    raise exception 'That invoice is voided — there is nothing to credit';
  end if;

  v_tax := case
    when p_tax_amount is not null then round(p_tax_amount, 2)
    when v_inv.amount > 0 then round(v_inv.tax_amount * (p_amount / v_inv.amount), 2)
    else 0 end;
  if v_tax < 0 then
    raise exception 'A tax credit cannot be negative';
  end if;

  select coalesce(sum(amount + tax_amount), 0) into v_credited
    from public.platform_invoices
   where credits_invoice_id = p_invoice_id and voided_at is null;

  v_room := (v_inv.amount + v_inv.tax_amount) - v_credited;
  if round(p_amount + v_tax, 2) > v_room then
    raise exception
      'That would credit % against %, which is % and already has % credited. '
      'At most % remains.',
      to_char(p_amount + v_tax, 'FM999999999.00'), v_inv.doc_no,
      to_char(v_inv.amount + v_inv.tax_amount, 'FM999999999.00'),
      to_char(v_credited, 'FM999999999.00'), to_char(v_room, 'FM999999999.00');
  end if;

  insert into public.platform_invoices
    (school_id, kind, credits_invoice_id, plan_code, cycle, months,
     period_start, period_end, amount, list_amount, tax_pct, tax_amount,
     issued_on, due_on, note, created_by)
  values
    (v_inv.school_id, 'credit_note', p_invoice_id, v_inv.plan_code, v_inv.cycle,
     v_inv.months, v_inv.period_start, v_inv.period_end,
     round(p_amount, 2),
     -- list_amount equals amount on a credit note, so fn_platform_revenue's
     -- discount figure — sum(list_amount - amount) — is untouched by credits. A
     -- refund is not a discount and must not appear as one.
     round(p_amount, 2),
     v_inv.tax_pct, v_tax,
     current_date, null,
     format('Credit against %s — %s', v_inv.doc_no, v_reason),
     auth.uid())
  returning id, doc_no into v_id, v_doc;

  insert into public.audit_log(school_id, actor, action, entity, entity_id, after, reason)
  values (v_inv.school_id, auth.uid(), 'platform_credit_note', 'platform_invoices',
          v_id::text,
          jsonb_build_object('doc_no', v_doc, 'credits', v_inv.doc_no,
                             'amount', round(p_amount, 2), 'tax_amount', v_tax),
          v_reason);

  return jsonb_build_object(
    'credit_note_id', v_id, 'doc_no', v_doc,
    'credits_doc_no', v_inv.doc_no,
    'amount', round(p_amount, 2), 'tax_amount', v_tax,
    'total', round(p_amount, 2) + v_tax,
    'outstanding', public.fn_platform_outstanding(v_inv.school_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Recording a payment, with the tax the school withheld
--
-- Replaces 0064's version. DROP first: the parameter list grows, and leaving the
-- 7-argument form as an overload would mean the console could still call the one
-- that cannot record a withholding certificate — which is defect 4.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_platform_record_payment(uuid, numeric, date, text, text, uuid, text);
drop function if exists public.fn_platform_record_payment(uuid, numeric, date, text, text, uuid, text, numeric, text);

create function public.fn_platform_record_payment(
  p_school_id uuid,
  p_amount numeric,
  p_paid_on date default null,
  p_method text default 'bank',
  p_reference text default null,
  p_invoice_id uuid default null,
  p_note text default null,
  -- What the school deducted and paid to the FBR on our behalf. Zero for a
  -- school that is not a withholding agent, which is most of them.
  p_tax_withheld numeric default 0,
  p_tax_certificate text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_actor uuid := auth.uid();
  v_tax numeric := round(coalesce(p_tax_withheld, 0), 2);
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'A payment must be more than zero';
  end if;
  if v_tax < 0 then
    raise exception 'Withheld tax cannot be negative';
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
  -- Allocating cash to a document that has been cancelled is how a void invoice
  -- comes back to life as a balance nobody can explain.
  if p_invoice_id is not null
     and exists (select 1 from public.platform_invoices
                  where id = p_invoice_id and voided_at is not null) then
    raise exception 'That invoice is voided — allocate the payment elsewhere or leave it unallocated';
  end if;
  -- A certificate number with no tax against it, or tax with no certificate, is
  -- half a record. The second is a warning rather than a refusal: the CPR often
  -- arrives weeks after the transfer, and refusing the payment until it does
  -- would push the operator back to the notebook.
  if v_tax = 0 and nullif(btrim(coalesce(p_tax_certificate, '')), '') is not null then
    raise exception 'A tax certificate was given but no withheld amount';
  end if;

  insert into public.platform_payments
    (school_id, invoice_id, amount, paid_on, method, reference, note, created_by,
     tax_withheld, tax_certificate)
  values (p_school_id, p_invoice_id, p_amount,
          coalesce(p_paid_on, current_date), coalesce(p_method, 'bank'),
          nullif(btrim(coalesce(p_reference, '')), ''),
          nullif(btrim(coalesce(p_note, '')), ''), v_actor,
          v_tax, nullif(btrim(coalesce(p_tax_certificate, '')), ''))
  returning id into v_id;

  insert into public.audit_log(school_id, actor, action, entity, entity_id, after, reason)
  values (p_school_id, v_actor, 'platform_payment_recorded', 'platform_payments',
          v_id::text,
          jsonb_build_object('amount', p_amount, 'method', coalesce(p_method, 'bank'),
                             'paid_on', coalesce(p_paid_on, current_date),
                             'invoice_id', p_invoice_id,
                             'tax_withheld', v_tax,
                             'tax_certificate', nullif(btrim(coalesce(p_tax_certificate, '')), '')),
          nullif(btrim(coalesce(p_note, '')), ''));

  return jsonb_build_object(
    'payment_id', v_id, 'school_id', p_school_id, 'amount', p_amount,
    'tax_withheld', v_tax, 'settled', p_amount + v_tax,
    'awaiting_certificate', v_tax > 0
      and nullif(btrim(coalesce(p_tax_certificate, '')), '') is null,
    'outstanding', public.fn_platform_outstanding(p_school_id));
end;
$$;

-- The CPR arriving later is the normal case, so there is a way to attach it
-- without inventing a second payment.
create or replace function public.fn_platform_attach_tax_certificate(
  p_payment_id uuid, p_certificate text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_pay record; v_cert text := nullif(btrim(coalesce(p_certificate, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_cert is null then
    raise exception 'Give the certificate or CPR number';
  end if;
  select * into v_pay from public.platform_payments where id = p_payment_id;
  if not found then
    raise exception 'No such payment';
  end if;
  if v_pay.tax_withheld <= 0 then
    raise exception 'No tax was withheld on that payment';
  end if;

  update public.platform_payments set tax_certificate = v_cert where id = p_payment_id;

  perform public.fn__log_operator_action('tax_certificate_attached', v_pay.school_id,
    jsonb_build_object('payment_id', p_payment_id, 'tax_withheld', v_pay.tax_withheld,
                       'certificate', v_cert));

  return jsonb_build_object('payment_id', p_payment_id, 'tax_certificate', v_cert);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Setting the tax line on an invoice
--
-- Separate from raising it, because the operator often does not know the rate at
-- the moment they grant the licence — and a renewal must not be blocked waiting
-- for a tax question. Refused once the invoice has been paid or credited: the
-- total on the document the customer is holding must not change under them.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_set_invoice_tax(
  p_invoice_id uuid, p_tax_pct numeric, p_tax_amount numeric default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_inv record; v_pct numeric; v_amt numeric; v_touched numeric;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into v_inv from public.platform_invoices where id = p_invoice_id;
  if not found then
    raise exception 'No such invoice';
  end if;
  if v_inv.voided_at is not null then
    raise exception 'That invoice is voided';
  end if;
  if v_inv.kind <> 'invoice' then
    raise exception 'Tax is set on the invoice, not on the credit note';
  end if;

  select coalesce(sum(settled), 0) into v_touched
    from public.platform_payments where invoice_id = p_invoice_id;
  if v_touched > 0 then
    raise exception
      'Cannot change the tax on %: % has been received against it. Raise a credit '
      'note and a fresh invoice.', v_inv.doc_no, to_char(v_touched, 'FM999999999.00');
  end if;
  if exists (select 1 from public.platform_invoices
              where credits_invoice_id = p_invoice_id and voided_at is null) then
    raise exception 'Cannot change the tax on %: it has a credit note against it', v_inv.doc_no;
  end if;

  v_pct := round(coalesce(p_tax_pct, 0), 2);
  if v_pct < 0 or v_pct > 100 then
    raise exception 'A tax rate must be between 0 and 100';
  end if;
  v_amt := round(coalesce(p_tax_amount, v_inv.amount * v_pct / 100), 2);
  if v_amt < 0 then
    raise exception 'A tax amount cannot be negative';
  end if;

  update public.platform_invoices
     set tax_pct = v_pct, tax_amount = v_amt where id = p_invoice_id;

  perform public.fn__log_operator_action('invoice_tax_set', v_inv.school_id,
    jsonb_build_object('invoice_id', p_invoice_id, 'doc_no', v_inv.doc_no,
                       'tax_pct', v_pct, 'tax_amount', v_amt,
                       'was_tax_amount', v_inv.tax_amount));

  return jsonb_build_object('invoice_id', p_invoice_id, 'doc_no', v_inv.doc_no,
    'tax_pct', v_pct, 'tax_amount', v_amt, 'total', v_inv.amount + v_amt,
    'outstanding', public.fn_platform_outstanding(v_inv.school_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. The printable document
--
-- Everything needed to render one invoice or credit note, in one call, so the
-- printable page cannot be assembled from three queries that disagree.
--
-- `seller_missing` is repeated here from 0076 on purpose: the moment somebody is
-- about to print is the moment a blank NTN matters, and a warning on the Settings
-- screen they configured six months ago is a warning they will not see.
-- ---------------------------------------------------------------------------
create or replace function public.fn__invoice_document(p_invoice_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_inv record; v_s record; v_set record; v_ss record;
  v_plan text; v_credits numeric; v_paid numeric; v_missing text[] := '{}';
  v_total numeric;
begin
  select * into v_inv from public.platform_invoices where id = p_invoice_id;
  if not found then
    raise exception 'No such document';
  end if;

  select * into v_s   from public.schools         where id = v_inv.school_id;
  select * into v_ss  from public.school_settings where school_id = v_inv.school_id;
  select * into v_set from public.platform_settings where id;
  select name into v_plan from public.plans where code = v_inv.plan_code;

  if btrim(coalesce(v_set.business_name, '')) = '' then
    v_missing := array_append(v_missing, 'business_name'); end if;
  if btrim(coalesce(v_set.ntn, '')) = '' then
    v_missing := array_append(v_missing, 'ntn'); end if;
  if btrim(coalesce(v_set.address, '')) = '' then
    v_missing := array_append(v_missing, 'address'); end if;
  if btrim(coalesce(v_set.bank_account, '')) = '' then
    v_missing := array_append(v_missing, 'bank_account'); end if;

  select coalesce(sum(amount + tax_amount), 0) into v_credits
    from public.platform_invoices
   where credits_invoice_id = p_invoice_id and voided_at is null;
  select coalesce(sum(settled), 0) into v_paid
    from public.platform_payments where invoice_id = p_invoice_id;

  v_total := v_inv.amount + v_inv.tax_amount;

  return jsonb_build_object(
    'id', v_inv.id,
    'kind', v_inv.kind,
    'doc_no', v_inv.doc_no,
    'title', case when v_inv.kind = 'credit_note' then 'CREDIT NOTE' else 'INVOICE' end,
    'issued_on', v_inv.issued_on,
    'due_on', v_inv.due_on,
    'voided', v_inv.voided_at is not null,
    'voided_at', v_inv.voided_at,
    'void_reason', v_inv.void_reason,
    'credits_doc_no', (select doc_no from public.platform_invoices
                        where id = v_inv.credits_invoice_id),

    'seller', jsonb_build_object(
      'name', nullif(btrim(coalesce(v_set.business_name, '')), ''),
      'ntn', v_set.ntn, 'strn', v_set.strn,
      'address', v_set.address, 'city', v_set.city,
      'phone', v_set.phone, 'email', v_set.email, 'website', v_set.website),
    'seller_missing', to_jsonb(v_missing),

    -- The school's own registered name and address from school_settings where it
    -- has one, falling back to the signup record. An invoice addressed to
    -- "Al-Noor" when the school calls itself "Al-Noor Public School, Gujranwala"
    -- is an invoice their accountant queries.
    'buyer', jsonb_build_object(
      'school_id', v_s.id,
      'name', coalesce(nullif(btrim(coalesce(v_ss.name, '')), ''), v_s.name),
      'address', coalesce(v_ss.address, v_s.city),
      'city', v_s.city,
      'phone', coalesce(v_ss.phone, v_s.contact_phone),
      'email', coalesce(v_ss.email, v_s.contact_email),
      'attention', coalesce(v_ss.principal_name, v_s.contact_name)),

    -- One line, which is what is actually being sold: a licence for a period.
    -- An itemised breakdown of a single subscription would be invented detail.
    'lines', jsonb_build_array(jsonb_build_object(
      'description', format('%s plan — school management software licence',
                            coalesce(v_plan, v_inv.plan_code)),
      -- The RAW dates, not a formatted string. Rendering them here would put
      -- "2026-09-01" on a document whose every other date reads "26 Aug 2026",
      -- and a customer's accountant notices that before they notice the total.
      -- Formatting is the client's job, in one place, for the whole document.
      'period_start', v_inv.period_start,
      'period_end', v_inv.period_end,
      'months', v_inv.months,
      'cycle', v_inv.cycle,
      'amount', v_inv.amount,
      -- Shown only when it differs, and then it is the whole point of showing it.
      'list_amount', case when v_inv.kind = 'invoice'
                           and v_inv.list_amount <> v_inv.amount
                          then v_inv.list_amount else null end)),

    'tax', jsonb_build_object(
      'pct', v_inv.tax_pct, 'amount', v_inv.tax_amount,
      'label', case when v_inv.tax_pct > 0
                    then format('Sales tax on services @ %s%%',
                                trim(to_char(v_inv.tax_pct, 'FM999.99')))
                    else null end),

    'totals', jsonb_build_object(
      'subtotal', v_inv.amount,
      'tax', v_inv.tax_amount,
      'total', v_total,
      'credited', v_credits,
      'paid', v_paid,
      -- On this document only. The school's overall balance is a different
      -- number and putting it here would make one invoice look unpaid because
      -- another one is.
      'balance', v_total - v_credits - v_paid),

    'amount_in_words', public.fn__amount_in_words(v_total),

    'bank', case when v_inv.kind = 'credit_note' then 'null'::jsonb else
      jsonb_build_object(
        'bank_name', v_set.bank_name, 'title', v_set.bank_title,
        'account', v_set.bank_account, 'iban', v_set.bank_iban) end,

    -- The sentence that stops the argument in defect 4 before it starts. Printed
    -- only when a rate is configured, and it asks for the CPR because that is the
    -- document we need in order to claim the deduction.
    'withholding_note', case
      when v_inv.kind <> 'invoice' or coalesce(v_set.default_withholding_pct, 0) <= 0
        then null
      else format(
        'If you are required to deduct income tax at source under section 153(1)(b), '
        'please deduct %s%% (Rs %s) and remit the balance of Rs %s. Kindly send us '
        'the CPR / tax deduction certificate so the deduction can be credited to '
        'this invoice.',
        trim(to_char(v_set.default_withholding_pct, 'FM999.99')),
        to_char(round(v_total * v_set.default_withholding_pct / 100, 2), 'FM999,999,999.00'),
        to_char(round(v_total - v_total * v_set.default_withholding_pct / 100, 2),
                'FM999,999,999.00')) end,

    'note', v_inv.note,
    'footer', v_set.invoice_footer,

    'payments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'paid_on', p.paid_on, 'amount', p.amount, 'method', p.method,
               'reference', p.reference, 'tax_withheld', p.tax_withheld,
               'tax_certificate', p.tax_certificate, 'settled', p.settled)
             order by p.paid_on, p.created_at)
        from public.platform_payments p where p.invoice_id = p_invoice_id), '[]'::jsonb),

    'credit_notes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'doc_no', c.doc_no, 'issued_on', c.issued_on,
               'amount', c.amount, 'tax_amount', c.tax_amount,
               'total', c.amount + c.tax_amount, 'note', c.note,
               'voided', c.voided_at is not null)
             order by c.issued_on, c.serial)
        from public.platform_invoices c
       where c.credits_invoice_id = p_invoice_id), '[]'::jsonb));
end;
$$;

revoke all on function public.fn__invoice_document(uuid) from public, anon, authenticated;

-- The operator's door to it.
create or replace function public.fn_platform_invoice(p_invoice_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return public.fn__invoice_document(p_invoice_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. The ledger, with document numbers on it
--
-- DROP first: three columns are added, which `create or replace` cannot do.
-- Before this, the ledger's rows could not be pointed at — "the Rs 38,000 one"
-- was the only way to refer to a line, and with two renewals of the same plan in
-- a year that is ambiguous.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_platform_ledger(uuid);
create function public.fn_platform_ledger(p_school_id uuid)
returns table (
  entry_id uuid, entry_date date, kind text, doc_no text, description text,
  charged numeric, paid numeric, voided boolean, note text, reference text
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  -- Wrapped in a subquery so the sort can be an EXPRESSION. A set operation's
  -- ORDER BY may only name output columns, and the natural reading order needs
  -- "documents before the payment that settles them" on a shared date — which
  -- alphabetical order on `kind` gets backwards.
  return query
  select x.entry_id, x.entry_date, x.kind, x.doc_no, x.description,
         x.charged, x.paid, x.voided, x.note, x.reference
    from (
      select i.id as entry_id, i.issued_on as entry_date, i.kind as kind,
             i.doc_no as doc_no,
             case when i.kind = 'credit_note'
                  then format('Credit against %s',
                              coalesce((select c.doc_no from public.platform_invoices c
                                         where c.id = i.credits_invoice_id), 'an invoice'))
                  else format('%s · %s month%s · %s to %s', i.plan_code, i.months,
                              case when i.months = 1 then '' else 's' end,
                              i.period_start, i.period_end) end as description,
             -- Signed, and zero for a void document: a voided invoice stays
             -- visible as a row — deleting history is how a business loses an
             -- audit — but it must not add up to anything.
             case when i.voided_at is not null then 0::numeric
                  else i.net_total end as charged,
             null::numeric as paid,
             (i.voided_at is not null) as voided,
             case
               when i.voided_at is not null
                 then format('VOID — %s', i.void_reason)
               -- A discount only reads as a discount next to the list price.
               when i.kind = 'invoice' and i.amount <> i.list_amount
                 then format('list %s — %s', to_char(i.list_amount, 'FM999999999.00'),
                             coalesce(i.note, 'no reason recorded'))
               else i.note end as note,
             null::text as reference
        from public.platform_invoices i
       where i.school_id = p_school_id
      union all
      select p.id, p.paid_on, 'payment'::text, null::text,
             case when p.tax_withheld > 0
                  then format('%s payment + %s tax withheld', p.method,
                              to_char(p.tax_withheld, 'FM999999999.00'))
                  else format('%s payment', p.method) end,
             null::numeric,
             p.settled,
             false,
             case when p.tax_withheld > 0 and p.tax_certificate is null
                  then btrim(coalesce(p.note || ' — ', '') || 'CPR not received yet')
                  else p.note end,
             p.reference
        from public.platform_payments p
       where p.school_id = p_school_id
    ) x
   order by x.entry_date,
            case when x.kind = 'payment' then 2 else 1 end,
            x.doc_no nulls last;
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. The two roll-ups
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_revenue(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_invoiced numeric; v_collected numeric; v_discounted numeric;
  v_credited numeric; v_withheld numeric;
  v_outstanding numeric; v_by_plan jsonb; v_owing jsonb;
  v_voided numeric; v_awaiting numeric;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Give a start date and an end date, the end not before the start';
  end if;

  select coalesce(sum(amount + tax_amount), 0), coalesce(sum(list_amount - amount), 0)
    into v_invoiced, v_discounted
    from public.platform_invoices
   where issued_on between p_from and p_to and kind = 'invoice' and voided_at is null;

  select coalesce(sum(amount + tax_amount), 0) into v_credited
    from public.platform_invoices
   where issued_on between p_from and p_to and kind = 'credit_note' and voided_at is null;

  -- Voided in this window, reported rather than silently dropped: a month where
  -- three invoices were cancelled is a month somebody should look at.
  select coalesce(sum(amount + tax_amount), 0) into v_voided
    from public.platform_invoices
   where issued_on between p_from and p_to and voided_at is not null;

  -- Collected is what SETTLED, cash plus withheld tax, because the withheld part
  -- was paid — to the FBR, against our liability. Reported separately too, since
  -- it is not money in the bank and a cash-flow question needs the difference.
  select coalesce(sum(settled), 0), coalesce(sum(tax_withheld), 0)
    into v_collected, v_withheld
    from public.platform_payments
   where paid_on between p_from and p_to;

  select coalesce(sum(tax_withheld), 0) into v_awaiting
    from public.platform_payments
   where tax_withheld > 0 and tax_certificate is null;

  select coalesce(jsonb_agg(x order by x->>'plan_code'), '[]'::jsonb) into v_by_plan
    from (
      select jsonb_build_object('plan_code', plan_code,
                                'invoices', count(*),
                                'amount', sum(amount + tax_amount)) as x
        from public.platform_invoices
       where issued_on between p_from and p_to and kind = 'invoice' and voided_at is null
       group by plan_code) g;

  -- Everything ever billed minus everything ever settled: a receivable does not
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
                 public.fn__platform_billed(s.id) - public.fn__platform_settled(s.id) as owed
            from public.schools s) bal
       where bal.owed > 0) o;

  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    'invoiced', v_invoiced, 'collected', v_collected,
    'discounted', v_discounted,
    'credited', v_credited,
    'voided', v_voided,
    'net_invoiced', v_invoiced - v_credited,
    'cash_received', v_collected - v_withheld,
    'tax_withheld', v_withheld,
    'tax_certificates_awaited', v_awaiting,
    'outstanding_total', v_outstanding,
    'by_plan', v_by_plan,
    'schools_owing', v_owing);
end;
$$;

create or replace function public.fn_platform_schools()
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
      public.fn__platform_billed(s.id) - public.fn__platform_settled(s.id),
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
-- 11. The insert log has to know a credit note when it sees one
--
-- 0073's trigger labels every platform_invoices insert 'invoice_raised'. A
-- credit note is the opposite of raising an invoice and an activity feed that
-- calls it one is worse than an empty feed.
-- ---------------------------------------------------------------------------
create or replace function public.fn__log_platform_invoice()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.fn__log_operator_action(
    case when new.kind = 'credit_note' then 'credit_note_raised' else 'invoice_raised' end,
    new.school_id,
    jsonb_build_object(
      'invoice_id',  new.id,
      'doc_no',      new.doc_no,
      'kind',        new.kind,
      'credits_invoice_id', new.credits_invoice_id,
      'plan_code',   new.plan_code,
      'months',      new.months,
      'amount',      new.amount,
      'tax_amount',  new.tax_amount,
      'total',       new.amount + new.tax_amount,
      -- The number that makes a discount visible. 0064 records list_amount so
      -- "given away" can be computed; recording the gap here means the reason
      -- and the amount sit in one row rather than being joined back together.
      'list_amount', new.list_amount,
      'discount',    case when new.kind = 'invoice'
                          then coalesce(new.list_amount, new.amount) - new.amount
                          else 0 end,
      'note',        new.note));
  return null;
end;
$$;

revoke all on function public.fn__log_platform_invoice() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 12. The school detail screen's money block
--
-- 0075's fn_platform_school_detail computes its own invoiced/paid with two
-- inline sums, which after this migration would ignore void documents, credit
-- notes and withheld tax — three ways for the operator console to disagree with
-- the ledger about what a school owes.
--
-- Rewritten in place rather than restated: repeating two hundred lines of a
-- function to change three statements is how two versions of it end up in the
-- repository. The END STATE is asserted, so a partial match raises here rather
-- than passing quietly — a threshold check that tolerates a partial revert has
-- bitten this project more than once.
-- ---------------------------------------------------------------------------
do $rewrite$
declare
  v_src text;
  v_new text;
begin
  v_src := pg_get_functiondef('public.fn_platform_school_detail(uuid)'::regprocedure);
  v_new := v_src;

  -- Matched with regexp_replace and \s+ for the line breaks rather than on an
  -- exact string. An earlier version of this technique in 0072 matched on
  -- literal text and the indentation of the target had to be counted by hand;
  -- one wrong space and the replacement silently does not happen, which is why
  -- the end state below is asserted rather than the edit count.

  -- (a) invoiced → net of credit notes, void excluded
  v_new := regexp_replace(v_new,
    'select coalesce\(sum\(amount\), 0\) into v_invoiced from public\.platform_invoices\s+where school_id = p_school_id;',
    'v_invoiced := public.fn__platform_billed(p_school_id);');

  -- (b) paid → settled, so withheld tax counts as paid
  v_new := regexp_replace(v_new,
    'select coalesce\(sum\(amount\), 0\) into v_paid from public\.platform_payments\s+where school_id = p_school_id;',
    'v_paid := public.fn__platform_settled(p_school_id);');

  -- (c) the invoice count must not count cancelled paperwork
  v_new := regexp_replace(v_new,
    '''invoice_count'', \(select count\(\*\) from public\.platform_invoices\s+where school_id = p_school_id\)',
    '''invoice_count'', (select count(*) from public.platform_invoices'
      || E'\n                         where school_id = p_school_id'
      || E'\n                           and kind = ''invoice'' and voided_at is null)');

  if v_new <> v_src then
    execute v_new;
  end if;

  -- Assert the END STATE, not the number of edits: this is what makes the block
  -- safe to re-run and impossible to satisfy halfway. A threshold or a count
  -- would pass over a PARTIAL rewrite, which has bitten this project more than
  -- once.
  v_src := pg_get_functiondef('public.fn_platform_school_detail(uuid)'::regprocedure);
  if position('fn__platform_billed(p_school_id)' in v_src) = 0
     or position('fn__platform_settled(p_school_id)' in v_src) = 0 then
    raise exception '0077: fn_platform_school_detail still computes its own totals — the statement it was matched on has changed. Fix the rewrite above.';
  end if;
  if position('kind = ''invoice'' and voided_at is null' in v_src) = 0 then
    raise exception '0077: fn_platform_school_detail still counts voided invoices';
  end if;
  if position('into v_invoiced from public.platform_invoices' in v_src) > 0
     or position('into v_paid from public.platform_payments' in v_src) > 0 then
    raise exception '0077: the old inline sums are still in fn_platform_school_detail';
  end if;
  raise notice '0077: fn_platform_school_detail money block rewritten';
end $rewrite$;

-- ---------------------------------------------------------------------------
-- 13. Grants
-- ---------------------------------------------------------------------------
grant  execute on function public.fn_platform_void_invoice(uuid, text)   to authenticated;
revoke execute on function public.fn_platform_void_invoice(uuid, text) from public, anon;
grant  execute on function public.fn_platform_credit_note(uuid, numeric, text, numeric)   to authenticated;
revoke execute on function public.fn_platform_credit_note(uuid, numeric, text, numeric) from public, anon;
grant  execute on function public.fn_platform_set_invoice_tax(uuid, numeric, numeric)   to authenticated;
revoke execute on function public.fn_platform_set_invoice_tax(uuid, numeric, numeric) from public, anon;
grant  execute on function public.fn_platform_attach_tax_certificate(uuid, text)   to authenticated;
revoke execute on function public.fn_platform_attach_tax_certificate(uuid, text) from public, anon;
grant  execute on function public.fn_platform_invoice(uuid)   to authenticated;
revoke execute on function public.fn_platform_invoice(uuid) from public, anon;
grant  execute on function public.fn_platform_ledger(uuid)   to authenticated;
revoke execute on function public.fn_platform_ledger(uuid) from public, anon;
grant  execute on function
  public.fn_platform_record_payment(uuid, numeric, date, text, text, uuid, text, numeric, text)
  to authenticated;
revoke execute on function
  public.fn_platform_record_payment(uuid, numeric, date, text, text, uuid, text, numeric, text)
  from public, anon;
