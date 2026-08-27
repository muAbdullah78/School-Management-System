-- =============================================================================
-- 0083 — A parent could see the marks and not whether their child passed
--
-- Three gaps from the ground-truth audit, all confirmed by query rather than by
-- reading a list.
--
-- 1. THE PORTAL WITHHELD THE ONE THING A PARENT OPENS IT FOR
--
--    fn_generate_result_cards (0058) freezes a complete verdict onto every
--    result card:
--
--      'result'            PASS / FAIL / PENDING
--      'failed_subjects'   how many papers were below the pass mark
--      'pass_percent'      the threshold this school actually uses
--      'provisional'       true when some papers are not marked yet
--      'unmarked_subjects' how many
--      'stream', 'bise_reg_no'
--
--    fn_portal_child_results returned NONE of them. A parent saw marks, a
--    percentage and a grade — and had to work out for themselves whether 41%
--    was a pass at a school whose threshold is 40 or 50.
--
--    Worse, `provisional` was dropped too. So a card generated while two papers
--    were unmarked showed a percentage computed over the marked papers only, and
--    the parent had no way to know it was not the final figure. The card the
--    SCHOOL prints says "provisional" on its face; the portal did not.
--
--    Per-subject practical marks were already in `frozen->subjects` — theory,
--    practical, practical_max — so the portal had them all along and rendered
--    only the total. That half is a UI fix; this makes the verdict available.
--
-- 2. AN UNLOGGED DIRECT-WRITE PATH FOR THE OPERATOR
--
--    `schools_update_platform` lets a platform admin UPDATE public.schools
--    straight over the REST API. Every operator write is supposed to go through a
--    SECURITY DEFINER function, because that is where the reason is demanded and
--    the row is written to operator_actions. A direct UPDATE writes no audit row
--    at all. Dropped.
--
--    Dropping it takes nothing away. The definer functions bypass RLS by
--    definition, so fn_platform_suspend_school and the rest are unaffected, and
--    no code anywhere issues a direct update to that table.
--
--    THIS SECTION FIRST SHIPPED WITH A GUARD BUILT ON A FALSE PREMISE, and the
--    premise was false on every real deployment. It read:
--
--        `authenticated` has no UPDATE privilege on that table at all, so the
--        policy has never been reachable
--
--        if has_table_privilege('authenticated', 'public.schools', 'update') then
--          raise exception '... Do not drop it blind ...'
--
--    That is true of a bare Postgres and FALSE of Supabase. A Supabase project is
--    created with
--
--        alter default privileges in schema public
--          grant all on tables to postgres, anon, authenticated, service_role;
--
--    so every table our migrations create there is granted to `authenticated`
--    automatically — `schools` included. The guard therefore fired on the real
--    thing and aborted the whole bundle, while passing in CI and on every local
--    stub, because neither has that default ACL.
--
--    Two lessons, both worth more than the fix:
--
--      * A guard whose condition is a PRIVILEGE is a guard that behaves
--        differently on Supabase than in CI. The question worth asking was never
--        "does the grant exist" but "is there a caller" — and there is none.
--      * The local harness must carry Supabase's default privileges or it is not
--        a faithful stub. It does now, and that is how this was reproduced.
--
-- 3. TWO TABLES AND TWO COLUMNS NOTHING HAS EVER USED
--
--    `campuses` and `shifts` were created in 0001 and are referenced by exactly
--    two things: classes.campus_id and classes.shift_id. No function reads
--    either. No screen writes either. Every install has zero rows in both,
--    because there has never been a way to create one.
--
--    They are carried by every catalogue sweep in the test suite, they appear in
--    the export list a school downloads, and they suggest a multi-campus feature
--    that does not exist. Dropped — GUARDED, so a database that somehow has rows
--    stops and says so rather than destroying them.
--
--    Multi-campus is a real request from larger schools and it will come back.
--    When it does it needs designing properly: a campus that owns sections,
--    staff, a fee structure and its own receipt series is not two nullable
--    columns on `classes`. Two empty tables are not a head start on that.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The verdict reaches the parent
--
-- Nothing new is computed. Every field here was already frozen onto the card
-- when it was generated, which matters: a portal that recomputed a pass mark
-- could disagree with the certificate the school printed, and the printed one is
-- the one the family is holding.
-- ---------------------------------------------------------------------------
create or replace function public.fn_portal_child_results(p_student_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  perform public.fn__assert_my_child(p_student_id);

  select coalesce(jsonb_agg(
           case when x.withheld then
             jsonb_build_object(
               'result_card_id', x.id, 'term', x.term, 'withheld', true,
               'message', 'Result withheld until outstanding fees are cleared.',
               'issued_at', x.issued_at)
           else
             jsonb_build_object(
               'result_card_id', x.id, 'term', x.term, 'withheld', false,
               'obtained_marks', x.total_marks, 'total_marks', x.total_max,
               'percentage', x.percentage, 'grade', x.grade,
               'position', x.position, 'attendance_pct', x.attendance_pct,
               -- THE VERDICT. Read straight out of the frozen snapshot, so the
               -- portal and the printed card cannot disagree — the printed one is
               -- what the family is holding.
               'result', x.frozen->>'result',
               'failed_subjects', (x.frozen->>'failed_subjects')::integer,
               'pass_percent', (x.frozen->>'pass_percent')::numeric,
               -- A provisional card must SAY so. Its percentage is computed over
               -- the marked papers only, and a parent shown 78% with no warning
               -- has been told something that is not the final figure.
               'provisional', coalesce((x.frozen->>'provisional')::boolean, false),
               'unmarked_subjects', coalesce((x.frozen->>'unmarked_subjects')::integer, 0),
               -- On a board class the registration number is the thing a parent
               -- checks hardest, because a wrong one is a real problem in March.
               'stream', x.frozen->>'stream',
               'bise_reg_no', x.frozen->>'bise_reg_no',
               'subjects', coalesce(x.frozen->'subjects', '[]'::jsonb),
               'issued_at', x.issued_at)
           end
           order by x.issued_at desc), '[]'::jsonb)
    into v_out
  from (
    select distinct on (rc.exam_term_id)
           rc.id, et.name as term, rc.total_marks, rc.total_max, rc.percentage,
           rc.grade, rc.position, rc.attendance_pct, rc.frozen,
           rc.published_at as issued_at,
           coalesce((rc.frozen->>'withheld')::boolean, false) as withheld
    from public.result_cards rc
    join public.exam_terms et on et.id = rc.exam_term_id
    where rc.student_id = p_student_id
      and rc.published_at is not null
    order by rc.exam_term_id, rc.version desc
  ) x;

  return coalesce(v_out, '[]'::jsonb);
end;
$$;

grant  execute on function public.fn_portal_child_results(uuid) to authenticated;
revoke execute on function public.fn_portal_child_results(uuid) from public, anon;

-- ---------------------------------------------------------------------------
-- 2. The policy that could never fire
-- ---------------------------------------------------------------------------
do $deadpolicy$
begin
  if exists (select 1 from pg_policies
              where schemaname = 'public' and tablename = 'schools'
                and policyname = 'schools_update_platform') then
    drop policy schools_update_platform on public.schools;
    raise notice
      '0083: dropped schools_update_platform — an operator UPDATE over REST '
      'writes no audit row; the definer functions bypass RLS and still work';
  end if;
end $deadpolicy$;

-- The END STATE, asserted rather than assumed.
--
-- Not "did my DROP run" but "is there any UPDATE policy on this table now" —
-- which is the property that actually matters and catches a second policy added
-- under another name. With none, an UPDATE over REST matches nothing and is
-- refused, whatever privileges the role happens to hold.
do $assert$
declare v_left text;
begin
  select string_agg(policyname, ', ') into v_left
    from pg_policies
   where schemaname = 'public' and tablename = 'schools' and cmd = 'UPDATE';
  if v_left is not null then
    raise exception
      '0083: public.schools still has an UPDATE policy (%). Every operator write '
      'must go through a SECURITY DEFINER function so the reason and the actor '
      'are recorded in operator_actions.', v_left;
  end if;
end $assert$;

-- ---------------------------------------------------------------------------
-- 3. campuses and shifts
--
-- Guarded on being empty. A destructive migration that assumes its own premise
-- is how a school loses data it turns out to have had.
-- ---------------------------------------------------------------------------
do $dead$
declare v_c bigint := 0; v_s bigint := 0; v_used bigint := 0;
begin
  if to_regclass('public.campuses') is null and to_regclass('public.shifts') is null then
    return;                                   -- already gone
  end if;

  if to_regclass('public.campuses') is not null then
    execute 'select count(*) from public.campuses' into v_c;
  end if;
  if to_regclass('public.shifts') is not null then
    execute 'select count(*) from public.shifts' into v_s;
  end if;
  select count(*) into v_used from public.classes
   where campus_id is not null or shift_id is not null;

  if v_c > 0 or v_s > 0 or v_used > 0 then
    -- NOT dropped, and the migration does not fail either: a school that somehow
    -- has campus rows must keep working, and the operator needs to know before
    -- anything is destroyed.
    raise notice
      '0083: NOT dropping campuses/shifts — % campus(es), % shift(s) and % class(es) '
      'reference them. Something created rows there. Look before removing them.',
      v_c, v_s, v_used;
    return;
  end if;

  -- The columns first: dropping the tables while classes still points at them
  -- would fail on the foreign keys.
  alter table public.classes drop column if exists campus_id;
  alter table public.classes drop column if exists shift_id;
  drop table if exists public.shifts;
  drop table if exists public.campuses;
  raise notice '0083: dropped campuses and shifts — empty, unreferenced, and no screen ever wrote to them';
end $dead$;
