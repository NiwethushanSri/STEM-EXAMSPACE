-- Families keep seeing exams they booked after the exam is cancelled or completed (My bookings shows the subject).
-- The check is a definer function: a plain policy subquery on bookings would re-enter bookings RLS, whose teacher
-- branch reads exams, which would recurse. The function reads only bookings and parent_children, by index.
create function public.family_has_booking(p_exam uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.bookings b
    where b.exam_id = p_exam
      and b.student_id is not null
      and (
        b.student_id = auth.uid()
        or exists (
          select 1 from public.parent_children pc
          where pc.parent_id = auth.uid() and pc.student_id = b.student_id)
      )
  )
$$;
revoke execute on function public.family_has_booking(uuid) from public, anon;
grant execute on function public.family_has_booking(uuid) to authenticated;

create policy exams_select_family on public.exams for select to authenticated
using ((select public.my_role()) in ('student', 'parent') and (select public.family_has_booking(id)));
