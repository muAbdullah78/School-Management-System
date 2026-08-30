-- =============================================================================
-- enforcement.sql — is the database still enforcing its foreign keys?
--
-- Read-only. Paste into the Supabase SQL Editor and Run. Send the whole table
-- back. It writes nothing, locks nothing, and creates nothing that outlives the
-- connection.
--
-- WHY THIS EXISTS
--
-- facts.sql established that one subscription really does name a school that is
-- not there — read as the table owner, with row-level security stood down, by a
-- session that bypasses RLS. Not a reading artefact. And two more rows of that
-- same output make the ordinary explanations impossible:
--
--   subscriptions -> schools  is  ON DELETE CASCADE, validated
--   profiles      -> schools  is  ON DELETE NO ACTION
--   school_settings -> schools is ON DELETE NO ACTION
--
-- Those three cannot produce what is on that database. Reproduced on a build of
-- this exact schema, migration for migration:
--
--   delete from schools where id = '…';
--   ERROR: update or delete on table "schools" violates foreign key constraint
--          "school_settings_school_id_fkey" on table "school_settings"
--
-- An ordinary DELETE is REFUSED. It cannot leave this state, because the first
-- NO ACTION child stops it before anything is removed. So the school row did not
-- go through the front door.
--
-- Now the same delete with foreign keys stood down:
--
--   set session_replication_role = 'replica';
--   delete from schools where id = '…';        -- succeeds
--
--   schools rows               0
--   orphan subscriptions       1      <- the CASCADE never ran
--   orphan school_settings     1      <- the NO ACTION never refused
--   FK reports validated       true   <- unchanged
--
-- That is the live shape exactly. `session_replication_role = 'replica'` turns
-- off every trigger Postgres uses to enforce referential integrity — which is
-- most of what a foreign key IS — and it is the standard advice people find when
-- they search for how to delete a row that a foreign key will not let them
-- delete. It is also what a restore, a point-in-time recovery or a branch reset
-- does while it loads data.
--
-- None of that is a criticism of anyone. It is a mechanism, it fits every
-- reading, and unlike the three explanations before it, it was reproduced before
-- it was written down.
--
-- THE QUESTION THIS FILE ANSWERS IS THE ONE THAT STILL MATTERS
--
-- Whatever removed that school is done. But `session_replication_role` can be
-- set for a session, or PERSISTED onto a role or a database with ALTER ROLE /
-- ALTER DATABASE, and a persisted one comes back on every new connection
-- forever. If that is the state, then no foreign key on this database is being
-- enforced right now — not the tenancy keys, not the invoice-to-payment keys,
-- none — and the next orphan is already on its way.
--
-- Section 1 answers that. It reads `pg_db_role_setting`, which is where a
-- PERSISTED setting lives, rather than only the current session: `ALTER ROLE …
-- SET` takes effect on the NEXT connection, so a session opened before it was
-- set still reports `origin` while every future one is in replica mode. Checking
-- the live session alone would miss precisely the dangerous case.
--
-- Section 2 checks the triggers themselves, because `ALTER TABLE … DISABLE
-- TRIGGER ALL` is the other way to the same place and it is permanent until
-- somebody turns it back on.
--
-- Section 3 stops looking at one table. facts.sql asked five tables by name and
-- found orphans in three of them; this walks EVERY table in `public` that has a
-- school_id column and reports what it finds, so the cleanup is sized against
-- the whole database rather than against the five I happened to think of.
-- =============================================================================

create or replace function pg_temp.ask(p_sql text) returns text
language plpgsql as $ask$
declare v_out text;
begin
  execute p_sql into v_out;
  return coalesce(v_out, '0');
exception when others then
  return 'ERROR: ' || sqlerrm;
end
$ask$;

-- Counts orphans on one table without RLS in the way. SECURITY DEFINER runs as
-- this function's owner, which owns the tables, and row-level security does not
-- apply to a table's owner unless FORCE is set. facts.sql row 20 showed the
-- plain and definer readings agreeing, so this is belt and braces — but the
-- whole point of this round is that a diagnostic should not depend on the
-- reader's privileges to be right.
create or replace function pg_temp.orphans_in(p_table text) returns bigint
language plpgsql security definer as $$
declare v_n bigint;
begin
  execute format(
    'select count(*) from public.%I t
      where t.school_id is not null
        and not exists (select 1 from public.schools sc where sc.id = t.school_id)',
    p_table) into v_n;
  return v_n;
exception when others then
  return -1;                                   -- unreadable; shown as such below
end
$$;

select * from (

  -- ===========================================================================
  -- 1. Is referential integrity switched on?
  -- ===========================================================================
  select 1 as n,
         'session_replication_role, THIS session' as item,
         current_setting('session_replication_role') as value,
         case when current_setting('session_replication_role') = 'origin'
              then 'normal'
              else 'FOREIGN KEYS ARE NOT BEING ENFORCED IN THIS SESSION' end as reading

  union all
  select 2,
         'session_replication_role, PERSISTED on a role or database',
         coalesce((select string_agg(
                     coalesce(r.rolname, 'every role') || ' on ' ||
                     coalesce(d.datname, 'every database') || ' -> ' || s.setting, '; ')
                     from pg_db_role_setting st
                     cross join lateral unnest(st.setconfig) as s(setting)
                     left join pg_roles r on r.oid = st.setrole
                     left join pg_database d on d.oid = st.setdatabase
                    where s.setting like 'session\_replication\_role%'), '(nothing persisted)'),
         case when exists (select 1 from pg_db_role_setting st
                           cross join lateral unnest(st.setconfig) as s(setting)
                           where s.setting like 'session\_replication\_role%'
                             and s.setting not like '%=origin')
              then 'THIS IS THE ONE THAT MATTERS. Every new connection starts with '
                   || 'foreign keys switched off. Clear it: ALTER ROLE <name> RESET '
                   || 'session_replication_role;'
              else 'normal — nothing is persisting a non-enforcing mode' end

  -- ===========================================================================
  -- 2. Are the enforcement triggers themselves still enabled?
  --
  -- A foreign key is enforced by two internal triggers: one on the child table
  -- for inserts and updates, one on the PARENT for deletes. Disabling the
  -- parent's is what lets a school be deleted while its children stay, so both
  -- sides are counted.
  -- ===========================================================================
  union all
  select 10,
         'referential-integrity triggers switched off, whole database',
         coalesce((select string_agg(distinct tg.tgrelid::regclass::text, ', ')
                     from pg_trigger tg
                     join pg_class c on c.oid = tg.tgrelid
                     join pg_namespace ns on ns.oid = c.relnamespace
                    where ns.nspname = 'public'
                      and tg.tgisinternal
                      and tg.tgconstraint <> 0
                      and tg.tgenabled <> 'O'), '(none — all enabled)'),
         case when exists (select 1 from pg_trigger tg
                           join pg_class c on c.oid = tg.tgrelid
                           join pg_namespace ns on ns.oid = c.relnamespace
                          where ns.nspname = 'public' and tg.tgisinternal
                            and tg.tgconstraint <> 0 and tg.tgenabled <> 'O')
              then 'The tables named here are not enforcing their foreign keys. '
                   || 'Re-enable: ALTER TABLE public.<name> ENABLE TRIGGER ALL;'
              else 'normal' end

  -- ===========================================================================
  -- 3. Every table in public with a school_id, and what it holds for a school
  --    that is not there
  --
  -- One row per table WITH orphans. A clean database returns the single "(none)"
  -- row at the bottom of this section and nothing else here.
  -- ===========================================================================
  union all
  select 20 + row_number() over (order by t.relname),
         'orphan rows in ' || t.relname,
         case when pg_temp.orphans_in(t.relname) < 0
              then 'could not read'
              else pg_temp.orphans_in(t.relname)::text end,
         case when t.relname like 'platform\_%' or t.relname like 'operator\_%'
              then 'our own ledger or audit trail — these are UNLINKED, never deleted'
              else 'tenant data belonging to a school that no longer exists' end
    from pg_class t
    join pg_namespace ns on ns.oid = t.relnamespace
    join pg_attribute a on a.attrelid = t.oid and a.attname = 'school_id' and not a.attisdropped
   where ns.nspname = 'public' and t.relkind = 'r'
     and pg_temp.orphans_in(t.relname) <> 0

  union all
  select 90, 'total tables holding orphan rows',
         (select count(*)::text
            from pg_class t
            join pg_namespace ns on ns.oid = t.relnamespace
            join pg_attribute a on a.attrelid = t.oid and a.attname = 'school_id'
                                and not a.attisdropped
           where ns.nspname = 'public' and t.relkind = 'r'
             and pg_temp.orphans_in(t.relname) > 0),
         'if this is 0, there is nothing to clean up'

  union all
  select 91, 'the school ids involved',
         coalesce(pg_temp.ask($q$
           select string_agg(distinct school_id::text, ', ')
             from public.subscriptions s
            where not exists (select 1 from public.schools sc where sc.id = s.school_id)
         $q$), '(none)'),
         'these are the ids to pass to fn_platform_purge_orphan_data, one at a time'

) x order by n;
