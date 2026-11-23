-- Phase 3A Task 7: holding pieces when a marking picture changes, "Name visible" from a marker, staff taking a script
-- back from marking and handing it back, pages set aside for a script being marked, and the marking alerts with their
-- emails.
--
-- A page picture of a script being marked (ready to mark, being marked or marked) is made to hide something else (its
-- rotation, staff or paper hidden areas: script_pages.marking_inputs, the key written as each picture is stored): its
-- pieces that are taken or submitted go on hold (picture_changed) and the lead marker and admins get an alert and an
-- email. A picture made again from the same inputs (a remask lists every answer page of its file) holds nothing. A
-- picture that goes (picture_missing) holds every piece of the script, open ones too, until the script is handed back.
-- Holds keep their marks; a hold on a piece that is on hold does not run out (Task 5). The lead (or an admin) releases
-- a picture_changed alert, or all of an exam's at once, once every page has a picture again, the script is not busy
-- and it is not taken back; the markers carry on, their Next script holds restarted at now + 2 hours. A missing
-- picture is never released: an admin takes the script back. While an alert other than name_visible is open, the
-- subject's lead may read the script's marking pictures (marking_picture_allowed); never once marking has closed
-- (Ruling R11).
--
-- A marker who sees a name presses "Name visible" (marking_name_visible: the piece and the page, no text the marker
-- could type a name into): a name_visible exception for the page; on every piece of the script their holds and
-- markings in progress end (name_seen) and Next script never offers them the piece again; and the whole script is
-- taken back from the markers. Taking back (also by an
-- admin, with a reason) puts every piece of the script on hold (name_visible or taken_back), keeps the other markers'
-- holds and markings, and returns the script to staff (needs attention, then worked out again by script_evaluate), so
-- the Phase 2 page tools work on it again. It never comes back by itself: marking_exam_sync leaves a taken-back script
-- alone (marking_script_waiting). Staff hand it back once it is verified and its pictures are made
-- (marking_script_hand_back): it is ready to mark again (its extra pages written down once more), the pieces whose pages
-- changed meanwhile are marked as changed and a submitted one goes back to its marker (or, when they may no longer mark
-- it, is set aside and left open, as Task 2 does), the holds are lifted and the open alerts of the script close.
--
-- A page scanned for a script being marked is set aside by Phase 2 (a not_expected exception, reason script_locked):
-- that raises a pages_set_aside alert, and changes nothing markers see.
--
-- An alert is one row per script and kind while open (marking_alerts_one_open); its email (script_notices kind
-- marking_alert, with the exam and the alert: alert_id) is grouped per exam and kind while one waits to be sent, and
-- says how many alerts it is about. Its recipients are the subject's lead marker and the
-- active owner and admin accounts. Nothing in an alert, its list or its email names the candidate or a marker: the
-- script number and the index number only.
--
-- Lock order (Ruling R9): the marker's advisory lock (exclusive in marking_name_visible, which adds exclusions; shared,
-- in uuid order, for the markers of a script handed back, whose pieces may go back to them: Ruling R10), then the exam's
-- marking row (for share), then the booking's advisory lock (taking back, handing back and
-- Name visible: Phase 2's script_evaluate takes the hand-in's row), then the script's row, then its pieces in id order,
-- then their assignments and markings. The picture trigger runs inside Phase 2's record of new pictures, which already
-- holds the bookings' locks and the page rows: it takes the rows of the scripts being marked that show a page of the
-- file, in id order, then their pieces; it never takes an exam's marking row. marking_save takes the script's row, the
-- piece, then the marking, so the two wait for each other in one order.
--
-- Changed, each from its latest definition:
--   marking_picture_allowed (20261122000007): also true for the subject's lead marker, not blocked for the candidate,
--     for a marking picture of a script being marked and not taken back, with an open alert other than name_visible
--     (and no open name_visible exception on the page), while the exam's marking is open.
--   script_detail (20261120000065): the script also says taken_back_at and taken_back_reason.
--   script_notice_recipients (20261120000055): a marking_alert goes to the subject's lead marker and the active owner
--     and admin accounts.
--   script_notice_count (20261120000076): a marking_alert's email counts the alerts of its exam and kind since it was
--     queued.
--   script_notice_content (20261120000076): a marking_alert's exam is the notice's, and every notice also says
--     alert_kind (the kind of its marking alert; null for the other kinds).
--   script_notice_next and script_notice_given_up (20261122000001): a marking_alert is handed out and given up as a
--     staff alert is (after the families' notices; 3 tries, 6 hours).
--   script_family_notices_waiting and script_family_notices_skip (20261122000001): a marking_alert is not a family
--     notice.
-- Nothing else in them changed.

-- ---------------------------------------------------------------------------------------------
-- Notices: the kind marking_alert, one per alert.
-- ---------------------------------------------------------------------------------------------
alter table public.script_notices add column alert_id uuid references public.marking_alerts (id);
alter table public.script_notices drop constraint script_notices_kind_check;
alter table public.script_notices add constraint script_notices_kind_check
  check (kind in ('receipt', 'needs_attention', 'rejected', 'staff_alert', 'marking_alert'));
alter table public.script_notices drop constraint script_notices_owner;
alter table public.script_notices add constraint script_notices_owner check (
  (kind = 'staff_alert' and exam_id is not null and exception_kind is not null)
  or (kind = 'marking_alert' and exam_id is not null and alert_id is not null)
  or (kind not in ('staff_alert', 'marking_alert') and submission_id is not null));
create unique index script_notices_once_per_alert on public.script_notices (alert_id) where kind = 'marking_alert';

-- ---------------------------------------------------------------------------------------------
-- Internal: holds what changing a script's marking needs, in the order of Ruling R9: the exam's marking row (for
-- share), the booking's advisory lock, the script's row, then its pieces in id order.
-- ---------------------------------------------------------------------------------------------
create function public.marking_script_lock(p_script uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_exam uuid;
  v_booking uuid;
begin
  select s.exam_id, s.booking_id into v_exam, v_booking from public.scripts s where s.id = p_script;
  perform 1 from public.exam_marking m where m.exam_id = v_exam for share;
  perform public.script_bookings_lock(array[v_booking]);
  perform 1 from public.scripts s where s.id = p_script for no key update;
  perform 1 from public.marking_units u where u.script_id = p_script order by u.id for update;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: an alert of this kind for the script, unless one is open already (one open per script and kind), and its
-- email. The emails are grouped per exam and kind, as Phase 2 groups staff alerts (20261120000076): an alert raised
-- while the email of its exam and kind still waits to be sent (not claimed, under 6 hours old) joins it, and the email
-- says how many alerts it is about (script_notice_count). Returns the new alert, or null when one was open.
-- ---------------------------------------------------------------------------------------------
create function public.marking_alert_raise(p_script uuid, p_kind text, p_unit uuid, p_page uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_exam uuid;
  v_id uuid;
  v_key text;
begin
  select s.exam_id into v_exam from public.scripts s where s.id = p_script;
  insert into public.marking_alerts (exam_id, kind, script_id, unit_id, page_id)
  values (v_exam, p_kind, p_script, p_unit, p_page)
  on conflict (script_id, kind) where state = 'open' do nothing
  returning id into v_id;
  v_key := concat_ws('|', v_exam, 'marking_alert', p_kind);
  if v_id is not null and not exists (
       select 1 from public.script_notices n
       where n.kind = 'marking_alert' and n.dedupe_key = v_key and n.sent_at is null and n.claimed_at is null
         and n.skipped_at is null and n.created_at > now() - interval '6 hours') then
    insert into public.script_notices (kind, script_id, exam_id, alert_id, dedupe_key)
    values ('marking_alert', p_script, v_exam, v_id, v_key);
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the script's pieces that are taken or submitted go on hold for p_hold_reason; for picture_missing every
-- piece does, open ones too, so nobody is handed a page with no picture (only handing the script back lifts that). A
-- piece already on hold keeps its reason, except that a missing picture outweighs a changed one. Then an alert of
-- p_alert_kind about the page (marking_alert_raise). The caller holds the script's row (taken again here, in the same
-- order).
-- ---------------------------------------------------------------------------------------------
create function public.marking_script_hold(p_script uuid, p_hold_reason text, p_alert_kind text, p_page uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform 1 from public.scripts s where s.id = p_script for no key update;
  update public.marking_units u
  set on_hold = true,
    hold_reason = case when u.on_hold and u.hold_reason is distinct from 'picture_changed' then u.hold_reason else p_hold_reason end
  where u.script_id = p_script and (p_hold_reason = 'picture_missing' or u.state in ('taken', 'submitted'));
  perform public.marking_alert_raise(p_script, p_alert_kind, null, p_page);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- What a page's marking picture hides, as a key (md5): its rotation, its staff hidden areas and the paper hidden areas
-- of its copy page (each in a stable order: by place, not by when they were saved), and the name band rule (a
-- constant; change it if the processor's band rule changes). p_copy and p_copy_page are the page's copy and copy page
-- (for a page with no code, the slot a script shows it at).
-- ---------------------------------------------------------------------------------------------
create function public.marking_mask_key(p_page uuid, p_rotation int, p_copy uuid, p_copy_page int)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select md5(jsonb_build_object(
    'band', 'name_band_1',
    'rotation', p_rotation,
    'staff_areas', coalesce((
      select jsonb_agg(jsonb_build_array(trim_scale(a.x), trim_scale(a.y), trim_scale(a.w), trim_scale(a.h)) order by a.x, a.y, a.w, a.h)
      from public.script_page_hidden_areas a where a.page_id = p_page), '[]'::jsonb),
    'paper_areas', coalesce((
      select jsonb_agg(jsonb_build_array(trim_scale(a.x), trim_scale(a.y), trim_scale(a.w), trim_scale(a.h)) order by a.x, a.y, a.w, a.h)
      from public.paper_copies c join public.paper_hidden_areas a on a.paper_id = c.paper_id and a.page = p_copy_page
      where c.id = p_copy), '[]'::jsonb))::text)
$$;

-- The key of what the page's current marking picture was made to hide (null: no marking picture). Written when a
-- picture is stored (marking_picture_inputs), so a picture made again from the same inputs (a remask lists every answer
-- page of its file) is told apart from one that hides something else.
alter table public.script_pages add column marking_inputs text;

-- Before a page row is stored with a marking picture, or its marking picture changes: the key of the inputs now. A
-- page with a code uses its own copy page; a page with no code, the slot a script shows it at (script_page_copy).
create function public.marking_picture_inputs()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_copy uuid := new.copy_id;
  v_copy_page int := new.copy_page;
begin
  if tg_op = 'UPDATE' and old.marking_path is not distinct from new.marking_path then
    new.marking_inputs := old.marking_inputs;
    return new;
  end if;
  if new.marking_path is null then
    new.marking_inputs := null;
    return new;
  end if;
  if tg_op = 'UPDATE' and v_copy is null then
    select t.copy_id, t.copy_page into v_copy, v_copy_page from public.script_page_copy(new.id) t;
  end if;
  new.marking_inputs := public.marking_mask_key(new.id, new.rotation, v_copy, v_copy_page);
  return new;
end;
$$;

create trigger marking_picture_inputs before insert or update of marking_path on public.script_pages
  for each row
  execute function public.marking_picture_inputs();

-- The pictures already stored count as made from their page's inputs now.
update public.script_pages p
set marking_inputs = public.marking_mask_key(p.id, p.rotation, t.copy_id, t.copy_page)
from public.script_pages q cross join lateral public.script_page_copy(q.id) t
where q.id = p.id and p.marking_path is not null and p.replaced_at is null;

-- ---------------------------------------------------------------------------------------------
-- A page's marking picture went (picture_missing), or was made again to hide something else (picture_changed: its
-- inputs key differs; a first picture, with no key before, counts as changed), while a script being marked shows it
-- (marking_script_pages): that script's pieces are held (marking_script_hold). A picture made again from the same
-- inputs holds nothing, raises no alert and sends no email. The rows of every script being marked that shows a page of
-- the same file are taken first, in id order, so a record that changes several scripts' pictures (a remask of a scan
-- file) takes them in one order whatever the order of its pages.
-- ---------------------------------------------------------------------------------------------
create function public.marking_on_page_picture()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hold text := case when new.marking_path is null then 'picture_missing' else 'picture_changed' end;
  v_s uuid;
begin
  -- The scripts that may show this page: those whose current version links it, and the home script of the hand-in it
  -- came with (an extra page). Usually none is being marked, and nothing more is done.
  if not exists (
       select 1 from public.scripts s
       where s.state in ('ready_to_mark', 'marking', 'marked')
         and s.id in (select l.script_id from public.script_page_links l
                      join public.scripts x on x.id = l.script_id and x.version = l.version
                      where l.page_id = new.id
                      union
                      select x.id from public.script_uploads u
                      join public.home_submissions hs on hs.id = u.submission_id
                      join public.scripts x on x.booking_id = hs.booking_id
                      where u.id = new.upload_id)) then
    return null;
  end if;

  perform 1 from public.scripts s
  where s.state in ('ready_to_mark', 'marking', 'marked')
    and s.id in (select l.script_id from public.script_pages p
                 join public.script_page_links l on l.page_id = p.id
                 join public.scripts x on x.id = l.script_id and x.version = l.version
                 where p.upload_id = new.upload_id
                 union
                 select x.id from public.script_uploads u
                 join public.home_submissions hs on hs.id = u.submission_id
                 join public.scripts x on x.booking_id = hs.booking_id
                 where u.id = new.upload_id)
  order by s.id
  for no key update;

  for v_s in
    select s.id from public.scripts s
    where s.state in ('ready_to_mark', 'marking', 'marked')
      and s.id in (select l.script_id from public.script_page_links l
                   join public.scripts x on x.id = l.script_id and x.version = l.version
                   where l.page_id = new.id
                   union
                   select x.id from public.script_uploads u
                   join public.home_submissions hs on hs.id = u.submission_id
                   join public.scripts x on x.booking_id = hs.booking_id
                   where u.id = new.upload_id)
      and exists (select 1 from public.marking_script_pages(s.id) x where x.page_id = new.id)
    order by s.id
  loop
    perform public.marking_script_hold(v_s, v_hold, v_hold, new.id);
  end loop;
  return null;
end;
$$;

create trigger marking_on_page_picture after update of marking_path on public.script_pages
  for each row
  when (old.marking_path is distinct from new.marking_path
        and (new.marking_path is null or new.marking_inputs is distinct from old.marking_inputs))
  execute function public.marking_on_page_picture();

-- ---------------------------------------------------------------------------------------------
-- A page set aside because its script is being marked (Phase 2: not_expected, reason script_locked): a
-- pages_set_aside alert for that script. Nothing is held: its pictures did not change.
-- ---------------------------------------------------------------------------------------------
create function public.marking_on_set_aside()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s public.scripts%rowtype;
begin
  select * into v_s from public.scripts s
  where s.id = coalesce(new.script_id, (select x.id from public.scripts x where x.booking_id = new.booking_id));
  if v_s.id is not null and v_s.state in ('ready_to_mark', 'marking', 'marked') then
    perform public.marking_alert_raise(v_s.id, 'pages_set_aside', null, new.page_id);
  end if;
  return null;
end;
$$;

create trigger marking_on_set_aside after insert on public.script_exceptions
  for each row
  when (new.kind = 'not_expected' and new.details ->> 'reason' = 'script_locked')
  execute function public.marking_on_set_aside();

-- ---------------------------------------------------------------------------------------------
-- Internal: the script is taken back from the markers, by p_actor. Every piece goes on hold (name_visible when
-- p_reason is 'name_visible', else taken_back); the holds and markings are kept, so each piece returns to its marker;
-- taken_back_at, taken_back_by and taken_back_reason are set; the script needs attention and is worked out again
-- (script_evaluate: verified when nothing is open). Audited (marking_script_taken_back). The caller holds the locks
-- (marking_script_lock) and has checked the script is being marked and not taken back.
-- ---------------------------------------------------------------------------------------------
create function public.marking_script_take_back_as(p_script uuid, p_actor uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.scripts s
                 where s.id = p_script and s.state in ('ready_to_mark', 'marking', 'marked') and s.taken_back_at is null) then
    raise exception 'marking_script_take_back_as: the script is not being marked';
  end if;
  update public.marking_units u
  set on_hold = true, hold_reason = case when p_reason = 'name_visible' then 'name_visible' else 'taken_back' end
  where u.script_id = p_script;
  update public.scripts
  set taken_back_at = now(), taken_back_by = p_actor, taken_back_reason = p_reason, state = 'needs_attention'
  where id = p_script;
  perform public.script_evaluate(p_script);
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (p_actor, 'marking_script_taken_back', 'script', p_script,
    case when p_reason = 'name_visible' then 'A marker reported a visible name.' else p_reason end);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the script's live markings (not set aside) whose pages_key is not that of its pages now
-- (marking_pages_key) are marked as changed (pages_key, pages_changed_at = now; their rev moves on, so a screen still
-- showing the old pages reloads). A submitted one goes back to its marker when they may still mark it (is_marker_for,
-- and not blocked for the candidate: the rule of a question added after opening, Task 2; and they did not see a name
-- on it: no name_seen exclusion, Name visible): in progress again, its piece taken, with an assigned hold (no time
-- limit) unless the piece has an open one. Otherwise it is set aside (name_seen, conflict or unapproved), its piece is
-- open and nobody is given it. A pages_changed alert when any changed. Returns how many went back to their
-- markers. The caller holds the keys of those markers (shared, in uuid order: a piece going back to its marker is a
-- hand-out, Ruling R10), then the script's locks.
-- ---------------------------------------------------------------------------------------------
create function public.marking_units_refresh(p_script uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text := public.marking_pages_key(p_script);
  v_subject bigint;
  v_student uuid;
  v_changed int := 0;
  v_n int := 0;
  r record;
begin
  select e.subject_id, b.student_id into v_subject, v_student
  from public.scripts s join public.exams e on e.id = s.exam_id join public.bookings b on b.id = s.booking_id
  where s.id = p_script;
  for r in
    select m.id, m.unit_id, m.marker_id, m.status,
      public.is_marker_for(m.marker_id, v_subject) as approved,
      public.marking_marker_blocked(m.marker_id, v_student) as blocked,
      exists (select 1 from public.marking_unit_exclusions x where x.unit_id = m.unit_id and x.marker_id = m.marker_id) as name_seen
    from public.markings m join public.marking_units u on u.id = m.unit_id
    where u.script_id = p_script and m.kind = 'live' and m.status <> 'set_aside' and m.pages_key is distinct from v_key
    order by u.id, m.id
  loop
    v_changed := v_changed + 1;
    update public.markings set pages_key = v_key, pages_changed_at = now(), rev = rev + 1 where id = r.id;
    if r.status = 'submitted' then
      if r.approved and not r.blocked and not r.name_seen then
        update public.markings set status = 'in_progress', submitted_at = null where id = r.id;
        update public.marking_units set state = 'taken' where id = r.unit_id;
        insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by)
        select r.unit_id, 'live', r.marker_id, 'assigned', auth.uid()
        where not exists (select 1 from public.marking_assignments a where a.unit_id = r.unit_id and a.kind = 'live' and a.ended_at is null);
        v_n := v_n + 1;
      else
        update public.markings
        set status = 'set_aside', set_aside_at = now(),
          set_aside_reason = case when r.name_seen then 'name_seen' when r.blocked then 'conflict' else 'unapproved' end
        where id = r.id;
        update public.marking_units set state = 'open' where id = r.unit_id and state = 'submitted';
      end if;
    end if;
  end loop;
  if v_changed > 0 then
    perform public.marking_alert_raise(p_script, 'pages_changed', null, null);
  end if;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: why the script's picture_changed holds may not be released now (null: they may). The first of taken_back,
-- pictures_updating (marking_script_busy) and picture_missing (a page it shows has no marking picture).
-- ---------------------------------------------------------------------------------------------
create function public.marking_alert_can_release(p_script uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when exists (select 1 from public.scripts s where s.id = p_script and s.taken_back_at is not null) then 'taken_back'
    when public.marking_script_busy(p_script) then 'pictures_updating'
    when exists (select 1 from public.marking_script_pages(p_script) x where x.marking_path is null) then 'picture_missing'
  end
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_name_visible: a marker says p_page shows the candidate's name. No text is taken: a marker might type the
-- name. A name a marker saw is always reportable: the caller holds the piece, or has a live marking on it that is not
-- set aside (in progress or submitted), even after their hold ran out, on hold or after marking closed. Refused:
-- invalid_input (also a page the piece does not show), not_found, forbidden (no such claim). In one transaction:
--   a name_visible exception for the page ({"from": "marker"}), unless one is open for it already;
--   on every piece of the script, the caller's holds end (name_seen), their markings in progress are set aside
--     (name_seen) and Next script never offers them the piece again (an exclusion); their marking of the reported
--     piece is set aside whatever its state; their submitted markings of other pieces stand (the alert tells admins,
--     who may take them back); the pieces they no longer hold are open;
--   the script is taken back from the markers (marking_script_take_back_as), unless it was already;
--   a name_visible alert; audit marking_name_visible.
-- Returns {ok}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_name_visible(p_unit uuid, p_page uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_u public.marking_units%rowtype;
  v_x public.scripts%rowtype;
  v_ended uuid[];
begin
  if p_unit is null or p_page is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  -- Ruling R10: the marker's advisory lock, exclusive (exclusions are added), first of all.
  perform pg_advisory_xact_lock(hashtextextended('marker:' || v_actor::text, 0));
  select * into v_u from public.marking_units u where u.id = p_unit;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  perform public.marking_script_lock(v_u.script_id);
  select * into v_x from public.scripts s where s.id = v_u.script_id;
  perform 1 from public.markings m
  where m.kind = 'live' and m.marker_id = v_actor
    and m.unit_id in (select u.id from public.marking_units u where u.script_id = v_x.id)
  order by m.id
  for update;
  if not exists (select 1 from public.marking_assignments a
                 where a.unit_id = p_unit and a.kind = 'live' and a.marker_id = v_actor and a.ended_at is null)
     and not exists (select 1 from public.markings m
                     where m.unit_id = p_unit and m.kind = 'live' and m.marker_id = v_actor and m.status in ('in_progress', 'submitted')) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if not exists (select 1 from public.marking_script_pages(v_x.id) x where x.page_id = p_page) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
  select v_x.exam_id, 'name_visible', v_x.booking_id, v_x.id, p.id, p.upload_id, '{"from": "marker"}'::jsonb
  from public.script_pages p
  where p.id = p_page
    and not exists (select 1 from public.script_exceptions e where e.page_id = p_page and e.kind = 'name_visible' and e.state = 'open');
  with ended as (
    update public.marking_assignments a set ended_at = now(), end_reason = 'name_seen'
    where a.kind = 'live' and a.marker_id = v_actor and a.ended_at is null
      and a.unit_id in (select u.id from public.marking_units u where u.script_id = v_x.id)
    returning a.unit_id
  )
  select coalesce(array_agg(e.unit_id), '{}') into v_ended from ended e;
  update public.markings m set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'name_seen'
  where m.kind = 'live' and m.marker_id = v_actor
    and m.unit_id in (select u.id from public.marking_units u where u.script_id = v_x.id)
    and (m.status = 'in_progress' or (m.unit_id = p_unit and m.status = 'submitted'));
  update public.marking_units u set state = 'open'
  where (u.id = p_unit or u.id = any (v_ended)) and u.state <> 'open';
  insert into public.marking_unit_exclusions (unit_id, marker_id, reason)
  select u.id, v_actor, 'name_seen' from public.marking_units u where u.script_id = v_x.id
  on conflict do nothing;
  if v_x.state in ('ready_to_mark', 'marking', 'marked') and v_x.taken_back_at is null then
    perform public.marking_script_take_back_as(v_x.id, v_actor, 'name_visible');
  end if;
  perform public.marking_alert_raise(v_x.id, 'name_visible', p_unit, p_page);
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'marking_name_visible', 'marking_unit', p_unit);
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_script_take_back: an admin takes a script being marked (ready to mark, being marked or marked) back from the
-- markers, with a reason (marking_script_take_back_as). Its pages can then be changed with the Phase 2 tools (hidden
-- areas, placing a page, turning a page). Refused: forbidden, invalid_input, reason_required, not_found, conflict with
-- reason taken_back (already) or not_marking. Returns {ok, state}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_script_take_back(p_script uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_x public.scripts%rowtype;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_script is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if not exists (select 1 from public.scripts s where s.id = p_script) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  perform public.marking_script_lock(p_script);
  select * into v_x from public.scripts s where s.id = p_script;
  if v_x.taken_back_at is not null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'taken_back');
  end if;
  if v_x.state not in ('ready_to_mark', 'marking', 'marked') then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'not_marking');
  end if;
  perform public.marking_script_take_back_as(p_script, v_actor, v_reason);
  select * into v_x from public.scripts s where s.id = p_script;
  return jsonb_build_object('ok', true, 'state', v_x.state);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_script_hand_back: an admin hands a taken-back script back to the markers. The reason is optional; given, it
-- is 3 to 300 characters (reason_required). The script must be verified (conflict, not_verified) and not busy (conflict,
-- pictures_updating: a file of its pages is being prepared or remasked). Its taken_back_* are cleared; it is ready to
-- mark again (so its extra pages are written down again) and the pieces whose pages changed are refreshed
-- (marking_units_refresh); the holds for taken_back, name_visible, picture_changed and picture_missing are lifted and
-- the Next script holds restart at now + 2 hours; its state follows its pieces (marking_script_state). Its open alerts
-- close (handed_back) before the refresh raises any pages_changed alert. Audited (marking_script_handed_back). The keys
-- of the markers of its live markings are taken first (shared, in uuid order), then the script's locks.
-- Refused also: forbidden, invalid_input, not_found, conflict with reason not_taken_back. Returns {ok, state, reopened}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_script_hand_back(p_script uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_given text := nullif(btrim(coalesce(p_reason, '')), '');
  v_reason text := public.script_resolution_reason(p_reason);
  v_x public.scripts%rowtype;
  v_reopened int;
  v_marker uuid;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_script is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_given is not null and v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if not exists (select 1 from public.scripts s where s.id = p_script) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  -- Ruling R10: a submitted piece may go back to its marker (marking_units_refresh), as a hand-out does, so the markers
  -- of the script's live markings have their keys taken (shared, in uuid order) before the script's locks. While the
  -- script is taken back its pieces are on hold, so no new marking appears meanwhile.
  for v_marker in
    select distinct m.marker_id from public.markings m join public.marking_units u on u.id = m.unit_id
    where u.script_id = p_script and m.kind = 'live' and m.status <> 'set_aside'
    order by 1
  loop
    perform pg_advisory_xact_lock_shared(hashtextextended('marker:' || v_marker::text, 0));
  end loop;
  perform public.marking_script_lock(p_script);
  select * into v_x from public.scripts s where s.id = p_script;
  if v_x.taken_back_at is null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'not_taken_back');
  end if;
  if v_x.state <> 'verified' then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'not_verified');
  end if;
  if public.marking_script_busy(p_script) then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'pictures_updating');
  end if;

  -- Through ready to mark first: marking_exam_sync looks at no pieces, and the extras trigger writes extras_locked.
  update public.scripts set taken_back_at = null, taken_back_by = null, taken_back_reason = null, state = 'ready_to_mark'
  where id = p_script;
  update public.marking_alerts set state = 'closed', closed_by = v_actor, closed_at = now(), resolution = 'handed_back', reason = v_reason
  where script_id = p_script and state = 'open';
  v_reopened := public.marking_units_refresh(p_script);
  update public.marking_units u set on_hold = false, hold_reason = null
  where u.script_id = p_script and u.on_hold and u.hold_reason in ('taken_back', 'name_visible', 'picture_changed', 'picture_missing');
  update public.marking_assignments a set hold_until = now() + interval '2 hours'
  where a.ended_at is null and a.how = 'next' and a.kind = 'live'
    and a.unit_id in (select u.id from public.marking_units u where u.script_id = p_script and not u.on_hold);
  perform public.marking_script_state(p_script);
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_script_handed_back', 'script', p_script, v_reason);
  select * into v_x from public.scripts s where s.id = p_script;
  return jsonb_build_object('ok', true, 'state', v_x.state, 'reopened', v_reopened);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_alerts_list: the marking alerts (p_state open, closed, or null for all; of one exam when given), at most
-- 500, oldest first. Admins: all; a lead marker: those of the subjects they lead. Each: {id, kind, exam_id,
-- exam_title, script_id, script_number, index_number, page_n (the page's number in the pieces, null when they do not
-- show it), unit_id, created_at, can_release (an open picture_changed alert whose script marking_alert_can_release
-- allows)}. No candidate name and no marker name.
-- ---------------------------------------------------------------------------------------------
create function public.marking_alerts_list(p_exam uuid default null, p_state text default 'open')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_admin boolean := public.is_staff_admin();
  v_subject bigint;
begin
  if not v_admin and not exists (select 1 from public.marker_approvals a where a.marker_id = v_actor and a.lead and public.is_lead_for(v_actor, a.subject_id)) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_state is not null and p_state not in ('open', 'closed') then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if p_exam is not null then
    select e.subject_id into v_subject from public.exams e where e.id = p_exam;
    if not found then
      return jsonb_build_object('ok', false, 'code', 'not_found');
    end if;
    if not v_admin and not public.is_lead_for(v_actor, v_subject) then
      return jsonb_build_object('ok', false, 'code', 'forbidden');
    end if;
  end if;

  return jsonb_build_object('ok', true, 'alerts', coalesce((
    select jsonb_agg(jsonb_build_object(
        'id', t.id, 'kind', t.kind, 'exam_id', t.exam_id, 'exam_title', t.title, 'script_id', t.script_id,
        'script_number', t.number, 'index_number', t.index_number,
        'page_n', (select x.n from public.marking_script_pages(t.script_id) x where x.page_id = t.page_id),
        'unit_id', t.unit_id, 'created_at', t.created_at,
        'can_release', t.kind = 'picture_changed' and t.state = 'open' and public.marking_alert_can_release(t.script_id) is null)
      order by t.created_at, t.id)
    from (
      select a.id, a.kind, a.exam_id, e.title, a.script_id, s.number, d.index_number, a.page_id, a.unit_id, a.created_at, a.state
      from public.marking_alerts a
      join public.exams e on e.id = a.exam_id
      join public.scripts s on s.id = a.script_id
      join public.bookings b on b.id = s.booking_id
      left join public.student_details d on d.profile_id = b.student_id
      where (p_exam is null or a.exam_id = p_exam)
        and (p_state is null or a.state = p_state)
        and (v_admin or public.is_lead_for(v_actor, e.subject_id))
      order by a.created_at, a.id
      limit 500
    ) t), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_alert_release: an admin or the subject's lead releases a picture_changed alert (wrong_kind for any other:
-- a missing picture is never released, an admin takes the script back), with a reason, when
-- marking_alert_can_release allows it (conflict with that reason: taken_back, pictures_updating, picture_missing). The
-- script's picture_changed holds are lifted and its Next script holds restart at now + 2 hours; the alert closes
-- (released). Audited (marking_alert_released). Refused also: forbidden (also a lead blocked for the script's candidate,
-- marking_marker_blocked; an admin may still), invalid_input, reason_required, not_found, conflict with reason closed.
-- Returns {ok, released} (how many pieces were released).
-- ---------------------------------------------------------------------------------------------
create function public.marking_alert_release(p_alert uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_a public.marking_alerts%rowtype;
  v_subject bigint;
  v_student uuid;
  v_why text;
  v_units uuid[];
begin
  if p_alert is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_a from public.marking_alerts a where a.id = p_alert;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when public.is_staff_admin() then 'not_found' else 'forbidden' end);
  end if;
  select e.subject_id into v_subject from public.exams e where e.id = v_a.exam_id;
  select b.student_id into v_student from public.scripts s join public.bookings b on b.id = s.booking_id where s.id = v_a.script_id;
  if not public.is_staff_admin()
     and (not public.is_lead_for(v_actor, v_subject) or public.marking_marker_blocked(v_actor, v_student)) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if v_a.kind <> 'picture_changed' then
    return jsonb_build_object('ok', false, 'code', 'wrong_kind');
  end if;

  -- Ruling R9: the exam's marking row, the script's row, its pieces; then the alert.
  perform 1 from public.exam_marking m where m.exam_id = v_a.exam_id for share;
  perform 1 from public.scripts s where s.id = v_a.script_id for no key update;
  perform 1 from public.marking_units u where u.script_id = v_a.script_id order by u.id for update;
  select * into v_a from public.marking_alerts a where a.id = p_alert for update;
  if v_a.state <> 'open' then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'closed');
  end if;
  v_why := public.marking_alert_can_release(v_a.script_id);
  if v_why is not null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', v_why);
  end if;

  with released as (
    update public.marking_units u set on_hold = false, hold_reason = null
    where u.script_id = v_a.script_id and u.on_hold and u.hold_reason = 'picture_changed'
    returning u.id
  )
  select coalesce(array_agg(r.id), '{}') into v_units from released r;
  update public.marking_assignments a set hold_until = now() + interval '2 hours'
  where a.unit_id = any (v_units) and a.kind = 'live' and a.ended_at is null and a.how = 'next';
  update public.marking_alerts set state = 'closed', closed_by = v_actor, closed_at = now(), resolution = 'released', reason = v_reason
  where id = v_a.id;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_alert_released', 'marking_alert', v_a.id, v_reason);
  return jsonb_build_object('ok', true, 'released', cardinality(v_units));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_alerts_release_all: an admin or the subject's lead releases, with one reason, every open picture_changed
-- alert of the exam that marking_alert_can_release allows (the others stay open), as marking_alert_release does each
-- one. The open alerts are read first; their scripts' rows are taken in id order, then those scripts' pieces (Ruling
-- R9); then the alerts of exactly those scripts are read again under the locks, and only those still open and
-- releasable are released. A lead blocked for a script's candidate (marking_marker_blocked) leaves its alert alone
-- (blocked counts them; an admin is never blocked). One audit row for the exam (marking_alerts_released_all) says how
-- many were released and skipped. Refused: forbidden, invalid_input, reason_required, not_found. Returns {ok,
-- released, blocked} (how many alerts).
-- ---------------------------------------------------------------------------------------------
create function public.marking_alerts_release_all(p_exam uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_admin boolean := public.is_staff_admin();
  v_reason text := public.script_resolution_reason(p_reason);
  v_subject bigint;
  v_scripts uuid[];
  v_units uuid[];
  v_n int := 0;
  v_blocked int := 0;
  r record;
begin
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select e.subject_id into v_subject from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when v_admin then 'not_found' else 'forbidden' end);
  end if;
  if not v_admin and not public.is_lead_for(v_actor, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;

  -- The scripts of the open alerts, then Ruling R9: the exam's marking row, those scripts' rows in id order, their
  -- pieces; then their alerts again, under the locks.
  select coalesce(array_agg(distinct a.script_id order by a.script_id), '{}') into v_scripts
  from public.marking_alerts a where a.exam_id = p_exam and a.kind = 'picture_changed' and a.state = 'open';
  perform 1 from public.exam_marking m where m.exam_id = p_exam for share;
  perform 1 from public.scripts s where s.id = any (v_scripts) order by s.id for no key update;
  perform 1 from public.marking_units u where u.script_id = any (v_scripts) order by u.id for update;
  for r in
    select a.id, a.script_id, b.student_id
    from public.marking_alerts a
    join public.scripts s on s.id = a.script_id
    join public.bookings b on b.id = s.booking_id
    where a.script_id = any (v_scripts) and a.exam_id = p_exam and a.kind = 'picture_changed' and a.state = 'open'
    order by a.script_id
    for update of a
  loop
    if not v_admin and public.marking_marker_blocked(v_actor, r.student_id) then
      v_blocked := v_blocked + 1;
      continue;
    end if;
    continue when public.marking_alert_can_release(r.script_id) is not null;
    with released as (
      update public.marking_units u set on_hold = false, hold_reason = null
      where u.script_id = r.script_id and u.on_hold and u.hold_reason = 'picture_changed'
      returning u.id
    )
    select coalesce(array_agg(x.id), '{}') into v_units from released x;
    update public.marking_assignments a set hold_until = now() + interval '2 hours'
    where a.unit_id = any (v_units) and a.kind = 'live' and a.ended_at is null and a.how = 'next';
    update public.marking_alerts set state = 'closed', closed_by = v_actor, closed_at = now(), resolution = 'released', reason = v_reason
    where id = r.id;
    v_n := v_n + 1;
  end loop;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_alerts_released_all', 'exam', p_exam,
    v_reason || ' (alerts released: ' || v_n
    || case when v_blocked > 0 then '; skipped, a conflict with the candidate: ' || v_blocked else '' end || ')');
  return jsonb_build_object('ok', true, 'released', v_n, 'blocked', v_blocked);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_alert_note: an admin or the subject's lead closes a pages_set_aside or pages_changed alert (noted; wrong_kind
-- for any other), with a reason. Audited (marking_alert_noted). Refused also: forbidden, invalid_input,
-- reason_required, not_found, conflict with reason closed. Returns {ok}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_alert_note(p_alert uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_a public.marking_alerts%rowtype;
  v_subject bigint;
begin
  if p_alert is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_a from public.marking_alerts a where a.id = p_alert;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when public.is_staff_admin() then 'not_found' else 'forbidden' end);
  end if;
  select e.subject_id into v_subject from public.exams e where e.id = v_a.exam_id;
  if not public.is_staff_admin() and not public.is_lead_for(v_actor, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if v_a.kind not in ('pages_set_aside', 'pages_changed') then
    return jsonb_build_object('ok', false, 'code', 'wrong_kind');
  end if;
  select * into v_a from public.marking_alerts a where a.id = p_alert for update;
  if v_a.state <> 'open' then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'closed');
  end if;
  update public.marking_alerts set state = 'closed', closed_by = v_actor, closed_at = now(), resolution = 'noted', reason = v_reason
  where id = v_a.id;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_alert_noted', 'marking_alert', v_a.id, v_reason);
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_picture_allowed: as 20261122000007, and also true for the subject's lead marker when p_name is the current
-- marking picture of a page that a script shows (marking_script_pages) whose exam's marking is open, the script is
-- ready to mark, being marked or marked and not taken back, the lead is not blocked for its candidate
-- (marking_marker_blocked), the script has an open alert other than name_visible and no open name_visible alert, and
-- no open name_visible exception is on the page: the lead looks at the pictures before releasing a hold.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_picture_allowed(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with pages as materialized (
    select p.id, p.upload_id from public.script_pages p
    where p.marking_path = p_name and p.replaced_at is null and p.full_path <> p_name
  ),
  scripts as materialized (
    select s.id from pages pg
    join public.script_page_links l on l.page_id = pg.id
    join public.scripts s on s.id = l.script_id and s.version = l.version
    union
    select s.id from pages pg
    join public.script_uploads up on up.id = pg.upload_id
    join public.home_submissions hs on hs.id = up.submission_id
    join public.scripts s on s.booking_id = hs.booking_id
  ),
  units as materialized (
    select u.id, u.script_id from scripts x
    join public.marking_units u on u.script_id = x.id
    where exists (select 1 from public.marking_assignments a
                  where a.unit_id = u.id and a.kind = 'live' and a.marker_id = (select auth.uid()) and a.ended_at is null)
       or exists (select 1 from public.markings m
                  where m.unit_id = u.id and m.kind = 'live' and m.marker_id = (select auth.uid()) and m.status = 'submitted')
  )
  select coalesce(p_name is not null and (
    exists (
      select 1 from units u
      where public.marking_work_blocked(u.id, (select auth.uid()), null) is null
        and exists (select 1 from public.marking_script_pages(u.script_id) x where x.marking_path = p_name))
    or exists (
      select 1 from scripts x
      join public.scripts s on s.id = x.id
      join public.bookings b on b.id = s.booking_id
      join public.exams e on e.id = s.exam_id
      join public.exam_marking m on m.exam_id = s.exam_id
      where m.opened_at is not null and m.closed_at is null
        and s.state in ('ready_to_mark', 'marking', 'marked') and s.taken_back_at is null
        and public.is_lead_for((select auth.uid()), e.subject_id)
        and not public.marking_marker_blocked((select auth.uid()), b.student_id)
        and exists (select 1 from public.marking_alerts a where a.script_id = s.id and a.state = 'open' and a.kind <> 'name_visible')
        and not exists (select 1 from public.marking_alerts a where a.script_id = s.id and a.state = 'open' and a.kind = 'name_visible')
        and not exists (select 1 from pages pg join public.script_exceptions v on v.page_id = pg.id
                        where v.kind = 'name_visible' and v.state = 'open')
        and exists (select 1 from public.marking_script_pages(s.id) mp where mp.marking_path = p_name))), false)
$$;

-- ---------------------------------------------------------------------------------------------
-- script_detail: as 20261120000065, and the script says taken_back_at and taken_back_reason.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_detail(p_script uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_x public.scripts%rowtype;
  v_b public.bookings%rowtype;
  v_pages uuid[];
  v_uploads uuid[];
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_script is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_x from public.scripts s where s.id = p_script;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into v_b from public.bookings b where b.id = v_x.booking_id;
  -- Every page any version showed, and the extra pages.
  v_pages := array(select distinct l.page_id from public.script_page_links l where l.script_id = v_x.id
                   union select x.page_id from public.script_extra_pages(v_x.id) x);
  v_uploads := array(
    select distinct p.upload_id from public.script_pages p where p.id = any (v_pages)
    union
    select u.id from public.script_uploads u join public.home_submissions hs on hs.id = u.submission_id
    where hs.booking_id = v_x.booking_id and hs.state <> 'draft' and u.state not in ('pending', 'discarded'));

  return jsonb_build_object(
    'ok', true,
    'script', jsonb_build_object('id', v_x.id, 'number', v_x.number, 'source', v_x.source, 'state', v_x.state,
      'state_reason', v_x.state_reason, 'version', v_x.version, 'complete', v_x.complete, 'late', v_x.late,
      'late_decision', v_x.late_decision, 'received_at', v_x.received_at, 'created_at', v_x.created_at, 'updated_at', v_x.updated_at,
      'taken_back_at', v_x.taken_back_at, 'taken_back_reason', v_x.taken_back_reason,
      'exam', (select jsonb_build_object('id', e.id, 'title', e.title, 'paper', e.paper, 'code', e.exam_code, 'starts_at', e.starts_at)
               from public.exams e where e.id = v_x.exam_id),
      'booking', public.script_booking_json(v_x.booking_id)),
    'candidate', (select jsonb_build_object('name', nullif(btrim(coalesce(pr.first_name, '') || ' ' || coalesce(pr.last_name, '')), ''),
                                            'index_number', d.index_number)
                  from public.bookings b left join public.profiles pr on pr.id = b.student_id
                  left join public.student_details d on d.profile_id = b.student_id where b.id = v_x.booking_id),
    'versions', coalesce((
      select jsonb_agg(jsonb_build_object('version', v.version, 'created_at', v.created_at, 'reason', v.reason,
               'by', (select nullif(btrim(coalesce(pr.first_name, '') || ' ' || coalesce(pr.last_name, '')), '') from public.profiles pr where pr.id = v.created_by),
               'submission_seq', hs.seq, 'upload_id', v.upload_id,
               'pages', coalesce((select jsonb_agg(l.copy_page order by l.copy_page) from public.script_page_links l
                                  where l.script_id = v.script_id and l.version = v.version), '[]'::jsonb))
             order by v.version desc)
      from public.script_versions v left join public.home_submissions hs on hs.id = v.submission_id
      where v.script_id = v_x.id), '[]'::jsonb),
    'pages', coalesce((
      select jsonb_agg(x.j order by x.at, x.extra, x.pos, x.idx)
      from (
        select l.copy_page as at, 0 as extra, 0 as pos, 0 as idx,
          public.script_page_json(l.page_id) || jsonb_build_object('page_id', l.page_id, 'copy_page', l.copy_page,
            'printed_page', p.copy_page, 'extra', false, 'turn', ((p.rotation - p.full_rotation) % 360 + 360) % 360,
            'role', case when t.copy_id is null then null
                         when t.copy_page > ep.page_count then 'spare'
                         else (select r.role::text from public.paper_page_roles r where r.paper_id = ep.id and r.page = t.copy_page) end) as j
        from public.script_page_links l
        join public.script_pages p on p.id = l.page_id
        cross join lateral public.script_page_copy(p.id) t
        left join public.paper_copies tc on tc.id = t.copy_id
        left join public.exam_papers ep on ep.id = tc.paper_id
        where l.script_id = v_x.id and l.version = v_x.version
        union all
        select xp.placed_after, 1, coalesce(xp.file_position, 0), xp.source_index,
          public.script_page_json(xp.page_id) || jsonb_build_object('page_id', xp.page_id, 'copy_page', null,
            'printed_page', null, 'extra', true, 'role', 'extra', 'turn', ((p.rotation - p.full_rotation) % 360 + 360) % 360)
        from public.script_extra_pages(v_x.id) xp join public.script_pages p on p.id = xp.page_id
      ) x), '[]'::jsonb),
    'uploads', coalesce((
      select jsonb_agg(jsonb_build_object('id', u.id, 'kind', u.kind, 'state', u.state,
               'source', case when u.batch_id is not null then 'centre' else 'home' end,
               'position', u.position, 'batch_number', sb.number, 'submission_seq', hs.seq, 'submission_state', hs.state,
               'created_at', u.created_at,
               'pages', (select count(*) from public.script_pages p where p.upload_id = u.id and p.replaced_at is null),
               'reprocess_refused', public.script_upload_reprocess_refused(u.id),
               'jobs', coalesce((select jsonb_agg(jsonb_build_object('id', j.id, 'kind', j.kind, 'state', j.state, 'attempts', j.attempts,
                                          'last_error', j.last_error, 'created_at', j.created_at, 'finished_at', j.finished_at) order by j.id desc)
                                 from (select * from public.processing_jobs j2 where j2.upload_id = u.id order by j2.id desc limit 10) j), '[]'::jsonb))
             order by u.created_at, u.id)
      from public.script_uploads u
      left join public.scan_batches sb on sb.id = u.batch_id
      left join public.home_submissions hs on hs.id = u.submission_id
      where u.id = any (v_uploads)), '[]'::jsonb),
    'exceptions', coalesce((
      select jsonb_agg(public.script_exception_json(e.id) order by (e.state = 'open') desc, e.created_at desc, e.id)
      from public.script_exceptions e
      where e.script_id = v_x.id or (e.script_id is null and e.booking_id = v_x.booking_id)), '[]'::jsonb),
    'custody', case when v_b.centre_id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'step', ev.step, 'at', ev.at, 'location', ev.location, 'note', ev.note, 'manifest', m.number,
        'from_name', nullif(btrim(coalesce(pf.first_name, '') || ' ' || coalesce(pf.last_name, '')), ''),
        'to_name', nullif(btrim(coalesce(pt.first_name, '') || ' ' || coalesce(pt.last_name, '')), ''),
        'by_name', nullif(btrim(coalesce(pb.first_name, '') || ' ' || coalesce(pb.last_name, '')), '')) order by ev.at, ev.seq)
      from public.custody_events ev
      left join public.collection_manifests m on m.id = ev.manifest_id
      left join public.profiles pf on pf.id = ev.from_staff
      left join public.profiles pt on pt.id = ev.to_staff
      left join public.profiles pb on pb.id = ev.recorded_by
      where ev.exam_id = v_x.exam_id and ev.centre_id = v_b.centre_id), '[]'::jsonb) end,
    'actions', coalesce((
      select jsonb_agg(jsonb_build_object('action', a.action, 'at', a.created_at, 'reason', a.reason, 'target_type', a.target_type,
               'by', (select nullif(btrim(coalesce(pr.first_name, '') || ' ' || coalesce(pr.last_name, '')), '') from public.profiles pr where pr.id = a.actor_id))
             order by a.created_at desc, a.id desc)
      from (select * from public.audit_log a2
            where (a2.target_type = 'script' and a2.target_id = v_x.id)
               or (a2.target_type = 'script_page' and a2.target_id = any (v_pages))
               or (a2.target_type = 'script_upload' and a2.target_id = any (v_uploads))
            order by a2.created_at desc, a2.id desc limit 100) a), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_notice_recipients: as 20261120000055, and a marking_alert goes to the subject's lead marker (is_lead_for) and
-- the active owner and admin accounts.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_notice_recipients(p_notice public.script_notices)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('profile_id', x.id, 'email', x.email, 'first_name', x.first_name)
    order by lower(x.email)), '[]'::jsonb)
  from (
    select distinct on (lower(r.email)) r.id, r.email, r.first_name
    from (
      select p.id, p.email::text as email, p.first_name, 0 as rnk
      from public.home_submissions h
      join public.bookings b on b.id = h.booking_id
      join public.profiles p on p.id = b.student_id and p.status = 'active'
      where p_notice.kind not in ('staff_alert', 'marking_alert') and h.id = p_notice.submission_id
      union all
      select p.id, p.email::text, p.first_name, 1
      from public.home_submissions h
      join public.bookings b on b.id = h.booking_id
      join public.parent_children pc on pc.student_id = b.student_id
      join public.profiles p on p.id = pc.parent_id and p.status = 'active'
      where p_notice.kind not in ('staff_alert', 'marking_alert') and h.id = p_notice.submission_id
      union all
      select p.id, p.email::text, p.first_name, 0
      from public.profiles p
      where p_notice.kind in ('staff_alert', 'marking_alert') and p.status = 'active' and p.role in ('owner', 'admin')
      union all
      select p.id, p.email::text, p.first_name, 0
      from public.profiles p
      where p_notice.kind = 'marking_alert'
        and public.is_lead_for(p.id, (select e.subject_id from public.exams e where e.id = p_notice.exam_id))
    ) r
    where r.email is not null and r.email <> ''
      and not exists (select 1 from public.script_notices_sent s where s.notice_id = p_notice.id and s.profile_id = r.id)
    order by lower(r.email), r.rnk
  ) x
$$;

-- ---------------------------------------------------------------------------------------------
-- script_notice_count: as 20261120000076, and a marking alert's email is about the alerts of its exam and kind raised
-- since it was queued (marking_alert_raise groups them). At least 1.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_notice_count(p_notice public.script_notices)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select greatest(1, case
    when p_notice.kind = 'marking_alert' then (
      select count(*)::int from public.marking_alerts a
      where a.exam_id = p_notice.exam_id and a.created_at >= p_notice.created_at
        and a.kind = (select k.kind from public.marking_alerts k where k.id = p_notice.alert_id))
    when p_notice.kind <> 'staff_alert' then 1
    when p_notice.exception_kind = 'needs_attention' then (
      select count(*)::int from public.scripts s
      where s.exam_id = p_notice.exam_id and s.source = 'home' and s.attention_notified_at >= p_notice.created_at)
    else (
      select count(*)::int from public.script_exceptions e
      where e.exam_id = p_notice.exam_id and e.kind::text = p_notice.exception_kind and e.created_at >= p_notice.created_at
        and case when p_notice.group_id is null then e.upload_id is null
                 else e.upload_id in (select u.id from public.script_uploads u
                                      where u.id = p_notice.group_id or u.submission_id = p_notice.group_id) end)
  end)
$$;

-- ---------------------------------------------------------------------------------------------
-- script_notice_content: as 20261120000076, and alert_kind (the kind of a marking alert). A marking alert's exam is
-- the notice's.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_notice_content(p_notice public.script_notices)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_sub public.home_submissions%rowtype;
  v_script public.scripts%rowtype;
  v_exam uuid;
  v_label text;
  v_pages int[];
begin
  if p_notice.kind in ('staff_alert', 'marking_alert') then
    v_exam := p_notice.exam_id;
  else
    select * into v_sub from public.home_submissions h where h.id = p_notice.submission_id;
    select b.exam_id into v_exam from public.bookings b where b.id = v_sub.booking_id;
  end if;
  select * into v_script from public.scripts s where s.id = p_notice.script_id;
  select case when coalesce(btrim(e.paper), '') <> '' and position(lower(btrim(e.paper)) in lower(e.title)) = 0
              then e.title || ' ' || btrim(e.paper) else e.title end
  into v_label from public.exams e where e.id = v_exam;
  select coalesce(array_agg(l.copy_page order by l.copy_page), '{}') into v_pages
  from public.script_page_links l where l.script_id = v_script.id and l.version = v_script.version;

  return jsonb_build_object(
    'exam', v_label,
    'script_number', v_script.number,
    'submission_seq', v_sub.seq,
    'at', coalesce(v_sub.checked_at, v_sub.submitted_at, p_notice.created_at),
    'page_count', cardinality(v_pages),
    'pages', to_jsonb(v_pages),
    'exception_kind', p_notice.exception_kind,
    'count', public.script_notice_count(p_notice),
    'alert_kind', (select a.kind from public.marking_alerts a where a.id = p_notice.alert_id));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_notice_next: as 20261122000001, and a marking_alert is handed out as a staff alert is (after the families'
-- notices; 3 tries within 6 hours).
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_notice_next(p_limit int, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_out jsonb := '[]'::jsonb;
  v_n public.script_notices%rowtype;
  v_rec jsonb;
begin
  for v_n in
    select n.* from public.script_notices n
    where n.sent_at is null
      and n.skipped_at is null
      and case when n.kind in ('staff_alert', 'marking_alert')
               then n.attempts < 3
                    and n.created_at > v_now - interval '6 hours'
                    and (n.claimed_at is null or n.claimed_at <= v_now - n.attempts * interval '5 minutes')
               else n.created_at > v_now - interval '7 days'
                    and (n.claimed_at is null or n.claimed_at <= v_now - least(n.attempts * 5, 60) * interval '1 minute')
          end
    order by (n.kind in ('staff_alert', 'marking_alert')), n.created_at, n.id
    limit greatest(coalesce(p_limit, 0), 0)
    for update skip locked
  loop
    update public.script_notices set claimed_at = v_now, attempts = attempts + 1 where id = v_n.id
    returning * into v_n;
    v_rec := public.script_notice_recipients(v_n);
    if jsonb_array_length(v_rec) = 0 then
      -- everyone was already recorded (a run stopped before marking): nothing left to send
      update public.script_notices set sent_at = v_now where id = v_n.id;
      continue;
    end if;
    v_out := v_out || (jsonb_build_object('id', v_n.id, 'kind', v_n.kind, 'recipients', v_rec)
      || public.script_notice_content(v_n));
  end loop;
  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_notice_given_up: as 20261122000001, and a marking_alert is given up as a staff alert is.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_notice_given_up(p_now timestamptz default null)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int from public.script_notices n
  where n.sent_at is null
    and n.skipped_at is null
    and case when n.kind in ('staff_alert', 'marking_alert')
             then n.attempts >= 3 and n.created_at > coalesce(p_now, now()) - interval '6 hours'
             else n.created_at <= coalesce(p_now, now()) - interval '7 days'
                  and n.created_at > coalesce(p_now, now()) - interval '7 days 6 hours'
        end
$$;

-- ---------------------------------------------------------------------------------------------
-- script_family_notices_waiting: as 20261122000001, without the marking alerts (they are not family emails).
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_family_notices_waiting()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_count int;
  v_oldest timestamptz;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select count(*)::int, min(n.created_at) into v_count, v_oldest
  from public.script_notices n
  where n.sent_at is null and n.skipped_at is null and n.kind not in ('staff_alert', 'marking_alert');
  return jsonb_build_object('ok', true, 'count', v_count, 'oldest', v_oldest);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_family_notices_skip: as 20261122000001; staff alerts and marking alerts are not touched.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_family_notices_skip(p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_skipped int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  update public.script_notices set skipped_at = now()
  where sent_at is null and skipped_at is null and kind not in ('staff_alert', 'marking_alert');
  get diagnostics v_skipped = row_count;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'script_family_notices_skipped', 'script_notices', null, v_reason);
  return jsonb_build_object('ok', true, 'skipped', v_skipped);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges. (Functions replaced above keep theirs.)
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.marking_script_lock(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_alert_raise(uuid, text, uuid, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_script_hold(uuid, text, text, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_on_page_picture() from public, anon, authenticated, service_role;
revoke execute on function public.marking_on_set_aside() from public, anon, authenticated, service_role;
revoke execute on function public.marking_script_take_back_as(uuid, uuid, text) from public, anon, authenticated, service_role;
revoke execute on function public.marking_units_refresh(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_alert_can_release(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_mask_key(uuid, int, uuid, int) from public, anon, authenticated, service_role;
revoke execute on function public.marking_picture_inputs() from public, anon, authenticated, service_role;
revoke execute on function public.marking_name_visible(uuid, uuid) from public, anon;
revoke execute on function public.marking_script_take_back(uuid, text) from public, anon;
revoke execute on function public.marking_script_hand_back(uuid, text) from public, anon;
revoke execute on function public.marking_alerts_list(uuid, text) from public, anon;
revoke execute on function public.marking_alert_release(uuid, text) from public, anon;
revoke execute on function public.marking_alert_note(uuid, text) from public, anon;
revoke execute on function public.marking_alerts_release_all(uuid, text) from public, anon;
grant execute on function public.marking_name_visible(uuid, uuid) to authenticated;
grant execute on function public.marking_script_take_back(uuid, text) to authenticated;
grant execute on function public.marking_script_hand_back(uuid, text) to authenticated;
grant execute on function public.marking_alerts_list(uuid, text) to authenticated;
grant execute on function public.marking_alert_release(uuid, text) to authenticated;
grant execute on function public.marking_alert_note(uuid, text) to authenticated;
grant execute on function public.marking_alerts_release_all(uuid, text) to authenticated;
