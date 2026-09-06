-- =============================================================================
-- 0112: A school records HOW it will pay, and the card number is never here
--
-- WHERE THIS FITS
--
-- 0111 set what a term costs. This records how a school intends to settle it and
-- which term it chose, so that the renewal machine in the next migration has
-- something to act on. It deliberately contains NO gateway integration: there is
-- no merchant account yet, and a card adapter written against documentation and
-- never run is not something to put near a customer's money.
--
-- What DOES work end to end today is the manual path - bank transfer, Easypaisa,
-- JazzCash - because that is how a Pakistani school actually pays. The research
-- behind that decision, recorded here because it will be questioned later:
--
--     credit cards      0.22% of Pakistani adults hold one   (World Bank)
--     debit cards       7.7%
--     Easypaisa         59M registered accounts, 20M monthly active
--     JazzCash          40M+ accounts
--
-- A design that requires a card to start a trial reaches under a twelfth of the
-- market. So a payment method is a first-class record with three kinds, the
-- manual kind is not a fallback, and auto_renew is a property of the method
-- rather than an assumption about everybody.
--
-- THE CARD NUMBER IS NOT IN THIS SCHEMA AND CANNOT BE PUT HERE
--
-- Three separate defences, because one is how this goes wrong:
--
--   1. THE TOKEN LIVES IN ITS OWN TABLE. payment_methods holds only what a
--      screen needs to say "Visa ending 4242, expires 09/28". The provider's
--      token - the thing that can actually move money - is in
--      payment_method_tokens, which has RLS on, NO policies, and no grants to
--      `authenticated` at all. A mistaken policy on the display table therefore
--      cannot leak the credential, because the credential is not in it.
--   2. A CHECK CONSTRAINT REFUSES PAN-SHAPED TEXT in every displayable column.
--      last4 must be exactly four digits and nothing longer. It is a tripwire,
--      not a security boundary, and it is there because the way a card number
--      ends up in a database is somebody putting it in a "notes" field.
--   3. THE WRITE PATH IS A DEFINER FUNCTION, so the browser never holds the
--      gateway's secret and never needs INSERT on either table.
--
-- WHY term_months AND NOT THE cycle ENUM
--
-- subscriptions.cycle is billing_cycle, which is ('monthly','yearly'). A
-- three-month term does not fit it, and Postgres forbids USING a new enum value
-- in the transaction that added it - the rule that forced this repository's
-- bundle split at 0032. An integer takes any term, needs no second bundle, and
-- is already the unit platform_invoices.months and fn__plan_price speak in.
-- `cycle` stays exactly as it is, as the coarse label on an invoice.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. What a school needs to see about how it pays
-- ---------------------------------------------------------------------------
do $ddl$ begin
  if not exists (select 1 from pg_type where typname = 'payment_method_kind') then
    create type public.payment_method_kind as enum (
      -- A saved card, chargeable without the school present once the gateway
      -- supports it. The minority case in this market, and the only one that
      -- makes renewal genuinely hands-off.
      'card',
      -- An Easypaisa or JazzCash wallet. Reaches most of the market. Whether it
      -- can be charged unattended depends on the provider's mandate support,
      -- which is why auto_renew is a stored fact rather than implied by kind.
      'wallet',
      -- The school sends the money and tells us. No credential, nothing to
      -- charge, and the way most Pakistani schools will pay for years.
      'manual'
    );
  end if;
end $ddl$;

create table if not exists public.payment_methods (
  id             uuid primary key default gen_random_uuid(),
  school_id      uuid not null references public.schools(id) on delete cascade,
  kind           public.payment_method_kind not null,

  -- Which gateway holds the credential. Null for manual, where there is none.
  provider       text,

  -- DISPLAY ONLY. Everything below exists so a screen can name the method
  -- without the credential being anywhere near the browser.
  brand          text,          -- 'visa' | 'mastercard' | 'easypaisa' | 'jazzcash'
  last4          text,          -- exactly four digits, or null
  exp_month      integer,
  exp_year       integer,
  -- What the school calls it. "HBL account", "Ammi's card". Their words.
  label          text,

  -- How the money will actually arrive when this method is the one in use.
  -- Free text on purpose: a manual method is a sentence, not an enum.
  -- "Bank transfer to HBL 1234", "Easypaisa from 0300-1234567".
  instructions   text,

  status         text not null default 'active',
  is_default     boolean not null default false,

  -- SEPARATE CONSENT TO STORE THE CREDENTIAL. Visa and Mastercard both require
  -- that agreement to keep a card on file is obtained apart from the general
  -- terms and conditions, and recorded. Null for a manual method, which stores
  -- nothing to consent to.
  --
  -- The WORDING the school agreed to is not here yet, deliberately. It belongs
  -- with the card flow that will actually write it, and a column nothing reads
  -- is a promise the software does not keep - check-columns-used.sh said so
  -- about this exact column and it was right.
  consent_at     timestamptz,

  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),

  constraint payment_methods_status_chk
    check (status in ('active', 'expired', 'failed', 'removed')),

  -- THE TRIPWIRE. last4 is four digits and nothing else, and no displayable
  -- column may hold a run of twelve or more digits. A card number reaches a
  -- database because somebody types it into a free-text field, so the free-text
  -- fields refuse it.
  constraint payment_methods_last4_chk
    check (last4 is null or last4 ~ '^[0-9]{4}$'),
  -- PUNCTUATION IS STRIPPED BEFORE THE CHECK, and that is the whole point.
  -- The first version tested the raw text for a run of twelve digits, which
  -- catches "4242424242424242" and misses "4242 4242 4242 4242" - the way a
  -- card number is actually written down, and the way it comes off a card. A
  -- tripwire that only catches the tidy spelling is a tripwire that catches
  -- nobody. Found by a test that fed it both.
  constraint payment_methods_no_pan_chk
    check (
      regexp_replace(coalesce(label, ''),        '[^0-9]', '', 'g') !~ '[0-9]{12,}'
      and regexp_replace(coalesce(instructions, ''), '[^0-9]', '', 'g') !~ '[0-9]{12,}'
      and regexp_replace(coalesce(brand, ''),        '[^0-9]', '', 'g') !~ '[0-9]{12,}'
    ),
  constraint payment_methods_expiry_chk
    check ((exp_month is null and exp_year is null)
        or (exp_month between 1 and 12 and exp_year between 2000 and 2100)),
  -- A card with no last four digits cannot be named on a screen, and an
  -- unnameable saved card is one a school cannot recognise or revoke.
  constraint payment_methods_card_shape_chk
    check (kind <> 'card' or (last4 is not null and provider is not null)),
  -- A manual method has no gateway and no credential, so it must not pretend to.
  constraint payment_methods_manual_shape_chk
    check (kind <> 'manual'
        or (provider is null and last4 is null and consent_at is null))
);

-- DROPPED FIRST. Postgres has no `create trigger if not exists`, so a plain
-- CREATE fails on the second paste with "trigger already exists" and rolls the
-- whole bundle back - and a school is told to paste again whenever it is
-- unsure a paste took. Found by applying this file twice, which is the only way
-- to find it.
drop trigger if exists trg_payment_methods_updated on public.payment_methods;
create trigger trg_payment_methods_updated before update on public.payment_methods
  for each row execute function public.set_updated_at();

create index if not exists idx_payment_methods_school
  on public.payment_methods(school_id) where status = 'active';

-- Exactly one default per school. A partial unique index rather than a trigger,
-- because two defaults is the state that makes a renewal charge the wrong card
-- and no application code can be trusted to prevent it forever.
create unique index if not exists uq_payment_methods_one_default
  on public.payment_methods(school_id) where is_default and status = 'active';

comment on table public.payment_methods is
  'How a school intends to pay. DISPLAY FACTS ONLY: the gateway credential is '
  'in payment_method_tokens, which has no policies and no grants. See 0112.';

-- ---------------------------------------------------------------------------
-- 2. The credential, where the application cannot reach it
--
-- RLS ON WITH NO POLICIES is the point. In Postgres that denies every row to
-- every non-superuser, non-owner role regardless of grants - so even if a later
-- migration granted SELECT to `authenticated` by mistake, this table would
-- still return nothing. The service role bypasses RLS, which is exactly the
-- boundary wanted: only an Edge Function holding the service key can read a
-- token, and only in order to hand it straight back to the gateway.
-- ---------------------------------------------------------------------------
create table if not exists public.payment_method_tokens (
  payment_method_id uuid primary key
    references public.payment_methods(id) on delete cascade,
  -- Denormalised so a leak-check query can be written without a join, and so
  -- the row is self-describing in a backup.
  school_id      uuid not null references public.schools(id) on delete cascade,
  provider       text not null,
  -- What the GATEWAY gave us. Never a card number: a token is meaningless
  -- without the gateway's own vault, which is the entire reason to use one.
  provider_token text not null,
  created_at     timestamptz not null default now(),

  -- A token that looks like a card number is a card number. Refuse it: a
  -- constraint here is the last place this can be stopped.
  constraint payment_method_tokens_not_a_pan_chk
    check (regexp_replace(provider_token, '[^0-9]', '', 'g') !~ '^[0-9]{12,19}$')
);

alter table public.payment_method_tokens enable row level security;
alter table public.payment_method_tokens force row level security;

revoke all on table public.payment_method_tokens from public, anon, authenticated;

comment on table public.payment_method_tokens is
  'Gateway credentials. RLS is on with NO policies, so every application role '
  'reads nothing; only the service role, inside an Edge Function, can see a '
  'token. Never add a policy to this table.';

-- ---------------------------------------------------------------------------
-- 3. Row level security on the display table
--
-- The school sees its own methods and nobody else's. Leadership only, on the
-- same reasoning 0074 gives for support visits: a clerk can do nothing about
-- the subscription, and how the school pays is a governance fact for whoever
-- signs the cheques.
--
-- No INSERT, UPDATE or DELETE policy at all. Every write goes through the
-- definer functions below, so there is one place that decides what a valid
-- method looks like and the browser never needs table rights.
-- ---------------------------------------------------------------------------
alter table public.payment_methods enable row level security;
alter table public.payment_methods force row level security;

do $pol$ begin
  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'payment_methods'
                    and policyname = 'payment_methods_read_own') then
    create policy payment_methods_read_own on public.payment_methods
      for select using (
        school_id = public.current_school_id()
        and public.has_role('owner', 'principal')
      );
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'payment_methods'
                    and policyname = 'payment_methods_read_operator') then
    create policy payment_methods_read_operator on public.payment_methods
      for select using (public.is_platform_admin());
  end if;
end $pol$;

revoke all on table public.payment_methods from public, anon;
grant select on table public.payment_methods to authenticated;

-- ---------------------------------------------------------------------------
-- 4. The term a school chose, and whether anything can be charged
-- ---------------------------------------------------------------------------
alter table public.subscriptions
  add column if not exists term_months integer not null default 12,
  -- FALSE BY DEFAULT, and that default is the honest one. Renewal is only
  -- automatic when there is a credential to charge; for the manual majority the
  -- money arrives because somebody sent it, and a system that assumed otherwise
  -- would lock a paying school out while believing it had been paid.
  add column if not exists auto_renew boolean not null default false,
  add column if not exists payment_method_id uuid references public.payment_methods(id),
  -- Cancelling keeps the school running to the end of what it paid for. The
  -- alternative - ending access the moment somebody clicks Cancel - takes money
  -- already received and gives nothing back for it.
  add column if not exists cancel_at_period_end boolean not null default false;

do $ddl$ begin
  if not exists (select 1 from pg_constraint where conname = 'subscriptions_term_chk') then
    alter table public.subscriptions add constraint subscriptions_term_chk
      check (term_months between 1 and 60);
  end if;
  -- Auto-renewal with nothing to charge is the state that silently stops
  -- collecting money, so the schema refuses it outright.
  if not exists (select 1 from pg_constraint where conname = 'subscriptions_autorenew_chk') then
    alter table public.subscriptions add constraint subscriptions_autorenew_chk
      check (not auto_renew or payment_method_id is not null);
  end if;
end $ddl$;

comment on column public.subscriptions.term_months is
  'What the school buys at a time: 1, 3 or 12. An integer rather than the '
  'billing_cycle enum because Postgres forbids using a new enum value in the '
  'transaction that adds it, and because months is already the unit '
  'platform_invoices and fn__plan_price speak in. `cycle` remains the coarse '
  'label printed on an invoice.';

-- ---------------------------------------------------------------------------
-- 5. When the next payment is due, DERIVED
--
-- Not stored. A stored next_charge_on has to be rewritten by every path that
-- moves a date - activation, renewal, grace, suspension, reinstatement - and
-- the one path that forgets is the one that charges a school twice or never.
-- Six live schools scanned per run costs nothing; a date that disagrees with
-- period_end costs a customer.
-- ---------------------------------------------------------------------------
create or replace function public.fn__next_charge_on(p_school_id uuid)
returns date language sql stable security definer set search_path = public as $$
  select case
    -- Suspended by hand: nothing is owed until somebody decides otherwise.
    when s.suspended_at is not null then null
    when s.status = 'cancelled' then null
    -- The trial ends and the first charge falls on that day. This is the date
    -- the school is shown at checkout, so it must come from here and not be
    -- computed again on a screen.
    when s.status = 'trialing' then s.trial_ends_on
    -- Cancelling at period end means there is no next charge, only an ending.
    when s.cancel_at_period_end then null
    when s.period_end is not null then s.period_end + 1
    else null
  end
  from public.subscriptions s
  where s.school_id = p_school_id;
$$;

revoke all on function public.fn__next_charge_on(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. What the school is told: the plan, the term, the date, the amount
--
-- One call, because the sentence a school reads at checkout and the sentence it
-- reads three days before the charge have to be the same sentence. Two screens
-- computing it separately is how "you will be charged on the 20th" and an
-- invoice dated the 21st end up in the same inbox.
--
-- DELIBERATELY NOT AN INVOICE. Raising a real platform_invoices row at signup,
-- dated at trial end, would make a school on a free trial show as owing
-- Rs 20,000 from its first day: fn_platform_outstanding would count it, the
-- console would say "Owes 20,000: unpaid invoice", and the receivable figure
-- the whole operator console is built on would be a work of fiction. The school
-- is told the amount and the date, which is what the promise requires; the
-- invoice is raised when the charge is actually due.
-- ---------------------------------------------------------------------------
create or replace function public.fn_my_next_payment()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_sub record; v_plan record; v_pm record; v_due date; v_amount numeric;
begin
  if v_school is null then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal can see the subscription'
      using errcode = '42501';
  end if;

  select * into v_sub from public.subscriptions where school_id = v_school;
  if not found then
    return jsonb_build_object('has_subscription', false);
  end if;
  select * into v_plan from public.plans where code = v_sub.plan_code;
  select * into v_pm from public.payment_methods where id = v_sub.payment_method_id;

  v_due := public.fn__next_charge_on(v_school);
  v_amount := public.fn__plan_price(v_sub.plan_code, v_sub.term_months);

  return jsonb_build_object(
    'has_subscription', true,
    'plan_code', v_sub.plan_code,
    'plan_name', v_plan.name,
    'term_months', v_sub.term_months,
    'status', public.fn_effective_status(v_school),
    'in_trial', v_sub.status = 'trialing',
    'trial_ends_on', v_sub.trial_ends_on,
    'period_end', v_sub.period_end,
    'next_charge_on', v_due,
    -- Null when nothing is due: cancelled, suspended, or ending at period end.
    -- A screen must be able to say "nothing further is due" rather than "Rs 0".
    'next_charge_amount', case when v_due is null then null else v_amount end,
    'auto_renew', v_sub.auto_renew,
    'cancel_at_period_end', v_sub.cancel_at_period_end,
    -- THE THREE TERMS WITH THEIR REAL FIGURES, so a screen offering the choice
    -- never has to state a discount of its own. The first version of the panel
    -- had "save about 5%" typed into the component, which is a promise about a
    -- number held in the price list: change the quarterly rate and the label
    -- lies, silently, on the screen where a school decides what to spend.
    'terms', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'months', t.m,
               'amount', public.fn__plan_price(v_sub.plan_code, t.m),
               'saving', greatest(0, round(v_plan.price_monthly * t.m, 2)
                                     - public.fn__plan_price(v_sub.plan_code, t.m)),
               'chosen', t.m = v_sub.term_months) order by t.m), '[]'::jsonb)
        from (values (1), (3), (12)) as t(m)
       where v_plan.price_monthly > 0
    ),
    'method', case when v_pm.id is null then null else jsonb_build_object(
      'id', v_pm.id, 'kind', v_pm.kind, 'brand', v_pm.brand,
      'last4', v_pm.last4, 'label', v_pm.label,
      'instructions', v_pm.instructions, 'status', v_pm.status) end,
    -- The sentence itself, composed here so every surface says the same words.
    'sentence', case
      when v_due is null and v_sub.cancel_at_period_end
        then format('Your subscription ends on %s. Nothing further will be charged.',
                    to_char(v_sub.period_end, 'FMDD Mon YYYY'))
      when v_due is null
        then 'Nothing is due at the moment.'
      when v_sub.status = 'trialing' and v_sub.auto_renew
        then format('Your free trial ends on %s. On that day you will be charged %s. '
                    || 'You are charged nothing today.',
                    to_char(v_due, 'FMDD Mon YYYY'),
                    'Rs ' || to_char(v_amount, 'FM999,999,999'))
      when v_sub.status = 'trialing'
        then format('Your free trial ends on %s. To keep going, %s is due by then. '
                    || 'You are charged nothing today.',
                    to_char(v_due, 'FMDD Mon YYYY'),
                    'Rs ' || to_char(v_amount, 'FM999,999,999'))
      when v_sub.auto_renew
        then format('%s will be charged on %s.',
                    'Rs ' || to_char(v_amount, 'FM999,999,999'),
                    to_char(v_due, 'FMDD Mon YYYY'))
      else format('%s is due by %s.',
                  'Rs ' || to_char(v_amount, 'FM999,999,999'),
                  to_char(v_due, 'FMDD Mon YYYY'))
    end);
end;
$$;

grant  execute on function public.fn_my_next_payment() to authenticated;
revoke execute on function public.fn_my_next_payment() from public, anon;

-- ---------------------------------------------------------------------------
-- 7. Recording the manual way to pay
--
-- The only write path this migration ships, and the only one that can be tested
-- without a merchant account. It records how the school says it will send the
-- money, which is what the operator reads when a transfer arrives with no
-- reference on it.
--
-- auto_renew is forced FALSE here and the schema will not let it be true: there
-- is nothing to charge. Saying so in the return value matters, because a school
-- that has "set up payment" and believes renewal is automatic is a school that
-- gets locked out while feeling it did everything asked of it.
-- ---------------------------------------------------------------------------
create or replace function public.fn_set_manual_payment_method(
  p_label text, p_instructions text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_label text := nullif(btrim(coalesce(p_label, '')), '');
  v_instr text := nullif(btrim(coalesce(p_instructions, '')), '');
  v_id uuid;
begin
  if v_school is null or not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal can change how the school pays'
      using errcode = '42501';
  end if;
  if v_label is null then
    raise exception 'Say how you will be paying, in your own words';
  end if;
  -- The tripwire again, before the constraint, so the school gets a sentence
  -- rather than a constraint violation.
  -- Digits only, so spaces and dashes do not smuggle it past. Same rule as the
  -- constraint, checked here first so the school reads a sentence rather than a
  -- constraint violation.
  if regexp_replace(v_label, '[^0-9]', '', 'g') ~ '[0-9]{12,}'
     or regexp_replace(coalesce(v_instr, ''), '[^0-9]', '', 'g') ~ '[0-9]{12,}' then
    raise exception 'Please do not put a card number here. Write the bank or '
      'wallet you will send it from, and we will match the payment by its '
      'reference.';
  end if;

  -- One default per school is a unique index, so the old one is stood down
  -- first rather than relying on the insert to sort it out.
  update public.payment_methods
     set is_default = false
   where school_id = v_school and is_default;

  insert into public.payment_methods
    (school_id, kind, label, instructions, is_default, created_by)
  values (v_school, 'manual', v_label, v_instr, true, auth.uid())
  returning id into v_id;

  update public.subscriptions
     set payment_method_id = v_id, auto_renew = false
   where school_id = v_school;

  insert into public.audit_log(school_id, actor, action, entity, entity_id, after)
  values (v_school, auth.uid(), 'payment_method_set', 'payment_methods',
          v_id::text, jsonb_build_object('kind', 'manual', 'label', v_label));

  return jsonb_build_object(
    'payment_method_id', v_id,
    'kind', 'manual',
    'auto_renew', false,
    -- Said plainly, because the whole failure mode of this path is a school
    -- believing it is on autopilot when it is not.
    'note', 'Recorded. Nothing is charged automatically: you send the payment '
      || 'and we match it against your invoice. We will remind you before it '
      || 'is due.',
    'next', public.fn_my_next_payment());
end;
$$;

grant  execute on function public.fn_set_manual_payment_method(text, text) to authenticated;
revoke execute on function public.fn_set_manual_payment_method(text, text) from public, anon;

-- ---------------------------------------------------------------------------
-- 8. Choosing the term
--
-- Separate from the payment method on purpose: a school changes its mind about
-- one without touching the other, and a single "save my subscription settings"
-- call that did both would make a failed card update also silently revert a
-- term change.
--
-- It changes what the NEXT charge is, never the period already paid for. A
-- school moving from monthly to annual mid-month does not get billed for a year
-- today; it gets billed for a year when its month runs out.
-- ---------------------------------------------------------------------------
create or replace function public.fn_choose_term(p_months integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_was integer;
begin
  if v_school is null or not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal can change the billing term'
      using errcode = '42501';
  end if;
  -- The three terms that are sold. An operator can invoice any number of
  -- months; a school choosing its own term picks from the price list.
  if p_months not in (1, 3, 12) then
    raise exception 'Choose one month, three months or a year';
  end if;

  select term_months into v_was from public.subscriptions where school_id = v_school;
  if v_was is null then
    raise exception 'This school has no subscription to change';
  end if;

  update public.subscriptions set term_months = p_months where school_id = v_school;

  insert into public.audit_log(school_id, actor, action, entity, entity_id, before, after)
  values (v_school, auth.uid(), 'term_changed', 'subscriptions', v_school::text,
          jsonb_build_object('term_months', v_was),
          jsonb_build_object('term_months', p_months));

  return jsonb_build_object(
    'term_months', p_months,
    'applies_from', 'the next payment, not the period you have already paid for',
    'next', public.fn_my_next_payment());
end;
$$;

grant  execute on function public.fn_choose_term(integer) to authenticated;
revoke execute on function public.fn_choose_term(integer) from public, anon;
