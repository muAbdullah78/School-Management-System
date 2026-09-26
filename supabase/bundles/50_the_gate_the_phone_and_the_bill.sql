-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0149_the_gate_the_phone_and_the_bill.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0149: the gate, the phone, and the bill.
--
-- Step 4 goes through staff check-in end to end (Settings, the Staff register,
-- the teacher's phone) and the Subscription screen, and finds that check-in
-- could not work the way the school was told it works.
--
-- CHECK-IN
--
--   1. NOBODY COULD TYPE THE CODE. The teacher's home screen offered a box for
--      "today's code". A static code is 32 hexadecimal characters and a
--      rotating one is code.window.digest, about 50 characters that change
--      every 30 seconds. Neither can be read off a wall and typed into a phone.
--      So a teacher whose camera would not scan had no way in at all. Every
--      code now also has a SIX DIGIT PIN. A static code keeps a random PIN of
--      its own. A rotating code's PIN is derived from its secret for each 30
--      second window, exactly as the QR token is, and the window before is
--      accepted too, so a PIN read at the last second still works. The gate
--      screen shows it under the QR.
--
--   2. THE REGISTER COULD NOT TELL A SCAN FROM A PIN. A PIN can be read out
--      over the phone to somebody at home, a QR has to be pointed at. The
--      school should know which it was, so staff_attendance.method records
--      'qr' or 'pin', and the day's register (fn_staff_register_day) returns it.
--
--   3. A DOUBLE SCAN COULD CHECK SOMEBODY OUT AT 07:46. The guard against a
--      second scan on arrival used the LATE grace minutes as its window. A
--      school that set the grace to zero had every double scan recorded as a
--      check-out one second after the check-in. The window is now its own
--      fifteen minutes, whatever the grace.
--
--   4. A TEACHER WHOSE STATUS THE OFFICE CORRECTED COULD NOT CHECK OUT. Any
--      office mark outranked a scan, including a principal changing a scanned
--      Present to Late, so the teacher's check-out scan that afternoon was
--      answered "the office has recorded today" and no leaving time was kept.
--      A day the office TYPED still outranks a scan. A day the teacher scanned
--      in, whose status the office changed to Present, Late or Half day, now
--      takes the check-out.
--
--   5. SOMEBODY MARKED AS LEFT COULD STILL CHECK IN. The check only asked for a
--      staff record, not a current one. The row then sat on no register,
--      because the register lists current staff only.
--
--   6. THE TEACHER'S PHONE COULD NOT SAY WHERE THEY STOOD. fn_my_checkin gives
--      the home screen today's record, whether the office or a scan wrote it,
--      when a check-out opens, and whether the school uses a rotating code,
--      a poster, a location check, or no check-in at all. fn_my_staff_attendance
--      gives any range of the teacher's own days, so a week that crosses a
--      month end is one read.
--
--   7. THE REGISTER NEEDED A RELOAD. The office watched a register that only
--      changed when somebody pressed refresh. staff_attendance joins the
--      realtime publication where the host has one, so the Staff screen updates
--      the moment somebody checks in. The row policies still decide who hears
--      about which row.
--
--   8. CHECK-IN COULD NOT BE SWITCHED OFF. The only way to stop the old code
--      was to make a new one. fn_switch_off_checkin closes every code.
--
-- THE BILL
--
--   9. A SCHOOL ALREADY OVER ITS PLAN WAS INVITED TO ASK FOR LESS THAN IT HAS.
--      A school with 238 pupils on a 150 plan was offered "room for 200", and
--      the database accepted it, because it only asked for more than the
--      limit. A request now has to cover the pupils already on the roll.
--
--  10. A NEW PUPIL COULD BE WRITTEN STRAIGHT INTO THE TABLES, past the limit.
--      Every screen goes through fn_admit_student, the import or
--      fn_set_student_status, which check the plan, but the row policies and
--      the column grants let the office insert an enrolment, or switch one
--      back to active, directly through the API, and nothing counted. That
--      direct write is now refused. No screen makes it, and the functions that
--      do (the admission, the import, the year rollover and its undo) run as
--      their owner and are untouched. A pupil's own status was already closed:
--      the column is not granted to a login.
--
-- Every changed function keeps its signature, and the register that adds the
-- method column is a new function beside the old one, so a school re-pasting
-- an earlier bundle is not refused. Every table change checks whether it is
-- already done, so re-pasting is a no-op.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The PIN beside every code
-- ---------------------------------------------------------------------------
alter table public.staff_checkin_codes add column if not exists pin text;

do $pin_shape$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.staff_checkin_codes'::regclass
                    and conname = 'staff_checkin_codes_pin_shape') then
    alter table public.staff_checkin_codes
      add constraint staff_checkin_codes_pin_shape check (pin is null or pin ~ '^[0-9]{6}$');
  end if;
end
$pin_shape$;

-- The PIN for one 30 second window of a rotating code. Salted differently from
-- the QR digest, so a PIN read off the screen says nothing about the token.
-- Twenty-eight bits of the hash, reduced to six digits.
create or replace function public.fn__checkin_pin(p_secret text, p_window bigint)
returns text
language sql
immutable
set search_path = public
as $$
  select lpad(((('x' || substr(encode(sha256((p_secret || ':pin:' || p_window::text || ':' || p_secret)::bytea),
                                        'hex'), 1, 7))::bit(28)::integer) % 1000000)::text, 6, '0');
$$;
revoke all on function public.fn__checkin_pin(text, bigint) from public, anon, authenticated;

-- A random PIN for a static code. Not one a person would guess first: no six of
-- the same digit and no straight run up or down.
create or replace function public.fn__random_pin()
returns text
language plpgsql
volatile
set search_path = public
as $$
declare v text;
begin
  loop
    v := lpad(((('x' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 7))::bit(28)::integer)
               % 1000000)::text, 6, '0');
    exit when v !~ '^(.)\1{5}$'
          and v not in ('012345', '123456', '234567', '345678', '456789',
                        '987654', '876543', '765432', '654321', '543210');
  end loop;
  return v;
end;
$$;
revoke all on function public.fn__random_pin() from public, anon, authenticated;

-- Existing static codes get a PIN now, so a poster already on the wall works
-- with the keypad the day this is applied. Rotating codes derive theirs.
update public.staff_checkin_codes
   set pin = public.fn__random_pin()
 where pin is null and not rotating;

-- ---------------------------------------------------------------------------
-- 2. How the day was recorded: scanned, or typed from the PIN
-- ---------------------------------------------------------------------------
-- Not back-filled. Every staff_attendance update writes the audit log, and a
-- back-fill would add one audit row per day ever scanned. The readers treat a
-- row with a code and no method as a scan, which is what every earlier row was.
alter table public.staff_attendance add column if not exists method text;

do $method_shape$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.staff_attendance'::regclass
                    and conname = 'staff_attendance_method_shape') then
    alter table public.staff_attendance
      add constraint staff_attendance_method_shape check (method is null or method in ('qr', 'pin'));
  end if;
end
$method_shape$;

-- ---------------------------------------------------------------------------
-- 3. Making a code
-- ---------------------------------------------------------------------------
create or replace function public.fn_generate_checkin_code(
  p_label text default null, p_valid_from date default null, p_valid_to date default null,
  p_deactivate_others boolean default true, p_rotating boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
set timezone to 'Asia/Karachi'
as $$
declare
  v_school uuid := public.current_school_id();
  v_today  date := (now() at time zone 'Asia/Karachi')::date;
  v_code text; v_secret text; v_pin text; v_id uuid;
begin
  if v_school is null or not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted to generate a check-in code' using errcode = '42501';
  end if;
  if p_valid_from is not null and p_valid_to is not null and p_valid_to < p_valid_from then
    raise exception 'The code cannot expire before it starts';
  end if;
  -- A code born expired was accepted, switched the working one off, and left
  -- the school with no check-in at all.
  if p_valid_to is not null and p_valid_to < v_today then
    raise exception 'That end date has already passed. Leave it empty, or choose today or later.';
  end if;
  if p_deactivate_others then
    update public.staff_checkin_codes set active = false
     where active and school_id = v_school;
  end if;
  v_code := replace(gen_random_uuid()::text, '-', '');
  v_secret := case when p_rotating
                   then replace(gen_random_uuid()::text, '-', '')
                        || replace(gen_random_uuid()::text, '-', '')
              end;
  v_pin := case when coalesce(p_rotating, false) then null else public.fn__random_pin() end;
  insert into public.staff_checkin_codes
    (school_id, code, label, valid_from, valid_to, active, created_by, rotating, secret, pin)
  values (v_school, v_code, nullif(btrim(p_label), ''), p_valid_from, p_valid_to, true,
          auth.uid(), coalesce(p_rotating, false), v_secret, v_pin)
  returning id into v_id;
  -- The secret is never returned. The screen gets tokens and PINs from
  -- fn_checkin_display, never the seed they are made from.
  return jsonb_build_object('id', v_id, 'code', v_code, 'pin', v_pin,
                            'rotating', coalesce(p_rotating, false));
end;
$$;
revoke all on function public.fn_generate_checkin_code(text, date, date, boolean, boolean) from public, anon;
grant execute on function public.fn_generate_checkin_code(text, date, date, boolean, boolean) to authenticated;

-- Switch self check-in off. The office marks everybody until a new code is made.
create or replace function public.fn_switch_off_checkin()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_school uuid := public.current_school_id(); v_n integer;
begin
  if v_school is null or not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted to switch check-in off' using errcode = '42501';
  end if;
  update public.staff_checkin_codes set active = false
   where active and school_id = v_school;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke all on function public.fn_switch_off_checkin() from public, anon;
grant execute on function public.fn_switch_off_checkin() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. What the gate screen shows
-- ---------------------------------------------------------------------------
create or replace function public.fn_checkin_display()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set timezone to 'Asia/Karachi'
as $$
declare
  v_school uuid := public.current_school_id();
  v_c record; v_win bigint; v_period integer := public.fn__checkin_period();
  v_today date := (now() at time zone 'Asia/Karachi')::date;
begin
  -- has_role, not may_view: a live token is a key to the gate, not a record.
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted to show the check-in code' using errcode = '42501';
  end if;

  select * into v_c from public.staff_checkin_codes
   where school_id = v_school and active
     and (valid_from is null or valid_from <= v_today)
     and (valid_to   is null or valid_to   >= v_today)
   order by created_at desc limit 1;
  if not found then
    return jsonb_build_object('status', 'none');
  end if;

  if not v_c.rotating then
    return jsonb_build_object(
      'status', 'static', 'code', v_c.code, 'pin', v_c.pin, 'label', v_c.label,
      'rotating', false, 'valid_to', v_c.valid_to);
  end if;

  v_win := floor(extract(epoch from now()) / v_period)::bigint;
  return jsonb_build_object(
    'status', 'rotating', 'code', v_c.code, 'label', v_c.label, 'rotating', true,
    'token', v_c.code || '.' || v_win::text || '.' || public.fn__checkin_digest(v_c.secret, v_win),
    'pin', public.fn__checkin_pin(v_c.secret, v_win),
    'period_seconds', v_period,
    'expires_in', v_period - (floor(extract(epoch from now()))::bigint % v_period),
    'valid_to', v_c.valid_to);
end;
$$;
revoke all on function public.fn_checkin_display() from public, anon;
grant execute on function public.fn_checkin_display() to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Checking in: the QR token, the poster code, or the six digit PIN
-- ---------------------------------------------------------------------------
create or replace function public.fn_staff_check_in(
  p_code text, p_lat double precision default null, p_lng double precision default null,
  p_device text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
set timezone to 'Asia/Karachi'
as $$
declare
  v_school uuid;
  v_staff  uuid;
  v_c      record;
  v_now    timestamptz := now();
  v_today  date := (now() at time zone 'Asia/Karachi')::date;
  v_exist  record;
  v_geo_on boolean; v_lat double precision; v_lng double precision;
  v_radius integer; v_dist double precision;
  v_start  time; v_grace integer;
  v_period integer := public.fn__checkin_period();
  -- A second scan inside this many minutes of arriving is a double scan, not
  -- a check-out. Its own number, not the late grace (see the header, item 3).
  v_gap    constant integer := 15;
  v_parts  text[]; v_bare text; v_pin text; v_win bigint; v_cur bigint;
  v_method text; v_rotating_live boolean;
  v_late   integer; v_status public.attendance_status;
  v_new    uuid; v_since_in integer;
begin
  if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  v_school := public.current_school_id();
  v_staff  := public.my_staff_id();

  if v_staff is null then
    return public.fn__checkin_refuse(v_school, null, p_code, 'login not linked to a staff record',
      'Your login is not linked to a staff record: ask the principal to link it in Staff.',
      p_device, p_lat, p_lng);
  end if;

  if not exists (select 1 from public.staff s
                  where s.id = v_staff and s.school_id = v_school and s.status = 'active') then
    return public.fn__checkin_refuse(v_school, v_staff, p_code, 'staff record marked as left',
      'Your staff record is marked as left, so check-in is closed. Speak to the office if that is wrong.',
      p_device, p_lat, p_lng);
  end if;

  -- More than ten refusals in ten minutes from this account and it stops. Per
  -- account, so one locked-out phone cannot stop the staff room. The lockout is
  -- not logged, so the window clears ten minutes after the last real attempt.
  -- Ten tries in ten minutes against a million PINs is a lifetime of guessing.
  if (select count(*) from public.staff_checkin_attempts
       where school_id = v_school and profile_id = auth.uid()
         and created_at > v_now - interval '10 minutes') >= 10 then
    return jsonb_build_object('status', 'refused', 'reason', 'rate limited',
      'message', 'Too many failed check-in attempts. Wait ten minutes, or ask the office to mark you present.');
  end if;

  v_bare := btrim(coalesce(p_code, ''));
  if v_bare = '' then
    return public.fn__checkin_refuse(v_school, v_staff, p_code, 'no code presented',
      'No check-in code was presented. Scan the code, or type the six digit PIN.', p_device, p_lat, p_lng);
  end if;

  v_pin := regexp_replace(v_bare, '[[:space:]-]', '', 'g');
  if v_pin ~ '^[0-9]{6}$' then
    -- ---- the PIN ---------------------------------------------------------
    v_method := 'pin';
    v_cur := floor(extract(epoch from v_now) / v_period)::bigint;
    select c.id, c.label, c.rotating,
           case when not c.rotating then null
                when public.fn__checkin_pin(c.secret, v_cur) = v_pin then v_cur
                else v_cur - 1 end as win
      into v_c
      from public.staff_checkin_codes c
     where c.school_id = v_school and c.active
       and (c.valid_from is null or c.valid_from <= v_today)
       and (c.valid_to   is null or c.valid_to   >= v_today)
       and ((not c.rotating and c.pin = v_pin)
            or (c.rotating and c.secret is not null
                and v_pin in (public.fn__checkin_pin(c.secret, v_cur),
                              public.fn__checkin_pin(c.secret, v_cur - 1))))
     order by c.created_at desc
     limit 1;
    if not found then
      select bool_or(c.rotating) into v_rotating_live
        from public.staff_checkin_codes c
       where c.school_id = v_school and c.active
         and (c.valid_from is null or c.valid_from <= v_today)
         and (c.valid_to   is null or c.valid_to   >= v_today);
      if v_rotating_live is null then
        return public.fn__checkin_refuse(v_school, v_staff, p_code, 'no check-in code today',
          'Check-in is not switched on today. Ask the office to mark you.', p_device, p_lat, p_lng);
      end if;
      return public.fn__checkin_refuse(v_school, v_staff, 'PIN ' || v_pin, 'wrong PIN',
        case when v_rotating_live
             then 'That PIN is not the one on the gate screen. It changes every 30 seconds: type the number showing now.'
             else 'That PIN is not right. Check the number on the check-in poster.' end,
        p_device, p_lat, p_lng);
    end if;
    v_win := v_c.win;
  else
    -- ---- the QR token or the poster code ---------------------------------
    v_method := 'qr';
    -- A rotating token is code.window.digest. Split first, then look the code
    -- up, so a token built around another school's code cannot match by prefix.
    v_parts := string_to_array(v_bare, '.');
    select c.id, c.label, c.rotating, c.secret, c.valid_from, c.valid_to
      into v_c
      from public.staff_checkin_codes c
     where c.school_id = v_school and c.active and c.code = v_parts[1];
    if not found then
      return public.fn__checkin_refuse(v_school, v_staff, p_code, 'unknown or inactive code',
        'That check-in code is not in use any more. Scan the code at the gate, or type the PIN.',
        p_device, p_lat, p_lng);
    end if;
    if v_c.valid_from is not null and v_today < v_c.valid_from then
      return public.fn__checkin_refuse(v_school, v_staff, p_code, 'code not active yet',
        'This check-in code is not active yet', p_device, p_lat, p_lng);
    end if;
    if v_c.valid_to is not null and v_today > v_c.valid_to then
      return public.fn__checkin_refuse(v_school, v_staff, p_code, 'code expired',
        'This check-in code has expired', p_device, p_lat, p_lng);
    end if;

    if v_c.rotating then
      if coalesce(array_length(v_parts, 1), 0) <> 3 then
        -- A bare code against a rotating record is the photographed poster.
        return public.fn__checkin_refuse(v_school, v_staff, p_code,
          'plain code presented against a rotating code',
          'This school uses a rotating code. Scan the code on the gate screen, or type the PIN under it: a saved link or an old photo will not work.',
          p_device, p_lat, p_lng);
      end if;
      begin
        v_win := nullif(v_parts[2], '')::bigint;
      exception when others then
        v_win := null;
      end;
      v_cur := floor(extract(epoch from v_now) / v_period)::bigint;
      -- The current window and the one before it, nothing older.
      if v_win is null or v_win > v_cur or v_win < v_cur - 1 then
        return public.fn__checkin_refuse(v_school, v_staff, p_code, 'stale or future token',
          'That code has already changed. Scan the code showing on the gate screen now.',
          p_device, p_lat, p_lng);
      end if;
      if v_parts[3] is distinct from public.fn__checkin_digest(v_c.secret, v_win) then
        return public.fn__checkin_refuse(v_school, v_staff, p_code, 'bad token digest',
          'That check-in code is not valid. Scan the code on the gate screen.',
          p_device, p_lat, p_lng);
      end if;
    elsif coalesce(array_length(v_parts, 1), 0) <> 1 then
      return public.fn__checkin_refuse(v_school, v_staff, p_code,
        'token presented against a static code',
        'That check-in code is not in use any more. Scan the code at the gate, or type the PIN.',
        p_device, p_lat, p_lng);
    end if;
  end if;

  -- ---- the location check ----------------------------------------------
  -- A deterrent, not proof: the coordinates come from the phone.
  select geofence_enabled, geo_lat, geo_lng, geo_radius_m, day_starts_at, late_grace_minutes
    into v_geo_on, v_lat, v_lng, v_radius, v_start, v_grace
    from public.school_settings where school_id = v_school;
  if coalesce(v_geo_on, false) then
    if p_lat is null or p_lng is null then
      return public.fn__checkin_refuse(v_school, v_staff, p_code, 'no location supplied',
        'Location is required to check in. Allow location for this site in your browser and try again.',
        p_device, p_lat, p_lng);
    end if;
    if v_lat is null or v_lng is null then
      -- The office's own misconfiguration, not an attempt: raise rather than
      -- filling the refusal register with it.
      raise exception 'School location is not set. Ask the principal to set it in Settings, Staff check-in.';
    end if;
    v_dist := 2 * 6371000 * asin(least(1, sqrt(
      power(sin(radians((p_lat - v_lat) / 2)), 2)
      + cos(radians(v_lat)) * cos(radians(p_lat)) * power(sin(radians((p_lng - v_lng) / 2)), 2))));
    if v_dist > coalesce(v_radius, 200) then
      return public.fn__checkin_refuse(v_school, v_staff, p_code,
        'outside the location check (' || round(v_dist) || ' m)',
        format('You are too far from the school to check in (about %s m away).', round(v_dist)),
        p_device, p_lat, p_lng);
    end if;
  end if;

  -- ---- what is already recorded for today -------------------------------
  select * into v_exist from public.staff_attendance
   where staff_id = v_staff and attendance_date = v_today and school_id = v_school;

  -- A day the office TYPED outranks a scan, and so does an office Absent or
  -- Leave over a scan. A scanned day whose status the office corrected to a
  -- present kind still takes the check-out (item 4).
  if v_exist.id is not null and v_exist.source = 'manual'
     and (v_exist.code_id is null or v_exist.status not in ('present', 'late', 'half_day')) then
    return jsonb_build_object(
      'status', 'office_marked',
      'attendance_status', v_exist.status,
      'reason', v_exist.reason,
      'checked_at', v_exist.checked_at);
  end if;

  if v_exist.id is not null then
    -- ---- the second scan is the check-out ------------------------------
    v_since_in := case when v_exist.checked_at is null then null
                       else floor(extract(epoch from (v_now - v_exist.checked_at)) / 60)::integer end;
    if v_since_in is not null and v_since_in < v_gap then
      return jsonb_build_object(
        'status', 'already', 'checked_at', v_exist.checked_at,
        'attendance_status', v_exist.status, 'late_minutes', v_exist.late_minutes,
        'out_opens_at', v_exist.checked_at + make_interval(mins => v_gap));
    end if;
    update public.staff_attendance a
       set checked_out_at = v_now,
           worked_minutes = case when a.checked_at is not null
                                 then floor(extract(epoch from (v_now - a.checked_at)) / 60)::integer end,
           device = coalesce(nullif(btrim(p_device), ''), a.device)
     where a.id = v_exist.id and a.school_id = v_school
     returning * into v_exist;
    return jsonb_build_object(
      'status', 'out', 'checked_at', v_exist.checked_at,
      'checked_out_at', v_exist.checked_out_at,
      'worked_minutes', v_exist.worked_minutes,
      'attendance_status', v_exist.status, 'late_minutes', v_exist.late_minutes,
      'method', v_method);
  end if;

  -- ---- lateness ---------------------------------------------------------
  -- With no start time set, nothing is ever late.
  v_late := null; v_status := 'present';
  if v_start is not null then
    v_late := floor(extract(epoch from
                ((v_now at time zone 'Asia/Karachi')::time - v_start)) / 60)::integer
              - coalesce(v_grace, 10);
    if v_late > 0 then v_status := 'late'; else v_late := 0; end if;
  end if;

  insert into public.staff_attendance
    (school_id, staff_id, attendance_date, status, checked_at, code_id, code_window,
     source, method, device, late_minutes)
  values (v_school, v_staff, v_today, v_status, v_now, v_c.id, v_win,
          'qr', v_method, nullif(btrim(p_device), ''), v_late)
  on conflict (staff_id, attendance_date) do nothing
  returning id into v_new;

  if v_new is null then
    -- Two scans in the same instant. Report what won rather than raising.
    select * into v_exist from public.staff_attendance
     where staff_id = v_staff and attendance_date = v_today and school_id = v_school;
    return jsonb_build_object('status', 'already', 'checked_at', v_exist.checked_at,
                              'attendance_status', v_exist.status,
                              'late_minutes', v_exist.late_minutes);
  end if;

  return jsonb_build_object('status', 'ok', 'checked_at', v_now,
                            'attendance_status', v_status, 'late_minutes', v_late,
                            'rotating', v_c.rotating, 'method', v_method,
                            'out_opens_at', v_now + make_interval(mins => v_gap));
end;
$$;
revoke all on function public.fn_staff_check_in(text, double precision, double precision, text) from public, anon;
grant execute on function public.fn_staff_check_in(text, double precision, double precision, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. The teacher's own phone: where they stand today, and their days
-- ---------------------------------------------------------------------------
create or replace function public.fn_my_checkin()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set timezone to 'Asia/Karachi'
as $$
declare
  v_school uuid := public.current_school_id();
  v_staff  uuid := public.my_staff_id();
  v_today  date := (now() at time zone 'Asia/Karachi')::date;
  v_s record; v_a record; v_mode text; v_active boolean;
begin
  if auth.uid() is null or v_school is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  if v_staff is null then
    return jsonb_build_object('linked', false, 'today', v_today);
  end if;
  select s.status = 'active' into v_active
    from public.staff s where s.id = v_staff and s.school_id = v_school;

  select geofence_enabled, day_starts_at, day_ends_at, late_grace_minutes into v_s
    from public.school_settings where school_id = v_school;

  select case when c.rotating then 'rotating' else 'static' end into v_mode
    from public.staff_checkin_codes c
   where c.school_id = v_school and c.active
     and (c.valid_from is null or c.valid_from <= v_today)
     and (c.valid_to   is null or c.valid_to   >= v_today)
   order by c.created_at desc limit 1;

  select * into v_a from public.staff_attendance a
   where a.staff_id = v_staff and a.attendance_date = v_today and a.school_id = v_school;

  return jsonb_build_object(
    'linked', true,
    'active', coalesce(v_active, false),
    'today', v_today,
    'mode', v_mode,
    'geofence', coalesce(v_s.geofence_enabled, false),
    'day_starts_at', v_s.day_starts_at,
    'day_ends_at', v_s.day_ends_at,
    'late_grace_minutes', coalesce(v_s.late_grace_minutes, 10),
    'record', case when v_a.id is null then null else jsonb_build_object(
      'status', v_a.status,
      'source', v_a.source,
      'scanned', v_a.code_id is not null,
      'method', coalesce(v_a.method, case when v_a.code_id is not null then 'qr' end),
      'checked_at', v_a.checked_at,
      'checked_out_at', v_a.checked_out_at,
      'late_minutes', v_a.late_minutes,
      'worked_minutes', v_a.worked_minutes,
      'reason', v_a.reason) end,
    -- Whether the phone should offer a check-out, and from when. The same rule
    -- fn_staff_check_in applies, so the button and the answer agree.
    'can_check_out', v_a.id is not null and v_a.code_id is not null and v_a.checked_at is not null
                     and (v_a.source <> 'manual' or v_a.status in ('present', 'late', 'half_day')),
    'out_opens_at', case when v_a.id is not null and v_a.code_id is not null and v_a.checked_at is not null
                         then v_a.checked_at + interval '15 minutes' end);
end;
$$;
revoke all on function public.fn_my_checkin() from public, anon;
grant execute on function public.fn_my_checkin() to authenticated;

create or replace function public.fn_my_staff_attendance(p_from date, p_to date)
returns table(attendance_date date, status text, checked_at timestamptz, checked_out_at timestamptz,
              late_minutes integer, worked_minutes integer, source text, method text, reason text)
language plpgsql
stable
security definer
set search_path = public
set timezone to 'Asia/Karachi'
as $$
declare
  v_school uuid := public.current_school_id();
  v_staff  uuid := public.my_staff_id();
begin
  if auth.uid() is null or v_school is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Choose a start date on or before the end date';
  end if;
  if p_to - p_from > 400 then
    raise exception 'Choose at most a year at a time';
  end if;
  if v_staff is null then
    return;
  end if;
  return query
  select a.attendance_date, a.status::text, a.checked_at, a.checked_out_at,
         a.late_minutes, a.worked_minutes, a.source,
         coalesce(a.method, case when a.code_id is not null then 'qr' end),
         a.reason
    from public.staff_attendance a
   where a.school_id = v_school and a.staff_id = v_staff
     and a.attendance_date between p_from and p_to
   order by a.attendance_date desc;
end;
$$;
revoke all on function public.fn_my_staff_attendance(date, date) from public, anon;
grant execute on function public.fn_my_staff_attendance(date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. The day's register learns how each day was recorded
-- ---------------------------------------------------------------------------
-- A NEW NAME rather than a new column on fn_staff_attendance_day. Changing a
-- function's return type cannot be done in place, and bundle 6 re-creates the
-- old shape, so a school told to re-paste it would have had the whole bundle
-- refused. The old function is left exactly as it is.
create or replace function public.fn_staff_register_day(p_date date default null)
returns table(staff_id uuid, full_name text, designation text, employee_no text, status text,
              checked_at timestamptz, checked_out_at timestamptz, late_minutes integer,
              worked_minutes integer, source text, scanned boolean, code_label text,
              code_window bigint, device text, reason text, marked_by_name text, method text)
language plpgsql
stable
security definer
set search_path = public
set timezone to 'Asia/Karachi'
as $$
declare
  v_school uuid := public.current_school_id();
  v_date date := coalesce(p_date, (now() at time zone 'Asia/Karachi')::date);
begin
  if not public.may_view('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select s.id, s.full_name, s.designation, s.employee_no,
         coalesce(a.status::text, 'not marked'),
         a.checked_at, a.checked_out_at, a.late_minutes, a.worked_minutes,
         a.source,
         (a.id is not null and a.code_id is not null),
         c.label, a.code_window, a.device, a.reason, p.full_name,
         case when a.code_id is null then null else coalesce(a.method, 'qr') end
    from public.staff s
    left join public.staff_attendance a
      on a.staff_id = s.id and a.attendance_date = v_date and a.school_id = v_school
    left join public.staff_checkin_codes c
      on c.id = a.code_id and c.school_id = v_school
    left join public.profiles p
      on p.id = a.marked_by and p.school_id = v_school
   where s.school_id = v_school and s.status = 'active'
   order by s.full_name;
end;
$$;
revoke all on function public.fn_staff_register_day(date) from public, anon;
grant execute on function public.fn_staff_register_day(date) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. The register updates itself
-- ---------------------------------------------------------------------------
-- Only where the host has a realtime publication (Supabase does, a bare
-- Postgres does not). The screen also polls, so a school whose project has
-- realtime switched off still sees a check-in within seconds.
do $realtime$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime'
                        and schemaname = 'public' and tablename = 'staff_attendance') then
    execute 'alter publication supabase_realtime add table public.staff_attendance';
  end if;
end
$realtime$;

-- ---------------------------------------------------------------------------
-- 9. A room request has to cover the roll the school already has
-- ---------------------------------------------------------------------------
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
  v_limit  integer;
  v_count  integer;
  v_id     uuid;
  v_sug    text;
begin
  if v_school is null or not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or the principal can ask for more room'
      using errcode = '42501';
  end if;
  if p_requested is null or p_requested < 1 then
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

  if v_limit is not null and p_requested <= v_limit then
    raise exception 'Your plan already covers % pupils, so there is nothing to '
      'ask for. Ask for more than % if you need it.', v_limit, v_limit;
  end if;
  -- THE NEW FLOOR. A school already over its plan asking for less than it has
  -- would be granted a limit that still stops every admission.
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

  select p2.code into v_sug from public.plans p2
   where p2.active and p2.price_monthly > 0
     and p2.student_limit >= greatest(p_requested, v_count + 1)
   order by p2.student_limit limit 1;

  return jsonb_build_object(
    'id', v_id, 'status', 'pending', 'requested_limit', p_requested,
    'students_now', v_count, 'plan_covers', v_limit, 'wants', v_wants,
    'suggested_plan', v_sug,
    'what_next', case when v_wants = 'move_up' then
        'We will work out what the bigger plan costs for the rest of your term '
        || 'and send you the price. Nothing changes on your account until you '
        || 'are happy with it, and the answer will appear on this screen.'
      else
        'We will look at this and come back to you, usually the same working '
        || 'day. Nothing changes in the meantime, nothing you have already '
        || 'entered is affected, and the answer will appear on this screen.'
      end);
end;
$$;
revoke all on function public.fn_request_student_limit(integer, text, text) from public, anon;
grant execute on function public.fn_request_student_limit(integer, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 10. A pupil joins the roll only through the functions that check the plan
-- ---------------------------------------------------------------------------
-- An INVOKER trigger, the same shape as 0148's guard_profile_links. Inside
-- fn_admit_student, the import, the year rollover or fn_set_student_status the
-- current user is the function's owner, and those check the plan themselves.
-- A login writing the table directly is the authenticated role, and no screen
-- does that: this only closes the door the row policies left open.
create or replace function public.guard_roll_writes()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if tg_op = 'INSERT'
       or (new.status = 'active'
         and (old.status is distinct from 'active'
              or new.session_id is distinct from old.session_id
              or new.student_id is distinct from old.student_id)) then
    raise exception 'A pupil is put on the roll through Admissions, Quick Add, the '
      'class grid or the import, which check how many pupils your plan covers. '
      'A direct write to the roll is not accepted.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_roll_writes() from public, anon, authenticated;

drop trigger if exists trg_enrollments_roll_guard on public.enrollments;
create trigger trg_enrollments_roll_guard
  before insert or update on public.enrollments
  for each row execute function public.guard_roll_writes();


-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0149_the_gate_the_phone_and_the_bill.sql', '50_the_gate_the_phone_and_the_bill.sql');
end $ledger$;
