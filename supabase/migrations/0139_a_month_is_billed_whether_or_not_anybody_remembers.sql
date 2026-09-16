-- =============================================================================
-- 0138  A month is billed whether or not anybody remembers
--
-- THE FAULT THIS FIXES IS THE ROOT OF THE FEE MODULE, and it is not a bug in
-- any one function. It is that a fee did not exist until a human pressed a
-- button, one class at a time.
--
-- fn_generate_class_invoices takes a session, ONE class, a month and a due date
-- typed by hand. Nothing anywhere recorded which classes had been done. There
-- is no scheduler in this product and no Edge Function that bills: I looked.
-- So a twelve-class school performed twelve separate acts of remembering every
-- month, and if one was missed that class simply had no fees. Not "unpaid":
-- ABSENT. No invoice, so nothing outstanding, so no defaulters, so no arrears,
-- and every total on every screen quietly agreed that the month had gone well.
--
-- That is why the question a school actually asks, "how many of my pupils have
-- paid this month", could not be answered by this software at all. The answer
-- would have been a statement about which buttons had been pressed.
--
-- WHAT REPLACES IT
--
-- A CALENDAR. public.billing_months holds one row per month of the session,
-- carrying the state of that month: scheduled, billed, or skipped. A school
-- that does not charge for the summer marks those months skipped, on purpose,
-- and the difference between "skipped" and "forgotten" is now written down
-- instead of being invisible.
--
-- A SCHOOL-WIDE BILL. fn_bill_month bills every active pupil in every class in
-- one statement each, not one class at a time, and is safe to run again: the
-- unique index on (enrollment_id, period_month) makes a repeat a no-op.
--
-- A SELF-HEALING RUN. fn_ensure_billing_current walks from the start of the
-- session to the current Karachi month and bills anything due and not yet
-- billed. The app calls it when the Fees screen opens. That is deliberate and
-- is the honest choice available here:
--
--   * pg_cron cannot be relied on. This software is installed by pasting SQL
--     into the Supabase editor; an extension a school has to enable by hand is
--     an extension some schools will not have, and billing that works for some
--     customers is worse than billing that works on a rule everybody shares.
--   * Doing it on read means a school that nobody opens for a week is billed
--     the moment somebody looks, dated to the month it belongs to rather than
--     to the day they looked. Nothing is lost by the delay because the charge
--     carries its own month.
--   * It is self-healing rather than incremental. It does not ask "what did I
--     do last time", it asks "what does this session still owe", so a gap from
--     any cause closes itself. A pupil admitted on the 20th of a month already
--     billed is picked up the next time it runs, for the same reason.
--
-- WHAT THE SCHOOL CONTROLS. school_settings gains the billing day, the due day
-- and a switch. Both days are clamped to the length of the month, so "due on
-- the 30th" is the 28th in February rather than an error or a silent skip.
--
-- WHAT IS NOT CHANGED HERE. fn_generate_class_invoices and
-- fn_bill_student_month stay exactly as they are and keep working. They are no
-- longer how a month comes to be billed, but a school that presses the old
-- button gets the old behaviour and no duplicate: the same unique index
-- protects both paths. Retiring the screen is a later, separate change, and
-- mixing it in here would mean a database whose billing depended on which of
-- two migrations had landed.
-- =============================================================================

-- ============================================ 1. what the school decides =====
alter table public.school_settings
  add column if not exists billing_day integer not null default 1;
alter table public.school_settings
  add column if not exists due_day integer not null default 10;
-- A school that genuinely wants to bill by hand can turn this off. It is not
-- there to be a shrug: with it off, the Fees screen says the month has not been
-- raised and offers one button that raises it for the whole school.
alter table public.school_settings
  add column if not exists auto_bill boolean not null default true;

do $c$
begin
  if not exists (select 1 from pg_constraint where conname = 'school_settings_billing_day_chk') then
    alter table public.school_settings
      add constraint school_settings_billing_day_chk check (billing_day between 1 and 31);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'school_settings_due_day_chk') then
    alter table public.school_settings
      add constraint school_settings_due_day_chk check (due_day between 1 and 31);
  end if;
end
$c$;

comment on column public.school_settings.billing_day is
  'Day of the month the fee is raised for every pupil. Clamped to the length of the month.';
comment on column public.school_settings.due_day is
  'Day of the month the fee falls due. Clamped to the length of the month. May be earlier than billing_day, which means due in the following month.';

-- ============================================== 2. the calendar of months ====
-- ONE ROW PER MONTH OF THE SESSION. The value of the table is not the billing;
-- it is that "we do not charge in July" and "nobody billed July" stop looking
-- identical to every screen in this product.
create table if not exists public.billing_months (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  session_id    uuid not null references public.academic_sessions(id) on delete cascade,
  -- Always the first of the month. period_month is a LABEL for a month, the
  -- same convention invoices.period_month already uses.
  period_month  date not null,
  state         text not null default 'scheduled',
  due_date      date,
  billed_at     timestamptz,
  billed_by     uuid references public.profiles(id),
  pupils_billed integer not null default 0,
  note          text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint billing_months_once unique (session_id, period_month),
  constraint billing_months_state_chk check (state in ('scheduled', 'billed', 'skipped')),
  constraint billing_months_first_of_month_chk
    check (period_month = date_trunc('month', period_month)::date)
);

create index if not exists billing_months_school
  on public.billing_months (school_id, session_id, period_month);

drop trigger if exists trg_billing_months_updated on public.billing_months;
create trigger trg_billing_months_updated before update on public.billing_months
  for each row execute function public.set_updated_at();

alter table public.billing_months enable row level security;

-- Readable by anyone who may see fee records, including an observer: knowing
-- which months have been charged is reading, not writing.
drop policy if exists billing_months_select on public.billing_months;
create policy billing_months_select on public.billing_months for select
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'readonly'));

-- No write policy at all. Rows arrive only through the SECURITY DEFINER
-- functions below, which is the same rule schema_migrations follows and for the
-- same reason: a record of what was charged that a signed-in user can edit
-- directly is a record that proves nothing.

-- ================================================ 4. billing one month ======
-- SET-BASED, and that is not premature optimisation. The obvious shape, a loop
-- calling fn_bill_student_month per pupil, calls student_balance once each to
-- snapshot arrears, and student_balance is four subqueries over the whole
-- ledger: measured at 3.7 seconds for 1046 pupils on the defaulters screen,
-- which is the same mistake. Four statements do the whole school instead.
create or replace function public.fn_bill_month(
  p_session_id uuid,
  p_period_month date,
  p_due_date date default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor   uuid := auth.uid();
  v_school  uuid := public.current_school_id();
  v_month   date := date_trunc('month', p_period_month)::date;
  v_due     date;
  v_billed  integer := 0;
  v_nofee   integer := 0;
  v_names   text;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Not permitted to raise fees' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.fn__assert_date_in_session(p_session_id, v_month,
            'Raising the fee for a month', true);

  v_due := coalesce(
    p_due_date,
    public.fn__day_in_month(v_month,
      (select due_day from public.school_settings where school_id = v_school)));

  -- 1. THE INVOICES. `on conflict do nothing` against the partial unique index
  -- is what makes this safe to run again, and it is the whole reason the
  -- self-healing pass below can be called on every page load without counting
  -- anything twice.
  --
  -- Arrears are snapshotted from a single aggregate over the ledger rather than
  -- a per-pupil function call. The figure is what the child owed BEFORE this
  -- month's charge, which is what a challan prints.
  with roll as (
    select e.id as enrollment_id, e.student_id, e.class_id
      from public.enrollments e
      join public.students s
        on s.id = e.student_id
       and s.school_id = v_school
       and s.status = 'active'
       and s.deleted_at is null
     where e.session_id = p_session_id
       and e.status = 'active'
       -- NOT BEFORE THE CHILD WAS ADMITTED, and this was found by the test
       -- rather than by reading. Without it the self-healing pass bills a
       -- pupil admitted in September for May, June, July and August as well,
       -- because it walks every month of the session and every active
       -- enrolment is active in all of them. The parent's first challan would
       -- have been five months of fees for a child who had been there a week.
       --
       -- The bound is the LATER of the session start and the admission month,
       -- which is what coalesce plus the comparison gives: a pupil admitted in
       -- 2024 and enrolled in this year's session is billed from the session
       -- start, not from 2024, because months before the session start are
       -- never walked at all.
       --
       -- A pupil who joins mid-month is charged the whole month. That is the
       -- ordinary arrangement in these schools and it is the school's to waive
       -- on the child's ledger if they disagree; guessing a pro-rata rule here
       -- would be inventing a policy nobody asked for.
       and date_trunc('month', coalesce(s.admission_date, v_month))::date <= v_month
       and not exists (
             select 1 from public.invoices i
              where i.enrollment_id = e.id
                and i.period_month = v_month
                and i.status <> 'void')
  ),
  charged as (
    select i.student_id,
           sum(coalesce(l.net, 0)) + sum(coalesce(i.fine, 0)) as charge
      from public.invoices i
      left join lateral (
             select sum(case when l.is_discount then -l.amount else l.amount end) as net
               from public.invoice_lines l where l.invoice_id = i.id) l on true
     where i.school_id = v_school and i.status <> 'void'
       and i.student_id in (select student_id from roll)
     group by i.student_id
  ),
  paid as (
    select i.student_id, sum(al.amount) as allocated
      from public.payment_allocations al
      join public.invoices i on i.id = al.invoice_id
      join public.payments p on p.id = al.payment_id
     where p.status = 'verified' and i.school_id = v_school
       and i.student_id in (select student_id from roll)
     group by i.student_id
  ),
  adj as (
    select a.student_id, sum(a.amount) as amount
      from public.adjustments a
     where a.student_id in (select student_id from roll)
     group by a.student_id
  )
  insert into public.invoices(
    student_id, enrollment_id, session_id, period_month, status,
    arrears_brought_forward, due_date, issued_at, created_by)
  select r.student_id, r.enrollment_id, p_session_id, v_month, 'issued',
         coalesce(c.charge, 0) + coalesce(j.amount, 0) - coalesce(pd.allocated, 0),
         v_due, now(), v_actor
    from roll r
    left join charged c on c.student_id = r.student_id
    left join paid    pd on pd.student_id = r.student_id
    left join adj     j  on j.student_id = r.student_id
  on conflict do nothing;

  get diagnostics v_billed = row_count;

  -- 2. THE LINES. Every recurring fee head, at the amount in force FOR THE
  -- MONTH BEING BILLED rather than for today, with a per-pupil override
  -- winning over the class amount. Both rules are 0066's and are kept.
  insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
  select i.id, fh.id, fh.name, coalesce(sfi.amount, amt.amount), false
    from public.invoices i
    join public.enrollments e on e.id = i.enrollment_id
    join public.fee_heads fh
      on fh.school_id = v_school and fh.is_recurring and fh.active
    join lateral (
           select fs.amount
             from public.fee_structures fs
            where fs.school_id = v_school
              and fs.session_id = p_session_id
              and fs.class_id = e.class_id
              and fs.fee_head_id = fh.id
              and fs.effective_from <= v_month
            order by fs.effective_from desc
            limit 1) amt on true
    left join public.student_fee_items sfi
      on sfi.student_id = i.student_id and sfi.fee_head_id = fh.id and sfi.active
   where i.school_id = v_school
     and i.session_id = p_session_id
     and i.period_month = v_month
     and i.status <> 'void'
     and not exists (select 1 from public.invoice_lines l
                      where l.invoice_id = i.id and not l.is_discount);

  -- 3. THE DISCOUNTS. Applied in the order they were granted and capped at the
  -- charge, which is fn__apply_discount_lines' rule, expressed as one statement
  -- rather than a loop per pupil. The running total is over the discounts
  -- BEFORE this one, so the cap is the room left rather than the whole charge.
  --
  -- Keyed on the CHILD and bounded by the months the discount covers, which is
  -- 0138's model. Keyed on the enrolment, as it was, every concession in the
  -- school would evaporate at rollover and this function would cheerfully bill
  -- the full fee to every family that had one.
  insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
  select d.invoice_id, null, 'Discount: ' || d.type,
         least(d.amt, greatest(d.gross - d.used_before, 0)), true
    from (
      select i.id as invoice_id,
             dc.type,
             g.gross,
             case when dc.is_percent then round(g.gross * dc.amount / 100.0, 2)
                  else dc.amount end as amt,
             coalesce(sum(case when dc.is_percent
                               then round(g.gross * dc.amount / 100.0, 2)
                               else dc.amount end)
                      over (partition by i.id order by dc.created_at, dc.id
                            rows between unbounded preceding and 1 preceding), 0) as used_before
        from public.invoices i
        join public.discounts dc
          on dc.student_id = i.student_id
         and dc.school_id = v_school
         and dc.status = 'approved'
         and dc.starts_on <= v_month
         and (dc.ends_on is null or dc.ends_on >= v_month)
        join lateral (
               select coalesce(sum(l.amount), 0) as gross
                 from public.invoice_lines l
                where l.invoice_id = i.id and not l.is_discount) g on true
       where i.school_id = v_school
         and i.session_id = p_session_id
         and i.period_month = v_month
         and i.status <> 'void'
         and not exists (select 1 from public.invoice_lines l
                          where l.invoice_id = i.id and l.is_discount)
    ) d
   where least(d.amt, greatest(d.gross - d.used_before, 0)) > 0;

  -- 4. A CLASS WITH NO FEE SET IS NAMED, NOT SILENTLY BILLED ZERO. This is the
  -- failure a school meets on its first month: the structure was filled in for
  -- five classes out of twelve and the other seven were charged nothing, which
  -- looks exactly like everybody having paid.
  select count(distinct c.id), string_agg(distinct c.name, ', ' order by c.name)
    into v_nofee, v_names
    from public.enrollments e
    join public.classes c on c.id = e.class_id
    join public.students s on s.id = e.student_id
                          and s.status = 'active' and s.deleted_at is null
   where e.session_id = p_session_id and e.status = 'active'
     and e.school_id = v_school
     and not exists (
           select 1 from public.fee_structures fs
            join public.fee_heads fh on fh.id = fs.fee_head_id
                                    and fh.is_recurring and fh.active
            where fs.session_id = p_session_id
              and fs.class_id = e.class_id
              and fs.effective_from <= v_month);

  insert into public.billing_months(school_id, session_id, period_month, state,
                                    due_date, billed_at, billed_by, pupils_billed)
  values (v_school, p_session_id, v_month, 'billed', v_due, now(), v_actor, v_billed)
  on conflict (session_id, period_month) do update
    set state = 'billed',
        due_date = excluded.due_date,
        billed_at = now(),
        billed_by = v_actor,
        pupils_billed = public.billing_months.pupils_billed + excluded.pupils_billed;

  return jsonb_build_object(
    'period_month', v_month,
    'due_date', v_due,
    'billed', v_billed,
    'classes_with_no_fee', v_nofee,
    'classes_with_no_fee_names', v_names);
end;
$$;
revoke all on function public.fn_bill_month(uuid, date, date) from public, anon;
grant execute on function public.fn_bill_month(uuid, date, date) to authenticated;

-- ============================================= 5. the self-healing pass ======
-- CALLED WHEN THE FEES SCREEN OPENS, and safe to call as often as that. It does
-- not remember what it did last time: it asks what the session still owes and
-- does that, so a gap left by any cause closes itself.
--
-- The current month is re-run even when already billed, which is the only thing
-- that picks up a pupil admitted on the 20th of a month billed on the 1st.
-- That re-run is cheap when there is nothing to do: the `not exists` in
-- fn_bill_month's first CTE rides the unique index on
-- (enrollment_id, period_month) and returns no rows.
--
-- IT RETURNS QUIETLY FOR SOMEBODY WHO MAY NOT BILL. An observer opening the
-- Fees screen must not meet a permission error from a background action they
-- did not ask for, and must not silently become a biller either.
create or replace function public.fn_ensure_billing_current(p_session_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school   uuid := public.current_school_id();
  v_today    date := (now() at time zone 'Asia/Karachi')::date;
  v_thismon  date := public.fn__karachi_month();
  v_settings record;
  v_ses      record;
  v_month    date;
  v_res      jsonb;
  v_done     jsonb := '[]'::jsonb;
  v_total    integer := 0;
begin
  if not public.has_role('owner', 'principal') then
    return jsonb_build_object('billed', 0, 'months', '[]'::jsonb, 'skipped_reason', 'not a biller');
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  select coalesce(billing_day, 1) as billing_day,
         coalesce(due_day, 10)    as due_day,
         coalesce(auto_bill, true) as auto_bill
    into v_settings
    from public.school_settings where school_id = v_school;
  if not found then
    return jsonb_build_object('billed', 0, 'months', '[]'::jsonb, 'skipped_reason', 'no settings');
  end if;
  if not v_settings.auto_bill then
    return jsonb_build_object('billed', 0, 'months', '[]'::jsonb, 'skipped_reason', 'auto billing is off');
  end if;

  select starts_on, ends_on, is_closed into v_ses
    from public.academic_sessions where id = p_session_id;
  if not found or v_ses.starts_on is null then
    return jsonb_build_object('billed', 0, 'months', '[]'::jsonb, 'skipped_reason', 'session has no dates');
  end if;
  -- A closed year is history. Billing into it would change a figure somebody
  -- has already reported.
  if coalesce(v_ses.is_closed, false) then
    return jsonb_build_object('billed', 0, 'months', '[]'::jsonb, 'skipped_reason', 'session is closed');
  end if;

  v_month := date_trunc('month', v_ses.starts_on)::date;
  while v_month <= least(v_thismon, date_trunc('month', coalesce(v_ses.ends_on, v_thismon))::date)
  loop
    -- Not yet due: the billing day for this month has not arrived. Only ever
    -- true of the current month, which is the point. A school that bills on the
    -- 5th does not show its parents a September charge on the 2nd.
    if public.fn__day_in_month(v_month, v_settings.billing_day) > v_today then
      exit;
    end if;

    -- THE CHEAP QUESTION FIRST, and it is the difference between this being
    -- callable on every page load and not. Measured before it existed: the
    -- pass cost 0.64s on a 600 pupil school with nothing whatever to do,
    -- because it called fn_bill_month for every month of the year and each
    -- call ran four statements and a scan for classes with no fee set.
    --
    -- Now a month is only opened if some active pupil is actually missing a
    -- challan for it. That EXISTS rides uq_invoice_enroll_month and stops at
    -- the first row.
    if not exists (select 1 from public.billing_months b
                    where b.session_id = p_session_id
                      and b.period_month = v_month
                      and b.state = 'skipped')
       and exists (
             select 1
               from public.enrollments e
               join public.students s
                 on s.id = e.student_id
                and s.school_id = v_school
                and s.status = 'active'
                and s.deleted_at is null
              where e.session_id = p_session_id
                and e.status = 'active'
                and date_trunc('month', coalesce(s.admission_date, v_month))::date <= v_month
                and not exists (
                      select 1 from public.invoices i
                       where i.enrollment_id = e.id
                         and i.period_month = v_month
                         and i.status <> 'void'))
    then
      v_res := public.fn_bill_month(p_session_id, v_month,
                 public.fn__day_in_month(v_month, v_settings.due_day));
      if (v_res->>'billed')::integer > 0 then
        v_total := v_total + (v_res->>'billed')::integer;
        v_done := v_done || jsonb_build_array(v_res);
      end if;
    end if;

    v_month := (v_month + interval '1 month')::date;
  end loop;

  return jsonb_build_object('billed', v_total, 'months', v_done);
end;
$$;
revoke all on function public.fn_ensure_billing_current(uuid) from public, anon;
grant execute on function public.fn_ensure_billing_current(uuid) to authenticated;

-- ================================================== 6. reading the calendar ==
create or replace function public.fn_billing_calendar(p_session_id uuid)
returns table(
  period_month date, state text, due_date date, billed_at timestamptz,
  pupils_billed integer, note text, invoices integer, unpaid integer
) language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_ses    record;
begin
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted to view fee records' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  select starts_on, ends_on into v_ses
    from public.academic_sessions where id = p_session_id;

  return query
  with months as (
    select generate_series(
             date_trunc('month', coalesce(v_ses.starts_on, public.fn__karachi_month())),
             date_trunc('month', coalesce(v_ses.ends_on, public.fn__karachi_month())),
             interval '1 month')::date as m
  ),
  counts as (
    select i.period_month as m,
           count(*)::integer as n,
           count(*) filter (
             where coalesce((select sum(case when l.is_discount then -l.amount else l.amount end)
                               from public.invoice_lines l where l.invoice_id = i.id), 0)
                   + i.fine
                   - coalesce((select sum(al.amount) from public.payment_allocations al
                                 join public.payments p on p.id = al.payment_id
                                where al.invoice_id = i.id and p.status = 'verified'), 0) > 0
           )::integer as unpaid
      from public.invoices i
     where i.school_id = v_school and i.session_id = p_session_id and i.status <> 'void'
       and i.period_month is not null
     group by i.period_month
  )
  select mo.m,
         coalesce(b.state, 'scheduled'),
         b.due_date, b.billed_at, coalesce(b.pupils_billed, 0), b.note,
         coalesce(c.n, 0), coalesce(c.unpaid, 0)
    from months mo
    left join public.billing_months b
      on b.session_id = p_session_id and b.period_month = mo.m
    left join counts c on c.m = mo.m
   order by mo.m;
end;
$$;
revoke all on function public.fn_billing_calendar(uuid) from public, anon;
grant execute on function public.fn_billing_calendar(uuid) to authenticated;

-- ============================================== 7. skipping a month ==========
-- A SCHOOL THAT DOES NOT CHARGE IN JULY SAYS SO, ONCE. Marking a month skipped
-- is the difference between a decision and an oversight, and it is the only way
-- the self-healing pass can be trusted not to bill a month the school meant to
-- leave alone.
--
-- Skipping a month that has ALREADY been billed does not delete the charges:
-- money already asked for is not unasked by a settings change. It refuses, and
-- names the screen that voids a charge, because a silent reversal of forty
-- invoices is the worst thing this function could do.
create or replace function public.fn_set_month_state(
  p_session_id uuid,
  p_period_month date,
  p_state text,
  p_due_date date default null,
  p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_month  date := date_trunc('month', p_period_month)::date;
  v_have   integer;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Not permitted to change the billing calendar' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  if p_state not in ('scheduled', 'skipped') then
    raise exception 'A month can be set to scheduled or skipped. Billing it is what '
      'raises the fees.' using errcode = '22023';
  end if;

  perform public.fn__assert_date_in_session(p_session_id, v_month,
            'Changing the billing calendar', true);
  if p_due_date is not null then
    perform public.fn__assert_date_in_calendar(p_due_date, 'The day a month''s fee falls due');
  end if;

  select count(*) into v_have from public.invoices i
   where i.school_id = v_school and i.session_id = p_session_id
     and i.period_month = v_month and i.status <> 'void';

  if p_state = 'skipped' and v_have > 0 then
    raise exception '% has already been charged to % pupil(s). Skipping it here '
      'would not take those charges back. Void them first if that is what you '
      'mean.', to_char(v_month, 'Mon YYYY'), v_have using errcode = '22023';
  end if;

  insert into public.billing_months(school_id, session_id, period_month, state, due_date, note)
  values (v_school, p_session_id, v_month, p_state, p_due_date, nullif(btrim(p_note), ''))
  on conflict (session_id, period_month) do update
    set state = excluded.state,
        due_date = coalesce(excluded.due_date, public.billing_months.due_date),
        note = coalesce(excluded.note, public.billing_months.note);

  return jsonb_build_object('period_month', v_month, 'state', p_state);
end;
$$;
revoke all on function public.fn_set_month_state(uuid, date, text, date, text) from public, anon;
grant execute on function public.fn_set_month_state(uuid, date, text, date, text) to authenticated;

-- ============================================ 8. the billing settings ========
create or replace function public.fn_set_billing_days(
  p_billing_day integer, p_due_day integer, p_auto_bill boolean
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Not permitted to change fee settings' using errcode = '42501';
  end if;
  if p_billing_day is null or p_billing_day < 1 or p_billing_day > 31
     or p_due_day is null or p_due_day < 1 or p_due_day > 31 then
    raise exception 'The billing day and the due day are days of the month, 1 to 31.'
      using errcode = '22023';
  end if;
  update public.school_settings
     set billing_day = p_billing_day, due_day = p_due_day,
         auto_bill = coalesce(p_auto_bill, true)
   where school_id = v_school;
  return jsonb_build_object('billing_day', p_billing_day, 'due_day', p_due_day,
                            'auto_bill', coalesce(p_auto_bill, true));
end;
$$;
revoke all on function public.fn_set_billing_days(integer, integer, boolean) from public, anon;
grant execute on function public.fn_set_billing_days(integer, integer, boolean) to authenticated;
