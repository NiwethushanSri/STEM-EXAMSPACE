-- Part 2 Task 3: booking functions (no payment gateway), cancellations, manual refunds, expiry.
-- Clients never write bookings directly. Client/admin RPCs check the caller themselves; internal
-- helpers (taking an explicit actor and clock) have no client grant.

-- ---------------------------------------------------------------------------------------------
-- Core insert shared by create_booking and admin_add_booking.
-- ---------------------------------------------------------------------------------------------
create function public.booking_create_core(
  p_exam uuid,
  p_student uuid,
  p_by uuid,
  p_now timestamptz,
  p_enforce_deadline boolean,
  p_paid boolean,
  p_note text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_exam public.exams%rowtype;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
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
  if public.seats_taken(p_exam) >= v_exam.seat_limit then
    return jsonb_build_object('ok', false, 'code', 'fully_booked');
  end if;

  v_status := case when v_exam.price_pence = 0 or p_paid then 'paid' else 'awaiting_payment' end;
  insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, paid_offline, notes)
  values (p_exam, p_student, p_by, v_status, v_exam.price_pence, coalesce(p_paid, false), v_note)
  returning id into v_id;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (p_by, 'booking_created', 'booking', v_id);
  return jsonb_build_object('ok', true, 'id', v_id, 'status', v_status);
end;
$$;
revoke execute on function public.booking_create_core(uuid, uuid, uuid, timestamptz, boolean, boolean, text)
  from public, anon, authenticated;

-- Caller rules for family bookings (explicit actor and clock so the deadline can be tested).
create function public.booking_create_as(p_actor uuid, p_exam uuid, p_student uuid, p_now timestamptz)
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
  return public.booking_create_core(p_exam, p_student, p_actor, p_now, true, false, null);
end;
$$;
revoke execute on function public.booking_create_as(uuid, uuid, uuid, timestamptz) from public, anon, authenticated;

create function public.create_booking(p_exam uuid, p_student uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.booking_create_as(auth.uid(), p_exam, p_student, now())
$$;

create function public.admin_add_booking(p_exam uuid, p_student uuid, p_paid boolean, p_note text)
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
  return public.booking_create_core(p_exam, p_student, v_actor, now(), false, coalesce(p_paid, false), p_note);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Admin: mark paid / cancel an unpaid booking.
-- ---------------------------------------------------------------------------------------------
create function public.mark_booking_paid(p_booking uuid, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_exam uuid;
  v_b public.bookings%rowtype;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not exists (
    select 1 from public.profiles a
    where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin') for share) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if v_note is not null and char_length(v_note) > 500 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select b.exam_id into v_exam from public.bookings b where b.id = p_booking;
  if v_exam is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  perform 1 from public.exams e where e.id = v_exam for share;
  select * into v_b from public.bookings b where b.id = p_booking for update;
  if v_b.status <> 'awaiting_payment' then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  update public.bookings
  set status = 'paid', paid_offline = true,
      notes = case when v_note is null then notes when notes is null then v_note else notes || E'\n' || v_note end
  where id = v_b.id;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'booking_marked_paid', 'booking', v_b.id);
  return jsonb_build_object('ok', true, 'id', v_b.id);
end;
$$;

create function public.cancel_booking_admin(p_booking uuid, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_exam uuid;
  v_b public.bookings%rowtype;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not exists (
    select 1 from public.profiles a
    where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin') for share) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if v_note is not null and char_length(v_note) > 500 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select b.exam_id into v_exam from public.bookings b where b.id = p_booking;
  if v_exam is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  perform 1 from public.exams e where e.id = v_exam for share;
  select * into v_b from public.bookings b where b.id = p_booking for update;
  if v_b.status <> 'awaiting_payment' then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  update public.bookings
  set status = 'cancelled',
      notes = case when v_note is null then notes when notes is null then v_note else notes || E'\n' || v_note end
  where id = v_b.id;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'booking_cancelled_by_admin', 'booking', v_b.id);
  return jsonb_build_object('ok', true, 'id', v_b.id);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Cancellation requests (family) and decisions / manual refunds (admin).
-- ---------------------------------------------------------------------------------------------
create function public.request_cancellation_as(p_actor uuid, p_booking uuid, p_now timestamptz)
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
  if v_b.status <> 'paid' or v_exam.status = 'cancelled' or v_exam.starts_at <= p_now then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  update public.bookings set status = 'cancel_requested' where id = v_b.id;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (p_actor, 'booking_cancellation_requested', 'booking', v_b.id);
  return jsonb_build_object('ok', true, 'id', v_b.id);
end;
$$;
revoke execute on function public.request_cancellation_as(uuid, uuid, timestamptz) from public, anon, authenticated;

create function public.request_cancellation(p_booking uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.request_cancellation_as(auth.uid(), p_booking, now())
$$;

create function public.decide_cancellation(p_booking uuid, p_approve boolean, p_refund_pence int, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_exam uuid;
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
  perform 1 from public.exams e where e.id = v_exam for share;
  select * into v_b from public.bookings b where b.id = p_booking for update;

  -- Decidable: a cancellation request, or any booking flagged refund_due (exam cancelled / account deleted).
  if not (v_b.status = 'cancel_requested' or (v_b.refund_due and v_b.status in ('part_refunded', 'cancelled'))) then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;

  if p_approve then
    v_total := v_b.refunded_pence + p_refund_pence;
    if v_total > v_b.amount_pence then
      return jsonb_build_object('ok', false, 'code', 'invalid_input');
    end if;
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
    -- Declining only applies to a live request; flagged (exam cancelled / account deleted) rows cannot be declined.
    if v_b.status <> 'cancel_requested' or v_b.refund_due then
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

-- ---------------------------------------------------------------------------------------------
-- Expiry of unpaid bookings after the booking deadline (cron; no client grant).
-- ---------------------------------------------------------------------------------------------
create function public.expire_unpaid_bookings(p_now timestamptz default now())
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int;
begin
  with changed as (
    update public.bookings b
    set status = 'expired'
    from public.exams e
    where e.id = b.exam_id
      and b.status = 'awaiting_payment'
      and e.booking_deadline < p_now
    returning b.id
  ), logged as (
    insert into public.audit_log (actor_id, action, target_type, target_id)
    select null, 'booking_expired', 'booking', id from changed
    returning 1
  )
  select count(*)::int into v_count from changed;
  return v_count;
end;
$$;
revoke execute on function public.expire_unpaid_bookings(timestamptz) from public, anon, authenticated;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'expire-unpaid-bookings') then
    perform cron.unschedule('expire-unpaid-bookings');
  end if;
  perform cron.schedule('expire-unpaid-bookings', '*/5 * * * *', $job$select public.expire_unpaid_bookings()$job$);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Account deletion: release the person's seats; paid money becomes a refund follow-up.
-- ---------------------------------------------------------------------------------------------
create function public.release_bookings_on_profile_delete()
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
    where b.student_id = old.id
      and b.status in ('awaiting_payment', 'paid', 'cancel_requested')
    returning b.id
  )
  insert into public.audit_log (actor_id, action, target_type, target_id)
  select auth.uid(), 'booking_cancelled_by_account_deletion', 'booking', id from changed;
  return old;
end;
$$;
revoke execute on function public.release_bookings_on_profile_delete() from public, anon, authenticated;

create trigger profiles_release_bookings before delete on public.profiles
  for each row execute function public.release_bookings_on_profile_delete();

-- ---------------------------------------------------------------------------------------------
-- Grants: client and admin RPCs to authenticated only.
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.create_booking(uuid, uuid) from public, anon;
revoke execute on function public.admin_add_booking(uuid, uuid, boolean, text) from public, anon;
revoke execute on function public.mark_booking_paid(uuid, text) from public, anon;
revoke execute on function public.cancel_booking_admin(uuid, text) from public, anon;
revoke execute on function public.request_cancellation(uuid) from public, anon;
revoke execute on function public.decide_cancellation(uuid, boolean, int, text) from public, anon;
grant execute on function public.create_booking(uuid, uuid) to authenticated;
grant execute on function public.admin_add_booking(uuid, uuid, boolean, text) to authenticated;
grant execute on function public.mark_booking_paid(uuid, text) to authenticated;
grant execute on function public.cancel_booking_admin(uuid, text) to authenticated;
grant execute on function public.request_cancellation(uuid) to authenticated;
grant execute on function public.decide_cancellation(uuid, boolean, int, text) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Exam cancel: paid bookings with nothing to refund are simply cancelled (replaces 0034 body, grants kept).
-- ---------------------------------------------------------------------------------------------
create or replace function public.set_exam_status(p_id uuid, p_status public.exam_status)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_role public.app_role;
  v_exam public.exams%rowtype;
begin
  select a.role into v_role
  from public.profiles a where a.id = v_actor and a.status = 'active' for share;
  if v_role is null or v_role not in ('owner', 'admin') then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_id is null or p_status is null or p_status in ('draft', 'completed') then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  select * into v_exam from public.exams e where e.id = p_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  if p_status = 'published' then
    if v_exam.status <> 'draft' then
      return jsonb_build_object('ok', false, 'code', 'conflict');
    end if;
    if not v_exam.price_confirmed then
      return jsonb_build_object('ok', false, 'code', 'invalid_input', 'message', 'Confirm the price first');
    end if;
    if v_exam.starts_at <= now() or v_exam.booking_deadline <= now() then
      return jsonb_build_object('ok', false, 'code', 'invalid_input');
    end if;
    if v_exam.format = 'in_person' and not exists (
      select 1 from public.venues v
      where v.id = v_exam.venue_id and v.active and v_exam.room = any (v.rooms)) then
      return jsonb_build_object('ok', false, 'code', 'invalid_input');
    end if;
    update public.exams set status = 'published' where id = v_exam.id;
    insert into public.audit_log (actor_id, action, target_type, target_id)
    values (v_actor, 'exam_published', 'exam', v_exam.id);
  else
    if v_exam.status <> 'published' then
      return jsonb_build_object('ok', false, 'code', 'conflict');
    end if;
    -- Task 11 must add the `reserved` status to this path (cancel it like awaiting_payment).
    with changed as (
      update public.bookings set status = 'cancelled'
      where exam_id = v_exam.id
        and (status = 'awaiting_payment'
             or (status in ('paid', 'cancel_requested') and amount_pence = 0))
      returning id
    )
    insert into public.audit_log (actor_id, action, target_type, target_id)
    select v_actor, 'booking_cancelled_by_exam', 'booking', id from changed;
    with changed as (
      update public.bookings
      set status = case when status = 'paid' then 'cancel_requested'::public.booking_status else status end,
          refund_due = true,
          notes = case when notes is null or notes = '' then 'exam cancelled — refund due'
                       else notes || E'\n' || 'exam cancelled — refund due' end
      where exam_id = v_exam.id
        and status in ('paid', 'cancel_requested', 'part_refunded')
        and refunded_pence < amount_pence
      returning id
    )
    insert into public.audit_log (actor_id, action, target_type, target_id)
    select v_actor, 'booking_cancelled_by_exam', 'booking', id from changed;
    update public.exams set status = 'cancelled' where id = v_exam.id;
    insert into public.audit_log (actor_id, action, target_type, target_id)
    values (v_actor, 'exam_cancelled', 'exam', v_exam.id);
  end if;
  return jsonb_build_object('ok', true, 'id', v_exam.id);
end;
$$;
