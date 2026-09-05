-- =============================================================================
-- 0101 — A key the database does not recognise was silently thrown away
--
-- HOW THIS WAS FOUND
--
-- Not by a school. By making the mistake while writing a test: a seed script
-- sent `practical` where fn_enter_marks reads `practical_marks`. The function
-- accepted the call, reported success, and wrote NULL into the practical column
-- for every pupil in the class. Nothing raised, nothing logged, and the office
-- marksheet simply showed an empty practical column, which reads as "nobody has
-- entered the practicals yet".
--
-- Four functions take a list of rows as jsonb and read the keys they know by
-- name, ignoring anything else:
--
--   fn_enter_marks              enrollment_id, marks, practical_marks, is_absent
--   fn_enter_assessment_marks   enrollment_id, marks, is_absent
--   fn_mark_attendance          enrollment_id, status
--   fn_record_bulk_payments     student_id, amount, receipt_no
--
-- WHAT EACH ONE ACTUALLY DOES TODAY, measured rather than assumed. The first
-- draft of this migration asserted that a misspelt attendance status marks a
-- whole class present and a misspelt amount posts a receipt for nothing. Both
-- were wrong, and running it was what showed that:
--
--   fn_mark_attendance       ALREADY REFUSES. A row with no `status` the
--                            function recognises fails the NOT NULL constraint
--                            on attendance_daily.status. Nothing is written.
--   fn_record_bulk_payments  ALREADY REFUSES, with "Amount for <name> must be
--                            more than zero". Nothing is written.
--   fn_enter_marks           SILENT. `practical` for `practical_marks` stores
--                            NULL; `absent` for `is_absent` stores false, so a
--                            child who sat no paper is recorded as having
--                            scored nothing, which prints as a FAIL on a card
--                            that goes home.
--   fn_enter_assessment_marks  the same, on a class test.
--
-- So the honest summary is: two of the four lose data silently, and two are
-- saved by a constraint that happens to be there.
--
-- IT IS STILL WORTH DOING FOR ALL FOUR, for two reasons.
--
-- The first is that the two which refuse do so for reasons unrelated to the
-- mistake, and say the wrong thing about it. "Amount for Ahmed must be more
-- than zero" sent to a clerk who typed an amount is a diagnosis pointing at the
-- wrong thing, and somebody will spend a morning on it. The refusal now names
-- the key.
--
-- The second is that being saved by a constraint is not a rule, it is luck.
-- attendance_daily.status is NOT NULL today; a future column added nullable, or
-- a fifth function of the same shape, has no such accident to fall back on.
--
-- The app is correct today: its TypeScript payload types match all four
-- functions exactly. That is a property of today's caller. The failure arrives
-- the day somebody renames a field on one side of the wall, imports a
-- spreadsheet through a script, or writes a second client.
--
-- WHY THE FOUR ARE PATCHED PROGRAMMATICALLY
--
-- Same reason as 0100. fn_enter_marks alone is 114 lines, and retyping a
-- function body to add one statement to it is how a stack of earlier fixes gets
-- silently reverted, which this repository has recorded happening twice.
-- Each definition is read from the catalogue, one `perform` is inserted directly
-- after the function's own permission gate, and the result is executed. The
-- insertion point is located rather than assumed, and the block refuses loudly
-- rather than guessing if it cannot find the gate.
--
-- WHAT IS DELIBERATELY LEFT ALONE
--
-- fn_admit_student, fn_import_students, fn_import_staff, fn_import_opening_balances
-- and fn_rollover also take jsonb. They are NOT given this treatment:
--
--   * the three importers already report per row, in words, what they did and
--     did not understand, and they are fed by a CSV mapper whose whole job is
--     that a school's column headings do not match ours. Refusing an unknown
--     column there would break the feature.
--   * fn_admit_student takes a nested DOCUMENT with sub-objects (guardian,
--     links), not a list of flat rows, so one flat key list does not describe
--     it and pretending otherwise would be a guard that is wrong about what it
--     is guarding.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The rule
--
-- Collects EVERY unrecognised key across the whole payload before raising, so a
-- caller with three fields wrong is told about three fields, not told about one,
-- corrected, and told about the next. A clerk pasting a spreadsheet does not get
-- three round trips.
-- ---------------------------------------------------------------------------
create or replace function public.fn__only_these_keys(
  p_rows jsonb, p_allowed text[], p_what text
) returns void language plpgsql immutable as $$
declare
  v_row jsonb;
  v_key text;
  v_bad text[] := '{}';
begin
  if p_rows is null then
    return;
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception '% expects a list of rows and was given a %.',
      p_what, jsonb_typeof(p_rows);
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    if jsonb_typeof(v_row) <> 'object' then
      raise exception '% expects each row to be an object and found a %.',
        p_what, jsonb_typeof(v_row);
    end if;
    for v_key in select jsonb_object_keys(v_row) loop
      if not (v_key = any(p_allowed)) and not (v_key = any(v_bad)) then
        v_bad := v_bad || v_key;
      end if;
    end loop;
  end loop;

  if array_length(v_bad, 1) is not null then
    raise exception '% does not understand %. It reads only: %. '
      'A field it does not recognise is not ignored here, because ignoring one '
      'silently loses whatever was in it.',
      p_what,
      array_to_string(v_bad, ', '),
      array_to_string(p_allowed, ', ')
      using errcode = '22023';
  end if;
end;
$$;

revoke all on function public.fn__only_these_keys(jsonb, text[], text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The four callers, patched from their own definitions
-- ---------------------------------------------------------------------------
do $patch$
declare
  v_targets text[][] := array[
    -- function, payload argument, what to call it, allowed keys (comma separated)
    array['fn_enter_marks', 'p_marks', 'Mark entry',
          'enrollment_id,marks,practical_marks,is_absent'],
    array['fn_enter_assessment_marks', 'p_marks', 'Class test mark entry',
          'enrollment_id,marks,is_absent'],
    array['fn_mark_attendance', 'p_marks', 'Attendance marking',
          'enrollment_id,status'],
    array['fn_record_bulk_payments', 'p_items', 'Bulk payment entry',
          'student_id,amount,receipt_no']
  ];
  v_i int;
  v_name text; v_arg text; v_what text; v_keys text;
  v_src text; v_new text;
  v_at int; v_end int;
  v_call text;
begin
  for v_i in 1 .. array_length(v_targets, 1) loop
    v_name := v_targets[v_i][1];
    v_arg  := v_targets[v_i][2];
    v_what := v_targets[v_i][3];
    v_keys := v_targets[v_i][4];

    select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_name;

    if v_src is null then
      raise exception '0101: % is not present. This migration expects the four '
        'payload functions to exist; apply the earlier bundles first.', v_name;
    end if;

    if v_src like '%fn__only_these_keys%' then
      raise notice '0101: % already refuses unknown keys', v_name;
      continue;
    end if;

    -- AFTER THE PERMISSION CHECK, not at the top of the body.
    --
    -- The first draft inserted after `begin`, which put payload validation
    -- ahead of "Not permitted". That is the wrong order on principle: a caller
    -- who may not do the thing should be told that and nothing else, and every
    -- other function in this schema authorises first. So the anchor is the
    -- closing `end if;` of the function's own permission gate, found by taking
    -- the first `end if;` that follows the first 'Not permitted' it raises.
    v_at := position('Not permitted' in v_src);
    if v_at = 0 then
      raise exception '0101: % has no "Not permitted" gate, so this migration '
        'cannot tell where the permission check ends. Nothing was changed.', v_name;
    end if;
    v_end := position(E'\n  end if;\n' in substr(v_src, v_at));
    if v_end = 0 then
      raise exception '0101: could not find the end of %''s permission gate. '
        'Nothing was changed.', v_name;
    end if;
    v_at := v_at + v_end + length(E'\n  end if;\n') - 1;

    v_call := format(
      E'  perform public.fn__only_these_keys(%I, %L::text[], %L);\n',
      v_arg, '{' || v_keys || '}', v_what);

    v_new := substr(v_src, 1, v_at - 1) || v_call || substr(v_src, v_at);
    if v_new = v_src then
      raise exception '0101: the insertion into % changed nothing', v_name;
    end if;
    execute v_new;
  end loop;
end $patch$;

-- ---------------------------------------------------------------------------
-- 3. Did it take?
--
-- Narrow, like 0100's: this runs straight after the patch, so what it catches
-- is THIS FILE failing on a school whose function shapes differ. The lasting
-- check is supabase/tests/payload_keys.sql, which proves the refusal actually
-- happens rather than that the text is present.
-- ---------------------------------------------------------------------------
do $assert$
declare v_missing text;
begin
  select string_agg(x.name, ', ' order by x.name) into v_missing
  from (values ('fn_enter_marks'), ('fn_enter_assessment_marks'),
               ('fn_mark_attendance'), ('fn_record_bulk_payments')) as x(name)
  where not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = x.name
      and p.prosrc like '%fn__only_these_keys%');

  if v_missing is not null then
    raise exception '0101: these still accept a key they do not read: %', v_missing;
  end if;
end $assert$;
