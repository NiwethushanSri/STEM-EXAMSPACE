-- Approval fixes: UTC year, index padding beyond 9999, student-vs-staff parent email detail,
-- and an invite claim bound to the user created for that invite.
create or replace function public.approve_student_tx(
  p_student uuid,
  p_actor uuid,
  p_year int default extract(year from (now() at time zone 'utc'))::int
)
returns table (index_number text, parent_id uuid, parent_email text, invite_token uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.app_role;
  v_status public.account_status;
  v_email text;
  v_seq int;
  v_index text;
  v_parent_id uuid;
  v_parent_role public.app_role;
  v_token uuid;
begin
  select p.role, p.status into v_role, v_status
  from public.profiles p
  where p.id = p_student
  for update;

  if not found or v_role <> 'student' or v_status <> 'pending' then
    raise exception 'conflict' using errcode = 'P0001';
  end if;

  select lower(btrim(d.signup_parent_email)) into v_email
  from public.student_details d
  where d.profile_id = p_student
  for update;

  if v_email is null or v_email = '' then
    raise exception 'invalid_input' using errcode = 'P0001';
  end if;

  select pr.id, pr.role into v_parent_id, v_parent_role
  from public.profiles pr
  where lower(pr.email::text) = v_email;

  if v_parent_id is not null and v_parent_role <> 'parent' then
    raise exception 'parent_email_is_staff' using errcode = 'P0001',
      detail = case when v_parent_role = 'student' then 'student' else 'staff' end;
  end if;

  if v_parent_id is null and exists (
    select 1 from public.pending_invites i where lower(i.email::text) = v_email and i.role <> 'parent'
  ) then
    raise exception 'parent_email_is_staff' using errcode = 'P0001', detail = 'staff';
  end if;

  insert into public.index_counters as c (year, last) values (p_year, 1)
  on conflict (year) do update set last = c.last + 1
  returning c.last into v_seq;

  v_index := 'SE-' || p_year::text || '-' || lpad(v_seq::text, greatest(4, length(v_seq::text)), '0');

  update public.student_details d set index_number = v_index where d.profile_id = p_student;
  update public.profiles p set status = 'profile_incomplete' where p.id = p_student;

  if v_parent_id is not null then
    insert into public.parent_children (parent_id, student_id) values (v_parent_id, p_student)
    on conflict do nothing;
  else
    insert into public.pending_invites as i (email, role, invited_by)
    values (v_email, 'parent', p_actor)
    on conflict (email) do update set invited_by = excluded.invited_by
    returning i.token into v_token;
  end if;

  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (p_actor, 'student_approved', 'student', p_student);

  index_number := v_index;
  parent_id := v_parent_id;
  parent_email := v_email;
  invite_token := v_token;
  return next;
end;
$$;

create or replace function public.claim_parent_invite(p_user uuid, p_token uuid)
returns boolean
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
begin
  select lower(pr.email::text), pr.role, pr.status into v_email, v_role, v_status
  from public.profiles pr
  where pr.id = p_user
  for update;
  if v_email is null then
    return false;
  end if;

  -- Idempotent: a previous claim already made this user a parent.
  if v_role = 'parent' then
    return true;
  end if;

  if v_role <> 'student' or v_status not in ('unconfirmed', 'pending') then
    return false;
  end if;

  select u.raw_app_meta_data ->> 'invite_token', u.created_at into v_meta_token, v_created
  from auth.users u where u.id = p_user;
  if v_meta_token is distinct from p_token::text or v_created is null or v_created <= now() - interval '24 hours' then
    return false;
  end if;

  -- Must be a bare sign-up shell, not a real registration.
  if exists (
    select 1 from public.student_details d
    where d.profile_id = p_user and (d.index_number is not null or d.signup_parent_email is not null)
  ) or exists (select 1 from public.student_subjects s where s.student_id = p_user) then
    return false;
  end if;

  if not exists (
    select 1 from public.pending_invites i
    where lower(i.email::text) = v_email and i.token = p_token and i.role = 'parent'
  ) then
    return false;
  end if;

  update public.profiles set role = 'parent', status = 'active' where id = p_user;
  delete from public.student_details where profile_id = p_user;
  delete from public.pending_invites where lower(email::text) = v_email;
  return true;
end;
$$;
