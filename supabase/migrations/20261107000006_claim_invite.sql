-- GoTrue's admin createUser inserts the auth row before app_metadata is written, so the
-- sign-up trigger cannot see the invite token. The approve-student function therefore
-- claims the invite right after creating the parent. Service role only.
create function public.claim_parent_invite(p_user uuid, p_token uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text;
  v_role public.app_role;
begin
  select lower(pr.email::text) into v_email
  from public.profiles pr
  where pr.id = p_user and pr.role = 'student' and pr.status in ('unconfirmed', 'pending')
  for update;
  if v_email is null then
    return false;
  end if;

  -- The profile must be a fresh, never-approved sign-up shell.
  if exists (select 1 from public.student_details d where d.profile_id = p_user and d.index_number is not null) then
    return false;
  end if;

  select i.role into v_role
  from public.pending_invites i
  where lower(i.email::text) = v_email and i.token = p_token and i.role = 'parent';
  if v_role is null then
    return false;
  end if;

  update public.profiles set role = v_role, status = 'active' where id = p_user;
  delete from public.student_details where profile_id = p_user;
  delete from public.pending_invites where lower(email::text) = v_email;
  return true;
end;
$$;

revoke execute on function public.claim_parent_invite(uuid, uuid) from public, anon, authenticated;
grant execute on function public.claim_parent_invite(uuid, uuid) to service_role;
