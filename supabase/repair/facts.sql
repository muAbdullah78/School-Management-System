-- =============================================================================
-- facts.sql — raw readings, no interpretation
--
-- Read-only. Paste into the Supabase SQL Editor and Run. Send the whole table
-- back.
--
-- WHY THIS EXISTS, AND WHY IT DELIBERATELY CONCLUDES NOTHING
--
-- One subscription row on a live project has now been explained wrongly three
-- times, and each explanation shipped a fix built on an inference:
--
--   1. "the foreign key is missing"    → 0090 restored it. It was not missing.
--   2. "the foreign key is NOT VALID"  → 0091 validated it. It reports itself
--                                        validated already.
--   3. "then a reader cannot SEE the school, because of RLS" → that mechanism is
--                                        real, and on THIS schema `subscriptions`
--                                        carries RLS too, so a session that
--                                        cannot see a school cannot see its
--                                        subscription either and both vanish
--                                        together. Which is not the live shape.
--
-- Every one was a reasonable reading of a diagnostic that summarises. The
-- summarising is the problem: each file in this directory turns readings into
-- advice, and when the underlying assumption is wrong the advice is confidently
-- wrong.
--
-- So this one prints numbers and names and stops. No verdicts, no "ok", no
-- recommendation. Whatever is true will be in here, and the reasoning happens
-- afterwards, out loud, against facts.
--
-- ONE QUERY, ONE RESULT TABLE. It used to be seven statements with \echo
-- headings, which is a psql habit: the Supabase SQL Editor shows only the LAST
-- result of a multi-statement script and ignores backslash commands, so six
-- sevenths of it would have been invisible in the one place it is meant to be
-- pasted. A diagnostic that cannot be read where it is used is not a diagnostic.
--
-- AND THEN SECTION 6 GOT ITS OWN QUESTION WRONG, WHICH IS WORTH LEAVING HERE.
--
-- Its five counts originally read `where not exists (select 1 from schools ...)`
-- with no NULL guard. That does not mean "rows whose school is missing". When
-- school_id is NULL, `sc.id = NULL` is never true, so `not exists` is TRUE and
-- the row is counted as an orphan — and a NULL school_id is the DESIGNED state
-- for several of the tables asked about: a platform operator's `profiles` row
-- has no school, and 0080 made the platform ledger nullable on purpose so it
-- survives a customer being purged.
--
-- So on the live project this file reported `profiles rows on such an id: 1`,
-- which was the operator's own account, and that number went straight into a
-- written claim that the orphan spanned three tables. It spanned two. A file
-- whose entire purpose is to print facts instead of inferences printed a wrong
-- fact, and the inference built on it was mine.
--
-- Guarded now, everywhere, and supabase/check-orphan-queries.py fails CI on any
-- sweep that leaves the guard out.
--
-- Nothing here writes, locks or creates anything outside the connection.
-- =============================================================================

create or replace function pg_temp.ask(p_sql text) returns text
language plpgsql as $ask$
declare v_out text;
begin
  execute p_sql into v_out;
  return v_out;
exception when others then
  return 'ERROR: ' || sqlerrm;
end
$ask$;

-- Runs as its OWNER, which owns these tables, so row-level security does not
-- apply to it. If section 3 disagrees with section 2, the plain SELECTs are the
-- thing that cannot see the rows.
create or replace function pg_temp.definer_counts()
returns text language sql security definer as $$
  select (select count(*) from public.schools)::text || ' school(s), '
      || (select count(*) from public.subscriptions)::text || ' subscription(s), '
      || (select count(*) from public.subscriptions x
           where x.school_id is not null
             and not exists (select 1 from public.schools sc
                              where sc.id = x.school_id))::text
      || ' with no school'
$$;

select * from (

  -- 1. who is asking, and can they see everything?
  select 1 as n, 'who am I'             as item, current_user::text                as value
  union all select 2, 'session_user',    session_user::text
  union all select 3, 'is superuser',    coalesce((select rolsuper::text     from pg_roles where rolname = current_user), '?')
  union all select 4, 'bypasses RLS',    coalesce((select rolbypassrls::text from pg_roles where rolname = current_user), '?')
  union all select 5, 'schools owned by',
                     coalesce(pg_get_userbyid((select relowner from pg_class where oid = 'public.schools'::regclass)), '?')
  union all select 6, 'schools RLS enabled / forced',
                     coalesce((select relrowsecurity::text || ' / ' || relforcerowsecurity::text
                                 from pg_class where oid = 'public.schools'::regclass), '?')
  union all select 7, 'subscriptions RLS enabled / forced',
                     coalesce((select relrowsecurity::text || ' / ' || relforcerowsecurity::text
                                 from pg_class where oid = 'public.subscriptions'::regclass), '?')

  -- 2. what a plain SELECT can see
  union all select 10, 'schools rows visible',       pg_temp.ask('select count(*) from public.schools')
  union all select 11, 'subscription rows visible',  pg_temp.ask('select count(*) from public.subscriptions')
  union all select 12, 'subscriptions whose school is NOT visible',
                       pg_temp.ask('select count(*) from public.subscriptions s
                                     where s.school_id is not null
                                       and not exists (select 1 from public.schools sc
                                                        where sc.id = s.school_id)')

  -- 3. the same counts with RLS stood down
  union all select 20, 'the same, read as the table owner', pg_temp.definer_counts()

  -- 4. every school id, and every subscription id
  union all select 30, 'school ids',
                       coalesce(pg_temp.ask('select string_agg(id::text, '', '' order by id) from public.schools'), '(none)')
  union all select 31, 'subscription ids',
                       coalesce(pg_temp.ask('select string_agg(school_id::text, '', '' order by school_id) from public.subscriptions'), '(none)')
  union all select 32, 'ids in subscriptions that are not in schools',
                       coalesce(pg_temp.ask('select string_agg(s.school_id::text, '', '')
                                               from public.subscriptions s
                                              where s.school_id is not null
                                                and not exists (select 1 from public.schools sc
                                                                 where sc.id = s.school_id)'), '(none)')

  -- 5. every foreign key on subscriptions, with the flag that matters
  union all
  select 40 + row_number() over (order by c.conname),
         'FK ' || c.conname,
         'validated=' || c.convalidated::text
           || ' deferrable=' || c.condeferrable::text
           || ' :: ' || pg_get_constraintdef(c.oid)
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
   where n.nspname = 'public' and t.relname = 'subscriptions' and c.contype = 'f'

  -- 6. anything else pointing at an id that is not in schools
  union all select 60, 'profiles rows on such an id',
                       pg_temp.ask('select count(*) from public.profiles p
                                     where p.school_id is not null
                                       and not exists (select 1 from public.schools sc
                                                        where sc.id = p.school_id)')
  union all select 61, 'students rows on such an id',
                       pg_temp.ask('select count(*) from public.students p
                                     where p.school_id is not null
                                       and not exists (select 1 from public.schools sc
                                                        where sc.id = p.school_id)')
  union all select 62, 'school_settings rows on such an id',
                       pg_temp.ask('select count(*) from public.school_settings p
                                     where p.school_id is not null
                                       and not exists (select 1 from public.schools sc
                                                        where sc.id = p.school_id)')
  union all select 63, 'platform_invoices rows on such an id',
                       pg_temp.ask('select count(*) from public.platform_invoices p
                                     where p.school_id is not null
                                       and not exists (select 1 from public.schools sc
                                                        where sc.id = p.school_id)')
  union all select 64, 'operator_actions rows on such an id',
                       pg_temp.ask('select count(*) from public.operator_actions p
                                     where p.school_id is not null
                                       and not exists (select 1 from public.schools sc
                                                        where sc.id = p.school_id)')

) x order by n;
