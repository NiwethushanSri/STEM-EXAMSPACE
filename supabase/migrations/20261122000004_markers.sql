-- Phase 3A Task 3: who may mark which subject, the lead marker of each subject, and declared conflicts.
--
-- Admins (and the owner) approve a corrector or a teacher to mark a subject (a teacher only for a subject they teach),
-- take the approval away, name the subject's one lead marker, and record a candidate a marker must never mark
-- (a relative, say). Every change asks for a reason (3 to 300 characters) and writes an audit row with it, in the same
-- transaction; the audit row names the subject or the candidate's index number after the reason.
--
-- Taking an approval away, or declaring a conflict, ends the marker's open assignments for it (end_reason 'unapproved'
-- or 'conflict'); a unit of the live pass that was taken goes back to open. The marker's in-progress live marking on a released
-- unit is set aside (set_aside_reason 'unapproved' or 'conflict', as Task 2 does), so "Next script" cannot hand it back
-- and another marker can take the unit; submitted markings stay.
--
-- Lock order (Ruling R9): approving, taking an approval away and declaring a conflict hold the marker's advisory lock
-- ('marker:' || id) exclusively (every hand-out to that marker holds it shared, 20261122000006); taking an approval
-- away and declaring a conflict then hold the rows of the scripts concerned, then their units, in id order, before the
-- assignments and markings change.
--
-- No earlier function is changed.

-- ---------------------------------------------------------------------------------------------
-- Internal: the reason with what it concerns after it, for the audit row.
-- ---------------------------------------------------------------------------------------------
create function public.marker_audit_reason(p_reason text, p_detail text)
returns text
language sql
immutable
set search_path = ''
as $$
  select p_reason || ' (' || p_detail || ')'
$$;

-- ---------------------------------------------------------------------------------------------
-- markers_list: every active or suspended corrector and teacher, their approvals (with the lead flag), the subjects
-- a teacher teaches, and their declared conflicts; and every subject with its lead marker. Admins only.
-- ---------------------------------------------------------------------------------------------
create function public.markers_list()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  return jsonb_build_object(
    'ok', true,
    'subjects', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id, 'name', s.name,
        'lead_id', (select a.marker_id from public.marker_approvals a where a.subject_id = s.id and a.lead)) order by s.name, s.id)
      from public.subjects s), '[]'::jsonb),
    'markers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id,
        'name', coalesce(nullif(btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), ''), p.email::text),
        'role', p.role, 'status', p.status,
        'subjects', coalesce((select jsonb_agg(jsonb_build_object('id', a.subject_id, 'lead', a.lead) order by a.subject_id)
                              from public.marker_approvals a where a.marker_id = p.id), '[]'::jsonb),
        'teaches', coalesce((select jsonb_agg(t.subject_id order by t.subject_id)
                             from public.teacher_subjects t where t.teacher_id = p.id), '[]'::jsonb),
        'conflicts', coalesce((
          select jsonb_agg(jsonb_build_object(
            'student_id', c.student_id, 'index_number', d.index_number,
            'name', nullif(btrim(coalesce(sp.first_name, '') || ' ' || coalesce(sp.last_name, '')), ''), 'note', c.note)
            order by c.recorded_at, c.student_id)
          from public.marker_conflicts c
          join public.profiles sp on sp.id = c.student_id
          left join public.student_details d on d.profile_id = c.student_id
          where c.marker_id = p.id), '[]'::jsonb))
        order by p.first_name, p.last_name, p.id)
      from public.profiles p
      where p.role in ('corrector', 'teacher') and p.status in ('active', 'suspended')), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marker_approve: the account is active and a corrector, or a teacher who teaches the subject (else not_approved).
-- Approving twice changes nothing. Returns {ok}.
-- ---------------------------------------------------------------------------------------------
create function public.marker_approve(p_marker uuid, p_subject bigint, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_p public.profiles%rowtype;
  v_subject text;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_marker is null or p_subject is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  select s.name into v_subject from public.subjects s where s.id = p_subject;
  select * into v_p from public.profiles p where p.id = p_marker;
  if v_subject is null or not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_p.status <> 'active' or v_p.role not in ('corrector', 'teacher')
     or (v_p.role = 'teacher' and not exists (select 1 from public.teacher_subjects t where t.teacher_id = p_marker and t.subject_id = p_subject)) then
    return jsonb_build_object('ok', false, 'code', 'not_approved');
  end if;

  perform pg_advisory_xact_lock(hashtextextended('marker:' || p_marker::text, 0));
  insert into public.marker_approvals (marker_id, subject_id, approved_by, approved_at)
  values (p_marker, p_subject, v_actor, now())
  on conflict (marker_id, subject_id) do nothing;

  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marker_approved', 'marker', p_marker, public.marker_audit_reason(v_reason, 'subject: ' || v_subject));
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marker_unapprove: removes the approval (and the lead flag with it), ends the marker's open assignments on the
-- subject's exams ('unapproved'; a taken unit of the live pass goes back to open). Submitted markings stay.
-- Returns {ok, released}.
-- ---------------------------------------------------------------------------------------------
create function public.marker_unapprove(p_marker uuid, p_subject bigint, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_subject text;
  v_released int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_marker is null or p_subject is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  select s.name into v_subject from public.subjects s where s.id = p_subject;
  perform pg_advisory_xact_lock(hashtextextended('marker:' || p_marker::text, 0));
  if v_subject is null or not exists (select 1 from public.marker_approvals a where a.marker_id = p_marker and a.subject_id = p_subject) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  delete from public.marker_approvals a where a.marker_id = p_marker and a.subject_id = p_subject;

  -- Ruling R9: the rows of the scripts whose pieces the marker holds for the subject, then those pieces, in id order,
  -- before their assignments and markings change.
  perform 1 from public.scripts s
  where s.id in (select u.script_id from public.marking_assignments x
                 join public.marking_units u on u.id = x.unit_id
                 join public.exams e on e.id = u.exam_id
                 where x.marker_id = p_marker and x.ended_at is null and e.subject_id = p_subject)
  order by s.id
  for no key update;
  perform 1 from public.marking_units u
  where u.id in (select x.unit_id from public.marking_assignments x
                 join public.marking_units v on v.id = x.unit_id
                 join public.exams e on e.id = v.exam_id
                 where x.marker_id = p_marker and x.ended_at is null and e.subject_id = p_subject)
  order by u.id
  for update;

  with ended as (
    update public.marking_assignments x set ended_at = now(), end_reason = 'unapproved'
    from public.marking_units u
    join public.exams e on e.id = u.exam_id
    where x.unit_id = u.id and x.marker_id = p_marker and x.ended_at is null and e.subject_id = p_subject
    returning x.unit_id, x.kind
  ),
  reopened as (
    update public.marking_units u set state = 'open'
    from ended where u.id = ended.unit_id and ended.kind = 'live' and u.state = 'taken'
    returning u.id
  ),
  aside as (
    update public.markings m
    set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'unapproved'
    from ended where m.unit_id = ended.unit_id and ended.kind = 'live' and m.marker_id = p_marker and m.kind = 'live' and m.status = 'in_progress'
    returning m.id
  )
  select count(*)::int into v_released from ended;

  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marker_unapproved', 'marker', p_marker, public.marker_audit_reason(v_reason, 'subject: ' || v_subject));
  return jsonb_build_object('ok', true, 'released', v_released);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marker_set_lead: the subject's lead marker (p_marker null clears it). The marker must be approved for the subject.
-- The earlier lead loses the flag first, in the same transaction. Returns {ok}.
-- ---------------------------------------------------------------------------------------------
create function public.marker_set_lead(p_subject bigint, p_marker uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_subject text;
  v_earlier uuid;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_subject is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  select s.name into v_subject from public.subjects s where s.id = p_subject;
  if v_subject is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('marker_lead:' || p_subject::text, 0));
  if p_marker is not null then
    perform pg_advisory_xact_lock(hashtextextended('marker:' || p_marker::text, 0));
    if not public.is_marker_for(p_marker, p_subject) then
      return jsonb_build_object('ok', false, 'code', 'not_approved');
    end if;
  end if;

  select a.marker_id into v_earlier from public.marker_approvals a where a.subject_id = p_subject and a.lead;
  begin
    update public.marker_approvals a set lead = false where a.subject_id = p_subject and a.lead;
    if p_marker is not null then
      update public.marker_approvals a set lead = true where a.subject_id = p_subject and a.marker_id = p_marker;
      if not found then
        raise exception 'not_approved';
      end if;
    end if;
  exception when raise_exception then
    return jsonb_build_object('ok', false, 'code', 'not_approved');
  end;

  if coalesce(p_marker, v_earlier) is not null then
    insert into public.audit_log (actor_id, action, target_type, target_id, reason)
    values (v_actor, 'marker_lead_set', 'marker', coalesce(p_marker, v_earlier),
      public.marker_audit_reason(v_reason, case when p_marker is null then 'lead removed, subject: ' else 'subject: ' end || v_subject));
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marker_conflict_set: the marker must never mark this candidate. p_student is a student, p_marker a corrector or
-- teacher; the note is at most 300 characters. Ends the marker's open assignments on the candidate's scripts
-- ('conflict'). already_marked counts the marker's submitted markings on the candidate's scripts, for an admin to take
-- back (Task 5). Returns {ok, released, already_marked}.
-- ---------------------------------------------------------------------------------------------
create function public.marker_conflict_set(p_marker uuid, p_student uuid, p_note text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_index text;
  v_released int;
  v_marked int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_marker is null or p_student is null or char_length(coalesce(v_note, '')) > 300 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if not exists (select 1 from public.profiles p where p.id = p_marker and p.role in ('corrector', 'teacher')) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select d.index_number into v_index
  from public.profiles s left join public.student_details d on d.profile_id = s.id
  where s.id = p_student and s.role = 'student';
  if not found then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  perform pg_advisory_xact_lock(hashtextextended('marker:' || p_marker::text, 0));
  insert into public.marker_conflicts (marker_id, student_id, note, recorded_by, recorded_at)
  values (p_marker, p_student, v_note, v_actor, now())
  on conflict (marker_id, student_id) do update set note = excluded.note, recorded_by = excluded.recorded_by, recorded_at = excluded.recorded_at;

  -- Ruling R9: the rows of the candidate's scripts whose pieces the marker holds, then those pieces, in id order, before
  -- their assignments and markings change.
  perform 1 from public.scripts s
  where s.id in (select u.script_id from public.marking_assignments x
                 join public.marking_units u on u.id = x.unit_id
                 join public.scripts t on t.id = u.script_id
                 join public.bookings b on b.id = t.booking_id
                 where x.marker_id = p_marker and x.ended_at is null and b.student_id = p_student)
  order by s.id
  for no key update;
  perform 1 from public.marking_units u
  where u.id in (select x.unit_id from public.marking_assignments x
                 join public.marking_units v on v.id = x.unit_id
                 join public.scripts t on t.id = v.script_id
                 join public.bookings b on b.id = t.booking_id
                 where x.marker_id = p_marker and x.ended_at is null and b.student_id = p_student)
  order by u.id
  for update;

  with ended as (
    update public.marking_assignments x set ended_at = now(), end_reason = 'conflict'
    from public.marking_units u
    join public.scripts s on s.id = u.script_id
    join public.bookings b on b.id = s.booking_id
    where x.unit_id = u.id and x.marker_id = p_marker and x.ended_at is null and b.student_id = p_student
    returning x.unit_id, x.kind
  ),
  reopened as (
    update public.marking_units u set state = 'open'
    from ended where u.id = ended.unit_id and ended.kind = 'live' and u.state = 'taken'
    returning u.id
  ),
  aside as (
    update public.markings m
    set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'conflict'
    from ended where m.unit_id = ended.unit_id and ended.kind = 'live' and m.marker_id = p_marker and m.kind = 'live' and m.status = 'in_progress'
    returning m.id
  )
  select count(*)::int into v_released from ended;

  select count(distinct u.script_id)::int into v_marked
  from public.markings m
  join public.marking_units u on u.id = m.unit_id
  join public.scripts s on s.id = u.script_id
  join public.bookings b on b.id = s.booking_id
  where m.marker_id = p_marker and m.status = 'submitted' and b.student_id = p_student;

  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marker_conflict_set', 'marker', p_marker, public.marker_audit_reason(v_reason, 'candidate: ' || coalesce(v_index, 'no index number')));
  return jsonb_build_object('ok', true, 'released', v_released, 'already_marked', v_marked);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marker_conflict_remove: the conflict is taken off. Returns {ok}.
-- ---------------------------------------------------------------------------------------------
create function public.marker_conflict_remove(p_marker uuid, p_student uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_index text;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_marker is null or p_student is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('marker:' || p_marker::text, 0));
  if not exists (select 1 from public.marker_conflicts c where c.marker_id = p_marker and c.student_id = p_student) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select d.index_number into v_index from public.student_details d where d.profile_id = p_student;
  delete from public.marker_conflicts c where c.marker_id = p_marker and c.student_id = p_student;

  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marker_conflict_removed', 'marker', p_marker, public.marker_audit_reason(v_reason, 'candidate: ' || coalesce(v_index, 'no index number')));
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marker_conflict_candidates: students whose index number contains the search (spaces, hyphens and case ignored) or
-- whose name contains it, at most 20. Admins only. Returns {ok, candidates: [{id, index_number, name}]}.
-- ---------------------------------------------------------------------------------------------
create function public.marker_conflict_candidates(p_query text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_raw text := btrim(coalesce(p_query, ''));
  v_q text := regexp_replace(upper(coalesce(p_query, '')), '[^A-Z0-9]', '', 'g');
  v_like text := '%' || replace(replace(replace(lower(btrim(coalesce(p_query, ''))), '!', '!!'), '%', '!%'), '_', '!_') || '%';
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if char_length(v_q) < 2 or char_length(v_raw) > 40 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  return jsonb_build_object('ok', true, 'candidates', coalesce((
    select jsonb_agg(jsonb_build_object('id', t.id, 'index_number', t.index_number, 'name', t.name) order by t.index_number, t.id)
    from (
      select p.id, d.index_number, nullif(btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), '') as name
      from public.profiles p
      left join public.student_details d on d.profile_id = p.id
      where p.role = 'student' and p.status in ('active', 'suspended')
        and (replace(upper(coalesce(d.index_number, '')), '-', '') like '%' || v_q || '%'
             or lower(btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, ''))) like v_like escape '!')
      order by d.index_number, p.id
      limit 20
    ) t), '[]'::jsonb));
end;
$$;

revoke execute on function public.marker_audit_reason(text, text) from public, anon, authenticated;
revoke execute on function public.markers_list() from public, anon;
revoke execute on function public.marker_approve(uuid, bigint, text) from public, anon;
revoke execute on function public.marker_unapprove(uuid, bigint, text) from public, anon;
revoke execute on function public.marker_set_lead(bigint, uuid, text) from public, anon;
revoke execute on function public.marker_conflict_set(uuid, uuid, text, text) from public, anon;
revoke execute on function public.marker_conflict_remove(uuid, uuid, text) from public, anon;
revoke execute on function public.marker_conflict_candidates(text) from public, anon;
grant execute on function public.markers_list() to authenticated;
grant execute on function public.marker_approve(uuid, bigint, text) to authenticated;
grant execute on function public.marker_unapprove(uuid, bigint, text) to authenticated;
grant execute on function public.marker_set_lead(bigint, uuid, text) to authenticated;
grant execute on function public.marker_conflict_set(uuid, uuid, text, text) to authenticated;
grant execute on function public.marker_conflict_remove(uuid, uuid, text) to authenticated;
grant execute on function public.marker_conflict_candidates(text) to authenticated;
