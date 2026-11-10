-- Part 2 Task 2: venue and exam management. Definer functions; the caller is auth.uid().
-- Business-rule refusals return {"ok": false, "code": ...}; success returns {"ok": true, "id": ...}.

create function public.save_venue(p_id uuid, p_name text, p_rooms text[], p_active boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_role public.app_role;
  v_name text := btrim(coalesce(p_name, ''));
  v_rooms text[];
  v_id uuid;
begin
  select a.role into v_role
  from public.profiles a where a.id = v_actor and a.status = 'active' for share;
  if v_role is null or v_role not in ('owner', 'admin') then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;

  if char_length(v_name) not between 1 and 80 or p_active is null or p_rooms is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select coalesce(array_agg(btrim(r) order by o), '{}') into v_rooms
  from unnest(p_rooms) with ordinality as t(r, o);
  if exists (select 1 from unnest(v_rooms) r where r is null or char_length(r) not between 1 and 40)
     or cardinality(v_rooms) > 50
     or (select count(distinct r) from unnest(v_rooms) r) <> cardinality(v_rooms) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  begin
    if p_id is null then
      insert into public.venues (name, rooms, active) values (v_name, v_rooms, p_active)
      returning id into v_id;
      insert into public.audit_log (actor_id, action, target_type, target_id)
      values (v_actor, 'venue_created', 'venue', v_id);
    else
      update public.venues set name = v_name, rooms = v_rooms, active = p_active
      where id = p_id returning id into v_id;
      if v_id is null then
        return jsonb_build_object('ok', false, 'code', 'not_found');
      end if;
      insert into public.audit_log (actor_id, action, target_type, target_id)
      values (v_actor, 'venue_updated', 'venue', v_id);
    end if;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create function public.save_exam(
  p_id uuid,
  p_subject_id bigint,
  p_title text,
  p_paper text,
  p_format public.exam_format,
  p_venue_id uuid,
  p_room text,
  p_starts_at timestamptz,
  p_duration_minutes int,
  p_seat_limit int,
  p_price_pence int,
  p_booking_deadline timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_role public.app_role;
  v_admin boolean;
  v_exam public.exams%rowtype;
  v_title text := btrim(coalesce(p_title, ''));
  v_paper text := btrim(coalesce(p_paper, ''));
  v_room text := nullif(btrim(coalesce(p_room, '')), '');
  v_price int;
  v_venue public.venues%rowtype;
  v_id uuid;
begin
  select a.role into v_role
  from public.profiles a where a.id = v_actor and a.status = 'active' for share;
  if v_role is null or v_role not in ('owner', 'admin', 'teacher') then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  v_admin := v_role in ('owner', 'admin');

  if p_id is not null then
    select * into v_exam from public.exams e where e.id = p_id for update;
    if not found then
      return jsonb_build_object('ok', false, 'code', 'not_found');
    end if;
  end if;

  -- Teachers: own subjects only (current and target), drafts only.
  if not v_admin then
    if p_subject_id is null or not exists (
      select 1 from public.teacher_subjects ts where ts.teacher_id = v_actor and ts.subject_id = p_subject_id) then
      return jsonb_build_object('ok', false, 'code', 'forbidden');
    end if;
    if p_id is not null then
      if not exists (
        select 1 from public.teacher_subjects ts where ts.teacher_id = v_actor and ts.subject_id = v_exam.subject_id)
         or v_exam.status <> 'draft' then
        return jsonb_build_object('ok', false, 'code', 'forbidden');
      end if;
    end if;
  elsif p_id is not null and v_exam.status in ('cancelled', 'completed') then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;

  -- Price: teachers never set it.
  if v_admin then
    v_price := p_price_pence;
  else
    v_price := case when p_id is null then 0 else v_exam.price_pence end;
  end if;

  if p_subject_id is null or p_format is null or p_starts_at is null or p_booking_deadline is null
     or p_duration_minutes is null or p_seat_limit is null or v_price is null
     or not exists (select 1 from public.subjects s where s.id = p_subject_id)
     or char_length(v_title) not between 1 and 120
     or char_length(v_paper) > 80
     or p_duration_minutes not between 15 and 600
     or p_seat_limit not between 1 and 1000
     or v_price not between 0 and 100000
     or p_booking_deadline > p_starts_at then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  if p_format = 'online' then
    if p_venue_id is not null or v_room is not null then
      return jsonb_build_object('ok', false, 'code', 'invalid_input');
    end if;
  else
    select * into v_venue from public.venues v where v.id = p_venue_id and v.active;
    if not found or v_room is null or not (v_room = any (v_venue.rooms)) then
      return jsonb_build_object('ok', false, 'code', 'invalid_input');
    end if;
  end if;

  if p_id is null then
    insert into public.exams (subject_id, title, paper, format, venue_id, room, starts_at, duration_minutes,
      seat_limit, price_pence, booking_deadline, status, created_by)
    values (p_subject_id, v_title, v_paper, p_format, p_venue_id, v_room, p_starts_at, p_duration_minutes,
      p_seat_limit, v_price, p_booking_deadline, 'draft', v_actor)
    returning id into v_id;
    insert into public.audit_log (actor_id, action, target_type, target_id)
    values (v_actor, 'exam_created', 'exam', v_id);
    return jsonb_build_object('ok', true, 'id', v_id);
  end if;

  if v_exam.status = 'published' and p_starts_at <> v_exam.starts_at and p_starts_at <= now() then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if p_seat_limit < public.seats_taken(v_exam.id) then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  if v_price <> v_exam.price_pence
     and exists (select 1 from public.bookings b where b.exam_id = v_exam.id) then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;

  update public.exams set
    subject_id = p_subject_id, title = v_title, paper = v_paper, format = p_format,
    venue_id = p_venue_id, room = v_room, starts_at = p_starts_at, duration_minutes = p_duration_minutes,
    seat_limit = p_seat_limit, price_pence = v_price, booking_deadline = p_booking_deadline
  where id = v_exam.id;
  if v_exam.status = 'published' then
    insert into public.audit_log (actor_id, action, target_type, target_id)
    values (v_actor, 'exam_updated', 'exam', v_exam.id);
  end if;
  return jsonb_build_object('ok', true, 'id', v_exam.id);
end;
$$;

create function public.set_exam_status(p_id uuid, p_status public.exam_status)
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
    if v_exam.starts_at <= now() or v_exam.booking_deadline <= now() then
      return jsonb_build_object('ok', false, 'code', 'invalid_input');
    end if;
    update public.exams set status = 'published' where id = v_exam.id;
    insert into public.audit_log (actor_id, action, target_type, target_id)
    values (v_actor, 'exam_published', 'exam', v_exam.id);
  else
    if v_exam.status <> 'published' then
      return jsonb_build_object('ok', false, 'code', 'conflict');
    end if;
    update public.bookings set status = 'cancelled'
    where exam_id = v_exam.id and status = 'awaiting_payment';
    update public.bookings
    set status = 'cancel_requested',
        notes = case when notes is null or notes = '' then 'exam cancelled — refund due'
                     else notes || E'\n' || 'exam cancelled — refund due' end
    where exam_id = v_exam.id and status in ('paid', 'cancel_requested');
    update public.exams set status = 'cancelled' where id = v_exam.id;
    insert into public.audit_log (actor_id, action, target_type, target_id)
    values (v_actor, 'exam_cancelled', 'exam', v_exam.id);
  end if;
  return jsonb_build_object('ok', true, 'id', v_exam.id);
end;
$$;

revoke execute on function public.save_venue(uuid, text, text[], boolean) from public, anon;
revoke execute on function public.save_exam(uuid, bigint, text, text, public.exam_format, uuid, text, timestamptz, int, int, int, timestamptz) from public, anon;
revoke execute on function public.set_exam_status(uuid, public.exam_status) from public, anon;
grant execute on function public.save_venue(uuid, text, text[], boolean) to authenticated;
grant execute on function public.save_exam(uuid, bigint, text, text, public.exam_format, uuid, text, timestamptz, int, int, int, timestamptz) to authenticated;
grant execute on function public.set_exam_status(uuid, public.exam_status) to authenticated;
