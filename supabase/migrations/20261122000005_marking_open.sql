-- Phase 3A Task 4: opening marking for an exam, when a verified script may be handed out, its marking units, and the
-- marking-tick job.
--
-- An admin sets how an exam is marked (whole scripts, or by question group) and its marking deadline, which must be
-- after the exam's finish. Once marking has opened the mode is fixed and a deadline change needs a reason. Opening
-- needs a question to mark, every top-level question in a group when marked by question, and an approved active marker
-- of the subject. Closing ends nothing and deletes nothing: it stops hand-out here (and saving and changes, Tasks 5 and
-- 6); reopening resumes. Every change writes an audit row, with its reason where it asks for one.
--
-- A verified script of an open exam becomes ready to mark, with its units (one for the whole script, or one per
-- question group), once nothing holds it back (marking_script_blocked): it was taken back from marking; it came in
-- late and nobody has accepted it; it is a home script and the hand-in time (finish + 24 hours) has not ended; it is
-- a centre script and a page with no code, or a code that could not be read, is still open in a scan file of its
-- centre; or a file holding one of its pages is being prepared or remasked. marking_exam_sync does this when marking
-- opens or reopens and every minute (marking_tick, pg_cron job marking-tick). A script moving past verified has its
-- extra pages written down (the Phase 2 trigger scripts_extras_lock) and its booking takes no family changes
-- (script_booking_locked).
--
-- A script withdrawn or void (its booking cancelled, refunded or expired, or voided by staff) puts its units on hold
-- ('withdrawn') and ends their open assignments ('withdrawn'). Its markings are kept.
--
-- Lock order, for every function that changes marking (Ruling R9; later tasks keep it): the exam's structure lock
-- (advisory, where taken: exam_structure_save, settings and opening), then the exam's exam_marking row (for update to
-- change it, for share to mark under it), then the bookings' advisory locks where taken (as Phase 2, in uuid order),
-- then the scripts' rows in id order (for no key update), then their units, assignments and markings. A booking
-- cancelled or a script voided takes its booking, then the script's row, then (through marking_on_script_state) its
-- units, in the same order. marking_script_state holds the script's row before it reads the units.
--
-- Changed: exam_structure_save, from its latest definition (20261122000003). A question added after opening (1) holds
-- the rows of the scripts whose pieces include it, in id order, before it reads their states and pieces, so it never
-- reopens a piece of a script withdrawn or voided meanwhile; pieces of withdrawn or void scripts are left out where
-- the reopened markings are read too (Ruling R9); and (2) sets the state of each script it reopens with
-- marking_script_state, instead of its own marked -> marking update (Ruling R1). Nothing else in it changed.

-- ---------------------------------------------------------------------------------------------
-- Internal: whether a file holding one of the script's pages (a page its current version shows, or one of its extra
-- pages) has a prepare or remask job queued or running.
-- ---------------------------------------------------------------------------------------------
create function public.marking_script_busy(p_script uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.processing_jobs j
    where j.kind in ('prepare', 'remask') and j.state in ('queued', 'running')
      and j.upload_id in (
        select p.upload_id from public.scripts s
        join public.script_page_links l on l.script_id = s.id and l.version = s.version
        join public.script_pages p on p.id = l.page_id
        where s.id = p_script
        union
        select p.upload_id from public.script_extra_pages(p_script) x
        join public.script_pages p on p.id = x.page_id))
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: what holds the script itself back, whatever the exam's marking (null: nothing). The first of taken_back,
-- late_undecided, home_window_open, centre_pages_unsettled, pictures_updating.
-- ---------------------------------------------------------------------------------------------
create function public.marking_script_waiting(p_script uuid, p_now timestamptz)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := public.paper_clock(p_now);
  v_x public.scripts%rowtype;
  v_e public.exams%rowtype;
begin
  select * into v_x from public.scripts s where s.id = p_script;
  if not found then
    return null;
  end if;
  if v_x.taken_back_at is not null then
    return 'taken_back';
  end if;
  if v_x.late and v_x.late_decision is distinct from 'accept' then
    return 'late_undecided';
  end if;
  if v_x.source = 'home' then
    select * into v_e from public.exams e where e.id = v_x.exam_id;
    if v_now < v_e.starts_at + v_e.duration_minutes * interval '1 minute' + interval '24 hours' then
      return 'home_window_open';
    end if;
  end if;
  if v_x.source = 'centre' and exists (
       select 1 from public.bookings b
       join public.scan_batches sb on sb.exam_id = v_x.exam_id and sb.centre_id = b.centre_id
       join public.script_uploads u on u.batch_id = sb.id
       join public.script_exceptions x on x.upload_id = u.id
       where b.id = v_x.booking_id and x.kind in ('no_code', 'unknown_code') and x.state = 'open') then
    return 'centre_pages_unsettled';
  end if;
  if public.marking_script_busy(p_script) then
    return 'pictures_updating';
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: why the script's units may not be handed out at p_now (null: they may). The first of not_verified (not
-- verified, ready to mark or being marked), marking_not_open, marking_closed, then what holds the script itself back
-- (marking_script_waiting).
-- ---------------------------------------------------------------------------------------------
create function public.marking_script_blocked(p_script uuid, p_now timestamptz)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_x public.scripts%rowtype;
  v_m public.exam_marking%rowtype;
begin
  select * into v_x from public.scripts s where s.id = p_script;
  if not found or v_x.state not in ('verified', 'ready_to_mark', 'marking') then
    return 'not_verified';
  end if;
  select * into v_m from public.exam_marking m where m.exam_id = v_x.exam_id;
  if v_m.opened_at is null then
    return 'marking_not_open';
  end if;
  if v_m.closed_at is not null then
    return 'marking_closed';
  end if;
  return public.marking_script_waiting(p_script, p_now);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: a script being marked takes its state from its units: marked when every unit is submitted; being marked
-- when a unit is taken or submitted or has a marking; else ready to mark. Scripts in other states are left as they
-- are. The script's row is held first, so two units submitted at the same moment end with the script marked.
-- ---------------------------------------------------------------------------------------------
create function public.marking_script_state(p_script uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_state public.script_state;
  v_new public.script_state;
begin
  select s.state into v_state from public.scripts s where s.id = p_script for no key update;
  if not found or v_state not in ('ready_to_mark', 'marking', 'marked') then
    return;
  end if;
  select case
      when count(*) > 0 and bool_and(u.state = 'submitted') then 'marked'
      when bool_or(u.state in ('taken', 'submitted') or exists (select 1 from public.markings m where m.unit_id = u.id)) then 'marking'
      else 'ready_to_mark'
    end::public.script_state
  into v_new
  from public.marking_units u where u.script_id = p_script;
  if v_new <> v_state then
    update public.scripts set state = v_new where id = p_script;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: every verified script of the exam that may be handed out at p_now becomes ready to mark, and gets its
-- units when it has none (one for the whole script, or one per question group). Returns how many it made ready.
-- Holds the exam's marking row for share, so it waits for a close (or a structure save) in progress.
-- ---------------------------------------------------------------------------------------------
create function public.marking_exam_sync(p_exam uuid, p_now timestamptz)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := public.paper_clock(p_now);
  v_m public.exam_marking%rowtype;
  v_n int := 0;
  r record;
begin
  select * into v_m from public.exam_marking m where m.exam_id = p_exam for share;
  if v_m.opened_at is null or v_m.closed_at is not null then
    return 0;
  end if;
  for r in
    select s.id, s.booking_id from public.scripts s
    where s.exam_id = p_exam and s.state = 'verified' and public.marking_script_blocked(s.id, v_now) is null
    order by s.booking_id
  loop
    -- Looked at again under the booking's lock and the script's row, as Phase 2 changes scripts.
    perform public.script_bookings_lock(array[r.booking_id]);
    perform 1 from public.scripts s where s.id = r.id and s.state = 'verified' for no key update;
    if not found or public.marking_script_blocked(r.id, v_now) is not null then
      continue;
    end if;
    update public.scripts set state = 'ready_to_mark' where id = r.id;
    if not exists (select 1 from public.marking_units u where u.script_id = r.id) then
      if v_m.mode = 'whole' then
        insert into public.marking_units (script_id, exam_id) values (r.id, p_exam);
      else
        insert into public.marking_units (script_id, exam_id, group_id)
        select r.id, p_exam, g.id from public.question_groups g where g.exam_id = p_exam order by g.position;
      end if;
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the minute job. Every exam whose marking is open and not closed is synced (Task 5 adds hold expiry).
-- ---------------------------------------------------------------------------------------------
create function public.marking_tick()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  for r in select m.exam_id from public.exam_marking m where m.opened_at is not null and m.closed_at is null order by m.exam_id loop
    perform public.marking_exam_sync(r.exam_id, null);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- A script withdrawn or void: its units go on hold ('withdrawn') and their open assignments end ('withdrawn'). The
-- markings are kept.
-- ---------------------------------------------------------------------------------------------
create function public.marking_on_script_state()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.marking_units u set on_hold = true, hold_reason = 'withdrawn' where u.script_id = new.id;
  update public.marking_assignments a set ended_at = now(), end_reason = 'withdrawn'
  where a.ended_at is null and a.unit_id in (select u.id from public.marking_units u where u.script_id = new.id);
  return null;
end;
$$;

create trigger marking_on_script_state after update of state on public.scripts
  for each row
  when (new.state in ('withdrawn', 'void') and old.state is distinct from new.state)
  execute function public.marking_on_script_state();

-- ---------------------------------------------------------------------------------------------
-- marking_settings_set: how the exam is marked and its marking deadline (null: none), which must be after the exam's
-- finish. Once marking has opened the mode cannot change (conflict) and a deadline change needs a reason. Saving the
-- same settings changes nothing and writes no audit row. Admins only. Returns {ok, mode, deadline}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_settings_set(p_exam uuid, p_mode public.marking_mode, p_deadline timestamptz, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_e public.exams%rowtype;
  v_m public.exam_marking%rowtype;
  v_mode public.marking_mode;
  v_london constant text := 'YYYY-MM-DD HH24:MI';
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null or p_mode is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_e from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if p_deadline is not null and p_deadline <= v_e.starts_at + v_e.duration_minutes * interval '1 minute' then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  perform pg_advisory_xact_lock(hashtextextended('exam_structure:' || p_exam::text, 0));
  select * into v_m from public.exam_marking m where m.exam_id = p_exam for update;
  v_mode := coalesce(v_m.mode, 'whole');
  if v_m.opened_at is not null then
    if p_mode <> v_mode then
      return jsonb_build_object('ok', false, 'code', 'conflict');
    end if;
    if p_deadline is distinct from v_m.deadline and v_reason is null then
      return jsonb_build_object('ok', false, 'code', 'reason_required');
    end if;
  end if;

  if v_m.exam_id is null or p_mode <> v_mode or p_deadline is distinct from v_m.deadline then
    insert into public.exam_marking as m (exam_id, mode, deadline, updated_at)
    values (p_exam, p_mode, p_deadline, now())
    on conflict (exam_id) do update set mode = excluded.mode, deadline = excluded.deadline, updated_at = now();
    insert into public.audit_log (actor_id, action, target_type, target_id, reason)
    values (v_actor, 'marking_settings_set', 'exam', p_exam,
      'mode ' || v_mode || ' -> ' || p_mode
      || '; deadline ' || coalesce(to_char(v_m.deadline at time zone 'Europe/London', v_london), 'none')
      || ' -> ' || coalesce(to_char(p_deadline at time zone 'Europe/London', v_london), 'none') || ' (UK time)'
      || coalesce('; reason: ' || v_reason, ''));
  end if;
  return jsonb_build_object('ok', true, 'mode', p_mode, 'deadline', p_deadline);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_exam_get: the exam's marking settings and what opening (and handing out) waits for. Admins only.
-- {ok, mode, deadline, opened_at, closed_at, structure:{version, leaves, max_total, ungrouped}, markers (approved
-- active markers of the subject), scripts:{verified, ready_to_mark, marking, marked}, waiting:{home_window_open,
-- centre_pages_unsettled, pictures_updating, late_undecided, taken_back}}. waiting counts the scripts that are
-- verified, ready to mark or being marked by the first thing holding each back (marking_script_waiting at p_now).
-- ---------------------------------------------------------------------------------------------
create function public.marking_exam_get(p_exam uuid, p_now timestamptz default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := public.paper_clock(p_now);
  v_e public.exams%rowtype;
  v_m public.exam_marking%rowtype;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_e from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into v_m from public.exam_marking m where m.exam_id = p_exam;

  return jsonb_build_object(
    'ok', true,
    'mode', coalesce(v_m.mode, 'whole'),
    'deadline', v_m.deadline,
    'opened_at', v_m.opened_at,
    'closed_at', v_m.closed_at,
    'structure', jsonb_build_object(
      'version', coalesce(v_m.structure_version, 0),
      'leaves', (select count(*)::int from public.exam_questions q
                 where q.exam_id = p_exam and not exists (select 1 from public.exam_questions c where c.parent_id = q.id)),
      'max_total', public.exam_structure_max_total(p_exam),
      'ungrouped', (select count(*)::int from public.exam_questions q where q.exam_id = p_exam and q.parent_id is null and q.group_id is null)),
    'markers', (select count(*)::int from public.marker_approvals a
                where a.subject_id = v_e.subject_id and public.is_marker_for(a.marker_id, a.subject_id)),
    'scripts', (select jsonb_build_object(
                  'verified', count(*) filter (where s.state = 'verified'),
                  'ready_to_mark', count(*) filter (where s.state = 'ready_to_mark'),
                  'marking', count(*) filter (where s.state = 'marking'),
                  'marked', count(*) filter (where s.state = 'marked'))
                from public.scripts s where s.exam_id = p_exam),
    'waiting', (select jsonb_build_object(
                  'home_window_open', count(*) filter (where t.why = 'home_window_open'),
                  'centre_pages_unsettled', count(*) filter (where t.why = 'centre_pages_unsettled'),
                  'pictures_updating', count(*) filter (where t.why = 'pictures_updating'),
                  'late_undecided', count(*) filter (where t.why = 'late_undecided'),
                  'taken_back', count(*) filter (where t.why = 'taken_back'))
                from (select public.marking_script_waiting(s.id, v_now) as why from public.scripts s
                      where s.exam_id = p_exam and s.state in ('verified', 'ready_to_mark', 'marking')) t));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_open: needs a question to mark and, marked by question, every top-level question in a group
-- (structure_incomplete), and an approved active marker of the subject (no_markers). Sets opened_at and opened_by,
-- then makes the verified scripts ready (marking_exam_sync). Admins only. Returns {ok, already: false, ready}, or
-- {ok, already: true} when marking had opened before.
-- ---------------------------------------------------------------------------------------------
create function public.marking_open(p_exam uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_e public.exams%rowtype;
  v_m public.exam_marking%rowtype;
  v_ready int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_e from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  -- The structure lock, as exam_structure_save takes it: the questions checked here are the ones marking opens with.
  perform pg_advisory_xact_lock(hashtextextended('exam_structure:' || p_exam::text, 0));
  select * into v_m from public.exam_marking m where m.exam_id = p_exam for update;
  if v_m.opened_at is not null then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  if not exists (select 1 from public.exam_questions q
                 where q.exam_id = p_exam and not exists (select 1 from public.exam_questions c where c.parent_id = q.id))
     or (coalesce(v_m.mode, 'whole') = 'by_question'
         and exists (select 1 from public.exam_questions q where q.exam_id = p_exam and q.parent_id is null and q.group_id is null)) then
    return jsonb_build_object('ok', false, 'code', 'structure_incomplete');
  end if;
  if not exists (select 1 from public.marker_approvals a
                 where a.subject_id = v_e.subject_id and public.is_marker_for(a.marker_id, a.subject_id)) then
    return jsonb_build_object('ok', false, 'code', 'no_markers');
  end if;

  insert into public.exam_marking as m (exam_id, opened_at, opened_by, updated_at)
  values (p_exam, now(), v_actor, now())
  on conflict (exam_id) do update set opened_at = excluded.opened_at, opened_by = excluded.opened_by, updated_at = now();
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'marking_opened', 'exam', p_exam);
  v_ready := public.marking_exam_sync(p_exam, null);
  return jsonb_build_object('ok', true, 'already', false, 'ready', v_ready);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_close: with a reason. Ends nothing and deletes nothing; nothing more is handed out. Admins only.
-- Returns {ok, already}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_close(p_exam uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_m public.exam_marking%rowtype;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if not exists (select 1 from public.exams e where e.id = p_exam) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into v_m from public.exam_marking m where m.exam_id = p_exam for update;
  if v_m.opened_at is null then
    return jsonb_build_object('ok', false, 'code', 'marking_not_open');
  end if;
  if v_m.closed_at is not null then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  update public.exam_marking set closed_at = now(), closed_by = v_actor, updated_at = now() where exam_id = p_exam;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_closed', 'exam', p_exam, v_reason);
  return jsonb_build_object('ok', true, 'already', false);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_reopen: with a reason. Hand-out resumes and the verified scripts are made ready (marking_exam_sync).
-- Admins only. Returns {ok, already: false, ready}, or {ok, already: true} when marking was not closed.
-- ---------------------------------------------------------------------------------------------
create function public.marking_reopen(p_exam uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_m public.exam_marking%rowtype;
  v_ready int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if not exists (select 1 from public.exams e where e.id = p_exam) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into v_m from public.exam_marking m where m.exam_id = p_exam for update;
  if v_m.opened_at is null then
    return jsonb_build_object('ok', false, 'code', 'marking_not_open');
  end if;
  if v_m.closed_at is null then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  update public.exam_marking set closed_at = null, closed_by = null, updated_at = now() where exam_id = p_exam;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_reopened', 'exam', p_exam, v_reason);
  v_ready := public.marking_exam_sync(p_exam, null);
  return jsonb_build_object('ok', true, 'already', false, 'ready', v_ready);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- exam_structure_save: as 20261122000003, except that a question added after opening holds the rows of the scripts
-- concerned before it reads them (Ruling R9) and sets each reopened script's state with marking_script_state (Ruling R1)
-- instead of updating marked scripts to marking itself.
-- ---------------------------------------------------------------------------------------------
create or replace function public.exam_structure_save(p_exam uuid, p_structure jsonb, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_e public.exams%rowtype;
  v_m public.exam_marking%rowtype;
  v_locked boolean;
  v_reason text := public.script_resolution_reason(p_reason);
  v_groups jsonb;
  v_options jsonb;
  v_qs jsonb;
  v_ids jsonb := '{}';
  v_gids jsonb;
  v_oids jsonb;
  v_added uuid[] := '{}';
  v_units uuid[];
  v_held uuid[];
  v_scripts uuid[];
  v_version int;
  v_opened timestamptz;
  v_id uuid;
  r record;
begin
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_e from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not public.structure_can_edit(v_actor, p_exam) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;

  -- One save of an exam's structure at a time. The exam's marking row (when there is one) is held from here, before
  -- the lock rules and the maximum check: a mark saved at the same moment (marking saves hold it for share), a submit
  -- and marking opening wait until this save ends.
  perform pg_advisory_xact_lock(hashtextextended('exam_structure:' || p_exam::text, 0));
  select * into v_m from public.exam_marking m where m.exam_id = p_exam for update;
  v_locked := v_m.opened_at is not null;
  if v_locked then
    if not exists (select 1 from public.profiles a where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin')) then
      return jsonb_build_object('ok', false, 'code', 'forbidden');
    end if;
    if v_reason is null then
      return jsonb_build_object('ok', false, 'code', 'reason_required');
    end if;
  end if;

  if not public.exam_structure_valid(p_structure, public.exam_structure_pages(p_exam)) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  v_groups := coalesce(p_structure -> 'groups', '[]');
  v_options := coalesce(p_structure -> 'option_groups', '[]');
  v_qs := p_structure -> 'questions';
  -- A question sent with an id must be one of this exam's.
  if exists (select 1 from jsonb_array_elements(v_qs) e
             where e ->> 'id' is not null
               and not exists (select 1 from public.exam_questions x where x.id = (e ->> 'id')::uuid and x.exam_id = p_exam)) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  if v_locked then
    -- Only the changes of Builder's call 11.
    if exists (
         with q as (
           select (e ->> 'id')::uuid as id, e ->> 'key' as key, e ->> 'parent_key' as parent_key,
             (e ->> 'mark_step')::numeric as mark_step, (e ->> 'levels')::boolean as levels,
             e ->> 'group_key' as group_key, e ->> 'option_group_key' as option_group_key
           from jsonb_array_elements(v_qs) e
         )
         -- a question removed
         select 1 from public.exam_questions x where x.exam_id = p_exam and not exists (select 1 from q where q.id = x.id)
         union all
         -- a question moved, given parts or a different step or levels; a question changing group or optional rule
         select 1 from q join public.exam_questions x on x.id = q.id
         where x.parent_id is distinct from (select p.id from q p where p.key = q.parent_key)
            or (x.max_mark is null) <> exists (select 1 from q c where c.parent_key = q.key)
            or x.mark_step <> q.mark_step or x.levels <> q.levels
            or (select g.label from public.question_groups g where g.id = x.group_id)
               is distinct from (select btrim(g ->> 'label') from jsonb_array_elements(v_groups) g where g ->> 'key' = q.group_key)
            or (select o.label from public.exam_option_groups o where o.id = x.option_group_id)
               is distinct from (select btrim(o ->> 'label') from jsonb_array_elements(v_options) o where o ->> 'key' = q.option_group_key)
         union all
         -- a new question made optional, or (marked by question) a new question without a group
         select 1 from q where q.id is null
           and (q.option_group_key is not null or (v_m.mode = 'by_question' and q.parent_key is null and q.group_key is null))
         union all
         -- the groups or the optional questions changed
         select 1 where (select array_agg(g.label order by g.label) from public.question_groups g where g.exam_id = p_exam)
                        is distinct from (select array_agg(btrim(g ->> 'label') order by btrim(g ->> 'label')) from jsonb_array_elements(v_groups) g)
         union all
         select 1 where (select array_agg(o.label || '|' || o.choose order by o.label || '|' || o.choose) from public.exam_option_groups o where o.exam_id = p_exam)
                        is distinct from (select array_agg(btrim(o ->> 'label') || '|' || (o ->> 'choose') order by btrim(o ->> 'label') || '|' || (o ->> 'choose'))
                                          from jsonb_array_elements(v_options) o)) then
      return jsonb_build_object('ok', false, 'code', 'structure_locked');
    end if;
    -- A maximum cannot go below a mark already given.
    if exists (
         select 1 from jsonb_array_elements(v_qs) e
         join public.question_marks m on m.question_id = (e ->> 'id')::uuid
         where e ->> 'id' is not null and m.mark > (e ->> 'max_mark')::numeric) then
      return jsonb_build_object('ok', false, 'code', 'conflict');
    end if;
  end if;

  -- The new version, which also holds the exam's marking row until this save ends. Should marking have opened since
  -- the structure was read as unlocked, nothing is saved.
  insert into public.exam_marking as m (exam_id, structure_version, updated_at)
  values (p_exam, 1, now())
  on conflict (exam_id) do update set structure_version = m.structure_version + 1, updated_at = now()
  returning m.structure_version, m.opened_at into v_version, v_opened;
  if v_opened is not null and not v_locked then
    raise exception 'marking opened while the structure was being saved' using errcode = '40001';
  end if;

  -- Groups and optional questions, matched by label: kept, added, or (before opening) deleted.
  update public.exam_questions set group_id = null, option_group_id = null, parent_id = null where exam_id = p_exam;
  delete from public.question_groups g
  where g.exam_id = p_exam and g.label not in (select btrim(x ->> 'label') from jsonb_array_elements(v_groups) x);
  update public.question_groups g set position = x.n
  from jsonb_array_elements(v_groups) with ordinality x(j, n)
  where g.exam_id = p_exam and g.label = btrim(x.j ->> 'label');
  insert into public.question_groups (exam_id, label, position)
  select p_exam, btrim(x.j ->> 'label'), x.n from jsonb_array_elements(v_groups) with ordinality x(j, n)
  where not exists (select 1 from public.question_groups g where g.exam_id = p_exam and g.label = btrim(x.j ->> 'label'));
  select coalesce(jsonb_object_agg(x ->> 'key', g.id), '{}') into v_gids
  from jsonb_array_elements(v_groups) x join public.question_groups g on g.exam_id = p_exam and g.label = btrim(x ->> 'label');

  delete from public.exam_option_groups o
  where o.exam_id = p_exam and o.label not in (select btrim(x ->> 'label') from jsonb_array_elements(v_options) x);
  update public.exam_option_groups o set choose = (x ->> 'choose')::int
  from jsonb_array_elements(v_options) x
  where o.exam_id = p_exam and o.label = btrim(x ->> 'label');
  insert into public.exam_option_groups (exam_id, label, choose)
  select p_exam, btrim(x ->> 'label'), (x ->> 'choose')::int from jsonb_array_elements(v_options) x
  where not exists (select 1 from public.exam_option_groups o where o.exam_id = p_exam and o.label = btrim(x ->> 'label'));
  select coalesce(jsonb_object_agg(x ->> 'key', o.id), '{}') into v_oids
  from jsonb_array_elements(v_options) x join public.exam_option_groups o on o.exam_id = p_exam and o.label = btrim(x ->> 'label');

  -- Questions: those not sent are deleted (never once marking has opened: refused above), the others kept or added,
  -- parents first; their marking points are replaced.
  delete from public.exam_questions x
  where x.exam_id = p_exam
    and x.id not in (select (e ->> 'id')::uuid from jsonb_array_elements(v_qs) e where e ->> 'id' is not null);
  delete from public.mark_scheme_points p using public.exam_questions x where x.id = p.question_id and x.exam_id = p_exam;
  for r in
    with recursive q as (
      select e, o, e ->> 'key' as key, e ->> 'parent_key' as parent_key from jsonb_array_elements(v_qs) with ordinality t(e, o)
    ),
    tree as (
      select q.key, 1 as depth from q where q.parent_key is null
      union all
      select c.key, t.depth + 1 from q c join tree t on c.parent_key = t.key
    )
    select q.e, q.key, q.parent_key, tree.depth,
      row_number() over (partition by q.parent_key order by q.o) as position,
      exists (select 1 from q c where c.parent_key = q.key) as has_parts
    from q join tree on tree.key = q.key
    order by tree.depth, q.o
  loop
    if r.e ->> 'id' is null then
      insert into public.exam_questions (exam_id, label, position) values (p_exam, btrim(r.e ->> 'label'), r.position)
      returning id into v_id;
      if not r.has_parts then
        v_added := v_added || v_id;
      end if;
    else
      v_id := (r.e ->> 'id')::uuid;
    end if;
    update public.exam_questions set
      parent_id = (v_ids ->> r.parent_key)::uuid,
      label = btrim(r.e ->> 'label'),
      position = r.position,
      max_mark = (r.e ->> 'max_mark')::numeric,
      mark_step = (r.e ->> 'mark_step')::numeric,
      levels = (r.e ->> 'levels')::boolean,
      pages = coalesce((select array_agg((p #>> '{}')::int order by o) from jsonb_array_elements(r.e -> 'pages') with ordinality t(p, o)), '{}'),
      areas = coalesce((select jsonb_agg(jsonb_build_object('page', (a ->> 'page')::int, 'x', (a ->> 'x')::numeric, 'y', (a ->> 'y')::numeric,
                                                            'w', (a ->> 'w')::numeric, 'h', (a ->> 'h')::numeric) order by o)
                        from jsonb_array_elements(r.e -> 'areas') with ordinality t(a, o)), '[]'),
      group_id = (v_gids ->> (r.e ->> 'group_key'))::uuid,
      option_group_id = (v_oids ->> (r.e ->> 'option_group_key'))::uuid,
      guidance = nullif(btrim(r.e ->> 'guidance'), ''),
      alternatives = nullif(btrim(r.e ->> 'alternatives'), ''),
      updated_at = now()
    where id = v_id;
    insert into public.mark_scheme_points (question_id, position, label, marks, marks_to, text)
    select v_id, o, nullif(btrim(p ->> 'label'), ''), (p ->> 'marks')::numeric, (p ->> 'marks_to')::numeric, btrim(p ->> 'text')
    from jsonb_array_elements(coalesce(r.e -> 'points', '[]')) with ordinality t(p, o);
    v_ids := v_ids || jsonb_build_object(r.key, v_id);
  end loop;

  -- A question added once marking has opened: the submitted live pieces that include it (the whole script, or the
  -- group of its top-level question) of scripts still being marked (not withdrawn or void) are reopened, and their
  -- scripts are being marked again. A piece goes back to the same marker when they may still mark it (is_marker_for:
  -- an active, approved marker of the subject; and not blocked for the candidate). Otherwise the piece is open again
  -- for anyone and that marking is set aside (unapproved, or conflict when blocked), so no hold is left stranded.
  if v_locked and cardinality(v_added) > 0 then
    -- The rows of the scripts whose pieces include the new question are held first, in id order (Ruling R9), and
    -- only then are their states and pieces read: a booking cancelled or a script voided at the same moment has either
    -- finished (the script is withdrawn or void and left alone) or waits until this save ends.
    with recursive up as (
      select q.id, q.parent_id, q.group_id from public.exam_questions q where q.id = any (v_added)
      union all
      select p.id, p.parent_id, p.group_id from up join public.exam_questions p on p.id = up.parent_id
    )
    select coalesce(array_agg(distinct u.script_id order by u.script_id), '{}') into v_held
    from public.marking_units u
    where u.exam_id = p_exam
      and (u.group_id is null or u.group_id in (select up.group_id from up where up.parent_id is null));
    perform 1 from public.scripts s where s.id = any (v_held) order by s.id for no key update;

    with recursive up as (
      select q.id, q.parent_id, q.group_id from public.exam_questions q where q.id = any (v_added)
      union all
      select p.id, p.parent_id, p.group_id from up join public.exam_questions p on p.id = up.parent_id
    )
    select coalesce(array_agg(u.id), '{}') into v_units
    from public.marking_units u
    join public.scripts s on s.id = u.script_id
    where u.exam_id = p_exam
      and s.id = any (v_held)
      and s.state not in ('withdrawn', 'void')
      and (u.group_id is null or u.group_id in (select up.group_id from up where up.parent_id is null));

    with pieces as (
      select m.id as marking_id, m.unit_id, m.marker_id, u.script_id,
        public.is_marker_for(m.marker_id, v_e.subject_id) as approved,
        public.marking_marker_blocked(m.marker_id, b.student_id) as blocked
      from public.markings m
      join public.marking_units u on u.id = m.unit_id
      join public.scripts s on s.id = u.script_id
      join public.bookings b on b.id = s.booking_id
      where m.unit_id = any (v_units) and m.kind = 'live' and m.status = 'submitted'
        and s.state not in ('withdrawn', 'void')
    ),
    reopened as (
      update public.markings m set status = 'in_progress', submitted_at = null
      from pieces p where m.id = p.marking_id and p.approved and not p.blocked
      returning m.unit_id, m.marker_id
    ),
    set_aside as (
      update public.markings m
      set status = 'set_aside', set_aside_at = now(), set_aside_reason = case when p.blocked then 'conflict' else 'unapproved' end
      from pieces p where m.id = p.marking_id and not (p.approved and not p.blocked)
      returning m.id
    ),
    units as (
      update public.marking_units u set state = case when p.approved and not p.blocked then 'taken' else 'open' end
      from pieces p where u.id = p.unit_id
      returning u.script_id
    ),
    assigned as (
      insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by)
      select ro.unit_id, 'live', ro.marker_id, 'assigned', v_actor from reopened ro
    )
    select coalesce(array_agg(distinct units.script_id order by units.script_id), '{}') into v_scripts from units;
    -- Each reopened script's state follows its units (a marked script is being marked again).
    foreach v_id in array v_scripts loop
      perform public.marking_script_state(v_id);
    end loop;
  end if;

  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, case when v_locked then 'exam_structure_changed_after_lock' else 'exam_structure_saved' end, 'exam', p_exam, v_reason);
  return jsonb_build_object('ok', true, 'version', v_version, 'max_total', public.exam_structure_max_total(p_exam));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- The minute job, scheduled once however often this migration runs.
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from cron.job where jobname = 'marking-tick') then
    perform cron.unschedule('marking-tick');
  end if;
  perform cron.schedule('marking-tick', '* * * * *', $job$select public.marking_tick()$job$);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges.
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.marking_script_busy(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_script_waiting(uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.marking_script_blocked(uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.marking_script_state(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_exam_sync(uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.marking_tick() from public, anon, authenticated, service_role;
revoke execute on function public.marking_on_script_state() from public, anon, authenticated, service_role;
revoke execute on function public.marking_settings_set(uuid, public.marking_mode, timestamptz, text) from public, anon;
revoke execute on function public.marking_exam_get(uuid, timestamptz) from public, anon;
revoke execute on function public.marking_open(uuid) from public, anon;
revoke execute on function public.marking_close(uuid, text) from public, anon;
revoke execute on function public.marking_reopen(uuid, text) from public, anon;
grant execute on function public.marking_settings_set(uuid, public.marking_mode, timestamptz, text) to authenticated;
grant execute on function public.marking_exam_get(uuid, timestamptz) to authenticated;
grant execute on function public.marking_open(uuid) to authenticated;
grant execute on function public.marking_close(uuid, text) to authenticated;
grant execute on function public.marking_reopen(uuid, text) to authenticated;
