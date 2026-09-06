-- =============================================================================
-- 0110: Re-pasting bundle 6 let a read-only user enter marks
--
-- FOUND BY THE RE-PASTE CHECK, WHILE INVESTIGATING SOMETHING ELSE.
--
-- 0059 built the read-only boundary. It introduced
--
--     may_view(roles) = has_role(roles) or has_role('readonly')
--
-- and then rewrote, programmatically, every STABLE or IMMUTABLE SECURITY
-- DEFINER function whose body contained has_role( so that a read-only observer
-- could see what the office sees. That was right, and its own comment is careful
-- about the danger:
--
--     A READ gate: true for any of the given roles, and additionally for
--     readonly. Must never appear in a write policy or a VOLATILE function.
--
-- It carries an exclusion list of two functions that are "write gates wearing a
-- read gate's clothes", and supabase/check-readonly-writes.py fails the build if
-- may_view turns up somewhere it must not.
--
-- THE HOLE IS IN THE ORDERING, AND ONLY LUCK WAS COVERING IT.
--
-- The loop can only see functions that EXIST when it runs. Every write gate
-- written after 0059 is invisible to it on a first install, which is why they
-- correctly keep has_role. But a school that re-pastes bundle 6 - which the
-- setup instructions tell them to do whenever they are unsure a paste took -
-- runs that loop again against a database that now holds all of them.
--
-- fn_may_mark_subject is the gate deciding WHO MAY ENTER MARKS. 0085 created it
-- after 0059. Re-paste bundle 6 and it becomes may_view, so the readonly role -
-- which exists precisely so an observer cannot write - passes it, and
-- fn_enter_marks, fn_enter_assessment_marks and fn_generate_result_cards all
-- consult it.
--
-- Nothing caught this because the source files are right: check-readonly-writes
-- reads the repository, where 0085 plainly says has_role. The damage exists only
-- in the stored body of a database that has been pasted twice. And the reason
-- nobody has hit it is that bundle 7 re-applies immediately afterwards and
-- rewrites the function from its own source. That is not a safeguard, it is a
-- coincidence: any future change that stops bundle 7 re-applying cleanly - a
-- signature change, a new constraint, a school pasting out of order - takes the
-- cover away. One such change was written and reverted in this very PR.
--
-- SO THE END STATE IS ASSERTED HERE RATHER THAN LEFT TO PASTE ORDER.
--
-- This migration lives in the newest bundle, which is pasted last in every
-- ordering, so it repairs whatever the pass before it did. It is a repair rather
-- than a redesign: 0059's decision stands, and this only names the functions the
-- loop was never meant to reach.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Put the write gates back
--
-- Named explicitly rather than derived. A rule like "anything called from a
-- VOLATILE function" would be clever and would silently change scope every time
-- somebody writes a new caller; a list is auditable, and if it is wrong the
-- assertion below says so by name.
-- ---------------------------------------------------------------------------
do $repair$
declare
  r record; v_src text; v_new text; v_fixed text[] := '{}';
  -- WRITE GATES. Each decides whether the caller may CHANGE something, so a
  -- read-only observer must fail it. All were created after 0059 and so are
  -- invisible to its loop on a first install, and wrongly caught by it on any
  -- later one.
  c_write_gates text[] := array['fn_may_mark_subject'];
begin
  for r in
    select p.oid, p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = any (c_write_gates)
       and p.prosrc like '%may_view(%'
  loop
    v_src := pg_get_functiondef(r.oid);
    v_new := replace(v_src, 'public.may_view(', 'public.has_role(');
    v_new := replace(v_new, ' may_view(', ' has_role(');
    if v_new <> v_src then
      execute v_new;
      v_fixed := v_fixed || r.proname::text;
    end if;
  end loop;

  if array_length(v_fixed, 1) > 0 then
    raise notice '0110: put % back onto has_role. This database had been pasted '
      'more than once and a read-only user could enter marks.',
      array_to_string(v_fixed, ', ');
  else
    raise notice '0110: the write gates were already correct';
  end if;
end
$repair$;

-- ---------------------------------------------------------------------------
-- 2. And say so if it is ever wrong again
--
-- The END STATE, not "a replacement matched", for the reason 0059 gives about
-- its own assertion: a check that passes because a string was found is a check
-- that passes on a database where the string was never wrong.
-- ---------------------------------------------------------------------------
do $assert$
declare v_bad text[];
begin
  select coalesce(array_agg(p.proname order by p.proname), '{}')
    into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('fn_may_mark_subject', 'fn_may_manage_class',
                       'fn_may_write_school_file')
     and p.prosrc like '%may_view(%';
  if array_length(v_bad, 1) > 0 then
    raise exception '0110: % still admit the readonly role to a write gate', 
      array_to_string(v_bad, ', ');
  end if;
end
$assert$;
