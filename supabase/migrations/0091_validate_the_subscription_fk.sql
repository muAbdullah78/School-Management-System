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
-- file's own end-state check said so by aborting the bundle. That is the second
-- confident explanation of one row, after "the foreign key is missing", and both
-- were inferences dressed as findings.
--
-- What IS established, rather than inferred:
--
--   * a NOT VALID constraint produces exactly the reported symptoms, and the
--     old check could not see it. That hole was real and is closed.
--   * a VALIDATED constraint is Postgres's own statement that it has scanned
--     every row. When a SELECT disagrees with one, the SELECT is what is wrong.
--   * a reader that cannot SEE the referenced table produces a false orphan.
--     Demonstrated on a two-table model: with RLS hiding `schools`, the same
--     query reports one orphan and zero schools while the constraint is
--     validated and correct.
--
--     THAT IS A MECHANISM, NOT THIS PROJECT'S DIAGNOSIS, and the difference is
--     the point. On the real schema `subscriptions` carries RLS too, so a
--     session that cannot see a school cannot see its subscription either and
--     both rows disappear together — which is NOT the live shape (one school
--     visible, one subscription apparently orphaned). So the mechanism is real
--     and it does not explain that project. What explains it is not yet known,
--     and this file no longer pretends otherwise.
--
-- So this file now TRUSTS THE CONSTRAINT over the query, everywhere. That
-- conclusion does not depend on knowing WHY they disagree, which is what makes
-- it the right one to act on: Postgres has scanned the table and a SELECT has
-- not. supabase/repair/facts.sql prints raw readings, with no interpretation,
-- for working out the rest. Three confident explanations of one row is enough to
-- stop summarising and start measuring.
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

  -- Checked BEFORE the orphan count is used for anything. A validated
  -- constraint is Postgres's own statement that it has scanned every row, and
  -- it outranks a SELECT that may be reading through RLS.
  if v_valid then
    return;                                   -- present and checked; nothing to do
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
-- AND THE CHECK ITSELF IS NOW THE RIGHT WAY ROUND. A VALIDATED foreign key
-- means Postgres has already scanned every row and found no orphan — that is
-- what validation IS. So when a SELECT disagrees with a validated constraint,
-- the SELECT is what is wrong, and the likeliest reason is that it cannot SEE
-- the row: `public.schools` carries RLS, and a session that is neither the
-- table's owner nor BYPASSRLS gets an empty answer rather than a wrong one.
-- Reproduced: under RLS the same query reports one orphan and zero schools
-- while the constraint is validated and correct.
--
-- Trusting the constraint over the query removes that entire class of
-- confusion. supabase/repair/facts.sql prints the readings, with no
-- interpretation, when the two still disagree.
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
      '0091: the foreign key reports itself VALIDATED and a query still sees % '
      'subscription row(s) with no school. Postgres has already scanned this '
      'table, so the constraint is the one to believe and the query is the one '
      'that is wrong. WHY it is wrong is not known — nothing has been changed, '
      'and nothing here will guess again. Run supabase/repair/facts.sql and send '
      'the output: it prints the same counts with RLS stood down, every foreign '
      'key on the table with its validated flag, and the row itself.',
      v_orphans;
  end if;
end $report$;
