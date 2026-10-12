-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0155_three_plans_and_paying_first.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0155. Three plans, and access that runs on what is paid.
--
-- THE PRICE LIST
--   Starter      up to 280 pupils     Rs 2,000 a month, Rs 5,400 for three
--                                     months (10% off), Rs 20,000 a year (two
--                                     months free)
--   Growth       up to 1,000 pupils   Rs 4,000 a month, Rs 10,800 for three
--                                     months, Rs 40,000 a year
--   Enterprise   more than 1,000      priced with each school by us. We set the
--                                     monthly figure; three months is 10% off
--                                     and a year is two months free unless we
--                                     set those too. No pupil limit.
--
-- WHAT WAS WRONG, AND WHAT THIS DOES ABOUT IT
--   * Access was bought by INVOICING. fn_activate_subscription pushed the
--     licence forward the moment it raised an invoice, so an unpaid school
--     never locked. Now a payment is allocated to an invoice, an invoice is
--     paid when its money is in, and only paid term invoices extend the
--     licence. Unpaid fourteen days after the due date, the school locks.
--   * A negotiated price was stored nowhere, so a by-arrangement school was
--     renewed for Rs 0 and told it owed Rs 0. The agreed price now lives on
--     the school's subscription and every reader asks one function for it.
--   * Two limit rules: the gate stopped at 100% while plan choice, renewals
--     and the console reasoned with a hidden 10% margin and ignored extra room
--     we had granted. There is one rule now: the limit is the limit.
--   * Extra room never ended. It now ends at the next renewal, and a plan
--     change clears it.
--   * Reinstating an expired trial gave free access for ever (period_end
--     NULL fell through to the stored status). A school with no date that
--     covers today is now locked, whatever its stored status says.
--   * A plan change happened in the same call as an invoice, at full price,
--     with no pro-rata. Plans now move only by us, with a suggested charge we
--     can accept or change.
--   * Signup could not express a large school. It now asks how many pupils
--     the school has and the plan follows from the number.
--   * Four helpers answered for ANY school to ANY signed-in user. Revoked.
--   * Confirming a payment report twice at the same moment recorded two
--     payments. The report row is now locked first.
--
-- Discount codes are rebuilt in 0156. This migration gives them one place to
-- plug in (fn__discount_for_quote and its partners), which return nothing
-- until 0156 replaces them.
--
-- Prices are data. Older migrations (0028, 0111) re-seed public.plans if they
-- are pasted again; verify.sql checks the price list against this one.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. THE PRICE LIST
-- -----------------------------------------------------------------------------

alter table public.plans add column if not exists min_students integer not null default 1;
alter table public.plans add column if not exists by_arrangement boolean not null default false;

comment on column public.plans.min_students is
  'The smallest roll this plan is offered to at signup. Starter 1, Growth 281, '
  'Enterprise 1,001. The plan a school signs up on follows from its number.';
comment on column public.plans.by_arrangement is
  'True when there is no list price: the price is agreed with each school and '
  'stored on its subscription (agreed_monthly and friends). Such a plan has '
  'zero list prices and no pupil limit.';

-- Every change to the price list is written down: who, when, before and after.
-- Prices still move only by migration; this makes the move visible.
create table if not exists public.plan_changes (
  id          bigint generated always as identity primary key,
  code        text not null,
  op          text not null check (op in ('INSERT', 'UPDATE', 'DELETE')),
  before      jsonb,
  after       jsonb,
  changed_by  uuid,
  changed_as  text not null default current_user,
  changed_at  timestamptz not null default now()
);
alter table public.plan_changes enable row level security;
alter table public.plan_changes force row level security;
revoke all on public.plan_changes from public, anon, authenticated;

-- WHO, said truthfully. This trigger runs as its owner, so current_user (the
-- column default) always read 'postgres' and every change looked like a
-- migration. The role a request runs as is the 'role' setting (service_role,
-- authenticated) and otherwise the login itself.
create or replace function public.fn__log_plan_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.plan_changes (code, op, before, after, changed_by, changed_as)
  values (coalesce(new.code, old.code), tg_op,
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end,
          auth.uid(),
          coalesce(nullif(current_setting('role', true), 'none'), session_user));
  return coalesce(new, old);
end;
$$;
revoke all on function public.fn__log_plan_change() from public, anon, authenticated;

drop trigger if exists trg_log_plan_change on public.plans;
create trigger trg_log_plan_change
  after insert or update or delete on public.plans
  for each row execute function public.fn__log_plan_change();

-- The log is append-only for everyone the API can be: the service role
-- bypasses row security and could otherwise rewrite or erase a price change.
create or replace function public.fn__plan_changes_append_only()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  raise exception 'The price list log is append-only' using errcode = '42501';
end;
$$;
revoke all on function public.fn__plan_changes_append_only() from public, anon, authenticated;
drop trigger if exists trg_plan_changes_append_only on public.plan_changes;
create trigger trg_plan_changes_append_only
  before update or delete on public.plan_changes
  for each row execute function public.fn__plan_changes_append_only();
do $svc$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'revoke update, delete, truncate on public.plan_changes from service_role';
  end if;
end $svc$;

insert into public.plans
  (code, name, student_limit, price_monthly, price_quarterly, price_yearly,
   sort_order, active, min_students, by_arrangement)
values
  ('starter',    'Starter',     280, 2000,  5400, 20000, 1, true,    1, false),
  ('growth',     'Growth',     1000, 4000, 10800, 40000, 2, true,  281, false),
  ('enterprise', 'Enterprise', null,    0,     0,     0, 3, true, 1001, true)
on conflict (code) do update
  set name            = excluded.name,
      student_limit   = excluded.student_limit,
      price_monthly   = excluded.price_monthly,
      price_quarterly = excluded.price_quarterly,
      price_yearly    = excluded.price_yearly,
      sort_order      = excluded.sort_order,
      active          = excluded.active,
      min_students    = excluded.min_students,
      by_arrangement  = excluded.by_arrangement;

-- Retired, not deleted: old invoices name them (platform_invoices.plan_code
-- references plans). Nobody can sign up on them or be moved onto them.
update public.plans
   set active = false,
       sort_order = 90,
       by_arrangement = false
 where code = 'institution';
update public.plans
   set active = false,
       sort_order = 91,
       by_arrangement = true,
       student_limit = null,
       price_monthly = 0, price_quarterly = 0, price_yearly = 0
 where code = 'custom';

-- The shape of a price. Kept to what is true of every row ever seeded, so an
-- old migration pasted again cannot trip it; the exact figures are checked by
-- verify.sql.
alter table public.plans drop constraint if exists plans_price_shape_chk;
alter table public.plans add constraint plans_price_shape_chk check (
  price_monthly >= 0 and price_quarterly >= 0 and price_yearly >= 0
  and price_monthly = round(price_monthly)
  and price_quarterly = round(price_quarterly)
  and price_yearly = round(price_yearly)
  and min_students >= 1
  and (student_limit is null or student_limit >= 1)
  and (not by_arrangement
       or (price_monthly = 0 and price_quarterly = 0 and price_yearly = 0
           and student_limit is null)));


-- -----------------------------------------------------------------------------
-- 2. WHAT EACH SCHOOL HAS
-- -----------------------------------------------------------------------------

alter table public.subscriptions
  add column if not exists declared_students integer,
  add column if not exists agreed_monthly numeric(12,2),
  add column if not exists agreed_quarterly numeric(12,2),
  add column if not exists agreed_yearly numeric(12,2),
  add column if not exists agreed_reason text,
  add column if not exists agreed_by uuid,
  add column if not exists agreed_at timestamptz,
  add column if not exists student_limit_override_until date,
  add column if not exists oldest_unpaid_due_on date,
  add column if not exists closed_from date;

comment on column public.subscriptions.declared_students is
  'The number of pupils the school said it has when it signed up. Its plan '
  'followed from this number.';
comment on column public.subscriptions.agreed_monthly is
  'Enterprise only: the monthly price we agreed with this school. NULL means '
  'not priced yet; such a school locks when its trial ends.';
comment on column public.subscriptions.agreed_quarterly is
  'Enterprise only: three months, when we agreed a figure of its own. NULL '
  'means three months of agreed_monthly less 10%.';
comment on column public.subscriptions.agreed_yearly is
  'Enterprise only: a year, when we agreed a figure of its own. NULL means ten '
  'months of agreed_monthly (two months free).';
comment on column public.subscriptions.student_limit_override_until is
  'Extra room ends after this day: the end of the period that was running '
  'when it was granted. A plan change clears it.';
comment on column public.subscriptions.closed_from is
  'A school that asked to stop and came back after its period ended: it had '
  'no access from this day, so it used no grace and is locked until it pays, '
  'billed from the day it pays. Cleared once a paid period reaches it.';
comment on column public.subscriptions.oldest_unpaid_due_on is
  'Kept by fn__recompute_licence: the due date of the oldest invoice with '
  'money still owed on it. Fourteen days after it, the school locks.';
comment on column public.subscriptions.period_end is
  'PAID THROUGH. The last day covered by term invoices that have been paid in '
  'full, in order. Raising an invoice does not move it; paying one does. '
  'Voiding the invoice that paid for it takes it back.';

-- ACCESS GIVEN WITHOUT AN INVOICE. Paid-through comes from paid invoices, with
-- one floor: dates that were GIVEN. Two things give dates:
--   * the old rules. Before this migration raising an invoice moved period_end
--     whether or not it was paid. Those schools keep what they were given: the
--     dates are copied here ONCE, in the statement that adds the columns, so a
--     second paste of this bundle (when period_end already comes from paid
--     invoices) never copies a paid date that a later void should take away;
--   * a person editing period_end in the table by hand, which is how an owner
--     who knows the Supabase editor gives a school time. The trigger below
--     records it here, so the next payment does not silently undo it.
-- fn__recompute_licence never lets paid-through fall below these dates, and
-- marks its own writes so the trigger leaves them alone. Voiding the invoice
-- that opened a school under the old rules takes its dates away
-- (fn__void_invoice); setting period_end to empty by hand does the same.
do $given$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'subscriptions'
                    and column_name = 'given_through') then
    alter table public.subscriptions
      add column given_from date,
      add column given_through date;
    update public.subscriptions
       set given_from = period_start, given_through = period_end
     where period_end is not null;
  end if;
end $given$;
comment on column public.subscriptions.given_through is
  'Access given without a paid invoice: the paid-through date a school had '
  'under the rules before 0155, or one set by hand in the table. Paid-through '
  'never falls below it. Voiding the invoice that opened it clears it.';

create or replace function public.fn__period_set_by_hand()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(current_setting('app.licence_recompute', true), '') = 'on' then
    return new;
  end if;
  if tg_op = 'INSERT' or new.period_end is distinct from old.period_end
     or new.period_start is distinct from old.period_start then
    new.given_from    := new.period_start;
    new.given_through := new.period_end;
  end if;
  return new;
end;
$$;
revoke all on function public.fn__period_set_by_hand() from public, anon, authenticated;
drop trigger if exists trg_period_set_by_hand on public.subscriptions;
create trigger trg_period_set_by_hand
  before insert or update of period_start, period_end on public.subscriptions
  for each row execute function public.fn__period_set_by_hand();

-- Retired plans: nobody stays on them.
update public.subscriptions set plan_code = 'growth'     where plan_code = 'institution';
update public.subscriptions set plan_code = 'enterprise' where plan_code = 'custom';

-- One, three or twelve months are the only terms sold.
update public.subscriptions
   set term_months = case when term_months >= 12 then 12
                          when term_months >= 3 then 3 else 1 end
 where term_months not in (1, 3, 12);
update public.subscriptions
   set cycle = public.fn__cycle_for_months(term_months)
 where cycle is distinct from public.fn__cycle_for_months(term_months);

-- Extra room granted before this change ends with the period it was given in.
update public.subscriptions
   set student_limit_override_until =
         coalesce(period_end, trial_ends_on,
                  (now() at time zone 'Asia/Karachi')::date)
 where student_limit_override is not null
   and student_limit_override_until is null;
update public.subscriptions
   set student_limit_override_until = null
 where student_limit_override is null
   and student_limit_override_until is not null;

alter table public.subscriptions drop constraint if exists subscriptions_term_sold_chk;
alter table public.subscriptions add constraint subscriptions_term_sold_chk
  check (term_months in (1, 3, 12));

alter table public.subscriptions drop constraint if exists subscriptions_declared_chk;
alter table public.subscriptions add constraint subscriptions_declared_chk
  check (declared_students is null or declared_students between 1 and 100000);

alter table public.subscriptions drop constraint if exists subscriptions_agreed_chk;
alter table public.subscriptions add constraint subscriptions_agreed_chk check (
  (agreed_monthly is null and agreed_quarterly is null and agreed_yearly is null)
  or (agreed_monthly > 0 and agreed_monthly = round(agreed_monthly)
      and (agreed_quarterly is null
           or (agreed_quarterly > 0 and agreed_quarterly = round(agreed_quarterly)
               and agreed_quarterly <= 3 * agreed_monthly))
      and (agreed_yearly is null
           or (agreed_yearly > 0 and agreed_yearly = round(agreed_yearly)
               and agreed_yearly <= 12 * agreed_monthly))
      and btrim(coalesce(agreed_reason, '')) <> ''));

-- Extra room set without an end date (by hand, or by an older function) ends
-- with the period that covers the school today, like any other.
create or replace function public.fn__override_until_default()
returns trigger
language plpgsql
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
begin
  if new.student_limit_override is null then
    new.student_limit_override_until := null;
  elsif new.student_limit_override_until is null
        -- New room with the old end date left in place (set by hand, or by an
        -- older grant that sets only the number) would be dead on arrival.
        or (tg_op = 'UPDATE'
            and new.student_limit_override is distinct from old.student_limit_override
            and new.student_limit_override_until is not distinct from old.student_limit_override_until
            and new.student_limit_override_until < current_date) then
    new.student_limit_override_until :=
      greatest(coalesce(greatest(new.period_end, new.trial_ends_on), current_date), current_date);
  end if;
  return new;
end;
$$;
revoke all on function public.fn__override_until_default() from public, anon, authenticated;
drop trigger if exists trg_override_until_default on public.subscriptions;
create trigger trg_override_until_default
  before insert or update on public.subscriptions
  for each row execute function public.fn__override_until_default();

-- grace_ends_on was written by the old activation and read by nothing, so after
-- this migration it would sit in the table showing a date from before it. It
-- is kept, because an older bundle pasted again compares it on every update,
-- and made true instead: the last day of grace on what covers the school now,
-- worked out from the row itself so it cannot drift. Nothing decides access
-- from it (fn_effective_status works it out the same way, and also locks on a
-- debt); it is there for whoever reads the table in the Supabase editor.
create or replace function public.fn__grace_ends_from_row()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.grace_ends_on := greatest(new.period_end, new.trial_ends_on)
                       + coalesce(new.grace_days_override, public.grace_days());
  return new;
end;
$$;
revoke all on function public.fn__grace_ends_from_row() from public, anon, authenticated;
drop trigger if exists trg_grace_ends_from_row on public.subscriptions;
create trigger trg_grace_ends_from_row
  before insert or update on public.subscriptions
  for each row execute function public.fn__grace_ends_from_row();
comment on column public.subscriptions.grace_ends_on is
  'The last day of grace after what covers the school now (paid period or '
  'trial), set from the row by trg_grace_ends_from_row. Informational: access '
  'is decided by fn_effective_status, which also locks on a debt.';
update public.subscriptions
   set grace_ends_on = greatest(period_end, trial_ends_on)
                       + coalesce(grace_days_override, public.grace_days())
 where grace_ends_on is distinct from greatest(period_end, trial_ends_on)
                       + coalesce(grace_days_override, public.grace_days());

alter table public.subscriptions drop constraint if exists subscriptions_override_until_chk;
alter table public.subscriptions add constraint subscriptions_override_until_chk
  check ((student_limit_override is null) = (student_limit_override_until is null));

-- The row now carries an agreed price. Staff who are not the owner or the
-- principal have no business reading it, and nothing on their screens does.
drop policy if exists subscriptions_select_own on public.subscriptions;
create policy subscriptions_select_own on public.subscriptions
  for select to authenticated
  using (school_id = public.current_school_id()
         and public.may_view('owner'::public.user_role, 'principal'::public.user_role));


-- -----------------------------------------------------------------------------
-- 3. INVOICES SAY WHAT THEY WERE FOR, AND MONEY SAYS WHICH INVOICE IT PAID
-- -----------------------------------------------------------------------------

alter table public.platform_invoices
  add column if not exists purpose text not null default 'term',
  add column if not exists plan_name text,
  add column if not exists discount_code text,
  add column if not exists discount_amount numeric(12,2) not null default 0,
  add column if not exists set_by_hand boolean not null default false,
  add column if not exists hand_reason text;

comment on column public.platform_invoices.set_by_hand is
  'We raised this invoice with a decision of our own: an amount typed by hand, '
  'a reason, or invoicing a school over its limit on purpose. Nothing the '
  'school does (changing its term, using a code) voids it.';
comment on column public.platform_invoices.hand_reason is
  'The reason we gave when we raised it, carried to its replacement if we '
  'reissue it, so a decision such as invoicing over the limit survives.';

comment on column public.platform_invoices.purpose is
  'term: pays for a period of the licence and extends it once paid. '
  'plan_change: the difference charged when we moved the school to another '
  'plan part way through a paid period. It never extends the licence, but '
  'leaving it unpaid locks the school like any other unpaid invoice.';
comment on column public.platform_invoices.plan_name is
  'The plan''s name on the day the invoice was raised, so renaming a plan '
  'never rewrites an old invoice.';

alter table public.platform_invoices drop constraint if exists platform_invoices_purpose_chk;
alter table public.platform_invoices add constraint platform_invoices_purpose_chk
  check (purpose in ('term', 'plan_change'));
alter table public.platform_invoices drop constraint if exists platform_invoices_discount_chk;
alter table public.platform_invoices add constraint platform_invoices_discount_chk
  check (discount_amount >= 0 and (discount_amount = 0 or discount_code is not null));

update public.platform_invoices i
   set plan_name = p.name
  from public.plans p
 where p.code = i.plan_code and i.plan_name is null;

-- New invoices are in whole rupees. The schools pay in whole rupees, and an
-- invoice of Rs 1,599.50 is one that a Rs 1,600 transfer pays and a Rs 1,599
-- transfer leaves owing fifty paisa, which then locks the school.
create or replace function public.fn__whole_rupee_invoice()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.kind = 'invoice' and new.amount <> round(new.amount) then
    raise exception 'An invoice is in whole rupees, and this one says %', new.amount
      using errcode = '22023';
  end if;
  if new.plan_name is null then
    select name into new.plan_name from public.plans where code = new.plan_code;
  end if;
  return new;
end;
$$;
revoke all on function public.fn__whole_rupee_invoice() from public, anon, authenticated;

drop trigger if exists trg_whole_rupee_invoice on public.platform_invoices;
create trigger trg_whole_rupee_invoice
  before insert on public.platform_invoices
  for each row execute function public.fn__whole_rupee_invoice();

-- THE LINK BETWEEN MONEY AND INVOICES. platform_payments.invoice_id named one
-- invoice a payment was recorded against and nothing ever read it to decide
-- anything. This table is the record of which invoice each rupee paid, written
-- only by fn__apply_credit, under locks, so a payment is never spent twice and
-- an invoice is never paid twice over.
create table if not exists public.platform_payment_allocations (
  id          uuid primary key default gen_random_uuid(),
  payment_id  uuid not null references public.platform_payments(id) on delete cascade,
  invoice_id  uuid not null references public.platform_invoices(id) on delete cascade,
  school_id   uuid references public.schools(id) on delete set null,
  amount      numeric(12,2) not null check (amount > 0),
  created_at  timestamptz not null default now(),
  created_by  uuid
);
create index if not exists idx_ppa_invoice on public.platform_payment_allocations (invoice_id);
create index if not exists idx_ppa_payment on public.platform_payment_allocations (payment_id);
create index if not exists idx_ppa_school  on public.platform_payment_allocations (school_id);
alter table public.platform_payment_allocations enable row level security;
alter table public.platform_payment_allocations force row level security;
revoke all on public.platform_payment_allocations from public, anon, authenticated;

-- What was paid against an invoice before this change: the invoice a payment
-- was recorded against, up to what that invoice still owed. Payments naming
-- the same invoice take their turn in the order they were paid, each taking
-- only what the ones before it left, so two payments against one invoice never
-- pay it twice: the excess stays unallocated and fn__apply_credit (section 18)
-- carries it to the next invoice. A second paste counts what is already
-- allocated to the invoice before giving anything more.
insert into public.platform_payment_allocations (payment_id, invoice_id, school_id, amount, created_by)
select t.payment_id, t.invoice_id, t.school_id,
       least(t.settled, greatest(t.room - t.before, 0)), t.created_by
  from (
    select pm.id as payment_id, pm.invoice_id, pm.school_id, pm.settled, pm.created_by,
           greatest(i.amount + i.tax_amount
                    - coalesce((select sum(c.amount + c.tax_amount)
                                  from public.platform_invoices c
                                 where c.credits_invoice_id = i.id
                                   and c.voided_at is null), 0)
                    - coalesce((select sum(a.amount)
                                  from public.platform_payment_allocations a
                                 where a.invoice_id = i.id), 0), 0) as room,
           coalesce(sum(pm.settled) over (
             partition by pm.invoice_id
             order by pm.paid_on, pm.created_at, pm.id
             rows between unbounded preceding and 1 preceding), 0) as before
      from public.platform_payments pm
      join public.platform_invoices i on i.id = pm.invoice_id
     where i.voided_at is null
       and i.kind = 'invoice'
       and not exists (select 1 from public.platform_payment_allocations a
                        where a.payment_id = pm.id)
  ) t
 where least(t.settled, greatest(t.room - t.before, 0)) > 0;


-- -----------------------------------------------------------------------------
-- 4. HOW MUCH IS OWED ON AN INVOICE
-- -----------------------------------------------------------------------------

-- Money in against one invoice: what was allocated to it plus the credit notes
-- raised against it. A credit note is how we honour something after the fact,
-- so it settles the invoice exactly as a payment would.
create or replace function public.fn__invoice_settled(p_invoice_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select sum(a.amount) from public.platform_payment_allocations a
                    where a.invoice_id = p_invoice_id), 0)
       + coalesce((select sum(c.amount + c.tax_amount) from public.platform_invoices c
                    where c.credits_invoice_id = p_invoice_id
                      and c.voided_at is null), 0);
$$;

-- What is still owed. Less than one rupee is nothing: schools pay in whole
-- rupees and tax can leave paisa, and paisa must never be what locks a school.
create or replace function public.fn__invoice_owed(p_invoice_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select case when i.kind <> 'invoice' or i.voided_at is not null then 0
              when (i.amount + i.tax_amount) - public.fn__invoice_settled(i.id) < 1 then 0
              else (i.amount + i.tax_amount) - public.fn__invoice_settled(i.id) end
    from public.platform_invoices i
   where i.id = p_invoice_id;
$$;

revoke all on function public.fn__invoice_settled(uuid) from public, anon, authenticated;
revoke all on function public.fn__invoice_owed(uuid) from public, anon, authenticated;

-- Money paid in and not yet against any invoice.
create or replace function public.fn__unallocated(p_school_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(pm.settled - coalesce((select sum(a.amount)
                                               from public.platform_payment_allocations a
                                              where a.payment_id = pm.id), 0)), 0)
    from public.platform_payments pm
   where pm.school_id = p_school_id;
$$;
revoke all on function public.fn__unallocated(uuid) from public, anon, authenticated;

-- ONE PAISA RULE FOR EVERY BALANCE. The licence counts less than a rupee owed
-- on an invoice as nothing; the statement, the outstanding figure and the
-- revenue report (all billed minus settled, through this function) went on
-- listing the school as owing 61 paisa it would never be asked for. Billed is
-- now net of those paisa, so every figure agrees with the licence.
create or replace function public.fn__platform_billed(p_school_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(i.net_total), 0)
       - coalesce(sum(case
           when i.kind = 'invoice'
            and (i.amount + i.tax_amount) - public.fn__invoice_settled(i.id) > 0
            and (i.amount + i.tax_amount) - public.fn__invoice_settled(i.id) < 1
           then (i.amount + i.tax_amount) - public.fn__invoice_settled(i.id) else 0 end), 0)
    from public.platform_invoices i
   where i.school_id = p_school_id and i.voided_at is null;
$$;
revoke all on function public.fn__platform_billed(uuid) from public, anon, authenticated;


-- -----------------------------------------------------------------------------
-- 5. THE LICENCE
-- -----------------------------------------------------------------------------

-- The day the school's access is covered to: the end of what it has paid for,
-- or the end of its trial if it has paid for nothing yet. NULL means nothing
-- covers it at all, which is a locked school.
create or replace function public.fn__coverage_end(p_school_id uuid)
returns date
language sql
stable
security definer
set search_path = public
as $$
  select greatest(s.period_end, s.trial_ends_on)
    from public.subscriptions s where s.school_id = p_school_id;
$$;

create or replace function public.fn__grace_for(p_school_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select s.grace_days_override from public.subscriptions s
                    where s.school_id = p_school_id), public.grace_days());
$$;

-- The last day of a term of p_months starting p_start: the day before the same
-- day of the month p_months later. When that day does not exist (a month that
-- starts on the 31st, a year from 29 February) the term runs to the end of the
-- shorter month and the next one starts on the 1st. Subtracting a day from
-- Postgres's clamped date instead made a month from 31 January end on 27
-- February: a full month's price for 28 days, and a billing day that crept.
create or replace function public.fn__term_end(p_start date, p_months integer)
returns date
language sql
immutable
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
  select case
    when extract(day from (p_start + make_interval(months => p_months))::date)
         < extract(day from p_start)
      then (p_start + make_interval(months => p_months))::date
    else (p_start + make_interval(months => p_months))::date - 1 end;
$$;

-- The first day the school is locked if nothing more is paid, leaving aside a
-- suspension or a cancellation: the end of what covers it plus its grace
-- (no grace for an Enterprise school with no price, which has nothing to pay
-- yet), or fourteen days after the oldest money owed falls due, whichever is
-- first. NULL when nothing covers the school at all.
create or replace function public.fn__lock_day(p_school_id uuid)
returns date
language sql
stable
security definer
set search_path = public
as $$
  select case when greatest(s.period_end, s.trial_ends_on) is null then null
    else least(
      case when p.by_arrangement and s.agreed_monthly is null
           then greatest(s.period_end, s.trial_ends_on) + 1
           else greatest(s.period_end, s.trial_ends_on)
                + coalesce(s.grace_days_override, public.grace_days()) + 1 end,
      s.oldest_unpaid_due_on + coalesce(s.grace_days_override, public.grace_days()),
      case when s.closed_from is not null
                and (s.period_end is null or s.period_end < s.closed_from)
           then s.closed_from end)
    end
    from public.subscriptions s
    join public.plans p on p.code = s.plan_code
   where s.school_id = p_school_id;
$$;

-- An invoice is LAPSED when its own due date and grace have passed with money
-- still owed on it: the school locked instead of paying it. A Rs 0 invoice
-- owes nothing and so never lapses (a free month we gave stays given).
create or replace function public.fn__invoice_lapsed(p_invoice_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
  select coalesce((
    select i.kind = 'invoice' and i.purpose = 'term' and i.voided_at is null
           and i.due_on is not null
           and current_date >= i.due_on + public.fn__grace_for(i.school_id)
           and public.fn__invoice_owed(i.id) > 0
      from public.platform_invoices i where i.id = p_invoice_id), false);
$$;

-- Where the next period starts.
--   Not locked (covered, or inside its grace): straight after the covered
--   period, because the school is using those days.
--   Locked and coming back: the grace days it used after its covered period
--   ARE billed, and the days it was locked out are not. So the period starts
--   that many days before today. Starting it today instead made paying late
--   cheaper than paying on time: every lapse turned fourteen days of grace
--   into free days, about a month in four on a monthly term.
-- The days used are worked out from today's lock day. A school locked first by
-- an unpaid plan-change charge, which it paid only after its period ended, is
-- counted as having used its grace; that costs it at most the grace days and
-- needs a lock history to do better.
create or replace function public.fn__next_period_start(p_school_id uuid)
returns date
language plpgsql
stable
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare v_cov date := public.fn__coverage_end(p_school_id); v_lock date;
begin
  if v_cov is null then
    return current_date;
  end if;
  v_lock := public.fn__lock_day(p_school_id);
  if v_lock is null or current_date < v_lock then
    return v_cov + 1;
  end if;
  return greatest(v_cov + 1, current_date - greatest(0, v_lock - (v_cov + 1)));
end;
$$;

revoke all on function public.fn__coverage_end(uuid) from public, anon, authenticated;
revoke all on function public.fn__grace_for(uuid) from public, anon, authenticated;
revoke all on function public.fn__term_end(date, integer) from public, anon, authenticated;
revoke all on function public.fn__lock_day(uuid) from public, anon, authenticated;
revoke all on function public.fn__invoice_lapsed(uuid) from public, anon, authenticated;
revoke all on function public.fn__next_period_start(uuid) from public, anon, authenticated;

-- THE ONE ANSWER TO "MAY THIS SCHOOL WORK TODAY". Read by the write gate on
-- every tenant table, so it reads one row and two dates.
--   suspended by us                                  -> locked
--   cancelled, or cancelled at period end and over   -> cancelled
--   nothing covers it at all                         -> locked
--   money owed and fourteen days past its due date   -> locked
--   covered today                                    -> trialing / active
--   Enterprise past its trial with no price agreed   -> locked (nothing can
--                                                       be invoiced, so there
--                                                       is no payment to wait
--                                                       for)
--   within the grace after the covered period        -> grace
--   otherwise                                        -> locked
create or replace function public.fn_effective_status(p_school_id uuid)
returns public.subscription_status
language sql
stable
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
  select case
    when s.suspended_at is not null then 'locked'::public.subscription_status
    when s.status = 'cancelled' then 'cancelled'::public.subscription_status
    when s.cancel_at_period_end
         and greatest(s.period_end, s.trial_ends_on) is not null
         and current_date > greatest(s.period_end, s.trial_ends_on)
      then 'cancelled'::public.subscription_status
    when greatest(s.period_end, s.trial_ends_on) is null
      then 'locked'::public.subscription_status
    when s.closed_from is not null and current_date >= s.closed_from
         and (s.period_end is null or s.period_end < s.closed_from)
      then 'locked'::public.subscription_status
    when s.oldest_unpaid_due_on is not null
         and current_date >= s.oldest_unpaid_due_on
                             + coalesce(s.grace_days_override, public.grace_days())
      then 'locked'::public.subscription_status
    when current_date <= greatest(s.period_end, s.trial_ends_on)
      then case when s.status = 'trialing' then 'trialing'::public.subscription_status
                else 'active'::public.subscription_status end
    when p.by_arrangement and s.agreed_monthly is null
      then 'locked'::public.subscription_status
    when current_date <= greatest(s.period_end, s.trial_ends_on)
                         + coalesce(s.grace_days_override, public.grace_days())
      then 'grace'::public.subscription_status
    else 'locked'::public.subscription_status
  end
  from public.subscriptions s
  join public.plans p on p.code = s.plan_code
  where s.school_id = p_school_id;
$$;

-- Live term invoices are walked in order of the period they pay for. Each one
-- paid in full extends the covered block; the first one with money owed stops
-- the walk, so paying a later invoice never skips an earlier unpaid one. A
-- period that starts after a gap (a school that came back after locking)
-- starts a new block.
--
-- PAID-THROUGH COMES ONLY FROM WHAT IS PAID. The first version left the dates
-- alone when the walk found nothing paid, so voiding the only paid invoice
-- (or the credit note that settled it) kept a year of access backed by
-- nothing, and the school's next invoice then started after that year. Now
-- nothing paid means no paid period: coverage falls back to the trial, and a
-- school that had paid goes back to trialing. The one floor is access GIVEN
-- without an invoice (given_through: the old rules, or a date set by hand).
--
-- A term invoice is not a debt while the school's trial still runs: a trial
-- lengthened by a code after its first invoice was raised must not lock the
-- school as unpaid in the middle of the trial.
create or replace function public.fn__recompute_licence(p_school_id uuid)
returns void
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  s public.subscriptions; r record; v_start date; v_end date;
  v_paid_any boolean := false; v_due date; v_closed date;
  v_new_start date; v_new_end date; v_status public.subscription_status;
begin
  select * into s from public.subscriptions where school_id = p_school_id;
  if not found then
    return;
  end if;

  for r in
    select i.id, i.period_start, i.period_end
      from public.platform_invoices i
     where i.school_id = p_school_id and i.kind = 'invoice'
       and i.purpose = 'term' and i.voided_at is null
     order by i.period_start, i.created_at
  loop
    exit when public.fn__invoice_owed(r.id) > 0;
    v_paid_any := true;
    if v_end is null or r.period_start > v_end + 1 then
      v_start := r.period_start;
      v_end   := r.period_end;
    else
      v_end := greatest(v_end, r.period_end);
    end if;
  end loop;

  if v_paid_any then
    v_new_start := v_start;
    v_new_end   := v_end;
    if s.given_through is not null and s.given_through > v_end then
      v_new_start := least(v_start, coalesce(s.given_from, v_start));
      v_new_end   := s.given_through;
    end if;
  else
    v_new_start := s.given_from;
    v_new_end   := s.given_through;
  end if;

  select min(case when i.purpose = 'term' and s.trial_ends_on is not null
                  then greatest(i.due_on, s.trial_ends_on + 1)
                  else i.due_on end) into v_due
    from public.platform_invoices i
   where i.school_id = p_school_id and i.kind = 'invoice'
     and i.voided_at is null and i.due_on is not null
     and public.fn__invoice_owed(i.id) > 0;

  v_status := case
    when v_paid_any and s.status = 'trialing' then 'active'::public.subscription_status
    when not v_paid_any and v_new_end is null and s.status = 'active'
      then 'trialing'::public.subscription_status
    else s.status end;
  -- A school that came back after leaving is no longer closed once a paid
  -- period reaches the day it closed.
  v_closed := case when s.closed_from is not null and v_new_end is not null
                        and v_new_end >= s.closed_from then null
                   else s.closed_from end;

  -- Marked as ours, so trg_period_set_by_hand does not take it for a grant.
  perform set_config('app.licence_recompute', 'on', true);
  update public.subscriptions
     set period_start = v_new_start,
         period_end   = v_new_end,
         cycle        = public.fn__cycle_for_months(term_months),
         status       = v_status,
         oldest_unpaid_due_on = v_due,
         closed_from  = v_closed
   where school_id = p_school_id
     and (period_start is distinct from v_new_start
          or period_end is distinct from v_new_end
          or status is distinct from v_status
          or oldest_unpaid_due_on is distinct from v_due
          or closed_from is distinct from v_closed
          or cycle is distinct from public.fn__cycle_for_months(term_months));
  perform set_config('app.licence_recompute', '', true);
end;
$$;
revoke all on function public.fn__recompute_licence(uuid) from public, anon, authenticated;

-- Unallocated money goes to invoices with money owed: the one named first,
-- then the oldest due. The school's subscription row is the lock every money
-- writer takes, so two of these for one school run one after the other.
create or replace function public.fn__apply_credit(p_school_id uuid, p_prefer uuid default null)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  pm record; inv record; v_free numeric; v_take numeric; v_total numeric := 0;
begin
  perform 1 from public.subscriptions where school_id = p_school_id for update;

  for pm in
    select p.id, p.settled - coalesce((select sum(a.amount)
                                         from public.platform_payment_allocations a
                                        where a.payment_id = p.id), 0) as free
      from public.platform_payments p
     where p.school_id = p_school_id
     order by p.paid_on, p.created_at
  loop
    v_free := pm.free;
    continue when v_free <= 0;
    for inv in
      select i.id, public.fn__invoice_owed(i.id) as owed
        from public.platform_invoices i
       where i.school_id = p_school_id and i.kind = 'invoice'
         and i.voided_at is null
       order by (i.id = p_prefer) desc nulls last, i.due_on nulls last,
                i.period_start, i.serial
    loop
      continue when inv.owed <= 0;
      v_take := least(v_free, inv.owed);
      insert into public.platform_payment_allocations
        (payment_id, invoice_id, school_id, amount, created_by)
      values (pm.id, inv.id, p_school_id, v_take, auth.uid());
      v_free  := v_free - v_take;
      v_total := v_total + v_take;
      exit when v_free <= 0;
    end loop;
  end loop;

  perform public.fn__recompute_licence(p_school_id);
  return v_total;
end;
$$;
revoke all on function public.fn__apply_credit(uuid, uuid) from public, anon, authenticated;


-- -----------------------------------------------------------------------------
-- 6. THE PUPIL LIMIT: ONE RULE
-- -----------------------------------------------------------------------------

-- There is no margin. This function stays because older functions call it;
-- it now gives back the limit it is given.
create or replace function public.plan_margin_limit(p_limit integer)
returns integer
language sql
immutable
as $$ select p_limit $$;

-- Extra room while it runs, then the plan's own limit; NULL for Enterprise.
create or replace function public.fn__student_limit(p_school_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
  select case
    when p.student_limit is null then null
    when sub.student_limit_override is not null
         and sub.student_limit_override_until >= current_date
      then sub.student_limit_override
    else p.student_limit end
    from public.subscriptions sub
    join public.plans p on p.code = sub.plan_code
   where sub.school_id = p_school_id;
$$;

create or replace function public.fn_refresh_student_count(p_school_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  v_count integer; v_plan text; v_limit integer;
begin
  v_count := public.fn_count_students(p_school_id);
  select sub.plan_code into v_plan from public.subscriptions sub
   where sub.school_id = p_school_id;
  if v_plan is null then
    raise exception 'No subscription for school %', p_school_id;
  end if;
  v_limit := public.fn__student_limit(p_school_id);

  update public.subscriptions
     set student_count = v_count,
         counted_at    = now(),
         over_limit_flagged_at = case
           when v_limit is not null and v_count > v_limit
             then coalesce(over_limit_flagged_at, now())
           else null end
   where school_id = p_school_id;

  insert into public.student_count_snapshots
    (school_id, counted_on, student_count, plan_code, student_limit)
  values (p_school_id, current_date, v_count, v_plan, v_limit)
  on conflict (school_id, counted_on) do update
    set student_count = excluded.student_count,
        plan_code     = excluded.plan_code,
        student_limit = excluded.student_limit;

  return v_count;
end;
$$;

-- These four answered for any school to any signed-in user. Their callers are
-- SECURITY DEFINER functions and triggers, which keep them.
revoke execute on function public.fn_count_students(uuid) from public, anon, authenticated;
revoke execute on function public.fn_effective_status(uuid) from public, anon, authenticated;
revoke execute on function public.fn_refresh_student_count(uuid) from public, anon, authenticated;
revoke execute on function public.fn_refresh_all_student_counts() from public, anon, authenticated;

-- The logs are append-only for the API roles. Nothing reaches them through
-- PostgREST today; this keeps it that way whatever policy is added later.
revoke truncate, update, delete on public.audit_log from anon, authenticated;
revoke truncate, update, delete on public.operator_actions from anon, authenticated;


-- -----------------------------------------------------------------------------
-- 7. ONE PRICE, ONE QUOTE
-- -----------------------------------------------------------------------------

-- The list price of a term on a plan: one, three or twelve months, nothing
-- else. NULL for a plan priced by arrangement (it has no list price) and for
-- any other length. Kept under its old name because older functions call it.
create or replace function public.fn__plan_price(p_plan_code text, p_months integer)
returns numeric
language sql
stable
set search_path = public
as $$
  select case
    when p.by_arrangement then null
    when p_months = 1  and p.price_monthly   > 0 then p.price_monthly
    when p_months = 3  and p.price_quarterly > 0 then p.price_quarterly
    when p_months = 12 and p.price_yearly    > 0 then p.price_yearly
    else null end
    from public.plans p where p.code = p_plan_code;
$$;
revoke all on function public.fn__plan_price(text, integer) from public, anon, authenticated;

-- What THIS school pays for a term on a plan. The list price for Starter and
-- Growth. For Enterprise, the price we agreed with the school: its own three-
-- month and yearly figures when we set them, otherwise three months less 10%
-- and ten months for a year. NULL when there is no price to charge.
create or replace function public.fn__term_price(p_school_id uuid, p_plan_code text, p_months integer)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_months not in (1, 3, 12) then null
    when not p.by_arrangement then public.fn__plan_price(p.code, p_months)
    when s.agreed_monthly is null then null
    when p_months = 1  then s.agreed_monthly
    when p_months = 3  then coalesce(s.agreed_quarterly, round(s.agreed_monthly * 3 * 0.9))
    else coalesce(s.agreed_yearly, s.agreed_monthly * 10) end
    from public.plans p
    left join public.subscriptions s on s.school_id = p_school_id
   where p.code = p_plan_code;
$$;
revoke all on function public.fn__term_price(uuid, text, integer) from public, anon, authenticated;

-- The monthly price the school would pay month by month, the figure a term's
-- saving is measured against.
create or replace function public.fn__month_price(p_school_id uuid, p_plan_code text)
returns numeric
language sql
stable
security definer
set search_path = public
as $$ select public.fn__term_price(p_school_id, p_plan_code, 1) $$;
revoke all on function public.fn__month_price(uuid, text) from public, anon, authenticated;

-- THE DISCOUNT HOOKS. 0156 replaces all three. Until then there is no code.
--   fn__discount_for_quote: what the school's live code takes off this term.
--   fn__discount_record: write down that an invoice used it.
--   fn__discount_reverse: give it back when the invoice is voided.
create or replace function public.fn__discount_for_quote(
  p_school_id uuid, p_plan_code text, p_months integer, p_period_start date,
  p_term_price numeric)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$ select null::jsonb $$;

create or replace function public.fn__discount_record(p_invoice_id uuid, p_quote jsonb, p_overridden boolean)
returns void
language sql
security definer
set search_path = public
as $$ select null::void $$;

create or replace function public.fn__discount_reverse(p_invoice_id uuid, p_reason text)
returns void
language sql
security definer
set search_path = public
as $$ select null::void $$;

revoke all on function public.fn__discount_for_quote(uuid, text, integer, date, numeric) from public, anon, authenticated;
revoke all on function public.fn__discount_record(uuid, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.fn__discount_reverse(uuid, text) from public, anon, authenticated;

-- THE QUOTE. Every place that names a price asks this: the invoice itself,
-- the renewal run and its dry run, the school's next payment, the locked
-- screen, the console. Whole rupees throughout.
--   list_amount   the monthly price times the months
--   term_price    what the term costs (the 3-month and yearly saving taken)
--   term_saving   list_amount - term_price
--   discount      the school's live code, if it applies to this invoice
--   amount        term_price - discount
create or replace function public.fn__quote(
  p_school_id uuid, p_plan_code text, p_months integer, p_period_start date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  v_plan record; v_term numeric; v_month numeric; v_disc jsonb; v_off numeric := 0;
begin
  select * into v_plan from public.plans where code = p_plan_code;
  if not found then
    return jsonb_build_object('priced', false, 'plan_code', p_plan_code,
                              'reason', 'unknown_plan');
  end if;
  if p_months is null or p_months not in (1, 3, 12) then
    return jsonb_build_object('priced', false, 'plan_code', p_plan_code,
                              'plan_name', v_plan.name, 'months', p_months,
                              'reason', 'term');
  end if;

  v_term  := public.fn__term_price(p_school_id, p_plan_code, p_months);
  v_month := public.fn__month_price(p_school_id, p_plan_code);
  if v_term is null or v_term <= 0 then
    return jsonb_build_object(
      'priced', false, 'plan_code', p_plan_code, 'plan_name', v_plan.name,
      'months', p_months,
      'reason', case when v_plan.by_arrangement then 'needs_price' else 'not_sold' end);
  end if;

  if p_school_id is not null then
    v_disc := public.fn__discount_for_quote(p_school_id, p_plan_code, p_months,
                                            p_period_start, v_term);
    v_off := least(greatest(coalesce((v_disc->>'amount')::numeric, 0), 0), v_term);
  end if;

  return jsonb_build_object(
    'priced',       true,
    'plan_code',    v_plan.code,
    'plan_name',    v_plan.name,
    'by_arrangement', v_plan.by_arrangement,
    'months',       p_months,
    'period_start', p_period_start,
    'period_end',   case when p_period_start is null then null
                         else public.fn__term_end(p_period_start, p_months) end,
    'month_price',  v_month,
    'list_amount',  v_month * p_months,
    'term_price',   v_term,
    'term_saving',  greatest(v_month * p_months - v_term, 0),
    'discount',     case when v_off > 0 then v_disc else null end,
    'discount_note', case when v_off > 0 then null else v_disc->>'skipped' end,
    'discount_amount', v_off,
    'amount',       v_term - v_off);
end;
$$;
revoke all on function public.fn__quote(uuid, text, integer, date) from public, anon, authenticated;


-- The list price of a term on a plan, for screens that show the price list.
-- One, three or twelve months only; a by-arrangement plan has no list price
-- and says so (sold_at_list false) instead of quoting Rs 0.
create or replace function public.fn_plan_quote(p_plan_code text, p_months integer)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_plan record; v_price numeric; v_list numeric;
begin
  if p_months is null or p_months not in (1, 3, 12) then
    raise exception 'A term is one month, three months or a year' using errcode = '22023';
  end if;
  select * into v_plan from public.plans where code = p_plan_code;
  if not found then
    raise exception 'No such plan: %', p_plan_code;
  end if;
  v_price := public.fn__plan_price(p_plan_code, p_months);
  v_list  := v_plan.price_monthly * p_months;
  return jsonb_build_object(
    'plan_code', v_plan.code,
    'plan_name', v_plan.name,
    'months', p_months,
    'amount', v_price,
    'list_amount', case when v_plan.by_arrangement then null else v_list end,
    'saving', case when v_price is null then null else greatest(0, v_list - v_price) end,
    'per_month', case when v_price is null then null else round(v_price / p_months) end,
    'sold_at_list', not v_plan.by_arrangement,
    'student_limit', v_plan.student_limit);
end;
$$;

-- -----------------------------------------------------------------------------
-- 8. RAISING AN INVOICE, AND VOIDING ONE
-- -----------------------------------------------------------------------------

-- The one place an invoice is voided. Refused when money is on it (a credit
-- note is the way back from a paid invoice). A discount the invoice used comes
-- back, and the licence is worked out again.
create or replace function public.fn__void_invoice(p_invoice_id uuid, p_reason text, p_by text)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare v_inv record; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if v_reason is null then
    raise exception 'Voiding a document needs a reason: it is printed on it';
  end if;
  select * into v_inv from public.platform_invoices where id = p_invoice_id for update;
  if not found then
    raise exception 'No such document';
  end if;
  if v_inv.voided_at is not null then
    raise exception 'That document was already voided on %', v_inv.voided_at::date;
  end if;
  if exists (select 1 from public.platform_payment_allocations a where a.invoice_id = p_invoice_id) then
    raise exception
      'Cannot void %: % has been received against it. Raise a credit note instead.',
      v_inv.doc_no,
      to_char((select sum(a.amount) from public.platform_payment_allocations a
                where a.invoice_id = p_invoice_id), 'FM999,999,999');
  end if;
  if exists (select 1 from public.platform_invoices c
              where c.credits_invoice_id = p_invoice_id and c.voided_at is null) then
    raise exception
      'Cannot void %: a credit note has already been raised against it. Void the '
      'credit note first if that was the mistake.', v_inv.doc_no;
  end if;

  update public.platform_invoices
     set voided_at = now(), voided_by = auth.uid(), void_reason = v_reason
   where id = p_invoice_id;

  perform public.fn__discount_reverse(p_invoice_id, v_reason);

  -- The invoice that opened a school under the old rules is what its
  -- given_through date stands on. Voiding it takes the date away.
  if v_inv.kind = 'invoice' and v_inv.purpose = 'term' and v_inv.school_id is not null then
    update public.subscriptions
       set given_from = null, given_through = null
     where school_id = v_inv.school_id
       and given_through is not null
       and given_through = v_inv.period_end;
  end if;

  perform public.fn__log_operator_action(
    case when v_inv.kind = 'credit_note' then 'credit_note_voided' else 'invoice_voided' end,
    v_inv.school_id,
    jsonb_build_object('invoice_id', p_invoice_id, 'doc_no', v_inv.doc_no,
                       'amount', v_inv.amount, 'tax_amount', v_inv.tax_amount,
                       'reason', v_reason, 'by', p_by));

  if v_inv.school_id is not null then
    insert into public.audit_log(school_id, actor, action, entity, entity_id, before, reason)
    values (v_inv.school_id, auth.uid(), 'platform_invoice_voided', 'platform_invoices',
            p_invoice_id::text,
            jsonb_build_object('doc_no', v_inv.doc_no, 'amount', v_inv.amount,
                               'tax_amount', v_inv.tax_amount, 'by', p_by),
            v_reason);
    perform public.fn__apply_credit(v_inv.school_id, null);
  end if;

  return jsonb_build_object('invoice_id', p_invoice_id, 'doc_no', v_inv.doc_no,
                            'voided', true);
end;
$$;
revoke all on function public.fn__void_invoice(uuid, text, text) from public, anon, authenticated;

-- The open term invoice: live, for a period of the licence, money still owed,
-- and not lapsed. A lapsed invoice is for weeks the school was locked out of,
-- so no screen offers it to be paid: what the school is asked for instead is
-- the period it would be billed for on the day it comes back.
create or replace function public.fn__open_term_invoice(p_school_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select i.id from public.platform_invoices i
   where i.school_id = p_school_id and i.kind = 'invoice' and i.purpose = 'term'
     and i.voided_at is null and public.fn__invoice_owed(i.id) > 0
     and not public.fn__invoice_lapsed(i.id)
   order by i.period_start limit 1;
$$;
revoke all on function public.fn__open_term_invoice(uuid) from public, anon, authenticated;

-- Money put on lapsed invoices: it comes back as credit when they are voided.
create or replace function public.fn__on_lapsed(p_school_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(a.amount), 0)
    from public.platform_payment_allocations a
    join public.platform_invoices i on i.id = a.invoice_id
   where i.school_id = p_school_id and public.fn__invoice_lapsed(i.id);
$$;
revoke all on function public.fn__on_lapsed(uuid) from public, anon, authenticated;

-- LAPSED INVOICES ARE CLOSED when the school comes back (it pays, asks for its
-- invoice, or we invoice it), so it is billed for the period starting the day
-- it comes back less the grace days it used, and never for the weeks it was
-- locked out. Whatever was paid on a lapsed invoice comes back as credit and
-- goes on the new one; a credit note we raised against it lapses with it.
-- The first version voided only invoices with nothing at all on them, so a
-- school that had paid Rs 500 of a month and locked paid the rest for weeks it
-- could not use and stayed locked; and it counted a Rs 0 invoice (a free month
-- we gave) as unpaid, voided it and gave the code's month back, for ever.
create or replace function public.fn__void_lapsed(p_school_id uuid, p_by text)
returns integer
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare r record; c record; v_n integer := 0; v_grace integer := public.fn__grace_for(p_school_id);
        v_released numeric;
begin
  perform 1 from public.subscriptions where school_id = p_school_id for update;
  for r in
    select i.id, i.doc_no, i.due_on from public.platform_invoices i
     where i.school_id = p_school_id and public.fn__invoice_lapsed(i.id)
     order by i.period_start
  loop
    for c in
      select id from public.platform_invoices
       where credits_invoice_id = r.id and voided_at is null
    loop
      perform public.fn__void_invoice(c.id, format(
        'The invoice it credits, %s, lapsed when the school locked.', r.doc_no), p_by);
    end loop;

    select coalesce(sum(amount), 0) into v_released
      from public.platform_payment_allocations where invoice_id = r.id;
    if v_released > 0 then
      delete from public.platform_payment_allocations where invoice_id = r.id;
      insert into public.audit_log(school_id, actor, action, entity, entity_id, after, reason)
      values (p_school_id, auth.uid(), 'platform_payment_released', 'platform_invoices',
              r.id::text, jsonb_build_object('doc_no', r.doc_no, 'released', v_released, 'by', p_by),
              'The invoice lapsed; what was paid on it goes on the next one.');
    end if;

    perform public.fn__void_invoice(r.id, format(
      'Lapsed: unpaid by %s, when the school locked.%s The next period is billed '
      'from the day the school comes back, less the grace days it used.',
      to_char(r.due_on + v_grace, 'DD Mon YYYY'),
      case when v_released > 0
           then format(' Rs %s paid on it is kept as credit.', to_char(v_released, 'FM999,999,999'))
           else '' end), p_by);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke all on function public.fn__void_lapsed(uuid, text) from public, anon, authenticated;

-- Is the roll over the limit that will apply in a period starting p_start?
-- Extra room ends with the period it was given in, so it counts only if it
-- reaches that day, and only if it lasts beyond today: room given during grace
-- (or while locked) ends today, and used to let a whole new year through on
-- the old plan. NULL when the roll fits; otherwise the sentence to show.
create or replace function public.fn__over_limit_for_period(p_school_id uuid, p_start date)
returns text
language plpgsql
stable
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare s public.subscriptions; v_plan record; v_count integer; v_cap integer;
begin
  select * into s from public.subscriptions where school_id = p_school_id;
  select * into v_plan from public.plans where code = s.plan_code;
  v_cap := case when s.student_limit_override is not null
                     and s.student_limit_override_until >= p_start
                     and s.student_limit_override_until > current_date
                then s.student_limit_override
                else v_plan.student_limit end;
  if v_cap is null then
    return null;
  end if;
  v_count := public.fn_count_students(p_school_id);
  if v_count <= v_cap then
    return null;
  end if;
  return format('%s has %s pupils and %s covers %s. Move it to %s with Change plan, or give a reason to invoice it on %s anyway.',
    (select name from public.schools where id = p_school_id), v_count, v_plan.name, v_cap,
    coalesce((select name from public.plans where code = public.fn__plan_for_students(v_count)),
             'a bigger plan'),
    v_plan.name);
end;
$$;
revoke all on function public.fn__over_limit_for_period(uuid, date) from public, anon, authenticated;

-- RAISE THE NEXT TERM INVOICE. Every caller comes through here: the console,
-- the renewal run, a school asking for its invoice, and a payment that arrives
-- before its invoice. It never moves the licence: paying the invoice does.
-- Refusals carry their own SQLSTATE so the renewal run can tell them apart
-- without reading the sentence:
--   SB001  there is already an open term invoice
--   SB002  no price to charge (Enterprise not priced yet)
--   SB003  the school cannot be invoiced (cancelled, suspended, archived)
--   SB004  the roll is over the plan's limit: a decision for us
create or replace function public.fn__raise_term_invoice(
  p_school_id uuid, p_months integer, p_amount numeric, p_reason text, p_by text)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  s public.subscriptions; v_school record; v_months integer; v_start date; v_end date;
  q jsonb; v_amount numeric; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_note text; v_inv uuid; v_doc text; v_open uuid; v_lapsed integer;
  v_code text; v_code_off numeric := 0; v_overridden boolean := false;
  v_over text; v_due date; v_hand_reason text;
begin
  select * into s from public.subscriptions where school_id = p_school_id for update;
  if not found then
    raise exception 'This school has no subscription.' using errcode = 'SB003';
  end if;
  select * into v_school from public.schools where id = p_school_id;
  if v_school.archived_at is not null or not v_school.active then
    raise exception '% is archived. Bring it back before invoicing it.', v_school.name
      using errcode = 'SB003';
  end if;
  if s.status = 'cancelled' then
    raise exception '% has cancelled. Reinstate it before invoicing it.', v_school.name
      using errcode = 'SB003';
  end if;
  if s.suspended_at is not null then
    raise exception '% is suspended. Lift the suspension before invoicing it.', v_school.name
      using errcode = 'SB003';
  end if;
  if s.cancel_at_period_end then
    raise exception '% asked to stop at the end of its period, so nothing more is invoiced. If it is staying after all, it restarts from its Subscription page, or we reinstate it.',
      v_school.name using errcode = 'SB003';
  end if;

  v_months := coalesce(p_months, s.term_months);
  if v_months not in (1, 3, 12) then
    raise exception 'A term is one month, three months or a year.' using errcode = '22023';
  end if;

  v_lapsed := public.fn__void_lapsed(p_school_id, p_by);

  v_open := public.fn__open_term_invoice(p_school_id);
  if v_open is not null then
    raise exception '% already has % open for % to %, with Rs % still owed. That one is paid first.',
      v_school.name,
      (select doc_no from public.platform_invoices where id = v_open),
      (select to_char(period_start, 'DD Mon YYYY') from public.platform_invoices where id = v_open),
      (select to_char(period_end, 'DD Mon YYYY') from public.platform_invoices where id = v_open),
      to_char(public.fn__invoice_owed(v_open), 'FM999,999,999')
      using errcode = 'SB001';
  end if;

  v_start := public.fn__next_period_start(p_school_id);
  v_end   := public.fn__term_end(v_start, v_months);
  -- Due on the first day of the period it pays for. A school already locked
  -- that is coming back is billed from before today (the grace days it used),
  -- and is given today as the day it is due.
  v_due   := case when v_start < current_date
                    and current_date >= coalesce(public.fn__lock_day(p_school_id), current_date)
                   then current_date else v_start end;

  if exists (select 1 from public.platform_invoices i
              where i.school_id = p_school_id and i.kind = 'invoice'
                and i.purpose = 'term' and i.voided_at is null
                and i.period_end >= v_start and i.period_start <= v_end) then
    raise exception '% is already invoiced for part of % to %.', v_school.name,
      to_char(v_start, 'DD Mon YYYY'), to_char(v_end, 'DD Mon YYYY')
      using errcode = 'SB001';
  end if;

  -- OVER THE LIMIT. Extra room ends with the period it was given in, so the
  -- period being invoiced is held to the limit that will apply in it. A school
  -- whose roll has outgrown its plan is a decision for us (move it, or invoice
  -- it on its plan on purpose, with a reason), never an automatic renewal and
  -- never something a school can buy for itself.
  v_hand_reason := case when p_by = 'operator' then v_reason end;
  v_over := public.fn__over_limit_for_period(p_school_id, v_start);
  if v_over is not null then
    if p_by <> 'operator' or v_reason is null then
      raise exception '%', v_over using errcode = 'SB004';
    end if;
    v_reason := format('%s (invoiced on its plan over the limit, on purpose: %s pupils)',
                       v_reason, public.fn_count_students(p_school_id));
  end if;

  q := public.fn__quote(p_school_id, s.plan_code, v_months, v_start);
  if not coalesce((q->>'priced')::boolean, false) then
    raise exception '% is on %, and no price has been agreed with it yet. Set its price first.',
      v_school.name, coalesce(q->>'plan_name', s.plan_code)
      using errcode = 'SB002';
  end if;

  if p_amount is not null then
    if p_amount < 0 or p_amount <> round(p_amount) then
      raise exception 'An invoice is a whole number of rupees, nothing below zero.'
        using errcode = '22023';
    end if;
    if p_amount <> (q->>'amount')::numeric and v_reason is null then
      raise exception 'Charging Rs % where the price is Rs % needs a reason: it is printed on the invoice.',
        to_char(p_amount, 'FM999,999,999'), to_char((q->>'amount')::numeric, 'FM999,999,999')
        using errcode = '22023';
    end if;
    v_amount := p_amount;
    v_overridden := jsonb_typeof(q->'discount') = 'object' and p_amount <> (q->>'amount')::numeric;
  else
    v_amount := (q->>'amount')::numeric;
  end if;

  if jsonb_typeof(q->'discount') = 'object' then
    v_code := q->'discount'->>'code';
    if not v_overridden then
      v_code_off := (q->>'discount_amount')::numeric;
    end if;
  end if;

  v_note := concat_ws('; ',
    v_reason,
    case when v_code is not null and not v_overridden
         then format('Rs %s off with code %s', to_char(v_code_off, 'FM999,999,999'), v_code) end,
    case when v_overridden
         then format('Price set by hand; code %s is used up on this invoice', v_code) end,
    case when q->>'discount_note' is not null then q->>'discount_note' end);

  insert into public.platform_invoices
    (school_id, school_name, plan_code, plan_name, cycle, months, period_start, period_end,
     amount, list_amount, due_on, note, created_by, purpose, discount_code, discount_amount,
     set_by_hand, hand_reason)
  values
    (p_school_id, v_school.name, s.plan_code, q->>'plan_name',
     public.fn__cycle_for_months(v_months), v_months, v_start, v_end,
     v_amount, (q->>'term_price')::numeric, v_due,
     nullif(v_note, ''), auth.uid(), 'term', v_code, v_code_off,
     p_by = 'operator' and (p_amount is not null or v_hand_reason is not null), v_hand_reason)
  returning id, doc_no into v_inv, v_doc;

  if v_code is not null then
    perform public.fn__discount_record(v_inv, q, v_overridden);
  end if;

  if s.term_months is distinct from v_months then
    update public.subscriptions
       set term_months = v_months, cycle = public.fn__cycle_for_months(v_months)
     where school_id = p_school_id;
  end if;

  insert into public.audit_log(school_id, actor, action, entity, entity_id, after, reason)
  values (p_school_id, auth.uid(), 'subscription_invoiced', 'platform_invoices', v_inv::text,
          jsonb_build_object('doc_no', v_doc, 'plan_code', s.plan_code, 'months', v_months,
                             'period_start', v_start, 'period_end', v_end,
                             'amount', v_amount, 'term_price', q->'term_price',
                             'discount_code', v_code, 'discount_amount', v_code_off,
                             'overridden', v_overridden, 'by', p_by,
                             'lapsed_voided', v_lapsed),
          v_reason);

  -- Money already paid in and not yet against anything goes on this invoice.
  perform public.fn__apply_credit(p_school_id, v_inv);

  return jsonb_build_object(
    'invoice_id', v_inv, 'doc_no', v_doc, 'school_id', p_school_id,
    'plan_code', s.plan_code, 'plan_name', q->>'plan_name',
    'months', v_months, 'period_start', v_start, 'period_end', v_end,
    'due_on', v_due,
    'amount', v_amount, 'list_amount', (q->>'term_price')::numeric,
    'term_price', (q->>'term_price')::numeric, 'term_saving', q->'term_saving',
    'discount_code', v_code, 'discount_amount', v_code_off,
    'overridden', v_overridden,
    'owed', public.fn__invoice_owed(v_inv),
    'lapsed_voided', v_lapsed,
    'status', public.fn_effective_status(p_school_id));
end;
$$;
revoke all on function public.fn__raise_term_invoice(uuid, integer, numeric, text, text) from public, anon, authenticated;

-- The console's old entry point. It used to move the plan, push the licence
-- forward and invoice in one breath. Now it raises the next term invoice on
-- the plan the school is on; moving a school between plans is
-- fn_platform_change_plan. p_allow_over_limit invoices a school whose roll is
-- over its plan's limit, on purpose, without a note of our own.
create or replace function public.fn_activate_subscription(
  p_school_id uuid, p_plan_code text, p_months integer default 12,
  p_amount numeric default null, p_note text default null,
  p_allow_over_limit boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare v_plan text;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select plan_code into v_plan from public.subscriptions where school_id = p_school_id;
  if v_plan is null then
    raise exception 'No subscription for school %', p_school_id;
  end if;
  if p_plan_code is not null and p_plan_code is distinct from v_plan then
    raise exception 'This school is on %. Move it to % with Change plan first; an invoice is raised on the plan the school is on.',
      v_plan, p_plan_code using errcode = '22023';
  end if;
  return public.fn__raise_term_invoice(p_school_id, p_months, p_amount,
    coalesce(nullif(btrim(coalesce(p_note, '')), ''),
             case when coalesce(p_allow_over_limit, false)
                  then 'Invoiced on its plan over the limit, on purpose' end),
    'operator');
end;
$$;

create or replace function public.fn_platform_raise_invoice(
  p_school_id uuid, p_months integer default null, p_amount numeric default null,
  p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return public.fn__raise_term_invoice(p_school_id, p_months, p_amount, p_reason, 'operator');
end;
$$;
revoke all on function public.fn_platform_raise_invoice(uuid, integer, numeric, text) from public, anon;
grant execute on function public.fn_platform_raise_invoice(uuid, integer, numeric, text) to authenticated;

-- A school asks for its next invoice (an accounts office often needs one
-- before it pays). From thirty days before its covered period ends.
create or replace function public.fn_my_request_invoice()
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare v_school uuid := public.current_school_id(); v_open uuid; v_cov date;
begin
  if v_school is null or not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or the principal can ask for the invoice'
      using errcode = '42501';
  end if;
  v_open := public.fn__open_term_invoice(v_school);
  if v_open is not null then
    return jsonb_build_object('invoice_id', v_open,
      'doc_no', (select doc_no from public.platform_invoices where id = v_open),
      'already', true);
  end if;
  v_cov := public.fn__coverage_end(v_school);
  if v_cov is not null and v_cov - current_date > 30 then
    raise exception 'Your next invoice can be raised from %, thirty days before your paid period ends on %.',
      to_char(v_cov - 30, 'DD Mon YYYY'), to_char(v_cov, 'DD Mon YYYY')
      using errcode = '22023';
  end if;
  return public.fn__raise_term_invoice(v_school, null, null, null, 'school')
         || jsonb_build_object('already', false);
exception
  when sqlstate 'SB002' then
    raise exception 'Your price has not been agreed yet. We will call you to agree it, and your invoice follows.'
      using errcode = '22023';
  when sqlstate 'SB003' then
    raise exception 'Your subscription cannot be invoiced at the moment. Please call us.'
      using errcode = '22023';
  when sqlstate 'SB004' then
    raise exception 'Your roll is bigger than your plan covers, so we need to move you to the right plan before the next invoice. Ask us from this screen and we will tell you the price.'
      using errcode = '22023';
end;
$$;
revoke all on function public.fn_my_request_invoice() from public, anon;
grant execute on function public.fn_my_request_invoice() to authenticated;

-- Voiding, through the one void path.
create or replace function public.fn_platform_void_invoice(p_invoice_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare v jsonb; v_school uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select school_id into v_school from public.platform_invoices where id = p_invoice_id;
  v := public.fn__void_invoice(p_invoice_id, p_reason, 'operator');
  return v || jsonb_build_object(
    'warning', null,
    'status', case when v_school is null then null else public.fn_effective_status(v_school) end,
    'outstanding', case when v_school is null then 0 else public.fn_platform_outstanding(v_school) end);
end;
$$;


-- -----------------------------------------------------------------------------
-- 9. MONEY IN
-- -----------------------------------------------------------------------------

-- MONEY PAID AHEAD REACHES THE LICENCE. Credit (money paid in and on no
-- invoice) raises and pays the next term invoice whenever there is nothing
-- open and either the covered period ends within thirty days (or has ended),
-- or, with p_ahead, the credit pays the whole term. It repeats while the
-- credit lasts, up to three years of terms. p_ahead is for money the school
-- SENT (a payment, or a price set while it waited): it meant to pay ahead.
-- Credit we released with a credit note is not that (it is often a refund for
-- a school that is leaving), so it waits for the usual thirty days. The first version raised the next invoice only when a
-- payment arrived within thirty days of the end, so a school that paid two
-- months at once, or paid while its Enterprise price was being agreed, kept
-- the money as credit and locked anyway, told it owed Rs 0.
-- Called when money arrives, when an Enterprise price is set, and when a
-- school is reinstated or restarts. Returns the invoices it raised, and why it
-- stopped if it stopped on a refusal.
create or replace function public.fn__spend_credit(p_school_id uuid, p_by text, p_ahead boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  s public.subscriptions; v_raised jsonb := '[]'::jsonb; v_note text; v_cov date;
  v_start date; q jsonb; j jsonb; i integer;
begin
  for i in 1..36 loop
    exit when public.fn__unallocated(p_school_id) < 1;
    exit when public.fn__open_term_invoice(p_school_id) is not null;
    select * into s from public.subscriptions where school_id = p_school_id;
    exit when not found or s.status = 'cancelled' or s.suspended_at is not null
              or s.cancel_at_period_end;
    v_cov   := public.fn__coverage_end(p_school_id);
    v_start := public.fn__next_period_start(p_school_id);
    q := public.fn__quote(p_school_id, s.plan_code, s.term_months, v_start);
    exit when not coalesce((q->>'priced')::boolean, false);
    exit when not (v_cov is null or v_cov - current_date <= 30
                   or (coalesce(p_ahead, true)
                       and public.fn__unallocated(p_school_id) >= (q->>'amount')::numeric));
    begin
      j := public.fn__raise_term_invoice(p_school_id, null, null, null, p_by);
      v_raised := v_raised || jsonb_build_array(j);
    exception when sqlstate 'SB001' or sqlstate 'SB002' or sqlstate 'SB003' or sqlstate 'SB004' then
      v_note := sqlerrm;
      exit;
    end;
    -- A term the credit did not pay in full stays open for the rest; stop.
    exit when public.fn__invoice_owed((j->>'invoice_id')::uuid) > 0;
  end loop;
  return jsonb_build_object('raised', v_raised, 'not_raised_because', v_note);
end;
$$;
revoke all on function public.fn__spend_credit(uuid, text, boolean) from public, anon, authenticated;

-- Where a payment goes, in order:
--   0. lapsed invoices are closed first (what was paid on them comes back);
--   1. the invoice it was recorded against, if one was named and is still live;
--   2. invoices with money owed, oldest due first;
--   3. what is left raises and pays the next term invoices (fn__spend_credit).
--      A school that pays what its screen asked for is back in the moment we
--      confirm it.
-- Anything still left is credit, used on the next invoice when it is raised.
create or replace function public.fn__settle_payment(p_school_id uuid, p_invoice_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  v_alloc numeric; v_spent jsonb; v_lapsed integer := 0; v_prefer uuid := p_invoice_id;
begin
  -- A school past its grace is starting again, whether or not its payment
  -- named the invoice that lapsed: money put on a lapsed invoice would buy
  -- only weeks already gone.
  v_lapsed := public.fn__void_lapsed(p_school_id, 'payment');
  if v_prefer is not null and exists (select 1 from public.platform_invoices
                                       where id = v_prefer and voided_at is not null) then
    v_prefer := null;
  end if;

  v_alloc := public.fn__apply_credit(p_school_id, v_prefer);
  v_spent := public.fn__spend_credit(p_school_id, 'payment');

  return jsonb_build_object(
    'allocated', v_alloc,
    -- The first invoice raised, as before; all of them in raised_all.
    'raised', v_spent->'raised'->0,
    'raised_all', v_spent->'raised',
    'not_raised_because', v_spent->'not_raised_because',
    'lapsed_voided', v_lapsed,
    'credit', public.fn__unallocated(p_school_id),
    'status', public.fn_effective_status(p_school_id),
    'paid_through', (select period_end from public.subscriptions where school_id = p_school_id));
end;
$$;
revoke all on function public.fn__settle_payment(uuid, uuid) from public, anon, authenticated;

create or replace function public.fn_platform_record_payment(
  p_school_id uuid, p_amount numeric, p_paid_on date default null,
  p_method text default 'bank', p_reference text default null,
  p_invoice_id uuid default null, p_note text default null,
  p_tax_withheld numeric default 0, p_tax_certificate text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  v_id uuid; v_actor uuid := auth.uid();
  v_tax numeric := round(coalesce(p_tax_withheld, 0), 2);
  v_settle jsonb;
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
  if p_paid_on is not null and p_paid_on > current_date then
    raise exception 'That payment date is in the future';
  end if;
  -- The school's lock first, then the invoice checks: a term change or a move
  -- that reissues the invoice at the same moment is either seen here or waits.
  -- Checked before the lock, a month's money could land as part payment of the
  -- year that had just replaced it.
  perform 1 from public.subscriptions where school_id = p_school_id for update;
  if p_invoice_id is not null
     and not exists (select 1 from public.platform_invoices
                      where id = p_invoice_id and school_id = p_school_id) then
    raise exception 'That invoice does not belong to this school';
  end if;
  if p_invoice_id is not null
     and exists (select 1 from public.platform_invoices
                  where id = p_invoice_id and voided_at is not null) then
    raise exception 'That invoice is voided. Allocate the payment elsewhere or leave it unallocated';
  end if;
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

  v_settle := public.fn__settle_payment(p_school_id, p_invoice_id);

  return jsonb_build_object(
    'payment_id', v_id, 'school_id', p_school_id, 'amount', p_amount,
    'tax_withheld', v_tax, 'settled', p_amount + v_tax,
    'awaiting_certificate', v_tax > 0
      and nullif(btrim(coalesce(p_tax_certificate, '')), '') is null,
    'outstanding', public.fn_platform_outstanding(p_school_id))
    || v_settle;
end;
$$;

-- The report row is locked first and its status checked again under the lock:
-- two people pressing Confirm at the same moment used to record two payments.
create or replace function public.fn_platform_confirm_claim(
  p_claim_id uuid, p_amount numeric default null, p_invoice_id uuid default null,
  p_tax_withheld numeric default 0, p_tax_certificate text default null,
  p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare v_c record; v_amt numeric; v_pay jsonb; v_pid uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into v_c from public.platform_payment_claims where id = p_claim_id for update;
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

  v_pay := public.fn_platform_record_payment(
    v_c.school_id, v_amt, v_c.paid_on, v_c.method, v_c.reference, p_invoice_id,
    btrim(coalesce('Reported by the school on ' || v_c.claimed_at::date || '. ', '')
          || coalesce(nullif(btrim(coalesce(p_note, '')), ''), '')),
    coalesce(p_tax_withheld, 0), p_tax_certificate);
  v_pid := (v_pay->>'payment_id')::uuid;

  update public.platform_payment_claims
     set status = 'confirmed', decided_by = auth.uid(), decided_at = now(),
         decision_note = nullif(btrim(coalesce(p_note, '')), ''),
         payment_id = v_pid
   where id = p_claim_id and status = 'pending';

  perform public.fn__log_operator_action('payment_claim_confirmed', v_c.school_id,
    jsonb_build_object('claim_id', p_claim_id, 'payment_id', v_pid,
                       'claimed_amount', v_c.amount, 'confirmed_amount', v_amt,
                       'reference', v_c.reference,
                       'paid_through', v_pay->'paid_through',
                       'status', v_pay->'status'));

  insert into public.audit_log(school_id, actor, action, entity, entity_id, after)
  values (v_c.school_id, auth.uid(), 'subscription_payment_confirmed',
          'platform_payment_claims', p_claim_id::text,
          jsonb_build_object('amount', v_amt, 'payment_id', v_pid,
                             'paid_through', v_pay->'paid_through'));

  return jsonb_build_object(
    'claim_id', p_claim_id, 'status', 'confirmed',
    'payment_id', v_pid, 'amount', v_amt,
    'outstanding', v_pay->'outstanding',
    'licence_status', v_pay->'status',
    'paid_through', v_pay->'paid_through',
    'raised', v_pay->'raised',
    'credit', v_pay->'credit');
end;
$$;

-- A credit note counts towards paying the invoice it is raised against.
--
-- UNDER THE SCHOOL'S LOCK, AND NEVER MORE THAN THE INVOICE. The first version
-- read what was already credited without a lock, so two credit notes at the
-- same moment credited Rs 3,000 against a Rs 2,000 invoice; and it ignored
-- what had been PAID, so a credit note on a paid invoice simply vanished: the
-- statement showed the school in credit while the next invoice asked for the
-- full price, and a school that paid what its statement said locked. Now a
-- credit note on money already paid releases that much of the payment back
-- to the school as credit, which goes on its next invoice. A credit note that
-- rounds to nothing is refused (it would only block voiding the invoice), and
-- sales tax is credited only up to the tax the invoice charged.
CREATE OR REPLACE FUNCTION public.fn_platform_credit_note(p_invoice_id uuid, p_amount numeric, p_reason text, p_tax_amount numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'Asia/Karachi'
AS $function$
declare
  v_inv record; v_credited numeric; v_tax_credited numeric; v_room numeric;
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_tax numeric; v_id uuid; v_doc text; v_school uuid; v_excess numeric;
  a record; v_take numeric; v_released numeric := 0;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_reason is null then
    raise exception 'A credit note needs a reason: it is printed on it';
  end if;
  if v_amount <= 0 then
    raise exception 'A credit note must be more than zero';
  end if;

  select school_id into v_school from public.platform_invoices where id = p_invoice_id;
  if v_school is not null then
    perform 1 from public.subscriptions where school_id = v_school for update;
  end if;
  select * into v_inv from public.platform_invoices where id = p_invoice_id for update;
  if not found then
    raise exception 'No such invoice';
  end if;
  if v_inv.kind <> 'invoice' then
    raise exception 'Credit notes are raised against invoices, not against %', v_inv.kind;
  end if;
  if v_inv.voided_at is not null then
    raise exception 'That invoice is voided: there is nothing to credit';
  end if;

  select coalesce(sum(amount + tax_amount), 0), coalesce(sum(tax_amount), 0)
    into v_credited, v_tax_credited
    from public.platform_invoices
   where credits_invoice_id = p_invoice_id and voided_at is null;

  v_tax := case
    when p_tax_amount is not null then round(p_tax_amount, 2)
    when v_inv.amount > 0 then round(v_inv.tax_amount * (v_amount / v_inv.amount), 2)
    else 0 end;
  if v_tax < 0 then
    raise exception 'A tax credit cannot be negative';
  end if;
  if v_tax > v_inv.tax_amount - v_tax_credited then
    raise exception
      'That would credit Rs % of sales tax on %, which charged Rs % and has Rs % of it credited already.',
      to_char(v_tax, 'FM999999999.00'), v_inv.doc_no,
      to_char(v_inv.tax_amount, 'FM999999999.00'), to_char(v_tax_credited, 'FM999999999.00');
  end if;

  v_room := (v_inv.amount + v_inv.tax_amount) - v_credited;
  if v_amount + v_tax > v_room then
    raise exception
      'That would credit % against %, which is % and already has % credited. '
      'At most % remains.',
      to_char(v_amount + v_tax, 'FM999999999.00'), v_inv.doc_no,
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
     v_amount,
     -- list_amount equals amount on a credit note, so fn_platform_revenue's
     -- discount figure, sum(list_amount - amount), is untouched by credits. A
     -- refund is not a discount and must not appear as one.
     v_amount,
     v_inv.tax_pct, v_tax,
     current_date, null,
     format('Credit against %s: %s', v_inv.doc_no, v_reason),
     auth.uid())
  returning id, doc_no into v_id, v_doc;

  -- Paid and credited together may not exceed the invoice. What over-covers it
  -- goes back to the payments, newest first, as credit.
  v_excess := public.fn__invoice_settled(p_invoice_id) - (v_inv.amount + v_inv.tax_amount);
  for a in
    select al.id, al.amount from public.platform_payment_allocations al
     where al.invoice_id = p_invoice_id
     order by al.created_at desc, al.id desc
  loop
    exit when v_excess <= 0;
    v_take := least(a.amount, v_excess);
    if v_take >= a.amount then
      delete from public.platform_payment_allocations where id = a.id;
    else
      update public.platform_payment_allocations set amount = amount - v_take where id = a.id;
    end if;
    v_excess   := v_excess - v_take;
    v_released := v_released + v_take;
  end loop;

  insert into public.audit_log(school_id, actor, action, entity, entity_id, after, reason)
  values (v_inv.school_id, auth.uid(), 'platform_credit_note', 'platform_invoices',
          v_id::text,
          jsonb_build_object('doc_no', v_doc, 'credits', v_inv.doc_no,
                             'amount', v_amount, 'tax_amount', v_tax,
                             'released_to_credit', v_released),
          v_reason);

  -- The licence is worked out again, and money released goes on what is owed
  -- or on the next term.
  perform public.fn__apply_credit(v_inv.school_id, null);
  if v_released > 0 then
    perform public.fn__spend_credit(v_inv.school_id, 'operator', false);
  end if;

  return jsonb_build_object(
    'licence_status', public.fn_effective_status(v_inv.school_id),
    'credit_note_id', v_id, 'doc_no', v_doc,
    'credits_doc_no', v_inv.doc_no,
    'amount', v_amount, 'tax_amount', v_tax,
    'total', v_amount + v_tax,
    'released_to_credit', v_released,
    'credit', public.fn__unallocated(v_inv.school_id),
    'outstanding', public.fn_platform_outstanding(v_inv.school_id));
end;
$function$;

-- Sales tax on an invoice, set before anything is paid on it. The guard read
-- platform_payments.invoice_id, which this migration stopped using to decide
-- anything, so an invoice paid by an unnamed payment could have tax added
-- (reopening it silently, with no debt date) or taken off after the tax was
-- paid (leaving the money on no invoice and not as credit). It now reads what
-- is settled on the invoice, and the licence follows any change.
create or replace function public.fn_platform_set_invoice_tax(
  p_invoice_id uuid, p_tax_pct numeric, p_tax_amount numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare v_inv record; v_pct numeric; v_amt numeric; v_settled numeric;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into v_inv from public.platform_invoices where id = p_invoice_id;
  if not found then
    raise exception 'No such invoice';
  end if;
  if v_inv.school_id is not null then
    perform 1 from public.subscriptions where school_id = v_inv.school_id for update;
  end if;
  select * into v_inv from public.platform_invoices where id = p_invoice_id for update;
  if v_inv.voided_at is not null then
    raise exception 'That invoice is voided';
  end if;
  if v_inv.kind <> 'invoice' then
    raise exception 'Tax is set on the invoice, not on the credit note';
  end if;

  v_settled := public.fn__invoice_settled(p_invoice_id);
  if v_settled > 0 then
    raise exception
      'Cannot change the tax on %: % has been paid or credited against it. Raise a credit '
      'note and a fresh invoice.', v_inv.doc_no, to_char(v_settled, 'FM999999999.00');
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

  if v_inv.school_id is not null then
    perform public.fn__apply_credit(v_inv.school_id, null);
  end if;

  return jsonb_build_object('invoice_id', p_invoice_id, 'doc_no', v_inv.doc_no,
    'tax_pct', v_pct, 'tax_amount', v_amt, 'total', v_inv.amount + v_amt,
    'outstanding', public.fn_platform_outstanding(v_inv.school_id));
end;
$$;
revoke all on function public.fn_platform_set_invoice_tax(uuid, numeric, numeric) from public, anon;
grant execute on function public.fn_platform_set_invoice_tax(uuid, numeric, numeric) to authenticated;


-- The reply no longer promises that nothing stops: an unpaid school locks.
CREATE OR REPLACE FUNCTION public.fn_my_report_payment(p_amount numeric, p_paid_on date DEFAULT NULL::date, p_method text DEFAULT 'bank'::text, p_reference text DEFAULT NULL::text, p_from_bank text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'Asia/Karachi'
AS $function$
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
    raise exception 'That date is more than a year ago. Check it';
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
               'confirm it here, usually the same working day. The moment we do, your '
               'paid period moves on and, if the software was locked, it opens again.');
end;
$function$;


-- The invoice prints the plan's name as it was on the day it was raised.
CREATE OR REPLACE FUNCTION public.fn__invoice_document(p_invoice_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_plan := coalesce(v_inv.plan_name, (select name from public.plans where code = v_inv.plan_code));

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
  -- Paid means allocated to this invoice (0155), whether the payment named it
  -- or was matched to it as the oldest invoice owed.
  select coalesce(sum(a.amount), 0) into v_paid
    from public.platform_payment_allocations a where a.invoice_id = p_invoice_id;

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
      'description', format('%s plan: school management software licence',
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
      -- another one is. Less than a rupee is nothing, as it is for the licence
      -- (fn__invoice_owed): paisa from tax are never shown as owing.
      'balance', case when v_total - v_credits - v_paid < 1
                       and v_total - v_credits - v_paid > -1
                      then 0 else v_total - v_credits - v_paid end),

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

    -- Each payment's share of THIS invoice. A payment split over two invoices
    -- printed its whole withheld tax on both, so the documents claimed twice
    -- the deduction the certificate shows. The withheld part is now prorated:
    -- cash plus withheld equals what this invoice received from the payment.
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'paid_on', x.paid_on, 'amount', x.share - x.wht, 'method', x.method,
               'reference', x.reference, 'tax_withheld', x.wht,
               'tax_certificate', x.tax_certificate, 'settled', x.share)
             order by x.paid_on, x.created_at)
        from (select p.paid_on, p.created_at, p.method, p.reference, p.tax_certificate,
                     a.amount as share,
                     case when p.settled > 0
                          then round(p.tax_withheld * a.amount / p.settled, 2) else 0 end as wht
                from public.platform_payment_allocations a
                join public.platform_payments p on p.id = a.payment_id
               where a.invoice_id = p_invoice_id) x), '[]'::jsonb),

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
$function$;



-- -----------------------------------------------------------------------------
-- 10. PLANS MOVE ONLY BY US
-- -----------------------------------------------------------------------------

-- REISSUE THE OPEN TERM INVOICE so the next period is billed at a new plan,
-- price, term or code. The rules, because the first version broke each one:
--   * A change the SCHOOL makes (its term, a code) never undoes a decision we
--     made on the invoice: one we priced by hand, gave a reason for, or raised
--     over the limit on purpose is kept, and the change applies from the
--     invoice after it. Two term changes used to price a hand-made invoice
--     back to list.
--   * The school's change also keeps an invoice with money on it.
--   * A change WE make (plan, price, a code we give) moves money already paid
--     on an open invoice onto its replacement, so a token payment cannot hold
--     a whole year at the old plan's price. An invoice with a credit note
--     against it is kept: that is a decision too.
--   * The void and the new invoice happen together or not at all. When the
--     replacement cannot be raised (over the limit, no price, cannot be
--     invoiced) the original stays, so a school is never left with no invoice
--     and no way to get one. The school is told in its own words.
create or replace function public.fn__reissue_open_invoice(p_school_id uuid, p_reason text, p_by text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_open uuid; v_inv record; v_new jsonb; v_settled numeric; v_released numeric := 0;
begin
  v_open := public.fn__open_term_invoice(p_school_id);
  if v_open is null then
    return null;
  end if;
  select * into v_inv from public.platform_invoices where id = v_open;

  if p_by = 'school' and v_inv.set_by_hand then
    return jsonb_build_object('kept', v_inv.doc_no,
      'why', 'We set this invoice with you, so it stays as it is. Your change applies from the invoice after it.');
  end if;
  v_settled := public.fn__invoice_settled(v_open);
  if v_settled > 0 and (p_by = 'school'
       or exists (select 1 from public.platform_invoices c
                   where c.credits_invoice_id = v_open and c.voided_at is null)) then
    return jsonb_build_object('kept', v_inv.doc_no,
      'why', 'money has been paid against it, so the change applies from the next invoice');
  end if;

  begin
    if v_settled > 0 then
      select coalesce(sum(amount), 0) into v_released
        from public.platform_payment_allocations where invoice_id = v_open;
      delete from public.platform_payment_allocations where invoice_id = v_open;
      insert into public.audit_log(school_id, actor, action, entity, entity_id, after, reason)
      values (p_school_id, auth.uid(), 'platform_payment_released', 'platform_invoices',
              v_open::text, jsonb_build_object('doc_no', v_inv.doc_no, 'released', v_released,
                                               'by', p_by), p_reason);
    end if;
    perform public.fn__void_invoice(v_open, p_reason, p_by);
    v_new := public.fn__raise_term_invoice(p_school_id, null, null,
               case when p_by = 'operator' then v_inv.hand_reason end, p_by);
  exception when sqlstate 'SB001' or sqlstate 'SB002' or sqlstate 'SB003' or sqlstate 'SB004' then
    -- Everything in this block is undone: the original invoice stands.
    return jsonb_build_object('kept', v_inv.doc_no,
      'why', case
        when p_by <> 'school' then sqlerrm
        when sqlstate = 'SB004' then 'Your roll is bigger than your plan covers, so we need to move you to the right plan first. Your invoice stays as it is until then.'
        when sqlstate = 'SB002' then 'Your price is still being agreed, so your invoice stays as it is.'
        else 'Your invoice stays as it is. Please call us if it needs to change.' end);
  end;
  return jsonb_build_object('voided', v_inv.doc_no, 'raised', v_new,
                            'carried_over', nullif(v_released, 0));
end;
$$;
revoke all on function public.fn__reissue_open_invoice(uuid, text, text) from public, anon, authenticated;

-- ENTERPRISE PRICE. We agree a monthly figure with the school; three months
-- and a year follow (10% off, two months free) unless we agree those too.
create or replace function public.fn_platform_set_price(
  p_school_id uuid, p_monthly numeric, p_quarterly numeric default null,
  p_yearly numeric default null, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  s public.subscriptions; v_plan record;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), ''); v_re jsonb; v_spent jsonb;
  v_before jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into s from public.subscriptions where school_id = p_school_id for update;
  if not found then
    raise exception 'That school has no subscription';
  end if;
  select * into v_plan from public.plans where code = s.plan_code;
  if not v_plan.by_arrangement then
    raise exception '% has a fixed price. To lower what this school pays, give it a discount code.',
      v_plan.name using errcode = '22023';
  end if;
  if p_monthly is null or p_monthly <= 0 or p_monthly <> round(p_monthly) then
    raise exception 'The monthly price is a whole number of rupees above zero.' using errcode = '22023';
  end if;
  if p_quarterly is not null and (p_quarterly <= 0 or p_quarterly <> round(p_quarterly)
                                  or p_quarterly > 3 * p_monthly) then
    raise exception 'Three months is a whole number of rupees, no more than three times the monthly price (Rs %).',
      to_char(3 * p_monthly, 'FM999,999,999') using errcode = '22023';
  end if;
  if p_yearly is not null and (p_yearly <= 0 or p_yearly <> round(p_yearly)
                               or p_yearly > 12 * p_monthly) then
    raise exception 'A year is a whole number of rupees, no more than twelve times the monthly price (Rs %).',
      to_char(12 * p_monthly, 'FM999,999,999') using errcode = '22023';
  end if;
  if v_reason is null or length(v_reason) < 8 then
    raise exception 'Say how this price was agreed (who, when, for how many pupils). It is kept with the price.'
      using errcode = '22023';
  end if;

  -- The price as it stood, every term, before it changes: the audit row's
  -- 'before' was read after the update and so recorded the new figures.
  v_before := jsonb_build_object(
    'monthly', public.fn__term_price(p_school_id, s.plan_code, 1),
    'quarterly', public.fn__term_price(p_school_id, s.plan_code, 3),
    'yearly', public.fn__term_price(p_school_id, s.plan_code, 12),
    'quarterly_set', s.agreed_quarterly is not null,
    'yearly_set', s.agreed_yearly is not null);

  update public.subscriptions
     set agreed_monthly = p_monthly, agreed_quarterly = p_quarterly,
         agreed_yearly = p_yearly, agreed_reason = v_reason,
         agreed_by = auth.uid(), agreed_at = now()
   where school_id = p_school_id;

  -- An Enterprise school that locked WAITING FOR ITS PRICE is treated as if
  -- its trial ended yesterday: it gets the same fourteen days to pay as any
  -- school whose trial ends, rather than staying locked until money arrives.
  -- Only then: correcting the price of a school that is locked because it has
  -- not paid must not reopen it for another fourteen days each time.
  if s.agreed_monthly is null
     and s.status = 'trialing' and s.period_end is null
     and s.trial_ends_on is not null and s.trial_ends_on < current_date - 1 then
    update public.subscriptions set trial_ends_on = current_date - 1
     where school_id = p_school_id;
  end if;

  perform public.fn__log_operator_action('price_agreed', p_school_id,
    jsonb_build_object(
      'before', jsonb_build_object('monthly', s.agreed_monthly, 'quarterly', s.agreed_quarterly,
                                   'yearly', s.agreed_yearly, 'reason', s.agreed_reason),
      'after', jsonb_build_object('monthly', p_monthly, 'quarterly', p_quarterly,
                                  'yearly', p_yearly, 'reason', v_reason)));
  insert into public.audit_log(school_id, actor, action, entity, entity_id, before, after, reason)
  values (p_school_id, auth.uid(), 'subscription_price_set', 'subscriptions', p_school_id::text,
          v_before,
          jsonb_build_object(
            'monthly', public.fn__term_price(p_school_id, s.plan_code, 1),
            'quarterly', public.fn__term_price(p_school_id, s.plan_code, 3),
            'yearly', public.fn__term_price(p_school_id, s.plan_code, 12),
            'quarterly_set', p_quarterly is not null, 'yearly_set', p_yearly is not null),
          v_reason);

  v_re := public.fn__reissue_open_invoice(p_school_id,
            format('Reissued at the agreed price of Rs %s a month', to_char(p_monthly, 'FM999,999,999')),
            'operator');
  perform public.fn__recompute_licence(p_school_id);
  -- Money the school paid while its price was being agreed goes on its first
  -- invoice now that there is one to raise.
  v_spent := public.fn__spend_credit(p_school_id, 'operator');

  return jsonb_build_object(
    'school_id', p_school_id, 'plan_code', s.plan_code,
    'monthly', public.fn__term_price(p_school_id, s.plan_code, 1),
    'quarterly', public.fn__term_price(p_school_id, s.plan_code, 3),
    'yearly', public.fn__term_price(p_school_id, s.plan_code, 12),
    'quarterly_is_derived', p_quarterly is null,
    'yearly_is_derived', p_yearly is null,
    'invoice', v_re,
    'from_credit', v_spent->'raised',
    'status', public.fn_effective_status(p_school_id));
end;
$$;
revoke all on function public.fn_platform_set_price(uuid, numeric, numeric, numeric, text) from public, anon;
grant execute on function public.fn_platform_set_price(uuid, numeric, numeric, numeric, text) to authenticated;

-- WHAT A MOVE WOULD COST. A suggestion: we decide what to charge.
-- For each paid term invoice whose period has not ended: the difference
-- between the new plan's price and the price on that invoice, for that
-- invoice's own term, times the share of ITS period that is left (all of it
-- for a period paid ahead). The first version priced the whole paid block as
-- one period at the term the school chose for the FUTURE, so after a year of
-- monthly payments it suggested a twelfth of the right charge, and a school
-- switching to yearly was told ten times too much. Periods given without an
-- invoice (before 0155, or by hand) are priced at the school's term.
create or replace function public.fn_platform_plan_change_quote(
  p_school_id uuid, p_plan_code text, p_agreed_monthly numeric default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  s public.subscriptions; v_from record; v_to record; v_old numeric; v_new numeric;
  v_days_total integer := 0; v_days_left integer := 0; v_suggest numeric := 0; v_count integer;
  r record; v_lines jsonb := '[]'::jsonb; v_line numeric; v_total integer; v_left integer;
  v_paid_to date; v_no_price boolean := false;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into s from public.subscriptions where school_id = p_school_id;
  if not found then
    raise exception 'That school has no subscription';
  end if;
  select * into v_from from public.plans where code = s.plan_code;
  select * into v_to from public.plans where code = p_plan_code and active;
  if not found then
    raise exception 'There is no plan called % on sale', p_plan_code using errcode = '22023';
  end if;
  v_count := public.fn_count_students(p_school_id);

  for r in
    select i.id, i.doc_no, i.months, i.period_start, i.period_end, i.list_amount, i.amount
      from public.platform_invoices i
     where i.school_id = p_school_id and i.kind = 'invoice' and i.purpose = 'term'
       and i.voided_at is null and i.period_end >= current_date
       and public.fn__invoice_owed(i.id) = 0
     order by i.period_start
  loop
    v_old := r.list_amount;
    v_new := case
      when not v_to.by_arrangement then public.fn__plan_price(v_to.code, r.months)
      when p_agreed_monthly is not null then case r.months
             when 1 then p_agreed_monthly
             when 3 then round(p_agreed_monthly * 3 * 0.9)
             else p_agreed_monthly * 10 end
      else public.fn__term_price(p_school_id, v_to.code, r.months) end;
    if v_new is null then
      v_no_price := true;
      continue;
    end if;
    v_total := r.period_end - r.period_start + 1;
    v_left  := least(r.period_end - greatest(current_date, r.period_start) + 1, v_total);
    v_line  := greatest(round((v_new - v_old) * v_left / v_total), 0);
    v_suggest := v_suggest + v_line;
    if v_days_total = 0 then
      v_days_total := v_total;
      v_days_left  := v_left;
    end if;
    v_paid_to := r.period_end;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'doc_no', r.doc_no, 'months', r.months, 'period_start', r.period_start,
      'period_end', r.period_end, 'old_price', v_old, 'new_price', v_new,
      'days_left', v_left, 'days_in_period', v_total, 'charge', v_line));
  end loop;

  -- Given dates with no paid invoice behind them: priced at the school's term.
  if jsonb_array_length(v_lines) = 0 and s.period_end is not null
     and s.period_end >= current_date and s.period_start is not null then
    v_old := public.fn__term_price(p_school_id, s.plan_code, s.term_months);
    v_new := case
      when not v_to.by_arrangement then public.fn__plan_price(v_to.code, s.term_months)
      when p_agreed_monthly is not null then case s.term_months
             when 1 then p_agreed_monthly
             when 3 then round(p_agreed_monthly * 3 * 0.9)
             else p_agreed_monthly * 10 end
      else public.fn__term_price(p_school_id, v_to.code, s.term_months) end;
    if v_old is not null and v_new is not null then
      v_total := least(s.period_end - s.period_start + 1,
                       public.fn__term_end(s.period_start, s.term_months) - s.period_start + 1);
      v_left  := least(s.period_end - current_date + 1, v_total);
      v_suggest := greatest(round((v_new - v_old) * v_left / v_total), 0);
      v_days_total := v_total;
      v_days_left := v_left;
      v_paid_to := s.period_end;
    else
      v_no_price := v_new is null;
    end if;
  end if;

  return jsonb_build_object(
    'school_id', p_school_id,
    'from', jsonb_build_object('code', v_from.code, 'name', v_from.name,
                               'limit', v_from.student_limit,
                               'term_price', public.fn__term_price(p_school_id, s.plan_code, s.term_months)),
    'to', jsonb_build_object('code', v_to.code, 'name', v_to.name,
                             'limit', v_to.student_limit,
                             'term_price', case
                               when not v_to.by_arrangement then public.fn__plan_price(v_to.code, s.term_months)
                               when p_agreed_monthly is not null then case s.term_months
                                      when 1 then p_agreed_monthly
                                      when 3 then round(p_agreed_monthly * 3 * 0.9)
                                      else p_agreed_monthly * 10 end
                               else public.fn__term_price(p_school_id, v_to.code, s.term_months) end,
                             'by_arrangement', v_to.by_arrangement),
    'term_months', s.term_months,
    'students', v_count,
    'fits', v_to.student_limit is null or v_count <= v_to.student_limit,
    'in_trial', s.status = 'trialing',
    'paid_from', s.period_start, 'paid_to', coalesce(v_paid_to, s.period_end),
    'days_left', v_days_left, 'days_in_period', v_days_total,
    'lines', v_lines,
    'suggested_charge', v_suggest,
    'explain', case
      when v_no_price
        then 'Agree a monthly price for Enterprise to see the difference.'
      when v_days_total = 0
        then 'Nothing has been paid for a running period, so there is nothing to top up. The new plan''s price applies from the first invoice.'
      when v_suggest = 0
        then 'The new plan costs the same or less for what is already paid. Nothing to charge; the new price applies from the next invoice.'
      when jsonb_array_length(v_lines) > 1
        then format('Rs %s: the difference between the plans for the rest of the running period and in full for the %s period(s) already paid after it, each at its own term.',
                    to_char(v_suggest, 'FM999,999,999'), jsonb_array_length(v_lines) - 1)
      else format('Rs %s for the %s day(s) left of the period paid to %s: the difference between the two plans for that %s-month period, pro rata.',
                  to_char(v_suggest, 'FM999,999,999'), v_days_left,
                  to_char(coalesce(v_paid_to, s.period_end), 'DD Mon YYYY'),
                  coalesce((v_lines->0->>'months')::integer, s.term_months)) end);
end;
$$;
revoke all on function public.fn_platform_plan_change_quote(uuid, text, numeric) from public, anon;
grant execute on function public.fn_platform_plan_change_quote(uuid, text, numeric) to authenticated;

-- MOVE A SCHOOL TO ANOTHER PLAN, now. The pupil limit changes at once; extra
-- room we gave on the old plan ends; a charge we decide on is invoiced for the
-- rest of the paid period and due today; an open invoice with nothing paid on
-- it is reissued on the new plan.
create or replace function public.fn_platform_change_plan(
  p_school_id uuid, p_plan_code text, p_reason text,
  p_charge numeric default null, p_agreed_monthly numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  s public.subscriptions; v_from record; v_to record; v_count integer;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_charge numeric := coalesce(p_charge, 0); v_inv uuid; v_doc text; v_q jsonb;
  v_re jsonb; v_months integer; v_name text; r record;
  v_withdrawn text[] := '{}'; v_still_open text[] := '{}';
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_reason is null or length(v_reason) < 8 then
    raise exception 'Say why the school is moving (their request, a call, a count). It is kept with the change.'
      using errcode = '22023';
  end if;
  select * into s from public.subscriptions where school_id = p_school_id for update;
  if not found then
    raise exception 'That school has no subscription';
  end if;
  select name into v_name from public.schools where id = p_school_id;
  select * into v_from from public.plans where code = s.plan_code;
  select * into v_to from public.plans where code = p_plan_code and active;
  if not found then
    raise exception 'There is no plan called % on sale', p_plan_code using errcode = '22023';
  end if;
  if v_to.code = s.plan_code then
    raise exception '% is already on %.', v_name, v_to.name using errcode = '22023';
  end if;

  v_count := public.fn_count_students(p_school_id);
  if v_to.student_limit is not null and v_count > v_to.student_limit then
    raise exception '% has % pupils on the roll and % covers %. Move it to a plan that fits.',
      v_name, v_count, v_to.name, v_to.student_limit using errcode = '22023';
  end if;
  if v_to.by_arrangement and p_agreed_monthly is null and s.agreed_monthly is null then
    raise exception 'Agree a monthly price for % before moving the school onto it.', v_to.name
      using errcode = '22023';
  end if;
  if v_charge < 0 or v_charge <> round(v_charge) then
    raise exception 'A charge is a whole number of rupees, nothing below zero.' using errcode = '22023';
  end if;
  if v_charge > 0 and (s.period_end is null or s.period_end < current_date) then
    raise exception 'There is no paid period running to charge the difference on. The new plan''s price applies from the next invoice.'
      using errcode = '22023';
  end if;

  v_q := public.fn_platform_plan_change_quote(p_school_id, p_plan_code, p_agreed_monthly);

  update public.subscriptions
     set plan_code = v_to.code,
         student_limit_override = null, student_limit_override_until = null,
         student_limit_override_reason = null,
         student_limit_override_by = case when s.student_limit_override is null
                                          then student_limit_override_by else auth.uid() end,
         student_limit_override_at = case when s.student_limit_override is null
                                          then student_limit_override_at else now() end,
         agreed_monthly   = case when v_to.by_arrangement then coalesce(p_agreed_monthly, s.agreed_monthly) end,
         agreed_quarterly = case when v_to.by_arrangement and p_agreed_monthly is null then s.agreed_quarterly end,
         agreed_yearly    = case when v_to.by_arrangement and p_agreed_monthly is null then s.agreed_yearly end,
         agreed_reason    = case when v_to.by_arrangement
                                 then case when p_agreed_monthly is null then s.agreed_reason else v_reason end end,
         agreed_by        = case when v_to.by_arrangement
                                 then case when p_agreed_monthly is null then s.agreed_by else auth.uid() end end,
         agreed_at        = case when v_to.by_arrangement
                                 then case when p_agreed_monthly is null then s.agreed_at else now() end end
   where school_id = p_school_id;

  if v_charge > 0 then
    v_months := greatest(1, round((s.period_end - current_date + 1) / 30.0)::integer);
    insert into public.platform_invoices
      (school_id, school_name, plan_code, plan_name, cycle, months, period_start, period_end,
       amount, list_amount, due_on, note, created_by, purpose)
    values
      (p_school_id, v_name, v_to.code, v_to.name, public.fn__cycle_for_months(s.term_months),
       v_months, current_date, s.period_end, v_charge,
       coalesce((v_q->>'suggested_charge')::numeric, v_charge), current_date,
       format('Moved from %s to %s for the rest of the period paid to %s. %s',
              v_from.name, v_to.name, to_char(s.period_end, 'DD Mon YYYY'), v_reason),
       auth.uid(), 'plan_change')
    returning id, doc_no into v_inv, v_doc;
  end if;

  v_re := public.fn__reissue_open_invoice(p_school_id,
            format('Reissued on %s after the move from %s', v_to.name, v_from.name), 'operator');

  -- A charge for moving ONTO the plan being left, still unpaid, is withdrawn:
  -- a school must not be locked for a plan it no longer has. One with money
  -- on it stays, and the reply says so.
  for r in
    select i.id, i.doc_no from public.platform_invoices i
     where i.school_id = p_school_id and i.kind = 'invoice' and i.purpose = 'plan_change'
       and i.voided_at is null and i.plan_code = v_from.code
       and (v_inv is null or i.id <> v_inv)
  loop
    if public.fn__invoice_settled(r.id) = 0 then
      perform public.fn__void_invoice(r.id,
        format('The school moved off %s, so the charge for moving onto it is withdrawn.', v_from.name),
        'operator');
      v_withdrawn := array_append(v_withdrawn, r.doc_no);
    elsif public.fn__invoice_owed(r.id) > 0 then
      v_still_open := array_append(v_still_open, r.doc_no);
    end if;
  end loop;

  -- A request for room is answered with what the move actually gives.
  update public.student_limit_requests
     set status = case when v_to.student_limit is null or v_to.student_limit >= requested_limit
                       then 'granted' else 'declined' end,
         granted_limit = case when v_to.student_limit is not null
                                   and v_to.student_limit >= requested_limit
                              then v_to.student_limit end,
         decided_by = auth.uid(), decided_at = now(),
         decision_note = case
           when v_to.student_limit is null
             then format('Moved to %s, which has no pupil limit.', v_to.name)
           when v_to.student_limit >= requested_limit
             then format('Moved to %s, which covers %s pupils.', v_to.name, v_to.student_limit)
           else format('Moved to %s, which covers %s pupils, fewer than the %s asked for. Ask again if you need more.',
                       v_to.name, v_to.student_limit, requested_limit) end
   where school_id = p_school_id and status = 'pending';

  perform public.fn__log_operator_action('plan_changed', p_school_id,
    jsonb_build_object('from', v_from.code, 'to', v_to.code, 'reason', v_reason,
                       'students', v_count, 'charge', v_charge,
                       'suggested', v_q->'suggested_charge', 'invoice_id', v_inv,
                       'agreed_monthly', p_agreed_monthly,
                       'extra_room_ended', s.student_limit_override,
                       'reissued', v_re, 'charges_withdrawn', to_jsonb(v_withdrawn),
                       'charges_still_open', to_jsonb(v_still_open)));
  insert into public.audit_log(school_id, actor, action, entity, entity_id, before, after, reason)
  values (p_school_id, auth.uid(), 'plan_changed', 'subscriptions', p_school_id::text,
          jsonb_build_object('plan_code', s.plan_code, 'extra_room', s.student_limit_override),
          jsonb_build_object('plan_code', v_to.code, 'charge', v_charge, 'invoice', v_doc),
          v_reason);

  perform public.fn_refresh_student_count(p_school_id);
  perform public.fn__apply_credit(p_school_id, v_inv);

  return jsonb_build_object(
    'school_id', p_school_id, 'from', v_from.code, 'to', v_to.code,
    'student_limit', public.fn__student_limit(p_school_id),
    'charge', v_charge, 'invoice_id', v_inv, 'doc_no', v_doc,
    'suggested_charge', v_q->'suggested_charge',
    'reissued', v_re,
    'charges_withdrawn', to_jsonb(v_withdrawn),
    'charges_still_open', to_jsonb(v_still_open),
    'status', public.fn_effective_status(p_school_id));
end;
$$;
revoke all on function public.fn_platform_change_plan(uuid, text, text, numeric, numeric) from public, anon;
grant execute on function public.fn_platform_change_plan(uuid, text, text, numeric, numeric) to authenticated;

-- THE SCHOOL CHOOSES HOW OFTEN IT PAYS. One month, three months or a year. An
-- invoice already raised with nothing paid on it is reissued for the new term.
create or replace function public.fn_choose_term(p_months integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_school uuid := public.current_school_id(); v_was integer; v_re jsonb;
begin
  if v_school is null or not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal can change the billing term'
      using errcode = '42501';
  end if;
  if p_months is null or p_months not in (1, 3, 12) then
    raise exception 'Choose one month, three months or a year';
  end if;

  select term_months into v_was from public.subscriptions where school_id = v_school for update;
  if v_was is null then
    raise exception 'This school has no subscription to change';
  end if;
  if v_was = p_months then
    return jsonb_build_object('term_months', p_months, 'changed', false,
                              'next', public.fn_my_next_payment());
  end if;

  update public.subscriptions
     set term_months = p_months, cycle = public.fn__cycle_for_months(p_months)
   where school_id = v_school;

  insert into public.audit_log(school_id, actor, action, entity, entity_id, before, after)
  values (v_school, auth.uid(), 'term_changed', 'subscriptions', v_school::text,
          jsonb_build_object('term_months', v_was),
          jsonb_build_object('term_months', p_months));

  v_re := public.fn__reissue_open_invoice(v_school,
            format('The school chose to pay for %s month(s) at a time', p_months), 'school');

  return jsonb_build_object(
    'term_months', p_months, 'changed', true,
    'invoice', v_re,
    'applies_from', case
      when v_re is null then 'your next invoice'
      when v_re ? 'kept' then 'the invoice after the one you already have'
      else 'the invoice we have just reissued' end,
    'why', v_re->>'why',
    'next', public.fn_my_next_payment());
end;
$$;

-- Kept for the old screen: the plan part is ours now, so only the term moves.
create or replace function public.fn_my_choose_plan(p_plan_code text, p_term_months integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_school uuid := public.current_school_id(); v_plan text; v_term integer;
begin
  if v_school is null or not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or the principal can change the subscription.'
      using errcode = '42501';
  end if;
  select plan_code, term_months into v_plan, v_term from public.subscriptions where school_id = v_school;
  if v_plan is null then
    raise exception 'This school has no subscription.';
  end if;
  if nullif(btrim(coalesce(p_plan_code, '')), '') is not null
     and btrim(p_plan_code) <> v_plan then
    raise exception 'Plans are changed by us, so nothing you have entered is ever caught out. '
      'Ask from Settings, Subscription: say how many pupils you have and we will move you '
      'and tell you what, if anything, it costs.'
      using errcode = '22023';
  end if;
  -- No term given means the term stands. Defaulting to a month quietly turned
  -- a yearly school monthly and reissued its year as one month.
  return public.fn_choose_term(coalesce(p_term_months, v_term));
end;
$$;


-- -----------------------------------------------------------------------------
-- 11. EXTRA ROOM, AND ASKING FOR IT
-- -----------------------------------------------------------------------------

create or replace function public.fn_platform_grant_student_limit(
  p_school_id uuid, p_limit integer, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_plan record; s public.subscriptions; v_req uuid; v_asked integer; v_until date;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into s from public.subscriptions where school_id = p_school_id for update;
  if not found then
    raise exception 'That school has no subscription';
  end if;
  select * into v_plan from public.plans where code = s.plan_code;
  if v_plan.student_limit is null then
    raise exception '% has no pupil limit, so there is no room to add.', v_plan.name
      using errcode = '22023';
  end if;
  if p_limit is null or p_limit <= v_plan.student_limit then
    raise exception 'Extra room is more than the % pupils % covers.',
      v_plan.student_limit, v_plan.name using errcode = '22023';
  end if;
  if v_note is null or length(v_note) < 8 then
    raise exception 'Say why this school gets extra room. It is shown with the allowance until it ends.'
      using errcode = '22023';
  end if;

  -- Until the next renewal: the end of what covers the school today.
  v_until := coalesce(public.fn__coverage_end(p_school_id), current_date);
  if v_until < current_date then
    v_until := current_date;
  end if;

  update public.subscriptions
     set student_limit_override        = p_limit,
         student_limit_override_until  = v_until,
         student_limit_override_reason = v_note,
         student_limit_override_by     = auth.uid(),
         student_limit_override_at     = now()
   where school_id = p_school_id;

  update public.student_limit_requests
     set status = 'granted', granted_limit = p_limit,
         decided_by = auth.uid(), decided_at = now(),
         decision_note = format('Room for %s pupils until %s. %s', p_limit,
                                to_char(v_until, 'DD Mon YYYY'), v_note)
   where school_id = p_school_id and status = 'pending'
  returning id, requested_limit into v_req, v_asked;

  insert into public.audit_log
    (school_id, actor, action, entity, entity_id, before, after, reason)
  values (p_school_id, auth.uid(), 'STUDENT_LIMIT_GRANTED', 'subscriptions', p_school_id::text,
          jsonb_build_object('override', s.student_limit_override,
                             'until', s.student_limit_override_until,
                             'plan_covers', v_plan.student_limit),
          jsonb_build_object('override', p_limit, 'until', v_until, 'request', v_req),
          v_note);
  perform public.fn__log_operator_action('student_limit_granted', p_school_id,
    jsonb_build_object('limit', p_limit, 'until', v_until, 'was', s.student_limit_override,
                       'reason', v_note));

  perform public.fn_refresh_student_count(p_school_id);

  return jsonb_build_object(
    'school_id', p_school_id, 'limit', p_limit, 'until', v_until,
    'was', s.student_limit_override, 'plan_covers', v_plan.student_limit,
    'request', v_req, 'partial', v_req is not null and p_limit < v_asked);
end;
$$;

create or replace function public.fn_platform_clear_student_limit(p_school_id uuid, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_note text := nullif(btrim(coalesce(p_note, '')), ''); s public.subscriptions;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_note is null or length(v_note) < 8 then
    raise exception 'Say why the allowance is being taken back: it may stop '
      'them admitting a pupil tomorrow, and somebody will ask.';
  end if;
  select * into s from public.subscriptions where school_id = p_school_id for update;

  update public.subscriptions
     set student_limit_override        = null,
         student_limit_override_until  = null,
         student_limit_override_reason = null,
         student_limit_override_by     = auth.uid(),
         student_limit_override_at     = now()
   where school_id = p_school_id;

  insert into public.audit_log
    (school_id, actor, action, entity, entity_id, before, after, reason)
  values (p_school_id, auth.uid(), 'STUDENT_LIMIT_CLEARED', 'subscriptions', p_school_id::text,
          jsonb_build_object('override', s.student_limit_override,
                             'until', s.student_limit_override_until),
          jsonb_build_object('override', null), v_note);
  perform public.fn__log_operator_action('student_limit_cleared', p_school_id,
    jsonb_build_object('was', s.student_limit_override, 'reason', v_note));

  perform public.fn_refresh_student_count(p_school_id);
  return jsonb_build_object('school_id', p_school_id, 'was', s.student_limit_override,
                            'limit', public.fn__student_limit(p_school_id));
end;
$$;

-- The plan a number of pupils belongs on: the smallest that covers it.
create or replace function public.fn__plan_for_students(p_students integer)
returns text
language sql
stable
set search_path = public
as $$
  select p.code from public.plans p
   where p.active and p.min_students <= greatest(coalesce(p_students, 1), 1)
     and (p.student_limit is null or p.student_limit >= greatest(coalesce(p_students, 1), 1))
   order by p.min_students desc, p.sort_order
   limit 1;
$$;
revoke all on function public.fn__plan_for_students(integer) from public, anon, authenticated;

-- What the school's own pupil-limit panel reads: the limit, the room left,
-- when extra room ends, and the plan it would move to, at that plan's price
-- for the school's term (Enterprise: priced with us).
create or replace function public.fn_my_student_limit()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  v_school uuid := public.current_school_id();
  v_limit integer; v_count integer; r record; s public.subscriptions; p public.plans;
  v_next public.plans;
begin
  if v_school is null
     or not public.may_view('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into s from public.subscriptions where school_id = v_school;
  select * into p from public.plans where code = s.plan_code;
  v_limit := public.fn__student_limit(v_school);
  v_count := public.fn_count_students(v_school);
  select * into r from public.student_limit_requests
   where school_id = v_school
   order by (status = 'pending') desc, requested_at desc, id desc
   limit 1;
  if p.student_limit is not null then
    select * into v_next from public.plans
     where active and (student_limit is null or student_limit > greatest(v_limit, p.student_limit))
     order by sort_order limit 1;
  end if;

  return jsonb_build_object(
    'students', v_count,
    'limit', v_limit,
    'plan_code', s.plan_code,
    'term_months', s.term_months,
    'plan_covers', p.student_limit,
    'room', case when v_limit is null then null else greatest(v_limit - v_count, 0) end,
    'at_limit', v_limit is not null and v_count >= v_limit,
    'warn', v_limit is not null and v_count >= ceil(v_limit * 0.9),
    'granted_extra', v_limit is distinct from p.student_limit,
    'extra_until', case when v_limit is distinct from p.student_limit
                        then s.student_limit_override_until end,
    'next_plan', case when v_next.code is null then null else jsonb_build_object(
      'code', v_next.code, 'name', v_next.name,
      'covers', v_next.student_limit,
      'by_arrangement', v_next.by_arrangement,
      'price', public.fn__plan_price(v_next.code, s.term_months),
      'term_months', s.term_months) end,
    'request', case when r.id is null then null else jsonb_build_object(
      'id', r.id, 'status', r.status, 'requested_limit', r.requested_limit,
      'requested_at', r.requested_at, 'reason', r.reason,
      'wants', r.wants,
      'granted_limit', r.granted_limit, 'decision_note', r.decision_note,
      'decided_at', r.decided_at) end);
end;
$$;

-- The change log on subscriptions now notices everything that changes what a
-- school pays or may do: the term, extra room and when it ends, an agreed
-- price, a cancellation at period end, and money owed.
create or replace function public.fn__log_subscription_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (new.plan_code, new.status, new.cycle, new.trial_ends_on, new.period_start,
      new.period_end, new.term_months, new.student_limit_override,
      new.student_limit_override_until, new.agreed_monthly, new.agreed_quarterly,
      new.agreed_yearly, new.cancel_at_period_end, new.grace_days_override,
      new.oldest_unpaid_due_on, new.suspended_at)
     is not distinct from
     (old.plan_code, old.status, old.cycle, old.trial_ends_on, old.period_start,
      old.period_end, old.term_months, old.student_limit_override,
      old.student_limit_override_until, old.agreed_monthly, old.agreed_quarterly,
      old.agreed_yearly, old.cancel_at_period_end, old.grace_days_override,
      old.oldest_unpaid_due_on, old.suspended_at)
  then
    return null;
  end if;

  perform public.fn__log_operator_action('licence_changed', new.school_id,
    jsonb_build_object(
      'from', jsonb_strip_nulls(jsonb_build_object(
        'plan_code', old.plan_code, 'status', old.status::text, 'cycle', old.cycle::text,
        'term_months', old.term_months,
        'trial_ends_on', old.trial_ends_on::text, 'period_start', old.period_start::text,
        'period_end', old.period_end::text,
        'extra_room', old.student_limit_override,
        'extra_until', old.student_limit_override_until::text,
        'agreed_monthly', old.agreed_monthly, 'agreed_quarterly', old.agreed_quarterly,
        'agreed_yearly', old.agreed_yearly,
        'cancel_at_period_end', old.cancel_at_period_end,
        'grace_days_override', old.grace_days_override,
        'oldest_unpaid_due_on', old.oldest_unpaid_due_on::text,
        'suspended_at', old.suspended_at::text)),
      'to', jsonb_strip_nulls(jsonb_build_object(
        'plan_code', new.plan_code, 'status', new.status::text, 'cycle', new.cycle::text,
        'term_months', new.term_months,
        'trial_ends_on', new.trial_ends_on::text, 'period_start', new.period_start::text,
        'period_end', new.period_end::text,
        'extra_room', new.student_limit_override,
        'extra_until', new.student_limit_override_until::text,
        'agreed_monthly', new.agreed_monthly, 'agreed_quarterly', new.agreed_quarterly,
        'agreed_yearly', new.agreed_yearly,
        'cancel_at_period_end', new.cancel_at_period_end,
        'grace_days_override', new.grace_days_override,
        'oldest_unpaid_due_on', new.oldest_unpaid_due_on::text,
        'suspended_at', new.suspended_at::text))));
  return null;
end;
$$;

create or replace function public.fn_request_student_limit(
  p_requested integer, p_reason text, p_wants text default 'more_room')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_school uuid := public.current_school_id();
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_wants  text := lower(nullif(btrim(coalesce(p_wants, '')), ''));
  v_limit  integer; v_count integer; v_id uuid; v_sug text;
begin
  if v_school is null or not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or the principal can ask for more room'
      using errcode = '42501';
  end if;
  if p_requested is null or p_requested < 1 or p_requested > 100000 then
    raise exception 'Say how many pupils you need room for';
  end if;
  v_wants := coalesce(v_wants, 'more_room');
  if v_wants not in ('more_room', 'move_up') then
    raise exception 'A request is either for more room on your plan or to move '
      'up a plan, and this one says "%"', v_wants;
  end if;
  if v_reason is null or length(v_reason) < 8 then
    raise exception 'Say briefly why you need the room: it is what we read '
      'when we decide, and a request with nothing in it waits longer.';
  end if;

  v_limit := public.fn__student_limit(v_school);
  v_count := public.fn_count_students(v_school);

  if v_limit is null then
    raise exception 'Your plan has no pupil limit, so there is nothing to ask for.'
      using errcode = '22023';
  end if;
  if p_requested <= v_limit then
    raise exception 'Your plan already covers % pupils, so there is nothing to '
      'ask for. Ask for more than % if you need it.', v_limit, v_limit;
  end if;
  if p_requested <= v_count then
    raise exception 'You have % pupils on the roll now, so room for % would still '
      'leave admissions paused. Ask for more than %.', v_count, p_requested, v_count;
  end if;
  if exists (select 1 from public.student_limit_requests
              where school_id = v_school and status = 'pending') then
    raise exception 'You already have a request waiting with us, for room for '
      '% pupils. We will answer that one, there is no need to send another.',
      (select requested_limit from public.student_limit_requests
        where school_id = v_school and status = 'pending');
  end if;

  insert into public.student_limit_requests
    (school_id, requested_limit, count_at_request, limit_at_request, reason,
     wants, requested_by)
  values (v_school, p_requested, v_count, v_limit, v_reason, v_wants, auth.uid())
  returning id into v_id;

  insert into public.audit_log
    (school_id, actor, actor_role, action, entity, entity_id, after, reason)
  values (v_school, auth.uid(),
          (select role from public.profiles where id = auth.uid() and school_id = v_school),
          'STUDENT_LIMIT_REQUESTED', 'subscriptions', v_school::text,
          jsonb_build_object('requested_limit', p_requested,
                             'students_now', v_count, 'plan_covers', v_limit,
                             'wants', v_wants),
          v_reason);

  v_sug := public.fn__plan_for_students(greatest(p_requested, v_count + 1));

  return jsonb_build_object(
    'id', v_id, 'status', 'pending', 'requested_limit', p_requested,
    'students_now', v_count, 'plan_covers', v_limit, 'wants', v_wants,
    'suggested_plan', v_sug,
    'what_next', case when v_wants = 'move_up' then
        'We will work out what the bigger plan costs for the rest of your period '
        || 'and tell you before anything changes. The answer will appear on this screen.'
      else
        'We will look at this and come back to you, usually the same working '
        || 'day. Nothing changes in the meantime, nothing you have already '
        || 'entered is affected, and extra room on your plan lasts until your '
        || 'next renewal. The answer will appear on this screen.'
      end);
end;
$$;

create or replace function public.fn_platform_limit_requests(p_status text default 'pending')
returns table(id uuid, school_id uuid, school_name text, contact_name text, contact_phone text,
              plan_code text, requested_limit integer, reason text, wants text,
              requested_at timestamptz, count_at_request integer, students_now integer,
              plan_covers integer, effective_limit integer, suggested_plan text,
              suggested_plan_covers integer, status text, decided_at timestamptz,
              granted_limit integer, decision_note text)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
    select r.id, r.school_id, s.name, s.contact_name, s.contact_phone,
           sub.plan_code, r.requested_limit, r.reason, r.wants, r.requested_at,
           r.count_at_request,
           public.fn_count_students(r.school_id),
           p.student_limit,
           public.fn__student_limit(r.school_id),
           sug.code, sug.student_limit,
           r.status, r.decided_at, r.granted_limit, r.decision_note
      from public.student_limit_requests r
      join public.schools s on s.id = r.school_id
      join public.subscriptions sub on sub.school_id = r.school_id
      join public.plans p on p.code = sub.plan_code
      left join public.plans sug on sug.code = public.fn__plan_for_students(r.requested_limit)
     where coalesce(nullif(btrim(p_status), ''), 'pending') in ('all', r.status)
     order by case when r.status = 'pending' then 0 else 1 end, r.requested_at;
end;
$$;


-- -----------------------------------------------------------------------------
-- 12. SIGNING UP: THE NUMBER OF PUPILS DECIDES THE PLAN
-- -----------------------------------------------------------------------------

-- Every way a school comes into existence goes through here, so a trial is the
-- same length, the term and cycle agree, and the plan is one on sale.
-- p_trial_days is days of access: fourteen days means today and the next
-- thirteen, so trial_ends_on is today + 13.
create or replace function public.fn__create_school(
  p_name text, p_city text, p_region text, p_contact_name text,
  p_contact_phone text, p_contact_email text, p_notes text,
  p_plan_code text, p_term_months integer, p_trial_days integer,
  p_declared_students integer)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  v_id uuid; v_plan record; v_term integer := coalesce(p_term_months, 1);
  v_days integer := coalesce(p_trial_days, 14); v_trial date;
  v_region text := nullif(btrim(coalesce(p_region, '')), '');
begin
  if nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'School name is required' using errcode = '22023';
  end if;
  select * into v_plan from public.plans where code = p_plan_code and active;
  if not found then
    raise exception 'There is no plan called "%" on sale. The plans are: %', p_plan_code,
      (select string_agg(code, ', ' order by sort_order) from public.plans where active)
      using errcode = '22023';
  end if;
  if v_term not in (1, 3, 12) then
    raise exception 'Choose one month, three months or a year' using errcode = '22023';
  end if;
  if v_days < 0 or v_days > 180 then
    raise exception 'A trial must be between 0 and 180 days' using errcode = '22023';
  end if;
  if p_declared_students is not null and (p_declared_students < 1 or p_declared_students > 100000) then
    raise exception 'Enter the number of pupils on your roll, between 1 and 100,000' using errcode = '22023';
  end if;
  if v_region is not null and not (v_region = any (public.fn_signup_regions())) then
    raise exception 'There is no region called "%". Choose one of: %',
      v_region, array_to_string(public.fn_signup_regions(), ', ') using errcode = '22023';
  end if;
  v_trial := current_date + v_days - 1;

  insert into public.schools (name, city, region, contact_name, contact_phone, contact_email, notes)
  values (btrim(p_name), nullif(btrim(coalesce(p_city, '')), ''), v_region,
          nullif(btrim(coalesce(p_contact_name, '')), ''),
          nullif(btrim(coalesce(p_contact_phone, '')), ''),
          nullif(btrim(lower(coalesce(p_contact_email, ''))), ''),
          nullif(btrim(coalesce(p_notes, '')), ''))
  returning id into v_id;

  insert into public.subscriptions
    (school_id, plan_code, status, cycle, term_months, trial_ends_on, declared_students)
  values
    (v_id, v_plan.code, 'trialing', public.fn__cycle_for_months(v_term), v_term,
     v_trial, p_declared_students);

  return jsonb_build_object(
    'school_id',      v_id,
    'trial_ends_on',  v_trial,
    'trial_days',     v_days,
    'plan_code',      v_plan.code,
    'plan_name',      v_plan.name,
    'by_arrangement', v_plan.by_arrangement,
    'student_limit',  v_plan.student_limit,
    'declared_students', p_declared_students,
    'term_months',    v_term,
    'region',         v_region,
    'first_amount',   public.fn__plan_price(v_plan.code, v_term));
end;
$$;
revoke all on function public.fn__create_school(text, text, text, text, text, text, text, text, integer, integer, integer) from public, anon, authenticated;

-- PUBLIC SIGNUP. Called by the signup-school Edge Function with the service
-- key. The school says how many pupils it has; the plan follows:
--   up to 280 Starter, up to 1,000 Growth, more than 1,000 Enterprise.
-- Enterprise gets the same fourteen-day trial with no pupil limit, and locks
-- when the trial ends unless we have agreed a price with it by then.
create or replace function public.fn_signup_school_for_students(
  p_name text, p_city text default null, p_contact_name text default null,
  p_contact_phone text default null, p_contact_email text default null,
  p_region text default null, p_students integer default null,
  p_term_months integer default 1)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare v_plan text;
begin
  if p_students is null or p_students < 1 or p_students > 100000 then
    raise exception 'Enter the number of pupils on your roll, between 1 and 100,000'
      using errcode = '22023';
  end if;
  v_plan := public.fn__plan_for_students(p_students);
  if v_plan is null then
    raise exception 'No plan covers % pupils. Please call us.', p_students using errcode = '22023';
  end if;
  return public.fn__create_school(p_name, p_city, p_region, p_contact_name, p_contact_phone,
                                  p_contact_email, null, v_plan, coalesce(p_term_months, 1),
                                  14, p_students);
end;
$$;
revoke all on function public.fn_signup_school_for_students(text, text, text, text, text, text, integer, integer) from public, anon, authenticated;
grant execute on function public.fn_signup_school_for_students(text, text, text, text, text, text, integer, integer) to service_role;

-- The older signup calls, for an Edge Function that has not been redeployed.
-- They name a plan instead of a number; only plans with a list price can be
-- named, and the term defaults to one month everywhere.
create or replace function public.fn_signup_school_on_plan_in_region(
  p_name text, p_city text default null, p_contact_name text default null,
  p_contact_phone text default null, p_contact_email text default null,
  p_plan_code text default 'starter', p_term_months integer default 1,
  p_region text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare v_code text := coalesce(nullif(btrim(coalesce(p_plan_code, '')), ''), 'starter');
begin
  if not exists (select 1 from public.plans where code = v_code and active and not by_arrangement) then
    raise exception 'There is no plan called "%" to sign up on. The plans with a list price are: %. A larger school tells us how many pupils it has instead.',
      v_code,
      (select string_agg(code, ', ' order by sort_order) from public.plans
        where active and not by_arrangement)
      using errcode = '22023';
  end if;
  return public.fn__create_school(p_name, p_city, p_region, p_contact_name, p_contact_phone,
                                  p_contact_email, null, v_code, coalesce(p_term_months, 1),
                                  14, null);
end;
$$;

create or replace function public.fn_signup_school_on_plan(
  p_name text, p_city text default null, p_contact_name text default null,
  p_contact_phone text default null, p_contact_email text default null,
  p_plan_code text default 'starter', p_term_months integer default 1)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.fn_signup_school_on_plan_in_region(
    p_name, p_city, p_contact_name, p_contact_phone, p_contact_email,
    p_plan_code, p_term_months, null);
end;
$$;

create or replace function public.fn_signup_school(
  p_name text, p_city text default null, p_contact_name text default null,
  p_contact_phone text default null, p_contact_email text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.fn_signup_school_on_plan_in_region(
    p_name, p_city, p_contact_name, p_contact_phone, p_contact_email, 'starter', 1, null);
end;
$$;

-- What the signup page shows before anybody creates anything. Enterprise is
-- listed with no price: the school sees it is priced with them, and how.
create or replace function public.fn_signup_plans()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code',           p.code,
           'name',           p.name,
           'student_limit',  p.student_limit,
           'min_students',   p.min_students,
           'by_arrangement', p.by_arrangement,
           'month_price',    case when p.by_arrangement then null else p.price_monthly end,
           'terms', case when p.by_arrangement then '[]'::jsonb else (
             select jsonb_agg(jsonb_build_object(
                      'months', m.months,
                      'amount', public.fn__plan_price(p.code, m.months),
                      'per_month', round(public.fn__plan_price(p.code, m.months) / m.months),
                      'saving', greatest(0, p.price_monthly * m.months
                                            - public.fn__plan_price(p.code, m.months)))
                      order by m.months)
               from (values (1), (3), (12)) as m(months)) end,
           'how_priced', case when p.by_arrangement then
             'We agree a monthly price with you. Three months is 10% off it and a year is two months free.'
             end
         ) order by p.sort_order), '[]'::jsonb)
    from public.plans p
   where p.active;
$$;
revoke all on function public.fn_signup_plans() from public;
grant execute on function public.fn_signup_plans() to anon, authenticated;

-- The operator's own way in. Same rules: a plan on sale, a term of 1, 3 or 12
-- months, a trial in days of access. An Enterprise school can be given its
-- price here.
create or replace function public.fn_platform_create_school(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  v_name text; v_plan text; v_students integer; v_res jsonb; v_monthly numeric;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'Give the school''s details';
  end if;
  perform public.fn__only_these_keys(jsonb_build_array(p),
    '{name,city,region,contact_name,contact_phone,contact_email,notes,plan_code,term_months,trial_days,students,agreed_monthly,agreed_reason}'::text[],
    'A new school');

  v_name := nullif(btrim(coalesce(p->>'name', '')), '');
  if v_name is null then
    raise exception 'The school name is required';
  end if;
  if exists (select 1 from public.schools
              where lower(btrim(name)) = lower(v_name) and archived_at is null) then
    raise exception 'A school called "%" already exists (%). Archive it first if this is a different one.',
      v_name, (select id from public.schools
                where lower(btrim(name)) = lower(v_name) and archived_at is null limit 1);
  end if;

  v_students := nullif(p->>'students', '')::integer;
  v_plan := coalesce(nullif(btrim(coalesce(p->>'plan_code', '')), ''),
                     public.fn__plan_for_students(v_students), 'starter');

  v_res := public.fn__create_school(
    v_name, p->>'city', p->>'region', p->>'contact_name', p->>'contact_phone',
    p->>'contact_email', p->>'notes', v_plan,
    coalesce(nullif(p->>'term_months', '')::integer, 1),
    coalesce(nullif(p->>'trial_days', '')::integer, 14),
    v_students);

  -- A price set here needs the same who, when and for how many as any other
  -- price we agree: fn_platform_set_price refuses it without one. A reason
  -- written for the operator ('Agreed when the school was created') would be a
  -- record nobody made.
  v_monthly := nullif(p->>'agreed_monthly', '')::numeric;
  if v_monthly is not null then
    perform public.fn_platform_set_price((v_res->>'school_id')::uuid, v_monthly, null, null,
      p->>'agreed_reason');
  end if;

  perform public.fn__log_operator_action('school_created', (v_res->>'school_id')::uuid,
    jsonb_build_object('name', v_name, 'plan_code', v_plan, 'students', v_students,
                       'trial_ends_on', v_res->'trial_ends_on',
                       'agreed_monthly', v_monthly));

  return v_res || jsonb_build_object(
    'name', v_name,
    'still_needed', 'Nobody can sign in to this school yet. Create the owner '
      || 'login, or send them the signup link.');
end;
$$;

create or replace function public.fn_provision_school(
  p_name text, p_plan_code text default 'starter', p_city text default null,
  p_contact_name text default null, p_contact_phone text default null,
  p_contact_email text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return public.fn__create_school(p_name, p_city, null, p_contact_name, p_contact_phone,
                                  p_contact_email, null, coalesce(p_plan_code, 'starter'),
                                  1, 14, null);
end;
$$;

-- Reinstating puts a school back on what it had: its paid period if it ever
-- paid, otherwise its trial. Its dates then decide, as for anybody, so an
-- expired trial is not turned into free access for ever.
create or replace function public.fn_platform_reinstate_subscription(p_school_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  v_sub record; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_new public.subscription_status; v_archived timestamptz; v_effective public.subscription_status;
  v_spent jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into v_sub from public.subscriptions where school_id = p_school_id for update;
  if not found then
    raise exception 'Unknown school %', p_school_id;
  end if;
  -- A school we cancelled, or one that asked to stop at the end of its period
  -- (before or after that end). The second could never come back before:
  -- invoicing refused it, this refused it, and its money sat as credit.
  if v_sub.status <> 'cancelled' and not v_sub.cancel_at_period_end then
    raise exception 'That subscription is not cancelled - there is nothing to reinstate';
  end if;
  select archived_at into v_archived from public.schools where id = p_school_id;
  if v_archived is not null then
    raise exception 'That school is archived. Bring them back into the list first, '
      'then reinstate the subscription.';
  end if;

  -- Paid at some point means active; never paid means back on the trial. The
  -- recompute below corrects either from what is actually paid.
  v_new := case when v_sub.status <> 'cancelled' then v_sub.status
                when v_sub.period_end is not null then 'active'::public.subscription_status
                else 'trialing'::public.subscription_status end;

  -- A school that comes back after its period ended had no access since, so
  -- it is closed from the day after that period until it pays, and billed
  -- from the day it pays: it used no grace.
  update public.subscriptions
     set status = v_new, cancel_at_period_end = false,
         closed_from = case when greatest(period_end, trial_ends_on) < current_date
                            then greatest(period_end, trial_ends_on) + 1 else closed_from end
   where school_id = p_school_id;
  perform public.fn__recompute_licence(p_school_id);
  -- Money it paid while it was away goes on its next term.
  v_spent := public.fn__spend_credit(p_school_id, 'operator');
  v_effective := public.fn_effective_status(p_school_id);

  perform public.fn__log_operator_action('subscription_reinstated', p_school_id,
    jsonb_build_object('reason', v_reason, 'status', v_new,
                       'was_cancel_at_period_end', v_sub.cancel_at_period_end,
                       'effective_status', v_effective,
                       'period_end', v_sub.period_end,
                       'trial_ends_on', v_sub.trial_ends_on,
                       'from_credit', v_spent->'raised'));
  insert into public.audit_log(school_id, actor, action, entity, entity_id, reason)
  values (p_school_id, auth.uid(), 'subscription_reinstated', 'subscriptions',
          p_school_id::text, v_reason);

  return jsonb_build_object(
    'school_id', p_school_id,
    'status', v_effective,
    'back_in', v_effective not in ('locked', 'cancelled'),
    'note', case
      when v_effective in ('locked', 'cancelled')
        then 'Reinstated, but nothing paid covers today, so they are still locked. '
          || 'Paying their next invoice is what opens the software.'
      when v_effective = 'grace'
        then 'Reinstated. They are inside their grace window, so the software works '
          || 'while the payment arrives.'
      when v_effective = 'trialing'
        then format('Reinstated onto the trial they already had, which ends %s.',
                    to_char(v_sub.trial_ends_on, 'DD Mon YYYY'))
      else format('Reinstated. They are back in, paid to %s.',
                  to_char((select period_end from public.subscriptions where school_id = p_school_id),
                          'DD Mon YYYY')) end,
    'invoiced', jsonb_array_length(coalesce(v_spent->'raised', '[]'::jsonb)) > 0,
    'from_credit', v_spent->'raised');
end;
$$;

-- ASKING TO STOP, AND CHANGING YOUR MIND. Stopping at the end of the period
-- voids the invoice already raised for the period after it, when nothing is
-- paid on it: a school that is leaving was otherwise told it owed a month it
-- will never have, and carried it as debt. Restarting works before and after
-- that end; after it, the school is locked until its next payment, like any
-- school whose period has ended. The old sentence sent it to choose a plan,
-- which no screen lets a school do.
create or replace function public.fn_cancel_my_subscription(p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  v_school uuid := public.current_school_id();
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_sub record; v_cov date; r record; v_voided text[] := '{}';
begin
  if v_school is null or not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal can cancel the subscription'
      using errcode = '42501';
  end if;
  select * into v_sub from public.subscriptions where school_id = v_school for update;
  if not found then
    raise exception 'There is no subscription to cancel';
  end if;
  if v_sub.status = 'cancelled' then
    raise exception 'This subscription is already cancelled';
  end if;
  if v_sub.cancel_at_period_end then
    raise exception 'This subscription is already set to end. Nothing further is due.';
  end if;
  v_cov := public.fn__coverage_end(v_school);

  update public.subscriptions
     set cancel_at_period_end = true,
         -- Auto-renewal off in the same statement. Leaving it on would mean the
         -- renewal runner and this flag disagreeing about whether the school is
         -- a customer, and the schema's own constraint would still be satisfied.
         auto_renew = false
   where school_id = v_school;

  -- Invoices for the time after the end, with nothing paid or credited on them.
  for r in
    select i.id, i.doc_no from public.platform_invoices i
     where i.school_id = v_school and i.kind = 'invoice' and i.purpose = 'term'
       and i.voided_at is null and v_cov is not null and i.period_start > v_cov
       and public.fn__invoice_settled(i.id) = 0
  loop
    perform public.fn__void_invoice(r.id,
      format('The school asked to stop at the end of its period on %s.',
             to_char(v_cov, 'DD Mon YYYY')), 'school');
    v_voided := array_append(v_voided, r.doc_no);
  end loop;

  -- Recorded on BOTH sides. The audit_log entry is the school's own record of
  -- who ended it, and the operator action is the churn data.
  insert into public.audit_log(school_id, actor, action, entity, entity_id, reason)
  values (v_school, auth.uid(), 'subscription_cancel_requested', 'subscriptions',
          v_school::text, v_reason);
  perform public.fn__log_operator_action('cancel_requested_by_school', v_school,
    jsonb_build_object('reason', v_reason, 'runs_until', v_cov, 'voided', to_jsonb(v_voided)));

  return jsonb_build_object(
    'cancelled', true,
    'runs_until', v_cov,
    'voided', to_jsonb(v_voided),
    -- What they keep, said plainly, because the fear that stops people
    -- cancelling is not knowing whether their records go with it.
    'keeps', 'Nothing is deleted. You keep everything until the date above, and '
      || 'you can download all of your records at any time, including afterwards.',
    'reversible', 'You can start again from this screen at any time. Before that date '
      || 'nothing will have changed; after it, the software opens again when your next '
      || 'payment reaches us.',
    'next', public.fn_my_next_payment());
end;
$$;
revoke all on function public.fn_cancel_my_subscription(text) from public, anon;
grant execute on function public.fn_cancel_my_subscription(text) to authenticated;

create or replace function public.fn_resume_my_subscription()
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare v_school uuid := public.current_school_id(); v_sub record; v_cov date;
        v_spent jsonb; v_status public.subscription_status;
begin
  if v_school is null or not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal can restart the subscription'
      using errcode = '42501';
  end if;
  select * into v_sub from public.subscriptions where school_id = v_school for update;
  if not found or not v_sub.cancel_at_period_end then
    raise exception 'This subscription is not set to end, so there is nothing to restart';
  end if;
  v_cov := public.fn__coverage_end(v_school);

  -- After its end the school had no access, so it used no grace: it is closed
  -- from the day after its period until it pays, and billed from that day.
  update public.subscriptions
     set cancel_at_period_end = false,
         closed_from = case when v_cov is not null and v_cov < current_date
                            then v_cov + 1 else closed_from end
   where school_id = v_school;
  perform public.fn__recompute_licence(v_school);
  v_spent := public.fn__spend_credit(v_school, 'school');
  v_status := public.fn_effective_status(v_school);

  insert into public.audit_log(school_id, actor, action, entity, entity_id)
  values (v_school, auth.uid(), 'subscription_cancel_withdrawn', 'subscriptions',
          v_school::text);
  perform public.fn__log_operator_action('cancel_withdrawn_by_school', v_school,
    jsonb_build_object('after_the_end', v_cov is not null and current_date > v_cov,
                       'status', v_status, 'from_credit', v_spent->'raised'));

  return jsonb_build_object(
    'resumed', true,
    'status', v_status,
    -- Deliberately NOT turning auto_renew back on. It was switched off by the
    -- cancellation and it depends on a payment method the school may since have
    -- removed; the schema would refuse the combination anyway. Saying so beats
    -- a school assuming renewal is automatic again when it is not.
    'note', case
      when v_status in ('locked', 'cancelled')
        then 'Welcome back. Your period has ended, so the software opens again when your '
          || 'next payment reaches us. What to pay is shown below; automatic renewal was '
          || 'switched off when you cancelled.'
      when v_cov is not null and v_cov < current_date
        then format('Welcome back. Your period ended on %s, so your next payment is due '
          || 'now, and the software keeps working until %s while it arrives. Automatic '
          || 'renewal was switched off when you cancelled.',
          to_char(v_cov, 'FMDD Mon YYYY'),
          to_char(public.fn__lock_day(v_school) - 1, 'FMDD Mon YYYY'))
      else 'Your subscription will carry on as before. Check how you pay below: '
        || 'automatic renewal was switched off when you cancelled.' end,
    'next', public.fn_my_next_payment());
end;
$$;
revoke all on function public.fn_resume_my_subscription() from public, anon;
grant execute on function public.fn_resume_my_subscription() to authenticated;


-- -----------------------------------------------------------------------------
-- 13. WHAT EVERYBODY IS TOLD
-- -----------------------------------------------------------------------------

-- ONE DESCRIPTION OF A SCHOOL'S SUBSCRIPTION, for its own screens and for
-- ours. p_operator adds what only we see (how a price was agreed, why extra
-- room was given). Every date and amount on any screen comes from here.
create or replace function public.fn__subscription_view(p_school_id uuid, p_operator boolean)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  s public.subscriptions; p public.plans; v_status public.subscription_status;
  v_cov date; v_grace integer; v_limit integer; v_count integer; v_open uuid;
  v_owed numeric; v_credit numeric; v_next date; v_q jsonb; v_lock date;
  v_why text; v_pay numeric := 0; v_priced boolean; v_inv record; v_terms jsonb;
  v_month numeric;
begin
  select * into s from public.subscriptions where school_id = p_school_id;
  if not found then
    return null;
  end if;
  select * into p from public.plans where code = s.plan_code;
  v_status := public.fn_effective_status(p_school_id);
  v_cov    := public.fn__coverage_end(p_school_id);
  v_grace  := public.fn__grace_for(p_school_id);
  v_limit  := public.fn__student_limit(p_school_id);
  v_count  := public.fn_count_students(p_school_id);
  v_open   := public.fn__open_term_invoice(p_school_id);
  v_credit := public.fn__unallocated(p_school_id);
  v_next   := public.fn__next_period_start(p_school_id);
  v_month  := public.fn__term_price(p_school_id, s.plan_code, 1);
  v_priced := v_month is not null and v_month > 0;

  -- Owed on live invoices, leaving out lapsed ones: they are closed the moment
  -- the school pays, and what was paid on them comes back as credit. So a
  -- locked school is asked for what will actually open it again.
  select coalesce(sum(public.fn__invoice_owed(i.id)), 0) into v_owed
    from public.platform_invoices i
   where i.school_id = p_school_id and i.kind = 'invoice' and i.voided_at is null
     and not public.fn__invoice_lapsed(i.id);
  v_credit := v_credit + public.fn__on_lapsed(p_school_id);

  if v_open is null and v_priced then
    v_q := public.fn__quote(p_school_id, s.plan_code, s.term_months, v_next);
  end if;

  -- The first day the school is locked if nothing more is paid. A school that
  -- asked to stop is closed the day after its period, with no grace; one that
  -- is already closed has no day to count down to.
  v_lock := case
    when v_status in ('locked', 'cancelled') or s.suspended_at is not null then null
    when s.cancel_at_period_end then least(v_cov + 1, public.fn__lock_day(p_school_id))
    else coalesce(public.fn__lock_day(p_school_id), current_date) end;

  v_why := case
    when s.suspended_at is not null then 'suspended'
    when v_status = 'cancelled' then 'cancelled'
    when v_status <> 'locked' then null
    when p.by_arrangement and s.agreed_monthly is null then 'needs_price'
    when s.oldest_unpaid_due_on is not null
         and current_date >= s.oldest_unpaid_due_on + v_grace then 'unpaid'
    else 'expired' end;

  -- What to pay now: what is owed, plus, with no term invoice raised yet, the
  -- next term once it is within thirty days or the school has run out. Credit
  -- comes off. A locked school with a plan-change charge outstanding is asked
  -- for both at once, because paying only the charge would leave it locked.
  v_pay := v_owed
         + case when v_open is null and v_q is not null
                     and coalesce((v_q->>'priced')::boolean, false)
                     and s.status <> 'cancelled' and s.suspended_at is null
                     and not s.cancel_at_period_end
                     and (v_cov is null or v_cov - current_date <= 30
                          or v_status in ('grace', 'locked'))
                then (v_q->>'amount')::numeric else 0 end;
  v_pay := greatest(v_pay - v_credit, 0);

  select i.* into v_inv from public.platform_invoices i where i.id = v_open;

  -- Each term as the school would be invoiced for it next, its code included.
  if v_priced then
    select jsonb_agg(jsonb_build_object(
             'months', t.m,
             'term_price', (q.q->>'term_price')::numeric,
             'amount', (q.q->>'amount')::numeric,
             'per_month', round((q.q->>'amount')::numeric / t.m),
             'saving', greatest(v_month * t.m - (q.q->>'amount')::numeric, 0),
             'discount_amount', (q.q->>'discount_amount')::numeric,
             'discount_note', q.q->>'discount_note',
             'chosen', t.m = s.term_months) order by t.m)
      into v_terms
      from (values (1), (3), (12)) as t(m)
      cross join lateral (select public.fn__quote(p_school_id, s.plan_code, t.m, v_next) as q) q;
  end if;

  return jsonb_build_object(
    'plan', jsonb_build_object('code', p.code, 'name', p.name,
                               'by_arrangement', p.by_arrangement,
                               'student_limit', p.student_limit,
                               'min_students', p.min_students),
    'price', jsonb_build_object(
      'priced', v_priced,
      'month', v_month,
      'quarter', public.fn__term_price(p_school_id, s.plan_code, 3),
      'year', public.fn__term_price(p_school_id, s.plan_code, 12),
      'agreed', p.by_arrangement and s.agreed_monthly is not null,
      'agreed_at', case when p.by_arrangement then s.agreed_at end,
      'agreed_reason', case when p_operator and p.by_arrangement then s.agreed_reason end,
      'quarter_set', s.agreed_quarterly is not null,
      'year_set', s.agreed_yearly is not null),
    'terms', coalesce(v_terms, '[]'::jsonb),
    'term_months', s.term_months,
    'status', v_status,
    'stored_status', s.status,
    'in_trial', s.status = 'trialing',
    'trial_ends_on', s.trial_ends_on,
    'paid_from', s.period_start,
    'paid_through', s.period_end,
    'covered_to', v_cov,
    'grace_days', v_grace,
    'locks_on', v_lock,
    'days_to_lock', case when v_lock is null then 0 else v_lock - current_date end,
    'locked_because', v_why,
    'needs_price', p.by_arrangement and s.agreed_monthly is null,
    'cancel_at_period_end', s.cancel_at_period_end,
    'suspended', s.suspended_at is not null,
    'suspend_reason', s.suspend_reason,
    'students', jsonb_build_object(
      'count', v_count, 'limit', v_limit, 'plan_limit', p.student_limit,
      'extra', case when v_limit is distinct from p.student_limit then s.student_limit_override end,
      'extra_until', case when v_limit is distinct from p.student_limit then s.student_limit_override_until end,
      'extra_reason', case when p_operator and v_limit is distinct from p.student_limit
                           then s.student_limit_override_reason end,
      'extra_expired', s.student_limit_override is not null
                       and s.student_limit_override_until < current_date,
      'declared', s.declared_students,
      'room', case when v_limit is null then null else greatest(v_limit - v_count, 0) end,
      'warn', v_limit is not null and v_count >= ceil(v_limit * 0.9),
      'full', v_limit is not null and v_count >= v_limit,
      'over', v_limit is not null and v_count > v_limit),
    'open_invoice', case when v_inv.id is null then null else jsonb_build_object(
      'id', v_inv.id, 'doc_no', v_inv.doc_no, 'months', v_inv.months,
      'period_start', v_inv.period_start, 'period_end', v_inv.period_end,
      'amount', v_inv.amount, 'total', v_inv.amount + v_inv.tax_amount,
      'paid', public.fn__invoice_settled(v_inv.id),
      'owed', public.fn__invoice_owed(v_inv.id),
      'due_on', v_inv.due_on, 'discount_code', v_inv.discount_code,
      'discount_amount', v_inv.discount_amount) end,
    'owed', v_owed,
    'credit', v_credit,
    'next', case when v_q is null then null else jsonb_build_object(
      'period_start', v_next, 'months', s.term_months, 'quote', v_q) end,
    'pay_now', v_pay,
    'can_request_invoice', v_open is null and v_priced and s.status <> 'cancelled'
      and s.suspended_at is null and not s.cancel_at_period_end
      and (v_cov is null or v_cov - current_date <= 30));
end;
$$;
revoke all on function public.fn__subscription_view(uuid, boolean) from public, anon, authenticated;

-- THE BANNER. Same keys as before so an older screen still reads it; the
-- margin is gone (margin_limit is the limit, limit_state is ok or over).
create or replace function public.fn_my_licence()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  v_school uuid := public.current_school_id();
  v jsonb; v_status text; v_expiry date; v_limit integer; v_count integer;
begin
  if v_school is null then
    return jsonb_build_object('ok', false, 'reason', 'no_school');
  end if;
  v := public.fn__subscription_view(v_school, false);
  if v is null then
    return jsonb_build_object('ok', false, 'reason', 'no_subscription');
  end if;
  v_status := v->>'status';
  v_limit  := (v->'students'->>'limit')::integer;
  v_count  := (v->'students'->>'count')::integer;
  v_expiry := case
    when v_status in ('trialing', 'active') then least((v->>'covered_to')::date,
                                                       (v->>'locks_on')::date - 1)
    when v_status = 'grace' then (v->>'locks_on')::date - 1
    else null end;

  return jsonb_build_object(
    'ok',             true,
    'school_id',      v_school,
    'status',         v_status,
    'locked',         v_status in ('locked', 'cancelled'),
    'locked_because', v->'locked_because',
    'can_read',       true,
    'can_export',     true,
    'can_operate',    v_status in ('trialing', 'active', 'grace'),
    'plan_code',      v->'plan'->'code',
    'plan_name',      v->'plan'->'name',
    'by_arrangement', v->'plan'->'by_arrangement',
    'needs_price',    v->'needs_price',
    'cycle',          public.fn__cycle_for_months((v->>'term_months')::integer),
    'term_months',    v->'term_months',
    'price_monthly',  v->'price'->'month',
    'price_quarterly', v->'price'->'quarter',
    'price_yearly',   v->'price'->'year',
    'expires_on',     v_expiry,
    'days_left',      case when v_expiry is null then null else v_expiry - current_date end,
    'locks_on',       v->'locks_on',
    'paid_through',   v->'paid_through',
    'trial_ends_on',  v->'trial_ends_on',
    'pay_now',        v->'pay_now',
    'student_count',  v_count,
    'student_limit',  v_limit,
    'plan_student_limit', v->'students'->'plan_limit',
    'limit_is_granted', v_limit is distinct from (v->'students'->>'plan_limit')::integer,
    'extra_until',    v->'students'->'extra_until',
    'room',           v->'students'->'room',
    'at_limit',       coalesce((v->'students'->>'full')::boolean, false),
    'warn_limit',     coalesce((v->'students'->>'warn')::boolean, false),
    'limit_notice_staff', case
      when v_limit is null then null
      when v_count >= v_limit then
        format('The roll is full: %s pupils, which is everything this ' ||
               'school''s plan covers. New admissions are paused until the ' ||
               'owner or principal asks for more room. Everything else, ' ||
               'including the register and the fees, works normally.', v_count)
      when v_count >= ceil(v_limit * 0.9) then
        format('%s of %s places on the roll are used. When the last one ' ||
               'goes, new admissions pause until the owner or principal ' ||
               'asks for more room, so it is worth mentioning to them.', v_count, v_limit)
      else null end,
    'margin_limit',   v_limit,
    'suspended',      v->'suspended',
    'suspended_on',   (select suspended_at from public.subscriptions where school_id = v_school),
    'suspend_reason', v->'suspend_reason',
    'grace_days',     v->'grace_days',
    'limit_state',    case when v_limit is not null and v_count > v_limit then 'over' else 'ok' end,
    'limit_notice',   case
      when v_limit is null then null
      when v_count >= v_limit then
        format('Your roll is full: %s pupils, and your plan covers %s. ' ||
               'New admissions are paused until there is room. Ask us for ' ||
               'more room, or to be moved up a plan, from Settings then ' ||
               'Subscription. Everything already entered is untouched.', v_count, v_limit)
      when v_count >= ceil(v_limit * 0.9) then
        format('%s of the %s pupils your plan covers. At %s, new ' ||
               'admissions pause until there is room, so if you are ' ||
               'expecting more children this term, ask us now from ' ||
               'Settings then Subscription.', v_count, v_limit, v_limit)
      else null end);
end;
$$;

-- The next payment, for the owner and principal: the full view plus the old
-- keys, priced by the same quote the invoice will use.
create or replace function public.fn_my_next_payment()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  v_school uuid := public.current_school_id(); v jsonb; v_due date; v_amount numeric;
  v_status text; v_credit numeric;
begin
  if v_school is null then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal can see the subscription'
      using errcode = '42501';
  end if;
  v := public.fn__subscription_view(v_school, false);
  if v is null then
    return jsonb_build_object('has_subscription', false);
  end if;
  v_status := v->>'status';
  v_credit := coalesce((v->>'credit')::numeric, 0);

  -- When and how much, from the same view the screens read. A locked school is
  -- due now, and asked for the amount that opens it again (pay_now). Credit
  -- comes off every amount. The trial sentence is for a school whose trial is
  -- actually running, not one whose stored status still says trialing.
  v_due := case
    when (v->>'cancel_at_period_end')::boolean or v_status = 'cancelled'
         or (v->>'suspended')::boolean then null
    when v_status = 'locked' then current_date
    when v->'open_invoice' is not null and v->'open_invoice' <> 'null'::jsonb
      then (v->'open_invoice'->>'due_on')::date
    when v->'next' is not null and v->'next' <> 'null'::jsonb
      then (v->'next'->>'period_start')::date
    else null end;
  v_amount := case
    when v_due is null then null
    when v_status = 'locked' then (v->>'pay_now')::numeric
    when v->'open_invoice' is not null and v->'open_invoice' <> 'null'::jsonb
      then greatest((v->'open_invoice'->>'owed')::numeric - v_credit, 0)
    else greatest((v->'next'->'quote'->>'amount')::numeric - v_credit, 0) end;

  return jsonb_build_object(
    'has_subscription', true,
    'view', v,
    'plan_code', v->'plan'->'code',
    'plan_name', v->'plan'->'name',
    'term_months', v->'term_months',
    'status', v_status,
    'in_trial', v->'in_trial',
    'trial_ends_on', v->'trial_ends_on',
    'period_end', v->'paid_through',
    'next_charge_on', v_due,
    'next_charge_amount', v_amount,
    'auto_renew', false,
    'cancel_at_period_end', v->'cancel_at_period_end',
    'terms', v->'terms',
    -- Where the school said it sends the money from (0112). Nothing is
    -- charged automatically: this is a note for both sides, read back so the
    -- screen shows what was saved.
    'method', (select case when pm.id is null then null else jsonb_build_object(
                 'id', pm.id, 'kind', pm.kind, 'brand', pm.brand,
                 'last4', pm.last4, 'label', pm.label,
                 'instructions', pm.instructions, 'status', pm.status) end
                 from public.subscriptions sub
                 left join public.payment_methods pm on pm.id = sub.payment_method_id
                where sub.school_id = v_school),
    'sentence', case
      when (v->>'needs_price')::boolean
        then 'We are agreeing your price with you. Your invoice follows once it is set.'
      when (v->>'cancel_at_period_end')::boolean and v_status = 'cancelled'
        then format('Your subscription ended on %s. You can restart it from this screen; '
                    || 'the software opens again when your next payment reaches us.',
                    to_char((v->>'covered_to')::date, 'FMDD Mon YYYY'))
      when (v->>'cancel_at_period_end')::boolean
        then format('Your subscription ends on %s. Nothing further will be charged.',
                    to_char((v->>'covered_to')::date, 'FMDD Mon YYYY'))
      when v_due is null then 'Nothing is due at the moment.'
      when v_status = 'locked'
        then format('New entries are paused until Rs %s reaches us. Pay it to the account '
                    || 'shown here and tell us with I have paid: the software opens the moment '
                    || 'we confirm it.', to_char(v_amount, 'FM999,999,999'))
      when v_amount = 0
        then format('Your credit of Rs %s covers your next term. It goes on your invoice '
                    || 'when that is raised.', to_char(v_credit, 'FM999,999,999'))
      when v_status = 'trialing'
        then format('Your free trial ends on %s. To keep going, Rs %s is due on %s, '
                    || 'and the software keeps working for %s days after that while it arrives. '
                    || 'You are charged nothing today.',
                    to_char((v->>'trial_ends_on')::date, 'FMDD Mon YYYY'),
                    to_char(v_amount, 'FM999,999,999'),
                    to_char(v_due, 'FMDD Mon YYYY'), v->>'grace_days')
      else format('Rs %s is due on %s. If it has not reached us by %s, the software locks until it does.',
                  to_char(v_amount, 'FM999,999,999'),
                  to_char(v_due, 'FMDD Mon YYYY'),
                  to_char((v->>'locks_on')::date - 1, 'FMDD Mon YYYY'))
    end);
end;
$$;

create or replace function public.fn_my_billing()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
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
    'licence', public.fn_my_licence(),
    'subscription', public.fn__subscription_view(v_school, false),
    'balance', jsonb_build_object(
      'billed', v_billed, 'paid', v_settled, 'outstanding', v_billed - v_settled),
    'documents', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', i.id, 'doc_no', i.doc_no, 'kind', i.kind, 'purpose', i.purpose,
               'issued_on', i.issued_on, 'due_on', i.due_on,
               'plan_code', i.plan_code, 'plan_name', coalesce(i.plan_name, i.plan_code),
               'period_start', i.period_start, 'period_end', i.period_end,
               'months', i.months,
               'amount', i.amount, 'tax_amount', i.tax_amount,
               'total', i.amount + i.tax_amount,
               'discount_code', i.discount_code, 'discount_amount', i.discount_amount,
               'voided', i.voided_at is not null,
               'paid', case when i.kind = 'invoice' then public.fn__invoice_settled(i.id) else 0 end,
               'owed', public.fn__invoice_owed(i.id),
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
    'reports', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'amount', c.amount, 'paid_on', c.paid_on,
               'method', c.method, 'reference', c.reference,
               'claimed_at', c.claimed_at, 'status', c.status,
               'decided_at', c.decided_at, 'decision_note', c.decision_note)
             order by c.claimed_at desc)
        from public.platform_payment_claims c where c.school_id = v_school), '[]'::jsonb),
    'pay_to', jsonb_build_object(
      'business_name', nullif(btrim(coalesce(v_set.business_name, '')), ''),
      'bank_name', v_set.bank_name, 'title', v_set.bank_title,
      'account', v_set.bank_account, 'iban', v_set.bank_iban,
      'support_phone', v_set.phone, 'support_email', v_set.email,
      'online_available', coalesce(v_set.gateway_enabled, false)),
    'how_to_pay', case when coalesce(v_set.gateway_enabled, false)
      then 'Pay online from this screen, or transfer to the account above and '
           'tell us the reference.'
      else 'Transfer to the account above from any bank or app, then use "I have '
           'paid" below to tell us the reference. We check it against our '
           'statement and confirm it here, usually the same day.' end);
end;
$$;


-- -----------------------------------------------------------------------------
-- 14. RENEWALS
-- -----------------------------------------------------------------------------

create or replace function public.fn__next_charge_on(p_school_id uuid)
returns date
language sql
stable
security definer
set search_path = public
as $$
  select case
    when s.suspended_at is not null or s.status = 'cancelled' or s.cancel_at_period_end then null
    when public.fn__open_term_invoice(p_school_id) is not null
      then (select due_on from public.platform_invoices
             where id = public.fn__open_term_invoice(p_school_id))
    else public.fn__next_period_start(p_school_id) end
  from public.subscriptions s where s.school_id = p_school_id;
$$;

-- Who is due an invoice on or before p_as_at: nothing open for the next
-- period and the next period starts by then. The amount is the quote the
-- invoice will carry. Trials are listed (was_trialing) but the run does not
-- invoice them: a trial school's first invoice comes when it asks or pays.
-- A school already locked after its period ended is not renewing: it is
-- invoiced when it comes back (pays or asks), from that day. Listing it made
-- every run void its lapsed invoice and raise another.
create or replace function public.fn__renewals_due(p_as_at date)
returns table(school_id uuid, school_name text, plan_code text, term_months integer,
              due_on date, amount numeric, was_trialing boolean, has_method boolean)
language sql
stable
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
  select s.id, s.name, sub.plan_code, sub.term_months,
         public.fn__next_period_start(s.id),
         (public.fn__quote(s.id, sub.plan_code, sub.term_months,
                           public.fn__next_period_start(s.id))->>'amount')::numeric,
         sub.status = 'trialing',
         sub.payment_method_id is not null
    from public.schools s
    join public.subscriptions sub on sub.school_id = s.id
   where s.active
     and s.archived_at is null
     and sub.suspended_at is null
     and sub.status <> 'cancelled'
     and not sub.cancel_at_period_end
     and not (public.fn_effective_status(s.id) = 'locked'
              and coalesce(public.fn__coverage_end(s.id), current_date - 1) < current_date)
     and public.fn__open_term_invoice(s.id) is null
     and public.fn__next_period_start(s.id) <= p_as_at
   order by public.fn__next_period_start(s.id), s.name;
$$;

alter table public.billing_attempts drop constraint if exists billing_attempts_outcome_chk;
alter table public.billing_attempts add constraint billing_attempts_outcome_chk check (
  outcome in ('would_invoice', 'invoiced', 'already_invoiced', 'needs_decision',
              'trial_never_said_yes', 'failed', 'needs_price', 'trial_ending'));

-- Outcomes are decided by the refusal's SQLSTATE, never by its wording.
create or replace function public.fn_platform_run_renewals(p_dry_run boolean default true, p_as_at date default null)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  v_run uuid; v_as_at date := coalesce(p_as_at, (now() at time zone 'Asia/Karachi')::date);
  v_dry boolean := coalesce(p_dry_run, true);
  r record; j jsonb; v_msg text; v_sqlstate text;
  v_considered int := 0; v_invoiced int := 0; v_skipped int := 0; v_failed int := 0;
  v_outcome text; v_note text; v_inv uuid; v_amount numeric;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_as_at > current_date + 31 then
    raise exception 'Invoices are raised at most a month ahead.' using errcode = '22023';
  end if;

  insert into public.billing_runs (dry_run, triggered_by, as_at)
  values (v_dry, auth.uid(), v_as_at)
  returning id into v_run;

  for r in select * from public.fn__renewals_due(v_as_at) loop
    v_considered := v_considered + 1;
    v_outcome := null; v_note := null; v_inv := null; v_amount := r.amount;

    if r.was_trialing then
      v_outcome := 'trial_ending';
      v_note := format('Trial %s %s. Trials are not invoiced by the run: the first '
                       || 'invoice is raised when the school asks for it or pays.',
                       case when (select trial_ends_on from public.subscriptions
                                   where school_id = r.school_id) < current_date
                            then 'ended' else 'ends' end,
                       to_char((select trial_ends_on from public.subscriptions
                                 where school_id = r.school_id), 'DD Mon YYYY'));
      v_skipped := v_skipped + 1;
    elsif r.amount is null then
      v_outcome := 'needs_price';
      v_note := 'No price has been agreed with this school. Set it on the school''s page.';
      v_skipped := v_skipped + 1;
    elsif public.fn__over_limit_for_period(r.school_id, r.due_on) is not null then
      -- The same check the invoice makes, so the dry run counts what the live
      -- run will do: a school that has outgrown its plan waits for us.
      v_outcome := 'needs_decision';
      v_note := public.fn__over_limit_for_period(r.school_id, r.due_on);
      v_skipped := v_skipped + 1;
    elsif v_dry then
      v_outcome := 'would_invoice';
      v_note := format('Would invoice Rs %s for %s month(s) from %s on %s.',
                       to_char(r.amount, 'FM999,999,999'), r.term_months,
                       to_char(r.due_on, 'DD Mon YYYY'), r.plan_code);
      v_skipped := v_skipped + 1;
    else
      begin
        j := public.fn__raise_term_invoice(r.school_id, r.term_months, null,
                                           'Renewal', 'renewal_run');
        v_inv := nullif(j->>'invoice_id', '')::uuid;
        v_amount := (j->>'amount')::numeric;
        v_outcome := 'invoiced';
        v_note := format('Invoiced Rs %s for %s month(s) from %s on %s.',
                         to_char(v_amount, 'FM999,999,999'), r.term_months,
                         to_char((j->>'period_start')::date, 'DD Mon YYYY'), r.plan_code);
        v_invoiced := v_invoiced + 1;
      exception when others then
        get stacked diagnostics v_msg = message_text, v_sqlstate = returned_sqlstate;
        v_note := v_msg;
        if v_sqlstate = 'SB001' then
          v_outcome := 'already_invoiced'; v_skipped := v_skipped + 1;
        elsif v_sqlstate = 'SB002' then
          v_outcome := 'needs_price'; v_skipped := v_skipped + 1;
        elsif v_sqlstate in ('SB003', 'SB004') then
          v_outcome := 'needs_decision'; v_skipped := v_skipped + 1;
        else
          v_outcome := 'failed'; v_note := format('[%s] %s', v_sqlstate, v_msg);
          v_failed := v_failed + 1;
        end if;
      end;
    end if;

    insert into public.billing_attempts
      (run_id, school_id, due_on, plan_code, term_months, amount, outcome, message, invoice_id)
    values (v_run, r.school_id, r.due_on, r.plan_code, r.term_months, v_amount,
            v_outcome, v_note, v_inv);
  end loop;

  update public.billing_runs
     set finished_at = now(), considered = v_considered, invoiced = v_invoiced,
         skipped = v_skipped, failed = v_failed
   where id = v_run;

  perform public.fn__log_operator_action('renewal_run', null,
    jsonb_build_object('run_id', v_run, 'dry_run', v_dry, 'as_at', v_as_at,
                       'considered', v_considered, 'invoiced', v_invoiced,
                       'skipped', v_skipped, 'failed', v_failed));

  return jsonb_build_object(
    'run_id', v_run, 'dry_run', v_dry, 'as_at', v_as_at,
    'considered', v_considered, 'invoiced', v_invoiced,
    'skipped', v_skipped, 'failed', v_failed,
    'note', case when v_dry
      then format('Nothing was changed. %s school(s) are due; run it again with '
                  || 'dry run off to raise the invoices.', v_considered)
      else format('%s invoice(s) raised. %s left alone, %s failed.',
                  v_invoiced, v_skipped, v_failed) end,
    'attempts', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'school_id', a.school_id,
               'school_name', (select name from public.schools where id = a.school_id),
               'due_on', a.due_on, 'plan_code', a.plan_code,
               'term_months', a.term_months, 'amount', a.amount,
               'outcome', a.outcome, 'message', a.message) order by a.at), '[]'::jsonb)
        from public.billing_attempts a where a.run_id = v_run));
end;
$$;


-- -----------------------------------------------------------------------------
-- 15. WHAT WE SEE
-- -----------------------------------------------------------------------------

create or replace function public.fn_platform_schools(p_include_archived boolean default false)
returns table(school_id uuid, school_name text, city text, contact_name text, contact_phone text,
              plan_code text, status public.subscription_status, expires_on date, days_left integer,
              student_count integer, student_limit integer, limit_state text, suggested_plan text,
              needs_upgrade boolean, outstanding numeric, last_paid_on date, suspended boolean,
              suspend_reason text, archived boolean)
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
  return query
    with b as (
      select s.id, s.name, s.city, s.contact_name, s.contact_phone, sub.plan_code,
             public.fn_effective_status(s.id) as eff,
             public.fn__coverage_end(s.id) as cov,
             sub.student_count, public.fn__student_limit(s.id) as lim,
             sub.suspended_at, sub.suspend_reason, s.archived_at
        from public.schools s
        join public.subscriptions sub on sub.school_id = s.id
       where coalesce(p_include_archived, false) or s.archived_at is null)
    select b.id, b.name, b.city, b.contact_name, b.contact_phone, b.plan_code, b.eff,
           b.cov, (b.cov - current_date)::integer,
           b.student_count, b.lim,
           case when b.lim is not null and b.student_count > b.lim then 'over' else 'ok' end,
           public.fn__plan_for_students(b.student_count),
           b.lim is not null and b.student_count > b.lim,
           public.fn__platform_billed(b.id) - public.fn__platform_settled(b.id),
           (select max(pm.paid_on) from public.platform_payments pm where pm.school_id = b.id),
           b.suspended_at is not null, b.suspend_reason, b.archived_at is not null
      from b
     order by b.name;
end;
$$;

-- The renewal worklist: priced on the school's own plan and price with the
-- same quote its invoice will use, never on a "suggested" plan.
create or replace function public.fn_platform_due_soon(p_days integer default 45)
returns table(school_id uuid, school_name text, city text, contact_name text, contact_phone text,
              plan_code text, status public.subscription_status, expires_on date, days_left integer,
              bucket text, student_count integer, student_limit integer, suggested_plan text,
              needs_upgrade boolean, renewal_amount numeric, outstanding numeric, invoiced_to date,
              unbilled_days integer, never_invoiced boolean, last_reminded_at timestamptz,
              last_reminded_stage text)
language plpgsql
stable
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare v_days integer := greatest(0, least(coalesce(p_days, 45), 365));
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
    with base as (
      select s.id, s.name, s.city, s.contact_name, s.contact_phone,
             sub.plan_code, sub.term_months, sub.student_count,
             public.fn__student_limit(s.id) as lim,
             public.fn_effective_status(s.id) as eff,
             public.fn__coverage_end(s.id) as expires
        from public.schools s
        join public.subscriptions sub on sub.school_id = s.id
       where s.active and s.archived_at is null
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
      b.student_count, b.lim,
      public.fn__plan_for_students(b.student_count),
      b.lim is not null and b.student_count > b.lim,
      (public.fn__quote(b.id, b.plan_code, b.term_months,
                        public.fn__next_period_start(b.id))->>'amount')::numeric,
      public.fn__platform_billed(b.id) - public.fn__platform_settled(b.id),
      inv.covered_to,
      case when inv.covered_to is null or b.expires is null then null
           when b.expires > inv.covered_to then (b.expires - inv.covered_to)::integer
           else 0 end,
      inv.covered_to is null,
      rem.at, rem.detail->>'stage'
      from base b
      left join lateral (
        select max(i.period_end) as covered_to
          from public.platform_invoices i
         where i.school_id = b.id and i.kind = 'invoice' and i.purpose = 'term'
           and i.voided_at is null
      ) inv on true
      left join lateral (
        select a.at, a.detail from public.operator_actions a
         where a.school_id = b.id and a.action = 'renewal_reminder'
         order by a.at desc limit 1
      ) rem on true
     where b.eff in ('grace', 'locked', 'cancelled')
        or (b.expires is not null and b.expires <= current_date + v_days)
     order by 9 nulls last, 2;
end;
$$;

-- The reminder quotes what the school will actually be asked for: its open
-- invoice if one is raised, otherwise the quote for its next term on its own
-- plan and price. An Enterprise school with no price gets a call, not a text.
create or replace function public.fn_platform_renewal_message(p_school_id uuid, p_stage text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  v record; v_set record; v_stage text; v_amount numeric; v_owed numeric;
  v_expiry date; v_days integer; v_stop date; v_text text; v_phone text; sv jsonb;
  v_hi text;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select s.name, s.contact_name, s.contact_phone, s.id into v
    from public.schools s where s.id = p_school_id;
  sv := public.fn__subscription_view(p_school_id, true);
  if v.name is null or sv is null then
    raise exception 'Unknown school, or it has no subscription';
  end if;
  select * into v_set from public.platform_settings where id;

  v_expiry := (sv->>'covered_to')::date;
  v_days   := case when v_expiry is null then null else v_expiry - current_date end;
  v_stop   := (sv->>'locks_on')::date - 1;
  v_owed   := (sv->>'owed')::numeric;
  v_amount := case
    when v_owed > 0 then v_owed
    when sv->'next' is not null and sv->'next' <> 'null'::jsonb
      then (sv->'next'->'quote'->>'amount')::numeric
    else null end;
  v_hi := case when v.contact_name is null then '' else ' ' || v.contact_name end;

  v_stage := coalesce(nullif(btrim(coalesce(p_stage, '')), ''), case
    when sv->>'status' = 'locked' then 'locked'
    when sv->>'status' = 'grace'  then 'grace'
    when v_days is null then 'ahead'
    when v_days < 0  then 'grace'
    when v_days = 0  then 'today'
    when v_days <= 10 then 'due'
    else 'ahead' end);
  if v_stage not in ('ahead', 'due', 'today', 'grace', 'locked') then
    raise exception 'Unknown reminder stage: %', v_stage;
  end if;

  if (sv->>'needs_price')::boolean then
    v_text := format(
      'Assalam-o-Alaikum%s. Thank you for trying %s at %s. Your trial runs to %s. '
      'We would like to agree your monthly price with you before then: please '
      'call or reply to this message with a good time.',
      v_hi, coalesce(v_set.business_name, 'the software'), v.name,
      to_char((sv->>'trial_ends_on')::date, 'DD Mon YYYY'));
  else
    v_text := case v_stage
      when 'ahead' then format(
        'Assalam-o-Alaikum%s. Your %s licence for %s runs to %s. The next payment '
        'is Rs %s. No rush: sending it now so you have time to arrange it. Bank '
        'details and the invoice are inside the software under Settings, Subscription.',
        v_hi, coalesce(v_set.business_name, 'school management'), v.name,
        to_char(v_expiry, 'DD Mon YYYY'), to_char(v_amount, 'FM999,999,999'))
      when 'due' then format(
        'Assalam-o-Alaikum%s. %s''s licence runs to %s, %s day(s) from today. '
        'The next payment is Rs %s. You can see the invoice and our bank details '
        'under Settings, Subscription, and tell us the transfer reference from '
        'the same screen.',
        v_hi, v.name, to_char(v_expiry, 'DD Mon YYYY'), greatest(v_days, 0),
        to_char(v_amount, 'FM999,999,999'))
      when 'today' then format(
        'Assalam-o-Alaikum%s. %s''s licence runs to today. Everything keeps working '
        'until %s while the payment of Rs %s reaches us; after that the software '
        'locks until it does.',
        v_hi, v.name, to_char(v_stop, 'DD Mon YYYY'), to_char(v_amount, 'FM999,999,999'))
      when 'grace' then format(
        'Assalam-o-Alaikum%s. %s''s payment of Rs %s is due. Everything still works '
        'until %s. Please send the transfer reference on Settings, Subscription and '
        'we will confirm it the same day.',
        v_hi, v.name, to_char(v_amount, 'FM999,999,999'), to_char(v_stop, 'DD Mon YYYY'))
      else format(
        'Assalam-o-Alaikum%s. %s''s licence is locked because Rs %s has not reached '
        'us. Your data is safe and nothing has been deleted: you can still open every '
        'screen, print and export. Send us the transfer reference and it opens again '
        'the moment we confirm it.',
        v_hi, v.name, to_char(v_amount, 'FM999,999,999'))
    end;
  end if;

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
    'needs_price', sv->'needs_price',
    'text', v_text,
    'phone_intl', v_phone,
    'no_phone_reason', case when v_phone is null
      then 'No contact phone on record for this school: add one in the console'
      else null end);
end;
$$;

-- What each plan is worth a month is each school's own price for its own term,
-- not a yearly list price assumed for everybody.
CREATE OR REPLACE FUNCTION public.fn_platform_metrics(p_as_at date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'Asia/Karachi'
AS $function$
declare
  v_at date := coalesce(p_as_at, current_date);
  v_mrr numeric := 0;
  v_paying integer := 0;
  v_trial integer := 0;
  v_grace integer := 0;
  v_locked integer := 0;
  v_cancelled integer := 0;
  v_unbilled integer := 0;
  v_archived integer := 0;
  v_students integer := 0;
  v_lost integer := 0;
  v_first_history date;
  r record;
  v_by_plan jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  for r in
    select s.id, s.archived_at, sub.plan_code, sub.student_count,
           public.fn_effective_status(s.id) as eff
      from public.schools s
      join public.subscriptions sub on sub.school_id = s.id
  loop
    if r.archived_at is not null then
      v_archived := v_archived + 1;
      continue;              -- archived schools are not customers
    end if;
    case r.eff
      when 'active'    then v_paying := v_paying + 1;
      when 'grace'     then v_grace := v_grace + 1;
      when 'trialing'  then v_trial := v_trial + 1;
      when 'locked'    then v_locked := v_locked + 1;
      when 'cancelled' then v_cancelled := v_cancelled + 1;
      else null;
    end case;

    -- Counted as recurring only while the licence is LIVE. Grace counts: the
    -- money is contracted and in flight. Locked and cancelled do not, whatever
    -- an unexpired invoice might say.
    if r.eff in ('active', 'grace') then
      declare v_m numeric := public.fn__school_mrr(r.id, v_at);
      begin
        if v_m = 0 then
          v_unbilled := v_unbilled + 1;
        end if;
        v_mrr := v_mrr + v_m;
      end;
      v_students := v_students + coalesce(r.student_count, 0);
    end if;
  end loop;

  -- Per plan, and this is what 5b of the design asked for: fn_platform_revenue
  -- has returned by_plan since 0064 and nothing has ever rendered it.
  select coalesce(jsonb_agg(x order by x->>'sort'), '[]'::jsonb) into v_by_plan
    from (
      select jsonb_build_object(
               'plan_code', p.code, 'plan_name', p.name,
               'sort', lpad(p.sort_order::text, 4, '0'),
               'schools', count(s.id),
               -- FILTERED on the join having matched. Without it the sum counts
               -- subscriptions whose school failed the live-status condition, so
               -- a locked school's pupils appeared under its plan while the
               -- school itself did not. Caught by a fixture where the numbers
               -- did not add up, not by reading.
               'students', coalesce(sum(sub.student_count)
                                      filter (where s.id is not null), 0),
               'mrr', coalesce(sum(public.fn__school_mrr(s.id, v_at))
                                 filter (where s.id is not null), 0),
               'list_mrr', coalesce(sum(round(public.fn__term_price(s.id, p.code, sub.term_months)
                                              / sub.term_months))
                                      filter (where s.id is not null), 0)) as x
        from public.plans p
        left join public.subscriptions sub on sub.plan_code = p.code
        left join public.schools s
               on s.id = sub.school_id
              and s.archived_at is null
              and public.fn_effective_status(s.id) in ('active', 'grace')
       group by p.code, p.name, p.sort_order) g;

  -- --- churn, from dated events ------------------------------------------
  -- The earliest thing that could have been recorded. If there is no history at
  -- all the answer is "we do not know", not zero — a confident zero churn on a
  -- database with no history is the most misleading number this screen could
  -- show.
  select least(
    (select min(at)::date from public.operator_actions),
    (select min(archived_at)::date from public.schools)
  ) into v_first_history;

  select count(*) into v_lost
    from public.schools s
   where (s.archived_at is not null and s.archived_at >= v_at - 365)
      or (s.archived_at is null and exists (
            select 1 from public.operator_actions a
             where a.school_id = s.id
               and a.action = 'subscription_cancelled'
               and a.at >= v_at - 365));

  return jsonb_build_object(
    'as_at', v_at,

    'recurring', jsonb_build_object(
      'mrr', round(v_mrr, 2),
      'arr', round(v_mrr * 12, 2),
      'paying_schools', v_paying,
      'in_grace', v_grace,
      -- Per PAYING school, not per school on the books. Dividing by trials and
      -- locked accounts makes the figure drop every time a demo is set up.
      'arps', case when v_paying + v_grace > 0
                   then round(v_mrr / (v_paying + v_grace), 2) else 0 end,
      'basis', 'What each live school was actually charged for the period covering '
        || v_at::text || ', divided by the number of months on the invoice, before '
        || 'tax. Not the price list: a discounted school counts at its discount.'),

    'unbilled', jsonb_build_object(
      'schools', v_unbilled,
      'note', case when v_unbilled = 0 then 'Every live school has an invoice covering today.'
                   else format('%s live school(s) have licence time no invoice covers, so '
                               || 'they add nothing to MRR. Raise the invoice or the figure '
                               || 'stays understated and the money never arrives.', v_unbilled)
              end),

    'counts', jsonb_build_object(
      'paying', v_paying, 'in_grace', v_grace, 'on_trial', v_trial,
      'locked', v_locked, 'cancelled', v_cancelled, 'archived', v_archived,
      'live_total', v_paying + v_grace + v_trial + v_locked,
      'students_at_paying_schools', v_students),

    -- Trials that turned into customers. Deliberately only counts trials whose
    -- 14-or-more days are OVER: a trial that started yesterday has not failed to
    -- convert, and including it makes the rate drop every time a demo is set up.
    'conversion', (
      select case when count(*) = 0 then
        jsonb_build_object('measurable', false,
          'why', 'No trial has finished yet.')
      else
        jsonb_build_object('measurable', true,
          'trials_finished', count(*),
          'converted', count(*) filter (where has_invoice),
          'rate_pct', round(100.0 * count(*) filter (where has_invoice) / count(*), 1),
          'basis', 'Schools whose trial end date has passed, and whether any live '
            || 'invoice was ever raised against them.')
      end
      from (
        select exists (select 1 from public.platform_invoices i
                        where i.school_id = s.id and i.kind = 'invoice'
                          and i.voided_at is null) as has_invoice
          from public.schools s
          join public.subscriptions sub on sub.school_id = s.id
         where sub.trial_ends_on is not null and sub.trial_ends_on < v_at) t),

    'churn', case when v_first_history is null then
      jsonb_build_object('measurable', false,
        'why', 'Nothing dated has been recorded yet. Cancellations before 0073 and '
          || '0079 left no timestamp, so there is no history to measure, which is '
          || 'not the same as no churn.')
      else
      jsonb_build_object('measurable', true,
        'lost_12m', v_lost,
        'rate_pct', case when v_paying + v_grace + v_lost > 0
          then round(100.0 * v_lost / (v_paying + v_grace + v_lost), 1) else 0 end,
        'history_starts', v_first_history,
        'basis', 'Schools archived or cancelled in the last 365 days, as a share of '
          || 'those plus the ones still paying. History only goes back to '
          || v_first_history::text || '.')
      end,

    'by_plan', v_by_plan);
end;
$function$;


-- The school's page carries the full subscription view, and the licence block
-- loses the margin.
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
  v_disc record;
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

    select d.code, d.kind, d.value, d.duration, d.ends_on, d.uses_left,
         d.times_applied, d.total_saved, d.trial_days_added,
         d.redeemed_at, dc.description
    into v_disc
    from public.subscription_discounts d
    join public.discount_codes dc on dc.code = d.code
   where d.school_id = p_school_id
     and d.removed_at is null
     and (d.ends_on is null or d.ends_on >= current_date)
     and (d.uses_left is null or d.uses_left > 0)
   order by d.redeemed_at desc
   limit 1;

  if v_disc.code is not null then
    v_disc_block := jsonb_build_object(
      'code', v_disc.code,
      'description', v_disc.description,
      'kind', v_disc.kind, 'value', v_disc.value,
      'duration', v_disc.duration, 'ends_on', v_disc.ends_on,
      'uses_left', v_disc.uses_left,
      'times_applied', v_disc.times_applied,
      'total_saved', v_disc.total_saved,
      'trial_days_added', v_disc.trial_days_added,
      'redeemed_at', v_disc.redeemed_at,
      'summary', public.fn__discount_sentence(v_disc.kind, v_disc.value,
                                              v_disc.duration, null, v_disc.ends_on));
  end if;

  return jsonb_build_object(
    'school', jsonb_build_object(
      'id', v_school.id, 'name', v_school.name, 'city', v_school.city,
      'contact_name', v_school.contact_name, 'contact_phone', v_school.contact_phone,
      'contact_email', v_school.contact_email, 'notes', v_school.notes,
      'active', v_school.active, 'created_at', v_school.created_at,
      -- From school_settings, which is what the school itself maintains — so a
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

    -- The school's own logins. NOT the children — see the header.
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



-- What the school list and the statement need beside their fixed columns.
-- fn_platform_schools and fn_platform_ledger return tables whose columns an
-- older bundle pasted again would expect, so these sit beside them instead of
-- changing them.
create or replace function public.fn_platform_school_billing_states()
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
      'school_id', s.school_id,
      'needs_price', p.by_arrangement and s.agreed_monthly is null,
      'trial_ends_on', s.trial_ends_on,
      'paid_through', s.period_end,
      'covered_to', public.fn__coverage_end(s.school_id),
      'in_trial', s.status = 'trialing',
      'oldest_unpaid_due_on', s.oldest_unpaid_due_on,
      'extra_until', case when s.student_limit_override_until >= current_date
                          then s.student_limit_override_until end,
      'term_months', s.term_months,
      'credit', public.fn__unallocated(s.school_id)))
      from public.subscriptions s
      join public.plans p on p.code = s.plan_code), '[]'::jsonb);
end;
$$;
revoke all on function public.fn_platform_school_billing_states() from public, anon;
grant execute on function public.fn_platform_school_billing_states() to authenticated;

create or replace function public.fn_platform_invoice_states(p_school_id uuid)
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
      'invoice_id', i.id, 'doc_no', i.doc_no, 'kind', i.kind, 'purpose', i.purpose,
      'plan_name', coalesce(i.plan_name, i.plan_code),
      'total', i.amount + i.tax_amount,
      'paid', case when i.kind = 'invoice' then public.fn__invoice_settled(i.id) else 0 end,
      'owed', public.fn__invoice_owed(i.id),
      'discount_code', i.discount_code, 'discount_amount', i.discount_amount,
      'due_on', i.due_on, 'voided', i.voided_at is not null)
      order by i.issued_on, i.serial)
      from public.platform_invoices i where i.school_id = p_school_id), '[]'::jsonb);
end;
$$;
revoke all on function public.fn_platform_invoice_states(uuid) from public, anon;
grant execute on function public.fn_platform_invoice_states(uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- 16. A LOCKED SCHOOL IS READ-ONLY, EVERYWHERE
-- -----------------------------------------------------------------------------

-- Four tables a school writes were outside the write gate, so a locked school
-- could still mark subject attendance, cancel a certificate, refund a deposit
-- or close a billing month. And the gate covered INSERT and UPDATE only, so a
-- locked school could still DELETE through the row policies. Records stay
-- readable and exportable; nothing changes until the school pays.
do $gate$
declare t text;
begin
  foreach t in array array['attendance_subject', 'certificate_cancellations',
                           'deposit_refunds', 'billing_months'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists %I on public.%I', 'trg_' || t || '_school', t);
      execute format('create trigger %I before insert or update on public.%I '
                     'for each row execute function public.enforce_school_id()',
                     'trg_' || t || '_school', t);
    end if;
  end loop;
end $gate$;

create or replace function public.fn__licence_delete_gate()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_school uuid := public.current_school_id();
begin
  if v_school is not null and old.school_id = v_school
     and public.fn_effective_status(v_school) in ('locked', 'cancelled') then
    raise exception
      'This school''s subscription has ended. Your records are safe and can still be viewed and exported. Renew to start entering data again.'
      using errcode = '42501';
  end if;
  return old;
end;
$$;
revoke all on function public.fn__licence_delete_gate() from public, anon, authenticated;

do $delgate$
declare r record;
begin
  for r in
    select distinct c.relname
      from pg_trigger g
      join pg_class c on c.oid = g.tgrelid
      join pg_namespace n on n.oid = c.relnamespace
      join pg_proc p on p.oid = g.tgfoid
     where n.nspname = 'public' and p.proname = 'enforce_school_id' and not g.tgisinternal
  loop
    execute format('drop trigger if exists trg_licence_delete_gate on public.%I', r.relname);
    execute format('create trigger trg_licence_delete_gate before delete on public.%I '
                   'for each row execute function public.fn__licence_delete_gate()', r.relname);
  end loop;
end $delgate$;

-- TRUNCATE skips row security and every row trigger, the gate above included,
-- and Supabase grants it to anon and authenticated on every table by default.
-- PostgREST never issues it, but a signed-in user with SQL could empty the
-- subscriptions table, after which the write gate sees no subscription and
-- (by design: a bug in the gate must never become a lock) lets every write
-- through. Nothing in this project truncates as a signed-in user, so it is
-- taken away on every table, and from tables created later.
revoke truncate on all tables in schema public from anon, authenticated;
alter default privileges in schema public revoke truncate on tables from anon, authenticated;

-- LOGINS ARE THE ONE EXEMPTION. profiles is not behind the gate on purpose:
-- taking someone's access away (a teacher who has left) must never wait on a
-- payment, so the owner of a locked school can still change or remove a login.
-- A login it adds while locked can read and export, like every other login,
-- and write nothing: every school table is behind the gate.


-- -----------------------------------------------------------------------------
-- 17. THE PRICE LIST, FOR US
-- -----------------------------------------------------------------------------

create or replace function public.fn_platform_price_list()
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
  return jsonb_build_object(
    'plans', coalesce((select jsonb_agg(jsonb_build_object(
               'code', p.code, 'name', p.name, 'active', p.active,
               'student_limit', p.student_limit, 'min_students', p.min_students,
               'by_arrangement', p.by_arrangement,
               'month', p.price_monthly, 'quarter', p.price_quarterly, 'year', p.price_yearly,
               'schools', (select count(*) from public.subscriptions s where s.plan_code = p.code))
             order by p.sort_order) from public.plans p), '[]'::jsonb),
    'changes', coalesce((select jsonb_agg(jsonb_build_object(
               'code', c.code, 'op', c.op, 'before', c.before, 'after', c.after,
               'by', c.changed_by, 'as', c.changed_as, 'at', c.changed_at)
             order by c.changed_at desc)
        from (select * from public.plan_changes order by changed_at desc limit 50) c), '[]'::jsonb));
end;
$$;
revoke all on function public.fn_platform_price_list() from public, anon;
grant execute on function public.fn_platform_price_list() to authenticated;


-- -----------------------------------------------------------------------------
-- 18. EVERY SCHOOL, WORKED OUT AGAIN UNDER THE NEW RULES
-- -----------------------------------------------------------------------------

do $backfill$
declare r record;
begin
  for r in select school_id from public.subscriptions loop
    perform public.fn__apply_credit(r.school_id, null);
    perform public.fn_refresh_student_count(r.school_id);
  end loop;
end $backfill$;

do $assert$
begin
  if (select price_monthly from public.plans where code = 'starter') <> 2000
     or (select price_quarterly from public.plans where code = 'starter') <> 5400
     or (select price_yearly from public.plans where code = 'starter') <> 20000
     or (select student_limit from public.plans where code = 'starter') <> 280
     or (select price_monthly from public.plans where code = 'growth') <> 4000
     or (select price_quarterly from public.plans where code = 'growth') <> 10800
     or (select price_yearly from public.plans where code = 'growth') <> 40000
     or (select student_limit from public.plans where code = 'growth') <> 1000
     or not (select by_arrangement and active from public.plans where code = 'enterprise') then
    raise warning '0155 did not fully apply: the price list is not Starter 280 / Growth 1,000 / Enterprise';
  end if;
  if to_regclass('public.platform_payment_allocations') is null
     or to_regprocedure('public.fn__recompute_licence(uuid)') is null
     or to_regprocedure('public.fn_signup_school_for_students(text,text,text,text,text,text,integer,integer)') is null then
    raise warning '0155 did not fully apply: payments are not allocated to invoices yet';
  end if;
end $assert$;

-- ─────────────────────────────────────────────────────────────────────────
-- 0156_discount_codes_that_keep_their_word.sql
-- ─────────────────────────────────────────────────────────────────────────
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
--     rupees off each billed month it covers.
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
update public.subscription_discounts d
   set months_total = coalesce(d.months_total,
                               (select c.duration_months from public.discount_codes c where c.code = d.code)),
       months_left  = coalesce(d.months_left,
                               greatest(coalesce((select c.duration_months from public.discount_codes c
                                                   where c.code = d.code), 0) - d.times_applied, 0))
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
--            flat: rupees per covered month; never more than the term price;
--            whole rupees
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
    else p_value * v_cov end;
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

-- The school's live MONEY discount: not removed, not a trial code, and with
-- months or days still to give.
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
     and (d.duration <> 'months' or coalesce(d.months_left, 0) > 0)
     and (d.duration <> 'until' or d.ends_on >= coalesce(p_as_at, current_date))
   order by d.redeemed_at desc
   limit 1;
$$;

-- 0155's hook: what the live code takes off this invoice.
create or replace function public.fn__discount_for_quote(
  p_school_id uuid, p_plan_code text, p_months integer, p_period_start date,
  p_term_price numeric)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare d public.subscription_discounts; v jsonb;
begin
  select * into d from public.fn__discount_live(p_school_id, p_period_start);
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
-- months this invoice would have covered, so it cannot be used again.
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
  v_off := case when p_overridden
                then greatest(coalesce((p_quote->>'term_price')::numeric, v_inv.amount) - v_inv.amount, 0)
                else coalesce((p_quote->>'discount_amount')::numeric, 0) end;

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
create or replace function public.fn__discount_reverse(p_invoice_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare a public.discount_applications;
begin
  select * into a from public.discount_applications
   where invoice_id = p_invoice_id and reversed_at is null for update;
  if not found then
    return;
  end if;
  update public.discount_applications
     set reversed_at = now(), reversed_reason = coalesce(nullif(btrim(p_reason), ''), 'voided')
   where id = a.id;
  update public.subscription_discounts
     set times_applied = greatest(times_applied - 1, 0),
         total_saved   = greatest(total_saved - a.amount_off, 0),
         months_left   = case when duration = 'months'
                              then least(coalesce(months_left, 0) + a.months_covered,
                                         coalesce(months_total, coalesce(months_left, 0) + a.months_covered))
                         end
   where id = a.redemption_id;
  perform public.fn__discount_event('reversed', a.code, a.school_id, a.redemption_id,
    p_invoice_id, 'system', jsonb_build_object('months_covered', a.months_covered,
                                               'amount_off', a.amount_off), null, p_reason);
end;
$$;

revoke all on function public.fn__norm_code(text) from public, anon, authenticated;
revoke all on function public.fn__months_until(date, integer, date) from public, anon, authenticated;
revoke all on function public.fn__discount_calc(text, text, numeric, text, integer, date, text[], integer, text, integer, date, numeric) from public, anon, authenticated;
revoke all on function public.fn__discount_sentence(text, numeric, text, integer, date) from public, anon, authenticated;
revoke all on function public.fn__discount_live(uuid, date) from public, anon, authenticated;
revoke all on function public.fn__discount_for_quote(uuid, text, integer, date, numeric) from public, anon, authenticated;
revoke all on function public.fn__discount_record(uuid, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.fn__discount_reverse(uuid, text) from public, anon, authenticated;

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

-- Ten refused tries in the last hour and the school waits.
create or replace function public.fn__discount_throttled(p_school_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select count(*) >= 10 from public.discount_events
   where school_id = p_school_id and event = 'refused' and at > now() - interval '1 hour';
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
  if v_open is not null and public.fn__invoice_settled(v_open) = 0 then
    select period_start into v_start from public.platform_invoices where id = v_open;
    v_applies := 'open_invoice';
  elsif v_open is not null then
    select period_end + 1 into v_start from public.platform_invoices where id = v_open;
    v_applies := 'invoice_after_open';
  else
    v_start := public.fn__next_period_start(p_school_id);
    v_applies := 'next_invoice';
  end if;
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
                                              live.months_left, live.ends_on)) end);
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
  if public.fn__discount_throttled(v_school) then
    return jsonb_build_object('ok', false, 'reason',
      'Too many codes have been tried in the last hour. Please try again later, or ask us.');
  end if;
  select * into s from public.subscriptions where school_id = v_school;

  select * into live from public.fn__discount_live(v_school, null);
  if live.id is not null and live.code = v_code then
    return jsonb_build_object('ok', false, 'already_yours', true, 'code', live.code,
      'reason', 'That code is already on your subscription.');
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
begin
  if v_school is null then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or the principal can apply a discount code.'
      using errcode = '42501';
  end if;
  if public.fn__discount_throttled(v_school) then
    return jsonb_build_object('ok', false, 'reason',
      'Too many codes have been tried in the last hour. Please try again later, or ask us.');
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

  if c.kind <> 'trial_days' then
    select * into live from public.fn__discount_live(v_school, null);
    if live.id is not null then
      if live.granted_by_kind = 'platform' then
        return jsonb_build_object('ok', false, 'reason',
          'Your current discount was arranged with us, so it can only be changed by us. Please call us.');
      end if;
      if not coalesce(p_replace, false) then
        return jsonb_build_object('ok', false, 'needs_replace', true, 'preview', v_prev,
          'reason', format('Your subscription already has %s (%s). Using %s takes it off for good.',
                           live.code, live.label, c.code));
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
  -- is closed; it is closed here, with the reason, before the new one goes in.
  if c.kind <> 'trial_days' then
    update public.subscription_discounts
       set removed_at = now(), removed_reason = 'Ran its course'
     where school_id = v_school and removed_at is null and kind <> 'trial_days';
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

  return jsonb_build_object(
    'ok', true, 'code', c.code, 'label', c.label,
    'summary', public.fn__discount_sentence(c.kind, c.value, c.duration,
                                            c.duration_months, c.duration_until),
    'trial_ends_on', v_trial,
    'preview', v_prev,
    'reissued', v_re,
    'what_next', case
      when c.kind = 'trial_days'
        then format('Your free trial now runs to %s.', to_char(v_trial, 'DD Mon YYYY'))
      when v_re is not null and v_re ? 'raised'
        then 'Your invoice has been reissued with the code taken off.'
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
      public.fn__discount_sentence(d.kind, d.value, d.duration, d.months_left, d.ends_on) end,
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

-- Kept for a console that has not been reloaded: a new code is created, an
-- existing one is edited under the same locks, never silently overwritten.
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
declare v jsonb; v_old public.discount_codes;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
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
  select * into v_old from public.discount_codes where code = public.fn__norm_code(p_code);
  if not found then
    return public.fn_platform_create_discount(v || jsonb_build_object('code', p_code))
           || jsonb_build_object('created', true);
  end if;
  return public.fn_platform_edit_discount(p_code, v - 'label' - 'description'
           || jsonb_build_object('description', p_description), v_old.updated_at)
         || jsonb_build_object('created', false);
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
  v_id uuid; v_trial date; v_name text; v_re jsonb;
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

  if prior.id is null and c.max_redemptions is not null
     and public.fn__discount_seats_taken(c.code) >= c.max_redemptions then
    raise exception 'Every place on % is taken (% of %).', c.code,
      public.fn__discount_seats_taken(c.code), c.max_redemptions using errcode = '22023';
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
        jsonb_build_object('code', live.code), jsonb_build_object('replaced_by', c.code), v_reason);
    end if;
  end if;

  -- A code that has run its course still holds the one-per-school slot until it
  -- is closed; it is closed here, with the reason, before the new one goes in.
  if c.kind <> 'trial_days' then
    update public.subscription_discounts
       set removed_at = now(), removed_reason = 'Ran its course'
     where school_id = p_school_id and removed_at is null and kind <> 'trial_days'
       and id is distinct from prior.id;
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

create or replace function public.fn_platform_remove_discount(p_school_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare live public.subscription_discounts; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_reason is null then
    raise exception 'Say why the discount is being taken off. The school is told.';
  end if;
  select * into live from public.fn__discount_live(p_school_id, null);
  if live.id is null then
    raise exception 'That school has no live discount.';
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
  return jsonb_build_object('school_id', p_school_id, 'code', live.code, 'removed', true);
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
                 and (d.duration <> 'months' or coalesce(d.months_left, 0) > 0)
                 and (d.duration <> 'until' or d.ends_on >= current_date))::int as live,
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
        when d.duration = 'months' and coalesce(d.months_left, 0) <= 0 then 'spent'
        when d.duration = 'until' and d.ends_on < current_date then 'expired'
        else 'active' end)
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
      -- From school_settings, which is what the school itself maintains — so a
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

    -- The school's own logins. NOT the children — see the header.
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

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0155_three_plans_and_paying_first.sql', '56_three_plans_and_paying_first.sql');
  perform public.fn_record_migration('0156_discount_codes_that_keep_their_word.sql', '56_three_plans_and_paying_first.sql');
end $ledger$;
