-- Phase 2 Task 10: the exception queue.
--
-- Anything the processing server or a family left uncertain is an open row of script_exceptions. Staff admins see
-- them in one queue (script_exceptions_list) and resolve each with a reason: assign the page to a candidate's page,
-- mark it blank, keep the page already chosen over a duplicate, reject it, confirm it (a family's placement, a page
-- sent as it is, a picture of poor quality), dismiss missing pages (left blank), or decide on a late home script
-- (script_late_decide). Every resolution records who, when and the reason on the exception and in audit_log (the
-- reason is 3 to 300 characters; confirming needs none). Exceptions a resolution closes as a side effect (set_aside,
-- submission_rejected, one_version) carry the same reason and get an audit row each. A second resolution of the same
-- exception answers conflict with who resolved it and when.
--
-- The original stays untouched: a resolution never changes or deletes a page row (script_pages). A correction is a
-- new script version (script_versions with created_by and a staff reason; earlier versions are kept), the
-- exception's resolution, and, for staff hidden areas, rows of script_page_hidden_areas. A page staff rejected, marked
-- blank or set aside is "refused" (script_page_refused): a script that still shows one is never verified, and a home
-- submission whose script shows one is never received (no receipt), whatever put it back.
--
-- Rejecting at home (script_reject_targets): when the script still shows the page, the submission the page came from
-- is rejected, with every later submission that still counts (each builds on it, so the family's latest is rejected
-- too and they hand in again); when the page's own submission is the latest handed in, that one is rejected; a page of
-- an older submission that a later upload already replaced only closes its exception. Rejected submissions stop
-- counting: the script goes back to the version before the first of them, and the family gets one email (for the
-- latest) and sees the reason. A remask failure is not the family's file and cannot be rejected (only noted).
--
-- Late scripts: accepting keeps the late pages. Rejecting rejects the late submissions: an on-time submission counts
-- again if there is one ("the late upload is set aside; the on-time pages are used"); if not, the script is void
-- (state_reason late_rejected), visibly not marked.
--
-- No resolution rewrites a script past verification (script_locked): Phase 3 owns those. (Task 4's
-- script_version_write still lets a scan version such a script, as Task 9 relies on; the refusal is in the staff
-- correction writer script_links_write, with a clean check before each resolution changes anything.)
--
-- Staff hidden areas (ruling R17): rectangles that staff draw over a candidate's name on one page's full picture
-- (fractions of the stored picture, from its top left, as Task 1's paper areas). They are how a page whose layout
-- was unexpected (no marking picture) is made ready: hide the name, then confirm (or say there is no name on it).
-- Task 11 applies them, with the nominal name band, when it re-makes marking pictures; here they are stored, and
-- confirming or assigning a page with no marking picture (or with staff areas) queues a remask job for its file.
--
-- After a resolution the scripts concerned are worked out again (script_resolution_settle): a script whose pages are
-- one paper version again loses its open mixed_versions exception; a centre script is checked by Task 9's
-- scan_booking_complete once the centre's scans were declared all in (scan_centre_complete ran for its centre, or
-- the booking already has a missing_pages exception), so pages are never called missing while scans still arrive;
-- otherwise script_evaluate.
--
-- Lock order (as 052): booking (advisory, in uuid order), then the exception and page rows, home submission, script
-- (script_resolution_lock).

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

-- Locks what resolving this exception changes, in the lock order: the bookings it and its page concern (with
-- p_extra), then the exception row and its page row. Which scripts show the page can change until the page row is
-- locked, so the bookings are worked out again afterwards. Bookings that joined are locked too (an advisory lock
-- taken in a transaction is held until it ends, so the retry adds the missing ones; an inverted order is caught by
-- the deadlock detector); if they changed once more, the answer is null and the caller refuses (conflict, changed).
-- Returns the bookings locked (distinct, no nulls); an exception that is gone gives what was locked so far.
create function public.script_resolution_lock(p_exception uuid, p_extra uuid[])
returns uuid[]
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_page uuid;
  v_want uuid[];
  v_locked uuid[] := '{}';
  v_try int;
begin
  for v_try in 1..3 loop
    select e.page_id,
           array(select distinct b from unnest(array[e.booking_id] || coalesce(p_extra, '{}'::uuid[]) || public.script_page_bookings(e.page_id)) b
                 where b is not null order by 1)
    into v_page, v_want
    from public.script_exceptions e where e.id = p_exception;
    if not found then
      return v_locked;
    end if;
    if v_try > 1 and v_want <@ v_locked then
      return v_locked;
    end if;
    if v_try = 3 then
      return null;
    end if;
    perform public.script_bookings_lock(v_want);
    v_locked := array(select distinct b from unnest(v_locked || v_want) b order by 1);
    perform 1 from public.script_exceptions e where e.id = p_exception for update;
    if v_page is not null then
      perform 1 from public.script_pages p where p.id = v_page for update;
    end if;
  end loop;
  return null;
end;
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

-- A page staff refused: an exception about it was resolved as rejected, blank, set aside or with its submission.
create function public.script_page_refused(p_page uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.script_exceptions e
                 where e.page_id = p_page and e.state = 'resolved'
                   and e.resolution in ('rejected', 'blank', 'set_aside', 'submission_rejected'))
$$;

-- Works a booking's script out again after a resolution (the caller holds the booking's lock). An open
-- mixed_versions exception closes (one_version, with the triggering reason, audited) once the current pages are of
-- one paper version. A centre booking that has been checked is checked again (scan_booking_complete, which also
-- evaluates the script); any other script is evaluated (script_evaluate).
create function public.script_resolution_settle(p_booking uuid, p_actor uuid, p_reason text)
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
    with closed as (
      update public.script_exceptions e
      set state = 'resolved', resolved_by = p_actor, resolved_at = now(), resolution = 'one_version', reason = p_reason
      where e.kind = 'mixed_versions' and e.state = 'open'
        and (e.script_id = v_x.id or (e.script_id is null and e.booking_id = p_booking))
        and (select count(distinct c.paper_id)
             from public.script_page_links l
             join public.script_pages p on p.id = l.page_id
             join public.paper_copies c on c.id = p.copy_id
             where l.script_id = v_x.id and l.version = v_x.version) <= 1
      returning e.id)
    insert into public.audit_log (actor_id, action, target_type, target_id, reason)
    select p_actor, 'script_exception_one_version', 'script_exception', c.id, p_reason from closed c;
  end if;
  if v_b.sitting = 'centre' and (v_x.id is null or v_x.source = 'centre') and public.script_centre_checked(p_booking) then
    perform public.scan_booking_complete(p_booking);
  elsif v_x.id is not null then
    perform public.script_evaluate(v_x.id);
  end if;
end;
$$;

-- Writes the next version of a script with these links as a staff correction (who made it, and why), and raises
-- mixed_versions when its pages now come from two paper versions. True when a version was written. A script past
-- verification is never rewritten here (script_locked; the resolutions check first and answer cleanly).
create function public.script_links_write(p_script uuid, p_links jsonb, p_reason text, p_actor uuid, p_now timestamptz)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.scripts s
             where s.id = p_script and s.state not in ('receiving', 'checking', 'needs_attention', 'verified')) then
    raise exception 'script_locked';
  end if;
  if not public.script_version_write(p_script, p_links, null, null, p_reason, p_now) then
    return false;
  end if;
  update public.script_versions v set created_by = p_actor
  where v.script_id = p_script and v.version = (select s.version from public.scripts s where s.id = p_script);
  perform public.script_raise_mixed(p_script, null);
  return true;
end;
$$;

-- Whether a script that shows this page is past verification (a resolution may not change its pages).
create function public.script_page_locked(p_page uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.script_page_links l join public.scripts s on s.id = l.script_id and l.version = s.version
                 where l.page_id = p_page and s.state not in ('receiving', 'checking', 'needs_attention', 'verified'))
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
-- with it (set_aside, with the reason, audited). The caller holds the locks of the page's bookings.
create function public.script_page_set_aside(p_page uuid, p_actor uuid, p_now timestamptz, p_reason text)
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
  with closed as (
    update public.script_exceptions e
    set state = 'resolved', resolved_by = p_actor, resolved_at = p_now, resolution = 'set_aside', reason = p_reason
    where e.page_id = p_page and e.state = 'open'
    returning e.id)
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  select p_actor, 'script_exception_set_aside', 'script_exception', c.id, p_reason from closed c;
end;
$$;

-- Rejects home submissions of a booking (the caller holds its lock). Each becomes rejected with the reason; Task 7's
-- trigger queues an email per submission, and all but the one for the latest of them are withdrawn (the family
-- follows its latest submission: one email). The open exceptions about their files close (submission_rejected, with
-- the reason, audited), and the script stops showing their pages: it goes back to the links of the version before the
-- first of them, with the pages from elsewhere that the current version shows (a staff correction) kept on top. When
-- the submission that now counts (the latest handed in and not rejected) was on time, or none does, the script is no
-- longer late and its open late exception closes the same way.
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
  v_last uuid;
begin
  perform 1 from public.home_submissions s where s.id = any (p_subs) order by s.id for update;
  select s.id into v_last from public.home_submissions s
  where s.id = any (p_subs) and s.booking_id = p_booking order by s.seq desc limit 1;
  update public.home_submissions s set state = 'rejected', rejected_reason = p_reason
  where s.id = any (p_subs) and s.booking_id = p_booking and s.state not in ('draft', 'rejected');
  delete from public.script_notices n
  where n.kind = 'rejected' and n.sent_at is null and n.claimed_at is null
    and n.submission_id = any (p_subs) and n.submission_id is distinct from v_last;
  with closed as (
    update public.script_exceptions e
    set state = 'resolved', resolved_by = p_actor, resolved_at = p_now, resolution = 'submission_rejected', reason = p_reason
    where e.state = 'open' and e.upload_id in (select u.id from public.script_uploads u where u.submission_id = any (p_subs))
    returning e.id)
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  select p_actor, 'script_exception_submission_rejected', 'script_exception', c.id, p_reason from closed c;

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
    with closed as (
      update public.script_exceptions e
      set state = 'resolved', resolved_by = p_actor, resolved_at = p_now, resolution = 'submission_rejected', reason = p_reason
      where e.booking_id = p_booking and e.kind = 'late' and e.state = 'open'
      returning e.id)
    insert into public.audit_log (actor_id, action, target_type, target_id, reason)
    select p_actor, 'script_exception_submission_rejected', 'script_exception', c.id, p_reason from closed c;
  end if;
end;
$$;

-- The home submissions that rejecting this exception rejects (see the header): none for a scanned page or file, or
-- for a remask failure; when the booking's current script shows the exception's page, the page's own submission and
-- every later one handed in that still counts; else, when its own submission is the latest handed in (and not
-- rejected), that one; else none.
create function public.script_reject_targets(p_exception uuid)
returns uuid[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_e public.script_exceptions%rowtype;
  v_sub public.home_submissions%rowtype;
  v_latest public.home_submissions%rowtype;
begin
  select * into v_e from public.script_exceptions e where e.id = p_exception;
  if not found or (v_e.kind = 'processing_failed' and v_e.details ->> 'kind' = 'remask') then
    return '{}';
  end if;
  select s.* into v_sub from public.home_submissions s join public.script_uploads u on u.submission_id = s.id
  where u.id = coalesce(v_e.upload_id, (select p.upload_id from public.script_pages p where p.id = v_e.page_id));
  if v_sub.id is null then
    return '{}';
  end if;
  if v_e.page_id is not null and exists (
       select 1 from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version
       where s.booking_id = v_sub.booking_id and l.page_id = v_e.page_id) then
    return array(select s.id from public.home_submissions s
                 where s.booking_id = v_sub.booking_id and s.seq >= v_sub.seq and s.state not in ('draft', 'rejected') order by s.seq);
  end if;
  v_latest := public.home_submission_latest(v_sub.booking_id);
  if v_latest.id = v_sub.id and v_sub.state not in ('draft', 'rejected') then
    return array[v_sub.id];
  end if;
  return '{}';
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
-- A refused page never counts: a home submission whose script shows one is not received, and a script that shows
-- one is not verified. (Same as 20261120000052 otherwise.)
-- ---------------------------------------------------------------------------------------------
create or replace function public.home_submission_evaluate(p_submission uuid, p_now timestamptz)
returns public.submission_state
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s public.home_submissions%rowtype;
  v_script uuid;
  v_version int;
  v_papers uuid[];
  v_paper uuid;
  v_state public.submission_state;
begin
  select * into v_s from public.home_submissions s where s.id = p_submission for update;
  if not found then
    return null;
  end if;
  if v_s.state in ('draft', 'rejected') then
    return v_s.state;
  end if;

  if exists (select 1 from public.script_uploads u
             where u.submission_id = v_s.id and u.state in ('pending', 'stored', 'queued', 'processing')) then
    v_state := 'checking';
  else
    select s.id, s.version into v_script, v_version from public.scripts s where s.booking_id = v_s.booking_id;
    select coalesce(array_agg(distinct c.paper_id), '{}') into v_papers
    from public.script_page_links l
    join public.script_pages p on p.id = l.page_id
    join public.paper_copies c on c.id = p.copy_id
    where l.script_id = v_script and l.version = v_version;
    if cardinality(v_papers) = 1 then
      v_paper := v_papers[1];
    elsif cardinality(v_papers) = 0 then
      select c.paper_id into v_paper from public.paper_copies c
      where c.booking_id = v_s.booking_id order by c.created_at desc, c.id limit 1;
    end if;

    if v_paper is null
       or exists (
         select 1 from public.paper_page_roles r
         where r.paper_id = v_paper and r.role = 'answer' and r.page <> all (v_s.blank_confirmed)
           and not exists (select 1 from public.script_page_links l
                           where l.script_id = v_script and l.version = v_version and l.copy_page = r.page))
       or exists (
         select 1 from public.script_page_links l
         join public.script_pages p on p.id = l.page_id
         where l.script_id = v_script and l.version = v_version
           and public.script_page_is_answer(p.copy_id, p.copy_page)
           and public.script_page_poor(p.quality, p.marking_path, true)
           and not exists (select 1 from public.script_exceptions e where e.page_id = p.id and e.kind = 'poor_quality'))
       or exists (
         select 1 from public.script_pages p
         join public.script_uploads u on u.id = p.upload_id
         where u.submission_id = v_s.id and p.replaced_at is null and p.state = 'unmatched' and p.placed_after is null)
       or exists (
         select 1 from public.script_page_links l
         where l.script_id = v_script and l.version = v_version and public.script_page_refused(l.page_id))
    then
      v_state := 'needs_attention';
    else
      v_state := 'received';
    end if;
  end if;

  if v_state is distinct from v_s.state then
    update public.home_submissions
    set state = v_state, checked_at = case when v_state <> 'checking' then p_now else checked_at end
    where id = v_s.id;
  end if;
  return v_state;
end;
$$;

create or replace function public.script_evaluate_at(p_script uuid, p_now timestamptz)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_x public.scripts%rowtype;
  v_sub uuid;
  v_sub_state public.submission_state;
  v_complete boolean;
  v_busy boolean;
  v_open boolean;
  v_state public.script_state;
  v_received timestamptz;
begin
  select * into v_x from public.scripts s where s.id = p_script;
  if not found then
    return;
  end if;
  if v_x.source = 'home' then
    select s.id into v_sub from public.home_submissions s
    where s.booking_id = v_x.booking_id and s.state not in ('draft', 'rejected')
    order by s.seq desc limit 1
    for update;
  end if;
  select * into v_x from public.scripts s where s.id = p_script for update;
  if v_x.state not in ('receiving', 'checking', 'needs_attention', 'verified') then
    return;
  end if;

  v_complete := v_x.complete;
  v_received := v_x.received_at;
  if v_x.source = 'home' then
    if v_sub is not null then
      v_sub_state := public.home_submission_evaluate(v_sub, p_now);
    end if;
    v_complete := coalesce(v_sub_state = 'received', false);
    if v_complete then
      v_received := coalesce(v_received, p_now);
    end if;
  end if;

  v_busy := coalesce(v_sub_state = 'checking', false)
    or exists (select 1 from public.script_uploads u
               where u.state in ('queued', 'processing')
                 and (u.booking_id = v_x.booking_id
                      or u.submission_id in (select s.id from public.home_submissions s where s.booking_id = v_x.booking_id)))
    or exists (select 1 from public.script_page_links l
               join public.script_pages p on p.id = l.page_id
               join public.script_uploads u on u.id = p.upload_id
               where l.script_id = v_x.id and l.version = v_x.version and u.state in ('queued', 'processing'));
  v_open := exists (select 1 from public.script_exceptions e
                    where e.state = 'open'
                      and (e.script_id = v_x.id or (e.script_id is null and e.booking_id = v_x.booking_id)))
    or exists (select 1 from public.script_page_links l
               where l.script_id = v_x.id and l.version = v_x.version and public.script_page_refused(l.page_id));
  v_state := case
    when v_busy then 'checking'
    when v_complete and not v_open then 'verified'
    when v_x.source = 'centre' and not v_complete and not v_open then 'receiving'
    else 'needs_attention'
  end;

  if (v_x.state, v_x.complete, v_x.received_at) is distinct from (v_state, v_complete, v_received) then
    update public.scripts set state = v_state, complete = v_complete, received_at = v_received where id = v_x.id;
  end if;
end;
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
-- came from, the late submission, whether rejecting it rejects a family's submission, and how it was resolved.
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
    'rejects_submission', p_e.state = 'open' and cardinality(public.script_reject_targets(p_e.id)) > 0,
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
-- script_exception_candidates: "Assign" looks a candidate up by index number. The exam's paid or cancel-requested
-- bookings whose student's index number contains p_query (spaces, hyphens and case ignored: "se 2026 0142" finds
-- SE-2026-0142), at most 10, filtered by the exam before the limit. Each with name, sitting, status, attendance,
-- script number, the copy pages the script shows and the copy's page count.
-- ---------------------------------------------------------------------------------------------
create function public.script_exception_candidates(p_exam uuid, p_query text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_q text := regexp_replace(upper(coalesce(p_query, '')), '[^A-Z0-9]', '', 'g');
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null or char_length(v_q) < 2 or char_length(coalesce(p_query, '')) > 40 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  return jsonb_build_object('ok', true, 'candidates', coalesce((
    select jsonb_agg(jsonb_build_object(
             'booking_id', t.id, 'name', t.name, 'index_number', t.index_number, 'sitting', t.sitting, 'status', t.status,
             'attendance', t.attendance, 'script_number', t.number,
             'pages', coalesce((select jsonb_agg(l.copy_page order by l.copy_page) from public.script_page_links l
                                where l.script_id = t.script_id and l.version = t.version), '[]'::jsonb),
             'copy_pages', (select c.page_count from public.paper_copies c where c.booking_id = t.id order by c.created_at desc, c.id limit 1))
           order by t.index_number, t.id)
    from (
      select b.id, b.sitting, b.status, d.index_number,
             nullif(btrim(coalesce(pr.first_name, '') || ' ' || coalesce(pr.last_name, '')), '') as name,
             (select a.status from public.attendance a where a.exam_id = b.exam_id and a.student_id = b.student_id) as attendance,
             s.id as script_id, s.number, s.version
      from public.bookings b
      join public.student_details d on d.profile_id = b.student_id
      join public.profiles pr on pr.id = b.student_id
      left join public.scripts s on s.booking_id = b.id
      where b.exam_id = p_exam and b.status in ('paid', 'cancel_requested')
        and replace(upper(d.index_number), '-', '') like '%' || v_q || '%'
      order by d.index_number, b.id
      limit 10
    ) t), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_exception_assign: puts the exception's page into a candidate's script at copy page p_copy_page (a new
-- version). For a page with no code, an unknown or unexpected code, a family-placed page, or a duplicate ("use this
-- page instead"). The candidate must be booked (paid or cancel requested) for the same exam and the same sitting as
-- the file: a scanned page goes to a centre candidate marked present or late; a page handed in from home goes to its
-- own booking or to a home booking of a sibling (a student sharing a linked parent with the uploading booking's
-- student), else forbidden (other_family). p_copy_page must be within their copy, and their script not past
-- verification. A copy page that already holds a page needs p_replace (else conflict, occupied); the page displaced
-- gets an open duplicate exception so staff see it (not for a duplicate's "use this page instead", where staff chose
-- between the two pages shown side by side). A candidate with no script yet gets one.
-- ---------------------------------------------------------------------------------------------
create function public.script_exception_assign(p_exception uuid, p_booking uuid, p_copy_page int, p_reason text, p_replace boolean default false)
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
  v_from uuid;
  v_pages int;
  v_links jsonb;
  v_old uuid;
  v_bookings uuid[];
  v_s uuid;
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

  v_bookings := public.script_resolution_lock(p_exception, array[v_b.id]);
  if v_bookings is null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'changed');
  end if;
  select * into v_e from public.script_exceptions e where e.id = p_exception;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_e.state <> 'open' then
    return public.script_exception_conflict(v_e.id);
  end if;
  if v_e.kind not in ('no_code', 'unknown_code', 'not_expected', 'uncoded_family_page', 'duplicate') or v_e.page_id is null then
    return jsonb_build_object('ok', false, 'code', 'wrong_kind');
  end if;
  select * into v_p from public.script_pages p where p.id = v_e.page_id;
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
  if v_home then
    select s.booking_id into v_from from public.home_submissions s where s.id = v_up.submission_id;
    if v_b.id is distinct from v_from and not exists (
         select 1 from public.bookings f
         join public.parent_children a on a.student_id = f.student_id
         join public.parent_children o on o.parent_id = a.parent_id
         where f.id = v_from and o.student_id = v_b.student_id) then
      return jsonb_build_object('ok', false, 'code', 'forbidden', 'reason', 'other_family');
    end if;
  elsif not exists (select 1 from public.attendance a
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
  if v_x.id is not null then
    v_old := (public.script_links(v_x.id) ->> p_copy_page::text)::uuid;
    if v_old is not null and v_old <> v_p.id and not coalesce(p_replace, false) then
      return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'occupied', 'page_id', v_old);
    end if;
  else
    v_x := public.script_create(v_b.id, (case when v_home then 'home' else 'centre' end)::public.script_source, v_now);
  end if;
  v_links := public.script_links(v_x.id);
  v_links := coalesce((select jsonb_object_agg(t.k, t.v) from jsonb_each_text(v_links) t(k, v) where t.v <> v_p.id::text), '{}'::jsonb)
             || jsonb_build_object(p_copy_page::text, v_p.id);
  perform public.script_links_write(v_x.id, v_links, 'staff_assign', v_actor, v_now);
  select * into v_x from public.scripts s where s.id = v_x.id;

  if v_old is not null and v_old <> v_p.id
     and not (v_e.kind = 'duplicate' and v_old = (v_e.details ->> 'kept_page_id')::uuid)
     and not exists (select 1 from public.script_exceptions e where e.page_id = v_old and e.kind = 'duplicate' and e.state = 'open') then
    insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
    select v_e.exam_id, 'duplicate', v_b.id, v_x.id, o.id, o.upload_id,
      jsonb_build_object('copy_page', p_copy_page, 'kept_page_id', v_p.id, 'from', 'staff')
    from public.script_pages o where o.id = v_old;
  end if;

  update public.script_exceptions
  set details = details || jsonb_build_object('assigned', jsonb_build_object(
        'booking_id', v_b.id, 'copy_page', p_copy_page, 'script_id', v_x.id, 'version', v_x.version)),
      booking_id = coalesce(booking_id, v_b.id),
      script_id = coalesce(script_id, v_x.id)
  where id = v_e.id;
  perform public.script_exception_close(v_e.id, 'assigned', v_reason, v_actor, v_now, 'script_exception_assigned');
  perform public.script_page_remask(v_p.id);
  foreach v_s in array v_bookings loop
    perform public.script_resolution_settle(v_s, v_actor, v_reason);
  end loop;
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
  if not exists (select 1 from public.script_exceptions e where e.id = p_exception) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  v_bookings := public.script_resolution_lock(p_exception, '{}');
  if v_bookings is null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'changed');
  end if;
  select * into v_e from public.script_exceptions e where e.id = p_exception;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_e.state <> 'open' then
    return public.script_exception_conflict(v_e.id);
  end if;
  if v_e.kind not in ('no_code', 'unknown_code', 'other_exam', 'not_expected', 'uncoded_family_page') or v_e.page_id is null then
    return jsonb_build_object('ok', false, 'code', 'wrong_kind');
  end if;
  if public.script_page_locked(v_e.page_id) then
    return jsonb_build_object('ok', false, 'code', 'script_locked');
  end if;

  perform public.script_exception_close(v_e.id, 'blank', v_reason, v_actor, v_now, 'script_exception_blank');
  perform public.script_page_set_aside(v_e.page_id, v_actor, v_now, v_reason);
  foreach v_b in array v_bookings loop
    perform public.script_resolution_settle(v_b, v_actor, v_reason);
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
  if not exists (select 1 from public.script_exceptions e where e.id = p_exception) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  v_bookings := public.script_resolution_lock(p_exception, '{}');
  if v_bookings is null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'changed');
  end if;
  select * into v_e from public.script_exceptions e where e.id = p_exception;
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
    perform public.script_resolution_settle(v_b, v_actor, v_reason);
  end loop;
  return jsonb_build_object('ok', true, 'exception_id', v_e.id, 'resolution', 'kept');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_exception_reject: the page (or file) is not accepted. At home the submissions script_reject_targets names
-- are rejected (script_home_reject: the family is emailed once and sees the reason); a scanned page is set aside, out
-- of any script that showed it. The page is set aside in every case. outcome: submission_rejected, set_aside (a
-- scanned page) or closed (nothing else counted it). For pages with no code, unknown, unexpected or other exam's
-- codes, family-placed pages, poor quality, and files that could not be prepared (not a remask failure: wrong_kind).
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
  v_targets uuid[];
  v_bookings uuid[];
  v_b uuid;
  v_outcome text;
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

  v_bookings := public.script_resolution_lock(p_exception, array[v_sub.booking_id]);
  if v_bookings is null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'changed');
  end if;
  select * into v_e from public.script_exceptions e where e.id = p_exception;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_e.state <> 'open' then
    return public.script_exception_conflict(v_e.id);
  end if;
  if v_e.kind not in ('no_code', 'unknown_code', 'other_exam', 'not_expected', 'uncoded_family_page', 'poor_quality', 'processing_failed')
     or (v_e.kind = 'processing_failed' and v_e.details ->> 'kind' = 'remask') then
    return jsonb_build_object('ok', false, 'code', 'wrong_kind');
  end if;
  v_targets := public.script_reject_targets(v_e.id);
  if (v_e.page_id is not null and public.script_page_locked(v_e.page_id))
     or (cardinality(v_targets) > 0 and exists (
           select 1 from public.scripts s where s.booking_id = v_sub.booking_id
             and s.state not in ('receiving', 'checking', 'needs_attention', 'verified'))) then
    return jsonb_build_object('ok', false, 'code', 'script_locked');
  end if;

  perform public.script_exception_close(v_e.id, 'rejected', v_reason, v_actor, v_now, 'script_exception_rejected');
  if cardinality(v_targets) > 0 then
    perform public.script_home_reject(v_sub.booking_id, v_targets, v_reason, v_actor, v_now);
    v_outcome := 'submission_rejected';
  end if;
  if v_e.page_id is not null then
    perform public.script_page_set_aside(v_e.page_id, v_actor, v_now, v_reason);
    v_outcome := coalesce(v_outcome, case when v_sub.id is null then 'set_aside' else 'closed' end);
  end if;
  foreach v_b in array v_bookings loop
    perform public.script_resolution_settle(v_b, v_actor, v_reason);
  end loop;
  return jsonb_build_object('ok', true, 'exception_id', v_e.id, 'resolution', 'rejected',
    'outcome', coalesce(v_outcome, 'closed'), 'submission_rejected', cardinality(v_targets) > 0);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_exception_confirm: staff accept the page as it is: a family's placement of a page with no code, a page of
-- poor quality (or sent as it is), a reported visible name, a file that could not be processed (noted), or mixed
-- versions once the script shows one version again (still_mixed before). A page whose layout was unexpected, and a
-- visible name, need a staff hidden area on the page first, or p_no_name ("There is no name on this page", kept in
-- the details); else name_not_hidden. A page with no marking picture, or with staff hidden areas, gets a remask job.
-- The reason is optional (3 to 300 characters when given).
-- ---------------------------------------------------------------------------------------------
create function public.script_exception_confirm(p_exception uuid, p_reason text default null, p_no_name boolean default false)
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
  v_name_check boolean;
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
  if not exists (select 1 from public.script_exceptions e where e.id = p_exception) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  v_bookings := public.script_resolution_lock(p_exception, '{}');
  if v_bookings is null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'changed');
  end if;
  select * into v_e from public.script_exceptions e where e.id = p_exception;
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
  v_name_check := v_e.kind = 'name_visible'
    or (v_e.kind = 'poor_quality' and exists (select 1 from public.script_pages p
                                              where p.id = v_e.page_id and coalesce(p.quality -> 'flags' ? 'layout_unexpected', false)));
  if v_name_check and not coalesce(p_no_name, false)
     and not exists (select 1 from public.script_page_hidden_areas a where a.page_id = v_e.page_id) then
    return jsonb_build_object('ok', false, 'code', 'name_not_hidden');
  end if;

  if v_name_check and coalesce(p_no_name, false) then
    update public.script_exceptions set details = details || '{"no_name": true}'::jsonb where id = v_e.id;
  end if;
  perform public.script_exception_close(v_e.id, 'confirmed', v_reason, v_actor, v_now, 'script_exception_confirmed');
  if v_e.page_id is not null then
    perform public.script_page_remask(v_e.page_id);
  end if;
  foreach v_b in array v_bookings loop
    perform public.script_resolution_settle(v_b, v_actor, v_reason);
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
  perform public.script_resolution_settle(v_e.booking_id, v_actor, v_reason);

  select * into v_e from public.script_exceptions e where e.id = v_e.id;
  return jsonb_build_object('ok', true, 'exception_id', v_e.id, 'state', v_e.state, 'dismissed', to_jsonb(v_dismissed),
    'missing', coalesce(v_e.details -> 'pages', '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_late_decide: staff decide whether a late home script is marked. Accept: late_decision accept, the script
-- stays late (a script made void by an earlier rejection is worked out again). Reject: every late submission of the
-- booking still counting is rejected with the reason (the family is emailed once and sees it); when an on-time
-- submission then counts, its pages are used (outcome on_time_used); when none does, the script is void with
-- state_reason late_rejected (outcome void), visibly not marked. Either way the open late exception is resolved
-- (late_accepted or late_rejected) and audited against the script. not_late when the script never had a late
-- exception; conflict (with who decided) when it was decided already; script_locked past verification.
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
  v_outcome text;
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
  select * into v_x from public.scripts s where s.id = p_script for update;
  if v_x.state not in ('receiving', 'checking', 'needs_attention', 'verified')
     and not (v_x.state = 'void' and v_x.state_reason = 'late_rejected') then
    return jsonb_build_object('ok', false, 'code', 'script_locked');
  end if;

  update public.script_exceptions
  set state = 'resolved', resolved_by = v_actor, resolved_at = v_now, reason = v_reason,
      resolution = case when p_accept then 'late_accepted' else 'late_rejected' end
  where id = v_e.id;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, case when p_accept then 'script_late_accepted' else 'script_late_rejected' end, 'script', v_x.id, v_reason);
  if v_x.state = 'void' then
    update public.scripts set state = 'receiving', state_reason = null where id = v_x.id;
  end if;
  if p_accept then
    update public.scripts set late_decision = 'accept' where id = v_x.id;
    v_outcome := 'accepted';
  else
    perform public.script_home_reject(v_x.booking_id,
      array(select s.id from public.home_submissions s
            where s.booking_id = v_x.booking_id and s.late and s.state not in ('draft', 'rejected') order by s.id),
      v_reason, v_actor, v_now);
    if exists (select 1 from public.home_submissions s where s.booking_id = v_x.booking_id and s.state not in ('draft', 'rejected')) then
      update public.scripts set late_decision = 'reject' where id = v_x.id;
      v_outcome := 'on_time_used';
    else
      update public.scripts set late_decision = 'reject', state = 'void', state_reason = 'late_rejected' where id = v_x.id;
      v_outcome := 'void';
    end if;
  end if;
  perform public.script_resolution_settle(v_x.booking_id, v_actor, v_reason);
  return jsonb_build_object('ok', true, 'script_id', v_x.id, 'late_decision', case when p_accept then 'accept' else 'reject' end,
    'outcome', v_outcome);
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
revoke execute on function public.script_resolution_lock(uuid, uuid[]) from public, anon, authenticated, service_role;
revoke execute on function public.script_centre_checked(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_refused(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_resolution_settle(uuid, uuid, text) from public, anon, authenticated, service_role;
revoke execute on function public.script_links_write(uuid, jsonb, text, uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_locked(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_exception_close(uuid, text, text, uuid, timestamptz, text) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_set_aside(uuid, uuid, timestamptz, text) from public, anon, authenticated, service_role;
revoke execute on function public.script_home_reject(uuid, uuid[], text, uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.script_reject_targets(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_remask(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_booking_json(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_json(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_exception_json(uuid) from public, anon, authenticated, service_role;
-- Re-created above; still internal (as 20261120000052).
revoke execute on function public.home_submission_evaluate(uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.script_evaluate_at(uuid, timestamptz) from public, anon, authenticated, service_role;

revoke execute on function public.script_exceptions_list(uuid, public.exception_kind, text) from public, anon;
revoke execute on function public.script_exception_candidates(uuid, text) from public, anon;
revoke execute on function public.script_exception_assign(uuid, uuid, int, text, boolean) from public, anon;
revoke execute on function public.script_exception_blank(uuid, text) from public, anon;
revoke execute on function public.script_exception_keep_existing(uuid, text) from public, anon;
revoke execute on function public.script_exception_reject(uuid, text) from public, anon;
revoke execute on function public.script_exception_confirm(uuid, text, boolean) from public, anon;
revoke execute on function public.script_exception_dismiss_missing(uuid, int[], text) from public, anon;
revoke execute on function public.script_late_decide(uuid, boolean, text) from public, anon;
revoke execute on function public.script_page_set_hidden_areas(uuid, jsonb, text) from public, anon;
grant execute on function public.script_exceptions_list(uuid, public.exception_kind, text) to authenticated;
grant execute on function public.script_exception_candidates(uuid, text) to authenticated;
grant execute on function public.script_exception_assign(uuid, uuid, int, text, boolean) to authenticated;
grant execute on function public.script_exception_blank(uuid, text) to authenticated;
grant execute on function public.script_exception_keep_existing(uuid, text) to authenticated;
grant execute on function public.script_exception_reject(uuid, text) to authenticated;
grant execute on function public.script_exception_confirm(uuid, text, boolean) to authenticated;
grant execute on function public.script_exception_dismiss_missing(uuid, int[], text) to authenticated;
grant execute on function public.script_late_decide(uuid, boolean, text) to authenticated;
grant execute on function public.script_page_set_hidden_areas(uuid, jsonb, text) to authenticated;
