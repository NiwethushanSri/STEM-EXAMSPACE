-- Profile completion: the only way a student reaches status 'active' from 'profile_incomplete'.
-- SECURITY DEFINER (owner postgres) so guard_protected_columns lets the status change through;
-- it acts only on auth.uid() and validates everything itself.
create function public.complete_profile(
  p_gender text,
  p_year_group text,
  p_subject_ids bigint[],
  p_parent_phone text,
  p_photo_path text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_phone text := btrim(coalesce(p_parent_phone, ''));
  v_ids bigint[];
begin
  perform 1 from public.profiles p
  where p.id = v_uid and p.role = 'student' and p.status = 'profile_incomplete'
  for update;
  if not found then
    raise exception 'Profile can only be completed by a student with an incomplete profile'
      using errcode = 'P0001';
  end if;

  if p_gender is null or p_gender not in ('Female', 'Male', 'Prefer not to say') then
    raise exception 'Invalid gender' using errcode = 'P0001';
  end if;
  if p_year_group is null
     or p_year_group not in ('Year 10', 'Year 11', 'Year 12', 'Year 13', 'University applicant') then
    raise exception 'Invalid year group' using errcode = 'P0001';
  end if;
  if v_phone = '' then
    raise exception 'Parent phone is required' using errcode = 'P0001';
  end if;

  select coalesce(array_agg(distinct x), '{}') into v_ids from unnest(p_subject_ids) as x;
  if cardinality(v_ids) = 0 then
    raise exception 'Choose at least one subject' using errcode = 'P0001';
  end if;
  if (select count(*) from public.subjects s where s.id = any (v_ids) and s.active) <> cardinality(v_ids) then
    raise exception 'Every subject must exist and be active' using errcode = 'P0001';
  end if;

  if p_photo_path is not null and p_photo_path <> v_uid::text || '/photo.jpg' then
    raise exception 'Invalid photo path' using errcode = 'P0001';
  end if;

  delete from public.student_subjects where student_id = v_uid;
  insert into public.student_subjects (student_id, subject_id)
  select v_uid, x from unnest(v_ids) as x;

  update public.student_details
  set gender = p_gender, year_group = p_year_group, parent_phone = v_phone, photo_path = p_photo_path
  where profile_id = v_uid;
  if not found then
    raise exception 'Student details not found' using errcode = 'P0001';
  end if;

  update public.profiles set status = 'active' where id = v_uid;
end;
$$;

revoke execute on function public.complete_profile(text, text, bigint[], text, text) from public, anon;
grant execute on function public.complete_profile(text, text, bigint[], text, text) to authenticated;

-- Private photo bucket. One object per student: <uid>/photo.jpg. Staff admins can read all.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('student-photos', 'student-photos', false, 5242880, array['image/jpeg'])
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create policy student_photos_insert on storage.objects for insert to authenticated
with check (bucket_id = 'student-photos' and name = (select auth.uid())::text || '/photo.jpg');

create policy student_photos_update on storage.objects for update to authenticated
using (bucket_id = 'student-photos' and name = (select auth.uid())::text || '/photo.jpg')
with check (bucket_id = 'student-photos' and name = (select auth.uid())::text || '/photo.jpg');

create policy student_photos_delete on storage.objects for delete to authenticated
using (bucket_id = 'student-photos' and name = (select auth.uid())::text || '/photo.jpg');

create policy student_photos_select on storage.objects for select to authenticated
using (
  bucket_id = 'student-photos'
  and (name = (select auth.uid())::text || '/photo.jpg' or (select public.is_staff_admin()))
);
