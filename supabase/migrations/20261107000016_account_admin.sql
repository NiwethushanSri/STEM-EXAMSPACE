-- Task 10b: account-admin state changes and self-deletion. Each function changes state AND writes its
-- audit row in one transaction. Authorization is re-derived from profiles here (never trusted from callers).

create function public.set_account_status_tx(p_target uuid, p_actor uuid, p_action text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_role public.app_role;
  v_role public.app_role;
  v_status public.account_status;
  v_new public.account_status;
begin
  if p_action not in ('suspend', 'reactivate') then
    return 'conflict';
  end if;

  select a.role into v_actor_role
  from public.profiles a where a.id = p_actor and a.status = 'active';
  if v_actor_role is null or v_actor_role not in ('owner', 'admin') then
    return 'forbidden';
  end if;

  select t.role, t.status into v_role, v_status
  from public.profiles t where t.id = p_target for update;
  if v_role is null then
    return 'not_found';
  end if;
  if p_target = p_actor or v_role = 'owner' or (v_actor_role = 'admin' and v_role = 'admin') then
    return 'forbidden';
  end if;

  if p_action = 'suspend' then
    if v_status not in ('active', 'profile_incomplete', 'pending') then
      return 'conflict';
    end if;
    v_new := 'suspended';
  else
    if v_status <> 'suspended' then
      return 'conflict';
    end if;
    if v_role <> 'student' then
      v_new := 'active';
    elsif exists (select 1 from public.student_subjects ss where ss.student_id = p_target) then
      v_new := 'active';
    elsif exists (select 1 from public.student_details d where d.profile_id = p_target and d.index_number is not null) then
      v_new := 'profile_incomplete';
    else
      v_new := 'pending';
    end if;
  end if;

  update public.profiles set status = v_new where id = p_target;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (p_actor, case p_action when 'suspend' then 'account_suspended' else 'account_reactivated' end, 'profile', p_target);
  return v_new::text;
end;
$$;

create function public.remove_staff_tx(p_target uuid, p_actor uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_role public.app_role;
  v_role public.app_role;
begin
  select a.role into v_actor_role
  from public.profiles a where a.id = p_actor and a.status = 'active';
  if v_actor_role is null or v_actor_role not in ('owner', 'admin') then
    return 'forbidden';
  end if;

  select t.role into v_role from public.profiles t where t.id = p_target for update;
  if v_role is null then
    return 'not_found';
  end if;
  if p_target = p_actor or v_role = 'owner' or (v_actor_role = 'admin' and v_role = 'admin') then
    return 'forbidden';
  end if;
  if v_role not in ('admin', 'teacher', 'tutor', 'corrector') then
    return 'conflict';
  end if;

  delete from auth.users where id = p_target;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (p_actor, 'staff_removed', 'profile', p_target);
  return 'removed';
end;
$$;

create function public.clear_invite_tx(p_email text, p_actor uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_role public.app_role;
  v_email text := lower(btrim(p_email));
  v_token uuid;
  v_invite_role public.app_role;
  v_shell uuid;
begin
  select a.role into v_actor_role
  from public.profiles a where a.id = p_actor and a.status = 'active';
  if v_actor_role is null or v_actor_role not in ('owner', 'admin') then
    return 'forbidden';
  end if;

  select i.token, i.role into v_token, v_invite_role
  from public.pending_invites i where lower(i.email::text) = v_email for update;
  if v_token is null then
    return 'not_found';
  end if;
  if v_invite_role <> 'parent' and v_actor_role <> 'owner' then
    return 'forbidden';
  end if;

  -- Only a token-bearing, never-approved sign-up shell for exactly this invite is deleted.
  select pr.id into v_shell
  from public.profiles pr
  join auth.users u on u.id = pr.id
  where lower(pr.email::text) = v_email
    and pr.role = 'student'
    and pr.status in ('unconfirmed', 'pending')
    and u.raw_app_meta_data ->> 'invite_token' = v_token::text
    and not exists (
      select 1 from public.student_details d
      where d.profile_id = pr.id
        and (d.index_number is not null or nullif(btrim(coalesce(d.signup_parent_email, '')), '') is not null)
    );

  delete from public.pending_invites where lower(email::text) = v_email;
  if v_shell is not null then
    delete from auth.users where id = v_shell;
  end if;
  insert into public.audit_log (actor_id, action) values (p_actor, 'invite_cleared');
  return 'cleared';
end;
$$;

create function public.delete_own_account_tx(p_user uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.app_role;
begin
  select pr.role into v_role from public.profiles pr where pr.id = p_user for update;
  if v_role is null then
    return 'not_found';
  end if;
  if v_role not in ('student', 'parent') then
    return 'forbidden';
  end if;
  delete from auth.users where id = p_user;
  insert into public.audit_log (actor_id, action) values (null, 'account_self_deleted');
  return 'deleted';
end;
$$;

revoke execute on function public.set_account_status_tx(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.remove_staff_tx(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.clear_invite_tx(text, uuid) from public, anon, authenticated;
revoke execute on function public.delete_own_account_tx(uuid) from public, anon, authenticated;
grant execute on function public.set_account_status_tx(uuid, uuid, text) to service_role;
grant execute on function public.remove_staff_tx(uuid, uuid) to service_role;
grant execute on function public.clear_invite_tx(text, uuid) to service_role;
grant execute on function public.delete_own_account_tx(uuid) to service_role;
