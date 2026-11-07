-- Row-level security. Default deny; clients get SELECT (and a few admin writes) only.
-- All profile writes (completion, approval, role changes) go through security-definer
-- functions or the service role in later tasks.

-- Role helpers. SECURITY DEFINER so policies on profiles never recurse into profiles' own RLS.
-- A suspended account has no role and no staff powers; staff powers need an active account.
create function public.my_role()
returns public.app_role
language sql
stable
security definer
set search_path = ''
as $$
  select p.role
  from public.profiles p
  where p.id = auth.uid() and p.status <> 'suspended'
$$;

create function public.is_staff_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select p.role in ('owner', 'admin') and p.status = 'active'
     from public.profiles p
     where p.id = auth.uid()),
    false)
$$;

revoke execute on function public.my_role() from public, anon;
revoke execute on function public.is_staff_admin() from public, anon;
grant execute on function public.my_role() to authenticated;
grant execute on function public.is_staff_admin() to authenticated;

-- Table privileges: anon gets nothing; authenticated gets only what the policies can use.
revoke all on public.profiles, public.student_details, public.subjects, public.student_subjects,
  public.parent_children, public.teacher_subjects, public.tutor_students, public.audit_log
  from anon, authenticated;

grant select on public.profiles, public.student_details, public.student_subjects, public.audit_log
  to authenticated;
grant select, insert, update on public.subjects to authenticated;
grant usage on sequence public.subjects_id_seq to authenticated;
grant select, insert, update, delete on public.parent_children, public.teacher_subjects,
  public.tutor_students to authenticated;

-- profiles: self; owner/admin all; parent -> linked children; tutor -> assigned students.
-- The parent/tutor subqueries hit link tables, whose policies use only definer helpers (no recursion).
create policy profiles_select on public.profiles for select to authenticated
using (
  id = (select auth.uid())
  or (select public.is_staff_admin())
  or (
    (select public.my_role()) = 'parent'
    and exists (
      select 1 from public.parent_children pc
      where pc.parent_id = (select auth.uid()) and pc.student_id = profiles.id)
  )
  or (
    (select public.my_role()) = 'tutor'
    and exists (
      select 1 from public.tutor_students ts
      where ts.tutor_id = (select auth.uid()) and ts.student_id = profiles.id)
  )
);

create policy student_details_select on public.student_details for select to authenticated
using (
  profile_id = (select auth.uid())
  or (select public.is_staff_admin())
  or (
    (select public.my_role()) = 'parent'
    and exists (
      select 1 from public.parent_children pc
      where pc.parent_id = (select auth.uid()) and pc.student_id = student_details.profile_id)
  )
  or (
    (select public.my_role()) = 'tutor'
    and exists (
      select 1 from public.tutor_students ts
      where ts.tutor_id = (select auth.uid()) and ts.student_id = student_details.profile_id)
  )
);

create policy student_subjects_select on public.student_subjects for select to authenticated
using (student_id = (select auth.uid()) or (select public.is_staff_admin()));

-- subjects: any signed-in user reads; owner/admin insert/update; no delete (deactivate via active).
create policy subjects_select on public.subjects for select to authenticated
using (true);
create policy subjects_insert on public.subjects for insert to authenticated
with check ((select public.is_staff_admin()));
create policy subjects_update on public.subjects for update to authenticated
using ((select public.is_staff_admin()))
with check ((select public.is_staff_admin()));

-- Link tables: owner/admin all writes; members read their own rows.
create policy parent_children_admin on public.parent_children for all to authenticated
using ((select public.is_staff_admin())) with check ((select public.is_staff_admin()));
create policy parent_children_select_own on public.parent_children for select to authenticated
using (parent_id = (select auth.uid()));

create policy teacher_subjects_admin on public.teacher_subjects for all to authenticated
using ((select public.is_staff_admin())) with check ((select public.is_staff_admin()));
create policy teacher_subjects_select_own on public.teacher_subjects for select to authenticated
using (teacher_id = (select auth.uid()));

create policy tutor_students_admin on public.tutor_students for all to authenticated
using ((select public.is_staff_admin())) with check ((select public.is_staff_admin()));
create policy tutor_students_select_own on public.tutor_students for select to authenticated
using (tutor_id = (select auth.uid()));

-- audit_log: owner/admin read; inserts come from server code (service role); nobody updates or deletes.
create policy audit_log_select on public.audit_log for select to authenticated
using ((select public.is_staff_admin()));
