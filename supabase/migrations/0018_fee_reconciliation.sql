-- =============================================================================
-- Fee reconciliation — the plan's headline anti-fraud control (03-FEATURES):
-- "expected-vs-collected + ghost-student check", which catches cash that was
-- never recorded at all (gapless receipts only catch under-recording of payments
-- that WERE entered).
--
--   expected  = everything billed this session (non-void invoice charges + fines)
--   collected = payments actually allocated to those invoices
--   outstanding = expected − collected
--
-- Plus two watch-lists:
--   * uninvoiced   — active students with NO invoice this session (a billing gap;
--                    also how a student could be quietly kept off the books).
--   * ghost_suspects — active students with no invoice AND no attendance ever
--                    (a name on the roll that may not be a real, present child).
-- Finance roles only.
-- =============================================================================

create or replace function public.fn_fee_reconciliation(p_session_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_expected  numeric;
  v_collected numeric;
  v_by_class  jsonb;
  v_uninv     jsonb;
  v_ghost     jsonb;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to view fee reconciliation';
  end if;

  select coalesce(sum(charge), 0), coalesce(sum(allocated), 0)
    into v_expected, v_collected
  from public.invoice_balances where session_id = p_session_id;

  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) into v_by_class
  from (
    select c.name as class_name,
           coalesce(sum(b.charge), 0) as expected,
           coalesce(sum(b.allocated), 0) as collected,
           coalesce(sum(b.charge - b.allocated), 0) as outstanding
    from public.invoice_balances b
    join public.enrollments e on e.id = b.enrollment_id
    join public.classes c on c.id = e.class_id
    where b.session_id = p_session_id
    group by c.name, c.level_order
    order by c.level_order
  ) t;

  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) into v_uninv
  from (
    select s.gr_no, s.full_name, c.name as class_name
    from public.enrollments e
    join public.students s on s.id = e.student_id
    join public.classes c on c.id = e.class_id
    where e.session_id = p_session_id and e.status = 'active'
      and not exists (select 1 from public.invoices i
                      where i.enrollment_id = e.id and i.status <> 'void')
    order by c.level_order, s.full_name
  ) t;

  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) into v_ghost
  from (
    select s.gr_no, s.full_name, c.name as class_name
    from public.enrollments e
    join public.students s on s.id = e.student_id
    join public.classes c on c.id = e.class_id
    where e.session_id = p_session_id and e.status = 'active'
      and not exists (select 1 from public.invoices i
                      where i.enrollment_id = e.id and i.status <> 'void')
      and not exists (select 1 from public.attendance_daily ad where ad.enrollment_id = e.id)
    order by c.level_order, s.full_name
  ) t;

  return jsonb_build_object(
    'expected', v_expected,
    'collected', v_collected,
    'outstanding', v_expected - v_collected,
    'by_class', v_by_class,
    'uninvoiced', v_uninv,
    'ghost_suspects', v_ghost);
end;
$$;

grant execute on function public.fn_fee_reconciliation(uuid) to authenticated;
