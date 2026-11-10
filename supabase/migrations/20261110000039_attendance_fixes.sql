-- Part 2 Task 4 fix round 1: concurrent scans, authorise before locking, lock the booking row.

create or replace function public.mark_attendance_as(p_actor uuid, p_exam uuid, p_student uuid, p_now timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_subject bigint;
  v_exam public.exams%rowtype;
  v_booking uuid;
  v_status public.attendance_status;
  v_new public.attendance_status;
begin
  if p_actor is null or p_exam is null or p_student is null or p_now is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select e.subject_id into v_subject from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not public.attendance_can_manage(p_actor, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;

  select * into v_exam from public.exams e where e.id = p_exam for share;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_exam.status <> 'published' then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;

  select b.id into v_booking from public.bookings b
  where b.exam_id = p_exam and b.student_id = p_student and b.status in ('paid', 'cancel_requested')
  limit 1 for share;
  if v_booking is null then
    return jsonb_build_object('ok', false, 'code', 'not_booked');
  end if;

  v_new := case when p_now >= v_exam.starts_at + interval '15 minutes' then 'late' else 'present' end;
  insert into public.attendance (exam_id, student_id, status, marked_by, marked_at)
  values (p_exam, p_student, v_new, p_actor, p_now)
  on conflict (exam_id, student_id) do nothing
  returning status into v_status;
  if v_status is null then
    select a.status into v_status from public.attendance a where a.exam_id = p_exam and a.student_id = p_student;
    return jsonb_build_object('ok', true, 'status', v_status, 'already', true);
  end if;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (p_actor, 'attendance_marked', 'booking', v_booking);
  return jsonb_build_object('ok', true, 'status', v_status, 'already', false);
end;
$$;
revoke execute on function public.mark_attendance_as(uuid, uuid, uuid, timestamptz) from public, anon, authenticated;

create or replace function public.close_register_as(p_actor uuid, p_exam uuid, p_now timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_subject bigint;
  v_exam public.exams%rowtype;
  v_absent int;
begin
  if p_actor is null or p_exam is null or p_now is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select e.subject_id into v_subject from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not public.attendance_can_manage(p_actor, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;

  select * into v_exam from public.exams e where e.id = p_exam for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_exam.status <> 'published' or p_now < v_exam.starts_at then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;

  with ins as (
    insert into public.attendance (exam_id, student_id, status, marked_by, marked_at)
    select distinct b.exam_id, b.student_id, 'absent'::public.attendance_status, p_actor, p_now
    from public.bookings b
    where b.exam_id = p_exam and b.status in ('paid', 'cancel_requested')
    on conflict (exam_id, student_id) do nothing
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
