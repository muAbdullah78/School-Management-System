-- =============================================================================
-- Auth provisioning. A Supabase auth user has no application profile until one
-- is created in public.profiles — and the profiles_insert policy requires an
-- existing owner/principal, so the FIRST user could never get a profile from
-- the client (chicken-and-egg). This trigger closes that gap:
--
--   * every new auth user gets a profiles row automatically, and
--   * the very FIRST user becomes 'owner' (school bootstrap); everyone after
--     starts as 'readonly' for the owner/principal to assign a real role.
--
-- Making the first user owner removes a lockout footgun: if new users defaulted
-- to readonly and the owner skipped the manual SQL elevation, nobody could ever
-- assign roles in-app (readonly can't), and the school would be stuck.
-- =============================================================================

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_is_first boolean;
begin
  select count(*) = 0 into v_is_first from public.profiles;

  insert into public.profiles (id, full_name, role)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data->>'full_name', ''), split_part(coalesce(new.email, ''), '@', 1)),
    (case when v_is_first then 'owner' else 'readonly' end)::public.user_role
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
