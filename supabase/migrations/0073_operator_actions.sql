-- =============================================================================
-- 0073 — Nothing recorded what the operator did to a school
--
-- Phase 1d of docs/SUPER-ADMIN-DESIGN.md, and the foundation the school-detail
-- screen and impersonation both need.
--
-- WHAT WAS MISSING
--
-- The operator can activate a licence, change a plan, discount a price to zero,
-- extend a trial and record a payment. Between them those decide what every
-- school pays. The only trace was the billing rows themselves: an invoice says
-- what was charged, but not who chose the price, or that a trial was extended
-- three times, or that a school was moved between plans and back.
--
-- With one customer that is recoverable from memory. With fifty it is the
-- difference between "why is this school on Starter at Rs 0" having an answer
-- and not having one — and the person asking in six months is the operator.
--
-- WHY A TRIGGER RATHER THAN A CALL IN EACH FUNCTION
--
-- The design doc said "every operator function writes one row". That is the
-- obvious shape and it is the weaker one: it can be forgotten. This project's
-- most common defect by a distance is not wrong logic, it is correct logic that
-- nothing reaches — fn_link_parent with no caller, message_templates.enabled
-- with no writer, fn_reverse_other_income with no caller. A log that a future
-- function forgets to call is worse than no log, because its gaps look like
-- inactivity.
--
-- So capture happens where the WRITE lands, on the tables only the operator
-- writes. A new operator function is logged the day it is written, by nobody
-- remembering anything. fn__log_operator_action stays available for actions that
-- touch no table at all — entering a school to help, refreshing every count —
-- which a trigger cannot see.
--
-- THE ONE HARD PART
--
-- subscriptions is not an operator-only table. 0067 put statement-level triggers
-- on students and enrollments that call fn_refresh_student_count, which UPDATEs
-- subscriptions on every admission at every school. Logging those would bury the
-- five decisions a year that matter under thousands of counter refreshes — and
-- a log nobody can read is a log nobody reads. So the trigger compares old and
-- new and ignores a change confined to the counter columns.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The log
--
-- RLS on with a read policy for the operator and NO write policy, exactly like
-- schema_migrations in 0069 and for the same reason: 0001:704 grants all four
-- verbs on every table in public to `authenticated` and 0025:768 makes that the
-- default for new tables. RLS is the only thing between a clerk and this table,
-- and tenant_isolation.sql check 4d fails CI if it is ever off.
--
-- actor_email is denormalised deliberately. platform_admins rows can be removed,
-- and "who granted this school a free year" must still have an answer afterwards.
-- ---------------------------------------------------------------------------
create table if not exists public.operator_actions (
  id          uuid primary key default gen_random_uuid(),
  at          timestamptz not null default now(),
  -- Null for a service-role or cron action, which is a real and distinguishable
  -- case rather than missing data.
  actor       uuid,
  actor_email text,
  action      text not null,
  -- Null where the action is not about one school (refreshing every count).
  school_id   uuid references public.schools(id),
  detail      jsonb not null default '{}'::jsonb
);

create index if not exists operator_actions_school_at_idx
  on public.operator_actions (school_id, at desc);
create index if not exists operator_actions_at_idx
  on public.operator_actions (at desc);

alter table public.operator_actions enable row level security;

drop policy if exists operator_actions_read on public.operator_actions;
create policy operator_actions_read on public.operator_actions
  for select using (public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- 2. Writing a row
--
-- SECURITY DEFINER so a trigger and an operator function can both reach it
-- without any grant to a browser role, and revoked from those roles so nothing
-- in the app can forge an entry.
-- ---------------------------------------------------------------------------
create or replace function public.fn__log_operator_action(
  p_action text, p_school_id uuid default null, p_detail jsonb default '{}'::jsonb
) returns void language plpgsql security definer set search_path = public as $$
declare v_email text;
begin
  select email into v_email from public.platform_admins where user_id = auth.uid();
  insert into public.operator_actions (actor, actor_email, action, school_id, detail)
  values (auth.uid(), v_email, p_action, p_school_id, coalesce(p_detail, '{}'::jsonb));
end;
$$;

revoke all on function public.fn__log_operator_action(text, uuid, jsonb)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Capture at the write
-- ---------------------------------------------------------------------------
create or replace function public.fn__log_platform_invoice()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.fn__log_operator_action('invoice_raised', new.school_id,
    jsonb_build_object(
      'invoice_id',  new.id,
      'plan_code',   new.plan_code,
      'months',      new.months,
      'amount',      new.amount,
      -- The number that makes a discount visible. 0064 records list_amount so
      -- "given away" can be computed; recording the gap here means the reason
      -- and the amount sit in one row rather than being joined back together.
      'list_amount', new.list_amount,
      'discount',    coalesce(new.list_amount, new.amount) - new.amount,
      'note',        new.note,
      'period',      new.period_start::text || ' to ' || new.period_end::text));
  return null;
end;
$$;

create or replace function public.fn__log_platform_payment()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.fn__log_operator_action('payment_recorded', new.school_id,
    jsonb_build_object(
      'payment_id', new.id,
      'invoice_id', new.invoice_id,
      'amount',     new.amount,
      'paid_on',    new.paid_on::text,
      'method',     new.method,
      'reference',  new.reference,
      'note',       new.note));
  return null;
end;
$$;

-- subscriptions, with the counter noise excluded. See the header.
create or replace function public.fn__log_subscription_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- Everything that is NOT the counter. If none of these moved, this update came
  -- from fn_refresh_student_count — which 0067 fires on every admission at every
  -- school — and is not an operator decision.
  if new.plan_code     is not distinct from old.plan_code
     and new.status        is not distinct from old.status
     and new.cycle         is not distinct from old.cycle
     and new.trial_ends_on is not distinct from old.trial_ends_on
     and new.period_start  is not distinct from old.period_start
     and new.period_end    is not distinct from old.period_end
     and new.grace_ends_on is not distinct from old.grace_ends_on
  then
    return null;
  end if;

  perform public.fn__log_operator_action('licence_changed', new.school_id,
    jsonb_build_object(
      'from', jsonb_strip_nulls(jsonb_build_object(
        'plan_code', old.plan_code, 'status', old.status::text, 'cycle', old.cycle::text,
        'trial_ends_on', old.trial_ends_on::text, 'period_end', old.period_end::text)),
      'to',   jsonb_strip_nulls(jsonb_build_object(
        'plan_code', new.plan_code, 'status', new.status::text, 'cycle', new.cycle::text,
        'trial_ends_on', new.trial_ends_on::text, 'period_end', new.period_end::text))));
  return null;
end;
$$;

create or replace function public.fn__log_school_created()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.fn__log_operator_action('school_created', new.id,
    jsonb_build_object('name', new.name, 'city', new.city,
                       'contact_name', new.contact_name,
                       'contact_phone', new.contact_phone));
  return null;
end;
$$;

revoke all on function public.fn__log_platform_invoice()      from public, anon, authenticated;
revoke all on function public.fn__log_platform_payment()      from public, anon, authenticated;
revoke all on function public.fn__log_subscription_change()   from public, anon, authenticated;
revoke all on function public.fn__log_school_created()        from public, anon, authenticated;

-- Row-level, not statement-level: unlike 0067's counter refresh these are one
-- row per human decision, and the detail IS the row. There is no bulk path.
drop trigger if exists trg_log_platform_invoice on public.platform_invoices;
create trigger trg_log_platform_invoice
  after insert on public.platform_invoices
  for each row execute function public.fn__log_platform_invoice();

drop trigger if exists trg_log_platform_payment on public.platform_payments;
create trigger trg_log_platform_payment
  after insert on public.platform_payments
  for each row execute function public.fn__log_platform_payment();

drop trigger if exists trg_log_subscription_change on public.subscriptions;
create trigger trg_log_subscription_change
  after update on public.subscriptions
  for each row execute function public.fn__log_subscription_change();

drop trigger if exists trg_log_school_created on public.schools;
create trigger trg_log_school_created
  after insert on public.schools
  for each row execute function public.fn__log_school_created();

-- ---------------------------------------------------------------------------
-- 4. Reading it back
--
-- One school's history, newest first, for the detail screen. Scoped by the
-- operator gate rather than by current_school_id(), because this describes the
-- OPERATOR's dealings with a school and a school has no business reading it.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_school_actions(
  p_school_id uuid, p_limit integer default 100
) returns table (
  at timestamptz, actor_email text, action text, detail jsonb
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
    select a.at, a.actor_email, a.action, a.detail
      from public.operator_actions a
     where a.school_id = p_school_id
     order by a.at desc
     limit greatest(1, least(coalesce(p_limit, 100), 500));
end;
$$;

-- Granted to `authenticated` because the operator's browser calls it, and
-- revoked from public and anon because Postgres hands EXECUTE to PUBLIC on every
-- new function and 0001:702 gives anon usage on this schema. 0071 closed that
-- surface for everything existing; a new function has to close its own.
-- check-definer-idor.py fails CI if this line is ever missing.
grant  execute on function public.fn_platform_school_actions(uuid, integer) to authenticated;
revoke execute on function public.fn_platform_school_actions(uuid, integer) from public, anon;

-- ---------------------------------------------------------------------------
-- 5. Backfill what the billing rows already prove
--
-- A history that starts empty makes every existing school look untouched, and
-- the console would say "no operator activity" about a school that was activated
-- and paid months ago. Invoices and payments are the two things already on
-- record, so they are replayed at their real dates.
--
-- Licence changes are NOT backfilled: nothing recorded the before-and-after, and
-- inventing one would put a fabricated row in an audit log. An absence is
-- honest; a guess is not.
-- ---------------------------------------------------------------------------
do $backfill$
declare r record; v_n integer := 0;
begin
  if exists (select 1 from public.operator_actions) then
    raise notice '0073: operator_actions already has rows — not backfilling';
    return;
  end if;

  for r in
    select 'invoice_raised' as action, i.school_id, i.created_at as at, i.created_by,
           jsonb_build_object('invoice_id', i.id, 'plan_code', i.plan_code,
             'months', i.months, 'amount', i.amount, 'list_amount', i.list_amount,
             'discount', coalesce(i.list_amount, i.amount) - i.amount,
             'note', i.note, 'backfilled', true) as detail
      from public.platform_invoices i
    union all
    select 'payment_recorded', p.school_id, p.created_at, p.created_by,
           jsonb_build_object('payment_id', p.id, 'invoice_id', p.invoice_id,
             'amount', p.amount, 'paid_on', p.paid_on::text, 'method', p.method,
             'reference', p.reference, 'backfilled', true)
      from public.platform_payments p
    order by at
  loop
    insert into public.operator_actions (at, actor, actor_email, action, school_id, detail)
    values (r.at, r.created_by,
            (select email from public.platform_admins where user_id = r.created_by),
            r.action, r.school_id, r.detail);
    v_n := v_n + 1;
  end loop;
  raise notice '0073: backfilled % action(s) from the billing rows', v_n;
end $backfill$;
