-- register-student: a fresh self sign-up for an address that still has an UNCONFIRMED self sign-up
-- replaces it (so an attacker who pre-registers someone's address cannot keep it). Only a plain,
-- unconfirmed, unapproved student created by self sign-up is ever deleted.
create function public.replace_unconfirmed_signup(p_email text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_id uuid;
  v_confirmed timestamptz;
  v_token text;
  v_role public.app_role;
  v_status public.account_status;
begin
  select au.id, au.email_confirmed_at, au.raw_app_meta_data ->> 'invite_token'
    into v_id, v_confirmed, v_token
  from auth.users au
  where lower(btrim(au.email)) = v_email
  for update;
  if not found then
    return 'none';
  end if;
  if v_confirmed is not null then
    return 'confirmed';
  end if;

  select pr.role, pr.status into v_role, v_status from public.profiles pr where pr.id = v_id for update;
  if not found or v_role <> 'student' or v_status <> 'unconfirmed' or v_token is not null then
    return 'protected';
  end if;
  -- A child registered by a parent, or any approved/indexed student, is not a self sign-up.
  if exists (
    select 1 from public.student_details d
    where d.profile_id = v_id and (d.index_number is not null or d.requested_by_parent is not null)
  ) or exists (select 1 from public.student_subjects s where s.student_id = v_id)
     or exists (select 1 from public.parent_children c where c.student_id = v_id) then
    return 'protected';
  end if;

  perform public.purge_student_residue(v_id);
  delete from auth.users where id = v_id;
  insert into public.audit_log (actor_id, action) values (null, 'signup_replaced');
  return 'replaced';
end;
$$;

revoke execute on function public.replace_unconfirmed_signup(text) from public, anon, authenticated;
grant execute on function public.replace_unconfirmed_signup(text) to service_role;
