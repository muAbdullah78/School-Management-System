-- =============================================================================
-- why.sql — detect.sql says WHAT is missing. This says WHY.
--
-- Paste into the Supabase SQL Editor and Run. It reads only; it writes nothing
-- and creates nothing that outlives the connection.
--
-- WHY IT EXISTS
--
-- detect.sql answers one question per migration — present or missing — and each
-- answer is an AND of up to four separate conditions. When a row says MISSING
-- there is no way to tell which condition failed, and the advice it prints
-- ("run this migration again") is wrong whenever the checker is the thing at
-- fault rather than the database. That has now happened twice in one week:
--
--   * 0059 reported MISSING on a database where it was correctly applied,
--     because detect.sql's exemption list had drifted from verify.sql's. A
--     school re-ran the migration twice, changing nothing, before anybody
--     looked at the checker.
--   * 0070 reported MISSING on a live project and PASSED on an identical local
--     build, and its signature has three parts with nothing to distinguish
--     them.
--
-- A checker that cries wolf teaches the reader to ignore it, and the next time
-- it is right. So this file names OBJECTS, never migrations: the function that
-- still gates a read on has_role, the helper a signed-in user can execute, the
-- subscription row whose school is not there.
--
-- Every row it returns is something to look at. If it returns only rows that
-- say "ok", there is nothing wrong with the things it knows how to check.
-- =============================================================================

-- Reads a scalar from a table that may not exist yet, so this file survives
-- being run against a database missing anything. Postgres resolves every table
-- reference at PARSE time, so a `case when to_regclass(...) is null then ...`
-- guard around a direct read NEVER works — planning fails before any branch is
-- evaluated. It has to be dynamic.
create or replace function pg_temp.ask(p_sql text) returns text
language plpgsql as $ask$
declare v_out text;
begin
  execute p_sql into v_out;
  return v_out;
exception
  when undefined_table then return null;
  when undefined_function then return null;
  when undefined_column then return null;
end
$ask$;

select * from (

-- ---------------------------------------------------------------------------
-- 1. Subscriptions naming a school that does not exist
--
-- The cause of the bundle-6 abort: 0067's backfill walks `subscriptions` and
-- writes a row keyed to `schools`.
-- ---------------------------------------------------------------------------
select 1 as sort, 'orphan subscription' as finding,
       coalesce(pg_temp.ask($q$
         select string_agg(s.school_id::text, ', ')
           from public.subscriptions s
          where not exists (select 1 from public.schools sc where sc.id = s.school_id)
       $q$), '') as object,
       case
         when to_regclass('public.subscriptions') is null then 'n/a — no subscriptions table yet'
         when coalesce(pg_temp.ask($q$
                select count(*)::text from public.subscriptions s
                 where not exists (select 1 from public.schools sc where sc.id = s.school_id)
              $q$), '0') = '0'
           then 'ok — every subscription has its school'
         -- THE CONSTRAINT OUTRANKS THIS QUERY. A validated foreign key means
         -- Postgres has already scanned every row, so a SELECT that still sees
         -- orphans cannot SEE the schools rows rather than proving them absent —
         -- public.schools carries RLS, and a session that is neither its owner
         -- nor BYPASSRLS reads an empty answer. Reproduced. Reporting this as an
         -- orphan sent two rounds of repair after a row that was never wrong.
         when exists (select 1 from pg_constraint c
                      join pg_class t on t.oid = c.conrelid
                      join pg_namespace n on n.oid = t.relnamespace
                      where n.nspname = 'public' and t.relname = 'subscriptions'
                        and c.contype = 'f' and c.convalidated
                        and pg_get_constraintdef(c.oid) ilike '%references%schools(id)%')
           then 'PROBABLY NOT AN ORPHAN. The foreign key on the next line is '
                || 'VALIDATED, which is Postgres''s own statement that it has '
                || 'scanned every row — so the constraint is the one to believe '
                || 'and this query is the one that is wrong. Why it is wrong is '
                || 'not established. Run supabase/repair/facts.sql and send the '
                || 'output rather than deleting anything.'
         else 'These rows cannot be viewed, billed or renewed, and they are what '
              || 'stopped bundle 6. Nothing has deleted them and nothing will — a '
              || 'customer record is the operator''s to decide about. Run '
              || 'supabase/repair/inspect-orphans.sql to see what each one IS '
              || '(an abandoned signup, or a school somebody was actually billed '
              || 'for), delete the ones you have looked at BY ID, then run bundle 9 '
              || '(0091), which puts the foreign key into the state line 2 will '
              || 'tell you it is not in yet.'
       end as what_to_do

union all

-- ---------------------------------------------------------------------------
-- 2. The foreign key that should have made rule 1 impossible
-- ---------------------------------------------------------------------------
select 2, 'subscriptions -> schools foreign key',
       coalesce((select string_agg(c.conname || case when c.convalidated then ''
                                                     else ' (NOT VALID)' end, ', ')
                   from pg_constraint c
                   join pg_class t on t.oid = c.conrelid
                   join pg_namespace n on n.oid = t.relnamespace
                  where n.nspname = 'public' and t.relname = 'subscriptions'
                    and c.contype = 'f'
                    and pg_get_constraintdef(c.oid) ilike '%references%schools(id)%'), ''),
       case
         when to_regclass('public.subscriptions') is null then 'n/a'
         -- THREE states, not two. This row used to say "ok" for a NOT VALID
         -- constraint and printed that beside row 1 reporting an orphan — two
         -- answers that cannot both be true, which is how the real state was
         -- finally noticed. A NOT VALID foreign key exists, matches a
         -- definition test, and guards every FUTURE row, while never having
         -- looked at the rows already there.
         when exists (select 1 from pg_constraint c
                      join pg_class t on t.oid = c.conrelid
                      join pg_namespace n on n.oid = t.relnamespace
                      where n.nspname = 'public' and t.relname = 'subscriptions'
                        and c.contype = 'f' and c.convalidated
                        and pg_get_constraintdef(c.oid) ilike '%references%schools(id)%')
           then 'ok — checked against every existing row, so deleting a school '
                || 'takes its subscription with it and the orphan above cannot recur'
         when exists (select 1 from pg_constraint c
                      join pg_class t on t.oid = c.conrelid
                      join pg_namespace n on n.oid = t.relnamespace
                      where n.nspname = 'public' and t.relname = 'subscriptions'
                        and c.contype = 'f' and not c.convalidated
                        and pg_get_constraintdef(c.oid) ilike '%references%schools(id)%')
           then 'NOT VALID. It refuses every NEW orphan and has never checked the '
                || 'rows that were already there — which is exactly how the row in '
                || 'line 1 survives. Remove that row, then run bundle 9 (0091), '
                || 'which validates the constraint so the state becomes impossible '
                || 'rather than merely absent.'
         else 'MISSING. 0025 declares it, so it has been dropped since — a '
              || 'recreated or restored `schools` does that. Until it is back, '
              || 'every school deleted from now on leaves its subscription '
              || 'behind. Migration 0090 restores it once no orphans remain.'
       end

union all

-- ---------------------------------------------------------------------------
-- 3. 0059 — read gates still on has_role
--
-- The exemption list is the same seven names verify.sql and detect.sql carry;
-- supabase/check-exemption-lists.py keeps those two in step, and this is the
-- third copy that a human reads.
-- ---------------------------------------------------------------------------
select 3, 'read gate still on has_role (0059)',
       coalesce((select string_agg(p.proname, ', ' order by p.proname)
                   from pg_proc p
                  where p.pronamespace = 'public'::regnamespace
                    and p.prosecdef and p.provolatile in ('s','i')
                    and p.prosrc like '%has_role(%'
                    and p.proname not in ('fn_may_manage_class', 'fn_may_write_school_file',
                                          'fn_may_mark_subject', 'fn_pending_invites',
                                          'fn_checkin_display', 'fn_support_visits',
                                          'may_view')), ''),
       case
         when not exists (select 1 from pg_proc where proname = 'may_view'
                           and pronamespace = 'public'::regnamespace)
           then 'may_view does not exist — 0059 has not been applied at all'
         when not exists (select 1 from pg_proc p
                          where p.pronamespace = 'public'::regnamespace
                            and p.prosecdef and p.provolatile in ('s','i')
                            and p.prosrc like '%has_role(%'
                            and p.proname not in ('fn_may_manage_class', 'fn_may_write_school_file',
                                                  'fn_may_mark_subject', 'fn_pending_invites',
                                                  'fn_checkin_display', 'fn_support_visits',
                                                  'may_view'))
           then 'ok — no read gate left on has_role'
         else 'Each function named here returns ZERO ROWS to an observer on a '
              || 'screen the navigation offers them. Either it is a genuine miss '
              || '(re-run 0059) or it authorises a WRITE and belongs in the '
              || 'exemption list in verify.sql AND detect.sql — both, or the '
              || 'lists drift and this row lies.'
       end

union all

-- ---------------------------------------------------------------------------
-- 4. 0070, condition three — internal helpers a signed-in user can call
-- ---------------------------------------------------------------------------
select 4, 'internal fn__ helper callable by a signed-in user (0070)',
       coalesce((select string_agg(p.proname, ', ' order by p.proname)
                   from pg_proc p
                  where p.pronamespace = 'public'::regnamespace
                    and p.proname like 'fn\_\_%'
                    and has_function_privilege('authenticated', p.oid, 'execute')), ''),
       case
         when not exists (select 1 from pg_proc p
                          where p.pronamespace = 'public'::regnamespace
                            and p.proname like 'fn\_\_%'
                            and has_function_privilege('authenticated', p.oid, 'execute'))
           then 'ok — every internal helper is closed'
         else 'Postgres grants EXECUTE to PUBLIC on every function it creates, so '
              || 'a new fn__ helper is open until something revokes it. Migration '
              || '0090 sweeps them; run bundle 8.'
       end

union all

-- ---------------------------------------------------------------------------
-- 5. 0070, conditions one and two — the scoping inside two function bodies
-- ---------------------------------------------------------------------------
select 5, 'family lookup scoped to the caller''s school (0070)',
       'fn_queue_message',
       case
         when not exists (select 1 from pg_proc where proname = 'fn_queue_message'
                           and pronamespace = 'public'::regnamespace)
           then 'fn_queue_message does not exist — bundle 3 has not been applied'
         when exists (select 1 from pg_proc where proname = 'fn_queue_message'
                       and pronamespace = 'public'::regnamespace
                       and prosrc like '%id = p_family_id and school_id = v_school%')
           then 'ok'
         else 'OPEN LEAK. Any signed-in user can name any family on the platform '
              || 'and receive the child''s name back in a rendered message. Re-run '
              || '0070_queue_message_scoping.sql then 0088_wire_the_dead_templates.sql, '
              || 'in that order.'
       end

union all

select 6, 'discount lookup scoped to the caller''s school (0070)',
       'fn__apply_discount_lines',
       case
         when not exists (select 1 from pg_proc where proname = 'fn__apply_discount_lines'
                           and pronamespace = 'public'::regnamespace)
           then 'fn__apply_discount_lines does not exist'
         when exists (select 1 from pg_proc where proname = 'fn__apply_discount_lines'
                       and pronamespace = 'public'::regnamespace
                       and prosrc like '%d.school_id = v_school%')
           then 'ok'
         else 'Re-run 0070_queue_message_scoping.sql.'
       end

union all

-- ---------------------------------------------------------------------------
-- 6. 0067 — the six triggers that keep the student count live
-- ---------------------------------------------------------------------------
select 7, 'student-count triggers (0067)',
       (select count(*)::text || ' of 6'
          from pg_trigger t
          join pg_proc p on p.oid = t.tgfoid
         where not t.tgisinternal
           and p.pronamespace = 'public'::regnamespace
           and p.proname = 'fn__refresh_counts_touched'),
       case
         when (select count(*) from pg_trigger t
                 join pg_proc p on p.oid = t.tgfoid
                where not t.tgisinternal
                  and p.pronamespace = 'public'::regnamespace
                  and p.proname = 'fn__refresh_counts_touched') = 6
           then 'ok — the console and the licence banner see the real roll'
         else 'Without all six, a school can outgrow its plan and neither the '
              || 'operator nor the school finds out: the console shows whatever '
              || 'the count was when somebody last pressed Refresh. Run bundle 8 '
              || '(0090), which installs them and cannot be stopped by a bad row.'
       end

union all

-- ---------------------------------------------------------------------------
-- 7. 0086 — the money tables, still closed?
-- ---------------------------------------------------------------------------
select 8, 'money tables writable from a session (0086)',
       coalesce((select string_agg(distinct t, ', ' order by t)
                   from unnest(array[
                          'invoices', 'invoice_lines', 'payments', 'payment_allocations',
                          'adjustments', 'discounts', 'result_cards', 'certificates',
                          'certificate_cancellations', 'deposit_refunds',
                          'student_fee_items', 'fee_heads', 'fee_structures', 'families'
                        ]) t,
                        unnest(array['authenticated', 'anon']) r,
                        unnest(array['insert', 'update', 'delete']) v
                  where to_regclass('public.' || t) is not null
                    and has_table_privilege(r, 'public.' || t, v)), ''),
       case
         when not exists (
                select 1 from unnest(array[
                       'invoices', 'invoice_lines', 'payments', 'payment_allocations',
                       'adjustments', 'discounts', 'result_cards', 'certificates',
                       'certificate_cancellations', 'deposit_refunds',
                       'student_fee_items', 'fee_heads', 'fee_structures', 'families'
                     ]) t,
                     unnest(array['authenticated', 'anon']) r,
                     unnest(array['insert', 'update', 'delete']) v
                 where to_regclass('public.' || t) is not null
                   and has_table_privilege(r, 'public.' || t, v))
           then 'ok — every change goes through a function that records who and why'
         else 'A clerk can rewrite these directly over the API, with no audit row. '
              || 'Re-run bundle 7 (0086).'
       end

) x order by sort;
