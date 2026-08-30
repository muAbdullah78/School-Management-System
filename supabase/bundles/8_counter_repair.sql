-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0090_counter_backfill_repair.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0090 — One school with no row in `schools` stopped an entire bundle
--
-- WHAT HAPPENED, on a real project, pasting bundle 6:
--
--   ERROR: 23503: insert or update on table "student_count_snapshots" violates
--          foreign key constraint "student_count_snapshots_school_id_fkey"
--   DETAIL: Key (school_id)=(a0bf0f0c-…) is not present in table "schools".
--   CONTEXT: PL/pgSQL function fn_refresh_student_count(uuid) line 32
--            SQL statement "SELECT public.fn_refresh_student_count(v_school)"
--            PL/pgSQL function inline_code_block line 5 at PERFORM
--
-- The inline_code_block is 0067's closing backfill:
--
--     for v_school in select school_id from public.subscriptions loop
--       perform public.fn_refresh_student_count(v_school);
--     end loop;
--
-- THREE THINGS ARE WRONG WITH THAT LOOP, and only the first is about this bug.
--
--   1. IT TRUSTS A FOREIGN KEY IT DOES NOT NAME. The loop reads `subscriptions`
--      and writes a row keyed to `schools`, which is safe only while every
--      subscription's school exists. It does not on that project. Driving the
--      loop from the table the constraint actually points at costs one join and
--      removes the assumption entirely.
--
--   2. ONE TENANT'S BAD ROW ABORTS THE MIGRATION FOR EVERY TENANT. This is the
--      part worth more than the fix. A backfill that walks every school on the
--      platform and raises on any of them is a migration whose success depends
--      on the worst row in the database — and the blast radius is not that
--      school's counter, it is the entire bundle, rolled back, for everybody. A
--      per-school BEGIN/EXCEPTION turns "nobody gets the upgrade" into "one
--      school's count is stale and the notice says which".
--
--   3. IT IS THE LAST STATEMENT OF THE LAST MIGRATION IN THE BUNDLE. So the
--      failure discarded 0057 through 0067 — photographs, exam computation, the
--      observer role, deposits, certificates, staff check-in, operator billing —
--      to recount a number.
--
-- HOW THE ORPHAN CAME TO EXIST IS NOT KNOWN, AND IS NOT GUESSED AT HERE.
-- `subscriptions.school_id` is the primary key and is declared
-- `references public.schools(id) on delete cascade` in 0025, so on a database
-- with that constraint the row is impossible. The constraint is therefore
-- missing on that project — dropped with a recreated `schools`, or lost in a
-- restore. Section 2 puts it back when it is safe to, which is the only way to
-- stop the row coming back.
--
-- NOTHING IS DELETED. A subscription naming a school that does not exist cannot
-- be viewed, billed or renewed, so there is little to lose by removing it — and
-- "little to lose" is exactly the reasoning that loses a school its data. It is
-- reported, by id, and left alone.
--
-- Re-runnable, and safe on a database where 0067 never applied: sections 3 and 4
-- restate its objects, all of which are idempotent by construction.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Say what is orphaned, by name
-- ---------------------------------------------------------------------------
do $orphans$
declare v_n bigint; v_ids text;
begin
  select count(*), string_agg(s.school_id::text, ', ')
    into v_n, v_ids
  from public.subscriptions s
  where not exists (select 1 from public.schools sc where sc.id = s.school_id);

  if v_n > 0 then
    raise notice
      '0090: % subscription row(s) name a school that does not exist: %. '
      'Nothing has been deleted. They are invisible to the operator console '
      '(every screen joins schools), they are skipped by the recount below, and '
      'the missing foreign key that let them exist is NOT restored while they '
      'are present — see the next notice.', v_n, v_ids;
  end if;
end $orphans$;

-- ---------------------------------------------------------------------------
-- 2. Put the foreign key back
--
-- Checked by what the constraint DOES rather than by its name: a constraint
-- named subscriptions_school_id_fkey that points somewhere else would satisfy a
-- name check and none of the guarantee.
-- ---------------------------------------------------------------------------
do $fk$
declare v_orphans bigint;
begin
  if exists (
    select 1 from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'public' and t.relname = 'subscriptions' and c.contype = 'f'
      and pg_get_constraintdef(c.oid) ilike '%references%schools(id)%'
  ) then
    return;                                   -- already there, nothing to do
  end if;

  select count(*) into v_orphans
  from public.subscriptions s
  where not exists (select 1 from public.schools sc where sc.id = s.school_id);

  if v_orphans > 0 then
    raise notice
      '0090: subscriptions has NO foreign key to schools, and % orphan row(s) '
      'stop it being added. Decide what those rows are — a school deleted by '
      'hand, or a restore that lost the constraint — then delete them and '
      're-run this file. Until then a deleted school will keep leaving its '
      'subscription behind.', v_orphans;
    return;
  end if;

  alter table public.subscriptions
    add constraint subscriptions_school_id_fkey
    foreign key (school_id) references public.schools(id) on delete cascade;
  raise notice
    '0090: restored subscriptions -> schools (on delete cascade). It was missing, '
    'which is how a subscription outlived its school.';
end $fk$;

-- ---------------------------------------------------------------------------
-- 3. The trigger function, with the same assumption removed
--
-- The live path takes its school ids from the rows a statement touched, and
-- students and enrollments both carry a foreign key to schools — so this guard
-- is defence in depth rather than a fix. It costs one join on a path that
-- already reads `subscriptions`, and the alternative is a clerk's admission
-- failing with a foreign-key error from a counter.
-- ---------------------------------------------------------------------------
create or replace function public.fn__refresh_counts_touched()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_schools uuid[];
  v_school  uuid;
begin
  -- Branch on TG_OP rather than declaring both transition tables everywhere:
  -- Postgres refuses OLD TABLE on an INSERT trigger and NEW TABLE on a DELETE
  -- one, so only the pair that exists for this verb may be named. plpgsql plans
  -- a statement the first time it is reached, so the unreachable branches never
  -- try to resolve a table that is not there.
  if tg_op = 'INSERT' then
    select array_agg(distinct school_id) into v_schools
      from touched_new where school_id is not null;
  elsif tg_op = 'DELETE' then
    select array_agg(distinct school_id) into v_schools
      from touched_old where school_id is not null;
  else
    select array_agg(distinct s) into v_schools
      from (select school_id as s from touched_new
            union
            select school_id as s from touched_old) x
     where s is not null;
  end if;

  foreach v_school in array coalesce(v_schools, '{}'::uuid[])
  loop
    -- Guard, not laziness: a school row can exist before its subscription does
    -- (the signup Edge Function creates the school, then the subscription), and
    -- fn_refresh_student_count raises 'No subscription for school %'. A pupil
    -- import must never fail because of a counter.
    --
    -- 0090 joins `schools` as well. The snapshot row this ends up writing is
    -- keyed to schools, so a subscription whose school is gone would fail the
    -- foreign key and take the clerk's admission down with it.
    if exists (select 1
                 from public.subscriptions sub
                 join public.schools sc on sc.id = sub.school_id
                where sub.school_id = v_school) then
      perform public.fn_refresh_student_count(v_school);
    end if;
  end loop;
  return null;
end;
$$;

revoke all on function public.fn__refresh_counts_touched() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. The six triggers
--
-- Restated because bundle 6 is ONE transaction: the failure above discarded
-- every statement of 0067, so a database that hit it has the stale counter and
-- none of the machinery. All idempotent, so a database where 0067 did apply is
-- unchanged.
-- ---------------------------------------------------------------------------
drop trigger if exists trg_enrollments_count_ins on public.enrollments;
create trigger trg_enrollments_count_ins
  after insert on public.enrollments
  referencing new table as touched_new
  for each statement execute function public.fn__refresh_counts_touched();

drop trigger if exists trg_enrollments_count_upd on public.enrollments;
create trigger trg_enrollments_count_upd
  after update on public.enrollments
  referencing new table as touched_new old table as touched_old
  for each statement execute function public.fn__refresh_counts_touched();

drop trigger if exists trg_enrollments_count_del on public.enrollments;
create trigger trg_enrollments_count_del
  after delete on public.enrollments
  referencing old table as touched_old
  for each statement execute function public.fn__refresh_counts_touched();

drop trigger if exists trg_students_count_ins on public.students;
create trigger trg_students_count_ins
  after insert on public.students
  referencing new table as touched_new
  for each statement execute function public.fn__refresh_counts_touched();

drop trigger if exists trg_students_count_upd on public.students;
create trigger trg_students_count_upd
  after update on public.students
  referencing new table as touched_new old table as touched_old
  for each statement execute function public.fn__refresh_counts_touched();

drop trigger if exists trg_students_count_del on public.students;
create trigger trg_students_count_del
  after delete on public.students
  referencing old table as touched_old
  for each statement execute function public.fn__refresh_counts_touched();

-- ---------------------------------------------------------------------------
-- 5. The backfill, which can no longer take the bundle down
--
-- Driven from `schools` joined to `subscriptions`, and every school wrapped on
-- its own. The exception handler is the point: a recount is a convenience, and a
-- convenience must never be able to discard eleven migrations.
-- ---------------------------------------------------------------------------
do $backfill$
declare
  v_school uuid;
  v_done  int := 0;
  v_fail  int := 0;
begin
  for v_school in
    select sub.school_id
      from public.subscriptions sub
      join public.schools sc on sc.id = sub.school_id
     order by sub.school_id
  loop
    begin
      perform public.fn_refresh_student_count(v_school);
      v_done := v_done + 1;
    exception when others then
      v_fail := v_fail + 1;
      raise notice '0090: could not recount school % — %', v_school, sqlerrm;
    end;
  end loop;

  if v_fail = 0 then
    raise notice '0090: recounted % school(s)', v_done;
  else
    raise notice
      '0090: recounted % school(s); % could not be recounted and are named '
      'above. Their console figure is stale until a pupil is edited or '
      '"Refresh counts" is pressed — everything else in this migration applied.',
      v_done, v_fail;
  end if;
end $backfill$;

-- ---------------------------------------------------------------------------
-- 6. Re-assert 0070's boundary rather than assume it held
--
-- A live project reported 0070 MISSING after bundle 7 applied cleanly, and the
-- signature has three parts with no way to tell from the output which one is
-- false. `supabase/repair/why.sql` now answers that; this section repairs the
-- part that CAN be repaired without seeing the database.
--
-- Postgres grants EXECUTE to PUBLIC on every function it creates, and `anon` has
-- USAGE on the schema, so a new `fn__` helper is callable by an unauthenticated
-- request until something revokes it. 0071 swept the schema once; every
-- migration since has had to remember. A sweep is the shape that does not
-- depend on remembering.
-- ---------------------------------------------------------------------------
do $internal$
declare r record; v_n int := 0;
begin
  for r in
    select p.oid::regprocedure::text as sig, p.proname
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname like 'fn\_\_%'
       and has_function_privilege('authenticated', p.oid, 'execute')
     order by p.proname
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    v_n := v_n + 1;
    raise notice '0090: revoked % — an internal helper was callable by a signed-in user', r.proname;
  end loop;
  if v_n > 0 then
    raise notice '0090: closed % internal helper(s)', v_n;
  end if;
end $internal$;

-- The other two thirds of 0070 are SCOPING inside two function bodies. Those
-- cannot be repaired blind — rewriting a body this file has not seen is how a
-- fix becomes the next defect — so they are checked and named.
do $scoping$
begin
  if not exists (select 1 from pg_proc
                  where proname = 'fn_queue_message'
                    and pronamespace = 'public'::regnamespace
                    and prosrc like '%id = p_family_id and school_id = v_school%') then
    raise exception
      '0090: fn_queue_message no longer scopes its family lookup to the caller''s '
      'school. That is the 0070 leak: any signed-in user could name any family on '
      'the platform and receive the child''s name back in a rendered message. '
      'Re-run supabase/migrations/0070_queue_message_scoping.sql followed by '
      '0088_wire_the_dead_templates.sql, in that order.';
  end if;

  if not exists (select 1 from pg_proc
                  where proname = 'fn__apply_discount_lines'
                    and pronamespace = 'public'::regnamespace
                    and prosrc like '%d.school_id = v_school%') then
    raise exception
      '0090: fn__apply_discount_lines no longer scopes its discount lookup. '
      'Re-run supabase/migrations/0070_queue_message_scoping.sql.';
  end if;
end $scoping$;

-- ---------------------------------------------------------------------------
-- 7. The end state, asserted
-- ---------------------------------------------------------------------------
do $assert$
declare v_n int;
begin
  select count(*) into v_n
  from pg_trigger t
  join pg_proc pr on pr.oid = t.tgfoid
  where not t.tgisinternal
    and pr.pronamespace = 'public'::regnamespace
    and pr.proname = 'fn__refresh_counts_touched'
    and t.tgrelid in ('public.students'::regclass, 'public.enrollments'::regclass);
  if v_n <> 6 then
    raise exception
      '0090: % of the 6 student-count triggers exist. Without all six a school '
      'can outgrow its plan and neither the operator nor the school finds out.',
      v_n;
  end if;

  select count(*) into v_n
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname like 'fn\_\_%'
    and has_function_privilege('authenticated', p.oid, 'execute');
  if v_n > 0 then
    raise exception
      '0090: % internal fn__ helper(s) are still callable by a signed-in user', v_n;
  end if;

  -- The guard that was the whole point: the backfill must no longer be able to
  -- ask for a school that is not there.
  if not exists (select 1 from pg_proc
                  where proname = 'fn__refresh_counts_touched'
                    and pronamespace = 'public'::regnamespace
                    and prosrc like '%join public.schools sc%') then
    raise exception
      '0090: fn__refresh_counts_touched still trusts subscriptions alone';
  end if;
end $assert$;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0090_counter_backfill_repair.sql', '8_counter_repair.sql');
end $ledger$;
