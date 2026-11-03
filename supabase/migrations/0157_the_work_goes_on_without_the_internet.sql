-- =============================================================================
-- 0157. The work goes on without the internet.
--
-- Many schools have weak or patchy internet and will not run on software that
-- stops when the signal does. The app now keeps working offline for the jobs
-- that cannot wait (attendance, marks, fee collection with expenses, and new
-- admissions) and hands the work in when the connection comes back. This is
-- the server half.
--
-- THE RULE. The server stays the only source of truth. A device never sends
-- rows. It sends COMMANDS ("these pupils were present on 3 November", "Rs 2,500
-- received for Ali on receipt 1204"), each with an id the device made itself.
-- fn_offline_apply runs every command through the same functions the screens
-- call online, so every permission, limit and rule still applies, and keeps the
-- id, so a command sent twice (an answer lost on a weak signal) is applied once
-- and the second send gets the first answer.
--
-- DEVICES AND LEASES. A device says hello when it connects (fn_sync_hello). It
-- is told the server's clock and given a lease: it may work offline for seven
-- days from its last connection, never past the day the school would lock.
-- Every lease is kept, so a command is accepted only if it was made while its
-- device held one. A school that locks while a device is offline loses nothing
-- done before the lock. Work dated after the lock waits on the device until the
-- school renews. A lost phone can be switched off (fn_revoke_device).
--
-- RECEIPTS. A receipt printed offline must be final, because the parent takes
-- it home. Each device that collects fees is given its own block of receipt
-- numbers in advance, taken from the school's counter so it can never collide
-- with a number the server hands out. Blocks are topped up at every connection
-- and every block is recorded, so a number never used is accounted for.
--
-- CONFLICTS. Payments, expenses and admissions only ever add, so they cannot
-- collide. Attendance and marks can: a teacher marks on a phone with no signal,
-- corrects one pupil on the office computer, and the phone connects later. The
-- newer entry wins by when it was MADE, not when it arrived. Attendance and
-- marks now carry authored_at, and an offline entry older than what is already
-- there is left out and reported back to the device.
--
-- NOTHING IS DROPPED. Money already taken is recorded: a receipt number that is
-- already used, or is not the device's own, is recorded under a fresh number and
-- flagged, and the same payment sent twice is recognised and kept once. A
-- command that is refused is kept with what was sent, for the owner to see
-- (fn_offline_review).
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. DEVICES, LEASES, RECEIPT BLOCKS AND COMMANDS
--
-- Written and read only by the functions in this migration. RLS on and no
-- policy, so a browser can neither read nor write them directly.
--
-- They carry no enforce_school_id trigger, on purpose. That trigger is also the
-- subscription gate, and a device of a school that has locked must still be
-- able to say hello, learn that it has locked, and hand in what it did while it
-- was allowed to. Every row is written with the caller's own school_id by the
-- functions here, and nothing else writes them.
-- -----------------------------------------------------------------------------
create table if not exists public.sync_devices (
  school_id     uuid not null references public.schools(id) on delete cascade,
  device_id     uuid not null,
  user_id       uuid not null,
  platform      text not null default 'web',
  app_version   text,
  first_seen    timestamptz not null default now(),
  last_seen     timestamptz not null default now(),
  revoked_at    timestamptz,
  revoked_by    uuid,
  revoke_reason text,
  primary key (school_id, device_id, user_id),
  constraint sync_devices_platform check (platform in ('web', 'android', 'windows', 'other')),
  constraint sync_devices_version check (app_version is null or char_length(app_version) <= 40),
  constraint sync_devices_reason check (revoke_reason is null or char_length(revoke_reason) <= 200)
);
alter table public.sync_devices enable row level security;
revoke all on public.sync_devices from public, anon, authenticated;

-- One row per unbroken stretch of permission to work offline. A device that
-- keeps connecting extends the same stretch. One that comes back after its
-- lease ran out starts a new one, so the gap between them is visible and a
-- command dated inside it is refused.
create table if not exists public.sync_leases (
  id         uuid primary key default gen_random_uuid(),
  school_id  uuid not null references public.schools(id) on delete cascade,
  device_id  uuid not null,
  user_id    uuid not null,
  from_at    timestamptz not null default now(),
  until_at   timestamptz not null,
  constraint sync_leases_order check (until_at >= from_at)
);
create index if not exists idx_sync_leases_device
  on public.sync_leases (school_id, device_id, user_id, from_at desc);
alter table public.sync_leases enable row level security;
revoke all on public.sync_leases from public, anon, authenticated;

create table if not exists public.receipt_blocks (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  device_id     uuid not null,
  user_id       uuid not null,
  first_no      bigint not null,
  last_no       bigint not null,
  issued_at     timestamptz not null default now(),
  closed_at     timestamptz,
  closed_reason text,
  constraint receipt_blocks_range check (first_no > 0 and last_no >= first_no),
  constraint receipt_blocks_reason check (closed_reason is null or closed_reason in ('used', 'device_revoked'))
);
create index if not exists idx_receipt_blocks_device
  on public.receipt_blocks (school_id, device_id, user_id, first_no);
alter table public.receipt_blocks enable row level security;
revoke all on public.receipt_blocks from public, anon, authenticated;

-- What each command did, by its id. The payload is kept only when the owner
-- may need to see it (refused, or applied with a flag), so a year of everyday
-- attendance does not fill the database.
create table if not exists public.client_commands (
  id           uuid primary key,
  school_id    uuid not null references public.schools(id) on delete cascade,
  user_id      uuid not null,
  device_id    uuid not null,
  type         text not null,
  occurred_at  timestamptz,
  received_at  timestamptz not null default now(),
  status       text not null,
  payload      jsonb,
  result       jsonb,
  flags        text[] not null default '{}',
  error        text,
  error_code   text,
  reviewed_at  timestamptz,
  reviewed_by  uuid,
  constraint client_commands_status check (status in ('applied', 'rejected')),
  constraint client_commands_type check (char_length(type) between 1 and 40)
);
create index if not exists idx_client_commands_school
  on public.client_commands (school_id, received_at desc);
alter table public.client_commands enable row level security;
revoke all on public.client_commands from public, anon, authenticated;

-- Every offline payment asks whether its printed number is already used, and
-- the devices screen counts the numbers used in each block. Neither should
-- read a school's whole payment history to answer.
create index if not exists idx_payments_receipt on public.payments (school_id, receipt_no);


-- -----------------------------------------------------------------------------
-- 2. WHEN AN ENTRY WAS MADE
--
-- updated_at says when a row was last written, which for an entry sent from a
-- phone that was offline is hours after it was made. authored_at says when the
-- value in the row was decided: now for the screens, the moment it was made for
-- a command handed in later (fn_offline_apply sets app.offline_at for the length
-- of the command). A write that leaves the value as it was (finalising a day,
-- reopening it) keeps the old authored_at, because nobody decided anything new.
--
-- updated_at is left alone. The result-card readiness check reads it to know a
-- card is out of date, and a mark that arrived after the card was made has made
-- it out of date whenever the mark was typed.
--
-- Nothing is backfilled: a row written before this has authored_at null, and the
-- one reader uses coalesce(authored_at, updated_at).
-- -----------------------------------------------------------------------------
alter table public.attendance_daily   add column if not exists authored_at timestamptz;
alter table public.attendance_subject add column if not exists authored_at timestamptz;
alter table public.mark_entries       add column if not exists authored_at timestamptz;

create or replace function public.fn__stamp_authored_at()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_off timestamptz := nullif(current_setting('app.offline_at', true), '')::timestamptz;
  v_at  timestamptz := coalesce(v_off, now());
begin
  -- AN ENTRY MADE OFFLINE NEVER REPLACES OR CLEARS ONE DECIDED AFTER IT.
  -- fn__offline_apply_one leaves such entries out before it calls the screen's
  -- function, but it reads without a lock: an entry another device or the
  -- screen commits while this command waits for the row would be overwritten
  -- by the older one. Here the row is the one being written, locked and
  -- current, so the decision cannot be raced. The row is left exactly as it is
  -- and its pupil is reported back in kept_newer (app.offline_kept).
  if v_off is not null and tg_op in ('UPDATE', 'DELETE')
     and coalesce(old.authored_at, old.updated_at) > v_off then
    perform set_config('app.offline_kept',
      concat_ws(',', nullif(current_setting('app.offline_kept', true), ''), old.enrollment_id::text), true);
    return null;
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  if tg_op = 'UPDATE' then
    -- Nested, not one condition: plpgsql reads new.status only on the tables
    -- that have it.
    if tg_table_name = 'mark_entries' then
      if (new.marks, new.practical_marks, new.is_absent)
           is not distinct from (old.marks, old.practical_marks, old.is_absent) then
        new.authored_at := old.authored_at;
        return new;
      end if;
    elsif new.status is not distinct from old.status then
      new.authored_at := old.authored_at;
      return new;
    end if;
  end if;
  new.authored_at := v_at;
  return new;
end;
$$;
revoke all on function public.fn__stamp_authored_at() from public, anon, authenticated;

drop trigger if exists trg_attendance_daily_authored on public.attendance_daily;
create trigger trg_attendance_daily_authored before insert or update or delete on public.attendance_daily
  for each row execute function public.fn__stamp_authored_at();
drop trigger if exists trg_attendance_subject_authored on public.attendance_subject;
create trigger trg_attendance_subject_authored before insert or update or delete on public.attendance_subject
  for each row execute function public.fn__stamp_authored_at();
drop trigger if exists trg_mark_entries_authored on public.mark_entries;
create trigger trg_mark_entries_authored before insert or update or delete on public.mark_entries
  for each row execute function public.fn__stamp_authored_at();


-- -----------------------------------------------------------------------------
-- 3. WORK DONE WHILE THE SCHOOL WAS OPEN, HANDED IN AFTER IT LOCKED
--
-- The subscription gate refuses every write once a school is locked. A clerk
-- who took fees on Monday with no signal, while the school was still paid up,
-- and reached a signal on Thursday after it locked, would otherwise have the
-- money refused. fn_offline_apply sets app.offline_replay for one command, and
-- only when that command was made before the school stopped being allowed to
-- write and while its device held a lease (which never runs past that moment).
-- It is a transaction-local setting, set only inside a definer function: a
-- browser cannot set it, and it cannot outlive the request (see 0074 on why
-- only the transaction-local form is safe behind a connection pool).
--
-- Both functions are otherwise exactly as they were.
-- -----------------------------------------------------------------------------
create or replace function public.enforce_school_id()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_school uuid := public.current_school_id();
  v_status public.subscription_status;
begin
  if tg_op = 'INSERT' then
    if new.school_id is null then
      new.school_id := v_school;
    elsif v_school is not null and new.school_id <> v_school then
      raise exception 'Cross-tenant write refused on %: row addressed to school %, caller belongs to %',
        tg_table_name, new.school_id, v_school;
    end if;
    if new.school_id is null then
      raise exception 'Cannot write to % : no school context for this user', tg_table_name;
    end if;
  else
    if new.school_id is distinct from old.school_id then
      raise exception 'A % row cannot be moved between schools', tg_table_name;
    end if;
  end if;

  -- Subscription gate. Only applies to writes made by a signed-in user: the
  -- platform's own service-role paths have no school context and must keep
  -- working (that is how a school gets REACTIVATED after paying). Work made
  -- before the lock and handed in after it passes (0157).
  if v_school is not null
     and coalesce(current_setting('app.offline_replay', true), '') <> 'on' then
    v_status := public.fn_effective_status(new.school_id);
    if v_status in ('locked', 'cancelled') then
      raise exception
        'This school''s subscription has ended. Your records are safe and can still be viewed and exported. Renew to start entering data again.'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.fn__licence_delete_gate()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_school uuid := public.current_school_id();
begin
  if v_school is not null and old.school_id = v_school
     and coalesce(current_setting('app.offline_replay', true), '') <> 'on'
     and public.fn_effective_status(v_school) in ('locked', 'cancelled') then
    raise exception
      'This school''s subscription has ended. Your records are safe and can still be viewed and exported. Renew to start entering data again.'
      using errcode = '42501';
  end if;
  return old;
end;
$$;

-- WHEN A SCHOOL STOPPED. Work handed in late is measured against the moment
-- the school stopped being allowed to write, so that moment has to be known for
-- every way a school stops. Suspension had suspended_at and the lock day is
-- worked out from the dates, but a cancellation (by us, or by archiving) and a
-- school's own request to stop at the end of its period left no time behind.
-- Without one, a cancelled school paid weeks ahead looked open until then, and
-- a school that asked to stop while in its grace days had those days' work
-- treated as made after it stopped. A trigger stamps both on every path that
-- sets them, since several functions do.
alter table public.subscriptions add column if not exists cancelled_at timestamptz;
alter table public.subscriptions add column if not exists cancel_requested_at timestamptz;

create or replace function public.fn__stamp_subscription_stops()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- Kept as it was while the status stays, null included: a school cancelled
  -- before 0157 has no time and counts as stopped since ever, and an unrelated
  -- update must not stamp it with that update's time.
  if new.status = 'cancelled' then
    new.cancelled_at := case when tg_op = 'UPDATE' and old.status = 'cancelled'
                             then old.cancelled_at else now() end;
  else
    new.cancelled_at := null;
  end if;
  if coalesce(new.cancel_at_period_end, false) then
    new.cancel_requested_at := case when tg_op = 'UPDATE' and coalesce(old.cancel_at_period_end, false)
                                    then old.cancel_requested_at else now() end;
  else
    new.cancel_requested_at := null;
  end if;
  return new;
end;
$$;
revoke all on function public.fn__stamp_subscription_stops() from public, anon, authenticated;
drop trigger if exists trg_subscription_stops on public.subscriptions;
create trigger trg_subscription_stops before insert or update on public.subscriptions
  for each row execute function public.fn__stamp_subscription_stops();

-- The moment this school stops (or stopped) being allowed to write: suspended
-- by us, cancelled, its lock day, or the end of the period it asked to leave at
-- (or the moment it asked, if that was later: a school in its grace days was
-- still writing until then). In the future for a school that may write today,
-- which is where a lease ends; in the past for a stopped one, which is what
-- work handed in late is measured against. A school cancelled before 0157
-- recorded no time and counts as stopped since ever. NULL when there is
-- nothing to measure by.
create or replace function public.fn__writes_end_at(p_school_id uuid)
returns timestamptz
language sql
stable
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
  select least(s.suspended_at,
               case when s.status = 'cancelled' then coalesce(s.cancelled_at, '-infinity'::timestamptz) end,
               public.fn__lock_day(s.school_id)::timestamptz,
               case when s.cancel_at_period_end
                         and greatest(s.period_end, s.trial_ends_on) is not null
                    then greatest((greatest(s.period_end, s.trial_ends_on) + 1)::timestamptz,
                                  coalesce(s.cancel_requested_at, '-infinity'::timestamptz)) end)
    from public.subscriptions s
   where s.school_id = p_school_id;
$$;
revoke all on function public.fn__writes_end_at(uuid) from public, anon, authenticated;

-- The oldest app that may still connect. Raised when a release changes what a
-- command means; an older app is told to update rather than send something the
-- server would read differently.
create or replace function public.fn__min_app_version()
returns text
language sql
immutable
set search_path = public
as $$ select '1.0.0'::text $$;
revoke all on function public.fn__min_app_version() from public, anon, authenticated;


-- -----------------------------------------------------------------------------
-- 4. THE SCREENS' OWN FUNCTIONS, TOLD WHAT THE DEVICE ALREADY DID
--
-- An offline payment or admission goes through fn_record_payment,
-- fn_record_family_payment and fn_admit_student themselves, not a copy, so
-- every rule they hold applies offline too. They keep their parameters and
-- answers. What an offline command adds (the receipt number the device
-- printed, when the money was taken, the pupil id the device made) reaches
-- them as transaction-local settings that fn__offline_apply_one sets for one
-- command, after checking them, and clears. payments.created_at is the date
-- every report files a payment under, so a fee taken on Monday and handed in
-- on Thursday is Monday's.
--
-- Why settings and not new parameters or a shared core: a function's
-- parameters never change here, and bundles schools have already pasted
-- (7 is frozen and never edited again, 34 is not) re-check fn_admit_student
-- by its text when pasted a second time, and roll back whole when they do not
-- find what they look for. The bodies stay whole so they keep finding it.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_record_payment(p_student_id uuid, p_amount numeric, p_method payment_method, p_note text DEFAULT NULL::text, p_pending boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_actor   uuid := auth.uid();
  v_receipt bigint;
  v_pay     uuid;
  v_family  uuid;
  v_left    numeric;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to record payments';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  perform public.assert_own('students', p_student_id);

  select family_id into v_family from public.students where id = p_student_id;


  -- 0157. A payment taken offline and handed in later: fn_offline_apply sets
  -- the receipt the device printed (checked as the device's own and unused)
  -- and when the money was taken, for that one command. Empty on every other
  -- call, which is then exactly what it was.
  v_receipt := coalesce(nullif(current_setting('app.offline_receipt_no', true), '')::bigint, public.next_counter('receipt'));
  insert into public.payments(student_id, family_id, amount, method, receipt_no,
                              status, received_by, note, created_at)
  values (p_student_id, v_family, p_amount, p_method, v_receipt,
          case when p_pending then 'pending' else 'verified' end, v_actor, p_note,
          coalesce(nullif(current_setting('app.offline_at', true), '')::timestamptz, now()))
  returning id into v_pay;

  if p_pending then
    return jsonb_build_object('payment_id', v_pay, 'receipt_no', v_receipt,
      'allocated', 0, 'unallocated', p_amount, 'pending', true);
  end if;

  v_left := public.fn__allocate_payment(v_pay, array[p_student_id], p_amount);

  return jsonb_build_object(
    'payment_id', v_pay, 'receipt_no', v_receipt,
    'allocated', p_amount - v_left, 'unallocated', v_left, 'pending', false,
    'applied', public.fn__payment_applied(v_pay));
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_record_family_payment(p_family_id uuid, p_amount numeric, p_method payment_method, p_note text DEFAULT NULL::text, p_pending boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_actor    uuid := auth.uid();
  v_receipt  bigint;
  v_pay      uuid;
  v_students uuid[];
  v_left     numeric;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to record payments';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  perform public.assert_own('families', p_family_id);

  select array_agg(id) into v_students from public.students where family_id = p_family_id;
  if v_students is null then raise exception 'This family has no students'; end if;


  -- 0157. A payment taken offline and handed in later: fn_offline_apply sets
  -- the receipt the device printed (checked as the device's own and unused)
  -- and when the money was taken, for that one command. Empty on every other
  -- call, which is then exactly what it was.
  v_receipt := coalesce(nullif(current_setting('app.offline_receipt_no', true), '')::bigint, public.next_counter('receipt'));
  insert into public.payments(family_id, student_id, amount, method, receipt_no,
                              status, received_by, note, created_at)
  values (p_family_id, null, p_amount, p_method, v_receipt,
          case when p_pending then 'pending' else 'verified' end, v_actor, p_note,
          coalesce(nullif(current_setting('app.offline_at', true), '')::timestamptz, now()))
  returning id into v_pay;

  if p_pending then
    return jsonb_build_object('payment_id', v_pay, 'receipt_no', v_receipt,
      'allocated', 0, 'credit', 0, 'pending', true);
  end if;

  v_left := public.fn__allocate_payment(v_pay, v_students, p_amount);

  return jsonb_build_object(
    'payment_id', v_pay, 'receipt_no', v_receipt,
    'allocated', p_amount - v_left,
    'credit', v_left,
    'family_outstanding', public.family_outstanding(p_family_id),
    'applied', public.fn__payment_applied(v_pay),
    'pending', false);
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_admit_student(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'Asia/Karachi'
AS $function$
declare
  v_actor   uuid := auth.uid();
  v_prefix  text;
  v_counter bigint;
  v_gr      text;
  v_student uuid;
  v_enroll  uuid;
  v_session uuid := nullif(p->>'session_id','')::uuid;
  v_class   uuid := nullif(p->>'class_id','')::uuid;
  v_section uuid := nullif(p->>'section_id','')::uuid;
  v_roll    text := nullif(p->>'roll_no','');
  v_gr_in   text := nullif(btrim(coalesce(p->>'gr_no','')), '');
  v_draft   boolean := false;
  v_next    int;
  v_g       jsonb := p->'guardian';
  v_link    jsonb;
  v_af      jsonb := p->'admission_fee';
  v_af_amt  numeric := 0;
  v_af_head uuid;
  v_af_inv  uuid;
  v_af_pay  uuid;
  v_receipt bigint;
  v_af_receipt bigint := null;
  v_af_recorded numeric := null;
  -- family resolution
  v_father_cnic text := nullif(btrim(coalesce(p->>'father_cnic','')), '');
  v_sibling  uuid;
  v_family   uuid;
  -- 0157. An admission taken offline and handed in later. fn_offline_apply
  -- sets these for that one command, after checking them: when it was made,
  -- the pupil id the device gave the child (so work taken offline for the
  -- new child can name them, and the same admission cannot make two
  -- children), and the receipt the device printed for the admission fee.
  -- A browser cannot set them, and on every other call they are empty and
  -- this is exactly what it was.
  v_at       timestamptz := coalesce(nullif(current_setting('app.offline_at', true), '')::timestamptz, now());
  v_day      date := (coalesce(nullif(current_setting('app.offline_at', true), '')::timestamptz, now()))::date;
  v_given_id uuid := nullif(current_setting('app.offline_student_id', true), '')::uuid;
  v_given_receipt bigint := nullif(current_setting('app.offline_receipt_no', true), '')::bigint;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to admit students';
  end if;
  if nullif(p->>'full_name','') is null then raise exception 'Student name is required'; end if;
  if v_session is null then raise exception 'Academic session is required'; end if;
  if v_class   is null then raise exception 'Class is required'; end if;

  -- The ids arrive inside the jsonb payload, so they need checking just like a
  -- named uuid parameter would.
  perform public.assert_own('academic_sessions', v_session);
  perform public.assert_own('classes', v_class);
  perform public.assert_own('sections', v_section);

  -- THE PLAN'S LIMIT (0128). After the tenant checks so a crafted
  -- payload cannot use this as an oracle, and before the first write so a
  -- refusal leaves nothing behind. This is the only function in the schema
  -- that inserts a pupil: fn_enquiry_admit and fn_import_students both
  -- come through here, which is why the gate is here and not in three
  -- places.
  perform public.fn__assert_room_for_students(public.current_school_id(), 1);

  -- ---- family: (a) an explicit sibling link ----
  -- Take the first link that names a student we own. assert_own is what stops a
  -- crafted payload reaching into another school's family through this path.
  if p->'links' is not null and jsonb_typeof(p->'links') = 'array' then
    for v_link in select * from jsonb_array_elements(p->'links') loop
      if v_sibling is null and nullif(v_link->>'related_student_id','') is not null then
        v_sibling := nullif(v_link->>'related_student_id','')::uuid;
        perform public.assert_own('students', v_sibling);
        select family_id into v_family from public.students where id = v_sibling;
      end if;
    end loop;
  end if;

  if v_family is not null and v_father_cnic is not null then
    -- Stamp the CNIC on the sibling's family so the NEXT admission finds it by
    -- CNIC without needing the checkbox. Left as a no-op if that CNIC is
    -- already on another family: the unique index would reject it, and a
    -- conflict here means the data needs a human, not a failed admission.
    update public.families set head_cnic = v_father_cnic
    where id = v_family
      and head_cnic is null
      and not exists (
        select 1 from public.families f2
        where f2.school_id = public.current_school_id()
          and f2.head_cnic = v_father_cnic
      );
  end if;

  -- ---- family: (b) the father's CNIC ----
  if v_family is null and v_father_cnic is not null then
    v_family := public.fn_family_for(
      nullif(p->>'father_name',''), v_father_cnic,
      nullif(p->>'phone',''), nullif(p->>'whatsapp',''));
  end if;

  -- ---- (c) v_family stays null, so the trigger makes a private one ----

  -- ---- the GR number (0142) ----
  -- next_counter has always been atomic, so two clerks adding at the same moment
  -- could never take the same number. That was not the hole. The hole is a
  -- school that typed GR 0001 to 0400 BY HAND and then leaves the box blank: the
  -- counter is still at zero, hands back 0001, and the insert dies on
  -- students_gr_no_school_key with a Postgres constraint name on the screen.
  if v_gr_in is not null then
    v_gr := v_gr_in;
    if exists (select 1 from public.students
                where school_id = public.current_school_id() and gr_no = v_gr) then
      raise exception 'GR number % is already used by another student in this '
        'school. Leave it blank to have one allotted.', v_gr
        using errcode = '23505';
    end if;
    -- The counter must never hand this number back later.
    perform public.fn__gr_high_water(v_gr);
  else
    v_gr := public.fn__next_gr();
  end if;

  insert into public.students(
    id, gr_no, admission_no, full_name, father_name, mother_name, b_form, dob, gender,
    address, phone, whatsapp, status, admission_date, notes, family_id)
  values (
    coalesce(v_given_id, gen_random_uuid()),
    v_gr,
    -- btrim on every text field (0142). A name typed off a register arrives
    -- with a trailing space often enough to matter, and " Bilal" sorts before
    -- every other name on the roster and is not found by a search for "Bilal".
    nullif(btrim(coalesce(p->>'admission_no','')), ''),
    btrim(p->>'full_name'),
    nullif(btrim(coalesce(p->>'father_name','')), ''),
    nullif(btrim(coalesce(p->>'mother_name','')), ''),
    nullif(btrim(coalesce(p->>'b_form','')), ''),
    nullif(p->>'dob','')::date,
    nullif(p->>'gender','')::public.gender,
    nullif(btrim(coalesce(p->>'address','')), ''),
    nullif(btrim(coalesce(p->>'phone','')), ''),
    nullif(btrim(coalesce(p->>'whatsapp','')), ''),
    'active',
    coalesce(nullif(p->>'admission_date','')::date, v_day),
    nullif(btrim(coalesce(p->>'notes','')), ''),
    v_family)
  returning id into v_student;

  -- Whatever the family ended up being (resolved above or created by the
  -- trigger), read it back so the admission-fee payment can be stamped with it.
  -- is_draft comes back with it (0142): trg_students_draft decides that from
  -- the record as it actually landed, and returning the value that went IN would
  -- tell the caller a name-and-roll-only child is a complete record, which is
  -- the one thing the flag exists to say.
  select family_id, is_draft into v_family, v_draft
    from public.students where id = v_student;

  if v_roll is null then
    select coalesce(max(nullif(regexp_replace(coalesce(roll_no,''), '[^0-9]', '', 'g'), '')::int), 0) + 1
    into v_next
    from public.enrollments
    where session_id = v_session and class_id = v_class and section_id is not distinct from v_section;
    v_roll := v_next::text;
  end if;

  insert into public.enrollments(student_id, session_id, class_id, section_id, roll_no, status)
  values (v_student, v_session, v_class, v_section, v_roll, 'active')
  returning id into v_enroll;

  -- optional primary guardian (kept for callers that still send one; the web
  -- admission form now relies on father/mother + the student contact number)
  if v_g is not null and jsonb_typeof(v_g) = 'object' and nullif(v_g->>'name','') is not null then
    insert into public.guardians(student_id, name, relation, phone, whatsapp, is_primary)
    values (v_student, v_g->>'name', nullif(v_g->>'relation',''), nullif(v_g->>'phone',''),
            nullif(v_g->>'whatsapp',''), true);
  end if;

  -- optional family links (sibling / relative already in the school)
  if p->'links' is not null and jsonb_typeof(p->'links') = 'array' then
    for v_link in select * from jsonb_array_elements(p->'links') loop
      if nullif(v_link->>'related_student_id','') is not null
         and nullif(v_link->>'related_student_id','')::uuid <> v_student then
        -- Every link, not only the first one the family was taken from: a
        -- crafted payload could otherwise tie this child to another school's
        -- pupil (0157).
        perform public.assert_own('students', nullif(v_link->>'related_student_id','')::uuid);
        insert into public.student_links(student_id, related_student_id, relation, created_by)
        values (v_student, nullif(v_link->>'related_student_id','')::uuid,
                nullif(v_link->>'relation',''), v_actor)
        on conflict (student_id, related_student_id) do nothing;
      end if;
    end loop;
  end if;

  -- optional admission fee → a real one-off invoice (+ receipt when an amount
  -- is given). period_month is null so it never appears in the monthly list.
  if v_af is not null and jsonb_typeof(v_af) = 'object' and (v_af->>'charged')::boolean is true then
    v_af_amt := coalesce(nullif(v_af->>'amount','')::numeric, 0);
    if v_af_amt < 0 then raise exception 'Admission fee cannot be negative'; end if;

    select id into v_af_head from public.fee_heads where type = 'admission' and active and school_id = public.current_school_id()
      order by sort_order limit 1;
    if v_af_head is null then
      insert into public.fee_heads(name, type, is_recurring, sort_order)
      values ('Admission Fee', 'admission', false, 20) returning id into v_af_head;
    end if;

    insert into public.invoices(student_id, enrollment_id, session_id, period_month, status,
        arrears_brought_forward, due_date, issued_at, created_by, notes)
    values (v_student, v_enroll, v_session, null, 'issued', 0, v_day, v_at, v_actor, 'Admission fee')
    returning id into v_af_inv;

    insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
    values (v_af_inv, v_af_head, 'Admission Fee', v_af_amt, false);

    if v_af_amt > 0 then
      v_af_receipt := coalesce(v_given_receipt, public.next_counter('receipt'));
      -- family_id stamped so the admission fee shows on the family sheet like
      -- any other payment. Before 0036 this was left null.
      insert into public.payments(student_id, family_id, amount, method, receipt_no, status, received_by, note, created_at)
      values (v_student, v_family, v_af_amt, 'cash', v_af_receipt, 'verified', v_actor,
              concat_ws(' ', 'Admission fee', nullif(current_setting('app.offline_receipt_note', true), '')), v_at)
      returning id into v_af_pay;
      insert into public.payment_allocations(payment_id, invoice_id, amount)
      values (v_af_pay, v_af_inv, v_af_amt);
      v_af_recorded := v_af_amt;
    end if;
    -- either way, nothing is left owing for the admission fee line
    update public.invoices set status = 'paid' where id = v_af_inv;
  end if;

  return jsonb_build_object(
    'student_id', v_student, 'enrollment_id', v_enroll, 'gr_no', v_gr, 'roll_no', v_roll,
    'family_id', v_family, 'is_draft', v_draft,
    'admission_fee_amount', v_af_recorded, 'admission_receipt_no', v_af_receipt);
end;
$function$;


-- -----------------------------------------------------------------------------
-- 5. HELLO
--
-- Called by the app whenever it connects, before it sends anything. Registers
-- the device, gives it the server's clock and its lease, and gives a device that
-- collects fees its receipt numbers. p_receipt_next is the next number the
-- device would print, which is how the server knows a block is used up.
-- -----------------------------------------------------------------------------
create or replace function public.fn_sync_hello(
  p_device_id    uuid,
  p_platform     text default 'web',
  p_app_version  text default null,
  p_receipt_next bigint default null)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  v_school   uuid := public.current_school_id();
  v_user     uuid := auth.uid();
  v_role     public.user_role;
  v_platform text := lower(btrim(coalesce(p_platform, 'web')));
  v_status   public.subscription_status;
  v_dev      public.sync_devices%rowtype;
  v_can      boolean;
  v_until    timestamptz;
  v_lease    public.sync_leases%rowtype;
  v_open     integer;
  v_left     bigint;
  v_last     bigint;
  v_blocks   jsonb := '[]'::jsonb;
  v_off      uuid;
begin
  if p_device_id is null then
    raise exception 'The app did not say which device this is. Update the app and try again.'
      using errcode = '22023';
  end if;
  if v_user is null then
    raise exception 'This login is not active in a school. Ask the school office to switch it back on.'
      using errcode = '42501';
  end if;
  -- A LOGIN SWITCHED OFF WHILE ITS DEVICE HELD WORK. The staff-exit flow sets
  -- profiles.active = false, and money taken before that must not vanish with
  -- the login. Its device is told it is revoked, which makes the app hand in
  -- everything it holds and then forget it; fn__offline_apply_one keeps each
  -- entry for the owner (login_off). Only a device this login has used here,
  -- and only a role that could have made the work.
  if v_school is null then
    select p.school_id, p.role into v_off, v_role
      from public.profiles p
     where p.id = v_user and not p.active and p.school_id is not null;
    if v_off is not null
       and v_role in ('owner', 'principal', 'admin_clerk', 'accountant', 'class_teacher', 'subject_teacher')
       and exists (select 1 from public.sync_devices d
                    where d.school_id = v_off and d.device_id = p_device_id and d.user_id = v_user) then
      return jsonb_build_object('server_time', now(), 'status', null, 'role', v_role,
        'can_write', false, 'revoked', true, 'login_off', true, 'lease_until', null,
        'receipt_blocks', '[]'::jsonb, 'command_version', 1,
        'min_app_version', public.fn__min_app_version());
    end if;
    raise exception 'This login is not active in a school. Ask the school office to switch it back on.'
      using errcode = '42501';
  end if;
  if v_platform not in ('web', 'android', 'windows') then
    v_platform := 'other';
  end if;
  v_status := public.fn_effective_status(v_school);

  -- A login with a role in this school that enters work. Without one (the
  -- vendor on a support visit, a parent, the observer) there is the clock and
  -- nothing to keep: no device is recorded, so nothing it sends can fill the
  -- owner's list of refused work.
  select p.role into v_role from public.profiles p
   where p.id = v_user and p.active and p.school_id = v_school;
  if v_role is null
     or v_role not in ('owner', 'principal', 'admin_clerk', 'accountant', 'class_teacher', 'subject_teacher') then
    return jsonb_build_object('server_time', now(), 'status', v_status, 'role', v_role,
      'can_write', false, 'revoked', false, 'lease_until', null,
      'receipt_blocks', '[]'::jsonb, 'command_version', 1,
      'min_app_version', public.fn__min_app_version());
  end if;

  -- A device id is the app's own choice, so any limit counted per device counts
  -- whatever the caller makes up. Twenty new devices a day for one login is far
  -- beyond a school's need and stops a script registering thousands.
  if not exists (select 1 from public.sync_devices d
                  where d.school_id = v_school and d.device_id = p_device_id and d.user_id = v_user)
     and (select count(*) from public.sync_devices d
           where d.school_id = v_school and d.user_id = v_user
             and d.first_seen > now() - interval '1 day') >= 20 then
    raise exception 'Too many new devices have connected with this login today. Try again '
      'tomorrow, or ask the school office.'
      using errcode = '54000';
  end if;

  insert into public.sync_devices (school_id, device_id, user_id, platform, app_version)
  values (v_school, p_device_id, v_user, v_platform, left(nullif(btrim(p_app_version), ''), 40))
  on conflict (school_id, device_id, user_id) do update
     set last_seen = now(), platform = excluded.platform, app_version = excluded.app_version
  returning * into v_dev;

  v_can := v_dev.revoked_at is null
           and v_status not in ('locked', 'cancelled')
           and v_role in ('owner', 'principal', 'admin_clerk', 'accountant',
                          'class_teacher', 'subject_teacher');

  -- Seven days from now, never past the moment the school stops being allowed
  -- to write. A lease is only ever lengthened here, never cut: the answer to
  -- this hello can be lost on a weak signal, and a device that never heard its
  -- lease was cut would go on working on the old one, and see that work refused
  -- for good. A device that may not write gets no new lease and is told so, and
  -- anything it makes after the school stopped is held by the stop itself
  -- (fn__offline_apply_one), not by the lease.
  if v_can then
    v_until := greatest(now(), least(now() + interval '7 days',
                                     coalesce(public.fn__writes_end_at(v_school), 'infinity'::timestamptz)));
    select * into v_lease from public.sync_leases
     where school_id = v_school and device_id = p_device_id and user_id = v_user
     order by from_at desc
     limit 1
     for update;
    if found and v_lease.until_at >= now() - interval '10 minutes' then
      update public.sync_leases set until_at = greatest(v_lease.until_at, v_until)
       where id = v_lease.id and school_id = v_school;
    else
      insert into public.sync_leases (school_id, device_id, user_id, from_at, until_at)
      values (v_school, p_device_id, v_user, now(), v_until);
    end if;
  end if;

  -- Receipt numbers, for the roles that take money.
  if v_can and v_role in ('owner', 'principal', 'admin_clerk', 'accountant') then
    if p_receipt_next is not null then
      update public.receipt_blocks set closed_at = now(), closed_reason = 'used'
       where school_id = v_school and device_id = p_device_id and user_id = v_user
         and closed_at is null and last_no < p_receipt_next;
    end if;
    select count(*),
           coalesce(sum(last_no - greatest(first_no, coalesce(p_receipt_next, first_no)) + 1), 0)
      into v_open, v_left
      from public.receipt_blocks
     where school_id = v_school and device_id = p_device_id and user_id = v_user
       and closed_at is null;
    -- Two hundred at a time, topped up below a hundred, two blocks at most on a
    -- device, and per LOGIN six open and ten a day at most. Per login, because
    -- the device id is the caller's to invent: counted per device, a script
    -- inventing ids ran the counter up by 200 a call. The numbers come off the
    -- same counter the server uses, so a number printed offline is one the
    -- server will never print.
    if v_open < 2 and v_left < 100
       and (select count(*) from public.receipt_blocks
             where school_id = v_school and user_id = v_user
               and issued_at > now() - interval '1 day') < 10
       and (select count(*) from public.receipt_blocks
             where school_id = v_school and user_id = v_user and closed_at is null) < 6 then
      insert into public.counters (school_id, key, value) values (v_school, 'receipt', 200)
      on conflict (school_id, key) do update set value = public.counters.value + 200
      returning value into v_last;
      insert into public.receipt_blocks (school_id, device_id, user_id, first_no, last_no)
      values (v_school, p_device_id, v_user, v_last - 199, v_last);
    end if;
    select coalesce(jsonb_agg(jsonb_build_object('first_no', b.first_no, 'last_no', b.last_no)
                              order by b.first_no), '[]'::jsonb)
      into v_blocks
      from public.receipt_blocks b
     where b.school_id = v_school and b.device_id = p_device_id and b.user_id = v_user
       and b.closed_at is null;
  end if;

  -- Housekeeping, a little at a time. After 180 days an applied command nobody
  -- needs to see keeps only its id: a copy of it sent again (a phone found in a
  -- drawer) is still answered "applied", never "not saved", which would invite
  -- somebody to enter the money twice. After two years the id goes too, along
  -- with anything the owner has dealt with; a command that old is refused for
  -- its age before its id is looked up, so it still cannot apply twice.
  update public.client_commands c set payload = null, result = null
   where c.id in (select c2.id from public.client_commands c2
                   where c2.school_id = v_school and c2.status = 'applied' and c2.flags = '{}'
                     and c2.received_at < now() - interval '180 days'
                     and (c2.payload is not null or c2.result is not null)
                   limit 500);
  delete from public.client_commands c
   where c.id in (select c2.id from public.client_commands c2
                   where c2.school_id = v_school
                     and c2.received_at < now() - interval '730 days'
                     and (c2.status = 'applied' or c2.reviewed_at is not null)
                   limit 500);

  return jsonb_build_object(
    'server_time', now(),
    'status', v_status,
    'role', v_role,
    'can_write', v_can,
    'revoked', v_dev.revoked_at is not null,
    'lease_until', case when v_can then v_until end,
    'receipt_blocks', v_blocks,
    'command_version', 1,
    'min_app_version', public.fn__min_app_version());
end;
$$;


-- -----------------------------------------------------------------------------
-- 6. HANDING IN THE WORK
-- -----------------------------------------------------------------------------

-- A refusal is kept with what was sent (unless it is too big to keep), so the
-- owner can see it and nobody has to remember it.
create or replace function public.fn__offline_reject(
  p_id uuid, p_school uuid, p_user uuid, p_device uuid, p_type text,
  p_at timestamptz, p_payload jsonb, p_code text, p_error text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.client_commands
    (id, school_id, user_id, device_id, type, occurred_at, status, payload, error, error_code)
  values (p_id, p_school, p_user, p_device, left(coalesce(nullif(p_type, ''), 'unknown'), 40),
          p_at, 'rejected',
          case when octet_length(coalesce(p_payload, 'null'::jsonb)::text) <= 65536 then p_payload end,
          left(p_error, 1000), p_code);
  return jsonb_build_object('id', p_id, 'status', 'rejected', 'code', p_code, 'error', p_error);
end;
$$;
revoke all on function public.fn__offline_reject(uuid, uuid, uuid, uuid, text, timestamptz, jsonb, text, text)
  from public, anon, authenticated;

-- One command. Answers applied, rejected (final, kept) or deferred (not kept:
-- the device holds on to it and sends it again later).
create or replace function public.fn__offline_apply_one(
  p_school uuid, p_user uuid, p_device uuid, p_cmd jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  v_id      uuid;
  v_type    text;
  v_at      timestamptz;
  v_p       jsonb;
  v_ver     text;
  v_prev    public.client_commands%rowtype;
  v_dev     public.sync_devices%rowtype;
  v_bypass  boolean := false;
  v_res     jsonb;
  v_flags   text[] := '{}';
  v_keep    jsonb;
  v_newer   jsonb;
  v_rno     bigint;
  v_printed bigint;
  v_payer   uuid;
  v_family  boolean;
  v_amount  numeric;
  v_note    text;
  v_dup     record;
  v_state   text;
  v_err     text;
  v_hint    text;
  v_end     timestamptz;
  v_day     date;
  v_out     jsonb;
  v_cleared uuid[];
  v_office  boolean;
  v_session uuid;
  v_class   uuid;
  v_subject uuid;
  v_stream  public.subjects.stream%type;
  v_adm     jsonb;
  v_gr      text;
  v_cons    text;
  v_raced   text;
begin
  -- Without an id nothing can be kept or answered twice.
  if jsonb_typeof(p_cmd) is distinct from 'object' then
    return jsonb_build_object('id', null, 'status', 'rejected', 'code', 'bad_command',
      'error', 'This entry could not be read, so it was not saved.');
  end if;
  begin
    v_id := nullif(p_cmd->>'id', '')::uuid;
  exception when others then
    v_id := null;
  end;
  if v_id is null then
    return jsonb_build_object('id', p_cmd->'id', 'status', 'rejected', 'code', 'bad_command',
      'error', 'This entry could not be read, so it was not saved.');
  end if;

  -- One at a time per id, then: has it been here before?
  perform pg_advisory_xact_lock(hashtextextended('client_command:' || v_id::text, 0));
  select * into v_prev from public.client_commands where id = v_id;
  if found then
    if v_prev.school_id <> p_school or v_prev.user_id <> p_user then
      return jsonb_build_object('id', v_id, 'status', 'rejected', 'code', 'id_taken',
        'error', 'This entry could not be saved because its id is already taken.');
    end if;
    return jsonb_build_object('id', v_id, 'status', v_prev.status, 'repeat', true,
      'result', v_prev.result, 'flags', to_jsonb(v_prev.flags),
      'code', v_prev.error_code, 'error', v_prev.error);
  end if;

  v_type := p_cmd->>'type';
  v_p    := p_cmd->'payload';
  v_ver  := p_cmd->>'v';
  begin
    v_at := (p_cmd->>'occurred_at')::timestamptz;
  exception when others then
    v_at := null;
  end;

  select * into v_dev from public.sync_devices
   where school_id = p_school and device_id = p_device and user_id = p_user;
  if not found then
    return jsonb_build_object('id', v_id, 'status', 'deferred', 'code', 'device_unknown',
      'error', 'This device has to connect again before it can send its work.');
  end if;
  if v_dev.revoked_at is not null then
    return public.fn__offline_reject(v_id, p_school, p_user, p_device, v_type, v_at, v_p,
      'device_revoked', 'This device was switched off by the school, so this was not saved. '
      || 'The owner can see it under offline work.');
  end if;
  -- A login switched off since the work was made (the staff-exit flow): kept for
  -- the owner like a switched-off device's work, never applied. After the id
  -- lookup, so an entry that did go in is still answered "applied".
  if not exists (select 1 from public.profiles p
                  where p.id = p_user and p.active and p.school_id = p_school) then
    return public.fn__offline_reject(v_id, p_school, p_user, p_device, v_type, v_at, v_p,
      'login_off', 'This login was switched off by the school, so this was not saved. '
      || 'The owner can see it under offline work.');
  end if;

  if v_ver is distinct from '1' then
    if v_ver ~ '^[0-9]{1,6}$' and v_ver::integer > 1 then
      return jsonb_build_object('id', v_id, 'status', 'deferred', 'code', 'server_behind',
        'error', 'This was made by a newer version of the app than the server understands yet. '
          || 'It is kept on this device and will be sent once the server is updated.');
    end if;
    return public.fn__offline_reject(v_id, p_school, p_user, p_device, v_type, v_at, v_p,
      'bad_command', 'This entry could not be read, so it was not saved.');
  end if;
  if v_type is null or v_type not in ('attendance.day', 'attendance.subject', 'marks.exam',
                                      'marks.test', 'fees.payment', 'fees.family_payment',
                                      'expenses.record', 'students.admit') then
    return public.fn__offline_reject(v_id, p_school, p_user, p_device, v_type, v_at, v_p,
      'bad_command', 'The server does not know this kind of entry, so it was not saved.');
  end if;
  if jsonb_typeof(v_p) is distinct from 'object' or v_at is null then
    return public.fn__offline_reject(v_id, p_school, p_user, p_device, v_type, v_at, v_p,
      'bad_command', 'This entry could not be read, so it was not saved.');
  end if;
  if octet_length(v_p::text) > 65536 then
    return public.fn__offline_reject(v_id, p_school, p_user, p_device, v_type, v_at, null,
      'too_large', 'This entry is too large to save. Enter it again in smaller parts.');
  end if;

  -- When it was made. The device keeps its clock to the server's, so a time
  -- ahead of the server is a device whose clock was changed.
  if v_at > now() + interval '10 minutes' then
    return public.fn__offline_reject(v_id, p_school, p_user, p_device, v_type, v_at, v_p,
      'clock_ahead', 'This entry is dated in the future, so it was not saved. Check the date '
      || 'and time on this device.');
  end if;
  if v_at < now() - interval '120 days' then
    return public.fn__offline_reject(v_id, p_school, p_user, p_device, v_type, v_at, v_p,
      'too_old', 'This entry is more than 120 days old, so it was not saved now. If it was '
      || 'sent before, the school may already have it: check before entering it again.');
  end if;
  if not exists (select 1 from public.sync_leases l
                  where l.school_id = p_school and l.device_id = p_device and l.user_id = p_user
                    and v_at between l.from_at - interval '10 minutes'
                                 and l.until_at + interval '10 minutes') then
    return public.fn__offline_reject(v_id, p_school, p_user, p_device, v_type, v_at, v_p,
      'outside_lease', 'This was made after the device had been offline longer than it is '
      || 'allowed to be, so it was not saved.');
  end if;

  -- A locked school: work made while it was allowed to write goes in, if it
  -- arrives within a week of the stop (a device's lease is a week, so a device
  -- holding such work has had that long to hand it in). The window is what
  -- stops a locked school writing on by dating new commands just before its
  -- lock: the time a command says it was made cannot be proved, so how long
  -- after the stop that claim is believed is kept short. Anything made after
  -- the stop, or arriving later than the window, waits on the device for the
  -- renewal and goes in then. Nothing is refused for it.
  if public.fn_effective_status(p_school) in ('locked', 'cancelled') then
    v_end := coalesce(public.fn__writes_end_at(p_school), '-infinity'::timestamptz);
    if v_at < v_end and now() < v_end + interval '7 days' then
      v_bypass := true;
    else
      return jsonb_build_object('id', v_id, 'status', 'deferred', 'code', 'school_locked',
        'error', 'The school''s subscription has ended. This is kept on this device and will '
          || 'be sent when it is renewed.');
    end if;
  end if;

  begin
    -- Never later than now: a device clock a few minutes fast must not put a
    -- payment taken at 23:55 into tomorrow's cash book.
    perform set_config('app.offline_at', least(v_at, now())::text, true);
    perform set_config('app.offline_kept', '', true);
    if v_bypass then
      perform set_config('app.offline_replay', 'on', true);
    end if;

    if v_type in ('attendance.day', 'attendance.subject', 'marks.exam', 'marks.test')
       and jsonb_typeof(v_p->'marks') is distinct from 'array' then
      raise exception 'This entry has no list of pupils.' using errcode = '22023';
    end if;

    -- THE DAY IT IS FOR CANNOT BE AFTER THE DAY IT WAS MADE. A register for
    -- Thursday cannot have been marked on Monday, and an expense or admission
    -- dated after its command was made says the time on the command is not
    -- true. That is also what a locked school would send to write on past its
    -- lock, with today's date inside a command dated before it.
    v_day := case v_type
               when 'attendance.day' then nullif(v_p->>'date', '')::date
               when 'attendance.subject' then nullif(v_p->>'date', '')::date
               when 'expenses.record' then nullif(v_p->>'spent_on', '')::date
               when 'students.admit' then nullif(v_p->'admission'->>'admission_date', '')::date
               when 'marks.test' then (select a.assessment_date from public.assessments a
                                        where a.id = nullif(v_p->>'assessment_id', '')::uuid
                                          and a.school_id = p_school)
             end;
    if v_day is not null and v_day > v_at::date then
      raise exception 'This is dated % but was made on %, which cannot be right, so it was not '
        'saved. Check the date and time on this device.',
        to_char(v_day, 'DD Mon YYYY'), to_char(v_at::date, 'DD Mon YYYY')
        using errcode = '22008', hint = 'offline:bad_date';
    end if;

    -- REGISTERS AND MARKS. Two kinds of entry are left out and the rest goes in:
    --   * a pupil whose entry was decided later, on another device or on the
    --     screen (kept_newer), including a mark cleared later, which leaves no
    --     row to compare with but does leave its deletion in the audit log;
    --   * a pupil no longer on this register or sheet, or no longer this
    --     login's to mark: left, moved section, enrolment gone (left_out). The
    --     screen's function refuses a whole sheet for one such pupil, which
    --     for work made days ago would refuse the whole day's work for good.
    -- Each test below is the screen function's own, so what is left out here is
    -- exactly what it would refuse. If nothing at all can go in for that
    -- reason, the entry is refused, so it is seen rather than quietly empty.
    if v_type in ('attendance.day', 'attendance.subject', 'marks.exam', 'marks.test') then
      if v_type = 'attendance.day' then
        v_office := public.has_role('owner');
        select coalesce(jsonb_agg(q.e) filter (where q.ok and not q.newer), '[]'::jsonb),
               coalesce(jsonb_agg(q.e->'enrollment_id') filter (where q.ok and q.newer), '[]'::jsonb),
               coalesce(jsonb_agg(q.e->'enrollment_id') filter (where not q.ok), '[]'::jsonb)
          into v_keep, v_newer, v_out
          from (select e,
                       exists (select 1 from public.enrollments en
                                where en.id = (e->>'enrollment_id')::uuid and en.school_id = p_school
                                  and (v_office
                                       or public.fn_may_manage_class(en.session_id, en.class_id, en.section_id))) as ok,
                       exists (select 1 from public.attendance_daily ad
                                where ad.school_id = p_school
                                  and ad.enrollment_id = (e->>'enrollment_id')::uuid
                                  and ad.attendance_date = (v_p->>'date')::date
                                  and coalesce(ad.authored_at, ad.updated_at) > v_at) as newer
                  from jsonb_array_elements(v_p->'marks') e) q;

      elsif v_type = 'attendance.subject' then
        select coalesce(jsonb_agg(q.e) filter (where q.ok and not q.newer), '[]'::jsonb),
               coalesce(jsonb_agg(q.e->'enrollment_id') filter (where q.ok and q.newer), '[]'::jsonb),
               coalesce(jsonb_agg(q.e->'enrollment_id') filter (where not q.ok), '[]'::jsonb)
          into v_keep, v_newer, v_out
          from (select e,
                       exists (select 1 from public.enrollments en
                                where en.id = (e->>'enrollment_id')::uuid and en.school_id = p_school
                                  and en.session_id = (v_p->>'session_id')::uuid
                                  and en.class_id = (v_p->>'class_id')::uuid
                                  and en.section_id is not distinct from nullif(v_p->>'section_id', '')::uuid) as ok,
                       exists (select 1 from public.attendance_subject sa
                                where sa.school_id = p_school
                                  and sa.enrollment_id = (e->>'enrollment_id')::uuid
                                  and sa.subject_id = (v_p->>'subject_id')::uuid
                                  and sa.attendance_date = (v_p->>'date')::date
                                  and coalesce(sa.authored_at, sa.updated_at) > v_at) as newer
                  from jsonb_array_elements(v_p->'marks') e) q;

      elsif v_type = 'marks.exam' then
        v_office := public.has_role('owner', 'principal', 'admin_clerk');
        select et.session_id, es.class_id, es.subject_id, sub.stream
          into v_session, v_class, v_subject, v_stream
          from public.exam_subjects es
          join public.exam_terms et on et.id = es.exam_term_id and et.school_id = p_school
          join public.subjects sub on sub.id = es.subject_id and sub.school_id = p_school
         where es.id = (v_p->>'exam_subject_id')::uuid and es.school_id = p_school;
        select coalesce(array_agg(distinct (al.before->>'enrollment_id')::uuid), '{}')
          into v_cleared
          from public.audit_log al
         where al.school_id = p_school and al.entity = 'mark_entries' and al.action = 'DELETE'
           and al.created_at > v_at
           and (al.before->>'exam_subject_id')::uuid = (v_p->>'exam_subject_id')::uuid;
        select coalesce(jsonb_agg(q.e) filter (where q.ok and not q.newer), '[]'::jsonb),
               coalesce(jsonb_agg(q.e->'enrollment_id') filter (where q.ok and q.newer), '[]'::jsonb),
               coalesce(jsonb_agg(q.e->'enrollment_id') filter (where not q.ok), '[]'::jsonb)
          into v_keep, v_newer, v_out
          from (select e,
                       -- No such paper: everything goes on, for the screen's own
                       -- function to refuse with its own words.
                       v_class is null or exists (
                         select 1
                           from public.enrollments en
                           join public.students s on s.id = en.student_id and s.school_id = p_school
                                                 and s.deleted_at is null
                          where en.id = (e->>'enrollment_id')::uuid and en.school_id = p_school
                            and en.session_id = v_session and en.class_id = v_class
                            and en.status in ('active', 'promoted', 'retained', 'graduated')
                            and public.fn_takes_subject(v_stream, en.stream)
                            and (v_office
                                 or public.fn_may_mark_subject(v_session, v_class, en.section_id, v_subject))) as ok,
                       exists (select 1 from public.mark_entries me
                                where me.school_id = p_school
                                  and me.exam_subject_id = (v_p->>'exam_subject_id')::uuid
                                  and me.enrollment_id = (e->>'enrollment_id')::uuid
                                  and coalesce(me.authored_at, me.updated_at) > v_at)
                       or (e->>'enrollment_id')::uuid = any(v_cleared) as newer
                  from jsonb_array_elements(v_p->'marks') e) q;

      else
        select coalesce(array_agg(distinct (al.before->>'enrollment_id')::uuid), '{}')
          into v_cleared
          from public.audit_log al
         where al.school_id = p_school and al.entity = 'mark_entries' and al.action = 'DELETE'
           and al.created_at > v_at
           and (al.before->>'assessment_id')::uuid = (v_p->>'assessment_id')::uuid;
        select coalesce(jsonb_agg(q.e) filter (where q.ok and not q.newer), '[]'::jsonb),
               coalesce(jsonb_agg(q.e->'enrollment_id') filter (where q.ok and q.newer), '[]'::jsonb),
               coalesce(jsonb_agg(q.e->'enrollment_id') filter (where not q.ok), '[]'::jsonb)
          into v_keep, v_newer, v_out
          from (select e,
                       exists (select 1 from public.enrollments en
                                where en.id = (e->>'enrollment_id')::uuid and en.school_id = p_school) as ok,
                       exists (select 1 from public.mark_entries me
                                where me.school_id = p_school
                                  and me.assessment_id = (v_p->>'assessment_id')::uuid
                                  and me.enrollment_id = (e->>'enrollment_id')::uuid
                                  and coalesce(me.authored_at, me.updated_at) > v_at)
                       or (e->>'enrollment_id')::uuid = any(v_cleared) as newer
                  from jsonb_array_elements(v_p->'marks') e) q;
      end if;

      if jsonb_array_length(v_out) > 0 and jsonb_array_length(v_keep) + jsonb_array_length(v_newer) = 0 then
        raise exception 'None of the pupils in this entry can be entered any more: they have left, '
          'moved to another section, or are no longer yours to mark. Nothing was saved.'
          using errcode = '22023', hint = 'offline:not_on_sheet';
      end if;

      if v_type = 'attendance.day' then
        v_res := public.fn_mark_attendance((v_p->>'date')::date, v_keep, v_p->>'reason');
      elsif v_type = 'attendance.subject' then
        v_res := public.fn_mark_subject_attendance(
          (v_p->>'session_id')::uuid, (v_p->>'class_id')::uuid,
          nullif(v_p->>'section_id', '')::uuid, (v_p->>'subject_id')::uuid,
          (v_p->>'date')::date, v_keep);
      elsif v_type = 'marks.exam' then
        v_res := public.fn_enter_marks((v_p->>'exam_subject_id')::uuid, v_keep, v_p->>'reason');
      else
        v_res := public.fn_enter_assessment_marks((v_p->>'assessment_id')::uuid, v_keep,
                                                  v_p->>'reason');
      end if;

    elsif v_type in ('fees.payment', 'fees.family_payment') then
      -- Who may take money is asked first, the same question fn_record_payment
      -- asks, so the receipt checks below cannot tell somebody who may not take
      -- money what has been paid.
      if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
        raise exception 'Not permitted to record payments' using errcode = '42501';
      end if;
      v_family := v_type = 'fees.family_payment';
      v_payer  := nullif(v_p->>(case when v_family then 'family_id' else 'student_id' end), '')::uuid;
      v_amount := (v_p->>'amount')::numeric;
      v_note   := nullif(btrim(coalesce(v_p->>'note', '')), '');
      v_rno    := nullif(v_p->>'receipt_no', '')::bigint;
      if v_payer is null then
        raise exception 'This payment does not say who paid.' using errcode = '22023';
      end if;
      if v_rno is not null then
        -- The same payment arriving twice under two ids is kept once: found by
        -- its number, or, when it was recorded under a number of the server's,
        -- by the printed number its note carries.
        if exists (select 1 from public.payments py
                    where py.school_id = p_school
                      and py.reversal_of is null and py.amount = v_amount
                      and (case when v_family then py.family_id = v_payer and py.student_id is null
                                else py.student_id = v_payer end)
                      and (py.receipt_no = v_rno
                           or py.note like '%' || format('(printed as receipt %s)', v_rno) || '%')) then
          raise exception 'Receipt % is already recorded for this payment, so it was not '
            'recorded twice.', v_rno
            using errcode = '23505', hint = 'offline:duplicate';
        end if;
        if exists (select 1 from public.payments py
                    where py.school_id = p_school and py.receipt_no = v_rno) then
          v_printed := v_rno;
        elsif not exists (select 1 from public.receipt_blocks b
                           where b.school_id = p_school and b.device_id = p_device
                             and b.user_id = p_user and v_rno between b.first_no and b.last_no) then
          v_printed := v_rno;
        end if;
        -- A number already used, or never given to this device: the money is
        -- still recorded, under a number of the server's, and flagged.
        if v_printed is not null then
          v_rno := null;
          v_flags := v_flags || 'receipt_renumbered'::text;
          v_note := concat_ws(' ', v_note, format('(printed as receipt %s)', v_printed));
        end if;
      end if;
      perform set_config('app.offline_receipt_no', coalesce(v_rno::text, ''), true);
      if v_family then
        v_res := public.fn_record_family_payment(v_payer, v_amount,
          coalesce(nullif(v_p->>'method', ''), 'cash')::public.payment_method,
          v_note, coalesce((v_p->>'pending')::boolean, false));
      else
        v_res := public.fn_record_payment(v_payer, v_amount,
          coalesce(nullif(v_p->>'method', ''), 'cash')::public.payment_method,
          v_note, coalesce((v_p->>'pending')::boolean, false));
      end if;

    elsif v_type = 'expenses.record' then
      v_res := public.fn_record_expense(
        (v_p->>'amount')::numeric,
        nullif(v_p->>'category_id', '')::uuid,
        coalesce(nullif(v_p->>'spent_on', '')::date, v_at::date),
        nullif(btrim(coalesce(v_p->>'payee', '')), ''),
        coalesce(nullif(v_p->>'method', ''), 'cash')::public.payment_method,
        nullif(btrim(coalesce(v_p->>'note', '')), ''));

    elsif v_type = 'students.admit' then
      -- fn_admit_student's own question, asked before the lookups below.
      if not public.has_role('owner', 'principal', 'admin_clerk') then
        raise exception 'Not permitted to admit students' using errcode = '42501';
      end if;
      v_payer := nullif(v_p->>'student_id', '')::uuid;
      if v_payer is null or jsonb_typeof(v_p->'admission') is distinct from 'object' then
        raise exception 'This admission could not be read.' using errcode = '22023';
      end if;
      v_adm := v_p->'admission';
      if exists (select 1 from public.students s where s.id = v_payer) then
        raise exception 'This pupil was already admitted, so they were not admitted twice.'
          using errcode = '23505', hint = 'offline:duplicate';
      end if;
      -- Two devices offline cannot see each other's admissions. The same child
      -- admitted on both would get two records and two sets of dues, and a
      -- pupil with dues can never be deleted, so a likely match is stopped here
      -- and the person decides. They can send it again with allow_duplicate.
      if not coalesce((v_p->>'allow_duplicate')::boolean, false) then
        select s.full_name, s.gr_no into v_dup
          from public.students s
         where s.school_id = p_school and s.deleted_at is null
           and ((nullif(regexp_replace(coalesce(v_p->'admission'->>'b_form', ''), '[^0-9]', '', 'g'), '')
                   is not null
                 and regexp_replace(coalesce(s.b_form, ''), '[^0-9]', '', 'g')
                     = regexp_replace(v_p->'admission'->>'b_form', '[^0-9]', '', 'g'))
             or (lower(btrim(s.full_name)) = lower(btrim(coalesce(v_p->'admission'->>'full_name', '')))
                 and nullif(btrim(coalesce(v_p->'admission'->>'father_name', '')), '') is not null
                 and lower(btrim(coalesce(s.father_name, '')))
                     = lower(btrim(v_p->'admission'->>'father_name'))
                 and (s.dob is null or nullif(v_p->'admission'->>'dob', '') is null
                      or s.dob = (v_p->'admission'->>'dob')::date)))
         order by s.created_at
         limit 1;
        if found then
          raise exception '% (GR %) looks like the same child, so this admission was not made. '
            'If they are different children, admit again and say so.', v_dup.full_name, v_dup.gr_no
            using errcode = '23505', hint = 'offline:possible_duplicate';
        end if;
      end if;
      -- A GR NUMBER TYPED OFFLINE AND TAKEN SINCE. Two devices offline cannot see
      -- each other's admissions, so both can type 0401. The child is still
      -- admitted, with a number allotted, and the entry is flagged, the way a
      -- receipt number is. Refusing it instead would leave the child, and the
      -- admission fee on a printed receipt, nowhere. The offline slip prints no
      -- GR number, so nothing printed is contradicted.
      v_gr := nullif(btrim(coalesce(v_adm->>'gr_no', '')), '');
      if v_gr is not null and exists (select 1 from public.students s
                                       where s.school_id = p_school and s.gr_no = v_gr) then
        v_adm := v_adm - 'gr_no';
        v_flags := v_flags || 'gr_renumbered'::text;
      end if;
      v_rno := nullif(v_p->>'admission_fee_receipt_no', '')::bigint;
      if v_rno is not null
         and (exists (select 1 from public.payments py
                       where py.school_id = p_school and py.receipt_no = v_rno)
              or not exists (select 1 from public.receipt_blocks b
                              where b.school_id = p_school and b.device_id = p_device
                                and b.user_id = p_user and v_rno between b.first_no and b.last_no)) then
        v_printed := v_rno;
        v_rno := null;
        v_flags := v_flags || 'receipt_renumbered'::text;
        perform set_config('app.offline_receipt_note', format('(printed as receipt %s)', v_printed), true);
      end if;
      perform set_config('app.offline_receipt_no', coalesce(v_rno::text, ''), true);
      perform set_config('app.offline_student_id', v_payer::text, true);
      v_res := public.fn_admit_student(v_adm);
      if v_gr is not null and 'gr_renumbered' = any(v_flags) then
        v_res := v_res || jsonb_build_object('typed_gr_no', v_gr);
      end if;
      -- AN ADMISSION FEE THE FAMILY STILL OWES, recorded as owed with the
      -- admission, as the screen does online straight after it. Made offline,
      -- nothing else would ever record it: the dues lived only in a sentence on
      -- the device. A refusal of the dues is reported and never undoes the
      -- admission, again as online.
      if coalesce(nullif(v_p->>'owed_admission_fee', '')::numeric, 0) > 0 then
        begin
          v_res := v_res || jsonb_build_object('owed', public.fn_record_dues(v_payer,
            jsonb_build_array(jsonb_build_object('kind', 'admission',
                                                 'amount', (v_p->>'owed_admission_fee')::numeric))));
        exception when others then
          get stacked diagnostics v_err = message_text;
          v_res := v_res || jsonb_build_object('owed', jsonb_build_object('recorded', 0, 'error', v_err));
        end;
      end if;
    end if;

    if v_printed is not null then
      v_res := v_res || jsonb_build_object('printed_receipt_no', v_printed);
    end if;
    v_raced := nullif(current_setting('app.offline_kept', true), '');
    if v_raced is not null then
      v_newer := coalesce(v_newer, '[]'::jsonb)
                 || (select coalesce(jsonb_agg(distinct x), '[]'::jsonb)
                       from unnest(string_to_array(v_raced, ',')) x
                      where not coalesce(v_newer, '[]'::jsonb) @> to_jsonb(x));
    end if;
    if v_newer is not null and jsonb_array_length(v_newer) > 0 then
      v_res := v_res || jsonb_build_object('kept_newer', v_newer);
    end if;
    if v_out is not null and jsonb_array_length(v_out) > 0 then
      v_res := v_res || jsonb_build_object('left_out', v_out);
    end if;

    insert into public.client_commands
      (id, school_id, user_id, device_id, type, occurred_at, status, payload, result, flags)
    values (v_id, p_school, p_user, p_device, v_type, v_at, 'applied',
            case when cardinality(v_flags) > 0 then v_p end, v_res, v_flags);

    perform set_config('app.offline_at', '', true);
    perform set_config('app.offline_replay', '', true);
    perform set_config('app.offline_receipt_no', '', true);
    perform set_config('app.offline_student_id', '', true);
    perform set_config('app.offline_receipt_note', '', true);
    perform set_config('app.offline_kept', '', true);
  exception when others then
    -- Everything the command did is undone with this block, the settings
    -- included.
    get stacked diagnostics v_state = returned_sqlstate, v_err = message_text,
                            v_hint = pg_exception_hint, v_cons = constraint_name;
    if v_state in ('40001', '40P01', '55P03') then
      return jsonb_build_object('id', v_id, 'status', 'deferred', 'code', 'busy',
        'error', 'The server was busy. This will be sent again.');
    end if;
    return public.fn__offline_reject(v_id, p_school, p_user, p_device, v_type, v_at, v_p,
      -- "duplicate" tells the device the school already has this and it can be
      -- let go, so it is said only when that is known: the checks above that
      -- say so, and the same pupil id inserted twice. Any other unique
      -- violation is a refusal, kept to be seen and sent again.
      coalesce(case when v_hint like 'offline:%' then substr(v_hint, 9) end,
               case when v_state = '42501' then 'not_permitted'
                    when v_state = '23505' and v_cons = 'students_pkey' then 'duplicate'
                    else 'refused' end),
      v_err);
  end;

  return jsonb_build_object('id', v_id, 'status', 'applied', 'result', v_res,
                            'flags', to_jsonb(v_flags));
end;
$$;
revoke all on function public.fn__offline_apply_one(uuid, uuid, uuid, jsonb)
  from public, anon, authenticated;

-- What the app calls. Up to 25 commands, in the order they were made. A command
-- that has to wait stops the rest of the batch, because a later one may depend
-- on it (a payment for a pupil whose admission is waiting); the app sends the
-- rest again with it later.
create or replace function public.fn_offline_apply(p_device_id uuid, p_commands jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
set "TimeZone" = 'Asia/Karachi'
as $$
declare
  v_school uuid := public.current_school_id();
  v_user   uuid := auth.uid();
  v_cmd    jsonb;
  v_one    jsonb;
  v_out    jsonb := '[]'::jsonb;
begin
  if p_device_id is null then
    raise exception 'The app did not say which device this is. Update the app and try again.'
      using errcode = '22023';
  end if;
  if v_user is null then
    raise exception 'This login is not active in a school, so its work cannot be sent. Ask the '
      'school office to switch it back on.'
      using errcode = '42501';
  end if;
  if v_school is null then
    -- A login switched off while its device held work (fn_sync_hello told the
    -- device so): what it hands in is kept for the owner, entry by entry
    -- (login_off). Only a device this login has used here, and a role that
    -- could have made the work.
    select p.school_id into v_school
      from public.profiles p
     where p.id = v_user and not p.active and p.school_id is not null
       and p.role in ('owner', 'principal', 'admin_clerk', 'accountant', 'class_teacher', 'subject_teacher')
       and exists (select 1 from public.sync_devices d
                    where d.school_id = p.school_id and d.device_id = p_device_id and d.user_id = v_user);
    if v_school is null then
      raise exception 'This login is not active in a school, so its work cannot be sent. Ask the '
        'school office to switch it back on.'
        using errcode = '42501';
    end if;
  elsif not public.has_role('owner', 'principal', 'admin_clerk', 'accountant',
                            'class_teacher', 'subject_teacher') then
    -- Parents and the observer enter nothing, so they send nothing: without
    -- this, what they sent was refused and KEPT, and filled the owner's list.
    raise exception 'This login does not enter work, so it has nothing to send.'
      using errcode = '42501';
  end if;
  if p_commands is null or jsonb_typeof(p_commands) <> 'array' then
    raise exception 'p_commands must be a JSON array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_commands) > 25 then
    raise exception 'Send at most 25 entries at a time.' using errcode = '22023';
  end if;

  for v_cmd in select value from jsonb_array_elements(p_commands) loop
    v_one := public.fn__offline_apply_one(v_school, v_user, p_device_id, v_cmd);
    v_out := v_out || jsonb_build_array(v_one);
    exit when v_one->>'status' = 'deferred';
  end loop;

  update public.sync_devices set last_seen = now()
   where school_id = v_school and device_id = p_device_id and user_id = v_user;

  return jsonb_build_object('server_time', now(), 'results', v_out);
end;
$$;


-- -----------------------------------------------------------------------------
-- 7. DEVICES AND REFUSED WORK, FOR THE PEOPLE WHO LOOK AFTER THEM
--
-- The owner and principal see every staff device and every refused command;
-- everyone else sees their own. A principal cannot switch off the owner's
-- device. These are access management, like fn_school_logins, so they are
-- gated on the role and not on may_view.
-- -----------------------------------------------------------------------------
create or replace function public.fn_school_devices()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_school uuid := public.current_school_id();
  v_all    boolean := public.has_role('owner', 'principal');
begin
  if v_school is null then
    raise exception 'Not permitted to see this school''s devices' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'device_id', d.device_id, 'user_id', d.user_id,
             'name', p.full_name, 'role', p.role,
             'platform', d.platform, 'app_version', d.app_version,
             'first_seen', d.first_seen, 'last_seen', d.last_seen,
             'lease_until', (select l.until_at from public.sync_leases l
                              where l.school_id = d.school_id and l.device_id = d.device_id
                                and l.user_id = d.user_id
                              order by l.from_at desc limit 1),
             'revoked_at', d.revoked_at,
             'revoked_by', (select r.full_name from public.profiles r
                             where r.id = d.revoked_by and r.school_id = d.school_id),
             'revoke_reason', d.revoke_reason,
             -- Open blocks, and those closed in the last 90 days with the
             -- numbers in them that were never used.
             'receipt_blocks', coalesce((
                select jsonb_agg(jsonb_build_object(
                         'first_no', b.first_no, 'last_no', b.last_no,
                         'issued_at', b.issued_at, 'closed_at', b.closed_at,
                         'closed_reason', b.closed_reason,
                         'used', (select count(*) from public.payments py
                                   where py.school_id = b.school_id
                                     and py.receipt_no between b.first_no and b.last_no))
                       order by b.first_no)
                  from public.receipt_blocks b
                 where b.school_id = d.school_id and b.device_id = d.device_id
                   and b.user_id = d.user_id
                   and (b.closed_at is null or b.closed_at > now() - interval '90 days')),
                '[]'::jsonb),
             'refused', (select count(*) from public.client_commands c
                          where c.school_id = d.school_id and c.device_id = d.device_id
                            and c.user_id = d.user_id and c.status = 'rejected'
                            and c.reviewed_at is null))
           order by d.last_seen desc)
      from public.sync_devices d
      left join public.profiles p on p.id = d.user_id and p.school_id = d.school_id
     where d.school_id = v_school
       and (v_all or d.user_id = auth.uid())
       and coalesce(p.role::text, '') <> 'parent'), '[]'::jsonb);
end;
$$;

create or replace function public.fn_revoke_device(
  p_device_id uuid, p_user_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_school uuid := public.current_school_id();
  v_me     uuid := auth.uid();
  v_target public.user_role;
  v_n      integer;
begin
  if v_school is null or v_me is null then
    raise exception 'Not permitted to switch off a device' using errcode = '42501';
  end if;
  select p.role into v_target from public.profiles p
   where p.id = p_user_id and p.school_id = v_school;
  if not (p_user_id = v_me
          or public.has_role('owner')
          or (public.has_role('principal') and v_target is distinct from 'owner')) then
    raise exception 'Not permitted to switch off another person''s device. The owner or '
      'principal can.' using errcode = '42501';
  end if;

  update public.sync_devices
     set revoked_at = now(), revoked_by = v_me,
         revoke_reason = left(nullif(btrim(coalesce(p_reason, '')), ''), 200)
   where school_id = v_school and device_id = p_device_id and user_id = p_user_id
     and revoked_at is null;
  get diagnostics v_n = row_count;
  if v_n = 0 and not exists (select 1 from public.sync_devices
                              where school_id = v_school and device_id = p_device_id
                                and user_id = p_user_id) then
    raise exception 'That device is not registered in this school.' using errcode = 'P0002';
  end if;

  -- Numbers it was given are closed and stay on record. It may not work
  -- offline from now on, and whatever it sends later is kept for the owner.
  update public.receipt_blocks set closed_at = now(), closed_reason = 'device_revoked'
   where school_id = v_school and device_id = p_device_id and user_id = p_user_id
     and closed_at is null;
  update public.sync_leases set until_at = greatest(from_at, now())
   where school_id = v_school and device_id = p_device_id and user_id = p_user_id
     and until_at > now();
  return jsonb_build_object('revoked', true, 'already', v_n = 0);
end;
$$;

create or replace function public.fn_offline_review(p_include_reviewed boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_school uuid := public.current_school_id();
  v_all    boolean := public.has_role('owner', 'principal');
begin
  if v_school is null then
    raise exception 'Not permitted to see offline work' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(x.j order by x.received_at desc)
      from (select c.received_at, jsonb_build_object(
                     'id', c.id, 'type', c.type, 'status', c.status,
                     'occurred_at', c.occurred_at, 'received_at', c.received_at,
                     'user_id', c.user_id, 'name', p.full_name, 'device_id', c.device_id,
                     'error', c.error, 'error_code', c.error_code, 'flags', to_jsonb(c.flags),
                     'payload', c.payload, 'result', c.result, 'reviewed_at', c.reviewed_at,
                     'reviewed_by', (select r.full_name from public.profiles r
                                      where r.id = c.reviewed_by and r.school_id = c.school_id)) as j
              from public.client_commands c
              left join public.profiles p on p.id = c.user_id and p.school_id = c.school_id
             where c.school_id = v_school
               and (v_all or c.user_id = auth.uid())
               and (c.status = 'rejected' or cardinality(c.flags) > 0)
               and (coalesce(p_include_reviewed, false) or c.reviewed_at is null)
             order by c.received_at desc
             limit 200) x), '[]'::jsonb);
end;
$$;

create or replace function public.fn_offline_dismiss(p_command_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_school uuid := public.current_school_id();
  v_n      integer;
begin
  if v_school is null then
    raise exception 'Not permitted to mark offline work as seen' using errcode = '42501';
  end if;
  -- Refused or flagged work is kept for the owner to see, so it is not cleared
  -- by the person it is about. The owner may clear anything; a principal what
  -- somebody else sent; the sender only their own refused registers and marks,
  -- never money, an admission or a flagged entry.
  update public.client_commands
     set reviewed_at = now(), reviewed_by = auth.uid()
   where id = p_command_id and school_id = v_school
     and reviewed_at is null
     and (status = 'rejected' or cardinality(flags) > 0)
     and (public.has_role('owner')
          or (public.has_role('principal') and user_id is distinct from auth.uid())
          or (user_id = auth.uid() and cardinality(flags) = 0
              and type in ('attendance.day', 'attendance.subject', 'marks.exam', 'marks.test')));
  get diagnostics v_n = row_count;
  return jsonb_build_object('dismissed', v_n > 0);
end;
$$;


-- -----------------------------------------------------------------------------
-- 8. WHO MAY CALL WHAT
-- -----------------------------------------------------------------------------
revoke all on function public.fn_sync_hello(uuid, text, text, bigint) from public, anon;
grant execute on function public.fn_sync_hello(uuid, text, text, bigint) to authenticated;
revoke all on function public.fn_offline_apply(uuid, jsonb) from public, anon;
grant execute on function public.fn_offline_apply(uuid, jsonb) to authenticated;
revoke all on function public.fn_school_devices() from public, anon;
grant execute on function public.fn_school_devices() to authenticated;
revoke all on function public.fn_revoke_device(uuid, uuid, text) from public, anon;
grant execute on function public.fn_revoke_device(uuid, uuid, text) to authenticated;
revoke all on function public.fn_offline_review(boolean) from public, anon;
grant execute on function public.fn_offline_review(boolean) to authenticated;
revoke all on function public.fn_offline_dismiss(uuid) from public, anon;
grant execute on function public.fn_offline_dismiss(uuid) to authenticated;

do $assert$
begin
  if to_regclass('public.client_commands') is null
     or to_regclass('public.receipt_blocks') is null
     or to_regprocedure('public.fn_offline_apply(uuid,jsonb)') is null
     or position('app.offline_receipt_no' in coalesce((select p.prosrc from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'fn_record_payment'), '')) = 0 then
    raise warning '0157 did not fully apply: work done offline cannot be handed in';
  end if;
end $assert$;
