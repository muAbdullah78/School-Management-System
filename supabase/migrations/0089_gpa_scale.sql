-- =============================================================================
-- 0089 — A school could choose a GPA scale and keep getting letters
--
-- WHAT WAS THERE
--
-- Settings → School profile offers a "Grade scale" dropdown with two options:
--
--     <option value="letter">Letter (A+, A, B…)</option>
--     <option value="gpa10">GPA (10-point)</option>
--
-- `fn_grade_for` is the only grade function in the database, it is the only
-- caller of the setting's own idea, and it never reads `grade_scale` at all:
--
--     select coalesce(pass_percent, 33) into v_pass from public.school_settings …
--     if p_percent < v_pass then return 'F'; end if;
--     return case when p_percent >= 90 then 'A+' … else 'E' end;
--
-- So a school selects GPA, the form saves, "Saved." appears, and every result
-- card, every per-subject grade, the tabulation sheet and the parent portal keep
-- printing A+ / A / B / C / D / E / F. Nothing warns anybody. The school finds
-- out when a parent asks why the card does not say what the office said it would.
--
-- This was a KNOWN gap — docs/PARITY.md recorded it in the exam-computation
-- section, in as many words: "`school_settings.grade_scale` still offers `gpa10`
-- and `fn_grade_for` still always returns letters, which is its own piece of
-- work." Recording a defect honestly is not the same as fixing it, and the UI
-- went on offering the option the whole time. That is the part worth naming: a
-- setting a school can choose must do what it says, or it must not be offered.
--
-- WHAT A 10-POINT SCALE ACTUALLY MEANS, AND THE ONE DECISION THAT MATTERS
--
-- A grade point is per PAPER. A GPA is the MEAN of a pupil's grade points. Those
-- are different numbers, and the difference is the whole reason for the feature:
--
--   Two pupils, four papers each, both aggregating 70%.
--     Aisha:  70, 70, 70, 70   → points 8, 8, 8, 8   → GPA 8.0
--     Bilal:  95, 95, 45, 45   → points 10, 10, 5, 5 → GPA 7.5
--
--   Banding the AGGREGATE gives them both 8.0 and throws away exactly the
--   information a GPA exists to carry. So the card's overall figure is computed
--   as the mean of the marked papers' points, to one decimal.
--
-- The bands are the same cut points the letter scale already uses — 90 / 80 / 70
-- / 60 / 50 / 40 — so the two scales agree about which band a mark falls into and
-- a school switching between them sees a translation rather than a re-grading.
-- Below the school's own pass mark is 0, matching the letter scale returning F.
--
--   90+ → 10    80+ → 9    70+ → 8    60+ → 7    50+ → 6    40+ → 5
--   at or above the pass mark but under 40 → 4        below the pass mark → 0
--
-- WHY THE SCALE IS FROZEN ONTO THE CARD
--
-- `fn_generate_result_cards` freezes everything the print needs, for the reason
-- 0083 set out: a portal or a print that recomputed could disagree with the paper
-- the family is holding. The scale is now part of that snapshot, so a card
-- generated under `letter` still prints "Grade A" after the school switches to
-- GPA, and a card generated under `gpa10` still prints "GPA 8.5" if they switch
-- back. Without it the printed label would flip on every card ever issued the
-- moment somebody changed a dropdown.
--
-- UNMARKED PAPERS ARE EXCLUDED FROM THE MEAN, not counted as zero. This is the
-- same rule 0058 established for the percentage, and for the same reason: one
-- `coalesce(sum(…), 0)` there had made "no mark exists" and "a mark of zero" the
-- same thing, and printed two A+ pupils as a C and a D. A provisional card's GPA
-- is the mean of what has been marked, and the card says PROVISIONAL on its face.
--
-- WHAT IS STILL NOT BUILT, said plainly rather than left to be discovered:
-- credit-weighted GPA. A real 10-point system often weights each paper by credit
-- hours; ours treats every paper as one credit, because `exam_subjects` has no
-- credit column and inventing one would be a schema change nobody has asked for.
-- A school running unequal credits gets an unweighted mean, which is what a
-- Pakistani school marking out of different totals per paper generally wants
-- anyway.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. fn_grade_for reads the setting it was always supposed to read
--
-- Returns text either way, because `result_cards.grade` and the per-subject
-- `grade` in the frozen snapshot are both text — '9' is a grade point, not a
-- number to do arithmetic on downstream, and the one place that DOES average
-- them casts explicitly.
-- ---------------------------------------------------------------------------
create or replace function public.fn_grade_for(p_percent numeric)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_pass numeric; v_scale text;
begin
  if p_percent is null then return null; end if;

  select coalesce(pass_percent, 33), coalesce(nullif(btrim(grade_scale), ''), 'letter')
    into v_pass, v_scale
  from public.school_settings where school_id = public.current_school_id();
  v_pass  := coalesce(v_pass, 33);
  v_scale := coalesce(v_scale, 'letter');

  if v_scale = 'gpa10' then
    -- Same cut points as the letter scale, so the two agree about the band.
    if p_percent < v_pass then return '0'; end if;
    return case
      when p_percent >= 90 then '10'
      when p_percent >= 80 then '9'
      when p_percent >= 70 then '8'
      when p_percent >= 60 then '7'
      when p_percent >= 50 then '6'
      when p_percent >= 40 then '5'
      else '4' end;
  end if;

  if p_percent < v_pass then return 'F'; end if;
  return case
    when p_percent >= 90 then 'A+'
    when p_percent >= 80 then 'A'
    when p_percent >= 70 then 'B'
    when p_percent >= 60 then 'C'
    when p_percent >= 50 then 'D'
    else 'E' end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. The card's overall figure becomes a real GPA
--
-- Four surgical edits to fn_generate_result_cards, applied programmatically from
-- pg_get_functiondef. The body is 250 lines of exam computation that has nothing
-- to do with this change, and retyping it is how the 0058 fixes get silently
-- reverted — which is the reason 0084 and 0085 did the same thing.
--
-- Every edit asserts its own anchor first and the whole set is verified by what
-- the body SAYS at the end of the file.
-- ---------------------------------------------------------------------------
do $rewrite$
declare
  v_src text;
  v_new text;

  -- (a) two more locals
  a_old text := '  v_ver integer; v_att numeric; v_grade text; v_frozen jsonb;';
  a_new text := '  v_ver integer; v_att numeric; v_grade text; v_frozen jsonb;'
             || E'\n' || '  v_scale text; v_gpa numeric;   -- 0089';

  -- (b) read the scale once, next to the pass mark it belongs with
  b_old text := '  v_pass_pct := coalesce(v_pass_pct, 33);';
  b_new text := '  v_pass_pct := coalesce(v_pass_pct, 33);'
             || E'\n' || E'\n'
             || '  -- 0089. Read once for the whole class, not per pupil: a school that'   || E'\n'
             || '  -- changed the dropdown halfway through a generation run would otherwise' || E'\n'
             || '  -- produce two kinds of card in one class.'                              || E'\n'
             || '  select coalesce(nullif(btrim(grade_scale), ''''), ''letter'') into v_scale' || E'\n'
             || '    from public.school_settings where school_id = v_school;'               || E'\n'
             || '  v_scale := coalesce(v_scale, ''letter'');';

  -- (c) the scale travels WITH the card
  c_old text := '      ''pass_percent'', v_pass_pct,';
  c_new text := '      ''pass_percent'', v_pass_pct,'
             || E'\n'
             || '      -- 0089. Frozen, so a card printed after the school switches scale'  || E'\n'
             || '      -- still says what it said when it was issued. Without this the'      || E'\n'
             || '      -- printed label on every card ever generated would flip the moment'  || E'\n'
             || '      -- somebody changed a dropdown.'                                      || E'\n'
             || '      ''grade_scale'', v_scale,';

  -- (d) the mean of the marked papers' points, replacing the banded aggregate
  d_old text := '    insert into public.result_cards(school_id, student_id, enrollment_id, exam_term_id,';
  d_new text :=
        '    -- 0089. A GPA is the MEAN of the grade points, not the band of the'      || E'\n'
     || '    -- aggregate. Two pupils both on 70% — one with four 70s, one with two'   || E'\n'
     || '    -- 95s and two 45s — have GPAs of 8.0 and 7.5, and banding the'           || E'\n'
     || '    -- aggregate would give them both 8.0 and discard exactly what a GPA'     || E'\n'
     || '    -- is for. Unmarked papers are excluded rather than counted as zero,'     || E'\n'
     || '    -- which is the rule 0058 established for the percentage.'                || E'\n'
     || '    if v_scale = ''gpa10'' then'                                             || E'\n'
     || '      select round(avg((s->>''grade'')::numeric), 1) into v_gpa'             || E'\n'
     || '      from jsonb_array_elements(v_frozen->''subjects'') s'                    || E'\n'
     || '      where coalesce((s->>''marked'')::boolean, false)'                       || E'\n'
     || '        and s->>''grade'' is not null;'                                       || E'\n'
     || '      if v_gpa is not null then'                                              || E'\n'
     || '        v_grade := trim(to_char(v_gpa, ''FM990.0''));'                        || E'\n'
     || '        v_frozen := jsonb_set(v_frozen, ''{grade}'', to_jsonb(v_grade));'     || E'\n'
     || '      end if;'                                                                || E'\n'
     || '    end if;'                                                                  || E'\n'
     || E'\n'
     || '    insert into public.result_cards(school_id, student_id, enrollment_id, exam_term_id,';
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_generate_result_cards';

  if v_src is null then
    raise exception '0089: public.fn_generate_result_cards does not exist';
  end if;

  if position('v_scale' in v_src) > 0 then
    raise notice '0089: fn_generate_result_cards already honours the grade scale';
    return;
  end if;

  if position(a_old in v_src) = 0 then
    raise exception '0089: cannot find the local declarations in fn_generate_result_cards';
  end if;
  if position(b_old in v_src) = 0 then
    raise exception '0089: cannot find the pass-mark default in fn_generate_result_cards';
  end if;
  if position(c_old in v_src) = 0 then
    raise exception '0089: cannot find pass_percent in the frozen snapshot';
  end if;
  if position(d_old in v_src) = 0 then
    raise exception '0089: cannot find the result_cards insert in fn_generate_result_cards';
  end if;

  v_new := replace(v_src, a_old, a_new);
  v_new := replace(v_new, b_old, b_new);
  v_new := replace(v_new, c_old, c_new);
  v_new := replace(v_new, d_old, d_new);
  execute v_new;
  -- create or replace preserves the ACL, so no re-grant is needed.
end $rewrite$;

-- ---------------------------------------------------------------------------
-- 3. The parent portal has to know which scale it is showing
--
-- fn_portal_child_results (0083) returns `grade` and nothing about the scale, so
-- a portal under gpa10 would show a parent a bare badge reading "8.5" with no
-- indication of what it was out of. Read from the FROZEN snapshot for the same
-- reason as everything else on that function: the portal and the printed card
-- must not be able to disagree.
-- ---------------------------------------------------------------------------
do $rewrite$
declare
  v_src text;
  v_old text := '               ''percentage'', x.percentage, ''grade'', x.grade,';
  v_new text := '               ''percentage'', x.percentage, ''grade'', x.grade,' || E'\n'
             || '               -- 0089. Which scale that grade is on, frozen onto the card.' || E'\n'
             || '               -- Older cards carry none, and older cards are letters.' || E'\n'
             || '               ''grade_scale'', coalesce(x.frozen->>''grade_scale'', ''letter''),';
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_portal_child_results';

  if v_src is null then
    raise exception '0089: public.fn_portal_child_results does not exist';
  end if;

  if position('''grade_scale''' in v_src) > 0 then
    raise notice '0089: the portal already reports the grade scale';
  elsif position(v_old in v_src) = 0 then
    raise exception
      '0089: cannot find the percentage/grade line in fn_portal_child_results';
  else
    execute replace(v_src, v_old, v_new);
  end if;
end $rewrite$;

-- ---------------------------------------------------------------------------
-- 4. The setting can only hold a scale that exists
--
-- Not a cosmetic tidy. `grade_scale` is plain text with no constraint, so a
-- typo or a third option added to the dropdown and not to fn_grade_for would
-- silently fall through to letters — the exact defect this migration exists to
-- fix, arriving again by a different route. A constraint makes the next person
-- add the branch before they can add the option.
-- ---------------------------------------------------------------------------
do $constraint$
declare v_bad text;
begin
  select string_agg(distinct coalesce(grade_scale, '(null)'), ', ') into v_bad
    from public.school_settings
   where coalesce(nullif(btrim(grade_scale), ''), 'letter') not in ('letter', 'gpa10');
  if v_bad is not null then
    -- Never rewrite a school's setting silently. Say what is there and stop.
    raise exception
      '0089: school_settings.grade_scale holds a value no grade scale implements '
      '(%). Set it to letter or gpa10 before applying this.', v_bad;
  end if;

  if not exists (select 1 from pg_constraint
                  where conname = 'school_settings_grade_scale_known') then
    alter table public.school_settings
      add constraint school_settings_grade_scale_known
      check (grade_scale is null
             or btrim(grade_scale) = ''
             or btrim(grade_scale) in ('letter', 'gpa10'));
  end if;
end $constraint$;

-- ---------------------------------------------------------------------------
-- 5. The end state, asserted
-- ---------------------------------------------------------------------------
do $assert$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_grade_for';
  if position('gpa10' in v_src) = 0 then
    raise exception
      '0089: fn_grade_for still ignores school_settings.grade_scale, so a school '
      'that selects GPA still gets letters on every card.';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_generate_result_cards';

  -- Each of the four edits, checked by what the body says. "The statement ran"
  -- is not evidence; this project has been caught by that four times.
  if position('''grade_scale'', v_scale' in v_src) = 0 then
    raise exception '0089: the grade scale is not frozen onto the card, so a '
      'printed card would change its label when the setting changes';
  end if;
  if position('jsonb_set(v_frozen, ''{grade}''' in v_src) = 0 then
    raise exception '0089: the card''s overall grade is still the band of the '
      'aggregate rather than the mean of the papers'' grade points';
  end if;
  if position('''{subjects}''' in v_src) > 0 then
    raise exception '0089: unexpected rewrite of the subjects array';
  end if;
  if position('marked' in v_src) = 0 then
    raise exception '0089: the GPA mean is not restricted to marked papers';
  end if;

  if not exists (select 1 from pg_constraint
                  where conname = 'school_settings_grade_scale_known') then
    raise exception '0089: grade_scale can still be set to a scale nothing implements';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_portal_child_results';
  if position('''grade_scale''' in v_src) = 0 then
    raise exception
      '0089: the portal does not say which scale a grade is on, so a parent '
      'under gpa10 sees a bare "8.5" with nothing to read it against.';
  end if;
end $assert$;
