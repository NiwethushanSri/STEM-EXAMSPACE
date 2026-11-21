-- Phase 2 Task 8: what happens to the paper scripts after the exam, at a centre.
--   collection_counts     extra answer sheets counted per present or late candidate (the printed copy is always one booklet)
--   collection_manifests  a printed list of the centre's candidates, their attendance and sheets, numbered M-<exam code>-<nn>
--   custody_events        who held the scripts, where, and when (collected, handed over, scanned, archived)
-- Staff who may keep the register may do all of this (attendance_can_manage). The tables are read and written only
-- through the functions below. Names appear in the manifest and the custody list (internal staff documents), never in
-- the audit log. Task 9 adds the foreign keys from scan_batches.manifest_id and custody_events.batch_id and the
-- scanned event.

create table public.collection_counts (
  booking_id uuid primary key references public.bookings (id) on delete cascade,
  exam_id uuid not null references public.exams (id) on delete cascade,
  extra_sheets int not null check (extra_sheets between 0 and 50),
  recorded_by uuid not null,
  recorded_at timestamptz not null default now()
);

create table public.collection_manifests (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.exams (id) on delete cascade,
  centre_id uuid not null references public.exam_centres (id),
  number text not null unique,
  created_by uuid not null,
  created_at timestamptz not null default now()
);
create index collection_manifests_exam_idx on public.collection_manifests (exam_id, centre_id);

create table public.custody_events (
  id uuid primary key default gen_random_uuid(),
  -- Events of one transaction share a timestamp: the sequence keeps them in the order they were recorded.
  seq bigint generated always as identity,
  exam_id uuid not null references public.exams (id) on delete cascade,
  centre_id uuid not null references public.exam_centres (id),
  manifest_id uuid references public.collection_manifests (id),
  batch_id uuid,
  step text not null check (step in ('collected', 'handed_over', 'scanned', 'archived')),
  from_staff uuid references public.profiles (id),
  to_staff uuid references public.profiles (id),
  location text not null check (char_length(location) between 1 and 120),
  note text check (char_length(note) <= 300),
  recorded_by uuid not null,
  at timestamptz not null default now()
);
create index custody_events_centre_idx on public.custody_events (exam_id, centre_id, at);

alter table public.collection_counts enable row level security;
alter table public.collection_manifests enable row level security;
alter table public.custody_events enable row level security;
revoke all on public.collection_counts, public.collection_manifests, public.custody_events from public, anon, authenticated;
grant select on public.collection_counts, public.collection_manifests, public.custody_events to service_role;
revoke all on sequence public.custody_events_seq_seq from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Extra sheets for one candidate. Only a candidate marked present or late has anything to collect.
-- ---------------------------------------------------------------------------------------------
create function public.collection_record(p_booking uuid, p_extra_sheets int)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_b public.bookings%rowtype;
  v_subject bigint;
  v_att public.attendance_status;
begin
  if v_actor is null or p_booking is null or p_extra_sheets is null or p_extra_sheets not between 0 and 50 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_b from public.bookings b where b.id = p_booking;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select e.subject_id into v_subject from public.exams e where e.id = v_b.exam_id;
  if not public.attendance_can_manage(v_actor, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select a.status into v_att from public.attendance a where a.exam_id = v_b.exam_id and a.student_id = v_b.student_id;
  if v_b.status not in ('paid', 'cancel_requested') or v_att is null or v_att not in ('present', 'late') then
    return jsonb_build_object('ok', false, 'code', 'not_present');
  end if;
  insert into public.collection_counts (booking_id, exam_id, extra_sheets, recorded_by, recorded_at)
  values (p_booking, v_b.exam_id, p_extra_sheets, v_actor, now())
  on conflict (booking_id) do update
    set extra_sheets = excluded.extra_sheets, recorded_by = excluded.recorded_by, recorded_at = excluded.recorded_at;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'collection_recorded', 'booking', p_booking);
  return jsonb_build_object('ok', true, 'extra_sheets', p_extra_sheets);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- A manifest of one centre. Each call makes a new number: M-<exam code>-<01..99>.
-- ---------------------------------------------------------------------------------------------
create function public.collection_manifest_create(p_exam uuid, p_centre uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_exam public.exams%rowtype;
  v_n int;
  v_number text;
  v_id uuid;
  v_rows jsonb;
begin
  if v_actor is null or p_exam is null or p_centre is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_exam from public.exams e where e.id = p_exam;
  if not found or not exists (select 1 from public.exam_centres c where c.id = p_centre and c.exam_id = p_exam) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not public.attendance_can_manage(v_actor, v_exam.subject_id) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('manifest:' || p_exam::text, 0));
  select count(*) + 1 into v_n from public.collection_manifests m where m.exam_id = p_exam;
  if v_n > 99 then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  v_number := 'M-' || coalesce(v_exam.exam_code, 'EXAM') || '-' || lpad(v_n::text, 2, '0');
  insert into public.collection_manifests (exam_id, centre_id, number, created_by)
  values (p_exam, p_centre, v_number, v_actor) returning id into v_id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'index_number', r.index_number, 'name', r.name, 'attendance', r.attendance, 'extra_sheets', r.extra_sheets)
      order by r.index_number), '[]'::jsonb)
  into v_rows
  from (
    select d.index_number, btrim(p.first_name || ' ' || p.last_name) as name,
           coalesce(a.status::text, 'not_marked') as attendance,
           case when a.status in ('present', 'late') then cc.extra_sheets end as extra_sheets
    from public.bookings b
    join public.profiles p on p.id = b.student_id
    left join public.student_details d on d.profile_id = b.student_id
    left join public.attendance a on a.exam_id = b.exam_id and a.student_id = b.student_id
    left join public.collection_counts cc on cc.booking_id = b.id
    where b.exam_id = p_exam and b.centre_id = p_centre and b.sitting = 'centre'
      and b.status in ('paid', 'cancel_requested')
  ) r;

  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'collection_manifest_created', 'collection_manifest', v_id);
  return jsonb_build_object('ok', true, 'manifest_id', v_id, 'number', v_number, 'rows', v_rows);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Custody: one row each time the scripts change hands or place.
-- ---------------------------------------------------------------------------------------------
create function public.custody_record(
  p_exam uuid, p_centre uuid, p_step text, p_from uuid, p_to uuid, p_location text, p_note text,
  p_manifest uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_subject bigint;
  v_loc text := btrim(p_location);
  v_note text := nullif(btrim(p_note), '');
  v_id uuid;
begin
  if v_actor is null or p_exam is null or p_centre is null
     or p_step is null or p_step not in ('collected', 'handed_over', 'scanned', 'archived')
     or v_loc is null or char_length(v_loc) not between 1 and 120
     or (v_note is not null and char_length(v_note) > 300)
     or (p_from is null and p_to is null and v_note is null) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select e.subject_id into v_subject from public.exams e
  where e.id = p_exam and exists (select 1 from public.exam_centres c where c.id = p_centre and c.exam_id = p_exam);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not public.attendance_can_manage(v_actor, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if exists (
    select 1 from unnest(array[p_from, p_to]) s(id)
    where s.id is not null and not exists (
      select 1 from public.profiles q
      where q.id = s.id and q.status = 'active' and q.role in ('owner', 'admin', 'teacher', 'tutor', 'corrector'))) then
    return jsonb_build_object('ok', false, 'code', 'invalid_staff');
  end if;
  if p_manifest is not null and not exists (
    select 1 from public.collection_manifests m where m.id = p_manifest and m.exam_id = p_exam and m.centre_id = p_centre) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  insert into public.custody_events (exam_id, centre_id, manifest_id, step, from_staff, to_staff, location, note, recorded_by)
  values (p_exam, p_centre, p_manifest, p_step, p_from, p_to, v_loc, v_note, v_actor)
  returning id into v_id;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'custody_recorded', 'custody_event', v_id);
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create function public.custody_list(p_exam uuid, p_centre uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_subject bigint;
begin
  if v_actor is null or p_exam is null or p_centre is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select e.subject_id into v_subject from public.exams e
  where e.id = p_exam and exists (select 1 from public.exam_centres c where c.id = p_centre and c.exam_id = p_exam);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not public.attendance_can_manage(v_actor, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  return jsonb_build_object('ok', true, 'events', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', ev.id, 'step', ev.step, 'at', ev.at, 'location', ev.location, 'note', ev.note,
      'manifest', m.number,
      'from_name', nullif(btrim(pf.first_name || ' ' || pf.last_name), ''),
      'to_name', nullif(btrim(pt.first_name || ' ' || pt.last_name), ''),
      'by_name', nullif(btrim(pb.first_name || ' ' || pb.last_name), '')) order by ev.at, ev.seq)
    from public.custody_events ev
    left join public.collection_manifests m on m.id = ev.manifest_id
    left join public.profiles pf on pf.id = ev.from_staff
    left join public.profiles pt on pt.id = ev.to_staff
    left join public.profiles pb on pb.id = ev.recorded_by
    where ev.exam_id = p_exam and ev.centre_id = p_centre), '[]'::jsonb));
end;
$$;

revoke execute on function public.collection_record(uuid, int) from public, anon;
revoke execute on function public.collection_manifest_create(uuid, uuid) from public, anon;
revoke execute on function public.custody_record(uuid, uuid, text, uuid, uuid, text, text, uuid) from public, anon;
revoke execute on function public.custody_list(uuid, uuid) from public, anon;
grant execute on function public.collection_record(uuid, int) to authenticated;
grant execute on function public.collection_manifest_create(uuid, uuid) to authenticated;
grant execute on function public.custody_record(uuid, uuid, text, uuid, uuid, text, text, uuid) to authenticated;
grant execute on function public.custody_list(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- What the register screens read (the tables are closed to everyone): the candidates of a centre who are present or
-- late with their counted sheets, and the active staff a handover can name. Both are for staff who may keep the register.
-- ---------------------------------------------------------------------------------------------
create function public.collection_list(p_exam uuid, p_centre uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_subject bigint;
begin
  if v_actor is null or p_exam is null or p_centre is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select e.subject_id into v_subject from public.exams e
  where e.id = p_exam and exists (select 1 from public.exam_centres c where c.id = p_centre and c.exam_id = p_exam);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not public.attendance_can_manage(v_actor, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
      'booking_id', b.id, 'index_number', d.index_number, 'name', btrim(p.first_name || ' ' || p.last_name),
      'attendance', a.status, 'extra_sheets', cc.extra_sheets) order by d.index_number, b.id)
    from public.bookings b
    join public.attendance a on a.exam_id = b.exam_id and a.student_id = b.student_id and a.status in ('present', 'late')
    join public.profiles p on p.id = b.student_id
    left join public.student_details d on d.profile_id = b.student_id
    left join public.collection_counts cc on cc.booking_id = b.id
    where b.exam_id = p_exam and b.centre_id = p_centre and b.sitting = 'centre'
      and b.status in ('paid', 'cancel_requested')), '[]'::jsonb));
end;
$$;

create function public.custody_staff(p_exam uuid, p_centre uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_subject bigint;
begin
  if v_actor is null or p_exam is null or p_centre is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select e.subject_id into v_subject from public.exams e
  where e.id = p_exam and exists (select 1 from public.exam_centres c where c.id = p_centre and c.exam_id = p_exam);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not public.attendance_can_manage(v_actor, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  return jsonb_build_object('ok', true, 'staff', coalesce((
    select jsonb_agg(jsonb_build_object('id', q.id, 'name', btrim(q.first_name || ' ' || q.last_name), 'role', q.role)
      order by q.first_name, q.last_name, q.id)
    from (select s.id, s.first_name, s.last_name, s.role from public.profiles s
          where s.status = 'active' and s.role in ('owner', 'admin', 'teacher', 'tutor', 'corrector')
          order by s.first_name, s.last_name, s.id limit 500) q), '[]'::jsonb));
end;
$$;

revoke execute on function public.collection_list(uuid, uuid) from public, anon;
revoke execute on function public.custody_staff(uuid, uuid) from public, anon;
grant execute on function public.collection_list(uuid, uuid) to authenticated;
grant execute on function public.custody_staff(uuid, uuid) to authenticated;
