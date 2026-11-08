-- Restores the audited decide_parent_link_tx body from migration 21 (migration 23 overwrote it by mistake) and adds the student lock.
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
  -- Serialise with edit_parent_email_tx / approval on the student's profile.
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
  end if;

  delete from public.parent_link_requests where id = p_request;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (p_actor, v_action, 'profile', v_student),
         (p_actor, v_action, 'profile', v_parent);
  return case when p_approve then 'approved' else 'rejected' end;
end;
$$;
