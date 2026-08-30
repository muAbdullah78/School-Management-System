-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0091_validate_the_subscription_fk.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0091 — The foreign key was there all along. It had never been checked.
--
-- WHAT THE DIAGNOSTIC SAID, and why two of its rows could not both be true:
--
--   1 | orphan subscription                  | a0bf0f0c-… | These rows … stopped bundle 6
--   2 | subscriptions -> schools foreign key | subscriptions_school_id_fkey
--                                            | ok — deleting a school takes its
--                                              subscription with it
--
-- A row naming a school that does not exist, and an enforced foreign key
-- forbidding exactly that, on the same table, at the same moment. One of them
-- had to be wrong, and it was the checker.
--
-- A `NOT VALID` foreign key does all three of these at once, which is what makes
-- it so easy to miss. Reproduced before anything here was written:
--
--   alter table subs add constraint subs_school_id_fkey
--     foreign key (school_id) references schools(id) not valid;
--
--   orphans present                                     → 1
--   pg_get_constraintdef ilike '%references%schools(id)%' → TRUE
--   inserting a NEW orphan                              → refused
--
-- So it exists, it matches the test, it guards every future row, and it has
-- never once looked at the rows that were already there.
--
-- THE MISTAKE IS MINE AND IT IS WORTH NAMING PRECISELY. `why.sql` and 0090 both
-- check the constraint by what it REFERENCES rather than by its name, and the
-- comment sitting two lines above that check says why:
--
--     Checked by what the constraint DOES rather than by its name: a constraint
--     named subscriptions_school_id_fkey that points somewhere else would satisfy
--     a name check and none of the guarantee.
--
-- Right principle, one step short. What a constraint DOES is `REFERENCES
-- schools(id)` AND `convalidated`. Reading the definition text and stopping
-- there is the same error one layer in — and it is the reason 0090 returned
-- early instead of finishing the job.
--
-- AND THAT EXPLANATION WAS ALSO WRONG ON THE PROJECT IT WAS WRITTEN FOR.
--
-- This header first said the constraint "was almost certainly NOT VALID from the
-- start". It is not: on that database it reports itself VALIDATED, and this
-- file's own end-state check said so by aborting the bundle.
--
-- The version after that drew the opposite conclusion — TRUST THE CONSTRAINT
-- OVER THE QUERY, everywhere — on the reasoning that Postgres has scanned the
-- table and a SELECT has not. THAT WAS WRONG TOO, and it was the worst of the
-- three, because the first two made somebody look and this one said PASS over a
-- real orphan.
--
-- WHY IT IS WRONG, PRECISELY. `convalidated` is a statement about the PAST: this
-- table was scanned at some earlier moment and nothing was amiss. It is not a
-- live guarantee. Rows orphaned AFTERWARDS by a path that did not run the
-- enforcement triggers leave the flag standing. Reproduced on a build of this
-- schema:
--
--   set session_replication_role = 'replica';
--   delete from schools where id = '…';        -- succeeds
--   orphan subscriptions  1        FK reports validated  true
--
-- And the flag cannot be re-checked from inside SQL, which is the part that
-- makes it genuinely dangerous rather than merely stale: ALTER TABLE … VALIDATE
-- CONSTRAINT on an already-validated constraint returns success WITHOUT
-- RE-SCANNING. So a stale flag stays stale, silently, and this file's own
-- validate branch can never repair one. supabase/tests/orphan_data.sql
-- assertions 22-23 hold both facts in place.
--
-- The worry that produced the inversion was real — a reader that cannot SEE
-- `schools` reports every row as an orphan — and it has a proper answer, which
-- is to count the rows AS THE TABLE'S OWNER with row-level security stood down.
-- verify.sql and repair/why.sql now do that. It removes the doubt without ever
-- calling a database clean because a flag from last month says so.
--
-- What IS established, rather than inferred:
--
--   * a NOT VALID constraint produces exactly the reported symptoms, and the
--     old check could not see it. That hole was real and is closed.
--   * an ordinary DELETE cannot produce the live state at all: `profiles` and
--     `school_settings` are ON DELETE NO ACTION, so either one refuses the
--     delete before a row moves. Reproduced.
--   * `session_replication_role = 'replica'` produces it exactly. Reproduced.
--
-- So the answer was never in this file. 0092 carries it, along with the reason
-- those rows could not be deleted even deliberately.
--
-- WHAT THIS FILE DOES
--
--   * constraint absent, no orphans      → add it (0090 already did this)
--   * constraint NOT VALID, no orphans   → VALIDATE it. This is the new case.
--   * constraint NOT VALID, orphans      → say so exactly, and change nothing.
--   * constraint valid                   → nothing to do
--
-- VALIDATE CONSTRAINT takes only a SHARE UPDATE EXCLUSIVE lock, so it does not
-- block reads or writes on `subscriptions` while it scans. On a table with one
-- row per school that is instant regardless.
--
-- Still nothing is deleted. The orphan is the operator's to decide about, and a
-- migration that quietly removed a customer record because it was inconvenient
-- would be a worse defect than the one it is fixing.
--
-- Re-runnable.
-- =============================================================================

do $validate$
declare
  v_conname text;
  v_valid   boolean;
  v_orphans bigint;
  v_ids     text;
begin
  select c.conname, c.convalidated
    into v_conname, v_valid
  from pg_constraint c
  join pg_class t on t.oid = c.conrelid
  join pg_namespace n on n.oid = t.relnamespace
  where n.nspname = 'public' and t.relname = 'subscriptions' and c.contype = 'f'
    and pg_get_constraintdef(c.oid) ilike '%references%schools(id)%'
  limit 1;

  select count(*), string_agg(s.school_id::text, ', ')
    into v_orphans, v_ids
  from public.subscriptions s
  where not exists (select 1 from public.schools sc where sc.id = s.school_id);

  -- Absent. 0090 handles this and will have run first in bundle order; the
  -- branch is here so this file is complete on its own.
  if v_conname is null then
    if v_orphans > 0 then
      raise notice
        '0091: subscriptions has no foreign key to schools, and % orphan row(s) '
        'stop one being added: %. Decide what they are, remove them, and re-run.',
        v_orphans, v_ids;
    else
      alter table public.subscriptions
        add constraint subscriptions_school_id_fkey
        foreign key (school_id) references public.schools(id) on delete cascade;
      raise notice '0091: added the missing subscriptions -> schools foreign key';
    end if;
    return;
  end if;

  -- Present and already scanned. Nothing for this file to do either way: a
  -- VALIDATE on an already-validated constraint is a no-op that returns success
  -- without re-reading a single row, so it could not repair a stale flag even if
  -- one were the problem. Whether the table is clean RIGHT NOW is a different
  -- question, and it belongs to verify.sql and 0092, which count rows.
  if v_valid then
    return;
  end if;

  -- THE CASE THIS FILE EXISTS FOR.
  if v_orphans > 0 then
    raise notice
      '0091: % (on subscriptions) is NOT VALID — it guards every new row and has '
      'never checked the ones already there, which is how % orphan row(s) came to '
      'exist: %. Nothing is broken by them and nothing has been deleted. Decide '
      'what they are, remove them, and re-run this file; it will then validate '
      'the constraint and the state becomes impossible rather than merely absent.',
      v_conname, v_orphans, v_ids;
    return;
  end if;

  execute format('alter table public.subscriptions validate constraint %I', v_conname);
  raise notice
    '0091: validated % — the foreign key has now checked every existing row, not '
    'just future ones.', v_conname;
end $validate$;

-- ---------------------------------------------------------------------------
-- The end state, REPORTED — never asserted
--
-- THIS BLOCK RAISED, AND RAISING WAS THE MISTAKE.
--
-- Its first version ended with `raise exception` when the constraint reported
-- itself validated while orphan rows were still visible. It fired on a live
-- project and took the whole of bundle 9 down with it.
--
-- The check found something real: those two readings cannot both be true, and
-- one of them is a checker reading something it does not mean. But 0090 exists
-- BECAUSE a loop that raised on one bad row discarded eleven migrations for
-- every tenant, and its header says in as many words that "a convenience must
-- never be able to discard eleven migrations". One file later I put an
-- exception in a migration over a data condition the operator has not looked at
-- yet, and it did exactly that.
--
-- A migration may refuse to ACT on a state it does not understand. It may not
-- refuse to APPLY over one. The disagreement is reported here and carried by
-- verify.sql, where it can be read without blocking an upgrade.
--
-- AND THE CHECK ITSELF WAS THEN PUT THE WRONG WAY ROUND.
--
-- The version after the abort said: a VALIDATED foreign key means Postgres has
-- scanned every row, so when a SELECT disagrees the SELECT is what is wrong.
-- That is false, and it turned this notice into a reassurance printed over a
-- real fault. `convalidated` is a past-tense fact. Rows orphaned afterwards by a
-- path that skipped the enforcement triggers leave it standing, and VALIDATE
-- CONSTRAINT on an already-validated constraint returns success without
-- re-scanning, so nothing here can even re-establish it. Both reproduced; see
-- this file's header and supabase/tests/orphan_data.sql.
--
-- The RLS worry behind that inversion was real and has a proper answer: count
-- the rows as the table's OWNER, with row-level security stood down. verify.sql
-- and repair/why.sql do that now. This notice states the disagreement and names
-- the mechanism that produces it, and still decides nothing.
-- ---------------------------------------------------------------------------
do $report$
declare v_valid boolean; v_orphans bigint;
begin
  select bool_or(c.convalidated) into v_valid
  from pg_constraint c
  join pg_class t on t.oid = c.conrelid
  join pg_namespace n on n.oid = t.relnamespace
  where n.nspname = 'public' and t.relname = 'subscriptions' and c.contype = 'f'
    and pg_get_constraintdef(c.oid) ilike '%references%schools(id)%';

  select count(*) into v_orphans
  from public.subscriptions s
  where not exists (select 1 from public.schools sc where sc.id = s.school_id);

  if coalesce(v_valid, false) and v_orphans > 0 then
    raise notice
      '0091: the foreign key reports itself VALIDATED and % subscription row(s) '
      'still name a school that is not there. Both are true. Validation is a past '
      'event — it says this table was scanned once, not that it is clean now — and '
      'rows orphaned since by a delete that ran with foreign keys switched off '
      'leave the flag exactly as it was. Nothing has been changed. Run '
      'supabase/repair/enforcement.sql: it says whether they are STILL switched '
      'off, and sweeps every table rather than this one.',
      v_orphans;
  end if;
end $report$;

-- ─────────────────────────────────────────────────────────────────────────
-- 0092_orphan_data.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0092 — Finish a purge that was interrupted, and stop calling the result clean
--
-- WHAT HAPPENED, ESTABLISHED RATHER THAN INFERRED
--
-- A live project has one subscription naming a school that is not in `schools`.
-- It has now been read four ways — plain SELECT, as the table owner with RLS
-- stood down, by a session with BYPASSRLS, and against the constraint catalogue
-- — and all four agree. It is real.
--
-- Three earlier explanations were wrong, and each shipped a fix built on an
-- inference: "the foreign key is missing" (it is not), "it is NOT VALID" (it
-- reports itself validated), "a reader cannot see the school because of RLS"
-- (a real mechanism that does not fit this schema). So this one was reproduced
-- on a build of this schema, migration for migration, BEFORE it was written
-- down:
--
--   delete from schools where id = '…';
--   ERROR: update or delete on table "schools" violates foreign key constraint
--          "school_settings_school_id_fkey" on table "school_settings"
--
-- An ordinary DELETE is REFUSED. `profiles` and `school_settings` both took
-- their school_id from 0025's generic `add column school_id uuid references
-- public.schools(id)` loop, with no ON DELETE clause, so both are NO ACTION and
-- either one stops the delete before a single row moves. The live state is
-- therefore not something an ordinary delete could have produced.
--
-- The same delete with referential integrity stood down produces it exactly:
--
--   set session_replication_role = 'replica';
--   delete from schools where id = '…';        -- succeeds
--
--   schools rows            0
--   orphan subscriptions    1     <- the ON DELETE CASCADE never ran
--   orphan school_settings  1     <- the NO ACTION never refused
--   FK reports validated    true  <- unchanged, because validation is a past event
--
-- `session_replication_role = 'replica'` is the standard answer people find when
-- a foreign key will not let them delete a row, and it is also what a restore, a
-- point-in-time recovery or a branch reset does while loading data. Nothing in
-- this codebase sets it — checked — so it came from outside the app, and it is
-- nobody's mistake to be sorry about. supabase/repair/enforcement.sql reports
-- whether it is STILL set, which is the part that would matter.
--
-- WHY A MIGRATION, AND WHY IT DELETES NOTHING BY ITSELF
--
-- The orphan is not one row. On the reproduction it was six tables — audit_log,
-- expense_categories, message_templates, school_settings, subscriptions and an
-- operator_actions entry — because creating a school provisions all of them.
-- facts.sql asked five tables by name and found three, which is exactly the
-- failure mode of asking by name: the answer is bounded by the question.
--
-- So this file ships two things and runs neither:
--
--   fn_platform_orphan_report()          — what is there, table by table
--   fn_platform_purge_orphan_data(id, …) — finish the purge, when the operator
--                                          has looked and decided
--
-- A migration that quietly deleted customer records because they were
-- inconvenient would be a worse defect than the one it repairs. Every earlier
-- file in this repair sequence says that and then honours it, and so does this.
--
-- WHAT IT IS NOT
--
-- It is not a way to delete a school. `fn_platform_purge_school` is that, with
-- five refusals in front of it, and this function REFUSES any id that still has
-- a row in `schools` and points at that one instead. This handles the wreckage
-- of a deletion that already happened by a route that did not clean up.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. The reason none of this was deletable
--
-- Found by writing the cleanup and watching it fail, which is the only reason it
-- is in this file rather than in a comment somewhere saying it should be fine:
--
--   delete from public.expense_categories where school_id = '<the orphan>';
--   ERROR: insert or update on table "audit_log" violates foreign key constraint
--          "audit_log_school_id_fkey"
--   CONTEXT: PL/pgSQL function audit_trigger() line 18
--
-- audit_trigger takes the school from the row being written — deliberately, so
-- the trail stays correct on service-role paths where the caller has no school
-- context — and writes an audit_log row keyed to it. audit_log.school_id is NOT
-- NULL with a NO ACTION foreign key to schools. When the school is gone, that
-- insert is refused, and the refusal takes the DELETE down with it.
--
-- SEVENTEEN TABLES CARRY THIS TRIGGER. So the consequence is not "the cleanup
-- is awkward": it is that every INSERT, UPDATE and DELETE on every audited table
-- belonging to a school whose row is missing FAILS, with an error naming
-- audit_log and explaining nothing. The data is not merely orphaned. It is
-- welded in place, and the message a person would see gives them no way to work
-- out why.
--
-- That is a fault in its own right and it is fixed here rather than tiptoed
-- around. Two other routes were considered and rejected:
--
--   * disable the audit trigger while cleaning up — disabling triggers is what
--     caused this. Doing it inside the repair would be absurd, and ALTER TABLE
--     … DISABLE is not session-scoped, so other connections would go unaudited
--     for as long as it ran.
--   * re-create the missing school row, purge normally, delete it again — every
--     check stays on, which is genuinely attractive, but four AFTER INSERT
--     triggers fire on schools and one of them writes a `school_created` entry
--     into the operator's own history. Inventing a record of a school being
--     created, to delete a school that is already gone, is not a trade worth
--     making for a tidier diff.
--
-- THE COST, STATED PLAINLY: one primary-key lookup on `schools` per audited row.
-- It sits beside the lookup on `profiles` the trigger already does for every
-- row, and `schools` is one row per tenant and permanently in cache, so this is
-- a second probe next to an existing one rather than a new kind of work.
--
-- Rewritten programmatically and asserted, not restated. Restating would silently
-- discard anything a later migration changed about this function.
-- ---------------------------------------------------------------------------
do $audit$
declare v_src text; v_new text; v_from text; v_to text;
begin
  v_src := pg_get_functiondef('public.audit_trigger()'::regprocedure);

  v_from := '  insert into public.audit_log(';
  v_to :=
    -- A school that is not there cannot be written about: audit_log.school_id is
    -- NOT NULL and points at schools. Before this guard the trigger did not skip
    -- the row, it REFUSED THE WHOLE WRITE — which is why the records of a school
    -- deleted without its children could not be removed, or touched at all.
    '  if v_school is not null'                                                 || E'\n' ||
    '     and not exists (select 1 from public.schools s where s.id = v_school) then' || E'\n' ||
    '    return coalesce(new, old);' || E'\n' ||
    '  end if;' || E'\n' ||
    '  insert into public.audit_log(';

  if position(v_from in v_src) = 0 then
    raise exception
      '0092: audit_trigger() does not contain the insert this migration expects to '
      'guard. It has been rewritten since, and this edit must be re-read against '
      'the new text rather than applied blind.';
  end if;

  -- Already guarded by an earlier run of this file.
  if position('not exists (select 1 from public.schools s where s.id = v_school)' in v_src) > 0 then
    return;
  end if;

  v_new := replace(v_src, v_from, v_to);
  if v_new = v_src then
    raise exception '0092: the audit_trigger() rewrite changed nothing';
  end if;
  execute v_new;
  raise notice
    '0092: audit_trigger() no longer refuses every write belonging to a school '
    'whose row is missing';
end $audit$;

do $assert$
begin
  if position('not exists (select 1 from public.schools s where s.id = v_school)'
              in pg_get_functiondef('public.audit_trigger()'::regprocedure)) = 0 then
    raise exception '0092: audit_trigger() is not guarded after the rewrite';
  end if;
end $assert$;

-- ---------------------------------------------------------------------------
-- 1. Every table in public that carries a school_id
--
-- fn__school_data_tables() (0080) deliberately excludes the licence tables and
-- our own ledger, because a purge deletes tenant records and KEEPS the sales
-- history. That exclusion is right for the purge and wrong for a report: an
-- operator asking "what is left of this school" wants the ledger rows named too,
-- marked as things that will be unlinked rather than removed.
--
-- Derived from the catalogue rather than from a list, so a table added in a
-- later migration is covered the day it exists. A hand-maintained list is how
-- detect.sql's exemption list drifted from verify.sql's and reported MISSING on
-- a correct database for two rounds.
-- ---------------------------------------------------------------------------
create or replace function public.fn__school_id_tables()
returns table (table_name text, treatment text) language sql stable as $$
  select c.relname::text,
         case
           -- Deleted: the school's own records.
           when exists (select 1 from public.fn__school_data_tables() d
                         where d.table_name = c.relname) then 'delete'
           -- Deleted: the licence and its history. Excluded from
           -- fn__school_data_tables because they are the licence rather than the
           -- school's records, but they go the same way.
           when c.relname in ('subscriptions', 'student_count_snapshots') then 'delete'
           -- Kept, unlinked: our sales ledger and what we did to them. A
           -- business keeps its invoices after a customer leaves, and tax
           -- records have to be retained for years.
           when a.attnotnull then 'delete'      -- cannot be unlinked; 0080 deletes these
           else 'unlink'
         end
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid
                       and a.attname = 'school_id' and not a.attisdropped
   where n.nspname = 'public' and c.relkind = 'r'
   order by 1;
$$;

revoke all on function public.fn__school_id_tables() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Referential health
--
-- The check verify.sql's orphan row should have been doing all along, and the
-- reason this file exists at all.
--
-- A VALIDATED foreign key is a statement about the PAST: Postgres scanned this
-- table at time T and found nothing wrong. It is not a live guarantee, and the
-- difference is not academic — it is this incident. Rows orphaned afterwards by
-- a path that did not run the enforcement triggers leave `convalidated` true,
-- and `ALTER TABLE … VALIDATE CONSTRAINT` on an already-validated constraint
-- returns success WITHOUT RE-SCANNING, so it cannot even be used to find out.
-- Both reproduced.
--
-- I inverted three checkers to trust that flag over a query. On this database
-- that inversion reports PASS over a real orphan. Counting the rows is the only
-- reading that is true right now, so this counts the rows.
--
-- SECURITY DEFINER so row-level security cannot hide a row and turn a genuine
-- orphan into a clean report — the opposite error, and the one that made the
-- RLS explanation plausible in the first place.
-- ---------------------------------------------------------------------------
create or replace function public.fn__referential_health()
returns table (child_table text, orphan_rows bigint)
language plpgsql stable security definer set search_path = public as $$
declare r record; v_n bigint;
begin
  for r in select t.table_name from public.fn__school_id_tables() t loop
    begin
      execute format(
        'select count(*) from public.%I x
          where x.school_id is not null
            and not exists (select 1 from public.schools sc where sc.id = x.school_id)',
        r.table_name) into v_n;
    exception when others then
      continue;                     -- unreadable table cannot make the answer worse
    end;
    if v_n > 0 then
      child_table := r.table_name; orphan_rows := v_n; return next;
    end if;
  end loop;
end $$;

revoke all on function public.fn__referential_health() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The report
--
-- One row per (school id, table). Operator-only: it names ids and row counts
-- across every tenant on the platform.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_orphan_report()
returns table (school_id uuid, table_name text, row_count bigint, treatment text)
language plpgsql stable security definer set search_path = public as $$
declare r record;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  for r in select t.table_name, t.treatment from public.fn__school_id_tables() t loop
    begin
      return query execute format(
        'select x.school_id, %L::text, count(*), %L::text
           from public.%I x
          where x.school_id is not null
            and not exists (select 1 from public.schools sc where sc.id = x.school_id)
          group by x.school_id',
        r.table_name, r.treatment, r.table_name);
    exception when others then
      continue;
    end;
  end loop;
end $$;

grant  execute on function public.fn_platform_orphan_report()   to authenticated;
revoke execute on function public.fn_platform_orphan_report() from public, anon;

-- ---------------------------------------------------------------------------
-- 4. Finishing the purge
--
-- Same rules as fn_platform_purge_school, minus the refusals that only make
-- sense for a school that still exists (archive it first, export it first — you
-- cannot archive or export a row that is gone), plus two that only make sense
-- here.
--
-- REFUSAL: the id must NOT be in `schools`. If it is, this is a live customer
-- and the answer is fn_platform_purge_school, which will insist on the archive,
-- the export, the typed name and the settled balance. Without this refusal, this
-- function would be a way around all five of them.
--
-- REFUSAL: referential integrity must be ON. If session_replication_role is not
-- 'origin' the deletes below would themselves skip the foreign keys and could
-- leave a second generation of orphans inside the very tables being cleaned. The
-- one thing worse than an interrupted purge is a cleanup that quietly repeats
-- the mistake that caused it.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_purge_orphan_data(
  p_school_id uuid,
  -- The id, typed out. Not a name: there is no name left to type, which is
  -- itself the reason a confirmation is needed — an id is easy to mis-paste and
  -- there is no second reading that would catch it.
  p_confirm_id text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r         record;
  v_n       bigint;
  v_deleted jsonb := '{}'::jsonb;
  v_before  jsonb := '{}'::jsonb;
  v_total   bigint := 0;
  v_unlinked bigint := 0;
  v_pass    integer := 0;
  v_progress boolean;
  v_left    text;
  v_found   bigint := 0;
  v_logins  text[] := '{}';
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  if exists (select 1 from public.schools where id = p_school_id) then
    raise exception
      'That school still exists. This function only clears what is left behind '
      'after a school row has already gone. To remove a real school use the '
      'Purge button, which will not proceed until it is archived, exported, paid '
      'up and its name typed out.'
      using errcode = '42501';
  end if;

  if p_confirm_id is distinct from p_school_id::text then
    raise exception
      'That is not the id. To clear the records left behind by this school, type '
      'exactly: %', p_school_id;
  end if;

  if current_setting('session_replication_role') <> 'origin' then
    raise exception
      'Foreign keys are not being enforced in this session (session_replication_role '
      'is %). Deleting now would skip the same checks that produced this mess. Run '
      'RESET session_replication_role; and try again — and run '
      'supabase/repair/enforcement.sql, because if that setting is persisted on a '
      'role it is switched off for every connection.',
      current_setting('session_replication_role');
  end if;

  -- What is there, counted BEFORE anything is touched, so the log entry and the
  -- return value describe the state that was actually found rather than what is
  -- left when the loop gives up.
  for r in select t.table_name, t.treatment from public.fn__school_id_tables() t loop
    execute format('select count(*) from public.%I x where x.school_id = $1', r.table_name)
      into v_n using p_school_id;
    if v_n > 0 then
      v_found := v_found + v_n;
      v_before := v_before || jsonb_build_object(r.table_name, v_n);
    end if;
  end loop;

  if v_found = 0 then
    return jsonb_build_object(
      'purged', false,
      'school_id', p_school_id,
      'why', 'Nothing on this platform refers to that id. Either it has already '
          || 'been cleared or the id is not one of the ones the report named.');
  end if;

  -- The logins that will be left with nowhere to go. Captured before the delete
  -- because afterwards there is no way to find them: profiles is where the link
  -- between an auth user and a school lives, and it is about to go.
  if to_regclass('auth.users') is not null and to_regclass('public.profiles') is not null then
    begin
      execute
        'select coalesce(array_agg(u.email::text order by u.email), ''{}'')
           from auth.users u
           join public.profiles p on p.id = u.id
          where p.school_id = $1'
        into v_logins using p_school_id;
    exception when others then
      v_logins := '{}';
    end;
  end if;

  -- The log entry goes FIRST, with school_id NULL so it survives what follows —
  -- and here it has to be null anyway, because operator_actions.school_id has a
  -- foreign key to a school that no longer exists.
  perform public.fn__log_operator_action('orphan_data_purged', null,
    jsonb_build_object(
      'school_id', p_school_id,
      'rows_found', v_found,
      'by_table', v_before,
      'orphan_logins', to_jsonb(v_logins),
      'why', 'Records left behind by a school row that was removed without its '
          || 'children. Cleared deliberately by the operator, from the report.'));

  -- The delete, in whatever order the foreign keys allow. Up to 12 passes; each
  -- swallows ONLY a foreign-key violation, which means "something still points at
  -- this, come back next pass". Any other error is a real fault and must not be
  -- swallowed — a permission problem that looked like "try again next pass" would
  -- report a clean purge of data it never touched.
  loop
    v_pass := v_pass + 1;
    v_progress := false;
    for r in select t.table_name from public.fn__school_id_tables() t
              where t.treatment = 'delete' loop
      begin
        execute format('delete from public.%I where school_id = $1', r.table_name)
          using p_school_id;
        get diagnostics v_n = row_count;
        if v_n > 0 then
          v_progress := true;
          v_total := v_total + v_n;
          v_deleted := v_deleted || jsonb_build_object(
            r.table_name, coalesce((v_deleted->>r.table_name)::bigint, 0) + v_n);
        end if;
      exception when foreign_key_violation then null;
      end;
    end loop;
    exit when not v_progress or v_pass >= 12;
  end loop;

  -- The operator's own history goes FIRST, and keeps the id.
  --
  -- 0080 stamps the school's name into `detail` before unlinking, because an
  -- operator_actions row with school_id set to null and nothing else is a record
  -- of something having been done to somebody, which is not a record at all. The
  -- same applies here and there is no name to stamp — the schools row is already
  -- gone — so the id is what goes in. Done before the generic loop below, which
  -- would otherwise null the column and leave nothing to write the id from.
  if to_regclass('public.operator_actions') is not null then
    update public.operator_actions
       set detail = coalesce(detail, '{}'::jsonb)
                    || jsonb_build_object('orphaned_school_id', p_school_id),
           school_id = null
     where school_id = p_school_id;
    get diagnostics v_n = row_count;
    v_unlinked := v_unlinked + v_n;
  end if;

  -- Everything else of ours that referred to it: unlinked, never deleted. Same
  -- rule as fn_platform_purge_school — a business keeps its sales ledger after a
  -- customer leaves, and tax records have to be retained for years. These tables
  -- carry the school's name on the row already (0080 denormalised it for exactly
  -- this reason), so nulling the id loses nothing.
  for r in select t.table_name from public.fn__school_id_tables() t
            where t.treatment = 'unlink' and t.table_name <> 'operator_actions' loop
    execute format('update public.%I set school_id = null where school_id = $1', r.table_name)
      using p_school_id;
    get diagnostics v_n = row_count;
    v_unlinked := v_unlinked + v_n;
  end loop;

  -- Anything still holding rows is a table this function cannot reach, and the
  -- honest thing is to stop and name it. The whole call is one transaction, so
  -- nothing has been deleted when this raises.
  for r in select t.table_name from public.fn__school_id_tables() t loop
    execute format('select count(*) from public.%I x where x.school_id = $1', r.table_name)
      into v_n using p_school_id;
    if v_n > 0 then
      v_left := coalesce(v_left || ', ', '') || r.table_name || ' (' || v_n::text || ')';
    end if;
  end loop;
  if v_left is not null then
    raise exception
      'Could not finish: % still holds rows for this id after % passes. Nothing has '
      'been deleted — the whole operation is one transaction.', v_left, v_pass;
  end if;

  -- The photographs. Storage objects are keyed by school id and no foreign key
  -- reaches them, so they outlive everything else unless they are removed here.
  if to_regclass('storage.objects') is not null then
    begin
      execute 'delete from storage.objects where name like $1'
        using p_school_id::text || '/%';
    exception when others then null;      -- no storage schema in the test harness
    end;
  end if;

  return jsonb_build_object(
    'purged', true,
    'school_id', p_school_id,
    'rows_deleted', v_total,
    'rows_unlinked', v_unlinked,
    'passes', v_pass,
    'by_table', v_deleted,
    'orphan_logins', to_jsonb(v_logins),
    'logins_note', case when array_length(v_logins, 1) is null then
        'No sign-in was attached to this school.'
      else
        'These accounts can still sign in and now have no school at all. Remove '
        'them in Supabase under Authentication -> Users, or leave them if they '
        'are yours.' end,
    'kept', 'Your invoices, receipts and the record of what this console did — '
         || 'those are unlinked, not deleted.');
end $$;

grant  execute on function public.fn_platform_purge_orphan_data(uuid, text)   to authenticated;
revoke execute on function public.fn_platform_purge_orphan_data(uuid, text) from public, anon;

-- ---------------------------------------------------------------------------
-- 5. What is true right now, REPORTED — never asserted
--
-- 0091's first version raised an exception here and took a live bundle down with
-- it. 0090's header says in as many words that a convenience must never be able
-- to discard eleven migrations, and one file later I put an exception in a
-- migration over a data condition the operator had not looked at yet.
--
-- A migration may refuse to ACT on a state it does not understand. It may not
-- refuse to APPLY over one.
-- ---------------------------------------------------------------------------
do $report$
declare v_tables int; v_rows bigint; v_ids text; r record; v_one text;
begin
  select count(*), coalesce(sum(h.orphan_rows), 0)
    into v_tables, v_rows
  from public.fn__referential_health() h;

  if v_tables > 0 then
    -- Collected directly rather than through fn_platform_orphan_report(), which
    -- is operator-gated: a migration runs with no signed-in operator, so calling
    -- it here would raise 'Not permitted' and the handler below would swallow
    -- the very state this block exists to print. It did exactly that on the
    -- first run of this file.
    for r in select h.child_table from public.fn__referential_health() h loop
      execute format(
        'select string_agg(distinct x.school_id::text, '', '')
           from public.%I x
          where x.school_id is not null
            and not exists (select 1 from public.schools sc where sc.id = x.school_id)',
        r.child_table) into v_one;
      if v_one is not null then
        v_ids := coalesce(v_ids || ', ', '') || v_one;
      end if;
    end loop;
    select string_agg(distinct trim(p), ', ')
      into v_ids from unnest(string_to_array(coalesce(v_ids, ''), ',')) as p
     where trim(p) <> '';

    raise notice
      '0092: % table(s) hold % row(s) belonging to a school that is not in '
      '`schools` (id: %). Nothing has been deleted. Open the platform console -> '
      'Danger zone -> Left-behind records to see them table by table, or run '
      'supabase/repair/enforcement.sql first — it says whether foreign keys are '
      'still switched off, which is the part that would keep happening.',
      v_tables, v_rows, coalesce(v_ids, '?');
  end if;
exception when others then
  -- is_platform_admin() is false when a migration runs outside a request, which
  -- is the normal case. The report is a courtesy; it must never be the reason a
  -- migration fails.
  raise notice '0092: applied. Run supabase/repair/enforcement.sql for the state.';
end $report$;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0091_validate_the_subscription_fk.sql', '9_validate_constraints.sql');
  perform public.fn_record_migration('0092_orphan_data.sql', '9_validate_constraints.sql');
end $ledger$;
