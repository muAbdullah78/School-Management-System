-- =============================================================================
-- Which login is which: prove the invisible ones become visible, and that
-- nobody who should not see them can.
--
-- The bug this closes: the staff roster reads the staff table, so a login never
-- attached to a staff record appeared on NO screen. It existed, it worked, it
-- could read every child's record, and creating one left the roster still
-- saying "No staff yet" — which looks exactly like failure. That is what the
-- first real school saw.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/logins.sql
-- =============================================================================
\set ON_ERROR_STOP on
begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create temp table ids (k text primary key, v uuid);

do $seed$
declare
  s1 uuid := gen_random_uuid(); s2 uuid := gen_random_uuid();
  own uuid := '00000000-0000-0000-0000-0000000f0001';
  clk uuid := '00000000-0000-0000-0000-0000000f0002';
  orphan uuid := '00000000-0000-0000-0000-0000000f0003';
  par uuid := '00000000-0000-0000-0000-0000000f0004';
  own2 uuid := '00000000-0000-0000-0000-0000000f0005';
  st uuid; fam uuid;
begin
  insert into public.schools (id, name, city) values
    (s1, 'Al Qalam Public School', 'Islamabad'), (s2, 'Elsewhere School', 'Karachi');
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on) values
    (s1, 'starter', 'active', current_date + 14), (s2, 'starter', 'active', current_date + 14);

  insert into auth.users (id, email) values
    (own, 'owner@alqalam.test'), (clk, 'clerk@alqalam.test'),
    (orphan, 'newteacher@alqalam.test'), (par, 'parent@alqalam.test'),
    (own2, 'owner@elsewhere.test')
    on conflict (id) do nothing;

  insert into public.families (school_id, head_name) values (s1, 'A Family') returning id into fam;

  alter table public.profiles disable trigger user;
  insert into public.profiles (id, school_id, full_name, role, family_id) values
    (own,  s1, 'The Owner',  'owner', null),
    (clk,  s1, 'The Clerk',  'admin_clerk', null),
    -- The one the roster could never show: a login with no staff row.
    (orphan, s1, 'New Teacher', 'class_teacher', null),
    (par,  s1, 'A Parent',   'parent', fam),
    (own2, s2, 'Other Owner','owner', null);
  alter table public.profiles enable trigger user;

  insert into public.staff (school_id, full_name, designation, profile_id)
    values (s1, 'The Clerk', 'Office', clk) returning id into st;

  insert into ids values ('s1', s1), ('own', own), ('clk', clk),
                         ('orphan', orphan), ('par', par), ('own2', own2);
end $seed$;

do $visible$
declare n int; e text; sid uuid;
begin
  perform set_config('test.uid', (select v::text from ids where k='own'), false);

  -- THE POINT: a login with no staff record must appear.
  select count(*) into n from public.fn_school_logins()
   where profile_id = (select v from ids where k='orphan');
  if n <> 1 then
    raise exception 'FAIL: a login with no staff record is still invisible. That is '
                    'the bug: it can sign in and read every child, and no screen shows it.';
  end if;

  select email, staff_id into e, sid from public.fn_school_logins()
   where profile_id = (select v from ids where k='orphan');
  if e <> 'newteacher@alqalam.test' then
    raise exception 'FAIL: the address is wrong or missing: %', e;
  end if;
  if sid is not null then
    raise exception 'FAIL: an unattached login is reported as attached';
  end if;

  -- The attached one carries its person.
  select staff_name into e from public.fn_school_logins()
   where profile_id = (select v from ids where k='clk');
  if e <> 'The Clerk' then raise exception 'FAIL: attached login lost its person: %', e; end if;

  -- Unattached first, because that is the work list.
  if (select profile_id from public.fn_school_logins() limit 1)
     <> (select v from ids where k='orphan') then
    raise exception 'FAIL: the unattached login is not listed first';
  end if;

  -- Parents are not staff and must not pad this list.
  select count(*) into n from public.fn_school_logins()
   where profile_id = (select v from ids where k='par');
  if n <> 0 then raise exception 'FAIL: a parent appears on the staff login list'; end if;

  -- Another school's logins are not ours.
  select count(*) into n from public.fn_school_logins()
   where profile_id = (select v from ids where k='own2');
  if n <> 0 then raise exception 'FAIL: another school''s login is listed'; end if;

  raise notice 'ok: unattached logins are visible, with their address, scoped to the school';
end $visible$;

do $guard$
declare ok boolean;
begin
  -- A clerk may not enumerate logins, and a PARENT certainly may not: this
  -- function reads auth.users, so a leak here is every staff email in the school.
  for i in 1 .. 2 loop
    perform set_config('test.uid',
      (select v::text from ids where k = case i when 1 then 'clk' else 'par' end), false);
    ok := false;
    begin
      perform * from public.fn_school_logins();
    exception when others then ok := true;
    end;
    if not ok then
      raise exception 'FAIL: % could read every login, and therefore every staff email',
        case i when 1 then 'a clerk' else 'a parent' end;
    end if;
  end loop;
  raise notice 'ok: neither a clerk nor a parent can enumerate logins';
end $guard$;

-- =============================================================================
-- A parent login that belongs to no family is on SOME screen
--
-- 0095 fixed this shape for staff and excluded parents, with a good reason
-- written on the line: four hundred linked parents would bury the staff roster.
-- That reason covers a LINKED parent and it hid the broken ones with them.
--
-- Measured on the running code before 0104, with a login whose family link was
-- never written:
--
--     Who can sign in            0 rows
--     the family page            0 rows
--     public.profiles            1 row
--     the parent's own portal    {"children": [], "full_name": "Unlinked Parent"}
--
-- The parent sits at home looking at their own name above an empty page, the
-- office has no screen that shows the login exists, and the only remedy anyone
-- finds is to create a second login for the same address, which fails because
-- the address is taken. There is no way out of that state from inside the
-- product.
--
-- Reachable by an ordinary failure: createParentLogin creates the login and then
-- links it, in two awaits.
-- =============================================================================
do $t$
declare
  v_school uuid; v_orphan uuid := '00000000-0000-0000-0000-0000000000fa';
  v_linked uuid := '00000000-0000-0000-0000-0000000000fb';
  v_fam uuid; v_n int;
begin
  -- Back to the owner. The block above deliberately leaves test.uid as a parent
  -- to prove a parent cannot enumerate logins, and picking that up here would
  -- fail on the permission gate rather than on anything this block is about.
  perform set_config('test.uid', (select v::text from ids where k = 'own'), false);
  select p.school_id into v_school from public.profiles p
   where p.id = (select v from ids where k = 'own');

  select id into v_fam from public.families where school_id = v_school limit 1;
  if v_fam is null then
    insert into public.families (school_id, head_name) values (v_school, 'Logins Family')
    returning id into v_fam;
  end if;

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_orphan, 'orphan.parent@logins.test'),
    (v_linked, 'linked.parent@logins.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_orphan, 'Unlinked Parent', 'parent', v_school),
    (v_linked, 'Linked Parent',   'parent', v_school)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;
  perform public.fn_link_parent(v_linked, v_fam);

  -- The broken one is listed.
  select count(*) into v_n from public.fn_school_logins() l
   where l.email = 'orphan.parent@logins.test';
  if v_n <> 1 then
    raise exception 'FAIL: a parent login belonging to no family is on no screen. '
                    'They can sign in and see an empty portal with their own name '
                    'on it, and the office has nothing to look at.';
  end if;

  -- And 0095's reason still holds: the LINKED one stays out of the staff roster.
  select count(*) into v_n from public.fn_school_logins() l
   where l.email = 'linked.parent@logins.test';
  if v_n <> 0 then
    raise exception 'FAIL: a parent WITH a family is in the staff roster. Four '
                    'hundred of them would bury it, and they are already listed '
                    'on their own family page.';
  end if;

  raise notice 'ok: a parent login with no family is visible, one with a family is not';
end $t$;

rollback;
