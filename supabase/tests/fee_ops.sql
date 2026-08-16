-- =============================================================================
-- Fee operations: effective-dated amounts, the annual raise, scannable challans.
--
-- Rules defended here:
--  1. Billing uses the amount IN FORCE for the month being billed, so a raise
--     dated 1 April does not retroactively change March.
--  2. fn_fee_increment previews without writing, and commits exactly what it
--     previewed — the preview and the raise share one amount function, so they
--     cannot disagree.
--  3. A raise never edits the old amount; last year's structure stays readable.
--  4. Every invoice gets a unique scannable code, and scanning one child's
--     challan resolves to the whole FAMILY.
--  5. Head-wise dues add up to the invoiced total.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/fee_ops.sql
-- =============================================================================

\set ON_ERROR_STOP on

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create table if not exists public._fo (k text primary key, v uuid);

do $seed$
declare
  v_school uuid; v_owner uuid := '00000000-0000-0000-0000-00000000f001';
  v_sess uuid; v_class uuid; v_sec uuid; v_head uuid; v_fam uuid; v_stu uuid;
begin
  perform set_config('test.uid', '', false);
  delete from public.schools where name = 'FeeOps Test School';
  insert into public.schools (name) values ('FeeOps Test School') returning id into v_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'starter', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_owner, 'f1@feeops.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_owner, 'FeeOps Owner', 'owner', v_school)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_owner::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_school) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Class 1', 1, v_school) returning id into v_class;
  insert into public.sections (class_id, name, school_id)
    values (v_class, 'A', v_school) returning id into v_sec;
  insert into public.fee_heads (name, type, is_recurring, active, school_id)
    values ('Tuition', 'monthly', true, true, v_school) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_class, v_head, 1000, v_school);

  insert into public.families (school_id, head_name) values (v_school, 'FeeOps Payer')
    returning id into v_fam;
  insert into public.students (full_name, status, school_id, family_id)
    values ('FeeOps Child', 'active', v_school, v_fam) returning id into v_stu;
  insert into public.enrollments (student_id, session_id, class_id, section_id, status, school_id)
    values (v_stu, v_sess, v_class, v_sec, 'active', v_school);

  insert into public._fo(k,v) values ('sess',v_sess),('class',v_class),('head',v_head),
                                     ('fam',v_fam),('stu',v_stu)
    on conflict (k) do update set v = excluded.v;
  raise notice 'fixture ok';
end $seed$;

-- 1. Preview does not write
do $t$
declare j jsonb; v_before integer; v_after integer;
begin
  select count(*) into v_before from public.fee_structures;
  j := public.fn_fee_increment(
    (select v from public._fo where k='sess'), null, null, 20, null, date '2026-04-01', false);
  select count(*) into v_after from public.fee_structures;

  if v_after <> v_before then raise exception 'FAIL: preview wrote rows'; end if;
  if (j->>'committed')::boolean then raise exception 'FAIL: preview reported committed'; end if;
  if (j->'rows'->0->>'from')::numeric <> 1000 then
    raise exception 'FAIL: preview from-amount wrong: %', j;
  end if;
  if (j->'rows'->0->>'to')::numeric <> 1200 then
    raise exception 'FAIL: 20%% of 1000 should be 1200, got %', j->'rows'->0->>'to';
  end if;
  raise notice '1. preview does not write, and computes correctly — ok';
end $t$;

-- 2. Commit writes a NEW row and leaves the old amount intact
do $t$
declare j jsonb; v_old numeric; v_new numeric;
begin
  j := public.fn_fee_increment(
    (select v from public._fo where k='sess'), null, null, 20, null, date '2026-04-01', true);
  if not (j->>'committed')::boolean then raise exception 'FAIL: commit not reported'; end if;

  v_old := public.fn_fee_amount((select v from public._fo where k='sess'),
                                (select v from public._fo where k='class'),
                                (select v from public._fo where k='head'), date '2026-03-01');
  v_new := public.fn_fee_amount((select v from public._fo where k='sess'),
                                (select v from public._fo where k='class'),
                                (select v from public._fo where k='head'), date '2026-04-01');
  if v_old <> 1000 then raise exception 'FAIL: March amount changed to %', v_old; end if;
  if v_new <> 1200 then raise exception 'FAIL: April amount is %, expected 1200', v_new; end if;
  raise notice '2. raise adds a row, old amount survives — ok';
end $t$;

-- 3. Billing uses the amount in force for the billed month
do $t$
declare v_sess uuid; v_class uuid; v_stu uuid; v_mar numeric; v_apr numeric;
begin
  select v into v_sess  from public._fo where k='sess';
  select v into v_class from public._fo where k='class';
  select v into v_stu   from public._fo where k='stu';

  perform public.fn_generate_class_invoices(v_sess, v_class, date '2026-03-01', date '2026-03-10');
  perform public.fn_generate_class_invoices(v_sess, v_class, date '2026-04-01', date '2026-04-10');

  select sum(l.amount) into v_mar from public.invoice_lines l
    join public.invoices i on i.id = l.invoice_id
   where i.student_id = v_stu and i.period_month = date '2026-03-01' and not l.is_discount;
  select sum(l.amount) into v_apr from public.invoice_lines l
    join public.invoices i on i.id = l.invoice_id
   where i.student_id = v_stu and i.period_month = date '2026-04-01' and not l.is_discount;

  if v_mar <> 1000 then raise exception 'FAIL: March billed % (raise leaked backwards)', v_mar; end if;
  if v_apr <> 1200 then raise exception 'FAIL: April billed %, expected 1200', v_apr; end if;
  raise notice '3. billing honours the effective date — ok';
end $t$;

-- 4. Percent and flat amount are mutually exclusive
do $t$
declare v_ok boolean;
begin
  v_ok := false;
  begin
    perform public.fn_fee_increment((select v from public._fo where k='sess'),
                                    null, null, 10, 500, date '2026-05-01', false);
    v_ok := true;
  exception when others then null; end;
  if v_ok then raise exception 'FAIL: accepted both a percent AND a flat amount'; end if;

  v_ok := false;
  begin
    perform public.fn_fee_increment((select v from public._fo where k='sess'),
                                    null, null, null, null, date '2026-05-01', false);
    v_ok := true;
  exception when others then null; end;
  if v_ok then raise exception 'FAIL: accepted neither a percent nor an amount'; end if;
  raise notice '4. percent xor flat amount enforced — ok';
end $t$;

-- 5. Only owner/principal may change fees
do $t$
declare v_clerk uuid := '00000000-0000-0000-0000-00000000f002'; v_ok boolean := false;
begin
  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_clerk, 'f2@feeops.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_clerk, 'FeeOps Clerk', 'admin_clerk',
            (select id from public.schools where name = 'FeeOps Test School'))
    on conflict (id) do update set role = excluded.role, school_id = excluded.school_id;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_clerk::text, false);
  begin
    perform public.fn_fee_increment((select v from public._fo where k='sess'),
                                    null, null, 50, null, date '2026-06-01', true);
    v_ok := true;
  exception when others then null; end;
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000f001', false);
  if v_ok then raise exception 'FAIL: a clerk raised the school fees'; end if;
  raise notice '5. fee changes are owner/principal only — ok';
end $t$;

-- 6. Every invoice is scannable, and a scan resolves to the FAMILY
do $t$
declare v_code text; j jsonb; v_dupes integer;
begin
  if exists (select 1 from public.invoices where voucher_code is null) then
    raise exception 'FAIL: an invoice has no voucher code';
  end if;
  select count(*) into v_dupes from (
    select school_id, voucher_code from public.invoices
    group by 1,2 having count(*) > 1) d;
  if v_dupes > 0 then raise exception 'FAIL: % duplicate voucher codes', v_dupes; end if;

  select voucher_code into v_code from public.invoices
   where student_id = (select v from public._fo where k='stu') limit 1;

  j := public.fn_find_by_voucher(v_code);
  if j is null then raise exception 'FAIL: a valid voucher code did not resolve'; end if;
  if (j->>'family_id')::uuid <> (select v from public._fo where k='fam') then
    raise exception 'FAIL: voucher resolved to the wrong family';
  end if;

  -- lower case and stray spaces must still work; a clerk retypes these by hand
  if public.fn_find_by_voucher('  ' || lower(v_code) || ' ') is null then
    raise exception 'FAIL: a hand-typed lowercase code did not resolve';
  end if;
  if public.fn_find_by_voucher('NOSUCH99') is not null then
    raise exception 'FAIL: an invented code resolved to something';
  end if;
  raise notice '6. challans are scannable and resolve to the family — ok';
end $t$;

-- 7. Head-wise dues reconcile with the invoiced total
do $t$
declare j jsonb; v_heads numeric; v_lines numeric;
begin
  j := public.fn_head_wise_dues((select v from public._fo where k='sess'));
  select coalesce(sum((h->>'charged')::numeric), 0) into v_heads
  from jsonb_array_elements(j->'heads') h;

  select coalesce(sum(case when l.is_discount then -l.amount else l.amount end), 0) into v_lines
  from public.invoice_lines l
  join public.invoices i on i.id = l.invoice_id
  where i.session_id = (select v from public._fo where k='sess') and i.status <> 'void';

  if v_heads <> v_lines then
    raise exception 'FAIL: head-wise total % <> invoiced total %', v_heads, v_lines;
  end if;
  if j->>'basis' is null then
    raise exception 'FAIL: the apportionment rule is not stated on the report';
  end if;
  raise notice '7. head-wise dues reconcile with invoices — ok';
end $t$;

-- 8. Cross-tenant
do $t$
declare v_other uuid; v_owner uuid := '00000000-0000-0000-0000-00000000f009'; v_ok boolean := false;
begin
  perform set_config('test.uid', '', false);
  delete from public.schools where name = 'Other FeeOps School';
  insert into public.schools (name) values ('Other FeeOps School') returning id into v_other;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_other, 'starter', 'active', current_date + 30);
  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_owner, 'f9@feeops.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_owner, 'Other FeeOps Owner', 'owner', v_other)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_owner::text, false);
  begin
    perform public.fn_fee_increment((select v from public._fo where k='sess'),
                                    null, null, 99, null, date '2026-07-01', true);
    v_ok := true;
  exception when others then null; end;
  if v_ok then raise exception 'FAIL: raised another school''s fees'; end if;

  if public.fn_find_by_voucher(
      (select voucher_code from public.invoices
       where student_id = (select v from public._fo where k='stu') limit 1)) is not null then
    raise exception 'FAIL: scanned another school''s challan';
  end if;
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000f001', false);
  raise notice '8. cross-tenant fee ops refused — ok';
end $t$;

drop table if exists public._fo;
do $$ begin raise notice 'ALL FEE OPS TESTS PASSED'; end $$;
