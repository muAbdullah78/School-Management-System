-- =============================================================================
-- 0066 — A school could not set a fee, and a scheduled rise double-billed
--
-- Three defects, all proven on a real database, all in the module the whole
-- product exists for.
--
-- 1. SAVING A FEE AMOUNT ALWAYS FAILED. 0035 replaced the 3-column unique key on
--    fee_structures with a 4-column one including effective_from. The app still
--    sent the old 3-column ON CONFLICT, so every save raised
--
--      ERROR:  there is no unique or exclusion constraint matching the
--              ON CONFLICT specification            (42P10)
--
--    A 100% failure rate since 0035, on Settings -> Fee Structure.
--
-- 2. NOTHING COULD CREATE A FEE HEAD. Fifteen Settings screens exist and none of
--    them manages fee_heads, so a new school had no 'Tuition' to put an amount
--    against: the Fee Structure grid showed an empty list with a Save button and
--    nothing to fill in. (The table has had a write policy all along — this was
--    a missing screen, not a missing permission.)
--
--    Together, 1 and 2 mean a fresh Pakistani school could not bill a monthly
--    fee at all. Challans printed Rs 0, Deposits stayed empty, and Year Rollover
--    dropped amounts. The dashboard's "N classes have students but no fee set"
--    warning was honest and the school had no way to act on it.
--
-- 3. A SCHEDULED FEE RISE DOUBLE-BILLED EVERY PARENT. effective_from arrived in
--    0035 and only ONE of four readers was taught about it:
--
--      fn_generate_class_invoices  correct — latest row on or before the month
--      fn_bill_student_month       NO date filter — joins EVERY dated row
--      fn_student_monthly_fee      NO date filter — SUMS every dated row
--      getFeeStructure (the grid)  NO date filter — arbitrary row wins
--
--    Proven: tuition 1500, a rise to 1800 scheduled from 2027-01-01, then bill
--    the pupil for MAY 2026:
--
--      description | amount
--      ------------+---------
--      Tuition     | 1500.00
--      Tuition     | 1800.00      <-- not in effect for another eight months
--
--    and fn_student_monthly_fee reported the monthly fee as 3300. The two
--    billing paths in the product disagreed with each other, and the wrong one
--    is the per-student path the fee counter uses.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Fee heads: a real management surface
--
-- Through functions rather than the existing table policy, because there are
-- rules worth keeping in one place: two heads called 'Tuition' make the fee grid
-- ambiguous, and a head that has already been billed must never be deleted out
-- from under an invoice line that names it.
-- ---------------------------------------------------------------------------
create or replace function public.fn_upsert_fee_head(
  p_name text,
  p_type public.fee_head_type default 'monthly',
  p_is_recurring boolean default true,
  p_is_refundable boolean default false,
  p_sort_order integer default 0,
  p_id uuid default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_name   text := nullif(btrim(coalesce(p_name, '')), '');
  v_id     uuid;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to change fee heads' using errcode = '42501';
  end if;
  if v_name is null then
    raise exception 'A fee head needs a name';
  end if;
  if p_id is not null then
    perform public.assert_own('fee_heads', p_id);
  end if;

  -- Case-insensitive, because "Tuition" and "tuition" in one grid is a support
  -- call about a duplicate row nobody can tell apart.
  if exists (select 1 from public.fee_heads
              where school_id = v_school
                and lower(btrim(name)) = lower(v_name)
                and (p_id is null or id <> p_id)) then
    raise exception 'This school already has a fee head called %', v_name;
  end if;

  -- A refundable head is money the school HOLDS and must give back (0060), so
  -- it cannot also be a recurring monthly charge — that combination would bill a
  -- deposit every month and report each one as a liability.
  if coalesce(p_is_refundable, false) and coalesce(p_is_recurring, false) then
    raise exception 'A refundable head cannot be recurring: a deposit is taken '
                    'once and given back, not charged every month';
  end if;

  if p_id is null then
    insert into public.fee_heads
      (school_id, name, type, is_recurring, is_refundable, sort_order, active)
    values (v_school, v_name, p_type, coalesce(p_is_recurring, true),
            coalesce(p_is_refundable, false), coalesce(p_sort_order, 0), true)
    returning id into v_id;
  else
    update public.fee_heads
       set name = v_name, type = p_type,
           is_recurring = coalesce(p_is_recurring, true),
           is_refundable = coalesce(p_is_refundable, false),
           sort_order = coalesce(p_sort_order, 0)
     where id = p_id and school_id = v_school
     returning id into v_id;
    if v_id is null then
      raise exception 'That fee head was not found in this school';
    end if;
  end if;

  return v_id;
end;
$$;

create or replace function public.fn_set_fee_head_active(p_id uuid, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_n integer;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to change fee heads' using errcode = '42501';
  end if;
  perform public.assert_own('fee_heads', p_id);

  update public.fee_heads set active = coalesce(p_active, true)
   where id = p_id and school_id = v_school;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'That fee head was not found in this school';
  end if;
end;
$$;

-- Deleting is deliberately NOT offered. An invoice line names its head, so
-- removing one would either break history or silently rewrite what a parent was
-- charged for. Deactivating stops it being billed and keeps every past challan
-- readable — the same choice 0053 made for staff and 0054 for pupils.
drop function if exists public.fn_fee_heads(boolean);
create function public.fn_fee_heads(p_include_inactive boolean default false)
returns table (id uuid, name text, type text, is_recurring boolean,
               is_refundable boolean, sort_order integer, active boolean,
               in_use boolean)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.may_view('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
  select h.id, h.name, h.type::text, h.is_recurring, h.is_refundable,
         h.sort_order, h.active,
         -- Whether anything already depends on it. The management screen greys
         -- out "delete" reasoning and explains why a head can only be switched
         -- off, rather than offering an action that would fail.
         exists (select 1 from public.fee_structures fs
                  where fs.fee_head_id = h.id and fs.school_id = v_school)
         or exists (select 1 from public.invoice_lines il
                     where il.fee_head_id = h.id and il.school_id = v_school)
    from public.fee_heads h
   where h.school_id = v_school
     and (coalesce(p_include_inactive, false) or h.active)
   order by h.sort_order, h.name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Setting an amount, with the dated history it was designed for
--
-- The grid means "what this class pays now". So this sets the amount effective
-- FROM TODAY and leaves earlier months alone — which is the whole point of
-- effective_from, and what makes a challan re-read for March still say March's
-- price.
--
-- The exception is a fee that has no history yet: there, the row is written at
-- the base date so it also covers a month billed retrospectively. A school
-- setting up in August and back-billing April must not find April empty.
-- ---------------------------------------------------------------------------
create or replace function public.fn_set_fee_amount(
  p_session_id uuid,
  p_class_id uuid,
  p_fee_head_id uuid,
  p_amount numeric,
  -- Explicit date for the scheduled-rise case. Null means "from today".
  p_effective_from date default null
) returns date language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_base   date := '1900-01-01';
  v_when   date;
  v_rows   integer;
  v_dated  integer;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to set fee amounts' using errcode = '42501';
  end if;
  if p_amount is null or p_amount < 0 then
    raise exception 'A fee amount cannot be negative';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);
  perform public.assert_own('fee_heads', p_fee_head_id);

  select count(*), count(*) filter (where effective_from > v_base)
    into v_rows, v_dated
    from public.fee_structures
   where school_id = v_school and session_id = p_session_id
     and class_id = p_class_id and fee_head_id = p_fee_head_id;

  v_when := coalesce(
    p_effective_from,
    -- No price on record at all, or only the base one: write the base, so the
    -- amount covers every month including one billed in arrears. Once a dated
    -- change exists, history is in play and a new amount starts today.
    case when v_dated = 0 then v_base else current_date end);

  insert into public.fee_structures
    (school_id, session_id, class_id, fee_head_id, amount, effective_from)
  values (v_school, p_session_id, p_class_id, p_fee_head_id, p_amount, v_when)
  on conflict (session_id, class_id, fee_head_id, effective_from)
    do update set amount = excluded.amount;

  return v_when;
end;
$$;

-- What the grid reads: the amount in force today, plus any change already
-- scheduled. Reading the raw table is what made the grid show an arbitrary row
-- once a school had used the increment tool.
drop function if exists public.fn_fee_structure(uuid, uuid);
create function public.fn_fee_structure(p_session_id uuid, p_class_id uuid)
returns table (fee_head_id uuid, fee_head text, is_recurring boolean,
               amount numeric, effective_from date,
               next_amount numeric, next_from date)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.may_view('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);

  return query
  select h.id, h.name, h.is_recurring,
         now_row.amount, now_row.effective_from,
         nxt.amount, nxt.effective_from
    from public.fee_heads h
    left join lateral (
      select fs.amount, fs.effective_from
        from public.fee_structures fs
       where fs.school_id = v_school and fs.session_id = p_session_id
         and fs.class_id = p_class_id and fs.fee_head_id = h.id
         and fs.effective_from <= current_date
       order by fs.effective_from desc limit 1
    ) now_row on true
    left join lateral (
      select fs.amount, fs.effective_from
        from public.fee_structures fs
       where fs.school_id = v_school and fs.session_id = p_session_id
         and fs.class_id = p_class_id and fs.fee_head_id = h.id
         and fs.effective_from > current_date
       order by fs.effective_from asc limit 1
    ) nxt on true
   where h.school_id = v_school and h.active
   order by h.sort_order, h.name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The two date-blind billers
--
-- Both now do exactly what fn_generate_class_invoices already did: take the
-- latest price on or before the month being billed. Without this, a school that
-- schedules a rise starts charging every parent the old price PLUS the new one.
-- ---------------------------------------------------------------------------
do $rewrite$
declare
  v_def text;
  -- The date-blind join, and its dated replacement. Written as a programmatic
  -- rewrite rather than a hand-copied function body so the surrounding logic —
  -- discounts, student_fee_items overrides, the invoice header — cannot drift
  -- from whatever the current migration left there.
  v_old_bill text := 'from public.fee_structures fs
  join public.fee_heads fh on fh.id = fs.fee_head_id
  left join public.student_fee_items sfi
    on sfi.enrollment_id = v_enr.id and sfi.fee_head_id = fh.id and sfi.active
  where fs.session_id = v_enr.session_id and fs.class_id = v_enr.class_id
    and fh.is_recurring and fh.active';
  v_new_bill text := 'from public.fee_heads fh
  join lateral (
    select fs.amount
      from public.fee_structures fs
     where fs.school_id = public.current_school_id()
       and fs.session_id = v_enr.session_id and fs.class_id = v_enr.class_id
       and fs.fee_head_id = fh.id
       and fs.effective_from <= coalesce(p_period_month, current_date)
     order by fs.effective_from desc limit 1
  ) fs on true
  left join public.student_fee_items sfi
    on sfi.enrollment_id = v_enr.id and sfi.fee_head_id = fh.id and sfi.active
  where fh.school_id = public.current_school_id() and fh.is_recurring and fh.active';
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_bill_student_month';

  if v_def is not null and strpos(v_def, v_old_bill) > 0 then
    execute replace(v_def, v_old_bill, v_new_bill) || ';';
    raise notice '0066: fn_bill_student_month now honours effective_from';
  end if;
end;
$rewrite$;

do $rewrite2$
declare
  v_def text;
  v_old text := 'from public.fee_structures fs
  join public.fee_heads fh on fh.id = fs.fee_head_id
  left join public.student_fee_items sfi
    on sfi.enrollment_id = v_enr.id and sfi.fee_head_id = fh.id and sfi.active
  where fs.session_id = v_enr.session_id and fs.class_id = v_enr.class_id
    and fh.is_recurring and fh.active';
  -- No date parameter here, and adding one would change the signature every
  -- caller depends on. current_date is the honest reading of "the monthly fee":
  -- what this pupil is charged now.
  v_new text := 'from public.fee_heads fh
  join lateral (
    select fs.amount
      from public.fee_structures fs
     where fs.school_id = public.current_school_id()
       and fs.session_id = v_enr.session_id and fs.class_id = v_enr.class_id
       and fs.fee_head_id = fh.id
       and fs.effective_from <= current_date
     order by fs.effective_from desc limit 1
  ) fs on true
  left join public.student_fee_items sfi
    on sfi.enrollment_id = v_enr.id and sfi.fee_head_id = fh.id and sfi.active
  where fh.school_id = public.current_school_id() and fh.is_recurring and fh.active';
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_student_monthly_fee';

  if v_def is not null and strpos(v_def, v_old) > 0 then
    execute replace(v_def, v_old, v_new) || ';';
    raise notice '0066: fn_student_monthly_fee now honours effective_from';
  end if;
end;
$rewrite2$;

-- ---------------------------------------------------------------------------
-- 4. Grants
-- ---------------------------------------------------------------------------
grant execute on function public.fn_upsert_fee_head(
  text, public.fee_head_type, boolean, boolean, integer, uuid) to authenticated;
grant execute on function public.fn_set_fee_head_active(uuid, boolean) to authenticated;
grant execute on function public.fn_fee_heads(boolean) to authenticated;
grant execute on function public.fn_set_fee_amount(uuid, uuid, uuid, numeric, date) to authenticated;
grant execute on function public.fn_fee_structure(uuid, uuid) to authenticated;
