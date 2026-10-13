-- =============================================================================
-- 0156. Discount codes that keep their word.
--
-- A discount code lowers what a school pays for its subscription. Prices are
-- fixed for Starter and Growth; codes are how we give a school less to pay.
-- The idea was sound (terms frozen when a school redeems, one live discount per
-- school, applied in one place). The rules around it were not:
--
--   * Restrictions were checked once, at redemption. A "yearly only" or
--     "Growth only" code kept coming off after the school switched term or
--     plan. Now the plan and term rules are frozen with the redemption and
--     checked again on every invoice; an invoice they do not fit skips the
--     code and says why.
--   * A code had no unit of time. "One month" took its percentage off a whole
--     year; an "until" code ending tomorrow discounted twelve months; "once"
--     was worth twelve times more on a yearly invoice; a one-month code
--     reached two monthly invoices. Now every code is counted in BILLED
--     MONTHS: on an invoice for N months, a code covers the months it still
--     has (or the months that start before its end date), and takes its share
--     of exactly those months. "Once" is one billed month.
--   * A flat code was rupees off an invoice whatever its length. It is now
--     rupees off each billed month it covers, and never more than that month
--     costs.
--   * Seats raced: three schools took a one-seat code at the same moment. The
--     code row is now locked while a seat is taken. A seat counts while the
--     redemption is live or once it has saved money, so a trial school that
--     takes a seat and drops it gives it back.
--   * A second code silently replaced the first, a trial-days code wiped out a
--     money discount, a principal could wipe a discount we had negotiated, and
--     we could not restore it. Trial days no longer occupy the money slot;
--     replacing needs a yes; a discount we gave can only be taken off by us,
--     and we can restore one.
--   * "Start again" in a trial deleted redemptions, so a trial code could be
--     redeemed for ever and a seat freed each time. Purging a school erased
--     its history. Both now keep them.
--   * Voiding an invoice kept the discount it used. Each use is now recorded
--     against its invoice and given back when the invoice is voided.
--   * The operator's private note was shown to schools. There is now a label
--     for schools and a description for us.
--   * Codes could be enumerated (three letters, no throttle, refusals that
--     told real codes from unknown ones). New codes are six characters or
--     more; unknown, switched-off, used-up and another school's code get one
--     sentence; ten refused tries in an hour pause the school for the hour;
--     every try is logged.
--   * The "New code" form overwrote an existing code; edits were logged
--     without their before-values; a school's own removal was not logged at
--     all. Create and edit are separate, edits need the version they were
--     made from, money terms lock once a code is redeemed, and every event
--     goes into an append-only log with before and after.
--   * Invoices are in whole rupees, discounts included.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. THE CODES
-- -----------------------------------------------------------------------------

alter table public.discount_codes
  add column if not exists label text,
  add column if not exists is_private boolean not null default false,
  add column if not exists school_id uuid references public.schools(id) on delete set null,
  add column if not exists updated_by uuid;

comment on column public.discount_codes.label is
  'What the school sees: a short, plain name for the offer. The description is '
  'ours and is never shown to a school.';
comment on column public.discount_codes.is_private is
  'A code made for one school. Only that school can use it, and only when we '
  'give it to them. If the school is purged the code is usable by nobody.';

-- Codes made before there was a label get one built from their terms, not a
-- copy of our description.
update public.discount_codes
   set label = left(case kind
                      when 'trial_days' then format('%s extra free days', value::integer)
                      when 'percent' then format('%s%% off', rtrim(rtrim(to_char(value, 'FM999990.99'), '0'), '.'))
                      else format('Rs %s off each month', to_char(value, 'FM999,999,999')) end, 80)
 where label is null;
alter table public.discount_codes alter column label set not null;
alter table public.discount_codes drop constraint if exists discount_codes_label_chk;
alter table public.discount_codes add constraint discount_codes_label_chk
  check (btrim(label) <> '' and char_length(label) <= 80);

-- "Once" is one billed month for a money code. Trial days stay "once": they
-- move a trial date once and never touch an invoice.
update public.discount_codes
   set duration = 'months', duration_months = 1
 where duration = 'once' and kind <> 'trial_days';
update public.discount_codes set value = least(value, 30) where kind = 'trial_days';

alter table public.discount_codes drop constraint if exists discount_codes_money_once_chk;
alter table public.discount_codes add constraint discount_codes_money_once_chk
  check (kind = 'trial_days' or duration <> 'once');
alter table public.discount_codes drop constraint if exists discount_codes_trial_cap_chk;
alter table public.discount_codes add constraint discount_codes_trial_cap_chk
  check (kind <> 'trial_days' or value <= 30);
alter table public.discount_codes drop constraint if exists discount_codes_whole_chk;
alter table public.discount_codes add constraint discount_codes_whole_chk
  check (kind = 'percent' or value = round(value));
alter table public.discount_codes drop constraint if exists discount_codes_plans_chk;
alter table public.discount_codes add constraint discount_codes_plans_chk
  check (plan_codes is null
         or (cardinality(plan_codes) > 0 and array_position(plan_codes, null) is null));
alter table public.discount_codes drop constraint if exists discount_codes_private_chk;
alter table public.discount_codes add constraint discount_codes_private_chk
  check (is_private or school_id is null);


-- -----------------------------------------------------------------------------
-- 2. A SCHOOL'S REDEMPTIONS: FROZEN TERMS, KEPT FOR EVER
-- -----------------------------------------------------------------------------

alter table public.subscription_discounts
  add column if not exists school_name text,
  add column if not exists label text,
  add column if not exists plan_codes text[],
  add column if not exists min_term_months integer,
  add column if not exists months_total integer,
  add column if not exists months_left integer,
  add column if not exists granted_by_kind text not null default 'school',
  add column if not exists grant_reason text;

comment on column public.subscription_discounts.months_left is
  'For a code that lasts N months: the billed months it still covers. Each '
  'invoice uses some; a voided invoice gives them back.';
comment on column public.subscription_discounts.granted_by_kind is
  'school: the school typed the code. platform: we gave it. Only we can take '
  'off a discount we gave.';

alter table public.subscription_discounts drop constraint if exists subscription_discounts_granted_chk;
alter table public.subscription_discounts add constraint subscription_discounts_granted_chk
  check (granted_by_kind in ('school', 'platform')
         and (granted_by_kind = 'school' or btrim(coalesce(grant_reason, '')) <> ''));
alter table public.subscription_discounts drop constraint if exists subscription_discounts_months_chk;
alter table public.subscription_discounts add constraint subscription_discounts_months_chk
  check (months_left is null or (months_left >= 0 and months_left <= coalesce(months_total, months_left)));

update public.subscription_discounts d
   set school_name = coalesce(d.school_name, (select name from public.schools where id = d.school_id)),
       label = coalesce(d.label, (select c.label from public.discount_codes c where c.code = d.code)),
       plan_codes = coalesce(d.plan_codes, (select c.plan_codes from public.discount_codes c where c.code = d.code)),
       min_term_months = coalesce(d.min_term_months, (select c.min_term_months from public.discount_codes c where c.code = d.code));
update public.subscription_discounts d
   set duration = 'months', months_total = 1, months_left = coalesce(d.uses_left, 1)
 where d.duration = 'once' and d.kind <> 'trial_days';
-- months_left of a "months" redemption made before 0156 is worked out in 4b,
-- from the window it had then. It cannot be the code's months less
-- times_applied: that counted invoices, so a yearly invoice counted once.
update public.subscription_discounts d
   set months_total = coalesce(d.months_total,
                               (select c.duration_months from public.discount_codes c where c.code = d.code))
 where d.duration = 'months';

-- A purge keeps the history: the school goes, its redemptions stay unlinked.
alter table public.subscription_discounts alter column school_id drop not null;
alter table public.subscription_discounts drop constraint if exists subscription_discounts_school_id_fkey;
alter table public.subscription_discounts add constraint subscription_discounts_school_id_fkey
  foreign key (school_id) references public.schools(id) on delete set null;

-- One live MONEY discount per school; trial days are their own thing, once per
-- school, ever.
drop index if exists public.uq_subscription_discount_live;
create unique index uq_subscription_discount_live on public.subscription_discounts (school_id)
  where removed_at is null and kind <> 'trial_days';
create unique index if not exists uq_subscription_discount_trial on public.subscription_discounts (school_id)
  where kind = 'trial_days';


-- -----------------------------------------------------------------------------
-- 3. EACH USE, AGAINST ITS INVOICE; AND THE LOG
-- -----------------------------------------------------------------------------

create table if not exists public.discount_applications (
  id              uuid primary key default gen_random_uuid(),
  invoice_id      uuid not null unique references public.platform_invoices(id) on delete cascade,
  redemption_id   uuid references public.subscription_discounts(id) on delete set null,
  school_id       uuid references public.schools(id) on delete set null,
  code            text not null,
  months_covered  integer not null check (months_covered >= 0),
  amount_off      numeric(12,2) not null check (amount_off >= 0 and amount_off = round(amount_off)),
  overridden      boolean not null default false,
  applied_at      timestamptz not null default now(),
  reversed_at     timestamptz,
  reversed_reason text,
  check ((reversed_at is null) = (reversed_reason is null))
);
create index if not exists idx_discount_applications_redemption on public.discount_applications (redemption_id);
alter table public.discount_applications enable row level security;
alter table public.discount_applications force row level security;
revoke all on public.discount_applications from public, anon, authenticated;

create table if not exists public.discount_events (
  id            bigint generated always as identity primary key,
  at            timestamptz not null default now(),
  event         text not null check (event in ('created', 'edited', 'retired', 'deleted',
                  'applied', 'given', 'restored', 'replaced', 'removed', 'refused',
                  'invoiced', 'reversed', 'trial_extended')),
  code          text,
  school_id     uuid,
  school_name   text,
  redemption_id uuid,
  invoice_id    uuid,
  actor         uuid,
  actor_kind    text not null check (actor_kind in ('platform', 'school', 'system')),
  before        jsonb,
  after         jsonb,
  reason        text
);
create index if not exists idx_discount_events_code on public.discount_events (code, at desc);
create index if not exists idx_discount_events_school on public.discount_events (school_id, at desc);
alter table public.discount_events enable row level security;
alter table public.discount_events force row level security;
revoke all on public.discount_events from public, anon, authenticated;

-- Append-only, whoever asks.
create or replace function public.fn__discount_events_append_only()
returns trigger
language plpgsql
as $$
begin
  raise exception 'The discount log is append-only' using errcode = '42501';
end;
$$;
revoke all on function public.fn__discount_events_append_only() from public, anon, authenticated;
drop trigger if exists trg_discount_events_append_only on public.discount_events;
create trigger trg_discount_events_append_only
  before update or delete on public.discount_events
  for each row execute function public.fn__discount_events_append_only();
drop trigger if exists trg_discount_events_no_truncate on public.discount_events;
create trigger trg_discount_events_no_truncate
  before truncate on public.discount_events
  for each statement execute function public.fn__discount_events_append_only();

create or replace function public.fn__discount_event(
  p_event text, p_code text, p_school_id uuid, p_redemption_id uuid, p_invoice_id uuid,
  p_actor_kind text, p_before jsonb, p_after jsonb, p_reason text)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.discount_events
    (event, code, school_id, school_name, redemption_id, invoice_id, actor, actor_kind,
     before, after, reason)
  values (p_event, p_code, p_school_id,
          (select name from public.schools where id = p_school_id),
          p_redemption_id, p_invoice_id, auth.uid(), p_actor_kind, p_before, p_after,
          left(p_reason, 500));
$$;
revoke all on function public.fn__discount_event(text, text, uuid, uuid, uuid, text, jsonb, jsonb, text) from public, anon, authenticated;

-- Reset and purge keep all of it: a trial "Start again" no longer frees a code
-- to be redeemed again, and a purged school's history stays.
create or replace function public.fn__school_data_tables()
returns table(table_name text)
language sql
stable
as $$
  select c.relname::text
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid
   where n.nspname = 'public' and c.relkind = 'r'
     and a.attname = 'school_id' and not a.attisdropped
     and c.relname not like 'platform\_%'
     and c.relname not like 'operator\_%'
     and c.relname not like 'discount\_%'
     and c.relname not in ('subscriptions', 'student_count_snapshots',
                           'subscription_discounts')
   order by c.relname;
$$;

-- The orphan report, the health check and the orphan cleaner (0092) read
-- this list. discount_events keeps a purged school's id ON PURPOSE: it has no
-- foreign key, carries the school's name on every row, and is append-only. On
-- the list, every purged school that ever touched a code showed up as left
-- behind for ever, and clearing it failed on "The discount log is
-- append-only". So it is left off, as kept history. The other discount tables
-- stay on: their school_id is a foreign key that a purge sets to NULL, so a row
-- that still names a missing school really was left behind.
create or replace function public.fn__school_id_tables()
returns table (table_name text, treatment text) language sql stable as $$
  select c.relname::text,
         case
           -- Deleted: the school's own records.
           when exists (select 1 from public.fn__school_data_tables() d
                         where d.table_name = c.relname) then 'delete'
           -- Deleted: the licence and its history. Excluded from
           -- fn__school_data_tables because they are the licence rather than the
           -- school's records, but they go the same way.
           when c.relname in ('subscriptions', 'student_count_snapshots') then 'delete'
           -- Kept, unlinked: our sales ledger and what we did to them. A
           -- business keeps its invoices after a customer leaves, and tax
           -- records have to be retained for years.
           when a.attnotnull then 'delete'      -- cannot be unlinked, 0080 deletes these
           else 'unlink'
         end
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid
                       and a.attname = 'school_id' and not a.attisdropped
   where n.nspname = 'public' and c.relkind = 'r'
     and c.relname <> 'discount_events'
   order by 1;
$$;
revoke all on function public.fn__school_id_tables() from public, anon, authenticated;


-- -----------------------------------------------------------------------------
-- 4. THE ARITHMETIC: BILLED MONTHS
-- -----------------------------------------------------------------------------

-- A code typed with spaces or in lower case is the same code.
create or replace function public.fn__norm_code(p_code text)
returns text
language sql
immutable
as $$ select upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g')) $$;

-- The months of an N-month invoice starting p_start that start on or before
-- p_until: what an "until" code covers on that invoice.
create or replace function public.fn__months_until(p_start date, p_months integer, p_until date)
returns integer
language sql
immutable
set "TimeZone" = 'Asia/Karachi'
as $$
  select count(*)::integer
    from generate_series(0, greatest(coalesce(p_months, 0), 1) - 1) k
   where (p_start + make_interval(months => k))::date <= p_until;
$$;

-- WHAT A CODE TAKES OFF ONE INVOICE. Pure arithmetic over frozen terms, so a
-- preview and the invoice can never disagree.
--   covered  the billed months of this invoice the code reaches
--   amount   percent: that share of the term price, at the percentage;
--            flat: rupees per covered month, but never more than the covered
--            months cost. Capped only at the whole term price, Rs 4,000 off
--            one month took Rs 4,000 off a Starter year whose month costs
--            Rs 1,667, so a code was worth more the longer the term.
--            Whole rupees.
--   skipped  why it does not apply, in a sentence, when it does not
create or replace function public.fn__discount_calc(
  p_code text, p_kind text, p_value numeric, p_duration text, p_months_left integer,
  p_until date, p_plan_codes text[], p_min_term integer,
  p_plan_code text, p_months integer, p_start date, p_term_price numeric)
returns jsonb
language plpgsql
stable
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare v_cov integer; v_off numeric; v_start date := coalesce(p_start, current_date);
begin
  if p_kind not in ('percent', 'flat') or p_term_price is null or p_term_price <= 0
     or p_months is null or p_months < 1 then
    return jsonb_build_object('covered', 0, 'amount', 0);
  end if;
  if p_plan_codes is not null and not coalesce(p_plan_code = any (p_plan_codes), false) then
    return jsonb_build_object('covered', 0, 'amount', 0, 'skipped', format(
      'Code %s is for %s, so it does not apply to this invoice.', p_code,
      (select string_agg(name, ' or ' order by sort_order) from public.plans
        where code = any (p_plan_codes))));
  end if;
  if p_min_term is not null and p_months < p_min_term then
    return jsonb_build_object('covered', 0, 'amount', 0, 'skipped', format(
      'Code %s needs paying for %s months or more at a time, so it does not apply to a %s-month invoice.',
      p_code, p_min_term, p_months));
  end if;

  v_cov := case p_duration
    when 'forever' then p_months
    when 'months'  then least(p_months, greatest(coalesce(p_months_left, 0), 0))
    when 'until'   then public.fn__months_until(v_start, p_months, p_until)
    else 0 end;
  if v_cov <= 0 then
    return jsonb_build_object('covered', 0, 'amount', 0, 'skipped', format(
      'Code %s has run its course, so it does not apply to this invoice.', p_code));
  end if;

  v_off := case p_kind
    when 'percent' then round(p_term_price * v_cov / p_months * p_value / 100)
    else least(p_value * v_cov, round(p_term_price * v_cov / p_months)) end;
  v_off := least(greatest(v_off, 0), p_term_price);

  return jsonb_build_object('covered', v_cov, 'amount', v_off);
end;
$$;

-- The sentence a school reads, from frozen terms only. 20% reads "20% off"
-- (the old helper trimmed zeros off 20 and printed "2%").
create or replace function public.fn__discount_sentence(
  p_kind text, p_value numeric, p_duration text, p_months integer, p_until date)
returns text
language sql
immutable
set search_path = public
as $$
  select case p_kind
           when 'trial_days' then format('%s extra free day(s) on your trial', p_value::integer)
           when 'percent' then format('%s%% off',
             rtrim(rtrim(to_char(p_value::numeric(12,2), 'FM999990.99'), '0'), '.'))
           else format('Rs %s off each month', to_char(p_value, 'FM999,999,999'))
         end
      || case
           when p_kind = 'trial_days' then ''
           when p_duration = 'forever' then ', for as long as you subscribe'
           when p_duration = 'months' and p_months = 1 then ', for one month of your subscription'
           when p_duration = 'months' then format(', for %s months of your subscription', p_months)
           when p_duration = 'until' then format(', on every month that starts by %s',
                                                  to_char(p_until, 'DD Mon YYYY'))
           else ''
         end;
$$;

-- The first day of the next invoice a code could come off: the open invoice's
-- own first day when nothing is paid on it (it is reissued with the change),
-- the day after it when something is, otherwise the next period start. The
-- day the school's preview is worked out for.
create or replace function public.fn__discount_next_start(p_school_id uuid)
returns date
language plpgsql
stable
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare v_open uuid := public.fn__open_term_invoice(p_school_id); v_start date;
begin
  if v_open is null then
    return public.fn__next_period_start(p_school_id);
  end if;
  select case when public.fn__invoice_settled(v_open) = 0 then period_start else period_end + 1 end
    into v_start from public.platform_invoices where id = v_open;
  return v_start;
end;
$$;

-- Does a money redemption still have anything to give? Months left; an end
-- date on or after the next month the school would be invoiced for; or a
-- saving sitting on an invoice that is not paid yet, which can still be
-- reissued and would hand its months back. Judged on months left and today's
-- date alone, a discount whose months were all on the open invoice, or whose
-- end date had passed while the school's next month still started before it,
-- counted as finished: it was closed without a word when the school typed
-- another code, we could not take it off, and the school was not shown it.
-- A use priced by hand is left out. That price used the code up, and the
-- school cannot get those months back (fn__discount_reverse), so they hold
-- nothing for it.
create or replace function public.fn__discount_has_value(d public.subscription_discounts)
returns boolean
language sql
stable
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
  select d.id is not null and d.kind in ('percent', 'flat') and (
       d.duration = 'forever'
    or (d.duration = 'months' and coalesce(d.months_left, 0) > 0)
    or (d.duration = 'until' and d.ends_on >= public.fn__discount_next_start(d.school_id))
    or exists (select 1 from public.discount_applications a
                 join public.platform_invoices i on i.id = a.invoice_id
                where a.redemption_id = d.id and a.reversed_at is null and not a.overridden
                  and i.voided_at is null and public.fn__invoice_owed(i.id) > 0));
$$;

-- The months of a "months" code the school has not paid for yet: the months
-- left plus those on an invoice still owed. The sentence a school reads uses
-- this, so a code whose months all sit on the unpaid invoice does not read
-- "for 0 months".
create or replace function public.fn__discount_months_to_give(d public.subscription_discounts)
returns integer
language sql
stable
set search_path = public
as $$
  select coalesce(d.months_left, 0)
       + coalesce((select sum(a.months_covered)::integer from public.discount_applications a
                     join public.platform_invoices i on i.id = a.invoice_id
                    where a.redemption_id = d.id and a.reversed_at is null and not a.overridden
                      and i.voided_at is null and public.fn__invoice_owed(i.id) > 0), 0);
$$;

-- The school's live MONEY discount: not removed and not a trial code.
--   p_as_at given: the one that reaches an invoice starting that day, with
--     months still to give or an end date on or after it. The quote asks this.
--   p_as_at NULL: the one that still has anything to give at all. Asking a
--     replace, protecting what we gave, taking a code off, and what the school
--     and we are shown all ask this.
create or replace function public.fn__discount_live(p_school_id uuid, p_as_at date default null)
returns public.subscription_discounts
language sql
stable
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
  select d.* from public.subscription_discounts d
   where d.school_id = p_school_id
     and d.removed_at is null
     and d.kind in ('percent', 'flat')
     and case when p_as_at is null then public.fn__discount_has_value(d)
              else (d.duration <> 'months' or coalesce(d.months_left, 0) > 0)
                   and (d.duration <> 'until' or d.ends_on >= p_as_at) end
   order by d.redeemed_at desc
   limit 1;
$$;

-- 0155's hook: what the live code takes off this invoice. A quote with no
-- period start is judged as at today.
create or replace function public.fn__discount_for_quote(
  p_school_id uuid, p_plan_code text, p_months integer, p_period_start date,
  p_term_price numeric)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare d public.subscription_discounts; v jsonb;
begin
  select * into d from public.fn__discount_live(p_school_id, coalesce(p_period_start, current_date));
  if d.id is null then
    return null;
  end if;
  v := public.fn__discount_calc(d.code, d.kind, d.value, d.duration, d.months_left, d.ends_on,
                                d.plan_codes, d.min_term_months, p_plan_code, p_months,
                                p_period_start, p_term_price);
  if (v->>'amount')::numeric > 0 then
    return jsonb_build_object(
      'code', d.code, 'label', d.label, 'kind', d.kind, 'value', d.value,
      'duration', d.duration, 'months_covered', (v->>'covered')::integer,
      'amount', (v->>'amount')::numeric, 'redemption_id', d.id,
      'granted_by_kind', d.granted_by_kind);
  end if;
  return jsonb_build_object('skipped', v->>'skipped', 'code', d.code);
end;
$$;

-- 0155's hook: an invoice used the code. Months come off, the saving is
-- recorded against the invoice. A price typed by hand uses the code up for the
-- months this invoice would have covered, so it cannot be used again. Its
-- saving is what the code itself would have taken, and never more than the
-- typed price actually took off. Booking the whole difference from the term
-- price recorded a hardship price we agreed (Rs 500 for a Rs 2,000 month) as
-- a 10% code having saved Rs 1,500.
create or replace function public.fn__discount_record(p_invoice_id uuid, p_quote jsonb, p_overridden boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_red uuid := nullif(p_quote->'discount'->>'redemption_id', '')::uuid;
  v_cov integer := coalesce((p_quote->'discount'->>'months_covered')::integer, 0);
  v_inv record; v_off numeric;
begin
  if v_red is null then
    return;
  end if;
  select * into v_inv from public.platform_invoices where id = p_invoice_id;
  v_off := coalesce((p_quote->>'discount_amount')::numeric, 0);
  if p_overridden then
    v_off := least(v_off, greatest(coalesce((p_quote->>'term_price')::numeric, v_inv.amount) - v_inv.amount, 0));
  end if;

  insert into public.discount_applications
    (invoice_id, redemption_id, school_id, code, months_covered, amount_off, overridden)
  values (p_invoice_id, v_red, v_inv.school_id, p_quote->'discount'->>'code',
          v_cov, v_off, coalesce(p_overridden, false));

  update public.subscription_discounts
     set times_applied = times_applied + 1,
         total_saved   = total_saved + v_off,
         months_left   = case when duration = 'months'
                              then greatest(coalesce(months_left, 0) - v_cov, 0) end
   where id = v_red;

  perform public.fn__discount_event('invoiced', p_quote->'discount'->>'code', v_inv.school_id,
    v_red, p_invoice_id, 'system', null,
    jsonb_build_object('doc_no', v_inv.doc_no, 'months_covered', v_cov,
                       'amount_off', v_off, 'overridden', coalesce(p_overridden, false)),
    null);
end;
$$;

-- 0155's hook: the invoice was voided, so the months and the saving go back.
-- Except the months a price we typed by hand used up, when the void is not
-- ours. That price was our decision about the code, so only we give it back:
-- a school that switched term and back, typed another code, or let the
-- invoice lapse and came back had the code come off again and our price
-- undone. The use still stands (the seat stays taken); only the saving goes,
-- since the invoice it was on is void.
create or replace function public.fn__discount_reverse(p_invoice_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare a public.discount_applications; v_keep boolean;
begin
  select * into a from public.discount_applications
   where invoice_id = p_invoice_id and reversed_at is null for update;
  if not found then
    return;
  end if;
  v_keep := a.overridden and not public.is_platform_admin();
  update public.discount_applications
     set reversed_at = now(),
         reversed_reason = coalesce(nullif(btrim(p_reason), ''), 'voided')
                           || case when v_keep then ' (priced by hand: its months stay used)' else '' end
   where id = a.id;
  update public.subscription_discounts
     set times_applied = case when v_keep then times_applied else greatest(times_applied - 1, 0) end,
         total_saved   = greatest(total_saved - a.amount_off, 0),
         months_left   = case when duration <> 'months' then null
                              when v_keep then months_left
                              else least(coalesce(months_left, 0) + a.months_covered,
                                         coalesce(months_total, coalesce(months_left, 0) + a.months_covered))
                         end
   where id = a.redemption_id;
  perform public.fn__discount_event('reversed', a.code, a.school_id, a.redemption_id,
    p_invoice_id, 'system', jsonb_build_object('months_covered', a.months_covered,
                                               'amount_off', a.amount_off),
    jsonb_build_object('months_given_back', case when v_keep then 0 else a.months_covered end,
                       'priced_by_hand', a.overridden),
    p_reason);
end;
$$;

revoke all on function public.fn__norm_code(text) from public, anon, authenticated;
revoke all on function public.fn__months_until(date, integer, date) from public, anon, authenticated;
revoke all on function public.fn__discount_calc(text, text, numeric, text, integer, date, text[], integer, text, integer, date, numeric) from public, anon, authenticated;
revoke all on function public.fn__discount_sentence(text, numeric, text, integer, date) from public, anon, authenticated;
revoke all on function public.fn__discount_next_start(uuid) from public, anon, authenticated;
revoke all on function public.fn__discount_has_value(public.subscription_discounts) from public, anon, authenticated;
revoke all on function public.fn__discount_months_to_give(public.subscription_discounts) from public, anon, authenticated;
revoke all on function public.fn__discount_live(uuid, date) from public, anon, authenticated;
revoke all on function public.fn__discount_for_quote(uuid, text, integer, date, numeric) from public, anon, authenticated;
revoke all on function public.fn__discount_record(uuid, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.fn__discount_reverse(uuid, text) from public, anon, authenticated;


-- -----------------------------------------------------------------------------
-- 4b. "MONTHS" REDEMPTIONS MADE BEFORE BILLED MONTHS
-- -----------------------------------------------------------------------------

-- Under 0131 a "months" code was a calendar window: it ran to ends_on (the day
-- it was redeemed plus its months) and came off every invoice starting by then.
-- So its billed months left are the months not yet invoiced that start inside
-- that window, and a window that has closed is spent. Taking times_applied
-- from the code's months instead brought back every code that ran out on fewer
-- invoices than it had months: a three-month code that ended in April came off
-- the next three invoices again, and one used on a yearly invoice (counted
-- once) had two months left. A spent redemption is closed here, with a line in
-- the log. Only rows 0156 has not counted yet (months_left NULL) are touched,
-- so running it again changes nothing.
create or replace function public.fn__discount_months_from_windows()
returns integer
language plpgsql
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare r record; v_left integer; v_start date; v_n integer := 0;
begin
  for r in
    select d.* from public.subscription_discounts d
     where d.duration = 'months' and d.months_left is null and d.kind in ('percent', 'flat')
     order by d.redeemed_at
     for update
  loop
    if r.ends_on is null then
      -- No window was written down: the code's months less its uses is all
      -- there is to go on.
      v_left := greatest(coalesce(r.months_total, 0) - r.times_applied, 0);
    elsif r.ends_on < current_date then
      v_left := 0;
    else
      -- From the first month not invoiced yet: an invoice raised under the old
      -- rules already has the code taken off.
      v_start := greatest(public.fn__next_period_start(r.school_id),
                          coalesce((select max(i.period_end) + 1 from public.platform_invoices i
                                     where i.school_id = r.school_id and i.kind = 'invoice'
                                       and i.purpose = 'term' and i.voided_at is null),
                                   current_date));
      v_left := public.fn__months_until(v_start, coalesce(r.months_total, 0), r.ends_on);
    end if;
    v_left := least(v_left, coalesce(r.months_total, v_left));

    update public.subscription_discounts set months_left = v_left where id = r.id;
    if v_left = 0 and r.removed_at is null then
      update public.subscription_discounts
         set removed_at = now(), removed_reason = 'Ran its course'
       where id = r.id;
      perform public.fn__discount_event('removed', r.code, r.school_id, r.id, null, 'system',
        jsonb_build_object('ends_on', r.ends_on, 'times_applied', r.times_applied,
                           'months_left', null),
        jsonb_build_object('months_left', 0),
        case when r.ends_on is null then 'Ran its course'
             else format('Ran its course: under the old rules it ran to %s',
                         to_char(r.ends_on, 'DD Mon YYYY')) end);
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke all on function public.fn__discount_months_from_windows() from public, anon, authenticated;

do $windows$
begin
  perform public.fn__discount_months_from_windows();
end $windows$;

-- The old arithmetic, kept for anything that still calls it: whole rupees.
create or replace function public.fn__discount_off(p_kind text, p_value numeric, p_list numeric)
returns numeric
language sql
immutable
as $$
  select case p_kind
    when 'percent' then least(round(coalesce(p_list, 0) * p_value / 100), coalesce(p_list, 0))
    when 'flat'    then least(p_value, coalesce(p_list, 0))
    else 0 end;
$$;


-- -----------------------------------------------------------------------------
-- 5. CAN THIS SCHOOL USE THIS CODE
-- -----------------------------------------------------------------------------

-- Seats taken: a redemption that is live, or one that has saved money. A
-- school that takes a seat and drops it before any invoice gives it back.
create or replace function public.fn__discount_seats_taken(p_code text)
returns integer
language sql
stable
set search_path = public
as $$
  select count(*)::integer from public.subscription_discounts d
   where d.code = p_code
     and (d.removed_at is null or d.times_applied > 0 or d.kind = 'trial_days');
$$;
revoke all on function public.fn__discount_seats_taken(text) from public, anon, authenticated;

-- One sentence for every code a school may not know about: unknown, switched
-- off, used up, or made for another school. Telling them apart is how codes
-- get guessed.
create or replace function public.fn__discount_refusal(
  p_code text, p_school_id uuid, p_plan_code text, p_term_months integer)
returns text
language plpgsql
stable
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  c public.discount_codes; v_when date; v_status public.subscription_status;
  v_generic text := 'That code is not one we can apply for your school. Check it, or ask us.';
begin
  select * into c from public.discount_codes where code = public.fn__norm_code(p_code);
  if not found or not c.active then
    return v_generic;
  end if;
  if c.is_private and (c.school_id is null or c.school_id is distinct from p_school_id) then
    return v_generic;
  end if;
  if c.is_private then
    -- A private code is given by us, never typed in.
    return 'That code was made for your school and we apply it for you. Ask us if it has not shown up.';
  end if;
  if c.max_redemptions is not null
     and public.fn__discount_seats_taken(c.code) >= c.max_redemptions then
    return v_generic;
  end if;
  if c.redeem_from is not null and current_date < c.redeem_from then
    return format('That code can be used from %s.', to_char(c.redeem_from, 'DD Mon YYYY'));
  end if;
  if c.redeem_until is not null and current_date > c.redeem_until then
    return format('That code could be used until %s.', to_char(c.redeem_until, 'DD Mon YYYY'));
  end if;
  if p_school_id is not null then
    select redeemed_at::date into v_when from public.subscription_discounts
     where school_id = p_school_id and code = c.code;
    if found then
      return format('Your school used that code on %s. Each code is once per school.',
                    to_char(v_when, 'DD Mon YYYY'));
    end if;
    v_status := public.fn_effective_status(p_school_id);
    if v_status = 'cancelled' or exists (select 1 from public.subscriptions
                                          where school_id = p_school_id and suspended_at is not null) then
      return 'Codes cannot be used while your subscription is cancelled or suspended. Please call us.';
    end if;
    if c.kind = 'trial_days' then
      if v_status <> 'trialing' then
        return 'That code adds days to a free trial, and yours has finished.';
      end if;
      if exists (select 1 from public.subscription_discounts
                  where school_id = p_school_id and kind = 'trial_days') then
        return 'Your trial has already been extended once with a code, which is the most it can be.';
      end if;
    end if;
  end if;
  if c.kind <> 'trial_days' and c.plan_codes is not null and p_plan_code is not null
     and not coalesce(p_plan_code = any (c.plan_codes), false) then
    return format('That code is for %s.',
      (select string_agg(p.name, ' or ' order by p.sort_order)
         from public.plans p where p.code = any (c.plan_codes)));
  end if;
  if c.kind <> 'trial_days' and c.min_term_months is not null
     and coalesce(p_term_months, 0) < c.min_term_months then
    return format('That code needs paying for %s months or more at a time. '
                  'Choose a longer term and it will apply.', c.min_term_months);
  end if;
  return null;
end;
$$;
revoke all on function public.fn__discount_refusal(text, uuid, text, integer) from public, anon, authenticated;

-- Ten refused tries in the last hour and the school waits. A try made while it
-- waits is logged too, marked paused, and does not count: counting it would
-- keep a school that is still typing waiting for ever.
create or replace function public.fn__discount_throttled(p_school_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select count(*) >= 10 from public.discount_events e
   where e.school_id = p_school_id and e.event = 'refused' and e.at > now() - interval '1 hour'
     and not coalesce((e.after->>'paused')::boolean, false);
$$;
revoke all on function public.fn__discount_throttled(uuid) from public, anon, authenticated;

-- What a school would save with a code it has not used: on the invoice that
-- is open (when nothing is paid on it, it is reissued with the code) or on the
-- next one.
create or replace function public.fn__code_preview(p_school_id uuid, c public.discount_codes,
                                                   p_plan_code text, p_months integer)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s public.subscriptions; v_start date; v_term numeric; v jsonb; v_open uuid;
  v_applies text; live public.subscription_discounts;
begin
  select * into s from public.subscriptions where school_id = p_school_id;
  v_open := public.fn__open_term_invoice(p_school_id);
  v_start := public.fn__discount_next_start(p_school_id);
  v_applies := case when v_open is null then 'next_invoice'
                    when public.fn__invoice_settled(v_open) = 0 then 'open_invoice'
                    else 'invoice_after_open' end;
  v_term := public.fn__term_price(p_school_id, coalesce(p_plan_code, s.plan_code),
                                  coalesce(p_months, s.term_months));
  v := public.fn__discount_calc(c.code, c.kind, c.value, c.duration, c.duration_months,
                                c.duration_until, c.plan_codes, c.min_term_months,
                                coalesce(p_plan_code, s.plan_code), coalesce(p_months, s.term_months),
                                v_start, v_term);
  select * into live from public.fn__discount_live(p_school_id, null);

  return jsonb_build_object(
    'ok', true, 'code', c.code, 'label', c.label,
    'kind', c.kind, 'value', c.value, 'duration', c.duration,
    'duration_months', c.duration_months, 'duration_until', c.duration_until,
    'summary', public.fn__discount_sentence(c.kind, c.value, c.duration,
                                            c.duration_months, c.duration_until),
    'trial_days', case when c.kind = 'trial_days' then c.value::integer end,
    'applies_to', v_applies,
    'period_start', v_start,
    'months', coalesce(p_months, s.term_months),
    'term_price', v_term,
    'months_covered', (v->>'covered')::integer,
    'discount_amount', (v->>'amount')::numeric,
    'amount', case when v_term is null then null else v_term - (v->>'amount')::numeric end,
    'list_amount', v_term,
    'skipped', v->>'skipped',
    'replaces', case when live.id is null or c.kind = 'trial_days' then null else jsonb_build_object(
      'code', live.code, 'label', live.label,
      'granted_by_kind', live.granted_by_kind,
      'summary', public.fn__discount_sentence(live.kind, live.value, live.duration,
                                              public.fn__discount_months_to_give(live), live.ends_on)) end);
end;
$$;
revoke all on function public.fn__code_preview(uuid, public.discount_codes, text, integer) from public, anon, authenticated;

-- PREVIEW. A refusal is an answer ({ok:false}) and is logged; ten in an hour
-- and the school waits. The school's own live code previews as its own.
create or replace function public.fn_preview_discount(p_code text, p_plan_code text, p_term_months integer)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_school uuid := public.current_school_id(); c public.discount_codes;
  v_refusal text; s public.subscriptions; v_code text := public.fn__norm_code(p_code);
  live public.subscription_discounts;
begin
  if v_school is null then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or the principal can apply a discount code.'
      using errcode = '42501';
  end if;
  -- Every refused try is logged, including one made while the school waits,
  -- so a school that keeps on guessing does not look as if it stopped at ten.
  if public.fn__discount_throttled(v_school) then
    v_refusal := 'Too many codes have been tried in the last hour. Please try again later, or ask us.';
    perform public.fn__discount_event('refused', left(v_code, 40), v_school, null, null,
      'school', null, jsonb_build_object('paused', true, 'preview', true), v_refusal);
    return jsonb_build_object('ok', false, 'reason', v_refusal);
  end if;
  select * into s from public.subscriptions where school_id = v_school;

  select * into live from public.fn__discount_live(v_school, null);
  if live.id is not null and live.code = v_code then
    v_refusal := 'That code is already on your subscription.';
    perform public.fn__discount_event('refused', live.code, v_school, live.id, null,
      'school', null, jsonb_build_object('preview', true), v_refusal);
    return jsonb_build_object('ok', false, 'already_yours', true, 'code', live.code,
      'reason', v_refusal);
  end if;

  v_refusal := public.fn__discount_refusal(v_code, v_school,
                 coalesce(nullif(btrim(coalesce(p_plan_code, '')), ''), s.plan_code),
                 coalesce(p_term_months, s.term_months));
  if v_refusal is not null then
    perform public.fn__discount_event('refused', left(v_code, 40), v_school, null, null,
      'school', null, null, v_refusal);
    return jsonb_build_object('ok', false, 'reason', v_refusal);
  end if;
  select * into c from public.discount_codes where code = v_code;
  return public.fn__code_preview(v_school, c,
           coalesce(nullif(btrim(coalesce(p_plan_code, '')), ''), s.plan_code),
           coalesce(p_term_months, s.term_months));
end;
$$;

-- REDEEM. The code row is locked while the seat is taken. Replacing a live
-- discount needs p_replace; a discount we gave cannot be replaced or removed by
-- the school; a code that would save nothing on its next invoice is not
-- allowed to replace one that would. Refusals are returned, not raised, so the
-- log of what was tried survives.
create or replace function public.fn_my_redeem_code(p_code text, p_replace boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  v_school uuid := public.current_school_id(); c public.discount_codes; s public.subscriptions;
  v_code text := public.fn__norm_code(p_code); v_refusal text; v_prev jsonb;
  live public.subscription_discounts; v_id uuid; v_trial date; v_re jsonb;
  dead public.subscription_discounts; v_raised boolean := false; v_shown jsonb;
begin
  if v_school is null then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or the principal can apply a discount code.'
      using errcode = '42501';
  end if;
  -- Logged and marked paused: visible to us, not counted towards the pause.
  if public.fn__discount_throttled(v_school) then
    v_refusal := 'Too many codes have been tried in the last hour. Please try again later, or ask us.';
    perform public.fn__discount_event('refused', left(v_code, 40), v_school, null, null,
      'school', null, jsonb_build_object('paused', true), v_refusal);
    return jsonb_build_object('ok', false, 'reason', v_refusal);
  end if;

  select * into s from public.subscriptions where school_id = v_school for update;
  if not found then
    raise exception 'This school has no subscription to apply a code to.';
  end if;
  -- The seat lock. Everything that counts seats for this code waits here.
  select * into c from public.discount_codes where code = v_code for update;

  v_refusal := public.fn__discount_refusal(v_code, v_school, s.plan_code, s.term_months);
  if v_refusal is not null then
    perform public.fn__discount_event('refused', left(v_code, 40), v_school, null, null,
      'school', null, null, v_refusal);
    return jsonb_build_object('ok', false, 'reason', v_refusal);
  end if;

  v_prev := public.fn__code_preview(v_school, c, s.plan_code, s.term_months);

  -- A money code that would save nothing on the invoice it would first reach is
  -- refused rather than spent: it would be burned for good for nothing.
  if c.kind <> 'trial_days' and coalesce((v_prev->>'discount_amount')::numeric, 0) = 0 then
    v_refusal := case
      when v_prev->>'term_price' is null
        then 'Your price has not been agreed yet. Use the code once it is, and it comes off your first invoice.'
      else format('Code %s would save nothing on your next invoice: %s', c.code,
                  coalesce(v_prev->>'skipped', 'it does not reach it.')) end;
    perform public.fn__discount_event('refused', c.code, v_school, null, null,
      'school', null, null, v_refusal);
    return jsonb_build_object('ok', false, 'reason', v_refusal);
  end if;

  -- "Live" here is anything still to give (fn__discount_has_value): months on
  -- an unpaid invoice, or an end date the next month still starts before.
  if c.kind <> 'trial_days' then
    select * into live from public.fn__discount_live(v_school, null);
    if live.id is not null then
      if live.granted_by_kind = 'platform' then
        v_refusal := 'Your current discount was arranged with us, so it can only be changed by us. Please call us.';
        perform public.fn__discount_event('refused', c.code, v_school, null, null, 'school', null,
          jsonb_build_object('arranged_with_us', live.code), v_refusal);
        return jsonb_build_object('ok', false, 'reason', v_refusal);
      end if;
      if not coalesce(p_replace, false) then
        v_refusal := format('Your subscription already has %s (%s). Using %s takes it off for good.',
                            live.code, live.label, c.code);
        perform public.fn__discount_event('refused', c.code, v_school, null, null, 'school', null,
          jsonb_build_object('needs_replace', live.code), v_refusal);
        return jsonb_build_object('ok', false, 'needs_replace', true, 'preview', v_prev,
          'reason', v_refusal);
      end if;
      update public.subscription_discounts
         set removed_at = now(), removed_by = auth.uid(),
             removed_reason = format('Replaced by %s at the school''s request', c.code)
       where id = live.id;
      perform public.fn__discount_event('replaced', live.code, v_school, live.id, null, 'school',
        jsonb_build_object('code', live.code, 'months_left', live.months_left),
        jsonb_build_object('replaced_by', c.code), null);
    end if;
  end if;

  -- A code that has run its course still holds the one-per-school slot until it
  -- is closed; it is closed here, with the reason and a line in the log, before
  -- the new one goes in. Only one with nothing left to give: anything else was
  -- replaced above or refused.
  if c.kind <> 'trial_days' then
    for dead in
      select * from public.subscription_discounts d
       where d.school_id = v_school and d.removed_at is null and d.kind <> 'trial_days'
         and not public.fn__discount_has_value(d)
    loop
      update public.subscription_discounts
         set removed_at = now(), removed_reason = 'Ran its course'
       where id = dead.id;
      perform public.fn__discount_event('removed', dead.code, v_school, dead.id, null, 'system',
        jsonb_build_object('months_left', dead.months_left, 'ends_on', dead.ends_on),
        null, 'Ran its course');
    end loop;
  end if;

  if c.kind = 'trial_days' then
    v_trial := s.trial_ends_on + c.value::integer;
    update public.subscriptions set trial_ends_on = v_trial where school_id = v_school;
  end if;

  insert into public.subscription_discounts
    (school_id, school_name, code, kind, value, duration, ends_on, uses_left,
     trial_days_added, redeemed_by, label, plan_codes, min_term_months,
     months_total, months_left, granted_by_kind)
  values (v_school, (select name from public.schools where id = v_school), c.code, c.kind,
          c.value, c.duration,
          case when c.duration = 'until' then c.duration_until end,
          case when c.kind = 'trial_days' then 0 end,
          case when c.kind = 'trial_days' then c.value::integer end,
          auth.uid(), c.label, c.plan_codes, c.min_term_months,
          case when c.duration = 'months' then c.duration_months end,
          case when c.duration = 'months' then c.duration_months end,
          'school')
  returning id into v_id;

  perform public.fn__discount_event(
    case when c.kind = 'trial_days' then 'trial_extended' else 'applied' end,
    c.code, v_school, v_id, null, 'school', null,
    jsonb_build_object('kind', c.kind, 'value', c.value, 'duration', c.duration,
                       'months', c.duration_months, 'until', c.duration_until,
                       'trial_ends_on', v_trial), null);
  insert into public.audit_log(school_id, actor, action, entity, entity_id, after, reason)
  values (v_school, auth.uid(), 'discount_applied', 'subscription_discounts', v_id::text,
          jsonb_build_object('code', c.code, 'kind', c.kind, 'value', c.value,
                             'duration', c.duration, 'trial_ends_on', v_trial),
          c.label);

  -- An invoice already raised and not yet paid is reissued so the code is on it.
  if c.kind <> 'trial_days' and v_prev->>'applies_to' = 'open_invoice' then
    v_re := public.fn__reissue_open_invoice(v_school, format('Reissued with code %s', c.code), 'school');
  -- A longer trial moves the first invoice to start after it. Left alone, an
  -- invoice raised for the old end fell due inside the new trial and locked
  -- the school as unpaid halfway through it.
  elsif c.kind = 'trial_days'
        and (select period_start from public.platform_invoices
              where id = public.fn__open_term_invoice(v_school)) <= v_trial then
    v_re := public.fn__reissue_open_invoice(v_school,
      format('Reissued to start after the trial, which now runs to %s', to_char(v_trial, 'DD Mon YYYY')),
      'school');
  end if;

  -- Reissued only when a replacement was actually raised. A reissue that could
  -- not raise one ({raised: {not_raised}}) or that kept the invoice ({kept,
  -- why}) is not, and its sentences are ours: they name Change plan and the
  -- reasons we keep an invoice. The school is shown which invoice went and
  -- which came, and nothing else.
  v_raised := jsonb_typeof(v_re->'raised') = 'object' and (v_re->'raised') ? 'invoice_id';
  v_shown := case
    when v_re is null then null
    when v_raised then jsonb_build_object('voided', v_re->'voided', 'raised',
      jsonb_build_object('invoice_id', v_re->'raised'->'invoice_id',
                         'doc_no', v_re->'raised'->'doc_no',
                         'amount', v_re->'raised'->'amount',
                         'period_start', v_re->'raised'->'period_start',
                         'period_end', v_re->'raised'->'period_end',
                         'due_on', v_re->'raised'->'due_on',
                         'discount_code', v_re->'raised'->'discount_code',
                         'discount_amount', v_re->'raised'->'discount_amount'))
    when v_re ? 'kept' then jsonb_build_object('kept', v_re->'kept')
    else jsonb_strip_nulls(jsonb_build_object('voided', v_re->'voided')) end;

  return jsonb_build_object(
    'ok', true, 'code', c.code, 'label', c.label,
    'summary', public.fn__discount_sentence(c.kind, c.value, c.duration,
                                            c.duration_months, c.duration_until),
    'trial_ends_on', v_trial,
    'preview', v_prev,
    'reissued', v_shown,
    'what_next', case
      when c.kind = 'trial_days'
        then format('Your free trial now runs to %s.', to_char(v_trial, 'DD Mon YYYY'))
      when v_raised
        then 'Your invoice has been reissued with the code taken off.'
      when v_re ? 'kept'
        then 'Your open invoice stays as it is, and the code comes off the invoice after it.'
      else 'It comes off your next invoice automatically.' end);
end;
$$;
revoke all on function public.fn_my_redeem_code(text, boolean) from public, anon;
grant execute on function public.fn_my_redeem_code(text, boolean) to authenticated;

-- The old entry point: no replacing, and a refusal is raised as before. It is
-- closed to signed-in users below: raising rolls back the log of the refused
-- try, so a guess made through it would never count towards the hourly limit.
-- The app redeems through fn_my_redeem_code, which answers instead of raising.
create or replace function public.fn_my_apply_discount(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v jsonb;
begin
  v := public.fn_my_redeem_code(p_code, false);
  if not coalesce((v->>'ok')::boolean, false) then
    raise exception '%', v->>'reason' using errcode = '22023';
  end if;
  return v;
end;
$$;
revoke all on function public.fn_my_apply_discount(text) from public, anon, authenticated;

create or replace function public.fn_my_remove_discount()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_school uuid := public.current_school_id(); live public.subscription_discounts;
begin
  if v_school is null or not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or the principal can remove a discount.'
      using errcode = '42501';
  end if;
  select * into live from public.fn__discount_live(v_school, null);
  if live.id is null then
    return jsonb_build_object('removed', false);
  end if;
  if live.granted_by_kind = 'platform' then
    raise exception 'This discount was arranged with us, so only we can take it off. Please call us.'
      using errcode = '22023';
  end if;
  update public.subscription_discounts
     set removed_at = now(), removed_by = auth.uid(), removed_reason = 'Removed by the school'
   where id = live.id;
  perform public.fn__discount_event('removed', live.code, v_school, live.id, null, 'school',
    jsonb_build_object('months_left', live.months_left, 'total_saved', live.total_saved),
    null, 'Removed by the school');
  insert into public.audit_log(school_id, actor, action, entity, entity_id, before, reason)
  values (v_school, auth.uid(), 'discount_removed', 'subscription_discounts', live.id::text,
          jsonb_build_object('code', live.code), 'Removed by the school');
  return jsonb_build_object('removed', true, 'code', live.code);
end;
$$;

-- What the school has, for the owner and principal only, from frozen terms.
create or replace function public.fn_my_discount()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare v_school uuid := public.current_school_id(); d public.subscription_discounts;
  t public.subscription_discounts;
begin
  if v_school is null
     or not public.may_view('owner'::public.user_role, 'principal'::public.user_role) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into d from public.fn__discount_live(v_school, null);
  select * into t from public.subscription_discounts
   where school_id = v_school and kind = 'trial_days';
  if d.id is null and t.id is null then
    return null;
  end if;
  return jsonb_build_object(
    'code', d.code, 'label', d.label,
    'kind', d.kind, 'value', d.value, 'duration', d.duration,
    'ends_on', d.ends_on, 'months_left', d.months_left, 'months_total', d.months_total,
    'times_applied', d.times_applied, 'total_saved', d.total_saved,
    'granted_by_us', d.granted_by_kind = 'platform',
    'can_remove', d.id is not null and d.granted_by_kind = 'school',
    'plan_codes', d.plan_codes, 'min_term_months', d.min_term_months,
    'summary', case when d.id is null then null else
      public.fn__discount_sentence(d.kind, d.value, d.duration,
                                   public.fn__discount_months_to_give(d), d.ends_on) end,
    'trial_code', case when t.id is null then null else jsonb_build_object(
      'code', t.code, 'days', t.trial_days_added, 'on', t.redeemed_at::date) end);
end;
$$;


-- -----------------------------------------------------------------------------
-- 6. OUR SIDE: MAKING, CHANGING, GIVING AND TAKING OFF CODES
-- -----------------------------------------------------------------------------

-- Every rule a code's terms must meet, in plain words. p_new is the row as it
-- would be saved; p_old is the row before (NULL when creating).
create or replace function public.fn__discount_validate(p_new public.discount_codes, p_old public.discount_codes)
returns void
language plpgsql
stable
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare v_bad text;
begin
  if p_old.code is null and (char_length(p_new.code) < 6 or p_new.code !~ '^[A-Z0-9][A-Z0-9_-]{5,31}$') then
    raise exception 'A code is 6 to 32 letters, digits, dashes or underscores, starting with a letter or digit. Short codes are guessed.'
      using errcode = '22023';
  end if;
  if btrim(coalesce(p_new.label, '')) = '' or char_length(p_new.label) > 80 then
    raise exception 'Give the code a label of up to 80 characters. It is the name the school sees.'
      using errcode = '22023';
  end if;
  if btrim(coalesce(p_new.description, '')) = '' then
    raise exception 'Say what the code is for, in our own words. Schools never see this.'
      using errcode = '22023';
  end if;
  if p_new.kind is null or p_new.kind not in ('percent', 'flat', 'trial_days') then
    raise exception 'A code takes a percentage off, takes rupees off each month, or adds trial days.'
      using errcode = '22023';
  end if;
  if p_new.value is null or p_new.value <= 0 then
    raise exception 'A discount of nothing is not a discount.' using errcode = '22023';
  end if;
  if p_new.kind = 'percent' and p_new.value > 100 then
    raise exception 'A percentage is at most 100.' using errcode = '22023';
  end if;
  if p_new.kind = 'flat' and (p_new.value <> round(p_new.value) or p_new.value > 50000) then
    raise exception 'Rupees off each month is a whole number, at most Rs 50,000.' using errcode = '22023';
  end if;
  if p_new.kind = 'trial_days' and (p_new.value <> round(p_new.value) or p_new.value > 30) then
    raise exception 'A trial can be extended by 1 to 30 days with a code.' using errcode = '22023';
  end if;
  if p_new.kind = 'trial_days' and p_new.duration <> 'once' then
    raise exception 'Trial days are added once.' using errcode = '22023';
  end if;
  if p_new.kind <> 'trial_days' then
    if p_new.duration not in ('months', 'until', 'forever') then
      raise exception 'A money code lasts a number of months, until a date, or for as long as the school subscribes.'
        using errcode = '22023';
    end if;
    if p_new.duration = 'months' and (p_new.duration_months is null or p_new.duration_months not between 1 and 36) then
      raise exception 'Say how many months the code lasts: 1 to 36.' using errcode = '22023';
    end if;
    if p_new.duration = 'until' and p_new.duration_until is null then
      raise exception 'Say the date the code runs until.' using errcode = '22023';
    end if;
    if p_new.duration = 'until'
       and (p_old.code is null or p_old.duration_until is distinct from p_new.duration_until)
       and p_new.duration_until < greatest(current_date, coalesce(p_new.redeem_until, current_date)) then
      raise exception 'A code cannot end before today, or before the last day it can be used.'
        using errcode = '22023';
    end if;
    if p_new.kind = 'percent' and p_new.value >= 100 and p_new.duration = 'forever' and not p_new.is_private then
      raise exception 'A code that makes the subscription free for ever must be private to one school.'
        using errcode = '22023';
    end if;
    -- The rule is about what the school pays, not the spelling: 99.98% rounds
    -- a month to Rs 0, Rs 50,000 off each month is every price we have, and
    -- "until 2099" is for ever. A code that can make invoices free, or all but
    -- free, for more than a year is one we give to one school, never one
    -- anybody can type. Checked when the code is made or its terms change, so
    -- a code made before this rule can still be renamed or retired.
    if not coalesce(p_new.is_private, false)
       and ((p_new.kind = 'percent' and p_new.value >= 99.5)
            or (p_new.kind = 'flat'
                and p_new.value >= (select min(p.price_monthly) from public.plans p
                                     where p.active and not p.by_arrangement and p.price_monthly > 0)))
       and (p_new.duration = 'forever'
            or (p_new.duration = 'until'
                and p_new.duration_until > (current_date + interval '12 months')::date)
            or (p_new.duration = 'months' and p_new.duration_months > 12))
       and (p_old.code is null
            or (p_new.kind, p_new.value, p_new.duration, p_new.duration_months,
                p_new.duration_until, p_new.is_private)
               is distinct from
               (p_old.kind, p_old.value, p_old.duration, p_old.duration_months,
                p_old.duration_until, p_old.is_private)) then
      raise exception 'A code that makes the subscription free, or all but free, for more than a year must be private to one school.'
        using errcode = '22023';
    end if;
  end if;
  if p_new.redeem_from is not null and p_new.redeem_until is not null
     and p_new.redeem_until < p_new.redeem_from then
    raise exception 'The last day it can be used comes before the first.' using errcode = '22023';
  end if;
  if p_new.redeem_until is not null and p_new.redeem_until < current_date
     and (p_old.code is null or p_old.redeem_until is distinct from p_new.redeem_until) then
    raise exception 'The last day it can be used is in the past.' using errcode = '22023';
  end if;
  if p_new.max_redemptions is not null and p_new.max_redemptions < 1 then
    raise exception 'A limit on schools is at least 1, or none.' using errcode = '22023';
  end if;
  if p_new.plan_codes is not null then
    if cardinality(p_new.plan_codes) = 0 or array_position(p_new.plan_codes, null) is not null then
      raise exception 'Leave the plans empty for "any plan".' using errcode = '22023';
    end if;
    select string_agg(x, ', ') into v_bad from unnest(p_new.plan_codes) x
     where not exists (select 1 from public.plans p where p.code = x and p.active);
    if v_bad is not null then
      raise exception 'Not a plan on sale: %', v_bad using errcode = '22023';
    end if;
  end if;
  if p_new.min_term_months is not null and p_new.min_term_months not in (3, 12) then
    raise exception 'A minimum term is three months or a year, or none.' using errcode = '22023';
  end if;
  if p_new.is_private and p_new.school_id is null then
    raise exception 'A private code is made for one school. Choose the school.' using errcode = '22023';
  end if;
end;
$$;
revoke all on function public.fn__discount_validate(public.discount_codes, public.discount_codes) from public, anon, authenticated;

-- A code from a jsonb object, starting from p_base.
create or replace function public.fn__discount_from_json(p jsonb, p_base public.discount_codes)
returns public.discount_codes
language plpgsql
stable
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare r public.discount_codes := p_base;
begin
  if p ? 'label' then r.label := nullif(btrim(p->>'label'), ''); end if;
  if p ? 'description' then r.description := nullif(btrim(p->>'description'), ''); end if;
  if p ? 'kind' then r.kind := p->>'kind'; end if;
  if p ? 'value' then r.value := nullif(p->>'value', '')::numeric; end if;
  if p ? 'duration' then r.duration := p->>'duration'; end if;
  if p ? 'duration_months' then r.duration_months := nullif(p->>'duration_months', '')::integer; end if;
  if p ? 'duration_until' then r.duration_until := nullif(p->>'duration_until', '')::date; end if;
  if p ? 'redeem_from' then r.redeem_from := nullif(p->>'redeem_from', '')::date; end if;
  if p ? 'redeem_until' then r.redeem_until := nullif(p->>'redeem_until', '')::date; end if;
  if p ? 'max_redemptions' then r.max_redemptions := nullif(p->>'max_redemptions', '')::integer; end if;
  if p ? 'plan_codes' then
    r.plan_codes := case when jsonb_typeof(p->'plan_codes') = 'array'
                              and jsonb_array_length(p->'plan_codes') > 0
                         then array(select jsonb_array_elements_text(p->'plan_codes')) end;
  end if;
  if p ? 'min_term_months' then r.min_term_months := nullif(p->>'min_term_months', '')::integer; end if;
  if p ? 'active' then r.active := coalesce((p->>'active')::boolean, true); end if;
  if p ? 'private' then r.is_private := coalesce((p->>'private')::boolean, false); end if;
  if p ? 'school_id' then r.school_id := nullif(p->>'school_id', '')::uuid; end if;
  if r.kind = 'trial_days' then r.duration := 'once'; end if;
  if r.duration is distinct from 'months' then r.duration_months := null; end if;
  if r.duration is distinct from 'until' then r.duration_until := null; end if;
  if not coalesce(r.is_private, false) then r.school_id := null; end if;
  if r.is_private then r.max_redemptions := 1; end if;
  return r;
end;
$$;
revoke all on function public.fn__discount_from_json(jsonb, public.discount_codes) from public, anon, authenticated;

create or replace function public.fn__discount_row_json(c public.discount_codes)
returns jsonb
language sql
stable
set search_path = public
as $$
  select case when c.code is null then null else jsonb_build_object(
    'code', c.code, 'label', c.label, 'description', c.description, 'kind', c.kind,
    'value', c.value, 'duration', c.duration, 'duration_months', c.duration_months,
    'duration_until', c.duration_until, 'redeem_from', c.redeem_from,
    'redeem_until', c.redeem_until, 'max_redemptions', c.max_redemptions,
    'plan_codes', c.plan_codes, 'min_term_months', c.min_term_months,
    'active', c.active, 'private', c.is_private, 'school_id', c.school_id,
    'updated_at', c.updated_at) end;
$$;
revoke all on function public.fn__discount_row_json(public.discount_codes) from public, anon, authenticated;

-- CREATE. Refuses a code that exists: a new code never overwrites an old one.
-- A private code with no code given gets a random ten-character one.
create or replace function public.fn_platform_create_discount(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare r public.discount_codes; v_old public.discount_codes;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'Give the code''s terms' using errcode = '22023';
  end if;
  perform public.fn__only_these_keys(jsonb_build_array(p),
    '{code,label,description,kind,value,duration,duration_months,duration_until,redeem_from,redeem_until,max_redemptions,plan_codes,min_term_months,active,private,school_id}'::text[],
    'A discount code');

  r.code := public.fn__norm_code(p->>'code');
  r.active := true;
  r.is_private := false;
  r := public.fn__discount_from_json(p, r);
  if r.code = '' and r.is_private then
    r.code := 'P' || upper(left(replace(gen_random_uuid()::text, '-', ''), 9));
  end if;
  if r.is_private and not exists (select 1 from public.schools where id = r.school_id) then
    raise exception 'There is no such school to make a private code for.' using errcode = '22023';
  end if;
  if exists (select 1 from public.discount_codes where code = r.code) then
    raise exception 'A code called % already exists. Choose another name, or edit that one.', r.code
      using errcode = '23505';
  end if;
  perform public.fn__discount_validate(r, v_old);

  r.created_by := auth.uid();
  r.updated_by := auth.uid();
  r.created_at := now();
  r.updated_at := now();
  insert into public.discount_codes values (r.*);
  select * into r from public.discount_codes where code = r.code;

  perform public.fn__discount_event('created', r.code, r.school_id, null, null, 'platform',
                                    null, public.fn__discount_row_json(r), null);
  return public.fn__discount_row_json(r) || jsonb_build_object(
    'summary', public.fn__discount_sentence(r.kind, r.value, r.duration, r.duration_months, r.duration_until));
end;
$$;
revoke all on function public.fn_platform_create_discount(jsonb) from public, anon;
grant execute on function public.fn_platform_create_discount(jsonb) to authenticated;

-- EDIT. Needs the version it was made from, so two people editing at once do
-- not overwrite each other. Once a code has been redeemed its money terms are
-- what schools were promised, so they are locked: retire it and make another.
create or replace function public.fn_platform_edit_discount(p_code text, p jsonb, p_expected_updated_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.discount_codes; r public.discount_codes; v_seats integer; v_used boolean;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'Give the changes' using errcode = '22023';
  end if;
  perform public.fn__only_these_keys(jsonb_build_array(p),
    '{label,description,kind,value,duration,duration_months,duration_until,redeem_from,redeem_until,max_redemptions,plan_codes,min_term_months,active,private,school_id}'::text[],
    'A discount code');

  select * into v_old from public.discount_codes where code = public.fn__norm_code(p_code) for update;
  if not found then
    raise exception 'There is no code called %', public.fn__norm_code(p_code) using errcode = '22023';
  end if;
  if p_expected_updated_at is null or v_old.updated_at is distinct from p_expected_updated_at then
    raise exception 'Somebody changed % while you were editing it. Reload it and make your change again.', v_old.code
      using errcode = '40001';
  end if;

  r := public.fn__discount_from_json(p, v_old);
  v_seats := public.fn__discount_seats_taken(v_old.code);
  v_used := v_seats > 0 or exists (select 1 from public.subscription_discounts where code = v_old.code);

  if v_used and (r.kind, r.value, r.duration, r.duration_months, r.duration_until,
                 r.plan_codes, r.min_term_months, r.is_private, r.school_id)
                is distinct from
                (v_old.kind, v_old.value, v_old.duration, v_old.duration_months, v_old.duration_until,
                 v_old.plan_codes, v_old.min_term_months, v_old.is_private, v_old.school_id) then
    raise exception 'Schools have already used %, so what it gives and to whom is locked. Retire it and make a new code instead.',
      v_old.code using errcode = '22023';
  end if;
  if r.max_redemptions is not null and r.max_redemptions < v_seats then
    raise exception '% school(s) already hold a place on %. The limit cannot go below that.', v_seats, v_old.code
      using errcode = '22023';
  end if;
  perform public.fn__discount_validate(r, v_old);

  update public.discount_codes
     set label = r.label, description = r.description, kind = r.kind, value = r.value,
         duration = r.duration, duration_months = r.duration_months,
         duration_until = r.duration_until, redeem_from = r.redeem_from,
         redeem_until = r.redeem_until, max_redemptions = r.max_redemptions,
         plan_codes = r.plan_codes, min_term_months = r.min_term_months,
         active = r.active, is_private = r.is_private, school_id = r.school_id,
         updated_by = auth.uid()
   where code = v_old.code
  returning * into r;

  perform public.fn__discount_event(case when v_old.active and not r.active then 'retired' else 'edited' end,
    r.code, r.school_id, null, null, 'platform',
    public.fn__discount_row_json(v_old), public.fn__discount_row_json(r), null);

  return public.fn__discount_row_json(r) || jsonb_build_object(
    'summary', public.fn__discount_sentence(r.kind, r.value, r.duration, r.duration_months, r.duration_until),
    'note', case when v_used then 'Schools that already have this code keep exactly what they were given.' end);
end;
$$;
revoke all on function public.fn_platform_edit_discount(text, jsonb, timestamptz) from public, anon;
grant execute on function public.fn_platform_edit_discount(text, jsonb, timestamptz) to authenticated;

create or replace function public.fn_platform_retire_discount(p_code text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_old public.discount_codes; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_reason is null then
    raise exception 'Say why the code is being retired.' using errcode = '22023';
  end if;
  select * into v_old from public.discount_codes where code = public.fn__norm_code(p_code) for update;
  if not found then
    raise exception 'There is no code called %', public.fn__norm_code(p_code) using errcode = '22023';
  end if;
  update public.discount_codes set active = false, updated_by = auth.uid() where code = v_old.code;
  perform public.fn__discount_event('retired', v_old.code, v_old.school_id, null, null, 'platform',
    public.fn__discount_row_json(v_old), jsonb_build_object('active', false), v_reason);
  return jsonb_build_object('code', v_old.code, 'active', false,
    'note', 'No school can take it up from now on. Schools that already have it keep it.');
end;
$$;
revoke all on function public.fn_platform_retire_discount(text, text) from public, anon;
grant execute on function public.fn_platform_retire_discount(text, text) to authenticated;

-- Kept for a console that has not been reloaded. It only ever creates. An
-- existing code is refused: this form cannot know the version the operator
-- was looking at, and the old signature's defaults (switched on, no limit on
-- schools) are not things anybody chose. Passing them on as an edit switched a
-- retired one-seat code back on with no limit, and turned an unused 10% code
-- into 60% for ever because a second "New code" form used the same name.
create or replace function public.fn_platform_save_discount(
  p_code text, p_description text, p_kind text, p_value numeric, p_duration text,
  p_duration_months integer default null, p_duration_until date default null,
  p_redeem_from date default null, p_redeem_until date default null,
  p_max_redemptions integer default null, p_plan_codes text[] default null,
  p_min_term_months integer default null, p_active boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if exists (select 1 from public.discount_codes where code = public.fn__norm_code(p_code)) then
    raise exception 'A code called % already exists. This screen is out of date: reload it and change % on the Discounts page, where an edit starts from the version you see.',
      public.fn__norm_code(p_code), public.fn__norm_code(p_code)
      using errcode = '23505';
  end if;
  -- The label the school sees is built from the terms, never copied from our
  -- description: that is ours, and the old console had no label field.
  v := jsonb_build_object(
    'label', left(public.fn__discount_sentence(p_kind, p_value,
                    case when p_duration = 'once' and p_kind <> 'trial_days' then 'months' else p_duration end,
                    case when p_duration = 'once' and p_kind <> 'trial_days' then 1 else p_duration_months end,
                    p_duration_until), 80),
    'description', p_description,
    'kind', p_kind, 'value', p_value,
    'duration', case when p_duration = 'once' and p_kind <> 'trial_days' then 'months' else p_duration end,
    'duration_months', case when p_duration = 'once' and p_kind <> 'trial_days' then 1 else p_duration_months end,
    'duration_until', p_duration_until, 'redeem_from', p_redeem_from,
    'redeem_until', p_redeem_until, 'max_redemptions', p_max_redemptions,
    'plan_codes', to_jsonb(p_plan_codes), 'min_term_months', p_min_term_months,
    'active', p_active);
  return public.fn_platform_create_discount(v || jsonb_build_object('code', p_code))
         || jsonb_build_object('created', true);
end;
$$;

create or replace function public.fn_platform_delete_discount(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_old public.discount_codes;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into v_old from public.discount_codes where code = public.fn__norm_code(p_code) for update;
  if not found then
    raise exception 'There is no code called %', public.fn__norm_code(p_code);
  end if;
  if exists (select 1 from public.subscription_discounts where code = v_old.code) then
    raise exception 'Code % has been used, so it cannot be deleted. Retire it instead.', v_old.code;
  end if;
  delete from public.discount_codes where code = v_old.code;
  perform public.fn__discount_event('deleted', v_old.code, v_old.school_id, null, null, 'platform',
    public.fn__discount_row_json(v_old), null, null);
  return jsonb_build_object('code', v_old.code, 'deleted', true);
end;
$$;

-- GIVE A SCHOOL A CODE. Ours to give: the redeem window and "switched off" do
-- not apply, a private code goes only to its school, seats are still counted
-- under the lock, and a reason is kept. A code the school had before and lost
-- is restored rather than refused.
create or replace function public.fn_platform_grant_discount(
  p_school_id uuid, p_code text, p_reason text, p_replace boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  c public.discount_codes; s public.subscriptions; live public.subscription_discounts;
  prior public.subscription_discounts; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_id uuid; v_trial date; v_name text; v_re jsonb; dead public.subscription_discounts;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_reason is null or length(v_reason) < 8 then
    raise exception 'Say why this school is getting the code. It is kept with the discount.'
      using errcode = '22023';
  end if;
  select * into s from public.subscriptions where school_id = p_school_id for update;
  if not found then
    raise exception 'That school has no subscription' using errcode = '22023';
  end if;
  select name into v_name from public.schools where id = p_school_id;
  select * into c from public.discount_codes where code = public.fn__norm_code(p_code) for update;
  if not found then
    raise exception 'There is no code called %', public.fn__norm_code(p_code) using errcode = '22023';
  end if;
  if c.is_private and c.school_id is distinct from p_school_id then
    raise exception 'Code % was made for another school.', c.code using errcode = '22023';
  end if;

  select * into prior from public.subscription_discounts
   where school_id = p_school_id and code = c.code;

  if c.kind = 'trial_days' then
    if prior.id is not null or exists (select 1 from public.subscription_discounts
                                        where school_id = p_school_id and kind = 'trial_days') then
      raise exception '% has already had its trial extended once with a code.', v_name using errcode = '22023';
    end if;
    if public.fn_effective_status(p_school_id) <> 'trialing' then
      raise exception '% is not in a running trial, so there is nothing to extend.', v_name using errcode = '22023';
    end if;
  end if;

  -- A seat is counted under the code row's lock, taken above. A restore needs
  -- one too when the old redemption gave its seat back (removed before it
  -- saved anything), because another school may have taken that seat since:
  -- restoring without counting left a one-seat code live at two schools.
  if (prior.id is null
      or (prior.removed_at is not null and prior.times_applied = 0 and prior.kind <> 'trial_days'))
     and c.max_redemptions is not null
     and public.fn__discount_seats_taken(c.code) >= c.max_redemptions then
    raise exception 'Every place on % is taken (% of %).%', c.code,
      public.fn__discount_seats_taken(c.code), c.max_redemptions,
      case when prior.id is not null
           then format(' %s gave its place back when it was taken off, so it cannot be restored unless the limit is raised.', v_name)
           else '' end
      using errcode = '22023';
  end if;

  if c.kind <> 'trial_days' then
    select * into live from public.fn__discount_live(p_school_id, null);
    if live.id is not null and live.id is distinct from prior.id then
      if not coalesce(p_replace, false) then
        raise exception '% already has % (%). Replace it on purpose if that is what you mean.',
          v_name, live.code, live.label using errcode = '22023';
      end if;
      update public.subscription_discounts
         set removed_at = now(), removed_by = auth.uid(),
             removed_reason = format('Replaced by %s: %s', c.code, v_reason)
       where id = live.id;
      perform public.fn__discount_event('replaced', live.code, p_school_id, live.id, null, 'platform',
        jsonb_build_object('code', live.code, 'months_left', live.months_left),
        jsonb_build_object('replaced_by', c.code), v_reason);
    end if;
  end if;

  -- A code that has run its course still holds the one-per-school slot until it
  -- is closed; it is closed here, with the reason and a line in the log, before
  -- the new one goes in. Only one with nothing left to give.
  if c.kind <> 'trial_days' then
    for dead in
      select * from public.subscription_discounts d
       where d.school_id = p_school_id and d.removed_at is null and d.kind <> 'trial_days'
         and d.id is distinct from prior.id
         and not public.fn__discount_has_value(d)
    loop
      update public.subscription_discounts
         set removed_at = now(), removed_reason = 'Ran its course'
       where id = dead.id;
      perform public.fn__discount_event('removed', dead.code, p_school_id, dead.id, null, 'system',
        jsonb_build_object('months_left', dead.months_left, 'ends_on', dead.ends_on),
        null, 'Ran its course');
    end loop;
  end if;

  if prior.id is not null then
    -- Restore what the school had: same frozen terms, months as they were.
    if prior.removed_at is null then
      raise exception '% already has % on its subscription.', v_name, c.code using errcode = '22023';
    end if;
    update public.subscription_discounts
       set removed_at = null, removed_by = null, removed_reason = null,
           granted_by_kind = 'platform', grant_reason = v_reason
     where id = prior.id
    returning id into v_id;
    perform public.fn__discount_event('restored', c.code, p_school_id, v_id, null, 'platform',
      null, jsonb_build_object('months_left', prior.months_left), v_reason);
  else
    if c.kind = 'trial_days' then
      v_trial := s.trial_ends_on + c.value::integer;
      update public.subscriptions set trial_ends_on = v_trial where school_id = p_school_id;
    end if;
    insert into public.subscription_discounts
      (school_id, school_name, code, kind, value, duration, ends_on, uses_left,
       trial_days_added, redeemed_by, label, plan_codes, min_term_months,
       months_total, months_left, granted_by_kind, grant_reason)
    values (p_school_id, v_name, c.code, c.kind, c.value, c.duration,
            case when c.duration = 'until' then c.duration_until end,
            case when c.kind = 'trial_days' then 0 end,
            case when c.kind = 'trial_days' then c.value::integer end,
            auth.uid(), c.label, c.plan_codes, c.min_term_months,
            case when c.duration = 'months' then c.duration_months end,
            case when c.duration = 'months' then c.duration_months end,
            'platform', v_reason)
    returning id into v_id;
    perform public.fn__discount_event(
      case when c.kind = 'trial_days' then 'trial_extended' else 'given' end,
      c.code, p_school_id, v_id, null, 'platform', null,
      jsonb_build_object('kind', c.kind, 'value', c.value, 'trial_ends_on', v_trial), v_reason);
  end if;

  insert into public.audit_log(school_id, actor, action, entity, entity_id, after, reason)
  values (p_school_id, auth.uid(), 'discount_given', 'subscription_discounts', v_id::text,
          jsonb_build_object('code', c.code, 'label', c.label, 'trial_ends_on', v_trial),
          c.label);

  if c.kind <> 'trial_days' then
    v_re := public.fn__reissue_open_invoice(p_school_id, format('Reissued with code %s', c.code), 'operator');
  elsif v_trial is not null
        and (select period_start from public.platform_invoices
              where id = public.fn__open_term_invoice(p_school_id)) <= v_trial then
    v_re := public.fn__reissue_open_invoice(p_school_id,
      format('Reissued to start after the trial, which now runs to %s', to_char(v_trial, 'DD Mon YYYY')),
      'operator');
  end if;

  return jsonb_build_object('school_id', p_school_id, 'code', c.code, 'redemption_id', v_id,
    'restored', prior.id is not null, 'trial_ends_on', v_trial, 'reissued', v_re,
    'summary', public.fn__discount_sentence(c.kind, c.value, c.duration,
                                            c.duration_months, c.duration_until));
end;
$$;
revoke all on function public.fn_platform_grant_discount(uuid, text, text, boolean) from public, anon;
grant execute on function public.fn_platform_grant_discount(uuid, text, text, boolean) to authenticated;

create or replace function public.fn_platform_give_discount(p_school_id uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return public.fn_platform_grant_discount(p_school_id, p_code, 'Given from the console', false);
end;
$$;

-- TAKE A DISCOUNT OFF. The open invoice is reissued without it when nothing
-- is paid on it and the code came off it, exactly as giving a code reissues
-- it with the code on. Closing the redemption alone left the saving on the
-- unpaid invoice: a school given half off a year by mistake still owed half.
-- An invoice we priced by hand is left alone (the code took nothing off it),
-- and one with money on it stays, the change applying from the next. The
-- result says which.
create or replace function public.fn_platform_remove_discount(p_school_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  live public.subscription_discounts; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_open uuid; v_doc text; v_carries boolean := false; v_re jsonb; v_note text;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_reason is null then
    raise exception 'Say why the discount is being taken off. The school is told.';
  end if;
  perform 1 from public.subscriptions where school_id = p_school_id for update;
  select * into live from public.fn__discount_live(p_school_id, null);
  if live.id is null then
    raise exception 'That school has no live discount.';
  end if;

  v_open := public.fn__open_term_invoice(p_school_id);
  if v_open is not null then
    select doc_no into v_doc from public.platform_invoices where id = v_open;
    v_carries := exists (select 1 from public.discount_applications a
                          where a.invoice_id = v_open and a.redemption_id = live.id
                            and a.reversed_at is null and not a.overridden);
  end if;

  update public.subscription_discounts
     set removed_at = now(), removed_by = auth.uid(), removed_reason = v_reason
   where id = live.id;
  perform public.fn__discount_event('removed', live.code, p_school_id, live.id, null, 'platform',
    jsonb_build_object('months_left', live.months_left, 'total_saved', live.total_saved),
    null, v_reason);
  insert into public.audit_log(school_id, actor, action, entity, entity_id, before, reason)
  values (p_school_id, auth.uid(), 'discount_removed', 'subscription_discounts', live.id::text,
          jsonb_build_object('code', live.code, 'label', live.label), v_reason);

  if v_carries then
    v_re := public.fn__reissue_open_invoice(p_school_id,
              format('Reissued without code %s: %s', live.code, v_reason), 'operator');
  end if;
  v_note := case
    when v_open is null
      then 'No invoice is open. The next one is raised without the code.'
    when not v_carries
      then format('%s did not have the code taken off it, so it stays as it is.', v_doc)
    when jsonb_typeof(v_re->'raised') = 'object' and (v_re->'raised') ? 'invoice_id'
      then format('%s was voided and reissued as %s for Rs %s, without the code.', v_doc,
                  v_re->'raised'->>'doc_no',
                  to_char((v_re->'raised'->>'amount')::numeric, 'FM999,999,999'))
    when v_re ? 'kept'
      then format('%s keeps the code: %s', v_doc, coalesce(v_re->>'why', 'it could not be reissued'))
    when jsonb_typeof(v_re->'raised') = 'object' and (v_re->'raised') ? 'not_raised'
      then format('%s was voided, and no new invoice could be raised: %s', v_doc,
                  v_re->'raised'->>'not_raised')
    else format('%s still has the code taken off it.', v_doc) end;

  return jsonb_build_object('school_id', p_school_id, 'code', live.code, 'removed', true,
                            'invoice', v_re, 'invoice_note', v_note);
end;
$$;


-- -----------------------------------------------------------------------------
-- 7. WHAT WE SEE
-- -----------------------------------------------------------------------------

create or replace function public.fn_platform_discounts()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(public.fn__discount_row_json(c) || jsonb_build_object(
      'created_at', c.created_at,
      'school_name', (select name from public.schools where id = c.school_id),
      'summary', public.fn__discount_sentence(c.kind, c.value, c.duration,
                                              c.duration_months, c.duration_until),
      'seats_taken', public.fn__discount_seats_taken(c.code),
      'redeemed', u.redeemed, 'live', u.live,
      'invoices', u.invoices, 'total_saved', u.total_saved,
      'deletable', u.redeemed = 0,
      'terms_locked', u.redeemed > 0)
      order by c.active desc, c.created_at desc)
    from public.discount_codes c
    cross join lateral (
      select (select count(*) from public.subscription_discounts d where d.code = c.code)::int as redeemed,
             (select count(*) from public.subscription_discounts d
               where d.code = c.code and d.removed_at is null and d.kind <> 'trial_days'
                 and public.fn__discount_has_value(d))::int as live,
             (select count(*) from public.discount_applications a
               where a.code = c.code and a.reversed_at is null)::int as invoices,
             (select coalesce(sum(a.amount_off), 0) from public.discount_applications a
               where a.code = c.code and a.reversed_at is null) as total_saved) u
  ), '[]'::jsonb);
end;
$$;

create or replace function public.fn_platform_discount_usage(p_code text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'redemption_id', d.id,
      'school_id', d.school_id,
      'school_name', coalesce(s.name, d.school_name),
      'code', d.code, 'label', d.label,
      'kind', d.kind, 'value', d.value, 'duration', d.duration,
      'ends_on', d.ends_on, 'months_left', d.months_left, 'months_total', d.months_total,
      'times_applied', d.times_applied, 'total_saved', d.total_saved,
      'trial_days_added', d.trial_days_added,
      'granted_by_kind', d.granted_by_kind, 'grant_reason', d.grant_reason,
      'redeemed_at', d.redeemed_at,
      'redeemed_by', (select full_name from public.profiles where id = d.redeemed_by),
      'removed_at', d.removed_at, 'removed_reason', d.removed_reason,
      'removed_by', (select full_name from public.profiles where id = d.removed_by),
      'plan_code', sub.plan_code,
      'summary', public.fn__discount_sentence(d.kind, d.value, d.duration,
                                              coalesce(d.months_left, d.months_total), d.ends_on),
      'state', case
        when d.removed_at is not null and d.removed_reason = 'Ran its course' then 'spent'
        when d.removed_at is not null then 'removed'
        when d.kind = 'trial_days' then 'trial'
        when public.fn__discount_has_value(d) then 'active'
        when d.duration = 'until' then 'expired'
        else 'spent' end)
      order by d.redeemed_at desc)
    from public.subscription_discounts d
    left join public.schools s on s.id = d.school_id
    left join public.subscriptions sub on sub.school_id = d.school_id
   where p_code is null or d.code = public.fn__norm_code(p_code)
  ), '[]'::jsonb);
end;
$$;

create or replace function public.fn_platform_discount_events(
  p_code text default null, p_school_id uuid default null, p_limit integer default 200)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'at', e.at, 'event', e.event, 'code', e.code,
      'school_id', e.school_id, 'school_name', e.school_name,
      'invoice_id', e.invoice_id,
      'doc_no', (select doc_no from public.platform_invoices where id = e.invoice_id),
      'actor_kind', e.actor_kind,
      'actor', coalesce((select full_name from public.profiles where id = e.actor),
                        (select email from public.platform_admins where user_id = e.actor)),
      'before', e.before, 'after', e.after, 'reason', e.reason) order by e.at desc, e.id desc)
    from (select * from public.discount_events
           where (p_code is null or code = public.fn__norm_code(p_code))
             and (p_school_id is null or school_id = p_school_id)
           order by at desc, id desc
           limit greatest(1, least(coalesce(p_limit, 200), 1000))) e
  ), '[]'::jsonb);
end;
$$;
revoke all on function public.fn_platform_discount_events(text, uuid, integer) from public, anon;
grant execute on function public.fn_platform_discount_events(text, uuid, integer) to authenticated;

-- The school's page reads its discount from the frozen redemption.
CREATE OR REPLACE FUNCTION public.fn_platform_school_detail(p_school_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'Asia/Karachi'
AS $function$
declare
  v_school   record;
  v_settings record;
  v_sub      record;
  v_plan     record;
  v_status   public.subscription_status;
  v_expiry   date;
  v_margin   integer;
  v_sess     uuid;
  v_n_classes    integer; v_n_sections integer; v_n_heads integer;
  v_n_priced     integer; v_n_students integer; v_n_staff integer;
  v_n_families   integer; v_n_parents  integer;
  v_billed       boolean; v_last_pay date; v_invoiced numeric; v_paid numeric;
  v_ready jsonb := '[]'::jsonb;
  v_disc public.subscription_discounts;
  v_disc_block jsonb := 'null'::jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  select * into v_school from public.schools where id = p_school_id;
  if not found then
    raise exception 'School not found';
  end if;

  select * into v_settings from public.school_settings where school_id = p_school_id;
  select * into v_sub      from public.subscriptions  where school_id = p_school_id;
  if v_sub.plan_code is not null then
    select * into v_plan from public.plans where code = v_sub.plan_code;
    v_status := public.fn_effective_status(p_school_id);
    v_margin := public.plan_margin_limit(
                  public.fn__student_limit(p_school_id));
    v_expiry := case
      when v_status = 'trialing' then v_sub.trial_ends_on
      when v_status = 'active'   then public.fn__coverage_end(p_school_id)
      when v_status = 'grace'    then public.fn__coverage_end(p_school_id) + public.fn__grace_for(p_school_id)
      else null end;
  end if;

  -- --- the numbers behind the checklist -----------------------------------
  select id into v_sess from public.academic_sessions
   where school_id = p_school_id and is_current limit 1;

  select count(*) into v_n_classes  from public.classes  where school_id = p_school_id and active;
  select count(*) into v_n_sections from public.sections where school_id = p_school_id;
  select count(*) into v_n_heads    from public.fee_heads where school_id = p_school_id and active;

  -- Classes with at least one fee amount on record, not rows in fee_structures:
  -- one head priced for one class is not a priced school, and the operator needs
  -- to see "3 of 11 classes priced" rather than "yes, fees are set".
  select count(distinct class_id) into v_n_priced
    from public.fee_structures where school_id = p_school_id;

  select count(*) into v_n_students from public.students
   where school_id = p_school_id and deleted_at is null and status = 'active';
  select count(*) into v_n_staff from public.staff
   where school_id = p_school_id and deleted_at is null and left_on is null;
  select count(*) into v_n_families from public.families where school_id = p_school_id;
  select count(*) into v_n_parents  from public.profiles
   where school_id = p_school_id and role = 'parent' and active;

  select exists (select 1 from public.invoices
                  where school_id = p_school_id and period_month is not null)
    into v_billed;
  select max(created_at)::date into v_last_pay from public.payments
   where school_id = p_school_id and status = 'verified';

  v_invoiced := public.fn__platform_billed(p_school_id);
  v_paid := public.fn__platform_settled(p_school_id);

  -- --- the checklist, in the order a school has to do it -------------------
  -- Ordered deliberately: you cannot price a class that does not exist, or put
  -- an amount against a fee head that has not been created. The UI shows the
  -- first unfinished row as the next thing to talk to them about.
  v_ready :=
    jsonb_build_array(
      jsonb_build_object('key','session','label','An academic year is set',
        'done', v_sess is not null,
        'detail', case when v_sess is null then 'Settings → Sessions' else '' end),
      jsonb_build_object('key','classes','label','Classes created',
        'done', v_n_classes > 0, 'detail', v_n_classes || ' class(es)'),
      jsonb_build_object('key','sections','label','Sections created',
        'done', v_n_sections > 0, 'detail', v_n_sections || ' section(s)'),
      jsonb_build_object('key','feeheads','label','Fee heads created',
        'done', v_n_heads > 0,
        'detail', case when v_n_heads = 0
                       then 'Nothing to charge for yet: Settings → Fee Heads'
                       else v_n_heads || ' active' end),
      jsonb_build_object('key','prices','label','Fee amounts set per class',
        'done', v_n_priced > 0,
        'detail', v_n_priced || ' of ' || v_n_classes || ' class(es) priced'),
      jsonb_build_object('key','students','label','Students admitted',
        'done', v_n_students > 0, 'detail', v_n_students || ' on roll'),
      jsonb_build_object('key','staff','label','Staff added',
        'done', v_n_staff > 0, 'detail', v_n_staff || ' on the books'),
      jsonb_build_object('key','billed','label','A month has been billed',
        'done', v_billed,
        'detail', case when v_billed then '' else 'Fees → Generate challans' end),
      jsonb_build_object('key','collected','label','A payment has been taken',
        'done', v_last_pay is not null,
        'detail', case when v_last_pay is null then ''
                       else 'last on ' || v_last_pay::text end)
    );

  select * into v_disc from public.fn__discount_live(p_school_id, null);
  if v_disc.code is not null then
    v_disc_block := jsonb_build_object(
      'code', v_disc.code,
      'label', v_disc.label,
      'description', (select description from public.discount_codes where code = v_disc.code),
      'kind', v_disc.kind, 'value', v_disc.value,
      'duration', v_disc.duration, 'ends_on', v_disc.ends_on,
      'months_left', v_disc.months_left, 'months_total', v_disc.months_total,
      'times_applied', v_disc.times_applied,
      'total_saved', v_disc.total_saved,
      'granted_by_kind', v_disc.granted_by_kind,
      'grant_reason', v_disc.grant_reason,
      'redeemed_at', v_disc.redeemed_at,
      'summary', public.fn__discount_sentence(v_disc.kind, v_disc.value, v_disc.duration,
                                              v_disc.months_left, v_disc.ends_on));
  end if;

  return jsonb_build_object(
    'school', jsonb_build_object(
      'id', v_school.id, 'name', v_school.name, 'city', v_school.city,
      'contact_name', v_school.contact_name, 'contact_phone', v_school.contact_phone,
      'contact_email', v_school.contact_email, 'notes', v_school.notes,
      'active', v_school.active, 'created_at', v_school.created_at,
      -- From school_settings, which is what the school itself maintains, so a
      -- mismatch with the signup details above is itself informative.
      'display_name', v_settings.name, 'address', v_settings.address,
      'phone', v_settings.phone, 'principal_name', v_settings.principal_name,
      'has_logo', v_settings.logo_path is not null),

    'subscription', public.fn__subscription_view(p_school_id, true),

    'licence', case when v_sub.plan_code is null then 'null'::jsonb else
      jsonb_build_object(
        'plan_code', v_sub.plan_code, 'plan_name', v_plan.name,
        'status', v_status, 'cycle', v_sub.cycle,
        'expires_on', v_expiry,
        'days_left', case when v_expiry is null then null else v_expiry - current_date end,
        'student_count', v_sub.student_count,
        -- 0128: WHAT THEY ARE ALLOWED, not what the price list says. An
        -- allowance an operator granted is the whole point of this
        -- migration, and a console showing the plan's number instead
        -- would have the operator grant it twice.
        'student_limit', public.fn__student_limit(p_school_id),
        'plan_student_limit', v_plan.student_limit,
        'limit_override', v_sub.student_limit_override,
        'limit_override_reason', v_sub.student_limit_override_reason,
        'limit_override_at', v_sub.student_limit_override_at,
        -- Who granted it, by name, because "who agreed to this?" is the
        -- first question asked about an exception six months later.
        'limit_override_by', (select pr.full_name from public.profiles pr
                               where pr.id = v_sub.student_limit_override_by),
        -- The request waiting, if there is one. An operator granting from
        -- this page instead of the queue is otherwise granting blind.
        'limit_request', (select jsonb_build_object(
                                   'id', r.id, 'requested_limit', r.requested_limit,
                                   'reason', r.reason, 'wants', r.wants,
                                   'requested_at', r.requested_at)
                            from public.student_limit_requests r
                           where r.school_id = p_school_id
                             and r.status = 'pending'),
        'margin_limit', v_margin,
        'counted_at', v_sub.counted_at,
        'over_limit_since', v_sub.over_limit_flagged_at,
        'limit_state', case          when public.fn__student_limit(p_school_id) is null then 'ok'
          when v_sub.student_count
                 <= public.fn__student_limit(p_school_id) then 'ok'
          else 'over' end,
        'limit_override_until', v_sub.student_limit_override_until,
        'suggested_plan', public.fn__plan_for_students(v_sub.student_count)) end,

    'money', jsonb_build_object(
      'invoiced', v_invoiced, 'paid', v_paid, 'outstanding', v_invoiced - v_paid,
      'last_paid_on', (select max(paid_on) from public.platform_payments
                        where school_id = p_school_id),
      'invoice_count', (select count(*) from public.platform_invoices
                         where school_id = p_school_id
                           and kind = 'invoice' and voided_at is null)),

    -- The school's own logins. NOT the children: see the header.
    --
    -- ever_signed_in is the churn signal that nothing in this product could see
    -- before: a school with one login that has not been used in three weeks is
    -- leaving, and an accountant who was invited and never signed in is a seat
    -- somebody is not using and probably does not know about.
    'discount', v_disc_block,

    'people', coalesce((
      select jsonb_agg(jsonb_build_object(
               'name', pr.full_name, 'role', pr.role, 'active', pr.active,
               'added_on', pr.created_at,
               'ever_signed_in', u.last_sign_in_at is not null,
               'last_sign_in', u.last_sign_in_at)
             order by pr.role, pr.full_name)
        from public.profiles pr
        left join auth.users u on u.id = pr.id
       where pr.school_id = p_school_id and pr.role <> 'parent'), '[]'::jsonb),

    'counts', jsonb_build_object(
      'classes', v_n_classes, 'sections', v_n_sections, 'fee_heads', v_n_heads,
      'classes_priced', v_n_priced, 'students', v_n_students, 'staff', v_n_staff,
      'families', v_n_families, 'parents_linked', v_n_parents),

    'readiness', v_ready,

    -- Is anybody actually using it? Dates only, one per module. A school whose
    -- last attendance was in April is not using attendance, whatever the roll
    -- says.
    'activity', jsonb_build_object(
      'last_payment',     (select max(created_at) from public.payments
                            where school_id = p_school_id and status = 'verified'),
      'last_invoice',     (select max(created_at) from public.invoices
                            where school_id = p_school_id),
      'last_attendance',  (select max(attendance_date) from public.attendance_daily
                            where school_id = p_school_id),
      'last_mark',        (select max(created_at) from public.mark_entries
                            where school_id = p_school_id),
      'last_certificate', (select max(issued_on) from public.certificates
                            where school_id = p_school_id)),

    -- Stated rather than silently absent. "Has a challan been printed" is the
    -- one readiness question this schema cannot answer: printing happens in the
    -- browser and nothing records it. Saying so beats a checklist row that is
    -- quietly always false, which would send the operator chasing a step the
    -- school had already done.
    'not_recorded', jsonb_build_array(
      'whether a challan was ever printed: printing is a browser action and '
      || 'nothing records it')
  );
end;
$function$;


-- A trial's "Start again" keeps the school's account with us.
CREATE OR REPLACE FUNCTION public.fn_reset_school_data(p_confirm_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_school uuid := public.current_school_id();
  v_name   text;
  v_status public.subscription_status;
  -- Ours, not theirs. Never cleared by a school.
  v_keep   text[] := array[
    'subscriptions', 'school_settings', 'profiles', 'audit_log', 'reviews',
    'operator_actions', 'operator_sessions', 'platform_invoices',
    'platform_payments', 'platform_payment_claims', 'platform_exports',
    -- 0156: what we billed, what was paid against it, and what discounts a
    -- school was given and used. "Start again" clears the school's records,
    -- never its account with us, so a trial code cannot be redeemed twice.
    'platform_payment_allocations', 'discount_codes', 'subscription_discounts',
    'discount_applications', 'discount_events', 'billing_attempts',
    'payment_methods', 'payment_method_tokens'
  ];
  v_tables text[];
  v_t      text;
  v_before bigint;
  v_after  bigint;
  v_pass   int := 0;
  v_left   text[];
  v_total  bigint := 0;
  v_n      bigint;
begin
  if not public.has_role('owner') then
    raise exception 'Only the owner may clear the school''s data';
  end if;

  select s.name into v_name from public.schools s where s.id = v_school;
  select sub.status into v_status from public.subscriptions sub where sub.school_id = v_school;

  if v_status is distinct from 'trialing' then
    raise exception 'This is only available during the free trial. Ask us if you '
                    'really need to start again.';
  end if;

  -- Typing the school's name is the whole confirmation. A dialog that only
  -- needs one click gets clicked.
  if btrim(lower(coalesce(p_confirm_name, ''))) <> btrim(lower(coalesce(v_name, ''))) then
    raise exception 'Type the school''s name exactly to confirm';
  end if;

  select array_agg(c.relname order by c.relname) into v_tables
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attname = 'school_id' and a.attnum > 0
   where n.nspname = 'public' and c.relkind = 'r'
     and not (c.relname = any(v_keep));

  -- Count what is about to go, for the message afterwards.
  foreach v_t in array v_tables loop
    execute format('select count(*) from public.%I where school_id = $1', v_t)
      into v_n using v_school;
    v_total := v_total + v_n;
  end loop;

  -- The fixpoint. Ten passes is far more than the dependency depth of this
  -- schema; the check below is what actually decides whether it worked.
  -- 0129: A WHOLESALE CLEAR IS NOT A MISTAKE. The BEFORE DELETE trigger on
  -- assessments, exam_subjects and exam_terms refuses any delete that would
  -- destroy a finalised mark, and the loop below reaches assessments long
  -- before mark_entries. set local, so it cannot outlive this transaction.
  perform set_config('app.clearing_school', 'on', true);
  loop
    v_pass := v_pass + 1;
    v_before := 0; v_after := 0;
    foreach v_t in array v_tables loop
      execute format('select count(*) from public.%I where school_id = $1', v_t)
        into v_n using v_school;
      v_before := v_before + v_n;
      begin
        execute format('delete from public.%I where school_id = $1', v_t) using v_school;
      exception when foreign_key_violation then
        -- Something else still points at these rows. A later pass will have
        -- removed it.
        null;
      end;
      execute format('select count(*) from public.%I where school_id = $1', v_t)
        into v_n using v_school;
      v_after := v_after + v_n;
    end loop;
    exit when v_after = 0 or v_after = v_before or v_pass >= 10;
  end loop;

  -- Prove it, rather than assume it. A half-cleared school is worse than an
  -- uncleared one, because the owner believes it is empty.
  v_left := array[]::text[];
  foreach v_t in array v_tables loop
    execute format('select count(*) from public.%I where school_id = $1', v_t)
      into v_n using v_school;
    if v_n > 0 then v_left := v_left || v_t; end if;
  end loop;

  if array_length(v_left, 1) > 0 then
    raise exception 'Could not clear everything: % still has rows. Nothing has been '
                    'left half done on purpose; please tell us.', array_to_string(v_left, ', ');
  end if;

  perform public.fn__log_operator_action('school.data_reset', v_school,
    jsonb_build_object('school', v_name, 'rows_removed', v_total, 'passes', v_pass));

  return jsonb_build_object('cleared', true, 'rows_removed', v_total, 'school', v_name);
end;
$function$;


do $assert$
begin
  if to_regclass('public.discount_applications') is null
     or to_regclass('public.discount_events') is null
     or to_regprocedure('public.fn_my_redeem_code(text,boolean)') is null
     or to_regprocedure('public.fn_platform_create_discount(jsonb)') is null then
    raise warning '0156 did not fully apply: discount codes are still counted the old way';
  end if;
end $assert$;
