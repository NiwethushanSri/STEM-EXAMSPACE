-- Index-number sequence, one counter row per calendar year. Server-side only.
create table public.index_counters (
  year int primary key,
  last int not null
);
alter table public.index_counters enable row level security;
revoke all on public.index_counters from public, anon, authenticated;

-- Approves a pending student in one transaction. Called by the approve-student Edge Function (service role).
-- Errors are raised as SQLSTATE P0001 with message: conflict | parent_email_is_staff | invalid_input.
create function public.approve_student_tx(
  p_student uuid,
  p_actor uuid,
  p_year int default extract(year from now())::int
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

  -- Find the parent first so a staff-email failure consumes no index number (the whole call rolls back anyway).
  select pr.id, pr.role into v_parent_id, v_parent_role
  from public.profiles pr
  where lower(pr.email::text) = v_email;

  if v_parent_id is not null and v_parent_role <> 'parent' then
    raise exception 'parent_email_is_staff' using errcode = 'P0001';
  end if;

  if v_parent_id is null and exists (
    select 1 from public.pending_invites i where lower(i.email::text) = v_email and i.role <> 'parent'
  ) then
    raise exception 'parent_email_is_staff' using errcode = 'P0001';
  end if;

  insert into public.index_counters as c (year, last) values (p_year, 1)
  on conflict (year) do update set last = c.last + 1
  returning c.last into v_seq;

  update public.student_details d
  set index_number = 'SE-' || p_year::text || '-' || lpad(v_seq::text, 4, '0')
  where d.profile_id = p_student;

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

  index_number := 'SE-' || p_year::text || '-' || lpad(v_seq::text, 4, '0');
  parent_id := v_parent_id;
  parent_email := v_email;
  invite_token := v_token;
  return next;
end;
$$;

revoke execute on function public.approve_student_tx(uuid, uuid, int) from public, anon, authenticated;
grant execute on function public.approve_student_tx(uuid, uuid, int) to service_role;
