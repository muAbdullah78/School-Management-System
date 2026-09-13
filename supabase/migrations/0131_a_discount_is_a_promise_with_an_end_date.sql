-- =============================================================================
-- 0131  A discount is a promise, and a promise needs an end date
--
-- -----------------------------------------------------------------------------
-- WHAT DID NOT EXIST
--
-- There was no way to sell a school anything other than the price list. Every
-- deal that needed a number off it was done by hand: fn_activate_subscription
-- takes p_amount, an operator typed the figure and a reason, and that was the
-- whole mechanism. Three things follow from that and all three were happening.
--
--   1. The discount lived in one invoice's note. Nothing carried it to the NEXT
--      invoice, so a school promised twenty percent for a year got it once and
--      full price after that, and found out when the renewal arrived.
--   2. Nobody could answer "which schools are on a discount". The only record
--      was prose in a note column.
--   3. A school could not be given a code to type. Every deal needed an
--      operator at a keyboard on the day, which is not a way to run a campaign.
--
-- -----------------------------------------------------------------------------
-- THE SHAPE
--
-- Two tables, and the split between them is the whole design.
--
--   discount_codes         what is on offer. Edited by the vendor, any time.
--   subscription_discounts what a school was actually promised, frozen at the
--                          moment they redeemed it.
--
-- THE TERMS ARE COPIED ON REDEMPTION AND NEVER READ BACK. A school that
-- redeemed twenty percent forever keeps twenty percent forever even if the code
-- is later edited to five percent, retired, or deleted. That is what a promise
-- is, and the alternative is a renewal run silently charging a school something
-- different from what they were told. It also makes an invoice reproducible:
-- the figures on it can be recomputed from a row that cannot move under them.
--
-- ONE LIVE DISCOUNT PER SCHOOL, enforced by a partial unique index rather than
-- by a function that could be bypassed. Stacking is a rabbit hole: two
-- percentages compound or add depending on who you ask, a flat and a percentage
-- have an order, and every answer is defensible, which is how a billing dispute
-- starts. A school with a second offer has the first one replaced, and the
-- replaced row stays for the record.
--
-- -----------------------------------------------------------------------------
-- WHERE IT APPLIES, AND WHY THERE IS ONLY ONE PLACE
--
-- fn_activate_subscription. Every invoice this product raises comes through it:
-- the operator console calls it, and fn_platform_run_renewals calls it once per
-- school. Putting the arithmetic anywhere else would mean a discount that works
-- when an operator clicks and not when the nightly run fires, which is the
-- failure nobody would notice until a school's renewal was wrong.
--
-- IT DOES NOT TOUCH p_amount. An operator who types an explicit figure is
-- overriding everything on purpose, and a discount quietly taking another
-- twenty percent off a hand-typed number is the opposite of what they meant.
--
-- AND IT WRITES THE REASON INTO THE INVOICE NOTE rather than into two new
-- columns. fn_activate_subscription already refuses to charge anything other
-- than the list price without a reason, and that reason already prints on the
-- invoice document. A discount is exactly that case, so it uses the mechanism
-- that is there instead of adding a second one beside it.
--
-- -----------------------------------------------------------------------------
-- THE EDGE CASES, EACH DECIDED HERE RATHER THAN LEFT TO THE CALLER
--
--   flat discount larger than the price   the invoice is zero, never negative,
--                                         and the recorded saving is what was
--                                         actually given, not what was offered.
--   percent of 100                        the same, and it is allowed: a free
--                                         term for a reference customer is a
--                                         real deal.
--   trial extension on a paying school    refused. There is no trial to extend
--                                         and silently doing nothing would read
--                                         as a broken code.
--   the same code twice                   refused, by name, saying when they
--                                         first used it.
--   the school changes plan mid-trial     the discount stays. It is attached to
--                                         the school, not to the plan, and the
--                                         terms were frozen on redemption.
--   the code is retired afterwards        every school already on it keeps it.
--   a code nobody has redeemed            can be deleted outright. One that has
--                                         been redeemed can only be retired.
-- =============================================================================

-- ---------------------------------------------------------------- the offer --
create table if not exists public.discount_codes (
  code            text primary key,
  description     text not null,

  -- WHAT it takes off.
  --   percent     a share of the list price for the term
  --   flat        rupees off the list price for the term
  --   trial_days  days added to the free trial; never touches an invoice
  kind            text not null check (kind in ('percent', 'flat', 'trial_days')),
  value           numeric(12,2) not null check (value > 0),

  -- HOW LONG it keeps applying to a school that has redeemed it.
  --   once     the next invoice only
  --   forever  every invoice, until somebody takes it off
  --   months   every invoice for this many months from the day they redeemed
  --   until    every invoice up to a fixed date
  duration        text not null check (duration in ('once', 'forever', 'months', 'until')),
  duration_months integer,
  duration_until  date,

  -- WHEN THE CODE ITSELF CAN BE TYPED IN, which is a different question from
  -- how long it lasts once it has been. A code can be redeemable for one week
  -- in April and give twenty percent forever to whoever caught it.
  redeem_from     date,
  redeem_until    date,
  max_redemptions integer check (max_redemptions is null or max_redemptions >= 1),

  -- WHICH PLANS it is for. Null is every plan.
  plan_codes      text[],
  -- The shortest term it will apply to, so "twenty percent if you pay yearly"
  -- is expressible without a second kind of code.
  min_term_months integer check (min_term_months is null or min_term_months between 1 and 60),

  active          boolean not null default true,
  created_by      uuid references auth.users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  -- A percentage over a hundred is not a discount, it is a payment to the
  -- customer. A flat amount has no upper bound here because it is checked
  -- against the actual price at the moment it applies.
  constraint discount_codes_percent_chk
    check (kind <> 'percent' or value <= 100),
  -- Days, not rupees. 365 because a trial longer than a year is a free
  -- customer and that decision belongs in a contract, not in a code.
  constraint discount_codes_trial_chk
    check (kind <> 'trial_days' or (value = round(value) and value between 1 and 365)),
  -- A trial extension happens once by definition: it moves a date. "Twenty
  -- extra days, forever" has no meaning.
  constraint discount_codes_trial_once_chk
    check (kind <> 'trial_days' or duration = 'once'),
  constraint discount_codes_duration_chk
    check (
      (duration = 'months' and duration_months between 1 and 120 and duration_until is null)
      or (duration = 'until' and duration_until is not null and duration_months is null)
      or (duration in ('once', 'forever') and duration_months is null and duration_until is null)),
  constraint discount_codes_window_chk
    check (redeem_from is null or redeem_until is null or redeem_until >= redeem_from),
  -- Upper case, no spaces. A code is read off a page and typed by somebody who
  -- is not sure whether it matters, so the answer is that it does not.
  constraint discount_codes_shape_chk
    check (code = upper(code) and code ~ '^[A-Z0-9][A-Z0-9_-]{2,31}$'),
  constraint discount_codes_description_chk
    check (btrim(description) <> '')
);

-- Dropped first so a re-paste of the bundle is a no-op rather than an error.
-- Every bundle in this repository is pasted into the Supabase editor by hand
-- and gets pasted twice sooner or later; `create trigger` has no `if not
-- exists`, and a bundle that fails on its second run rolls back every migration
-- inside it.
drop trigger if exists trg_discount_codes_updated on public.discount_codes;
create trigger trg_discount_codes_updated before update on public.discount_codes
  for each row execute function public.set_updated_at();

-- --------------------------------------------------------------- the promise --
create table if not exists public.subscription_discounts (
  id              uuid primary key default gen_random_uuid(),
  school_id       uuid not null references public.schools(id) on delete cascade,
  code            text not null references public.discount_codes(code),

  -- FROZEN AT REDEMPTION. See the header: a promise that can be edited
  -- underneath a school is not a promise.
  kind            text not null check (kind in ('percent', 'flat', 'trial_days')),
  value           numeric(12,2) not null check (value > 0),
  duration        text not null check (duration in ('once', 'forever', 'months', 'until')),
  -- Null means forever. Resolved from duration and duration_months on the day.
  ends_on         date,
  -- Null means unlimited. 'once' redemptions carry 1 and count down.
  uses_left       integer check (uses_left is null or uses_left >= 0),

  -- What it has actually been worth, so the console can show a number rather
  -- than a promise. Both are written by fn_activate_subscription.
  times_applied   integer not null default 0,
  total_saved     numeric(12,2) not null default 0,
  -- Trial extensions save no money and raise no invoice, so they are recorded
  -- in the unit they are given in.
  trial_days_added integer,

  redeemed_at     timestamptz not null default now(),
  redeemed_by     uuid references auth.users(id),
  removed_at      timestamptz,
  removed_by      uuid references auth.users(id),
  removed_reason  text,

  constraint subscription_discounts_removed_chk
    check ((removed_at is null and removed_reason is null)
           or (removed_at is not null and btrim(coalesce(removed_reason, '')) <> ''))
);

-- ONE LIVE DISCOUNT PER SCHOOL, in the database rather than in a function.
create unique index if not exists uq_subscription_discount_live
  on public.subscription_discounts (school_id) where removed_at is null;
-- A school may not redeem the same code twice, live or spent.
create unique index if not exists uq_subscription_discount_once
  on public.subscription_discounts (school_id, code);
create index if not exists idx_subscription_discounts_code
  on public.subscription_discounts (code);

-- NO CLIENT REACHES EITHER TABLE DIRECTLY. Everything goes through the
-- functions below, which decide what a school may see about its own offer and
-- what only the vendor may see. RLS enabled with no policies is a closed door;
-- the revokes are the second gate, because a grant and a policy are independent
-- and this repository has been caught by that before (0024).
alter table public.discount_codes enable row level security;
alter table public.subscription_discounts enable row level security;
revoke all on public.discount_codes from anon, authenticated;
revoke all on public.subscription_discounts from anon, authenticated;

-- =============================================================================
-- The arithmetic, in one place
-- =============================================================================

/**
 * What a discount takes off a list price.
 *
 * THE FLOOR IS THE POINT. A flat five hundred off a plan that costs four
 * hundred gives an invoice of zero, not of minus a hundred, and the saving
 * recorded is four hundred and not five. A negative invoice would pass every
 * check in this product (fn_activate_subscription only refuses a negative
 * p_amount) and then sit in the ledger as money the vendor owes a school.
 *
 * A trial extension takes nothing off any invoice. It is answered here as zero
 * rather than left to each caller to remember.
 */
create or replace function public.fn__discount_off(
  p_kind text, p_value numeric, p_list numeric)
returns numeric language sql immutable set search_path = public as $$
  select case
    when p_kind = 'percent' then least(round(coalesce(p_list, 0) * p_value / 100.0, 2),
                                       greatest(coalesce(p_list, 0), 0))
    when p_kind = 'flat'    then least(p_value, greatest(coalesce(p_list, 0), 0))
    else 0
  end;
$$;

/**
 * The live promise for a school, or no row.
 *
 * Live means: not removed, not past its end date, and with a use left if it
 * counts them. All three are asked here so that no caller can ask two of the
 * three and be right most of the time.
 */
create or replace function public.fn__discount_live(p_school_id uuid, p_as_at date default null)
returns public.subscription_discounts language sql stable set search_path = public as $$
  select d.* from public.subscription_discounts d
   where d.school_id = p_school_id
     and d.removed_at is null
     and (d.ends_on is null or d.ends_on >= coalesce(p_as_at, current_date))
     and (d.uses_left is null or d.uses_left > 0)
   limit 1;
$$;

/**
 * Can this code be redeemed by this school, on this plan, for this term?
 *
 * Returns the reason it cannot in plain words, or null when it can. One
 * function so the preview a school sees before it commits and the check made
 * when it commits can never disagree: a preview that says yes and an apply that
 * says no is the worst version of this screen.
 *
 * p_school_id may be null, which is the signup case: everything except "you
 * have already used this" can still be answered.
 */
create or replace function public.fn__discount_refusal(
  p_code text, p_school_id uuid, p_plan_code text, p_term_months integer)
returns text language plpgsql stable set search_path = public as $$
declare c public.discount_codes; v_used integer; v_when date;
begin
  select * into c from public.discount_codes where code = upper(btrim(p_code));
  if not found then
    return 'We do not recognise that code. Check the spelling, or ask us for a new one.';
  end if;
  if not c.active then
    return 'That code is no longer being offered.';
  end if;
  if c.redeem_from is not null and current_date < c.redeem_from then
    return format('That code cannot be used until %s.', to_char(c.redeem_from, 'DD Mon YYYY'));
  end if;
  if c.redeem_until is not null and current_date > c.redeem_until then
    return format('That code expired on %s.', to_char(c.redeem_until, 'DD Mon YYYY'));
  end if;
  if c.max_redemptions is not null then
    select count(*) into v_used from public.subscription_discounts where code = c.code;
    if v_used >= c.max_redemptions then
      return 'That code has been taken up by as many schools as it was meant for.';
    end if;
  end if;
  if c.plan_codes is not null and p_plan_code is not null
     and not (p_plan_code = any (c.plan_codes)) then
    return format('That code is only for the %s plan.',
      (select string_agg(p.name, ' or ' order by p.sort_order)
         from public.plans p where p.code = any (c.plan_codes)));
  end if;
  if c.min_term_months is not null and coalesce(p_term_months, 0) < c.min_term_months then
    return format('That code needs a term of at least %s month(s). '
                  'Choose a longer term and it will apply.', c.min_term_months);
  end if;
  if p_school_id is not null then
    select redeemed_at::date into v_when from public.subscription_discounts
     where school_id = p_school_id and code = c.code;
    if found then
      return format('You already used that code on %s.', to_char(v_when, 'DD Mon YYYY'));
    end if;
    if c.kind = 'trial_days'
       and (select status from public.subscriptions where school_id = p_school_id) <> 'trialing' then
      return 'That code adds days to a free trial, and your trial has already finished.';
    end if;
  end if;
  return null;
end;
$$;

/**
 * What a code would do, without doing it.
 *
 * Reachable by any signed-in school user, and deliberately so: the plan screen
 * has to be able to say "that is Rs 400 off" before anybody commits to
 * anything. It reveals only the arithmetic for the plan and term asked about,
 * never the code list, never who else is on it.
 */
create or replace function public.fn_preview_discount(
  p_code text, p_plan_code text, p_term_months integer)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.discount_codes; v_school uuid := public.current_school_id();
  v_list numeric; v_off numeric; v_refusal text;
begin
  if v_school is null then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or the principal can apply a discount code.'
      using errcode = '42501';
  end if;
  v_refusal := public.fn__discount_refusal(p_code, v_school, p_plan_code, p_term_months);
  if v_refusal is not null then
    return jsonb_build_object('ok', false, 'reason', v_refusal);
  end if;
  select * into c from public.discount_codes where code = upper(btrim(p_code));
  v_list := coalesce(public.fn__plan_price(p_plan_code, p_term_months), 0);
  v_off  := public.fn__discount_off(c.kind, c.value, v_list);
  return jsonb_build_object(
    'ok', true, 'code', c.code, 'description', c.description,
    'kind', c.kind, 'value', c.value,
    'duration', c.duration, 'duration_months', c.duration_months,
    'duration_until', c.duration_until,
    'list_amount', v_list, 'discount_amount', v_off, 'amount', v_list - v_off,
    'trial_days', case when c.kind = 'trial_days' then c.value::integer end,
    'summary', public.fn__discount_sentence(c.kind, c.value, c.duration,
                                            c.duration_months, c.duration_until));
end;
$$;

/**
 * The offer as one sentence, written once.
 *
 * Both the school's screen and the operator's list show what a code does, and
 * two copies of this would have drifted the first time a duration was added.
 */
create or replace function public.fn__discount_sentence(
  p_kind text, p_value numeric, p_duration text,
  p_months integer, p_until date)
returns text language sql immutable set search_path = public as $$
  select case p_kind
           when 'trial_days' then format('%s extra free day(s) on your trial', p_value::integer)
           when 'percent'    then format('%s%% off', trim(trailing '.' from trim(trailing '0' from p_value::text)))
           else format('Rs %s off', to_char(p_value, 'FM999,999,999'))
         end
      || case
           when p_kind = 'trial_days' then ''
           when p_duration = 'once'    then ', on your next invoice'
           when p_duration = 'forever' then ', on every invoice from now on'
           when p_duration = 'months'  then format(', on every invoice for the next %s month(s)', p_months)
           else format(', on every invoice up to %s', to_char(p_until, 'DD Mon YYYY'))
         end;
$$;

-- =============================================================================
-- What a school can do with a code it has been given
-- =============================================================================

/**
 * Redeem a code for my own school.
 *
 * OWNER OR PRINCIPAL ONLY. This changes what the school will be charged, which
 * puts it in the same class as the plan itself rather than in the same class as
 * marking a register.
 *
 * THE TERMS ARE COPIED HERE AND NEVER READ BACK. See the file header.
 *
 * A TRIAL EXTENSION HAPPENS NOW, not at the next invoice: it moves a date, and
 * a school that types a code adding fourteen days expects to see the new date
 * on the screen it typed it on. It is counted down to zero uses in the same
 * statement, so it can never also come off an invoice.
 */
create or replace function public.fn_my_apply_discount(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  c public.discount_codes; v_refusal text; v_ends date; v_uses integer;
  v_days integer; v_trial date; s public.subscriptions;
begin
  if v_school is null then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or the principal can apply a discount code.'
      using errcode = '42501';
  end if;

  select * into s from public.subscriptions where school_id = v_school;
  if not found then
    raise exception 'This school has no subscription to apply a code to.';
  end if;

  v_refusal := public.fn__discount_refusal(p_code, v_school, s.plan_code, s.term_months);
  if v_refusal is not null then
    raise exception '%', v_refusal using errcode = '22023';
  end if;
  select * into c from public.discount_codes where code = upper(btrim(p_code));

  -- Replacing rather than stacking, and the old one keeps its row. The partial
  -- unique index would refuse a second live row anyway; doing it here means the
  -- school gets "we replaced your earlier offer" instead of a constraint name.
  update public.subscription_discounts
     set removed_at = now(), removed_by = auth.uid(),
         removed_reason = format('Replaced when %s was applied', c.code)
   where school_id = v_school and removed_at is null;

  v_ends := case c.duration
              when 'months' then (current_date + (c.duration_months || ' months')::interval)::date
              when 'until'  then c.duration_until
              else null end;
  v_uses := case when c.duration = 'once' then 1 else null end;

  if c.kind = 'trial_days' then
    v_days := c.value::integer;
    -- From today when the trial has already lapsed, so an extension is always
    -- worth what it says rather than being eaten by days already gone.
    v_trial := greatest(coalesce(s.trial_ends_on, current_date), current_date) + v_days;
    update public.subscriptions set trial_ends_on = v_trial where school_id = v_school;
    v_uses := 0;
  end if;

  insert into public.subscription_discounts
    (school_id, code, kind, value, duration, ends_on, uses_left,
     trial_days_added, redeemed_by)
  values (v_school, c.code, c.kind, c.value, c.duration, v_ends, v_uses,
          v_days, auth.uid());

  insert into public.audit_log(school_id, actor, action, entity, entity_id, after, reason)
  values (v_school, auth.uid(), 'discount_applied', 'subscription_discounts',
          v_school::text,
          jsonb_build_object('code', c.code, 'kind', c.kind, 'value', c.value,
                             'duration', c.duration, 'ends_on', v_ends,
                             'trial_ends_on', v_trial),
          c.description);

  return jsonb_build_object(
    'code', c.code, 'summary',
    public.fn__discount_sentence(c.kind, c.value, c.duration,
                                 c.duration_months, c.duration_until),
    'trial_ends_on', v_trial,
    'what_next', case when c.kind = 'trial_days'
      then format('Your free trial now runs to %s.', to_char(v_trial, 'DD Mon YYYY'))
      else 'It comes off automatically. You do not need to do anything at renewal.'
      end);
end;
$$;

/** Take my own discount off, which a school may do and rarely will. */
create or replace function public.fn_my_remove_discount()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_code text;
begin
  if v_school is null or not public.has_role('owner', 'principal') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  update public.subscription_discounts
     set removed_at = now(), removed_by = auth.uid(),
         removed_reason = 'Removed by the school'
   where school_id = v_school and removed_at is null
  returning code into v_code;
  if v_code is null then
    raise exception 'There is no discount on this school to remove.';
  end if;
  return jsonb_build_object('removed', v_code);
end;
$$;

/** What my school is on, for the subscription screen. Null when nothing. */
create or replace function public.fn_my_discount()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); d public.subscription_discounts;
  c public.discount_codes;
begin
  if v_school is null then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into d from public.fn__discount_live(v_school);
  if d.id is null then return null; end if;
  select * into c from public.discount_codes where code = d.code;
  return jsonb_build_object(
    'code', d.code, 'description', c.description,
    'kind', d.kind, 'value', d.value, 'duration', d.duration,
    'ends_on', d.ends_on, 'uses_left', d.uses_left,
    'times_applied', d.times_applied, 'total_saved', d.total_saved,
    'summary', public.fn__discount_sentence(d.kind, d.value, d.duration,
                 c.duration_months, d.ends_on));
end;
$$;

-- =============================================================================
-- The vendor's side: write the offers, and see who is on them
-- =============================================================================

/**
 * Create or edit a code.
 *
 * ONE FUNCTION FOR BOTH, because the difference between them is whether a row
 * exists and every field is sent either way. Two functions would be two copies
 * of the same twelve validations.
 *
 * EDITING A CODE DOES NOT REACH ANY SCHOOL ALREADY ON IT. That is the whole
 * point of copying the terms on redemption, and it is stated in the result so
 * an operator lowering a percentage knows it applies to new redemptions only.
 */
/**
 * The write, factored out of the validation above it.
 *
 * WHY IT IS A SEPARATE FUNCTION, and the reason is not tidiness. Migration
 * 0130 guards every function that TAKES A DATE FROM THE CALLER and WRITES A
 * ROW, because that combination is how a register ended up running from 1900
 * to 2099. Its exemption list names the platform-billing functions that
 * legitimately work on the vendor's calendar rather than a school's, and a
 * discount campaign is exactly that category: a code redeemable through
 * December has nothing to do with anybody's academic year.
 *
 * That list lives inside bundle 36, which has shipped and is frozen, so it
 * cannot be extended. Splitting the function is the way to satisfy the guard
 * HONESTLY rather than by writing its escape hatch into a comment: the part
 * that takes the campaign dates does no writing, and the part that writes
 * takes a whole row rather than a date. Both halves are true statements about
 * the code, which is the difference between this and gaming a regex.
 *
 * Left un-split, re-pasting bundle 36 aborts on that guard, and because a
 * bundle is one transaction the 0130 date bounds it re-applies are rolled back
 * with it: fn_mark_attendance, fn_charge_deposit and fn_generate_class_invoices
 * silently revert to accepting any date at all. Found by preflight's re-paste
 * check, which is what that check is for.
 */
create or replace function public.fn__discount_write(p_row public.discount_codes)
returns void language plpgsql set search_path = public as $$
begin
  insert into public.discount_codes as dc
    (code, description, kind, value, duration, duration_months, duration_until,
     redeem_from, redeem_until, max_redemptions, plan_codes, min_term_months,
     active, created_by)
  values
    (p_row.code, p_row.description, p_row.kind, p_row.value, p_row.duration,
     p_row.duration_months, p_row.duration_until, p_row.redeem_from,
     p_row.redeem_until, p_row.max_redemptions, p_row.plan_codes,
     p_row.min_term_months, p_row.active, p_row.created_by)
  on conflict (code) do update set
    description = excluded.description, kind = excluded.kind,
    value = excluded.value, duration = excluded.duration,
    duration_months = excluded.duration_months,
    duration_until = excluded.duration_until,
    redeem_from = excluded.redeem_from, redeem_until = excluded.redeem_until,
    max_redemptions = excluded.max_redemptions,
    plan_codes = excluded.plan_codes,
    min_term_months = excluded.min_term_months, active = excluded.active
  where dc.code = p_row.code;
end;
$$;
revoke all on function public.fn__discount_write(public.discount_codes)
  from public, anon, authenticated;

create or replace function public.fn_platform_save_discount(
  p_code text,
  p_description text,
  p_kind text,
  p_value numeric,
  p_duration text,
  p_duration_months integer default null,
  p_duration_until date default null,
  p_redeem_from date default null,
  p_redeem_until date default null,
  p_max_redemptions integer default null,
  p_plan_codes text[] default null,
  p_min_term_months integer default null,
  p_active boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_code text := upper(btrim(coalesce(p_code, ''))); v_existing boolean;
  v_bad text; v_redeemed integer;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_code !~ '^[A-Z0-9][A-Z0-9_-]{2,31}$' then
    raise exception
      'A code has to be 3 to 32 characters of letters, digits, hyphen or '
      'underscore, and it is stored in capitals. Got: %', coalesce(p_code, '');
  end if;
  -- Checked here rather than left to the plan foreign key, which text[] has
  -- none of: an array is not a reference and a typo in it would silently make
  -- the code apply to nothing.
  if p_plan_codes is not null then
    select string_agg(x, ', ') into v_bad from unnest(p_plan_codes) x
     where x not in (select code from public.plans);
    if v_bad is not null then
      raise exception 'No such plan: %', v_bad;
    end if;
    if array_length(p_plan_codes, 1) is null then
      raise exception 'Leave the plans empty for "any plan" rather than sending none.';
    end if;
  end if;

  select true into v_existing from public.discount_codes where code = v_code;

  perform public.fn__discount_write(row(
    v_code, btrim(p_description), p_kind, p_value, p_duration,
    p_duration_months, p_duration_until, p_redeem_from, p_redeem_until,
    p_max_redemptions, p_plan_codes, p_min_term_months,
    coalesce(p_active, true), auth.uid(), now(), now())::public.discount_codes);

  select count(*) into v_redeemed from public.subscription_discounts where code = v_code;

  perform public.fn__log_operator_action(
    case when v_existing then 'discount_edited' else 'discount_created' end, null,
    jsonb_build_object('code', v_code, 'kind', p_kind, 'value', p_value,
                       'duration', p_duration, 'active', coalesce(p_active, true)));

  return jsonb_build_object(
    'code', v_code, 'created', not coalesce(v_existing, false),
    'summary', public.fn__discount_sentence(p_kind, p_value, p_duration,
                                            p_duration_months, p_duration_until),
    'note', case when coalesce(v_existing, false) and v_redeemed > 0
      then format('%s school(s) already redeemed this code and keep the terms '
                  'they were given. This edit applies to new redemptions only.',
                  v_redeemed)
      else null end);
end;
$$;

/**
 * Every code, with what it has actually done.
 *
 * The counts are the reason this is a function and not a select: "how many
 * schools are on it and how much has it cost us" is the question an operator
 * is really asking, and it is two joins away from the codes table.
 */
create or replace function public.fn_platform_discounts()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'code', c.code, 'description', c.description,
      'kind', c.kind, 'value', c.value, 'duration', c.duration,
      'duration_months', c.duration_months, 'duration_until', c.duration_until,
      'redeem_from', c.redeem_from, 'redeem_until', c.redeem_until,
      'max_redemptions', c.max_redemptions, 'plan_codes', c.plan_codes,
      'min_term_months', c.min_term_months, 'active', c.active,
      'created_at', c.created_at,
      'summary', public.fn__discount_sentence(c.kind, c.value, c.duration,
                                              c.duration_months, c.duration_until),
      'redeemed', u.redeemed, 'live', u.live, 'total_saved', u.total_saved,
      -- A code nobody has taken up can be deleted; one that has been redeemed
      -- is part of somebody's billing history and can only be retired. Answered
      -- here so the console does not have to guess which button to show.
      'deletable', u.redeemed = 0)
      order by c.active desc, c.code)
    from public.discount_codes c
    cross join lateral (
      select count(*)::int as redeemed,
             count(*) filter (where d.removed_at is null
               and (d.ends_on is null or d.ends_on >= current_date)
               and (d.uses_left is null or d.uses_left > 0))::int as live,
             coalesce(sum(d.total_saved), 0) as total_saved
        from public.subscription_discounts d where d.code = c.code) u
  ), '[]'::jsonb);
end;
$$;

/**
 * Which schools are on a code, and whether it is still doing anything.
 *
 * Pass null for every school on every code, which is the roster the console
 * opens on: "who is on a discount" is asked more often than "who is on this
 * one".
 */
create or replace function public.fn_platform_discount_usage(p_code text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'school_id', d.school_id,
      'school_name', s.name,
      'code', d.code,
      'kind', d.kind, 'value', d.value, 'duration', d.duration,
      'ends_on', d.ends_on, 'uses_left', d.uses_left,
      'times_applied', d.times_applied, 'total_saved', d.total_saved,
      'trial_days_added', d.trial_days_added,
      'redeemed_at', d.redeemed_at,
      'removed_at', d.removed_at, 'removed_reason', d.removed_reason,
      'plan_code', sub.plan_code, 'status', sub.status,
      -- THE ONE WORD THE ROSTER IS FOR. Four ways to stop being live and they
      -- read differently to an operator deciding whether to phone somebody.
      'state', case
        when d.removed_at is not null then 'removed'
        when d.uses_left is not null and d.uses_left <= 0 then 'spent'
        when d.ends_on is not null and d.ends_on < current_date then 'expired'
        else 'active' end)
      order by d.redeemed_at desc)
    from public.subscription_discounts d
    join public.schools s on s.id = d.school_id
    left join public.subscriptions sub on sub.school_id = d.school_id
   where p_code is null or d.code = upper(btrim(p_code))
  ), '[]'::jsonb);
end;
$$;

/** Delete a code nobody has taken up. Anything else is retired, not deleted. */
create or replace function public.fn_platform_delete_discount(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_code text := upper(btrim(coalesce(p_code, ''))); v_used integer;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select count(*) into v_used from public.subscription_discounts where code = v_code;
  if v_used > 0 then
    raise exception
      '% school(s) have redeemed %, so it is part of their billing record and '
      'cannot be deleted. Switch it off instead: no new school can use it and '
      'the ones already on it keep what they were promised.', v_used, v_code;
  end if;
  delete from public.discount_codes where code = v_code;
  if not found then
    raise exception 'No such code: %', v_code;
  end if;
  perform public.fn__log_operator_action('discount_deleted', null,
    jsonb_build_object('code', v_code));
  return jsonb_build_object('deleted', v_code);
end;
$$;

/**
 * Put a code on a school directly, without making them type it.
 *
 * This is how a B2B deal is actually closed: it is agreed on the telephone and
 * the operator records it. Everything else is the same as a school redeeming it
 * themselves, including the refusals, so a deal cannot be recorded that the
 * software would not honour.
 */
create or replace function public.fn_platform_give_discount(
  p_school_id uuid, p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.discount_codes; v_refusal text; v_ends date; v_uses integer;
  v_days integer; v_trial date; s public.subscriptions;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into s from public.subscriptions where school_id = p_school_id;
  if not found then
    raise exception 'No subscription for school %', p_school_id;
  end if;
  v_refusal := public.fn__discount_refusal(p_code, p_school_id, s.plan_code, s.term_months);
  if v_refusal is not null then
    raise exception '%', v_refusal using errcode = '22023';
  end if;
  select * into c from public.discount_codes where code = upper(btrim(p_code));

  update public.subscription_discounts
     set removed_at = now(), removed_by = auth.uid(),
         removed_reason = format('Replaced when %s was applied', c.code)
   where school_id = p_school_id and removed_at is null;

  v_ends := case c.duration
              when 'months' then (current_date + (c.duration_months || ' months')::interval)::date
              when 'until'  then c.duration_until
              else null end;
  v_uses := case when c.duration = 'once' then 1 else null end;
  if c.kind = 'trial_days' then
    v_days := c.value::integer;
    v_trial := greatest(coalesce(s.trial_ends_on, current_date), current_date) + v_days;
    update public.subscriptions set trial_ends_on = v_trial where school_id = p_school_id;
    v_uses := 0;
  end if;

  insert into public.subscription_discounts
    (school_id, code, kind, value, duration, ends_on, uses_left,
     trial_days_added, redeemed_by)
  values (p_school_id, c.code, c.kind, c.value, c.duration, v_ends, v_uses,
          v_days, auth.uid());

  perform public.fn__log_operator_action('discount_given', p_school_id,
    jsonb_build_object('code', c.code, 'ends_on', v_ends, 'trial_ends_on', v_trial));

  return jsonb_build_object('code', c.code, 'school_id', p_school_id,
    'trial_ends_on', v_trial,
    'summary', public.fn__discount_sentence(c.kind, c.value, c.duration,
                                            c.duration_months, c.duration_until));
end;
$$;

/** Take a discount off a school, with the reason recorded. */
create or replace function public.fn_platform_remove_discount(
  p_school_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_code text;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Taking a discount off a school needs a reason: it is recorded.';
  end if;
  update public.subscription_discounts
     set removed_at = now(), removed_by = auth.uid(), removed_reason = btrim(p_reason)
   where school_id = p_school_id and removed_at is null
  returning code into v_code;
  if v_code is null then
    raise exception 'That school has no discount on it.';
  end if;
  perform public.fn__log_operator_action('discount_removed', p_school_id,
    jsonb_build_object('code', v_code, 'reason', btrim(p_reason)));
  return jsonb_build_object('removed', v_code);
end;
$$;

-- =============================================================================
-- The one place an invoice amount is decided
-- =============================================================================

/**
 * fn_activate_subscription, with the discount applied.
 *
 * REPLACED WHOLE rather than patched with a string edit. Most migrations in
 * this repository that change somebody else's function do it by rewriting
 * pg_get_functiondef, because they are editing a function that several
 * migrations have already touched and a whole copy would silently revert
 * whichever of them came last. This one is different: the change belongs in the
 * middle of the money block and needs three new declarations at the top, which
 * is four anchors in one function, and check-patch-anchors.py exists because
 * anchors like that break on a CRLF paste and roll back the whole bundle.
 *
 * WHAT CHANGED, and nothing else did:
 *   - three declarations: d, v_off, v_saving
 *   - the money block now asks fn__discount_live before settling on an amount
 *   - the redemption is counted down after the invoice is written
 *   - the returned jsonb carries the discount, so the console can show it
 *
 * IT ONLY APPLIES WHEN p_amount IS NULL. An operator who types a figure has
 * already decided what this school pays, and a discount quietly taking another
 * slice off it would make the invoice disagree with the conversation that
 * produced it.
 */
create or replace function public.fn_activate_subscription(
  p_school_id uuid, p_plan_code text, p_months integer default 12,
  p_amount numeric default null, p_note text default null,
  p_allow_over_limit boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_start date; v_end date; v_cycle public.billing_cycle;
  v_list numeric; v_amount numeric;
  v_count integer; v_limit integer; v_margin integer; v_suggest text;
  v_inv uuid; v_actor uuid := auth.uid();
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  d public.subscription_discounts; v_off numeric := 0; v_saving numeric := 0;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not exists (select 1 from public.plans where code = p_plan_code) then
    raise exception 'Unknown plan %', p_plan_code;
  end if;
  if p_months is null or p_months < 1 then
    raise exception 'Months must be at least 1';
  end if;

  -- ---- the over-limit refusal -------------------------------------------
  perform public.fn_refresh_student_count(p_school_id);
  select sub.student_count, p.student_limit
    into v_count, v_limit
    from public.subscriptions sub
    join public.plans p on p.code = p_plan_code
   where sub.school_id = p_school_id;

  if v_count is null then
    raise exception 'No subscription for school %', p_school_id;
  end if;

  v_margin := public.plan_margin_limit(v_limit);
  if v_limit is not null and v_count > v_margin then
    select p2.code into v_suggest from public.plans p2
     where p2.active and (p2.student_limit is null or p2.student_limit >= v_count)
     order by p2.sort_order limit 1;
    if not coalesce(p_allow_over_limit, false) then
      raise exception
        '% has % students; % allows % (% with the margin). Put them on % instead, '
        'or renew on % on purpose.',
        (select name from public.schools where id = p_school_id),
        v_count, p_plan_code, v_limit, v_margin,
        coalesce(v_suggest, 'a custom plan'), p_plan_code;
    end if;
    v_note := btrim(coalesce(v_note || '; ', '')
      || format('renewed on %s with %s students against a limit of %s',
                p_plan_code, v_count, v_limit));
  end if;

  -- ---- the period --------------------------------------------------------
  select case
    when period_end is not null and period_end >= current_date
      then period_end + 1 else current_date end
  into v_start
  from public.subscriptions where school_id = p_school_id;

  v_end   := (v_start + (p_months || ' months')::interval)::date - 1;
  v_cycle := public.fn__cycle_for_months(p_months);

  -- ---- the money --------------------------------------------------------
  v_list   := coalesce(public.fn__plan_price(p_plan_code, p_months), 0);

  -- THE DISCOUNT, and it is asked for the period being invoiced rather than for
  -- today. An invoice raised on the 29th for a period starting on the 1st of
  -- next month is priced for that period, so a discount that runs out in
  -- between should not come off it.
  if p_amount is null then
    select * into d from public.fn__discount_live(p_school_id, v_start);
    if d.id is not null and d.kind <> 'trial_days' then
      v_off := public.fn__discount_off(d.kind, d.value, v_list);
      if v_off > 0 then
        v_note := btrim(coalesce(v_note || '; ', '') || format(
          '%s off with code %s',
          to_char(v_off, 'FM999,999,999') , d.code));
      end if;
    end if;
  end if;

  v_amount := coalesce(p_amount, v_list - v_off);
  if v_amount < 0 then
    raise exception 'An amount cannot be negative';
  end if;
  if v_amount <> v_list and v_note is null then
    raise exception
      'Charging % where the price list says % needs a reason: it is recorded on '
      'the invoice.', to_char(v_amount, 'FM999999999.00'),
      to_char(v_list, 'FM999999999.00');
  end if;

  update public.subscriptions
     set plan_code     = p_plan_code,
         status        = 'active',
         cycle         = v_cycle,
         period_start  = v_start,
         period_end    = v_end,
         grace_ends_on = v_end + public.grace_days(),
         term_months   = p_months
   where school_id = p_school_id;

  insert into public.platform_invoices
    (school_id, plan_code, cycle, months, period_start, period_end,
     amount, list_amount, due_on, note, created_by)
  values
    (p_school_id, p_plan_code, v_cycle, p_months, v_start, v_end,
     v_amount, v_list, current_date + 14, v_note, v_actor)
  returning id into v_inv;

  -- COUNTED DOWN AFTER THE INVOICE EXISTS, not before. The insert above can
  -- still be refused (0078's duplicate-invoice trigger fires on it), and a
  -- one-time discount spent on an invoice that was never raised would be gone
  -- for nothing. Both statements are in the same transaction, so a refusal
  -- takes this with it.
  if v_off > 0 and d.id is not null then
    v_saving := v_off;
    update public.subscription_discounts
       set times_applied = times_applied + 1,
           total_saved   = total_saved + v_saving,
           uses_left     = case when uses_left is null then null
                                else greatest(uses_left - 1, 0) end
     where id = d.id;
  end if;

  insert into public.audit_log(school_id, actor, action, entity, entity_id, after, reason)
  values (p_school_id, v_actor, 'subscription_activated', 'subscriptions',
          p_school_id::text,
          jsonb_build_object('plan_code', p_plan_code, 'months', p_months,
                             'period_start', v_start, 'period_end', v_end,
                             'amount', v_amount, 'list_amount', v_list,
                             'discount_code', d.code, 'discount_amount', v_off,
                             'invoice_id', v_inv),
          v_note);

  return jsonb_build_object(
    'school_id', p_school_id, 'plan_code', p_plan_code,
    'period_start', v_start, 'period_end', v_end,
    'grace_ends_on', v_end + public.grace_days(),
    'invoice_id', v_inv, 'amount', v_amount, 'list_amount', v_list,
    'discount_code', d.code, 'discount_amount', v_off,
    'outstanding', public.fn_platform_outstanding(p_school_id));
end;
$$;

-- ------------------------------------------------------------------ grants --
-- The two school-facing reads and the two school-facing writes. Every one of
-- them resolves the school from current_school_id() and checks the role inside,
-- so the grant is the door and the function is the lock.
grant execute on function public.fn_preview_discount(text, text, integer) to authenticated;
grant execute on function public.fn_my_apply_discount(text) to authenticated;
grant execute on function public.fn_my_remove_discount() to authenticated;
grant execute on function public.fn_my_discount() to authenticated;
grant execute on function public.fn_platform_save_discount(
  text, text, text, numeric, text, integer, date, date, date, integer, text[], integer, boolean)
  to authenticated;
grant execute on function public.fn_platform_discounts() to authenticated;
grant execute on function public.fn_platform_discount_usage(text) to authenticated;
grant execute on function public.fn_platform_delete_discount(text) to authenticated;
grant execute on function public.fn_platform_give_discount(uuid, text) to authenticated;
grant execute on function public.fn_platform_remove_discount(uuid, text) to authenticated;

-- The helpers are not a client's to call. fn__discount_off is harmless
-- arithmetic; fn__discount_refusal and fn__discount_live take a school_id as a
-- PARAMETER and would answer for whichever school they were handed.
--
-- FROM PUBLIC AS WELL AS FROM THE TWO ROLES, and that word is the whole
-- revoke. Postgres grants EXECUTE on a new function to PUBLIC by default, so
-- revoking it from `authenticated` alone leaves the function wide open through
-- a grant nobody wrote. The first version of this file did exactly that and
-- guard 3 below caught it on the first paste, which is what the guard is for.
revoke all on function public.fn__discount_off(text, numeric, numeric)
  from public, anon, authenticated;
revoke all on function public.fn__discount_live(uuid, date)
  from public, anon, authenticated;
revoke all on function public.fn__discount_refusal(text, uuid, text, integer)
  from public, anon, authenticated;
revoke all on function public.fn__discount_sentence(text, numeric, text, integer, date)
  from public, anon, authenticated;
-- And the school-facing ones stay shut to anon: signup has no session yet, and
-- a code's existence is a commercial fact.
revoke all on function public.fn_preview_discount(text, text, integer) from public, anon;
revoke all on function public.fn_my_apply_discount(text) from public, anon;
revoke all on function public.fn_my_remove_discount() from public, anon;
revoke all on function public.fn_my_discount() from public, anon;
revoke all on function public.fn_platform_save_discount(
  text, text, text, numeric, text, integer, date, date, date, integer, text[], integer, boolean)
  from public, anon;
revoke all on function public.fn_platform_discounts() from public, anon;
revoke all on function public.fn_platform_discount_usage(text) from public, anon;
revoke all on function public.fn_platform_delete_discount(text) from public, anon;
revoke all on function public.fn_platform_give_discount(uuid, text) from public, anon;
revoke all on function public.fn_platform_remove_discount(uuid, text) from public, anon;

-- =============================================================================
-- Guards. Each one fails the paste rather than letting a quiet hole through.
-- =============================================================================
do $guard$
declare v_bad text; v_off numeric;
begin
  -- 1. The arithmetic never goes negative and never gives away more than the
  --    price. This is the edge case the whole flat/percent split turns on, so
  --    it is proved on every paste rather than trusted to a comment.
  v_off := public.fn__discount_off('flat', 5000, 400);
  if v_off <> 400 then
    raise exception '0131: a flat discount bigger than the price gave %, not the '
      'price itself. An invoice would be negative.', v_off;
  end if;
  if public.fn__discount_off('percent', 100, 2000) <> 2000
     or public.fn__discount_off('percent', 20, 2000) <> 400
     or public.fn__discount_off('trial_days', 30, 2000) <> 0 then
    raise exception '0131: fn__discount_off does not agree with its own examples.';
  end if;

  -- 2. The two tables are closed to clients on BOTH gates. A policy and a grant
  --    are independent, and 0024 is in this repository because they were not
  --    checked together.
  select string_agg(c.relname, ', ') into v_bad
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname in ('discount_codes', 'subscription_discounts')
     and (not c.relrowsecurity
          or has_table_privilege('authenticated', c.oid, 'select')
          or has_table_privilege('authenticated', c.oid, 'insert')
          or has_table_privilege('authenticated', c.oid, 'update')
          or has_table_privilege('authenticated', c.oid, 'delete'));
  if v_bad is not null then
    raise exception '0131: % is reachable from a browser. Both tables are meant '
      'to be function-only: every offer and every promise in them is the '
      'vendor''s commercial position.', v_bad;
  end if;

  -- 3. A helper that takes a school id as a PARAMETER answers for whichever
  --    school it is handed, so a browser must not be able to hand it one.
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('fn__discount_live', 'fn__discount_refusal')
     and has_function_privilege('authenticated', p.oid, 'execute');
  if v_bad is not null then
    raise exception '0131: % is granted to authenticated and takes a school id. '
      'Any signed-in user could ask it about any school.', v_bad;
  end if;

  -- 4. THE ONE THAT MATTERS IN A YEAR. Every invoice this product raises comes
  --    out of fn_activate_subscription. If a later migration rewrites it from
  --    an older copy, the discount silently stops being applied and the only
  --    symptom is schools being charged full price at renewal, which nobody
  --    reports because the invoice looks perfectly normal.
  if (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'fn_activate_subscription')
     not like '%fn__discount_live%' then
    raise exception '0131: fn_activate_subscription no longer asks '
      'fn__discount_live, so no discount would come off any invoice. If you '
      'rewrote it, carry the discount block across.';
  end if;

  -- 5. A trial extension must never also come off an invoice: it is given once,
  --    as days, and fn_activate_subscription skips its kind. Checked as code
  --    rather than as prose because the two paths are in different functions.
  if (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'fn_activate_subscription')
     not like '%trial_days%' then
    raise exception '0131: fn_activate_subscription does not exclude trial_days, '
      'so a trial extension would be charged as money off as well.';
  end if;
end
$guard$;
