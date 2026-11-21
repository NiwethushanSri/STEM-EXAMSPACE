-- Phase 2 Task 5: the home sitting screen.
--
-- Each exam can carry its own home rules and allowed materials (empty: the web shows the institution's default text).
-- A home booking's family sees where the sitting stands (before the start, sitting, upload open, late window,
-- closed) from the database clock, and a parent (or a student with no linked parent) acknowledges that the exam is
-- supervised and the rules followed. The first acknowledgement stands.
--
-- Times: start = exams.starts_at; finish = start + duration; uploads are on time until finish + 2 hours, late (flagged,
-- an admin decides) until finish + 24 hours, refused after that. p_now is honoured only for direct database sessions
-- (paper_clock); an API call always uses the database clock.

alter table public.exams
  add column home_rules text check (char_length(home_rules) <= 2000),
  add column allowed_materials text check (char_length(allowed_materials) <= 500);

create table public.sitting_acknowledgements (
  booking_id uuid primary key references public.bookings (id),
  acknowledged_by uuid not null references public.profiles (id),
  as_role text not null check (as_role in ('parent', 'student')),
  at timestamptz not null
);
alter table public.sitting_acknowledgements enable row level security;
revoke all on public.sitting_acknowledgements from anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- set_exam_home_rules: who may edit the exam (as in save_exam), audited. Empty text is stored as null.
-- ---------------------------------------------------------------------------------------------
create function public.set_exam_home_rules(p_exam uuid, p_rules text, p_materials text)
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
  v_rules text := nullif(btrim(coalesce(p_rules, '')), '');
  v_materials text := nullif(btrim(coalesce(p_materials, '')), '');
begin
  select a.role into v_role
  from public.profiles a where a.id = v_actor and a.status = 'active' for share;
  if v_role is null or v_role not in ('owner', 'admin', 'teacher') then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  v_admin := v_role in ('owner', 'admin');
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  select * into v_exam from public.exams e where e.id = p_exam for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when v_admin then 'not_found' else 'forbidden' end);
  end if;
  -- Teachers: draft exams in their own subjects only. Admins: not a cancelled or completed exam.
  if not v_admin then
    if v_exam.status <> 'draft' or not exists (
      select 1 from public.teacher_subjects ts where ts.teacher_id = v_actor and ts.subject_id = v_exam.subject_id) then
      return jsonb_build_object('ok', false, 'code', 'forbidden');
    end if;
  elsif v_exam.status in ('cancelled', 'completed') then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;

  if char_length(v_rules) > 2000 or char_length(v_materials) > 500 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  -- Every exam save calls this: nothing changed, nothing written and no audit row.
  if v_exam.home_rules is not distinct from v_rules and v_exam.allowed_materials is not distinct from v_materials then
    return jsonb_build_object('ok', true, 'id', v_exam.id);
  end if;

  update public.exams set home_rules = v_rules, allowed_materials = v_materials where id = v_exam.id;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'exam_home_rules_set', 'exam', v_exam.id);
  return jsonb_build_object('ok', true, 'id', v_exam.id);
end;
$$;
revoke execute on function public.set_exam_home_rules(uuid, text, text) from public, anon;
grant execute on function public.set_exam_home_rules(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Phase of a home sitting at p_now (internal).
-- ---------------------------------------------------------------------------------------------
create function public.sitting_phase(p_exam public.exams, p_now timestamptz)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_exam.status = 'cancelled' then 'closed'
    when p_now < p_exam.starts_at then 'before_start'
    when p_now < p_exam.starts_at + p_exam.duration_minutes * interval '1 minute' then 'sitting'
    when p_now < p_exam.starts_at + p_exam.duration_minutes * interval '1 minute' + interval '2 hours' then 'upload_open'
    when p_now < p_exam.starts_at + p_exam.duration_minutes * interval '1 minute' + interval '24 hours' then 'late_window'
    else 'closed'
  end
$$;
revoke execute on function public.sitting_phase(public.exams, timestamptz) from public, anon, authenticated;

-- Who may see or act on a home booking: the candidate, an active linked parent, and (to read) owner/admin.
-- Answers a failure code, or null with the booking and exam filled in by the caller.
create function public.sitting_access_code(p_actor uuid, p_booking public.bookings, p_acting boolean)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role public.app_role;
begin
  select a.role into v_role from public.profiles a where a.id = p_actor and a.status = 'active';
  if v_role is null then
    return 'forbidden';
  end if;
  if v_role in ('owner', 'admin') then
    return case when p_acting then 'forbidden' else null end;
  end if;
  if p_booking.student_id is null then
    return 'forbidden';
  end if;
  if v_role = 'student' and p_actor = p_booking.student_id then
    return null;
  end if;
  if v_role = 'parent' and exists (
    select 1 from public.parent_children pc where pc.parent_id = p_actor and pc.student_id = p_booking.student_id) then
    return null;
  end if;
  return 'forbidden';
end;
$$;
revoke execute on function public.sitting_access_code(uuid, public.bookings, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- booking_sitting_state: what the family sees on the sitting screen.
-- ---------------------------------------------------------------------------------------------
create function public.booking_sitting_state(p_booking uuid, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_b public.bookings%rowtype;
  v_e public.exams%rowtype;
  v_code text;
  v_finish timestamptz;
  v_ack jsonb;
  v_script jsonb;
  v_sub jsonb;
  v_role public.app_role;
  v_has_parent boolean;
begin
  if p_booking is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_b from public.bookings b where b.id = p_booking;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  v_code := public.sitting_access_code(v_actor, v_b, false);
  if v_code is not null then
    return jsonb_build_object('ok', false, 'code', v_code);
  end if;
  if v_b.sitting <> 'home' then
    return jsonb_build_object('ok', false, 'code', 'wrong_sitting');
  end if;
  if v_b.status not in ('paid', 'cancel_requested') then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  select * into v_e from public.exams e where e.id = v_b.exam_id;
  v_finish := v_e.starts_at + v_e.duration_minutes * interval '1 minute';
  select a.role into v_role from public.profiles a where a.id = v_actor;
  v_has_parent := exists (select 1 from public.parent_children pc where pc.student_id = v_b.student_id);

  select jsonb_build_object('as_role', a.as_role, 'at', a.at,
           'by_name', nullif(btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), ''))
  into v_ack
  from public.sitting_acknowledgements a
  left join public.profiles p on p.id = a.acknowledged_by
  where a.booking_id = v_b.id;

  select jsonb_build_object('number', s.number, 'state', s.state, 'late', s.late) into v_script
  from public.scripts s where s.booking_id = v_b.id;

  select jsonb_build_object('id', h.id, 'seq', h.seq, 'state', h.state, 'late', h.late) into v_sub
  from public.home_submissions h where h.booking_id = v_b.id order by h.seq desc limit 1;

  return jsonb_build_object(
    'ok', true,
    'phase', public.sitting_phase(v_e, v_now),
    'server_now', v_now,
    'starts_at', v_e.starts_at,
    'finish_at', v_finish,
    'on_time_until', v_finish + interval '2 hours',
    'late_until', v_finish + interval '24 hours',
    'rules', v_e.home_rules,
    'materials', v_e.allowed_materials,
    'acknowledged', v_ack,
    -- who may acknowledge for this caller: a parent; a student with no linked parent; nobody else (null)
    'ack_as', case when v_role = 'parent' then 'parent' when v_role = 'student' and not v_has_parent then 'student' end,
    'has_parent', v_has_parent,
    'script', v_script,
    'submission', v_sub);
end;
$$;
revoke execute on function public.booking_sitting_state(uuid, timestamptz) from public, anon;
grant execute on function public.booking_sitting_state(uuid, timestamptz) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- sitting_acknowledge: the family says the exam is sat under supervision and by the rules. A linked parent does it
-- as parent; a student does it as student only when no parent is linked. Before the finish only; the first
-- acknowledgement stands (a second call returns it unchanged).
-- ---------------------------------------------------------------------------------------------
create function public.sitting_acknowledge(p_booking uuid, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_b public.bookings%rowtype;
  v_e public.exams%rowtype;
  v_code text;
  v_role public.app_role;
  v_a public.sitting_acknowledgements%rowtype;
begin
  if p_booking is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_b from public.bookings b where b.id = p_booking for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  v_code := public.sitting_access_code(v_actor, v_b, true);
  if v_code is not null then
    return jsonb_build_object('ok', false, 'code', v_code);
  end if;
  if v_b.sitting <> 'home' then
    return jsonb_build_object('ok', false, 'code', 'wrong_sitting');
  end if;
  select a.role into v_role from public.profiles a where a.id = v_actor;
  -- A student with a linked parent leaves it to the parent.
  if v_role = 'student' and exists (select 1 from public.parent_children pc where pc.student_id = v_b.student_id) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;

  select * into v_a from public.sitting_acknowledgements a where a.booking_id = v_b.id;
  if not found then
    if v_b.status not in ('paid', 'cancel_requested') then
      return jsonb_build_object('ok', false, 'code', 'conflict');
    end if;
    select * into v_e from public.exams e where e.id = v_b.exam_id;
    if v_e.status = 'cancelled' or v_now >= v_e.starts_at + v_e.duration_minutes * interval '1 minute' then
      return jsonb_build_object('ok', false, 'code', 'conflict');
    end if;
    insert into public.sitting_acknowledgements (booking_id, acknowledged_by, as_role, at)
    values (v_b.id, v_actor, v_role::text, v_now)
    returning * into v_a;
  end if;
  return jsonb_build_object('ok', true, 'as_role', v_a.as_role, 'at', v_a.at);
end;
$$;
revoke execute on function public.sitting_acknowledge(uuid, timestamptz) from public, anon;
grant execute on function public.sitting_acknowledge(uuid, timestamptz) to authenticated, service_role;
