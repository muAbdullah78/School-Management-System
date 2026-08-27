-- =============================================================================
-- 0081 — The business could not say what it was worth
--
-- Phase 5 of docs/SUPER-ADMIN-DESIGN.md.
--
-- WHAT THE CONSOLE COULD ANSWER BEFORE THIS
--
--   what did we invoice in August? ....... fn_platform_revenue, yes
--   who owes us money? ................... yes
--   what is our monthly recurring revenue? nothing
--   how many trials turn into customers? . nothing
--   how many customers have we lost? ..... nothing — `cancelled` has no date
--   are our schools growing? ............. student_count_snapshots is written on
--                                          every recount and read by NOTHING
--
-- The last one is the waste worth naming: 0026 writes a row per school per day
-- recording its pupil count, 0067 made that happen automatically on every
-- admission, and no function has ever read the table. That is a daily record of
-- your customers' growth, which is your own growth, sitting unused.
--
-- WHY MRR IS NOT COMPUTED FROM THE PRICE LIST
--
-- The obvious implementation is `sum(price_yearly)/12 over active subscriptions`.
-- It is wrong in a way that flatters: a school on a discount, a school given a
-- free year as an apology, and a school paying full price all contribute the same
-- list price. 0064 exists precisely because discounts left no trace, and an MRR
-- built on list price would reintroduce the same blindness one layer up.
--
-- So each school contributes the monthly equivalent of what it was ACTUALLY
-- charged: the live invoice covering today, amount divided by months. Pre-tax,
-- because sales tax collected on somebody else's behalf is not revenue.
--
-- AND WHY A SCHOOL WITH NO INVOICE CONTRIBUTES ZERO
--
-- A school holding licence time nobody billed for contributes nothing, because
-- nothing was billed. Counting list price there would put revenue in the figure
-- that does not exist and will never arrive. But a silent zero is its own lie, so
-- `unbilled` is reported beside MRR with the count — it is the same fact 0079's
-- `unbilled_days` surfaces per school, totalled.
--
-- CHURN IS MEASURED FROM DATED EVENTS, NOT FROM A STATUS
--
-- `subscriptions.status = 'cancelled'` has no timestamp, so "how many did we lose
-- this year" was unanswerable from the subscription alone. It is computed from
-- schools.archived_at (0079) and from operator_actions rows, which 0073 dates.
-- Before those two migrations there is no history, and the function says so
-- rather than reporting a confident zero.
--
-- EVERY FIGURE CARRIES WHAT IT MEASURES. A metric on a dashboard with no
-- definition becomes whatever the person looking at it assumes, and two people
-- then argue about a number they define differently.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. What one school contributes per month, right now
--
-- fn__ and revoked: it answers for any school without asking who wants to know.
-- ---------------------------------------------------------------------------
create or replace function public.fn__school_mrr(p_school_id uuid, p_as_at date)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce((
    select round(i.amount / greatest(i.months, 1), 2)
      from public.platform_invoices i
     where i.school_id = p_school_id
       and i.kind = 'invoice'
       and i.voided_at is null
       and p_as_at between i.period_start and i.period_end
     -- The newest document covering the date, so a mid-term plan change counts
     -- at the new price rather than the one it replaced.
     order by i.issued_on desc, i.serial desc
     limit 1), 0);
$$;

revoke all on function public.fn__school_mrr(uuid, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The business, in one call
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_metrics(p_as_at date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
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
               'list_mrr', round(count(s.id) * p.price_yearly / 12, 2)) as x
        from public.plans p
        left join public.subscriptions sub on sub.plan_code = p.code
        left join public.schools s
               on s.id = sub.school_id
              and s.archived_at is null
              and public.fn_effective_status(s.id) in ('active', 'grace')
       group by p.code, p.name, p.sort_order, p.price_yearly) g;

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
        || 'tax. Not the price list — a discounted school counts at its discount.'),

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
          || '0079 left no timestamp, so there is no history to measure — which is '
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
$$;

-- ---------------------------------------------------------------------------
-- 3. The growth chart the snapshots were always for
--
-- One row per month: how many schools we had and how many pupils were inside
-- them. The last snapshot in each month, per school, so a school recounted forty
-- times in March is one point in March and not forty.
--
-- Reading student_count_snapshots for the first time since 0026 wrote it.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_growth(p_months integer default 12)
returns table (
  month date, schools integer, students integer, avg_per_school numeric
) language plpgsql stable security definer set search_path = public as $$
declare v_n integer := greatest(1, least(coalesce(p_months, 12), 60));
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
    with month_end as (
      -- The last count recorded for each school in each month. distinct on is
      -- the cheapest correct way to say "the newest row per group".
      select distinct on (date_trunc('month', s.counted_on), s.school_id)
             date_trunc('month', s.counted_on)::date as m,
             s.school_id, s.student_count
        from public.student_count_snapshots s
       where s.counted_on >= (date_trunc('month', current_date)
                              - make_interval(months => v_n - 1))::date
       order by date_trunc('month', s.counted_on), s.school_id, s.counted_on desc
    )
    select me.m,
           count(*)::integer,
           coalesce(sum(me.student_count), 0)::integer,
           round(coalesce(sum(me.student_count), 0)::numeric
                 / greatest(count(*), 1), 1)
      from month_end me
     group by me.m
     order by me.m;
end;
$$;

grant  execute on function public.fn_platform_metrics(date)   to authenticated;
revoke execute on function public.fn_platform_metrics(date) from public, anon;
grant  execute on function public.fn_platform_growth(integer)   to authenticated;
revoke execute on function public.fn_platform_growth(integer) from public, anon;
