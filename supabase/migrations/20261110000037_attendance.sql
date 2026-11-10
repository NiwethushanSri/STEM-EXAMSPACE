-- Part 2 Task 4: attendance on exam day (lookup by index number, mark, close register).

-- Port of packages/shared/src/index-number.ts normaliseIndexNumber.
create function public.normalise_index(p_raw text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_raw is null then null
    when regexp_replace(upper(p_raw), '[\s-]+', '', 'g') ~ '^SE\d{4}\d{4,}$' then
      'SE-' || substr(regexp_replace(upper(p_raw), '[\s-]+', '', 'g'), 3, 4) || '-'
        || substr(regexp_replace(upper(p_raw), '[\s-]+', '', 'g'), 7)
    else regexp_replace(upper(p_raw), '\s+', '', 'g')
  end
$$;

-- Active owner/admin, or active teacher of the exam's subject.
create function public.attendance_can_manage(p_actor uuid, p_subject bigint)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles a
    where a.id = p_actor and a.status = 'active'
      and (a.role in ('owner', 'admin')
        or (a.role = 'teacher' and exists (
          select 1 from public.teacher_subjects ts
          where ts.teacher_id = a.id and ts.subject_id = p_subject))))
$$;
revoke execute on function public.attendance_can_manage(uuid, bigint) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
create function public.attendance_lookup_as(p_actor uuid, p_exam uuid, p_index text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_exam public.exams%rowtype;
  v_admin boolean;
  v_idx text := public.normalise_index(p_index);
  v_stu record;
  v_booked boolean;
  v_status public.attendance_status;
begin
  if p_actor is null or p_exam is null or v_idx is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_exam from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not public.attendance_can_manage(p_actor, v_exam.subject_id) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  v_admin := exists (select 1 from public.profiles a where a.id = p_actor and a.role in ('owner', 'admin'));

  select p.id, btrim(p.first_name || ' ' || p.last_name) as name, d.photo_path into v_stu
  from public.student_details d
  join public.profiles p on p.id = d.profile_id
  where d.index_number = v_idx and p.role = 'student' and p.status = 'active';
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  v_booked := exists (
    select 1 from public.bookings b
    where b.exam_id = p_exam and b.student_id = v_stu.id and b.status in ('paid', 'cancel_requested'));
  if not v_admin and not v_booked then
    return jsonb_build_object('ok', true, 'booked', false);
  end if;
  select a.status into v_status from public.attendance a where a.exam_id = p_exam and a.student_id = v_stu.id;
  return jsonb_build_object('ok', true, 'studentId', v_stu.id, 'name', v_stu.name,
    'photoPath', v_stu.photo_path, 'booked', v_booked, 'status', v_status);
end;
$$;
revoke execute on function public.attendance_lookup_as(uuid, uuid, text) from public, anon, authenticated;

create function public.attendance_lookup(p_exam uuid, p_index text)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.attendance_lookup_as(auth.uid(), p_exam, p_index)
$$;

-- ---------------------------------------------------------------------------------------------
create function public.mark_attendance_as(p_actor uuid, p_exam uuid, p_student uuid, p_now timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_exam public.exams%rowtype;
  v_booking uuid;
  v_existing public.attendance_status;
  v_status public.attendance_status;
begin
  if p_actor is null or p_exam is null or p_student is null or p_now is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_exam from public.exams e where e.id = p_exam for share;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not public.attendance_can_manage(p_actor, v_exam.subject_id) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if v_exam.status <> 'published' then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;

  select b.id into v_booking from public.bookings b
  where b.exam_id = p_exam and b.student_id = p_student and b.status in ('paid', 'cancel_requested')
  limit 1;
  if v_booking is null then
    return jsonb_build_object('ok', false, 'code', 'not_booked');
  end if;

  select a.status into v_existing from public.attendance a where a.exam_id = p_exam and a.student_id = p_student;
  if found then
    return jsonb_build_object('ok', true, 'status', v_existing, 'already', true);
  end if;

  v_status := case when p_now >= v_exam.starts_at + interval '15 minutes' then 'late' else 'present' end;
  insert into public.attendance (exam_id, student_id, status, marked_by, marked_at)
  values (p_exam, p_student, v_status, p_actor, p_now);
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (p_actor, 'attendance_marked', 'booking', v_booking);
  return jsonb_build_object('ok', true, 'status', v_status, 'already', false);
end;
$$;
revoke execute on function public.mark_attendance_as(uuid, uuid, uuid, timestamptz) from public, anon, authenticated;

create function public.mark_attendance(p_exam uuid, p_student uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.mark_attendance_as(auth.uid(), p_exam, p_student, now())
$$;

-- ---------------------------------------------------------------------------------------------
create function public.close_register_as(p_actor uuid, p_exam uuid, p_now timestamptz)
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
    select distinct b.exam_id, b.student_id, 'absent', p_actor, p_now
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

create function public.close_register(p_exam uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.close_register_as(auth.uid(), p_exam, now())
$$;

revoke execute on function public.normalise_index(text) from public, anon;
revoke execute on function public.attendance_lookup(uuid, text) from public, anon;
revoke execute on function public.mark_attendance(uuid, uuid) from public, anon;
revoke execute on function public.close_register(uuid) from public, anon;
grant execute on function public.attendance_lookup(uuid, text) to authenticated;
grant execute on function public.mark_attendance(uuid, uuid) to authenticated;
grant execute on function public.close_register(uuid) to authenticated;
