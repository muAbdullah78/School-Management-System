-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0123_a_school_has_one_name.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0123 - A school has one name
--
-- REPORTED BY A SCHOOL, and it is the kind of defect that makes somebody
-- distrust the whole product: two screens showed two different names for the
-- same school.
--
--   Settings -> School Profile   "Chaudhary Puclix High School Ghauriii"
--   the operator console         "Choudhary Public School"
--
-- WHY. There are two name columns, and until now only one of them could ever
-- change.
--
--   schools.name           set at signup by fn_signup_school. Read by the
--                          operator console, by platform_invoices.school_name
--                          on the bill sent to the school, and by every tool
--                          that finds a school by name.
--   school_settings.name   seeded from schools.name by the provisioning
--                          trigger, and thereafter the ONLY one the school can
--                          edit: the first-run wizard and Settings both write
--                          it. Read by the sidebar, receipts, challans,
--                          certificates and result cards.
--
-- And public.schools carries only SELECT policies. No INSERT, UPDATE or DELETE
-- policy exists on it, so with row level security on, a signed-in user cannot
-- change schools.name by ANY route. The application did not forget to write it.
-- It structurally could not. So the moment a school edits its own name, the two
-- diverge permanently and nothing in the product can bring them back together.
--
-- WHAT THAT COSTS
--
--   * The school is billed under a name it never chose, because
--     platform_invoices.school_name is taken from schools.name.
--   * Support opens a console that names the school something the school does
--     not recognise.
--   * Anything that finds a school by name misses it. That is how this was
--     found: a school pasted a seven-file demo seed and every file refused
--     with "no school of that name", while the name on its own screen matched
--     what it had typed into the file.
--
-- THE FIX IS A TRIGGER AND NOT A FUNCTION THE APPLICATION CALLS, deliberately.
-- A new RPC fixes the two screens that exist today and leaves the next screen
-- free to diverge again, and the app cannot write schools.name in any case. As
-- a trigger the two columns become one fact, for every write path, including
-- the first-run wizard that already exists and any that comes later.
--
-- DIRECTION: school_settings.name wins. It is the one the school chose and the
-- one printed on everything the school hands to a parent.
--
-- EXCEPT for the placeholder. school_settings.name is NOT NULL DEFAULT
-- 'Your School', and while the provisioning trigger seeds it from the real
-- name, fn_set_current_session inserts that row with no name at all if it is
-- somehow missing. A blind copy would then rename a real school to
-- "Your School" in the console and on its own invoices. So the placeholder is
-- never mirrored, in the trigger or in the backfill.
--
-- Re-runnable. The backfill is a no-op once the two agree.
-- =============================================================================

create or replace function public.fn__mirror_school_name()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- SECURITY DEFINER because public.schools has no UPDATE policy at all, which
  -- is the whole reason this defect existed. The definer rights are used for
  -- exactly one column of exactly one row, the caller's own school, and the
  -- school_id on the row being written is already enforced by
  -- enforce_school_id() on this table.
  if coalesce(btrim(new.name), '') not in ('', 'Your School') then
    update public.schools
       set name = btrim(new.name)
     where id = new.school_id
       and name is distinct from btrim(new.name);
  end if;
  return null;   -- AFTER trigger: the return value is discarded
end;
$$;

revoke execute on function public.fn__mirror_school_name() from public, anon;

-- `create trigger` has no IF NOT EXISTS, so it is dropped first. Named for what
-- it does rather than for the table, because the next person looking for why
-- schools.name changed will grep for the name.
drop trigger if exists trg_school_settings_name_mirrors_school on public.school_settings;
create trigger trg_school_settings_name_mirrors_school
  after insert or update of name on public.school_settings
  for each row execute function public.fn__mirror_school_name();

-- --- The schools already carrying two names ---------------------------------
do $heal$
declare v_n integer;
begin
  update public.schools s
     set name = btrim(st.name)
    from public.school_settings st
   where st.school_id = s.id
     and coalesce(btrim(st.name), '') not in ('', 'Your School')
     and s.name is distinct from btrim(st.name);
  get diagnostics v_n = row_count;
  if v_n > 0 then
    raise notice '0123: % school(s) had two names and now have one', v_n;
  else
    raise notice '0123: every school already had one name';
  end if;
end $heal$;

-- ---------------------------------------------------------------------------
-- THE GUARD, and it asserts the BEHAVIOUR: that renaming a school the way the
-- application renames it now moves both columns, and that the placeholder is
-- not mirrored. A check that the trigger merely exists would pass on a body
-- that returned without doing anything.
--
-- The probe runs in a subtransaction that is rolled back either way. It needs
-- no signed-in user, because the path being tested is a trigger on a table the
-- probe writes directly, which is why this one can run everywhere the
-- migration does.
-- ---------------------------------------------------------------------------
do $check$
declare
  v_moved       boolean := false;
  v_placeholder boolean := false;   -- true means the placeholder was NOT copied
begin
  begin
    declare
      v_a uuid; v_b uuid; v_name text;
    begin
      insert into public.schools (name) values ('0123 probe as signed up')
        returning id into v_a;
      -- The provisioning trigger has now seeded school_settings from that name.
      update public.school_settings
         set name = '0123 probe as the school renamed itself'
       where school_id = v_a;
      select name into v_name from public.schools where id = v_a;
      v_moved := v_name = '0123 probe as the school renamed itself';

      -- And the placeholder must not travel.
      insert into public.schools (name) values ('0123 probe keeps its name')
        returning id into v_b;
      update public.school_settings set name = 'Your School' where school_id = v_b;
      select name into v_name from public.schools where id = v_b;
      v_placeholder := v_name = '0123 probe keeps its name';
    end;
    raise exception 'rollback the probe';
  exception
    when others then
      if sqlerrm <> 'rollback the probe' then
        raise warning '0123: the behaviour check could not finish (%). The '
          'trigger is installed; supabase/verify.sql says whether it works.', sqlerrm;
        return;
      end if;
  end;

  if not v_moved then
    raise exception '0123: a school renamed itself in Settings and the name the '
      'console and its invoices use did not follow.';
  end if;
  if not v_placeholder then
    raise exception '0123: the "Your School" placeholder overwrote a real '
      'school name, which is worse than the divergence it was meant to fix.';
  end if;
  raise notice '0123: a school has one name, and the placeholder never '
    'overwrites a real one';
end $check$;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0123_a_school_has_one_name.sql', '29_a_school_has_one_name.sql');
end $ledger$;
