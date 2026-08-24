-- =============================================================================
-- 0062 — Staff QR check-in that is not decorative
--
-- Probed on a real database before a line of this was written. One teacher,
-- login linked to her staff record, sitting at home:
--
--   she inserted her own attendance row .......... yes. No QR code involved.
--   with source = 'qr' and code_id null ......... nothing anywhere read code_id
--   she back-dated seven days she never worked .. yes
--   the code itself ............................. 32 static hex chars, no expiry
--   check-out, lateness, school day ............. none of the three existed
--
-- `staff_att_insert` allowed `staff_id = my_staff_id()`, which meant the whole
-- QR mechanism was a suggestion. fn_staff_check_in has always been SECURITY
-- DEFINER, so that policy branch was never needed for the feature to work.
--
-- The design and the argument against each decision are in
-- docs/STAFF-CHECKIN-DESIGN.md. No biometric — that was the instruction, and it
-- is also why this file is careful about the difference between "a body was at
-- the gate" and "a valid currently-displayed code was presented by a signed-in
-- account". It closes every gap between those two that can be closed and makes
-- the remaining one visible instead of silent.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. A teacher can never write her own attendance row
--
-- THE ONE THAT MATTERS. Everything else in this file is a lock on a door; this
-- is the wall next to it.
-- ---------------------------------------------------------------------------
drop policy if exists staff_att_insert on public.staff_attendance;
create policy staff_att_insert on public.staff_attendance
  for insert to authenticated
  with check (
    school_id = public.current_school_id()
    and public.has_role('owner', 'principal', 'admin_clerk')
  );

-- Attendance for a day that has not happened yet. A CHECK rather than a trigger:
-- declarative, applies to every path including ones nobody has written yet, and
-- cannot be forgotten. Past dates stay valid for ever so a dump/restore is safe.
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'staff_attendance_not_future'
                    and conrelid = 'public.staff_attendance'::regclass) then
    -- Any future-dated rows already present would block the constraint. There
    -- should be none; if a database has them they were forged, and naming them
    -- is better than silently dropping the check.
    if exists (select 1 from public.staff_attendance where attendance_date > current_date) then
      raise exception 'staff_attendance already holds % future-dated row(s) — review them before applying 0062',
        (select count(*) from public.staff_attendance where attendance_date > current_date);
    end if;
    alter table public.staff_attendance
      add constraint staff_attendance_not_future check (attendance_date <= current_date);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. The school day, so that "late" can mean something
--
-- attendance_status has had a 'late' value since the first migration and nothing
-- could ever produce it, because there was no start time to be late against.
-- ---------------------------------------------------------------------------
alter table public.school_settings
  add column if not exists day_starts_at time,
  add column if not exists day_ends_at time,
  add column if not exists late_grace_minutes integer not null default 10;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'school_settings_grace_chk'
                    and conrelid = 'public.school_settings'::regclass) then
    alter table public.school_settings
      add constraint school_settings_grace_chk
      check (late_grace_minutes between 0 and 240);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Rotating codes, check-out, and the columns that make a register auditable
-- ---------------------------------------------------------------------------
alter table public.staff_checkin_codes
  -- A rotating code is displayed on a screen and changes every 30 seconds. A
  -- static one is printed on a poster and a photograph of it works for ever;
  -- both are offered, and the Settings copy says which is which.
  add column if not exists rotating boolean not null default false,
  -- Never leaves the database. The display calls fn_checkin_display() and
  -- renders what comes back; a rotating code whose seed is in a browser is not
  -- a rotating code.
  add column if not exists secret text;

alter table public.staff_attendance
  add column if not exists checked_out_at timestamptz,
  add column if not exists late_minutes integer,
  add column if not exists worked_minutes integer,
  -- The token window the scan presented. Two check-ins seconds apart on the
  -- same window from two different devices is the shape of a relayed
  -- photograph, and a principal can only ask about it if it is recorded.
  add column if not exists code_window bigint;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'staff_attendance_out_after_in'
                    and conrelid = 'public.staff_attendance'::regclass) then
    alter table public.staff_attendance
      add constraint staff_attendance_out_after_in
      check (checked_out_at is null or checked_at is null or checked_out_at >= checked_at);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Every refused attempt, recorded
--
-- Without this, a teacher trying last term's photograph forty times, or a script
-- walking the token space, is invisible.
-- ---------------------------------------------------------------------------
create table if not exists public.staff_checkin_attempts (
  id          bigserial primary key,
  school_id   uuid not null references public.schools(id),
  profile_id  uuid references public.profiles(id),
  staff_id    uuid references public.staff(id) on delete set null,
  presented   text,
  reason      text not null,
  device      text,
  lat         double precision,
  lng         double precision,
  created_at  timestamptz not null default now()
);

create index if not exists idx_checkin_attempts_school
  on public.staff_checkin_attempts (school_id, created_at desc);
create index if not exists idx_checkin_attempts_profile
  on public.staff_checkin_attempts (profile_id, created_at desc);

alter table public.staff_checkin_attempts enable row level security;

-- Read-only to the office, and to nobody else. There is no INSERT policy at all:
-- rows arrive only through fn_staff_check_in, which is SECURITY DEFINER. A
-- teacher who could write this table could bury her own failures in noise.
drop policy if exists checkin_attempts_select on public.staff_checkin_attempts;
create policy checkin_attempts_select on public.staff_checkin_attempts
  for select to authenticated
  using (school_id = public.current_school_id()
         and public.may_view('owner', 'principal', 'admin_clerk'));

-- ---------------------------------------------------------------------------
-- 5. The token
--
-- code.window.digest, digest = left(sha256(secret || ':' || window || ':' ||
-- secret), 8). sha256() is built in from PG11; pgcrypto is NOT installed in this
-- project and no migration has ever required an extension, because CI runs on
-- plain Postgres 16. The trailing secret is there so that even the full digest
-- would not permit a length-extension — it costs nothing to include.
--
-- Internal: revoked from every client role. It takes a secret as an argument, so
-- anything that can call it can mint tokens.
-- ---------------------------------------------------------------------------
create or replace function public.fn__checkin_digest(p_secret text, p_window bigint)
returns text language sql immutable as $$
  select left(encode(sha256((p_secret || ':' || p_window::text || ':' || p_secret)::bytea),
                     'hex'), 8);
$$;

revoke all on function public.fn__checkin_digest(text, bigint) from public;
revoke all on function public.fn__checkin_digest(text, bigint) from anon;
revoke all on function public.fn__checkin_digest(text, bigint) from authenticated;

-- The rotation period, in one place. 30 seconds, and the previous window is also
-- accepted, so a scan is good for between 30 and 60 seconds.
create or replace function public.fn__checkin_period() returns integer
  language sql immutable as $$ select 30 $$;

revoke all on function public.fn__checkin_period() from public;
revoke all on function public.fn__checkin_period() from anon;
revoke all on function public.fn__checkin_period() from authenticated;

-- ---------------------------------------------------------------------------
-- 6. Generating a code — now with a mode
-- ---------------------------------------------------------------------------
drop function if exists public.fn_generate_checkin_code(text, date, date, boolean);
create or replace function public.fn_generate_checkin_code(
  p_label text default null,
  p_valid_from date default null,
  p_valid_to date default null,
  p_deactivate_others boolean default true,
  p_rotating boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_code text; v_secret text; v_id uuid;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to generate a check-in code' using errcode = '42501';
  end if;
  if p_valid_from is not null and p_valid_to is not null and p_valid_to < p_valid_from then
    raise exception 'The code cannot expire before it starts';
  end if;
  if p_deactivate_others then
    -- Without `where school_id`, rotating one school's QR would deactivate the
    -- check-in code of every school in the database at once.
    update public.staff_checkin_codes set active = false
     where active and school_id = public.current_school_id();
  end if;
  v_code := replace(gen_random_uuid()::text, '-', '');
  -- 256 bits from two UUIDs. gen_random_bytes would be tidier and lives in
  -- pgcrypto, which this project does not install.
  v_secret := case when p_rotating
                   then replace(gen_random_uuid()::text, '-', '')
                        || replace(gen_random_uuid()::text, '-', '')
              end;
  insert into public.staff_checkin_codes
    (code, label, valid_from, valid_to, active, created_by, rotating, secret)
  values (v_code, nullif(btrim(p_label),''), p_valid_from, p_valid_to, true,
          auth.uid(), coalesce(p_rotating, false), v_secret)
  returning id into v_id;
  -- The secret is NOT returned. The caller gets tokens from
  -- fn_checkin_display(), never the seed they are made from.
  return jsonb_build_object('id', v_id, 'code', v_code,
                            'rotating', coalesce(p_rotating, false));
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. What the gate display renders
--
-- Called every few seconds by the screen at the gate. Office roles only: this is
-- the one place a live token is handed out, and a teacher who could call it
-- could sit at home refreshing it.
-- ---------------------------------------------------------------------------
--
-- STABLE, and gated on has_role rather than may_view — deliberately, and it is
-- the same category as fn_may_manage_class and fn_may_write_school_file: a
-- function that LOOKS like a read but authorises something. Handing an observer
-- a live check-in token is not letting them look at the school's records, it is
-- giving them a key to the gate. It is named in the has_role exemption list in
-- check-readonly-writes.py, verify.sql and detect.sql for that reason.
create or replace function public.fn_checkin_display()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_c record; v_win bigint; v_period integer := public.fn__checkin_period();
  v_today date := (now() at time zone 'Asia/Karachi')::date;
begin
  -- has_role, not may_view: an observer must not be handed a live check-in
  -- token. It is not a read of the school's records, it is a key to the gate.
  if not public.has_role('owner','principal','admin_clerk') then
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
      'status', 'static', 'code', v_c.code, 'label', v_c.label,
      'rotating', false, 'valid_to', v_c.valid_to);
  end if;

  v_win := floor(extract(epoch from now()) / v_period)::bigint;
  return jsonb_build_object(
    'status', 'rotating', 'code', v_c.code, 'label', v_c.label, 'rotating', true,
    'token', v_c.code || '.' || v_win::text || '.'
             || public.fn__checkin_digest(v_c.secret, v_win),
    'period_seconds', v_period,
    -- How long THIS token still has. The display refreshes on it rather than on
    -- a fixed timer, so a token is never shown after it has stopped working.
    'expires_in', v_period - (floor(extract(epoch from now()))::bigint % v_period),
    'valid_to', v_c.valid_to);
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. The check-in itself
--
-- Rewritten rather than patched. It now: refuses a plain code against a rotating
-- record (otherwise the rotation is decorative in exactly the way the direct
-- insert was), computes lateness against the school day, treats the second scan
-- as a departure, refuses to overwrite an office mark, and records every refusal.
--
-- REFUSALS RETURN, THEY DO NOT RAISE. The first draft of this function logged the
-- attempt and then raised, which logs nothing: plpgsql has no autonomous
-- transaction, so the raise rolls the log row back with it and the refusal
-- register would have been permanently empty — and the brute-force counter that
-- reads it would never have counted past zero. So a refusal comes back as
-- {status: 'refused', message: ...} and the log row commits. The web wrapper
-- turns that into the same thrown error the UI has always shown, so nothing
-- downstream can quietly ignore one.
--
-- Only two things still raise: not being signed in (there is no account to log
-- against) and the school having no location set while the geofence is on, which
-- is a misconfiguration by the office rather than an attempt by a teacher.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_staff_check_in(text, double precision, double precision, text);
create or replace function public.fn_staff_check_in(
  p_code text,
  p_lat double precision default null,
  p_lng double precision default null,
  p_device text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
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
  v_parts  text[]; v_bare text; v_win bigint; v_cur bigint;
  v_late   integer; v_status public.attendance_status;
  v_new    uuid; v_since_in integer;
begin
  if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  v_school := public.current_school_id();
  v_staff  := public.my_staff_id();

  if v_staff is null then
    return public.fn__checkin_refuse(v_school, null, p_code, 'login not linked to a staff record',
      'Your login is not linked to a staff record — ask the principal to link it in Staff.',
      p_device, p_lat, p_lng);
  end if;

  -- ---- brute force ------------------------------------------------------
  -- More than ten refusals in ten minutes from THIS ACCOUNT and it stops. Per
  -- account rather than per school, so one person's locked-out phone cannot
  -- stop the rest of the staff room checking in. The lockout itself is NOT
  -- logged, so the window clears ten minutes after the last real attempt
  -- instead of extending itself for as long as somebody keeps trying.
  if (select count(*) from public.staff_checkin_attempts
       where school_id = v_school and profile_id = auth.uid()
         and created_at > v_now - interval '10 minutes') >= 10 then
    return jsonb_build_object('status', 'refused', 'reason', 'rate limited',
      'message', 'Too many failed check-in attempts. Wait ten minutes, or ask the office to mark you present.');
  end if;

  -- ---- the code ---------------------------------------------------------
  v_bare := btrim(coalesce(p_code, ''));
  if v_bare = '' then
    return public.fn__checkin_refuse(v_school, v_staff, p_code, 'no code presented',
      'No check-in code was presented. Scan the code again.', p_device, p_lat, p_lng);
  end if;

  -- A rotating token is code.window.digest. Split first, then look the code up,
  -- so a token built around another school's code cannot be matched by prefix.
  v_parts := string_to_array(v_bare, '.');
  select * into v_c from public.staff_checkin_codes
   where school_id = v_school and active and code = v_parts[1];
  if not found then
    return public.fn__checkin_refuse(v_school, v_staff, p_code, 'unknown or inactive code',
      'Invalid or inactive check-in code', p_device, p_lat, p_lng);
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
      -- The whole point. A bare code against a rotating record is the
      -- photographed poster, and accepting it would make the rotation
      -- decorative in exactly the way the direct insert was.
      return public.fn__checkin_refuse(v_school, v_staff, p_code,
        'plain code presented against a rotating code',
        'This school uses a rotating check-in code. Scan the code on the screen at the gate — a saved link or an old photo will not work.',
        p_device, p_lat, p_lng);
    end if;
    begin
      v_win := nullif(v_parts[2], '')::bigint;
    exception when others then
      v_win := null;
    end;
    v_cur := floor(extract(epoch from v_now) / v_period)::bigint;
    -- The current window and the one before it. Nothing older: that is the
    -- difference between "a photograph is worth a minute" and "a photograph is
    -- worth a term".
    if v_win is null or v_win > v_cur or v_win < v_cur - 1 then
      return public.fn__checkin_refuse(v_school, v_staff, p_code, 'stale or future token',
        'That code has already changed. Look at the screen and scan the code showing now.',
        p_device, p_lat, p_lng);
    end if;
    if v_parts[3] <> public.fn__checkin_digest(v_c.secret, v_win) then
      return public.fn__checkin_refuse(v_school, v_staff, p_code, 'bad token digest',
        'That check-in code is not valid. Scan the code on the screen at the gate.',
        p_device, p_lat, p_lng);
    end if;
  elsif coalesce(array_length(v_parts, 1), 0) <> 1 then
    return public.fn__checkin_refuse(v_school, v_staff, p_code,
      'token presented against a static code',
      'Invalid or inactive check-in code', p_device, p_lat, p_lng);
  end if;

  -- ---- the geofence -----------------------------------------------------
  -- A deterrent, not a control: the coordinates come from the phone and a
  -- browser can be told to lie. Kept because it raises the effort, and the
  -- Settings copy says exactly this rather than implying more.
  select geofence_enabled, geo_lat, geo_lng, geo_radius_m, day_starts_at, late_grace_minutes
    into v_geo_on, v_lat, v_lng, v_radius, v_start, v_grace
    from public.school_settings where school_id = v_school;
  if coalesce(v_geo_on, false) then
    if p_lat is null or p_lng is null then
      return public.fn__checkin_refuse(v_school, v_staff, p_code, 'no location supplied',
        'Location is required to check in — enable location and try again.', p_device, p_lat, p_lng);
    end if;
    if v_lat is null or v_lng is null then
      -- The office has switched the geofence on and not set the school's
      -- position. That is a misconfiguration, not an attempt, so it raises
      -- rather than filling the refusal register with the office's own mistake.
      raise exception 'School location is not set — ask the principal to set it in Settings.';
    end if;
    v_dist := 2 * 6371000 * asin(least(1, sqrt(
      power(sin(radians((p_lat - v_lat) / 2)), 2)
      + cos(radians(v_lat)) * cos(radians(p_lat)) * power(sin(radians((p_lng - v_lng) / 2)), 2))));
    if v_dist > coalesce(v_radius, 200) then
      return public.fn__checkin_refuse(v_school, v_staff, p_code,
        'outside the geofence (' || round(v_dist) || ' m)',
        format('You are too far from the school to check in (about %s m away).', round(v_dist)),
        p_device, p_lat, p_lng);
    end if;
  end if;

  -- ---- what is already recorded for today -------------------------------
  select * into v_exist from public.staff_attendance
   where staff_id = v_staff and attendance_date = v_today and school_id = v_school;

  if v_exist.id is not null and v_exist.source = 'manual' then
    -- An office mark outranks a scan. Otherwise a teacher marked absent could
    -- scan the absence away.
    return jsonb_build_object(
      'status', 'office_marked',
      'attendance_status', v_exist.status,
      'reason', v_exist.reason,
      'checked_at', v_exist.checked_at);
  end if;

  if v_exist.id is not null then
    -- ---- the second scan is the check-out ------------------------------
    v_since_in := floor(extract(epoch from (v_now - v_exist.checked_at)) / 60)::integer;
    if v_exist.checked_at is not null and v_since_in < coalesce(v_grace, 10) then
      -- A double scan on arrival must not check somebody out at 08:01.
      return jsonb_build_object(
        'status', 'already', 'checked_at', v_exist.checked_at,
        'attendance_status', v_exist.status, 'late_minutes', v_exist.late_minutes);
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
      'attendance_status', v_exist.status, 'late_minutes', v_exist.late_minutes);
  end if;

  -- ---- lateness ---------------------------------------------------------
  -- With no start time set, nothing is ever late. Inventing a default would mark
  -- a whole staff room late on the day the school upgraded.
  v_late := null; v_status := 'present';
  if v_start is not null then
    v_late := floor(extract(epoch from
                ((v_now at time zone 'Asia/Karachi')::time - v_start)) / 60)::integer
              - coalesce(v_grace, 10);
    if v_late > 0 then v_status := 'late'; else v_late := 0; end if;
  end if;

  insert into public.staff_attendance
    (school_id, staff_id, attendance_date, status, checked_at, code_id, code_window,
     source, device, late_minutes)
  values (v_school, v_staff, v_today, v_status, v_now, v_c.id, v_win,
          'qr', nullif(btrim(p_device), ''), v_late)
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
                            'rotating', v_c.rotating);
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. The refusal: one function that logs it AND builds the answer
--
-- Its own function so that logging and refusing cannot come apart — a new
-- refusal path physically cannot be written without recording it, because the
-- return value only exists here. The table needs no INSERT policy as a result: a
-- teacher who could write it could bury her own failures in noise.
--
-- Internal, revoked from every client role: it can write any reason against any
-- staff id in the caller's school.
-- ---------------------------------------------------------------------------
create or replace function public.fn__checkin_refuse(
  p_school uuid, p_staff uuid, p_presented text, p_reason text, p_message text,
  p_device text, p_lat double precision, p_lng double precision
) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  insert into public.staff_checkin_attempts
    (school_id, profile_id, staff_id, presented, reason, device, lat, lng)
  values (p_school, auth.uid(), p_staff, left(coalesce(p_presented, ''), 120),
          p_reason, nullif(left(coalesce(p_device, ''), 120), ''), p_lat, p_lng);
  return jsonb_build_object('status', 'refused', 'reason', p_reason, 'message', p_message);
end;
$$;

revoke all on function public.fn__checkin_refuse(uuid, uuid, text, text, text, text, double precision, double precision) from public;
revoke all on function public.fn__checkin_refuse(uuid, uuid, text, text, text, text, double precision, double precision) from anon;
revoke all on function public.fn__checkin_refuse(uuid, uuid, text, text, text, text, double precision, double precision) from authenticated;

-- ---------------------------------------------------------------------------
-- 10. An office mark that overwrites a scan needs a reason
-- ---------------------------------------------------------------------------
create or replace function public.fn_set_staff_attendance(
  p_staff_id uuid, p_date date, p_status public.attendance_status, p_reason text default null
) returns void language plpgsql security definer set search_path = public as $$
declare v_prior record;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to set staff attendance' using errcode = '42501';
  end if;
  perform public.assert_own('staff', p_staff_id);
  if p_date > current_date then
    raise exception 'Attendance cannot be recorded for a day that has not happened yet';
  end if;

  select * into v_prior from public.staff_attendance
   where staff_id = p_staff_id and attendance_date = p_date
     and school_id = public.current_school_id();

  -- Overwriting a recorded scan with a judgement is exactly the thing somebody
  -- has to be able to explain a month later. A principal who knows a teacher
  -- left at nine outranks the machine — but says so.
  if v_prior.id is not null and v_prior.source = 'qr'
     and nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'This day was recorded by a check-in at %. Changing it needs a reason.',
      to_char(v_prior.checked_at at time zone 'Asia/Karachi', 'HH24:MI');
  end if;

  insert into public.staff_attendance
    (staff_id, attendance_date, status, source, reason, marked_by, checked_at)
  values (p_staff_id, p_date, p_status, 'manual', nullif(btrim(p_reason),''), auth.uid(), now())
  on conflict (staff_id, attendance_date) do update
    set status = excluded.status, source = 'manual', reason = excluded.reason,
        marked_by = excluded.marked_by,
        -- The scan is not erased. What time somebody actually arrived is a fact
        -- worth keeping even when the office overrides the status.
        checked_at = coalesce(public.staff_attendance.checked_at, excluded.checked_at);
end;
$$;

-- ---------------------------------------------------------------------------
-- 11. The daily register — the thing that makes any of this useful
--
-- The direct-insert loophole survived because nothing displayed code_id. Every
-- staff member, present or not, with what was scanned and what was typed.
-- ---------------------------------------------------------------------------
create or replace function public.fn_staff_attendance_day(p_date date default null)
returns table (
  staff_id uuid, full_name text, designation text, employee_no text,
  status text, checked_at timestamptz, checked_out_at timestamptz,
  late_minutes integer, worked_minutes integer,
  source text, scanned boolean, code_label text, code_window bigint,
  device text, reason text, marked_by_name text
) language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_date date := coalesce(p_date, (now() at time zone 'Asia/Karachi')::date);
begin
  if not public.may_view('owner','principal','admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select s.id, s.full_name, s.designation, s.employee_no,
         coalesce(a.status::text, 'not marked'),
         a.checked_at, a.checked_out_at, a.late_minutes, a.worked_minutes,
         a.source,
         -- The distinction the register was missing. A row with source 'qr' and
         -- no code_id is what the forged insert produced.
         (a.id is not null and a.code_id is not null),
         c.label, a.code_window, a.device, a.reason, p.full_name
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

-- ---------------------------------------------------------------------------
-- 12. Refused attempts, for the office
-- ---------------------------------------------------------------------------
create or replace function public.fn_checkin_attempts(p_limit integer default 50)
returns table (
  id bigint, staff_name text, reason text, presented text,
  device text, created_at timestamptz
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.may_view('owner','principal','admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
  select t.id, s.full_name, t.reason, t.presented, t.device, t.created_at
    from public.staff_checkin_attempts t
    left join public.staff s on s.id = t.staff_id and s.school_id = v_school
   where t.school_id = v_school
   order by t.created_at desc
   limit greatest(1, least(coalesce(p_limit, 50), 500));
end;
$$;

-- ---------------------------------------------------------------------------
-- 13. Grants
-- ---------------------------------------------------------------------------
grant execute on function public.fn_generate_checkin_code(text, date, date, boolean, boolean) to authenticated;
grant execute on function public.fn_checkin_display() to authenticated;
grant execute on function public.fn_staff_check_in(text, double precision, double precision, text) to authenticated;
grant execute on function public.fn_set_staff_attendance(uuid, date, public.attendance_status, text) to authenticated;
grant execute on function public.fn_staff_attendance_day(date) to authenticated;
grant execute on function public.fn_checkin_attempts(integer) to authenticated;
grant select on public.staff_checkin_attempts to authenticated;
