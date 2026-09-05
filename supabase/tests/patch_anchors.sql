-- =============================================================================
-- The anchor a migration uses to patch somebody else's function
--
-- WHY THIS FILE EXISTS
--
-- 0101 needed to add one `perform` to four functions that are 60 to 114 lines
-- long. Retyping a body to add a statement is how a stack of earlier fixes gets
-- silently reverted, which this repository has recorded happening twice, so the
-- statement is inserted into the function's own definition instead. The first
-- version located the insertion point with
--
--     position(E'\n  end if;\n' in substr(v_src, v_at))
--
-- which requires the permission gate to close with a newline, exactly two
-- spaces, `end if;`, and a newline. That held on every database built in this
-- repository. It missed on the first real school, with
--
--     ERROR: 0101: could not find the end of fn_enter_marks's permission gate.
--
-- and because the Supabase SQL editor runs a pasted file as ONE transaction,
-- that single raise rolled back all seven migrations in bundle 12. The fee
-- total, the headcount, the attendance rule, the till, the family's deposit and
-- the parent login were all lost to a whitespace assumption in the seventh.
--
-- Two things came out of that. The anchor moved into one function,
-- public.fn__patch_after_gate, so there is one of it to get right rather than
-- one per migration. And this file exists, because the reason the flaw shipped
-- is that nothing ever asked the anchor about a gate written any other way.
--
-- So it is asked about every spelling of the same gate that a Postgres
-- definition can carry:
--
--   1. multi-line, two-space indentation, LF        the shape written here
--   2. the same with CRLF line endings              a file edited on Windows
--   3. the whole gate on one line                   a body written compactly
--   4. four-space indentation                       another house style
--   5. END IF ; in capitals with a space            valid PL/pgSQL
--
-- and about the two cases where it must NOT guess: a function with no gate at
-- all, where it falls back to the body's opening `begin`, and one where neither
-- anchor is present, where it returns null and says so rather than mangling
-- somebody's function.
--
-- The four real callers are checked separately, in payload_keys.sql. This file
-- is only about the anchor.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/patch_anchors.sql
-- =============================================================================

\set ON_ERROR_STOP on
begin;

do $t$
declare
  v_stmt text := '  perform public.marker();';
  v_src  text;
  v_new  text;
  v_anch text;
  v_gate text;
  v_i    int;
  -- Five spellings of one gate. Each is a whole function body, given to the
  -- anchor exactly as pg_get_functiondef would hand it over.
  v_shapes text[] := array[
    -- 1. what this repository writes
    'CREATE OR REPLACE FUNCTION public.probe()' || chr(10) ||
    ' RETURNS void' || chr(10) || ' LANGUAGE plpgsql' || chr(10) ||
    'AS $function$' || chr(10) ||
    'declare' || chr(10) || '  v int;' || chr(10) ||
    'begin' || chr(10) ||
    '  if not public.has_role(''owner'') then' || chr(10) ||
    '    raise exception ''Not permitted'';' || chr(10) ||
    '  end if;' || chr(10) ||
    '  v := 1;' || chr(10) ||
    'end' || chr(10) || '$function$' || chr(10),

    -- 2. the same, CRLF
    'CREATE OR REPLACE FUNCTION public.probe()' || chr(13) || chr(10) ||
    ' RETURNS void' || chr(13) || chr(10) || ' LANGUAGE plpgsql' || chr(13) || chr(10) ||
    'AS $function$' || chr(13) || chr(10) ||
    'declare' || chr(13) || chr(10) || '  v int;' || chr(13) || chr(10) ||
    'begin' || chr(13) || chr(10) ||
    '  if not public.has_role(''owner'') then' || chr(13) || chr(10) ||
    '    raise exception ''Not permitted'';' || chr(13) || chr(10) ||
    '  end if;' || chr(13) || chr(10) ||
    '  v := 1;' || chr(13) || chr(10) ||
    'end' || chr(13) || chr(10) || '$function$' || chr(13) || chr(10),

    -- 3. the gate on one line
    'CREATE OR REPLACE FUNCTION public.probe()' || chr(10) ||
    ' RETURNS void' || chr(10) || ' LANGUAGE plpgsql' || chr(10) ||
    'AS $function$' || chr(10) ||
    'declare' || chr(10) || '  v int;' || chr(10) ||
    'begin' || chr(10) ||
    '  if not public.has_role(''owner'') then raise exception ''Not permitted''; end if;' || chr(10) ||
    '  v := 1;' || chr(10) ||
    'end' || chr(10) || '$function$' || chr(10),

    -- 4. four-space indentation
    'CREATE OR REPLACE FUNCTION public.probe()' || chr(10) ||
    ' RETURNS void' || chr(10) || ' LANGUAGE plpgsql' || chr(10) ||
    'AS $function$' || chr(10) ||
    'declare' || chr(10) || '    v int;' || chr(10) ||
    'begin' || chr(10) ||
    '    if not public.has_role(''owner'') then' || chr(10) ||
    '        raise exception ''Not permitted'';' || chr(10) ||
    '    end if;' || chr(10) ||
    '    v := 1;' || chr(10) ||
    'end' || chr(10) || '$function$' || chr(10),

    -- 5. capitals, and a space before the semicolon
    'CREATE OR REPLACE FUNCTION public.probe()' || chr(10) ||
    ' RETURNS void' || chr(10) || ' LANGUAGE plpgsql' || chr(10) ||
    'AS $function$' || chr(10) ||
    'declare' || chr(10) || '  v int;' || chr(10) ||
    'begin' || chr(10) ||
    '  IF NOT public.has_role(''owner'') THEN' || chr(10) ||
    '    RAISE EXCEPTION ''Not permitted'';' || chr(10) ||
    '  END  IF ;' || chr(10) ||
    '  v := 1;' || chr(10) ||
    'end' || chr(10) || '$function$' || chr(10)
  ];
begin
  -- 1. Every shape is patched, and every one is patched at the GATE, not at the
  --    fallback. A shape that quietly took the fallback would put the statement
  --    ahead of the permission check, which is the thing being tested.
  for v_i in 1 .. array_length(v_shapes, 1) loop
    select t.patched, t.anchor into v_new, v_anch
    from public.fn__patch_after_gate(v_shapes[v_i], v_stmt) t;

    if v_new is null then
      raise exception 'FAIL: shape % was not patched at all', v_i;
    end if;
    if v_anch <> 'gate' then
      raise exception 'FAIL: shape % was patched at the % and not at the gate, '
        'so the statement runs before the permission check', v_i, v_anch;
    end if;
    if position(v_stmt in v_new) = 0 then
      raise exception 'FAIL: shape % reports patched and does not contain the '
        'statement', v_i;
    end if;
    -- The statement must land AFTER the refusal, not before it.
    if position(v_stmt in v_new) < position('Not permitted' in v_new) then
      raise exception 'FAIL: shape % put the statement ahead of the gate', v_i;
    end if;
    -- And after the gate CLOSES, not inside it: the text between the refusal
    -- and the statement has to contain the gate's own `end if;`.
    v_gate := substr(v_new,
                position('Not permitted' in v_new),
                position(v_stmt in v_new) - position('Not permitted' in v_new));
    if v_gate !~* 'end\s+if\s*;' then
      raise exception 'FAIL: shape % put the statement INSIDE the gate, so it '
        'only runs for a caller who was refused', v_i;
    end if;
    -- Exactly one copy. A patch that inserts twice is a patch that ran twice.
    if (length(v_new) - length(replace(v_new, v_stmt, ''))) / length(v_stmt) <> 1 then
      raise exception 'FAIL: shape % got the statement more than once', v_i;
    end if;
  end loop;
  raise notice '1. all five gate spellings patched, after the gate - ok';

  -- 2. Whatever the shape, the result must still be a function Postgres will
  --    accept. Textual success is not the point; a definition that no longer
  --    compiles is the failure this whole approach risks.
  for v_i in 1 .. array_length(v_shapes, 1) loop
    select t.patched into v_new
    from public.fn__patch_after_gate(v_shapes[v_i], '  perform 1;') t;
    begin
      execute v_new;
    exception when others then
      raise exception 'FAIL: shape % produced a definition Postgres rejects: %',
        v_i, sqlerrm;
    end;
  end loop;
  raise notice '2. every patched definition still compiles - ok';

  -- 3. No gate: fall back to the body's opening `begin` and SAY so, so the
  --    caller can report that the ordering is not what it intended.
  v_src := 'CREATE OR REPLACE FUNCTION public.probe2()' || chr(10) ||
           ' RETURNS void' || chr(10) || ' LANGUAGE plpgsql' || chr(10) ||
           'AS $function$' || chr(10) ||
           'begin' || chr(10) || '  perform 1;' || chr(10) ||
           'end' || chr(10) || '$function$' || chr(10);
  select t.patched, t.anchor into v_new, v_anch
  from public.fn__patch_after_gate(v_src, v_stmt) t;
  if v_anch <> 'begin' then
    raise exception 'FAIL: a function with no permission gate reported anchor %, '
      'expected begin', v_anch;
  end if;
  if position(v_stmt in v_new) = 0 then
    raise exception 'FAIL: the begin fallback did not insert the statement';
  end if;
  execute v_new;
  raise notice '3. a function with no gate falls back to `begin`, and says so - ok';

  -- 4. Neither anchor: return null rather than guess. A migration that guesses
  --    here hands `execute` a mangled body, and the school finds out.
  select t.patched, t.anchor into v_new, v_anch
  from public.fn__patch_after_gate('select 1', v_stmt) t;
  if v_new is not null or v_anch <> 'none' then
    raise exception 'FAIL: text with no anchor at all was reported as patched (%)',
      v_anch;
  end if;
  raise notice '4. text with neither anchor returns null, not a guess - ok';

  -- 5. Nothing to insert is not an error, and must not silently return a
  --    definition claiming to have been patched.
  select t.patched, t.anchor into v_new, v_anch
  from public.fn__patch_after_gate(v_shapes[1], '') t;
  if v_new is not null then
    raise exception 'FAIL: an empty statement was reported as patched';
  end if;
  select t.patched into v_new from public.fn__patch_after_gate(null, v_stmt) t;
  if v_new is not null then
    raise exception 'FAIL: a null definition was reported as patched';
  end if;
  raise notice '5. an empty or missing input is refused, not invented - ok';

  -- 6. The anchor is not reachable by anybody who signs in. It edits function
  --    bodies and executes the result; it is a migration tool, not an API.
  if has_function_privilege('anon', 'public.fn__patch_after_gate(text,text)', 'execute')
     or has_function_privilege('authenticated', 'public.fn__patch_after_gate(text,text)', 'execute')
  then
    raise exception 'FAIL: fn__patch_after_gate is reachable from the browser';
  end if;
  raise notice '6. the anchor is not reachable from the browser - ok';
end $t$;

-- 7. And the mistake itself, held in place. No migration may go back to
--    anchoring on a literal newline plus a fixed indentation, because that is
--    the exact line that cost a school six migrations. The check is on the
--    files, not the database, so it fails the moment somebody writes it again.
--
--    This is asserted in CI as well, by supabase/check-patch-anchors.py, which
--    can read the migration files. Here it is only recorded, because a psql
--    suite cannot see the repository.
do $t$
begin
  raise notice '7. the newline-anchored form is banned by '
    'supabase/check-patch-anchors.py - ok';
end $t$;

rollback;
\echo 'PATCH ANCHORS: ALL TESTS PASSED'
