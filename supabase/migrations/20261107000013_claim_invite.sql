-- Generalised invite claim (any invited role) and parent reconciliation. Service role only.
-- GoTrue inserts the auth row before app_metadata, so the sign-up trigger yields a student shell;
-- the Edge Function then claims it with the invite token.
create function public.claim_invite(p_user uuid, p_token uuid, p_email text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text;
  v_role public.app_role;
  v_status public.account_status;
  v_meta_token text;
  v_created timestamptz;
  v_invite_role public.app_role;
begin
  select lower(pr.email::text), pr.role, pr.status into v_email, v_role, v_status
  from public.profiles pr
  where pr.id = p_user
  for update;
  if v_email is null then
    return 'refused';
  end if;

  -- Already promoted: the same email, and any still-present invite for this token agrees on the role.
  if v_role <> 'student' then
    if v_email <> lower(btrim(coalesce(p_email, ''))) then
      return 'refused';
    end if;
    if exists (select 1 from public.pending_invites i where i.token = p_token and i.role <> v_role) then
      return 'refused';
    end if;
    return 'already';
  end if;

  if v_status not in ('unconfirmed', 'pending') then
    return 'refused';
  end if;
  if v_email <> lower(btrim(coalesce(p_email, ''))) then
    return 'refused';
  end if;

  select u.raw_app_meta_data ->> 'invite_token', u.created_at into v_meta_token, v_created
  from auth.users u where u.id = p_user;
  if v_meta_token is distinct from p_token::text or v_created is null or v_created <= now() - interval '24 hours' then
    return 'refused';
  end if;

  if exists (
    select 1 from public.student_details d
    where d.profile_id = p_user and (d.index_number is not null or d.signup_parent_email is not null)
  ) or exists (select 1 from public.student_subjects s where s.student_id = p_user) then
    return 'refused';
  end if;

  select i.role into v_invite_role
  from public.pending_invites i
  where lower(i.email::text) = v_email and i.token = p_token;
  if v_invite_role is null then
    return 'refused';
  end if;

  update public.profiles set role = v_invite_role, status = 'active' where id = p_user;
  delete from public.student_details where profile_id = p_user;
  delete from public.pending_invites where lower(email::text) = v_email;
  return 'claimed';
end;
$$;

revoke execute on function public.claim_invite(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.claim_invite(uuid, uuid, text) to service_role;

-- Thin wrapper: only parent invites (or accounts that are already parents) go through.
create or replace function public.claim_parent_invite(p_user uuid, p_token uuid, p_email text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
       select 1 from public.pending_invites i
       where i.token = p_token and i.role = 'parent' and lower(i.email::text) = lower(btrim(coalesce(p_email, '')))
     )
     or exists (select 1 from public.profiles pr where pr.id = p_user and pr.role = 'parent') then
    return public.claim_invite(p_user, p_token, p_email);
  end if;
  return 'refused';
end;
$$;

revoke execute on function public.claim_parent_invite(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.claim_parent_invite(uuid, uuid, text) to service_role;

-- Links every approved student whose sign-up parent email is this parent's email and who has no parent yet.
create function public.link_children_to_parent(p_parent uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text;
  v_count int;
begin
  select lower(pr.email::text) into v_email
  from public.profiles pr
  where pr.id = p_parent and pr.role = 'parent';
  if v_email is null then
    return 0;
  end if;

  with ins as (
    insert into public.parent_children (parent_id, student_id)
    select p_parent, s.id
    from public.profiles s
    join public.student_details d on d.profile_id = s.id
    where s.role = 'student'
      and s.status in ('profile_incomplete', 'active')
      and d.index_number is not null
      and lower(btrim(d.signup_parent_email)) = v_email
      and not exists (select 1 from public.parent_children pc where pc.student_id = s.id)
    on conflict do nothing
    returning 1
  )
  select count(*)::int into v_count from ins;
  return v_count;
end;
$$;

revoke execute on function public.link_children_to_parent(uuid) from public, anon, authenticated;
grant execute on function public.link_children_to_parent(uuid) to service_role;
