-- =============================================================================
-- One question, one number: what does this family owe, and why?
--
-- WHY THIS FILE EXISTS
--
-- Every other suite in this directory tests one function against what that
-- function is supposed to do. This one tests the application against ITSELF: it
-- seeds a single school and then asks every screen that reports money the same
-- question, on the same data, in the same transaction, and fails if any two of
-- them answer differently.
--
-- That is a different kind of test and it earned its place. Written against the
-- code as it stood, it failed on the first run with six screens giving three
-- answers:
--
--   Dashboard / balance sheet / defaulters          Rs 8,350
--   Reconciliation / unpaid challans                Rs 8,100
--   Dues by fee head                                Rs 8,062.50
--
-- Each function was defensible read alone. Read together they were a product
-- that could not tell a school what it was owed. 0098 is the fix; this is what
-- stops it coming back, because the next person to add a money report will find
-- out here rather than from a school.
--
-- THE FIXTURE IS DELIBERATELY AWKWARD
--
-- Four children in one family, two months billed, and every complication a real
-- fee office produces in its first term:
--
--   Awkward Ali     approved sibling discount, a late fine, a manual van charge,
--                   and a part payment
--   Plain Bilal     nothing paid, October deferred
--   Paid Up Chand   paid in full
--   Void Dawood     September challan cancelled
--
-- A fixture where every child is billed the same and pays in full proves
-- nothing: every one of the three answers above agrees on that data.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/one_number.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

-- --- Fixture ---------------------------------------------------------------
do $seed$
declare
  v_school uuid;
  v_owner  uuid := '00000000-0000-0000-0000-0000000000c1';
  v_parent uuid := '00000000-0000-0000-0000-0000000000c2';
  v_sess uuid; v_class uuid; v_sec uuid; v_head uuid;
  v_fam uuid; v_stu uuid; v_enr uuid; v_inv uuid; v_disc uuid;
  v_names text[] := array['Awkward Ali', 'Plain Bilal', 'Paid Up Chand', 'Void Dawood'];
  v_n text;
begin
  insert into public.schools (name) values ('Cross Check School') returning id into v_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'starter', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_owner,  'cc@cross.test'),
    (v_parent, 'parent@cross.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_owner,  'Cross Owner',  'owner',  v_school),
    (v_parent, 'Cross Parent', 'parent', v_school)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_owner::text, false);

  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_school) returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_school;

  insert into public.classes (name, level_order, school_id)
    values ('Class 5', 5, v_school) returning id into v_class;
  insert into public.sections (class_id, name, school_id)
    values (v_class, 'A', v_school) returning id into v_sec;

  insert into public.fee_heads (name, type, is_recurring, active, school_id)
    values ('Tuition', 'monthly', true, true, v_school) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_class, v_head, 2000, v_school);

  insert into public.families (school_id, head_name, head_cnic, phone)
    values (v_school, 'Cross Head', '35201-9999999-9', '03009999999') returning id into v_fam;
  perform public.fn_link_parent(v_parent, v_fam);

  foreach v_n in array v_names loop
    insert into public.students (full_name, status, school_id, family_id)
      values (v_n, 'active', v_school, v_fam) returning id into v_stu;
    insert into public.enrollments (student_id, session_id, class_id, section_id, status, school_id)
      values (v_stu, v_sess, v_class, v_sec, 'active', v_school) returning id into v_enr;
  end loop;

  -- The discount is approved BEFORE billing, so it reaches the challan as a
  -- discount line rather than sitting in the discounts table unapplied.
  select e.id into v_enr from public.enrollments e
    join public.students s on s.id = e.student_id
   where s.full_name = 'Awkward Ali' and s.school_id = v_school;
  v_disc := public.fn_add_discount(v_enr, 'sibling', 500, false, 'brother in Class 3');
  perform public.fn_set_discount_status(v_disc, 'approved');

  perform public.fn_generate_class_invoices(v_sess, v_class, date '2025-09-01', date '2025-09-10');
  perform public.fn_generate_class_invoices(v_sess, v_class, date '2025-10-01', date '2025-10-10');

  select id into v_stu from public.students
   where full_name = 'Awkward Ali' and school_id = v_school;
  select i.id into v_inv from public.invoices i
   where i.student_id = v_stu and i.period_month = date '2025-09-01';
  perform public.fn_apply_fine(v_inv, 100, 'Ten days late');
  perform public.fn_add_adjustment(v_stu, 250, 'Van fare, September');
  perform public.fn_record_payment(v_stu, 1000, 'cash', 'part payment');

  select id into v_stu from public.students
   where full_name = 'Paid Up Chand' and school_id = v_school;
  perform public.fn_record_payment(v_stu, 4000, 'cash', 'both months');

  select id into v_stu from public.students
   where full_name = 'Void Dawood' and school_id = v_school;
  select i.id into v_inv from public.invoices i
   where i.student_id = v_stu and i.period_month = date '2025-09-01';
  perform public.fn_void_invoice(v_inv, 'billed the wrong child');

  select id into v_stu from public.students
   where full_name = 'Plain Bilal' and school_id = v_school;
  select i.id into v_inv from public.invoices i
   where i.student_id = v_stu and i.period_month = date '2025-10-01';
  perform public.fn_defer_invoice(v_inv, current_date + 30, 'father is abroad until November');

  raise notice 'fixture ok';
end $seed$;

-- =============================================================================
-- 0. Every figure this suite reads is actually there
--
-- THIS BLOCK EXISTS BECAUSE THE SUITE PASSED A REGRESSION IT WAS WRITTEN TO
-- CATCH. Reverting fn_dashboard_summary to its pre-0099 form and re-running
-- reported all fourteen checks green. The old function simply does not return
-- `students_without_a_class`; `->> 'students_without_a_class'` on a missing key
-- is NULL, `NULL::int` is NULL, every comparison against it is NULL, and
-- `if NULL then raise` does nothing at all.
--
-- So a whole assertion evaluated to "no opinion" and printed "ok". That is the
-- worst failure a test can have -- worse than being absent, because it is
-- counted. Every key the suite goes on to read is therefore proved to exist
-- first, and a renamed or dropped field fails HERE, loudly, instead of turning
-- a later check into a no-op.
-- =============================================================================
do $t$
declare
  v_sess uuid; v_stu uuid; j jsonb; k text; v_missing text := '';
  v_dash_keys  text[] := array['active_students', 'students_without_a_class',
                               'new_admissions_month', 'attendance', 'finance_visible',
                               'collected_today', 'collected_month', 'outstanding',
                               'defaulters', 'session_set'];
  v_recon_keys text[] := array['expected', 'collected', 'outstanding', 'by_class', 'bridge'];
  v_bridge_keys text[] := array['on_challans_this_session', 'charges_keyed_by_hand',
                                'arrears_from_earlier_sessions', 'student_outstanding',
                                'owed_by_children_no_longer_on_the_roll'];
  v_heads_keys text[] := array['heads', 'total_charged', 'total_collected', 'total_outstanding'];
  v_sheet_keys text[] := array['receivable', 'students_owing'];
  v_fees_keys  text[] := array['balance', 'invoices', 'receipts', 'adjustments',
                               'charges_not_on_a_challan', 'family_outstanding', 'family_credit'];
begin
  select id into v_sess from public.academic_sessions
   where school_id = (select id from public.schools where name = 'Cross Check School');
  select id into v_stu from public.students
   where full_name = 'Awkward Ali'
     and school_id = (select id from public.schools where name = 'Cross Check School');

  j := public.fn_dashboard_summary();
  foreach k in array v_dash_keys loop
    if not (j ? k) then v_missing := v_missing || 'dashboard.' || k || ' '; end if;
  end loop;

  j := public.fn_fee_reconciliation(v_sess);
  foreach k in array v_recon_keys loop
    if not (j ? k) then v_missing := v_missing || 'reconciliation.' || k || ' '; end if;
  end loop;
  foreach k in array v_bridge_keys loop
    if not (coalesce(j -> 'bridge', '{}'::jsonb) ? k) then
      v_missing := v_missing || 'reconciliation.bridge.' || k || ' ';
    end if;
  end loop;

  j := public.fn_head_wise_dues(v_sess);
  foreach k in array v_heads_keys loop
    if not (j ? k) then v_missing := v_missing || 'head_wise.' || k || ' '; end if;
  end loop;

  j := public.fn_report_balance_sheet(current_date);
  foreach k in array v_sheet_keys loop
    if not (j ? k) then v_missing := v_missing || 'balance_sheet.' || k || ' '; end if;
  end loop;

  j := public.fn_counter_summary();
  if not (j ? 'income_today') then v_missing := v_missing || 'counter.income_today '; end if;
  j := public.fn_finance_summary(current_date, current_date);
  if not (j ? 'total_income') then v_missing := v_missing || 'finance.total_income '; end if;
  j := public.fn_profit_snapshot();
  if not (coalesce(j -> 'today', '{}'::jsonb) ? 'total_income') then
    v_missing := v_missing || 'profit.today.total_income ';
  end if;

  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000c2', false);
  j := public.fn_portal_child_fees(v_stu);
  foreach k in array v_fees_keys loop
    if not (j ? k) then v_missing := v_missing || 'portal_fees.' || k || ' '; end if;
  end loop;
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000c1', false);

  if v_missing <> '' then
    raise exception 'FAIL: the suite reads figures that are not returned: %— every check below that reads one of these would have printed ok without evaluating anything',
      v_missing;
  end if;
  raise notice '0. every figure the suite reads exists — ok';
end $t$;

-- =============================================================================
-- 1. Every office screen agrees on what one child owes
--
-- Five surfaces, five different queries, one child. The student profile, the
-- roster, the class collection sheet, the defaulters list and the certificate
-- dues gate. A school reads at least three of these in a normal week and a
-- clerk arguing with a parent will read all five.
-- =============================================================================
do $t$
declare r record; v_sess uuid; v_class uuid; v_bad text := '';
begin
  select id into v_sess from public.academic_sessions
   where school_id = (select id from public.schools where name = 'Cross Check School');
  select id into v_class from public.classes
   where school_id = (select id from public.schools where name = 'Cross Check School');

  for r in
    select s.full_name,
           public.student_balance(s.id) as canonical,
           (select l.balance from public.fn_student_list(null, null, null, false, 50, 0) l
             where l.student_id = s.id) as roster,
           (select d.total_due from public.fn_class_dues(v_sess, v_class, null, date '2025-10-01') d
             where d.student_id = s.id) as class_sheet,
           coalesce((select f.balance from public.fn_defaulters(v_sess) f
                      where f.student_id = s.id), 0) as defaulters,
           (public.fn_certificate_readiness(s.id, 'leaving') ->> 'balance')::numeric as certificate
    from public.students s
    where s.school_id = (select id from public.schools where name = 'Cross Check School')
  loop
    if r.roster is distinct from r.canonical then
      v_bad := v_bad || format('%s: roster %s vs balance %s; ', r.full_name, r.roster, r.canonical);
    end if;
    if r.class_sheet is distinct from r.canonical then
      v_bad := v_bad || format('%s: class sheet %s vs balance %s; ', r.full_name, r.class_sheet, r.canonical);
    end if;
    -- The defaulters list only carries children who owe something, so a zero
    -- balance is allowed to be absent rather than present as zero.
    if r.canonical > 0 and r.defaulters is distinct from r.canonical then
      v_bad := v_bad || format('%s: defaulters %s vs balance %s; ', r.full_name, r.defaulters, r.canonical);
    end if;
    if r.certificate is distinct from r.canonical then
      v_bad := v_bad || format('%s: certificate gate %s vs balance %s; ', r.full_name, r.certificate, r.canonical);
    end if;
  end loop;

  if v_bad <> '' then
    raise exception 'FAIL: office screens disagree on what a child owes — %', v_bad;
  end if;
  raise notice '1. five office screens agree per child — ok';
end $t$;

-- =============================================================================
-- 2. Every school-wide screen agrees on what the school is owed
--
-- This is the assertion that failed before 0098, three ways at once.
-- =============================================================================
do $t$
declare
  v_sess uuid;
  v_dash numeric; v_sheet numeric; v_defaulters numeric; v_family numeric;
  v_recon jsonb; v_heads jsonb;
begin
  select id into v_sess from public.academic_sessions
   where school_id = (select id from public.schools where name = 'Cross Check School');

  v_dash       := (public.fn_dashboard_summary() ->> 'outstanding')::numeric;
  v_sheet      := (public.fn_report_balance_sheet(current_date) ->> 'receivable')::numeric;
  select coalesce(sum(d.balance), 0) into v_defaulters from public.fn_defaulters(v_sess) d;
  v_family     := public.family_outstanding(
                    (select id from public.families where head_name = 'Cross Head'));
  v_recon      := public.fn_fee_reconciliation(v_sess);
  v_heads      := public.fn_head_wise_dues(v_sess);

  if v_sheet <> v_dash then
    raise exception 'FAIL: dashboard says % owed, the balance sheet says %', v_dash, v_sheet;
  end if;
  if v_defaulters <> v_dash then
    raise exception 'FAIL: dashboard says % owed, the defaulters list adds to %', v_dash, v_defaulters;
  end if;
  -- Every child in this fixture is in one family and on the roll, and nobody is
  -- holding credit, so the family total has to be the school total too.
  if v_family <> v_dash then
    raise exception 'FAIL: dashboard says % owed, the family sheet says %', v_dash, v_family;
  end if;

  -- Reconciliation and dues-by-head are CHALLAN basis, deliberately. What is
  -- not allowed is for them to disagree with EACH OTHER, because they are
  -- answering the same question off the same rows.
  if (v_heads ->> 'total_outstanding')::numeric <> (v_recon ->> 'outstanding')::numeric then
    raise exception 'FAIL: dues by fee head says % outstanding, reconciliation says %',
      v_heads ->> 'total_outstanding', v_recon ->> 'outstanding';
  end if;

  -- And the bridge must actually bridge. This is what makes the two bases safe
  -- to show a school on adjacent screens.
  if (v_recon -> 'bridge' ->> 'student_outstanding')::numeric <> v_dash then
    raise exception 'FAIL: the reconciliation bridge says % but the dashboard says %',
      v_recon -> 'bridge' ->> 'student_outstanding', v_dash;
  end if;
  if (v_recon -> 'bridge' ->> 'on_challans_this_session')::numeric
     + (v_recon -> 'bridge' ->> 'charges_keyed_by_hand')::numeric
     + (v_recon -> 'bridge' ->> 'arrears_from_earlier_sessions')::numeric
     <> v_dash then
    raise exception 'FAIL: the bridge does not add up: % + % + % <> %',
      v_recon -> 'bridge' ->> 'on_challans_this_session',
      v_recon -> 'bridge' ->> 'charges_keyed_by_hand',
      v_recon -> 'bridge' ->> 'arrears_from_earlier_sessions', v_dash;
  end if;

  raise notice '2. dashboard, balance sheet, defaulters and family all say % — ok', v_dash;
end $t$;

-- =============================================================================
-- 3. Dues by fee head accounts for every rupee billed and every rupee taken
--
-- The fine used to be missing from `charged` while still sitting in the
-- denominator that apportions payments, so both columns were wrong at once and
-- neither was obviously so.
--
-- The per-head split is an apportionment and carries division, so it is checked
-- to the rupee rather than the paisa. The TOTALS are not apportioned and must
-- be exact.
-- =============================================================================
do $t$
declare
  v_sess uuid; j jsonb;
  v_charge numeric; v_alloc numeric;
  v_rows_charged numeric; v_rows_collected numeric;
  v_fine numeric;
begin
  select id into v_sess from public.academic_sessions
   where school_id = (select id from public.schools where name = 'Cross Check School');
  j := public.fn_head_wise_dues(v_sess);

  select coalesce(sum(b.charge), 0), coalesce(sum(b.allocated), 0) into v_charge, v_alloc
  from public.invoice_balances b
  join public.invoices i on i.id = b.invoice_id
  where i.session_id = v_sess;

  if (j ->> 'total_charged')::numeric <> v_charge then
    raise exception 'FAIL: dues by head total charged % but the challans say %',
      j ->> 'total_charged', v_charge;
  end if;
  if (j ->> 'total_collected')::numeric <> v_alloc then
    raise exception 'FAIL: dues by head total collected % but the receipts say %',
      j ->> 'total_collected', v_alloc;
  end if;

  select coalesce(sum((h ->> 'charged')::numeric), 0),
         coalesce(sum((h ->> 'collected')::numeric), 0)
    into v_rows_charged, v_rows_collected
  from jsonb_array_elements(j -> 'heads') h;

  if v_rows_charged <> v_charge then
    raise exception 'FAIL: the fee-head rows charge % but the challans charge % — a charge is in no row',
      v_rows_charged, v_charge;
  end if;
  if abs(v_rows_collected - v_alloc) > 1 then
    raise exception 'FAIL: the fee-head rows collect % but the receipts total % — that is not rounding',
      v_rows_collected, v_alloc;
  end if;

  -- And the fine specifically, because that is the row that did not exist.
  select coalesce(sum((h ->> 'charged')::numeric), 0) into v_fine
  from jsonb_array_elements(j -> 'heads') h where h ->> 'fee_head' = 'Late fee';
  if v_fine <> 100 then
    raise exception 'FAIL: the Rs 100 fine is reported as % under Late fee', v_fine;
  end if;

  raise notice '3. dues by fee head accounts for every rupee — ok';
end $t$;

-- =============================================================================
-- 4. The statement closes on the balance, for every child
--
-- This is the assertion that makes a manual adjustment impossible to hide: if
-- an entry moves the balance and the ledger does not list it, the running total
-- misses and this fails.
-- =============================================================================
do $t$
declare r record; v_last numeric; v_rows int; v_bad text := '';
begin
  for r in
    select s.id, s.full_name, public.student_balance(s.id) as bal
    from public.students s
    where s.school_id = (select id from public.schools where name = 'Cross Check School')
  loop
    select l.balance_after, count(*) over () into v_last, v_rows
    from public.fn_student_ledger(r.id) l
    order by l.seq desc
    limit 1;

    if r.bal = 0 and v_last is null then
      continue;  -- nothing ever happened to this child; nothing to reconcile
    end if;
    if coalesce(v_last, 0) is distinct from r.bal then
      v_bad := v_bad || format('%s: statement closes at %s, balance is %s; ',
                               r.full_name, coalesce(v_last, 0), r.bal);
    end if;
  end loop;

  if v_bad <> '' then
    raise exception 'FAIL: the fee statement does not close on the balance — %', v_bad;
  end if;
  raise notice '4. every statement closes on the balance — ok';
end $t$;

-- =============================================================================
-- 5. The statement SHOWS the manual charge, with its reason
--
-- The point of 0098. Before it, `fn_add_adjustment` was a write with no reader
-- anywhere in the product: an owner could waive a family's whole balance and
-- nothing in the application could ever say that they had.
-- =============================================================================
do $t$
declare v_stu uuid; v_found int; v_waive int;
begin
  select id into v_stu from public.students
   where full_name = 'Awkward Ali'
     and school_id = (select id from public.schools where name = 'Cross Check School');

  select count(*) into v_found from public.fn_student_ledger(v_stu) l
   where l.kind = 'adjustment' and l.particulars = 'Van fare, September' and l.debit = 250;
  if v_found <> 1 then
    raise exception 'FAIL: the Rs 250 manual charge is not on the statement (% rows matched)', v_found;
  end if;

  -- A waiver is the same mechanism with the sign flipped, and is the one that
  -- matters for fraud. Assert it lands on the statement as a credit.
  perform public.fn_add_adjustment(v_stu, -100, 'Hardship: half the fine waived');
  select count(*) into v_waive from public.fn_student_ledger(v_stu) l
   where l.kind = 'adjustment' and l.credit = 100
     and l.particulars = 'Hardship: half the fine waived';
  if v_waive <> 1 then
    raise exception 'FAIL: a waiver does not appear on the statement';
  end if;

  -- and the statement still closes after it
  if (select l.balance_after from public.fn_student_ledger(v_stu) l
       order by l.seq desc limit 1) <> public.student_balance(v_stu) then
    raise exception 'FAIL: the statement stopped closing once a waiver was added';
  end if;

  raise notice '5. manual charges and waivers appear on the statement — ok';
end $t$;

-- =============================================================================
-- 6. The parent sees the same arithmetic, off the same implementation
--
-- A parent and the office looking at one child must see one set of numbers.
-- Not similar numbers computed twice: the same rows, from fn__student_ledger,
-- with the staff name stripped.
-- =============================================================================
do $t$
declare
  v_stu uuid; v_office numeric; v_portal numeric;
  j jsonb; v_inv numeric; v_manual numeric;
  v_office_rows int; v_portal_rows int; v_named int;
begin
  select id into v_stu from public.students
   where full_name = 'Awkward Ali'
     and school_id = (select id from public.schools where name = 'Cross Check School');

  select count(*) into v_office_rows from public.fn_student_ledger(v_stu);
  select count(*) into v_named from public.fn_student_ledger(v_stu) l where l.recorded_by <> '';
  if v_named = 0 then
    raise exception 'FAIL: the office statement names nobody — an entry with no author is not an audit trail';
  end if;

  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000c2', false);

  select count(*) into v_portal_rows from public.fn_portal_child_ledger(v_stu);
  if v_portal_rows <> v_office_rows then
    raise exception 'FAIL: the parent sees % statement rows, the office sees %',
      v_portal_rows, v_office_rows;
  end if;
  if exists (select 1 from public.fn_portal_child_ledger(v_stu) l where l.recorded_by <> '') then
    raise exception 'FAIL: the parent statement names the member of staff who keyed the entry';
  end if;

  select l.balance_after into v_portal from public.fn_portal_child_ledger(v_stu) l
   order by l.seq desc limit 1;

  j := public.fn_portal_child_fees(v_stu);
  if (j ->> 'balance')::numeric <> v_portal then
    raise exception 'FAIL: the parent portal shows a balance of % above a statement closing at %',
      j ->> 'balance', v_portal;
  end if;

  -- The page must add up on its own face: challans + what is not on a challan.
  select coalesce(sum((x ->> 'outstanding')::numeric), 0) into v_inv
  from jsonb_array_elements(j -> 'invoices') x;
  v_manual := (j ->> 'charges_not_on_a_challan')::numeric;
  if v_inv + v_manual <> (j ->> 'balance')::numeric then
    raise exception 'FAIL: the parent page shows challans of %, other charges of %, and a balance of % — it does not add up',
      v_inv, v_manual, j ->> 'balance';
  end if;
  if jsonb_array_length(j -> 'adjustments') = 0 and v_manual <> 0 then
    raise exception 'FAIL: the parent is charged % that the page does not itemise', v_manual;
  end if;

  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000c1', false);

  select l.balance_after into v_office from public.fn_student_ledger(v_stu) l
   order by l.seq desc limit 1;
  if v_office <> v_portal then
    raise exception 'FAIL: the office statement closes at %, the parent statement at %',
      v_office, v_portal;
  end if;

  raise notice '6. the parent and the office read one statement — ok';
end $t$;

-- =============================================================================
-- 7. A parent reaches their own children's statement and nobody else's
--
-- fn_portal_child_ledger is new, so it needs the same proof every other portal
-- function carries. Two ways it could be wrong: another family's child, and a
-- member of staff calling the parent function.
-- =============================================================================
do $t$
declare
  v_school uuid; v_other_fam uuid; v_other uuid; v_ok boolean;
begin
  select id into v_school from public.schools where name = 'Cross Check School';
  insert into public.families (school_id, head_name) values (v_school, 'Other Head')
    returning id into v_other_fam;
  insert into public.students (full_name, status, school_id, family_id)
    values ('Someone Elses Child', 'active', v_school, v_other_fam) returning id into v_other;

  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000c2', false);
  v_ok := false;
  begin
    perform * from public.fn_portal_child_ledger(v_other);
    v_ok := true;
  exception when others then null;
  end;
  if v_ok then
    raise exception 'FAIL: a parent read the fee statement of a child in another family';
  end if;

  -- and the office function is not open to a parent either
  v_ok := false;
  begin
    perform * from public.fn_student_ledger(v_other);
    v_ok := true;
  exception when others then null;
  end;
  if v_ok then
    raise exception 'FAIL: a parent called the office fee statement';
  end if;

  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000c1', false);
  raise notice '7. the statement is scoped to the caller — ok';
end $t$;

-- =============================================================================
-- 8. The shared implementation is not reachable by a signed-in user
--
-- fn__student_ledger takes a student id and applies no permission check at all,
-- which is the whole reason the two wrappers exist. Postgres grants EXECUTE on
-- a new function to PUBLIC, and `anon` is a member of PUBLIC, so this is not
-- theoretical: it is the default until it is revoked.
-- =============================================================================
do $t$
declare v_leaks text := '';
begin
  if has_function_privilege('anon', 'public.fn__student_ledger(uuid)', 'execute') then
    v_leaks := v_leaks || 'anon ';
  end if;
  if has_function_privilege('authenticated', 'public.fn__student_ledger(uuid)', 'execute') then
    v_leaks := v_leaks || 'authenticated ';
  end if;
  if v_leaks <> '' then
    raise exception 'FAIL: fn__student_ledger is executable by: %', v_leaks;
  end if;
  raise notice '8. the ungated implementation is revoked — ok';
end $t$;

-- =============================================================================
-- 9. Money received says the same thing everywhere too
--
-- The other half of the question. A school reads "collected today" on the
-- dashboard, on the counter card, in the till report and in the finance
-- summary, and a difference between any two of them is an accusation against
-- whoever was on the counter.
-- =============================================================================
do $t$
declare
  v_dash numeric; v_finance numeric; v_till numeric; v_counter numeric; v_profit numeric;
begin
  v_dash    := (public.fn_dashboard_summary() ->> 'collected_today')::numeric;
  v_finance := (public.fn_finance_summary(current_date, current_date) ->> 'total_income')::numeric;
  select coalesce(sum(t.all_taken), 0) into v_till
    from public.fn_till_report(current_date, current_date) t;
  v_counter := (public.fn_counter_summary() ->> 'income_today')::numeric;
  v_profit  := (public.fn_profit_snapshot() -> 'today' ->> 'total_income')::numeric;

  if v_finance <> v_dash then
    raise exception 'FAIL: dashboard collected % today, the finance summary says %', v_dash, v_finance;
  end if;
  if v_counter <> v_dash then
    raise exception 'FAIL: dashboard collected % today, the counter card says %', v_dash, v_counter;
  end if;
  if v_profit <> v_dash then
    raise exception 'FAIL: dashboard collected % today, the profit snapshot says %', v_dash, v_profit;
  end if;
  if v_till <> v_dash then
    raise exception 'FAIL: dashboard collected % today, the till report says %', v_dash, v_till;
  end if;
  raise notice '9. collected today is % on every screen — ok', v_dash;
end $t$;

-- =============================================================================
-- 10. The headcount agrees with itself, and the difference is explained
--
-- "How many children are here" is answered by the dashboard tile, by the
-- Students screen and by the counter that decides whether the school may admit
-- another child. Before 0099 those were three separate rules and gave three
-- answers; two of them were wrong in opposite directions and collided on a
-- simple fixture, which is why nobody had noticed.
--
-- The tile and the plan counter must be identical -- the tile is now literally
-- the same function. The Students screen is allowed to list MORE, because a
-- child admitted an hour ago with no class yet has to appear somewhere, but
-- every extra row has to be accounted for by `students_without_a_class`.
-- =============================================================================
do $t$
declare
  v_school uuid; v_sess uuid;
  v_dash int; v_roster int; v_licence int; v_no_class int;
  v_defaulters int; v_listed int; v_named int;
  v_stu uuid;
begin
  select id into v_school from public.schools where name = 'Cross Check School';
  select id into v_sess from public.academic_sessions where school_id = v_school;

  v_dash     := (public.fn_dashboard_summary() ->> 'active_students')::int;
  v_no_class := (public.fn_dashboard_summary() ->> 'students_without_a_class')::int;
  select count(*) into v_roster from public.fn_student_list(null, null, null, false, 200, 0);
  v_licence  := public.fn_count_students(v_school);

  if v_licence <> v_dash then
    raise exception 'FAIL: the dashboard counts % children, the plan limit counts %',
      v_dash, v_licence;
  end if;
  if v_roster <> v_dash + v_no_class then
    raise exception 'FAIL: the Students screen lists % rows, the dashboard counts % and reports % without a class — % rows are unexplained',
      v_roster, v_dash, v_no_class, v_roster - v_dash - v_no_class;
  end if;

  -- and the defaulter COUNT matches the defaulter LIST
  v_defaulters := (public.fn_dashboard_summary() ->> 'defaulters')::int;
  select count(*) into v_listed from public.fn_defaulters(v_sess);
  if v_defaulters <> v_listed then
    raise exception 'FAIL: the dashboard says % children owe money, the list has % rows',
      v_defaulters, v_listed;
  end if;

  -- THE CHILD A ROLLOVER LEAVES BEHIND. Active student, no enrolment in the
  -- current session: no challan, no register, no result card, and until 0099
  -- no screen anywhere that said so.
  insert into public.students (full_name, status, school_id)
  values ('Left Out Of The Rollover', 'active', v_school) returning id into v_stu;

  if (public.fn_dashboard_summary() ->> 'active_students')::int <> v_dash then
    raise exception 'FAIL: a child with no class changed the roll count';
  end if;
  if (public.fn_dashboard_summary() ->> 'students_without_a_class')::int <> v_no_class + 1 then
    raise exception 'FAIL: a child with no class is not reported on the dashboard';
  end if;
  select count(*) into v_named from public.fn_students_without_a_class() f
   where f.student_id = v_stu;
  if v_named <> 1 then
    raise exception 'FAIL: a child with no class is counted but cannot be named';
  end if;

  -- and the accounting still holds with them in it
  select count(*) into v_roster from public.fn_student_list(null, null, null, false, 200, 0);
  if v_roster <> (public.fn_dashboard_summary() ->> 'active_students')::int
                 + (public.fn_dashboard_summary() ->> 'students_without_a_class')::int then
    raise exception 'FAIL: the Students screen and the dashboard stopped adding up';
  end if;

  delete from public.students where id = v_stu;

  -- A RECORD REMOVED IN ERROR. `students.deleted_at` is honoured by 27 places
  -- and set by none of them today, which is exactly why it is worth pinning:
  -- the day something sets it, the tile must not keep counting the child while
  -- the Students screen and the licence both stop. Set here directly because no
  -- function writes it, and the point of the check is the READERS.
  insert into public.students (full_name, status, school_id)
  values ('Removed By Mistake', 'active', v_school) returning id into v_stu;
  insert into public.enrollments (student_id, session_id, class_id, section_id, status, school_id)
  values (v_stu, v_sess,
          (select id from public.classes where school_id = v_school limit 1),
          (select id from public.sections where school_id = v_school limit 1),
          'active', v_school);
  update public.students set deleted_at = now() where id = v_stu;

  if (public.fn_dashboard_summary() ->> 'active_students')::int <> v_dash then
    raise exception 'FAIL: a removed child is still in the dashboard headcount (% vs %)',
      (public.fn_dashboard_summary() ->> 'active_students')::int, v_dash;
  end if;
  if public.fn_count_students(v_school) <> v_dash then
    raise exception 'FAIL: a removed child is still counted against the plan limit';
  end if;
  if (public.fn_dashboard_summary() ->> 'students_without_a_class')::int <> v_no_class then
    raise exception 'FAIL: a removed child is reported as needing a class';
  end if;

  delete from public.enrollments where student_id = v_stu;
  delete from public.students where id = v_stu;

  raise notice '10. one headcount, and the difference from the roster is named — ok';
end $t$;

-- =============================================================================
-- 11. A cancelled challan leaves nothing behind
--
-- 0087 introduced the first writer of `void` and audited the readers. This
-- checks the result end to end rather than function by function: the cancelled
-- September challan must be absent from the balance, from the statement, from
-- the parent's page and from every total above.
-- =============================================================================
do $t$
declare v_stu uuid; v_bal numeric; j jsonb;
begin
  select id into v_stu from public.students
   where full_name = 'Void Dawood'
     and school_id = (select id from public.schools where name = 'Cross Check School');

  v_bal := public.student_balance(v_stu);
  if v_bal <> 2000 then
    raise exception 'FAIL: one month cancelled of two at Rs 2,000 should leave 2000, balance is %', v_bal;
  end if;
  if exists (select 1 from public.fn_student_ledger(v_stu) l
              where l.particulars like '%Sep 2025%') then
    raise exception 'FAIL: a cancelled challan is still on the statement';
  end if;

  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000c2', false);
  j := public.fn_portal_child_fees(v_stu);
  if jsonb_array_length(j -> 'invoices') <> 1 then
    raise exception 'FAIL: the parent still sees the cancelled challan (% listed)',
      jsonb_array_length(j -> 'invoices');
  end if;
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000c1', false);

  raise notice '11. a cancelled challan is gone from every surface — ok';
end $t$;

-- =============================================================================
-- 12. A pending payment counts nowhere until it is verified
--
-- 0098 put a `status = 'verified'` filter into invoice_balances so the view and
-- student_balance cannot mean different things by "paid". Today the payment
-- flow never allocates a pending payment, so this asserts the property the
-- filter defends rather than merely the filter: record a bank challan, check
-- that nothing anywhere moves, verify it, check that everything moves together.
-- =============================================================================
do $t$
declare
  v_stu uuid; v_before numeric; v_after numeric; v_dash_before numeric; v_dash_after numeric;
  j jsonb; v_pay uuid;
begin
  select id into v_stu from public.students
   where full_name = 'Plain Bilal'
     and school_id = (select id from public.schools where name = 'Cross Check School');

  v_before      := public.student_balance(v_stu);
  v_dash_before := (public.fn_dashboard_summary() ->> 'outstanding')::numeric;

  j := public.fn_record_payment(v_stu, 1500, 'bank_challan', 'not cleared yet', true);
  v_pay := (j ->> 'payment_id')::uuid;

  if public.student_balance(v_stu) <> v_before then
    raise exception 'FAIL: an uncleared bank challan moved the balance from % to %',
      v_before, public.student_balance(v_stu);
  end if;
  if (public.fn_dashboard_summary() ->> 'outstanding')::numeric <> v_dash_before then
    raise exception 'FAIL: an uncleared bank challan moved the dashboard total';
  end if;
  if exists (select 1 from public.invoice_balances b
              where b.student_id = v_stu and b.allocated > 0) then
    raise exception 'FAIL: an uncleared bank challan was allocated against a challan';
  end if;
  if exists (select 1 from public.fn_student_ledger(v_stu) l where l.kind = 'payment') then
    raise exception 'FAIL: an uncleared bank challan is on the statement as a payment';
  end if;

  perform public.fn_verify_payment(v_pay);

  v_after      := public.student_balance(v_stu);
  v_dash_after := (public.fn_dashboard_summary() ->> 'outstanding')::numeric;
  if v_after <> v_before - 1500 then
    raise exception 'FAIL: clearing Rs 1,500 moved the balance from % to %', v_before, v_after;
  end if;
  if v_dash_after <> v_dash_before - 1500 then
    raise exception 'FAIL: clearing Rs 1,500 moved the dashboard by %', v_dash_before - v_dash_after;
  end if;
  if (select l.balance_after from public.fn_student_ledger(v_stu) l
       order by l.seq desc limit 1) <> v_after then
    raise exception 'FAIL: the statement did not follow the cleared payment';
  end if;

  raise notice '12. a pending payment counts nowhere, then counts everywhere — ok';
end $t$;

-- =============================================================================
-- 13. A reversal puts every screen back
--
-- The counter's undo. A receipt reversed in error must not leave one screen
-- showing the money and another not.
-- =============================================================================
do $t$
declare
  v_stu uuid; v_pay uuid; v_before numeric; v_dash_before numeric;
begin
  select id into v_stu from public.students
   where full_name = 'Paid Up Chand'
     and school_id = (select id from public.schools where name = 'Cross Check School');

  v_before      := public.student_balance(v_stu);
  v_dash_before := (public.fn_dashboard_summary() ->> 'outstanding')::numeric;

  select p.id into v_pay from public.payments p
   where p.student_id = v_stu and p.status = 'verified' and p.amount > 0
   order by p.created_at limit 1;
  perform public.fn_reverse_payment(v_pay, 'cheque bounced');

  if public.student_balance(v_stu) <> v_before + 4000 then
    raise exception 'FAIL: reversing Rs 4,000 left the balance at % (was %)',
      public.student_balance(v_stu), v_before;
  end if;
  if (public.fn_dashboard_summary() ->> 'outstanding')::numeric <> v_dash_before + 4000 then
    raise exception 'FAIL: reversing Rs 4,000 did not move the dashboard by the same amount';
  end if;
  if (select l.balance_after from public.fn_student_ledger(v_stu) l
       order by l.seq desc limit 1) <> public.student_balance(v_stu) then
    raise exception 'FAIL: the statement does not close after a reversal';
  end if;
  if not exists (select 1 from public.fn_student_ledger(v_stu) l
                  where l.particulars like 'Payment reversed%') then
    raise exception 'FAIL: a reversal is not named on the statement';
  end if;

  raise notice '13. a reversal moves every screen together — ok';
end $t$;

-- =============================================================================
-- 14. A child who leaves still owes what they owed, and it is still findable
--
-- The dashboard counts the roll, so a leaver's arrears drop off it. That is the
-- right behaviour and the wrong thing to be silent about: the money is real and
-- somebody has to chase it. The reconciliation bridge carries the line.
-- =============================================================================
do $t$
declare
  v_stu uuid; v_sess uuid; v_owed numeric; v_dash_before numeric; v_dash_after numeric; j jsonb;
begin
  select id into v_sess from public.academic_sessions
   where school_id = (select id from public.schools where name = 'Cross Check School');
  select id into v_stu from public.students
   where full_name = 'Plain Bilal'
     and school_id = (select id from public.schools where name = 'Cross Check School');

  v_owed        := public.student_balance(v_stu);
  v_dash_before := (public.fn_dashboard_summary() ->> 'outstanding')::numeric;

  update public.enrollments set status = 'left' where student_id = v_stu;

  v_dash_after := (public.fn_dashboard_summary() ->> 'outstanding')::numeric;
  if v_dash_after <> v_dash_before - v_owed then
    raise exception 'FAIL: a child leaving with % owed moved the dashboard by %',
      v_owed, v_dash_before - v_dash_after;
  end if;

  j := public.fn_fee_reconciliation(v_sess);
  if (j -> 'bridge' ->> 'owed_by_children_no_longer_on_the_roll')::numeric <= 0 then
    raise exception 'FAIL: % is owed by a child off the roll and the bridge reports %',
      v_owed, j -> 'bridge' ->> 'owed_by_children_no_longer_on_the_roll';
  end if;
  if public.student_balance(v_stu) <> v_owed then
    raise exception 'FAIL: leaving changed what the child owes';
  end if;

  raise notice '14. a leaver keeps their arrears and the bridge names them — ok';
end $t$;

rollback;
