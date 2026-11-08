-- Fix round 2: edit_parent_email_tx refuses invite shells and pending rows without a signup parent email;
-- link functions lock the student's profile first so an edit/approve race cannot interleave.

create or replace function public.edit_parent_email_tx(p_target uuid, p_actor uuid, p_email text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_role public.app_role;
  v_role public.app_role;
  v_status public.account_status;
  v_index text;
  v_current text;
  v_has_details boolean;
  v_email text := lower(btrim(coalesce(p_email, '')));
begin
  select a.role into v_actor_role
  from public.profiles a where a.id = p_actor and a.status = 'active' for share;
  if v_actor_role is null or v_actor_role not in ('owner', 'admin') then
    return 'forbidden';
  end if;

  if length(v_email) > 320 or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    return 'invalid_input';
  end if;

  select t.role, t.status into v_role, v_status
  from public.profiles t where t.id = p_target for update;
  if v_role is null then
    return 'not_found';
  end if;
  if v_role <> 'student' then
    return 'conflict';
  end if;

  select d.index_number, d.signup_parent_email, true into v_index, v_current, v_has_details
  from public.student_details d where d.profile_id = p_target for update;
  if v_has_details is not true then
    return 'conflict';
  end if;

  if v_status = 'pending' then
    -- A real registration carries the parent email typed at sign-up; shells and blanks are refused.
    if nullif(btrim(coalesce(v_current, '')), '') is null then
      return 'conflict';
    end if;
  elsif v_status in ('profile_incomplete', 'active') and v_index is not null
        and not exists (select 1 from public.parent_children pc where pc.student_id = p_target) then
    null;
  else
    return 'conflict';
  end if;

  update public.student_details set signup_parent_email = v_email where profile_id = p_target;
  if not found then
    return 'conflict';
  end if;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (p_actor, 'parent_email_edited', 'profile', p_target);
  return 'ok';
end;
$$;

create or replace function public.link_student_to_parent(p_parent uuid, p_student uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Serialise with edit_parent_email_tx / approval on the student's profile.
  perform 1 from public.profiles s0 where s0.id = p_student for update;
  if not exists (select 1 from public.profiles pr where pr.id = p_parent and pr.role = 'parent' and pr.status = 'active') then
    return 'parent_inactive';
  end if;
  if not exists (
    select 1 from public.profiles s
    join public.student_details d on d.profile_id = s.id
    where s.id = p_student and s.role = 'student'
      and s.status in ('profile_incomplete', 'active') and d.index_number is not null
  ) then
    return 'refused';
  end if;
  if exists (select 1 from public.parent_link_blocks b where b.parent_id = p_parent and b.student_id = p_student) then
    return 'blocked';
  end if;
  if exists (select 1 from public.parent_children pc where pc.parent_id = p_parent and pc.student_id = p_student) then
    return 'exists';
  end if;
  insert into public.parent_children (parent_id, student_id) values (p_parent, p_student) on conflict do nothing;
  return 'linked';
end;
$$;

create or replace function public.decide_parent_link_tx(p_request uuid, p_actor uuid, p_approve boolean)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_parent uuid;
  v_student uuid;
begin
  if not exists (
    select 1 from public.profiles a where a.id = p_actor and a.role in ('owner', 'admin') and a.status = 'active'
  ) then
    return 'forbidden';
  end if;

  select r.parent_id, r.student_id into v_parent, v_student
  from public.parent_link_requests r where r.id = p_request for update;
  if not found then
    return 'not_found';
  end if;
  perform 1 from public.profiles s0 where s0.id = v_student for update;

  if p_approve then
    if not exists (select 1 from public.profiles pr where pr.id = v_parent and pr.role = 'parent' and pr.status = 'active')
       or not exists (
         select 1 from public.profiles s
         join public.student_details d on d.profile_id = s.id
         where s.id = v_student and s.role = 'student'
           and s.status in ('profile_incomplete', 'active') and d.index_number is not null
       ) then
      return 'conflict';
    end if;
    delete from public.parent_link_blocks where parent_id = v_parent and student_id = v_student;
    insert into public.parent_children (parent_id, student_id) values (v_parent, v_student) on conflict do nothing;
    delete from public.parent_link_requests where id = p_request;
    insert into public.audit_log (actor_id, action, target_type, target_id)
    values (p_actor, 'parent_link_approved', 'parent_link_request', p_request);
    return 'approved';
  end if;

  delete from public.parent_link_requests where id = p_request;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (p_actor, 'parent_link_rejected', 'parent_link_request', p_request);
  return 'rejected';
end;
$$;
