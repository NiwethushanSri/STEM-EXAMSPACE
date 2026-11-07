-- Task 10c fix round 1: traceable link audits, failure-only index counting, requester index.

create index student_details_requested_by_parent_idx on public.student_details (requested_by_parent)
  where requested_by_parent is not null;

-- Gives back the single most recent attempt row of one key.
create function public.login_attempt_refund_key(p_key text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(p_key, 0));
  delete from public.login_attempts where ctid = (
    select a.ctid from public.login_attempts a where a.key = p_key order by a.attempted_at desc limit 1
  );
end;
$$;
revoke execute on function public.login_attempt_refund_key(text) from public, anon, authenticated;
grant execute on function public.login_attempt_refund_key(text) to service_role;

-- Request: audit rows for the child and for the request id.
create or replace function public.request_parent_link_tx(p_parent uuid, p_index text, p_dob date)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
  v_req uuid;
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
  on conflict (parent_id, student_id) do nothing
  returning id into v_req;
  if v_req is not null then
    insert into public.audit_log (actor_id, action, target_type, target_id)
    values (p_parent, 'parent_link_requested', 'profile', v_student),
           (p_parent, 'parent_link_requested', 'parent_link_request', v_req);
  end if;
  return true;
end;
$$;

-- Decision: two audit rows (child, parent) that outlive the deleted request.
create or replace function public.decide_parent_link_tx(p_request uuid, p_actor uuid, p_approve boolean)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_parent uuid;
  v_student uuid;
  v_action text := case when p_approve then 'parent_link_approved' else 'parent_link_rejected' end;
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
  end if;

  delete from public.parent_link_requests where id = p_request;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (p_actor, v_action, 'profile', v_student),
         (p_actor, v_action, 'profile', v_parent);
  return case when p_approve then 'approved' else 'rejected' end;
end;
$$;
