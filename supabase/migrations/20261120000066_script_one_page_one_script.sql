-- Phase 2 Task 11, final fix round (Ruling R37).
--
-- (1) script_pages_record locks the file's current page rows before it checks for staff work, so a staff save made at
-- the same moment is either seen by the check (the pages are kept) or lands on a page already replaced (refused,
-- page_replaced). script_page_set_hidden_areas takes the file's row first, as the record does, so the two wait for
-- each other in one order.
-- (2) A page is never in two scripts' current versions: script_links_current drops a link to a page another script
-- shows, whoever writes the version, and staff are told (an open duplicate exception on the page, reason
-- in_other_script). A rerun's slot decision leaves pages linked elsewhere out, and its sweep covers them.
-- (3) A script being marked (ready to mark and later) cannot change through a family: home_submission_open,
-- home_submission_submit and home_page_place refuse (script_locked); a family's page with no code is not confirmed
-- into it; its extra pages are those it had when marking began (scripts.extras_locked), whatever is handed in later;
-- a page with no code read for it is recorded but not offered for placing (not_expected, script_locked).
-- (4) Whenever a version is written without a slot it was asked to show (its page was replaced, or is in another
-- script), an open missing_pages exception names that slot (raised, or merged into the open one).

-- ---------------------------------------------------------------------------------------------
-- Helpers (internal).
-- ---------------------------------------------------------------------------------------------

-- Whether the booking's script is being marked (ready to mark, marking, marked, checked, final): nothing a family or a
-- file does changes it any more.
create function public.script_booking_locked(p_booking uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.scripts s
                 where s.booking_id = p_booking and s.state in ('ready_to_mark', 'marking', 'marked', 'checked', 'final'))
$$;

-- The other script whose current version shows this page (not p_script; any script when p_script is null), or null.
create function public.script_page_elsewhere(p_page uuid, p_script uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select s.id from public.script_page_links l
  join public.scripts s on s.id = l.script_id and l.version = s.version
  where l.page_id = p_page and s.id is distinct from p_script
  order by s.id
  limit 1
$$;

-- How many current links of a script show a page another script's current version shows too: always 0 (Ruling R37 2).
create function public.script_shared_links(p_script uuid)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int from public.script_page_links l
  join public.scripts s on s.id = l.script_id and l.version = s.version
  where s.id = p_script and public.script_page_elsewhere(l.page_id, s.id) is not null
$$;

-- ---------------------------------------------------------------------------------------------
-- script_links_current: as 20261120000064, and a page another script's current version shows gives up its slot here
-- (the script that already shows it keeps it).
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_links_current(p_script uuid, p_links jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_booking uuid;
  v_out jsonb;
  v_r record;
  v_n uuid;
begin
  select s.booking_id into v_booking from public.scripts s where s.id = p_script;
  select coalesce(jsonb_object_agg(t.key, t.value), '{}'::jsonb) into v_out
  from jsonb_each_text(coalesce(p_links, '{}'::jsonb)) t
  join public.script_pages p on p.id = t.value::uuid
  where p.replaced_at is null and public.script_page_elsewhere(p.id, p_script) is null;
  for v_r in
    select t.key, p.upload_id
    from jsonb_each_text(coalesce(p_links, '{}'::jsonb)) t
    join public.script_pages p on p.id = t.value::uuid
    where p.replaced_at is not null
    order by t.key::int
  loop
    v_n := null;
    select n.id into v_n from public.script_pages n
    where n.upload_id = v_r.upload_id and n.replaced_at is null and n.state = 'matched'
      and n.booking_id = v_booking and n.copy_page = v_r.key::int
      and not exists (select 1 from jsonb_each_text(v_out) x where x.value = n.id::text)
      and public.script_page_elsewhere(n.id, p_script) is null
    order by n.source_index
    limit 1;
    if v_n is not null then
      v_out := v_out || jsonb_build_object(v_r.key, v_n);
    end if;
  end loop;
  return v_out;
end;
$$;

-- Tells staff about the slots a version was asked to show (p_links) and does not (p_written): one open missing_pages
-- exception of the booking names them (merged into the open one, else raised, reason reprocessed or in_other_script),
-- and a page left out because another script shows it gets an open duplicate exception (reason in_other_script).
create function public.script_slots_dropped(p_script uuid, p_links jsonb, p_written jsonb, p_upload uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_x public.scripts%rowtype;
  v_gone int[];
  v_shared boolean;
  v_rows int;
begin
  select coalesce(array_agg(t.key::int order by t.key::int), '{}') into v_gone
  from jsonb_each_text(coalesce(p_links, '{}'::jsonb)) t where not coalesce(p_written, '{}'::jsonb) ? t.key;
  if cardinality(v_gone) = 0 then
    return;
  end if;
  select * into v_x from public.scripts s where s.id = p_script;

  insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
  select v_x.exam_id, 'duplicate', v_x.booking_id, v_x.id, p.id, p.upload_id,
    jsonb_build_object('copy_page', t.key::int, 'reason', 'in_other_script',
      'other_script_id', public.script_page_elsewhere(p.id, v_x.id))
  from jsonb_each_text(p_links) t
  join public.script_pages p on p.id = t.value::uuid
  where t.key::int = any (v_gone) and p.replaced_at is null and public.script_page_elsewhere(p.id, v_x.id) is not null
    and not exists (select 1 from public.script_exceptions e
                    where e.page_id = p.id and e.kind = 'duplicate' and e.state = 'open' and e.booking_id = v_x.booking_id);
  -- Why, when a new missing_pages is raised: every slot left out shows a page of another script, or pages were replaced.
  v_shared := not exists (
    select 1 from jsonb_each_text(p_links) t left join public.script_pages p on p.id = t.value::uuid
    where t.key::int = any (v_gone) and (p.id is null or p.replaced_at is not null
                                         or public.script_page_elsewhere(p.id, v_x.id) is null));

  update public.script_exceptions e
  set details = e.details || jsonb_build_object('pages', to_jsonb(array(
        select distinct t.n from unnest(array(select jsonb_array_elements_text(
          case when jsonb_typeof(e.details -> 'pages') = 'array' then e.details -> 'pages' else '[]'::jsonb end)::int) || v_gone) t(n)
        order by t.n)))
  where e.booking_id = v_x.booking_id and e.kind = 'missing_pages' and e.state = 'open';
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    insert into public.script_exceptions (exam_id, kind, booking_id, script_id, upload_id, details)
    values (v_x.exam_id, 'missing_pages', v_x.booking_id, v_x.id, p_upload,
      jsonb_build_object('pages', to_jsonb(v_gone), 'reason', case when v_shared then 'in_other_script' else 'reprocessed' end));
  end if;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_version_write: as 20261120000064, and staff are told of every slot it was asked to show and leaves out
-- (script_slots_dropped): the page was replaced with no page to take its place, or another script shows it.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_version_write(
  p_script uuid,
  p_links jsonb,
  p_submission uuid,
  p_upload uuid,
  p_reason text,
  p_now timestamptz
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_x public.scripts%rowtype;
  v_links jsonb;
begin
  select * into v_x from public.scripts s where s.id = p_script for update;
  if not found or v_x.state in ('ready_to_mark', 'marking', 'marked', 'checked', 'final') then
    return false;
  end if;
  v_links := public.script_links_current(v_x.id, p_links);
  perform public.script_slots_dropped(v_x.id, p_links, v_links, p_upload);
  if public.script_links(v_x.id) = v_links then
    return false;
  end if;
  insert into public.script_versions (script_id, version, created_at, reason, submission_id, upload_id)
  values (v_x.id, v_x.version + 1, p_now, p_reason, p_submission, p_upload);
  insert into public.script_page_links (script_id, version, copy_page, page_id)
  select v_x.id, v_x.version + 1, t.k::int, t.v::uuid from jsonb_each_text(v_links) t(k, v);
  update public.scripts set version = v_x.version + 1 where id = v_x.id;
  return true;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- A script being marked keeps the extra pages it had when marking began (Ruling R37 3): they are written down as its
-- state moves past verified (scripts.extras_locked) and read from there until it comes back, so a later hand-in,
-- placement or confirmation changes nothing markers see.
-- ---------------------------------------------------------------------------------------------
alter table public.scripts add column extras_locked jsonb;

update public.scripts s
set extras_locked = coalesce((
  select jsonb_agg(jsonb_build_object('page_id', x.page_id, 'placed_after', x.placed_after, 'file_position', x.file_position,
                                      'source_index', x.source_index))
  from public.script_extra_pages(s.id) x), '[]'::jsonb)
where s.state in ('ready_to_mark', 'marking', 'marked', 'checked', 'final');

create function public.script_extras_lock()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.state in ('ready_to_mark', 'marking', 'marked', 'checked', 'final') then
    if old.state not in ('ready_to_mark', 'marking', 'marked', 'checked', 'final') or new.extras_locked is null then
      -- The row still says the earlier state, so this reads the pages as they count now.
      new.extras_locked := coalesce((
        select jsonb_agg(jsonb_build_object('page_id', x.page_id, 'placed_after', x.placed_after, 'file_position', x.file_position,
                                            'source_index', x.source_index))
        from public.script_extra_pages(old.id) x), '[]'::jsonb);
    else
      new.extras_locked := old.extras_locked;
    end if;
  else
    new.extras_locked := null;
  end if;
  return new;
end;
$$;

create trigger scripts_extras_lock before update on public.scripts
  for each row
  when (old.state is distinct from new.state or old.extras_locked is distinct from new.extras_locked)
  execute function public.script_extras_lock();

-- script_extra_pages: as 20261120000059 for a script not yet being marked; for one being marked, the pages written
-- down when marking began.
create or replace function public.script_extra_pages(p_script uuid)
returns table (page_id uuid, placed_after int, file_position int, source_index int)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.placed_after, u.position, p.source_index
  from public.scripts s
  join public.home_submissions hs on hs.booking_id = s.booking_id and hs.state not in ('draft', 'rejected')
  join public.script_uploads u on u.submission_id = hs.id
  join public.script_pages p on p.upload_id = u.id
  where s.id = p_script and s.state not in ('ready_to_mark', 'marking', 'marked', 'checked', 'final')
    and p.replaced_at is null and p.state = 'unmatched' and p.placed_after is not null
    and hs.seq >= coalesce((select max(h2.seq) from public.home_submissions h2
                            where h2.booking_id = s.booking_id and h2.state not in ('draft', 'rejected') and h2.replaces_all), 0)
    and not exists (select 1 from public.script_page_links l where l.script_id = s.id and l.version = s.version and l.page_id = p.id)
    and exists (select 1 from public.script_exceptions e
                where e.page_id = p.id and e.kind = 'uncoded_family_page' and e.state = 'resolved' and e.resolution = 'confirmed')
  union all
  select (x ->> 'page_id')::uuid, (x ->> 'placed_after')::int, (x ->> 'file_position')::int, (x ->> 'source_index')::int
  from public.scripts s
  cross join lateral jsonb_array_elements(coalesce(s.extras_locked, '[]'::jsonb)) x
  where s.id = p_script and s.state in ('ready_to_mark', 'marking', 'marked', 'checked', 'final')
    and exists (select 1 from public.script_pages p where p.id = (x ->> 'page_id')::uuid)
$$;

-- ---------------------------------------------------------------------------------------------
-- script_page_set_hidden_areas: as 20261120000062, and it takes the file's row before the page's row, the order
-- script_pages_record takes them in (Ruling R37 1): a save made while the file is being recorded again waits for the
-- record, then finds its page replaced (page_replaced; not_found when the replaced page is gone) instead of landing
-- on a page whose pictures are being swapped; a record that starts during a save waits for it and then sees the areas.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_page_set_hidden_areas(p_page uuid, p_areas jsonb, p_reason text)
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
  -- Lock order: the file's row (no key change: what queues a remask for it is not held up), then the page's row.
  perform 1 from public.script_uploads u
  where u.id = (select p.upload_id from public.script_pages p where p.id = p_page) for no key update;
  select * into v_p from public.script_pages p where p.id = p_page for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_p.replaced_at is not null then
    return jsonb_build_object('ok', false, 'code', 'page_replaced');
  end if;
  if public.script_page_locked(v_p.id) then
    return jsonb_build_object('ok', false, 'code', 'script_locked');
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
-- home_submission_open: as 20261120000054, and refused (script_locked) once the booking's script is being marked
-- (Ruling R37 3): "Your answers are already being marked."
-- ---------------------------------------------------------------------------------------------
create or replace function public.home_submission_open(p_booking uuid, p_replaces_all boolean default true, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_b public.bookings%rowtype;
  v_code text;
  v_all boolean;
  v_s public.home_submissions%rowtype;
begin
  if p_booking is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_b from public.bookings b where b.id = p_booking;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  v_code := public.home_upload_code(v_actor, v_b, v_now);
  if v_code is not null then
    return jsonb_build_object('ok', false, 'code', v_code);
  end if;

  perform public.home_booking_lock(v_b.id);
  if public.script_booking_locked(v_b.id) then
    return jsonb_build_object('ok', false, 'code', 'script_locked');
  end if;
  v_all := coalesce(p_replaces_all, true)
    or not exists (select 1 from public.home_submissions s where s.booking_id = v_b.id and s.state <> 'draft');
  select * into v_s from public.home_submissions s where s.booking_id = v_b.id and s.state = 'draft' for update;
  if found then
    if v_s.replaces_all <> v_all then
      update public.home_submissions set replaces_all = v_all where id = v_s.id returning * into v_s;
    end if;
  else
    insert into public.home_submissions (booking_id, seq, replaces_all)
    values (v_b.id, coalesce((select max(s.seq) from public.home_submissions s where s.booking_id = v_b.id), 0) + 1, v_all)
    returning * into v_s;
  end if;
  return jsonb_build_object('ok', true, 'submission_id', v_s.id, 'seq', v_s.seq, 'replaces_all', v_s.replaces_all);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- home_submission_submit: as 20261120000054, and a draft is not handed in (script_locked) once the booking's script is
-- being marked (Ruling R37 3). A submission already handed in still answers as the first call did.
-- ---------------------------------------------------------------------------------------------
create or replace function public.home_submission_submit(p_submission uuid, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_s public.home_submissions%rowtype;
  v_b public.bookings%rowtype;
  v_e public.exams%rowtype;
  v_prev public.home_submissions%rowtype;
  v_code text;
  v_late boolean;
  v_script uuid;
begin
  if p_submission is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_s from public.home_submissions s where s.id = p_submission;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into v_b from public.bookings b where b.id = v_s.booking_id;
  v_code := public.home_upload_code(v_actor, v_b, null);
  if v_code is not null then
    return jsonb_build_object('ok', false, 'code', v_code);
  end if;

  perform public.home_booking_lock(v_b.id);
  select * into v_s from public.home_submissions s where s.id = p_submission for update;
  if v_s.state <> 'draft' then
    return public.home_submission_result(v_s.id);
  end if;
  if public.script_booking_locked(v_b.id) then
    return jsonb_build_object('ok', false, 'code', 'script_locked');
  end if;
  v_code := public.home_upload_code(v_actor, v_b, v_now);
  if v_code is not null then
    return jsonb_build_object('ok', false, 'code', v_code);
  end if;
  if exists (select 1 from public.script_uploads u where u.submission_id = v_s.id and u.state = 'pending') then
    return jsonb_build_object('ok', false, 'code', 'still_uploading');
  end if;
  if not exists (select 1 from public.script_uploads u where u.submission_id = v_s.id and u.state = 'stored') then
    return jsonb_build_object('ok', false, 'code', 'nothing_to_submit');
  end if;

  select * into v_e from public.exams e where e.id = v_b.exam_id;
  v_late := v_now >= v_e.starts_at + v_e.duration_minutes * interval '1 minute' + interval '2 hours';
  if not v_s.replaces_all then
    select * into v_prev from public.home_submissions s
    where s.booking_id = v_b.id and s.state not in ('draft', 'rejected')
    order by s.seq desc limit 1;
  end if;
  update public.home_submissions
  set state = 'checking', submitted_by = v_actor, submitted_at = v_now, late = v_late,
      blank_confirmed = coalesce(v_prev.blank_confirmed, v_s.blank_confirmed)
  where id = v_s.id
  returning * into v_s;
  update public.script_uploads set state = 'queued' where submission_id = v_s.id and state = 'stored';
  insert into public.processing_jobs (upload_id, kind)
  select u.id, 'prepare' from public.script_uploads u where u.submission_id = v_s.id and u.state = 'queued' order by u.position, u.id;

  select x.id into v_script from public.scripts x where x.booking_id = v_b.id;
  if v_late then
    update public.scripts set late = true where id = v_script and not late;
    insert into public.script_exceptions (exam_id, kind, booking_id, script_id, details)
    select v_b.exam_id, 'late', v_b.id, v_script, jsonb_build_object('submission_id', v_s.id, 'seq', v_s.seq)
    where not exists (select 1 from public.script_exceptions e where e.booking_id = v_b.id and e.kind = 'late' and e.state = 'open');
  end if;
  if v_script is not null then
    perform public.script_evaluate_at(v_script, v_now);
  end if;
  return public.home_submission_result(v_s.id);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- home_page_place: as 20261120000054, and refused (script_locked) once the booking's script is being marked
-- (Ruling R37 3).
-- ---------------------------------------------------------------------------------------------
create or replace function public.home_page_place(p_page uuid, p_after_page int)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_p public.script_pages%rowtype;
  v_sub uuid;
  v_s public.home_submissions%rowtype;
  v_b public.bookings%rowtype;
  v_code text;
  v_pages int;
  v_exc uuid;
begin
  if p_page is null or p_after_page is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_p from public.script_pages p where p.id = p_page;
  select u.submission_id into v_sub from public.script_uploads u where u.id = v_p.upload_id;
  if v_p.id is null or v_sub is null then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select b.* into v_b from public.bookings b join public.home_submissions s on s.booking_id = b.id where s.id = v_sub;
  v_code := public.home_upload_code(v_actor, v_b, null);
  if v_code is not null then
    return jsonb_build_object('ok', false, 'code', v_code);
  end if;

  perform public.home_booking_lock(v_b.id);
  if public.script_booking_locked(v_b.id) then
    return jsonb_build_object('ok', false, 'code', 'script_locked');
  end if;
  select * into v_s from public.home_submissions s where s.id = v_sub for update;
  if v_s.state not in ('needs_attention', 'received') or (public.home_submission_latest(v_b.id)).id is distinct from v_s.id then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  select * into v_p from public.script_pages p where p.id = p_page for update;
  select c.page_count into v_pages from public.paper_copies c where c.booking_id = v_b.id order by c.created_at desc, c.id limit 1;
  if v_p.replaced_at is not null or v_p.state <> 'unmatched' or p_after_page < 1 or p_after_page > coalesce(v_pages, 0) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  update public.script_pages set placed_after = p_after_page where id = v_p.id;
  update public.script_exceptions e
  set details = jsonb_build_object('after_page', p_after_page, 'from', 'family')
  where e.page_id = v_p.id and e.kind = 'uncoded_family_page' and e.state = 'open'
  returning e.id into v_exc;
  if v_exc is null then
    insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
    values (v_p.exam_id, 'uncoded_family_page', v_b.id, (select x.id from public.scripts x where x.booking_id = v_b.id),
      v_p.id, v_p.upload_id, jsonb_build_object('after_page', p_after_page, 'from', 'family'))
    returning id into v_exc;
  end if;
  return jsonb_build_object('ok', true, 'state', public.home_reevaluate(v_b.id, v_s.id), 'exception_id', v_exc);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_exception_confirm: as 20261120000063, and a family's page with no code is not confirmed into a script being
-- marked (script_locked, Ruling R37 3): staff reject it, or tell the marking lead.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_exception_confirm(p_exception uuid, p_reason text default null, p_no_name boolean default false)
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
  if v_e.kind = 'uncoded_family_page' and public.script_booking_locked(coalesce(v_e.booking_id,
       (select hs.booking_id from public.script_pages p join public.script_uploads u on u.id = p.upload_id
        join public.home_submissions hs on hs.id = u.submission_id where p.id = v_e.page_id))) then
    return jsonb_build_object('ok', false, 'code', 'script_locked');
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
  v_name_check := v_e.page_id is not null and (
    v_e.kind in ('name_visible', 'uncoded_family_page')
    or (v_e.kind = 'poor_quality' and coalesce(v_e.details ->> 'stale_marking', '') <> 'true'
        and (v_e.details ->> 'from' = 'remask' or v_e.details ->> 'marking_picture' = 'false'
        or exists (select 1 from public.script_pages p
                   where p.id = v_e.page_id and (p.copy_id is null or coalesce(p.quality -> 'flags' ? 'layout_unexpected', false))))));
  if v_name_check and not coalesce(p_no_name, false)
     and not exists (select 1 from public.script_page_hidden_areas a where a.page_id = v_e.page_id) then
    return jsonb_build_object('ok', false, 'code', 'name_not_hidden');
  end if;

  if v_name_check then
    -- The confirmation holds for the page as staff saw it: its turn and its staff hidden areas now (Ruling R32).
    update public.script_exceptions
    set details = details || public.script_page_binding(v_e.page_id)
                  || case when coalesce(p_no_name, false) then '{"no_name": true}'::jsonb else '{}'::jsonb end
    where id = v_e.id;
  end if;
  perform public.script_exception_close(v_e.id, 'confirmed', v_reason, v_actor, v_now, 'script_exception_confirmed');
  if v_name_check then
    perform public.script_remask_queue(p.upload_id) from public.script_pages p where p.id = v_e.page_id and p.replaced_at is null;
  elsif v_e.page_id is not null then
    perform public.script_page_remask(v_e.page_id);
  end if;
  -- A remask that failed for good is made again once staff have looked (Ruling R32 e).
  if v_e.kind = 'processing_failed' and v_e.details ->> 'kind' = 'remask' and v_e.upload_id is not null then
    perform public.script_remask_queue(v_e.upload_id);
  end if;
  foreach v_b in array v_bookings loop
    perform public.script_resolution_settle(v_b, v_actor, v_reason);
  end loop;
  return jsonb_build_object('ok', true, 'exception_id', v_e.id, 'resolution', 'confirmed');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_pages_record: as 20261120000065, and (Ruling R37)
-- (1) the lock order is: the job's row, the file's row, the bookings' advisory locks (uuid order), the submission's
--     row, then the file's current page rows (id order), and only then the check for staff work. A staff save that
--     holds a page's row is waited for and then seen (the pages are kept); one that comes later waits for this and
--     finds its page replaced. Bookings that joined while it waited (staff placed a page of the file in another
--     candidate's script) are locked too and evaluated;
-- (2) a page another script shows is no candidate for a slot, keeps its state and gets no duplicate exception from
--     the slot decision; a script whose undone version brought back a link to such a page (or to a replaced page)
--     is swept, the undone script first, so the script that took the page since keeps it;
-- (3) a page with no code read for a home booking whose script is being marked is not_expected (script_locked), not
--     offered to the family for placing;
-- (4) the slots a sweep empties are told to staff by script_version_write (script_slots_dropped).
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_pages_record(
  p_job bigint,
  p_worker text,
  p_attempt int,
  p_sha256 text,
  p_pages jsonb,
  p_now timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_job public.processing_jobs%rowtype;
  v_up public.script_uploads%rowtype;
  v_sub public.home_submissions%rowtype;
  v_home boolean;
  v_centre uuid;
  v_old uuid[];
  v_old_slots jsonb;
  v_placed jsonb;
  v_found jsonb;
  v_bookings uuid[];
  v_b uuid;
  v_x public.scripts%rowtype;
  v_links jsonb;
  v_slot int;
  v_linked uuid;
  v_winner uuid;
  v_changed uuid[] := '{}';
  v_keep text;
  v_undone uuid[] := '{}';
  v_home_locked boolean := false;
begin
  select * into v_job from public.processing_jobs j where j.id = p_job for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_job.state <> 'running' or v_job.locked_by is distinct from left(coalesce(p_worker, ''), 100)
     or v_job.attempts is distinct from p_attempt then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  select * into v_up from public.script_uploads u where u.id = v_job.upload_id for update;
  if v_job.kind <> 'prepare' or p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$'
     or not public.script_pages_valid(p_pages,
              v_up.exam_id::text || '/' || v_up.id::text || '/' || v_job.id::text || '-' || v_job.attempts::text || '/') then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_up.sha256 is not null and v_up.sha256 <> p_sha256 then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'sha256_mismatch');
  end if;
  v_home := v_up.submission_id is not null;

  -- Every booking this can touch: those of the upload's current pages, of the scripts that show them, of the codes
  -- read and of the submission.
  select coalesce(array_agg(distinct t.b order by t.b), '{}') into v_bookings
  from (
    select p.booking_id as b from public.script_pages p
    where p.upload_id = v_up.id and p.replaced_at is null and p.booking_id is not null
    union
    select s.booking_id from public.script_pages p
    join public.script_page_links l on l.page_id = p.id
    join public.scripts s on s.id = l.script_id and l.version = s.version
    where p.upload_id = v_up.id and p.replaced_at is null
    union
    select c.booking_id from jsonb_array_elements(p_pages) e
    join public.paper_copies c on c.code = e ->> 'code'
    join public.exam_papers ep on ep.id = c.paper_id and ep.exam_id = v_up.exam_id
    union
    select s.booking_id from public.home_submissions s where s.id = v_up.submission_id
  ) t;
  foreach v_b in array v_bookings loop
    perform pg_advisory_xact_lock(hashtextextended('script_booking:' || v_b::text, 0));
  end loop;
  if v_home then
    select * into v_sub from public.home_submissions s where s.id = v_up.submission_id for update;
    v_home_locked := public.script_booking_locked(v_sub.booking_id);
  else
    select sb.centre_id into v_centre from public.scan_batches sb where sb.id = v_up.batch_id;
  end if;

  -- The file's current page rows, in id order, before anything is decided from them (Ruling R37 1): a staff save in
  -- flight on one of them (hidden areas take the page's row) is waited for here, so the check below sees it; a save
  -- that comes later waits for this transaction and finds its page replaced.
  perform 1 from public.script_pages p where p.upload_id = v_up.id and p.replaced_at is null order by p.id for update;
  -- Bookings that came to concern the file while this waited (a page of it placed in another candidate's script).
  for v_b in
    select b from unnest(public.script_upload_bookings(v_up.id)) b where b <> all (v_bookings) order by 1
  loop
    perform pg_advisory_xact_lock(hashtextextended('script_booking:' || v_b::text, 0));
    v_bookings := v_bookings || v_b;
  end loop;

  -- A rerun of a file staff have worked on, or whose pages a script being marked shows, replaces nothing (Ruling R35):
  -- staff may have worked on its pages while the job waited. The pages stay as they are and the file is processed.
  if exists (select 1 from public.script_pages p where p.upload_id = v_up.id and p.replaced_at is null) then
    v_keep := public.script_upload_staff_changes(v_up.id, false);
    if v_keep is null and exists (
         select 1 from public.scripts s
         where s.booking_id = any (public.script_upload_bookings(v_up.id))
           and s.state in ('ready_to_mark', 'marking', 'marked', 'checked', 'final')) then
      v_keep := 'script_locked';
    end if;
    if v_keep is not null then
      update public.script_uploads set state = 'processed', sha256 = coalesce(sha256, p_sha256) where id = v_up.id;
      insert into public.audit_log (actor_id, action, target_type, target_id, reason)
      values (null, 'script_upload_reprocess_kept', 'script_upload', v_up.id,
        case v_keep when 'script_locked' then 'A script being marked shows pages of this file, so its pages were kept.'
                    else 'Staff have worked on pages of this file, so its pages were kept.' end);
      if v_home then
        perform public.home_submission_evaluate(v_sub.id, v_now);
      end if;
      for v_x in select s.* from public.scripts s where s.booking_id = any (v_bookings) order by s.booking_id loop
        perform public.script_evaluate_at(v_x.id, v_now);
      end loop;
      return jsonb_build_object('ok', true, 'kept', true, 'reason', v_keep,
        'pages', (select count(*) from public.script_pages p where p.upload_id = v_up.id and p.replaced_at is null),
        'matched', (select count(*) from public.script_pages p where p.upload_id = v_up.id and p.replaced_at is null and p.state = 'matched'),
        'exceptions', (select count(*) from public.script_exceptions e where e.upload_id = v_up.id and e.state = 'open'));
    end if;
  end if;

  -- A rerun. The latest versions this upload (or its submission) made are undone, to be made again below. The open
  -- exceptions this function raised on the earlier run go (they are raised again where they still hold); on a home
  -- upload an open poor_quality exception is the family's "Send as it is" and moves to the new page of the same
  -- copy page. The earlier pages are set aside (replaced_at) and, once the new pages are in, deleted unless a kept
  -- version or an exception still names them. A family's placement of a page with no code carries over to the new
  -- page at the same position.
  for v_x in
    select s.* from public.scripts s
    join public.script_versions v on v.script_id = s.id and v.version = s.version
    where s.booking_id = any (v_bookings)
      and (v.upload_id = v_up.id or (v_home and v.submission_id = v_up.submission_id))
      and s.state not in ('ready_to_mark', 'marking', 'marked', 'checked', 'final')  -- never a script being marked
    for update of s
  loop
    delete from public.script_page_links l where l.script_id = v_x.id and l.version = v_x.version;
    delete from public.script_versions v where v.script_id = v_x.id and v.version = v_x.version;
    update public.scripts set version = v_x.version - 1 where id = v_x.id;
    v_undone := v_undone || v_x.id;
  end loop;

  select coalesce(array_agg(p.id), '{}'),
         coalesce(jsonb_agg(jsonb_build_object('booking_id', p.booking_id, 'copy_page', p.copy_page))
                    filter (where p.booking_id is not null), '[]'::jsonb),
         coalesce(jsonb_object_agg(p.source_index::text, jsonb_build_object('id', p.id, 'placed_after', p.placed_after))
                    filter (where p.state = 'unmatched' and p.placed_after is not null), '{}'::jsonb)
  into v_old, v_old_slots, v_placed
  from public.script_pages p where p.upload_id = v_up.id and p.replaced_at is null;

  delete from public.script_exceptions e
  where e.state = 'open'
    and e.kind in ('no_code', 'unknown_code', 'other_exam', 'not_expected', 'duplicate', 'mixed_versions', 'poor_quality')
    and not (v_home and e.kind = 'poor_quality')
    and (e.upload_id = v_up.id or e.page_id = any (v_old));
  update public.script_pages p set replaced_at = v_now where p.id = any (v_old);

  -- What each page is.
  with f as (
    select (e ->> 'source_index')::int as idx, e, c.id as copy_id, c.booking_id as copy_booking, c.page_count as copy_pages,
      ep.exam_id as copy_exam, b.status as b_status, b.sitting as b_sitting, b.centre_id as b_centre,
      coalesce((select x.state in ('ready_to_mark', 'marking', 'marked', 'checked', 'final')
                from public.scripts x where x.booking_id = c.booking_id), false) as locked,
      exists (select 1 from public.attendance a
              where a.exam_id = b.exam_id and a.student_id = b.student_id and a.status = 'absent') as absent
    from jsonb_array_elements(p_pages) e
    left join public.paper_copies c on c.code = e ->> 'code'
    left join public.exam_papers ep on ep.id = c.paper_id
    left join public.bookings b on b.id = c.booking_id
  ), g as (
    select f.*,
      case
        when f.e ->> 'code' is null and (f.e ->> 'blank')::boolean then 'blank'
        when f.e ->> 'code' is null and v_home_locked then 'not_expected'  -- nothing is placed in a script being marked
        when f.e ->> 'code' is null then 'no_code'
        when f.copy_id is null then 'unknown_code'
        when f.copy_exam <> v_up.exam_id then 'other_exam'
        when (f.e ->> 'copy_page')::int > f.copy_pages then 'unknown_code'
        when v_home and f.copy_booking is distinct from v_sub.booking_id then 'not_expected'
        when not v_home and (f.b_status not in ('paid', 'cancel_requested') or f.b_sitting <> 'centre'
                             or f.b_centre is distinct from v_centre or f.absent) then 'not_expected'
        when f.locked then 'not_expected'  -- its script is being marked: recorded, never linked (Ruling R35 2)
        else 'match'
      end as finding,
      case
        when f.e ->> 'code' is null and v_home_locked then 'script_locked'
        when v_home and f.copy_booking is distinct from v_sub.booking_id then 'other_booking'
        when not v_home and f.b_status not in ('paid', 'cancel_requested') then 'booking_status'
        when not v_home and f.b_sitting <> 'centre' then 'home_sitting'
        when not v_home and f.b_centre is distinct from v_centre then 'other_centre'
        when not v_home and f.absent then 'absent'
        else 'script_locked'
      end as reason
    from f
  )
  select coalesce(jsonb_agg(jsonb_build_object('idx', g.idx, 'e', g.e, 'finding', g.finding, 'reason', g.reason,
           'copy_id', case when g.finding <> 'other_exam' then g.copy_id end, 'copy_booking', g.copy_booking,
           'copy_exam', g.copy_exam)), '[]'::jsonb)
  into v_found from g;

  insert into public.script_pages (upload_id, source_index, exam_id, copy_id, copy_page, booking_id, state, blank, quality,
    rotation, full_path, marking_path)
  select v_up.id, (x ->> 'idx')::int, v_up.exam_id, (x ->> 'copy_id')::uuid, (x -> 'e' ->> 'copy_page')::int,
    case when x ->> 'finding' = 'match' then (x ->> 'copy_booking')::uuid end,
    (case x ->> 'finding' when 'match' then 'matched' when 'blank' then 'blank' when 'no_code' then 'unmatched'
       else 'rejected' end)::public.page_state,
    (x -> 'e' ->> 'blank')::boolean,
    jsonb_build_object('sharpness', x -> 'e' -> 'quality' -> 'sharpness', 'brightness', x -> 'e' -> 'quality' -> 'brightness',
      'cut_off', x -> 'e' -> 'quality' -> 'cut_off', 'flags', x -> 'e' -> 'quality' -> 'flags'),
    (x -> 'e' ->> 'rotation')::int, x -> 'e' ->> 'full_path', x -> 'e' ->> 'marking_path'
  from jsonb_array_elements(v_found) x;

  if v_placed <> '{}'::jsonb then
    update public.script_exceptions e set page_id = p.id
    from public.script_pages p
    where p.upload_id = v_up.id and p.replaced_at is null and p.state = 'unmatched' and v_placed ? p.source_index::text
      and e.page_id = (v_placed -> p.source_index::text ->> 'id')::uuid and e.kind = 'uncoded_family_page' and e.state = 'open';
    update public.script_pages p set placed_after = (v_placed -> p.source_index::text ->> 'placed_after')::int
    where p.upload_id = v_up.id and p.replaced_at is null and p.state = 'unmatched' and v_placed ? p.source_index::text;
  end if;

  if v_home then
    -- Duplicates within the submission.
    update public.script_pages p
    set state = (case when r.rn = 1 then 'matched' else 'duplicate' end)::public.page_state
    from (
      select p2.id, row_number() over (
        partition by p2.copy_page
        order by public.script_page_poor(p2.quality, p2.marking_path, public.script_page_is_answer(p2.copy_id, p2.copy_page)),
                 (p2.quality ->> 'sharpness')::numeric desc nulls last, u.position nulls last, u.created_at, u.id,
                 p2.source_index) as rn
      from public.script_pages p2
      join public.script_uploads u on u.id = p2.upload_id
      where u.submission_id = v_sub.id and p2.replaced_at is null and p2.booking_id = v_sub.booking_id
        and p2.state in ('matched', 'duplicate')
    ) r
    where p.id = r.id and p.state <> (case when r.rn = 1 then 'matched' else 'duplicate' end)::public.page_state;

    -- The family's "Send as it is" (an open poor_quality exception) follows its page to the new run's page of the
    -- same copy page, the kept one first.
    update public.script_exceptions e set page_id = n.id
    from public.script_pages o
    cross join lateral (
      select n2.id from public.script_pages n2
      where n2.upload_id = v_up.id and n2.replaced_at is null and n2.booking_id = o.booking_id and n2.copy_page = o.copy_page
      order by (n2.state = 'matched') desc, n2.source_index
      limit 1
    ) n
    where o.id = e.page_id and o.id = any (v_old) and e.kind = 'poor_quality' and e.state = 'open';

    select * into v_x from public.scripts s where s.booking_id = v_sub.booking_id for update;
    if v_x.id is null and exists (
      select 1 from public.script_pages p join public.script_uploads u on u.id = p.upload_id
      where u.submission_id = v_sub.id and p.replaced_at is null and p.state = 'matched') then
      v_x := public.script_create(v_sub.booking_id, 'home', v_now);
    end if;

    if public.home_submission_assemble(v_sub.id, v_up.id, v_now) then
      v_changed := v_changed || v_x.id;
    end if;
  else
    -- Scanner file: per booking, each copy page this file (or its earlier run) touched is decided again between
    -- the booking's scanned pages of that copy page and the page the script shows there now.
    foreach v_b in array v_bookings loop
      select * into v_x from public.scripts s where s.booking_id = v_b for update;
      if v_x.state in ('ready_to_mark', 'marking', 'marked', 'checked', 'final') then
        continue;  -- a script being marked is never changed (its pages were classed not_expected above)
      end if;
      v_links := case when v_x.id is null then '{}'::jsonb else public.script_links(v_x.id) end;
      for v_slot in
        select distinct t.copy_page from (
          select p.copy_page from public.script_pages p
          where p.upload_id = v_up.id and p.replaced_at is null and p.state = 'matched' and p.booking_id = v_b
          union
          select (o ->> 'copy_page')::int from jsonb_array_elements(v_old_slots) o where (o ->> 'booking_id')::uuid = v_b
        ) t
        order by 1
      loop
        v_linked := (v_links ->> v_slot::text)::uuid;
        v_winner := null;
        select c.id into v_winner
        from (
          select p.id, p.quality, p.marking_path, p.copy_id, p.copy_page, p.source_index, p.upload_id
          from public.script_pages p join public.script_uploads u on u.id = p.upload_id
          where p.replaced_at is null and u.submission_id is null and p.booking_id = v_b and p.copy_page = v_slot
            and p.state in ('matched', 'duplicate')
            and public.script_page_elsewhere(p.id, v_x.id) is null  -- never a page another script shows (Ruling R37 2)
          union
          select p.id, p.quality, p.marking_path, p.copy_id, p.copy_page, p.source_index, p.upload_id
          from public.script_pages p where p.id = v_linked and p.replaced_at is null
            and public.script_page_elsewhere(p.id, v_x.id) is null
        ) c
        join public.script_uploads u on u.id = c.upload_id
        order by public.script_page_poor(c.quality, c.marking_path, public.script_page_is_answer(c.copy_id, c.copy_page)),
                 (c.quality ->> 'sharpness')::numeric desc nulls last, u.created_at, u.id, c.source_index
        limit 1;
        -- A page staff put in this slot keeps it (Ruling R36): the page scanned for it is set aside as a duplicate,
        -- and staff decide (keep the page already chosen, or use this page instead).
        if v_x.id is not null and v_linked is not null and public.script_slot_staff_placed(v_x.id, v_slot, v_linked)
           and exists (select 1 from public.script_pages p where p.id = v_linked and p.replaced_at is null) then
          v_winner := v_linked;
        end if;

        update public.script_pages p
        set state = (case when p.id = v_winner then 'matched' else 'duplicate' end)::public.page_state
        where p.replaced_at is null and p.booking_id = v_b and p.copy_page = v_slot and p.state in ('matched', 'duplicate')
          and exists (select 1 from public.script_uploads u where u.id = p.upload_id and u.submission_id is null)
          and public.script_page_elsewhere(p.id, v_x.id) is null
          and p.state <> (case when p.id = v_winner then 'matched' else 'duplicate' end)::public.page_state;
        delete from public.script_exceptions e where e.state = 'open' and e.kind = 'duplicate' and e.page_id = v_winner;
        insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
        select v_up.exam_id, 'duplicate', v_b, v_x.id, p.id, v_up.id,
          jsonb_build_object('copy_page', v_slot, 'kept_page_id', v_winner)
        from public.script_pages p
        where p.replaced_at is null and p.booking_id = v_b and p.copy_page = v_slot and p.state = 'duplicate'
          and exists (select 1 from public.script_uploads u where u.id = p.upload_id and u.submission_id is null)
          and public.script_page_elsewhere(p.id, v_x.id) is null
          and not exists (select 1 from public.script_exceptions e where e.page_id = p.id and e.kind = 'duplicate' and e.state = 'open');

        -- A slot whose page another script shows and that nothing else fills is left as it is here: the version
        -- write drops it and tells staff (a duplicate exception on the page, missing_pages for the slot).
        if v_winner is not null then
          v_links := v_links || jsonb_build_object(v_slot::text, v_winner);
        elsif v_linked is null or public.script_page_elsewhere(v_linked, v_x.id) is null then
          v_links := v_links - v_slot::text;
        end if;
      end loop;

      if v_x.id is null and v_links <> '{}'::jsonb then
        v_x := public.script_create(v_b, 'centre', v_now);
      end if;
      if v_x.id is not null then
        if public.script_version_write(v_x.id, v_links, null, v_up.id, 'scan_upload', v_now) then
          v_changed := v_changed || v_x.id;
        end if;
      end if;
    end loop;
  end if;

  -- The invariants (Rulings R34, R35, R37): no current link of a script this rerun touched points at a replaced page,
  -- or at a page another script shows. A script that still has one (the rerun did not decide that slot, or its undo
  -- brought an older version back) is written again with current pages only (script_version_write: a replaced page
  -- gives its slot to the file's current page matched to that candidate and copy page, else the slot is emptied and
  -- staff are told). The scripts whose version was undone go first: a page staff have since placed in another script
  -- stays there. Nothing is carried by position.
  for v_x in
    select s.* from public.scripts s
    where s.booking_id = any (v_bookings)
    order by (s.id = any (v_undone)) desc, s.id
    for update
  loop
    if public.script_stale_links(v_x.id) > 0 or public.script_shared_links(v_x.id) > 0 then
      if public.script_version_write(v_x.id, public.script_links(v_x.id), null, v_up.id, 'reprocessed', v_now) then
        v_changed := v_changed || v_x.id;
      end if;
    end if;
  end loop;

  -- No open exception stays on a page this rerun replaced: what it said is raised again for the new pages where it
  -- still holds (a family's "Send as it is" and placement moved above).
  delete from public.script_exceptions e where e.state = 'open' and e.page_id = any (v_old);

  -- The earlier run's pages that no version and no exception names any more are deleted; the rest stay, replaced.
  delete from public.script_pages p
  where p.id = any (v_old)
    and not exists (select 1 from public.script_page_links l where l.page_id = p.id)
    and not exists (select 1 from public.script_exceptions e where e.page_id = p.id);

  -- Exceptions about single pages.
  insert into public.script_exceptions (exam_id, kind, booking_id, page_id, upload_id, details)
  select v_up.exam_id, (x ->> 'finding')::public.exception_kind,
    case when v_home then v_sub.booking_id when x ->> 'finding' = 'not_expected' then (x ->> 'copy_booking')::uuid end,
    p.id, v_up.id,
    case x ->> 'finding'
      when 'unknown_code' then jsonb_build_object('code', x -> 'e' ->> 'code', 'copy_page', (x -> 'e' ->> 'copy_page')::int)
      when 'other_exam' then jsonb_build_object('copy_page', (x -> 'e' ->> 'copy_page')::int, 'other_exam_id', x ->> 'copy_exam')
      when 'not_expected' then jsonb_build_object('copy_id', x ->> 'copy_id', 'copy_page', (x -> 'e' ->> 'copy_page')::int,
        'reason', x ->> 'reason')
      else '{}'::jsonb
    end
  from jsonb_array_elements(v_found) x
  join public.script_pages p on p.upload_id = v_up.id and p.replaced_at is null and p.source_index = (x ->> 'idx')::int
  where (x ->> 'finding' in ('unknown_code', 'other_exam', 'not_expected') or (x ->> 'finding' = 'no_code' and not v_home));

  if not v_home then
    insert into public.script_exceptions (exam_id, kind, booking_id, page_id, upload_id, details)
    select v_up.exam_id, 'poor_quality', p.booking_id, p.id, v_up.id,
      jsonb_build_object('flags', p.quality -> 'flags', 'copy_page', p.copy_page, 'marking_picture', p.marking_path is not null)
    from public.script_pages p
    where p.upload_id = v_up.id and p.replaced_at is null
      and (p.quality -> 'flags' ?| array['blurred', 'dark', 'cut_off', 'layout_unexpected']
           or (p.state = 'matched' and p.marking_path is null and public.script_page_is_answer(p.copy_id, p.copy_page)));
  end if;

  foreach v_b in array v_changed loop
    perform public.script_raise_mixed(v_b, v_up.id);
  end loop;

  -- A page the prepare proved (it still has its marking picture) settles what a remask raised about it.
  perform public.script_page_marking_made(p.id) from public.script_pages p
  where p.upload_id = v_up.id and p.replaced_at is null and p.marking_path is not null;

  update public.script_exceptions e set script_id = s.id
  from public.scripts s
  where e.upload_id = v_up.id and e.script_id is null and s.booking_id = e.booking_id;

  update public.script_uploads set state = 'processed', sha256 = coalesce(sha256, p_sha256) where id = v_up.id;

  if v_home then
    perform public.home_submission_evaluate(v_sub.id, v_now);
  end if;
  for v_x in select s.* from public.scripts s where s.booking_id = any (v_bookings) order by s.booking_id loop
    perform public.script_evaluate_at(v_x.id, v_now);
  end loop;

  return jsonb_build_object('ok', true,
    'pages', (select count(*) from public.script_pages p where p.upload_id = v_up.id and p.replaced_at is null),
    'matched', (select count(*) from public.script_pages p where p.upload_id = v_up.id and p.replaced_at is null and p.state = 'matched'),
    'exceptions', (select count(*) from public.script_exceptions e where e.upload_id = v_up.id and e.state = 'open'));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Access: the new helpers are internal (the re-created functions keep their access).
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.script_booking_locked(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_elsewhere(uuid, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_shared_links(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_slots_dropped(uuid, jsonb, jsonb, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_extras_lock() from public, anon, authenticated, service_role;
