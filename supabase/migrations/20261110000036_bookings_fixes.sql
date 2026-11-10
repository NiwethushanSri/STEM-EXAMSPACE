-- Part 2 Task 3 fix round 1.

-- 1. Account deletion only releases bookings on upcoming published exams.
create or replace function public.release_bookings_on_profile_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  with changed as (
    update public.bookings b
    set status = 'cancelled',
        refund_due = (b.status in ('paid', 'cancel_requested') and b.amount_pence > 0),
        notes = case
          when b.status in ('paid', 'cancel_requested') and b.amount_pence > 0 then
            case when b.notes is null or b.notes = '' then 'account deleted — refund due'
                 else b.notes || E'\n' || 'account deleted — refund due' end
          else b.notes end
    from public.exams e
    where e.id = b.exam_id
      and e.status = 'published'
      and e.starts_at > now()
      and b.student_id = old.id
      and b.status in ('awaiting_payment', 'paid', 'cancel_requested')
    returning b.id
  )
  insert into public.audit_log (actor_id, action, target_type, target_id)
  select auth.uid(), 'booking_cancelled_by_account_deletion', 'booking', id from changed;
  return old;
end;
$$;

-- 2. Unpaid admin bookings respect the deadline; paid ones do not.
create or replace function public.admin_add_booking(p_exam uuid, p_student uuid, p_paid boolean, p_note text)
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
    coalesce(p_paid, false), p_note);
end;
$$;

-- 3b. At most 3 unpaid bookings per booker (serialised per booker with an advisory lock).
create or replace function public.booking_create_as(p_actor uuid, p_exam uuid, p_student uuid, p_now timestamptz)
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
  return public.booking_create_core(p_exam, p_student, p_actor, p_now, true, false, null);
end;
$$;

-- 3a. Cancelling one's own unpaid booking is immediate.
create or replace function public.request_cancellation_as(p_actor uuid, p_booking uuid, p_now timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.app_role;
  v_exam public.exams%rowtype;
  v_exam_id uuid;
  v_b public.bookings%rowtype;
begin
  select a.role into v_role
  from public.profiles a where a.id = p_actor and a.status = 'active' for share;
  if v_role is null or v_role not in ('student', 'parent') then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select b.exam_id into v_exam_id from public.bookings b where b.id = p_booking;
  if v_exam_id is null then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into v_exam from public.exams e where e.id = v_exam_id for share;
  select * into v_b from public.bookings b where b.id = p_booking for update;
  if v_b.student_id is null
     or not (
       (v_role = 'student' and v_b.student_id = p_actor)
       or (v_role = 'parent' and exists (
         select 1 from public.parent_children pc
         where pc.parent_id = p_actor and pc.student_id = v_b.student_id))) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if v_b.status not in ('paid', 'awaiting_payment') or v_exam.status = 'cancelled' or v_exam.starts_at <= p_now then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  if v_b.status = 'awaiting_payment' then
    update public.bookings set status = 'cancelled' where id = v_b.id;
    insert into public.audit_log (actor_id, action, target_type, target_id)
    values (p_actor, 'booking_cancelled_by_owner', 'booking', v_b.id);
  else
    update public.bookings set status = 'cancel_requested' where id = v_b.id;
    insert into public.audit_log (actor_id, action, target_type, target_id)
    values (p_actor, 'booking_cancellation_requested', 'booking', v_b.id);
  end if;
  return jsonb_build_object('ok', true, 'id', v_b.id);
end;
$$;

-- 4 + 5. Decline refused on a cancelled exam; refund bounds checked before adding.
create or replace function public.decide_cancellation(p_booking uuid, p_approve boolean, p_refund_pence int, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_exam uuid;
  v_exam_status public.exam_status;
  v_b public.bookings%rowtype;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_total int;
  v_status public.booking_status;
begin
  if not exists (
    select 1 from public.profiles a
    where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin') for share) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_approve is null or (v_note is not null and char_length(v_note) > 500)
     or (p_approve and (p_refund_pence is null or p_refund_pence < 0)) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select b.exam_id into v_exam from public.bookings b where b.id = p_booking;
  if v_exam is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select e.status into v_exam_status from public.exams e where e.id = v_exam for share;
  select * into v_b from public.bookings b where b.id = p_booking for update;

  if not (v_b.status = 'cancel_requested' or (v_b.refund_due and v_b.status in ('part_refunded', 'cancelled'))) then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;

  if p_approve then
    if p_refund_pence > v_b.amount_pence - v_b.refunded_pence then
      return jsonb_build_object('ok', false, 'code', 'invalid_input');
    end if;
    v_total := v_b.refunded_pence + p_refund_pence;
    v_status := case
      when v_total = v_b.amount_pence and v_total > 0 then 'refunded'
      when v_total > 0 then 'part_refunded'
      else 'cancelled' end;
    update public.bookings
    set status = v_status, refunded_pence = v_total, refund_due = false,
        notes = case when v_note is null then notes when notes is null then v_note else notes || E'\n' || v_note end
    where id = v_b.id;
    insert into public.audit_log (actor_id, action, target_type, target_id)
    values (v_actor, 'booking_cancellation_approved', 'booking', v_b.id);
  else
    if v_b.status <> 'cancel_requested' or v_b.refund_due or v_exam_status = 'cancelled' then
      return jsonb_build_object('ok', false, 'code', 'conflict');
    end if;
    update public.bookings
    set status = 'paid',
        notes = case when v_note is null then notes when notes is null then v_note else notes || E'\n' || v_note end
    where id = v_b.id;
    insert into public.audit_log (actor_id, action, target_type, target_id)
    values (v_actor, 'booking_cancellation_declined', 'booking', v_b.id);
  end if;
  return jsonb_build_object('ok', true, 'id', v_b.id);
end;
$$;
