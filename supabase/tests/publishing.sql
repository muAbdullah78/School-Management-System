-- =============================================================================
-- The installer registry and notices to every school (0082).
--
-- Two things joined up here that had never been joined up, and the assertions
-- follow from what each one is FOR.
--
-- THE INSTALLER. desktop/ has produced a Windows .msi in CI since it was
-- written, and it went into a workflow artifact — behind a GitHub login, expiring
-- after 90 days. So the one thing a Pakistani school office actually asks for
-- ("give me the file for the front-desk computer") could not be given to them,
-- and the website had no download button because there was nothing to point at.
--
-- The rules that matter: exactly ONE current release per platform, an https link
-- only, and a checksum that is not optional. An installer fetched over plain HTTP
-- on a café connection is the easiest thing in this product to tamper with, and
-- the hash is the only thing that makes "is this really yours?" answerable.
--
-- NOTICES. There has never been any way to tell every school anything, so
-- "maintenance on Sunday 6-7am" meant fifty WhatsApp messages — and the schools
-- that most need to know are the ones whose number is out of date.
--
-- The rule that matters: an end date is MANDATORY. A banner with no end is still
-- telling schools about last March's maintenance window, and one nobody believes
-- takes the next one down with it.
--
-- The anon boundary these two open is swept in tenant_isolation.sql TEST 10,
-- which is the more important half and belongs with the other boundary tests.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/publishing.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if p_cond then raise notice 'PASS  %', p_label;
  else raise exception 'FAIL  %', p_label; end if;
end;
$$;

create or replace function pg_temp.refused(p_sql text) returns boolean
language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return true;
end;
$$;

create or replace function pg_temp.why(p_sql text) returns text
language plpgsql as $$
begin
  execute p_sql;
  return '(no error)';
exception when others then
  return sqlerrm;
end;
$$;

-- --- Fixture: one operator, one school with an owner and a parent -------------
do $seed$
declare
  v_school uuid;
  v_owner  uuid := '00000000-0000-0000-0000-00000000b001';
  v_clerk  uuid := '00000000-0000-0000-0000-00000000b002';
  v_parent uuid := '00000000-0000-0000-0000-00000000b003';
  ops      uuid := '00000000-0000-0000-0000-00000000b0fa';
begin
  insert into public.schools (name) values ('Publish Test School') returning id into v_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'starter', 'active', current_date + 90);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_owner, 'owner@pub.test'), (v_clerk, 'clerk@pub.test'),
    (v_parent, 'parent@pub.test'), (ops, 'ops@pub.test')
  on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_owner,  'Publish Owner',  'owner',       v_school),
    (v_clerk,  'Publish Clerk',  'admin_clerk', v_school),
    (v_parent, 'Publish Parent', 'parent',      v_school)
  on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;

  insert into public.platform_admins (user_id, email) values (ops, 'ops@pub.test')
    on conflict (user_id) do nothing;

  -- The suite runs against a database other suites have also written to, so the
  -- release table is cleared to make the "exactly one current" assertions mean
  -- something. Inside a transaction that rolls back.
  delete from public.app_releases;
  delete from public.platform_announcements;

  create temp table _pub (k text primary key, v uuid);
  insert into _pub values
    ('school', v_school), ('owner', v_owner), ('clerk', v_clerk),
    ('parent', v_parent), ('ops', ops);
end $seed$;

do $grant_pub$
declare v_ns text;
begin
  select n.nspname into v_ns from pg_namespace n
    join pg_class c on c.relnamespace = n.oid
   where c.relname = '_pub' and n.nspname like 'pg\_temp%';
  execute format('grant usage on schema %I to authenticated', v_ns);
  grant select on _pub to authenticated;
end $grant_pub$;

create or replace function public._pact(p_key text) returns void
language plpgsql as $$
begin
  perform set_config('test.uid', (select v::text from _pub where k = p_key), false);
end;
$$;

-- =============================================================================
-- 1-9  THE INSTALLER
-- =============================================================================
do $rel$
declare r jsonb; msg text; n integer;
begin
  perform public._pact('ops');

  -- The three refusals, and each one is a way a school ends up with the wrong
  -- file on the office computer.
  msg := pg_temp.why(
    'select public.fn_platform_publish_release(''{"version":"1.0.0","url":"http://x.test/a.msi","sha256":"' || repeat('a', 64) || '"}''::jsonb)');
  perform pg_temp.ok(msg like '%https%',
    '1 a plain-HTTP download link is refused — that file is trivial to swap');

  msg := pg_temp.why(
    'select public.fn_platform_publish_release(''{"version":"1.0.0","url":"https://x.test/a.msi"}''::jsonb)');
  perform pg_temp.ok(msg like '%SHA-256%' and msg like '%certutil%',
    '2 a release with no checksum is refused, and it says how to compute one');

  perform pg_temp.ok(pg_temp.refused(
    'select public.fn_platform_publish_release(''{"url":"https://x.test/a.msi","sha256":"' || repeat('a', 64) || '"}''::jsonb)'),
    '3 and one with no version');
  perform pg_temp.ok(pg_temp.refused(
    'select public.fn_platform_publish_release(''{"version":"1.0.0","url":"https://x.test/a.msi","sha256":"nothex"}''::jsonb)'),
    '3b and one whose checksum is not 64 hex characters');

  r := public.fn_platform_publish_release(jsonb_build_object(
    'version', '1.0.0', 'url', 'https://x.test/SchoolManager-1.0.0.msi',
    'sha256', repeat('a', 64), 'size_bytes', 74000000,
    'notes', 'first release'));
  perform pg_temp.ok((r->>'is_current')::boolean, '4 a valid release is published');

  -- EXACTLY ONE current per platform. Two download buttons is a school
  -- installing whichever the page happened to render.
  r := public.fn_platform_publish_release(jsonb_build_object(
    'version', '1.1.0', 'url', 'https://x.test/SchoolManager-1.1.0.msi',
    'sha256', repeat('b', 64)));
  select count(*) into n from public.app_releases
   where platform = 'windows' and channel = 'stable' and is_current;
  perform pg_temp.ok(n = 1, '5 publishing a new version leaves exactly one current');
  perform pg_temp.ok(
    (select version from public.app_releases
      where platform = 'windows' and channel = 'stable' and is_current) = '1.1.0',
    '5b and it is the new one');
  perform pg_temp.ok((select count(*) from public.app_releases) = 2,
    '5c while the old one stays on record');

  -- Re-publishing the same version corrects it rather than failing. A checksum
  -- typed wrong is the likeliest mistake here and it must be fixable.
  r := public.fn_platform_publish_release(jsonb_build_object(
    'version', '1.1.0', 'url', 'https://x.test/SchoolManager-1.1.0.msi',
    'sha256', repeat('c', 64)));
  perform pg_temp.ok(
    (select sha256 from public.app_releases where version = '1.1.0') = repeat('c', 64),
    '6 re-publishing the same version corrects the checksum');
  perform pg_temp.ok((select count(*) from public.app_releases) = 2,
    '6b without adding a row');

  -- Pulling one.
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_unpublish_release(%L, '' '')',
    (select id from public.app_releases where version = '1.1.0'))),
    '7 pulling a release needs a reason');
  r := public.fn_platform_unpublish_release(
    (select id from public.app_releases where version = '1.1.0'),
    'installer crashed on Windows 10 without .NET');
  perform pg_temp.ok(r->>'note' like '%NO current%',
    '8 pulling the only current release says the download button now has nothing');
  select count(*) into n from public.app_releases where is_current;
  perform pg_temp.ok(n = 0, '8b and nothing is current');
  perform pg_temp.ok(exists (select 1 from public.operator_actions
                              where action = 'release_pulled'
                                and detail->>'reason' like '%.NET%'),
    '9 the reason is in the history — "why is 1.1.0 not current" has no other answer');

  -- A school user publishes nothing.
  perform public._pact('owner');
  set local role authenticated;
  perform pg_temp.ok(pg_temp.refused(
    'select public.fn_platform_publish_release(''{"version":"9.9.9","url":"https://evil.test/x.msi","sha256":"' || repeat('f', 64) || '"}''::jsonb)'),
    '9b a school owner cannot publish an installer');
  perform pg_temp.ok(pg_temp.refused(
    'insert into public.app_releases (platform, version, url, sha256) values (''windows'',''9.9.9'',''https://evil.test/x.msi'',''' || repeat('f', 64) || ''')'),
    '9c nor insert one by hand');
  reset role;
end $rel$;

-- =============================================================================
-- 20-29  NOTICES
-- =============================================================================
do $ann$
declare r jsonb; msg text; n integer; v_id uuid;
begin
  perform public._pact('ops');

  msg := pg_temp.why(
    'select public.fn_platform_announce(''{"title":"Hi","message":"Something"}''::jsonb)');
  perform pg_temp.ok(msg like '%last March%',
    '20 an announcement with no end date is refused, and the message says why');
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_announce(''{"title":"Hi","message":"x","starts_at":"%s","ends_at":"%s"}''::jsonb)',
    now() + interval '2 days', now() + interval '1 day')),
    '20b and one that ends before it starts');
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_announce(''{"title":" ","message":"x","ends_at":"%s"}''::jsonb)',
    now() + interval '1 day')),
    '20c and one with no heading');

  r := public.fn_platform_announce(jsonb_build_object(
    'audience', 'staff', 'severity', 'warning',
    'title', 'Maintenance on Sunday morning',
    'message', 'Unavailable 6-7am while we upgrade the server. Nothing will be lost.',
    'ends_at', (now() + interval '3 days')::text));
  v_id := (r->>'announcement_id')::uuid;
  perform pg_temp.ok((r->>'live_now')::boolean, '21 it is showing straight away');

  -- Aimed at staff. A clerk sees it; a parent does not.
  perform public._pact('clerk');
  set local role authenticated;
  select count(*) into n from public.platform_announcements;
  perform pg_temp.ok(n = 1, '22 a clerk sees a notice aimed at staff');
  reset role;

  perform public._pact('parent');
  set local role authenticated;
  select count(*) into n from public.platform_announcements;
  perform pg_temp.ok(n = 0, '23 a parent does not');
  reset role;

  -- Aimed at owners. The clerk must not see the commercial ones.
  perform public._pact('ops');
  perform public.fn_platform_announce(jsonb_build_object(
    'audience', 'owners', 'severity', 'info',
    'title', 'Prices change in April',
    'message', 'Your renewal is at the current price. New schools pay the new one.',
    'ends_at', (now() + interval '30 days')::text));

  perform public._pact('clerk');
  set local role authenticated;
  select count(*) into n from public.platform_announcements;
  perform pg_temp.ok(n = 1, '24 a clerk does not see an owners-only notice');
  reset role;

  perform public._pact('owner');
  set local role authenticated;
  select count(*) into n from public.platform_announcements;
  perform pg_temp.ok(n = 2, '24b the owner sees both');
  -- And cannot post one, which is the whole point of the audience column.
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_announce(''{"title":"Free for all","message":"x","ends_at":"%s"}''::jsonb)',
    now() + interval '1 day')),
    '25 and cannot post one to every school on the platform');
  perform pg_temp.ok(pg_temp.refused(format(
    'insert into public.platform_announcements (title, message, ends_at) values (''x'',''y'',''%s'')',
    now() + interval '1 day')),
    '25b nor insert one by hand');
  reset role;

  -- A finished notice stops showing, with no cleanup job.
  perform public._pact('ops');
  perform public.fn_platform_end_announcement(v_id, 'server upgrade finished early');
  perform public._pact('clerk');
  set local role authenticated;
  select count(*) into n from public.platform_announcements;
  perform pg_temp.ok(n = 0,
    '26 ending it early takes it off the clerk''s screen immediately');
  reset role;

  perform public._pact('ops');
  select count(*) into n from public.fn_platform_announcements();
  perform pg_temp.ok(n = 2,
    '27 while the operator still sees both, live or not');
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_end_announcement(%L)', v_id)),
    '28 and one already finished cannot be ended again');
  perform pg_temp.ok(exists (select 1 from public.operator_actions
                              where action = 'announcement_ended'
                                and detail->>'reason' like '%early%'),
    '29 with the reason on record');
end $ann$;

rollback;
