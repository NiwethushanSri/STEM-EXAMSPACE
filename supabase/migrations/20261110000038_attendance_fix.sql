-- Part 2 Task 4 fix: cast the absent literal to attendance_status (037 applied before the first test run).
create or replace function public.close_register_as(p_actor uuid, p_exam uuid, p_now timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_exam public.exams%rowtype;
  v_absent int;
begin
  if p_actor is null or p_exam is null or p_now is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_exam from public.exams e where e.id = p_exam for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not public.attendance_can_manage(p_actor, v_exam.subject_id) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if v_exam.status <> 'published' or p_now < v_exam.starts_at then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;

  with ins as (
    insert into public.attendance (exam_id, student_id, status, marked_by, marked_at)
    select distinct b.exam_id, b.student_id, 'absent'::public.attendance_status, p_actor, p_now
    from public.bookings b
    where b.exam_id = p_exam and b.status in ('paid', 'cancel_requested')
      and not exists (select 1 from public.attendance a where a.exam_id = p_exam and a.student_id = b.student_id)
    returning 1)
  select count(*) into v_absent from ins;

  update public.bookings set status = 'expired' where exam_id = p_exam and status = 'awaiting_payment';
  update public.exams set status = 'completed' where id = p_exam;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (p_actor, 'register_closed', 'exam', p_exam);
  return jsonb_build_object('ok', true, 'absent', v_absent);
end;
$$;
revoke execute on function public.close_register_as(uuid, uuid, timestamptz) from public, anon, authenticated;
