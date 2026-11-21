-- Phase 2 Task 11 fix round 3 (Ruling R34): processing a file again never keeps a picture or a link that staff work
-- had made unsafe.
--
-- (a) After a prepare rerun, a new page whose earlier page (same file, same position) staff had touched (staff hidden
-- areas, a staff confirmation, a staff assignment, or that the rerun carried into a script) gets no marking picture
-- from the prepare, which knows nothing of that work: its marking_path is cleared and staff check its name again (an
-- open poor_quality exception, reprocessed).
-- (b) Invariant: after a rerun no current script link points at a page of that file the rerun replaced. Every such
-- link (whatever version wrote it) moves to this run's page at the same position, in a version owned by the staff
-- member who asked for the reprocess (not by the file, so a later rerun never undoes it); with no such page the slot
-- is emptied and staff are told (missing_pages, reason reprocessed). script_upload_stale_links counts breaches.
-- (c) A link moves only onto a page that belongs to no other candidate (no booking, or the script's own) and that no
-- script shows yet; otherwise the slot is emptied and staff told, so a page is never in two scripts.
-- (d) A stale_marking notice (a script past verification) is noted without the name check.

-- How many current script links point at a page of the file that a rerun replaced: 0 after every rerun (R34 b).
create function public.script_upload_stale_links(p_upload uuid)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int from public.script_page_links l
  join public.scripts s on s.id = l.script_id and l.version = s.version
  join public.script_pages p on p.id = l.page_id
  where p.upload_id = p_upload and p.replaced_at is not null
$$;

-- ---------------------------------------------------------------------------------------------
-- script_page_marking_lost: as 20261120000062, with p_extra: more details for the exception (such as reprocessed: the
-- file was processed again and staff check the page's name again).
-- ---------------------------------------------------------------------------------------------
drop function public.script_page_marking_lost(uuid, boolean);
create function public.script_page_marking_lost(p_page uuid, p_cleared boolean default true, p_extra jsonb default '{}')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_p public.script_pages%rowtype;
  v_e public.script_exceptions%rowtype;
  v_booking uuid;
  v_script uuid;
  v_copy_page int;
  v_marks jsonb := case when coalesce(p_cleared, true) then '{"from": "remask", "marking_picture": false}'::jsonb
                        else '{"from": "remask", "marking_picture": true, "stale_marking": true}'::jsonb end
                   || coalesce(p_extra, '{}'::jsonb);
begin
  select * into v_p from public.script_pages p where p.id = p_page;
  if not found then
    return;
  end if;
  select * into v_e from public.script_exceptions e
  where e.page_id = p_page and e.kind = 'poor_quality' and e.state = 'open' order by e.created_at, e.id limit 1;
  if v_e.id is not null then
    update public.script_exceptions e
    set details = e.details
      || case when e.details ->> 'from' is distinct from 'remask' and not e.details ? 'before_remask'
              then jsonb_build_object('before_remask', jsonb_build_object('from', e.details -> 'from', 'marking_picture', e.details -> 'marking_picture'))
              else '{}'::jsonb end
      || v_marks
    where e.id = v_e.id;
    return;
  end if;
  select s.booking_id, s.id, l.copy_page into v_booking, v_script, v_copy_page
  from public.script_page_links l join public.scripts s on s.id = l.script_id and l.version = s.version
  where l.page_id = p_page order by s.id limit 1;
  if v_booking is null then
    v_booking := coalesce(v_p.booking_id, (select hs.booking_id from public.script_uploads u
                                           join public.home_submissions hs on hs.id = u.submission_id where u.id = v_p.upload_id));
    select x.id into v_script from public.scripts x where x.booking_id = v_booking;
  end if;
  insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
  values (v_p.exam_id, 'poor_quality', v_booking, v_script, v_p.id, v_p.upload_id,
    jsonb_build_object('flags', coalesce(v_p.quality -> 'flags', '[]'::jsonb), 'copy_page', coalesce(v_copy_page, v_p.copy_page)) || v_marks);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_exception_confirm: as 20261120000061, and a stale_marking notice (a script past verification kept a marking
-- picture a failed remask could not make again) is noted without the name check: its areas can no longer change here.
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
-- script_pages_record: as 20261120000062, with Ruling R34 in place of R33's carry: (b, c) after the rerun no current
-- script link points at a replaced page of this file (carried to this run's page at the same position when it belongs to
-- no other candidate and no script shows it, in a staff-owned version; else the slot is emptied, missing_pages); (a) a
-- new page whose earlier page staff touched gets no marking picture from the prepare, and staff check its name again.
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
  v_carried uuid[] := '{}';
  v_pre jsonb;
  v_actor uuid;
  v_l record;
  v_cur uuid;
  v_n public.script_pages%rowtype;
  v_gone int[];
  v_rows int;
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
  else
    select sb.centre_id into v_centre from public.scan_batches sb where sb.id = v_up.batch_id;
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
    for update of s
  loop
    delete from public.script_page_links l where l.script_id = v_x.id and l.version = v_x.version;
    delete from public.script_versions v where v.script_id = v_x.id and v.version = v_x.version;
    update public.scripts set version = v_x.version - 1 where id = v_x.id;
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
      exists (select 1 from public.attendance a
              where a.exam_id = b.exam_id and a.student_id = b.student_id and a.status = 'absent') as absent
    from jsonb_array_elements(p_pages) e
    left join public.paper_copies c on c.code = e ->> 'code'
    left join public.exam_papers ep on ep.id = c.paper_id
    left join public.bookings b on b.id = c.booking_id
  ), g as (
    select f.*,
      case
        when f.e ->> 'code' is null then case when (f.e ->> 'blank')::boolean then 'blank' else 'no_code' end
        when f.copy_id is null then 'unknown_code'
        when f.copy_exam <> v_up.exam_id then 'other_exam'
        when (f.e ->> 'copy_page')::int > f.copy_pages then 'unknown_code'
        when v_home and f.copy_booking is distinct from v_sub.booking_id then 'not_expected'
        when not v_home and (f.b_status not in ('paid', 'cancel_requested') or f.b_sitting <> 'centre'
                             or f.b_centre is distinct from v_centre or f.absent) then 'not_expected'
        else 'match'
      end as finding,
      case
        when v_home then 'other_booking'
        when f.b_status not in ('paid', 'cancel_requested') then 'booking_status'
        when f.b_sitting <> 'centre' then 'home_sitting'
        when f.b_centre is distinct from v_centre then 'other_centre'
        else 'absent'
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

  -- What the scripts show of this file's earlier pages now (the versions this file made are undone): after the rerun no
  -- current link may still point at one of them (Ruling R34).
  select coalesce(jsonb_agg(jsonb_build_object('script_id', l.script_id, 'copy_page', l.copy_page, 'page_id', l.page_id)), '[]'::jsonb)
  into v_pre
  from public.script_page_links l join public.scripts s on s.id = l.script_id and l.version = s.version
  where l.page_id = any (v_old);

  -- A family's page with no code that staff had confirmed: its placement carried over, so staff confirm the new page
  -- again (it is not silently dropped from the script; Ruling R33).
  if v_home then
    insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
    select v_up.exam_id, 'uncoded_family_page', v_sub.booking_id, (select x.id from public.scripts x where x.booking_id = v_sub.booking_id),
      n.id, v_up.id, jsonb_build_object('after_page', n.placed_after, 'from', 'family', 'reprocessed', true)
    from public.script_pages o
    join public.script_pages n on n.upload_id = v_up.id and n.replaced_at is null and n.source_index = o.source_index
      and n.state = 'unmatched' and n.placed_after is not null
    where o.id = any (v_old)
      and exists (select 1 from public.script_exceptions e
                  where e.page_id = o.id and e.kind = 'uncoded_family_page' and e.state = 'resolved' and e.resolution = 'confirmed')
      and not exists (select 1 from public.script_exceptions e where e.page_id = n.id and e.kind = 'uncoded_family_page' and e.state = 'open');
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
          union
          select p.id, p.quality, p.marking_path, p.copy_id, p.copy_page, p.source_index, p.upload_id
          from public.script_pages p where p.id = v_linked and p.replaced_at is null
        ) c
        join public.script_uploads u on u.id = c.upload_id
        order by public.script_page_poor(c.quality, c.marking_path, public.script_page_is_answer(c.copy_id, c.copy_page)),
                 (c.quality ->> 'sharpness')::numeric desc nulls last, u.created_at, u.id, c.source_index
        limit 1;

        update public.script_pages p
        set state = (case when p.id = v_winner then 'matched' else 'duplicate' end)::public.page_state
        where p.replaced_at is null and p.booking_id = v_b and p.copy_page = v_slot and p.state in ('matched', 'duplicate')
          and exists (select 1 from public.script_uploads u where u.id = p.upload_id and u.submission_id is null)
          and p.state <> (case when p.id = v_winner then 'matched' else 'duplicate' end)::public.page_state;
        delete from public.script_exceptions e where e.state = 'open' and e.kind = 'duplicate' and e.page_id = v_winner;
        insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
        select v_up.exam_id, 'duplicate', v_b, v_x.id, p.id, v_up.id,
          jsonb_build_object('copy_page', v_slot, 'kept_page_id', v_winner)
        from public.script_pages p
        where p.replaced_at is null and p.booking_id = v_b and p.copy_page = v_slot and p.state = 'duplicate'
          and exists (select 1 from public.script_uploads u where u.id = p.upload_id and u.submission_id is null)
          and not exists (select 1 from public.script_exceptions e where e.page_id = p.id and e.kind = 'duplicate' and e.state = 'open');

        v_links := case when v_winner is null then v_links - v_slot::text
                        else v_links || jsonb_build_object(v_slot::text, v_winner) end;
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

  -- The invariant (Ruling R34): no current link points at a page of this file the rerun replaced. A slot that showed
  -- one, and that the rerun did not decide, moves to this run's page at the same position when that page belongs to no
  -- other candidate (no booking, or this script's) and no script shows it yet; else the slot is emptied and staff are
  -- told (missing_pages, reason reprocessed). The version is staff-owned (by whoever asked for the reprocess, not the
  -- file), so a later rerun never undoes it.
  select a.actor_id into v_actor from public.audit_log a
  where a.action = 'script_upload_reprocess' and a.target_type = 'script_upload' and a.target_id = v_up.id
  order by a.id desc limit 1;
  for v_x in
    select s.* from public.scripts s
    where s.id in (select (x ->> 'script_id')::uuid from jsonb_array_elements(v_pre) x)
       or exists (select 1 from public.script_page_links l where l.script_id = s.id and l.version = s.version and l.page_id = any (v_old))
    order by s.id
    for update
  loop
    v_links := public.script_links(v_x.id);
    v_gone := '{}';
    for v_l in
      select (x ->> 'copy_page')::int as slot, (x ->> 'page_id')::uuid as page_id
      from jsonb_array_elements(v_pre) x where (x ->> 'script_id')::uuid = v_x.id
      union
      select l.copy_page, l.page_id from public.script_page_links l
      where l.script_id = v_x.id and l.version = v_x.version and l.page_id = any (v_old)
      order by 1
    loop
      v_cur := (v_links ->> v_l.slot::text)::uuid;
      if v_cur is not null and v_cur <> v_l.page_id and not (v_cur = any (v_old)) then
        continue;  -- the rerun decided this slot
      end if;
      select n.* into v_n from public.script_pages n join public.script_pages o on o.id = v_l.page_id
      where n.upload_id = v_up.id and n.replaced_at is null and n.source_index = o.source_index;
      if v_n.id is not null and (v_n.booking_id is null or v_n.booking_id = v_x.booking_id)
         and not exists (select 1 from public.script_page_links l join public.scripts s on s.id = l.script_id and l.version = s.version
                         where l.page_id = v_n.id)
         and not exists (select 1 from jsonb_each_text(v_links) t where t.value = v_n.id::text) then
        v_links := v_links || jsonb_build_object(v_l.slot::text, v_n.id);
        v_carried := v_carried || v_n.id;
      else
        v_links := v_links - v_l.slot::text;
        v_gone := v_gone || v_l.slot;
      end if;
    end loop;
    if public.script_version_write(v_x.id, v_links, null, null, 'reprocessed', v_now) then
      update public.script_versions v set created_by = v_actor
      where v.script_id = v_x.id and v.version = (select s.version from public.scripts s where s.id = v_x.id);
      v_changed := v_changed || v_x.id;
    end if;
    if cardinality(v_gone) > 0 then
      update public.script_exceptions e
      set details = e.details || jsonb_build_object('pages', to_jsonb(array(
            select distinct t.n from unnest(array(select jsonb_array_elements_text(
              case when jsonb_typeof(e.details -> 'pages') = 'array' then e.details -> 'pages' else '[]'::jsonb end)::int) || v_gone) t(n)
            order by t.n)))
      where e.booking_id = v_x.booking_id and e.kind = 'missing_pages' and e.state = 'open';
      get diagnostics v_rows = row_count;
      if v_rows = 0 then
        insert into public.script_exceptions (exam_id, kind, booking_id, script_id, upload_id, details)
        values (v_x.exam_id, 'missing_pages', v_x.booking_id, v_x.id, v_up.id,
          jsonb_build_object('pages', to_jsonb(array(select distinct t from unnest(v_gone) t order by t)), 'reason', 'reprocessed'));
      end if;
    end if;
  end loop;
  -- A carried page was placed by staff: what this rerun found about it (a duplicate of a page kept elsewhere) is closed
  -- as kept where staff placed it; its name check is asked for below.
  with closed as (
    update public.script_exceptions e
    set state = 'resolved', resolution = 'assigned', resolved_by = v_actor, resolved_at = v_now,
        reason = 'Kept where staff placed it (the file was processed again)'
    where e.page_id = any (v_carried) and e.state = 'open' and e.kind in ('duplicate', 'no_code', 'unknown_code', 'not_expected', 'other_exam')
    returning e.id)
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  select v_actor, 'script_exception_assigned', 'script_exception', c.id, 'Kept where staff placed it (the file was processed again)' from closed c;

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
  where (x ->> 'finding' in ('unknown_code', 'other_exam', 'not_expected') or (x ->> 'finding' = 'no_code' and not v_home))
    and not (p.id = any (v_carried));  -- a page staff placed, carried over: its name check is asked for instead

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

  -- A new page whose earlier page staff touched (hidden areas, a confirmation, an assignment, or carried here) gets no
  -- marking picture from the prepare, which knows nothing of that: staff check its name again (Ruling R34 a). A family's
  -- placed page asked to be confirmed again (above) is left to that exception.
  for v_n in
    select n.* from public.script_pages n
    join public.script_pages o on o.upload_id = v_up.id and o.id = any (v_old) and o.source_index = n.source_index
    where n.upload_id = v_up.id and n.replaced_at is null
      and (n.id = any (v_carried)
           or exists (select 1 from public.script_page_hidden_areas a where a.page_id = o.id)
           or public.script_page_confirm_given(o.id)
           or exists (select 1 from public.script_exceptions e where e.page_id = o.id and e.state = 'resolved' and e.resolution = 'assigned'))
      and not exists (select 1 from public.script_exceptions e where e.page_id = n.id and e.kind = 'uncoded_family_page' and e.state = 'open')
    order by n.source_index
  loop
    if v_n.marking_path is not null then
      update public.script_pages set marking_path = null where id = v_n.id;
    end if;
    perform public.script_page_marking_lost(v_n.id, true, '{"reprocessed": true}'::jsonb);
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
revoke execute on function public.script_upload_stale_links(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_marking_lost(uuid, boolean, jsonb) from public, anon, authenticated, service_role;
