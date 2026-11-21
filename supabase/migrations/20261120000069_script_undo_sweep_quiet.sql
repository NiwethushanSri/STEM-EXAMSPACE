-- Phase 2 Task 12, fix round 1 (Ruling R39 1): the early sweep of a rerun's undone scripts tells staff only what stays.
--
-- 067 made an undone script give up, before the slot decision, the pages another script shows (Ruling R38), through
-- script_version_write, which at once raised an in_other_script duplicate and missing_pages for each slot given up. On
-- an ordinary rerun that reads the file as before, the slot decision then fills the slot again (b1's page 3 from the
-- same file), and the script was left complete but needing attention, with two open exceptions about nothing.
--
-- script_pages_record now gives those pages up quietly (a version written straight from script_links_current, raising
-- nothing), remembers the slots given up, and after every slot is decided raises the in_other_script duplicate and
-- missing_pages only for the slots the script still does not show. It also takes out of any open missing_pages the
-- slots this rerun added and then filled, and removes a missing_pages it raised that is left with none. R38 holds:
-- a page staff placed is never taken back, and no page is in two scripts. Only script_pages_record is re-created; it
-- keeps its access (service_role only).

-- ---------------------------------------------------------------------------------------------
-- script_pages_record: as 20261120000067, and (Ruling R39)
-- (1) the early sweep of undone scripts writes their versions without telling staff (no script_slots_dropped);
-- (2) after the slot decision and the final sweep, the slots the early sweep took that the script still does not show
--     are told to staff (script_slots_dropped);
-- (3) slots this rerun added to open missing_pages exceptions and then filled are taken out again; a missing_pages it
--     raised that is left empty is removed.
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
  v_r record;
  v_all jsonb;
  v_quiet jsonb;
  v_swept jsonb := '{}';
  v_mp_before jsonb;
  v_pages int[];
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

  -- The open missing_pages exceptions of these bookings as they are before this rerun writes anything: below, the
  -- slots this rerun added to them and then filled are taken out again (Ruling R39).
  select coalesce(jsonb_object_agg(e.id::text, coalesce(e.details -> 'pages', '[]'::jsonb)), '{}'::jsonb) into v_mp_before
  from public.script_exceptions e
  where e.kind = 'missing_pages' and e.state = 'open' and e.booking_id = any (v_bookings);

  -- Before anything is decided, an undone script gives up the pages another script shows now (Ruling R38): the other
  -- script took the page after the undone version was made (staff placed it there), so its slot is the one that
  -- holds. Doing this first means no script this rerun writes can lose such a page to the undone one. When two undone
  -- scripts show one page, the one holding it in a slot staff placed it in goes last, so it keeps the page. This is
  -- done quietly (Ruling R39): the slot decision below may fill the slot again, so staff are told only after it, of the
  -- slots given up here that nothing filled (v_swept).
  for v_x in
    select s.* from public.scripts s
    where s.id = any (v_undone)
    order by exists (select 1 from public.script_page_links l
                     where l.script_id = s.id and l.version = s.version
                       and public.script_page_elsewhere(l.page_id, s.id) is not null
                       and public.script_slot_staff_placed(s.id, l.copy_page, l.page_id)), s.id
  loop
    if public.script_shared_links(v_x.id) > 0 then
      v_all := public.script_links(v_x.id);
      v_quiet := public.script_links_current(v_x.id, v_all);
      if v_quiet <> v_all then
        insert into public.script_versions (script_id, version, created_at, reason, submission_id, upload_id)
        values (v_x.id, v_x.version + 1, v_now, 'reprocessed', null, v_up.id);
        insert into public.script_page_links (script_id, version, copy_page, page_id)
        select v_x.id, v_x.version + 1, t.k::int, t.v::uuid from jsonb_each_text(v_quiet) t(k, v);
        update public.scripts set version = v_x.version + 1 where id = v_x.id;
        v_changed := v_changed || v_x.id;
        v_swept := v_swept || jsonb_build_object(v_x.id::text,
          (select coalesce(jsonb_object_agg(t.key, t.value), '{}'::jsonb) from jsonb_each(v_all) t where not v_quiet ? t.key));
      end if;
    end if;
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
        -- The winner's open duplicate exceptions go, but never one saying another script's version asked for this page
        -- (in_other_script) unless the winner is linked here because staff placed it here (Ruling R38).
        delete from public.script_exceptions e
        where e.state = 'open' and e.kind = 'duplicate' and e.page_id = v_winner
          and (coalesce(e.details ->> 'reason', '') <> 'in_other_script'
               or (v_x.id is not null and public.script_slot_staff_placed(v_x.id, v_slot, v_winner)));
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
  -- staff are told). The scripts whose version was undone go first (they already gave up, before the slot decision,
  -- the pages another script showed): a page staff have since placed in another script stays there. Nothing is
  -- carried by position.
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

  -- Now that every slot is decided (Ruling R39): of the slots the early sweep took from an undone script, those its
  -- current version still does not show are told to staff (an in_other_script duplicate for a page another script
  -- shows, and missing_pages for the slot).
  for v_r in select t.key, t.value from jsonb_each(v_swept) t loop
    perform public.script_slots_dropped(v_r.key::uuid, v_r.value, public.script_links(v_r.key::uuid), v_up.id);
  end loop;

  -- A slot this rerun added to an open missing_pages and then filled is taken out of it again; a missing_pages this
  -- rerun raised that is left with no slot is removed (Ruling R39). Slots that were there before the rerun stay.
  for v_r in
    select e.id, e.details, s.id as script_id, v_mp_before -> e.id::text as before
    from public.script_exceptions e
    join public.scripts s on s.booking_id = e.booking_id
    where e.kind = 'missing_pages' and e.state = 'open' and e.booking_id = any (v_bookings)
  loop
    select coalesce(array_agg(t.n order by t.n), '{}') into v_pages
    from (select x::int as n from jsonb_array_elements_text(
            case when jsonb_typeof(v_r.details -> 'pages') = 'array' then v_r.details -> 'pages' else '[]'::jsonb end) x) t
    where (v_r.before is not null and v_r.before @> to_jsonb(t.n))
       or not (public.script_links(v_r.script_id) ? t.n::text);
    if to_jsonb(v_pages) is distinct from (v_r.details -> 'pages') then
      if cardinality(v_pages) = 0 and v_r.before is null then
        delete from public.script_exceptions e where e.id = v_r.id;
      else
        update public.script_exceptions e set details = e.details || jsonb_build_object('pages', to_jsonb(v_pages)) where e.id = v_r.id;
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
