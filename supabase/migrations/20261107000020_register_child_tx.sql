-- Task 10c: record who registered a child and audit it in one transaction.
-- Only a fresh, unconfirmed, unapproved student shell may be claimed by a requesting parent.
create function public.register_child_tx(p_child uuid, p_parent uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.profiles pr where pr.id = p_parent and pr.role = 'parent' and pr.status = 'active') then
    return false;
  end if;
  update public.student_details d set requested_by_parent = p_parent
  from public.profiles s
  where d.profile_id = p_child and s.id = d.profile_id
    and s.role = 'student' and s.status = 'unconfirmed' and d.index_number is null
    and d.requested_by_parent is null;
  if not found then
    return false;
  end if;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (p_parent, 'child_registered_by_parent', 'profile', p_child);
  return true;
end;
$$;

revoke execute on function public.register_child_tx(uuid, uuid) from public, anon, authenticated;
grant execute on function public.register_child_tx(uuid, uuid) to service_role;
