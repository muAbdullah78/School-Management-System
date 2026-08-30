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
  where s.school_id is not null
    and not exists (select 1 from public.schools sc where sc.id = s.school_id);

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
  where s.school_id is not null
    and not exists (select 1 from public.schools sc where sc.id = s.school_id);

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
