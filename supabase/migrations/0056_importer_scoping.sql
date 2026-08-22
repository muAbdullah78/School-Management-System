-- =============================================================================
-- 0056 — The go-live importers looked up children across every school.
--
-- WHAT WAS WRONG
--
-- gr_no, admission_no and roll_no are PER-SCHOOL counters. Every school on the
-- platform has a GR 0001. Both bulk importers — the two tools a school uses on
-- its very first day — resolved and de-duplicated on those keys with no school
-- filter, inside SECURITY DEFINER functions where RLS never applies.
--
-- fn_import_students, de-duplicating:
--
--     select count(*) into v_cnt from public.students where gr_no = v_gr;
--     if v_cnt > 0 then ... 'GR ' || v_gr || ' already exists'
--
-- So a school importing its register was told "GR 0001 already exists" because
-- ANOTHER school already had a GR 0001. A school could not complete its first
-- bulk import, and the rejection rate grows with every school that joins.
--
-- fn_import_opening_balances, resolving who a row belongs to:
--
--     select id into v_student from public.students where gr_no = v_gr ...
--
-- plpgsql SELECT INTO takes the first row and raises nothing, so this could
-- resolve to another school's child. Step 4 then checks enrolment in the target
-- session, the foreign child has none, and the row fails with
--
--     "Student is not enrolled in the selected session"
--
-- about a pupil who is enrolled. Proven by running it: two schools, both with
-- GR 0001, import by GR fails with exactly that message. The name lookup has
-- the same fault in a more visible form — "Name Muhammad Ali matches several
-- students — use GR No" for a school holding exactly one Muhammad Ali, with the
-- advice pointing at the GR path that is also broken.
--
-- And the result row carries `name`, filled from the resolved student, so the
-- import report could print ANOTHER SCHOOL'S PUPIL'S NAME back to the importer.
--
-- WHY THIS IS THE THIRD TIME
--
-- Migration 0042 already found and fixed exactly this, for staff:
--
--     "No school filter, so importing staff rejected rows as duplicates because
--      ANOTHER school already used that employee number"
--
-- The diagnosis was right and it was applied to one of the three importers. The
-- student importer and the opening-balance importer were never revisited. This
-- migration finishes the job, and check-import-keys.py now fails the build on
-- any lookup of a per-school business key that has no school filter, so a
-- fourth importer cannot repeat it.
--
-- HOW
--
-- Same technique as 0042: fetch the live definition, replace only the offending
-- fragments, and execute it. Nothing is retyped — 0054 nearly reverted five
-- migrations' worth of billing logic by hand-copying a function body.
--
-- Unlike 0042, every replacement is CHECKED — but on its END STATE, not on
-- whether it matched. A replace() that matches nothing is a silent no-op: the
-- migration applies perfectly cleanly and the bug is still there. That is the
-- one failure mode this technique has and it needs a guard.
--
-- The first version of this file asserted "the replacement changed something",
-- and that was wrong: run it twice and the second run raises, because the
-- unscoped text is legitimately gone. Asserting the end state instead — the
-- unscoped form is absent AND the scoped form is present — is idempotent and
-- still fails loudly if the function has been rewritten under us and neither
-- form is there. Found by re-running it, not by reading it.
-- =============================================================================

do $mig$
declare
  v_def   text;
  v_fn    text;
  v_pair  text[];
  v_pairs text[][];
begin
  foreach v_fn in array array['fn_import_students', 'fn_import_opening_balances']
  loop
    select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_fn;
    if v_def is null then raise exception '0056: % not found', v_fn; end if;

    -- {unscoped, scoped}. Both forms are named so the end state can be checked
    -- either way round: after this runs the unscoped text must be gone and the
    -- scoped text must be there.
    if v_fn = 'fn_import_students' then
      v_pairs := array[
        array['from public.students where gr_no = v_gr',
              'from public.students where school_id = public.current_school_id() and gr_no = v_gr'],
        array['from public.students where admission_no = v_admno',
              'from public.students where school_id = public.current_school_id() and admission_no = v_admno']
      ];
    else
      v_pairs := array[
        -- The GR lookup that could resolve to another school's child.
        array['from public.students where gr_no = v_gr and deleted_at is null',
              'from public.students where school_id = public.current_school_id() and gr_no = v_gr and deleted_at is null'],
        -- Twice: the count and the select. replace() rewrites both.
        array['from public.students where admission_no = v_adm and deleted_at is null',
              'from public.students where school_id = public.current_school_id() and admission_no = v_adm and deleted_at is null'],
        -- The name lookup, also twice. Keyed on the father-name clause because
        -- the two copies are indented differently and share no other text.
        array['lower(coalesce(father_name, '''')) = lower(v_father))',
              'lower(coalesce(father_name, '''')) = lower(v_father)) and school_id = public.current_school_id()'],
        -- The label. By id, so already this school's child once the lookups
        -- above are fixed — scoped anyway, because it is what the import report
        -- prints back and a name is the most visible thing to leak.
        array['(select full_name from public.students where id = v_student)',
              '(select full_name from public.students where id = v_student and school_id = public.current_school_id())']
      ];
    end if;

    foreach v_pair slice 1 in array v_pairs
    loop
      if position(v_pair[2] in v_def) = 0 then
        -- Not yet scoped. It must be present in the unscoped form, or the
        -- function is neither what we found nor what we intend to leave.
        if position(v_pair[1] in v_def) = 0 then
          raise exception
            '0056: %s matches neither the unscoped nor the scoped form of "%" — '
            'the function has been rewritten and this migration must be updated, '
            'not skipped', v_fn, left(v_pair[1], 60);
        end if;
        v_def := replace(v_def, v_pair[1], v_pair[2]);
      end if;
      -- End state, asserted either way round.
      if position(v_pair[2] in v_def) = 0 then
        raise exception '0056: failed to scope "%" in %', left(v_pair[1], 60), v_fn;
      end if;
    end loop;

    execute v_def;
  end loop;
end
$mig$;

-- Belt and braces against the stored bodies, not against local variables: prove
-- no unscoped lookup on a per-school counter survives in either importer. If
-- this fails the whole migration rolls back.
do $check$
declare v_bad text;
begin
  select string_agg(p.proname, ', ') into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('fn_import_students', 'fn_import_opening_balances')
    and (   p.prosrc ~ 'from public\.students where gr_no'
         or p.prosrc ~ 'from public\.students where admission_no'
         or p.prosrc ~ 'lower\(v_father\)\)\s*$');
  if v_bad is not null then
    raise exception '0056 did not take effect in: %', v_bad;
  end if;
end
$check$;
