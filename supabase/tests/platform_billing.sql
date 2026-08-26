-- =============================================================================
-- Platform billing: documents, corrections, withholding tax, renewals, and the
-- school's own view of its bill.
--
-- Covers 0076, 0077 and 0078. The four defects those migrations were written for
-- are each reproduced here as a test that FAILS if the fix is reverted:
--
--   1. no document number            → assertions 10-14
--   2. an invoice raised in error is permanent → 20-29 (void)
--   3. no way to give anything back   → 30-39 (credit notes)
--   4. WITHHOLDING TAX MADE EVERY BALANCE WRONG → 40-45
--
-- Defect 4 is the one to read first if this file ever starts failing. A school
-- invoiced Rs 38,000 that deducts 8% tax at source pays Rs 34,960 and sends a
-- CPR. Before 0077 the software reported Rs 3,040 outstanding forever, and the
-- operator would chase a school for money it had already paid — to the FBR, in
-- our name. Assertion 42 is that number being zero.
--
-- The other rule this file defends, and it is the important one:
--
--   A SCHOOL CANNOT MOVE ITS OWN BALANCE.
--
-- 0078 gives a school a form that says "I have paid, reference 4471". That form
-- writes to platform_payment_claims, which is a REQUEST and changes no total.
-- Assertions 50-64 sweep every way a school might try to turn a request into
-- money: insert a payment, update a claim to confirmed, call the operator's
-- confirm function, forge an invoice, read another school's books.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/platform_billing.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if p_cond then raise notice 'PASS  %', p_label;
  else raise exception 'FAIL  %', p_label; end if;
end;
$$;

-- Numeric equality without float surprises. The books are numeric(12,2) and a
-- comparison against an integer literal must not depend on how psql renders it.
create or replace function pg_temp.eq(a numeric, b numeric) returns boolean
language sql immutable as $$ select round(coalesce(a, -1), 2) = round(b, 2) $$;

create or replace function pg_temp.refused(p_sql text) returns boolean
language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return true;
end;
$$;

-- The message, so an assertion can prove a refusal happened for the RIGHT reason.
-- "It raised something" is how a test passes on a typo.
create or replace function pg_temp.why(p_sql text) returns text
language plpgsql as $$
begin
  execute p_sql;
  return '(no error)';
exception when others then
  return sqlerrm;
end;
$$;

-- --- Fixture: two schools, one operator, one non-owner ------------------------
do $seed$
declare
  a_school uuid; b_school uuid; g_school uuid;
  a_owner  uuid := '00000000-0000-0000-0000-0000000007a1';
  a_acct   uuid := '00000000-0000-0000-0000-0000000007a2';
  b_owner  uuid := '00000000-0000-0000-0000-0000000007b1';
  ops      uuid := '00000000-0000-0000-0000-0000000007fa';
begin
  insert into public.schools (name, city, contact_name, contact_phone, contact_email)
    values ('Billing Alpha', 'Lahore', 'Rashid Sahib', '0300-1112223', 'a@bill.test')
    returning id into a_school;
  insert into public.schools (name, city, contact_name, contact_phone)
    values ('Billing Beta', 'Karachi', 'Nadia Sahiba', '0333-2223334')
    returning id into b_school;
  -- Gamma exists to be LEFT ALONE. Beta gets renewed in the numbering block
  -- below, which pushes its expiry a year out — the first version of this suite
  -- asserted on Beta being overdue after renewing it, and the worklist
  -- assertions passed for the wrong reason until Gamma was added.
  insert into public.schools (name, city, contact_name, contact_phone)
    values ('Billing Gamma', 'Multan', 'Iqbal Sahib', '+92 321 4445556')
    returning id into g_school;

  -- Alpha is live for another 20 days on growth; Beta and Gamma expired 5 days
  -- ago, so both are in grace.
  insert into public.subscriptions
    (school_id, plan_code, status, cycle, period_start, period_end, grace_ends_on,
     student_count)
  values
    (a_school, 'growth', 'active', 'yearly',
     current_date - 345, current_date + 20, current_date + 20 + 14, 140),
    (b_school, 'starter', 'active', 'yearly',
     current_date - 370, current_date - 5, current_date - 5 + 14, 60),
    -- 420 students on `starter` (limit 100): the renewal quote must follow the
    -- COUNT, not the plan they are sitting on. Quoting Rs 9,500 to a school that
    -- needs Rs 35,000 of licence is how a renewal becomes an argument.
    (g_school, 'starter', 'active', 'yearly',
     current_date - 370, current_date - 5, current_date - 5 + 14, 420);

  -- A row already exists: creating a school provisions its settings. Upserted so
  -- the suite does not depend on which.
  insert into public.school_settings (school_id, name, address, phone, principal_name)
    values (a_school, 'Billing Alpha Public School, Lahore',
            '12 Ferozepur Road, Lahore', '042-3512345', 'Rashid Ahmed')
  on conflict (school_id) do update
    set name = excluded.name, address = excluded.address,
        phone = excluded.phone, principal_name = excluded.principal_name;

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (a_owner, 'a-owner@bill.test'), (a_acct, 'a-acct@bill.test'),
    (b_owner, 'b-owner@bill.test'), (ops, 'ops@bill.test')
  on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (a_owner, 'Alpha Owner', 'owner', a_school),
    (a_acct,  'Alpha Accountant', 'accountant', a_school),
    (b_owner, 'Beta Owner', 'owner', b_school)
  on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;

  insert into public.platform_admins (user_id, email) values (ops, 'ops@bill.test')
    on conflict (user_id) do nothing;

  create temp table _bill (k text primary key, v uuid);
  insert into _bill values
    ('a', a_school), ('b', b_school), ('g', g_school),
    ('a_owner', a_owner), ('a_acct', a_acct),
    ('b_owner', b_owner), ('ops', ops);
end $seed$;

-- Somewhere to stash ids between blocks. A temp table rather than session GUCs so
-- a typo is a missing row rather than an empty string that silently casts.
create temp table _bdoc (k text primary key, v text);

-- The blocks below read these while acting as `authenticated`, and a temp table
-- is not readable by another role by default. `pg_temp` is a per-session ALIAS,
-- not a schema name, so it cannot be granted on directly — the real name has to
-- be looked up. operator_support.sql learned this the same way.
do $grant_bill$
declare v_ns text;
begin
  select n.nspname into v_ns
    from pg_namespace n join pg_class c on c.relnamespace = n.oid
   where c.relname = '_bill' and n.nspname like 'pg\_temp%';
  execute format('grant usage on schema %I to authenticated', v_ns);
  grant select on _bill to authenticated;
  grant select on _bdoc to authenticated;
end $grant_bill$;

create or replace function public._bact(p_key text) returns void
language plpgsql as $$
begin
  perform set_config('test.uid', (select v::text from _bill where k = p_key), false);
end;
$$;


-- =============================================================================
-- 1-9  AMOUNT IN WORDS, and the settings row
-- =============================================================================
do $words$
begin
  -- South Asian grouping. Getting this wrong is the tell that a document was
  -- produced by software written for somewhere else, and a bank teller is the
  -- one who notices.
  perform pg_temp.ok(public.fn__amount_in_words(1250000)
    = 'Rupees Twelve Lakh Fifty Thousand Only', '1 amount in words uses lakh');
  perform pg_temp.ok(public.fn__amount_in_words(12345678)
    = 'Rupees One Crore Twenty Three Lakh Forty Five Thousand Six Hundred Seventy Eight Only',
    '2 amount in words uses crore');
  perform pg_temp.ok(public.fn__amount_in_words(0) = 'Rupees Zero Only',
    '3 zero has words');
  perform pg_temp.ok(public.fn__amount_in_words(38000.50)
    = 'Rupees Thirty Eight Thousand and Fifty Paisa Only', '4 paisa');
  perform pg_temp.ok(public.fn__amount_in_words(20) = 'Rupees Twenty Only',
    '5 exact tens have no trailing word');
  perform pg_temp.ok(public.fn__amount_in_words(115)
    = 'Rupees One Hundred Fifteen Only', '6 hundreds and teens');
end $words$;

do $settings$
declare r jsonb;
begin
  -- A school user must not reach the vendor's settings at all.
  perform public._bact('a_owner');
  set local role authenticated;
  perform pg_temp.ok(pg_temp.refused('select public.fn_platform_settings()'),
    '7 a school owner cannot read the platform settings');
  perform pg_temp.ok((select count(*) from public.platform_settings) = 0,
    '7b and cannot read the table through RLS either');
  reset role;

  perform public._bact('ops');
  r := public.fn_platform_settings();
  -- Everything blank on a fresh database, and the read SAYS SO rather than
  -- returning a form that looks configured.
  perform pg_temp.ok(r->'missing' @> '["ntn"]'::jsonb
                 and r->'missing' @> '["bank_account"]'::jsonb,
    '8 an unconfigured settings row reports what is missing');

  r := public.fn_platform_save_settings(jsonb_build_object(
    'business_name', '  Brndsh Technologies  ',
    'ntn', '1234567-8', 'strn', '3277876543210',
    'address', 'Office 4, Gulberg III, Lahore', 'city', 'Lahore',
    'phone', '0300-9998887', 'email', 'billing@brndsh.test',
    'bank_name', 'Meezan Bank', 'bank_title', 'Brndsh Technologies',
    'bank_account', '01234567890123', 'bank_iban', 'pk36meza0000001234567890',
    'default_withholding_pct', 8, 'invoice_prefix', 'bsh',
    'payment_terms_days', 10));
  perform pg_temp.ok(r->>'business_name' = 'Brndsh Technologies',
    '9 saving trims the business name');
  perform pg_temp.ok(r->>'bank_iban' = 'PK36MEZA0000001234567890',
    '9b an IBAN is stored upper-cased');
  perform pg_temp.ok(r->>'invoice_prefix' = 'BSH',
    '9c a lower-case prefix is accepted and upper-cased, not refused');
  perform pg_temp.ok(r->'missing' = '[]'::jsonb,
    '9d nothing is missing once it is filled in');

  -- A key this function does not know is a mistake on one side or the other, and
  -- ignoring it would show a saved value that was never stored.
  perform pg_temp.ok(pg_temp.refused(
    'select public.fn_platform_save_settings(''{"bank_acount":"1"}''::jsonb)'),
    '9e a misspelled setting is refused, not ignored');
  -- A pay button wired to nothing.
  perform pg_temp.ok(pg_temp.refused(
    'select public.fn_platform_save_settings(''{"gateway_enabled":true}''::jsonb)'),
    '9f the gateway cannot be switched on with no provider named');
  perform pg_temp.ok(pg_temp.refused(
    'select public.fn_platform_save_settings(''{"invoice_prefix":"much too long"}''::jsonb)'),
    '9g an unusable prefix is refused');
end $settings$;

-- =============================================================================
-- 10-19  DOCUMENT NUMBERS
-- =============================================================================
do $numbers$
declare
  a uuid := (select v from _bill where k='a');
  b uuid := (select v from _bill where k='b');
  r jsonb; i1 uuid; i2 uuid; n1 text; n2 text;
begin
  perform public._bact('ops');

  r := public.fn_activate_subscription(a, 'growth', 12);
  i1 := (r->>'invoice_id')::uuid;
  select doc_no into n1 from public.platform_invoices where id = i1;
  perform pg_temp.ok(n1 = 'BSH-0001',
    '10 the first invoice takes the configured prefix and serial 1');

  r := public.fn_activate_subscription(b, 'starter', 12);
  i2 := (r->>'invoice_id')::uuid;
  select doc_no into n2 from public.platform_invoices where id = i2;
  perform pg_temp.ok(n2 = 'BSH-0002', '11 the series continues across schools');

  insert into _bdoc values ('i_a', i1::text), ('i_b', i2::text);

  -- Renaming the series must not rename a document a customer is holding.
  perform public.fn_platform_save_settings('{"invoice_prefix":"INV"}'::jsonb);
  perform pg_temp.ok(
    (select doc_no from public.platform_invoices where id = i1) = 'BSH-0001',
    '12 changing the prefix does not renumber what is already issued');

  r := public.fn_activate_subscription(a, 'growth', 1, 2000, 'monthly top-up');
  perform pg_temp.ok(
    (select doc_no from public.platform_invoices where id = (r->>'invoice_id')::uuid)
      = 'INV-0003',
    '13 the serial keeps counting across a prefix change, so the series is unbroken');
  insert into _bdoc values ('i_a2', (r->>'invoice_id'));

  -- The unique index is a backstop, but the trigger is what must be right.
  perform pg_temp.ok(
    (select count(distinct doc_no) = count(*) from public.platform_invoices),
    '14 every document number is distinct');
  perform pg_temp.ok(
    (select count(*) from public.platform_invoices where doc_no is null) = 0,
    '14b no document is left without a number');
end $numbers$;

-- =============================================================================
-- 20-29  VOID
-- =============================================================================
do $void$
declare
  a uuid := (select v from _bill where k='a');
  i_a  uuid := (select v::uuid from _bdoc where k='i_a');
  i_a2 uuid := (select v::uuid from _bdoc where k='i_a2');
  before_owed numeric; after_owed numeric; r jsonb; msg text;
begin
  perform public._bact('ops');
  before_owed := public.fn_platform_outstanding(a);
  perform pg_temp.ok(pg_temp.eq(before_owed, 22000),
    '20 Alpha owes the yearly 20,000 plus the 2,000 top-up');

  perform pg_temp.ok(pg_temp.refused(
    format('select public.fn_platform_void_invoice(%L, ''  '')', i_a2)),
    '21 voiding without a reason is refused');

  r := public.fn_platform_void_invoice(i_a2, 'raised twice by mistake');
  after_owed := public.fn_platform_outstanding(a);
  perform pg_temp.ok(pg_temp.eq(after_owed, 20000),
    '22 a voided invoice leaves the balance');
  -- The reproduction of defect 2 in 0077's header: before this, a double-click
  -- renewal was permanent.
  perform pg_temp.ok(pg_temp.eq(before_owed - after_owed, 2000),
    '22b and takes exactly its own amount out of it');

  perform pg_temp.ok(r->>'warning' is not null,
    '23 voiding the invoice for the live period warns that the licence stands');

  perform pg_temp.ok(pg_temp.refused(
    format('select public.fn_platform_void_invoice(%L, ''again'')', i_a2)),
    '24 the same document cannot be voided twice');

  -- Still a row. Deleting history is how a business loses an audit.
  perform pg_temp.ok(exists (select 1 from public.platform_invoices
                              where id = i_a2 and voided_at is not null),
    '25 the voided invoice is still on record');
  perform pg_temp.ok(
    (select charged from public.fn_platform_ledger(a) where entry_id = i_a2) = 0,
    '25b it appears in the ledger charging nothing');
  perform pg_temp.ok(
    (select voided and note like 'VOID%' from public.fn_platform_ledger(a)
      where entry_id = i_a2),
    '25c and says why');

  -- A payment against it must not be possible: that is how a void invoice comes
  -- back as a balance nobody can explain.
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_record_payment(%L, 100, null, ''bank'', null, %L)', a, i_a2)),
    '26 a payment cannot be allocated to a voided invoice');

  -- And the reverse: an invoice with money against it must be credited, not
  -- voided. This is the distinction the whole design turns on.
  perform public.fn_platform_record_payment(a, 5000, current_date, 'bank', 'TR-1', i_a);
  msg := pg_temp.why(format(
    'select public.fn_platform_void_invoice(%L, ''changed my mind'')', i_a));
  perform pg_temp.ok(msg like '%credit note%',
    '27 an invoice with a payment against it cannot be voided, and says to credit it');
  perform pg_temp.ok(pg_temp.eq(public.fn_platform_outstanding(a), 15000),
    '28 the payment moved the balance');

  perform pg_temp.ok(exists (select 1 from public.operator_actions
                              where action = 'invoice_voided' and school_id = a),
    '29 the void is in the operator log');
end $void$;

-- =============================================================================
-- 30-39  CREDIT NOTES
-- =============================================================================
do $credit$
declare
  a uuid := (select v from _bill where k='a');
  i_a uuid := (select v::uuid from _bdoc where k='i_a');
  r jsonb; msg text; cn uuid;
begin
  perform public._bact('ops');

  perform pg_temp.ok(pg_temp.refused(
    format('select public.fn_platform_credit_note(%L, 1000, '' '')', i_a)),
    '30 a credit note needs a reason');
  perform pg_temp.ok(pg_temp.refused(
    format('select public.fn_platform_credit_note(%L, 0, ''x'')', i_a)),
    '30b and an amount above zero');

  -- Over-crediting turns a receivable into a liability the software cannot pay.
  msg := pg_temp.why(format(
    'select public.fn_platform_credit_note(%L, 25000, ''too much'')', i_a));
  perform pg_temp.ok(msg like '%At most%',
    '31 crediting more than the invoice is refused, and says how much remains');

  r := public.fn_platform_credit_note(i_a, 4000, 'left in March, four months unused');
  cn := (r->>'credit_note_id')::uuid;
  perform pg_temp.ok(r->>'doc_no' = 'CN-0001',
    '32 a credit note takes its own series, not an invoice number');
  perform pg_temp.ok(pg_temp.eq((r->>'outstanding')::numeric, 11000),
    '33 the credit reduces what the school owes');
  perform pg_temp.ok(
    (select credits_invoice_id from public.platform_invoices where id = cn) = i_a,
    '34 and points at the invoice it credits');
  perform pg_temp.ok(
    (select net_total from public.platform_invoices where id = cn) = -4000,
    '34b a credit note counts negative');

  -- Its remaining room shrinks, and the second credit fits exactly.
  perform public.fn_platform_credit_note(i_a, 16000, 'balance of the year');
  perform pg_temp.ok(pg_temp.eq(public.fn_platform_outstanding(a), -5000),
    '35 fully credited, the 5,000 already paid is now a credit to the school');
  perform pg_temp.ok(pg_temp.refused(
    format('select public.fn_platform_credit_note(%L, 1, ''one rupee more'')', i_a)),
    '36 nothing remains to credit');

  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_credit_note(%L, 100, ''x'')',
    (select v from _bdoc where k='i_a2'))),
    '37 a voided invoice cannot be credited');
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_credit_note(%L, 100, ''x'')', cn)),
    '38 and neither can a credit note');

  -- A refund is not a discount, and revenue must not report it as one.
  r := public.fn_platform_revenue(current_date - 1, current_date + 1);
  perform pg_temp.ok(pg_temp.eq((r->>'credited')::numeric, 20000),
    '39 revenue reports what was credited');
  perform pg_temp.ok(pg_temp.eq((r->>'discounted')::numeric, 0),
    '39b and does not count a credit note as a discount');
  perform pg_temp.ok(pg_temp.eq((r->>'voided')::numeric, 2000),
    '39c and reports what was voided rather than dropping it silently');
  perform pg_temp.ok(exists (select 1 from public.operator_actions
                              where action = 'credit_note_raised' and school_id = a),
    '39d the credit note is logged as a credit note, not as an invoice raised');
end $credit$;

-- =============================================================================
-- 40-49  WITHHOLDING TAX — the reproduction of defect 4
-- =============================================================================
do $wht$
declare
  b uuid := (select v from _bill where k='b');
  i_b uuid := (select v::uuid from _bdoc where k='i_b');
  r jsonb; owed numeric;
begin
  perform public._bact('ops');
  perform pg_temp.ok(pg_temp.eq(public.fn_platform_outstanding(b), 9500),
    '40 Beta was invoiced the starter yearly price');

  -- Beta is a withholding agent: it deducts 8% and transfers the rest.
  r := public.fn_platform_record_payment(
         b, 8740, current_date, 'bank', 'HBL-88213', i_b, null, 760, null);
  perform pg_temp.ok(pg_temp.eq((r->>'settled')::numeric, 9500),
    '41 cash plus withheld tax settles the invoice in full');
  owed := public.fn_platform_outstanding(b);
  -- THE DEFECT. Before 0077 this was 760, forever, and the operator would chase
  -- a school for money it had already paid to the government in our name.
  perform pg_temp.ok(pg_temp.eq(owed, 0),
    '42 nothing is outstanding — the withheld tax was paid, not lost');
  perform pg_temp.ok((r->>'awaiting_certificate')::boolean,
    '43 the payment is flagged as waiting for the CPR');

  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_record_payment(%L, 100, null, ''bank'', null, null, null, 0, ''CPR-9'')', b)),
    '44 a certificate with no withheld amount is refused');
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_record_payment(%L, 100, null, ''bank'', null, null, null, -5)', b)),
    '44b and negative withheld tax is refused');

  -- The CPR arrives three weeks later, which is the normal case.
  perform public.fn_platform_attach_tax_certificate(
    (select id from public.platform_payments where school_id = b and tax_withheld > 0),
    'CPR-2026-77812');
  perform pg_temp.ok(exists (select 1 from public.platform_payments
                              where school_id = b and tax_certificate = 'CPR-2026-77812'),
    '45 the certificate can be attached afterwards without inventing a payment');
  perform pg_temp.ok(pg_temp.eq(public.fn_platform_outstanding(b), 0),
    '45b and attaching it changes no balance');

  r := public.fn_platform_revenue(current_date - 1, current_date + 1);
  perform pg_temp.ok(pg_temp.eq((r->>'tax_withheld')::numeric, 760),
    '46 revenue separates the withheld tax');
  perform pg_temp.ok(pg_temp.eq((r->>'cash_received')::numeric,
                                (r->>'collected')::numeric - 760),
    '46b so a cash-flow question can be answered as well as a revenue one');
  perform pg_temp.ok(pg_temp.eq((r->>'tax_certificates_awaited')::numeric, 0),
    '46c and nothing is awaiting a certificate now');

  -- The total on a document a customer is holding must not change under them.
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_set_invoice_tax(%L, 16)', i_b)),
    '47 the tax on a paid invoice cannot be changed');
end $wht$;

-- =============================================================================
-- 50-59  THE PRINTABLE DOCUMENT
-- =============================================================================
do $doc$
declare
  a uuid := (select v from _bill where k='a');
  i_a uuid := (select v::uuid from _bdoc where k='i_a');
  i_b uuid := (select v::uuid from _bdoc where k='i_b');
  d jsonb; r jsonb; i_new uuid;
begin
  perform public._bact('ops');

  -- A fresh invoice with a tax line on it, so the document has something to show.
  r := public.fn_activate_subscription(a, 'growth', 12, null, null, false);
  i_new := (r->>'invoice_id')::uuid;
  perform public.fn_platform_set_invoice_tax(i_new, 16);
  insert into _bdoc values ('i_tax', i_new::text);

  d := public.fn_platform_invoice(i_new);
  perform pg_temp.ok(pg_temp.eq((d->'totals'->>'subtotal')::numeric, 20000)
                 and pg_temp.eq((d->'totals'->>'tax')::numeric, 3200)
                 and pg_temp.eq((d->'totals'->>'total')::numeric, 23200),
    '50 the document totals the tax onto the charge');
  perform pg_temp.ok(d->>'amount_in_words'
    = 'Rupees Twenty Three Thousand Two Hundred Only',
    '51 the words match the total, not the subtotal');
  perform pg_temp.ok(d->'seller'->>'ntn' = '1234567-8'
                 and d->'seller_missing' = '[]'::jsonb,
    '52 the seller block carries the NTN');
  -- An invoice addressed to "Billing Alpha" is an invoice their accountant
  -- queries; school_settings is the name they actually trade under.
  perform pg_temp.ok(d->'buyer'->>'name' = 'Billing Alpha Public School, Lahore',
    '53 the buyer is the name the school uses for itself');
  perform pg_temp.ok(d->'bank'->>'account' = '01234567890123',
    '54 the bank details are on it');
  perform pg_temp.ok(d->>'withholding_note' like '%153(1)(b)%'
                 and d->>'withholding_note' like '%8%',
    '55 it tells the school what to withhold and asks for the CPR');
  -- The RAW dates, not a formatted string. The first version returned
  -- 'period' as "2026-09-01 to 2027-08-31" and the rendered document put ISO
  -- dates on a page whose every other date read "26 Aug 2026" — a customer's
  -- accountant notices that before they notice the total. Formatting is the
  -- document component's job, in one place.
  perform pg_temp.ok(d->'lines'->0->>'period_start' is not null
                 and d->'lines'->0->>'period_end' is not null
                 and (d->'lines'->0->>'period_end')::date
                       > (d->'lines'->0->>'period_start')::date
                 and (d->'lines'->0->>'months')::int = 12,
    '56 one line, the licence period, as dates rather than a rendered string');

  -- The balance shown is THIS document's, not the school's. Putting the school
  -- balance here makes one invoice look unpaid because another one is.
  d := public.fn_platform_invoice(i_a);
  perform pg_temp.ok(pg_temp.eq((d->'totals'->>'paid')::numeric, 5000)
                 and pg_temp.eq((d->'totals'->>'credited')::numeric, 20000)
                 and pg_temp.eq((d->'totals'->>'balance')::numeric, -5000),
    '57 the document shows its own payments and credits');
  perform pg_temp.ok(jsonb_array_length(d->'credit_notes') = 2,
    '57b and lists the credit notes raised against it');

  -- A voided document says so on its face.
  d := public.fn_platform_invoice((select v::uuid from _bdoc where k='i_a2'));
  perform pg_temp.ok((d->>'voided')::boolean
                 and d->>'void_reason' = 'raised twice by mistake',
    '58 a voided invoice prints as voided, with the reason');

  -- A credit note is titled as one and has no bank block: nobody pays it.
  d := public.fn_platform_invoice(
    (select id from public.platform_invoices where kind = 'credit_note' limit 1));
  perform pg_temp.ok(d->>'title' = 'CREDIT NOTE' and d->'bank' = 'null'::jsonb,
    '59 a credit note is not a demand for money');
  perform pg_temp.ok(d->>'withholding_note' is null,
    '59b and carries no withholding instruction');
end $doc$;

-- =============================================================================
-- 60-69  RENEWALS: the worklist and the reminder
-- =============================================================================
do $renew$
declare
  a uuid := (select v from _bill where k='a');
  b uuid := (select v from _bill where k='b');
  g uuid := (select v from _bill where k='g');
  rg record; m jsonb; i_a uuid := (select v::uuid from _bdoc where k='i_a');
begin
  perform public._bact('ops');

  select * into rg from public.fn_platform_due_soon(45) where school_id = g;
  perform pg_temp.ok(rg.school_id is not null,
    '60 an expired school is on the worklist');
  perform pg_temp.ok(rg.bucket = 'grace',
    '61 and is bucketed by how bad it is, not alphabetically');
  -- Gamma has a licence and no invoice at all: a year given away, which nothing
  -- in this product could see before.
  perform pg_temp.ok(rg.never_invoiced and rg.invoiced_to is null,
    '62 a school with licence time and no invoice is flagged');

  -- Beta was invoiced for exactly the year it holds. `unbilled_days` is the
  -- comparison that replaced a flag which could never be true — see 0078's
  -- header. Beta rather than Alpha because Alpha has been renewed three times
  -- above and its licence now runs past the 365-day cap on this window.
  perform pg_temp.ok(
    (select not never_invoiced and unbilled_days = 0
       from public.fn_platform_due_soon(365) where school_id = b),
    '62b an invoiced school shows no unbilled days');

  -- Licence time nobody billed for. Gamma's licence ran to 5 days ago; the
  -- invoice below covers it only to 35 days ago, so 30 days of it were given
  -- away. Nothing in this product could see that before, and it is how a year
  -- quietly goes unbilled.
  insert into public.platform_invoices
    (school_id, plan_code, cycle, months, period_start, period_end,
     amount, list_amount)
  values (g, 'starter', 'yearly', 11, current_date - 370, current_date - 35,
          9500, 9500);
  perform pg_temp.ok(
    (select unbilled_days = 30 from public.fn_platform_due_soon(45)
      where school_id = g),
    '62c a licence that outruns its invoices shows up as unbilled days');

  -- Priced on the plan the count fits. Gamma has 420 students on `starter`.
  perform pg_temp.ok(
    (select pg_temp.eq(renewal_amount, 35000) from public.fn_platform_due_soon(45)
      where school_id = g),
    '63 the renewal is quoted at the plan the student count fits, not the plan they are on');

  -- THE DOUBLE-RENEWAL GUARD. Two operators, or one double click: the second
  -- transaction has not seen the first, computes the identical period, and would
  -- bill the school twice for the same year.
  perform pg_temp.ok(pg_temp.refused(format(
    'insert into public.platform_invoices (school_id, plan_code, cycle, months, '
    'period_start, period_end, amount, list_amount) select school_id, plan_code, '
    'cycle, months, period_start, period_end, amount, list_amount from '
    'public.platform_invoices where id = %L', i_a)),
    '63b an invoice that duplicates a live one exactly is refused');
  -- And voiding it must clear the way for the replacement, or void would be
  -- useless for the case it exists for.
  perform pg_temp.ok(not pg_temp.refused(format(
    'insert into public.platform_invoices (school_id, plan_code, cycle, months, '
    'period_start, period_end, amount, list_amount) select school_id, plan_code, '
    'cycle, months, period_start, period_end, amount, list_amount from '
    'public.platform_invoices where id = %L',
    (select v from _bdoc where k='i_a2'))),
    '63c but a voided invoice does not block its replacement');

  m := public.fn_platform_renewal_message(g);
  perform pg_temp.ok(m->>'stage' in ('grace', 'locked'),
    '64 the reminder stage is chosen from the licence, not asked for');
  perform pg_temp.ok(m->>'text' like '%still works%' or m->>'text' like '%data is safe%',
    '65 an expired school is told what still works, not threatened');
  perform pg_temp.ok(m->>'phone_intl' = '923214445556',
    '66 the phone is normalised for WhatsApp');

  -- Gamma rather than Alpha: fn_activate_subscription recounts students from
  -- enrollments, and Alpha has none in this fixture, so every renewal above
  -- reset its stored count to zero. Gamma was never activated, so its 420 is
  -- intact and the quote has something to be right about.
  m := public.fn_platform_renewal_message(g, 'ahead');
  perform pg_temp.ok(m->>'text' like '%No rush%',
    '67 a month out, the tone is a reminder and not a demand');
  perform pg_temp.ok(m->>'text' like '%35,000%',
    '67b and it names the amount for the plan they actually need');
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_renewal_message(%L, ''threaten'')', a)),
    '68 an unknown stage is refused rather than silently defaulted');

  perform public.fn_platform_mark_reminded(g, 'grace', 'called too');
  perform pg_temp.ok(
    (select last_reminded_stage from public.fn_platform_due_soon(45)
      where school_id = g) = 'grace',
    '69 the worklist shows that the school was already reminded');
end $renew$;

-- =============================================================================
-- 70-79  THE SCHOOL'S OWN VIEW, and every way it might move its own balance
-- =============================================================================
do $school$
declare
  a uuid := (select v from _bill where k='a');
  b uuid := (select v from _bill where k='b');
  i_b uuid := (select v::uuid from _bdoc where k='i_b');
  r jsonb; payload text; claim uuid; msg text;
begin
  -- --- the owner sees their own bill ---------------------------------------
  perform public._bact('a_owner');
  set local role authenticated;
  r := public.fn_my_billing();
  perform pg_temp.ok((r->>'ok')::boolean, '70 the owner can open their subscription');
  perform pg_temp.ok(r->'pay_to'->>'account' = '01234567890123',
    '71 and is told where to pay');
  perform pg_temp.ok(r->>'how_to_pay' like '%I have paid%',
    '71b with an instruction, not just an account number');
  perform pg_temp.ok(jsonb_array_length(r->'documents') >= 3,
    '72 their own documents are listed');

  -- The boundary. Every id and number in the payload must belong to Alpha.
  payload := r::text;
  perform pg_temp.ok(position(b::text in payload) = 0,
    '73 nothing in the payload mentions the other school');
  perform pg_temp.ok(position('BSH-0002' in payload) = 0,
    '73b nor the other school''s invoice number');
  -- The vendor's own private settings must not ride along.
  perform pg_temp.ok(position('1234567-8' in payload) = 0,
    '73c nor the vendor NTN, which belongs on the invoice and not on this screen');
  perform pg_temp.ok(position('default_withholding' in payload) = 0
                 and position('invoice_prefix' in payload) = 0,
    '73d nor any vendor setting beyond the bank block');

  -- An accountant is not the owner. This is a bill, not an operating screen.
  reset role;
  perform public._bact('a_acct');
  set local role authenticated;
  perform pg_temp.ok(pg_temp.refused('select public.fn_my_billing()'),
    '74 an accountant cannot see the subscription bill');
  reset role;

  -- --- reporting a payment -------------------------------------------------
  perform public._bact('b_owner');
  set local role authenticated;
  r := public.fn_my_report_payment(9500, current_date - 1, 'bank', 'MEZ-55110',
                                   'Meezan Bank', 'for the renewal');
  claim := (r->>'claim_id')::uuid;
  perform pg_temp.ok(r->>'status' = 'pending',
    '75 a reported payment is a request, not money');
  perform pg_temp.ok(pg_temp.eq(
    (public.fn_my_billing()->'balance'->>'outstanding')::numeric, 0),
    '75b and it moves no balance');

  -- Told us twice. Refused loudly, because a silent no-op reads as a broken form
  -- and produces the phone call this screen exists to prevent.
  msg := pg_temp.why(
    'select public.fn_my_report_payment(9500, null, ''bank'', ''MEZ-55110'')');
  perform pg_temp.ok(msg like '%already sent us%',
    '76 the same reference twice is refused, and says why');

  perform pg_temp.ok(pg_temp.refused(
    'select public.fn_my_report_payment(-1, null, ''bank'', ''X'')'),
    '76b a negative amount is refused');
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_my_report_payment(100, %L, ''bank'', ''Y'')',
    current_date + 5)),
    '76c and a date in the future');

  -- THE ATTACK SURFACE. A claim is a request; money is a payment. Every route
  -- from one to the other must be closed to a school.
  perform pg_temp.ok(pg_temp.refused(format(
    'insert into public.platform_payments (school_id, amount) values (%L, 9500)', b)),
    '77 a school cannot insert a payment');
  perform pg_temp.ok(pg_temp.refused(format(
    'insert into public.platform_invoices (school_id, plan_code, cycle, months, '
    'period_start, period_end, amount, list_amount) values '
    '(%L, ''starter'', ''yearly'', 12, current_date, current_date, 0, 0)', b)),
    '77b nor an invoice');
  -- UPDATE with no policy affects zero rows SILENTLY, so this is checked by
  -- reading back rather than by whether it raised.
  update public.platform_payment_claims set status = 'confirmed' where id = claim;
  reset role;
  perform pg_temp.ok(
    (select status from public.platform_payment_claims where id = claim) = 'pending',
    '78 a school''s UPDATE to confirm its own claim changes nothing');
  set local role authenticated;
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_confirm_claim(%L)', claim)),
    '79 and it cannot call the operator''s confirm function');
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_credit_note(%L, 9500, ''i credit myself'')', i_b)),
    '79b nor credit its own invoice');
  perform pg_temp.ok(pg_temp.refused('select public.fn_platform_payment_claims()'),
    '79c nor read the whole claim queue');
  reset role;

  insert into _bdoc values ('claim_b', claim::text);
end $school$;

-- =============================================================================
-- 80-89  THE OPERATOR WORKS THE QUEUE, and the cross-tenant sweep
-- =============================================================================
do $queue$
declare
  a uuid := (select v from _bill where k='a');
  b uuid := (select v from _bill where k='b');
  claim uuid := (select v::uuid from _bdoc where k='claim_b');
  i_b uuid := (select v::uuid from _bdoc where k='i_b');
  r jsonb; n integer; claim2 uuid;
begin
  perform public._bact('ops');
  select count(*) into n from public.fn_platform_payment_claims('pending');
  perform pg_temp.ok(n = 1, '80 the operator sees the pending report');
  perform pg_temp.ok(
    (select claimed_by_name from public.fn_platform_payment_claims('pending')
      where id = claim) = 'Beta Owner',
    '80b and who at the school reported it');

  perform pg_temp.ok(pg_temp.refused(
    format('select public.fn_platform_reject_claim(%L, '' '')', claim)),
    '81 rejecting needs a reason — the school is shown it');

  -- Confirm it as a smaller amount than reported: the bank statement is the
  -- authority, and a school that transfers net of tax reports the gross.
  r := public.fn_platform_confirm_claim(claim, 8740, i_b, 760, 'CPR-2026-99001',
                                        'net of 8% withholding');
  perform pg_temp.ok(r->>'status' = 'confirmed' and (r->>'payment_id') is not null,
    '82 confirming a report creates a real payment');
  perform pg_temp.ok(pg_temp.eq(
    (select settled from public.platform_payments where id = (r->>'payment_id')::uuid),
    9500), '82b settled at cash plus the withheld tax');
  perform pg_temp.ok(
    (select reference from public.platform_payments where id = (r->>'payment_id')::uuid)
      = 'MEZ-55110',
    '83 the school''s reference is what goes on the receipt');
  perform pg_temp.ok(
    (select payment_id from public.platform_payment_claims where id = claim) is not null,
    '84 the report and the payment point at each other');
  perform pg_temp.ok(pg_temp.refused(
    format('select public.fn_platform_confirm_claim(%L)', claim)),
    '85 a report cannot be confirmed twice');

  -- A rejection, and the school must be able to read the reason.
  perform public._bact('b_owner');
  set local role authenticated;
  claim2 := (public.fn_my_report_payment(1000, current_date, 'cash', 'WRONG-1')
             ->>'claim_id')::uuid;
  reset role;
  perform public._bact('ops');
  perform public.fn_platform_reject_claim(claim2,
    'No transfer of Rs 1,000 on our statement — please check the reference');
  perform public._bact('b_owner');
  set local role authenticated;
  perform pg_temp.ok(
    (select r2->>'decision_note' from jsonb_array_elements(
       public.fn_my_billing()->'reports') r2
      where (r2->>'id')::uuid = claim2) like '%check the reference%',
    '86 the school is shown why a report was rejected');
  reset role;

  -- --- cross-tenant sweep ---------------------------------------------------
  perform public._bact('a_owner');
  set local role authenticated;
  perform pg_temp.ok((select count(*) from public.platform_payment_claims
                       where school_id = b) = 0,
    '87 a school cannot read another school''s payment reports');
  perform pg_temp.ok((select count(*) from public.platform_invoices) = 0,
    '87b nor any invoice through RLS — the school-facing view is a function');
  perform pg_temp.ok((select count(*) from public.platform_payments) = 0,
    '87c nor any payment');
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_my_platform_invoice(%L)', i_b)),
    '88 nor print another school''s invoice');
  perform pg_temp.ok(
    (public.fn_my_platform_invoice((select v::uuid from _bdoc where k='i_a'))
      ->>'doc_no') = 'BSH-0001',
    '88b and can print its own');
  reset role;

  -- The school-detail money block must agree with the ledger. Two screens
  -- disagreeing about what a customer owes is the defect 0064's header names.
  perform public._bact('ops');
  perform pg_temp.ok(pg_temp.eq(
    (public.fn_platform_school_detail(b)->'money'->>'outstanding')::numeric,
    public.fn_platform_outstanding(b)),
    '89 the school detail screen agrees with the books');
  perform pg_temp.ok(
    (public.fn_platform_school_detail(a)->'money'->>'invoice_count')::int
      = (select count(*) from public.platform_invoices
          where school_id = a and kind = 'invoice' and voided_at is null),
    '89b and does not count voided paperwork or credit notes as invoices');
end $queue$;

rollback;
