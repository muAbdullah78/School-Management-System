-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0113_the_renewal_run.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0113: The bill goes out on the day it is due, whether anybody remembered
--
-- WHAT WAS MISSING
--
-- 0078 built the operator's renewal worklist and built it well: who expires
-- when, in buckets, ordered so the top of the list is today's phone calls. What
-- it could not do is act. Every renewal invoice in this product exists because
-- somebody opened the console and pressed a button, so the failure mode is not
-- a bug, it is a Tuesday: the operator is on a call, the list is not opened, and
-- a school's period ends with no invoice ever raised. It then lapses into grace
-- and finally locks, having never been asked for money.
--
-- This is the runner. It finds every school whose payment has fallen due and
-- raises the invoice.
--
-- IT RAISES INVOICES. IT DOES NOT TAKE MONEY.
--
-- That separation is deliberate and it survives the arrival of a card gateway.
-- The bill is owed by every school whose period has ended, whatever it pays
-- with; only the COLLECTION differs, and collection is a separate step against
-- a separate table of attempts. Building them as one function would mean a
-- gateway outage stopped invoices going out.
--
-- WHY IT REUSES fn_activate_subscription RATHER THAN BILLING FOR ITSELF
--
-- That function already decides the period ("renewing early extends from the
-- existing end date, so a school that pays a week ahead does not lose that
-- week"), already refuses a renewal onto a plan the school has outgrown,
-- already writes the invoice and the operator action, and already trips 0078's
-- duplicate-invoice trigger if the same period is billed twice. A runner with
-- its own copy of that arithmetic would be a second opinion about what a school
-- owes, and the two would diverge on the first edge case.
--
-- DRY RUN BY DEFAULT
--
-- The default is to change nothing and report what it WOULD do. A batch job
-- that moves money and whose default is "go" is a job somebody runs by accident
-- while exploring, and the exploring is exactly what a new operator does first.
--
-- AND IT DOES NOT INVOICE A TRIAL THAT NEVER SAID YES
--
-- A school whose trial ends having never recorded a payment method has not
-- agreed to buy anything. Billing it would manufacture a receivable against
-- somebody who signed up to look around, put a fictional number into the
-- outstanding total the whole console is built on, and start a debt-chasing
-- conversation with a stranger. Those trials lapse exactly as they do today,
-- and they appear on the operator's worklist as they do today.
--
-- An already-paying school renewing is different: it is a customer, the term is
-- recorded, and the invoice is the bill for the period it is about to use.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. One row per run
-- ---------------------------------------------------------------------------
create table if not exists public.billing_runs (
  id           uuid primary key default gen_random_uuid(),
  started_at   timestamptz not null default now(),
  finished_at  timestamptz,
  dry_run      boolean not null,
  -- Null for a scheduled run with no human behind it, which is a real and
  -- distinguishable case rather than missing data.
  triggered_by uuid,
  as_at        date not null default current_date,
  considered   integer not null default 0,
  invoiced     integer not null default 0,
  skipped      integer not null default 0,
  failed       integer not null default 0
);

create index if not exists idx_billing_runs_recent on public.billing_runs(started_at desc);

alter table public.billing_runs enable row level security;
alter table public.billing_runs force row level security;
revoke all on table public.billing_runs from public, anon, authenticated;

comment on table public.billing_runs is
  'One row per renewal run. The vendor''s own operational record: no school_id, '
  'no policies, read through fn_platform_renewal_runs by a platform admin only.';

-- ---------------------------------------------------------------------------
-- 2. One row per school per run
--
-- THE LEDGER IS THE POINT, not a log. "Why was this school not billed in
-- March" is a question that gets asked, and the answer has to be a row rather
-- than an inference. Every school the run considered gets an entry, including
-- the ones it deliberately left alone and WHY.
-- ---------------------------------------------------------------------------
create table if not exists public.billing_attempts (
  id           uuid primary key default gen_random_uuid(),
  run_id       uuid not null references public.billing_runs(id) on delete cascade,
  school_id    uuid not null references public.schools(id) on delete cascade,
  at           timestamptz not null default now(),

  due_on       date,
  plan_code    text,
  term_months  integer,
  amount       numeric(12,2),

  outcome      text not null,
  -- In words, for a person. An outcome code says what happened; this says why,
  -- and it is what the operator reads when a school asks.
  message      text,
  invoice_id   uuid references public.platform_invoices(id) on delete set null,

  constraint billing_attempts_outcome_chk check (outcome in (
    -- Changed nothing, because this was a dry run.
    'would_invoice',
    -- The invoice was raised.
    'invoiced',
    -- 0078's duplicate trigger refused it: this period is already billed. Not
    -- an error. It is what a second run of the same day looks like, and the
    -- reason a re-run is safe.
    'already_invoiced',
    -- The school has outgrown its plan. fn_activate_subscription refuses that
    -- deliberately and a runner must not override it: putting a school on the
    -- wrong plan automatically is worse than leaving it for a person.
    'needs_decision',
    -- A trial that never recorded a way to pay. Not a customer.
    'trial_never_said_yes',
    'failed'
  ))
);

create index if not exists idx_billing_attempts_run on public.billing_attempts(run_id);
create index if not exists idx_billing_attempts_school
  on public.billing_attempts(school_id, at desc);

alter table public.billing_attempts enable row level security;
alter table public.billing_attempts force row level security;
revoke all on table public.billing_attempts from public, anon, authenticated;

comment on table public.billing_attempts is
  'Why each school was or was not billed on a given run. The vendor''s own '
  'record: no policies, read through fn_platform_renewal_runs.';

-- ---------------------------------------------------------------------------
-- 3. Who is due
--
-- Separate from the runner so the console can show the same list WITHOUT
-- running anything. A preview that is computed by a different query from the
-- one that acts is a preview that eventually lies.
-- ---------------------------------------------------------------------------
create or replace function public.fn__renewals_due(p_as_at date)
returns table (
  school_id uuid, school_name text, plan_code text, term_months integer,
  due_on date, amount numeric, was_trialing boolean, has_method boolean
) language sql stable security definer set search_path = public as $$
  select s.id, s.name, sub.plan_code, sub.term_months,
         public.fn__next_charge_on(s.id),
         public.fn__plan_price(sub.plan_code, sub.term_months),
         sub.status = 'trialing',
         sub.payment_method_id is not null
    from public.schools s
    join public.subscriptions sub on sub.school_id = s.id
   where s.active
     and s.archived_at is null
     -- Suspended by us, or cancelled: nothing is owed for a period we switched
     -- off, and billing for it is indefensible.
     and sub.suspended_at is null
     and sub.status <> 'cancelled'
     and not sub.cancel_at_period_end
     and public.fn__next_charge_on(s.id) is not null
     and public.fn__next_charge_on(s.id) <= p_as_at
   order by public.fn__next_charge_on(s.id), s.name;
$$;

revoke all on function public.fn__renewals_due(date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. The run
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_run_renewals(
  p_dry_run boolean default true,
  p_as_at date default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_run uuid; v_as_at date := coalesce(p_as_at, (now() at time zone 'Asia/Karachi')::date);
  v_dry boolean := coalesce(p_dry_run, true);
  r record; j jsonb; v_msg text; v_sqlstate text;
  v_considered int := 0; v_invoiced int := 0; v_skipped int := 0; v_failed int := 0;
  v_outcome text; v_note text; v_inv uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  insert into public.billing_runs (dry_run, triggered_by, as_at)
  values (v_dry, auth.uid(), v_as_at)
  returning id into v_run;

  for r in select * from public.fn__renewals_due(v_as_at) loop
    v_considered := v_considered + 1;
    v_outcome := null; v_note := null; v_inv := null;

    -- A trial that never said how it would pay is not a customer. Recorded
    -- rather than silently passed over: "why was this school not billed" has to
    -- have an answer that is a row.
    if r.was_trialing and not r.has_method then
      v_outcome := 'trial_never_said_yes';
      v_note := 'Their trial has ended and they never recorded a way to pay, so '
        || 'they have not agreed to buy anything. Left alone deliberately: they '
        || 'are on the renewal worklist and this is a phone call, not an invoice.';
      v_skipped := v_skipped + 1;

    elsif v_dry then
      v_outcome := 'would_invoice';
      v_note := format('Would invoice %s for %s month(s) on %s.',
                       to_char(r.amount, 'FM999,999,999'), r.term_months, r.plan_code);
      v_skipped := v_skipped + 1;

    else
      -- ONE SCHOOL'S FAILURE MUST NOT ABORT THE RUN. A plpgsql block with an
      -- exception handler is an implicit savepoint, so a raise here rolls back
      -- this school's invoice and nothing else. Without it, one school over its
      -- student limit would stop every school after it in the loop from being
      -- billed at all, and the run would report a success for the ones it never
      -- reached.
      begin
        j := public.fn_activate_subscription(
               r.school_id, r.plan_code, r.term_months, null,
               'Automatic renewal', false);
        v_inv := nullif(j->>'invoice_id', '')::uuid;
        v_outcome := 'invoiced';
        v_note := format('Invoiced %s for %s month(s) on %s.',
                         to_char(coalesce((j->>'amount')::numeric, r.amount),
                                 'FM999,999,999'),
                         r.term_months, r.plan_code);
        v_invoiced := v_invoiced + 1;
      exception when others then
        get stacked diagnostics v_msg = message_text, v_sqlstate = returned_sqlstate;
        -- 0078's duplicate-invoice trigger. Not an error: it is what a second
        -- run of the same day looks like, and it is the reason re-running is
        -- safe rather than expensive.
        if v_msg like '%already covers%' then
          v_outcome := 'already_invoiced';
          v_note := v_msg;
          v_skipped := v_skipped + 1;
        -- The school has outgrown its plan. fn_activate_subscription refuses
        -- that on purpose and the runner must not talk it round: renewing a
        -- school automatically onto a plan that does not fit it is worse than
        -- leaving it for a person who can phone them.
        elsif v_msg like '%allows%with the margin%' or v_msg like '%students;%' then
          v_outcome := 'needs_decision';
          v_note := v_msg;
          v_skipped := v_skipped + 1;
        else
          v_outcome := 'failed';
          v_note := format('[%s] %s', v_sqlstate, v_msg);
          v_failed := v_failed + 1;
        end if;
      end;
    end if;

    insert into public.billing_attempts
      (run_id, school_id, due_on, plan_code, term_months, amount,
       outcome, message, invoice_id)
    values (v_run, r.school_id, r.due_on, r.plan_code, r.term_months, r.amount,
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
    -- Said plainly, because the difference between the two is the whole reason
    -- the default is a dry run and an operator has to be sure which they ran.
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

grant  execute on function public.fn_platform_run_renewals(boolean, date) to authenticated;
revoke execute on function public.fn_platform_run_renewals(boolean, date) from public, anon;

-- ---------------------------------------------------------------------------
-- 5. What the last runs did
--
-- So a run is answerable after the fact. A batch job whose only output is the
-- screen of whoever pressed it is a job nobody can audit.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_renewal_runs(p_limit integer default 20)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(x order by x.started_at desc) from (
      select r.id, r.started_at, r.finished_at, r.dry_run, r.as_at,
             r.considered, r.invoiced, r.skipped, r.failed,
             (select email from public.platform_admins pa where pa.user_id = r.triggered_by)
               as triggered_by_email,
             (select coalesce(jsonb_agg(jsonb_build_object(
                       'school_name', (select name from public.schools s where s.id = a.school_id),
                       'outcome', a.outcome, 'amount', a.amount,
                       'message', a.message) order by a.at), '[]'::jsonb)
                from public.billing_attempts a where a.run_id = r.id) as attempts
        from public.billing_runs r
       order by r.started_at desc
       limit greatest(1, least(coalesce(p_limit, 20), 100))
    ) x), '[]'::jsonb);
end;
$$;

grant  execute on function public.fn_platform_renewal_runs(integer) to authenticated;
revoke execute on function public.fn_platform_renewal_runs(integer) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0113_the_renewal_run.sql', '19_the_renewal_run.sql');
end $ledger$;
