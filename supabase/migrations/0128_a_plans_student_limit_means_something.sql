-- =============================================================================
-- 0128 - A plan's student limit was a number on an invoice, not a limit
--
-- REPORTED BY THE VENDOR, of a real school in his own console:
--
--   "the school is only allowed to have 150 students but it exceeds to 200
--    plus students so this is a loophole. We should not allow any school
--    exceed their limit. If they want more entries for their students we have
--    to create a request box that directly goes to our admin."
--
-- He is right that nothing enforced it, and the code said so out loud.
-- fn_my_licence has always computed the breach and then told the school:
--
--     'You have %s students, above the %s your plan covers. We will move you
--      to the right plan at your next renewal. Nothing stops working.'
--
-- and only said even that while a renewal was within thirty days. So a school
-- could sit at 228 pupils on a 150 plan for a year, paying Rs 2,000 a month
-- for Rs 3,500 a month of use, and the software's own position was that
-- nothing stops working.
--
-- -----------------------------------------------------------------------------
-- WHAT THIS DOES, and the shape was chosen against the vendor's decision
-- rather than around it. He was offered "block the clerk, let the owner
-- override with a confirmation" and chose "block everyone, including the
-- owner". That is what is built. The risk of it is real and named here so it
-- is not discovered later: the person standing at the blocked screen during
-- admission week cannot pay for an upgrade, and a school that cannot enter a
-- child will write the child on paper, which is worse for them and for us than
-- being over the limit. Three things blunt it, all of them deliberate:
--
--   1. NOBODY MEETS THE WALL WITHOUT WARNING. From 90% of the limit the owner
--      and the principal see what happens at 100%, on every screen that reads
--      fn_my_licence, whatever the renewal date. Today's code only warns
--      within thirty days of a renewal and only once already over.
--   2. THERE ARE ALWAYS TWO WAYS OUT, and one of them does not need us.
--
--      Marking a child who has actually left as left frees a place at once
--      and asks nobody's permission. And the request box, which reaches the
--      console and offers both answers: room on this plan, or moving up.
--
--      IT DOES NOT SAY "move up a plan yourself, which is self-service".
--      That was this header's first draft and it was false: nothing in this
--      product lets a school change its own plan. fn_activate_subscription is
--      operator-only, the term chooser changes how OFTEN they pay and not
--      what they are on, and every renewal is a bank transfer somebody here
--      confirms by hand. A refusal that names a control the product does not
--      have sends a school looking for it, and they phone anyway.
--   3. THE BLOCK IS ON ADMISSION ONLY. Nothing already recorded is touched,
--      no screen closes, no report stops. A school over its limit keeps every
--      pupil, every challan and every mark, and can still read, print and
--      export all of it.
--
-- -----------------------------------------------------------------------------
-- WHERE IT IS ENFORCED, established by reading the catalogue rather than by
-- guessing which screens matter:
--
--     select proname from pg_proc where prosrc ~ 'insert into public\.students'
--       fn_admit_student
--
-- ONE function inserts a pupil. fn_enquiry_admit and fn_import_students both
-- call it, so the admission gate has a single home instead of three. The other
-- way a roll rises is fn_set_student_status bringing a child back from a
-- leaving state, which reactivates the pupil AND their enrolment, so it is
-- gated too.
--
-- fn_rollover IS DELIBERATELY NOT GATED, and this is the important exclusion.
-- It inserts enrolments for the next session, which is the same children a
-- year older rather than new ones. Gating it would stop a school over its
-- limit from starting its academic year at all: no register, no challans, no
-- classes. That is not enforcement, it is taking the product away.
--
-- -----------------------------------------------------------------------------
-- NO GRANDFATHERING, and it was considered. Recording every over-limit
-- school's current count as an allowance would mean the limit changes nothing
-- on the one day it starts existing. There is exactly one school over its
-- limit today and it belongs to the vendor. So this migration REPORTS who is
-- over and by how much, and leaves the decision where it belongs: the operator
-- console can grant an allowance to anyone who needs one, with a reason, in
-- one click.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. THE ALLOWANCE AN OPERATOR CAN GRANT
--
-- Shaped exactly like grace_days_override (0079), which is the same kind of
-- thing: a per-school exception to a platform rule, and worthless without the
-- reason beside it. The check constraint makes the reason mandatory at the
-- database, so the column cannot be set from a psql prompt without one.
-- ---------------------------------------------------------------------------
alter table public.subscriptions
  add column if not exists student_limit_override        integer,
  add column if not exists student_limit_override_reason text,
  add column if not exists student_limit_override_by     uuid,
  add column if not exists student_limit_override_at     timestamptz;

comment on column public.subscriptions.student_limit_override is
  'Extra room granted to THIS school, replacing plans.student_limit. Null means '
  'the plan''s own limit applies. Set only by an operator, only with a reason, '
  'and only through fn_platform_grant_student_limit.';

do $c$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'subscriptions_student_limit_override_chk') then
    alter table public.subscriptions add constraint subscriptions_student_limit_override_chk
      check (student_limit_override is null
             or (student_limit_override >= 1
                 and btrim(coalesce(student_limit_override_reason, '')) <> ''));
  end if;
end $c$;

-- ---------------------------------------------------------------------------
-- 2. THE LIMIT THAT ACTUALLY APPLIES, IN ONE FUNCTION
--
-- Null means no limit, which is what the by-arrangement plan has and is why
-- every caller has to handle it. An override wins over the plan even when the
-- plan is unlimited: an operator who sets a number on a custom plan means it.
-- ---------------------------------------------------------------------------
create or replace function public.fn__student_limit(p_school_id uuid)
returns integer
language sql stable security definer set search_path = public as $$
  select coalesce(sub.student_limit_override, p.student_limit)
    from public.subscriptions sub
    join public.plans p on p.code = sub.plan_code
   where sub.school_id = p_school_id;
$$;

revoke all on function public.fn__student_limit(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. THE GATE
--
-- One function, so the rule has one home and one wording. p_adding is how many
-- pupils the caller is about to add, so the importer can ask about a whole
-- batch instead of failing on row 151 of 300.
--
-- THE MESSAGE IS THE FEATURE. Somebody is standing at a screen with a parent
-- in front of them, so it says the count, the limit, both ways out, and who
-- can do them. A refusal that says "limit reached" turns into a phone call.
-- ---------------------------------------------------------------------------
create or replace function public.fn__assert_room_for_students(
  p_school_id uuid, p_adding integer default 1)
returns void
language plpgsql stable security definer set search_path = public as $$
declare
  v_limit integer := public.fn__student_limit(p_school_id);
  v_count integer;
  v_add   integer := greatest(coalesce(p_adding, 1), 1);
begin
  -- No limit: the by-arrangement plan, or a school with no subscription row at
  -- all, which is a broken state this function is not the place to report.
  if v_limit is null then
    return;
  end if;

  v_count := public.fn_count_students(p_school_id);
  if v_count + v_add <= v_limit then
    return;
  end if;

  -- THE TWO WAYS OUT, IN THE ORDER THEY ARE USEFUL, and neither of them is a
  -- button this product does not have. An earlier draft of this sentence ended
  -- "or move up a plan from the same screen, which takes effect at once",
  -- which was false: no school can change its own plan here. This is the
  -- sentence somebody reads with a parent in front of them, so it is the last
  -- place that should send them hunting.
  if v_add = 1 then
    raise exception
      'Your plan covers % pupils and you have %. Adding another needs more '
      'room first. Ask us for it from Settings, Subscription (the owner or '
      'the principal can), where you can ask for room on this plan or to be '
      'moved up to a bigger one, and the answer comes back on that screen. If '
      'a child on your roll has actually left, marking them as left frees a '
      'place straight away. Nothing you have already entered is affected.',
      v_limit, v_count
      using errcode = 'P0002';
  else
    raise exception
      'This would put % pupils on the roll and your plan covers %. You have % '
      'now, so there is room for % more. Ask us for more room, or to be moved '
      'up a plan, from Settings, Subscription, and then import the whole file '
      'in one go rather than splitting it.',
      v_count + v_add, v_limit, v_count, greatest(v_limit - v_count, 0)
      using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function public.fn__assert_room_for_students(uuid, integer)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. THE THREE PATHS THAT CAN RAISE A ROLL
--
-- Patched programmatically and asserted, the way 0092, 0126 and 0127 patch a
-- large function: restating fn_admit_student to add one line would silently
-- discard whatever the eleven migrations since 0004 did to the other four
-- hundred. Every anchor is a single line with no newline in it, which is the
-- lesson 0126 learned the hard way about bodies pasted from a CRLF editor.
-- ---------------------------------------------------------------------------
-- 3b. AN ANCHOR THAT SURVIVES A CRLF PASTE
--
-- Four of the rewrites below have to match TWO OR MORE LINES of somebody
-- else's function body, and a needle that spells its own line break cannot do
-- that safely. E'\n' is one bare line feed, always. A body created by pasting
-- a CRLF file into the Supabase SQL editor has \r\n, so the needle is simply
-- not in it, the rewrite silently does not take, and because the editor runs a
-- pasted file as one transaction, the raise that notices rolls back every
-- migration in the bundle. That is not a hypothetical: it cost bundle 12 seven
-- migrations on a live school, which is why supabase/check-patch-anchors.py
-- exists and why it failed this migration.
--
-- The remedy the checker names is \s+, which matches a space, a tab, a line
-- feed and a carriage return alike. Writing that by hand means also escaping
-- every bracket, dot, star and pipe in a forty-line SQL fragment, which is a
-- second way to be wrong and a much quieter one. So this does it mechanically:
-- hand it the fragment exactly as it appears in the source and it returns a
-- regex that matches that fragment however its lines end and however it is
-- indented.
--
-- replace() rather than a bracket expression for the escaping, because a
-- backslash inside a POSIX bracket expression is itself ambiguous and the one
-- job of this function is to remove ambiguity. The backslash goes FIRST, so
-- the backslashes the later passes add are not escaped a second time.
-- ---------------------------------------------------------------------------
create or replace function public.fn__anchor_regex(p_text text)
returns text language plpgsql immutable set search_path = public as $anch$
declare v text := p_text; c text;
begin
  foreach c in array array['\', '.', '^', '$', '|', '(', ')', '[', ']',
                           '{', '}', '*', '+', '?'] loop
    v := replace(v, c, '\' || c);
  end loop;
  return regexp_replace(v, '\s+', '\\s+', 'g');
end;
$anch$;

revoke all on function public.fn__anchor_regex(text) from public, anon, authenticated;

do $anchtest$
declare v_pat text;
begin
  -- IT IS TESTED HERE, IN THE MIGRATION, rather than only in a suite. A school
  -- applies this file without ever running supabase/tests, and a broken anchor
  -- builder would rewrite nothing and raise nothing.
  v_pat := public.fn__anchor_regex('  if (a.b) then' || E'\n' || '  else');
  if regexp_replace('x' || chr(13) || chr(10) || '  if (a.b) then' || chr(13)
                    || chr(10) || '  else' || chr(13) || chr(10) || 'y',
                    v_pat, 'HIT') not like '%HIT%' then
    raise exception '0128: fn__anchor_regex does not match a CRLF body, which '
      'is the only reason it exists';
  end if;
  if regexp_replace('  if (a.b) then' || chr(10) || '  else', v_pat, 'HIT')
       <> 'HIT' then
    raise exception '0128: fn__anchor_regex does not match an LF body';
  end if;
  -- And it must not match something that merely looks similar: the brackets and
  -- the dot are literal, not a regex.
  if regexp_replace('  if (aXb) then' || chr(10) || '  else', v_pat, 'HIT')
       like '%HIT%' then
    raise exception '0128: fn__anchor_regex treats a dot as a wildcard, so it '
      'can match the wrong line';
  end if;
end $anchtest$;

-- ---------------------------------------------------------------------------

-- 4a. ADMISSION. The gate goes after the tenant checks and before anything is
--     written, so a refusal writes nothing and a crafted payload still cannot
--     reach another school's ids first.
do $admit$
declare v_src text; v_new text;
begin
  v_src := pg_get_functiondef('public.fn_admit_student(jsonb)'::regprocedure);
  if position('fn__assert_room_for_students' in v_src) > 0 then
    raise notice '0128: fn_admit_student already checks the plan''s limit';
    return;
  end if;
  if position('  perform public.assert_own(''sections'', v_section);' in v_src) = 0 then
    raise exception '0128: fn_admit_student no longer contains the tenant check '
      'this migration inserts the limit check after. It has been rewritten '
      'since. The gate belongs after the assert_own calls and before the first '
      'write: perform public.fn__assert_room_for_students(public.current_school_id(), 1).';
  end if;
  v_new := replace(v_src,
    '  perform public.assert_own(''sections'', v_section);',
    '  perform public.assert_own(''sections'', v_section);' || E'\n' ||
    E'\n' ||
    '  -- THE PLAN''S LIMIT (0128). After the tenant checks so a crafted' || E'\n' ||
    '  -- payload cannot use this as an oracle, and before the first write so a' || E'\n' ||
    '  -- refusal leaves nothing behind. This is the only function in the schema' || E'\n' ||
    '  -- that inserts a pupil: fn_enquiry_admit and fn_import_students both' || E'\n' ||
    '  -- come through here, which is why the gate is here and not in three' || E'\n' ||
    '  -- places.' || E'\n' ||
    '  perform public.fn__assert_room_for_students(public.current_school_id(), 1);');
  if v_new = v_src then
    raise exception '0128: the fn_admit_student rewrite changed nothing';
  end if;
  execute v_new;
  raise notice '0128: an admission past the plan''s limit is refused';
end $admit$;

-- 4b. COMING BACK. fn_set_student_status reactivates the pupil AND their
--     enrolment in the current session, so the roll rises by one. Only the
--     coming-back branch: marking a child as left must always work, and a
--     school over its limit needs it to.
do $back$
declare v_src text; v_new text; v_pat text;
begin
  v_src := pg_get_functiondef(
    'public.fn_set_student_status(uuid,public.student_status,text,date)'::regprocedure);
  if position('fn__assert_room_for_students' in v_src) > 0 then
    raise notice '0128: fn_set_student_status already checks the plan''s limit';
    return;
  end if;
  if position('  -- ------------------------------------------------------------ coming back --'
      in v_src) = 0 then
    raise exception '0128: fn_set_student_status no longer contains the '
      'coming-back marker this migration inserts the limit check after. It has '
      'been rewritten since. Bringing a child back from a leaving state '
      'reactivates their enrolment and so raises the roll by one, and needs '
      'the same check an admission does. Marking a child as LEFT must stay '
      'unchecked: a school over its limit needs that to work.';
  end if;
  -- ONE CALL, ACROSS BOTH LINES, and whitespace-tolerant.
  --
  -- This was two chained replace() calls: the first inserted the comment after
  -- the marker, the second matched '-- never be refused.' + newline + 'else' +
  -- newline to put the check inside the branch. On a CRLF body that second
  -- needle could not match, because the newline BEFORE `else` had just been
  -- inserted as a bare line feed while the one AFTER it was still the body's
  -- own \r\n. So the rewrite did not take, the raise below fired, and the whole
  -- bundle rolled back. Caught by preflight's CRLF pass.
  v_pat := public.fn__anchor_regex(
    '  -- ------------------------------------------------------------ coming back --'
    || E'\n' || '  else');
  v_new := regexp_replace(v_src, v_pat,
    '  -- ------------------------------------------------------------ coming back --' || E'\n' ||
    '  -- AND IT COUNTS AGAINST THE PLAN (0128). A child brought back is a' || E'\n' ||
    '  -- child on the roll, billed and marked like any other, so this is an' || E'\n' ||
    '  -- admission as far as the limit is concerned. The check is inside the' || E'\n' ||
    '  -- else branch only: marking somebody as LEFT lowers the roll and must' || E'\n' ||
    '  -- never be refused.' || E'\n' ||
    '  else' || E'\n' ||
    '    perform public.fn__assert_room_for_students(v_school, 1);');
  if v_new = v_src or position('fn__assert_room_for_students' in v_new) = 0 then
    raise exception '0128: the fn_set_student_status rewrite did not take';
  end if;
  execute v_new;
  raise notice '0128: bringing a pupil back past the plan''s limit is refused';
end $back$;

-- 4c. THE IMPORTER, ASKED ONCE ABOUT THE WHOLE FILE.
--
-- It calls fn_admit_student per row, so without this a 300-row import into a
-- 150 plan would create 150 pupils and then report 150 identical failures,
-- leaving the school half imported and the file useless. Asked up front it
-- refuses the whole thing and says how much room there is.
do $imp$
declare v_src text; v_new text;
begin
  v_src := pg_get_functiondef(
    'public.fn_import_students(uuid,jsonb,boolean)'::regprocedure);
  if position('fn__assert_room_for_students' in v_src) > 0 then
    raise notice '0128: fn_import_students already checks the plan''s limit';
    return;
  end if;
  if position('  for v_row in select value from jsonb_array_elements(p_rows) as value'
      in v_src) = 0 then
    raise exception '0128: fn_import_students no longer contains the row loop '
      'this migration inserts the batch check before. It has been rewritten '
      'since. The check belongs before the loop, asked once for the whole file: '
      'perform public.fn__assert_room_for_students(public.current_school_id(), '
      'jsonb_array_length(p_rows)).';
  end if;
  v_new := replace(v_src,
    '  for v_row in select value from jsonb_array_elements(p_rows) as value',
    '  -- THE WHOLE FILE, ASKED ONCE (0128). Every row goes through' || E'\n' ||
    '  -- fn_admit_student, which checks the limit itself, so without this a' || E'\n' ||
    '  -- 300-row import into a 150 plan would create 150 pupils and then' || E'\n' ||
    '  -- report 150 identical failures: half imported, and the file no longer' || E'\n' ||
    '  -- safe to re-run. The count here is the rows OFFERED, not the rows that' || E'\n' ||
    '  -- will be created (some are duplicates and get skipped), so it is a' || E'\n' ||
    '  -- deliberate over-estimate: refusing a file that would just fit is' || E'\n' ||
    '  -- recoverable in one click, and half-importing one is not.' || E'\n' ||
    '  perform public.fn__assert_room_for_students(' || E'\n' ||
    '    public.current_school_id(), jsonb_array_length(p_rows));' || E'\n' ||
    E'\n' ||
    '  for v_row in select value from jsonb_array_elements(p_rows) as value');
  if v_new = v_src then
    raise exception '0128: the fn_import_students rewrite changed nothing';
  end if;
  execute v_new;
  raise notice '0128: an import that would not fit is refused before it starts';
end $imp$;

-- ---------------------------------------------------------------------------
-- 5. THE REQUEST BOX
--
-- Shaped like platform_payment_claims (0112), which is the same kind of thing:
-- a school says something, the operator decides, and both halves stay on the
-- record. Same status vocabulary, same decided_by/decided_at/decision_note,
-- same "a refusal needs a reason" check constraint, and the same two SELECT
-- policies so the school sees only its own and the operator sees all of them.
--
-- SELECT ONLY, for both. Every write goes through a function, which is how the
-- rest of this schema works and is what stops a school inserting a request
-- marked `granted`.
-- ---------------------------------------------------------------------------
create table if not exists public.student_limit_requests (
  id              uuid primary key default gen_random_uuid(),
  school_id       uuid not null references public.schools(id) on delete cascade,
  -- What they asked for and what was true when they asked. Both, because "we
  -- need room for 200" reads differently against a roll of 148 than 195, and
  -- the operator is deciding weeks later.
  requested_limit integer not null check (requested_limit >= 1),
  count_at_request integer not null,
  limit_at_request integer,
  reason          text not null,
  -- WHICH OF THE TWO THINGS THEY ARE ASKING FOR, as a value rather than as
  -- prose in the reason.
  --
  -- A school at its limit does not care whether the next child is admitted
  -- under an exception or under a bigger plan; it cares what it costs. The two
  -- answers are completely different for US, though: an allowance is a
  -- permanent hole in our own pricing, and moving up is a school agreeing to
  -- pay more. Reading which one they meant out of a sentence like "we need
  -- room for 200 pupils" is a guess, and a guess here costs a phone call on
  -- every single request. So the box asks, and the worklist shows the answer.
  wants           text not null default 'more_room'
                    check (wants in ('more_room', 'move_up')),
  requested_by    uuid,
  requested_at    timestamptz not null default now(),
  status          text not null default 'pending'
                    check (status in ('pending', 'granted', 'declined', 'withdrawn')),
  decided_by      uuid,
  decided_at      timestamptz,
  decision_note   text,
  granted_limit   integer,
  -- A decision has a time on it, and a decline or a partial grant has a reason
  -- the school can read. A granted request that gave exactly what was asked
  -- needs no note.
  constraint student_limit_requests_decision_chk check (
    status = 'pending'
    or (status = 'withdrawn' and decided_at is not null)
    or (decided_at is not null
        and (status = 'granted' and granted_limit >= requested_limit
             or btrim(coalesce(decision_note, '')) <> '')))
);

comment on table public.student_limit_requests is
  'A school asking for more room than its plan covers, and the operator''s '
  'answer. Written only through fn_request_student_limit and the two '
  'fn_platform_ functions; readable by the school''s owner and principal and by '
  'a platform admin.';

create index if not exists idx_slr_pending
  on public.student_limit_requests (requested_at) where status = 'pending';
create index if not exists idx_slr_school
  on public.student_limit_requests (school_id, requested_at desc);
-- ONE PENDING REQUEST PER SCHOOL, at the database rather than in the function.
-- Two clicks on a slow connection is the ordinary way a school ends up with
-- two, and the operator then has to work out which one to answer.
create unique index if not exists uq_slr_one_pending
  on public.student_limit_requests (school_id) where status = 'pending';

-- Belt and braces for the column above: `create table if not exists` adds
-- nothing to a table that already exists, and this migration may be re-pasted
-- as part of a bundle onto a database that already has the table from an
-- earlier paste of the same bundle.
alter table public.student_limit_requests
  add column if not exists wants text not null default 'more_room';
-- Matched on what the constraint SAYS rather than on a name, because a fresh
-- install already has one from the create table above under Postgres's own
-- auto-generated name. Two identical checks would both be enforced and both be
-- correct, and would still be one too many to read.
do $w$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.student_limit_requests'::regclass
                    and contype = 'c'
                    and pg_get_constraintdef(oid) like '%move_up%') then
    alter table public.student_limit_requests
      add constraint student_limit_requests_wants_chk
      check (wants in ('more_room', 'move_up'));
  end if;
end $w$;

alter table public.student_limit_requests enable row level security;

drop policy if exists slr_select_platform on public.student_limit_requests;
create policy slr_select_platform on public.student_limit_requests
  for select to authenticated using (public.is_platform_admin());

drop policy if exists slr_select_school on public.student_limit_requests;
create policy slr_select_school on public.student_limit_requests
  for select to authenticated using (
    school_id = public.current_school_id()
    and public.may_view(variadic array['owner', 'principal']::public.user_role[]));

-- ---------------------------------------------------------------------------
-- 6. THE SCHOOL'S SIDE
-- ---------------------------------------------------------------------------
create or replace function public.fn_request_student_limit(
  p_requested integer, p_reason text, p_wants text default 'more_room')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_wants  text := lower(nullif(btrim(coalesce(p_wants, '')), ''));
  v_limit  integer;
  v_count  integer;
  v_id     uuid;
  v_sug    text;
begin
  if v_school is null or not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or the principal can ask for more room'
      using errcode = '42501';
  end if;
  if p_requested is null or p_requested < 1 then
    raise exception 'Say how many pupils you need room for';
  end if;
  -- Defaulted rather than refused when absent, so an older client that only
  -- knows about the two-argument call still works and lands on the cautious
  -- answer: an exception, which we have to think about, rather than an upgrade
  -- we would then bill them for.
  v_wants := coalesce(v_wants, 'more_room');
  if v_wants not in ('more_room', 'move_up') then
    raise exception 'A request is either for more room on your plan or to move '
      'up a plan, and this one says "%"', v_wants;
  end if;
  -- A REASON, LIKE EVERY OTHER REQUEST IN THIS SCHEMA. The operator is
  -- deciding about a school they cannot see inside, so "we are opening a
  -- second campus in April" is the whole difference between a yes and a
  -- guess. Eight characters, the same floor fn_unlock_attendance uses.
  if v_reason is null or length(v_reason) < 8 then
    raise exception 'Say briefly why you need the room: it is what we read '
      'when we decide, and a request with nothing in it waits longer.';
  end if;

  v_limit := public.fn__student_limit(v_school);
  v_count := public.fn_count_students(v_school);

  if v_limit is not null and p_requested <= v_limit then
    raise exception 'Your plan already covers % pupils, so there is nothing to '
      'ask for. Ask for more than % if you need it.', v_limit, v_limit;
  end if;

  -- The unique index is the real guard; this is the sentence a person reads.
  if exists (select 1 from public.student_limit_requests
              where school_id = v_school and status = 'pending') then
    raise exception 'You already have a request waiting with us, for room for '
      '% pupils. We will answer that one; there is no need to send another.',
      (select requested_limit from public.student_limit_requests
        where school_id = v_school and status = 'pending');
  end if;

  insert into public.student_limit_requests
    (school_id, requested_limit, count_at_request, limit_at_request, reason,
     wants, requested_by)
  values (v_school, p_requested, v_count, v_limit, v_reason, v_wants, auth.uid())
  returning id into v_id;

  -- AUDITED AGAINST THE SCHOOL, so the owner can see who asked and when on
  -- their own audit screen. It is their request, not a platform secret.
  insert into public.audit_log
    (school_id, actor, actor_role, action, entity, entity_id, after, reason)
  values (v_school, auth.uid(),
          (select role from public.profiles where id = auth.uid()),
          'STUDENT_LIMIT_REQUESTED', 'subscriptions', v_school::text,
          jsonb_build_object('requested_limit', p_requested,
                             'students_now', v_count, 'plan_covers', v_limit,
                             'wants', v_wants),
          v_reason);

  select p2.code into v_sug from public.plans p2
   where p2.active and p2.price_monthly > 0
     and p2.student_limit >= p_requested
   order by p2.student_limit limit 1;

  return jsonb_build_object(
    'id', v_id, 'status', 'pending', 'requested_limit', p_requested,
    'students_now', v_count, 'plan_covers', v_limit, 'wants', v_wants,
    'suggested_plan', v_sug,
    -- What happens next, in the answer, so no screen has to invent it.
    --
    -- THIS SENTENCE USED TO END "and you can still move up a plan yourself
    -- from this screen if you would rather not wait", which was false. Nothing
    -- in this product lets a school change its own plan: fn_activate_subscription
    -- is operator-only, the term chooser changes how often they pay and not
    -- what they are on, and every renewal is a bank transfer somebody here
    -- confirms by hand. A message telling a school to press a button that does
    -- not exist is worse than telling them to wait, because they go looking,
    -- do not find it, and then phone anyway.
    'what_next', case when v_wants = 'move_up' then
        'We will work out what the bigger plan costs for the rest of your term '
        || 'and send you the price. Nothing changes on your account until you '
        || 'are happy with it, and the answer will appear on this screen.'
      else
        'We will look at this and come back to you, usually the same working '
        || 'day. Nothing changes in the meantime, nothing you have already '
        || 'entered is affected, and the answer will appear on this screen.'
      end);
end;
$$;

revoke all on function public.fn_request_student_limit(integer, text, text)
  from public, anon;
grant execute on function public.fn_request_student_limit(integer, text, text)
  to authenticated;

-- What the school's own screen shows: the room it has, and any request in
-- flight. One read, so the banner and the request box cannot disagree.
create or replace function public.fn_my_student_limit()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_limit  integer;
  v_count  integer;
  r        record;
  v_sub    record;
  v_sug    record;
begin
  -- may_view AND NOT has_role, which is migration 0059's rule and verify.sql
  -- caught this the moment 0128 was written: every STABLE security-definer
  -- function that gates a READ must go through may_view, because has_role
  -- excludes the observer role and an operator on a support visit. This is a
  -- read: the roll, the limit, and any request in flight. The three roles named
  -- are the ones who admit pupils, and may_view adds the observer and the
  -- support visit on top.
  if v_school is null
     or not public.may_view('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  v_limit := public.fn__student_limit(v_school);
  v_count := public.fn_count_students(v_school);
  -- ONE REQUEST TO SHOW, AND PENDING WINS.
  --
  -- `order by requested_at desc` alone was wrong twice. It has no tiebreak, so
  -- two requests written in the same second, which is what a school gets when
  -- it withdraws one and sends another straight away, resolved arbitrarily and
  -- could show the withdrawn one. And even with a tiebreak, "most recent"
  -- is not what this screen wants: if something is in flight the school needs
  -- to see THAT, and only when nothing is waiting does it want the last
  -- answer. The unique partial index allows at most one pending row, so the
  -- first key is unambiguous.
  select * into r from public.student_limit_requests
   where school_id = v_school
   order by (status = 'pending') desc, requested_at desc, id desc
   limit 1;

  -- The plan they are on, the term they pay on, and the cheapest plan on sale
  -- that would hold the roll they are asking about.
  --
  -- ALL OF IT SERVES ONE SENTENCE ON THEIR SCREEN: "Growth covers 350 pupils
  -- and would be Rs X for the same twelve months you pay now." A school
  -- deciding between an exception and an upgrade is deciding about money, and
  -- a request box that cannot name the number is asking them to decide blind.
  -- Priced on THEIR term rather than monthly, because a yearly school quoted a
  -- monthly figure reads it as the new annual price and feels cheated later.
  select sub.plan_code, sub.term_months, p.student_limit as plan_limit
    into v_sub
    from public.subscriptions sub
    join public.plans p on p.code = sub.plan_code
   where sub.school_id = v_school;

  select p2.code, p2.name, p2.student_limit,
         public.fn__plan_price(p2.code, coalesce(v_sub.term_months, 12)) as price
    into v_sug
    from public.plans p2
   where p2.active and p2.price_monthly > 0
     and p2.student_limit is not null
     -- v_limit NULL MEANS NO LIMIT AT ALL, which is the by-arrangement plan.
     -- Written as its own clause rather than coalesced to zero, because
     -- coalesce(v_limit, 0) made every plan on the price list look like an
     -- upgrade for the school that is already above all of them.
     and v_limit is not null
     and p2.student_limit > v_limit
     and p2.student_limit > v_count
   order by p2.student_limit limit 1;

  return jsonb_build_object(
    'students', v_count,
    'limit', v_limit,
    'plan_code', v_sub.plan_code,
    'term_months', v_sub.term_months,
    -- What the PLAN covers, beside what this school is allowed, so a screen can
    -- say "150 your plan covers plus 80 we granted you" rather than a bare 230
    -- that matches no price list.
    'plan_covers', v_sub.plan_limit,
    -- Null when the plan has no limit, so a screen can tell "plenty of room"
    -- apart from "no limit at all" instead of dividing by null.
    'room', case when v_limit is null then null
                 else greatest(v_limit - v_count, 0) end,
    'at_limit', v_limit is not null and v_count >= v_limit,
    -- The 90% line, computed here rather than in each screen. ceil, so a limit
    -- of 150 warns from 135 and a limit of 15 warns from 14 instead of 13.
    'warn', v_limit is not null and v_count >= ceil(v_limit * 0.9),
    'granted_extra', (select student_limit_override is not null
                        from public.subscriptions where school_id = v_school),
    -- Null when nothing on the price list is bigger than what they already
    -- have, which is the by-arrangement case and needs a conversation rather
    -- than a button. A screen that cannot tell "no bigger plan" from "we did
    -- not look" would offer an upgrade to a school already on the largest.
    'next_plan', case when v_sug.code is null then null else jsonb_build_object(
      'code', v_sug.code, 'name', v_sug.name,
      'covers', v_sug.student_limit,
      'price', v_sug.price,
      'term_months', coalesce(v_sub.term_months, 12)) end,
    'request', case when r.id is null then null else jsonb_build_object(
      'id', r.id, 'status', r.status, 'requested_limit', r.requested_limit,
      'requested_at', r.requested_at, 'reason', r.reason,
      'wants', r.wants,
      'granted_limit', r.granted_limit, 'decision_note', r.decision_note,
      'decided_at', r.decided_at) end);
end;
$$;

revoke all on function public.fn_my_student_limit() from public, anon;
grant execute on function public.fn_my_student_limit() to authenticated;

-- Withdrawing one, because a school that upgrades instead should be able to
-- take its request off our list rather than wait to be told no.
create or replace function public.fn_withdraw_student_limit_request()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_id uuid;
begin
  if v_school is null or not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or the principal can withdraw a request'
      using errcode = '42501';
  end if;
  update public.student_limit_requests
     set status = 'withdrawn', decided_by = auth.uid(), decided_at = now()
   where school_id = v_school and status = 'pending'
  returning id into v_id;
  if v_id is null then
    raise exception 'You have no request waiting with us.';
  end if;
  return jsonb_build_object('id', v_id, 'status', 'withdrawn');
end;
$$;

revoke all on function public.fn_withdraw_student_limit_request()
  from public, anon;
grant execute on function public.fn_withdraw_student_limit_request()
  to authenticated;

-- ---------------------------------------------------------------------------
-- 7. THE OPERATOR'S SIDE
--
-- The worklist carries what the operator needs to decide without opening the
-- school: what they asked for, what they said, what their roll actually is NOW
-- (not when they asked, which may be weeks old), what their plan covers, and
-- which plan would cover the request. That last one matters: most of these
-- requests are a school that has outgrown its plan, and the right answer is
-- often "move up" rather than "here is an exception".
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_limit_requests(
  p_status text default 'pending')
returns table (
  id uuid, school_id uuid, school_name text, contact_name text,
  contact_phone text, plan_code text, requested_limit integer,
  reason text, wants text, requested_at timestamptz, count_at_request integer,
  students_now integer, plan_covers integer, effective_limit integer,
  suggested_plan text, suggested_plan_covers integer,
  status text, decided_at timestamptz, granted_limit integer,
  decision_note text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
    select r.id, r.school_id, s.name, s.contact_name, s.contact_phone,
           sub.plan_code, r.requested_limit, r.reason, r.wants, r.requested_at,
           r.count_at_request,
           public.fn_count_students(r.school_id),
           p.student_limit,
           public.fn__student_limit(r.school_id),
           sug.code, sug.student_limit,
           r.status, r.decided_at, r.granted_limit, r.decision_note
      from public.student_limit_requests r
      join public.schools s on s.id = r.school_id
      join public.subscriptions sub on sub.school_id = r.school_id
      join public.plans p on p.code = sub.plan_code
      left join lateral (
        -- The cheapest plan on sale that would cover what they asked for. Null
        -- when nothing does, which is the case that needs a conversation.
        select p2.code, p2.student_limit from public.plans p2
         where p2.active and p2.price_monthly > 0
           and p2.student_limit >= r.requested_limit
         order by p2.student_limit limit 1
      ) sug on true
     where coalesce(nullif(btrim(p_status), ''), 'pending') in ('all', r.status)
     order by case when r.status = 'pending' then 0 else 1 end,
              r.requested_at;
end;
$$;

revoke all on function public.fn_platform_limit_requests(text) from public, anon;
grant execute on function public.fn_platform_limit_requests(text) to authenticated;

-- Granting. Sets the allowance AND answers the request, in one transaction, so
-- there is no state where a school has the room and no record of being given
-- it, or a granted request and no room.
create or replace function public.fn_platform_grant_student_limit(
  p_school_id uuid, p_limit integer, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_plan integer;
  v_was  integer;
  v_req  uuid;
  v_asked integer;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p_limit is null or p_limit < 1 then
    raise exception 'An allowance is a number of pupils, at least 1';
  end if;

  select p.student_limit, sub.student_limit_override
    into v_plan, v_was
    from public.subscriptions sub
    join public.plans p on p.code = sub.plan_code
   where sub.school_id = p_school_id;
  if not found then
    raise exception 'That school has no subscription';
  end if;

  -- AN ALLOWANCE BELOW THE PLAN'S OWN LIMIT IS A REDUCTION, and needs saying
  -- out loud rather than being taken as a typo. It is legitimate (a school
  -- moved down a plan and we are holding them to it) and it is also how you
  -- would accidentally cut a school off at 15 pupils.
  if v_plan is not null and p_limit < v_plan and v_note is null then
    raise exception 'That would give them room for % pupils when their plan '
      'already covers %, which is a reduction. Say why if you mean it.',
      p_limit, v_plan;
  end if;

  -- The reason is mandatory at the database (see the check constraint), so
  -- this is the sentence rather than the enforcement.
  if v_note is null then
    v_note := format('Allowance of %s pupils granted', p_limit);
  end if;

  update public.subscriptions
     set student_limit_override        = p_limit,
         student_limit_override_reason = v_note,
         student_limit_override_by     = auth.uid(),
         student_limit_override_at     = now()
   where school_id = p_school_id;

  -- Answer the pending request, if there is one. Granting without a request is
  -- normal: the operator is often ahead of the school.
  update public.student_limit_requests
     set status = 'granted', granted_limit = p_limit,
         decided_by = auth.uid(), decided_at = now(),
         decision_note = case when p_limit >= requested_limit then p_note
                              else coalesce(v_note, '') end
   where school_id = p_school_id and status = 'pending'
  returning id, requested_limit into v_req, v_asked;

  -- Against the school, so its owner sees it on their own audit screen: they
  -- asked, and this is the answer.
  insert into public.audit_log
    (school_id, actor, actor_role, action, entity, entity_id, before, after, reason)
  values (p_school_id, auth.uid(), null,
          'STUDENT_LIMIT_GRANTED', 'subscriptions', p_school_id::text,
          jsonb_build_object('override', v_was, 'plan_covers', v_plan),
          jsonb_build_object('override', p_limit, 'request', v_req),
          v_note);

  perform public.fn_refresh_student_count(p_school_id);

  return jsonb_build_object(
    'school_id', p_school_id, 'limit', p_limit, 'was', v_was,
    'plan_covers', v_plan, 'request', v_req,
    'partial', v_req is not null and p_limit < v_asked);
end;
$$;

revoke all on function public.fn_platform_grant_student_limit(uuid, integer, text)
  from public, anon;
grant execute on function public.fn_platform_grant_student_limit(uuid, integer, text)
  to authenticated;

-- Declining, which needs a reason the school can read. A request that goes
-- quiet is the thing that produces a phone call.
create or replace function public.fn_platform_decline_student_limit(
  p_request_id uuid, p_note text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_school uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_note is null or length(v_note) < 8 then
    raise exception 'Say why, in a sentence the school will read. A request '
      'that comes back with nothing on it is worse than one still waiting.';
  end if;

  update public.student_limit_requests
     set status = 'declined', decided_by = auth.uid(), decided_at = now(),
         decision_note = v_note
   where id = p_request_id and status = 'pending'
  returning school_id into v_school;
  if v_school is null then
    raise exception 'No request waiting with that id';
  end if;

  insert into public.audit_log
    (school_id, actor, actor_role, action, entity, entity_id, after, reason)
  values (v_school, auth.uid(), null,
          'STUDENT_LIMIT_DECLINED', 'subscriptions', v_school::text,
          jsonb_build_object('request', p_request_id), v_note);

  return jsonb_build_object('id', p_request_id, 'status', 'declined');
end;
$$;

revoke all on function public.fn_platform_decline_student_limit(uuid, text)
  from public, anon;
grant execute on function public.fn_platform_decline_student_limit(uuid, text)
  to authenticated;

-- Taking one back, for the school that shrank or the exception that has run
-- its course. Separate from granting so it cannot happen by passing a null.
create or replace function public.fn_platform_clear_student_limit(
  p_school_id uuid, p_note text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_note text := nullif(btrim(coalesce(p_note, '')), ''); v_was integer;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_note is null or length(v_note) < 8 then
    raise exception 'Say why the allowance is being taken back: it may stop '
      'them admitting a pupil tomorrow, and somebody will ask.';
  end if;

  select student_limit_override into v_was from public.subscriptions
   where school_id = p_school_id;

  update public.subscriptions
     set student_limit_override        = null,
         student_limit_override_reason = null,
         student_limit_override_by     = auth.uid(),
         student_limit_override_at     = now()
   where school_id = p_school_id;

  insert into public.audit_log
    (school_id, actor, actor_role, action, entity, entity_id, before, after, reason)
  values (p_school_id, auth.uid(), null,
          'STUDENT_LIMIT_CLEARED', 'subscriptions', p_school_id::text,
          jsonb_build_object('override', v_was),
          jsonb_build_object('override', null), v_note);

  perform public.fn_refresh_student_count(p_school_id);
  return jsonb_build_object('school_id', p_school_id, 'was', v_was,
                            'limit', public.fn__student_limit(p_school_id));
end;
$$;

revoke all on function public.fn_platform_clear_student_limit(uuid, text)
  from public, anon;
grant execute on function public.fn_platform_clear_student_limit(uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 8. WHAT THE SCHOOL IS TOLD, AND WHEN
--
-- fn_my_licence has always computed the breach. What it did with it was:
--
--     v_tell := v_status in ('grace', 'locked', 'cancelled')
--            or (v_days is not null and v_days <= 30);
--     ...
--     'limit_notice', case
--       when not v_tell then null
--       when v_state = 'over' then
--         format('You have %s students, above the %s your plan covers. We will
--                 move you to the right plan at your next renewal. Nothing
--                 stops working.', ...)
--
-- Three things wrong with that once the limit actually bites. It says nothing
-- until a renewal is thirty days away, so a school can spend eleven months
-- walking towards a wall it is never shown. It says nothing at all until
-- already OVER, so the first warning arrives after the first refusal. And its
-- last sentence, "Nothing stops working", is about to become false.
--
-- After this: the notice appears from 90% of the limit, whatever the renewal
-- date, and says what happens at 100% and both ways out. It still says
-- nothing below 90%, because a banner a school sees every day is a banner it
-- stops reading.
--
-- Five anchors, each a single line. Patched rather than restated because 0127
-- added term_months to this same function four hours ago and restating would
-- silently drop it.
-- ---------------------------------------------------------------------------
do $lic$
declare v_src text; v_new text; v_pat text;
begin
  v_src := pg_get_functiondef('public.fn_my_licence()'::regprocedure);
  if position('fn__student_limit' in v_src) > 0 then
    raise notice '0128: fn_my_licence already reports the limit that applies';
    return;
  end if;

  -- (a) The effective limit, once, into a variable the rest can use. The plan's
  --     number is no longer the whole answer: an operator can have granted this
  --     school an allowance.
  if position('  v_margin := public.plan_margin_limit(v_plan.student_limit);' in v_src) = 0 then
    raise exception '0128: fn_my_licence no longer computes the margin from the '
      'plan''s limit. It has been rewritten since. The change is to take the '
      'limit from public.fn__student_limit(v_school), which is the plan''s '
      'limit or the allowance an operator granted this school, and to use that '
      'everywhere the plan''s own number was used.';
  end if;
  v_new := replace(v_src,
    '  v_margin := public.plan_margin_limit(v_plan.student_limit);',
    '  -- THE LIMIT THAT ACTUALLY APPLIES (0128): the plan''s, unless an' || E'\n' ||
    '  -- operator granted this school an allowance. One call, so nothing below' || E'\n' ||
    '  -- can read the plan''s number by mistake.' || E'\n' ||
    '  v_limit  := public.fn__student_limit(v_school);' || E'\n' ||
    '  v_margin := public.plan_margin_limit(v_limit);');

  -- (b) The declaration for it.
  if position('  v_margin integer;' in v_new) = 0 then
    raise exception '0128: fn_my_licence does not declare v_margin where this '
      'migration expects to declare v_limit beside it';
  end if;
  v_new := replace(v_new, '  v_margin integer;',
                          '  v_limit  integer;   -- 0128' || E'\n' || '  v_margin integer;');

  -- (c) The state machine and the reported figure.
  v_new := replace(v_new,
    '    when v_plan.student_limit is null then ''ok''          -- custom: no limit',
    '    when v_limit is null then ''ok''          -- custom: no limit');
  v_new := replace(v_new,
    '    when v_sub.student_count <= v_plan.student_limit then ''ok''',
    '    when v_sub.student_count <= v_limit then ''ok''');
  v_new := replace(v_new,
    '    ''student_limit'',  v_plan.student_limit,',
    '    ''student_limit'',  v_limit,' || E'\n' ||
    '    -- 0128: what the PLAN covers, beside what this school is allowed, so' || E'\n' ||
    '    -- a screen can say "150 plus 80 we granted you" rather than just 230.' || E'\n' ||
    '    ''plan_student_limit'', v_plan.student_limit,' || E'\n' ||
    '    ''limit_is_granted'', v_limit is distinct from v_plan.student_limit,' || E'\n' ||
    '    -- 0128: room left, and the 90% line, computed here so every screen' || E'\n' ||
    '    -- agrees about when the warning starts.' || E'\n' ||
    '    ''room'', case when v_limit is null then null' || E'\n' ||
    '                 else greatest(v_limit - v_sub.student_count, 0) end,' || E'\n' ||
    '    ''at_limit'', v_limit is not null and v_sub.student_count >= v_limit,' || E'\n' ||
    '    ''warn_limit'', v_limit is not null' || E'\n' ||
    '                  and v_sub.student_count >= ceil(v_limit * 0.9),' || E'\n' ||
    '    -- 0128: THE SAME NEWS, WORDED FOR SOMEBODY WHO CANNOT ACT ON IT.' || E'\n' ||
    '    --' || E'\n' ||
    '    -- The banner has always shown limit_notice to the owner and the' || E'\n' ||
    '    -- principal only, and the reason was sound while the limit was' || E'\n' ||
    '    -- advisory: a clerk shown "you are over your plan" reads it as "stop' || E'\n' ||
    '    -- admitting children", which was exactly the behaviour the soft limit' || E'\n' ||
    '    -- existed to avoid. That reasoning inverts the moment the limit is' || E'\n' ||
    '    -- enforced. The clerk is the person who presses Admit, so a clerk who' || E'\n' ||
    '    -- is told nothing meets the refusal for the first time with a parent' || E'\n' ||
    '    -- standing at the desk.' || E'\n' ||
    '    --' || E'\n' ||
    '    -- So they are told, in their own words: what is happening, that it is' || E'\n' ||
    '    -- not their doing, and who can fix it. It does not send them to' || E'\n' ||
    '    -- Settings then Subscription, which they cannot open.' || E'\n' ||
    '    ''limit_notice_staff'', case' || E'\n' ||
    '      when v_limit is null then null' || E'\n' ||
    '      when v_sub.student_count >= v_limit then' || E'\n' ||
    '        format(''The roll is full: %s pupils, which is everything this '' ||' || E'\n' ||
    '               ''school''''s plan covers. New admissions are paused until the '' ||' || E'\n' ||
    '               ''owner or principal asks for more room. Everything else, '' ||' || E'\n' ||
    '               ''including the register and the fees, works normally.'',' || E'\n' ||
    '               v_sub.student_count)' || E'\n' ||
    '      when v_sub.student_count >= ceil(v_limit * 0.9) then' || E'\n' ||
    '        format(''%s of %s places on the roll are used. When the last one '' ||' || E'\n' ||
    '               ''goes, new admissions pause until the owner or principal '' ||' || E'\n' ||
    '               ''asks for more room, so it is worth mentioning to them.'',' || E'\n' ||
    '               v_sub.student_count, v_limit)' || E'\n' ||
    '      else null end,');

  -- (d) The notice itself, which is the point of the section.
  if position('      when not v_tell then null' in v_new) = 0 then
    raise exception '0128: fn_my_licence''s limit_notice is no longer gated on '
      'v_tell. It has been rewritten since. The change is to say it from 90%% '
      'of the limit whatever the renewal date, and to stop promising that '
      'nothing stops working, because at 100%% an admission is refused.';
  end if;
  -- Four lines, so the needle goes through fn__anchor_regex: a bare line feed
  -- cannot match a body stored from a CRLF paste, and this rewrite failing
  -- silently would leave a school with a limit that blocks admissions and a
  -- notice that still promises nothing stops working.
  v_pat := public.fn__anchor_regex(
    '      when not v_tell then null' || E'\n' ||
    '      when v_state = ''over'' then' || E'\n' ||
    '        format(''You have %s students, above the %s your plan covers. We will move you to the right plan at your next renewal. Nothing stops working.'',' || E'\n' ||
    '               v_sub.student_count, v_plan.student_limit)');
  v_new := regexp_replace(v_new, v_pat,
    '      -- 0128: FROM 90%, WHATEVER THE RENEWAL DATE, because at 100% an' || E'\n' ||
    '      -- admission is refused and the first warning must not arrive after' || E'\n' ||
    '      -- the first refusal. v_tell no longer gates this: it gates the' || E'\n' ||
    '      -- renewal conversation, and a full roll is not one.' || E'\n' ||
    '      when v_limit is null then null' || E'\n' ||
    '      when v_sub.student_count >= v_limit then' || E'\n' ||
    '        format(''Your roll is full: %s pupils, and your plan covers %s. '' ||' || E'\n' ||
    '               ''New admissions are paused until there is room. Ask us for '' ||' || E'\n' ||
    '               ''more room, or to be moved up a plan, from Settings then '' ||' || E'\n' ||
    '               ''Subscription. Everything already entered is untouched.'',' || E'\n' ||
    '               v_sub.student_count, v_limit)' || E'\n' ||
    '      when v_sub.student_count >= ceil(v_limit * 0.9) then' || E'\n' ||
    '        format(''%s of the %s pupils your plan covers. At %s, new '' ||' || E'\n' ||
    '               ''admissions pause until there is room, so if you are '' ||' || E'\n' ||
    '               ''expecting more children this term, ask us now from '' ||' || E'\n' ||
    '               ''Settings then Subscription. It takes a minute and it '' ||' || E'\n' ||
    '               ''costs nothing to ask.'',' || E'\n' ||
    '               v_sub.student_count, v_limit, v_limit)');

  if v_new = v_src or position('fn__student_limit' in v_new) = 0 then
    raise exception '0128: the fn_my_licence rewrite did not take';
  end if;
  execute v_new;
  raise notice '0128: a school is warned from 90%% of its limit, whatever the '
    'renewal date, and told both ways out';
end $lic$;

-- ---------------------------------------------------------------------------
-- 8b. THE OPERATOR'S OWN VIEW OF ONE SCHOOL
--
-- fn_platform_school_detail's licence block reported public.plans.student_limit,
-- which was the whole truth until this migration invented the allowance. After
-- it, the number on the operator's screen is the one number on the platform
-- that is NOT what the school is allowed: grant a school 400 against Starter's
-- 150 and this page still says 150, still paints "over limit", and still
-- advises moving them up. The operator would then grant the allowance a second
-- time, or ring a school that is perfectly fine.
--
-- It also gains the pending request, because an operator granting from this
-- page rather than from the queue is otherwise granting blind: they cannot see
-- that the school has already asked, for how many, or why.
--
-- Patched rather than restated: 0077 rewrote this same function's money block
-- and restating from 0075's text would silently undo it.
-- ---------------------------------------------------------------------------
do $det$
declare v_src text; v_new text; v_pat text;
begin
  v_src := pg_get_functiondef('public.fn_platform_school_detail(uuid)'::regprocedure);
  if position('fn__student_limit' in v_src) > 0 then
    raise notice '0128: fn_platform_school_detail already reports the limit that applies';
    return;
  end if;

  -- (a) The effective limit in place of the plan's, with the plan's kept beside
  --     it so the console can say "150 on the plan plus 250 we granted".
  if position($a$        'student_count', v_sub.student_count, 'student_limit', v_plan.student_limit,$a$ in v_src) = 0 then
    raise exception '0128: fn_platform_school_detail no longer reports '
      'student_limit from the plan. It has been rewritten since. The change is '
      'to report public.fn__student_limit(p_school_id) as student_limit, keep '
      'the plan''s own number as plan_student_limit, and use the effective '
      'limit in limit_state.';
  end if;
  v_new := replace(v_src,
    $a$        'student_count', v_sub.student_count, 'student_limit', v_plan.student_limit,$a$,
    $a$        'student_count', v_sub.student_count,$a$ || E'\n' ||
    $a$        -- 0128: WHAT THEY ARE ALLOWED, not what the price list says. An$a$ || E'\n' ||
    $a$        -- allowance an operator granted is the whole point of this$a$ || E'\n' ||
    $a$        -- migration, and a console showing the plan's number instead$a$ || E'\n' ||
    $a$        -- would have the operator grant it twice.$a$ || E'\n' ||
    $a$        'student_limit', public.fn__student_limit(p_school_id),$a$ || E'\n' ||
    $a$        'plan_student_limit', v_plan.student_limit,$a$ || E'\n' ||
    $a$        'limit_override', v_sub.student_limit_override,$a$ || E'\n' ||
    $a$        'limit_override_reason', v_sub.student_limit_override_reason,$a$ || E'\n' ||
    $a$        'limit_override_at', v_sub.student_limit_override_at,$a$ || E'\n' ||
    $a$        -- Who granted it, by name, because "who agreed to this?" is the$a$ || E'\n' ||
    $a$        -- first question asked about an exception six months later.$a$ || E'\n' ||
    $a$        'limit_override_by', (select pr.full_name from public.profiles pr$a$ || E'\n' ||
    $a$                               where pr.id = v_sub.student_limit_override_by),$a$ || E'\n' ||
    $a$        -- The request waiting, if there is one. An operator granting from$a$ || E'\n' ||
    $a$        -- this page instead of the queue is otherwise granting blind.$a$ || E'\n' ||
    $a$        'limit_request', (select jsonb_build_object($a$ || E'\n' ||
    $a$                                   'id', r.id, 'requested_limit', r.requested_limit,$a$ || E'\n' ||
    $a$                                   'reason', r.reason, 'wants', r.wants,$a$ || E'\n' ||
    $a$                                   'requested_at', r.requested_at)$a$ || E'\n' ||
    $a$                            from public.student_limit_requests r$a$ || E'\n' ||
    $a$                           where r.school_id = p_school_id$a$ || E'\n' ||
    $a$                             and r.status = 'pending'),$a$);

  -- (b) The state machine, on the effective limit. Left saying 'over' against
  --     the plan's number, the console would paint a red chip on a school that
  --     is inside the room we ourselves gave it.
  if position($b$          when v_plan.student_limit is null then 'ok'$b$ in v_new) = 0 then
    raise exception '0128: fn_platform_school_detail''s limit_state no longer '
      'reads the plan''s limit where this migration expects to swap in the '
      'effective one';
  end if;
  -- Two lines, so the needle goes through fn__anchor_regex for the same
  -- reason as fn_my_licence above.
  v_pat := public.fn__anchor_regex(
    $b$          when v_plan.student_limit is null then 'ok'$b$ || E'\n' ||
    $b$          when v_sub.student_count <= v_plan.student_limit then 'ok'$b$);
  v_new := regexp_replace(v_new, v_pat,
    $b$          when public.fn__student_limit(p_school_id) is null then 'ok'$b$ || E'\n' ||
    $b$          when v_sub.student_count$b$ || E'\n' ||
    $b$                 <= public.fn__student_limit(p_school_id) then 'ok'$b$);

  -- (c) The margin too, which is derived from the limit and is what
  --     'within_margin' is measured against.
  if position('    v_margin := public.plan_margin_limit(v_plan.student_limit);' in v_new) = 0 then
    raise exception '0128: fn_platform_school_detail no longer computes its '
      'margin from the plan''s limit';
  end if;
  v_new := replace(v_new,
    '    v_margin := public.plan_margin_limit(v_plan.student_limit);',
    '    v_margin := public.plan_margin_limit(' || E'\n' ||
    '                  public.fn__student_limit(p_school_id));');

  if v_new = v_src or position('fn__student_limit' in v_new) = 0 then
    raise exception '0128: the fn_platform_school_detail rewrite did not take';
  end if;
  execute v_new;
  raise notice '0128: the console reports the limit a school is actually '
    'allowed, who granted it, and any request waiting';
end $det$;

-- ---------------------------------------------------------------------------
-- 9. WHO IS OVER, RIGHT NOW
--
-- NOT GRANDFATHERED, and this is the one place where that decision is visible.
-- Recording every over-limit school's current count as an allowance would make
-- the limit change nothing on the day it starts existing. So this reports, and
-- the console grants. The counts are refreshed first, because
-- subscriptions.student_count is a cached figure and a stale one would name the
-- wrong schools.
-- ---------------------------------------------------------------------------
do $report$
declare r record; v_n integer := 0;
begin
  for r in
    select s.id, s.name from public.schools s
      join public.subscriptions sub on sub.school_id = s.id
     where s.active
  loop
    begin
      perform public.fn_refresh_student_count(r.id);
    exception when others then
      -- A school with no plan row, or one mid-repair. Not this migration's
      -- problem, and not a reason to stop reporting the others.
      null;
    end;
  end loop;

  for r in
    select s.name,
           public.fn_count_students(s.id) as students,
           public.fn__student_limit(s.id) as allowed
      from public.schools s
      join public.subscriptions sub on sub.school_id = s.id
     where s.active
     order by s.name
  loop
    if r.allowed is not null and r.students > r.allowed then
      v_n := v_n + 1;
      raise notice '0128: "%" has % pupils and is allowed %. They cannot admit '
        'another until the console grants them room. Nothing they already have '
        'is affected.', r.name, r.students, r.allowed;
    end if;
  end loop;

  if v_n = 0 then
    raise notice '0128: no active school is over its limit';
  else
    raise notice '0128: % school(s) are over. Grant an allowance from the '
      'operator console (Schools, open one, Student limit) or leave it and they '
      'will ask.', v_n;
  end if;
end $report$;

-- ---------------------------------------------------------------------------
-- THE GUARDS. Properties, not restatements.
-- ---------------------------------------------------------------------------
do $check$
declare v_n integer; v_name text;
begin
  -- 1. STILL EXACTLY ONE FUNCTION INSERTS A PUPIL. The whole reason the gate
  --    sits in fn_admit_student rather than in three places is that
  --    fn_enquiry_admit and fn_import_students come through it. A future
  --    migration that adds a second insert path would walk straight past the
  --    limit, and this is what stops that being silent.
  for v_name in
    select p.proname from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and p.prosrc ~ 'insert into public\.students'
       and p.proname <> 'fn_admit_student'
  loop
    raise exception '0128: % inserts a pupil without going through '
      'fn_admit_student, so it can put a school past its plan''s limit. Either '
      'route it through fn_admit_student or call '
      'fn__assert_room_for_students(school, n) first.', v_name;
  end loop;

  -- 2. And all three paths that can raise a roll carry the gate.
  select count(*) into v_n from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('fn_admit_student', 'fn_set_student_status',
                       'fn_import_students')
     and p.prosrc ~ 'fn__assert_room_for_students';
  if v_n <> 3 then
    raise exception '0128: % of the 3 paths that can raise a roll check the '
      'limit (admission, coming back from a leaving state, and the importer)', v_n;
  end if;

  -- 3. AND fn_rollover DOES NOT, which is as important as the three that do.
  --    It inserts enrolments for next year, which is the same children a year
  --    older. Gating it would stop a school over its limit starting its
  --    academic year: no register, no challans, no classes. That is not
  --    enforcement, it is taking the product away.
  if (select p.prosrc ~ 'fn__assert_room_for_students' from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'fn_rollover') then
    raise exception '0128: fn_rollover checks the student limit. It must not: '
      'rolling a year over is the same children a year older, and refusing it '
      'stops a school over its limit from starting its year at all.';
  end if;

  -- 4. The request box is readable by the school and by us, and writable by
  --    neither directly. Every write goes through a function that checks who
  --    is asking; a school able to insert its own row could mark it granted.
  select count(*) into v_n from pg_policies
   where schemaname = 'public' and tablename = 'student_limit_requests';
  if v_n <> 2 then
    raise exception '0128: student_limit_requests has % policies, expected the '
      'two SELECTs (the school''s own, and the platform''s)', v_n;
  end if;
  if exists (select 1 from pg_policies
              where schemaname = 'public' and tablename = 'student_limit_requests'
                and cmd <> 'SELECT') then
    raise exception '0128: student_limit_requests has a write policy. A school '
      'that can insert its own request can insert one marked granted.';
  end if;

  -- 5. No internal helper is reachable from a browser, which is 0125's rule
  --    and this migration adds two more fn__ functions to it.
  for v_name in
    select p.proname from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('fn__student_limit', 'fn__assert_room_for_students')
       and (has_function_privilege('authenticated', p.oid, 'execute')
            or has_function_privilege('anon', p.oid, 'execute'))
  loop
    raise exception '0128: % is callable from a browser', v_name;
  end loop;

  -- 6. And the operator's three are operator-only. Granting an allowance from
  --    a school's own browser is the loophole this migration exists to close,
  --    wearing a different hat.
  for v_name in
    select p.proname from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('fn_platform_grant_student_limit',
                         'fn_platform_decline_student_limit',
                         'fn_platform_clear_student_limit')
       and p.prosrc !~ 'is_platform_admin'
  loop
    raise exception '0128: % does not check is_platform_admin, so a school '
      'could grant itself room', v_name;
  end loop;

  -- 7. AND THE READ GOES THROUGH may_view (0059). verify.sql's observer row
  --    is an EXACT check: any STABLE security-definer function gating on
  --    has_role fails it, because has_role excludes the observer role and an
  --    operator on a support visit. fn_my_student_limit is a read, so it uses
  --    may_view. This is the assertion rather than a comment because the row
  --    that caught it lives in another file.
  if (select p.prosrc ~ 'has_role\(' from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'fn_my_student_limit') then
    raise exception '0128: fn_my_student_limit gates a read on has_role, which '
      'shuts out the observer role and an operator on a support visit. Use '
      'may_view: see migration 0059 and verify.sql''s observer row.';
  end if;

  -- 8. NOTHING TELLS A SCHOOL TO CHANGE ITS OWN PLAN, because nothing in this
  --    product lets it. fn_activate_subscription is operator-only, the term
  --    chooser changes how often they pay and not what they are on, and every
  --    renewal is a bank transfer somebody here confirms by hand. The first
  --    draft of fn_request_student_limit ended its reply with "you can still
  --    move up a plan yourself from this screen", which sent a school looking
  --    for a button that does not exist. Asserted as a property so a future
  --    edit cannot put it back while this stays true.
  for v_name in
    select p.proname from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('fn_request_student_limit', 'fn_my_student_limit',
                         'fn_my_licence')
       -- MATCHED ON THE SOURCE WITH ITS COMMENTS STRIPPED. The first version
       -- of this guard fired on the comment inside fn_request_student_limit
       -- that explains what the sentence used to say and why it was removed. A
       -- guard that cannot tell a warning from the thing it is warning about is
       -- a guard somebody deletes rather than reads. Same lesson as
       -- scripts/check-raise-format.py, which scans a RAISE's format string
       -- rather than the whole statement.
       -- '--.*' with the n flag, NOT a hand-built class around chr(10). In
       -- newline-sensitive mode a dot does not cross a line break, and naming
       -- one line ending would have been the very mistake the anchor checker
       -- exists to catch: a body stored from a CRLF paste carries the other.
       and regexp_replace(p.prosrc, '--.*', '', 'gn')
             ~* ('move up a plan yourself|upgrade yourself'
                 || '|change your (own )?plan yourself')
  loop
    raise exception '0128: % tells a school it can change its own plan. It '
      'cannot: fn_activate_subscription is operator-only and there is no '
      'self-serve plan change anywhere in this product. Say "ask us" instead, '
      'or build the plan change first.', v_name;
  end loop;

  -- 9. And the request carries WHICH of the two things they asked for, as a
  --    value. The operator's answer to "more room" and to "move us up" are
  --    completely different acts, and reading the difference out of prose is a
  --    phone call per request.
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public'
                    and table_name = 'student_limit_requests'
                    and column_name = 'wants') then
    raise exception '0128: student_limit_requests has no wants column, so the '
      'operator cannot tell an exception request from an upgrade request '
      'without phoning the school';
  end if;

  raise notice '0128: a plan''s student limit is enforced on every path that '
    'can raise a roll, and on none that cannot';
end $check$;
