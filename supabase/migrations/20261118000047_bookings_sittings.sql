-- Phase 1A Task 2: a booking records its sitting (at the centre or at home) and, for the centre, which one.
-- Seats are counted per centre; home sittings have no limit. Exam-day registers are per centre.

create type public.sitting_mode as enum ('centre', 'home');

-- ---------------------------------------------------------------------------------------------
-- bookings.sitting. Backfill: bookings at a centre (in-person exams, 20261118000046) sit at the centre;
-- the rest (online exams) sit at home.
-- ---------------------------------------------------------------------------------------------
alter table public.bookings add column sitting public.sitting_mode;

alter table public.bookings disable trigger bookings_touch_updated_at;
alter table public.bookings disable trigger bookings_set_paid_at;

update public.bookings
set sitting = case when centre_id is null then 'home'::public.sitting_mode else 'centre'::public.sitting_mode end
where sitting is null;

alter table public.bookings enable trigger bookings_touch_updated_at;
alter table public.bookings enable trigger bookings_set_paid_at;

alter table public.bookings
  alter column sitting set not null,
  add constraint bookings_sitting_matches_centre check ((sitting = 'centre') = (centre_id is not null));

-- ---------------------------------------------------------------------------------------------
-- Booking creation with a sitting and a centre (replaces 20261110000035 and 20261110000036).
-- ---------------------------------------------------------------------------------------------
drop function public.create_booking(uuid, uuid);
drop function public.admin_add_booking(uuid, uuid, boolean, text);
drop function public.booking_create_as(uuid, uuid, uuid, timestamptz);
drop function public.booking_create_core(uuid, uuid, uuid, timestamptz, boolean, boolean, text);

create function public.booking_create_core(
  p_exam uuid,
  p_student uuid,
  p_by uuid,
  p_now timestamptz,
  p_enforce_deadline boolean,
  p_paid boolean,
  p_note text,
  p_sitting public.sitting_mode,
  p_centre uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_exam public.exams%rowtype;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_sitting public.sitting_mode := p_sitting;
  v_centre public.exam_centres%rowtype;
  v_status public.booking_status;
  v_id uuid;
begin
  if p_exam is null or p_student is null or p_now is null
     or (v_note is not null and char_length(v_note) > 500) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  -- The exam row lock serialises concurrent bookings for the same exam (last-seat race).
  select * into v_exam from public.exams e where e.id = p_exam for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_exam.status <> 'published' or not v_exam.price_confirmed or v_exam.starts_at <= p_now then
    return jsonb_build_object('ok', false, 'code', 'not_bookable');
  end if;
  if p_enforce_deadline and p_now >= v_exam.booking_deadline then
    return jsonb_build_object('ok', false, 'code', 'deadline_passed');
  end if;

  if not exists (
    select 1 from public.profiles s
    where s.id = p_student and s.role = 'student' and s.status = 'active' for share) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  if exists (
    select 1 from public.bookings b
    where b.exam_id = p_exam and b.student_id = p_student
      and b.status in ('awaiting_payment', 'paid', 'cancel_requested')) then
    return jsonb_build_object('ok', false, 'code', 'already_booked');
  end if;

  -- Sitting: the exam's only sitting when none is given; an exam offering both needs a choice.
  if v_sitting is null then
    if v_exam.format = 'both' then
      return jsonb_build_object('ok', false, 'code', 'choose_sitting');
    end if;
    v_sitting := case when v_exam.format = 'online' then 'home'::public.sitting_mode else 'centre'::public.sitting_mode end;
  elsif (v_sitting = 'home' and v_exam.format = 'in_person')
        or (v_sitting = 'centre' and v_exam.format = 'online') then
    return jsonb_build_object('ok', false, 'code', 'sitting_not_offered');
  end if;

  if v_sitting = 'home' then
    -- Home sittings have no centre and no seat limit.
    if p_centre is not null then
      return jsonb_build_object('ok', false, 'code', 'invalid_input');
    end if;
  else
    -- Centre: the exam's only centre when none is given; with several, the family chooses.
    if p_centre is null then
      if (select count(*) from public.exam_centres ec where ec.exam_id = p_exam) > 1 then
        return jsonb_build_object('ok', false, 'code', 'choose_centre');
      end if;
      select * into v_centre from public.exam_centres ec where ec.exam_id = p_exam for update;
      if not found then
        return jsonb_build_object('ok', false, 'code', 'not_bookable');
      end if;
    else
      select * into v_centre from public.exam_centres ec where ec.id = p_centre and ec.exam_id = p_exam for update;
      if not found then
        return jsonb_build_object('ok', false, 'code', 'invalid_input');
      end if;
    end if;
    if public.centre_seats_taken(v_centre.id) >= v_centre.seat_limit then
      return jsonb_build_object('ok', false, 'code', 'centre_full');
    end if;
  end if;

  v_status := case when v_exam.price_pence = 0 or p_paid then 'paid' else 'awaiting_payment' end;
  insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, paid_offline, notes,
    sitting, centre_id)
  values (p_exam, p_student, p_by, v_status, v_exam.price_pence, coalesce(p_paid, false), v_note,
    v_sitting, v_centre.id)
  returning id into v_id;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (p_by, 'booking_created', 'booking', v_id);
  return jsonb_build_object('ok', true, 'id', v_id, 'status', v_status);
end;
$$;
revoke execute on function public.booking_create_core(uuid, uuid, uuid, timestamptz, boolean, boolean, text, public.sitting_mode, uuid)
  from public, anon, authenticated;

-- Caller rules for family bookings (explicit actor and clock so the deadline can be tested).
-- At most 3 unpaid bookings per booker (serialised per booker with an advisory lock).
create function public.booking_create_as(
  p_actor uuid,
  p_exam uuid,
  p_student uuid,
  p_now timestamptz,
  p_sitting public.sitting_mode default null,
  p_centre uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.app_role;
begin
  select a.role into v_role
  from public.profiles a where a.id = p_actor and a.status = 'active' for share;
  if v_role is null or p_student is null then
    return jsonb_build_object('ok', false, 'code', case when v_role is null then 'forbidden' else 'invalid_input' end);
  end if;
  if v_role = 'student' then
    if p_student <> p_actor then
      return jsonb_build_object('ok', false, 'code', 'forbidden');
    end if;
  elsif v_role = 'parent' then
    if not exists (
      select 1 from public.parent_children pc where pc.parent_id = p_actor and pc.student_id = p_student) then
      return jsonb_build_object('ok', false, 'code', 'forbidden');
    end if;
  else
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('booking_unpaid:' || p_actor::text, 0));
  if (select count(*) from public.bookings b
      where b.booked_by = p_actor and b.status = 'awaiting_payment') >= 3 then
    return jsonb_build_object('ok', false, 'code', 'too_many_unpaid');
  end if;
  return public.booking_create_core(p_exam, p_student, p_actor, p_now, true, false, null, p_sitting, p_centre);
end;
$$;
revoke execute on function public.booking_create_as(uuid, uuid, uuid, timestamptz, public.sitting_mode, uuid)
  from public, anon, authenticated;

create function public.create_booking(
  p_exam uuid,
  p_student uuid,
  p_sitting public.sitting_mode default null,
  p_centre uuid default null
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.booking_create_as(auth.uid(), p_exam, p_student, now(), p_sitting, p_centre)
$$;

-- Unpaid admin bookings respect the deadline; paid ones do not.
create function public.admin_add_booking(
  p_exam uuid,
  p_student uuid,
  p_paid boolean,
  p_note text,
  p_sitting public.sitting_mode default null,
  p_centre uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
begin
  if not exists (
    select 1 from public.profiles a
    where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin') for share) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  return public.booking_create_core(p_exam, p_student, v_actor, now(), not coalesce(p_paid, false),
    coalesce(p_paid, false), p_note, p_sitting, p_centre);
end;
$$;

revoke execute on function public.create_booking(uuid, uuid, public.sitting_mode, uuid) from public, anon;
revoke execute on function public.admin_add_booking(uuid, uuid, boolean, text, public.sitting_mode, uuid) from public, anon;
grant execute on function public.create_booking(uuid, uuid, public.sitting_mode, uuid) to authenticated;
grant execute on function public.admin_add_booking(uuid, uuid, boolean, text, public.sitting_mode, uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Admin: move a live booking to the other sitting or another centre of the same exam (audited).
-- Families cannot change their sitting.
-- ---------------------------------------------------------------------------------------------
create function public.change_booking_sitting(
  p_booking uuid,
  p_sitting public.sitting_mode,
  p_centre uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := btrim(coalesce(p_reason, ''));
  v_exam_id uuid;
  v_exam public.exams%rowtype;
  v_b public.bookings%rowtype;
  v_centre public.exam_centres%rowtype;
begin
  if not exists (
    select 1 from public.profiles a
    where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin') for share) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_booking is null or p_sitting is null or char_length(v_reason) not between 1 and 300 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select b.exam_id into v_exam_id from public.bookings b where b.id = p_booking;
  if v_exam_id is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  -- The exam lock serialises this with new bookings at the same centres.
  select * into v_exam from public.exams e where e.id = v_exam_id for update;
  select * into v_b from public.bookings b where b.id = p_booking for update;
  if v_b.status not in ('awaiting_payment', 'paid', 'cancel_requested') or v_exam.status <> 'published' then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  if (p_sitting = 'home' and v_exam.format = 'in_person')
     or (p_sitting = 'centre' and v_exam.format = 'online') then
    return jsonb_build_object('ok', false, 'code', 'sitting_not_offered');
  end if;

  if p_sitting = 'home' then
    if p_centre is not null then
      return jsonb_build_object('ok', false, 'code', 'invalid_input');
    end if;
  else
    if p_centre is null then
      if (select count(*) from public.exam_centres ec where ec.exam_id = v_exam.id) > 1 then
        return jsonb_build_object('ok', false, 'code', 'choose_centre');
      end if;
      select * into v_centre from public.exam_centres ec where ec.exam_id = v_exam.id for update;
    else
      select * into v_centre from public.exam_centres ec where ec.id = p_centre and ec.exam_id = v_exam.id for update;
    end if;
    if not found then
      return jsonb_build_object('ok', false, 'code', 'invalid_input');
    end if;
  end if;

  -- Nothing to change, or a register that is already closed.
  if (p_sitting = v_b.sitting and v_centre.id is not distinct from v_b.centre_id)
     or v_centre.register_closed_at is not null then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  if p_sitting = 'centre' and public.centre_seats_taken(v_centre.id) >= v_centre.seat_limit then
    return jsonb_build_object('ok', false, 'code', 'centre_full');
  end if;

  update public.bookings
  set sitting = p_sitting, centre_id = v_centre.id,
      notes = case when notes is null or notes = '' then 'sitting changed — ' || v_reason
                   else notes || E'\n' || 'sitting changed — ' || v_reason end
  where id = v_b.id;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'booking_sitting_changed', 'booking', v_b.id);
  return jsonb_build_object('ok', true, 'id', v_b.id);
end;
$$;
revoke execute on function public.change_booking_sitting(uuid, public.sitting_mode, uuid, text) from public, anon;
grant execute on function public.change_booking_sitting(uuid, public.sitting_mode, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Registers per centre (replaces 20261110000037, 0039 and 0043). Only centre bookings at that centre are on
-- its register; home candidates are on none. Attendance stays one row per exam and student.
-- ---------------------------------------------------------------------------------------------
drop function public.attendance_lookup(uuid, text);
drop function public.attendance_lookup_as(uuid, uuid, text);
drop function public.mark_attendance(uuid, uuid);
drop function public.mark_attendance_as(uuid, uuid, uuid, timestamptz);
drop function public.close_register(uuid);
drop function public.close_register_as(uuid, uuid, timestamptz);

create function public.attendance_lookup_as(p_actor uuid, p_centre uuid, p_index text)
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
  if p_actor is null or p_centre is null or v_idx is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select e.* into v_exam
  from public.exam_centres ec join public.exams e on e.id = ec.exam_id
  where ec.id = p_centre;
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
    where b.centre_id = p_centre and b.sitting = 'centre' and b.student_id = v_stu.id
      and b.status in ('paid', 'cancel_requested'));
  if not v_admin and not v_booked then
    return jsonb_build_object('ok', true, 'booked', false);
  end if;
  select a.status into v_status from public.attendance a where a.exam_id = v_exam.id and a.student_id = v_stu.id;
  return jsonb_build_object('ok', true, 'studentId', v_stu.id, 'name', v_stu.name,
    'photoPath', v_stu.photo_path, 'booked', v_booked, 'status', v_status);
end;
$$;
revoke execute on function public.attendance_lookup_as(uuid, uuid, text) from public, anon, authenticated;

create function public.attendance_lookup(p_centre uuid, p_index text)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.attendance_lookup_as(auth.uid(), p_centre, p_index)
$$;

create function public.mark_attendance_as(p_actor uuid, p_centre uuid, p_student uuid, p_now timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_exam_id uuid;
  v_subject bigint;
  v_exam public.exams%rowtype;
  v_centre public.exam_centres%rowtype;
  v_booking uuid;
  v_status public.attendance_status;
  v_new public.attendance_status;
begin
  if p_actor is null or p_centre is null or p_student is null or p_now is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select ec.exam_id, e.subject_id into v_exam_id, v_subject
  from public.exam_centres ec join public.exams e on e.id = ec.exam_id
  where ec.id = p_centre;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not public.attendance_can_manage(p_actor, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;

  -- Same lock order as close_register: the exam, then the centre.
  select * into v_exam from public.exams e where e.id = v_exam_id for share;
  select * into v_centre from public.exam_centres ec where ec.id = p_centre for share;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_exam.status <> 'published' or v_centre.register_closed_at is not null then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;

  select b.id into v_booking from public.bookings b
  where b.centre_id = p_centre and b.sitting = 'centre' and b.student_id = p_student
    and b.status in ('paid', 'cancel_requested')
  limit 1 for share;
  if v_booking is null then
    return jsonb_build_object('ok', false, 'code', 'not_booked');
  end if;

  v_new := case when p_now >= v_exam.starts_at + interval '15 minutes' then 'late' else 'present' end;
  insert into public.attendance (exam_id, student_id, status, marked_by, marked_at)
  values (v_exam.id, p_student, v_new, p_actor, p_now)
  on conflict (exam_id, student_id) do nothing
  returning status into v_status;
  if v_status is null then
    select a.status into v_status from public.attendance a where a.exam_id = v_exam.id and a.student_id = p_student;
    return jsonb_build_object('ok', true, 'status', v_status, 'already', true);
  end if;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (p_actor, 'attendance_marked', 'booking', v_booking);
  return jsonb_build_object('ok', true, 'status', v_status, 'already', false);
end;
$$;
revoke execute on function public.mark_attendance_as(uuid, uuid, uuid, timestamptz) from public, anon, authenticated;

create function public.mark_attendance(p_centre uuid, p_student uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.mark_attendance_as(auth.uid(), p_centre, p_student, now())
$$;

-- Closing a centre's register marks its unscanned candidates absent and expires its unpaid bookings.
-- When the last open register of the exam closes, the exam is completed and its other unpaid bookings expire.
create function public.close_register_as(p_actor uuid, p_centre uuid, p_now timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_exam_id uuid;
  v_subject bigint;
  v_exam public.exams%rowtype;
  v_centre public.exam_centres%rowtype;
  v_absent int;
begin
  if p_actor is null or p_centre is null or p_now is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select ec.exam_id, e.subject_id into v_exam_id, v_subject
  from public.exam_centres ec join public.exams e on e.id = ec.exam_id
  where ec.id = p_centre;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not public.attendance_can_manage(p_actor, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;

  select * into v_exam from public.exams e where e.id = v_exam_id for update;
  select * into v_centre from public.exam_centres ec where ec.id = p_centre for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_exam.status <> 'published' or p_now < v_exam.starts_at or v_centre.register_closed_at is not null then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;

  with ins as (
    insert into public.attendance (exam_id, student_id, status, marked_by, marked_at)
    select distinct b.exam_id, b.student_id, 'absent'::public.attendance_status, p_actor, p_now
    from public.bookings b
    where b.centre_id = p_centre and b.sitting = 'centre'
      and b.status in ('paid', 'cancel_requested') and b.student_id is not null
    on conflict (exam_id, student_id) do nothing
    returning 1)
  select count(*) into v_absent from ins;

  with expired as (
    update public.bookings set status = 'expired'
    where centre_id = p_centre and status = 'awaiting_payment'
    returning id)
  insert into public.audit_log (actor_id, action, target_type, target_id)
  select p_actor, 'booking_expired', 'booking', id from expired;
  update public.exam_centres set register_closed_at = p_now where id = p_centre;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (p_actor, 'register_closed', 'exam_centre', p_centre);

  if not exists (
    select 1 from public.exam_centres ec where ec.exam_id = v_exam.id and ec.register_closed_at is null) then
    with expired as (
      update public.bookings set status = 'expired'
      where exam_id = v_exam.id and status = 'awaiting_payment'
      returning id)
    insert into public.audit_log (actor_id, action, target_type, target_id)
    select p_actor, 'booking_expired', 'booking', id from expired;
    update public.exams set status = 'completed' where id = v_exam.id;
    insert into public.audit_log (actor_id, action, target_type, target_id)
    values (p_actor, 'exam_completed', 'exam', v_exam.id);
  end if;
  return jsonb_build_object('ok', true, 'absent', v_absent);
end;
$$;
revoke execute on function public.close_register_as(uuid, uuid, timestamptz) from public, anon, authenticated;

create function public.close_register(p_centre uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.close_register_as(auth.uid(), p_centre, now())
$$;

revoke execute on function public.attendance_lookup(uuid, text) from public, anon;
revoke execute on function public.mark_attendance(uuid, uuid) from public, anon;
revoke execute on function public.close_register(uuid) from public, anon;
grant execute on function public.attendance_lookup(uuid, text) to authenticated;
grant execute on function public.mark_attendance(uuid, uuid) to authenticated;
grant execute on function public.close_register(uuid) to authenticated;
