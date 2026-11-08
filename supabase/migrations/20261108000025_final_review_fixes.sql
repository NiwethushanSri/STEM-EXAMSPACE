-- Final review fixes: cleanup of dead code, profile email sync, learner-only photo writes,
-- read-only reject pre-check.

-- Dead code: superseded by the atomic login_attempt_begin / succeed / refund functions and by claim_invite.
drop function public.login_attempt_clear(text);
drop function public.claim_parent_invite(uuid, uuid, text);

-- Sign-up trigger without the invite branch (it could never fire: GoTrue writes app_metadata after the
-- insert, so invites are applied by claim_invite). Otherwise identical to the previous definition.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text := lower(btrim(coalesce(new.email, '')));
  v_meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_first text := coalesce(v_meta ->> 'first_name', '');
  v_last text := coalesce(v_meta ->> 'last_name', '');
  v_dob date;
begin
  begin
    v_dob := nullif(btrim(v_meta ->> 'date_of_birth'), '')::date;
  exception when others then
    v_dob := null;
  end;

  insert into public.profiles (id, role, status, first_name, last_name, email)
  values (
    new.id, 'student',
    case when new.email_confirmed_at is not null then 'pending'::public.account_status
         else 'unconfirmed'::public.account_status end,
    v_first, v_last, v_email);

  insert into public.student_details (profile_id, date_of_birth, school, signup_parent_name, signup_parent_email)
  values (
    new.id,
    v_dob,
    v_meta ->> 'school',
    v_meta ->> 'parent_name',
    lower(btrim(v_meta ->> 'parent_email'))
  );

  return new;
end;
$$;

-- profiles.email follows auth.users.email (login by index number and parent matching read it).
create function public.sync_profile_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.email is distinct from old.email then
    update public.profiles set email = lower(btrim(coalesce(new.email, ''))) where id = new.id;
  end if;
  return new;
end;
$$;

create trigger on_auth_user_email_changed
  after update of email on auth.users
  for each row execute function public.sync_profile_email();

revoke execute on function public.sync_profile_email() from public, anon, authenticated;

-- Account status of the caller (null when there is no profile). Used by storage policies.
create function public.my_status()
returns public.account_status
language sql
stable
security definer
set search_path = ''
as $$
  select p.status from public.profiles p where p.id = auth.uid()
$$;

revoke execute on function public.my_status() from public, anon;
grant execute on function public.my_status() to authenticated;

-- Photo writes: learners only, and only while their profile is open for editing or active.
drop policy student_photos_insert on storage.objects;
drop policy student_photos_update on storage.objects;

create policy student_photos_insert on storage.objects for insert to authenticated
with check (
  bucket_id = 'student-photos'
  and name = (select auth.uid())::text || '/photo.jpg'
  and (select public.my_role()) = 'student'
  and (select public.my_status()) in ('profile_incomplete', 'active')
);

create policy student_photos_update on storage.objects for update to authenticated
using (
  bucket_id = 'student-photos'
  and name = (select auth.uid())::text || '/photo.jpg'
  and (select public.my_role()) = 'student'
  and (select public.my_status()) in ('profile_incomplete', 'active')
)
with check (
  bucket_id = 'student-photos'
  and name = (select auth.uid())::text || '/photo.jpg'
  and (select public.my_role()) = 'student'
  and (select public.my_status()) in ('profile_incomplete', 'active')
);

-- Read-only mirror of reject_student_tx's validation: the Edge Function calls it before removing the
-- photo; the transaction still re-checks under lock.
create function public.can_reject_student(p_student uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role public.app_role;
  v_status public.account_status;
  v_parent_email text;
  v_token text;
begin
  select p.role, p.status into v_role, v_status from public.profiles p where p.id = p_student;
  if not found then
    return 'not_found';
  end if;
  if v_role <> 'student' or v_status <> 'pending' then
    return 'conflict';
  end if;
  select d.signup_parent_email into v_parent_email from public.student_details d where d.profile_id = p_student;
  select au.raw_app_meta_data ->> 'invite_token' into v_token from auth.users au where au.id = p_student;
  if v_parent_email is null and v_token is not null then
    return 'conflict';
  end if;
  return 'ok';
end;
$$;

revoke execute on function public.can_reject_student(uuid) from public, anon, authenticated;
grant execute on function public.can_reject_student(uuid) to service_role;
