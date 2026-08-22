-- =============================================================================
-- Global search and birthdays.
--
-- The rules this file defends:
--
--  1. A PHONE NUMBER MATCHES HOWEVER IT WAS TYPED. Numbers are entered as
--     0300-111 2233, 03001112233, +92 300 111 2233 — every combination. A
--     search that only matches the stored formatting is a search nobody trusts,
--     so both sides are reduced to digits.
--  2. AN EXACT IDENTIFIER MATCH COMES FIRST. This is not cosmetic: `exact` is
--     built from comparisons against nullable columns, so it can be NULL, and
--     `order by exact desc` puts NULLs FIRST in Postgres. Without coalescing,
--     typing a GR number would sort the right answer BELOW the fuzzy ones.
--  3. A WILDCARD MATCHES NOTHING. Searching "%" must not return the school.
--  4. IT IS ROLE-AWARE, NOT ALL-OR-NOTHING. A class teacher may find a pupil
--     and must not find the family ledger or the receipt book. Refusing them
--     the whole search would be as wrong as showing them everything.
--  5. A BIRTHDAY ALREADY PAST THIS YEAR ROLLS FORWARD, so days_away is never
--     negative and a January birthday is not "355 days ago".
--  6. 29 FEBRUARY DOES NOT THROW in a non-leap year.
--  7. Nothing crosses a school boundary.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/search_birthdays.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if p_cond then raise notice 'PASS  %', p_label;
  else raise exception 'FAIL  %', p_label; end if;
end;
$$;

create or replace function pg_temp.be(p_name text) returns void language sql as $$
  select set_config('test.uid',
    (select id::text from public.profiles where full_name = p_name), false);
$$;

create or replace function pg_temp.kinds(p_term text) returns text[] language sql as $$
  select coalesce(array_agg(distinct kind order by kind), '{}')
  from public.fn_global_search(p_term, 100)
$$;

-- --- Fixture -----------------------------------------------------------------
-- One family with a child, a sibling, a member of staff, a challan, a receipt
-- and an enquiry, so every branch of the union has something to find. Phone
-- numbers are stored WITH separators, and searched for without, on purpose.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa uuid := '00000000-0000-0000-0000-0000000c0de1';
  v_tc uuid := '00000000-0000-0000-0000-0000000c0de2';
  v_pa uuid := '00000000-0000-0000-0000-0000000c0de3';
  v_ob uuid := '00000000-0000-0000-0000-0000000c0de4';
  v_sess uuid; v_cl uuid; v_head uuid; v_stu uuid;
  v_sess_b uuid; v_cl_b uuid;
begin
  insert into public.schools (name) values ('Srch A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);
  insert into public.schools (name) values ('Srch B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'growth', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_oa,'sa@srch.test'), (v_tc,'st@srch.test'),
    (v_pa,'sp@srch.test'), (v_ob,'sb@srch.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_oa, 'Srch Owner',   'owner',         v_a),
    (v_tc, 'Srch Teacher', 'class_teacher', v_a),
    (v_pa, 'Srch Parent',  'parent',        v_a),
    (v_ob, 'Srch Other',   'owner',         v_b)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role      = excluded.role,
                                   full_name = excluded.full_name,
                                   active    = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_oa::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_a) returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_a;
  insert into public.classes (name, level_order, school_id)
    values ('Class 6', 6, v_a) returning id into v_cl;
  insert into public.fee_heads (name, type, is_recurring, sort_order, school_id)
    values ('Tuition','monthly',true,10,v_a) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_cl, v_head, 2500, v_a);

  -- Phone stored WITH separators; the tests search without them.
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Bilal Ahmed','father_name','Ahmed Ali','father_cnic','35201-7000001-1',
    'phone','0300-111 2233','b_form','12345-6789012-3',
    'dob',(current_date - interval '12 years')::date,
    'session_id',v_sess,'class_id',v_cl,'roll_no','7','links','[]'::jsonb));
  -- Same father CNIC, so 0036's family linkage puts them together.
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Zainab Ahmed','father_name','Ahmed Ali','father_cnic','35201-7000001-1',
    'dob',(current_date + interval '3 days' - interval '9 years')::date,
    'session_id',v_sess,'class_id',v_cl,'roll_no','8','links','[]'::jsonb));
  -- A birthday that has already gone this year.
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Past Birthday','father_name','Someone Else','father_cnic','35201-7000009-9',
    'dob',(current_date - interval '30 days' - interval '10 years')::date,
    'session_id',v_sess,'class_id',v_cl,'roll_no','9','links','[]'::jsonb));
  -- 29 February, which has no make_date in a non-leap year.
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Leap Child','father_name','Leap Father','father_cnic','35201-7000008-8',
    'dob','2016-02-29',
    'session_id',v_sess,'class_id',v_cl,'roll_no','10','links','[]'::jsonb));

  insert into public.staff (full_name, designation, employee_no, mobile, cnic, dob, school_id)
    values ('Farhan Teacher','Senior Teacher','EMP-42','0321-999 8877',
            '35201-5000001-1', (current_date - interval '35 years')::date, v_a);

  select id into v_stu from public.students where full_name = 'Bilal Ahmed';
  perform public.fn_generate_class_invoices(v_sess, v_cl,
    date_trunc('month', current_date)::date, current_date + 7);
  perform public.fn_record_payment(v_stu, 1000, 'cash', 'part payment', false);
  perform public.fn_add_enquiry(jsonb_build_object(
    'child_name','Zara Bilal','father_name','Ahmed Ali','phone','03004445566'));

  -- School B, with a deliberately similar name so a leak would be obvious.
  perform set_config('test.uid', v_ob::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_b) returning id into v_sess_b;
  update public.school_settings set current_session_id = v_sess_b where school_id = v_b;
  insert into public.classes (name, level_order, school_id)
    values ('B Six', 6, v_b) returning id into v_cl_b;
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Bilal Imposter','father_name','Ahmed Ali','father_cnic','35201-8000001-1',
    'session_id',v_sess_b,'class_id',v_cl_b,'roll_no','1','links','[]'::jsonb));

  perform set_config('test.uid', v_oa::text, false);
end;
$seed$;

-- =============================================================================
-- 1. The floor, and the wildcards
-- =============================================================================
do $$
begin
  perform pg_temp.ok((select count(*) from public.fn_global_search('B')) = 0,
    '1  one character returns nothing — it would match most of the school');
  perform pg_temp.ok((select count(*) from public.fn_global_search('')) = 0,
    '2  an empty term returns nothing rather than everything');
  perform pg_temp.ok((select count(*) from public.fn_global_search('%')) = 0,
    '3  a "%" wildcard matches nothing (0041''s escaping bug does not recur)');
  perform pg_temp.ok((select count(*) from public.fn_global_search('_')) = 0,
    '4  and neither does "_"');
  perform pg_temp.ok((select count(*) from public.fn_global_search('%%')) = 0,
    '5  nor a two-character wildcard, which clears the length floor');
end $$;

-- =============================================================================
-- 2. Finding a child, the several ways a clerk actually types it
-- =============================================================================
do $$
begin
  perform pg_temp.ok('student' = any(pg_temp.kinds('Bilal')),
    '6  by first name');
  perform pg_temp.ok(
    exists (select 1 from public.fn_global_search('Ahmed Ali')
             where kind = 'student' and title = 'Bilal Ahmed'),
    '7  by the FATHER''s name — "I am Bilal''s father" is how the call starts');
  perform pg_temp.ok(
    exists (select 1 from public.fn_global_search('0001') where kind = 'student'),
    '8  by GR number');
  perform pg_temp.ok(
    exists (select 1 from public.fn_global_search('12345-6789012-3')
             where kind = 'student'),
    '9  by B-form number');
end $$;

-- THE PRACTICAL ONE. Stored as "0300-111 2233"; a clerk types digits.
do $$
begin
  perform pg_temp.ok(
    exists (select 1 from public.fn_global_search('03001112233')
             where kind = 'student' and title = 'Bilal Ahmed'),
    '10 a phone typed WITHOUT separators finds one stored WITH them');
  perform pg_temp.ok(
    exists (select 1 from public.fn_global_search('0300-111-2233')
             where kind = 'student'),
    '11 ...and a different separator style finds it too');
  perform pg_temp.ok(
    exists (select 1 from public.fn_global_search('1112233') where kind = 'student'),
    '12 a partial number finds it, which is what a half-remembered digit is for');
end $$;

-- =============================================================================
-- 3. Exact matches first — the NULL-ordering trap
-- =============================================================================
do $$
declare v_first record;
begin
  -- `exact` is built from comparisons against nullable columns (b_form is
  -- usually null), so it can be NULL — and `order by exact desc` puts NULLs
  -- FIRST in Postgres. Uncoalesced, the right answer sorts below the noise.
  select * into v_first from public.fn_global_search('0001') limit 1;
  perform pg_temp.ok(v_first.exact,
    '13 a GR-number search puts the exact match FIRST, not behind fuzzy hits');

  perform pg_temp.ok(
    (select bool_and(exact is not null) from public.fn_global_search('Ahmed')),
    '14 `exact` is never NULL, which is what makes that ordering reliable');
end $$;

-- =============================================================================
-- 4. Challans, receipts, families, enquiries
-- =============================================================================
do $$
declare v_code text; v_rcpt bigint;
begin
  select voucher_code into v_code from public.invoices
   where school_id = public.current_school_id() and voucher_code is not null limit 1;
  perform pg_temp.ok(
    exists (select 1 from public.fn_global_search(v_code) where kind = 'challan'),
    '15 a printed challan is found by the code on the slip');
  perform pg_temp.ok(
    exists (select 1 from public.fn_global_search(lower(v_code)) where kind = 'challan'),
    '16 ...case-insensitively, because nobody types it in capitals');
  perform pg_temp.ok(
    not exists (select 1 from public.fn_global_search(substr(v_code, 1, 4))
                 where kind = 'challan'),
    '17 a PARTIAL voucher code matches no challan — it would bury the real answers');

  select receipt_no into v_rcpt from public.payments
   where school_id = public.current_school_id() order by receipt_no limit 1;
  perform pg_temp.ok(
    exists (select 1 from public.fn_global_search(v_rcpt::text) where kind = 'receipt'),
    '18 a receipt is found by its number');

  perform pg_temp.ok(
    exists (select 1 from public.fn_global_search('Ahmed Ali') where kind = 'family'),
    '19 the family is found, with both children named in the subtitle');
  perform pg_temp.ok(
    (select subtitle from public.fn_global_search('Ahmed Ali') where kind = 'family')
      like '%Bilal%Zainab%',
    '20 ...so a clerk can see whose family it is before opening it');

  perform pg_temp.ok(
    exists (select 1 from public.fn_global_search('Zara') where kind = 'enquiry'),
    '21 an admission enquiry is searchable alongside real students');
end $$;

-- Every result says where it lives, or the UI cannot navigate to it.
do $$
begin
  perform pg_temp.ok(
    (select bool_and(route is not null and route like '/%')
     from public.fn_global_search('Ahmed', 100)),
    '22 every hit carries a route, so nothing is found but unreachable');
end $$;

-- =============================================================================
-- 5. Role-aware, not all-or-nothing
-- =============================================================================
do $$
declare v_kinds text[];
begin
  perform pg_temp.be('Srch Teacher');
  v_kinds := pg_temp.kinds('Ahmed Ali');
  perform pg_temp.ok('student' = any(v_kinds),
    '23 a class teacher CAN find a pupil — refusing them the search would be wrong');
  perform pg_temp.ok(not ('family' = any(v_kinds)),
    '24 ...but not the family ledger');
  perform pg_temp.ok(not ('staff' = any(v_kinds)),
    '25 ...nor the staff register');
  perform pg_temp.ok(not ('receipt' = any(v_kinds)) and not ('challan' = any(v_kinds)),
    '26 ...nor the receipt book');

  perform pg_temp.be('Srch Owner');
  v_kinds := pg_temp.kinds('Ahmed Ali');
  perform pg_temp.ok('family' = any(v_kinds) and 'student' = any(v_kinds),
    '27 the owner sees the kinds the teacher does not');

  perform pg_temp.be('Srch Parent');
  begin
    perform public.fn_global_search('Bilal');
    raise exception 'FAIL  28 a parent searched the school';
  exception when insufficient_privilege then
    raise notice 'PASS  28 a parent cannot use the staff search at all';
  end;
  perform pg_temp.be('Srch Owner');
end $$;

-- =============================================================================
-- 6. Tenant isolation
-- =============================================================================
do $$
begin
  perform pg_temp.ok(
    not exists (select 1 from public.fn_global_search('Imposter')),
    '29 school B''s pupil is invisible to school A, despite the shared father name');
  perform pg_temp.ok(
    (select count(*) from public.fn_global_search('Bilal') where kind = 'student') = 1,
    '30 searching a name both schools have returns only this school''s child');

  perform pg_temp.be('Srch Other');
  perform pg_temp.ok(
    not exists (select 1 from public.fn_global_search('Zainab')),
    '31 and the reverse: school A''s pupils are invisible to school B');
  perform pg_temp.be('Srch Owner');
end $$;

-- The limit is honoured and clamped.
do $$
begin
  perform pg_temp.ok((select count(*) from public.fn_global_search('Ahmed', 1)) = 1,
    '32 the limit is honoured');
  perform pg_temp.ok((select count(*) from public.fn_global_search('Ahmed', 0)) >= 1,
    '33 a nonsense limit of 0 is clamped up rather than returning nothing');
end $$;

-- =============================================================================
-- 7. Birthdays
-- =============================================================================
do $$
declare r record;
begin
  perform pg_temp.ok(
    (select count(*) from public.fn_birthdays(0)) >= 2,
    '34 today''s birthdays include both the child and the member of staff');

  select * into r from public.fn_birthdays(0) where full_name = 'Bilal Ahmed';
  perform pg_temp.ok(r.days_away = 0 and r.turning = 12,
    '35 with the age they are turning, so nobody has to do the arithmetic');
  perform pg_temp.ok(r.class_name = 'Class 6',
    '36 and the class, so the card can be sent to the right room');

  perform pg_temp.ok(
    exists (select 1 from public.fn_birthdays(7)
             where full_name = 'Zainab Ahmed' and days_away = 3),
    '37 a birthday three days out appears in the seven-day window');
  perform pg_temp.ok(
    not exists (select 1 from public.fn_birthdays(0) where full_name = 'Zainab Ahmed'),
    '38 ...and not in today''s');
end $$;

-- A birthday already gone this year must roll FORWARD, not report a negative.
do $$
declare r record;
begin
  select * into r from public.fn_birthdays(366) where full_name = 'Past Birthday';
  perform pg_temp.ok(r.days_away > 300,
    '39 a birthday a month ago is ~11 months away, not negative');
  perform pg_temp.ok(r.birthday > current_date,
    '40 ...and the date shown is the NEXT one, not the one that passed');
  perform pg_temp.ok(
    (select bool_and(days_away >= 0) from public.fn_birthdays(366)),
    '41 no birthday is ever reported as negative days away');
end $$;

-- 29 February has no make_date in a non-leap year. It must not throw.
do $$
begin
  perform pg_temp.ok(
    exists (select 1 from public.fn_birthdays(366) where full_name = 'Leap Child'),
    '42 a 29 February birthday resolves rather than raising');
end $$;

-- Staff are personnel data. A class teacher sees the children, not the staff.
do $$
begin
  perform pg_temp.be('Srch Teacher');
  perform pg_temp.ok(
    not exists (select 1 from public.fn_birthdays(366) where kind = 'staff'),
    '43 a class teacher sees pupils'' birthdays but not colleagues''');
  perform pg_temp.ok(
    exists (select 1 from public.fn_birthdays(366) where kind = 'student'),
    '44 ...and does see the pupils');

  perform pg_temp.be('Srch Parent');
  begin
    perform public.fn_birthdays(0);
    raise exception 'FAIL  45 a parent read the birthday list';
  exception when insufficient_privilege then
    raise notice 'PASS  45 a parent cannot read the birthday list';
  end;
  perform pg_temp.be('Srch Owner');
end $$;

-- A struck-off child should not be wished a happy birthday.
do $$
begin
  update public.students set status = 'withdrawn' where full_name = 'Bilal Ahmed';
  perform pg_temp.ok(
    not exists (select 1 from public.fn_birthdays(366) where full_name = 'Bilal Ahmed'),
    '46 a withdrawn child drops off the birthday list');
  update public.students set status = 'active' where full_name = 'Bilal Ahmed';
end $$;

do $$
begin
  perform pg_temp.be('Srch Other');
  perform pg_temp.ok(
    not exists (select 1 from public.fn_birthdays(366)),
    '47 school B sees none of school A''s birthdays');
  perform pg_temp.be('Srch Owner');
end $$;

rollback;
