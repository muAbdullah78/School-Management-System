-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0143_a_roll_number_you_can_see_and_a_portal_that_makes_itself.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0143  A roll number you can see, and a portal that makes itself
--
-- THREE THINGS 0142 GOT WRONG BY LEAVING THEM TO THE CLERK.
--
-- 1. THE GRID OPENED ON AN EMPTY BOX AND SAID NOTHING ABOUT THE CLASS. Class 1
--    (A) might already hold twenty-three children on rolls 1 to 23, and the
--    screen showed a blank column and let the clerk type 1 again. Nothing in the
--    schema forbids two children on roll 1, so there is no error to catch it:
--    the register just quietly has two number ones in it, and the school finds
--    out when a result card is handed to the wrong child. fn_section_roll_state
--    answers what is taken, so the screen can fill the column in before anybody
--    types.
--
-- 2. EVERY FAMILY NEEDED A LOGIN MADE BY HAND, one press at a time, on the
--    student's own page. That is fine for the child who joins in March and
--    hopeless for the four hundred who arrive on the first afternoon, which is
--    the whole case rapid entry exists for. The credential rule lives here, in
--    SQL, for the same reason the draft rule does: two implementations of
--    "what is this family's login" is two answers, and the second one locks a
--    parent out.
--
-- 3. ONE PORTAL PER FAMILY, NOT PER CHILD. Two brothers entered in the same
--    grid resolve to one family (0036 does that), so they must resolve to one
--    login. Keyed on the child, the second brother would either fail on a
--    duplicate address or quietly create a second account showing half the
--    family. Keyed on the family, the second brother finds the login the first
--    one made and is simply already inside it.
--
-- THE ADDRESS IS SANITISED HERE AND NOT IN THE BROWSER. "Muhammad Ali" with a
-- phone of "0333 123 4567" has to become muhammadali03331234567@gmail.com or
-- the auth service refuses it, and a refusal at that point has already admitted
-- the child. Lowercased, every character that is not a-z or 0-9 removed, and
-- bounded in length. A name written in Urdu script leaves nothing behind at all,
-- so the GR number is the fallback, and a family with neither is given a stable
-- string built from their own id rather than something random, so running this
-- twice produces the same address rather than two accounts.
-- =============================================================================

-- ============================================== 1. what the section holds ====
-- WHY ROLLS ARE READ AS INTEGERS. Nothing makes roll_no numeric: a school may
-- write "1", "01", "A-1" or "Roll 7". The next free number is only meaningful
-- for the numeric ones, so the digits are pulled out and anything with no digits
-- at all is reported separately rather than silently counted as zero.
create or replace function public.fn_section_roll_state(
  p_session_id uuid, p_class_id uuid, p_section_id uuid default null
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_taken integer[];
  v_n     integer;
  v_other integer;
begin
  if not public.may_view('owner','principal','class_teacher','subject_teacher','readonly') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);
  perform public.assert_own('sections', p_section_id);

  select count(*),
         coalesce(array_agg(distinct n order by n)
                    filter (where n is not null), '{}'::integer[]),
         count(*) filter (where n is null)
    into v_n, v_taken, v_other
    from (
      select nullif(regexp_replace(coalesce(e.roll_no, ''), '[^0-9]', '', 'g'), '')::integer as n
        from public.enrollments e
        join public.students s on s.id = e.student_id
       where e.session_id = p_session_id
         and e.class_id = p_class_id
         and e.section_id is not distinct from p_section_id
         and e.status = 'active'
         and s.deleted_at is null
    ) q;

  return jsonb_build_object(
    'on_roll', coalesce(v_n, 0),
    'taken', to_jsonb(v_taken),
    -- Rolls with no digits in them: "A-1", or blank. Counted so the screen can
    -- say the next free number is a suggestion rather than a guarantee.
    'unnumbered', coalesce(v_other, 0),
    'next_free', (select coalesce(max(t), 0) + 1 from unnest(v_taken) t));
end;
$$;
revoke all on function public.fn_section_roll_state(uuid, uuid, uuid) from public, anon;
grant execute on function public.fn_section_roll_state(uuid, uuid, uuid) to authenticated;

-- ======================================= 2. the credential, defined once =====
-- Pure text, no reads, so it can be tested on its own and cannot differ between
-- the screen that shows it and the code that creates it.
create or replace function public.fn__portal_email(p_name text, p_number text)
returns text language sql immutable set search_path = public as $$
  -- BOTH PARTS ARE REQUIRED, and the number is the one that matters. The first
  -- draft returned an address as soon as ANYTHING survived, so a family called
  -- Hamza with no phone number on file got hamza@gmail.com: an address that is
  -- certainly taken somewhere on the platform already, and that the next family
  -- called Hamza would collide with. The number is what makes it theirs, so
  -- without one this answers nothing and the caller falls through to the GR
  -- number and then to the family's own id.
  select case
           when coalesce(a.name_part, '') = '' or coalesce(a.num_part, '') = '' then null
           else left(a.name_part, 30) || left(a.num_part, 30) || '@gmail.com'
         end
    from (
      select
        -- The FIRST word of the name only: a login is typed by a parent on a
        -- phone, and "muhammadalikhanabbasi0333..." is not.
        regexp_replace(lower(coalesce(split_part(btrim(coalesce(p_name, '')), ' ', 1), '')),
                       '[^a-z0-9]', '', 'g') as name_part,
        regexp_replace(lower(coalesce(p_number, '')), '[^a-z0-9]', '', 'g') as num_part
    ) a
$$;
revoke all on function public.fn__portal_email(text, text) from public, anon, authenticated;

comment on function public.fn__portal_email(text, text) is
  'The parent portal address, sanitised. Lowercased, stripped to a-z0-9, first '
  'name only, bounded at 60 characters before the domain. Returns NULL when '
  'nothing survives, which is a real case: a name written in Urdu script with no '
  'phone number leaves an empty string, and "@gmail.com" is not an address.';

-- ============================== 3. which families still need one, and what ===
-- GIVEN THE CHILDREN JUST ENTERED, one row per FAMILY that has no parent login.
--
-- The dedupe is on the family and not on the address, and that ordering matters.
-- Two brothers typed into the same grid share a family by the time this runs, so
-- asking "which families are without a login" answers the sibling question by
-- construction. Asking "which addresses are free" would have produced two rows
-- for one house and a second account nobody wants.
--
-- THE PASSWORD IS THE NUMBER, as the vendor asked. That is a deliberate trade:
-- it is guessable by anybody who knows the family's phone number, and it is the
-- only thing a parent with one shared handset will remember. The portal shows
-- fees, attendance and marks for one family and can write nothing, so the blast
-- radius is a neighbour reading a report card. It is written down on the key
-- ring (0116) so the office can change it for any family that asks.
create or replace function public.fn_portal_targets(p_student_ids uuid[])
returns table(
  family_id uuid, head_name text, student_id uuid, student_name text,
  gr_no text, number text, email text, password text
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal can create parent logins'
      using errcode = '42501';
  end if;

  return query
  with mine as (
    select s.*
      from public.students s
     where s.school_id = v_school
       and s.id = any(coalesce(p_student_ids, '{}'::uuid[]))
       and s.deleted_at is null
  ),
  -- ONE CHILD PER FAMILY, the first by name, and it is only used to BUILD the
  -- address. The login belongs to the family whichever child produced it.
  pick as (
    select distinct on (m.family_id)
           m.family_id, m.id as student_id, m.full_name, m.gr_no,
           coalesce(nullif(btrim(coalesce(m.whatsapp, '')), ''),
                    nullif(btrim(coalesce(m.phone, '')), '')) as number
      from mine m
     where m.family_id is not null
     order by m.family_id, m.full_name, m.id
  )
  select p.family_id,
         coalesce(f.head_name, p.full_name),
         p.student_id,
         p.full_name,
         p.gr_no,
         p.number,
         -- THE FALLBACK CHAIN, and every step of it has to produce something a
         -- mail server would accept.
         --   the parent's number   the case this was designed for
         --   the GR number         a clerk in a hurry left the phone blank
         --   the family's own id   neither, and it must still be STABLE: a
         --                         random suffix would make a second account
         --                         every time somebody pressed the button again
         coalesce(
           public.fn__portal_email(coalesce(f.head_name, p.full_name), p.number),
           public.fn__portal_email(coalesce(f.head_name, p.full_name), p.gr_no),
           'family' || replace(p.family_id::text, '-', '') || '@gmail.com'),
         -- AT LEAST SIX CHARACTERS, because auth refuses anything shorter and a
         -- refusal here happens AFTER the child has been admitted. A GR number
         -- of "0002" is four, so the family's own id pads it out. The parent is
         -- still told their phone number when they have one, which is the case
         -- this was built for.
         (select case when length(raw) >= 6 then raw
                      else raw || left(replace(p.family_id::text, '-', ''), 6 - length(raw))
                 end
            from (select coalesce(
                    nullif(regexp_replace(coalesce(p.number, ''), '[^0-9]', '', 'g'), ''),
                    nullif(regexp_replace(coalesce(p.gr_no, ''), '[^a-zA-Z0-9]', '', 'g'), ''),
                    left(replace(p.family_id::text, '-', ''), 12)) as raw) r)
    from pick p
    left join public.families f on f.id = p.family_id
   -- ALREADY HAS ONE: say nothing. A sibling arriving in March must not make a
   -- second login for a house that has had one since June.
   where not exists (
     select 1 from public.profiles pr
      where pr.family_id = p.family_id
        and pr.role = 'parent'
        and pr.active
        and pr.school_id = v_school);
end;
$$;
revoke all on function public.fn_portal_targets(uuid[]) from public, anon;
grant execute on function public.fn_portal_targets(uuid[]) to authenticated;

-- ============================================ 4. linking a batch in one call =
-- fn_link_parent one profile at a time is four hundred round trips on the
-- afternoon this exists for. Same checks, same refusals, one call.
create or replace function public.fn_link_parents(p_pairs jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_row jsonb;
  v_n   integer := 0;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may link a parent account'
      using errcode = '42501';
  end if;
  if p_pairs is null or jsonb_typeof(p_pairs) <> 'array' then return 0; end if;

  for v_row in select * from jsonb_array_elements(p_pairs) loop
    -- Per-row exception block, for the reason 0142 gives at length: one login
    -- that could not be attached must not throw away the ninety-nine that could.
    begin
      -- A LOGIN ALREADY BELONGING TO ANOTHER FAMILY IS NEVER MOVED, and this is
      -- the hole the batch path opens that the one-at-a-time path does not.
      --
      -- The address is built from the father's name and phone number. Two
      -- unrelated families whose father is called Rashid, with the same number
      -- mistyped onto both, produce the same address. The first creates the
      -- login; the second is told "already registered", the Edge Function finds
      -- it in this school and hands it back as `existed`, and an unguarded link
      -- would point it at the SECOND family. The first family would silently
      -- lose their portal to somebody else's house.
      --
      -- fn_link_parent keeps its own behaviour: an office deliberately
      -- re-attaching one login from the family sheet is a decision with a
      -- person behind it. This is the automatic path, where there is not.
      -- SCOPED TO THIS SCHOOL. RLS does not apply inside a SECURITY DEFINER
      -- function, so an unscoped read here could see another school's profile
      -- and decide this school's link from it. supabase/tests/dashboard.sql
      -- assertion 20 sweeps for exactly this and found it.
      if exists (
        select 1 from public.profiles pr
         where pr.id = (v_row->>'profile_id')::uuid
           and pr.school_id = public.current_school_id()
           and pr.family_id is not null
           and pr.family_id <> (v_row->>'family_id')::uuid
      ) then
        continue;
      end if;
      perform public.fn_link_parent(
        (v_row->>'profile_id')::uuid, (v_row->>'family_id')::uuid);
      v_n := v_n + 1;
    exception when others then
      null;
    end;
  end loop;
  return v_n;
end;
$$;
revoke all on function public.fn_link_parents(jsonb) from public, anon;
grant execute on function public.fn_link_parents(jsonb) to authenticated;

-- ======================================== 5. the key ring, a batch at a time =
-- Same reason as fn_link_parents: four hundred families is four hundred round
-- trips, and the key ring is the only way back in for an address the office
-- invented, so it must not be the thing that is skipped because it is slow.
--
-- SWALLOWS PER ROW ON PURPOSE. A school that has not applied bundle 22 has no
-- key ring at all, and reporting that as a failed login would send the office
-- round the retry loop that ends in "already registered". The count comes back
-- so the screen can say plainly whether the passwords were kept.
create or replace function public.fn_remember_login_passwords(p_rows jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare v_row jsonb; v_n integer := 0;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal can keep login passwords'
      using errcode = '42501';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then return 0; end if;
  for v_row in select * from jsonb_array_elements(p_rows) loop
    begin
      perform public.fn_remember_login_password(
        (v_row->>'profile_id')::uuid, v_row->>'password');
      v_n := v_n + 1;
    exception when others then
      null;
    end;
  end loop;
  return v_n;
end;
$$;
revoke all on function public.fn_remember_login_passwords(jsonb) from public, anon;
grant execute on function public.fn_remember_login_passwords(jsonb) to authenticated;

-- ================== 6. the draft flag, proved against the real function names =
-- 0142 added a verify row asserting that nothing in the schema reads is_draft to
-- decide whether a child is billed, registered or examined. It named
-- `fn_get_roster`, WHICH DOES NOT EXIST. A probe that names a missing function
-- checks nothing at all and reads exactly like a probe that passes, which is the
-- failure supabase/tests/removed_features.sql was written about.
--
-- Nothing to create here: the correction is in verify.sql, and this comment is
-- where somebody looking for it will be. The real names are fn_section_roster,
-- fn_subject_roster, fn_attendance_day, fn_mark_attendance,
-- fn_assessment_marksheet, fn_generate_result_cards and fn_student_list, and
-- supabase/tests/rapid_data_entry.sql now walks a name-and-roll-only child
-- through each of them.

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0143_a_roll_number_you_can_see_and_a_portal_that_makes_itself.sql', '44_a_roll_number_you_can_see.sql');
end $ledger$;
