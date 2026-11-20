-- Phase 2 Task 10: the exception queue.
--
-- Anything the processing server or a family left uncertain is an open row of script_exceptions. Staff admins see
-- them in one queue (script_exceptions_list) and resolve each with a reason: assign the page to a candidate's page,
-- mark it blank, keep the page already chosen over a duplicate, reject it (at home the submission is rejected and the
-- family emailed), confirm it (a family's placement, a page sent as it is, a picture of poor quality), dismiss
-- missing pages (left blank), or decide on a late home script (script_late_decide). Every resolution records who,
-- when and the reason on the exception and in audit_log (the reason is 3 to 300 characters; confirming needs none).
-- A second resolution of the same exception answers conflict with who resolved it and when.
--
-- The original stays untouched: a resolution never changes or deletes a page row (script_pages). A correction is a
-- new script version (script_versions with created_by and a staff reason; earlier versions are kept), the
-- exception's resolution, and, for staff hidden areas, rows of script_page_hidden_areas.
--
-- Staff hidden areas (ruling R17): rectangles that staff draw over a candidate's name on one page's full picture
-- (fractions of the stored picture, from its top left, as Task 1's paper areas). They are how a page whose layout
-- was unexpected (no marking picture) is made ready: hide the name, then confirm. Task 11 applies them, with the
-- nominal name band, when it re-makes marking pictures; here they are stored, and confirming or assigning a page with
-- no marking picture (or with staff areas) queues a remask job for its file.
--
-- After a resolution the scripts concerned are worked out again (script_resolution_settle): a script whose pages are
-- one paper version again loses its open mixed_versions exception; a centre script is checked by Task 9's
-- scan_booking_complete once the centre's scans were declared all in (scan_centre_complete ran for its centre, or
-- the booking already has a missing_pages exception), so pages are never called missing while scans still arrive;
-- otherwise script_evaluate.
--
-- Lock order (as 052): booking (advisory, in uuid order), then the exception and page rows, home submission, script.

-- ---------------------------------------------------------------------------------------------
-- Schema additions.
-- ---------------------------------------------------------------------------------------------

-- Why staff rejected a home submission: shown to the family ("Rejected", with the reason from staff).
alter table public.home_submissions
  add column rejected_reason text
  constraint home_submissions_rejected_reason_length check (rejected_reason is null or char_length(rejected_reason) between 3 and 300);

create table public.script_page_hidden_areas (
  id uuid primary key default gen_random_uuid(),
  -- A rerun deletes the page rows nothing names any more; their areas go with them.
  page_id uuid not null references public.script_pages (id) on delete cascade,
  x numeric not null,
  y numeric not null,
  w numeric not null,
  h numeric not null,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint script_page_hidden_areas_inside_page check (x >= 0 and y >= 0 and w > 0 and h > 0 and x + w <= 1 and y + h <= 1)
);
create index script_page_hidden_areas_page_idx on public.script_page_hidden_areas (page_id);

alter table public.script_page_hidden_areas enable row level security;
revoke all on public.script_page_hidden_areas from anon, authenticated;
grant select on public.script_page_hidden_areas to authenticated;
create policy script_page_hidden_areas_select on public.script_page_hidden_areas for select to authenticated
using ((select public.is_staff_admin()));

-- script_centre_checked looks for a centre's completion here.
create index audit_log_centre_completed_idx on public.audit_log (target_id) where action = 'scan_centre_completed';

-- ---------------------------------------------------------------------------------------------
-- Helpers (internal).
-- ---------------------------------------------------------------------------------------------

-- A staff reason: trimmed, 3 to 300 characters; null when it is not one.
create function public.script_resolution_reason(p_reason text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when char_length(btrim(coalesce(p_reason, ''))) between 3 and 300 then btrim(p_reason) end
$$;

-- The answer to a second resolution: who resolved the exception (display name), when and how.
create function public.script_exception_conflict(p_exception uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('ok', false, 'code', 'conflict',
    'resolved_by', (select nullif(btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), '')
                    from public.profiles p where p.id = e.resolved_by),
    'resolved_at', e.resolved_at,
    'resolution', e.resolution)
  from public.script_exceptions e where e.id = p_exception
$$;

-- Takes the advisory lock of each booking (the key of 052), in uuid order.
create function public.script_bookings_lock(p_bookings uuid[])
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_b uuid;
begin
  for v_b in select distinct b from unnest(coalesce(p_bookings, '{}'::uuid[])) b where b is not null order by 1 loop
    perform pg_advisory_xact_lock(hashtextextended('script_booking:' || v_b::text, 0));
  end loop;
end;
$$;

-- The bookings a page concerns: the one it was matched to and those whose current script shows it.
create function public.script_page_bookings(p_page uuid)
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(distinct t.b) filter (where t.b is not null), '{}'::uuid[])
  from (
    select p.booking_id as b from public.script_pages p where p.id = p_page
    union all
    select s.booking_id from public.script_page_links l join public.scripts s on s.id = l.script_id and l.version = s.version
    where l.page_id = p_page
  ) t
$$;

-- Whether a centre booking has been checked for completeness: its centre's scans were declared all in
-- (scan_centre_complete), or it has a missing_pages exception. Before that, pages are still arriving.
create function public.script_centre_checked(p_booking uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.bookings b
                 join public.audit_log a on a.target_id = b.centre_id and a.action = 'scan_centre_completed' and a.target_type = 'exam_centre'
                 where b.id = p_booking)
      or exists (select 1 from public.script_exceptions e where e.booking_id = p_booking and e.kind = 'missing_pages')
$$;

-- Works a booking's script out again after a resolution (the caller holds the booking's lock). An open
-- mixed_versions exception closes (one_version) once the current pages are of one paper version. A centre booking
-- that has been checked is checked again (scan_booking_complete, which also evaluates the script); any other script
-- is evaluated (script_evaluate).
create function public.script_resolution_settle(p_booking uuid, p_actor uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_b public.bookings%rowtype;
  v_x public.scripts%rowtype;
begin
  if p_booking is null then
    return;
  end if;
  select * into v_b from public.bookings b where b.id = p_booking;
  select * into v_x from public.scripts s where s.booking_id = p_booking;
  if v_x.id is not null then
    update public.script_exceptions e
    set state = 'resolved', resolved_by = p_actor, resolved_at = now(), resolution = 'one_version'
    where e.kind = 'mixed_versions' and e.state = 'open'
      and (e.script_id = v_x.id or (e.script_id is null and e.booking_id = p_booking))
      and (select count(distinct c.paper_id)
           from public.script_page_links l
           join public.script_pages p on p.id = l.page_id
           join public.paper_copies c on c.id = p.copy_id
           where l.script_id = v_x.id and l.version = v_x.version) <= 1;
  end if;
  if v_b.sitting = 'centre' and (v_x.id is null or v_x.source = 'centre') and public.script_centre_checked(p_booking) then
    perform public.scan_booking_complete(p_booking);
  elsif v_x.id is not null then
    perform public.script_evaluate(v_x.id);
  end if;
end;
$$;

-- Writes the next version of a script with these links as a staff correction (who made it, and why), and raises
-- mixed_versions when its pages now come from two paper versions. True when a version was written.
create function public.script_links_write(p_script uuid, p_links jsonb, p_reason text, p_actor uuid, p_now timestamptz)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.script_version_write(p_script, p_links, null, null, p_reason, p_now) then
    return false;
  end if;
  update public.script_versions v set created_by = p_actor
  where v.script_id = p_script and v.version = (select s.version from public.scripts s where s.id = p_script);
  perform public.script_raise_mixed(p_script, null);
  return true;
end;
$$;

-- Resolves an exception as the actor, now, with how and why, and audits it as p_action.
create function public.script_exception_close(p_id uuid, p_resolution text, p_reason text, p_actor uuid, p_now timestamptz, p_action text)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.script_exceptions
  set state = 'resolved', resolved_by = p_actor, resolved_at = p_now, resolution = p_resolution, reason = p_reason
  where id = p_id;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (p_actor, p_action, 'script_exception', p_id, p_reason);
$$;

-- Sets a page aside: each script that shows it now gets a version without it, and its other open exceptions close
-- with it (set_aside). The caller holds the locks of the page's bookings (script_page_bookings).
create function public.script_page_set_aside(p_page uuid, p_actor uuid, p_now timestamptz)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s uuid;
begin
  for v_s in
    select distinct l.script_id from public.script_page_links l join public.scripts s on s.id = l.script_id and l.version = s.version
    where l.page_id = p_page order by 1
  loop
    perform public.script_links_write(v_s, (
      select coalesce(jsonb_object_agg(l.copy_page::text, l.page_id), '{}'::jsonb)
      from public.script_page_links l join public.scripts s on s.id = l.script_id and l.version = s.version
      where l.script_id = v_s and l.page_id <> p_page), 'staff_set_aside', p_actor, p_now);
  end loop;
  update public.script_exceptions e
  set state = 'resolved', resolved_by = p_actor, resolved_at = p_now, resolution = 'set_aside'
  where e.page_id = p_page and e.state = 'open';
end;
$$;

-- Rejects home submissions of a booking (the caller holds its lock). Each becomes rejected with the reason (Task 7's
-- trigger emails the family), the open exceptions about their files close (submission_rejected), and the script stops
-- showing their pages: it goes back to the links of the version before the first of them, with the pages from
-- elsewhere that the current version shows (a staff correction) kept on top. When the submission that now counts
-- (the latest handed in and not rejected) was on time, or none does, the script is no longer late and its open late
-- exception closes.
create function public.script_home_reject(p_booking uuid, p_subs uuid[], p_reason text, p_actor uuid, p_now timestamptz)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_x public.scripts%rowtype;
  v_first int;
  v_links jsonb;
begin
  perform 1 from public.home_submissions s where s.id = any (p_subs) order by s.id for update;
  update public.home_submissions s set state = 'rejected', rejected_reason = p_reason
  where s.id = any (p_subs) and s.booking_id = p_booking and s.state not in ('draft', 'rejected');
  update public.script_exceptions e
  set state = 'resolved', resolved_by = p_actor, resolved_at = p_now, resolution = 'submission_rejected'
  where e.state = 'open' and e.upload_id in (select u.id from public.script_uploads u where u.submission_id = any (p_subs));

  select * into v_x from public.scripts s where s.booking_id = p_booking for update;
  if v_x.id is not null then
    select min(v.version) into v_first from public.script_versions v where v.script_id = v_x.id and v.submission_id = any (p_subs);
    select coalesce(jsonb_object_agg(l.copy_page::text, l.page_id), '{}'::jsonb) into v_links
    from public.script_page_links l
    join public.script_pages p on p.id = l.page_id
    join public.script_uploads u on u.id = p.upload_id
    where l.script_id = v_x.id and l.version = v_x.version and not coalesce(u.submission_id = any (p_subs), false);
    if v_first is not null then
      v_links := (select coalesce(jsonb_object_agg(l.copy_page::text, l.page_id), '{}'::jsonb)
                  from public.script_page_links l where l.script_id = v_x.id and l.version = v_first - 1) || v_links;
    end if;
    perform public.script_links_write(v_x.id, v_links, 'submission_rejected', p_actor, p_now);
  end if;

  if not coalesce((select s.late from public.home_submissions s
                   where s.booking_id = p_booking and s.state not in ('draft', 'rejected') order by s.seq desc limit 1), false) then
    update public.scripts set late = false where booking_id = p_booking and late;
    update public.script_exceptions e
    set state = 'resolved', resolved_by = p_actor, resolved_at = p_now, resolution = 'submission_rejected'
    where e.booking_id = p_booking and e.kind = 'late' and e.state = 'open';
  end if;
end;
$$;

-- Queues a remask job for a page's file when the page has no marking picture yet or carries staff hidden areas, so
-- its marking picture is made (Task 11) with them. One waiting remask job per file is enough.
create function public.script_page_remask(p_page uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.processing_jobs (upload_id, kind)
  select p.upload_id, 'remask' from public.script_pages p
  where p.id = p_page
    and (p.marking_path is null or exists (select 1 from public.script_page_hidden_areas a where a.page_id = p.id))
  on conflict do nothing
$$;

-- ---------------------------------------------------------------------------------------------
-- What the queue shows (internal builders).
-- ---------------------------------------------------------------------------------------------

-- A booking as the queue names it: the candidate's name and index number (staff only), sitting and status.
create function public.script_booking_json(p_booking uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('id', b.id, 'sitting', b.sitting, 'status', b.status, 'centre_id', b.centre_id,
    'name', nullif(btrim(coalesce(pr.first_name, '') || ' ' || coalesce(pr.last_name, '')), ''),
    'index_number', d.index_number)
  from public.bookings b
  left join public.profiles pr on pr.id = b.student_id
  left join public.student_details d on d.profile_id = b.student_id
  where b.id = p_booking
$$;

-- A page: where it came from, what the server read, its pictures, its paper version and its staff hidden areas.
create function public.script_page_json(p_page uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('id', p.id, 'upload_id', p.upload_id, 'source_index', p.source_index, 'copy_page', p.copy_page,
    'state', p.state, 'blank', p.blank, 'quality', p.quality, 'rotation', p.rotation, 'full_path', p.full_path,
    'marking_path', p.marking_path, 'placed_after', p.placed_after, 'replaced', p.replaced_at is not null,
    'paper_version', ep.version, 'paper_current', case when ep.id is not null then ep.superseded_at is null end,
    'areas', coalesce((select jsonb_agg(jsonb_build_object('x', a.x, 'y', a.y, 'w', a.w, 'h', a.h) order by a.created_at, a.id)
                       from public.script_page_hidden_areas a where a.page_id = p.id), '[]'::jsonb))
  from public.script_pages p
  left join public.paper_copies c on c.id = p.copy_id
  left join public.exam_papers ep on ep.id = c.paper_id
  where p.id = p_page
$$;

-- One exception as the queue shows it: what the server found (details), the exam, the candidate and script, the
-- page (and the page kept, for a duplicate; the script's pages, for mixed versions and missing pages), the file it
-- came from, the late submission, and how it was resolved.
create function public.script_exception_json(p_exception uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_e.id,
    'kind', p_e.kind,
    'state', p_e.state,
    'created_at', p_e.created_at,
    'details', p_e.details,
    'exam', (select jsonb_build_object('id', e.id, 'title', e.title, 'paper', e.paper, 'code', e.exam_code)
             from public.exams e where e.id = p_e.exam_id),
    'booking', public.script_booking_json(p_e.booking_id),
    'script', (select jsonb_build_object('id', s.id, 'number', s.number, 'state', s.state, 'source', s.source, 'version', s.version,
                        'complete', s.complete, 'late', s.late, 'late_decision', s.late_decision)
               from public.scripts s where s.id = x.script_id),
    'page', public.script_page_json(p_e.page_id),
    'printed_for', (select public.script_booking_json(c.booking_id)
                    from public.script_pages p join public.paper_copies c on c.id = p.copy_id where p.id = p_e.page_id),
    'kept_page', case when p_e.kind = 'duplicate' then public.script_page_json((p_e.details ->> 'kept_page_id')::uuid) end,
    'linked_pages', case when p_e.kind in ('mixed_versions', 'missing_pages') then (
      select coalesce(jsonb_agg(jsonb_build_object('copy_page', l.copy_page, 'page', public.script_page_json(l.page_id)) order by l.copy_page), '[]'::jsonb)
      from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version
      where s.id = x.script_id) end,
    'upload', (select jsonb_build_object('id', u.id, 'kind', u.kind, 'state', u.state,
                        'source', case when u.batch_id is not null then 'centre' else 'home' end,
                        'position', u.position, 'batch_number', sb.number,
                        'submission_id', u.submission_id, 'submission_seq', hs.seq, 'submission_state', hs.state)
               from public.script_uploads u
               left join public.scan_batches sb on sb.id = u.batch_id
               left join public.home_submissions hs on hs.id = u.submission_id
               where u.id = coalesce(p_e.upload_id, (select p.upload_id from public.script_pages p where p.id = p_e.page_id))),
    'submission', case when p_e.kind = 'late' then (
      select jsonb_build_object('id', hs.id, 'seq', hs.seq, 'state', hs.state, 'late', hs.late, 'submitted_at', hs.submitted_at)
      from public.home_submissions hs where hs.id = (p_e.details ->> 'submission_id')::uuid) end,
    'resolved', case when p_e.state = 'resolved' then jsonb_build_object(
      'by', (select nullif(btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), '') from public.profiles p where p.id = p_e.resolved_by),
      'at', p_e.resolved_at, 'resolution', p_e.resolution, 'reason', p_e.reason) end)
  from public.script_exceptions p_e
  cross join lateral (select coalesce(p_e.script_id, (select s.id from public.scripts s where s.booking_id = p_e.booking_id)) as script_id) x
  where p_e.id = p_exception
$$;

-- ---------------------------------------------------------------------------------------------
-- script_exceptions_list: the queue for staff admins. Filters: exam, kind, and p_state open (newest first) or
-- resolved (most recently resolved first). At most 200 items; more says whether there were others.
-- ---------------------------------------------------------------------------------------------
create function public.script_exceptions_list(p_exam uuid default null, p_kind public.exception_kind default null, p_state text default 'open')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_state text := coalesce(p_state, 'open');
  v_items jsonb;
  v_n int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if v_state not in ('open', 'resolved') then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select coalesce(jsonb_agg(public.script_exception_json(t.id) order by t.at desc, t.id desc) filter (where t.n <= 200), '[]'::jsonb),
         count(*)
  into v_items, v_n
  from (
    select e.id, case when v_state = 'resolved' then coalesce(e.resolved_at, e.created_at) else e.created_at end as at,
           row_number() over (order by case when v_state = 'resolved' then coalesce(e.resolved_at, e.created_at) else e.created_at end desc, e.id desc) as n
    from public.script_exceptions e
    where e.state = v_state and (p_exam is null or e.exam_id = p_exam) and (p_kind is null or e.kind = p_kind)
    order by 2 desc, e.id desc
    limit 201
  ) t;
  return jsonb_build_object('ok', true, 'items', v_items, 'more', v_n > 200);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_exception_assign: puts the exception's page into a candidate's script at copy page p_copy_page (a new
-- version; a page the script showed there is replaced, and named in the answer). For a page with no code, an
-- unknown or unexpected code, a family-placed page, or a duplicate ("use this page instead"). The candidate must be
-- booked (paid or cancel requested) for the same exam and the same sitting as the file (a scanned page goes to a
-- centre candidate marked present or late, a home page to a home candidate), p_copy_page within their copy, and their
-- script not past verification. A candidate with no script yet gets one.
-- ---------------------------------------------------------------------------------------------
create function public.script_exception_assign(p_exception uuid, p_booking uuid, p_copy_page int, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := now();
  v_reason text := public.script_resolution_reason(p_reason);
  v_e public.script_exceptions%rowtype;
  v_p public.script_pages%rowtype;
  v_up public.script_uploads%rowtype;
  v_b public.bookings%rowtype;
  v_x public.scripts%rowtype;
  v_home boolean;
  v_pages int;
  v_links jsonb;
  v_old uuid;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exception is null or p_booking is null or p_copy_page is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  select * into v_e from public.script_exceptions e where e.id = p_exception;
  select * into v_b from public.bookings b where b.id = p_booking;
  if v_e.id is null or v_b.id is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  perform public.script_bookings_lock(array[v_e.booking_id, v_b.id] || public.script_page_bookings(v_e.page_id));
  select * into v_e from public.script_exceptions e where e.id = p_exception for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_e.state <> 'open' then
    return public.script_exception_conflict(v_e.id);
  end if;
  if v_e.kind not in ('no_code', 'unknown_code', 'not_expected', 'uncoded_family_page', 'duplicate') or v_e.page_id is null then
    return jsonb_build_object('ok', false, 'code', 'wrong_kind');
  end if;
  select * into v_p from public.script_pages p where p.id = v_e.page_id for update;
  if v_p.replaced_at is not null then
    return jsonb_build_object('ok', false, 'code', 'page_replaced');
  end if;
  select * into v_up from public.script_uploads u where u.id = v_p.upload_id;
  v_home := v_up.submission_id is not null;

  if v_b.exam_id <> v_e.exam_id then
    return jsonb_build_object('ok', false, 'code', 'other_exam');
  end if;
  if v_b.status not in ('paid', 'cancel_requested') then
    return jsonb_build_object('ok', false, 'code', 'booking_not_active');
  end if;
  if v_b.sitting <> (case when v_home then 'home' else 'centre' end)::public.sitting_mode then
    return jsonb_build_object('ok', false, 'code', 'wrong_sitting');
  end if;
  if not v_home and not exists (select 1 from public.attendance a
                                where a.exam_id = v_b.exam_id and a.student_id = v_b.student_id and a.status in ('present', 'late')) then
    return jsonb_build_object('ok', false, 'code', 'not_present');
  end if;
  select c.page_count into v_pages from public.paper_copies c where c.booking_id = v_b.id order by c.created_at desc, c.id limit 1;
  if v_pages is null or p_copy_page not between 1 and v_pages then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if exists (select 1 from public.script_page_links l join public.scripts s on s.id = l.script_id and l.version = s.version
             where l.page_id = v_p.id and s.booking_id <> v_b.id) then
    return jsonb_build_object('ok', false, 'code', 'in_other_script');
  end if;

  select * into v_x from public.scripts s where s.booking_id = v_b.id for update;
  if v_x.id is not null and v_x.state not in ('receiving', 'checking', 'needs_attention', 'verified') then
    return jsonb_build_object('ok', false, 'code', 'script_locked');
  end if;
  if v_x.id is null then
    v_x := public.script_create(v_b.id, (case when v_home then 'home' else 'centre' end)::public.script_source, v_now);
  end if;
  v_links := public.script_links(v_x.id);
  v_old := (v_links ->> p_copy_page::text)::uuid;
  v_links := coalesce((select jsonb_object_agg(t.k, t.v) from jsonb_each_text(v_links) t(k, v) where t.v <> v_p.id::text), '{}'::jsonb)
             || jsonb_build_object(p_copy_page::text, v_p.id);
  perform public.script_links_write(v_x.id, v_links, 'staff_assign', v_actor, v_now);
  select * into v_x from public.scripts s where s.id = v_x.id;

  update public.script_exceptions
  set details = details || jsonb_build_object('assigned', jsonb_build_object(
        'booking_id', v_b.id, 'copy_page', p_copy_page, 'script_id', v_x.id, 'version', v_x.version)),
      booking_id = coalesce(booking_id, v_b.id),
      script_id = coalesce(script_id, v_x.id)
  where id = v_e.id;
  perform public.script_exception_close(v_e.id, 'assigned', v_reason, v_actor, v_now, 'script_exception_assigned');
  perform public.script_page_remask(v_p.id);
  perform public.script_resolution_settle(v_b.id, v_actor);
  if v_e.booking_id is distinct from v_b.id then
    perform public.script_resolution_settle(v_e.booking_id, v_actor);
  end if;
  return jsonb_build_object('ok', true, 'exception_id', v_e.id, 'resolution', 'assigned', 'script_id', v_x.id,
    'script_number', v_x.number, 'version', v_x.version,
    'replaced_page_id', case when v_old is distinct from v_p.id then v_old end);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_exception_blank: the page is a blank sheet (a page with no code, an unknown, unexpected or other exam's
-- code, or a family-placed page). It is set aside (script_page_set_aside).
-- ---------------------------------------------------------------------------------------------
create function public.script_exception_blank(p_exception uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := now();
  v_reason text := public.script_resolution_reason(p_reason);
  v_e public.script_exceptions%rowtype;
  v_bookings uuid[];
  v_b uuid;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exception is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  select * into v_e from public.script_exceptions e where e.id = p_exception;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  v_bookings := array(select distinct b from unnest(array[v_e.booking_id] || public.script_page_bookings(v_e.page_id)) b where b is not null order by 1);
  perform public.script_bookings_lock(v_bookings);
  select * into v_e from public.script_exceptions e where e.id = p_exception for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_e.state <> 'open' then
    return public.script_exception_conflict(v_e.id);
  end if;
  if v_e.kind not in ('no_code', 'unknown_code', 'other_exam', 'not_expected', 'uncoded_family_page') or v_e.page_id is null then
    return jsonb_build_object('ok', false, 'code', 'wrong_kind');
  end if;

  perform public.script_exception_close(v_e.id, 'blank', v_reason, v_actor, v_now, 'script_exception_blank');
  perform public.script_page_set_aside(v_e.page_id, v_actor, v_now);
  foreach v_b in array v_bookings loop
    perform public.script_resolution_settle(v_b, v_actor);
  end loop;
  return jsonb_build_object('ok', true, 'exception_id', v_e.id, 'resolution', 'blank');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_exception_keep_existing: a duplicate is left set aside; the page chosen for that copy page stays.
-- ---------------------------------------------------------------------------------------------
create function public.script_exception_keep_existing(p_exception uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := now();
  v_reason text := public.script_resolution_reason(p_reason);
  v_e public.script_exceptions%rowtype;
  v_bookings uuid[];
  v_b uuid;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exception is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  select * into v_e from public.script_exceptions e where e.id = p_exception;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  v_bookings := array(select distinct b from unnest(array[v_e.booking_id] || public.script_page_bookings(v_e.page_id)) b where b is not null order by 1);
  perform public.script_bookings_lock(v_bookings);
  select * into v_e from public.script_exceptions e where e.id = p_exception for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_e.state <> 'open' then
    return public.script_exception_conflict(v_e.id);
  end if;
  if v_e.kind <> 'duplicate' then
    return jsonb_build_object('ok', false, 'code', 'wrong_kind');
  end if;

  perform public.script_exception_close(v_e.id, 'kept', v_reason, v_actor, v_now, 'script_exception_kept');
  foreach v_b in array v_bookings loop
    perform public.script_resolution_settle(v_b, v_actor);
  end loop;
  return jsonb_build_object('ok', true, 'exception_id', v_e.id, 'resolution', 'kept');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_exception_reject: the page (or file) is not accepted. At home the submission is rejected (the family is
-- emailed with the reason) when it is the latest handed in, or the page is one the script shows now (then the latest
-- submission, which counts it, is rejected): script_home_reject. An older submission already replaced is left as it
-- is. A scanned page is set aside, out of any script that showed it. For pages with no code, unknown, unexpected or
-- other exam's codes, family-placed pages, poor quality, and files that could not be processed.
-- ---------------------------------------------------------------------------------------------
create function public.script_exception_reject(p_exception uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := now();
  v_reason text := public.script_resolution_reason(p_reason);
  v_e public.script_exceptions%rowtype;
  v_sub public.home_submissions%rowtype;
  v_latest public.home_submissions%rowtype;
  v_bookings uuid[];
  v_b uuid;
  v_rejected boolean := false;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exception is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  select * into v_e from public.script_exceptions e where e.id = p_exception;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select s.* into v_sub from public.home_submissions s join public.script_uploads u on u.submission_id = s.id
  where u.id = coalesce(v_e.upload_id, (select p.upload_id from public.script_pages p where p.id = v_e.page_id));

  v_bookings := array(select distinct b from unnest(array[v_e.booking_id, v_sub.booking_id] || public.script_page_bookings(v_e.page_id)) b where b is not null order by 1);
  perform public.script_bookings_lock(v_bookings);
  select * into v_e from public.script_exceptions e where e.id = p_exception for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_e.state <> 'open' then
    return public.script_exception_conflict(v_e.id);
  end if;
  if v_e.kind not in ('no_code', 'unknown_code', 'other_exam', 'not_expected', 'uncoded_family_page', 'poor_quality', 'processing_failed') then
    return jsonb_build_object('ok', false, 'code', 'wrong_kind');
  end if;

  perform public.script_exception_close(v_e.id, 'rejected', v_reason, v_actor, v_now, 'script_exception_rejected');
  if v_sub.id is not null then
    v_latest := public.home_submission_latest(v_sub.booking_id);
    if v_latest.state not in ('draft', 'rejected')
       and (v_latest.id = v_sub.id
            or exists (select 1 from public.script_page_links l join public.scripts s on s.id = l.script_id and l.version = s.version
                       where s.booking_id = v_sub.booking_id and l.page_id = v_e.page_id)) then
      perform public.script_home_reject(v_sub.booking_id, array[v_latest.id], v_reason, v_actor, v_now);
      v_rejected := true;
    end if;
  elsif v_e.page_id is not null then
    perform public.script_page_set_aside(v_e.page_id, v_actor, v_now);
  end if;
  foreach v_b in array v_bookings loop
    perform public.script_resolution_settle(v_b, v_actor);
  end loop;
  return jsonb_build_object('ok', true, 'exception_id', v_e.id, 'resolution', 'rejected', 'submission_rejected', v_rejected);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_exception_confirm: staff accept the page as it is: a family's placement of a page with no code, a page of
-- poor quality (or sent as it is; hide the name first when its layout was unexpected), a reported visible name once
-- hidden, a file that could not be processed (noted), or mixed versions once the script shows one version again
-- (still_mixed before). A page with no marking picture, or with staff hidden areas, gets a remask job. The reason is
-- optional (3 to 300 characters when given).
-- ---------------------------------------------------------------------------------------------
create function public.script_exception_confirm(p_exception uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := now();
  v_given text := nullif(btrim(coalesce(p_reason, '')), '');
  v_reason text := public.script_resolution_reason(p_reason);
  v_e public.script_exceptions%rowtype;
  v_bookings uuid[];
  v_b uuid;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exception is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_given is not null and v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  select * into v_e from public.script_exceptions e where e.id = p_exception;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  v_bookings := array(select distinct b from unnest(array[v_e.booking_id] || public.script_page_bookings(v_e.page_id)) b where b is not null order by 1);
  perform public.script_bookings_lock(v_bookings);
  select * into v_e from public.script_exceptions e where e.id = p_exception for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_e.state <> 'open' then
    return public.script_exception_conflict(v_e.id);
  end if;
  if v_e.kind not in ('uncoded_family_page', 'poor_quality', 'mixed_versions', 'processing_failed', 'name_visible') then
    return jsonb_build_object('ok', false, 'code', 'wrong_kind');
  end if;
  if v_e.kind = 'mixed_versions' and (
       select count(distinct c.paper_id)
       from public.scripts s
       join public.script_page_links l on l.script_id = s.id and l.version = s.version
       join public.script_pages p on p.id = l.page_id
       join public.paper_copies c on c.id = p.copy_id
       where s.id = coalesce(v_e.script_id, (select x.id from public.scripts x where x.booking_id = v_e.booking_id))) > 1 then
    return jsonb_build_object('ok', false, 'code', 'still_mixed');
  end if;

  perform public.script_exception_close(v_e.id, 'confirmed', v_reason, v_actor, v_now, 'script_exception_confirmed');
  if v_e.page_id is not null then
    perform public.script_page_remask(v_e.page_id);
  end if;
  foreach v_b in array v_bookings loop
    perform public.script_resolution_settle(v_b, v_actor);
  end loop;
  return jsonb_build_object('ok', true, 'exception_id', v_e.id, 'resolution', 'confirmed');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_exception_dismiss_missing: staff confirm that some missing answer pages were left blank. p_pages (1 to 100,
-- each listed as missing) join the exception's details.dismissed (Task 9 reads them there); with every missing page
-- dismissed the exception is resolved (dismissed), else it stays open. The booking is checked again
-- (scan_booking_complete), which brings the pages still missing up to date.
-- ---------------------------------------------------------------------------------------------
create function public.script_exception_dismiss_missing(p_exception uuid, p_pages int[], p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := now();
  v_reason text := public.script_resolution_reason(p_reason);
  v_e public.script_exceptions%rowtype;
  v_missing int[];
  v_dismissed int[];
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exception is null or p_pages is null or cardinality(p_pages) = 0 or cardinality(p_pages) > 100
     or array_position(p_pages, null) is not null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  select * into v_e from public.script_exceptions e where e.id = p_exception;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  perform public.script_bookings_lock(array[v_e.booking_id]);
  select * into v_e from public.script_exceptions e where e.id = p_exception for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_e.state <> 'open' then
    return public.script_exception_conflict(v_e.id);
  end if;
  if v_e.kind <> 'missing_pages' then
    return jsonb_build_object('ok', false, 'code', 'wrong_kind');
  end if;
  v_missing := array(select x::int from jsonb_array_elements_text(
    case when jsonb_typeof(v_e.details -> 'pages') = 'array' then v_e.details -> 'pages' else '[]'::jsonb end) x);
  if exists (select 1 from unnest(p_pages) n where n <> all (v_missing)) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  v_dismissed := array(select distinct x from unnest(p_pages || array(select d::int from jsonb_array_elements_text(
    case when jsonb_typeof(v_e.details -> 'dismissed') = 'array' then v_e.details -> 'dismissed' else '[]'::jsonb end) d)) x order by x);

  update public.script_exceptions set details = details || jsonb_build_object('dismissed', to_jsonb(v_dismissed)) where id = v_e.id;
  if not exists (select 1 from unnest(v_missing) m where m <> all (v_dismissed)) then
    update public.script_exceptions
    set state = 'resolved', resolved_by = v_actor, resolved_at = v_now, resolution = 'dismissed', reason = v_reason
    where id = v_e.id;
  end if;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'script_missing_dismissed', 'script_exception', v_e.id, v_reason);
  perform public.script_resolution_settle(v_e.booking_id, v_actor);

  select * into v_e from public.script_exceptions e where e.id = v_e.id;
  return jsonb_build_object('ok', true, 'exception_id', v_e.id, 'state', v_e.state, 'dismissed', to_jsonb(v_dismissed),
    'missing', coalesce(v_e.details -> 'pages', '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_late_decide: staff decide whether a late home script is marked. Accept: late_decision accept, the script
-- stays late. Reject: every late submission of the booking still counting is rejected with the reason (the family is
-- emailed; an earlier on-time submission counts again), late_decision reject. Either way the open late exception is
-- resolved (late_accepted or late_rejected) and audited against the script. not_late when the script never had a
-- late exception; conflict (with who decided) when it was decided already.
-- ---------------------------------------------------------------------------------------------
create function public.script_late_decide(p_script uuid, p_accept boolean, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := now();
  v_reason text := public.script_resolution_reason(p_reason);
  v_x public.scripts%rowtype;
  v_e public.script_exceptions%rowtype;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_script is null or p_accept is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  select * into v_x from public.scripts s where s.id = p_script;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  perform public.script_bookings_lock(array[v_x.booking_id]);
  select * into v_e from public.script_exceptions e
  where e.booking_id = v_x.booking_id and e.kind = 'late' and e.state = 'open'
  order by e.created_at desc, e.id limit 1
  for update;
  if v_e.id is null then
    select * into v_e from public.script_exceptions e
    where e.booking_id = v_x.booking_id and e.kind = 'late' order by e.resolved_at desc nulls last, e.created_at desc, e.id limit 1;
    if v_e.id is null then
      return jsonb_build_object('ok', false, 'code', 'not_late');
    end if;
    return public.script_exception_conflict(v_e.id);
  end if;

  update public.script_exceptions
  set state = 'resolved', resolved_by = v_actor, resolved_at = v_now, reason = v_reason,
      resolution = case when p_accept then 'late_accepted' else 'late_rejected' end
  where id = v_e.id;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, case when p_accept then 'script_late_accepted' else 'script_late_rejected' end, 'script', v_x.id, v_reason);
  if not p_accept then
    perform public.script_home_reject(v_x.booking_id,
      array(select s.id from public.home_submissions s
            where s.booking_id = v_x.booking_id and s.late and s.state not in ('draft', 'rejected') order by s.id),
      v_reason, v_actor, v_now);
  end if;
  update public.scripts set late_decision = case when p_accept then 'accept' else 'reject' end where id = v_x.id;
  perform public.script_resolution_settle(v_x.booking_id, v_actor);
  return jsonb_build_object('ok', true, 'script_id', v_x.id, 'late_decision', case when p_accept then 'accept' else 'reject' end);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_page_set_hidden_areas: replaces the staff hidden areas of one page (ruling R17): p_areas =
-- [{"x":..,"y":..,"w":..,"h":..}], fractions of the stored full page picture from its top left, inside the page, at
-- most 20; [] removes them. Audited with the reason. Returns {ok, page_id, areas (how many), changed}.
-- ---------------------------------------------------------------------------------------------
create function public.script_page_set_hidden_areas(p_page uuid, p_areas jsonb, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_p public.script_pages%rowtype;
  v_changed boolean;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_page is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if p_areas is null or jsonb_typeof(p_areas) <> 'array' or jsonb_array_length(p_areas) > 20
     or exists (
       select 1 from jsonb_array_elements(p_areas) e
       where jsonb_typeof(e) <> 'object'
          or jsonb_typeof(e -> 'x') is distinct from 'number'
          or jsonb_typeof(e -> 'y') is distinct from 'number'
          or jsonb_typeof(e -> 'w') is distinct from 'number'
          or jsonb_typeof(e -> 'h') is distinct from 'number'
          or (e ->> 'x')::numeric < 0 or (e ->> 'y')::numeric < 0
          or (e ->> 'w')::numeric <= 0 or (e ->> 'h')::numeric <= 0
          or (e ->> 'x')::numeric + (e ->> 'w')::numeric > 1
          or (e ->> 'y')::numeric + (e ->> 'h')::numeric > 1) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_p from public.script_pages p where p.id = p_page for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_p.replaced_at is not null then
    return jsonb_build_object('ok', false, 'code', 'page_replaced');
  end if;

  v_changed := exists (
    (select a.x, a.y, a.w, a.h from public.script_page_hidden_areas a where a.page_id = v_p.id
     except all
     select (e ->> 'x')::numeric, (e ->> 'y')::numeric, (e ->> 'w')::numeric, (e ->> 'h')::numeric from jsonb_array_elements(p_areas) e)
    union all
    (select (e ->> 'x')::numeric, (e ->> 'y')::numeric, (e ->> 'w')::numeric, (e ->> 'h')::numeric from jsonb_array_elements(p_areas) e
     except all
     select a.x, a.y, a.w, a.h from public.script_page_hidden_areas a where a.page_id = v_p.id));
  delete from public.script_page_hidden_areas where page_id = v_p.id;
  insert into public.script_page_hidden_areas (page_id, x, y, w, h, created_by)
  select v_p.id, (e ->> 'x')::numeric, (e ->> 'y')::numeric, (e ->> 'w')::numeric, (e ->> 'h')::numeric, v_actor
  from jsonb_array_elements(p_areas) with ordinality t(e, n) order by n;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'script_page_hidden_areas_set', 'script_page', v_p.id, v_reason);
  return jsonb_build_object('ok', true, 'page_id', v_p.id, 'areas', jsonb_array_length(p_areas), 'changed', v_changed);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- home_submission_status: as 20261120000054, and the submission now carries rejected_reason, the reason from staff
-- that the family sees with "Rejected".
-- ---------------------------------------------------------------------------------------------
create or replace function public.home_submission_status(p_booking uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_b public.bookings%rowtype;
  v_code text;
  v_s public.home_submissions%rowtype;
  v_d public.home_submissions%rowtype;
  v_x public.scripts%rowtype;
  v_linked int[];
  v_files jsonb;
  v_settled boolean;
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

  v_s := public.home_submission_latest(v_b.id);
  select * into v_d from public.home_submissions s where s.booking_id = v_b.id and s.state = 'draft';
  select * into v_x from public.scripts s where s.booking_id = v_b.id;
  select coalesce(array_agg(l.copy_page order by l.copy_page), '{}') into v_linked
  from public.script_page_links l where l.script_id = v_x.id and l.version = v_x.version;
  select coalesce(jsonb_object_agg(f.id::text, f.n), '{}') into v_files
  from (select u.id, row_number() over (order by u.position nulls last, u.created_at, u.id) as n
        from public.script_uploads u where u.submission_id = v_s.id and u.state <> 'discarded') f;
  v_settled := coalesce(v_s.state in ('needs_attention', 'received'), false);

  return jsonb_build_object(
    'ok', true,
    'submission', case when v_s.id is not null then jsonb_build_object('id', v_s.id, 'seq', v_s.seq, 'state', v_s.state,
      'late', v_s.late, 'submitted_at', v_s.submitted_at, 'checked_at', v_s.checked_at, 'replaces_all', v_s.replaces_all,
      'rejected_reason', case when v_s.state = 'rejected' then v_s.rejected_reason end) end,
    'pages', (
      select coalesce(jsonb_agg(jsonb_build_object('page_id', p.id, 'copy_page', p.copy_page, 'state', p.state,
               'flags', coalesce(p.quality -> 'flags', '[]'::jsonb), 'upload_id', p.upload_id, 'source_index', p.source_index,
               'file_number', (v_files ->> p.upload_id::text)::int)
             order by (v_files ->> p.upload_id::text)::int, p.source_index), '[]'::jsonb)
      from public.script_pages p
      where v_files ? p.upload_id::text and p.replaced_at is null),
    'missing', case when v_settled then to_jsonb(public.home_missing_pages(v_s.id, true)) else '[]'::jsonb end,
    'retake', case when v_settled then (
      select coalesce(jsonb_agg(jsonb_build_object('page_id', p.id, 'copy_page', l.copy_page,
               'flags', coalesce(p.quality -> 'flags', '[]'::jsonb)) order by l.copy_page), '[]'::jsonb)
      from public.script_page_links l
      join public.script_pages p on p.id = l.page_id
      where l.script_id = v_x.id and l.version = v_x.version
        and public.script_page_is_answer(p.copy_id, p.copy_page)
        and public.script_page_poor(p.quality, p.marking_path, true)
        and not exists (select 1 from public.script_exceptions e where e.page_id = p.id and e.kind = 'poor_quality'))
      else '[]'::jsonb end,
    'unplaced', case when v_settled then (
      select coalesce(jsonb_agg(jsonb_build_object('page_id', p.id, 'upload_id', p.upload_id, 'source_index', p.source_index,
               'file_number', (v_files ->> p.upload_id::text)::int)
             order by (v_files ->> p.upload_id::text)::int, p.source_index), '[]'::jsonb)
      from public.script_pages p
      where v_files ? p.upload_id::text and p.replaced_at is null and p.state = 'unmatched' and p.placed_after is null)
      else '[]'::jsonb end,
    'failed', (
      select coalesce(jsonb_agg((v_files ->> u.id::text)::int order by (v_files ->> u.id::text)::int), '[]'::jsonb)
      from public.script_uploads u where v_files ? u.id::text and u.state = 'failed'),
    'blank', case when v_s.id is not null then
      to_jsonb(array(select x from unnest(v_s.blank_confirmed) x where x <> all (v_linked) order by x)) else '[]'::jsonb end,
    'script', case when v_x.id is not null then jsonb_build_object('number', v_x.number, 'state', v_x.state,
      'pages', to_jsonb(v_linked)) end,
    'copy_pages', (select c.page_count from public.paper_copies c where c.booking_id = v_b.id order by c.created_at desc, c.id limit 1),
    'draft', case when v_d.id is not null then jsonb_build_object('id', v_d.id, 'seq', v_d.seq, 'replaces_all', v_d.replaces_all,
      'uploads', (
        select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'kind', u.kind, 'mime', u.mime, 'byte_size', u.byte_size,
                 'state', u.state, 'position', u.position, 'storage_path', u.storage_path, 'mine', u.uploaded_by = v_actor)
               order by u.position nulls last, u.created_at, u.id), '[]'::jsonb)
        from public.script_uploads u where u.submission_id = v_d.id and u.state <> 'discarded')) end);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Access: the queue's functions check the caller (staff admins); the helpers are internal.
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.script_resolution_reason(text) from public, anon, authenticated, service_role;
revoke execute on function public.script_exception_conflict(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_bookings_lock(uuid[]) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_bookings(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_centre_checked(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_resolution_settle(uuid, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_links_write(uuid, jsonb, text, uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.script_exception_close(uuid, text, text, uuid, timestamptz, text) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_set_aside(uuid, uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.script_home_reject(uuid, uuid[], text, uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_remask(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_booking_json(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_json(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_exception_json(uuid) from public, anon, authenticated, service_role;

revoke execute on function public.script_exceptions_list(uuid, public.exception_kind, text) from public, anon;
revoke execute on function public.script_exception_assign(uuid, uuid, int, text) from public, anon;
revoke execute on function public.script_exception_blank(uuid, text) from public, anon;
revoke execute on function public.script_exception_keep_existing(uuid, text) from public, anon;
revoke execute on function public.script_exception_reject(uuid, text) from public, anon;
revoke execute on function public.script_exception_confirm(uuid, text) from public, anon;
revoke execute on function public.script_exception_dismiss_missing(uuid, int[], text) from public, anon;
revoke execute on function public.script_late_decide(uuid, boolean, text) from public, anon;
revoke execute on function public.script_page_set_hidden_areas(uuid, jsonb, text) from public, anon;
grant execute on function public.script_exceptions_list(uuid, public.exception_kind, text) to authenticated;
grant execute on function public.script_exception_assign(uuid, uuid, int, text) to authenticated;
grant execute on function public.script_exception_blank(uuid, text) to authenticated;
grant execute on function public.script_exception_keep_existing(uuid, text) to authenticated;
grant execute on function public.script_exception_reject(uuid, text) to authenticated;
grant execute on function public.script_exception_confirm(uuid, text) to authenticated;
grant execute on function public.script_exception_dismiss_missing(uuid, int[], text) to authenticated;
grant execute on function public.script_late_decide(uuid, boolean, text) to authenticated;
grant execute on function public.script_page_set_hidden_areas(uuid, jsonb, text) to authenticated;
