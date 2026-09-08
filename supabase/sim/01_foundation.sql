-- =============================================================================
-- SIMULATION, PART 1 OF N: the school as it was set up in February 2024.
--
-- WHAT THIS IS FOR, AND WHY IT IS NOT A FIXTURE
--
-- This is not test data in the usual sense. It is a two-year QA run against the
-- application's OWN write paths: every row below arrives through the same
-- function or the same insert the user interface uses, with a real signed-in
-- owner's session and Row Level Security switched on. Raw inserts would fill
-- the tables faster and prove nothing at all: fn_record_payment is what keeps
-- the ledger balanced, fn_close_till is what catches a till variance, and
-- fn_publish_results is what stops a parent seeing an unpublished mark. A seed
-- that bypasses them tests the shape of the schema and none of its behaviour.
--
-- HOW THE SESSION IS FAKED, AND WHY THIS EXACT WAY
--
-- Every one of those functions keys off auth.uid(), which on Supabase reads
-- request.jwt.claims: the GUC PostgREST sets on a real HTTP request. So this
-- file sets that GUC and nothing else. It does NOT redefine auth.uid(), which
-- is how supabase/tests/*.sql do it. That is correct for a test that runs in a
-- transaction on a throwaway database and catastrophic here: redefining
-- auth.uid() on a live project breaks every request from every real school for
-- as long as the definition stands.
--
-- IDEMPOTENT. Every insert is guarded. Running this file twice adds nothing and
-- raises nothing, because a paste that half-succeeded and cannot be repeated is
-- worse than one that fails outright.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/sim/01_foundation.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

-- --- Become the school's owner -----------------------------------------------
-- Looked up while still superuser, because profiles is behind RLS and the
-- context needed to read it is the thing being established.
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', p.id::text, 'role', 'authenticated')::text,
  true)
from public.profiles p
join public.schools s on s.id = p.school_id
where s.name = 'Chaudhary Puclix High School Ghauriii'
  and p.role = 'owner' and p.active
limit 1;

-- RLS applies from here down. If any statement below fails on a policy, that is
-- a finding about the application and not about this file.
set local role authenticated;

do $sim$
declare
  v_school uuid := public.current_school_id();
  v_sess_2324 uuid; v_sess_2425 uuid; v_sess_2526 uuid; v_sess_2627 uuid;
  v_class uuid;
  r record;
begin
  if v_school is null then
    raise exception 'No owner session. Is the school name exactly right?';
  end if;

  -- --- 1. School profile -----------------------------------------------------
  -- The screenshot that started this run showed every one of these fields
  -- empty, which is what a school looks like on day one and not what one looks
  -- like after two years of use.
  -- day_starts_at, the grace window and the geofence are set too. They are not
  -- cosmetic: they are what fn_staff_check_in judges a check-in against, so a
  -- school with them at their defaults never produces a "late" staff row and
  -- the lateness half of that feature would go untested.
  update public.school_settings set
    name_short         = 'CPHS Ghauri',
    principal_name     = 'Rana Abdul Rasheed',
    phone              = '051-4938271',
    email              = 'office@chaudharypuclix.pk',
    address            = 'Street 7, Ghauri Town Phase 3, Islamabad',
    grade_scale        = 'letter',
    pass_percent       = 33,
    gr_prefix          = 'GR-',
    receipt_prefix     = 'R-',
    day_starts_at      = time '07:45',
    day_ends_at        = time '13:30',
    late_grace_minutes = 10,
    geofence_enabled   = true,
    geo_lat            = 33.5651,
    geo_lng            = 73.1234,
    geo_radius_m       = 150
  where school_id = v_school;

  -- --- 2. Academic sessions --------------------------------------------------
  -- April to March, the Punjab private-school year. Four of them, because the
  -- school joined mid-2023-2024 and today is inside 2026-2027: three year-end
  -- rollovers happen inside this simulation, not the two originally asked for.
  insert into public.academic_sessions (name, starts_on, ends_on, is_current)
  select v.name, v.s, v.e, false
    from (values
      ('2023-2024', date '2023-04-01', date '2024-03-31'),
      ('2024-2025', date '2024-04-01', date '2025-03-31'),
      ('2025-2026', date '2025-04-01', date '2026-03-31'),
      ('2026-2027', date '2026-04-01', date '2027-03-31')
    ) as v(name, s, e)
   where not exists (select 1 from public.academic_sessions a
                      where a.school_id = v_school and a.name = v.name);

  select id into v_sess_2324 from public.academic_sessions
   where school_id = v_school and name = '2023-2024';
  select id into v_sess_2425 from public.academic_sessions
   where school_id = v_school and name = '2024-2025';
  select id into v_sess_2526 from public.academic_sessions
   where school_id = v_school and name = '2025-2026';
  select id into v_sess_2627 from public.academic_sessions
   where school_id = v_school and name = '2026-2027';

  -- The school starts the simulation in its 2023-2024 year. fn_rollover moves
  -- this forward three times in 04_the_years.sql, which is the point.
  --
  -- GUARDED, AND THIS FILE CLAIMED TO BE IDEMPOTENT WITHOUT IT. Every insert
  -- above is guarded by a `not exists`; this line is an UPDATE, and it was the
  -- one destructive statement in the file. Re-running it on a finished school
  -- rewound the current year from 2026-2027 to 2023-2024, so the dashboard,
  -- the register, the fee screens and the class lists all went blank: they read
  -- the current session, and the current session suddenly had nothing in it.
  -- Measured on the finished simulation, which is how this was found.
  --
  -- Anybody who re-runs a set of seven files "to be sure" would hit that, and
  -- would reasonably conclude the data had been lost when it was all still
  -- there. The guard is enrolments in a later year: on a first run there are
  -- none, and after 04_the_years.sql there are hundreds.
  if not exists (select 1 from public.enrollments e
                  where e.school_id = v_school
                    and e.session_id is distinct from v_sess_2324) then
    update public.academic_sessions set is_current = (id = v_sess_2324)
     where school_id = v_school;
  else
    raise notice 'this school has already been rolled past 2023-2024, so the '
      'current session is left as it is';
  end if;

  -- --- 3. Classes ------------------------------------------------------------
  -- Nursery to Class 10: a high school, which is what the name says. level_order
  -- is what the rollover walks up, so it has to be right or promotion sends
  -- Class 9 into Nursery.
  insert into public.classes (name, level_order, active)
  select v.name, v.lvl, true
    from (values
      ('Nursery', 1), ('Prep', 2), ('Class 1', 3), ('Class 2', 4),
      ('Class 3', 5), ('Class 4', 6), ('Class 5', 7), ('Class 6', 8),
      ('Class 7', 9), ('Class 8', 10), ('Class 9', 11), ('Class 10', 12)
    ) as v(name, lvl)
   where not exists (select 1 from public.classes c
                      where c.school_id = v_school and c.name = v.name);

  -- --- 4. Sections -----------------------------------------------------------
  -- Every class gets A. Classes 1 to 5 get a B as well, because the primary
  -- years are where the numbers actually are in a school of this size. Two
  -- sections in one class is also the case that catches a roster query which
  -- silently assumes one.
  for r in select id, name, level_order from public.classes
            where school_id = v_school order by level_order loop
    insert into public.sections (class_id, name, sort_order)
    select r.id, 'A', 1
     where not exists (select 1 from public.sections s
                        where s.class_id = r.id and s.name = 'A');
    if r.level_order between 3 and 7 then
      insert into public.sections (class_id, name, sort_order)
      select r.id, 'B', 2
       where not exists (select 1 from public.sections s
                          where s.class_id = r.id and s.name = 'B');
    end if;
  end loop;

  -- --- 5. Subjects -----------------------------------------------------------
  -- Per class, because that is how the table is keyed. The senior classes get
  -- the extra papers, which is what makes a result card for Class 9 different
  -- in shape from one for Prep and therefore worth testing separately.
  for r in select id, name, level_order from public.classes
            where school_id = v_school order by level_order loop
    insert into public.subjects (name, class_id, sort_order)
    select v.name, r.id, v.ord
      from (values
        ('English', 1), ('Urdu', 2), ('Mathematics', 3), ('Islamiat', 4)
      ) as v(name, ord)
     where not exists (select 1 from public.subjects s
                        where s.class_id = r.id and s.name = v.name);
    if r.level_order >= 5 then
      insert into public.subjects (name, class_id, sort_order)
      select v.name, r.id, v.ord
        from (values ('Science', 5), ('Social Studies', 6), ('Computer', 7)) as v(name, ord)
       where not exists (select 1 from public.subjects s
                          where s.class_id = r.id and s.name = v.name);
    end if;
    if r.level_order >= 11 then
      insert into public.subjects (name, class_id, sort_order)
      select v.name, r.id, v.ord
        from (values ('Physics', 8), ('Chemistry', 9), ('Biology', 10), ('Pak Studies', 11)) as v(name, ord)
       where not exists (select 1 from public.subjects s
                          where s.class_id = r.id and s.name = v.name);
      -- Science subjects replaced by the real papers at this level.
      delete from public.subjects
       where class_id = r.id and name in ('Science', 'Social Studies');
    end if;
  end loop;

  raise notice 'sessions=% classes=% sections=% subjects=%',
    (select count(*) from public.academic_sessions where school_id = v_school),
    (select count(*) from public.classes where school_id = v_school),
    (select count(*) from public.sections s join public.classes c on c.id = s.class_id
      where c.school_id = v_school),
    (select count(*) from public.subjects s join public.classes c on c.id = s.class_id
      where c.school_id = v_school);
end
$sim$;

commit;
