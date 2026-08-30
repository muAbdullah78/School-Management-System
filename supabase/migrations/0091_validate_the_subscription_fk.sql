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
-- WHAT THIS EXPLAINS, retrospectively. The constraint was almost certainly NOT
-- VALID from the start on that project, the orphan predates it, and 0067's
-- closing backfill walked straight into a row the database had promised to
-- forbid. Nothing "dropped" the constraint; it was simply never asked to check.
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
-- The end state, asserted — but only as far as it CAN be
--
-- "The constraint is validated" is not assertable here: a database that still
-- has an orphan is a database this migration has deliberately left alone, and
-- raising would abort a bundle over a row the operator has not looked at yet.
-- That is the whole lesson of 0090, one file later.
--
-- What IS assertable is the two states being mutually exclusive from here on:
-- if the constraint is valid, there are no orphans, because Postgres has just
-- checked. Catching THAT disagreement is what the checker failed to do.
-- ---------------------------------------------------------------------------
do $assert$
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
    raise exception
      '0091: the foreign key reports itself validated and % subscription row(s) '
      'still name a school that does not exist. Those cannot both be true — one '
      'of them is a checker reading something it does not mean.', v_orphans;
  end if;
end $assert$;
