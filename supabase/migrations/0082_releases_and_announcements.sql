-- =============================================================================
-- 0082 — The download button pointed at nothing, and a notice meant fifty
--        WhatsApp messages
--
-- Phase 6 of docs/SUPER-ADMIN-DESIGN.md. Three surfaces exist — the website, the
-- app, the console — and nothing joined them up.
--
-- THREE DEFECTS
--
-- 1. THE DESKTOP BUILD IS UNREACHABLE
--
--    desktop/ produces a Windows .msi in CI. It is uploaded as a workflow
--    artifact, which requires a GitHub login and expires in 90 days. So the one
--    thing a Pakistani school office actually wants — "give me the file, I will
--    install it on the front-desk computer" — cannot be given to them, and the
--    website has no download button because there is nothing to point it at.
--
--    A registry, not a hardcoded URL: the operator records a release and BOTH
--    the website's download button and the app's "an update is available" read
--    the same row. One place to change when a version ships.
--
-- 2. THE WEBSITE'S PRICES ARE TYPED INTO HTML
--
--    site/index.html carries Rs 950 / Rs 2,000 / Rs 3,500 as literal text and
--    `plans` carries them as data. Two copies of a price is one copy too many:
--    the day one is raised, the site quotes a figure the console does not charge
--    and a school arrives expecting the old one. `plans` becomes readable
--    WITHOUT a login so the site can read the real thing.
--
--    That is a deliberate widening and it is paid for: 4b-iii of
--    tenant_isolation.sql already requires `plans` to have no write policy, so
--    world-readable cannot become world-writable. A price list is a public
--    document — it is printed on the website either way.
--
-- 3. "MAINTENANCE ON SUNDAY 6-7AM" MEANS FIFTY WHATSAPP MESSAGES
--
--    There is no way to tell every school anything. With three customers that is
--    three messages; with fifty it is an afternoon, and the schools that most
--    need to know are the ones whose number is out of date.
--
--    platform_announcements, with an audience and a window, rendered as a banner
--    in the app. Deliberately NOT a message in message_outbox: that table is the
--    school's own outbox to its parents, and putting vendor notices in it would
--    mean a school's clerk seeing our maintenance window in a list of fee
--    reminders they are about to send.
--
-- WHY NONE OF THIS IS A FUNCTION GRANTED TO `anon`
--
-- 0071 closed the entire function surface to anon and check-definer-idor.py
-- fails CI if a single function in public is executable without a login. So the
-- public reads here are TABLE policies with an explicit grant, which is a much
-- narrower thing to reason about: a policy says which rows, and the grant says
-- which columns are reachable at all.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The price list becomes public
--
-- Only the ACTIVE plans, so a retired price cannot be quoted back at us.
-- ---------------------------------------------------------------------------
drop policy if exists plans_select_public on public.plans;
create policy plans_select_public on public.plans
  for select to anon using (active);

grant select on public.plans to anon;

-- ---------------------------------------------------------------------------
-- 2. Releases
-- ---------------------------------------------------------------------------
create table if not exists public.app_releases (
  id           uuid primary key default gen_random_uuid(),
  platform     text not null check (platform in ('windows', 'mac', 'linux', 'web')),
  channel      text not null default 'stable' check (channel in ('stable', 'beta')),
  version      text not null,
  url          text not null,
  -- The checksum a school can verify, and the reason it is NOT optional: an .msi
  -- downloaded over a Pakistani DSL line and installed on the office computer is
  -- exactly the file somebody would want to swap. Publishing the hash costs a
  -- line and is the only thing that makes "is this the real installer?"
  -- answerable.
  sha256       text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  size_bytes   bigint,
  notes        text,
  published_at timestamptz not null default now(),
  published_by uuid,
  -- Exactly one current release per platform+channel, enforced by a partial
  -- unique index below rather than by whoever remembers to clear the last one.
  is_current   boolean not null default true,
  unique (platform, channel, version)
);

create unique index if not exists idx_app_releases_current
  on public.app_releases(platform, channel) where is_current;

alter table public.app_releases enable row level security;

-- The operator sees every release including superseded ones; everybody else —
-- INCLUDING a visitor with no login, which is the whole point — sees only what
-- is current. Two policies rather than one, because "what should we offer for
-- download" and "what have we ever shipped" are different questions.
drop policy if exists app_releases_select_platform on public.app_releases;
create policy app_releases_select_platform on public.app_releases
  for select to authenticated using (public.is_platform_admin());

drop policy if exists app_releases_select_current on public.app_releases;
create policy app_releases_select_current on public.app_releases
  for select to anon, authenticated using (is_current);

grant select on public.app_releases to anon;

-- No write policy. Publishing a release is how a school gets an executable, so
-- it goes through one definer function that validates the checksum shape and the
-- URL, and records who did it.
create or replace function public.fn_platform_publish_release(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_platform text; v_channel text; v_version text;
  v_url text; v_sha text;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'Give the release details';
  end if;

  v_platform := coalesce(nullif(btrim(lower(coalesce(p->>'platform', ''))), ''), 'windows');
  v_channel  := coalesce(nullif(btrim(lower(coalesce(p->>'channel', ''))), ''), 'stable');
  v_version  := nullif(btrim(coalesce(p->>'version', '')), '');
  v_url      := nullif(btrim(coalesce(p->>'url', '')), '');
  v_sha      := nullif(btrim(lower(coalesce(p->>'sha256', ''))), '');

  if v_version is null then
    raise exception 'A version is required, e.g. 1.4.2';
  end if;
  if v_url is null or v_url !~ '^https://' then
    -- http:// refused, not merely discouraged. An installer fetched over plain
    -- HTTP on a Pakistani café connection is the easiest thing in this product
    -- to tamper with, and the school would have no way to know.
    raise exception 'The download URL must be an https:// address';
  end if;
  if v_sha is null or v_sha !~ '^[0-9a-f]{64}$' then
    raise exception
      'A SHA-256 checksum is required — 64 hex characters. On the machine that '
      'built the file: certutil -hashfile <file> SHA256';
  end if;

  -- One current release per platform and channel. Cleared first, in the same
  -- transaction, so the partial unique index can never see two.
  update public.app_releases set is_current = false
   where platform = v_platform and channel = v_channel and is_current;

  insert into public.app_releases
    (platform, channel, version, url, sha256, size_bytes, notes, published_by, is_current)
  values (v_platform, v_channel, v_version, v_url, v_sha,
          (p->>'size_bytes')::bigint,
          nullif(btrim(coalesce(p->>'notes', '')), ''), auth.uid(), true)
  on conflict (platform, channel, version) do update
    set url = excluded.url, sha256 = excluded.sha256,
        size_bytes = excluded.size_bytes, notes = excluded.notes,
        published_at = now(), published_by = excluded.published_by,
        is_current = true
  returning id into v_id;

  perform public.fn__log_operator_action('release_published', null,
    jsonb_build_object('release_id', v_id, 'platform', v_platform,
                       'channel', v_channel, 'version', v_version, 'url', v_url));

  return jsonb_build_object('release_id', v_id, 'platform', v_platform,
                            'channel', v_channel, 'version', v_version,
                            'is_current', true);
end;
$$;

create or replace function public.fn_platform_releases(p_limit integer default 50)
returns table (
  id uuid, platform text, channel text, version text, url text, sha256 text,
  size_bytes bigint, notes text, published_at timestamptz, is_current boolean
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
    select r.id, r.platform, r.channel, r.version, r.url, r.sha256,
           r.size_bytes, r.notes, r.published_at, r.is_current
      from public.app_releases r
     order by r.published_at desc
     limit greatest(1, least(coalesce(p_limit, 50), 200));
end;
$$;

create or replace function public.fn_platform_unpublish_release(
  p_release_id uuid, p_reason text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_r record; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  -- A release is pulled because it was broken. That is worth a sentence: six
  -- months later "why is 1.4.1 not the current one" has no other answer.
  if v_reason is null then
    raise exception 'Say why this release is being pulled';
  end if;
  select * into v_r from public.app_releases where id = p_release_id;
  if not found then
    raise exception 'No such release';
  end if;

  update public.app_releases set is_current = false where id = p_release_id;

  perform public.fn__log_operator_action('release_pulled', null,
    jsonb_build_object('release_id', p_release_id, 'platform', v_r.platform,
                       'version', v_r.version, 'reason', v_reason));

  return jsonb_build_object(
    'release_id', p_release_id, 'is_current', false,
    -- Said out loud: pulling the current release leaves the website's download
    -- button with nothing to offer, which is right, and silent otherwise.
    'note', case when exists (select 1 from public.app_releases
                               where platform = v_r.platform
                                 and channel = v_r.channel and is_current)
                 then 'Another release is now current for that platform.'
                 else format('There is now NO current %s release. The website''s '
                             || 'download button will say the installer is being '
                             || 'prepared.', v_r.platform) end);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Announcements
-- ---------------------------------------------------------------------------
create table if not exists public.platform_announcements (
  id         uuid primary key default gen_random_uuid(),
  -- Who sees it. 'staff' is everybody with a school login; 'parents' is the
  -- portal; 'owners' is the person who pays, for anything commercial.
  audience   text not null default 'staff'
               check (audience in ('staff', 'parents', 'owners', 'everyone')),
  severity   text not null default 'info'
               check (severity in ('info', 'warning', 'critical')),
  title      text not null check (btrim(title) <> ''),
  message    text not null check (btrim(message) <> ''),
  starts_at  timestamptz not null default now(),
  -- NOT NULL on purpose. An announcement with no end date is a banner that is
  -- still telling schools about last March's maintenance window, and a banner
  -- nobody believes is worse than no banner — the one that matters gets ignored
  -- with it.
  ends_at    timestamptz not null,
  created_by uuid,
  created_at timestamptz not null default now()
);

-- A HALF-OPEN window: [starts_at, ends_at). Named, and reconciled on every run,
-- because the first version of this table wrote `check (ends_at > starts_at)`
-- and that made retraction impossible to express.
--
-- now() is TRANSACTION-stable. A notice posted and immediately retracted —
-- because the wording was wrong, which is exactly when you retract one — has
-- starts_at = now(), so "ends now" can only mean ends_at = starts_at. With a
-- strict > that violated the constraint; with `between` in the policy it stayed
-- visible for a second. A half-open interval is both the standard way to write a
-- window and the one where "it showed, and now it does not" is expressible.
do $win$
begin
  if exists (select 1 from pg_constraint
              where conrelid = 'public.platform_announcements'::regclass
                and conname = 'platform_announcements_check') then
    alter table public.platform_announcements drop constraint platform_announcements_check;
  end if;
  if not exists (select 1 from pg_constraint
                  where conname = 'platform_announcements_window_chk') then
    alter table public.platform_announcements add constraint platform_announcements_window_chk
      check (ends_at >= starts_at);
  end if;
end $win$;

create index if not exists idx_announcements_window
  on public.platform_announcements(starts_at, ends_at);

alter table public.platform_announcements enable row level security;

drop policy if exists announcements_select_platform on public.platform_announcements;
create policy announcements_select_platform on public.platform_announcements
  for select to authenticated using (public.is_platform_admin());

-- Everybody with a login sees what is live and aimed at them. No school_id: it
-- is the same notice for every school, which is the entire point.
drop policy if exists announcements_select_live on public.platform_announcements;
create policy announcements_select_live on public.platform_announcements
  for select to authenticated using (
    -- Half-open: shows from starts_at, stops the instant ends_at is reached. See
    -- the note on the constraint above for why `between` was wrong.
    now() >= starts_at and now() < ends_at
    and (audience = 'everyone'
      or (audience = 'staff'   and public.is_staff())
      or (audience = 'owners'  and public.may_view('owner'::public.user_role,
                                                   'principal'::public.user_role))
      or (audience = 'parents' and exists (
            select 1 from public.profiles pr
             where pr.id = auth.uid() and pr.role = 'parent'))));

create or replace function public.fn_platform_announce(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_ends timestamptz; v_starts timestamptz;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'Give the announcement';
  end if;

  v_starts := coalesce((p->>'starts_at')::timestamptz, now());
  v_ends   := (p->>'ends_at')::timestamptz;
  if v_ends is null then
    -- Refused rather than defaulted, because whatever default this picked would
    -- be wrong: a maintenance window is hours and a price change is weeks.
    raise exception
      'Say when this stops showing. A banner with no end date is still telling '
      'schools about last March.';
  end if;
  if v_ends <= v_starts then
    raise exception 'It has to stop after it starts';
  end if;

  insert into public.platform_announcements
    (audience, severity, title, message, starts_at, ends_at, created_by)
  values (coalesce(nullif(btrim(lower(coalesce(p->>'audience', ''))), ''), 'staff'),
          coalesce(nullif(btrim(lower(coalesce(p->>'severity', ''))), ''), 'info'),
          btrim(coalesce(p->>'title', '')),
          btrim(coalesce(p->>'message', '')),
          v_starts, v_ends, auth.uid())
  returning id into v_id;

  perform public.fn__log_operator_action('announcement_posted', null,
    jsonb_build_object('announcement_id', v_id,
                       'audience', p->>'audience', 'severity', p->>'severity',
                       'title', p->>'title',
                       'starts_at', v_starts, 'ends_at', v_ends));

  return jsonb_build_object('announcement_id', v_id,
                            'starts_at', v_starts, 'ends_at', v_ends,
                            'live_now', now() >= v_starts and now() < v_ends);
end;
$$;

-- Ending one early is a separate act from posting it, and needs its own reason:
-- "we said the wrong thing" and "it is no longer true" are different, and the
-- log should be able to tell them apart.
create or replace function public.fn_platform_end_announcement(
  p_id uuid, p_reason text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_a record;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into v_a from public.platform_announcements where id = p_id;
  if not found then
    raise exception 'No such announcement';
  end if;
  if v_a.ends_at <= now() then
    raise exception 'That announcement has already finished';
  end if;

  -- least(starts_at, ...) is not what is wanted; greatest is. A notice retracted
  -- BEFORE it was due to start should stop at its start rather than end in the
  -- past, and one retracted while showing stops now. Either way ends_at is never
  -- less than starts_at, which the constraint requires.
  update public.platform_announcements
     set ends_at = greatest(now(), starts_at)
   where id = p_id;

  perform public.fn__log_operator_action('announcement_ended', null,
    jsonb_build_object('announcement_id', p_id, 'title', v_a.title,
                       'was_ending', v_a.ends_at,
                       'reason', nullif(btrim(coalesce(p_reason, '')), '')));

  return jsonb_build_object('announcement_id', p_id, 'ended', true);
end;
$$;

create or replace function public.fn_platform_announcements(p_limit integer default 50)
returns table (
  id uuid, audience text, severity text, title text, message text,
  starts_at timestamptz, ends_at timestamptz, live_now boolean
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
    select a.id, a.audience, a.severity, a.title, a.message,
           a.starts_at, a.ends_at,
           -- The SAME half-open test the policy uses. Two different definitions
           -- of "showing now" would have the operator's list disagree with the
           -- banner the schools are looking at.
           (now() >= a.starts_at and now() < a.ends_at)
      from public.platform_announcements a
     order by a.starts_at desc
     limit greatest(1, least(coalesce(p_limit, 50), 200));
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Grants
--
-- Nothing here goes to `anon`. The public reads are the two table policies
-- above; check-definer-idor.py fails CI if any function in public becomes
-- callable without a login, and that guard is worth more than the convenience.
-- ---------------------------------------------------------------------------
grant  execute on function public.fn_platform_publish_release(jsonb)   to authenticated;
revoke execute on function public.fn_platform_publish_release(jsonb) from public, anon;
grant  execute on function public.fn_platform_releases(integer)   to authenticated;
revoke execute on function public.fn_platform_releases(integer) from public, anon;
grant  execute on function public.fn_platform_unpublish_release(uuid, text)   to authenticated;
revoke execute on function public.fn_platform_unpublish_release(uuid, text) from public, anon;
grant  execute on function public.fn_platform_announce(jsonb)   to authenticated;
revoke execute on function public.fn_platform_announce(jsonb) from public, anon;
grant  execute on function public.fn_platform_end_announcement(uuid, text)   to authenticated;
revoke execute on function public.fn_platform_end_announcement(uuid, text) from public, anon;
grant  execute on function public.fn_platform_announcements(integer)   to authenticated;
revoke execute on function public.fn_platform_announcements(integer) from public, anon;
