-- Phase 2 Task 11 fix round 4, addition (Ruling R36).
--
-- (1) A slot staff filled (a version staff made put that page there) is not taken over silently by a page scanned
-- later for the same candidate and copy page: the staff-placed page stays, and the scanned page is set aside as a
-- duplicate with an open duplicate exception, so staff decide ("keep the page already chosen" / "use this page
-- instead").
-- (2) script_detail says for each file whether it may be processed again: reprocess_refused is null, or why not
-- (script_locked, or the kind of staff work script_upload_reprocess answers with staff_changes).

-- Whether staff put this page in this slot of the script: a version staff made shows it there, and the version before
-- did not.
create function public.script_slot_staff_placed(p_script uuid, p_copy_page int, p_page uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.script_page_links l
    join public.script_versions v on v.script_id = l.script_id and v.version = l.version
    where l.script_id = p_script and l.copy_page = p_copy_page and l.page_id = p_page
      and (v.created_by is not null or (v.upload_id is null and v.submission_id is null))
      and not exists (select 1 from public.script_page_links o
                      where o.script_id = l.script_id and o.version = l.version - 1 and o.copy_page = l.copy_page and o.page_id = l.page_id))
$$;

-- Why a file may not be processed again, as script_upload_reprocess would refuse it, or null: script_locked (a script
-- being marked shows its pages or is its candidate's), else the kind of staff work (script_upload_staff_changes).
create function public.script_upload_reprocess_refused(p_upload uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when exists (select 1 from public.scripts s
                 where s.booking_id = any (public.script_upload_bookings(p_upload))
                   and s.state in ('ready_to_mark', 'marking', 'marked', 'checked', 'final')) then 'script_locked'
    else public.script_upload_staff_changes(p_upload, true)
  end
$$;

-- ---------------------------------------------------------------------------------------------
-- script_detail: as 20261120000059, and each upload says why it may not be processed again (reprocess_refused; null
-- when it may).
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
-- script_pages_record: as 20261120000064, and a slot staff filled keeps its page against a page scanned for it
-- (Ruling R36 1).
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
  v_fresh jsonb;
  v_keep text;
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
        when f.e ->> 'code' is null then case when (f.e ->> 'blank')::boolean then 'blank' else 'no_code' end
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
          union
          select p.id, p.quality, p.marking_path, p.copy_id, p.copy_page, p.source_index, p.upload_id
          from public.script_pages p where p.id = v_linked and p.replaced_at is null
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

  -- The invariant (Rulings R34, R35): no current link of a script this rerun touched points at a replaced page. A slot
  -- that still shows one (the rerun did not decide it, or its undo brought an older version back) gets the file's current
  -- page matched to that candidate and copy page, else it is emptied and staff are told (missing_pages, reason
  -- reprocessed). Nothing is carried by position: staff-placed pages are never replaced (the gate above).
  for v_x in
    select s.* from public.scripts s
    where s.booking_id = any (v_bookings) and public.script_stale_links(s.id) > 0
    order by s.id
    for update
  loop
    v_links := public.script_links(v_x.id);
    v_fresh := public.script_links_current(v_x.id, v_links);
    select coalesce(array_agg(t.key::int order by t.key::int), '{}') into v_gone
    from jsonb_each_text(v_links) t where not v_fresh ? t.key;
    if public.script_version_write(v_x.id, v_fresh, null, v_up.id, 'reprocessed', v_now) then
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
revoke execute on function public.script_slot_staff_placed(uuid, int, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_upload_reprocess_refused(uuid) from public, anon, authenticated, service_role;
