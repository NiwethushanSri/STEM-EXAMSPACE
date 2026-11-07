-- Task 10a fix round 2: approved-only links, stale parent shells refused, no real owner on dev tests.
create or replace function public.link_student_to_parent(p_parent uuid, p_student uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.profiles pr where pr.id = p_parent and pr.role = 'parent' and pr.status = 'active') then
    return 'parent_inactive';
  end if;
  -- Only approved students are linked (several parents per student are allowed).
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
  v_shell_token uuid;
  v_invite_role public.app_role;
  v_shell_created timestamptz;
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
    -- A token-bearing sign-up shell is a parent whose creation was interrupted: reuse its invite.
    select i.token, au.created_at into v_shell_token, v_shell_created
    from public.pending_invites i
    join auth.users au on au.id = v_parent_id
    where lower(i.email::text) = v_email
      and i.role = 'parent'
      and au.raw_app_meta_data ->> 'invite_token' = i.token::text
      and v_parent_role = 'student'
      and exists (select 1 from public.profiles sp where sp.id = v_parent_id and sp.status in ('unconfirmed', 'pending'))
      and not exists (select 1 from public.student_details d
                      where d.profile_id = v_parent_id and (d.index_number is not null or d.signup_parent_email is not null))
      and not exists (select 1 from public.student_subjects ss where ss.student_id = v_parent_id);
    if v_shell_token is null then
      raise exception 'parent_email_is_staff' using errcode = 'P0001',
        detail = case when v_parent_role = 'student' then 'student' else 'staff' end;
    end if;
    -- The claim only accepts shells younger than 24 hours: an older one needs an owner to clear it.
    if v_shell_created <= now() - interval '24 hours' then
      raise exception 'parent_email_is_staff' using errcode = 'P0001', detail = 'stuck';
    end if;
    v_parent_id := null;
    v_token := v_shell_token;
  end if;

  if v_parent_id is null and v_shell_token is null and exists (
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
    perform public.link_student_to_parent(v_parent_id, p_student);
  elsif v_shell_token is null then
    insert into public.pending_invites (email, role, invited_by)
    values (v_email, 'parent', p_actor)
    on conflict (email) do nothing;
    select i.token, i.role into v_token, v_invite_role
    from public.pending_invites i where lower(i.email::text) = v_email;
    if v_invite_role is not null and v_invite_role <> 'parent' then
      raise exception 'parent_email_is_staff' using errcode = 'P0001', detail = 'staff';
    end if;
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
