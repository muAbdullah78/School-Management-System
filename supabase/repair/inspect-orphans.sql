-- =============================================================================
-- inspect-orphans.sql — what IS that row?
--
-- Read-only. Paste into the SQL Editor and Run.
--
-- verify.sql and why.sql will tell you a subscription names a school that no
-- longer exists. Neither will delete it, and neither should: a customer record
-- is the operator's to decide about, and "there is little to lose" is exactly
-- the reasoning that loses a school its data.
--
-- This prints everything the platform still holds about such an id — the
-- subscription itself, and any invoice, payment or operator action raised
-- against it — so the decision is made by looking rather than by assuming.
--
-- READ IT LIKE THIS:
--
--   * only a `subscription` row, with student_count 0, no period_start and no
--     invoice → an abandoned signup or a test school. Safe to delete.
--   * a `platform invoice` or `platform payment` as well → somebody was BILLED.
--     Do not delete anything: that is sales history, and the missing `schools`
--     row is the thing to investigate. Ask before touching it.
--
-- To remove one once you have decided, name it explicitly — never `delete from
-- subscriptions where not exists (...)`, which would take every orphan
-- including ones you have not looked at:
--
--     delete from public.subscriptions where school_id = '<the id>';
--
-- Then run bundle 9 (0091). It validates the foreign key, and from then on this
-- state is impossible rather than merely absent.
-- =============================================================================

select 'subscription'   as record, to_jsonb(s) as detail
  from public.subscriptions s
 where not exists (select 1 from public.schools sc where sc.id = s.school_id)
union all
select 'platform invoice', to_jsonb(i)
  from public.platform_invoices i
 where not exists (select 1 from public.schools sc where sc.id = i.school_id)
union all
select 'platform payment', to_jsonb(p)
  from public.platform_payments p
 where not exists (select 1 from public.schools sc where sc.id = p.school_id)
union all
select 'operator action', to_jsonb(a)
  from public.operator_actions a
 where not exists (select 1 from public.schools sc where sc.id = a.school_id);
