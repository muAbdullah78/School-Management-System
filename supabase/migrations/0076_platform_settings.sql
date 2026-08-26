-- =============================================================================
-- 0076 — The invoices had no seller on them
--
-- Phase 3 of docs/SUPER-ADMIN-DESIGN.md, first of three.
--
-- 0064 built the books: platform_invoices records what a school was charged and
-- platform_payments what it paid. What it cannot do is produce a DOCUMENT. A
-- Pakistani school's accountant cannot pay against a row in a table. They need
-- a piece of paper with:
--
--   * the seller's registered name, address and NTN — without the NTN the
--     school cannot claim the expense, and cannot file the withholding tax it is
--     obliged by law to deduct from a services invoice
--   * an invoice number that is part of an unbroken series
--   * the amount in words, because that is what a bank counter accepts and what
--     every Pakistani invoice, challan and cheque carries
--   * the bank account to pay into
--
-- None of that exists anywhere in this schema. `fn_platform_ledger` returns
-- "growth · 12 months · 2027-07-26 to 2028-07-25" and an amount. That is a
-- record of a sale, not an invoice.
--
-- WHY A TABLE AND NOT A CONSTANT
--
-- The obvious shortcut is to hardcode the business name, NTN and bank details
-- in a migration, or to paste them into an environment variable. Both are
-- wrong for the same reason: they make the operator ask a developer to change
-- a bank account. An NTN is issued once, but a bank account changes, an address
-- changes, and a business that grows registers for sales tax and acquires an
-- STRN it did not have. Those are Settings, and Settings belong in a row a
-- screen can edit.
--
-- It also keeps the values OUT of the repository. A registered address and a
-- bank account number in a public git history is a thing you cannot take back.
--
-- SINGLE ROW, ENFORCED
--
--   id boolean primary key default true check (id)
--
-- One row, always, and it is impossible to insert a second: the only value the
-- check permits is `true`, and `true` is already taken by the primary key. This
-- is better than a `limit 1` convention, which is a rule that lives in whoever
-- remembers it.
--
-- WHAT IS DELIBERATELY NOT HERE
--
--   * No tax RATES beyond a default withholding percentage. Sales tax on
--     services in Pakistan is provincial (PRA/SRB/KPRA/BRA), the rate depends
--     on the province AND on whether the buyer is a withholding agent, and this
--     software is not going to guess that correctly. 0077 puts a tax line on
--     the invoice that the operator fills in per invoice, with the default as a
--     starting point. A wrong rate printed confidently is worse than a blank.
--
--   * No payment gateway credentials. `gateway_enabled` is a switch and
--     `gateway_provider` a name; keys belong in the Edge Function's secrets,
--     never in a table the browser can reach through a definer function.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The row
-- ---------------------------------------------------------------------------
create table if not exists public.platform_settings (
  id boolean primary key default true check (id),

  -- --- who is selling -----------------------------------------------------
  -- Defaults are empty rather than plausible. A placeholder like
  -- "Your Company (Pvt) Ltd" reads as filled in, and would be printed on a real
  -- invoice by somebody who assumed it was already configured. Blank is loud.
  business_name text not null default '',
  ntn           text,
  strn          text,
  address       text,
  city          text,
  phone         text,
  email         text,
  website       text,

  -- --- where the money goes ----------------------------------------------
  bank_name     text,
  bank_title    text,   -- the account TITLE, which is what a bank teller checks
  bank_account  text,
  bank_iban     text,

  -- --- document series ----------------------------------------------------
  -- Two series, because a credit note is not an invoice and must not consume an
  -- invoice number: an unbroken invoice series is what a tax audit looks at.
  invoice_prefix text not null default 'INV'
    check (invoice_prefix ~ '^[A-Z0-9-]{1,8}$'),
  credit_prefix  text not null default 'CN'
    check (credit_prefix ~ '^[A-Z0-9-]{1,8}$'),
  payment_terms_days integer not null default 14
    check (payment_terms_days between 0 and 180),

  -- The rate a school is expected to withhold, as a STARTING POINT for the
  -- operator to accept or change per invoice. Not applied automatically: see
  -- 0077 on why silence beats a confident guess.
  default_withholding_pct numeric(5,2) not null default 0
    check (default_withholding_pct >= 0 and default_withholding_pct <= 100),

  invoice_footer text,

  -- --- the gateway switch -------------------------------------------------
  -- Bank transfer now, a gateway later, and the switch decides which one the
  -- school-facing screen offers. Off means the school is shown bank details and
  -- an "I have paid" form; on means it is additionally shown a pay button.
  -- No credentials here — see the header.
  gateway_enabled  boolean not null default false,
  gateway_provider text
    check (gateway_provider is null
           or gateway_provider in ('jazzcash', 'easypaisa', 'stripe', 'other')),

  updated_at timestamptz not null default now(),
  updated_by uuid
);

-- The row itself. `on conflict do nothing` so re-running changes nothing.
insert into public.platform_settings (id) values (true) on conflict (id) do nothing;

alter table public.platform_settings enable row level security;

-- Operator-readable, and NOT writable through RLS: every field is validated in
-- fn_platform_save_settings, which is the same argument 0064 made for invoices.
-- A direct UPDATE could set invoice_prefix to something the document series
-- cannot represent, and the check constraint is the only thing that would catch
-- it — constraints are a floor, not a policy.
--
-- A school user must not read this table. The bank details a school needs to
-- pay reach it through fn_my_billing (0078), which returns the four bank fields
-- and nothing else — not the gateway provider, not the withholding default, not
-- the document prefixes.
drop policy if exists platform_settings_select on public.platform_settings;
create policy platform_settings_select on public.platform_settings
  for select to authenticated using (public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- 2. Amount in words
--
-- Every Pakistani invoice, cheque and fee challan carries the amount in words,
-- and it is not decoration: it is the version a bank teller and a court both
-- treat as authoritative when the figures disagree.
--
-- SOUTH ASIAN GROUPING, NOT WESTERN. 1,250,000 is "Twelve Lakh Fifty Thousand",
-- not "One Million Two Hundred Fifty Thousand". Getting this wrong is the tell
-- that a document was produced by software written for somewhere else.
--
-- Immutable and pure — no table reads, so it is safe to call from anywhere and
-- the planner can fold it.
-- ---------------------------------------------------------------------------
create or replace function public.fn__words_below_100(n integer)
returns text language sql immutable as $$
  select case
    when n is null or n <= 0 then ''
    when n < 20 then (array['Zero','One','Two','Three','Four','Five','Six','Seven',
                            'Eight','Nine','Ten','Eleven','Twelve','Thirteen',
                            'Fourteen','Fifteen','Sixteen','Seventeen','Eighteen',
                            'Nineteen'])[n + 1]
    else btrim(
      (array['','','Twenty','Thirty','Forty','Fifty','Sixty','Seventy','Eighty',
             'Ninety'])[(n / 10) + 1]
      || case when n % 10 = 0 then ''
              else ' ' || (array['Zero','One','Two','Three','Four','Five','Six',
                                 'Seven','Eight','Nine'])[(n % 10) + 1] end)
  end;
$$;

create or replace function public.fn__words_below_1000(n integer)
returns text language sql immutable as $$
  select case
    when n is null or n <= 0 then ''
    when n < 100 then public.fn__words_below_100(n)
    else btrim(public.fn__words_below_100(n / 100) || ' Hundred'
      || case when n % 100 = 0 then ''
              else ' ' || public.fn__words_below_100(n % 100) end)
  end;
$$;

create or replace function public.fn__amount_in_words(p_amount numeric)
returns text language plpgsql immutable as $$
declare
  v_amt   numeric;
  v_rup   bigint;
  v_paisa integer;
  v_rem   bigint;
  v_parts text[] := '{}';
  v_words text;
  v_neg   boolean;
begin
  if p_amount is null then
    return '';
  end if;

  v_neg := p_amount < 0;
  v_amt := round(abs(p_amount), 2);

  v_rup   := floor(v_amt)::bigint;
  -- Computed from the already-rounded value, so 0.005 cannot produce 100 paisa
  -- here. Guarded anyway: a carry that is impossible today becomes possible the
  -- day somebody changes the rounding above, and the failure would be the words
  -- "Zero Rupees and Hundred Paisa" on a customer's invoice.
  v_paisa := round((v_amt - floor(v_amt)) * 100)::integer;
  if v_paisa >= 100 then
    v_rup   := v_rup + 1;
    v_paisa := v_paisa - 100;
  end if;

  -- Crore (10^7) can exceed 99 — Rs 100 crore is a number a business can reach —
  -- so that group gets the below-1000 form. Lakh, thousand and hundred are
  -- bounded at 99, 99 and 9 by construction.
  v_rem := v_rup;
  if v_rem / 10000000 > 0 then
    v_parts := array_append(v_parts,
      public.fn__words_below_1000((v_rem / 10000000)::integer) || ' Crore');
    v_rem := v_rem % 10000000;
  end if;
  if v_rem / 100000 > 0 then
    v_parts := array_append(v_parts,
      public.fn__words_below_100((v_rem / 100000)::integer) || ' Lakh');
    v_rem := v_rem % 100000;
  end if;
  if v_rem / 1000 > 0 then
    v_parts := array_append(v_parts,
      public.fn__words_below_100((v_rem / 1000)::integer) || ' Thousand');
    v_rem := v_rem % 1000;
  end if;
  if v_rem > 0 then
    v_parts := array_append(v_parts, public.fn__words_below_1000(v_rem::integer));
  end if;

  v_words := case when array_length(v_parts, 1) is null
                  then 'Zero' else array_to_string(v_parts, ' ') end;

  return btrim(
    case when v_neg then 'Minus ' else '' end
    || 'Rupees ' || v_words
    || case when v_paisa > 0
            then ' and ' || public.fn__words_below_100(v_paisa) || ' Paisa'
            else '' end
    || ' Only');
end;
$$;

-- Internal helpers. Revoked from every browser role: nothing outside a definer
-- function has business calling them, and check-definer-idor.py fails CI if an
-- fn__* is left callable.
revoke all on function public.fn__words_below_100(integer)  from public, anon, authenticated;
revoke all on function public.fn__words_below_1000(integer) from public, anon, authenticated;
revoke all on function public.fn__amount_in_words(numeric)  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Reading and writing the settings
--
-- `missing` is the part that matters. An invoice printed with a blank NTN is
-- useless to the school receiving it and they will not tell us — they will just
-- fail to claim it, or phone about it in three weeks. So the read reports which
-- required fields are empty, and the screen shows that as a warning before the
-- first invoice is ever printed rather than after.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_settings()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v record; v_missing text[] := '{}';
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  select * into v from public.platform_settings where id;
  if not found then
    -- Cannot happen: the insert above is part of this migration. Reported rather
    -- than returning null, because a null here would render as an empty form
    -- that silently saves nothing.
    raise exception 'Platform settings row is missing';
  end if;

  if btrim(coalesce(v.business_name, '')) = '' then
    v_missing := array_append(v_missing, 'business_name');
  end if;
  if btrim(coalesce(v.ntn, '')) = '' then
    v_missing := array_append(v_missing, 'ntn');
  end if;
  if btrim(coalesce(v.address, '')) = '' then
    v_missing := array_append(v_missing, 'address');
  end if;
  -- A school cannot pay a bank transfer without an account number, and the
  -- title is what the teller matches. IBAN is optional: it is the same account.
  if btrim(coalesce(v.bank_account, '')) = '' then
    v_missing := array_append(v_missing, 'bank_account');
  end if;
  if btrim(coalesce(v.bank_title, '')) = '' then
    v_missing := array_append(v_missing, 'bank_title');
  end if;
  if btrim(coalesce(v.bank_name, '')) = '' then
    v_missing := array_append(v_missing, 'bank_name');
  end if;

  return jsonb_build_object(
    'business_name', v.business_name, 'ntn', v.ntn, 'strn', v.strn,
    'address', v.address, 'city', v.city, 'phone', v.phone, 'email', v.email,
    'website', v.website,
    'bank_name', v.bank_name, 'bank_title', v.bank_title,
    'bank_account', v.bank_account, 'bank_iban', v.bank_iban,
    'invoice_prefix', v.invoice_prefix, 'credit_prefix', v.credit_prefix,
    'payment_terms_days', v.payment_terms_days,
    'default_withholding_pct', v.default_withholding_pct,
    'invoice_footer', v.invoice_footer,
    'gateway_enabled', v.gateway_enabled, 'gateway_provider', v.gateway_provider,
    'updated_at', v.updated_at,
    -- Empty array means ready to invoice. The screen renders this list, and
    -- 0077's invoice document repeats it so a blank NTN is visible at the moment
    -- somebody is about to print.
    'missing', to_jsonb(v_missing));
end;
$$;

-- Takes a jsonb patch rather than 20 parameters. Only the keys PRESENT are
-- changed, so the settings screen can save one field without having to send —
-- and therefore risk overwriting — the other nineteen.
create or replace function public.fn_platform_save_settings(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_known text[] := array[
    'business_name','ntn','strn','address','city','phone','email','website',
    'bank_name','bank_title','bank_account','bank_iban',
    'invoice_prefix','credit_prefix','payment_terms_days',
    'default_withholding_pct','invoice_footer',
    'gateway_enabled','gateway_provider'];
  k text;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'Give an object of settings to change';
  end if;

  -- A key this function does not know is a mistake somewhere — a typo in the
  -- client, or a field renamed on one side only. Ignoring it silently means the
  -- screen shows a saved value that was never stored.
  for k in select x from jsonb_object_keys(p) x loop
    if not (k = any(v_known)) then
      raise exception 'Unknown setting: %', k;
    end if;
  end loop;

  update public.platform_settings s set
    business_name = case when p ? 'business_name'
      then btrim(coalesce(p->>'business_name', '')) else s.business_name end,
    ntn      = case when p ? 'ntn'      then nullif(btrim(coalesce(p->>'ntn', '')), '')      else s.ntn end,
    strn     = case when p ? 'strn'     then nullif(btrim(coalesce(p->>'strn', '')), '')     else s.strn end,
    address  = case when p ? 'address'  then nullif(btrim(coalesce(p->>'address', '')), '')  else s.address end,
    city     = case when p ? 'city'     then nullif(btrim(coalesce(p->>'city', '')), '')     else s.city end,
    phone    = case when p ? 'phone'    then nullif(btrim(coalesce(p->>'phone', '')), '')    else s.phone end,
    email    = case when p ? 'email'    then nullif(btrim(coalesce(p->>'email', '')), '')    else s.email end,
    website  = case when p ? 'website'  then nullif(btrim(coalesce(p->>'website', '')), '')  else s.website end,
    bank_name    = case when p ? 'bank_name'    then nullif(btrim(coalesce(p->>'bank_name', '')), '')    else s.bank_name end,
    bank_title   = case when p ? 'bank_title'   then nullif(btrim(coalesce(p->>'bank_title', '')), '')   else s.bank_title end,
    bank_account = case when p ? 'bank_account' then nullif(btrim(coalesce(p->>'bank_account', '')), '') else s.bank_account end,
    bank_iban    = case when p ? 'bank_iban'    then nullif(btrim(upper(coalesce(p->>'bank_iban', ''))), '') else s.bank_iban end,
    -- Upper-cased rather than rejected for case: an operator typing "inv" means
    -- INV, and refusing that is a form to fight rather than a form to fill.
    invoice_prefix = case when p ? 'invoice_prefix'
      then upper(btrim(coalesce(p->>'invoice_prefix', ''))) else s.invoice_prefix end,
    credit_prefix  = case when p ? 'credit_prefix'
      then upper(btrim(coalesce(p->>'credit_prefix', ''))) else s.credit_prefix end,
    payment_terms_days = case when p ? 'payment_terms_days'
      then (p->>'payment_terms_days')::integer else s.payment_terms_days end,
    default_withholding_pct = case when p ? 'default_withholding_pct'
      then (p->>'default_withholding_pct')::numeric else s.default_withholding_pct end,
    invoice_footer = case when p ? 'invoice_footer'
      then nullif(btrim(coalesce(p->>'invoice_footer', '')), '') else s.invoice_footer end,
    gateway_enabled = case when p ? 'gateway_enabled'
      then (p->>'gateway_enabled')::boolean else s.gateway_enabled end,
    gateway_provider = case when p ? 'gateway_provider'
      then nullif(btrim(lower(coalesce(p->>'gateway_provider', ''))), '') else s.gateway_provider end,
    updated_at = now(),
    updated_by = auth.uid()
  where s.id;

  -- Switching the gateway on with no provider named would give the school a pay
  -- button wired to nothing. Checked after the update so it sees the resulting
  -- state rather than the patch, which may set only one of the two.
  if exists (select 1 from public.platform_settings
              where id and gateway_enabled and gateway_provider is null) then
    raise exception 'Name the gateway provider before switching online payment on';
  end if;

  -- The keys that changed, not the values: a bank account number does not belong
  -- in an activity feed, and "who changed the bank details and when" is the
  -- question this answers. school_id null — this is not about one school.
  perform public.fn__log_operator_action('settings_changed', null,
    jsonb_build_object('fields', (select coalesce(jsonb_agg(x), '[]'::jsonb)
                                    from jsonb_object_keys(p) x)));

  return public.fn_platform_settings();
end;
$$;

grant  execute on function public.fn_platform_settings()            to authenticated;
revoke execute on function public.fn_platform_settings()          from public, anon;
grant  execute on function public.fn_platform_save_settings(jsonb)  to authenticated;
revoke execute on function public.fn_platform_save_settings(jsonb) from public, anon;
