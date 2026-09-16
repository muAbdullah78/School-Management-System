-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0138_a_discount_belongs_to_the_child.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0139  A discount belongs to the child, not to one year's enrolment
--
-- THIS REVERSES A DECISION THIS PROJECT MADE ON PURPOSE, so it says why.
-- fn_report_discounts carries the original reasoning in its own body:
--
--     "discounts key on ENROLMENT, not student, so the join goes through
--      enrollments. That also means a discount is scoped to one session,
--      which is correct: last year's hardship waiver should not silently
--      continue."
--
-- The argument is a good one and the implementation did not honour it. Scoping
-- a discount to a session would be a decision if the school were asked again at
-- rollover. Nothing asks. fn_rollover inserts into exactly one table,
-- enrollments, and the only function in this schema that has ever written to
-- discounts is fn_add_discount. So on the first day of a new session every
-- approved sibling, staff-child, hardship and scholarship discount stops
-- existing, every one of those families is charged the full fee, and not one
-- screen, notice or report mentions it. That is not "the waiver did not
-- continue". That is the school silently raising the fee on its poorest
-- parents, and finding out when they come to the office.
--
-- The vendor was asked and chose: the discount belongs to the child and lasts
-- until somebody ends it, with the school free to change its terms whenever it
-- likes. So:
--
--   * discounts key on student_id, and carry starts_on and ends_on. A waiver
--     that really is for one year gets an end date, which makes ending it a
--     decision written down at the time rather than an accident in April.
--   * they can be EDITED. The amount, the kind, the reason and the end date all
--     change in place, because a school that raises a concession from 10 to 20
--     per cent should not have to revoke one discount and create another.
--   * changing one REPRICES the challans it should have been on. This is the
--     second half of the same fault: discount lines were written only inside
--     invoice generation, so a discount approved on the 5th did nothing at all
--     to the challan raised on the 1st, for ever, in silence.
--
-- WHAT REPRICING WILL NOT DO. It only touches a challan NOTHING HAS BEEN PAID
-- AGAINST. Once a rupee has been taken for a month, changing what that month
-- charges is a refund, and a refund is a decision with a person's name on it,
-- not something a settings change does to forty families at once. The function
-- returns how many it repriced and how many it left alone for that reason, so
-- the office is told rather than left to notice.
--
-- SIBLING DISCOUNTS STAY HAND-TYPED. The vendor was asked whether the software
-- should compute them from the number of children enrolled and said no: in
-- these schools the head decides each case, and two brothers can be on
-- different rates for reasons that are not in any database. What is fixed here
-- is the dishonesty around it, not the flexibility: the screen used to print
-- "Sibling 10% - 2 siblings" where the sibling count was counted in the browser
-- and had nothing to do with the discount. A number the software displays next
-- to a discount must be a number the discount is based on.
--
-- student_fee_items, the per-child fee override, is moved for exactly the same
-- reason and was losing exactly the same way.
-- =============================================================================

-- ================================================= 1. the columns ============
alter table public.discounts
  add column if not exists student_id uuid references public.students(id) on delete cascade;
alter table public.discounts
  add column if not exists starts_on date;
alter table public.discounts
  add column if not exists ends_on date;

update public.discounts d
   set student_id = e.student_id
  from public.enrollments e
 where e.id = d.enrollment_id and d.student_id is null;

-- A discount with no child cannot exist: enrollment_id was NOT NULL with a
-- foreign key, so every row has one. If that is somehow untrue on a real
-- database, stopping here is right: the alternative is a discount the new code
-- cannot see, which is the very fault this migration exists to end.
do $assert$
declare v_n integer;
begin
  select count(*) into v_n from public.discounts where student_id is null;
  if v_n > 0 then
    raise exception '0139: % discount(s) could not be matched to a child. Their '
      'enrolment rows are missing. Run supabase/repair/detect.sql before this.', v_n;
  end if;
end
$assert$;

alter table public.discounts alter column student_id set not null;
-- Kept and populated, because five frozen bundles write and read it, but it is
-- no longer what a discount is attached to. After a rollover it names the
-- enrolment the discount was FIRST granted under, which is a fact worth having.
alter table public.discounts alter column enrollment_id drop not null;

-- Backfilled so an existing discount starts at the beginning of the year it was
-- granted in rather than on the day the school happened to type it. A discount
-- entered in November for a child who has had it since April should not suddenly
-- claim to have begun in November.
update public.discounts d
   set starts_on = coalesce(
         d.starts_on,
         greatest(date_trunc('month', s.starts_on)::date,
                  date_trunc('month', d.created_at at time zone 'Asia/Karachi')::date))
  from public.enrollments e
  join public.academic_sessions s on s.id = e.session_id
 where e.id = d.enrollment_id and d.starts_on is null;

update public.discounts
   set starts_on = date_trunc('month', created_at at time zone 'Asia/Karachi')::date
 where starts_on is null;

alter table public.discounts alter column starts_on set not null;

do $c$
begin
  if not exists (select 1 from pg_constraint where conname = 'discounts_window_chk') then
    alter table public.discounts
      add constraint discounts_window_chk check (ends_on is null or ends_on >= starts_on);
  end if;
end
$c$;

create index if not exists discounts_student
  on public.discounts (school_id, student_id, status);

comment on column public.discounts.student_id is
  'The child the discount belongs to. It survives rollover; 0139 explains why it had to.';
comment on column public.discounts.starts_on is
  'First month the discount applies to. A month label, so the first of that month.';
comment on column public.discounts.ends_on is
  'Last month it applies to, or null for until somebody ends it.';

-- The same move for the per-child fee override, which was being lost the same
-- way and is the other half of what a school sets up for one family.
alter table public.student_fee_items
  add column if not exists student_id uuid references public.students(id) on delete cascade;

update public.student_fee_items sfi
   set student_id = e.student_id
  from public.enrollments e
 where e.id = sfi.enrollment_id and sfi.student_id is null;

do $assert2$
declare v_n integer;
begin
  select count(*) into v_n from public.student_fee_items where student_id is null;
  if v_n > 0 then
    raise exception '0139: % per-child fee override(s) could not be matched to a child.', v_n;
  end if;
end
$assert2$;

alter table public.student_fee_items alter column student_id set not null;
alter table public.student_fee_items alter column enrollment_id drop not null;
create index if not exists student_fee_items_student
  on public.student_fee_items (school_id, student_id, fee_head_id) where active;

-- =================================================== 3. the two helpers ======
-- A day clamped into a month. "Due on the 30th" in February is the 28th, and in
-- a leap year the 29th. Written once because getting it wrong in two places is
-- how a school ends up with a due date that silently does not exist.
create or replace function public.fn__day_in_month(p_month date, p_day integer)
returns date language sql immutable set search_path = public as $$
  select (date_trunc('month', p_month)
          + (least(
               greatest(coalesce(p_day, 1), 1),
               extract(day from (date_trunc('month', p_month)
                                 + interval '1 month - 1 day'))::integer
             ) - 1) * interval '1 day')::date
$$;
revoke all on function public.fn__day_in_month(date, integer) from public, anon, authenticated;

-- The month a Pakistani school is in right now. Every date bound in this file
-- goes through Karachi, for the reason 0107 exists: the server is on UTC and a
-- fee taken at 2am in Lahore belongs to that day, not the one before.
create or replace function public.fn__karachi_month()
returns date language sql stable set search_path = public as $$
  select date_trunc('month', (now() at time zone 'Asia/Karachi')::date)::date
$$;
revoke all on function public.fn__karachi_month() from public, anon, authenticated;

-- ============================================ 2. which discounts are live ====
-- ONE ANSWER TO "what does this child get off in this month", used by billing,
-- by repricing and by every screen. Three places computed it separately before
-- and they did not agree: fn_student_monthly_fee summed every approved discount
-- with no cap check until the end, fn__apply_discount_lines capped as it went,
-- and the browser showed a sibling count from somewhere else entirely.
create or replace function public.fn__discounts_live(p_student_id uuid, p_month date)
returns table(id uuid, type public.discount_type, amount numeric, is_percent boolean,
              reason text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select d.id, d.type, d.amount, d.is_percent, d.reason, d.created_at
    from public.discounts d
   where d.student_id = p_student_id
     and d.school_id = public.current_school_id()
     and d.status = 'approved'
     and d.starts_on <= date_trunc('month', p_month)::date
     and (d.ends_on is null or d.ends_on >= date_trunc('month', p_month)::date)
   order by d.created_at, d.id
$$;
revoke all on function public.fn__discounts_live(uuid, date) from public, anon, authenticated;

-- What a month costs this child, gross, discount and net, computed the same way
-- the challan is. Replaces fn_student_monthly_fee's separate arithmetic.
create or replace function public.fn_student_fee_for_month(p_student_id uuid, p_month date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_month  date := date_trunc('month', coalesce(p_month, public.fn__karachi_month()))::date;
  v_enr    record;
  v_gross  numeric := 0;
  v_disc   numeric := 0;
  v_room   numeric;
  v_rec    record;
  v_amt    numeric;
  v_lines  jsonb := '[]'::jsonb;
begin
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted to view fee records' using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);

  -- THE ENROLMENT THAT COVERS THE MONTH ASKED ABOUT, not the current one. The
  -- first draft ordered by is_current and answered every question with this
  -- year's class and this year's fee, so asking what next September costs
  -- returned this September's answer. The test caught it: a 25 per cent waiver
  -- came back as Rs 1,000 of a Rs 4,000 fee when next year's fee is Rs 4,500.
  select e.id, e.session_id, e.class_id into v_enr
    from public.enrollments e
    join public.academic_sessions s on s.id = e.session_id
   where e.student_id = p_student_id and e.status = 'active'
     and date_trunc('month', s.starts_on)::date <= v_month
     and date_trunc('month', s.ends_on)::date   >= v_month
   order by s.starts_on desc
   limit 1;
  -- Asked about a month in no session at all (before the child joined, or after
  -- the last year on record), fall back to the nearest year so the screen shows
  -- a number rather than a blank.
  if not found then
    select e.id, e.session_id, e.class_id into v_enr
      from public.enrollments e
      join public.academic_sessions s on s.id = e.session_id
     where e.student_id = p_student_id and e.status = 'active'
     order by abs(extract(epoch from (s.starts_on - v_month))), s.starts_on desc
     limit 1;
  end if;
  if not found then
    return jsonb_build_object('gross', 0, 'discount', 0, 'net', 0, 'lines', '[]'::jsonb);
  end if;

  select coalesce(sum(coalesce(sfi.amount, amt.amount)), 0) into v_gross
    from public.fee_heads fh
    join lateral (
           select fs.amount from public.fee_structures fs
            where fs.school_id = v_school and fs.session_id = v_enr.session_id
              and fs.class_id = v_enr.class_id and fs.fee_head_id = fh.id
              and fs.effective_from <= v_month
            order by fs.effective_from desc limit 1) amt on true
    left join public.student_fee_items sfi
      on sfi.student_id = p_student_id and sfi.fee_head_id = fh.id and sfi.active
   where fh.school_id = v_school and fh.is_recurring and fh.active;

  v_room := v_gross;
  for v_rec in select * from public.fn__discounts_live(p_student_id, v_month) loop
    exit when v_room <= 0;
    v_amt := case when v_rec.is_percent then round(v_gross * v_rec.amount / 100.0, 2)
                  else v_rec.amount end;
    v_amt := least(v_amt, v_room);
    if v_amt > 0 then
      v_disc := v_disc + v_amt;
      v_room := v_room - v_amt;
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'discount_id', v_rec.id, 'type', v_rec.type, 'amount', v_amt,
        'is_percent', v_rec.is_percent, 'rate', v_rec.amount, 'reason', v_rec.reason));
    end if;
  end loop;

  return jsonb_build_object('month', v_month, 'gross', v_gross,
                            'discount', v_disc, 'net', v_gross - v_disc, 'lines', v_lines);
end;
$$;
revoke all on function public.fn_student_fee_for_month(uuid, date) from public, anon;
grant execute on function public.fn_student_fee_for_month(uuid, date) to authenticated;

-- ==================================================== 3. repricing ===========
-- THE OTHER HALF OF THE FAULT. Discount lines were only ever written inside
-- invoice generation, so a discount approved on the 5th did nothing to the
-- challan raised on the 1st and nothing said so.
--
-- ONLY A CHALLAN NOTHING HAS BEEN PAID AGAINST. Once a rupee has been taken for
-- a month, changing what that month charges is a refund, and a refund has a
-- person's name on it. The count of what was left alone comes back so the
-- office is told rather than left to notice.
create or replace function public.fn_reprice_student(
  p_student_id uuid, p_from_month date default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_from    date := date_trunc('month', coalesce(p_from_month, public.fn__karachi_month()))::date;
  v_inv     record;
  v_gross   numeric;
  v_room    numeric;
  v_rec     record;
  v_amt     numeric;
  v_done    integer := 0;
  v_held    integer := 0;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Not permitted to change fees' using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);
  -- Bounded for the same reason fn_add_discount is: this takes a month from the
  -- caller and rewrites charges from it onwards. 0130's guard found it.
  perform public.fn__assert_date_in_calendar(v_from, 'The month to reprice from');

  for v_inv in
    select i.id, i.period_month,
           coalesce((select sum(al.amount) from public.payment_allocations al
                       join public.payments p on p.id = al.payment_id
                      where al.invoice_id = i.id and p.status = 'verified'), 0) as allocated
      from public.invoices i
     where i.school_id = v_school
       and i.student_id = p_student_id
       and i.status <> 'void'
       and i.period_month is not null
       and i.period_month >= v_from
     order by i.period_month
  loop
    if v_inv.allocated <> 0 then
      v_held := v_held + 1;
      continue;
    end if;

    delete from public.invoice_lines where invoice_id = v_inv.id and is_discount;

    select coalesce(sum(amount), 0) into v_gross
      from public.invoice_lines where invoice_id = v_inv.id and not is_discount;

    v_room := v_gross;
    for v_rec in select * from public.fn__discounts_live(p_student_id, v_inv.period_month) loop
      exit when v_room <= 0;
      v_amt := case when v_rec.is_percent then round(v_gross * v_rec.amount / 100.0, 2)
                    else v_rec.amount end;
      v_amt := least(v_amt, v_room);
      if v_amt > 0 then
        insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
        values (v_inv.id, null, 'Discount: ' || v_rec.type, v_amt, true);
        v_room := v_room - v_amt;
      end if;
    end loop;

    -- The status is a label over the money and has to follow it: a challan that
    -- a discount has just cleared in full is paid, not issued.
    update public.invoices i
       set status = (case
             when (select b.allocated from public.invoice_balances b where b.invoice_id = i.id)
                  >= (select b.charge from public.invoice_balances b where b.invoice_id = i.id)
             then 'paid'
             when (select b.allocated from public.invoice_balances b where b.invoice_id = i.id) > 0
             then 'partial'
             else 'issued' end)::public.invoice_status
     where i.id = v_inv.id;

    v_done := v_done + 1;
  end loop;

  return jsonb_build_object('repriced', v_done, 'left_alone_because_paid', v_held,
                            'from_month', v_from);
end;
$$;
revoke all on function public.fn_reprice_student(uuid, date) from public, anon;
grant execute on function public.fn_reprice_student(uuid, date) to authenticated;

-- ============================== 4. granting, editing and ending a discount ===
-- EVERY OVERLOAD DROPPED FIRST. 0017 created fn_add_discount taking an
-- enrolment, and 0017 is frozen inside a bundle that a school re-pastes. Naming
-- only the new signature would leave the old one standing beside it as a live
-- overload, and a call that matched both would be ambiguous. The bundles are
-- pasted in ascending order so this file runs last and is the one that stands.
do $drop$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       -- fn_set_discount_status is here because it returns jsonb now and used to
       -- return void, and `create or replace` refuses to change a return type.
       -- Approving a discount is what makes it real, so it has to be able to
       -- report what it repriced.
       and p.proname in ('fn_add_discount', 'fn_student_monthly_fee',
                         'fn_set_discount_status')
  loop
    execute format('drop function if exists %s', r.sig);
  end loop;
end
$drop$;

create or replace function public.fn_add_discount(
  p_student_id uuid,
  p_type       public.discount_type,
  p_amount     numeric,
  p_is_percent boolean default false,
  p_reason     text default null,
  p_starts_on  date default null,
  p_ends_on    date default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id     uuid;
  v_school uuid := public.current_school_id();
  v_enr    uuid;
  v_start  date := date_trunc('month', coalesce(p_starts_on, public.fn__karachi_month()))::date;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Not permitted to propose discounts' using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);
  if p_amount is null or p_amount <= 0 then
    raise exception 'A discount has to be worth something. Enter an amount above zero.'
      using errcode = '22023';
  end if;
  if p_is_percent and p_amount > 100 then
    raise exception 'A percentage discount cannot be more than 100%%.' using errcode = '22023';
  end if;
  if p_ends_on is not null and date_trunc('month', p_ends_on)::date < v_start then
    raise exception 'A discount cannot end before the month it starts in.' using errcode = '22023';
  end if;

  -- BOUNDED, because this takes dates from the caller and writes a row with
  -- them. 0130's guard caught the first draft not doing it, which is the same
  -- hole that let attendance be marked in 2099. The calendar check rather than
  -- the session one: a discount deliberately outlives a session now, so
  -- refusing a start month outside this year would refuse the very thing this
  -- migration exists to allow. A year either side of the school's own years is
  -- the right fence.
  perform public.fn__assert_date_in_calendar(v_start, 'The month a discount starts in');
  if p_ends_on is not null then
    perform public.fn__assert_date_in_calendar(p_ends_on, 'The month a discount ends in');
  end if;

  -- Recorded, not relied on. See the note on the column.
  select e.id into v_enr from public.enrollments e
    join public.academic_sessions s on s.id = e.session_id
   where e.student_id = p_student_id and e.status = 'active'
   order by s.is_current desc, s.starts_on desc limit 1;

  insert into public.discounts(school_id, student_id, enrollment_id, type, amount,
                               is_percent, reason, status, created_by,
                               starts_on, ends_on)
  values (v_school, p_student_id, v_enr, p_type, p_amount,
          coalesce(p_is_percent, false), nullif(btrim(p_reason), ''), 'pending', auth.uid(),
          v_start, case when p_ends_on is null then null
                        else date_trunc('month', p_ends_on)::date end)
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.fn_add_discount(uuid, public.discount_type, numeric, boolean, text, date, date) from public, anon;
grant execute on function public.fn_add_discount(uuid, public.discount_type, numeric, boolean, text, date, date) to authenticated;

-- CHANGED IN PLACE. A school that raises a concession from 10 to 20 per cent
-- should not have to revoke one discount and invent another: the second reads
-- in every report as two separate acts of generosity.
create or replace function public.fn_edit_discount(
  p_discount_id uuid,
  p_type        public.discount_type,
  p_amount      numeric,
  p_is_percent  boolean,
  p_reason      text default null,
  p_starts_on   date default null,
  p_ends_on     date default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_d      record;
  v_start  date;
  v_res    jsonb;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Not permitted to change discounts' using errcode = '42501';
  end if;
  perform public.assert_own('discounts', p_discount_id);
  select * into v_d from public.discounts where id = p_discount_id;
  if not found then raise exception 'Discount not found'; end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'A discount has to be worth something. Enter an amount above zero.'
      using errcode = '22023';
  end if;
  if p_is_percent and p_amount > 100 then
    raise exception 'A percentage discount cannot be more than 100%%.' using errcode = '22023';
  end if;

  v_start := date_trunc('month', coalesce(p_starts_on, v_d.starts_on))::date;
  if p_ends_on is not null and date_trunc('month', p_ends_on)::date < v_start then
    raise exception 'A discount cannot end before the month it starts in.' using errcode = '22023';
  end if;
  perform public.fn__assert_date_in_calendar(v_start, 'The month a discount starts in');
  if p_ends_on is not null then
    perform public.fn__assert_date_in_calendar(p_ends_on, 'The month a discount ends in');
  end if;

  update public.discounts
     set type = p_type,
         amount = p_amount,
         is_percent = coalesce(p_is_percent, false),
         reason = nullif(btrim(p_reason), ''),
         starts_on = v_start,
         ends_on = case when p_ends_on is null then null
                        else date_trunc('month', p_ends_on)::date end
   where id = p_discount_id;

  -- From the EARLIER of the old and new start, because widening a discount
  -- backwards has to reach the challans it now covers.
  v_res := public.fn_reprice_student(v_d.student_id, least(v_start, v_d.starts_on));
  return jsonb_build_object('discount_id', p_discount_id, 'reprice', v_res);
end;
$$;
revoke all on function public.fn_edit_discount(uuid, public.discount_type, numeric, boolean, text, date, date) from public, anon;
grant execute on function public.fn_edit_discount(uuid, public.discount_type, numeric, boolean, text, date, date) to authenticated;

-- ENDED, NOT DELETED. The months it did apply to keep it, which is what makes
-- last year's statement still add up.
create or replace function public.fn_end_discount(
  p_discount_id uuid, p_last_month date default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_d   record;
  v_end date;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Not permitted to change discounts' using errcode = '42501';
  end if;
  perform public.assert_own('discounts', p_discount_id);
  select * into v_d from public.discounts where id = p_discount_id;
  if not found then raise exception 'Discount not found'; end if;

  -- Default: it stops applying from next month. Ending it in the CURRENT month
  -- would re-bill a family mid-month for a fee they were already shown.
  v_end := date_trunc('month', coalesce(p_last_month, public.fn__karachi_month()))::date;
  if v_end < v_d.starts_on then v_end := v_d.starts_on; end if;
  perform public.fn__assert_date_in_calendar(v_end, 'The month a discount ends in');

  update public.discounts set ends_on = v_end where id = p_discount_id;
  return jsonb_build_object(
    'discount_id', p_discount_id, 'ends_on', v_end,
    'reprice', public.fn_reprice_student(v_d.student_id, (v_end + interval '1 month')::date));
end;
$$;
revoke all on function public.fn_end_discount(uuid, date) from public, anon;
grant execute on function public.fn_end_discount(uuid, date) to authenticated;

-- Approving is what makes a discount real, so it is what must reach the
-- challans. This was the missing link: a discount could be approved and the
-- month's challan never heard about it.
create or replace function public.fn_set_discount_status(
  p_discount_id uuid, p_status public.discount_status
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_d record;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may approve or reject discounts'
      using errcode = '42501';
  end if;
  perform public.assert_own('discounts', p_discount_id);
  select * into v_d from public.discounts where id = p_discount_id;
  if not found then raise exception 'Discount not found'; end if;

  update public.discounts
     set status = p_status,
         approved_by = case when p_status = 'approved' then auth.uid() else approved_by end,
         approved_at = case when p_status = 'approved' then now() else approved_at end
   where id = p_discount_id;

  return jsonb_build_object(
    'discount_id', p_discount_id, 'status', p_status,
    'reprice', public.fn_reprice_student(v_d.student_id, v_d.starts_on));
end;
$$;
revoke all on function public.fn_set_discount_status(uuid, public.discount_status) from public, anon;
grant execute on function public.fn_set_discount_status(uuid, public.discount_status) to authenticated;

-- What the child's screen shows. Every discount, live or finished, with the
-- months it covers, so a parent asking "when did my concession stop" has an
-- answer that is not a guess.
create or replace function public.fn_student_discounts(p_student_id uuid)
returns table(
  id uuid, type text, amount numeric, is_percent boolean, reason text,
  status text, starts_on date, ends_on date, live boolean,
  proposed_by text, approved_by text, approved_at timestamptz
) language plpgsql stable security definer set search_path = public as $$
declare v_month date := public.fn__karachi_month();
begin
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted to view fee records' using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);
  return query
  select d.id, d.type::text, d.amount, d.is_percent, d.reason, d.status::text,
         d.starts_on, d.ends_on,
         (d.status = 'approved' and d.starts_on <= v_month
          and (d.ends_on is null or d.ends_on >= v_month)),
         coalesce(pb.full_name, '-'), coalesce(ab.full_name, '-'), d.approved_at
    from public.discounts d
    left join public.profiles pb on pb.id = d.created_by
    left join public.profiles ab on ab.id = d.approved_by
   where d.student_id = p_student_id
     and d.school_id = public.current_school_id()
   order by d.starts_on desc, d.created_at desc;
end;
$$;
revoke all on function public.fn_student_discounts(uuid) from public, anon;
grant execute on function public.fn_student_discounts(uuid) to authenticated;

-- ================== 5. everything that reads a discount, brought into line ===
-- fn__apply_discount_lines KEEPS ITS SIGNATURE and changes what it means. It
-- still takes (invoice, enrolment, tuition), because two frozen bundles call it
-- by exactly that, and it now ignores the enrolment and asks who the child is
-- and which month the challan is for. That one rewrite is what carries the new
-- rule into fn_generate_class_invoices and fn_bill_student_month without
-- either of them knowing, which is the whole reason for keeping the shape.
create or replace function public.fn__apply_discount_lines(
  p_invoice_id uuid, p_enrollment_id uuid, p_tuition numeric
) returns void language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_inv    record;
  v_room   numeric := p_tuition;
  v_amt    numeric;
  v_rec    record;
begin
  if v_school is null then
    raise exception 'No school context for this user' using errcode = '42501';
  end if;
  select i.id, i.student_id, i.period_month into v_inv
    from public.invoices i where i.id = p_invoice_id and i.school_id = v_school;
  if not found then
    raise exception 'Invoice not found in this school' using errcode = '42501';
  end if;

  for v_rec in
    select * from public.fn__discounts_live(
      v_inv.student_id, coalesce(v_inv.period_month, public.fn__karachi_month()))
  loop
    exit when v_room <= 0;
    v_amt := case when v_rec.is_percent then round(p_tuition * v_rec.amount / 100.0, 2)
                  else v_rec.amount end;
    v_amt := least(v_amt, v_room);
    if v_amt > 0 then
      insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
      values (p_invoice_id, null, 'Discount: ' || v_rec.type, v_amt, true);
      v_room := v_room - v_amt;
    end if;
  end loop;
end;
$$;
revoke all on function public.fn__apply_discount_lines(uuid, uuid, numeric) from public, anon, authenticated;

-- The two older billing paths, reproduced whole from pg_get_functiondef on a
-- fully migrated database with ONE line changed in each: the per-child fee
-- override is looked up by child rather than by enrolment. Without it they
-- would keep the discounts (through the function above) and lose the
-- overrides at rollover, which is the worse half of the same bug and harder
-- to spot because it is silent in both directions.
CREATE OR REPLACE FUNCTION public.fn_generate_class_invoices(p_session_id uuid, p_class_id uuid, p_period_month date, p_due_date date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_actor    uuid := auth.uid();
  v_school   uuid := public.current_school_id();
  v_enr      record;
  v_inv      uuid;
  v_count    integer := 0;
  v_arrears  numeric;
  v_tuition  numeric;
  v_families uuid[] := '{}';
  v_fam      uuid;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to generate invoices';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);

  -- 0130: same rule as the single-pupil version, and it matters more
  -- here: this writes a challan for every child in the class, so a
  -- mistyped year is forty rows in a month nobody will look at.
  perform public.fn__assert_date_in_session(p_session_id,
            p_period_month, 'Generating challans for a class',
            true);
  if p_due_date is not null
     and (p_due_date < p_period_month - 31
          or p_due_date > p_period_month + 180) then
    raise exception 'A challan for % cannot be due on %. Check the '
      'date.', to_char(p_period_month, 'Mon YYYY'),
      to_char(p_due_date, 'DD Mon YYYY')
      using errcode = '22008';
  end if;


  for v_enr in
    select e.id as enrollment_id, e.student_id
    from public.enrollments e
    -- The join added in 0054. See the note above: the student's own record must
    -- agree that they are here, not just the enrollment. This is the ONLY change
    -- to this function; everything else is pg_get_functiondef() output verbatim.
    join public.students s
      on s.id = e.student_id
     and s.school_id = v_school
     and s.status = 'active'
     and s.deleted_at is null
    where e.session_id = p_session_id and e.class_id = p_class_id and e.status = 'active'
      and not exists (
        select 1 from public.invoices i
        where i.enrollment_id = e.id and i.period_month = p_period_month and i.status <> 'void'
      )
  loop
    v_arrears := public.student_balance(v_enr.student_id);
    begin
      insert into public.invoices(
        student_id, enrollment_id, session_id, period_month, status,
        arrears_brought_forward, due_date, issued_at, created_by)
      values (
        v_enr.student_id, v_enr.enrollment_id, p_session_id, p_period_month, 'issued',
        v_arrears, p_due_date, now(), v_actor)
      returning id into v_inv;
    exception when unique_violation then
      continue;
    end;

    -- A per-student override (student_fee_items) still wins over the class
    -- amount; the class amount is now the one in force for the billed month.
    insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
    select v_inv, fh.id, fh.name, coalesce(sfi.amount, amt.amount), false
    from public.fee_heads fh
    join lateral (
      select fs.amount
      from public.fee_structures fs
      where fs.session_id = p_session_id
        and fs.class_id = p_class_id
        and fs.fee_head_id = fh.id
        and fs.effective_from <= coalesce(p_period_month, current_date)
      order by fs.effective_from desc
      limit 1
    ) amt on true
    left join public.student_fee_items sfi
      on sfi.student_id = v_enr.student_id and sfi.fee_head_id = fh.id and sfi.active
    where fh.school_id = v_school and fh.is_recurring and fh.active;

    select coalesce(sum(amount), 0) into v_tuition
    from public.invoice_lines where invoice_id = v_inv and not is_discount;

    perform public.fn__apply_discount_lines(v_inv, v_enr.enrollment_id, v_tuition);
    v_count := v_count + 1;

    select family_id into v_fam from public.students where id = v_enr.student_id;
    if v_fam is not null and not (v_fam = any(v_families)) then
      v_families := v_families || v_fam;
    end if;
  end loop;

  foreach v_fam in array v_families loop
    perform public.fn_apply_family_credit(v_fam);
  end loop;

  return v_count;
end;
$function$

;
CREATE OR REPLACE FUNCTION public.fn_bill_student_month(p_enrollment_id uuid, p_period_month date, p_due_date date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_actor   uuid := auth.uid();
  v_enr     record;
  v_inv     uuid;
  v_arrears numeric;
  v_tuition numeric;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to generate invoices';
  end if;
  perform public.assert_own('enrollments', p_enrollment_id);
  select e.id, e.student_id, e.session_id, e.class_id into v_enr
  from public.enrollments e where e.id = p_enrollment_id;
  if not found then raise exception 'Enrolment not found'; end if;

  -- 0130: the month being billed belongs to the year the child is
  -- enrolled in. A challan dated outside it shows in no month's
  -- collection and on no defaulter list.
  perform public.fn__assert_date_in_session(v_enr.session_id,
            p_period_month, 'Generating a challan',
            -- whole months: period_month is the FIRST of the month, a
            -- label for "September" and not a day. A school whose year
            -- begins on the 7th still bills that whole month.
            true);
  if p_due_date is not null
     and (p_due_date < p_period_month - 31
          or p_due_date > p_period_month + 180) then
    raise exception 'A challan for % cannot be due on %. Check the '
      'date.', to_char(p_period_month, 'Mon YYYY'),
      to_char(p_due_date, 'DD Mon YYYY')
      using errcode = '22008';
  end if;


  select id into v_inv from public.invoices
   where enrollment_id = p_enrollment_id and period_month = p_period_month and status <> 'void'
   limit 1;
  if found then return v_inv; end if;

  v_arrears := public.student_balance(v_enr.student_id);
  begin
    insert into public.invoices(student_id, enrollment_id, session_id, period_month, status,
        arrears_brought_forward, due_date, issued_at, created_by)
    values (v_enr.student_id, v_enr.id, v_enr.session_id, p_period_month, 'issued',
        v_arrears, p_due_date, now(), v_actor)
    returning id into v_inv;
  exception when unique_violation then
    -- lost a race with a concurrent bill for the same (enrolment, month)
    select id into v_inv from public.invoices
     where enrollment_id = p_enrollment_id and period_month = p_period_month and status <> 'void' limit 1;
    return v_inv;
  end;

  insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
  select v_inv, fh.id, fh.name, coalesce(sfi.amount, fs.amount), false
  from public.fee_heads fh
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
    on sfi.student_id = v_enr.student_id and sfi.fee_head_id = fh.id and sfi.active
  where fh.school_id = public.current_school_id() and fh.is_recurring and fh.active;

  select coalesce(sum(amount), 0) into v_tuition
  from public.invoice_lines where invoice_id = v_inv and not is_discount;

  perform public.fn__apply_discount_lines(v_inv, v_enr.id, v_tuition);
  return v_inv;
end;
$function$

;

-- The discount report follows the same move.
CREATE OR REPLACE FUNCTION public.fn_report_discounts(p_from date, p_to date)
 RETURNS TABLE(granted_on date, student_id uuid, student_name text, gr_no text, class_name text, reason_type text, is_percent boolean, amount numeric, reason text, status text, proposed_by text, approved_by text, approved_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_school uuid := public.current_school_id();
begin
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted to read discounts' using errcode = '42501';
  end if;

  -- 0138 MOVED THE KEY FROM THE ENROLMENT TO THE CHILD, and the paragraph that
  -- stood here argued the opposite: that scoping a discount to one session was
  -- correct because last year's hardship waiver should not silently continue.
  -- The argument was sound and the code did not implement it. Nothing asked the
  -- school at rollover; the waiver just stopped, in silence, for every family
  -- at once. A discount now ends when somebody ends it, and this report shows
  -- the months it covered so that ending is visible.

  return query
  select d.created_at::date, s.id, s.full_name, s.gr_no, c.name,
         d.type::text, d.is_percent, d.amount, d.reason, d.status::text,
         coalesce(pb.full_name, '-'), coalesce(ab.full_name, '-'), d.approved_at
  from public.discounts d
  join public.students s on s.id = d.student_id
  left join public.enrollments e
    on e.student_id = d.student_id and e.status = 'active'
  left join public.classes c on c.id = e.class_id
  left join public.profiles pb on pb.id = d.created_by
  left join public.profiles ab on ab.id = d.approved_by
  where d.school_id = v_school
    and s.deleted_at is null
    and (p_from is null or d.created_at::date >= p_from)
    and (p_to   is null or d.created_at::date <= p_to)
  order by d.created_at desc;
end;
$function$

;

-- ─────────────────────────────────────────────────────────────────────────
-- 0139_a_month_is_billed_whether_or_not_anybody_remembers.sql
-- ─────────────────────────────────────────────────────────────────────────
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

-- ─────────────────────────────────────────────────────────────────────────
-- 0140_the_month_the_roll_and_who_has_paid.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0140  The month, the roll, and who has paid
--
-- THE FEES SCREEN OPENED ON FOUR NUMBERS AND NONE OF THEM WAS THE QUESTION.
-- Unpaid challans, collected today, spent today, balance today. A school
-- standing at the counter on the fifth of the month wants to know: it is
-- September, there are 240 children, 118 have paid and 122 have not, and here
-- are their names. Not one of those four numbers answers any part of that.
--
-- Two of them were also wrong, and not by a rounding error. fn_counter_summary
-- measured "today" as date_trunc('day', now()) and "spent today" as
-- spent_on = current_date, both in the server's timezone, and Supabase runs on
-- UTC. Proven on a test database:
--
--     a payment taken at 02:00 on 16 September in Karachi
--     lands in 15 SEPTEMBER's "collected today"
--
-- A school that takes a fee early in the morning sees it on yesterday's figure.
-- 0107 exists precisely to put every date bound through Asia/Karachi and this
-- function was missed; so was fn_dashboard_summary, which shows the same figure
-- on the home screen.
--
-- fn_defaulters was a third kind of wrong. It called student_balance three
-- times per row, in the select list, in the where clause and again in the order
-- by, and student_balance is four subqueries over the whole ledger. Measured on
-- a 1046 pupil database with EXPLAIN ANALYZE: 3.7 SECONDS, for a screen the
-- office opens every day. 0118 exists to stop a balance reading the whole
-- ledger and this walked straight back into it.
--
-- And its rule was wrong as well: "defaulter" meant "owes anything", so a child
-- billed on the 1st and due on the 30th was a defaulter on the 2nd. The vendor
-- was asked and chose the rule a school actually uses: you are in arrears when
-- you owe for a month BEFORE the current one. September is in progress and
-- nobody is chased for it; the moment October is raised, an unpaid September
-- puts the family on the list.
-- =============================================================================

-- ================================================ 1. the month, in one go ====
-- ONE QUERY, NOT ONE PER PUPIL. Every figure on the Fees screen comes from
-- here, so it is written as three aggregates joined to the roll rather than as
-- a function called per child. The difference is the 3.7 seconds above.
create or replace function public.fn_fees_month(
  p_session_id uuid, p_month date default null
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_month  date := date_trunc('month', coalesce(p_month, public.fn__karachi_month()))::date;
  v_out    jsonb;
begin
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted to view fee records' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  with roll as (
    select e.id as enrollment_id, e.student_id
      from public.enrollments e
      join public.students s on s.id = e.student_id
                            and s.school_id = v_school
                            and s.status = 'active'
                            and s.deleted_at is null
     where e.session_id = p_session_id and e.status = 'active'
  ),
  inv as (
    select i.id, i.student_id, i.fine
      from public.invoices i
     where i.school_id = v_school and i.session_id = p_session_id
       and i.period_month = v_month and i.status <> 'void'
  ),
  lines as (
    select l.invoice_id,
           sum(case when l.is_discount then -l.amount else l.amount end) as net
      from public.invoice_lines l
      join inv on inv.id = l.invoice_id
     group by l.invoice_id
  ),
  alloc as (
    select al.invoice_id, sum(al.amount) as paid
      from public.payment_allocations al
      join public.payments p on p.id = al.payment_id and p.status = 'verified'
      join inv on inv.id = al.invoice_id
     group by al.invoice_id
  ),
  per_pupil as (
    select r.student_id,
           coalesce(sum(coalesce(l.net, 0) + coalesce(inv.fine, 0)), 0) as charge,
           coalesce(sum(coalesce(a.paid, 0)), 0) as paid,
           count(inv.id) as invoices
      from roll r
      left join inv on inv.student_id = r.student_id
      left join lines l on l.invoice_id = inv.id
      left join alloc a on a.invoice_id = inv.id
     group by r.student_id
  )
  select jsonb_build_object(
    'month',        v_month,
    'today',        (now() at time zone 'Asia/Karachi')::date,
    'state',        coalesce((select b.state from public.billing_months b
                               where b.session_id = p_session_id and b.period_month = v_month),
                             'scheduled'),
    'due_date',     (select b.due_date from public.billing_months b
                      where b.session_id = p_session_id and b.period_month = v_month),
    'roll',         (select count(*) from roll),
    'billed',       (select count(*) from per_pupil where invoices > 0),
    'not_billed',   (select count(*) from per_pupil where invoices = 0),
    -- Paid means the month is settled: charged and nothing left on it. A child
    -- whose fee is entirely waived counts as paid, because there is nothing for
    -- the office to chase and showing them on the unpaid list would be a lie
    -- forty families long.
    'paid',         (select count(*) from per_pupil where invoices > 0 and charge - paid <= 0),
    'unpaid',       (select count(*) from per_pupil where invoices > 0 and charge - paid > 0),
    'part_paid',    (select count(*) from per_pupil where invoices > 0 and paid > 0 and charge - paid > 0),
    'charged_total',(select coalesce(sum(charge), 0) from per_pupil),
    'paid_total',   (select coalesce(sum(paid), 0) from per_pupil),
    'due_total',    (select coalesce(sum(greatest(charge - paid, 0)), 0) from per_pupil)
  ) into v_out;

  return v_out;
end;
$$;
revoke all on function public.fn_fees_month(uuid, date) from public, anon;
grant execute on function public.fn_fees_month(uuid, date) to authenticated;

-- The two lists behind the two counts. Same shape for both so the screen shows
-- them the same way, and the caller says which it wants rather than this
-- returning everything and the browser filtering, which would send the whole
-- roll down the wire to show half of it.
create or replace function public.fn_fees_month_pupils(
  p_session_id uuid, p_month date default null, p_state text default 'unpaid'
) returns table(
  student_id uuid, gr_no text, full_name text, class_name text, section_name text,
  roll_no text, family_id uuid, family_head text,
  charge numeric, paid numeric, due numeric, state text
) language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_month  date := date_trunc('month', coalesce(p_month, public.fn__karachi_month()))::date;
begin
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted to view fee records' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  if coalesce(p_state, 'unpaid') not in ('paid', 'unpaid', 'not_billed', 'all') then
    raise exception 'Ask for paid, unpaid, not_billed or all.' using errcode = '22023';
  end if;

  return query
  with inv as (
    select i.id, i.student_id, i.fine
      from public.invoices i
     where i.school_id = v_school and i.session_id = p_session_id
       and i.period_month = v_month and i.status <> 'void'
  ),
  lines as (
    select l.invoice_id, sum(case when l.is_discount then -l.amount else l.amount end) as net
      from public.invoice_lines l join inv on inv.id = l.invoice_id group by l.invoice_id
  ),
  alloc as (
    select al.invoice_id, sum(al.amount) as paid
      from public.payment_allocations al
      join public.payments p on p.id = al.payment_id and p.status = 'verified'
      join inv on inv.id = al.invoice_id group by al.invoice_id
  ),
  per_pupil as (
    select e.student_id,
           coalesce(sum(coalesce(l.net, 0) + coalesce(inv.fine, 0)), 0) as charge,
           coalesce(sum(coalesce(a.paid, 0)), 0) as paid,
           count(inv.id) as invoices
      from public.enrollments e
      join public.students s on s.id = e.student_id and s.school_id = v_school
                            and s.status = 'active' and s.deleted_at is null
      left join inv on inv.student_id = e.student_id
      left join lines l on l.invoice_id = inv.id
      left join alloc a on a.invoice_id = inv.id
     where e.session_id = p_session_id and e.status = 'active'
     group by e.student_id
  )
  select s.id, s.gr_no, s.full_name, c.name, sec.name, e.roll_no,
         s.family_id, f.head_name,
         pp.charge, pp.paid, greatest(pp.charge - pp.paid, 0),
         case when pp.invoices = 0 then 'not_billed'
              when pp.charge - pp.paid <= 0 then 'paid'
              else 'unpaid' end
    from per_pupil pp
    join public.students s on s.id = pp.student_id
    join public.enrollments e on e.student_id = s.id and e.session_id = p_session_id
                             and e.status = 'active'
    join public.classes c on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
    left join public.families f on f.id = s.family_id
   where coalesce(p_state, 'unpaid') = 'all'
      or (case when pp.invoices = 0 then 'not_billed'
               when pp.charge - pp.paid <= 0 then 'paid'
               else 'unpaid' end) = p_state
   order by c.level_order, c.name, sec.name nulls first, s.full_name;
end;
$$;
revoke all on function public.fn_fees_month_pupils(uuid, date, text) from public, anon;
grant execute on function public.fn_fees_month_pupils(uuid, date, text) to authenticated;

-- ==================================================== 2. arrears ============
-- OWES FOR A MONTH BEFORE THIS ONE. The vendor chose this rule over "past the
-- due date" and over "owes more than a month's fee", and it is the one a school
-- can explain to a parent in one sentence: September is running, so nobody is
-- chased for September.
--
-- months_owed is the count of separate months still open, which is what tells
-- the office the difference between a family one month behind and a family four
-- months behind. The old screen showed one number, the total, where Rs 12,000
-- could be one expensive month or four cheap ones.
create or replace function public.fn_arrears(p_session_id uuid)
returns table(
  student_id uuid, gr_no text, full_name text, class_name text, section_name text,
  roll_no text, family_id uuid, family_head text, phone text,
  months_owed integer, oldest_month date, amount numeric
) language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_month  date := public.fn__karachi_month();
begin
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted to view fee records' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  return query
  with inv as (
    select i.id, i.student_id, i.period_month, i.fine
      from public.invoices i
     where i.school_id = v_school
       and i.status <> 'void'
       and i.period_month is not null
       and i.period_month < v_month
       -- A challan the office has deliberately deferred is not an arrear: the
       -- school has already said "pay me in November". 0083 put that field
       -- there and nothing on the defaulters screen ever read it.
       and (i.deferred_until is null or i.deferred_until <= (now() at time zone 'Asia/Karachi')::date)
  ),
  lines as (
    select l.invoice_id, sum(case when l.is_discount then -l.amount else l.amount end) as net
      from public.invoice_lines l join inv on inv.id = l.invoice_id group by l.invoice_id
  ),
  alloc as (
    select al.invoice_id, sum(al.amount) as paid
      from public.payment_allocations al
      join public.payments p on p.id = al.payment_id and p.status = 'verified'
      join inv on inv.id = al.invoice_id group by al.invoice_id
  ),
  owing as (
    select inv.student_id, inv.period_month,
           coalesce(l.net, 0) + coalesce(inv.fine, 0) - coalesce(a.paid, 0) as due
      from inv
      left join lines l on l.invoice_id = inv.id
      left join alloc a on a.invoice_id = inv.id
  ),
  rolled as (
    select o.student_id,
           count(*)::integer as months_owed,
           min(o.period_month) as oldest_month,
           sum(o.due) as amount
      from owing o
     where o.due > 0
     group by o.student_id
  )
  select s.id, s.gr_no, s.full_name, c.name, sec.name, e.roll_no,
         s.family_id, f.head_name, coalesce(f.phone, s.phone),
         r.months_owed, r.oldest_month, r.amount
    from rolled r
    join public.students s on s.id = r.student_id
                          and s.status = 'active' and s.deleted_at is null
    join public.enrollments e on e.student_id = s.id and e.session_id = p_session_id
                             and e.status = 'active'
    join public.classes c on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
    left join public.families f on f.id = s.family_id
   order by r.oldest_month, r.amount desc;
end;
$$;
revoke all on function public.fn_arrears(uuid) from public, anon;
grant execute on function public.fn_arrears(uuid) to authenticated;

-- fn_defaulters KEEPS ITS NAME AND ITS SHAPE and stops being slow. Three
-- frozen bundles and the reports screen call it by this signature. The rule is
-- unchanged here on purpose, "owes anything at all", because that IS a useful
-- question for the reports page; what changes is that it asks it once instead
-- of three times per pupil over the whole ledger. The screen that used to be
-- called Defaulters now shows fn_arrears above.
create or replace function public.fn_defaulters(p_session_id uuid)
returns table(
  student_id uuid, gr_no text, full_name text, class_name text,
  section_name text, roll_no text, balance numeric
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  return query
  with inv as (
    select i.id, i.student_id, i.fine from public.invoices i
     where i.school_id = v_school and i.status <> 'void'
  ),
  lines as (
    select l.invoice_id, sum(case when l.is_discount then -l.amount else l.amount end) as net
      from public.invoice_lines l join inv on inv.id = l.invoice_id group by l.invoice_id
  ),
  alloc as (
    select al.invoice_id, sum(al.amount) as paid
      from public.payment_allocations al
      join public.payments p on p.id = al.payment_id and p.status = 'verified'
      join inv on inv.id = al.invoice_id group by al.invoice_id
  ),
  adj as (
    select a.student_id, sum(a.amount) as amount
      from public.adjustments a group by a.student_id
  ),
  bal as (
    select inv.student_id,
           sum(coalesce(l.net, 0) + coalesce(inv.fine, 0) - coalesce(a.paid, 0)) as owed
      from inv
      left join lines l on l.invoice_id = inv.id
      left join alloc a on a.invoice_id = inv.id
     group by inv.student_id
  )
  select s.id, s.gr_no, s.full_name, c.name, sec.name, e.roll_no,
         coalesce(b.owed, 0) + coalesce(j.amount, 0)
    from public.enrollments e
    join public.students s on s.id = e.student_id and s.school_id = v_school
                          and s.status = 'active' and s.deleted_at is null
    join public.classes c on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
    left join bal b on b.student_id = s.id
    left join adj j on j.student_id = s.id
   where e.session_id = p_session_id and e.status = 'active'
     and coalesce(b.owed, 0) + coalesce(j.amount, 0) > 0
   order by coalesce(b.owed, 0) + coalesce(j.amount, 0) desc;
end;
$$;
revoke all on function public.fn_defaulters(uuid) from public, anon;
grant execute on function public.fn_defaulters(uuid) to authenticated;

-- ==================================== 3. the two counters, in Karachi time ===
-- Reproduced whole from pg_get_functiondef on a fully migrated database, with
-- only the date bounds changed. See the header: a payment taken at 02:00 on the
-- 16th in Karachi was being counted on the 15th, on both of these screens, for
-- five hours every single morning.
CREATE OR REPLACE FUNCTION public.fn_counter_summary()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_school   uuid := public.current_school_id();
  v_unpaid   integer;
  v_income   numeric;
  v_expense  numeric;
  v_pending  integer;
  v_pending_amt numeric;
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  -- An invoice is "unpaid" when what it charges exceeds what has been allocated
  -- to it from VERIFIED payments. Derived rather than read off invoices.status,
  -- because status is a label and this is the money.
  select count(*) into v_unpaid
  from public.invoices i
  where i.school_id = v_school
    and i.status <> 'void'
    and (
      coalesce((select sum(case when l.is_discount then -l.amount else l.amount end)
                  from public.invoice_lines l where l.invoice_id = i.id), 0)
      + coalesce(i.fine, 0)
      - coalesce((select sum(al.amount)
                    from public.payment_allocations al
                    join public.payments p on p.id = al.payment_id
                   where al.invoice_id = i.id and p.status = 'verified'), 0)
    ) > 0;

  select coalesce(sum(p.amount), 0) into v_income
  from public.payments p
  where p.school_id = v_school
    and p.status = 'verified'
    -- KARACHI, NOT THE SERVER. Supabase runs on UTC, so date_trunc('day', now())
    -- began the day at 05:00 Pakistan time: a fee taken at 2am appeared in
    -- YESTERDAY's collection. 0107 put every other date bound in this schema
    -- through Asia/Karachi and this one was missed.
    and (p.created_at at time zone 'Asia/Karachi')::date
        = (now() at time zone 'Asia/Karachi')::date;

  select coalesce(sum(e.amount), 0) into v_expense
  from public.expenses e
  where e.school_id = v_school
    and e.spent_on = (now() at time zone 'Asia/Karachi')::date
    and e.reversal_of is null;

  -- Money taken but not yet cleared. Shown next to the day's income because a
  -- clerk who has accepted three bank transfers needs to know they are not in
  -- that income figure — otherwise the drawer looks short at closing.
  select count(*), coalesce(sum(p.amount), 0) into v_pending, v_pending_amt
  from public.payments p
  where p.school_id = v_school and p.status = 'pending';

  return jsonb_build_object(
    'unpaid_invoices', v_unpaid,
    'income_today',    v_income,
    'expense_today',   v_expense,
    'balance_today',   v_income - v_expense,
    'pending_count',   v_pending,
    'pending_amount',  v_pending_amt);
end;
$function$

;

CREATE OR REPLACE FUNCTION public.fn_dashboard_summary()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_school  uuid := public.current_school_id();
  v_session uuid := (select current_session_id from public.school_settings
                      where school_id = v_school);
  -- may_view, and NOT the plain role check. 0059 rewrote every READ gate in the
  -- schema to go through one helper, programmatically, and warned in its own
  -- header that retyping a function body by hand is how that gets silently
  -- reverted. The first draft of this migration did exactly that on all three
  -- functions it touches; supabase/repair/detect.sql caught it. Uncaught, it
  -- would have shut the observer role out of the money tiles all over again.
  v_finance boolean := public.may_view('owner','principal','admin_clerk','accountant','readonly');
  v_active  int;
  v_no_class int;
  v_present int; v_absent int; v_leave int; v_late int; v_half int; v_marked int;
  v_today numeric; v_month numeric; v_outstanding numeric; v_defaulters int;
  v_new_admissions int;
  v_billed_month int;
  v_classes_no_fee int;
  -- Karachi for the same reason as fn_counter_summary: for five hours every
  -- morning the server's date is still yesterday's.
  v_month_start date := date_trunc('month', (now() at time zone 'Asia/Karachi')::date)::date;
begin
  if not public.may_view('owner','principal','admin_clerk','accountant',
                         'class_teacher','subject_teacher','readonly') then
    raise exception 'Not permitted';
  end if;

  -- ONE definition, shared with the plan limit. Previously this counted
  -- enrolments without looking at the student row, so a record removed in error
  -- stayed in the tile while dropping out of the licence count and off the
  -- Students screen.
  v_active := public.fn_count_students(v_school);

  -- The children the tile cannot see. An active student with no active
  -- enrolment in the current session gets no challan, no register entry and no
  -- result card, and no other screen in the product reports them.
  select count(*) into v_no_class
  from public.students s
  where s.school_id = v_school
    and s.status = 'active'
    and s.deleted_at is null
    and not exists (
      select 1 from public.enrollments e
      where e.student_id = s.id
        and e.session_id = v_session
        and e.status = 'active');

  -- Joined to students so a removed child cannot be marked present against a
  -- headcount that no longer includes them. "42 present of 40 on the roll" is
  -- the kind of arithmetic that makes a school stop trusting the whole page.
  select
    count(*) filter (where ad.status = 'present'),
    count(*) filter (where ad.status = 'absent'),
    count(*) filter (where ad.status = 'leave'),
    count(*) filter (where ad.status = 'late'),
    count(*) filter (where ad.status = 'half_day'),
    count(*)
  into v_present, v_absent, v_leave, v_late, v_half, v_marked
  from public.attendance_daily ad
  join public.enrollments e on e.id = ad.enrollment_id
  join public.students s on s.id = e.student_id
  where ad.school_id = v_school
    and ad.attendance_date = (now() at time zone 'Asia/Karachi')::date
    and e.session_id = v_session
    and s.deleted_at is null;

  select count(*) into v_new_admissions
  from public.students s
  where s.school_id = v_school
    and s.deleted_at is null
    and s.created_at >= v_month_start
    and s.created_at < (v_month_start + interval '1 month');

  if v_finance then
    select coalesce(sum(p.amount), 0) into v_today
    from public.payments p
    where p.school_id = v_school
      and p.status = 'verified'
      and (p.created_at at time zone 'Asia/Karachi')::date
          = (now() at time zone 'Asia/Karachi')::date;

    select coalesce(sum(p.amount), 0) into v_month
    from public.payments p
    where p.school_id = v_school
      and p.status = 'verified'
      and p.created_at >= v_month_start
      and p.created_at <  (v_month_start + interval '1 month');

    select coalesce(sum(b.bal), 0), count(*) into v_outstanding, v_defaulters
    from public.enrollments e
    join lateral (select public.student_balance(e.student_id) as bal) b on true
    where e.school_id = v_school
      and e.session_id = v_session
      and e.status = 'active'
      and b.bal > 0;

    select count(distinct i.student_id) into v_billed_month
    from public.invoices i
    where i.school_id = v_school
      and i.period_month = v_month_start
      and i.status <> 'void'
      and coalesce((select sum(case when l.is_discount then -l.amount else l.amount end)
                      from public.invoice_lines l where l.invoice_id = i.id), 0) > 0;

    select count(*) into v_classes_no_fee
    from public.classes c
    where c.school_id = v_school
      and exists (select 1 from public.enrollments e
                   where e.class_id = c.id and e.session_id = v_session and e.status = 'active')
      and not exists (select 1 from public.fee_structures fs
                       where fs.class_id = c.id and fs.session_id = v_session and fs.amount > 0);
  end if;

  return jsonb_build_object(
    'active_students', coalesce(v_active, 0),
    'students_without_a_class', coalesce(v_no_class, 0),
    'new_admissions_month', coalesce(v_new_admissions, 0),
    'attendance', jsonb_build_object(
      'marked', coalesce(v_marked, 0), 'present', coalesce(v_present, 0),
      'absent', coalesce(v_absent, 0), 'leave', coalesce(v_leave, 0),
      'late', coalesce(v_late, 0), 'half_day', coalesce(v_half, 0)),
    'finance_visible', v_finance,
    'collected_today', coalesce(v_today, 0),
    'collected_month', coalesce(v_month, 0),
    'outstanding', coalesce(v_outstanding, 0),
    'defaulters', coalesce(v_defaulters, 0),
    'billed_students_month', coalesce(v_billed_month, 0),
    'classes_without_fee', coalesce(v_classes_no_fee, 0),
    'session_set', v_session is not null);
end;
$function$

;

-- ================================ 4. one child, one answer, everywhere =======
-- THE TAG BEHIND EVERY SEARCH RESULT. When the office types a name, the answer
-- they need first is "has this child paid this month", and nothing in this
-- product could say it. The child's own Fees tab could not either: it showed
-- CURRENT BALANCE Rs 0 for a family whose Rs 3,150 the school was holding as an
-- advance, because student_balance answers "what is owed" and nothing answered
-- "what are we sitting on".
--
-- Both come back here, from one call, so the search result, the child's tab and
-- the family sheet cannot disagree with each other.
create or replace function public.fn_student_fee_state(
  p_student_id uuid, p_month date default null
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_month  date := date_trunc('month', coalesce(p_month, public.fn__karachi_month()))::date;
  v_charge numeric; v_paid numeric; v_inv integer;
  v_arr_n integer; v_arr_amt numeric; v_arr_old date;
  v_family uuid; v_credit numeric := 0;
begin
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted to view fee records' using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);
  select family_id into v_family from public.students where id = p_student_id;

  select count(i.id),
         coalesce(sum(coalesce(l.net, 0) + i.fine), 0),
         coalesce(sum(coalesce(a.paid, 0)), 0)
    into v_inv, v_charge, v_paid
    from public.invoices i
    left join lateral (
      select sum(case when x.is_discount then -x.amount else x.amount end) as net
        from public.invoice_lines x where x.invoice_id = i.id) l on true
    left join lateral (
      select sum(al.amount) as paid from public.payment_allocations al
        join public.payments p on p.id = al.payment_id and p.status = 'verified'
       where al.invoice_id = i.id) a on true
   where i.school_id = v_school and i.student_id = p_student_id
     and i.period_month = v_month and i.status <> 'void';

  select count(*)::integer, coalesce(sum(due), 0), min(period_month)
    into v_arr_n, v_arr_amt, v_arr_old
    from (
      select i.period_month,
             coalesce((select sum(case when x.is_discount then -x.amount else x.amount end)
                         from public.invoice_lines x where x.invoice_id = i.id), 0)
             + i.fine
             - coalesce((select sum(al.amount) from public.payment_allocations al
                           join public.payments p on p.id = al.payment_id and p.status = 'verified'
                          where al.invoice_id = i.id), 0) as due
        from public.invoices i
       where i.school_id = v_school and i.student_id = p_student_id
         and i.status <> 'void' and i.period_month is not null
         and i.period_month < v_month
         and (i.deferred_until is null
              or i.deferred_until <= (now() at time zone 'Asia/Karachi')::date)
    ) q
   where q.due > 0;

  if v_family is not null then
    v_credit := public.family_credit(v_family);
  end if;

  return jsonb_build_object(
    'month', v_month,
    'billed', v_inv > 0,
    -- 'paid' is only true of a month that was actually charged. A child nobody
    -- billed is neither paid nor unpaid and saying either would be a lie.
    'state', case when v_inv = 0 then 'not_billed'
                  when v_charge - v_paid <= 0 then 'paid'
                  when v_paid > 0 then 'part_paid'
                  else 'unpaid' end,
    'charge', v_charge,
    'paid', v_paid,
    'due', greatest(v_charge - v_paid, 0),
    'arrears_months', coalesce(v_arr_n, 0),
    'arrears_amount', coalesce(v_arr_amt, 0),
    'arrears_oldest', v_arr_old,
    'balance', public.student_balance(p_student_id),
    -- The money the school is holding for this family that is not yet against
    -- any month. Invisible on the child's screen until now.
    'family_credit', v_credit);
end;
$$;
revoke all on function public.fn_student_fee_state(uuid, date) from public, anon;
grant execute on function public.fn_student_fee_state(uuid, date) to authenticated;

-- ============================= 5. a note about the withdrawn roles ===========
-- 0133 withdrew admin_clerk and accountant, and forty-one fee functions still
-- name them inside has_role lists. That is dead text, not a hole: 0133 added a
-- check constraint that makes both values unreachable, so no profile can carry
-- one and no gate can pass on one.
--
-- It is NOT swept here, and the reason is worth writing down. Rewriting forty
-- one function bodies by string replacement is precisely the technique that
-- took bundle 7 down once already: 0085 was a text patch, 0135 removed the
-- name it anchored on, and the whole bundle rolled back on the schools it was
-- written for. Every fee function this batch touches is reproduced whole with
-- the live roles only; the rest are left to be rewritten the same way when
-- they are next opened, which is slower and cannot go stale.

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0138_a_discount_belongs_to_the_child.sql', '41_the_fee_module_rebuilt_around_the_month.sql');
  perform public.fn_record_migration('0139_a_month_is_billed_whether_or_not_anybody_remembers.sql', '41_the_fee_module_rebuilt_around_the_month.sql');
  perform public.fn_record_migration('0140_the_month_the_roll_and_who_has_paid.sql', '41_the_fee_module_rebuilt_around_the_month.sql');
end $ledger$;
