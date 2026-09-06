-- =============================================================================
-- 0109: The history said "what we have done to this school" and three of the
--       things on it were done by the school
--
-- FOUND BY A SECOND OPINION, AND MY OWN SWEEP MISSED IT.
--
-- 0108 went through every action name in this schema to give the operator's
-- History feed a readable sentence for each. It enumerated them with
--
--     grep -o "fn__log_operator_action('[a-z_]*'"
--
-- and that character class does not contain a dot, so three call sites matched
-- nothing and were never seen. They are the three in 0094:
--
--     student.deleted     staff.deleted     login.deleted
--
-- Every other action in this schema is named entity_verb with an underscore.
-- These three use entity.verb with a dot, so describeAction's fallback -
-- replace(/_/g, ' ') - left them exactly as they were, and the operator's
-- history literally read "login.deleted". A regex that excluded precisely the
-- rows that were misnamed.
--
-- THE BIGGER HALF, WHICH THE NAMING WAS HIDING.
--
-- fn_delete_student, fn_delete_staff and fn_delete_login are granted to
-- `authenticated`. They are called by the SCHOOL'S OWN OFFICE, from the school's
-- own screens, and they write into operator_actions - the table whose reader is
-- titled, on screen, "What we have done to this school".
--
-- So a principal deleting a duplicate pupil record appeared in the vendor's
-- audit feed as something the vendor had done, with no actor beside it. Read
-- back a year later in a dispute about who removed a child's records, that is
-- not a cosmetic problem.
--
-- The fix is not to stop logging them: the school deleting a pupil is exactly
-- the kind of thing worth keeping. It is to record WHO, so the feed can say so.
-- actor_email is already null for a school clerk, because it is looked up in
-- platform_admins - but null also means a cron or service-role action, so the
-- two cannot be told apart from the email alone. by_operator answers it
-- directly, from the membership table, at read time.
--
-- The three call sites are also renamed to the convention everything else uses.
-- Rows already written keep the old spelling forever, so the app normalises the
-- dot away and one case covers both.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. A reader that says who, UNDER A NEW NAME
--
-- WHY A NEW NAME RATHER THAN A COLUMN ON THE OLD ONE, which is what this
-- migration did in its first draft.
--
-- Adding an OUT column means DROP and CREATE: `create or replace` cannot change
-- a function's return type. That works, and the preflight caught what it costs.
-- 0073 lives in bundle 7, which is frozen and already pasted into a live school,
-- and its `create or replace function public.fn_platform_school_actions(...)`
-- carries the OLD return type. So the moment this migration changed that
-- signature, re-pasting bundle 7 - which the setup instructions explicitly tell
-- a school to do if it is unsure a paste took - failed with "cannot change
-- return type of existing function" and rolled the WHOLE bundle back.
--
-- And a rolled-back bundle 7 is not harmless. Bundle 6 carries 0059, whose loop
-- rewrites every STABLE SECURITY DEFINER function containing has_role( into
-- may_view(, which is has_role(...) OR has_role('readonly'). fn_may_mark_subject
-- is created by 0085 in bundle 7, AFTER 0059, so on a first install 0059 never
-- sees it and it correctly keeps has_role. On a re-paste 0059 does see it and
-- converts it - and the only thing that put it back was bundle 7 re-applying
-- afterwards. With bundle 7 rolling back, the gate deciding WHO MAY ENTER MARKS
-- silently started admitting the readonly role.
--
-- One column on a return type is not worth that. The old function keeps its
-- exact signature and stays re-pastable; this is a new function beside it.
-- 0110 closes the readonly hole underneath, which was only ever being covered
-- by bundle 7 happening to re-apply.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_school_activity(
  p_school_id uuid, p_limit integer default 100
) returns table (
  at timestamptz, actor_email text, action text, detail jsonb, by_operator boolean
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
    select a.at, a.actor_email, a.action, a.detail,
           -- Answered from the membership table rather than from actor_email
           -- being null, because null there means EITHER a school clerk OR a
           -- cron/service-role action, and those are different sentences.
           exists (select 1 from public.platform_admins pa where pa.user_id = a.actor)
             as by_operator
      from public.operator_actions a
     where a.school_id = p_school_id
     order by a.at desc
     limit greatest(1, least(coalesce(p_limit, 100), 500));
end;
$$;

grant  execute on function public.fn_platform_school_activity(uuid, integer) to authenticated;
revoke execute on function public.fn_platform_school_activity(uuid, integer) from public, anon;

comment on function public.fn_platform_school_activity(uuid, integer) is
  'The operator history feed, with by_operator saying whether WE did each thing '
  'or the SCHOOL did. Supersedes fn_platform_school_actions, which is kept at '
  'its original signature so bundle 7 stays re-pastable.';

-- ---------------------------------------------------------------------------
-- 2. The three names join the convention
--
-- Patched in place rather than recreated: fn_delete_student and its two
-- siblings are 60 lines each of blocker checks that 0094 argued carefully, and
-- copying them here to change one string would leave two versions of that
-- argument in the repository.
--
-- The anchor is a SINGLE LINE with no newline inside it, which is the whole
-- lesson of 0101: a match spanning a line break fails on a database whose
-- bodies are stored CRLF, and every one of this customer's is, because bundles
-- are pasted through a browser editor. Warn and skip rather than raise: a
-- function that has already been renamed is not an error, and one raise rolls
-- back the entire pasted bundle.
-- ---------------------------------------------------------------------------
do $rename$
declare
  r record; v_src text; v_new text; v_done int := 0; v_skip int := 0;
begin
  for r in
    -- A VALUES alias list takes column NAMES ONLY. Writing `as t(fn text, ...)`
    -- is the FROM-a-function spelling and the parser rejects it here, so the
    -- types are cast on the first row instead. `old` and `new` are also
    -- unusable as aliases: PL/pgSQL reserves both for rule and trigger contexts.
    select * from (values
      ('public.fn_delete_student(uuid)'::text, 'student.deleted'::text, 'student_deleted'::text),
      ('public.fn_delete_staff(uuid)',         'staff.deleted',         'staff_deleted'),
      ('public.fn_delete_login(uuid)',         'login.deleted',         'login_deleted')
    ) as t(fn, was, now_called)
  loop
    if to_regprocedure(r.fn) is null then
      raise warning '0109: % does not exist; skipping the rename', r.fn;
      v_skip := v_skip + 1;
      continue;
    end if;
    v_src := pg_get_functiondef(r.fn::regprocedure);
    v_new := replace(v_src, '''' || r.was || '''', '''' || r.now_called || '''');
    if v_new = v_src then
      raise warning '0109: % does not log %; leaving it alone', r.fn, r.was;
      v_skip := v_skip + 1;
    else
      execute v_new;
      v_done := v_done + 1;
    end if;
  end loop;
  raise notice '0109: % of 3 deletion actions renamed, % skipped', v_done, v_skip;
end
$rename$;

-- Rows already written keep 'student.deleted' forever. Deliberately NOT
-- rewritten: an audit table whose past is edited to look tidier is an audit
-- table nobody can rely on. The app normalises the dot to an underscore when it
-- reads, so one case in describeAction covers both spellings.
