-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0122_the_em_dash_a_parent_receives.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0122 - The em dash a parent receives
--
-- 0120 swept the em dash out of every `raise exception` message in the schema
-- and its verify row has been asserting that ever since. It was half the job,
-- and the missing half is the more visible one: a `raise exception` is what the
-- software says when it REFUSES, which most users never see. What everybody
-- sees is the text it hands over when it works.
--
-- Found while adding the verify row for 0121, by reading
-- fn_attendance_corrections and noticing coalesce(p.full_name, '—') at the
-- end of it. Counted properly afterwards, against the functions as stored and
-- with their comments stripped out: 57 string literals in 29 functions, none of
-- them a refusal message and every one of them read by somebody.
--
-- WHAT THEY ARE, in the order that matters:
--
--   * SIX MESSAGE TEMPLATES, which is the worst of it. These are seeded into
--     message_templates at signup and sent to parents by SMS and WhatsApp:
--     "Fee received. Thank you — {school}." So the em dash was not merely in
--     this product's writing, it was going out in text messages under a
--     school's name.
--
--     It is also the only place here where more than the punctuation changed.
--     Three of the six end by thanking the parent, so "Thank you. {school}."
--     is a sign-off already. The other three end on an instruction ("...please
--     contact the office."), and a bare school name after a full stop reads
--     like a dangling sentence rather than a signature, so those three now end
--     "Regards, {school}.".
--   * TWENTY-FOUR PLACEHOLDERS. `coalesce(x, '—')` in thirteen report and
--     search functions: the fee ledger, recent payments, the enquiry list, the
--     corrections reports, global search, voided challans, the discount
--     report. It is the character a school sees in a table cell where there is
--     no value, so it is on screen constantly.
--   * TWENTY-SEVEN SENTENCES the software says without refusing anything: the
--     staff check-in explaining why a saved link will not work, the licence
--     notice saying nothing stops working, the renewal message, the importer
--     saying which column to add, the operator console throughout.
--
-- READ AND PUNCTUATED ONE AT A TIME, for the reason 0120 gives at length: the
-- dash is doing the work of a colon, a full stop, a comma and a semicolon in
-- these sentences, and one global swap produces text nobody would write. The
-- placeholder is the only pattern here, and it is written WITH ITS QUOTES so it
-- can only match a literal that is exactly a dash.
--
-- IT ALSO FIXES THE DATA, not just the functions. fn__default_message_templates
-- runs once, at signup, so patching it changes nothing for a school that
-- already exists: their message_templates rows still carry the dash, and so do
-- any messages already queued and not yet sent. Both are repaired below, by the
-- exact fragment only, so a template a school has edited for itself keeps its
-- own wording.
--
-- WHY A PATCH RATHER THAN AN EDIT TO THE MIGRATIONS THAT WROTE THEM: they are
-- inside frozen bundles, and supabase/build-bundles.sh refuses to change a
-- bundle a school has already pasted.
--
-- Re-runnable: a pair that has already been applied matches nothing.
-- =============================================================================

do $emdash$
declare
  v_pair  record;
  v_fn    record;
  v_src   text;
  v_new   text;
  v_fixed int := 0;
  v_rows  int := 0;
  v_left  int;
  v_where text;
begin
  for v_pair in
    select * from (values
    ('''—''',
     '''-'''),
    ('. — {school}.',
     '. Regards, {school}.'),
    ('Thank you — {school}.',
     'Thank you. {school}.'),
    ('%s plan — school management software licence',
     '%s plan: school management software licence'),
    ('coalesce(v_note || '' — '', '''')',
     'coalesce(v_note || ''; '', '''')'),
    ('coalesce(p.note || '' — '', '''')',
     'coalesce(p.note || ''; '', '''')'),
    ('sub.name || '' — '' || count(*)::text',
     'sub.name || '': '' || count(*)::text'),
    (' matches several students — use GR No',
     ' matches several students: use GR No'),
    ('No identifier — provide GR No, Admission No, or Name',
     'No identifier: provide GR No, Admission No, or Name'),
    ('statement and confirm it here — usually the same day.',
     'statement and confirm it here, usually the same day.'),
    ('at your next renewal — nothing stops working.',
     'at your next renewal. Nothing stops working.'),
    ('Credit against %s — %s',
     'Credit against %s: %s'),
    ('VOID — %s',
     'VOID: %s'),
    ('list %s — %s',
     'list %s: %s'),
    ('no history to measure — which is ',
     'no history to measure, which is '),
    ('Not the price list — a discounted school counts at its discount.',
     'Not the price list: a discounted school counts at its discount.'),
    ('what this console did — ',
     'what this console did: '),
    ('and try again — and run ',
     'and try again, and run '),
    ('did to them — suspensions, discounts, support visits.',
     'did to them: suspensions, discounts, support visits.'),
    ('nothing has been deleted — you can still open every ',
     'nothing has been deleted: you can still open every '),
    ('s licence expires on %s — %s day(s) from today. ',
     's licence expires on %s, %s day(s) from today. '),
    ('No rush — sending it now so you have time to ',
     'No rush: sending it now so you have time to '),
    ('No contact phone on record for this school — add one in the console',
     'No contact phone on record for this school: add one in the console'),
    ('Nothing to charge for yet — Settings ',
     'Nothing to charge for yet: Settings '),
    ('a challan was ever printed — printing is a browser action and ',
     'a challan was ever printed: printing is a browser action and '),
    ('does not shorten it — ',
     'does not shorten it: '),
    ('were left as-is — reinstate individually from the student profile.',
     'were left as-is: reinstate individually from the student profile.'),
    ('at the gate — a saved link or an old photo will not work.',
     'at the gate: a saved link or an old photo will not work.'),
    ('not linked to a staff record — ask the principal to link it in Staff.',
     'not linked to a staff record: ask the principal to link it in Staff.'),
    ('Location is required to check in — enable location and try again.',
     'Location is required to check in: enable location and try again.')
    ) as t(old_text, new_text)
  loop
    for v_fn in
      select p.oid, p.proname
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.prosrc like '%' || v_pair.old_text || '%'
    loop
      begin
        v_src := pg_get_functiondef(v_fn.oid);
        v_new := replace(v_src, v_pair.old_text, v_pair.new_text);
        if v_new <> v_src then
          execute v_new;
          v_fixed := v_fixed + 1;
        end if;
      exception when others then
        raise warning '0122: % kept its em dash: %. The rest of this bundle '
          'still applied.', v_fn.proname, sqlerrm;
      end;
    end loop;
  end loop;

  -- --- The data the old function already wrote ------------------------------
  -- Two fragments, matched exactly. A school that has rewritten its own
  -- template keeps every word of it, including a dash it chose to type.
  update public.message_templates
     set body = replace(replace(body,
           'Thank you — {school}.', 'Thank you. {school}.'),
           '. — {school}.', '. Regards, {school}.')
   where body like '%— {school}%';
  get diagnostics v_rows = row_count;
  raise notice '0122: % message template(s) repunctuated', v_rows;

  -- THE MESSAGES ALREADY WAITING TO GO OUT, which is the half that would
  -- otherwise still reach a parent. message_outbox holds the FINISHED text in
  -- `rendered_text`, with the school's name already substituted for {school},
  -- so the fragments used on the template above do not match here at all. What
  -- is actually in the table is
  --
  --   ...If this is a mistake please contact the office. — Ali Public School.
  --
  -- Measured against a two-year simulation of one school: 864 queued messages
  -- carrying the dash, of which the first version of this migration repaired
  -- 104, because it matched on '{school}' and the other 760 had the name in
  -- place of it. That is why this is two statements and not one.
  --
  -- QUEUED AND FAILED ONLY. A message that has already been SENT, or that was
  -- skipped and never will be, is a record of what happened and editing it
  -- would be a lie about the past. One that has not gone yet is still this
  -- software's own writing and can still be got right.
  update public.message_outbox
     set rendered_text = replace(rendered_text, 'Thank you — ', 'Thank you. ')
   where status in ('queued', 'failed') and rendered_text like '%Thank you — %';
  get diagnostics v_rows = row_count;
  raise notice '0122: % unsent message(s) signed off with a thank you', v_rows;

  -- A regexp rather than replace(), because the school's name follows the dash
  -- and is different in every row. Anchored on ". — " so it can only match the
  -- sign-off, never a dash a school has typed inside a sentence of its own.
  update public.message_outbox
     set rendered_text = regexp_replace(rendered_text, '\. — ', '. Regards, ', 'g')
   where status in ('queued', 'failed') and rendered_text ~ '\. — ';
  get diagnostics v_rows = row_count;
  raise notice '0122: % more unsent message(s) signed off with the school name', v_rows;

  -- --- The guard -----------------------------------------------------------
  -- COUNTS WHAT IS LEFT, not what was changed, for the reason 0120 gives: a
  -- pair table that had all drifted would report 0 fixed and read like a
  -- successful no-op.
  --
  -- And it strips `--` comments before looking, which is the whole reason this
  -- can be asserted at all. supabase/ holds about 2,900 em dashes and almost
  -- every one is in a comment no school reads, so "does this function contain
  -- the character" is not the question. "Does this function SAY it" is, and
  -- with the comments removed the only place left for a dash to hide is a
  -- string literal.
  select count(*), string_agg(distinct proname, ', ') into v_left, v_where
    from (
      select p.proname
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and regexp_replace(p.prosrc, '--.*$', '', 'gn') ~ '[\u2014\u2013]'
    ) q;

  if v_left > 0 then
    raise exception '0122: % function(s) still say an em or en dash out loud: %',
      v_left, v_where;
  end if;
  raise notice '0122: % function body/bodies repunctuated; nothing in this '
    'schema now says an em or en dash outside a comment', v_fixed;
end $emdash$;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0122_the_em_dash_a_parent_receives.sql', '28_the_em_dash_a_parent_receives.sql');
end $ledger$;
