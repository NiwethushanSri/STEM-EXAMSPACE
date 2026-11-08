-- Admin edits the parent email on a student's registration (spec section 10: "admin edits the parent email first").
-- Allowed for a pending student, or an approved student (profile_incomplete/active with an index number)
-- that has no parent link yet. Row-locked; audits the target profile in the same transaction.
create function public.edit_parent_email_tx(p_target uuid, p_actor uuid, p_email text)
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

  select d.index_number into v_index from public.student_details d where d.profile_id = p_target for update;
  if v_status = 'pending' then
    null;
  elsif v_status in ('profile_incomplete', 'active') and v_index is not null
        and not exists (select 1 from public.parent_children pc where pc.student_id = p_target) then
    null;
  else
    return 'conflict';
  end if;

  update public.student_details set signup_parent_email = v_email where profile_id = p_target;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (p_actor, 'parent_email_edited', 'profile', p_target);
  return 'ok';
end;
$$;

revoke execute on function public.edit_parent_email_tx(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.edit_parent_email_tx(uuid, uuid, text) to service_role;
