-- Audit inside the rejection transaction; lock-safe expiry.

drop function if exists public.reject_student_tx(uuid);

create or replace function public.reject_student_tx(p_student uuid, p_actor uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.app_role;
  v_status public.account_status;
  v_email text;
  v_parent_email text;
  v_token text;
begin
  select p.role, p.status, p.email::text into v_role, v_status, v_email
  from public.profiles p
  where p.id = p_student
  for update;

  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if v_role <> 'student' or v_status <> 'pending' then
    raise exception 'conflict' using errcode = 'P0001';
  end if;

  select d.signup_parent_email into v_parent_email
  from public.student_details d
  where d.profile_id = p_student;
  select au.raw_app_meta_data ->> 'invite_token' into v_token
  from auth.users au
  where au.id = p_student;
  if v_parent_email is null and v_token is not null then
    raise exception 'conflict' using errcode = 'P0001';
  end if;

  delete from auth.users where id = p_student;
  insert into public.audit_log (actor_id, action) values (p_actor, 'registration_rejected');
  return v_email;
end;
$$;

revoke all on function public.reject_student_tx(uuid, uuid) from public, anon, authenticated;
grant execute on function public.reject_student_tx(uuid, uuid) to service_role;

create or replace function public.expire_unconfirmed(p_now timestamptz default now())
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int;
begin
  with doomed as (
    select au.id
    from auth.users au
    join public.profiles p on p.id = au.id
    where p.role = 'student'
      and p.status = 'unconfirmed'
      and au.created_at < p_now - interval '7 days'
    for update of au, p
  ),
  del as (
    delete from auth.users au
    using doomed, public.profiles p
    where au.id = doomed.id
      and p.id = doomed.id
      and p.role = 'student'
      and p.status = 'unconfirmed'
    returning au.id
  ),
  logged as (
    insert into public.audit_log (actor_id, action)
    select null, 'registration_expired' from del
    returning 1
  )
  select count(*)::int into v_count from logged;
  return v_count;
end;
$$;

revoke all on function public.expire_unconfirmed(timestamptz) from public, anon, authenticated, service_role;
