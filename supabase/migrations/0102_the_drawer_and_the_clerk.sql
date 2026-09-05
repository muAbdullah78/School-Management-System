-- =============================================================================
-- 0102 — The cash drawer accused the clerk of a shortfall the software created
--
-- WHAT WAS MEASURED
--
-- One ordinary morning at the counter, seeded and run:
--
--   open the drawer with a Rs 1,000 float
--   take Rs 3,000 in cash for September            drawer holds 4,000
--   the cheque bounced: reverse it, hand the money back   drawer holds 1,000
--   admit a child, Rs 2,000 admission fee in cash  drawer holds 3,000
--
--   THE TILL EXPECTS Rs 4,000. THE DRAWER HOLDS Rs 3,000.
--   "The drawer is off by -1000.00. A reason is required to close it."
--
-- The clerk did everything correctly and cannot close their till without
-- writing an explanation for money they never touched. The variance is then
-- recorded against them and an owner signs it off. In a Pakistani school office
-- that is not a rounding complaint, it is an accusation, and it lands on the
-- lowest-paid person in the building.
--
-- WHY, EXACTLY
--
-- 0031 attached cash to the collector's drawer by adding one line to the two
-- payment entry points, fn_record_payment and fn_record_family_payment. Two
-- other functions write to `payments` and neither was given that line:
--
--   fn_reverse_payment    the contra receipt. Money leaves the drawer and the
--                         till never learns, so the till still expects the
--                         original receipt. The drawer is SHORT by that amount.
--   fn_admit_student      the admission fee, which is hardcoded 'cash'. Money
--                         enters the drawer and the till never learns, so the
--                         drawer is OVER by that amount -- which fn_close_till's
--                         own comment calls "as much a red flag as missing cash".
--
-- In the run above the two partly cancelled, which is worse than either alone:
-- a Rs 3,000 shortfall and a Rs 2,000 surplus presented as a Rs 1,000 mystery.
--
-- WHICH DRAWER A REVERSAL COMES OUT OF
--
-- Not the same question as "who is doing it". fn_reverse_payment is
-- owner/principal only, and a principal usually has no drawer of their own; the
-- cash is handed back from the drawer it went into. So:
--
--   1. the original payment's till, IF that session is still open. The money is
--      physically in that drawer and taking it out is what the contra records.
--   2. otherwise the person's own open till, if they have one. The original
--      drawer is closed and counted; the cash is coming out of whatever is open
--      in front of them now.
--   3. otherwise nothing, exactly as today. A reversal of last month's receipt
--      belongs to no drawer, and inventing one would open a till in somebody's
--      name that they never opened and will be asked to count.
--
-- It never CREATES a till, which is the difference from the money-in path.
-- fn__ensure_till opens one because cash that has arrived must be in somebody's
-- drawer; cash going out has no such guarantee, and a till opened with a
-- negative balance is a worse lie than an unattributed reversal.
--
-- The admission fee is money IN and uses fn__ensure_till, exactly like the two
-- entry points 0031 fixed.
--
-- Both functions are patched from their own definitions rather than retyped:
-- fn_admit_student is 200 lines and this changes one of them. Same reasoning as
-- 0100 and 0101, and the same refusal to guess if the anchor is not found.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Which drawer a reversal comes out of
-- ---------------------------------------------------------------------------
create or replace function public.fn__reversal_till(
  p_original_till uuid, p_method public.payment_method
) returns uuid language plpgsql stable security definer set search_path = public as $$
declare v_id uuid;
begin
  -- Only cash sits in a drawer. Reversing a bank transfer moves nothing on the
  -- counter, and attributing it to a till would make that till wrong.
  if p_method <> 'cash' then
    return null;
  end if;

  if p_original_till is not null then
    select id into v_id from public.till_sessions
     where id = p_original_till and status = 'open';
    if found then return v_id; end if;
  end if;

  if auth.uid() is not null then
    select id into v_id from public.till_sessions
     where opened_by = auth.uid() and status = 'open';
    if found then return v_id; end if;
  end if;

  return null;
exception when others then
  -- Never let till bookkeeping stop a reversal being recorded. The same
  -- decision fn__ensure_till made, for the same reason: the money movement is
  -- the fact, and the drawer is the annotation.
  return null;
end;
$$;

revoke all on function public.fn__reversal_till(uuid, public.payment_method)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The two writers that never learned about the drawer
-- ---------------------------------------------------------------------------
--
-- EVERY PATTERN HERE IS WHITESPACE-BLIND, AND EVERY PATCH IS ITS OWN
-- SUBTRANSACTION. 0101 shipped an anchor that assumed a fixed indentation and
-- LF line endings; it matched on every database built here, missed on the first
-- real school, and because the Supabase SQL editor runs a pasted file as ONE
-- transaction, that one raise rolled back all seven migrations in the bundle.
-- The admission-fee pattern below had the same flaw -- it matched an exact
-- newline followed by exactly six spaces -- and the two `raise exception`s had
-- the same blast radius. So:
--
--   * the two patterns match `\s+` wherever the source has whitespace, so
--     indentation and line endings cannot decide whether a school's drawer
--     balances;
--   * each patch runs in a block with an exception handler, so a definition
--     neither pattern fits leaves that one function alone;
--   * a miss is a WARNING naming the function, not an exception. The drawer
--     staying wrong for one of the two paths is bad. Reverting the fee total,
--     the headcount, the attendance rule, the family's deposit and the parent
--     login as well is worse, and it is what raising here does.
--
-- Nothing becomes invisible by being non-fatal: supabase/verify.sql names every
-- function that still writes to `payments` without a drawer, and
-- supabase/tests/till_and_the_clerk.sql runs the morning above and asserts the
-- drawer balances.
do $patch$
declare
  v_src text; v_new text;
begin
  -- ---- the contra receipt --------------------------------------------------
  begin
    select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'fn_reverse_payment';

    if v_src is null then
      raise warning '0102: fn_reverse_payment is not present, so nothing was '
        'attributed for it. Apply the earlier bundles first.';
    elsif v_src like '%fn__reversal_till%' then
      raise notice '0102: fn_reverse_payment already attributes the drawer';
    else
      v_new := regexp_replace(
        v_src,
        '(insert\s+into\s+public\.payments\s*\(\s*student_id,\s*family_id,\s*amount,\s*method,\s*receipt_no,\s*'
          || 'status,\s*received_by,\s*reversal_of,\s*note\s*\)\s*'
          || 'values\s*\(\s*v_orig\.student_id,\s*v_orig\.family_id,\s*-v_orig\.amount,\s*v_orig\.method,\s*v_receipt,\s*'
          || '''verified'',\s*v_actor,\s*p_payment_id,\s*coalesce\(\s*p_reason,\s*''reversal''\s*\))\s*\)',
        '\1, public.fn__reversal_till(v_orig.till_session_id, v_orig.method))');
      -- The column list needs the new name at the END, where the value was
      -- appended. The first version of this put the column after `receipt_no`
      -- and the value last, so the columns and the values no longer lined up
      -- and Postgres tried to write 'verified' into a uuid. Caught by
      -- re-running the morning above, which is why that fixture exists.
      v_new := regexp_replace(v_new,
        'status,(\s*)received_by,(\s*)reversal_of,(\s*)note\s*\)',
        'status,\1received_by,\2reversal_of,\3note, till_session_id)');
      if v_new = v_src or v_new not like '%fn__reversal_till%' then
        raise warning '0102: could not find the contra-receipt insert in '
          'fn_reverse_payment. It has been reworded, so nothing was changed, '
          'the rest of this bundle still applied, and a reversal still leaves '
          'the drawer short. Run supabase/verify.sql; it names what is '
          'outstanding.';
      else
        execute v_new;
      end if;
    end if;
  exception when others then
    raise warning '0102: fn_reverse_payment was left as it was: %. The rest of '
      'this bundle still applied.', sqlerrm;
  end;

  -- ---- the admission fee ---------------------------------------------------
  begin
    select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'fn_admit_student';

    if v_src is null then
      raise warning '0102: fn_admit_student is not present, so nothing was '
        'attributed for it. Apply the earlier bundles first.';
    elsif v_src like '%fn__ensure_till%' then
      raise notice '0102: fn_admit_student already attributes the drawer';
    else
      -- Two separate whitespace-blind substitutions rather than one match over
      -- the column list AND the value list together, because the two are on
      -- different lines and the amount of space between them is exactly what
      -- the earlier version got wrong.
      v_new := regexp_replace(
        v_src,
        '(insert\s+into\s+public\.payments\s*\(\s*student_id,\s*family_id,\s*amount,\s*method,\s*'
          || 'receipt_no,\s*status,\s*received_by,\s*note\s*)\)(\s*)'
          || '(values\s*\(\s*v_student,\s*v_family,\s*v_af_amt,\s*''cash'',\s*v_af_receipt,\s*'
          || '''verified'',\s*v_actor,\s*''Admission fee''\s*)\)',
        '\1, till_session_id)\2\3, public.fn__ensure_till())');
      if v_new = v_src or v_new not like '%fn__ensure_till%' then
        raise warning '0102: could not find the admission-fee insert in '
          'fn_admit_student. It has been reworded, so nothing was changed, the '
          'rest of this bundle still applied, and an admission fee still leaves '
          'the drawer over. Run supabase/verify.sql; it names what is '
          'outstanding.';
      else
        execute v_new;
      end if;
    end if;
  exception when others then
    raise warning '0102: fn_admit_student was left as it was: %. The rest of '
      'this bundle still applied.', sqlerrm;
  end;
end $patch$;

-- ---------------------------------------------------------------------------
-- 3. Did it take?
--
-- Narrow, like 0100's and 0101's: this runs straight after the patch, so it
-- catches THIS FILE failing rather than a later regression. The lasting check
-- is supabase/tests/till_and_the_clerk.sql, which runs the morning above and
-- asserts the drawer balances.
-- ---------------------------------------------------------------------------
do $assert$
declare v_bad text;
begin
  select string_agg(x.name, ', ' order by x.name) into v_bad
  from (values ('fn_reverse_payment'), ('fn_admit_student')) as x(name)
  where not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = x.name
      and p.prosrc like '%till_session_id%');

  if v_bad is null then
    raise notice '0102: both writers now say which drawer the cash came from';
  else
    -- A WARNING and not an exception, for the reason recorded above section 2:
    -- raising here undoes six migrations that have nothing to do with the till.
    raise warning '0102: these still write cash without saying which drawer '
      'it came from or went into: %. Everything else in this bundle applied. '
      'Send the output of supabase/verify.sql.', v_bad;
  end if;
end $assert$;
