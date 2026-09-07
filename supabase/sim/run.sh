#!/usr/bin/env bash
# Rebuild the simulation from nothing, on the local harness.
#
# NOT FOR A LIVE DATABASE. This drops and recreates a database. The paste-able
# bundle for a real Supabase project is built from these same files by
# scripts/build-sim-bundle.py, which omits the parts below that only make sense
# on a throwaway box (the auth stub, the createdb).
set -euo pipefail
cd "$(dirname "$0")/../.."
export PGHOST=${PGHOST:-/tmp/pgd} PGPORT=${PGPORT:-5455} PGUSER=${PGUSER:-postgres}
DB=${1:-sim}

dropdb --if-exists "$DB"; createdb "$DB"
psql -q -d "$DB" -v ON_ERROR_STOP=1 <<'SQL'
create schema if not exists auth;
create table if not exists auth.users (
  id uuid primary key, email text, raw_app_meta_data jsonb, raw_user_meta_data jsonb,
  encrypted_password text, email_confirmed_at timestamptz, created_at timestamptz default now());
-- The REAL Supabase definition. preflight.sh stubs this to null, which is right
-- for a migration check and useless here: every function in the simulation
-- keys off it. Setting request.jwt.claims is what PostgREST does on a real
-- request, so the seed files are identical on this box and in the SQL editor.
create or replace function auth.uid() returns uuid language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;
create or replace function auth.role() returns text language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$$;
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
end $$;
grant usage on schema public, auth to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to postgres, anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to postgres, anon, authenticated, service_role;
SQL

for f in supabase/migrations/*.sql; do
  psql -q -d "$DB" -v ON_ERROR_STOP=1 -f "$f" >/dev/null
done
echo "migrations: $(ls supabase/migrations/*.sql | wc -l) applied"

# The school and its owner, through the same two calls the Edge Function makes.
psql -q -d "$DB" -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
select public.fn_signup_school(
  'Chaudhary Puclix High School Ghauriii', 'Ghauri Town', 'Majid Choudhary',
  '03001234567', 'majid@chaudharypuclix.pk');
do $$
declare v_school uuid; v_uid uuid := '11111111-0000-0000-0000-000000000001';
begin
  select id into v_school from public.schools
   where name = 'Chaudhary Puclix High School Ghauriii';
  insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data, email_confirmed_at)
  values (v_uid, 'majid@chaudharypuclix.pk',
          jsonb_build_object('school_id', v_school::text, 'role', 'owner'),
          jsonb_build_object('full_name', 'Majid Choudhary'), now())
  on conflict (id) do nothing;
end $$;
SQL
echo "school + owner: created"

for f in supabase/sim/[0-9][0-9]_*.sql; do
  printf '%-40s' "$(basename "$f")"
  start=$(date +%s)
  psql -q -d "$DB" -v ON_ERROR_STOP=1 -f "$f" 2>&1 | sed -E 's/^psql:[^ ]+ //' | grep -E "^(NOTICE|ERROR)" | sed -E 's/^NOTICE:  /    /' || true
  echo "  ($(( $(date +%s) - start ))s)"
done
