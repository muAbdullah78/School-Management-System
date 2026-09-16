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
