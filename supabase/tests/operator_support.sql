-- =============================================================================
-- Read-only support access: can the operator see, and can the operator write?
--
-- 0074 gives the operator a way into any school to help when a principal phones.
-- The owner chose full permanent read over consented, time-boxed access — see
-- docs/SUPER-ADMIN-DESIGN.md §2.1 for the argument they overrode. What is NOT
-- negotiable is that the access is read-only, because a writable operator
-- session would make every row in every school "possibly the vendor", and the
-- school's own audit trail is the only reason this software can be trusted with
-- money.
--
-- HOW THE READ REACH WORKS, since the assertions below only make sense with it
--
-- Every read policy on a tenant table is `school_id = current_school_id() AND
-- is_staff()` (25 tables) or `... AND may_view(roles)` (20 tables). Every WRITE
-- policy — all 43 of them — is `... AND has_role(roles)`. So 0074 amends
-- current_school_id(), is_staff() and may_view(), and deliberately leaves
-- has_role() alone. The write refusal is not code; it is the absence of a change.
--
-- That makes one thing worth stating: the assertions here are not testing a
-- feature, they are testing that a WHOLE CLASS of policy was left alone. A
-- future migration that "helpfully" adds is_operator_session() to has_role()
-- would open every write path in the product at once, and this file plus
-- check-readonly-writes.py are what stand in its way.
--
-- The rules this file defends:
--
--   1. NO SESSION, NO REACH. current_school_id() is null for an operator who has
--      not entered a school, and every tenant table reads zero.
--   2. ENTERING REQUIRES BEING THE OPERATOR, AND A REASON.
--   3. A SCHOOL USER CANNOT MANUFACTURE A SESSION. This is the catastrophic case:
--      an insertable operator_sessions row is a read of every school.
--   4. INSIDE A SESSION, READS WORK — on the is_staff tables and the may_view
--      tables alike, because those are different policy shapes.
--   5. INSIDE A SESSION, EVERY WRITE IS REFUSED. Swept over EVERY tenant table
--      and all three verbs, from the catalogue rather than a list.
--   6. THE DEFINER WRITE PATH IS REFUSED TOO. RLS does not apply inside a
--      SECURITY DEFINER function, so this is a separate boundary.
--   7. has_role() STAYS FALSE. The one-line assertion that everything else rests
--      on.
--   8. LEAVING ENDS IT, and an expired session is dead without anyone leaving.
--   9. THE SCHOOL CAN READ ITS OWN VISITS, and cannot read another school's.
--  10. EVERY ENTRY AND EXIT IS LOGGED.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/operator_support.sql
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

-- --- Fixture: two schools, one operator ---------------------------------------
-- Two, because "the operator can read the school they entered" is only half the
-- claim; the other half is that they cannot read the one they did not.
do $seed$
declare
  a_school uuid; b_school uuid;
  a_owner uuid := '00000000-0000-0000-0000-0000000005a1';
  b_owner uuid := '00000000-0000-0000-0000-0000000005b1';
  ops     uuid := '00000000-0000-0000-0000-0000000005fa';
  a_sess uuid; b_sess uuid; a_cls uuid; b_cls uuid;
  a_kid uuid; b_kid uuid; a_fam uuid;
begin
  -- Both schools before any login is adopted: enforce_school_id refuses
  -- cross-tenant provisioning once current_school_id() resolves.
  insert into public.schools (name) values ('Support Alpha') returning id into a_school;
  insert into public.schools (name) values ('Support Beta')  returning id into b_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (a_school, 'starter', 'active', current_date + 90),
           (b_school, 'starter', 'active', current_date + 90);

  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, a_school) returning id into a_sess;
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, b_school) returning id into b_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Class 1', 1, a_school) returning id into a_cls;
  insert into public.classes (name, level_order, school_id)
    values ('Class 1', 1, b_school) returning id into b_cls;

  insert into public.families (head_name, phone, school_id)
    values ('Alpha Family', '0300-1111111', a_school) returning id into a_fam;
  insert into public.students (gr_no, full_name, family_id, school_id)
    values ('SA-1', 'Alpha Child', a_fam, a_school) returning id into a_kid;
  insert into public.students (gr_no, full_name, school_id)
    values ('SB-1', 'Beta Child', b_school) returning id into b_kid;
  insert into public.enrollments (student_id, session_id, class_id, school_id)
    values (a_kid, a_sess, a_cls, a_school), (b_kid, b_sess, b_cls, b_school);

  -- A may_view table as well as an is_staff one, since they are different shapes.
  insert into public.fee_heads (name, type, is_recurring, school_id)
    values ('Tuition', 'monthly', true, a_school), ('Tuition', 'monthly', true, b_school);
  insert into public.expenses (spent_on, amount, note, school_id)
    values (current_date, 500, 'Alpha expense', a_school);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (a_owner, 'a@support.test'), (b_owner, 'b@support.test'), (ops, 'ops@support.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (a_owner, 'Alpha Owner', 'owner', a_school),
    (b_owner, 'Beta Owner',  'owner', b_school)
  on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;

  insert into public.platform_admins (user_id, email) values (ops, 'ops@support.test')
    on conflict (user_id) do nothing;

  create temp table _sup (k text primary key, v uuid);
  insert into _sup values
    ('a_school', a_school), ('b_school', b_school),
    ('a_owner', a_owner), ('b_owner', b_owner), ('ops', ops),
    ('a_kid', a_kid), ('b_kid', b_kid), ('a_fam', a_fam),
    ('a_sess', a_sess), ('a_cls', a_cls);
end $seed$;

-- The blocks below read _sup while acting as `authenticated`, and a temp table is
-- not readable by another role by default — the first run died with "permission
-- denied for table _sup" after the very first assertion. Granting is simpler than
-- hoisting every id into a local variable before each `set local role`, and it is
-- a temp table inside a transaction that rolls back.
do $grant_sup$
begin
  execute format('grant usage on schema %I to authenticated',
                 (select nspname from pg_namespace n
                   join pg_class c on c.relnamespace = n.oid
                  where c.relname = '_sup' and n.nspname like 'pg_temp%'));
  grant select on _sup to authenticated;
end $grant_sup$;

-- --- 1. No session, no reach --------------------------------------------------
do $no_session$
declare v_students bigint; v_fee bigint; v_exp bigint;
begin
  perform set_config('test.uid', (select v::text from _sup where k='ops'), false);
  set local role authenticated;
  select count(*) into v_students from public.students;
  select count(*) into v_fee      from public.fee_heads;
  select count(*) into v_exp      from public.expenses;
  if public.current_school_id() is not null then
    raise exception 'FAIL  1a. an operator with no session has a current_school_id';
  end if;
  if public.is_operator_session() then
    raise exception 'FAIL  1b. is_operator_session() true with no session';
  end if;
  if v_students <> 0 or v_fee <> 0 or v_exp <> 0 then
    raise exception 'FAIL  1c. an operator with no session reads students=% fee_heads=% expenses=%',
      v_students, v_fee, v_exp;
  end if;
  reset role;
  raise notice 'PASS  1. with no session open the operator reads nothing at all';
end $no_session$;

-- --- 2. Entering needs the operator role and a reason -------------------------
do $enter_rules$
begin
  -- A school owner cannot enter anything, including their own school.
  perform set_config('test.uid', (select v::text from _sup where k='a_owner'), false);
  set local role authenticated;
  if not pg_temp.refused(format(
      $q$select public.fn_operator_enter(%L, 'nosy')$q$,
      (select v from _sup where k='b_school'))) then
    raise exception 'FAIL  2a. a school owner opened a support session';
  end if;
  reset role;

  perform set_config('test.uid', (select v::text from _sup where k='ops'), false);
  set local role authenticated;
  -- An empty reason is refused. A log with no reason is a log nobody can use.
  if not pg_temp.refused(format(
      $q$select public.fn_operator_enter(%L, '   ')$q$,
      (select v from _sup where k='a_school'))) then
    raise exception 'FAIL  2b. a session was opened with a blank reason';
  end if;
  -- A school that does not exist is refused rather than creating a dangling row.
  if not pg_temp.refused(
      $q$select public.fn_operator_enter('00000000-0000-0000-0000-00000000dead', 'probe')$q$) then
    raise exception 'FAIL  2c. a session was opened on a nonexistent school';
  end if;
  reset role;
  raise notice 'PASS  2. entering requires the operator role, a real school and a reason';
end $enter_rules$;

-- --- 3. A school user cannot manufacture a session ----------------------------
-- The catastrophic case. An insertable operator_sessions row is a read of every
-- school in the platform, so this is checked directly against the table as well
-- as through the function.
do $forge$
declare v_touched bigint;
begin
  perform set_config('test.uid', (select v::text from _sup where k='a_owner'), false);
  set local role authenticated;

  if not pg_temp.refused(format(
      $q$insert into public.operator_sessions (admin_id, school_id, reason, expires_at)
         values (%L, %L, 'forged', now() + interval '1 hour')$q$,
      (select v from _sup where k='a_owner'), (select v from _sup where k='b_school'))) then
    raise exception 'FAIL  3a. a school owner INSERTED an operator session';
  end if;

  -- And cannot extend or reopen one. RLS makes UPDATE affect zero rows silently
  -- rather than raising, so the count is the only evidence that means anything.
  update public.operator_sessions set expires_at = now() + interval '100 days';
  get diagnostics v_touched = row_count;
  reset role;
  if v_touched <> 0 then
    raise exception 'FAIL  3b. a school owner UPDATED % operator session(s)', v_touched;
  end if;
  raise notice 'PASS  3. a school user can neither create nor extend a support session';
end $forge$;

-- --- 4-7. Inside a session ----------------------------------------------------
do $inside$
declare
  a_school uuid := (select v from _sup where k='a_school');
  b_school uuid := (select v from _sup where k='b_school');
  a_kid    uuid := (select v from _sup where k='a_kid');
  r jsonb;
  v_students bigint; v_fee bigint; v_exp bigint; v_beta bigint;
  t text; v_touched bigint; failures text := '';
begin
  perform set_config('test.uid', (select v::text from _sup where k='ops'), false);
  set local role authenticated;
  r := public.fn_operator_enter(a_school, 'principal called: the fee will not save');

  -- 4. Reads work, on BOTH policy shapes, and only for the school entered.
  select count(*) into v_students from public.students;   -- is_staff shape
  select count(*) into v_fee      from public.fee_heads;  -- may_view shape
  select count(*) into v_exp      from public.expenses;   -- may_view, narrower roles
  select count(*) into v_beta     from public.students where school_id = b_school;

  if public.current_school_id() <> a_school then
    failures := failures || '  4a. current_school_id() is not the school entered' || chr(10);
  end if;
  if v_students <> 1 then
    failures := failures || format('  4b. students reads %s, expected 1 (is_staff shape)%s', v_students, chr(10));
  end if;
  if v_fee <> 1 then
    failures := failures || format('  4c. fee_heads reads %s, expected 1 (may_view shape)%s', v_fee, chr(10));
  end if;
  if v_exp <> 1 then
    failures := failures || format('  4d. expenses reads %s, expected 1 (may_view, owner/principal/accountant)%s', v_exp, chr(10));
  end if;
  if v_beta <> 0 then
    failures := failures || '  4e. the operator can read the school they did NOT enter' || chr(10);
  end if;

  -- 7. The assertion the whole write refusal rests on.
  if public.has_role('owner') or public.has_role('principal')
     or public.has_role('admin_clerk') or public.has_role('accountant') then
    failures := failures
      || '  7. has_role() is TRUE inside a support session. Every one of the 43 '
      || 'write policies gates on it, so the operator can now write to every '
      || 'school in the platform.' || chr(10);
  end if;
  if not public.is_staff() then
    failures := failures || '  7b. is_staff() is false inside a session, so 25 read policies deny' || chr(10);
  end if;
  if not public.may_view('owner') then
    failures := failures || '  7c. may_view() is false inside a session, so 20 read policies deny' || chr(10);
  end if;

  -- 5. Every write, on every tenant table, all three verbs. From the catalogue,
  -- because a hardcoded list is how a table added later escapes the sweep.
  for t in
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid and a.attname = 'school_id'
                         and not a.attisdropped
     where n.nspname = 'public' and c.relkind = 'r'
       and c.relname not in ('_test_ids', 'subscriptions', 'student_count_snapshots',
                             'operator_actions', 'operator_sessions',
                             'platform_invoices', 'platform_payments')
     order by c.relname
  loop
    -- UPDATE and DELETE with no WHERE. Two ways a write can be refused and both
    -- count as a pass:
    --
    --   * the GRANT refuses, raising "permission denied for table X". Several
    --     tables are SELECT-only for `authenticated` — attendance_daily,
    --     invoices, payments and others whose writes all go through definer
    --     functions — so the privilege stops it before RLS is consulted. The
    --     first version of this sweep treated that as an error and died on
    --     attendance_daily.
    --   * RLS refuses, which for UPDATE and DELETE means ZERO ROWS AFFECTED,
    --     silently, without raising. So "it did not throw" proves nothing there
    --     and only the count does.
    --
    -- What must never happen is a write that both succeeds and touches a row.
    -- Any error OTHER than insufficient_privilege means the write got PAST RLS
    -- and was stopped by something incidental — a foreign key, a check
    -- constraint, a trigger. That is a failure, not a pass, and it has to say so
    -- in those words. Proved necessary by negative-testing this file: opening
    -- has_role() to operator sessions made the run die with
    --     violates foreign key constraint "enrollments_session_id_fkey"
    -- which is technically a red suite but reads like a broken fixture, and
    -- whoever saw it next would go looking in entirely the wrong place.
    begin
      execute format('update public.%I set school_id = school_id', t);
      get diagnostics v_touched = row_count;
      if v_touched <> 0 then
        failures := failures || format('  5. UPDATE %s affected %s row(s)%s', t, v_touched, chr(10));
      end if;
    exception
      when insufficient_privilege then null;
      when others then
        failures := failures || format(
          '  5. UPDATE %s was PERMITTED by RLS, stopped only by: %s%s',
          t, sqlerrm, chr(10));
    end;

    begin
      execute format('delete from public.%I', t);
      get diagnostics v_touched = row_count;
      if v_touched <> 0 then
        failures := failures || format('  5. DELETE %s removed %s row(s)%s', t, v_touched, chr(10));
      end if;
    exception
      when insufficient_privilege then null;
      when others then
        failures := failures || format(
          '  5. DELETE %s was PERMITTED by RLS, stopped only by: %s%s',
          t, sqlerrm, chr(10));
    end;
  end loop;

  -- And an INSERT, which RLS refuses by raising rather than by affecting nothing.
  if not pg_temp.refused(format(
      $q$insert into public.students (gr_no, full_name, school_id) values ('OPS-BAD','Forged',%L)$q$,
      a_school)) then
    failures := failures || '  5b. the operator INSERTED a student' || chr(10);
  end if;

  -- 6. The definer write path, which bypasses RLS entirely and is therefore a
  -- separate boundary. Three of them, chosen because each gates differently:
  -- money, access management, and a child's record.
  if not pg_temp.refused(format($q$select public.fn_record_payment(%L, 100, 'cash', null, false)$q$, a_kid)) then
    failures := failures || '  6a. the operator took a payment through fn_record_payment' || chr(10);
  end if;
  if not pg_temp.refused($q$select public.fn_invite_user('attacker@evil.test','owner')$q$) then
    failures := failures || '  6b. the operator created a user invite' || chr(10);
  end if;
  if not pg_temp.refused(format($q$select public.fn_set_student_status(%L,'struck_off','x')$q$, a_kid)) then
    failures := failures || '  6c. the operator struck a child off the roll' || chr(10);
  end if;

  reset role;
  if failures <> '' then
    raise exception E'A SUPPORT SESSION IS NOT READ-ONLY:\n%', failures;
  end if;
  raise notice 'PASS  4. inside a session both read shapes work, and only for the school entered';
  raise notice 'PASS  5. every write on every tenant table is refused (% tables swept)',
    (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid and a.attname = 'school_id' and not a.attisdropped
     where n.nspname = 'public' and c.relkind = 'r');
  raise notice 'PASS  6. the SECURITY DEFINER write path is refused too';
  raise notice 'PASS  7. has_role() stays false, which is what refuses all 43 write policies';
end $inside$;

-- --- 8. Leaving, and expiry ----------------------------------------------------
do $leaving$
declare n bigint; v_left integer;
begin
  perform set_config('test.uid', (select v::text from _sup where k='ops'), false);
  set local role authenticated;
  v_left := public.fn_operator_leave();
  select count(*) into n from public.students;
  if v_left < 1 then
    raise exception 'FAIL  8a. fn_operator_leave ended no session';
  end if;
  if n <> 0 then
    raise exception 'FAIL  8b. after leaving, the operator still reads % student(s)', n;
  end if;
  if public.current_school_id() is not null then
    raise exception 'FAIL  8c. current_school_id() survives leaving';
  end if;
  reset role;

  -- An EXPIRED session is dead without anyone having left. Otherwise a forgotten
  -- session is a permanent one, which is the failure the expiry exists for.
  perform public.fn__log_operator_action('test-marker', null, '{}'::jsonb);
  insert into public.operator_sessions (admin_id, school_id, reason, started_at, expires_at)
  values ((select v from _sup where k='ops'), (select v from _sup where k='a_school'),
          'stale session', now() - interval '2 hours', now() - interval '1 hour');

  set local role authenticated;
  select count(*) into n from public.students;
  if n <> 0 then
    raise exception 'FAIL  8d. an EXPIRED session still reads % student(s)', n;
  end if;
  if public.is_operator_session() then
    raise exception 'FAIL  8e. is_operator_session() true for an expired session';
  end if;
  reset role;
  raise notice 'PASS  8. leaving ends the reach, and an expired session is already dead';
end $leaving$;

-- --- 9. The school's own view --------------------------------------------------
do $school_view$
declare n bigint; v_reason text; v_other bigint;
begin
  perform set_config('test.uid', (select v::text from _sup where k='a_owner'), false);
  set local role authenticated;
  select count(*) into n from public.fn_support_visits();
  select reason into v_reason from public.fn_support_visits() limit 1;
  reset role;

  if n < 1 then
    raise exception 'FAIL  9a. the school cannot see that it was visited';
  end if;
  if coalesce(v_reason, '') = '' then
    raise exception 'FAIL  9b. the visit has no reason recorded';
  end if;

  -- Beta was never entered, so Beta must see nothing. A per-school log that
  -- showed every school's visits would be worse than no log.
  perform set_config('test.uid', (select v::text from _sup where k='b_owner'), false);
  set local role authenticated;
  select count(*) into v_other from public.fn_support_visits();
  reset role;
  if v_other <> 0 then
    raise exception 'FAIL  9c. a school can see support visits made to ANOTHER school (%)', v_other;
  end if;
  raise notice 'PASS  9. the school reads its own visits ("%"), and no other school''s', v_reason;
end $school_view$;

-- --- 10. Every entry and exit is logged ----------------------------------------
do $logged$
declare v_in bigint; v_out bigint;
begin
  select count(*) into v_in from public.operator_actions
   where action = 'school_entered' and school_id = (select v from _sup where k='a_school');
  select count(*) into v_out from public.operator_actions
   where action = 'school_left' and school_id = (select v from _sup where k='a_school');
  if v_in < 1 then
    raise exception 'FAIL  10a. entering a school was not logged';
  end if;
  if v_out < 1 then
    raise exception 'FAIL  10b. leaving a school was not logged';
  end if;
  if not exists (
    select 1 from public.operator_actions
     where action = 'school_entered' and detail->>'reason' is not null) then
    raise exception 'FAIL  10c. the logged entry carries no reason';
  end if;
  raise notice 'PASS  10. entering and leaving are both logged, with the reason';
end $logged$;

select 'OPERATOR SUPPORT: ALL TESTS PASSED' as result;

rollback;
