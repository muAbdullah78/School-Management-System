-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0120_the_em_dash_a_clerk_reads.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0120 - The em dash a clerk reads
--
-- This house has one absolute rule about writing: no em dashes, anywhere,
-- internal or external. scripts/check-no-emdash.py enforces it and passes, and
-- it has passed all along while a clerk voiding a challan was being shown
--
--     Rs 759 has been paid against this challan. Reverse the payment first —
--     Fees -> the receipt -> Reverse — so the money movement stays on the
--     record, then cancel the charge.
--
-- WHY THE GUARD MISSED IT, and its reasoning was careful rather than lazy. Its
-- own docstring counts about 2,900 em dashes under supabase/ and argues that
-- almost all of them are in code comments no school ever reads, so sweeping the
-- directory would be "a mechanical edit of three thousand comment lines with no
-- review, which is how a real defect gets hidden inside a diff nobody can
-- read". That is right. The hole is the word "almost": supabase/ also holds
-- every `raise exception` message in the product, and those are not comments.
-- They are the sentences the software says out loud when it refuses.
--
-- Measured against the functions as actually stored, not against the migration
-- text (a message rewritten by a later migration does not matter): 28 string
-- fragments in 27 exception messages across 22 functions.
--
-- EACH ONE READ AND PUNCTUATED BY HAND, because the dash is doing three
-- different jobs in these sentences:
--
--   * a colon, where the second half explains the first
--     "A cancellation needs a reason: it stays on the register permanently"
--   * a full stop, where the second half is a fresh instruction
--     "That invoice is voided. Allocate the payment elsewhere..."
--   * a comma, where the clause simply continues
--     "...the school's records, and archiving is reversible."
--
-- A global character swap would have produced "That invoice is voided:
-- allocate the payment elsewhere", which is not a sentence anybody would write.
-- So this is a table of 27 pairs and not a regexp.
--
-- WHY A PATCH AND NOT AN EDIT TO THE MIGRATIONS THAT WROTE THEM. Those
-- migrations are inside frozen bundles. Editing 0046 to fix one word changes
-- bundle 6, which schools have already pasted, and supabase/build-bundles.sh
-- refuses it for exactly that reason.
--
-- THE DURABLE HALF OF THIS FIX IS THE VERIFY ROW, not this migration. A static
-- script cannot tell which migration holds a function's latest definition, so
-- the rule is asserted in supabase/verify.sql against the live database, where
-- the question "does any stored function say this to a user" has a real answer.
--
-- Re-runnable: a pair that has already been applied simply matches nothing.
-- =============================================================================

do $emdash$
declare
  v_pair   record;
  v_fn     record;
  v_src    text;
  v_new    text;
  v_fixed  int := 0;
  v_left   int;
begin
  for v_pair in
    select * from (values
    ('Nothing to record — no students were ticked',
     'Nothing to record: no students were ticked'),
    ('The last working day cannot be in the future — the login is closed straight away',
     'The last working day cannot be in the future: the login is closed straight away'),
    ('reason — it is recorded on the certificate itself',
     'reason: it is recorded on the certificate itself'),
    ('A cancellation needs a reason — it stays on the register permanently',
     'A cancellation needs a reason: it stays on the register permanently'),
    ('s only active owner — make someone else an owner first',
     's only active owner: make someone else an owner first'),
    ('needs a reason — it is recorded on ',
     'needs a reason: it is recorded on '),
    ('Use fn_enquiry_admit to admit — it creates the student record too',
     'Use fn_enquiry_admit to admit: it creates the student record too'),
    ('A phone number is required — an enquiry nobody can ring is not an enquiry',
     'A phone number is required: an enquiry nobody can ring is not an enquiry'),
    ('Say what happened — an empty follow-up tells the next person nothing',
     'Say what happened: an empty follow-up tells the next person nothing'),
    ('Voiding a document needs a reason — it is printed on it',
     'Voiding a document needs a reason: it is printed on it'),
    ('A credit note needs a reason — it is printed on it',
     'A credit note needs a reason: it is printed on it'),
    ('That invoice is voided — there is nothing to credit',
     'That invoice is voided: there is nothing to credit'),
    ('Say why — the school is shown this reason',
     'Say why: the school is shown this reason'),
    ('Give a reason — the school is shown it on their own screen',
     'Give a reason: the school is shown it on their own screen'),
    ('been deleted — the whole operation is one transaction.',
     'been deleted: the whole operation is one transaction.'),
    ('Take the export first — it is what you ',
     'Take the export first: it is what you '),
    ('has been deleted — the whole purge is one transaction.',
     'has been deleted: the whole purge is one transaction.'),
    ('A SHA-256 checksum is required — 64 hex characters.',
     'A SHA-256 checksum is required: 64 hex characters.'),
    ('Reverse the payment first — ',
     'Reverse the payment first: '),
    ('School location is not set — ask the principal to set it in Settings.',
     'School location is not set. Ask the principal to set it in Settings.'),
    ('exported — renew to start entering data again.',
     'exported. Renew to start entering data again.'),
    ('That invoice is voided — allocate the payment elsewhere or leave it unallocated',
     'That invoice is voided. Allocate the payment elsewhere or leave it unallocated'),
    ('That date is more than a year ago — check it',
     'That date is more than a year ago. Check it'),
    ('it off — raise a credit note if you are forgiving it, or purge on purpose.',
     'it off. Raise a credit note if you are forgiving it, or purge on purpose.'),
    ('not there — say what was wrong with the challan.',
     'not there. Say what was wrong with the challan.'),
    ('s records — and archiving is reversible.',
     's records, and archiving is reversible.'),
    ('Fees → the receipt → Reverse — so the money movement stays on the',
     'Fees → the receipt → Reverse, so the money movement stays on the')
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
        raise warning '0120: % kept its em dash: %. The rest of this bundle '
          'still applied.', v_fn.proname, sqlerrm;
      end;
    end loop;
  end loop;

  -- The guard, and it counts what is LEFT rather than what was changed. A table
  -- of pairs that had all drifted would report 0 fixed and look like a
  -- successful no-op, which is the failure mode this whole migration is about.
  select count(*) into v_left
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral regexp_matches(p.prosrc, 'raise\s+exception[^;]*[\u2014\u2013][^;]*;', 'gi') m
   where n.nspname = 'public';

  if v_left > 0 then
    raise exception '0120: % exception message(s) still contain an em or en dash. '
      'A school is still being shown one when the software refuses.', v_left;
  end if;
  raise notice '0120: % message(s) repunctuated; no stored exception message '
    'contains an em or en dash', v_fixed;
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
  perform public.fn_record_migration('0120_the_em_dash_a_clerk_reads.sql', '26_the_em_dash_a_clerk_reads.sql');
end $ledger$;
