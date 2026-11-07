-- Task 10c: parents register or link children, always through admin approval (spec 6.9).

alter table public.student_details
  add column requested_by_parent uuid null references public.profiles (id) on delete set null;

create table public.parent_link_requests (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid not null references public.profiles (id) on delete cascade,
  student_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (parent_id, student_id)
);
alter table public.parent_link_requests enable row level security;
revoke all on public.parent_link_requests from anon, authenticated;
grant select on public.parent_link_requests to authenticated;
create policy parent_link_requests_select on public.parent_link_requests for select to authenticated
using (
  (parent_id = (select auth.uid()) and (select public.my_role()) = 'parent')
  or (select public.is_staff_admin())
);

-- Parent asks to be linked to an approved child. True for a match (new request, existing request or
-- an existing link: the caller cannot tell them apart); false for anything else.
create function public.request_parent_link_tx(p_parent uuid, p_index text, p_dob date)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
  v_rows int;
begin
  if p_index is null or p_dob is null or not exists (
    select 1 from public.profiles pr where pr.id = p_parent and pr.role = 'parent' and pr.status = 'active'
  ) then
    return false;
  end if;

  select s.id into v_student
  from public.student_details d
  join public.profiles s on s.id = d.profile_id
  where d.index_number = p_index
    and d.date_of_birth = p_dob
    and s.role = 'student'
    and s.status in ('profile_incomplete', 'active');
  if v_student is null then
    return false;
  end if;

  if exists (select 1 from public.parent_children pc where pc.parent_id = p_parent and pc.student_id = v_student) then
    return true;
  end if;

  insert into public.parent_link_requests (parent_id, student_id) values (p_parent, v_student)
  on conflict (parent_id, student_id) do nothing;
  get diagnostics v_rows = row_count;
  if v_rows > 0 then
    insert into public.audit_log (actor_id, action, target_type, target_id)
    values (p_parent, 'parent_link_requested', 'profile', v_student);
  end if;
  return true;
end;
$$;

-- Owner/admin decision. Returns approved | rejected | not_found | forbidden | conflict.
create function public.decide_parent_link_tx(p_request uuid, p_actor uuid, p_approve boolean)
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

revoke execute on function public.request_parent_link_tx(uuid, text, date) from public, anon, authenticated;
grant execute on function public.request_parent_link_tx(uuid, text, date) to service_role;
revoke execute on function public.decide_parent_link_tx(uuid, uuid, boolean) from public, anon, authenticated;
grant execute on function public.decide_parent_link_tx(uuid, uuid, boolean) to service_role;

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
  v_requester uuid;
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

  select d.requested_by_parent into v_requester from public.student_details d where d.profile_id = p_student;
  if v_requester is not null then
    perform public.link_student_to_parent(v_requester, p_student);
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
