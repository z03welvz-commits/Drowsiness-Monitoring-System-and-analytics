-- Settings > Personal Info: let a signed-in user update their own
-- display_name. Until now the only UPDATE policy on profiles was
-- profiles_update_admin (an approved admin updating ANY row) — a regular
-- user had no way to persist a name change to their own profile at all.
--
-- RLS's WITH CHECK only sees the proposed new row, not the old one, so it
-- can't by itself express "role/status/username must be unchanged" —
-- that comparison needs OLD, which only a trigger has. So the RLS policy
-- below just answers "is this your own row", and a BEFORE UPDATE trigger
-- does the real guarding: it silently re-pins role/status/username back
-- to their prior value whenever the actor updating the row is NOT an
-- approved admin, so a non-admin's update can only ever actually change
-- display_name, regardless of what values they send. An approved admin
-- (already gated by profiles_update_admin) passes through untouched,
-- preserving Access Management's existing approve/reject/role-change
-- behavior exactly as before.

create policy profiles_update_self
  on public.profiles
  for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create or replace function public.profiles_guard_self_update()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_is_admin boolean;
begin
  select exists (
    select 1 from public.profiles p
    where p.user_id = auth.uid() and p.role = 'admin' and p.status = 'approved'
  ) into v_is_admin;

  if not v_is_admin then
    new.role := old.role;
    new.status := old.status;
    new.username := old.username;
  end if;

  return new;
end;
$function$;

drop trigger if exists trg_profiles_guard_self_update on public.profiles;
create trigger trg_profiles_guard_self_update
  before update on public.profiles
  for each row
  execute function public.profiles_guard_self_update();
