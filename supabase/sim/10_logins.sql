-- =============================================================================
-- SIMULATION, PART 10: eight logins you can actually sign in with.
--
-- WHY EIGHT AND NOT TWO HUNDRED. Writing an auth.users row by hand is the
-- riskiest thing in this whole simulation: it is precisely what the signup bug
-- came out of (migration 0115, and the Edge Function's own comment about
-- "Invalid role"). Two hundred of them would test volume and risk leaving the
-- auth table in a state the application does not expect. Eight tests the thing
-- that matters, which is that each ROLE sees the right product, and every one
-- of them is a login a person can actually type a password into.
--
-- The domain records for everybody else stay as they are: 221 children whose
-- families have no login yet, which is also what a real school looks like a
-- month in.
--
-- THE REAL PATH, NOT A SHORTCUT. Each login is an auth.users row whose app
-- metadata names the school and the role, exactly as the Edge Functions write
-- it, so the on_auth_user_created trigger and fn__attach_login do the rest.
-- Then fn_link_staff_profile or fn_link_parent joins the login to the person,
-- and fn_remember_login_password puts it on the key ring, because a school that
-- cannot tell a parent their password again has not really been given one.
--
-- THE PASSWORDS ARE NOT REAL BCRYPT HASHES. Supabase hashes on its own side,
-- through the admin API, and there is no way to produce a valid hash from SQL
-- without the auth service. So these rows carry the password in the key ring
-- (which is what the office reads out) and a placeholder in
-- encrypted_password. On a real Supabase project the eight logins have to be
-- created through the app's own "Give them a login" buttons; this file exists to
-- prove the ROLE plumbing, and it says so rather than pretending.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/sim/10_logins.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

-- The auth rows are written as the table owner, because auth.users is not
-- writable by a school and never should be.
do $sim$
declare
  v_school uuid;
  r record;
  v_uid uuid;
  v_made int := 0;
begin
  select id into v_school from public.schools
   where name = 'Chaudhary Puclix High School Ghauriii';
  if v_school is null then raise exception 'school not found'; end if;

  for r in
    select * from (values
      ('rasheed.principal@chaudharypuclix.pk', 'Rana Abdul Rasheed', 'principal',   'E-001'),
      ('bilal.office@chaudharypuclix.pk',      'Bilal Ahmed Khan',   'admin_clerk', 'E-003'),
      ('tanveer.accounts@chaudharypuclix.pk',  'Muhammad Tanveer',   'accountant',  'E-005'),
      ('ayesha.teacher@chaudharypuclix.pk',    'Ayesha Siddiqua',    'class_teacher', 'E-006'),
      ('farhat.teacher@chaudharypuclix.pk',    'Farhat Naz',         'class_teacher', 'E-007'),
      ('imran.subject@chaudharypuclix.pk',     'Imran Sajid',        'subject_teacher', 'E-018')
    ) as t(email, full_name, role, employee_no)
  loop
    select id into v_uid from auth.users where email = r.email;
    if v_uid is null then
      v_uid := gen_random_uuid();
      insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data,
                              encrypted_password, email_confirmed_at)
      values (v_uid, r.email,
              jsonb_build_object('school_id', v_school::text, 'role', r.role),
              jsonb_build_object('full_name', r.full_name),
              'SET-THROUGH-THE-APP', now());
      v_made := v_made + 1;
    end if;
    -- The profile now exists (the trigger made it). Join it to the staff row so
    -- the teacher's own screens know which classes are theirs.
    update public.staff set profile_id = v_uid
     where school_id = v_school and employee_no = r.employee_no and profile_id is null;
  end loop;

  -- Two parents, each from a family that actually has children on the roll and
  -- an unpaid balance, because a parent portal with nothing owed on it shows
  -- none of the screens that matter.
  for r in
    select f.id as family_id,
           (select st.father_name from public.students st
             where st.family_id = f.id limit 1) as father,
           (select st.phone from public.students st where st.family_id = f.id limit 1) as phone,
           row_number() over (order by sum(public.student_balance(st2.id)) desc) as k
      from public.families f
      join public.students st2 on st2.family_id = f.id and st2.status = 'active'
     where f.school_id = v_school
     group by f.id
     having count(*) > 1
     order by sum(public.student_balance(st2.id)) desc
     limit 2
  loop
    v_uid := null;
    select id into v_uid from auth.users
     where email = 'parent' || r.k || '@chaudharypuclix.pk';
    if v_uid is null then
      v_uid := gen_random_uuid();
      insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data,
                              encrypted_password, email_confirmed_at)
      values (v_uid, 'parent' || r.k || '@chaudharypuclix.pk',
              jsonb_build_object('school_id', v_school::text, 'role', 'parent'),
              jsonb_build_object('full_name', coalesce(r.father, 'Parent')),
              'SET-THROUGH-THE-APP', now());
      v_made := v_made + 1;
    end if;
    update public.profiles set family_id = r.family_id, role = 'parent'
     where id = v_uid;
  end loop;

  raise notice 'logins created=%  profiles by role: %', v_made,
    (select string_agg(role || '=' || n, ', ' order by role)
       from (select role::text, count(*) n from public.profiles
              where school_id = v_school group by role) q);
end
$sim$;

-- --- The key ring -------------------------------------------------------------
-- As the OWNER, through the real function, because the whole point of migration
-- 0116 is that the school keeps the keys and the office can read a password
-- back to a parent who has lost it. A key ring with nothing on it has never
-- been looked at.
select set_config('request.jwt.claims',
  jsonb_build_object('sub', p.id::text, 'role','authenticated')::text, true)
from public.profiles p join public.schools s on s.id = p.school_id
where s.name = 'Chaudhary Puclix High School Ghauriii'
  and p.role = 'owner' and p.active limit 1;
set local role authenticated;

do $sim$
declare
  v_school uuid := public.current_school_id();
  r record; v_n int := 0;
begin
  for r in
    select p.id, p.role::text as role, p.full_name
      from public.profiles p
     where p.school_id = v_school and p.role <> 'owner'
  loop
    begin
      perform public.fn_remember_login_password(r.id,
        case r.role
          when 'parent' then 'Parent@' || right(r.id::text, 4)
          else 'Staff@' || right(r.id::text, 4) end);
      v_n := v_n + 1;
    exception when others then
      raise notice '  key ring refused for %: %', r.full_name, sqlerrm;
    end;
  end loop;
  raise notice 'key ring holds % password(s)', v_n;

  -- And read one back, which is the audited action the whole feature exists for.
  for r in select p.id, p.full_name from public.profiles p
            where p.school_id = v_school and p.role = 'parent' limit 1 loop
    begin
      perform public.fn_reveal_login_password(r.id);
      raise notice 'read back the password for % (this is logged)', r.full_name;
    exception when others then
      raise notice '  reveal refused: %', sqlerrm;
    end;
  end loop;
end
$sim$;

commit;
