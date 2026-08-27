-- =============================================================================
-- Suspending, cancelling, archiving and purging a school.
--
-- Covers 0079 and 0080. Two things here are worth more than the rest:
--
--   1. A SUSPENDED SCHOOL IS TOLD WHY, BY THE SOFTWARE.
--      suspend_reason is not an operator note. fn_my_licence returns it and the
--      banner shows it. A school whose software stops with no explanation
--      phones in a panic, and the person answering is the person who suspended
--      it. Assertions 20-24.
--
--   2. THE PURGE ACTUALLY WORKS, AND IS HARD TO REACH.
--      37 tables reference public.schools with ON DELETE NO ACTION, so before
--      0080 a school could not be deleted at all — the delete failed on the
--      first foreign key. This suite builds a school with rows in the awkward
--      tables (payments before allocations, invoices before lines) and purges
--      it, then asserts the count of remaining rows is zero across EVERY table
--      in the catalogue rather than a list somebody maintained. Assertions
--      50-59.
--
--      And it proves all five refusals in front of it, because a purge that can
--      be reached by a mis-click is worse than no purge.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/school_lifecycle.sql
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

create or replace function pg_temp.refused(p_sql text) returns boolean
language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return true;
end;
$$;

create or replace function pg_temp.why(p_sql text) returns text
language plpgsql as $$
begin
  execute p_sql;
  return '(no error)';
exception when others then
  return sqlerrm;
end;
$$;

-- --- Fixture: one school with data in the awkward tables ---------------------
-- The point of the fixture is the DEPENDENCY CHAINS. A purge that works on an
-- empty school proves nothing: the reason a school could not be deleted was
-- payment_allocations pointing at payments pointing at invoices pointing at
-- students, and mark_entries pointing at assessments pointing at exam_subjects.
do $seed$
declare
  v_school uuid; v_keep uuid;
  v_owner uuid := '00000000-0000-0000-0000-00000000a001';
  ops     uuid := '00000000-0000-0000-0000-00000000a0fa';
  v_sess uuid; v_cls uuid; v_sec uuid; v_fam uuid; v_kid uuid;
  v_head uuid; v_inv uuid; v_pay uuid; v_term uuid; v_subj uuid;
  v_es uuid; v_asmt uuid; v_staff uuid; v_enr uuid;
begin
  insert into public.schools (name, city, contact_name, contact_phone)
    values ('Purge Test School', 'Sialkot', 'Tariq Sahib', '0300-7778889')
    returning id into v_school;
  -- A second school that must be UNTOUCHED by everything below. A purge that
  -- deletes one school's rows and one row of somebody else's is the worst
  -- possible outcome and nothing else in this file would notice.
  insert into public.schools (name, city) values ('Keep Me School', 'Quetta')
    returning id into v_keep;
  -- One child of its own, with a name nothing else in this file uses. It is the
  -- marker for "the purge took a row it should not have": a sweep that only
  -- counts the purged school's rows would pass on a function that emptied both.
  insert into public.students (gr_no, full_name, school_id)
    values ('KEEP-1', 'KEEPME Child', v_keep);

  insert into public.subscriptions (school_id, plan_code, status, cycle,
                                    period_start, period_end, grace_ends_on, student_count)
  values (v_school, 'growth', 'active', 'yearly',
          current_date - 100, current_date + 265, current_date + 279, 3),
         (v_keep, 'starter', 'active', 'yearly',
          current_date - 100, current_date + 265, current_date + 279, 1);

  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_school) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Class 5', 5, v_school) returning id into v_cls;
  insert into public.sections (class_id, name, school_id)
    values (v_cls, 'A', v_school) returning id into v_sec;
  insert into public.families (head_name, phone, school_id)
    values ('Tariq Mahmood', '0300-7778889', v_school) returning id into v_fam;
  insert into public.students (gr_no, full_name, family_id, school_id)
    values ('PT-1', 'Purge Child One', v_fam, v_school) returning id into v_kid;
  insert into public.guardians (student_id, name, relation, phone, school_id)
    values (v_kid, 'Tariq Mahmood', 'father', '0300-7778889', v_school);
  insert into public.enrollments (student_id, session_id, class_id, section_id, school_id)
    values (v_kid, v_sess, v_cls, v_sec, v_school) returning id into v_enr;

  -- Money: invoice -> lines, payment -> allocations. The chain that made the
  -- delete impossible.
  insert into public.fee_heads (name, type, is_recurring, school_id)
    values ('Tuition', 'monthly', true, v_school) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_cls, v_head, 3500, v_school);
  insert into public.invoices (student_id, session_id, period_month, due_date,
                               status, school_id)
    values (v_kid, v_sess, date_trunc('month', current_date)::date,
            current_date + 10, 'issued', v_school)
    returning id into v_inv;
  insert into public.invoice_lines (invoice_id, description, amount, school_id)
    values (v_inv, 'Tuition Fee', 3500, v_school);
  insert into public.payments (student_id, amount, method, status, school_id)
    values (v_kid, 3500, 'cash', 'verified', v_school) returning id into v_pay;
  insert into public.payment_allocations (payment_id, invoice_id, amount, school_id)
    values (v_pay, v_inv, 3500, v_school);

  -- Exams: exam_terms -> exam_subjects -> assessments -> mark_entries.
  insert into public.subjects (name, school_id) values ('Maths', v_school)
    returning id into v_subj;
  insert into public.exam_terms (session_id, name, school_id)
    values (v_sess, 'First Term', v_school) returning id into v_term;
  insert into public.exam_subjects (exam_term_id, class_id, subject_id, max_marks, school_id)
    values (v_term, v_cls, v_subj, 100, v_school) returning id into v_es;
  insert into public.assessments (session_id, class_id, subject_id, title,
                                  max_marks, assessment_date, school_id)
    values (v_sess, v_cls, v_subj, 'First Term Maths', 100, current_date, v_school)
    returning id into v_asmt;
  insert into public.mark_entries (assessment_id, enrollment_id, marks, max_marks, school_id)
    values (v_asmt, v_enr, 88, 100, v_school);

  insert into public.attendance_daily (enrollment_id, attendance_date, status, school_id)
    values (v_enr, current_date, 'present', v_school);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_owner, 'owner@purge.test'), (ops, 'ops@purge.test')
  on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_owner, 'Purge Owner', 'owner', v_school)
  on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;

  insert into public.staff (full_name, designation, joined_on, school_id)
    values ('Nasreen Bibi', 'Teacher', current_date - 400, v_school)
    returning id into v_staff;
  insert into public.staff_attendance (staff_id, attendance_date, status, school_id)
    values (v_staff, current_date, 'present', v_school);

  insert into public.platform_admins (user_id, email) values (ops, 'ops@purge.test')
    on conflict (user_id) do nothing;

  create temp table _life (k text primary key, v uuid);
  insert into _life values
    ('school', v_school), ('keep', v_keep), ('owner', v_owner), ('ops', ops),
    ('kid', v_kid);
end $seed$;

do $grant_life$
declare v_ns text;
begin
  select n.nspname into v_ns from pg_namespace n
    join pg_class c on c.relnamespace = n.oid
   where c.relname = '_life' and n.nspname like 'pg\_temp%';
  execute format('grant usage on schema %I to authenticated', v_ns);
  grant select on _life to authenticated;
end $grant_life$;

create or replace function public._lact(p_key text) returns void
language plpgsql as $$
begin
  perform set_config('test.uid', (select v::text from _life where k = p_key), false);
end;
$$;

-- =============================================================================
-- 1-9  THE CALENDAR STILL WORKS, and a per-school grace window
-- =============================================================================
do $grace$
declare
  s uuid := (select v from _life where k='school');
  r jsonb;
begin
  perform public._lact('ops');
  perform pg_temp.ok(public.fn_effective_status(s) = 'active',
    '1 a paid school is active');

  -- Expire it, and check the standard window first.
  update public.subscriptions set period_end = current_date - 5 where school_id = s;
  perform pg_temp.ok(public.fn_effective_status(s) = 'grace',
    '2 five days past the end, inside the standard 14, is grace');
  update public.subscriptions set period_end = current_date - 20 where school_id = s;
  perform pg_temp.ok(public.fn_effective_status(s) = 'locked',
    '3 twenty days past is locked');

  -- The school that always pays late and always pays.
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_set_grace(%L, 45)', s)),
    '4 a different grace window for one school needs a reason');
  r := public.fn_platform_set_grace(s, 45, 'pays every year, accountant is slow');
  perform pg_temp.ok((r->>'grace_days')::int = 45 and (r->>'is_override')::boolean,
    '5 the override is recorded');
  perform pg_temp.ok(public.fn_effective_status(s) = 'grace',
    '6 and twenty days past the end is now inside grace');

  -- And back.
  r := public.fn_platform_set_grace(s, null);
  perform pg_temp.ok((r->>'grace_days')::int = public.grace_days()
                 and not (r->>'is_override')::boolean,
    '7 clearing the override needs no reason and restores the standard window');
  perform pg_temp.ok(public.fn_effective_status(s) = 'locked',
    '8 which puts them back to locked');
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_set_grace(%L, 400, ''forever'')', s)),
    '9 an absurd grace period is refused');

  -- Put the licence back for the blocks below.
  update public.subscriptions set period_end = current_date + 265 where school_id = s;
end $grace$;

-- =============================================================================
-- 20-29  SUSPEND — and the school is told why
-- =============================================================================
do $suspend$
declare
  s uuid := (select v from _life where k='school');
  r jsonb; lic jsonb; msg text;
begin
  perform public._lact('ops');
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_suspend_school(%L, ''  '')', s)),
    '20 suspending without a reason is refused');

  r := public.fn_platform_suspend_school(s, 'Three months unpaid and not answering the phone');
  perform pg_temp.ok((r->>'suspended')::boolean, '21 the school is suspended');
  -- The calendar says active; the suspension says otherwise, and it wins.
  perform pg_temp.ok(public.fn_effective_status(s) = 'locked',
    '22 a suspension beats a licence that has months left');

  -- THE ASSERTION THIS WHOLE FEATURE TURNS ON.
  perform public._lact('owner');
  set local role authenticated;
  lic := public.fn_my_licence();
  reset role;
  perform pg_temp.ok((lic->>'suspended')::boolean
                 and lic->>'suspend_reason' like '%not answering%',
    '23 the school is told it is suspended, and why, by the software');
  perform pg_temp.ok((lic->>'can_read')::boolean and (lic->>'can_export')::boolean
                 and not (lic->>'can_operate')::boolean,
    '24 reading and exporting are never withdrawn — only new entries stop');

  -- Reads really do still work while suspended.
  perform public._lact('owner');
  set local role authenticated;
  perform pg_temp.ok((select count(*) from public.students) > 0,
    '25 a suspended school can still read its own students');
  reset role;

  perform public._lact('ops');
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_suspend_school(%L, ''again'')', s)),
    '26 it cannot be suspended twice');
  perform pg_temp.ok(exists (select 1 from public.audit_log
                              where school_id = s and action = 'subscription_suspended'),
    '27 the suspension is in the SCHOOL''s own audit log, not only ours');

  r := public.fn_platform_unsuspend_school(s, 'paid in full');
  perform pg_temp.ok(not (r->>'suspended')::boolean
                 and r->>'status' = 'active',
    '28 lifting it returns them to whatever the calendar says');
  -- The reason survives in the log entry that lifted it. Clearing the column
  -- would otherwise erase the only record of why.
  perform pg_temp.ok((select detail->>'was_reason' from public.operator_actions
                       where school_id = s and action = 'school_unsuspended'
                       order by at desc limit 1) like '%not answering%',
    '29 and the reason it was suspended survives in the history');
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_unsuspend_school(%L)', s)),
    '29b un-suspending a school that is not suspended is refused');
end $suspend$;

-- =============================================================================
-- 30-39  CANCEL AND ARCHIVE
-- =============================================================================
do $arch$
declare
  s uuid := (select v from _life where k='school');
  ops uuid := (select v from _life where k='ops');
  r jsonb; n integer; msg text;
begin
  perform public._lact('ops');

  -- Cancelling is a churn record. The reason is the only churn data this
  -- business will ever have, so it is mandatory.
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_cancel_subscription(%L, null)', s)),
    '30 cancelling needs a reason');

  -- Give them an invoice so the debt path is exercised.
  perform public.fn_activate_subscription(s, 'growth', 12);
  r := public.fn_platform_cancel_subscription(s, 'moved to a competitor on price');
  perform pg_temp.ok(r->>'status' = 'cancelled', '31 the licence is cancelled');
  -- Cancelling must not look like forgiving a debt.
  perform pg_temp.ok((r->>'outstanding')::numeric > 0
                 and r->>'note' like '%does not write that off%',
    '32 and it says the money is still owed');
  perform pg_temp.ok(public.fn_effective_status(s) = 'cancelled',
    '33 the status follows');

  -- Still visible in the console: cancelled is not archived.
  select count(*) into n from public.fn_platform_schools() where school_id = s;
  perform pg_temp.ok(n = 1, '34 a cancelled school is still in the list');

  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_archive_school(%L, '' '')', s)),
    '35 archiving needs a reason');

  r := public.fn_platform_archive_school(s, 'left in August, data kept for a year');
  perform pg_temp.ok((r->>'archived')::boolean and (r->>'reversible')::boolean,
    '36 the school is archived, and it says so is reversible');
  select count(*) into n from public.fn_platform_schools() where school_id = s;
  perform pg_temp.ok(n = 0, '37 and gone from the console list');
  select count(*) into n from public.fn_platform_schools(true) where school_id = s;
  perform pg_temp.ok(n = 1, '37b unless you ask for archived ones');
  select count(*) into n from public.fn_platform_due_soon(365) where school_id = s;
  perform pg_temp.ok(n = 0, '38 and off the renewal worklist');

  -- Data intact. This is the promise archive makes.
  perform pg_temp.ok((select count(*) from public.students where school_id = s) > 0
                 and (select count(*) from public.mark_entries where school_id = s) > 0,
    '39 nothing was deleted');
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_archive_school(%L, ''twice'')', s)),
    '39b it cannot be archived twice');

  -- Reversible, and it does NOT quietly hand back a licence.
  r := public.fn_platform_unarchive_school(s);
  perform pg_temp.ok(not (r->>'archived')::boolean
                 and public.fn_effective_status(s) = 'cancelled',
    '39c unarchiving makes them visible again and still cancelled');
  perform public.fn_platform_archive_school(s, 'left in August, data kept for a year');
end $arch$;

-- =============================================================================
-- 40-49  EXPORT — and the boundary it must not cross
-- =============================================================================
do $exp$
declare
  s uuid := (select v from _life where k='school');
  keep uuid := (select v from _life where k='keep');
  m jsonb; t jsonb; r jsonb; msg text;
begin
  perform public._lact('ops');

  -- THE LINE. A full export of every child's name and every guardian's phone
  -- number is an offboarding step, not a way to pull a live customer's records.
  msg := pg_temp.why(format('select public.fn_platform_export_manifest(%L)', keep));
  perform pg_temp.ok(msg like '%Archive%',
    '40 a live school cannot be exported, and the message says to archive first');

  m := public.fn_platform_export_manifest(s);
  perform pg_temp.ok((m->>'total_rows')::int > 10,
    '41 the archived school has a manifest with rows in it');
  -- Every table, empty ones included: otherwise "they never used marks" and
  -- "marks were left out" look identical.
  perform pg_temp.ok(jsonb_array_length(m->'tables')
                       = (select count(*) from public.fn__school_data_tables()),
    '42 the manifest lists every data table, including the empty ones');
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(m->'tables') x
                              where x->>'name' = 'mark_entries'
                                and (x->>'rows')::int = 1),
    '42b and its counts are right');

  t := public.fn_platform_export_table(s, 'students');
  perform pg_temp.ok((t->>'count')::int = 1
                 and t->'rows'->0->>'full_name' = 'Purge Child One',
    '43 a table exports its actual rows');

  -- A table name from a client goes into dynamic SQL. Checked against the
  -- catalogue-derived list, not quoted and hoped.
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_export_table(%L, ''platform_payments'')', s)),
    '44 our own billing tables are not the school''s data to export');
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_export_table(%L, ''pg_authid'')', s)),
    '44b nor is anything outside the list');

  -- The export must not reach the other school's rows in a table they BOTH have
  -- rows in — which is the only version of this check that means anything. The
  -- generated statement scopes on school_id; `students` is where a missing scope
  -- would hand one customer another customer's children.
  perform pg_temp.ok(
    not ((public.fn_platform_export_table(s, 'students'))::text like '%KEEPME%'),
    '45 an export of one school contains no other school''s pupil');
  perform pg_temp.ok(
    (public.fn_platform_export_table(s, 'students'))::text like '%Purge Child One%',
    '45b (premise) while containing its own');

  r := public.fn_platform_record_export(s,
    jsonb_build_object('students', 1, 'mark_entries', 1, 'payments', 1), 'sent by email');
  perform pg_temp.ok((r->>'total_rows')::int = 3, '46 the export is recorded');
  perform pg_temp.ok(exists (select 1 from public.platform_exports
                              where school_id = s and school_name = 'Purge Test School'),
    '47 with the school name denormalised, so it can outlive the school');
end $exp$;

-- =============================================================================
-- 50-59  PURGE — five refusals, then it actually works
-- =============================================================================
do $purge$
declare
  s uuid := (select v from _life where k='school');
  keep uuid := (select v from _life where k='keep');
  r record; n bigint; total bigint := 0; msg text; res jsonb;
  keep_before bigint; keep_after bigint;
begin
  perform public._lact('ops');

  -- --- refusal 3: the phrase ------------------------------------------------
  msg := pg_temp.why(format(
    'select public.fn_platform_purge_school(%L, ''purge test school'')', s));
  perform pg_temp.ok(msg like '%type exactly%',
    '50 a near-miss on the name is refused, and the message gives the exact name');
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_purge_school(%L, null)', s)),
    '50b and so is no name at all');

  -- --- refusal 4: money still owed -----------------------------------------
  msg := pg_temp.why(format(
    'select public.fn_platform_purge_school(%L, ''Purge Test School'')', s));
  perform pg_temp.ok(msg like '%still owes%',
    '51 a school that owes money is not purged by accident');

  -- --- refusal 2: never exported -------------------------------------------
  -- Checked by removing the export record, because the fixture above took one.
  delete from public.platform_exports where school_id = s;
  msg := pg_temp.why(format(
    'select public.fn_platform_purge_school(%L, ''Purge Test School'', true)', s));
  perform pg_temp.ok(msg like '%exported%',
    '52 nothing is purged that has not been handed over first');
  perform public.fn_platform_record_export(s, jsonb_build_object('students', 1));

  -- --- refusal 1: not archived ---------------------------------------------
  perform public.fn_platform_unarchive_school(s);
  msg := pg_temp.why(format(
    'select public.fn_platform_purge_school(%L, ''Purge Test School'', true)', s));
  perform pg_temp.ok(msg like '%Archive%',
    '53 a school that is not archived cannot be purged');
  perform public.fn_platform_archive_school(s, 'left in August');

  -- How much is there, and how much belongs to the school that must survive.
  for r in select table_name from public.fn__school_data_tables() loop
    execute format('select count(*) from public.%I where school_id = $1', r.table_name)
      into n using s;
    total := total + n;
  end loop;
  perform pg_temp.ok(total > 15,
    '54 there is a real school here to delete, with dependency chains in it');

  select count(*) into keep_before from public.students where school_id = keep;

  -- --- and now it works ----------------------------------------------------
  -- 37 tables reference public.schools with ON DELETE NO ACTION, so before 0080
  -- this delete was impossible. It succeeds by retrying until a pass makes no
  -- progress, which is what walks payment_allocations before payments and
  -- mark_entries before assessments without a hand-kept order.
  res := public.fn_platform_purge_school(s, 'Purge Test School', true);
  -- AT LEAST what was counted, not exactly. The audit triggers this product has
  -- carried since 0001 fire on the deletes and write their own rows into
  -- audit_log, which later passes then delete as well — so the purge legitimately
  -- removes MORE rows than were there when it started. An `=` here failed at 60
  -- against 71, and the right reading of that is "the audit trail recorded its own
  -- erasure", not a bug. What must be exact is assertion 56: nothing left.
  perform pg_temp.ok((res->>'purged')::boolean
                 and (res->>'rows_deleted')::bigint >= total,
    '55 the purge deletes at least everything that was counted');
  perform pg_temp.ok((res->>'passes')::int between 2 and 12,
    '55b and it took more than one pass, which is the dependency order being walked');

  -- The assertion that matters: EVERY table in the catalogue, not a list.
  total := 0;
  for r in select table_name from public.fn__school_data_tables() loop
    execute format('select count(*) from public.%I where school_id = $1', r.table_name)
      into n using s;
    total := total + n;
  end loop;
  perform pg_temp.ok(total = 0, '56 no row for that school remains in any table');
  perform pg_temp.ok(not exists (select 1 from public.schools where id = s),
    '56b and the school itself is gone');
  perform pg_temp.ok(not exists (select 1 from public.subscriptions where school_id = s),
    '56c with its licence');

  -- The other school is untouched. Nothing else in this file would notice a
  -- purge that took one row too many.
  select count(*) into keep_after from public.students where school_id = keep;
  perform pg_temp.ok(keep_after = keep_before and keep_after > 0,
    '57 the other school lost nothing');

  -- What SURVIVES, and why: our own business records and the proof of handover.
  perform pg_temp.ok(exists (select 1 from public.platform_exports
                              where school_name = 'Purge Test School'
                                and school_id is null),
    '58 the export record outlives the school, with the name still on it');
  perform pg_temp.ok(exists (
    select 1 from public.operator_actions
     where action = 'school_purged'
       and detail->>'school_name' = 'Purge Test School'
       and school_id is null),
    '59 and the purge is on record — school_id null, so it survives the delete');
  perform pg_temp.ok((select (detail->>'exported_rows')::int > 0
                        from public.operator_actions where action = 'school_purged'
                        order by at desc limit 1),
    '59b naming what was handed over before it happened');
end $purge$;

-- =============================================================================
-- 60-69  A SCHOOL USER CAN REACH NONE OF IT
-- =============================================================================
do $deny$
declare
  keep uuid := (select v from _life where k='keep');
  owner uuid := (select v from _life where k='owner');
begin
  -- The owner's school was purged, so a fresh owner is needed for the other one.
  alter table public.profiles disable trigger user;
  insert into auth.users (id, email)
    values ('00000000-0000-0000-0000-00000000a002', 'keep@purge.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values ('00000000-0000-0000-0000-00000000a002', 'Keep Owner', 'owner', keep)
  on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', '00000000-0000-0000-0000-00000000a002', false);
  set local role authenticated;

  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_suspend_school(%L, ''x'')', keep)),
    '60 a school owner cannot suspend anybody');
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_archive_school(%L, ''x'')', keep)),
    '61 nor archive');
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_export_manifest(%L)', keep)),
    '62 nor export their own school through the operator path');
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_purge_school(%L, ''Keep Me School'', true)', keep)),
    '63 and certainly not purge');
  perform pg_temp.ok(pg_temp.refused(
    'select public.fn_platform_create_school(''{"name":"Mine"}''::jsonb)'),
    '64 nor create a school');
  perform pg_temp.ok((select count(*) from public.platform_exports) = 0,
    '65 nor read the export history');
  -- THE PREMISE, and it is not optional: a deny sweep that passes because the
  -- user can see nothing at all is measuring a broken login, not a boundary.
  -- The first version of this line was `= 0 or >= 0`, which is true of every
  -- database ever built.
  perform pg_temp.ok((select count(*) from public.students where full_name = 'KEEPME Child') = 1,
    '66 (premise) the owner can still read their own school''s pupils');
  reset role;
end $deny$;

-- =============================================================================
-- 70-79  CREATING A SCHOOL FROM THE CONSOLE
-- =============================================================================
do $create$
declare r jsonb; v_new uuid;
begin
  perform public._lact('ops');

  perform pg_temp.ok(pg_temp.refused(
    'select public.fn_platform_create_school(''{"city":"Lahore"}''::jsonb)'),
    '70 a school needs a name');
  perform pg_temp.ok(pg_temp.refused(
    'select public.fn_platform_create_school(''{"name":"X","plan_code":"nosuch"}''::jsonb)'),
    '70b and a real plan');

  r := public.fn_platform_create_school(jsonb_build_object(
    'name', '  New Console School  ', 'city', 'Faisalabad',
    'contact_name', 'Asif Sahib', 'contact_phone', '0301-1234567',
    'contact_email', 'ASIF@example.TEST', 'plan_code', 'growth',
    'trial_days', 30, 'notes', 'met at the Faisalabad expo'));
  v_new := (r->>'school_id')::uuid;
  perform pg_temp.ok(r->>'name' = 'New Console School',
    '71 the name is trimmed');
  perform pg_temp.ok((select contact_email from public.schools where id = v_new)
                       = 'asif@example.test',
    '71b and the email folded, so it matches the login they will be given');
  perform pg_temp.ok(r->>'trial_ends_on' = (current_date + 30)::text,
    '72 the trial length is what was asked for, not a fixed 14 days');
  -- The thing a console must not hide: a school row with no owner login looks
  -- like an ordinary trialing customer and nobody can sign in to it.
  perform pg_temp.ok(r->>'still_needed' like '%Nobody can sign in%',
    '73 and it says nobody can sign in yet');

  perform pg_temp.ok(pg_temp.refused(
    'select public.fn_platform_create_school(''{"name":"New Console School"}''::jsonb)'),
    '74 the same name twice is refused — it is almost always a duplicate');
  perform pg_temp.ok(pg_temp.refused(
    'select public.fn_platform_create_school(''{"name":"Y","trial_days":900}''::jsonb)'),
    '74b and an absurd trial is refused');

  -- Archiving the duplicate clears the way, because a name can legitimately be
  -- reused after a school has left.
  perform public.fn_platform_archive_school(v_new, 'test duplicate');
  perform pg_temp.ok(not pg_temp.refused(
    'select public.fn_platform_create_school(''{"name":"New Console School"}''::jsonb)'),
    '75 unless the first one is archived');
end $create$;

rollback;
