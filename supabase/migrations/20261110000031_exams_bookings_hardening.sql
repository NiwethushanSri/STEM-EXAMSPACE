-- Part 2 Task 1 fixes: account deletion must not fail on exam data; schema hardening.

-- Financial records survive profile deletion, anonymised (student_id / booked_by become null).
alter table public.bookings alter column student_id drop not null;
alter table public.bookings alter column booked_by drop not null;
alter table public.bookings drop constraint bookings_student_id_fkey;
alter table public.bookings drop constraint bookings_booked_by_fkey;
alter table public.bookings
  add constraint bookings_student_id_fkey foreign key (student_id) references public.profiles (id) on delete set null,
  add constraint bookings_booked_by_fkey foreign key (booked_by) references public.profiles (id) on delete set null;

alter table public.attendance drop constraint attendance_student_id_fkey;
alter table public.attendance
  add constraint attendance_student_id_fkey foreign key (student_id) references public.profiles (id) on delete cascade;

alter table public.attendance alter column marked_by drop not null;
alter table public.attendance drop constraint attendance_marked_by_fkey;
alter table public.attendance
  add constraint attendance_marked_by_fkey foreign key (marked_by) references public.profiles (id) on delete set null;

alter table public.exams alter column created_by drop not null;
alter table public.exams drop constraint exams_created_by_fkey;
alter table public.exams
  add constraint exams_created_by_fkey foreign key (created_by) references public.profiles (id) on delete set null;

-- Checks.
alter table public.bookings add constraint bookings_refund_within_amount check (refunded_pence <= amount_pence);
alter table public.exams add constraint exams_online_has_no_room check (format <> 'online' or room is null);

-- Bookings with a null student (anonymised) are readable by owner/admin only: the teacher branch needs a student.
drop policy bookings_select on public.bookings;
create policy bookings_select on public.bookings for select to authenticated
using (
  (select public.is_staff_admin())
  or (student_id = (select auth.uid()) and (select public.my_role()) = 'student')
  or (
    student_id is not null
    and (select public.my_role()) = 'parent'
    and exists (
      select 1 from public.parent_children pc
      where pc.parent_id = (select auth.uid()) and pc.student_id = bookings.student_id)
  )
  or (
    student_id is not null
    and (select public.my_role()) = 'tutor'
    and exists (
      select 1 from public.tutor_students ts
      where ts.tutor_id = (select auth.uid()) and ts.student_id = bookings.student_id)
  )
  or (
    student_id is not null
    and (select public.my_role()) = 'teacher'
    and exists (
      select 1 from public.exams e
      join public.teacher_subjects tsub on tsub.subject_id = e.subject_id
      where e.id = bookings.exam_id and tsub.teacher_id = (select auth.uid()))
  )
);

-- Public view: security barrier; owner and grants unchanged.
alter view public.exams_public set (security_barrier = true);

-- seats_taken: service_role only.
revoke execute on function public.seats_taken(uuid) from authenticated;

-- updated_at maintenance.
create function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
revoke execute on function public.touch_updated_at() from public, anon, authenticated;

create trigger exams_touch_updated_at before update on public.exams
  for each row execute function public.touch_updated_at();
create trigger bookings_touch_updated_at before update on public.bookings
  for each row execute function public.touch_updated_at();
