-- Task 10b fix round 2: suspended users cannot write photos; authorise before any destructive side effect.

-- my_role() is null for suspended users. Delete and select policies stay as they were.
drop policy student_photos_insert on storage.objects;
drop policy student_photos_update on storage.objects;

create policy student_photos_insert on storage.objects for insert to authenticated
with check (
  bucket_id = 'student-photos'
  and name = (select auth.uid())::text || '/photo.jpg'
  and (select public.my_role()) is not null
);

create policy student_photos_update on storage.objects for update to authenticated
using (
  bucket_id = 'student-photos'
  and name = (select auth.uid())::text || '/photo.jpg'
  and (select public.my_role()) is not null
)
with check (
  bucket_id = 'student-photos'
  and name = (select auth.uid())::text || '/photo.jpg'
  and (select public.my_role()) is not null
);

-- Read-only authorisation check with the same rules as remove_staff_tx / delete_account_tx. The Edge
-- Function calls it before removing a photo; the transaction functions still re-check under lock.
create function public.can_manage_account(p_actor uuid, p_target uuid, p_action text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor_role public.app_role;
  v_role public.app_role;
begin
  if p_action not in ('remove_staff', 'delete_account') then
    return 'conflict';
  end if;
  select a.role into v_actor_role
  from public.profiles a where a.id = p_actor and a.status = 'active';
  if v_actor_role is null or v_actor_role not in ('owner', 'admin') then
    return 'forbidden';
  end if;
  select t.role into v_role from public.profiles t where t.id = p_target;
  if v_role is null then
    return 'not_found';
  end if;
  if p_target = p_actor or v_role = 'owner' or (v_actor_role = 'admin' and v_role = 'admin') then
    return 'forbidden';
  end if;
  if p_action = 'remove_staff' and v_role not in ('admin', 'teacher', 'tutor', 'corrector') then
    return 'conflict';
  end if;
  if p_action = 'delete_account' and v_role not in ('student', 'parent') then
    return 'conflict';
  end if;
  return 'ok';
end;
$$;

revoke execute on function public.can_manage_account(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.can_manage_account(uuid, uuid, text) to service_role;
