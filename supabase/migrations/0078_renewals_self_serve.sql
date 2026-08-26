-- =============================================================================
-- 0078 — Renewals were remembered, or they were not
--
-- Phase 3 of docs/SUPER-ADMIN-DESIGN.md, third of three. 0076 gave the invoices
-- a seller, 0077 gave them numbers and corrections. This is the part that decides
-- whether the business survives fifty customers.
--
-- THREE DEFECTS
--
-- 1. NOTHING TELLS THE OPERATOR A RENEWAL IS COMING
--
--    fn_platform_schools returns days_left and the console sorts by name. With
--    three schools that is fine — you know them. With fifty, a licence that
--    expired eleven days ago is row 34 of an alphabetical list, and the first
--    anyone hears of it is the principal phoning to say the software has locked.
--
--    That call is the worst possible moment for the renewal conversation: the
--    school is angry, the office is full of parents, and the vendor is the
--    reason nobody can take a fee. A renewal reminder sent 30 days earlier is
--    the same money and none of that.
--
-- 2. THE OPERATOR COULD RENEW A SCHOOL TWICE AND NOT KNOW
--
--    fn_activate_subscription extends from period_end when the licence is still
--    live, so running it twice grants two years and raises two invoices — the
--    reproduction in 0077's header.
--
--    THE FIRST VERSION OF THIS MIGRATION GOT THE FIX WRONG, and the test caught
--    it, so the reasoning is recorded rather than quietly corrected.
--
--    It reported `already_invoiced` on the worklist: an unvoided invoice whose
--    period starts after the current period ends. That column can never be
--    true. Activation raises the invoice AND extends period_end in the same
--    statement, so the newest invoice's period always ENDS at period_end, never
--    starts after it. A double renewal produces two contiguous invoices and a
--    period_end that moved twice — and no comparison between the invoices and
--    the subscription can tell that apart from one long renewal. The column
--    would have shipped reading `false` for every school on every screen and
--    looked like a working safeguard.
--
--    The fix belongs where the writing happens, not on the screen that reads it:
--    a trigger refuses an invoice that duplicates an existing one exactly — same
--    school, same plan, same period, not voided. Raising the same document twice
--    is never legitimate, so it needs no override, and a double click on Renew
--    is precisely the case where the second transaction has not seen the first
--    and computes the identical period.
--
--    What the worklist reports instead is `invoiced_to` — the furthest date any
--    unvoided invoice covers — beside `expires_on`. That comparison answers a
--    question the software genuinely could not answer before: this school has
--    licence time nobody billed for. `unbilled_days` names it, and
--    `never_invoiced` marks a school running on a trial or a favour.
--
-- 3. THE SCHOOL COULD NOT SEE ITS OWN BILL, OR TELL US IT HAD PAID
--
--    This is the defect that generates the phone calls. Today a school:
--      * cannot see what it was invoiced, or its balance
--      * cannot get a copy of an invoice for its own accounts
--      * does not know which bank account to pay into
--      * has no way to say "transferred, reference 4471" except to phone
--
--    And on our side, a bank transfer arrives with a reference and no name we
--    recognise, and matching it to a school is guesswork.
--
--    So: a Subscription screen with their own documents and our bank details,
--    and a claim path — the school reports the transfer, the operator confirms
--    it into a real payment. That is the same shape as the school's OWN parent
--    payment verification, which is deliberate: the workflow is already proven
--    inside this product, and the operator side of the business should not
--    invent a second pattern for the same problem.
--
-- WHY A CLAIM AND NOT A PAYMENT
--
-- A school-created row in platform_payments would let a school reduce its own
-- balance to zero by typing a number. The claim is a REQUEST — it changes no
-- total, appears in no revenue figure, and becomes money only when the operator
-- has seen the transfer. fn_platform_confirm_claim is the only bridge and it
-- goes through fn_platform_record_payment, so there is still exactly one place
-- that decides what a receipt looks like.
--
-- WHAT THE SCHOOL IS SHOWN OF OUR SETTINGS
--
-- Four bank fields, the business name, our phone and email, and whether online
-- payment is on. NOT the withholding default, NOT the document prefixes, NOT the
-- gateway provider's name, NOT platform_settings.updated_at. The table stays
-- operator-only in RLS and this function hand-picks what leaves it — an
-- allow-list, so a column added to platform_settings later is private until
-- somebody decides otherwise.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Raising the same document twice
--
-- A BEFORE INSERT trigger rather than a check inside fn_activate_subscription,
-- for the same reason 0077 numbered documents in a trigger: it covers every
-- path, including any future one, and fn_activate_subscription does not have to
-- know the rule exists.
--
-- "Exactly the same" is deliberately strict — school, plan, both period dates,
-- and only against invoices that are still live. A deliberate second year has a
-- different period_start and passes. A voided invoice does not block its
-- replacement, which is the whole point of voiding one.
-- ---------------------------------------------------------------------------
create or replace function public.fn__refuse_duplicate_invoice()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_doc text;
begin
  if new.kind <> 'invoice' then
    return new;
  end if;
  select i.doc_no into v_doc
    from public.platform_invoices i
   where i.school_id = new.school_id
     and i.kind = 'invoice'
     and i.voided_at is null
     and i.plan_code = new.plan_code
     and i.period_start = new.period_start
     and i.period_end = new.period_end
   limit 1;
  if v_doc is not null then
    -- One `%` per argument. A stray `%s` here would print the letter s and hide
    -- an argument, which this project has already shipped once.
    raise exception
      'Invoice % already covers % for % from % to %. Void it first if it was wrong.',
      v_doc, new.plan_code,
      (select name from public.schools where id = new.school_id),
      new.period_start, new.period_end;
  end if;
  return new;
end;
$$;

revoke all on function public.fn__refuse_duplicate_invoice() from public, anon, authenticated;

drop trigger if exists trg_refuse_duplicate_invoice on public.platform_invoices;
create trigger trg_refuse_duplicate_invoice
  before insert on public.platform_invoices
  for each row execute function public.fn__refuse_duplicate_invoice();

-- ---------------------------------------------------------------------------
-- 2. What is coming up, and how much of it was billed
--
-- Ordered by days_left so the list IS the worklist: the top of it is today's
-- phone calls and nobody has to sort anything.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_platform_due_soon(integer);
create function public.fn_platform_due_soon(p_days integer default 45)
returns table (
  school_id uuid, school_name text, city text,
  contact_name text, contact_phone text,
  plan_code text, status public.subscription_status,
  expires_on date, days_left integer, bucket text,
  student_count integer, student_limit integer,
  suggested_plan text, needs_upgrade boolean,
  renewal_amount numeric,
  outstanding numeric,
  -- The furthest date any live invoice covers, beside expires_on. See the header
  -- on why this replaced an `already_invoiced` flag that could never be true.
  invoiced_to date, unbilled_days integer, never_invoiced boolean,
  last_reminded_at timestamptz, last_reminded_stage text
) language plpgsql stable security definer set search_path = public as $$
declare v_days integer := greatest(0, least(coalesce(p_days, 45), 365));
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
    with base as (
      select s.id, s.name, s.city, s.contact_name, s.contact_phone,
             sub.plan_code, sub.status as raw_status, sub.cycle,
             sub.student_count, sub.period_end, sub.trial_ends_on,
             p.student_limit,
             public.fn_effective_status(s.id) as eff,
             case when sub.status = 'trialing' then sub.trial_ends_on
                  else sub.period_end end as expires
        from public.schools s
        join public.subscriptions sub on sub.school_id = s.id
        join public.plans p on p.code = sub.plan_code
       where s.active
    )
    select
      b.id, b.name, b.city, b.contact_name, b.contact_phone,
      b.plan_code, b.eff, b.expires,
      (b.expires - current_date)::integer,
      case
        when b.eff = 'cancelled' then 'cancelled'
        when b.eff = 'locked' then 'locked'
        when b.eff = 'grace'  then 'grace'
        when b.expires is null then 'unknown'
        when b.expires < current_date then 'overdue'
        when b.expires = current_date then 'today'
        when b.expires <= current_date + 7  then 'week'
        when b.expires <= current_date + 14 then 'fortnight'
        when b.expires <= current_date + 30 then 'month'
        else 'later' end,
      b.student_count, b.student_limit,
      sug.code,
      sug.code is distinct from b.plan_code,
      -- Priced on the plan they SHOULD be on and the cycle they are on now, so
      -- the number in the reminder is the number on the invoice. Quoting the
      -- old plan's price to a school that has outgrown it is how a renewal
      -- becomes an argument.
      public.fn__plan_price(coalesce(sug.code, b.plan_code),
                            case when b.cycle = 'yearly' then 12 else 1 end),
      public.fn__platform_billed(b.id) - public.fn__platform_settled(b.id),
      inv.covered_to,
      -- Licence time nobody billed for. A trial shows null here rather than a
      -- number, because a trial is unbilled on purpose and flagging it would put
      -- every new school on the chase list.
      case when inv.covered_to is null or b.expires is null then null
           when b.expires > inv.covered_to then (b.expires - inv.covered_to)::integer
           else 0 end,
      inv.covered_to is null,
      rem.at, rem.detail->>'stage'
      from base b
      cross join lateral (
        select p2.code from public.plans p2
         where p2.active
           and (p2.student_limit is null or p2.student_limit >= b.student_count)
         order by p2.sort_order limit 1
      ) sug
      -- How far the live invoices reach. Void excluded, because a cancelled
      -- invoice covers nothing. Null when a school has never been invoiced at
      -- all — a trial, or a year given away.
      left join lateral (
        select max(i.period_end) as covered_to
          from public.platform_invoices i
         where i.school_id = b.id and i.kind = 'invoice' and i.voided_at is null
      ) inv on true
      left join lateral (
        select a.at, a.detail
          from public.operator_actions a
         where a.school_id = b.id and a.action = 'renewal_reminder'
         order by a.at desc limit 1
      ) rem on true
     where b.eff in ('grace', 'locked', 'cancelled')
        or (b.expires is not null and b.expires <= current_date + v_days)
     order by 9 nulls last, 2;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. The reminder text
--
-- WhatsApp, not SMS and not email: it is what a Pakistani school office
-- actually reads, and this product already made that choice for parent
-- messaging. Click-to-chat, so no gateway, no per-message cost, and no delivery
-- report to pretend we have.
--
-- FIVE STAGES, and the difference between them is tone, not information:
--
--   ahead   a month out. Friendly, no urgency, gives them time to raise a
--           cheque request internally — which in a school takes weeks.
--   due     a week out. Names the date and the amount.
--   today   the last day. Still not a threat: grace has not started.
--   grace   expired, still working. This is the one that must be clear about
--           the date the software stops, because that is the only fact the
--           school needs in order to act.
--   locked  stopped. Says exactly what still works — reading and exporting
--           never stop, per 0026 — so the school is not panicking about data.
--
-- STABLE, and it does NOT record anything. Composing a message is not sending
-- one, and a function that logged "reminded" every time a screen rendered would
-- fill the history with reminders nobody sent. fn_platform_mark_reminded is the
-- separate, deliberate act.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_renewal_message(
  p_school_id uuid, p_stage text default null
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v record; v_set record; v_stage text; v_amount numeric; v_owed numeric;
  v_expiry date; v_days integer; v_stop date; v_text text; v_phone text;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  select s.name, s.contact_name, s.contact_phone, s.id,
         sub.plan_code, sub.cycle, sub.student_count, sub.period_end,
         sub.trial_ends_on, sub.status as raw_status,
         public.fn_effective_status(s.id) as eff,
         p.student_limit
    into v
    from public.schools s
    join public.subscriptions sub on sub.school_id = s.id
    join public.plans p on p.code = sub.plan_code
   where s.id = p_school_id;
  if v.name is null then
    raise exception 'Unknown school, or it has no subscription';
  end if;

  select * into v_set from public.platform_settings where id;

  v_expiry := case when v.raw_status = 'trialing' then v.trial_ends_on
                   else v.period_end end;
  v_days   := case when v_expiry is null then null else v_expiry - current_date end;
  v_stop   := case when v.period_end is null then null
                   else v.period_end + public.grace_days() end;

  v_stage := coalesce(nullif(btrim(coalesce(p_stage, '')), ''), case
    when v.eff = 'locked' then 'locked'
    when v.eff = 'grace'  then 'grace'
    when v_days is null then 'ahead'
    when v_days < 0  then 'grace'
    when v_days = 0  then 'today'
    when v_days <= 10 then 'due'
    else 'ahead' end);
  if v_stage not in ('ahead', 'due', 'today', 'grace', 'locked') then
    raise exception 'Unknown reminder stage: %', v_stage;
  end if;

  -- Priced on the plan the count fits, same as the worklist.
  select public.fn__plan_price(
           coalesce((select p2.code from public.plans p2
                      where p2.active and (p2.student_limit is null
                                        or p2.student_limit >= v.student_count)
                      order by p2.sort_order limit 1), v.plan_code),
           case when v.cycle = 'yearly' then 12 else 1 end)
    into v_amount;
  v_owed := public.fn__platform_billed(p_school_id) - public.fn__platform_settled(p_school_id);

  v_text := case v_stage
    when 'ahead' then format(
      'Assalam-o-Alaikum%s. Your %s software licence for %s runs to %s. Renewal '
      'for the next term is Rs %s. No rush — sending it now so you have time to '
      'arrange it. Bank details are on the Subscription screen inside the '
      'software (Settings → Subscription).',
      case when v.contact_name is null then '' else ' ' || v.contact_name end,
      coalesce(v_set.business_name, 'school management'), v.name,
      to_char(v_expiry, 'DD Mon YYYY'), to_char(v_amount, 'FM999,999,999'))

    when 'due' then format(
      'Assalam-o-Alaikum%s. %s''s licence expires on %s — %s day(s) from today. '
      'Renewal is Rs %s. You can see the invoice and our bank details inside the '
      'software under Settings → Subscription, and tell us the transfer reference '
      'from the same screen.',
      case when v.contact_name is null then '' else ' ' || v.contact_name end,
      v.name, to_char(v_expiry, 'DD Mon YYYY'), greatest(v_days, 0),
      to_char(v_amount, 'FM999,999,999'))

    when 'today' then format(
      'Assalam-o-Alaikum%s. %s''s licence expires today. Everything keeps working '
      'for %s more day(s) after that while we wait for the transfer, so nothing '
      'stops in the office today. Renewal is Rs %s.',
      case when v.contact_name is null then '' else ' ' || v.contact_name end,
      v.name, public.grace_days(), to_char(v_amount, 'FM999,999,999'))

    when 'grace' then format(
      'Assalam-o-Alaikum%s. %s''s licence expired on %s and is in the grace '
      'period. Everything still works until %s. Renewal is Rs %s%s. Please send '
      'the transfer reference on Settings → Subscription and we will confirm it '
      'the same day.',
      case when v.contact_name is null then '' else ' ' || v.contact_name end,
      v.name, to_char(v.period_end, 'DD Mon YYYY'),
      to_char(v_stop, 'DD Mon YYYY'), to_char(v_amount, 'FM999,999,999'),
      case when v_owed > 0
           then format(' (Rs %s is outstanding)', to_char(v_owed, 'FM999,999,999'))
           else '' end)

    else format(
      'Assalam-o-Alaikum%s. %s''s licence has expired and new entries are paused. '
      'Your data is safe and nothing has been deleted — you can still open every '
      'screen, print and export while this is sorted out. Renewal is Rs %s%s. '
      'Send us the transfer reference and we will restore it the same day.',
      case when v.contact_name is null then '' else ' ' || v.contact_name end,
      v.name, to_char(v_amount, 'FM999,999,999'),
      case when v_owed > 0
           then format(' (Rs %s outstanding)', to_char(v_owed, 'FM999,999,999'))
           else '' end)
  end;

  -- Digits only, and a bare local number gets Pakistan's country code, because
  -- wa.me refuses anything else. Same normalisation the parent outbox uses.
  v_phone := regexp_replace(coalesce(v.contact_phone, ''), '[^0-9]', '', 'g');
  v_phone := case
    when v_phone = '' then null
    when left(v_phone, 2) = '92' then v_phone
    when left(v_phone, 1) = '0'  then '92' || substr(v_phone, 2)
    else '92' || v_phone end;

  return jsonb_build_object(
    'school_id', p_school_id, 'school_name', v.name,
    'stage', v_stage,
    'contact_name', v.contact_name, 'phone', v.contact_phone,
    'expires_on', v_expiry, 'days_left', v_days,
    'stops_on', v_stop,
    'renewal_amount', v_amount, 'outstanding', v_owed,
    'text', v_text,
    -- The normalised number, NOT a finished wa.me URL. Building the link is the
    -- client's job here exactly as it is for the parent outbox — web/src/lib/
    -- whatsapp.ts owns that, has tests for the leading-zero and +92 cases, and
    -- percent-encoding a message body in SQL would be a second implementation of
    -- it that drifts.
    'phone_intl', v_phone,
    -- Null rather than an empty string when there is no number: a wa.me link
    -- built on '' opens WhatsApp at a blank contact picker, which reads as the
    -- software losing the message.
    'no_phone_reason', case when v_phone is null
      then 'No contact phone on record for this school — add one in the console'
      else null end);
end;
$$;

-- Recorded when the operator actually opens the chat, which is the honest claim:
-- we know a message was composed and WhatsApp was opened, and we do not know it
-- was read. The worklist shows this as "reminded 3 days ago" so nobody nags the
-- same school twice in one morning.
create or replace function public.fn_platform_mark_reminded(
  p_school_id uuid, p_stage text, p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not exists (select 1 from public.schools where id = p_school_id) then
    raise exception 'Unknown school %', p_school_id;
  end if;
  if coalesce(p_stage, '') not in ('ahead', 'due', 'today', 'grace', 'locked') then
    raise exception 'Unknown reminder stage: %', coalesce(p_stage, '(null)');
  end if;

  perform public.fn__log_operator_action('renewal_reminder', p_school_id,
    jsonb_build_object('stage', p_stage,
                       'note', nullif(btrim(coalesce(p_note, '')), ''),
                       'channel', 'whatsapp'));

  return jsonb_build_object('school_id', p_school_id, 'stage', p_stage, 'at', now());
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The school reports a transfer
-- ---------------------------------------------------------------------------
create table if not exists public.platform_payment_claims (
  id         uuid primary key default gen_random_uuid(),
  school_id  uuid not null references public.schools(id) on delete cascade,
  amount     numeric(12,2) not null check (amount > 0),
  paid_on    date not null,
  method     text not null default 'bank'
               check (method in ('bank', 'cash', 'cheque', 'online', 'other')),
  reference  text,
  from_bank  text,
  note       text,
  claimed_by uuid,
  claimed_at timestamptz not null default now(),
  status     text not null default 'pending'
               check (status in ('pending', 'confirmed', 'rejected')),
  decided_by uuid,
  decided_at timestamptz,
  decision_note text,
  -- Set when confirmed, so the claim and the money it became are one click apart
  -- in both directions.
  payment_id uuid references public.platform_payments(id) on delete set null,
  -- A decision is either fully recorded or not made. A rejected claim with no
  -- reason is a school being told no with nothing to act on.
  check (status = 'pending'
      or (decided_at is not null
          and (status = 'confirmed' or btrim(coalesce(decision_note, '')) <> '')))
);

create index if not exists idx_ppc_school on public.platform_payment_claims(school_id, claimed_at desc);
create index if not exists idx_ppc_pending on public.platform_payment_claims(claimed_at)
  where status = 'pending';

alter table public.platform_payment_claims enable row level security;

-- TWO read policies, the same shape 0074 used for operator_sessions: the
-- operator sees every claim, and a school sees its own. The school's own claim
-- is its own record and hiding it would mean it could report the same transfer
-- twice with no way to notice.
--
-- No write policy at all. A school INSERT here is the whole attack surface — a
-- row that says "we paid Rs 200,000" is not money, but a school that could
-- write `status = 'confirmed'` would be writing money.
drop policy if exists ppc_select_platform on public.platform_payment_claims;
create policy ppc_select_platform on public.platform_payment_claims
  for select to authenticated using (public.is_platform_admin());

drop policy if exists ppc_select_school on public.platform_payment_claims;
create policy ppc_select_school on public.platform_payment_claims
  for select to authenticated using (
    school_id = public.current_school_id()
    and public.may_view('owner'::public.user_role, 'principal'::public.user_role));

create or replace function public.fn_my_report_payment(
  p_amount numeric,
  p_paid_on date default null,
  p_method text default 'bank',
  p_reference text default null,
  p_from_bank text default null,
  p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_ref text := nullif(btrim(coalesce(p_reference, '')), '');
  v_on date := coalesce(p_paid_on, current_date);
  v_id uuid; v_pending integer;
begin
  if v_school is null then
    raise exception 'No school' using errcode = '42501';
  end if;
  -- has_role, not may_view: this is a WRITE, and an operator inside a read-only
  -- support session must not be able to report a payment on the school's behalf.
  -- 0074's whole design rests on has_role() staying untouched, and using it here
  -- is what makes that protection apply to this table too.
  if not public.has_role('owner'::public.user_role, 'principal'::public.user_role) then
    raise exception 'Only the owner or principal can report a payment'
      using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Enter the amount you transferred';
  end if;
  if v_on > current_date then
    raise exception 'That date is in the future';
  end if;
  if v_on < current_date - 365 then
    raise exception 'That date is more than a year ago — check it';
  end if;
  if coalesce(p_method, 'bank') not in ('bank', 'cash', 'cheque', 'online', 'other') then
    raise exception 'Unknown payment method';
  end if;

  -- Told us twice about the same transfer. Refused rather than deduplicated,
  -- because the school needs to know the first one arrived — a silent no-op
  -- reads as the form being broken and produces a phone call, which is the
  -- thing this whole screen exists to prevent.
  if v_ref is not null and exists (
    select 1 from public.platform_payment_claims
     where school_id = v_school and status = 'pending'
       and lower(btrim(coalesce(reference, ''))) = lower(v_ref)) then
    raise exception
      'You have already sent us reference % and we are checking it. '
      'We will confirm it shortly.', v_ref;
  end if;

  select count(*) into v_pending from public.platform_payment_claims
   where school_id = v_school and status = 'pending';
  if v_pending >= 5 then
    raise exception
      'There are already 5 payments waiting to be checked for this school. '
      'Please give us a day to work through them before adding more.';
  end if;

  insert into public.platform_payment_claims
    (school_id, amount, paid_on, method, reference, from_bank, note, claimed_by)
  values (v_school, round(p_amount, 2), v_on, coalesce(p_method, 'bank'),
          v_ref, nullif(btrim(coalesce(p_from_bank, '')), ''),
          nullif(btrim(coalesce(p_note, '')), ''), auth.uid())
  returning id into v_id;

  -- In the SCHOOL's own audit log, because it is the school's own action and
  -- their owner should be able to see that their accountant reported it.
  insert into public.audit_log(school_id, actor, actor_role, action, entity, entity_id, after)
  values (v_school, auth.uid(),
          (select role from public.profiles where id = auth.uid()),
          'subscription_payment_reported', 'platform_payment_claims', v_id::text,
          jsonb_build_object('amount', round(p_amount, 2), 'paid_on', v_on,
                             'method', coalesce(p_method, 'bank'), 'reference', v_ref));

  return jsonb_build_object(
    'claim_id', v_id, 'amount', round(p_amount, 2), 'paid_on', v_on,
    'status', 'pending',
    'message', 'Thank you. We will check it against our bank statement and '
               'confirm it here. Nothing stops working while we do.');
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The operator works through the claims
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_payment_claims(
  p_status text default 'pending', p_limit integer default 200
) returns table (
  id uuid, school_id uuid, school_name text, amount numeric, paid_on date,
  method text, reference text, from_bank text, note text,
  claimed_at timestamptz, claimed_by_name text,
  status text, decided_at timestamptz, decision_note text, payment_id uuid,
  outstanding numeric
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if coalesce(p_status, 'pending') not in ('pending', 'confirmed', 'rejected', 'all') then
    raise exception 'Unknown status filter: %', p_status;
  end if;
  return query
    select c.id, c.school_id, s.name, c.amount, c.paid_on, c.method, c.reference,
           c.from_bank, c.note, c.claimed_at,
           -- The name of the school's own staff member who reported it, which is
           -- who to ask when a reference does not match. A name and a role, not
           -- a login or an email.
           pr.full_name,
           c.status, c.decided_at, c.decision_note, c.payment_id,
           public.fn__platform_billed(c.school_id) - public.fn__platform_settled(c.school_id)
      from public.platform_payment_claims c
      join public.schools s on s.id = c.school_id
      left join public.profiles pr on pr.id = c.claimed_by
     where coalesce(p_status, 'pending') = 'all'
        or c.status = coalesce(p_status, 'pending')
     order by c.claimed_at desc
     limit greatest(1, least(coalesce(p_limit, 200), 1000));
end;
$$;

create or replace function public.fn_platform_confirm_claim(
  p_claim_id uuid,
  -- Null means "what they said". An explicit amount is for the case the bank
  -- statement disagrees, which happens when a school transfers net of the
  -- withholding tax and reports the gross.
  p_amount numeric default null,
  p_invoice_id uuid default null,
  p_tax_withheld numeric default 0,
  p_tax_certificate text default null,
  p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_c record; v_amt numeric; v_pay jsonb; v_pid uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into v_c from public.platform_payment_claims where id = p_claim_id;
  if not found then
    raise exception 'No such payment report';
  end if;
  if v_c.status <> 'pending' then
    raise exception 'That report was already % on %', v_c.status, v_c.decided_at::date;
  end if;

  v_amt := coalesce(p_amount, v_c.amount);
  if v_amt <= 0 then
    raise exception 'A payment must be more than zero';
  end if;

  -- Through the ordinary receipt path, so a confirmed claim and a payment the
  -- operator typed in are indistinguishable afterwards — one shape of truth in
  -- platform_payments, and the claim keeps the story of where it came from.
  v_pay := public.fn_platform_record_payment(
    v_c.school_id, v_amt, v_c.paid_on, v_c.method,
    -- The school's reference is the one on our bank statement, so it is what
    -- goes on the receipt.
    v_c.reference, p_invoice_id,
    btrim(coalesce('Reported by the school on ' || v_c.claimed_at::date || '. ', '')
          || coalesce(nullif(btrim(coalesce(p_note, '')), ''), '')),
    coalesce(p_tax_withheld, 0), p_tax_certificate);
  v_pid := (v_pay->>'payment_id')::uuid;

  update public.platform_payment_claims
     set status = 'confirmed', decided_by = auth.uid(), decided_at = now(),
         decision_note = nullif(btrim(coalesce(p_note, '')), ''),
         payment_id = v_pid
   where id = p_claim_id;

  perform public.fn__log_operator_action('payment_claim_confirmed', v_c.school_id,
    jsonb_build_object('claim_id', p_claim_id, 'payment_id', v_pid,
                       'claimed_amount', v_c.amount, 'confirmed_amount', v_amt,
                       'reference', v_c.reference));

  -- Into the SCHOOL's audit log too: they reported it, they should see it land.
  insert into public.audit_log(school_id, actor, action, entity, entity_id, after)
  values (v_c.school_id, auth.uid(), 'subscription_payment_confirmed',
          'platform_payment_claims', p_claim_id::text,
          jsonb_build_object('amount', v_amt, 'payment_id', v_pid));

  return jsonb_build_object(
    'claim_id', p_claim_id, 'status', 'confirmed',
    'payment_id', v_pid, 'amount', v_amt,
    'outstanding', v_pay->'outstanding');
end;
$$;

create or replace function public.fn_platform_reject_claim(
  p_claim_id uuid, p_reason text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_c record; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  -- The school is shown this sentence. "Rejected" with no reason is how a
  -- customer relationship breaks over a typo in a reference number.
  if v_reason is null then
    raise exception 'Say why — the school is shown this reason';
  end if;
  select * into v_c from public.platform_payment_claims where id = p_claim_id;
  if not found then
    raise exception 'No such payment report';
  end if;
  if v_c.status <> 'pending' then
    raise exception 'That report was already % on %', v_c.status, v_c.decided_at::date;
  end if;

  update public.platform_payment_claims
     set status = 'rejected', decided_by = auth.uid(), decided_at = now(),
         decision_note = v_reason
   where id = p_claim_id;

  perform public.fn__log_operator_action('payment_claim_rejected', v_c.school_id,
    jsonb_build_object('claim_id', p_claim_id, 'amount', v_c.amount,
                       'reference', v_c.reference, 'reason', v_reason));

  insert into public.audit_log(school_id, actor, action, entity, entity_id, after, reason)
  values (v_c.school_id, auth.uid(), 'subscription_payment_rejected',
          'platform_payment_claims', p_claim_id::text,
          jsonb_build_object('amount', v_c.amount, 'reference', v_c.reference),
          v_reason);

  return jsonb_build_object('claim_id', p_claim_id, 'status', 'rejected',
                            'reason', v_reason);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. The school's own Subscription screen
--
-- One call. Their licence, their documents, their balance, where to pay, and
-- what they have already told us about.
--
-- Gated on may_view rather than has_role: this is a READ, and an operator in a
-- read-only support session (0074) should be able to see exactly what the
-- principal is looking at when they phone about it. That is the entire purpose
-- of a support session, and check-readonly-writes.py permits may_view on a read
-- for precisely this reason.
-- ---------------------------------------------------------------------------
create or replace function public.fn_my_billing()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_set record; v_billed numeric; v_settled numeric;
begin
  if v_school is null then
    return jsonb_build_object('ok', false, 'reason', 'no_school');
  end if;
  if not public.may_view('owner'::public.user_role, 'principal'::public.user_role) then
    raise exception 'Only the owner or principal can see the subscription bill'
      using errcode = '42501';
  end if;

  select * into v_set from public.platform_settings where id;
  v_billed  := public.fn__platform_billed(v_school);
  v_settled := public.fn__platform_settled(v_school);

  return jsonb_build_object(
    'ok', true,
    -- Reused rather than restated: whatever fn_my_licence says about status,
    -- days left and the limit is what the banner says, and two screens
    -- disagreeing about whether a licence is expiring is worse than either.
    'licence', public.fn_my_licence(),

    'balance', jsonb_build_object(
      'billed', v_billed, 'paid', v_settled, 'outstanding', v_billed - v_settled),

    -- Their own documents. doc_no is what they quote back to us, which is the
    -- point of 0077.
    'documents', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', i.id, 'doc_no', i.doc_no, 'kind', i.kind,
               'issued_on', i.issued_on, 'due_on', i.due_on,
               'plan_code', i.plan_code,
               'period_start', i.period_start, 'period_end', i.period_end,
               'months', i.months,
               'amount', i.amount, 'tax_amount', i.tax_amount,
               'total', i.amount + i.tax_amount,
               'voided', i.voided_at is not null,
               'paid', coalesce((select sum(pm.settled) from public.platform_payments pm
                                  where pm.invoice_id = i.id), 0),
               'note', i.note)
             order by i.issued_on desc, i.serial desc)
        from public.platform_invoices i where i.school_id = v_school), '[]'::jsonb),

    'payments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'paid_on', p.paid_on, 'amount', p.amount, 'method', p.method,
               'reference', p.reference, 'tax_withheld', p.tax_withheld,
               'tax_certificate', p.tax_certificate)
             order by p.paid_on desc, p.created_at desc)
        from public.platform_payments p where p.school_id = v_school), '[]'::jsonb),

    -- What they have told us and what came of it, including the reason a report
    -- was rejected. A school that cannot see why is a school that phones.
    'reports', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'amount', c.amount, 'paid_on', c.paid_on,
               'method', c.method, 'reference', c.reference,
               'claimed_at', c.claimed_at, 'status', c.status,
               'decided_at', c.decided_at, 'decision_note', c.decision_note)
             order by c.claimed_at desc)
        from public.platform_payment_claims c where c.school_id = v_school), '[]'::jsonb),

    -- An ALLOW-LIST of the vendor's settings, not the row. See the header.
    'pay_to', jsonb_build_object(
      'business_name', nullif(btrim(coalesce(v_set.business_name, '')), ''),
      'bank_name', v_set.bank_name, 'title', v_set.bank_title,
      'account', v_set.bank_account, 'iban', v_set.bank_iban,
      'support_phone', v_set.phone, 'support_email', v_set.email,
      'online_available', coalesce(v_set.gateway_enabled, false)),

    -- Stated rather than implied: a screen with a bank account and no
    -- instruction is a screen somebody transfers money from and then phones
    -- about anyway.
    'how_to_pay', case when coalesce(v_set.gateway_enabled, false)
      then 'Pay online from this screen, or transfer to the account above and '
           'tell us the reference.'
      else 'Transfer to the account above from any bank or app, then use "I have '
           'paid" below to tell us the reference. We check it against our '
           'statement and confirm it here — usually the same day.' end);
end;
$$;

-- A printable copy of one of their own documents. The ownership check is the
-- whole function: fn__invoice_document takes an id and answers, so this is the
-- only thing standing between a school and another school's invoice.
create or replace function public.fn_my_platform_invoice(p_invoice_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if v_school is null then
    raise exception 'No school' using errcode = '42501';
  end if;
  if not public.may_view('owner'::public.user_role, 'principal'::public.user_role) then
    raise exception 'Only the owner or principal can see the subscription bill'
      using errcode = '42501';
  end if;
  if not exists (select 1 from public.platform_invoices
                  where id = p_invoice_id and school_id = v_school) then
    raise exception 'No such invoice' using errcode = '42501';
  end if;
  return public.fn__invoice_document(p_invoice_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------------
grant  execute on function public.fn_platform_due_soon(integer)   to authenticated;
revoke execute on function public.fn_platform_due_soon(integer) from public, anon;
grant  execute on function public.fn_platform_renewal_message(uuid, text)   to authenticated;
revoke execute on function public.fn_platform_renewal_message(uuid, text) from public, anon;
grant  execute on function public.fn_platform_mark_reminded(uuid, text, text)   to authenticated;
revoke execute on function public.fn_platform_mark_reminded(uuid, text, text) from public, anon;
grant  execute on function public.fn_platform_payment_claims(text, integer)   to authenticated;
revoke execute on function public.fn_platform_payment_claims(text, integer) from public, anon;
grant  execute on function
  public.fn_platform_confirm_claim(uuid, numeric, uuid, numeric, text, text) to authenticated;
revoke execute on function
  public.fn_platform_confirm_claim(uuid, numeric, uuid, numeric, text, text) from public, anon;
grant  execute on function public.fn_platform_reject_claim(uuid, text)   to authenticated;
revoke execute on function public.fn_platform_reject_claim(uuid, text) from public, anon;
grant  execute on function
  public.fn_my_report_payment(numeric, date, text, text, text, text) to authenticated;
revoke execute on function
  public.fn_my_report_payment(numeric, date, text, text, text, text) from public, anon;
grant  execute on function public.fn_my_billing()   to authenticated;
revoke execute on function public.fn_my_billing() from public, anon;
grant  execute on function public.fn_my_platform_invoice(uuid)   to authenticated;
revoke execute on function public.fn_my_platform_invoice(uuid) from public, anon;
