-- =============================================================================
-- Certificates — the document a family cannot enrol a child anywhere else
-- without, and the school's main lever for unpaid fees.
--
-- Demonstrated on a real database before 0061 was written. One pupil, STILL
-- ENROLLED, owing Rs 4,000. A leaving certificate was requested:
--
--   issued .................................... yes, serial 1
--   students.status afterwards ................ 'active'
--   students.left_on afterwards ............... null
--   snapshot contents ......................... name, father, class, roll. Nothing else.
--   issued a second time ...................... yes, serial 2, also looking original
--   ways to cancel one issued in error ........ none
--
-- The rules this file defends:
--
--   1. A LEAVING CERTIFICATE IS REFUSED WHILE FEES ARE OUTSTANDING, and the
--      message names the amount. It is the one lever the school has.
--   2. AN OWNER OR PRINCIPAL CAN RELEASE IT ANYWAY, with a reason, and the
--      amount and the authoriser go ON THE DOCUMENT. A gate that cannot be
--      opened gets bypassed outside the system, and then the school has neither
--      the money nor the record.
--   3. ONLY `leaving` IS GATED. A bonafide is proof of enrolment — a family
--      needs it for a bank account or a passport — and withholding that over
--      fees is punitive. Asserted for both, because a gate applied to the wrong
--      types is as wrong as no gate.
--   4. ISSUING A LEAVING CERTIFICATE RECORDS THE LEAVING, in the same
--      transaction. Otherwise the child stays on the attendance sheet and in
--      next month's billing while holding a certificate that says they left.
--   5. IT CANNOT BE ISSUED WITHOUT A LEAVING DATE. That is what stops anybody
--      issuing one by accident to see the wording — the answer to the objection
--      that printing a document should not change a pupil's status.
--   6. THE SNAPSHOT STATES WHAT AN SLC STATES: dates of attendance, date of
--      leaving, GR number, class last studied, conduct.
--   7. A SECOND COPY IS MARKED DUPLICATE, and carries the original's serial.
--   8. A CERTIFICATE CAN BE CANCELLED, by an owner or principal, with a reason,
--      once — and `certificates` itself stays append-only.
--   9. NOTHING CROSSES A SCHOOL BOUNDARY, in both directions.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/certificates.sql
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

create or replace function pg_temp.raises(p_sql text, p_needle text) returns boolean
language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return position(lower(p_needle) in lower(sqlerrm)) > 0;
end;
$$;

create or replace function pg_temp.stu(p_name text) returns uuid language sql as $$
  select id from public.students
   where school_id = public.current_school_id() and full_name = p_name
$$;

-- The frozen snapshot of the newest certificate of a type for a pupil.
create or replace function pg_temp.snap(p_name text, p_type text) returns jsonb
language sql as $$
  select c.data from public.certificates c
   join public.students s on s.id = c.student_id
  where c.school_id = public.current_school_id()
    and s.full_name = p_name and c.cert_type::text = p_type
  order by c.serial_no desc limit 1
$$;

-- --- Fixture -----------------------------------------------------------------
-- Owing Child: enrolled, owes 4,000 — every dues assertion runs on this one.
-- Clear Child: enrolled, owes nothing.
-- Both admitted on a known date, because "a bona fide student from ___ to ___"
-- is the thing the old snapshot could not state.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa uuid := '00000000-0000-0000-0000-00000000ca01';
  v_ca uuid := '00000000-0000-0000-0000-00000000ca02';
  v_ob uuid := '00000000-0000-0000-0000-00000000ca03';
  v_sess uuid; v_cl uuid; v_sec uuid; v_head uuid;
  v_owe uuid; v_clear uuid; v_e1 uuid; v_e2 uuid; v_inv uuid;
  v_sess_b uuid; v_cl_b uuid; v_stu_b uuid;
begin
  insert into public.schools (name) values ('Cert A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);
  insert into public.schools (name) values ('Cert B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'growth', 'active', current_date + 30);

  insert into auth.users (id, email) values
    (v_oa, 'oa@cert.test'), (v_ca, 'ca@cert.test'), (v_ob, 'ob@cert.test');
  insert into public.profiles (id, school_id, full_name, role, active) values
    (v_oa, v_a, 'Cert Owner A', 'owner', true),
    (v_ca, v_a, 'Cert Clerk A', 'admin_clerk', true),
    (v_ob, v_b, 'Cert Owner B', 'owner', true);

  perform set_config('test.uid', v_oa::text, false);
  insert into public.academic_sessions (school_id, name, is_current, starts_on, ends_on)
    values (v_a, '2025-26', true, '2025-04-01', '2026-03-31') returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_a;
  insert into public.classes (school_id, name, level_order) values (v_a, 'Class 5', 5)
    returning id into v_cl;
  insert into public.sections (school_id, class_id, name) values (v_a, v_cl, 'B')
    returning id into v_sec;
  insert into public.fee_heads (school_id, name, type, is_recurring)
    values (v_a, 'Tuition', 'monthly', true) returning id into v_head;

  insert into public.students (school_id, full_name, father_name, gr_no, dob,
                               gender, status, admission_date)
    values (v_a, 'Owing Child', 'Rashid Ali', 'GR-0007', '2014-06-11',
            'male', 'active', '2022-04-05')
    returning id into v_owe;
  insert into public.enrollments (school_id, student_id, session_id, class_id,
                                  section_id, roll_no, status)
    values (v_a, v_owe, v_sess, v_cl, v_sec, '7', 'active') returning id into v_e1;

  insert into public.students (school_id, full_name, father_name, gr_no, status, admission_date)
    values (v_a, 'Clear Child', 'Imran Khan', 'GR-0008', 'active', '2023-04-10')
    returning id into v_clear;
  insert into public.enrollments (school_id, student_id, session_id, class_id,
                                  section_id, roll_no, status)
    values (v_a, v_clear, v_sess, v_cl, v_sec, '8', 'active') returning id into v_e2;

  -- Owing Child is billed 4,000 and never pays.
  insert into public.invoices (school_id, student_id, enrollment_id, session_id,
                               period_month, status, due_date, issued_at)
    values (v_a, v_owe, v_e1, v_sess, date_trunc('month', current_date)::date,
            'issued', current_date, now()) returning id into v_inv;
  insert into public.invoice_lines (school_id, invoice_id, fee_head_id, description, amount)
    values (v_a, v_inv, v_head, 'Tuition', 4000);

  -- ---- School B ----
  perform set_config('test.uid', v_ob::text, false);
  insert into public.academic_sessions (school_id, name, is_current)
    values (v_b, '2025-26', true) returning id into v_sess_b;
  update public.school_settings set current_session_id = v_sess_b where school_id = v_b;
  insert into public.classes (school_id, name, level_order) values (v_b, 'Class 5', 5)
    returning id into v_cl_b;
  insert into public.students (school_id, full_name, status, admission_date)
    values (v_b, 'Other School Child', 'active', '2024-04-01') returning id into v_stu_b;
  insert into public.enrollments (school_id, student_id, session_id, class_id, roll_no, status)
    values (v_b, v_stu_b, v_sess_b, v_cl_b, '1', 'active');
end;
$seed$;

-- =============================================================================
-- 1. The dues gate
-- =============================================================================
select pg_temp.be('Cert Owner A');

select pg_temp.ok(
  (public.fn_certificate_readiness(pg_temp.stu('Owing Child'), 'leaving')->>'balance')::numeric = 4000,
  '1. readiness reports the 4,000 outstanding, so a screen can say so before the '
  || 'button is pressed');

select pg_temp.ok(
  (public.fn_certificate_readiness(pg_temp.stu('Owing Child'), 'leaving')->>'blocked_by_dues')::boolean,
  '2. and reports that a LEAVING certificate is blocked');

select pg_temp.ok(
  not (public.fn_certificate_readiness(pg_temp.stu('Owing Child'), 'bonafide')->>'blocked_by_dues')::boolean,
  '3. but a BONAFIDE is not blocked for the same pupil — it is proof of enrolment, '
  || 'needed for a bank account or a passport, and withholding it over fees is punitive');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_issue_certificate(''leaving'', %L, ''{}''::jsonb, current_date, ''Moving city'')',
           pg_temp.stu('Owing Child')),
    'owes 4000'),
  '4. THE DEFECT: issuing is refused, and the message NAMES THE AMOUNT. It used to '
  || 'be handed over freely');

select pg_temp.ok(
  (select count(*) from public.certificates) = 0,
  '5. and the refusal wrote nothing — no serial was burned on a refused certificate');

-- A bonafide for the same owing pupil goes through.
select public.fn_issue_certificate('bonafide', pg_temp.stu('Owing Child')) as bf \gset
select pg_temp.ok(
  (:'bf'::jsonb->>'serial_no')::bigint = 1,
  '6. the bonafide is issued to the same pupil despite the 4,000 — the gate is per '
  || 'type, and a gate on the wrong types is as wrong as no gate');

-- =============================================================================
-- 2. The override: allowed, restricted, and recorded ON the document
-- =============================================================================
select pg_temp.be('Cert Clerk A');
select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_issue_certificate(''leaving'', %L, ''{}''::jsonb, '
           || 'current_date, ''Moving city'', ''withdrawn'', true, ''Hardship'')',
           pg_temp.stu('Owing Child')),
    'only an owner or principal'),
  '7. a CLERK cannot release it over unpaid fees, even with a reason');

select pg_temp.be('Cert Owner A');
select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_issue_certificate(''leaving'', %L, ''{}''::jsonb, '
           || 'current_date, ''Moving city'', ''withdrawn'', true, null)',
           pg_temp.stu('Owing Child')),
    'needs a reason'),
  '8. and an owner cannot release it without a reason — the reason goes on the '
  || 'certificate, so a blank one would be a document that explains nothing');

select public.fn_issue_certificate(
  'leaving', pg_temp.stu('Owing Child'), '{"conduct": "Satisfactory"}'::jsonb,
  '2026-08-20', 'Family moving to Lahore', 'withdrawn',
  true, 'Father lost his job; principal released it') as lv \gset

select pg_temp.ok(
  (:'lv'::jsonb->>'dues_overridden')::boolean,
  '9. an owner CAN release it, and the result says the dues were overridden');

select pg_temp.ok(
  (pg_temp.snap('Owing Child', 'leaving')->>'balance_at_issue')::numeric = 4000
  and (pg_temp.snap('Owing Child', 'leaving')->>'dues_cleared')::boolean = false
  and pg_temp.snap('Owing Child', 'leaving')->>'dues_override_reason'
      = 'Father lost his job; principal released it'
  and pg_temp.snap('Owing Child', 'leaving')->>'dues_override_by' = 'Cert Owner A',
  '10. and the AMOUNT, the REASON and WHO AUTHORISED IT are frozen onto the '
  || 'certificate itself — not in a log somebody has to go and find');

-- =============================================================================
-- 3. Issuing a leaving certificate records the leaving
-- =============================================================================
select pg_temp.ok(
  (select status::text = 'withdrawn' and left_on = '2026-08-20'
     from public.students where id = pg_temp.stu('Owing Child')),
  '11. THE OTHER DEFECT: the pupil is now recorded as withdrawn, on the stated '
  || 'date. They used to stay ''active'' with no left_on — on the attendance sheet '
  || 'and in next month''s billing, while holding a certificate saying they left');

select pg_temp.ok(
  (select status::text <> 'active' from public.enrollments
    where student_id = pg_temp.stu('Owing Child')),
  '12. and the enrolment is closed too, so class strength and the register agree');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_issue_certificate(''leaving'', %L)', pg_temp.stu('Clear Child')),
    'needs the date'),
  '13. a leaving certificate CANNOT be issued without a leaving date. That is what '
  || 'stops anybody issuing one by accident to see the wording — the answer to the '
  || 'objection that printing a document should not change a pupil''s status');

-- =============================================================================
-- 4. The snapshot states what an SLC states
-- =============================================================================
select pg_temp.ok(
  pg_temp.snap('Owing Child', 'leaving')->>'attended_from' = '2022-04-05'
  and pg_temp.snap('Owing Child', 'leaving')->>'attended_to' = '2026-08-20',
  '14. "a bona fide student from 2022-04-05 to 2026-08-20" — the admission date '
  || 'was on the pupil''s record all along and was never copied onto the document');

select pg_temp.ok(
  pg_temp.snap('Owing Child', 'leaving')->>'gr_no' = 'GR-0007'
  and pg_temp.snap('Owing Child', 'leaving')->>'class_name' = 'Class 5'
  and pg_temp.snap('Owing Child', 'leaving')->>'section_name' = 'B'
  and pg_temp.snap('Owing Child', 'leaving')->>'roll_no' = '7'
  and pg_temp.snap('Owing Child', 'leaving')->>'dob' = '2014-06-11',
  '15. GR number, class last studied, section, roll and date of birth are all on it');

select pg_temp.ok(
  pg_temp.snap('Owing Child', 'leaving')->>'date_of_leaving' = '2026-08-20'
  and pg_temp.snap('Owing Child', 'leaving')->>'leaving_reason' = 'Family moving to Lahore'
  and pg_temp.snap('Owing Child', 'leaving')->>'conduct' = 'Satisfactory',
  '16. date of leaving, reason and conduct — the caller''s own data is merged over '
  || 'the snapshot, so a school can still add its own wording');

select pg_temp.ok(
  pg_temp.snap('Owing Child', 'bonafide')->>'date_of_leaving' is null
  and pg_temp.snap('Owing Child', 'bonafide')->>'attended_to' = current_date::text,
  '17. a BONAFIDE has no date of leaving and runs to today — it certifies a pupil '
  || 'who is here, not one who has gone');

-- =============================================================================
-- 5. A second copy is a duplicate
-- =============================================================================
select pg_temp.ok(
  (public.fn_certificate_readiness(pg_temp.stu('Owing Child'), 'leaving')->>'would_be_duplicate')::boolean,
  '18. readiness warns that another leaving certificate would be a duplicate');

select public.fn_issue_certificate(
  'leaving', pg_temp.stu('Owing Child'), '{}'::jsonb,
  '2026-08-20', 'Replacement for lost original', 'withdrawn',
  true, 'Original lost by the family') as dup \gset

select pg_temp.ok(
  (:'dup'::jsonb->>'is_duplicate')::boolean,
  '19. the second one is marked a DUPLICATE. Two indistinguishable originals let a '
  || 'family present one at each of two schools');

select pg_temp.ok(
  (pg_temp.snap('Owing Child', 'leaving')->>'original_serial_no')::bigint = 1,
  '20. and it carries the original''s serial number, so the two can be tied together');

select pg_temp.ok(
  (select count(*) from public.certificates where cert_type = 'leaving') = 2,
  '21. both exist on the register — a replacement is a fact, not a correction');

-- =============================================================================
-- 6. Cancelling one issued in error
-- =============================================================================
select pg_temp.be('Cert Clerk A');
select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_cancel_certificate(%L, ''Wrong child'')',
           (select id from public.certificates where cert_type = 'bonafide')),
    'only an owner or principal'),
  '22. a clerk cannot cancel a certificate — a family may already be holding it');

select pg_temp.be('Cert Owner A');
select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_cancel_certificate(%L, ''  '')',
           (select id from public.certificates where cert_type = 'bonafide')),
    'needs a reason'),
  '23. and cancelling needs a reason, because it stays on the register for ever');

select public.fn_cancel_certificate(
  (select id from public.certificates where cert_type = 'bonafide'),
  'Issued to the wrong child') as canc \gset

select pg_temp.ok(
  (:'canc'::jsonb->>'serial_no')::bigint = 1,
  '24. the bonafide is cancelled');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_cancel_certificate(%L, ''again'')',
           (select id from public.certificates where cert_type = 'bonafide')),
    'already been cancelled'),
  '25. and cannot be cancelled twice — two conflicting reasons on one register row '
  || 'would be worse than none');

select pg_temp.ok(
  (select cancelled_at is not null and cancel_reason = 'Issued to the wrong child'
     from public.fn_certificate_register(50) where cert_type = 'bonafide'),
  '26. the register SHOWS it as cancelled with the reason, rather than hiding it — '
  || 'a gap in the numbering with no explanation is worse than a cancelled row');

select pg_temp.ok(
  (select count(*) from public.certificates where cert_type = 'bonafide') = 1,
  '27. and `certificates` itself is untouched — still strictly append-only, so a '
  || 'certificate can never be edited into something it never was');

-- A cancelled certificate no longer counts as the original for duplicate purposes.
select pg_temp.ok(
  not (public.fn_certificate_readiness(pg_temp.stu('Owing Child'), 'bonafide')->>'would_be_duplicate')::boolean,
  '28. after cancellation the next bonafide is NOT a duplicate — it replaces one '
  || 'that never should have existed');

-- =============================================================================
-- 7. The register
-- =============================================================================
select pg_temp.ok(
  (select count(*) from public.fn_certificate_register(50)) = 3,
  '29. the register lists all three certificates');

select pg_temp.ok(
  (select issued_by_name from public.fn_certificate_register(50)
    where cert_type = 'leaving' and serial_no = 1) = 'Cert Owner A',
  '30. and names who issued each one');

select pg_temp.ok(
  (select balance_at_issue from public.fn_certificate_register(50)
    where cert_type = 'leaving' and serial_no = 1) = 4000,
  '31. and what was outstanding at the time — so a principal reviewing the register '
  || 'can see which releases were made over unpaid fees');

-- =============================================================================
-- 8. A clear pupil, the ordinary case
-- =============================================================================
select public.fn_issue_certificate(
  'leaving', pg_temp.stu('Clear Child'), '{"conduct": "Excellent"}'::jsonb,
  '2026-08-22', 'Completed primary') as clear \gset

select pg_temp.ok(
  not (:'clear'::jsonb->>'dues_overridden')::boolean
  and (pg_temp.snap('Clear Child', 'leaving')->>'dues_cleared')::boolean,
  '32. a pupil who owes nothing needs no override, and the certificate says the '
  || 'dues were cleared');

select pg_temp.ok(
  pg_temp.snap('Clear Child', 'leaving')->>'dues_override_reason' is null,
  '33. and carries no override text — an ordinary certificate must not look like '
  || 'a released one');

-- =============================================================================
-- 9. Nothing crosses a school boundary, in both directions
-- =============================================================================
select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_issue_certificate(''bonafide'', %L)',
           (select s.id from public.students s where s.full_name = 'Other School Child')),
    'not found in this school'),
  '34. school A cannot issue a certificate for school B''s pupil');

select pg_temp.be('Cert Owner B');

select pg_temp.ok(
  (select count(*) from public.fn_certificate_register(50)) = 0,
  '35. school B''s register is empty — it cannot see school A''s certificates');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_cancel_certificate(%L, ''mine now'')',
           (select id from public.certificates where cert_type = 'leaving' limit 1)),
    'not found in this school'),
  '36. and cannot cancel one of school A''s');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_certificate_readiness(%L, ''leaving'')',
           (select s.id from public.students s where s.full_name = 'Owing Child')),
    'not found in this school'),
  '37. nor read the readiness of school A''s pupil');

-- School B's own serial numbering starts at 1 — the counter is PER SCHOOL, so
-- both schools have a certificate number 1 and neither collides.
select public.fn_issue_certificate('bonafide',
  (select s.id from public.students s where s.full_name = 'Other School Child')) as b1 \gset

select pg_temp.ok(
  (:'b1'::jsonb->>'serial_no')::bigint = 1,
  '38. school B''s first bonafide is serial 1, not 2 — the counter is per school, '
  || 'so every school has a certificate number 1');

select pg_temp.be('Cert Owner A');
select pg_temp.ok(
  not exists (select 1 from public.fn_certificate_register(50)
               where student_name = 'Other School Child'),
  '39. and the reverse: school A''s register cannot see school B''s certificate — a '
  || 'filter scoped to whichever school was created first passes one way only');

-- =============================================================================
-- 10. The free-form `data` field cannot forge what the snapshot asserts
--
-- Found by probe, not by reading: `p_data` was merged OVER the snapshot, so
-- every field the register and the printed document rely on was whatever the
-- caller chose to send. A clerk issued a second bonafide with
--
--   {"is_duplicate": false, "dues_cleared": true, "balance_at_issue": 0,
--    "student_name": "Somebody Else", "gr_no": "GR-9999"}
--
-- and got serial 2: a legitimate serial in the school's register, printing a
-- different child's name and GR number, with no DUPLICATE stamp, stating the
-- fees as cleared while Rs 4,000 was outstanding. Nothing in the app sends
-- those keys — but "the app doesn't send it" is not a boundary, and a
-- certificate is exactly the document somebody has a motive to forge.
-- =============================================================================
select pg_temp.be('Cert Clerk A');

-- An honest original first. Owing Child's earlier bonafide was CANCELLED in
-- section 6, and a cancelled certificate correctly stops counting as an
-- original — so without this the forged call would not be a duplicate at all
-- and assertions 41–42 would be asserting nothing.
select public.fn_issue_certificate('bonafide', pg_temp.stu('Owing Child')) as honest \gset

select public.fn_issue_certificate(
  'bonafide', pg_temp.stu('Owing Child'),
  jsonb_build_object(
    'is_duplicate', false, 'original_serial_no', 99,
    'dues_cleared', true, 'balance_at_issue', 0,
    'student_name', 'Somebody Else', 'gr_no', 'GR-9999',
    'date_of_leaving', '1999-01-01', 'attended_from', '1999-01-01',
    'dues_override_reason', 'nobody authorised this',
    'dues_override_by', 'Cert Owner A',
    -- The two the clerk IS meant to be able to set.
    'purpose', 'passport application', 'remarks', 'Fee concession holder')) as forged \gset

select pg_temp.ok(
  (select data->>'student_name' from public.certificates
    where serial_no = (:'forged'::jsonb->>'serial_no')::bigint
      and cert_type = 'bonafide') = 'Owing Child',
  '40. a forged student_name is discarded — the document names the child on the '
  || 'record, not the one the caller typed');

select pg_temp.ok(
  (select (data->>'is_duplicate')::boolean from public.certificates
    where serial_no = (:'forged'::jsonb->>'serial_no')::bigint
      and cert_type = 'bonafide'),
  '41. and it is still marked a duplicate — the DUPLICATE stamp is not the '
  || 'caller''s to switch off');

select pg_temp.ok(
  (select is_duplicate
      and original_serial_no = (:'honest'::jsonb->>'serial_no')::bigint
     from public.fn_certificate_register(50)
    where cert_type = 'bonafide'
      and serial_no = (:'forged'::jsonb->>'serial_no')::bigint),
  '42. the register agrees, and points at the REAL original''s serial, not the '
  || 'one the caller asserted');

select pg_temp.ok(
  (select not dues_cleared and balance_at_issue = 4000
     from public.fn_certificate_register(50)
    where cert_type = 'bonafide'
      and serial_no = (:'forged'::jsonb->>'serial_no')::bigint),
  '43. and the dues position is the real one — Rs 4,000 outstanding, not the '
  || 'zero that was sent');

select pg_temp.ok(
  (select data->>'dues_override_reason' is null and data->>'dues_override_by' is null
     from public.certificates
    where serial_no = (:'forged'::jsonb->>'serial_no')::bigint
      and cert_type = 'bonafide'),
  '44. no authorisation can be attributed to somebody who did not give it');

select pg_temp.ok(
  (select data->>'date_of_leaving' is null
     from public.certificates
    where serial_no = (:'forged'::jsonb->>'serial_no')::bigint
      and cert_type = 'bonafide'),
  '45. and a bonafide gains no date of leaving from a caller that sends one — a '
  || 'proof-of-enrolment document must not read as a leaving certificate');

select pg_temp.ok(
  (select data->>'purpose' = 'passport application'
      and data->>'remarks' = 'Fee concession holder'
     from public.certificates
    where serial_no = (:'forged'::jsonb->>'serial_no')::bigint
      and cert_type = 'bonafide'),
  '46. while purpose and remarks — the fields the free-form data exists for — '
  || 'still reach the document. Locking it down must not empty it');

rollback;
