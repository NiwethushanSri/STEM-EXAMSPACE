-- Phase 1A Task 1: an exam runs at one or more centres, each with a venue, a room and its own seat limit.
-- Replaces exams.venue_id, exams.room and exams.seat_limit. Seats are counted per centre; home sittings
-- (next migration) have no limit. bookings.centre_id is added here because seat counts, the public view and
-- save_exam's centre rules count bookings per centre; 20261118000047 adds bookings.sitting and its check.
-- A centre is never deleted: removing it sets removed_at, so past bookings keep their centre. A removed centre
-- is skipped everywhere (timetable, booking, moves, registers, publishing, venue checks, save_exam).

-- ---------------------------------------------------------------------------------------------
-- Centres.
-- ---------------------------------------------------------------------------------------------
create table public.exam_centres (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.exams (id) on delete cascade,
  venue_id uuid not null references public.venues (id),
  room text not null,
  seat_limit int not null check (seat_limit between 1 and 1000),
  register_closed_at timestamptz,
  removed_at timestamptz,
  created_at timestamptz not null default now(),
  -- One centre per exam, venue and room among those not removed. An exclusion constraint because it is both
  -- partial and deferrable (save_exam swaps rooms between centres and checks the key before returning).
  constraint exam_centres_exam_venue_room_excl
    exclude using btree (exam_id with =, venue_id with =, room with =) where (removed_at is null)
    deferrable initially immediate,
  -- Target of the bookings (centre_id, exam_id) foreign key: a booking's centre belongs to its exam.
  constraint exam_centres_id_exam_key unique (id, exam_id)
);
create index exam_centres_venue_idx on public.exam_centres (venue_id);

alter table public.exam_centres enable row level security;
revoke all on public.exam_centres from anon, authenticated;
grant select on public.exam_centres to authenticated;

-- Visible exactly when its exam is: the subquery runs under exams_select and exams_select_family.
create policy exam_centres_select on public.exam_centres for select to authenticated
using (exists (select 1 from public.exams e where e.id = exam_centres.exam_id));

-- ---------------------------------------------------------------------------------------------
-- Backfill: each in-person exam keeps its venue, room and seat limit as its single centre.
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from public.exams e where e.format = 'in_person' and (e.venue_id is null or e.room is null)) then
    raise exception 'An in-person exam has no venue or room; give it one before this migration';
  end if;
end;
$$;

insert into public.exam_centres (exam_id, venue_id, room, seat_limit)
select e.id, e.venue_id, e.room, e.seat_limit
from public.exams e
where e.format = 'in_person' and e.venue_id is not null
  and not exists (select 1 from public.exam_centres ec where ec.exam_id = e.id);

-- ---------------------------------------------------------------------------------------------
-- Bookings at a centre. Bookings on in-person exams are at the exam's single centre.
-- ---------------------------------------------------------------------------------------------
alter table public.bookings add column centre_id uuid;
alter table public.bookings
  add constraint bookings_centre_exam_fkey foreign key (centre_id, exam_id)
  references public.exam_centres (id, exam_id);
create index bookings_centre_idx on public.bookings (centre_id) where centre_id is not null;

-- The backfill changes no booking's history: updated_at and paid_at stay as they are.
alter table public.bookings disable trigger bookings_touch_updated_at;
alter table public.bookings disable trigger bookings_set_paid_at;

update public.bookings b
set centre_id = ec.id
from public.exam_centres ec
join public.exams e on e.id = ec.exam_id
where ec.exam_id = b.exam_id and e.format = 'in_person' and b.centre_id is null;

alter table public.bookings enable trigger bookings_touch_updated_at;
alter table public.bookings enable trigger bookings_set_paid_at;

-- ---------------------------------------------------------------------------------------------
-- Drop the exam-level venue, room and seat limit (and what reads them).
-- ---------------------------------------------------------------------------------------------
drop view public.exams_public;
drop function public.seats_taken(uuid);
drop function public.save_exam(uuid, bigint, text, text, public.exam_format, uuid, text, timestamptz, int, int, int, timestamptz);

alter table public.exams
  drop constraint exams_venue_matches_format,
  drop constraint exams_online_has_no_room,
  drop column venue_id,
  drop column room,
  drop column seat_limit;

-- Seats taken at a centre: awaiting_payment, paid, cancel_requested; a cancelled exam releases its seats.
create function public.centre_seats_taken(p_centre uuid)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int
  from public.bookings b
  join public.exams e on e.id = b.exam_id
  where b.centre_id = p_centre
    and e.status <> 'cancelled'
    and b.status in ('awaiting_payment', 'paid', 'cancel_requested')
$$;
revoke execute on function public.centre_seats_taken(uuid) from public, anon, authenticated;
grant execute on function public.centre_seats_taken(uuid) to service_role;

-- ---------------------------------------------------------------------------------------------
-- save_exam with centres. p_centres is a JSON array of {"id"?, "venue_id", "room", "seat_limit"}: empty
-- (or null) for a home-only exam, at least one centre otherwise. A centre with an id is updated in place;
-- one without is added; a current centre left out is removed (archived), unless live bookings sit there.
-- Other rules as in 20261110000043.
-- ---------------------------------------------------------------------------------------------
create function public.save_exam(
  p_id uuid,
  p_subject_id bigint,
  p_title text,
  p_paper text,
  p_format public.exam_format,
  p_centres jsonb,
  p_starts_at timestamptz,
  p_duration_minutes int,
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
  v_price int;
  v_centres jsonb := coalesce(p_centres, '[]'::jsonb);
  v_n int;
  v_ids uuid[];
  v_keep uuid[];
  v_venues uuid[];
  v_rooms text[];
  v_limits int[];
  v_old_id uuid;
  v_old_venue uuid;
  v_old_room text;
  v_venue public.venues%rowtype;
  v_id uuid;
  v_uuid constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
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
      -- Teachers get the same answer for missing and foreign exams.
      return jsonb_build_object('ok', false, 'code', case when v_admin then 'not_found' else 'forbidden' end);
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
     or p_duration_minutes is null or v_price is null
     or p_starts_at in ('infinity', '-infinity') or p_booking_deadline in ('infinity', '-infinity')
     or p_starts_at > now() + interval '3 years'
     or not exists (select 1 from public.subjects s where s.id = p_subject_id)
     or char_length(v_title) not between 1 and 120
     or char_length(v_paper) > 80
     or p_duration_minutes not between 15 and 600
     or v_price not between 0 and 100000
     or p_booking_deadline > p_starts_at then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  -- Centres: shape first, then values. None for a home-only exam; 1 to 20 when it offers the centre.
  if jsonb_typeof(v_centres) <> 'array' then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  v_n := jsonb_array_length(v_centres);
  if v_n > 20 or (p_format = 'online') <> (v_n = 0) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_centres) c
    where jsonb_typeof(c) <> 'object'
       or coalesce(jsonb_typeof(c -> 'id'), 'null') not in ('null', 'string')
       or jsonb_typeof(c -> 'venue_id') is distinct from 'string'
       or jsonb_typeof(c -> 'room') is distinct from 'string'
       or jsonb_typeof(c -> 'seat_limit') is distinct from 'number'
       or (c ->> 'id') !~* v_uuid
       or (c ->> 'venue_id') !~* v_uuid
       or (c ->> 'seat_limit') !~ '^[0-9]{1,4}$'
       or char_length(btrim(c ->> 'room')) not between 1 and 40) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select coalesce(array_agg((c ->> 'id')::uuid order by o), '{}'),
         coalesce(array_agg((c ->> 'venue_id')::uuid order by o), '{}'),
         coalesce(array_agg(btrim(c ->> 'room') order by o), '{}'),
         coalesce(array_agg((c ->> 'seat_limit')::int order by o), '{}')
  into v_ids, v_venues, v_rooms, v_limits
  from jsonb_array_elements(v_centres) with ordinality as t(c, o);
  v_keep := array_remove(v_ids, null);
  -- Seat limits in range; one centre per venue and room; each id once and one of this exam's current centres.
  if exists (select 1 from unnest(v_limits) l where l not between 1 and 1000)
     or (select count(distinct t.v::text || '/' || lower(t.r)) from unnest(v_venues, v_rooms) as t(v, r)) <> v_n
     or (select count(distinct i) from unnest(v_keep) i) <> cardinality(v_keep)
     or exists (
       select 1 from unnest(v_keep) i
       where p_id is null
          or not exists (
            select 1 from public.exam_centres ec
            where ec.id = i and ec.exam_id = p_id and ec.removed_at is null)) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  for i in 1 .. v_n loop
    select ec.id, ec.venue_id, ec.room into v_old_id, v_old_venue, v_old_room
    from public.exam_centres ec where ec.id = v_ids[i];
    -- Venue and room are re-validated unless a published exam keeps both unchanged.
    if p_id is null or v_exam.status <> 'published' or v_old_id is null
       or v_old_venue <> v_venues[i] or v_old_room <> v_rooms[i] then
      select * into v_venue from public.venues v where v.id = v_venues[i] and v.active for share;
      if not found or not (v_rooms[i] = any (v_venue.rooms)) then
        return jsonb_build_object('ok', false, 'code', 'invalid_input');
      end if;
    end if;
  end loop;

  if p_id is null then
    insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes,
      price_pence, price_confirmed, booking_deadline, status, created_by)
    values (p_subject_id, v_title, v_paper, p_format, p_starts_at, p_duration_minutes,
      v_price, v_admin, p_booking_deadline, 'draft', v_actor)
    returning id into v_id;
    insert into public.exam_centres (exam_id, venue_id, room, seat_limit)
    select v_id, t.v, t.r, t.l from unnest(v_venues, v_rooms, v_limits) as t(v, r, l);
    insert into public.audit_log (actor_id, action, target_type, target_id)
    values (v_actor, 'exam_created', 'exam', v_id);
    return jsonb_build_object('ok', true, 'id', v_id);
  end if;

  if v_exam.status = 'published' then
    -- Once started, dates are frozen; a moved deadline must still be in the future.
    if v_exam.starts_at <= now()
       and (p_starts_at is distinct from v_exam.starts_at
            or p_booking_deadline is distinct from v_exam.booking_deadline) then
      return jsonb_build_object('ok', false, 'code', 'conflict');
    end if;
  end if;
  if v_exam.status = 'published' and p_starts_at <> v_exam.starts_at and p_starts_at <= now() then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_exam.status = 'published' and p_booking_deadline is distinct from v_exam.booking_deadline
     and p_booking_deadline <= now() then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;

  -- Centres are locked before their seats are compared (bookings lock the exam, then the centre).
  perform 1 from public.exam_centres ec
  where ec.exam_id = v_exam.id and ec.removed_at is null order by ec.id for update;
  if exists (
    select 1 from unnest(v_ids, v_limits) as t(i, l)
    where t.i is not null and t.l < public.centre_seats_taken(t.i)) then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  -- A centre with live bookings stays; past bookings do not hold it (they keep their centre_id on record).
  if exists (
    select 1 from public.exam_centres ec
    join public.bookings b on b.centre_id = ec.id
    where ec.exam_id = v_exam.id and ec.removed_at is null and ec.id <> all (v_keep)
      and b.status in ('awaiting_payment', 'paid', 'cancel_requested')) then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  -- The new format must still offer each live booking its sitting (a home booking has no centre).
  if exists (
    select 1 from public.bookings b
    where b.exam_id = v_exam.id
      and b.status in ('awaiting_payment', 'paid', 'cancel_requested')
      and ((p_format = 'online' and b.centre_id is not null)
           or (p_format = 'in_person' and b.centre_id is null))) then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  if v_exam.status = 'published' and p_subject_id <> v_exam.subject_id and exists (
    select 1 from public.bookings b
    where b.exam_id = v_exam.id and b.status in ('awaiting_payment', 'paid', 'cancel_requested')) then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  if v_price <> v_exam.price_pence and exists (
    select 1 from public.bookings b
    where b.exam_id = v_exam.id
      and b.status in ('awaiting_payment', 'paid', 'cancel_requested', 'refunded', 'part_refunded')) then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;

  update public.exams set
    subject_id = p_subject_id, title = v_title, paper = v_paper, format = p_format,
    starts_at = p_starts_at, duration_minutes = p_duration_minutes,
    price_pence = v_price,
    price_confirmed = price_confirmed or v_admin,
    booking_deadline = p_booking_deadline
  where id = v_exam.id;

  -- Remove (archive), update in place, then add. The (exam, venue, room) key is checked once all are written.
  set constraints public.exam_centres_exam_venue_room_excl deferred;
  update public.exam_centres ec set removed_at = now()
  where ec.exam_id = v_exam.id and ec.removed_at is null and ec.id <> all (v_keep);
  update public.exam_centres ec
  set venue_id = t.v, room = t.r, seat_limit = t.l
  from unnest(v_ids, v_venues, v_rooms, v_limits) as t(i, v, r, l)
  where ec.id = t.i;
  insert into public.exam_centres (exam_id, venue_id, room, seat_limit)
  select v_exam.id, t.v, t.r, t.l
  from unnest(v_ids, v_venues, v_rooms, v_limits) as t(i, v, r, l)
  where t.i is null;
  set constraints public.exam_centres_exam_venue_room_excl immediate;

  if v_exam.status = 'published' then
    insert into public.audit_log (actor_id, action, target_type, target_id)
    values (v_actor, 'exam_updated', 'exam', v_exam.id);
  end if;
  return jsonb_build_object('ok', true, 'id', v_exam.id);
end;
$$;
revoke execute on function public.save_exam(uuid, bigint, text, text, public.exam_format, jsonb, timestamptz, int, int, timestamptz) from public, anon;
grant execute on function public.save_exam(uuid, bigint, text, text, public.exam_format, jsonb, timestamptz, int, int, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- set_exam_status: publishing checks every centre (replaces 20261110000035; grants kept).
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
    -- An exam offering the centre needs at least one current centre, each at an active venue with its room.
    if v_exam.format <> 'online' and (
      not exists (select 1 from public.exam_centres ec where ec.exam_id = v_exam.id and ec.removed_at is null)
      or exists (
        select 1 from public.exam_centres ec
        where ec.exam_id = v_exam.id and ec.removed_at is null
          and not exists (
            select 1 from public.venues v
            where v.id = ec.venue_id and v.active and ec.room = any (v.rooms)))) then
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

-- ---------------------------------------------------------------------------------------------
-- save_venue: upcoming exam centres keep an active venue and their room (replaces 20261110000033).
-- ---------------------------------------------------------------------------------------------
create or replace function public.save_venue(p_id uuid, p_name text, p_rooms text[], p_active boolean)
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
     or (select count(distinct lower(r)) from unnest(v_rooms) r) <> cardinality(v_rooms) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  begin
    if p_id is null then
      insert into public.venues (name, rooms, active) values (v_name, v_rooms, p_active)
      returning id into v_id;
      insert into public.audit_log (actor_id, action, target_type, target_id)
      values (v_actor, 'venue_created', 'venue', v_id);
    else
      select v.id into v_id from public.venues v where v.id = p_id for update;
      if v_id is null then
        return jsonb_build_object('ok', false, 'code', 'not_found');
      end if;
      -- Centres of upcoming live exams must keep an active venue and a room that still exists.
      if exists (
        select 1 from public.exam_centres ec
        join public.exams e on e.id = ec.exam_id
        where ec.venue_id = p_id and ec.removed_at is null and e.status <> 'cancelled' and e.starts_at > now()
          and (not p_active or not (ec.room = any (v_rooms)))
      ) then
        return jsonb_build_object('ok', false, 'code', 'conflict');
      end if;
      update public.venues set name = v_name, rooms = v_rooms, active = p_active where id = p_id;
      insert into public.audit_log (actor_id, action, target_type, target_id)
      values (v_actor, 'venue_updated', 'venue', v_id);
    end if;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Public timetable: each current centre with its seats left (by venue name, rooms not shown). Owned by postgres
-- (bypasses RLS by design), published exams only, no personal data. Seats are counted inline because the
-- calling role (anon) cannot execute centre_seats_taken.
-- ---------------------------------------------------------------------------------------------
create view public.exams_public with (security_barrier = true) as
select
  e.id,
  s.name as subject,
  e.title,
  e.paper,
  e.format,
  e.starts_at,
  e.duration_minutes,
  e.price_pence,
  e.booking_deadline,
  case when e.format = 'online' then null else coalesce(c.seats_left, 0) end as seats_left,
  coalesce(c.centres, '[]'::jsonb) as centres
from public.exams e
join public.subjects s on s.id = e.subject_id
left join lateral (
  select
    sum(x.seats_left)::int as seats_left,
    jsonb_agg(jsonb_build_object('id', x.id, 'venue', x.venue, 'seats_left', x.seats_left)
      order by x.venue, x.created_at, x.id) as centres
  from (
    select ec.id, v.name as venue, ec.created_at,
      greatest(ec.seat_limit - (
        select count(*)::int from public.bookings b
        where b.centre_id = ec.id and b.status in ('awaiting_payment', 'paid', 'cancel_requested')), 0) as seats_left
    from public.exam_centres ec
    join public.venues v on v.id = ec.venue_id
    where ec.exam_id = e.id and ec.removed_at is null
  ) x
) c on true
where e.status = 'published';

revoke all on public.exams_public from public, anon, authenticated;
grant select on public.exams_public to anon, authenticated;
