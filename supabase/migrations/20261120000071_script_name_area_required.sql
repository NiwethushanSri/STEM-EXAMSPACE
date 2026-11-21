-- Phase 2 final review, fix wave (Ruling R40, C1 — privacy).
-- A page with a copy code always carries the printed name box. When its layout was not proved (for example a copy
-- printed with "Fit to page"), the nominal band at the top of the picture does not cover that box, so "There is no
-- name on this page" must never confirm it: staff draw a hidden area over the name, and the confirmation holds while
-- that set of areas (and the page's turn) stays as it was (Ruling R32).
--   script_page_confirmed: a "no name" confirmation counts only for a page with no copy (no code, or an unknown one).
--   script_exception_confirm: for a name-checked page with a copy and no staff hidden area, "no name" is refused with
--     the code name_area_required (without "no name" it stays name_not_hidden). No "no_name" mark is kept for a page
--     with a copy.
-- Pages with no code are as they were (Ruling R31).

create or replace function public.script_page_confirmed(p_page uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
      select (exists (select 1 from public.script_page_hidden_areas a where a.page_id = p_page)
              or (coalesce(e.details ->> 'no_name', '') = 'true' and p.copy_id is null
                  and not exists (select 1 from public.script_exceptions v
                                  where v.page_id = p_page and v.kind = 'name_visible' and v.state = 'resolved'
                                    and v.id <> e.id
                                    and public.script_exception_seq(v.id) > coalesce(public.script_exception_seq(e.id), 0))))
             and e.details ->> 'confirmed_rotation' = p.rotation::text
             and e.details ->> 'confirmed_areas' = public.script_page_areas_key(p.id)
      from public.script_exceptions e
      join public.script_pages p on p.id = e.page_id
      where e.page_id = p_page and e.state = 'resolved' and e.details ? 'confirmed_rotation'
        and ((e.resolution = 'confirmed' and e.kind in ('poor_quality', 'name_visible', 'uncoded_family_page'))
             or (e.resolution = 'assigned' and e.kind in ('no_code', 'unknown_code', 'uncoded_family_page')))
      order by public.script_exception_seq(e.id) desc nulls last, e.resolved_at desc nulls last, e.created_at desc, e.id desc
      limit 1), false)
    and not exists (select 1 from public.script_exceptions v where v.page_id = p_page and v.kind = 'name_visible' and v.state = 'open')
$$;

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
  v_coded boolean;
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
  v_coded := v_e.page_id is not null
    and exists (select 1 from public.script_pages p where p.id = v_e.page_id and p.copy_id is not null);
  if v_name_check and not exists (select 1 from public.script_page_hidden_areas a where a.page_id = v_e.page_id) then
    if not coalesce(p_no_name, false) then
      return jsonb_build_object('ok', false, 'code', 'name_not_hidden');
    end if;
    -- A page with a code carries the printed name box: "no name" is never taken for it (Ruling R40).
    if v_coded then
      return jsonb_build_object('ok', false, 'code', 'name_area_required');
    end if;
  end if;

  if v_name_check then
    -- The confirmation holds for the page as staff saw it: its turn and its staff hidden areas now (Ruling R32).
    update public.script_exceptions
    set details = details || public.script_page_binding(v_e.page_id)
                  || case when coalesce(p_no_name, false) and not v_coded then '{"no_name": true}'::jsonb else '{}'::jsonb end
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
