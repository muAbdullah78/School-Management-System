-- =============================================================================
-- Family linkage: do siblings actually end up in the same family?
--
-- WHY THIS FILE EXISTS
--
-- supabase/tests/family_money.sql tests allocation, credit and conservation
-- exhaustively, and all fifteen of its assertions passed while family billing
-- was completely broken in production. It passed because it built its families
-- by hand:
--
--     insert into public.families ... returning id into v_fam;
--     insert into public.students (..., family_id) values (..., v_fam);
--
-- Nothing in the shipped application does that. Admissions go through
-- fn_admit_student, which never set family_id, so every real student got a
-- private single-child family and no payment ever spanned siblings.
--
-- So the rule for this file: NEVER insert a family or a student directly.
-- Everything here goes through fn_admit_student, the way the app does. A test
-- that constructs the state it wants to verify is testing itself.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/family_linkage.sql
-- =============================================================================

\set ON_ERROR_STOP on

-- Everything below runs inside ONE transaction that is rolled back at the end.
--
-- Not a stylistic choice. There is no way to delete a school in this schema:
-- 34 tables reference public.schools and not one of those foreign keys
-- cascades, so a fixture cannot clean up after itself and the file would only
-- work on a virgin database. Rolling back also means this suite leaves nothing
-- behind for the other suites to trip over, which is how outbox.sql previously
-- ended up picking a message belonging to a different test's school.
--
-- (That no school can ever be deleted is a real gap, not just a test problem:
-- the operator console will need it. Noted, not fixed here.)
begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

-- --- Fixture -----------------------------------------------------------------
-- Two schools, because per-school uniqueness of the father's CNIC has to be
-- proved as well as uniqueness within one school.
do $seed$
declare
  v_school uuid; v_owner uuid := '00000000-0000-0000-0000-0000000000c1';
  v_other  uuid; v_o2    uuid := '00000000-0000-0000-0000-0000000000c2';
begin
  insert into public.schools (name) values ('Linkage Test School') returning id into v_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'starter', 'active', current_date + 30);
  insert into public.schools (name) values ('Linkage Other School') returning id into v_other;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_other, 'starter', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_owner, 'c1@linkage.test'), (v_o2, 'c2@linkage.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_owner, 'Linkage Owner', 'owner', v_school),
    (v_o2,    'Other Owner',   'owner', v_other)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role      = excluded.role,
                                   full_name = excluded.full_name,
                                   active    = true;
  alter table public.profiles enable trigger user;

  -- The school_id stamping trigger refuses a row addressed to a school the
  -- caller does not belong to, so each school is seeded as its own owner.
  perform set_config('test.uid', v_owner::text, false);

  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_school);
  insert into public.classes (name, level_order, school_id)
    values ('Class 1', 1, v_school);

  perform set_config('test.uid', v_o2::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_other);
  insert into public.classes (name, level_order, school_id)
    values ('Class 1', 1, v_other);

  perform set_config('test.uid', v_owner::text, false);

  -- Tuition, so the pooling test has something to bill.
  insert into public.fee_heads (name, type, is_recurring, sort_order, school_id)
    values ('Tuition', 'monthly', true, 10, v_school);
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    select s.id, c.id, h.id, 1000, v_school
    from public.academic_sessions s, public.classes c, public.fee_heads h
    where s.school_id = v_school and c.school_id = v_school and h.school_id = v_school;
end $seed$;

-- A helper so each test reads as one admission, not fifteen lines of jsonb.
create or replace function pg_temp.admit(
  p_name text, p_father text default null, p_cnic text default null,
  p_phone text default null, p_sibling uuid default null
) returns uuid language plpgsql as $$
declare v_res jsonb; v_sess uuid; v_class uuid; v_school uuid;
begin
  -- Newest first: a database that has seen an aborted earlier run can hold
  -- more than one school of this name, and picking the wrong one fails inside
  -- assert_own with a confusing "not found in this school".
  select id into v_school from public.schools
   where name = 'Linkage Test School' order by created_at desc limit 1;
  select id into v_sess  from public.academic_sessions
   where school_id = v_school and is_current limit 1;
  select id into v_class from public.classes where school_id = v_school limit 1;

  v_res := public.fn_admit_student(jsonb_build_object(
    'full_name',   p_name,
    'father_name', p_father,
    'father_cnic', p_cnic,
    'phone',       p_phone,
    'session_id',  v_sess,
    'class_id',    v_class,
    'links', case when p_sibling is null then '[]'::jsonb
                  else jsonb_build_array(jsonb_build_object(
                         'related_student_id', p_sibling, 'relation', 'Brother')) end
  ));
  return (v_res->>'student_id')::uuid;
end;
$$;

create or replace function pg_temp.fam(p_student uuid) returns uuid language sql as
  $$ select family_id from public.students where id = $1 $$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if p_cond then raise notice 'PASS  %', p_label;
  else raise exception 'FAIL  %', p_label; end if;
end;
$$;

-- =============================================================================
-- 1-6: does admission put the right children together?
-- =============================================================================
do $t$
declare a uuid; b uuid; c uuid; d uuid; e uuid; f uuid; g uuid;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000c1', false);

  -- 1. Two brothers, same father CNIC, no checkbox ticked. THE headline case:
  --    this is what a clerk does when both parents' cards are on the desk.
  a := pg_temp.admit('LNK Ahmed',  'Muhammad Aslam', '35201-1111111-1', '0300-1111111');
  b := pg_temp.admit('LNK Bilal',  'Muhammad Aslam', '35201-1111111-1', '0300-1111111');
  perform pg_temp.ok(pg_temp.fam(a) = pg_temp.fam(b),
    '1. same father CNIC -> one family');

  -- 2. A third child, months later, CNIC only. Proves the family is found and
  --    reused rather than a second one being created alongside it.
  c := pg_temp.admit('LNK Sana', 'Muhammad Aslam', '35201-1111111-1');
  perform pg_temp.ok(pg_temp.fam(c) = pg_temp.fam(a),
    '2. later admission on the same CNIC joins the existing family');
  perform pg_temp.ok(
    (select count(*) from public.students where family_id = pg_temp.fam(a)) = 3,
    '3. all three children are in that one family');

  -- 4. No CNIC — the parent left their card at home — but the clerk ticks the
  --    sibling box and picks Ahmed. The human assertion has to be enough.
  d := pg_temp.admit('LNK Zara', 'Imran Khan', null, '0300-2222222', a);
  perform pg_temp.ok(pg_temp.fam(d) = pg_temp.fam(a),
    '4. sibling checkbox with no CNIC still joins the family');

  -- 5. Sibling box AND a CNIC that is new. The sibling wins, and the CNIC is
  --    stamped onto that family so the NEXT admission finds it without the box.
  e := pg_temp.admit('LNK Hina', 'Muhammad Aslam', '35201-9999999-9', null, a);
  perform pg_temp.ok(pg_temp.fam(e) = pg_temp.fam(a),
    '5. sibling link beats CNIC when they disagree');

  -- 6. A walk-in with nothing: no CNIC, no sibling. Must still be admitted,
  --    into a family of their own. Blocking the counter is not an option.
  f := pg_temp.admit('LNK Solo', 'Unknown Father');
  perform pg_temp.ok(pg_temp.fam(f) is not null and pg_temp.fam(f) <> pg_temp.fam(a),
    '6. no CNIC and no sibling -> own family, admission still succeeds');

  -- 7. An unrelated family with a different CNIC must stay separate. The whole
  --    migration merges aggressively, so the negative case matters.
  g := pg_temp.admit('LNK Usman', 'Rashid Butt', '35201-3333333-3', '0300-3333333');
  perform pg_temp.ok(pg_temp.fam(g) <> pg_temp.fam(a),
    '7. a different CNIC stays a different family');
end $t$;

-- =============================================================================
-- 8-9: one CNIC per family, first one wins
--
-- Test 5 admitted Hina with a sibling link AND a second, different CNIC. The
-- sibling link put her in Ahmed's family, and the question this pair settles is
-- what happened to that second CNIC.
--
-- It is NOT written over the one already on file. A family holds one CNIC (see
-- the limitation noted in 0036) and the first one recorded is the one the
-- counter has been searching on; replacing it silently would move an existing
-- family out from under the clerk. So a later admission quoting the second CNIC
-- lands in a family of its own, and the clerk merges it by hand — visible and
-- reversible, rather than a silent overwrite.
-- =============================================================================
do $t$
declare v_new uuid; v_ahmed_fam uuid;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000c1', false);
  select family_id into v_ahmed_fam from public.students where full_name = 'LNK Ahmed';

  perform pg_temp.ok(
    (select head_cnic from public.families where id = v_ahmed_fam) = '35201-1111111-1',
    '8. a family already holding a CNIC keeps it when a second one arrives');

  v_new := pg_temp.admit('LNK Late', 'Muhammad Aslam', '35201-9999999-9');
  perform pg_temp.ok(pg_temp.fam(v_new) <> v_ahmed_fam,
    '9. an admission on the unrecorded second CNIC starts its own family');

  -- ...and the repair path closes it, which is the point of having one.
  perform public.fn_student_join_family(
    v_new, (select id from public.students where full_name = 'LNK Ahmed'));
  perform pg_temp.ok(pg_temp.fam(v_new) = v_ahmed_fam,
    '10. the clerk can merge that back by hand');
end $t$;

-- =============================================================================
-- 11-16: the point of all this — does one payment cover several children?
-- =============================================================================
do $t$
declare
  v_fam uuid; v_school uuid; v_sess uuid; v_class uuid;
  v_bal_a numeric; v_credit numeric; v_out numeric; v_neg int;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000c1', false);
  -- Newest first: a database that has seen an aborted earlier run can hold
  -- more than one school of this name, and picking the wrong one fails inside
  -- assert_own with a confusing "not found in this school".
  select id into v_school from public.schools
   where name = 'Linkage Test School' order by created_at desc limit 1;
  select id into v_sess  from public.academic_sessions
   where school_id = v_school and is_current limit 1;
  select id into v_class from public.classes where school_id = v_school limit 1;
  select family_id into v_fam from public.students where full_name = 'LNK Ahmed';

  -- Bill the class for one month. Six children of this family are enrolled, at
  -- Rs 1,000 each.
  perform public.fn_generate_class_invoices(v_sess, v_class,
                                            date_trunc('month', current_date)::date,
                                            current_date + 10);

  select public.family_outstanding(v_fam) into v_out;
  perform pg_temp.ok(v_out = 6000,
    '11. the family owes the sum of ALL its children, not one child (' || v_out || ')');

  -- First, a PENDING payment — a bank transfer the school has not yet seen
  -- clear. It must change nothing. Asserted here because the last argument of
  -- fn_record_family_payment is p_pending and getting it the wrong way round is
  -- an easy mistake that would silently overstate collections.
  perform public.fn_record_family_payment(v_fam, 9999, 'bank_transfer', 'Not cleared yet', true);
  select coalesce(sum(public.student_balance(id)), 0) into v_bal_a
    from public.students where family_id = v_fam;
  perform pg_temp.ok(v_bal_a = 6000,
    '12. a pending payment does not reduce what the family owes (' || v_bal_a || ')');

  -- Now a real one, less than the total. This is the assertion the whole
  -- migration exists for: before 0036 this payment could only ever touch one
  -- child, because the other five were in families of their own.
  perform public.fn_record_family_payment(v_fam, 2500, 'cash', 'One payment, several kids', false);

  select coalesce(sum(public.student_balance(id)), 0) into v_bal_a
    from public.students where family_id = v_fam;
  perform pg_temp.ok(v_bal_a = 3500,
    '13. the payment came off the family as a whole: 6000 - 2500 = ' || v_bal_a);

  -- Every invoice here is for the same month, so which child is cleared first
  -- is a tie-break the design does not promise and this test must not assert.
  -- What it does promise is that no child is driven below zero — the overpay
  -- guard — and that the money is not double-counted.
  select count(*) into v_neg from public.students
   where family_id = v_fam and public.student_balance(id) < 0;
  perform pg_temp.ok(v_neg = 0,
    '14. no child is driven into a negative balance by a pooled payment');

  perform pg_temp.ok(
    (select count(*) from public.students where family_id = v_fam
      and public.student_balance(id) = 0) >= 2,
    '15. the payment fully cleared more than one child rather than sitting on one');

  select public.family_credit(v_fam) into v_credit;
  select public.family_outstanding(v_fam) into v_out;
  perform pg_temp.ok(v_out = v_bal_a - v_credit,
    '16. conservation holds after a pooled payment');
end $t$;

-- =============================================================================
-- 17-18: fn_find_family, the search at the counter
-- =============================================================================
do $t$
declare v_hits int; v_children int;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000c1', false);

  select count(*) into v_hits from public.fn_find_family('35201-1111111-1');
  perform pg_temp.ok(v_hits = 1, '17. the father CNIC finds exactly one family');

  select children into v_children from public.fn_find_family('35201-1111111-1') limit 1;
  perform pg_temp.ok(v_children > 1,
    '18. that family reports more than one child (' || v_children || ')');
end $t$;

-- =============================================================================
-- 19-22: the repair path, for data that arrived before 0036 or by CSV
-- =============================================================================
do $t$
declare x uuid; y uuid; v_fx uuid; v_fy uuid; v_kept uuid; v_pay_moved int;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000c1', false);

  -- Two brothers admitted the way a CSV import leaves them: no CNIC, no link,
  -- so two separate families — the exact pre-0036 state.
  x := pg_temp.admit('LNK Kamran', 'Nadeem Sheikh', null, '0300-4444444');
  y := pg_temp.admit('LNK ImranS',  'Nadeem Sheikh', null, '0300-4444444');
  v_fx := pg_temp.fam(x); v_fy := pg_temp.fam(y);
  perform pg_temp.ok(v_fx <> v_fy,
    '19. without a CNIC or a link they start apart (this is the bug''s shape)');

  -- Money against the family that is about to be absorbed, to prove the merge
  -- carries payments with it rather than orphaning them.
  perform public.fn_record_family_payment(v_fx, 500, 'cash', 'before merge', true);

  v_kept := public.fn_student_join_family(x, y);
  perform pg_temp.ok(pg_temp.fam(x) = pg_temp.fam(y),
    '20. fn_student_join_family puts them together');

  select count(*) into v_pay_moved from public.payments where family_id = v_kept and note = 'before merge';
  perform pg_temp.ok(v_pay_moved = 1,
    '21. the payment followed the merge instead of being orphaned');
  perform pg_temp.ok(not exists (select 1 from public.families where id = v_fx),
    '22. the absorbed family is gone, not left dangling');
end $t$;

-- =============================================================================
-- 23-25: fn_repair_families finds father+phone matches on its own
-- =============================================================================
do $t$
declare p uuid; q uuid; v_merged int;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000c1', false);

  p := pg_temp.admit('LNK Ali',  'Ghulam Raza', null, '0321-7777777');
  q := pg_temp.admit('LNK Hassan','Ghulam Raza', null, '0321-7777777');
  perform pg_temp.ok(pg_temp.fam(p) <> pg_temp.fam(q), '23. they start apart');

  v_merged := public.fn_repair_families();
  perform pg_temp.ok(pg_temp.fam(p) = pg_temp.fam(q),
    '24. fn_repair_families merges same father + same phone');

  -- And it must NOT have swept up the unrelated families along the way.
  perform pg_temp.ok(
    (select family_id from public.students where full_name = 'LNK Usman')
      <> (select family_id from public.students where full_name = 'LNK Ahmed'),
    '25. repair leaves unrelated families alone');
end $t$;

-- =============================================================================
-- 26-28: the guards. These are the ones that matter if I got the SQL wrong.
-- =============================================================================
do $t$
declare v_mine uuid; v_theirs uuid; v_other_school uuid; v_sess uuid; v_class uuid; v_res jsonb;
begin
  -- A student in the OTHER school, admitted as that school's owner.
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000c2', false);
  select id into v_other_school from public.schools where name = 'Linkage Other School';
  select id into v_sess  from public.academic_sessions where school_id = v_other_school and is_current;
  select id into v_class from public.classes where school_id = v_other_school limit 1;
  v_res := public.fn_admit_student(jsonb_build_object(
    'full_name', 'LNK Foreign', 'father_name', 'Foreign Father',
    'father_cnic', '35201-1111111-1',     -- deliberately the SAME cnic as school 1
    'session_id', v_sess, 'class_id', v_class, 'links', '[]'::jsonb));
  v_theirs := (v_res->>'student_id')::uuid;

  -- 20. The same CNIC in a different school is a different family. The unique
  --     index is on (school_id, head_cnic) and this proves the school_id half.
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000c1', false);
  perform pg_temp.ok(
    (select family_id from public.students where id = v_theirs)
      <> (select family_id from public.students where full_name = 'LNK Ahmed'),
    '26. the same CNIC in another school is a separate family');

  -- 21. Merging across schools must be refused. This is the whole tenant
  --     boundary for this feature.
  select family_id into v_mine from public.students where full_name = 'LNK Ahmed';
  select family_id into v_theirs from public.students where id = v_theirs;
  begin
    perform public.fn_merge_families(v_mine, v_theirs);
    raise exception 'FAIL  27. cross-school merge was ALLOWED';
  exception
    when others then
      if sqlerrm like 'FAIL%' then raise; end if;
      raise notice 'PASS  27. cross-school merge refused (%)', sqlerrm;
  end;

  -- 22. And joining a student to a foreign sibling is refused too — the same
  --     boundary reached through the friendlier function.
  begin
    perform public.fn_student_join_family(
      (select id from public.students where full_name = 'LNK Ahmed'),
      (select id from public.students where full_name = 'LNK Foreign'));
    raise exception 'FAIL  28. cross-school join was ALLOWED';
  exception
    when others then
      if sqlerrm like 'FAIL%' then raise; end if;
      raise notice 'PASS  28. cross-school join refused (%)', sqlerrm;
  end;
end $t$;

-- =============================================================================
-- 29-30: the internals stay internal
-- =============================================================================
do $t$
declare v_bad int;
begin
  -- fn__merge_two_families has no role check and fn__repair_families_for takes
  -- an arbitrary school id. Either one reachable by a signed-in user is a
  -- cross-tenant write, so the revokes are load-bearing.
  select count(*) into v_bad
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name in ('fn__merge_two_families', 'fn__repair_families_for')
    and grantee in ('anon', 'authenticated', 'PUBLIC');
  perform pg_temp.ok(v_bad = 0,
    '29. the internal merge/repair functions are not granted to app roles');

  -- The unique index is what stops two clerks creating two families for the
  -- same father on the same afternoon.
  perform pg_temp.ok(exists (
    select 1 from pg_indexes where schemaname = 'public' and indexname = 'uq_families_school_cnic'),
    '30. one family per father per school is enforced by an index');
end $t$;

do $$ begin raise notice '--- family_linkage.sql: all assertions passed'; end $$;

rollback;
