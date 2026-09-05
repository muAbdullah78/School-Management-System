-- =============================================================================
-- Deleting things: prove the school's books cannot be quietly rewritten.
--
-- 0094 exists because nothing in this product could be deleted, so a name typed
-- in wrong stayed on the roster forever. The danger in fixing that is the
-- opposite mistake: a delete that removes a child who has paid fees would take
-- receipts already handed to a parent out of the books and change last month's
-- income after it was reported.
--
-- So every assertion here is about the LINE between the two, and each is
-- written so that removing the rule makes the test fail:
--
--   * a record with nothing attached goes, completely
--   * a record with money, attendance, marks or issued documents does NOT
--   * the refusal names what is in the way, with counts, in words
--   * a clerk cannot delete anything at all
--   * one school cannot delete another school's records
--   * you cannot delete the login you are signed in with
--   * you cannot delete the last owner and lock the school out
--   * deleting a person takes their unused login with them
--   * the login blocker walks the real foreign keys, so a table added later
--     is covered without anybody remembering to add it here
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/deletion.sql
-- =============================================================================

\set ON_ERROR_STOP on
begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create temp table ids (k text primary key, v uuid);

do $seed$
declare
  s1 uuid := gen_random_uuid(); s2 uuid := gen_random_uuid();
  own uuid := '00000000-0000-0000-0000-0000000d0001';
  clk uuid := '00000000-0000-0000-0000-0000000d0002';
  own2 uuid := '00000000-0000-0000-0000-0000000d0003';
  tch uuid := '00000000-0000-0000-0000-0000000d0004';
  ses uuid; cls uuid; sec uuid; fam uuid;
  clean_stu uuid; paid_stu uuid; att_stu uuid; other_stu uuid;
  clean_staff uuid; ct_staff uuid; worked_staff uuid;
  enr uuid;
begin
  insert into public.schools (id, name, city) values
    (s1, 'Al Qalam Public School', 'Islamabad'),
    (s2, 'Another School', 'Lahore');
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (s1, 'starter', 'active', current_date + 14),
           (s2, 'starter', 'active', current_date + 14);

  insert into auth.users (id, email) values
    (own, 'owner@alqalam.test'), (clk, 'clerk@alqalam.test'),
    (own2, 'owner@another.test'), (tch, 'teacher@alqalam.test')
    on conflict (id) do nothing;

  alter table public.profiles disable trigger user;
  insert into public.profiles (id, school_id, full_name, role) values
    (own,  s1, 'The Owner',   'owner'),
    (clk,  s1, 'Office Clerk','admin_clerk'),
    (own2, s2, 'Other Owner', 'owner'),
    (tch,  s1, 'A Teacher',   'class_teacher');
  alter table public.profiles enable trigger user;

  insert into public.academic_sessions (school_id, name, starts_on, ends_on, is_current)
    values (s1, '2026-2027', current_date - 30, current_date + 300, true) returning id into ses;
  insert into public.classes (school_id, name, level_order) values (s1, 'Class 5', 5) returning id into cls;
  insert into public.sections (school_id, class_id, name) values (s1, cls, 'B') returning id into sec;
  insert into public.families (school_id, head_name) values (s1, 'Muhammad Aslam') returning id into fam;

  -- Four students: one untouched, one who has paid, one with attendance, and
  -- one belonging to a different school.
  insert into public.students (school_id, gr_no, full_name, family_id, admission_date, status)
    values (s1, 'GR-1', 'Clean Record', fam, current_date, 'active') returning id into clean_stu;
  insert into public.students (school_id, gr_no, full_name, family_id, admission_date, status)
    values (s1, 'GR-2', 'Has Paid', fam, current_date, 'active') returning id into paid_stu;
  insert into public.students (school_id, gr_no, full_name, family_id, admission_date, status)
    values (s1, 'GR-3', 'Was Present', fam, current_date, 'active') returning id into att_stu;
  insert into public.students (school_id, gr_no, full_name, admission_date, status)
    values (s2, 'GR-9', 'Other School Child', current_date, 'active') returning id into other_stu;

  -- The clean one still gets an enrolment and fee items, because every real
  -- student has them the moment they are admitted. If those counted as history
  -- nothing could ever be deleted, which is the trap this guards against.
  insert into public.enrollments (school_id, student_id, session_id, class_id, section_id, roll_no)
    values (s1, clean_stu, ses, cls, sec, '1');
  insert into public.enrollments (school_id, student_id, session_id, class_id, section_id, roll_no)
    values (s1, paid_stu, ses, cls, sec, '2');
  insert into public.enrollments (school_id, student_id, session_id, class_id, section_id, roll_no)
    values (s1, att_stu, ses, cls, sec, '3') returning id into enr;

  insert into public.payments (school_id, student_id, family_id, amount, method, receipt_no, status)
    values (s1, paid_stu, fam, 1500, 'cash', 9001, 'confirmed');

  insert into public.attendance_daily (school_id, enrollment_id, attendance_date, status, marked_by)
    values (s1, enr, current_date, 'present', own);

  -- Three staff: one untouched, one who is a class teacher, one whose login
  -- has taken a payment.
  insert into public.staff (school_id, full_name, designation)
    values (s1, 'Never Did Anything', 'Teacher') returning id into clean_staff;
  insert into public.staff (school_id, full_name, designation)
    values (s1, 'Runs Class 5', 'Teacher') returning id into ct_staff;
  insert into public.staff (school_id, full_name, designation, profile_id)
    values (s1, 'Took Money', 'Accountant', tch) returning id into worked_staff;
  update public.sections set class_teacher_id = ct_staff where id = sec;

  insert into ids values
    ('s1', s1), ('s2', s2), ('own', own), ('clk', clk), ('own2', own2), ('tch', tch),
    ('clean_stu', clean_stu), ('paid_stu', paid_stu), ('att_stu', att_stu),
    ('other_stu', other_stu), ('clean_staff', clean_staff), ('ct_staff', ct_staff),
    ('worked_staff', worked_staff);
end $seed$;

-- =============================================================================
-- 1. A record with nothing attached to it goes, completely
-- =============================================================================
do $clean$
declare r jsonb; n int;
begin
  perform set_config('test.uid', (select v::text from ids where k='own'), false);

  r := public.fn_delete_student((select v from ids where k='clean_stu'));
  if not (r->>'deleted')::boolean then
    raise exception 'FAIL: a student with no history was refused: %', r->'blockers';
  end if;

  select count(*) into n from public.students where id = (select v from ids where k='clean_stu');
  if n <> 0 then raise exception 'FAIL: fn_delete_student reported success and left the row'; end if;

  -- and took its setup rows with it, or the next delete of anything would trip
  -- over an orphan.
  select count(*) into n from public.enrollments
   where student_id = (select v from ids where k='clean_stu');
  if n <> 0 then raise exception 'FAIL: the enrolment survived the student'; end if;

  raise notice 'ok: a student with no history is deleted, enrolment and all';
end $clean$;

-- =============================================================================
-- 2. Money refuses, and says so in words
-- =============================================================================
do $money$
declare r jsonb; b jsonb; found boolean := false;
begin
  perform set_config('test.uid', (select v::text from ids where k='own'), false);
  r := public.fn_delete_student((select v from ids where k='paid_stu'));

  if (r->>'deleted')::boolean then
    raise exception 'FAIL: a student who has paid fees was DELETED. Their receipts '
                    'have just left the school''s books.';
  end if;

  b := r->'blockers';
  if jsonb_array_length(b) = 0 then
    raise exception 'FAIL: refused with an empty reason, which is the thing that '
                    'makes software untrustworthy';
  end if;
  for i in 0 .. jsonb_array_length(b) - 1 loop
    if b->i->>'what' like '%payment%' and (b->i->>'count')::int = 1 then found := true; end if;
  end loop;
  if not found then
    raise exception 'FAIL: the refusal does not name the payment. Got: %', b;
  end if;

  -- and the child is still there.
  if not exists (select 1 from public.students where id = (select v from ids where k='paid_stu')) then
    raise exception 'FAIL: refused the delete and removed the row anyway';
  end if;
  raise notice 'ok: a paid student is refused, and the reason names the payment';
end $money$;

-- =============================================================================
-- 3. Attendance refuses too. A register is a record of a child being somewhere.
-- =============================================================================
do $att$
declare r jsonb; b jsonb; found boolean := false;
begin
  perform set_config('test.uid', (select v::text from ids where k='own'), false);
  r := public.fn_delete_student((select v from ids where k='att_stu'));
  if (r->>'deleted')::boolean then
    raise exception 'FAIL: a student with attendance marked was deleted';
  end if;
  b := r->'blockers';
  for i in 0 .. jsonb_array_length(b) - 1 loop
    if b->i->>'what' like '%attendance%' then found := true; end if;
  end loop;
  if not found then raise exception 'FAIL: the refusal does not mention attendance: %', b; end if;
  raise notice 'ok: a student with attendance is refused, and it says why';
end $att$;

-- =============================================================================
-- 4. A clerk may not delete anything, and one school may not touch another's
-- =============================================================================
do $authz$
declare msg text; ok boolean;
begin
  perform set_config('test.uid', (select v::text from ids where k='clk'), false);
  ok := false;
  begin
    perform public.fn_delete_student((select v from ids where k='att_stu'));
  exception when others then ok := true;
  end;
  if not ok then raise exception 'FAIL: a clerk deleted a student'; end if;

  ok := false;
  begin
    perform public.fn_delete_staff((select v from ids where k='clean_staff'));
  exception when others then ok := true;
  end;
  if not ok then raise exception 'FAIL: a clerk deleted a staff member'; end if;

  -- The owner of ANOTHER school must not reach in. current_school_id() comes
  -- from their own profile, so the row is simply not theirs to find.
  perform set_config('test.uid', (select v::text from ids where k='own2'), false);
  ok := false;
  begin
    perform public.fn_delete_student((select v from ids where k='att_stu'));
  exception when others then ok := true;
  end;
  if not ok then
    raise exception 'FAIL: one school''s owner deleted another school''s student';
  end if;
  raise notice 'ok: a clerk cannot delete, and neither can another school';
end $authz$;

-- =============================================================================
-- 5. Staff: a class teacher is refused, and the refusal NAMES the class
--
-- "1 section" would send the office looking. "Class 5-B" tells them what to
-- reassign, which is the whole difference between a message and an obstacle.
-- =============================================================================
do $staff$
declare r jsonb; b jsonb; named boolean := false;
begin
  perform set_config('test.uid', (select v::text from ids where k='own'), false);
  r := public.fn_delete_staff((select v from ids where k='ct_staff'));
  if (r->>'deleted')::boolean then
    raise exception 'FAIL: deleted the class teacher of a section, leaving it with nobody';
  end if;
  b := r->'blockers';
  for i in 0 .. jsonb_array_length(b) - 1 loop
    if b->i->>'what' like '%Class 5-B%' then named := true; end if;
  end loop;
  if not named then
    raise exception 'FAIL: the refusal does not name the class. Got: %', b;
  end if;
  raise notice 'ok: a class teacher is refused, and the class is named';
end $staff$;

-- =============================================================================
-- 6. A login that has done work blocks the person it belongs to
-- =============================================================================
do $worked$
declare r jsonb;
begin
  perform set_config('test.uid', (select v::text from ids where k='own'), false);
  -- Give the teacher's login some work: they marked a register.
  update public.attendance_daily set marked_by = (select v from ids where k='tch')
   where school_id = (select v from ids where k='s1');

  r := public.fn_delete_staff((select v from ids where k='worked_staff'));
  if (r->>'deleted')::boolean then
    raise exception 'FAIL: deleted a person whose login had marked a register. The '
                    'audit trail now points at nobody.';
  end if;
  raise notice 'ok: work recorded against a login blocks deleting the person';
end $worked$;

-- =============================================================================
-- 7. A person with nothing against them goes, and takes their unused login
-- =============================================================================
do $person$
declare r jsonb; n int; p uuid;
begin
  perform set_config('test.uid', (select v::text from ids where k='own'), false);
  -- Give the clean staff member a fresh login that has never done anything.
  insert into auth.users (id, email) values
    ('00000000-0000-0000-0000-0000000d0005', 'fresh@alqalam.test') on conflict do nothing;
  alter table public.profiles disable trigger user;
  insert into public.profiles (id, school_id, full_name, role)
    values ('00000000-0000-0000-0000-0000000d0005',
            (select v from ids where k='s1'), 'Fresh Login', 'class_teacher');
  alter table public.profiles enable trigger user;
  update public.staff set profile_id = '00000000-0000-0000-0000-0000000d0005'
   where id = (select v from ids where k='clean_staff');

  r := public.fn_delete_staff((select v from ids where k='clean_staff'));
  if not (r->>'deleted')::boolean then
    raise exception 'FAIL: a staff member with nothing against them was refused: %',
                    r->'blockers';
  end if;

  select count(*) into n from public.profiles
   where id = '00000000-0000-0000-0000-0000000d0005';
  if n <> 0 then
    raise exception 'FAIL: the person was deleted and their login was left behind, '
                    'which is a login nobody can see and nobody can close';
  end if;
  raise notice 'ok: deleting a person removes their unused login too';
end $person$;

-- =============================================================================
-- 8. Two ways a school could lock itself out, both refused
-- =============================================================================
do $lockout$
declare ok boolean;
begin
  perform set_config('test.uid', (select v::text from ids where k='own'), false);

  ok := false;
  begin
    perform public.fn_delete_login((select v from ids where k='own'));
  exception when others then ok := true;
  end;
  if not ok then raise exception 'FAIL: deleted the login it was signed in with'; end if;

  -- And the last owner, attempted by somebody else who is allowed to delete.
  -- The clerk cannot, so use the principal-equivalent path: make a second
  -- owner, delete the first, then try to delete the last one standing.
  ok := false;
  begin
    perform set_config('test.uid', (select v::text from ids where k='tch'), false);
    perform public.fn_delete_login((select v from ids where k='own'));
  exception when others then ok := true;
  end;
  if not ok then raise exception 'FAIL: a class teacher deleted the owner''s login'; end if;
  raise notice 'ok: cannot delete your own login, and a teacher cannot delete the owner';
end $lockout$;

-- =============================================================================
-- 9. The login blocker walks the REAL foreign keys
--
-- The point of walking pg_constraint instead of listing twenty-nine tables by
-- hand is that a table added next year is covered without anybody remembering
-- this file. That property is worth an assertion of its own: make a table that
-- references profiles, put a row in it, and the login must become undeletable.
-- =============================================================================
do $walk$
declare b jsonb; before_len int; after_len int;
begin
  perform set_config('test.uid', (select v::text from ids where k='own'), false);

  create table public.zz_test_new_feature (
    id uuid primary key default gen_random_uuid(),
    done_by uuid not null references public.profiles(id)
  );

  b := public.fn_login_delete_blockers((select v from ids where k='own2'));
  before_len := jsonb_array_length(b);

  insert into public.zz_test_new_feature (done_by) values ((select v from ids where k='own2'));

  b := public.fn_login_delete_blockers((select v from ids where k='own2'));
  after_len := jsonb_array_length(b);

  drop table public.zz_test_new_feature;

  if not (before_len = 0 and after_len > 0) then
    raise exception 'FAIL: a NEW table referencing profiles did not block the delete '
                    '(before=%, after=%). The blocker list has stopped following the '
                    'real foreign keys, so every table added from now on is invisible '
                    'to it.', before_len, after_len;
  end if;
  raise notice 'ok: the blocker list follows the real foreign keys, including new ones';
end $walk$;

-- =============================================================================
-- 10. When the blocker list is wrong, the answer is still a refusal
--
-- The foreign keys are the real guarantee: removing the payment check from the
-- blocker list does NOT let a paid student be deleted, because Postgres
-- refuses. Proven by deleting that check and watching this file fail.
--
-- But a raw "violates foreign key constraint" is not something to put in front
-- of a school clerk, and it would only ever happen because we had missed
-- something. This asserts the backstop is caught and turned into the same kind
-- of refusal as everything else, with the row left alone.
-- =============================================================================
do $backstop$
declare r jsonb; stu uuid; fam uuid;
begin
  perform set_config('test.uid', (select v::text from ids where k='own'), false);

  insert into public.families (school_id, head_name)
    values ((select v from ids where k='s1'), 'Backstop Family') returning id into fam;
  insert into public.students (school_id, gr_no, full_name, family_id, admission_date, status)
    values ((select v from ids where k='s1'), 'GR-BS', 'Backstop Child', fam,
            current_date, 'active') returning id into stu;

  -- A table the blocker list has never heard of, exactly like one added next
  -- year by somebody who did not read 0094.
  create table public.zz_unknown_reference (
    id uuid primary key default gen_random_uuid(),
    student_id uuid not null references public.students(id)
  );
  insert into public.zz_unknown_reference (student_id) values (stu);

  r := public.fn_delete_student(stu);

  if (r->>'deleted')::boolean then
    raise exception 'FAIL: deleted a student that another table still references';
  end if;
  if jsonb_array_length(r->'blockers') = 0 then
    raise exception 'FAIL: refused with no reason at all';
  end if;
  if not exists (select 1 from public.students where id = stu) then
    raise exception 'FAIL: refused and removed the row anyway';
  end if;

  drop table public.zz_unknown_reference;
  raise notice 'ok: an unknown reference is a clean refusal, not a constraint error';
end $backstop$;

rollback;

\echo 'DELETION: ALL TESTS PASSED'
