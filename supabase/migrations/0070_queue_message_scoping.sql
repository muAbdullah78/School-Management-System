-- =============================================================================
-- 0070 — One school could read another school's families, and edit their fees
--
-- TWO cross-tenant defects, both proven on live two-school fixtures before this
-- file was written, both now permanent assertions in
-- supabase/tests/tenant_isolation.sql TEST 6:
--
--   1. fn_queue_message handed over another school's family head name, phone
--      number, child's name and exact outstanding balance. A READ leak.
--
--   2. fn__apply_discount_lines let one school write a discount line onto
--      ANOTHER school's invoice, cutting what that school charges its parent
--      from Rs 5,000 to Rs 4,000. A WRITE, and the worse of the two: the
--      victim school's own fee report shows a discount it never granted.
--
-- Both are the same bug class: a SECURITY DEFINER function — where RLS does not
-- apply — looking up a tenant row by a CALLER-SUPPLIED id with no school filter.
-- The plainest IDOR there is. This codebase already has the answer to it,
-- public.assert_own(table, id), and 33 of the 38 functions taking an id use it.
-- These two did not.
--
-- WHAT HAPPENED — 1. THE READ LEAK
--
-- public.fn_queue_message(p_template_key, p_family_id, ...) is SECURITY DEFINER,
-- so RLS does not apply to anything inside it. It looked up the family like
-- this:
--
--     select * into v_f from public.families where id = p_family_id;
--
-- No school filter. No assert_own. The children's names were gathered the same
-- way, and the balance came from family_outstanding(p_family_id), which sums
-- students by family_id with no school filter of its own.
--
-- So School A's owner passed School B's family id and got this row in School A's
-- OWN message_outbox, which School A can read:
--
--     to_name : Haji Abdul Rehman VICTIMHEAD
--     to_phone: 0300-9998887
--     text    : "Assalam-o-Alaikum Haji Abdul Rehman VICTIMHEAD. A balance of
--                Rs 7,777 is outstanding for Fatima Rehman VICTIMCHILD. ..."
--
-- Another school's family head name, their phone number, their child's name, and
-- their exact debt. Enumerable one uuid at a time, and it lands in a table the
-- attacker is entitled to read, so nothing looks wrong afterwards.
--
-- WHY TWO CI GUARDS BOTH MISSED IT
--
-- Worth stating precisely, because the answer is what the new guard is built on.
--
--   * check-definer-queries.py hunts a DIFFERENT shape on purpose: inequality
--     comparisons between two table columns. That is the fn_rollover bug, where
--     "the next class up" was chosen without a school filter and a school's
--     year-end rollover promoted its children into another school's classroom.
--     Its own header says it is deliberately narrow, because a broad version
--     flagged 65 functions and was wrong about nearly all of them.
--
--   * dashboard.sql assertion 20 checks only that a definer function MENTIONS
--     scoping SOMEWHERE in its body. fn_queue_message mentions
--     current_school_id() twice — for the template lookup and for the school's
--     name — so it passed with flying colours while the families lookup sat
--     wide open. One correct mention exempted three incorrect queries. Exactly
--     the failure that made check-definer-queries.py necessary in the first
--     place, in a shape it does not cover.
--
-- Neither guard looks at the shape above. supabase/check-definer-idor.py now
-- does, judging it per QUERY rather than per function, so the next one fails CI
-- instead of shipping. It also fails if any fn__ helper becomes callable by
-- `authenticated` again, which is how defect 2 was reachable at all.
--
-- Note what is NOT wrong here, since it shows the standard exists:
-- fn_queue_enquiry_message, written later for the same job, scopes every single
-- lookup by `school_id = v_school`. fn_queue_message dates from 0034 and was
-- simply never brought up to the standard the rest of the schema holds to.
-- These were outliers, not a convention.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. fn_queue_message, scoped
--
-- Every lookup now carries the school. Kept as explicit `school_id = v_school`
-- predicates rather than assert_own calls, because this function's contract is
-- to return NULL and let the triggering action succeed — a school that has
-- switched a message off still gets its payment recorded. assert_own RAISES,
-- which would turn "we did not send a WhatsApp" into "your payment failed".
-- The same reason fn_queue_enquiry_message returns null rather than raising.
-- ---------------------------------------------------------------------------
create or replace function public.fn_queue_message(
  p_template_key text,
  p_family_id uuid,
  p_vars jsonb default '{}'::jsonb,
  p_payment_id uuid default null,
  p_student_id uuid default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_t record; v_f record; v_id uuid; v_vars jsonb; v_kids text;
  v_school uuid := public.current_school_id();
begin
  -- No school context, no message. Reached when a service-role job calls this
  -- with no session; queuing a message to a family we cannot attribute is worse
  -- than queuing none.
  if v_school is null then return null; end if;

  select * into v_t from public.message_templates
  where school_id = v_school and template_key = p_template_key;
  -- Not an error. A school that has switched this message off gets no message,
  -- and the action that triggered it still succeeds.
  if not found or not v_t.enabled then return null; end if;

  -- THE LEAK. Was `where id = p_family_id` with no school filter, inside a
  -- SECURITY DEFINER function where RLS does not apply — so any signed-in user
  -- at any school could name any family in the database.
  select * into v_f from public.families
  where id = p_family_id and school_id = v_school;
  if not found then return null; end if;

  -- Same fix, same reason: this is where the victim child's NAME came from.
  select string_agg(s.full_name, ', ' order by s.full_name) into v_kids
  from public.students s
  where s.family_id = p_family_id and s.school_id = v_school
    and s.deleted_at is null;

  -- The two optional foreign keys were written into the outbox row without ever
  -- being checked. enforce_school_id stamps the ROW's school_id, so the row
  -- looked native to the caller's school while pointing at another school's
  -- payment or pupil — and the portal and receipt screens join through them.
  -- Silently dropped rather than raised, for the same reason as above: a
  -- mis-supplied reference must not fail the payment that triggered the message.
  if p_payment_id is not null and not exists (
       select 1 from public.payments where id = p_payment_id and school_id = v_school) then
    p_payment_id := null;
  end if;
  if p_student_id is not null and not exists (
       select 1 from public.students where id = p_student_id and school_id = v_school) then
    p_student_id := null;
  end if;

  v_vars := jsonb_build_object(
    'parent',   coalesce(v_f.head_name, 'Parent'),
    'children', coalesce(v_kids, 'your child'),
    'school',   coalesce((select name from public.school_settings
                          where school_id = v_school), 'the school'),
    'date',     to_char(current_date, 'DD Mon YYYY'),
    'balance',  trim(to_char(public.family_outstanding(p_family_id), 'FM999,999,990'))
  ) || coalesce(p_vars, '{}'::jsonb);

  insert into public.message_outbox (
    template_key, to_name, to_phone, family_id, student_id, payment_id, rendered_text)
  values (
    p_template_key, v_f.head_name,
    coalesce(nullif(btrim(coalesce(v_f.whatsapp, '')), ''), v_f.phone),
    p_family_id, p_student_id, p_payment_id,
    public.fn__render_template(v_t.body, v_vars))
  returning id into v_id;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Take it off the browser's reach entirely
--
-- Defence in depth, and it costs nothing: the app never calls this function.
-- The only RPC in web/src is fn_queue_class_reminders (db.ts:3949); the other
-- two callers are fn__queue_payment_receipt and fn_queue_enquiry_message. All
-- three are SECURITY DEFINER, so they invoke this one as the definer and are
-- unaffected by the revoke.
--
-- check-reachable.sh still counts it as reachable — "another function's body"
-- is one of the things it accepts — so this does not make it look like dead
-- weight.
--
-- The scoping above is the fix. This is the second lock: if a future edit
-- reintroduces an unscoped lookup, a browser session cannot get at it directly.
-- ---------------------------------------------------------------------------
revoke execute on function
  public.fn_queue_message(text, uuid, jsonb, uuid, uuid) from authenticated;
revoke execute on function
  public.fn_queue_message(text, uuid, jsonb, uuid, uuid) from anon;
revoke execute on function
  public.fn_queue_message(text, uuid, jsonb, uuid, uuid) from public;

-- ---------------------------------------------------------------------------
-- 3. family_outstanding: a family's balance is its own school's children
--
-- This is the function that produced the leaked Rs 7,777. It sums
-- student_balance() over `students where family_id = p_family_id` with no school
-- predicate.
--
-- It is SECURITY INVOKER, so when a school user calls it directly RLS filters
-- the students and it is safe. It is only dangerous inside a SECURITY DEFINER
-- caller, where RLS is off — and its callers must therefore be trusted to have
-- scoped the family id. fn_queue_message was not, which is how the figure got
-- out. The other four callers do scope (fn_family_sheet, fn_record_family_payment
-- via assert_own; fn_portal_child_fees via fn__assert_my_child, which checks
-- family AND school; fn_find_family via current_school_id).
--
-- Relying on every future caller remembering is the arrangement that just
-- failed. Joining families and requiring the child to be in the family's own
-- school makes the function correct on its own terms: a pupil in a different
-- school than their family is not a real state, so this changes no legitimate
-- answer and removes the hazard for every caller at once.
-- ---------------------------------------------------------------------------
create or replace function public.family_outstanding(p_family_id uuid)
returns numeric language sql stable set search_path = public as $$
  select coalesce((
    select sum(public.student_balance(s.id))
    from public.students s
    join public.families f on f.id = s.family_id
    where s.family_id = p_family_id
      and s.school_id = f.school_id
  ), 0) - public.family_credit(p_family_id);
$$;

-- ---------------------------------------------------------------------------
-- 4. fn__apply_discount_lines — one school could edit another school's fees
--
-- THE SECOND DEFECT, and the more serious one, because it is a WRITE.
--
-- The function is SECURITY DEFINER, so RLS does not apply, and it did two
-- unscoped things with caller-supplied ids:
--
--     select * from public.discounts d
--     where d.enrollment_id = p_enrollment_id and d.status = 'approved'
--     ...
--     insert into public.invoice_lines(invoice_id, ...) values (p_invoice_id, ...)
--
-- Neither the enrolment nor the invoice was checked against the caller's school.
-- And despite the fn__ prefix, which in this schema means "internal, revoked
-- from the browser", 0021:286 granted EXECUTE on it to `authenticated`.
--
-- Proven: School A's owner called
--     fn__apply_discount_lines(<School B's invoice>, <School B's enrolment>, 5000)
-- and got
--     line: Tuition Fee       | amount=5000 | discount=f | school_id is ATTACKER's: f
--     line: Discount: sibling | amount=1000 | discount=t | school_id is ATTACKER's: t
--     VICTIM invoice net charge now: 4000.00
--
-- So a stranger reduced what another school charges a parent by Rs 1,000, and
-- the line they inserted carries THEIR school_id while sitting on the victim's
-- invoice — which means the victim's fee reports and the attacker's both now
-- disagree with the invoice a parent is holding. Repeatable per invoice.
--
-- Three fixes, because any one of them alone leaves the shape intact:
-- ---------------------------------------------------------------------------
create or replace function public.fn__apply_discount_lines(
  p_invoice_id uuid, p_enrollment_id uuid, p_tuition numeric
) returns void language plpgsql security definer set search_path = public as $$
declare
  v_drec record;
  v_room numeric := p_tuition;
  v_amt  numeric;
  v_school uuid := public.current_school_id();
begin
  -- Raised, not skipped. Silently applying no discounts would over-charge a
  -- parent, which is the failure a school notices last and trusts least. Every
  -- caller (fn_bill_student_month, fn_generate_class_invoices, and the family
  -- and leaving paths) gates on has_role first, so a null school cannot occur on
  -- any real path — this is a tripwire, not a branch.
  if v_school is null then
    raise exception 'No school context for this user' using errcode = '42501';
  end if;

  -- The invoice being written to must be this school's. Was entirely unchecked:
  -- p_invoice_id went straight into the INSERT.
  if not exists (select 1 from public.invoices
                  where id = p_invoice_id and school_id = v_school) then
    raise exception 'Invoice not found in this school' using errcode = '42501';
  end if;

  for v_drec in
    select * from public.discounts d
    where d.enrollment_id = p_enrollment_id
      and d.school_id = v_school            -- was missing: read another school's discounts
      and d.status = 'approved'
    order by d.created_at
  loop
    exit when v_room <= 0;
    v_amt := case when v_drec.is_percent then round(p_tuition * v_drec.amount / 100.0, 2) else v_drec.amount end;
    v_amt := least(v_amt, v_room);
    if v_amt > 0 then
      insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
      values (p_invoice_id, null, 'Discount: ' || v_drec.type, v_amt, true);
      v_room := v_room - v_amt;
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Restore the fn__ convention
--
-- In this schema an fn__ prefix means "internal helper, revoked from the browser
-- roles". Fourteen of the eighteen fn__ functions honour that. Four did not:
--
--   fn__apply_discount_lines       granted at 0021:286 — the write above
--   fn__default_message_templates  returns static template text
--   fn__render_template            {tag} substitution on a string
--   fn__voucher_code               a random code generator
--
-- Only the first was exploitable. The other three are revoked anyway, because a
-- convention with four exceptions is not a convention — it is a thing nobody can
-- rely on when reading the next function. Confirmed first that none of the four
-- is called from web/src or supabase/functions: the single hit for
-- fn__render_template is a COMMENT in db.ts:3848 describing it, not a call.
--
-- Their real callers are all SECURITY DEFINER functions, which invoke them as
-- the definer, so the revoke changes nothing about how the product works.
-- check-reachable.sh still counts them as reachable — "another function's body"
-- is one of the things it accepts — so this does not make them look like dead
-- weight. supabase/check-definer-idor.py now fails CI if any fn__ function is
-- callable by `authenticated` again.
-- ---------------------------------------------------------------------------
revoke all on function public.fn__apply_discount_lines(uuid, uuid, numeric)
  from public, anon, authenticated;
revoke all on function public.fn__default_message_templates()
  from public, anon, authenticated;
revoke all on function public.fn__render_template(text, jsonb)
  from public, anon, authenticated;
revoke all on function public.fn__voucher_code()
  from public, anon, authenticated;
