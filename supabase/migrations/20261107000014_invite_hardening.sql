-- Task 10a fixes: role-bound claims, deliberate-unlink blocks, parent-status-aware linking, single owner.

-- Single Super administrator.
create unique index one_owner on public.profiles ((true)) where role = 'owner';

-- Deliberate unlinks by owner/admin (via RLS as `authenticated`) must survive automatic reconciliation.
create table public.parent_link_blocks (
  parent_id uuid not null references public.profiles (id) on delete cascade,
  student_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (parent_id, student_id)
);
alter table public.parent_link_blocks enable row level security;
revoke all on public.parent_link_blocks from anon, authenticated;
grant select on public.parent_link_blocks to authenticated;
create policy parent_link_blocks_select on public.parent_link_blocks for select to authenticated
using ((select public.is_staff_admin()));

-- `role` is the session role PostgREST sets for the request; it is unaffected by security definer.
create function public.parent_children_after_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if current_setting('role', true) = 'authenticated'
     and exists (select 1 from public.profiles where id = old.parent_id)
     and exists (select 1 from public.profiles where id = old.student_id) then
    insert into public.parent_link_blocks (parent_id, student_id) values (old.parent_id, old.student_id)
    on conflict do nothing;
  end if;
  return old;
end;
$$;

create function public.parent_children_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if current_setting('role', true) = 'authenticated' then
    delete from public.parent_link_blocks where parent_id = new.parent_id and student_id = new.student_id;
  end if;
  return new;
end;
$$;

revoke execute on function public.parent_children_after_delete() from public, anon, authenticated;
revoke execute on function public.parent_children_before_insert() from public, anon, authenticated;

create trigger parent_children_block_on_delete after delete on public.parent_children
  for each row execute function public.parent_children_after_delete();
create trigger parent_children_unblock_on_insert before insert on public.parent_children
  for each row execute function public.parent_children_before_insert();

-- Automatic link of one student: never to a non-active parent, never over a deliberate unlink.
create function public.link_student_to_parent(p_parent uuid, p_student uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.profiles pr where pr.id = p_parent and pr.role = 'parent' and pr.status = 'active') then
    return 'parent_inactive';
  end if;
  if not exists (select 1 from public.profiles s where s.id = p_student and s.role = 'student') then
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

revoke execute on function public.link_student_to_parent(uuid, uuid) from public, anon, authenticated;
grant execute on function public.link_student_to_parent(uuid, uuid) to service_role;

create or replace function public.link_children_to_parent(p_parent uuid)
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
  where pr.id = p_parent and pr.role = 'parent' and pr.status = 'active';
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
      and not exists (select 1 from public.parent_link_blocks b where b.parent_id = p_parent and b.student_id = s.id)
    on conflict do nothing
    returning 1
  )
  select count(*)::int into v_count from ins;
  return v_count;
end;
$$;

-- Role-bound claim: the invite row's role must equal p_role; 'already' only for that role.
drop function public.claim_parent_invite(uuid, uuid, text);
drop function public.claim_invite(uuid, uuid, text);

create function public.claim_invite(p_user uuid, p_token uuid, p_email text, p_role public.app_role)
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
  if p_role is null or p_role = 'student' then
    return 'refused';
  end if;

  select lower(pr.email::text), pr.role, pr.status into v_email, v_role, v_status
  from public.profiles pr
  where pr.id = p_user
  for update;
  if v_email is null then
    return 'refused';
  end if;

  if v_role <> 'student' then
    if v_role <> p_role or v_email <> lower(btrim(coalesce(p_email, ''))) then
      return 'refused';
    end if;
    if exists (select 1 from public.pending_invites i where i.token = p_token and i.role <> p_role) then
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
  if v_invite_role is distinct from p_role then
    return 'refused';
  end if;

  update public.profiles set role = v_invite_role, status = 'active' where id = p_user;
  delete from public.student_details where profile_id = p_user;
  delete from public.pending_invites where lower(email::text) = v_email;
  return 'claimed';
end;
$$;

revoke execute on function public.claim_invite(uuid, uuid, text, public.app_role) from public, anon, authenticated;
grant execute on function public.claim_invite(uuid, uuid, text, public.app_role) to service_role;

create function public.claim_parent_invite(p_user uuid, p_token uuid, p_email text)
returns text
language sql
security definer
set search_path = ''
as $$
  select public.claim_invite(p_user, p_token, p_email, 'parent');
$$;

revoke execute on function public.claim_parent_invite(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.claim_parent_invite(uuid, uuid, text) to service_role;

-- Approval: atomic invite row (insert … on conflict do nothing, re-read) and parent-aware linking.
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
    select i.token into v_shell_token
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
