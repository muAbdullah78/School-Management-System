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
-- after the function's own permission gate, and the result is executed.
--
-- THE FIRST VERSION OF THAT INSERTION IS WHY THIS FILE READS THE WAY IT DOES.
-- It located the gate with an anchor that assumed two-space indentation and LF
-- line endings, which held on every database built here and failed on the first
-- real school. Because the Supabase SQL editor runs a pasted file as one
-- transaction, one raise in this file rolled back all seven migrations in the
-- bundle. Section 2 records the measurement, moves the anchor into a single
-- tested function, and makes an anchor that cannot find its footing report
-- itself and step aside rather than take six unrelated fixes with it.
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
-- 2. Where a check like this belongs in somebody else's function
--
-- WHY THIS IS A FUNCTION AND NOT FOUR LINES OF STRING SURGERY
--
-- The first version of this migration found its insertion point with
--
--     position(E'\n  end if;\n' in substr(v_src, v_at))
--
-- which requires the gate to close with a newline, exactly two spaces, `end
-- if;`, and a newline. That held on every database built here and failed on the
-- first real school, with
--
--     0101: could not find the end of fn_enter_marks's permission gate.
--
-- and because the Supabase SQL editor runs a pasted file as ONE transaction,
-- that single raise rolled back all seven migrations in the bundle. Six
-- unrelated fixes -- the fee total, the headcount, the attendance rule, the
-- till, the family's deposit, the parent login -- were lost to a whitespace
-- assumption in the seventh.
--
-- Measured afterwards, on four spellings of the same gate:
--
--   shape                              E'\n  end if;\n'   end\s+if\s*;
--   multi-line, two spaces, LF               matches         matches
--   the same with CRLF line endings          NO              matches
--   the whole gate on one line               NO              matches
--   four-space indentation                   NO              matches
--
-- So the anchor is now whitespace-blind, it lives in ONE place rather than
-- being retyped per function, and supabase/tests/patch_anchors.sql runs it
-- against all four shapes. Any later migration that needs to add a statement to
-- a function it did not write must call this rather than inventing its own
-- anchor, which is the mistake this file made.
--
-- IF THE GATE CANNOT BE FOUND AT ALL, it falls back to the first line that is
-- exactly `begin`, which is where pg_get_functiondef always puts the start of
-- the body. The cost of the fallback is ordering: the payload is checked before
-- the caller is authorised, so an unauthorised caller is told the key list
-- rather than only "Not permitted". Those key names are already in the
-- browser bundle as TypeScript payload types, so nothing is disclosed that a
-- reader of the app does not already have; the check still refuses, and a
-- refusal in the wrong order beats a class of marks written as NULL.
--
-- Returns null when neither anchor is found, so the caller decides what that
-- means instead of this function aborting a transaction it knows nothing about.
-- ---------------------------------------------------------------------------
create or replace function public.fn__patch_after_gate(p_src text, p_stmt text)
returns table (patched text, anchor text)
language plpgsql immutable as $$
declare
  v_at   int;
  v_tail text;
  v_new  text;
begin
  patched := null;
  anchor  := 'none';

  if p_src is null or p_stmt is null or p_stmt = '' then
    return next;
    return;
  end if;

  -- 1. Immediately after the close of the function's own permission gate,
  --    taken as the first `end if;` following the first 'Not permitted' it
  --    raises. Every gate in this schema is a flat two-line if, checked; a
  --    nested one would put the statement inside the inner branch, which is
  --    why the four callers are inspected rather than assumed.
  v_at := position('Not permitted' in p_src);
  if v_at > 0 then
    v_tail := substr(p_src, v_at);
    v_new  := regexp_replace(v_tail, 'end\s+if\s*;',
                             'end if;' || chr(10) || p_stmt, 'i');
    if v_new <> v_tail then
      patched := substr(p_src, 1, v_at - 1) || v_new;
      anchor  := 'gate';
      return next;
      return;
    end if;
  end if;

  -- 2. Otherwise the body's opening `begin`, which pg_get_functiondef always
  --    emits in column one. Indented `begin`s are nested blocks and are
  --    deliberately not matched.
  v_new := regexp_replace(p_src, '^begin[ \t\r]*$',
                          'begin' || chr(10) || p_stmt, 'n');
  if v_new <> p_src then
    patched := v_new;
    anchor  := 'begin';
    return next;
    return;
  end if;

  return next;
end $$;

revoke all on function public.fn__patch_after_gate(text, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The four callers, patched from their own definitions
--
-- Every overload carrying the payload argument is patched, not the first row
-- pg_proc happens to return. The earlier version did
--
--     select pg_get_functiondef(p.oid) into v_src ... where p.proname = v_name
--
-- which on a database that still carries a superseded signature picks one of
-- them arbitrarily and hardens whichever it got.
--
-- Each patch runs inside its own block with an exception handler, so it is its
-- own subtransaction. A surprise in one function -- a shape neither anchor
-- fits, a definition that no longer compiles -- leaves that one function alone
-- and says so, and the other six migrations in this bundle still apply. That is
-- the whole lesson of the failure recorded in section 2: a hardening that
-- cannot find its footing must not take correctness fixes down with it.
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
  v_proc oid;
  v_src text; v_new text; v_anchor text;
  v_call text;
  v_found int;
  v_done int;
begin
  for v_i in 1 .. array_length(v_targets, 1) loop
    v_name := v_targets[v_i][1];
    v_arg  := v_targets[v_i][2];
    v_what := v_targets[v_i][3];
    v_keys := v_targets[v_i][4];

    v_call := format(
      '  perform public.fn__only_these_keys(%I, %L::text[], %L);',
      v_arg, '{' || v_keys || '}', v_what);

    v_found := 0;
    v_done  := 0;

    for v_proc in
      select p.oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname = v_name
        and p.proargnames @> array[v_arg]
      order by p.oid
    loop
      v_found := v_found + 1;
      begin
        v_src := pg_get_functiondef(v_proc);
        if v_src like '%fn__only_these_keys%' then
          raise notice '0101: % already refuses unknown keys', v_proc::regprocedure;
          v_done := v_done + 1;
        else
          select t.patched, t.anchor into v_new, v_anchor
          from public.fn__patch_after_gate(v_src, v_call) t;

          if v_new is null then
            raise warning '0101: % has neither a "Not permitted" gate this '
              'migration can find the end of nor a body opening on its own '
              '`begin` line, so it was left exactly as it was and the rest of '
              'this bundle still applied. It still accepts a key it does not '
              'read. Run supabase/verify.sql; it names what is outstanding.',
              v_proc::regprocedure;
          else
            execute v_new;
            if v_anchor = 'begin' then
              raise notice '0101: the permission gate in % was not where this '
                'migration looks, so the key check went at the top of the body '
                'instead of after it. It refuses correctly; it just answers '
                'before "Not permitted" does.', v_proc::regprocedure;
            end if;
            v_done := v_done + 1;
          end if;
        end if;
      exception when others then
        raise warning '0101: % was left as it was: %. The rest of this bundle '
          'still applied. Run supabase/verify.sql for what is outstanding.',
          v_proc::regprocedure, sqlerrm;
      end;
    end loop;

    if v_found = 0 then
      raise warning '0101: no function public.% takes a % argument, so nothing '
        'was hardened for it. Apply the earlier bundles first.', v_name, v_arg;
    elsif v_done = 0 then
      raise warning '0101: nothing could be hardened for public.%', v_name;
    end if;
  end loop;
end $patch$;

-- ---------------------------------------------------------------------------
-- 4. Did it take?
--
-- A WARNING and not an exception, deliberately, and this is the second half of
-- the lesson in section 2. Raising here aborts the pasted bundle and undoes six
-- migrations that have nothing to do with unknown keys. So the shortfall is
-- reported by name and the transaction is allowed to commit.
--
-- It does not become invisible by being non-fatal. supabase/verify.sql asks the
-- same catalogue question on the finished database and prints a FAIL naming the
-- functions still outstanding, and supabase/tests/payload_keys.sql proves the
-- refusal actually happens rather than that the text is present.
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

  if v_missing is null then
    raise notice '0101: all four now refuse a key they do not read';
  else
    raise warning '0101: these still accept a key they do not read: %. '
      'Everything else in this bundle applied. Send the output of '
      'supabase/verify.sql so the gate shape on this database can be handled.',
      v_missing;
  end if;
end $assert$;
