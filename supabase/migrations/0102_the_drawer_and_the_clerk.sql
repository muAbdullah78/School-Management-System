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
do $patch$
declare
  v_src text; v_new text;
begin
  -- ---- the contra receipt --------------------------------------------------
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_reverse_payment';
  if v_src is null then
    raise exception '0102: fn_reverse_payment is not present; apply the earlier bundles first';
  end if;

  if v_src like '%fn__reversal_till%' then
    raise notice '0102: fn_reverse_payment already attributes the drawer';
  else
    v_new := regexp_replace(
      v_src,
      '(insert into public\.payments\(student_id, family_id, amount, method, receipt_no,\s*'
        || 'status, received_by, reversal_of, note\)\s*'
        || 'values \(v_orig\.student_id, v_orig\.family_id, -v_orig\.amount, v_orig\.method, v_receipt,\s*'
        || '''verified'', v_actor, p_payment_id, coalesce\(p_reason, ''reversal''\))\)',
      '\1, public.fn__reversal_till(v_orig.till_session_id, v_orig.method))');
    -- The column list needs the new name at the END, where the value was
    -- appended. The first version of this put the column after `receipt_no` and
    -- the value last, so the columns and the values no longer lined up and
    -- Postgres tried to write 'verified' into a uuid. Caught by re-running the
    -- morning above, which is why that fixture exists.
    v_new := replace(v_new,
      'status, received_by, reversal_of, note)',
      'status, received_by, reversal_of, note, till_session_id)');
    if v_new = v_src or v_new not like '%fn__reversal_till%' then
      raise exception '0102: could not find the contra-receipt insert in '
        'fn_reverse_payment. It has been reworded, so nothing was changed and '
        'the drawer would keep being wrong. Update the pattern in this migration.';
    end if;
    execute v_new;
  end if;

  -- ---- the admission fee ---------------------------------------------------
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_admit_student';
  if v_src is null then
    raise exception '0102: fn_admit_student is not present; apply the earlier bundles first';
  end if;

  if v_src like '%fn__ensure_till%' then
    raise notice '0102: fn_admit_student already attributes the drawer';
  else
    v_new := replace(v_src,
      'insert into public.payments(student_id, family_id, amount, method, receipt_no, status, received_by, note)'
        || E'\n      values (v_student, v_family, v_af_amt, ''cash'', v_af_receipt, ''verified'', v_actor, ''Admission fee'')',
      'insert into public.payments(student_id, family_id, amount, method, receipt_no, status, received_by, note, till_session_id)'
        || E'\n      values (v_student, v_family, v_af_amt, ''cash'', v_af_receipt, ''verified'', v_actor, ''Admission fee'', public.fn__ensure_till())');
    if v_new = v_src then
      raise exception '0102: could not find the admission-fee insert in '
        'fn_admit_student. It has been reworded, so nothing was changed and the '
        'drawer would keep being over. Update the pattern in this migration.';
    end if;
    execute v_new;
  end if;
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

  if v_bad is not null then
    raise exception '0102: these still write cash without saying which drawer '
      'it came from or went into: %', v_bad;
  end if;
end $assert$;
