-- Phase 2 final review, fix wave (Ruling R40, I1): large scanner files and large centres.
--
-- What was slow. Right after a deploy the script tables have been analysed while empty, so the planner takes each of
-- them for a table of one row. It then joins them in any order, and may run a helper function for every row of a table
-- before the cheap conditions have cut the rows down. Measured in that state, 100 candidates x 20 pages from one scan
-- file:
--   script_links_current asked script_page_elsewhere for every page of the table, once per script (about 204,000
--     calls), and script_evaluate_at ran script_page_copy for every page of the table, once per script:
--     script_pages_record took 164 s and scan_centre_complete 146 s;
--   with those two put right, the three-table joins of script_raise_mixed, script_shared_links and
--     scan_booking_complete (links, pages, copies) still took 70 to 110 ms per script.
-- PostgREST stops a statement after 8 s.
--
-- What changes. No rule changes: one page per script, staff slots kept, dropped slots raise missing_pages, R31-R39.
-- The work per script now starts from the script's own links (one small list of page ids) and then reads one table
-- at a time by those ids, so no statement's cost depends on the order the planner picks for a join:
--   - script_pages_elsewhere (new): of a list of pages, those another script's current version shows, worked out once
--     for the list; script_links_current and script_shared_links use it instead of asking page by page;
--   - script_links, script_stale_links, script_slot_copy, script_raise_mixed, script_slots_dropped,
--     script_evaluate_at and scan_booking_complete read the links first, then the pages, then the copies;
--   - script_slot_copy: a candidate with one copy has that one, nothing is counted; script_raise_mixed: linked pages
--     of one copy raise nothing;
--   - script_evaluate_at looks only at the script's linked pages that have no marking picture, and works out the
--     script's copy once, when such a page exists (it was worked out for every linked page);
--   - an index for a booking's current pages by copy page (the slot decision of script_pages_record), and one for the
--     versions a file made (its undo).
-- Measured after, in the same state: see the timing guard supabase/tests/037_script_scale.test.sql.
--
-- The service role's statements (the processing server's calls through the API) may run 5 minutes; the authenticated
-- role keeps its 8 s. PostgREST applies a role's own statement_timeout to the calls it makes as that role.

create index script_pages_slot_idx on public.script_pages (booking_id, copy_page) where replaced_at is null;
create index script_versions_upload_idx on public.script_versions (upload_id) where upload_id is not null;

alter role service_role set statement_timeout = '5min';
notify pgrst, 'reload config';

-- The planner's row counts for the script tables, brought up to date when they are far behind: a table of 200 rows or
-- more of which the planner knows less than half. It is always so for the first large files after a deploy (the tables
-- were last analysed empty, and the automatic analyse only sees rows once their transaction is over, a minute or so
-- later); with such counts a join can be planned as if its tables held one row. The rows of a table are counted
-- cheaply: the statistics collector's live rows plus the rows this transaction has inserted. Called by
-- script_pages_record once it holds its locks and again once its pages are in; it does nothing in the usual case.
-- ANALYZE holds its table lock to the end of the transaction, which only makes two such first records queue.
create function public.script_stats_refresh()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_t record;
begin
  for v_t in
    select c.oid, c.relname, c.reltuples,
      pg_catalog.pg_stat_get_live_tuples(c.oid) + pg_catalog.pg_stat_get_xact_tuples_inserted(c.oid) as n
    from pg_catalog.pg_class c
    where c.oid in ('public.script_pages'::regclass, 'public.script_page_links'::regclass, 'public.script_versions'::regclass,
                    'public.scripts'::regclass, 'public.script_exceptions'::regclass, 'public.script_uploads'::regclass)
    order by c.relname
  loop
    if v_t.n >= 200 and v_t.reltuples < v_t.n / 2 then
      execute format('analyze public.%I', v_t.relname);
    end if;
  end loop;
end;
$$;
revoke execute on function public.script_stats_refresh() from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- script_links: as 20261120000052 (a script's current links, {copy page: page id}); the version first, then its links.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_links(p_script uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_version int;
  v_out jsonb;
begin
  select s.version into v_version from public.scripts s where s.id = p_script;
  select coalesce(jsonb_object_agg(l.copy_page::text, l.page_id), '{}'::jsonb) into v_out
  from public.script_page_links l where l.script_id = p_script and l.version = v_version;
  return v_out;
end;
$$;

-- Of these pages, the ones another script's current version shows (p_script null: any script's). Worked out once for
-- the whole list: the links to these pages from other scripts, then whether each is of its script's current version.
create function public.script_pages_elsewhere(p_pages uuid[], p_script uuid)
returns uuid[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_out uuid[] := '{}';
  v_r record;
begin
  if p_pages is null or cardinality(p_pages) = 0 then
    return v_out;
  end if;
  for v_r in
    select l.page_id, l.script_id, l.version from public.script_page_links l
    where l.page_id = any (p_pages) and l.script_id is distinct from p_script
  loop
    if not v_r.page_id = any (v_out)
       and exists (select 1 from public.scripts s where s.id = v_r.script_id and s.version = v_r.version) then
      v_out := v_out || v_r.page_id;
    end if;
  end loop;
  return v_out;
end;
$$;
revoke execute on function public.script_pages_elsewhere(uuid[], uuid) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- script_shared_links: as 20261120000066 (how many pages a script shows that another script's current version shows
-- too: always 0).
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_shared_links(p_script uuid)
returns int
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return cardinality(public.script_pages_elsewhere(
    array(select t.value::uuid from jsonb_each_text(public.script_links(p_script)) t), p_script));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_stale_links: as 20261120000064 (how many of a script's current links show a page a rerun replaced).
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_stale_links(p_script uuid)
returns int
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ids uuid[] := array(select t.value::uuid from jsonb_each_text(public.script_links(p_script)) t);
begin
  if cardinality(v_ids) = 0 then
    return 0;
  end if;
  return (select count(*)::int from public.script_pages p where p.id = any (v_ids) and p.replaced_at is not null);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_links_current: as 20261120000066 (links to pages that are current and that no other script's current version
-- shows; a replaced page gives its slot to its file's current page matched to that candidate and copy page, the first
-- by position that is free).
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
  v_ids uuid[];
  v_else uuid[];
  v_out jsonb := '{}'::jsonb;
  v_replaced jsonb := '{}'::jsonb;  -- {page id: its file}, for the pages asked for that a rerun replaced
  v_p record;
  v_r record;
  v_n record;
begin
  select s.booking_id into v_booking from public.scripts s where s.id = p_script;
  v_ids := array(select t.value::uuid from jsonb_each_text(coalesce(p_links, '{}'::jsonb)) t);
  if cardinality(v_ids) = 0 then
    return v_out;
  end if;
  v_else := public.script_pages_elsewhere(v_ids, p_script);
  for v_p in select p.id, p.upload_id, p.replaced_at from public.script_pages p where p.id = any (v_ids) loop
    if v_p.replaced_at is not null then
      v_replaced := v_replaced || jsonb_build_object(v_p.id::text, v_p.upload_id);
    elsif not v_p.id = any (v_else) then
      v_out := v_out || (select jsonb_object_agg(t.key, t.value) from jsonb_each_text(p_links) t where t.value = v_p.id::text);
    end if;
  end loop;
  if v_replaced = '{}'::jsonb then
    return v_out;
  end if;
  for v_r in
    select t.key, (v_replaced ->> t.value)::uuid as upload_id
    from jsonb_each_text(p_links) t where v_replaced ? t.value
    order by t.key::int
  loop
    for v_n in
      select n.id from public.script_pages n
      where n.upload_id = v_r.upload_id and n.replaced_at is null and n.state = 'matched'
        and n.booking_id = v_booking and n.copy_page = v_r.key::int
      order by n.source_index
    loop
      if not exists (select 1 from jsonb_each_text(v_out) x where x.value = v_n.id::text)
         and public.script_page_elsewhere(v_n.id, p_script) is null then
        v_out := v_out || jsonb_build_object(v_r.key, v_n.id);
        exit;
      end if;
    end loop;
  end loop;
  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_slots_dropped: as 20261120000066. The slots left out are read first, and only their pages are looked at.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_slots_dropped(p_script uuid, p_links jsonb, p_written jsonb, p_upload uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_x public.scripts%rowtype;
  v_gone int[];
  v_shared boolean := true;
  v_rows int;
  v_r record;
  v_p public.script_pages%rowtype;
  v_other uuid;
begin
  select coalesce(array_agg(t.key::int order by t.key::int), '{}') into v_gone
  from jsonb_each_text(coalesce(p_links, '{}'::jsonb)) t where not coalesce(p_written, '{}'::jsonb) ? t.key;
  if cardinality(v_gone) = 0 then
    return;
  end if;
  select * into v_x from public.scripts s where s.id = p_script;

  -- Each slot left out: a current page another script shows gets an open duplicate exception (once per booking); the
  -- reason of a new missing_pages is in_other_script only when every slot left out is such a page.
  for v_r in
    select t.key::int as copy_page, t.value::uuid as page_id
    from jsonb_each_text(p_links) t where t.key::int = any (v_gone)
    order by t.key::int
  loop
    select * into v_p from public.script_pages p where p.id = v_r.page_id;
    v_other := case when v_p.id is not null and v_p.replaced_at is null then public.script_page_elsewhere(v_p.id, v_x.id) end;
    if v_other is null then
      v_shared := false;
    elsif not exists (select 1 from public.script_exceptions e
                      where e.page_id = v_p.id and e.kind = 'duplicate' and e.state = 'open' and e.booking_id = v_x.booking_id) then
      insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
      values (v_x.exam_id, 'duplicate', v_x.booking_id, v_x.id, v_p.id, v_p.upload_id,
        jsonb_build_object('copy_page', v_r.copy_page, 'reason', 'in_other_script', 'other_script_id', v_other));
    end if;
  end loop;

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
-- script_slot_copy: as 20261120000062 (the candidate's copy a script's slots are of: the one of the paper version most
-- of its linked pages are from, else the latest). A candidate with one copy has that one: nothing is counted.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_slot_copy(p_script uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_booking uuid;
  v_copy uuid;
  v_n int;
  v_ids uuid[];
  v_paper uuid;
begin
  select s.booking_id into v_booking from public.scripts s where s.id = p_script;
  if not found then
    return null;
  end if;
  select count(*), (array_agg(c.id))[1] into v_n, v_copy from public.paper_copies c where c.booking_id = v_booking;
  if v_n <= 1 then
    return v_copy;
  end if;
  v_ids := array(select t.value::uuid from jsonb_each_text(public.script_links(p_script)) t);
  select pc.paper_id into v_paper
  from public.script_pages p join public.paper_copies pc on pc.id = p.copy_id
  where p.id = any (v_ids)
  group by pc.paper_id order by count(*) desc, pc.paper_id limit 1;
  select c.id into v_copy from public.paper_copies c
  where c.booking_id = v_booking
  order by (c.paper_id is not distinct from v_paper) desc, c.created_at desc, c.id
  limit 1;
  return v_copy;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_raise_mixed: as 20261120000052 (an open mixed_versions exception for a script whose current pages are of two
-- paper versions, once). Linked pages of one copy are of one paper: nothing more is read.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_raise_mixed(p_script uuid, p_upload uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_x public.scripts%rowtype;
  v_ids uuid[];
  v_copies uuid[];
  v_papers jsonb;
  v_n int;
begin
  select * into v_x from public.scripts s where s.id = p_script;
  if not found then
    return;
  end if;
  v_ids := array(select l.page_id from public.script_page_links l where l.script_id = v_x.id and l.version = v_x.version);
  v_copies := array(select distinct p.copy_id from public.script_pages p where p.id = any (v_ids) and p.copy_id is not null);
  if cardinality(v_copies) <= 1 then
    return;
  end if;
  select jsonb_agg(distinct c.paper_id), count(distinct c.paper_id) into v_papers, v_n
  from public.paper_copies c where c.id = any (v_copies);
  if coalesce(v_n, 0) <= 1
     or exists (select 1 from public.script_exceptions e where e.script_id = v_x.id and e.kind = 'mixed_versions' and e.state = 'open') then
    return;
  end if;
  insert into public.script_exceptions (exam_id, kind, booking_id, script_id, upload_id, details)
  values (v_x.exam_id, 'mixed_versions', v_x.booking_id, v_x.id, p_upload, jsonb_build_object('paper_ids', v_papers));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_evaluate_at: as 20261120000062. The same rules, read from the script's own links:
--   - "a file of a page it shows is still being processed" and "a page it shows was refused" look at its linked pages
--     by their ids;
--   - "an answer page it shows has no marking picture" looks only at its linked pages with no marking picture (or
--     replaced), one by one, and the script's copy (script_slot_copy) is worked out once, when such a page exists;
--   - a family's extra pages are looked for only when the booking has a submission that was handed in.
-- ---------------------------------------------------------------------------------------------
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
  v_unmarked boolean := false;
  v_links jsonb;
  v_ids uuid[];
  v_uploads uuid[];
  v_r record;
  v_slot_copy uuid;
  v_slot_copy_known boolean := false;
  v_copy uuid;
  v_copy_page int;
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

  -- The script's current links, {copy page: page id}, and the pages they show.
  select coalesce(jsonb_object_agg(l.copy_page::text, l.page_id), '{}'::jsonb) into v_links
  from public.script_page_links l where l.script_id = v_x.id and l.version = v_x.version;
  v_ids := array(select t.value::uuid from jsonb_each_text(v_links) t);

  v_busy := coalesce(v_sub_state = 'checking', false)
    or exists (select 1 from public.script_uploads u
               where u.state in ('queued', 'processing')
                 and (u.booking_id = v_x.booking_id
                      or u.submission_id in (select s.id from public.home_submissions s where s.booking_id = v_x.booking_id)));
  if not v_busy and cardinality(v_ids) > 0 then
    v_uploads := array(select distinct p.upload_id from public.script_pages p where p.id = any (v_ids));
    v_busy := exists (select 1 from public.script_uploads u where u.id = any (v_uploads) and u.state in ('queued', 'processing'));
  end if;
  v_open := exists (select 1 from public.script_exceptions e
                    where e.state = 'open'
                      and (e.script_id = v_x.id or (e.script_id is null and e.booking_id = v_x.booking_id)))
    or (cardinality(v_ids) > 0
        and exists (select 1 from public.script_exceptions e
                    where e.page_id = any (v_ids) and e.state = 'resolved'
                      and e.resolution in ('rejected', 'blank', 'set_aside', 'submission_rejected')));  -- script_page_refused
  -- An answer page it shows (a page staff refused aside), or a family's confirmed extra page, with no marking picture:
  -- markers could not see it, so the script is not verified (Ruling R32 d). An answer page is one by its own copy page
  -- or by the slot the script shows it at (Ruling R33).
  if cardinality(v_ids) > 0 then
    for v_r in
      select p.id, p.copy_id, p.copy_page from public.script_pages p
      where p.id = any (v_ids) and (p.marking_path is null or p.replaced_at is not null)
    loop
      if public.script_page_refused(v_r.id) then
        continue;
      end if;
      v_copy := v_r.copy_id;
      v_copy_page := v_r.copy_page;
      if v_copy is null or v_copy_page is null then  -- a page with no code: the copy and page of the slot it is linked at
        select t.copy_id, t.copy_page into v_copy, v_copy_page from public.script_page_copy(v_r.id) t;
      end if;
      if coalesce(public.script_page_is_answer(v_copy, v_copy_page), false) then
        v_unmarked := true;
        exit;
      end if;
      if not v_slot_copy_known then
        v_slot_copy := public.script_slot_copy(v_x.id);
        v_slot_copy_known := true;
      end if;
      if exists (select 1 from jsonb_each_text(v_links) t
                 where t.value = v_r.id::text and public.script_page_is_answer(v_slot_copy, t.key::int)) then
        v_unmarked := true;
        exit;
      end if;
    end loop;
  end if;
  if not v_unmarked
     and exists (select 1 from public.home_submissions hs
                 where hs.booking_id = v_x.booking_id and hs.state not in ('draft', 'rejected')) then
    v_unmarked := exists (select 1 from public.script_extra_pages(v_x.id) xp join public.script_pages p on p.id = xp.page_id
                          where p.marking_path is null);
  end if;
  v_state := case
    when v_busy then 'checking'
    when v_complete and not v_open and not v_unmarked then 'verified'
    when v_complete and v_unmarked then 'needs_attention'
    when v_x.source = 'centre' and not v_complete and not v_open then 'receiving'
    else 'needs_attention'
  end;

  if (v_x.state, v_x.complete, v_x.received_at) is distinct from (v_state, v_complete, v_received) then
    update public.scripts set state = v_state, complete = v_complete, received_at = v_received where id = v_x.id;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- scan_booking_complete: as 20261120000057. The script's links are read once; its pages and their copies are then read
-- by their ids. The answer pages still missing are worked out from that list, not asked page by page.
-- ---------------------------------------------------------------------------------------------
create or replace function public.scan_booking_complete(p_booking uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := now();
  v_b public.bookings%rowtype;
  v_x public.scripts%rowtype;
  v_links jsonb := '{}'::jsonb;
  v_ids uuid[] := '{}';
  v_copy_of jsonb := '{}'::jsonb;  -- {page id: its copy} for the linked pages with a code
  v_paper_of jsonb := '{}'::jsonb;  -- {copy id: its paper}
  v_papers uuid[];
  v_paper uuid;
  v_answers int[];
  v_filled int[];
  v_dismissed int[];
  v_missing int[] := '{}';
  v_details jsonb;
  v_outcome text;
  v_rows int;
begin
  select * into v_b from public.bookings b where b.id = p_booking;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('script_booking:' || v_b.id::text, 0));
  select * into v_x from public.scripts s where s.booking_id = v_b.id for update;

  if not (v_b.sitting = 'centre' and v_b.status in ('paid', 'cancel_requested')
          and exists (select 1 from public.attendance a
                      where a.exam_id = v_b.exam_id and a.student_id = v_b.student_id and a.status in ('present', 'late'))) then
    update public.script_exceptions e
    set state = 'resolved', resolved_by = v_actor, resolved_at = v_now, resolution = 'not_expected'
    where e.booking_id = v_b.id and e.kind = 'missing_pages' and e.state = 'open';
    get diagnostics v_rows = row_count;
    if v_rows > 0 and v_x.id is not null then
      perform public.script_evaluate(v_x.id);
    end if;
    return jsonb_build_object('ok', true, 'booking_id', v_b.id, 'outcome', 'not_candidate', 'pages', '[]'::jsonb,
      'complete', coalesce(v_x.complete, false));
  end if;
  if v_x.id is not null and v_x.state not in ('receiving', 'checking', 'needs_attention', 'verified') then
    return jsonb_build_object('ok', true, 'booking_id', v_b.id, 'outcome', 'past_verification', 'pages', '[]'::jsonb,
      'complete', v_x.complete);
  end if;

  -- The script's current links, the copy of each linked page that has a code, and each such copy's paper.
  if v_x.id is not null then
    select coalesce(jsonb_object_agg(l.copy_page::text, l.page_id), '{}'::jsonb) into v_links
    from public.script_page_links l where l.script_id = v_x.id and l.version = v_x.version;
    v_ids := array(select t.value::uuid from jsonb_each_text(v_links) t);
  end if;
  if cardinality(v_ids) > 0 then
    select coalesce(jsonb_object_agg(p.id::text, p.copy_id), '{}'::jsonb) into v_copy_of
    from public.script_pages p where p.id = any (v_ids) and p.copy_id is not null;
    select coalesce(jsonb_object_agg(c.id::text, c.paper_id), '{}'::jsonb) into v_paper_of
    from public.paper_copies c where c.id = any (array(select distinct t.value::uuid from jsonb_each_text(v_copy_of) t));
  end if;
  v_papers := array(select distinct t.value::uuid from jsonb_each_text(v_paper_of) t);

  if cardinality(v_papers) = 1 then
    v_paper := v_papers[1];
  else
    select c.paper_id into v_paper from public.paper_copies c where c.booking_id = v_b.id order by c.created_at desc, c.id limit 1;
    if v_paper is null then
      select p.id into v_paper from public.exam_papers p
      where p.exam_id = v_b.exam_id and p.kind = 'paper' and p.superseded_at is null order by p.version desc limit 1;
    end if;
  end if;
  select coalesce(array_agg(r.page order by r.page), '{}') into v_answers
  from public.paper_page_roles r where r.paper_id = v_paper and r.role = 'answer';

  if cardinality(v_answers) = 0 then
    v_outcome := 'no_paper';
    v_details := jsonb_build_object('pages', '[]'::jsonb, 'reason', 'no_paper');
  else
    -- A slot is filled by a linked page that exists and has no code, or whose copy is of this paper.
    v_filled := array(
      select t.key::int from jsonb_each_text(v_links) t
      where (not v_copy_of ? t.value and exists (select 1 from public.script_pages p where p.id = t.value::uuid))
         or (v_paper_of ->> (v_copy_of ->> t.value))::uuid = v_paper);
    v_dismissed := array(
      select d.page::int from public.script_exceptions e
      cross join lateral jsonb_array_elements_text(
        case when jsonb_typeof(e.details -> 'dismissed') = 'array' then e.details -> 'dismissed' else '[]'::jsonb end) d(page)
      where e.booking_id = v_b.id and e.kind = 'missing_pages' and d.page ~ '^[0-9]+$');
    select coalesce(array_agg(a.page order by a.page), '{}') into v_missing
    from unnest(v_answers) a(page)
    where not a.page = any (v_filled) and not a.page = any (v_dismissed);
    v_outcome := case
      when cardinality(v_missing) > 0 then 'missing'
      when cardinality(v_papers) > 1 then 'mixed'
      when v_x.id is null then 'no_script'
      else 'complete'
    end;
    v_details := jsonb_build_object('pages', to_jsonb(v_missing));
  end if;

  if v_outcome in ('no_paper', 'missing') then
    update public.script_exceptions e
    set details = (e.details - 'reason') || v_details, script_id = coalesce(e.script_id, v_x.id)
    where e.booking_id = v_b.id and e.kind = 'missing_pages' and e.state = 'open';
    get diagnostics v_rows = row_count;
    if v_rows = 0 then
      insert into public.script_exceptions (exam_id, kind, booking_id, script_id, details)
      values (v_b.exam_id, 'missing_pages', v_b.id, v_x.id, v_details);
    end if;
  else
    update public.script_exceptions e
    set state = 'resolved', resolved_by = v_actor, resolved_at = v_now, resolution = 'pages_arrived'
    where e.booking_id = v_b.id and e.kind = 'missing_pages' and e.state = 'open';
  end if;
  if v_outcome = 'mixed' then
    perform public.script_raise_mixed(v_x.id, null);
  end if;

  if v_x.id is not null then
    if v_x.complete is distinct from (v_outcome = 'complete') then
      update public.scripts set complete = (v_outcome = 'complete') where id = v_x.id;
    end if;
    perform public.script_evaluate(v_x.id);
  end if;
  return jsonb_build_object('ok', true, 'booking_id', v_b.id, 'outcome', v_outcome, 'pages', to_jsonb(v_missing),
    'complete', v_outcome = 'complete');
end;
$$;

-- A file that is processed now settles what was raised when an earlier prepare of it failed for good (Ruling R40, m1):
-- its open processing_failed exceptions about a prepare are closed, with no actor, each with an audit row, as
-- script_page_marking_made does for a marking picture. The dashboard's count of files that could not be processed
-- then drops. A remask's failure is not touched: noting it re-queues the remask.
create function public.script_upload_processed(p_upload uuid, p_now timestamptz)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  with closed as (
    update public.script_exceptions e
    set state = 'resolved', resolved_at = p_now, resolution = 'processed', reason = 'The file was processed again.'
    where e.upload_id = p_upload and e.kind = 'processing_failed' and e.state = 'open'
      and coalesce(e.details ->> 'kind', 'prepare') = 'prepare'
    returning e.id)
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  select null, 'script_exception_processed', 'script_exception', c.id, 'The file was processed again.' from closed c;
end;
$$;
revoke execute on function public.script_upload_processed(uuid, timestamptz) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- script_pages_record: as 20261120000069, and (Ruling R40, I1) for a scanner file
--   - a candidate's scanned pages that may fill a slot are read once per booking (by copy page), with the ones another
--     script shows (script_pages_elsewhere), instead of four statements per slot;
--   - the usual slot (one scanned page for it, the script shows nothing else there, no other script shows the page)
--     keeps that page at once: the general decision would find the same winner, change no other page and raise
--     nothing. Every other slot is decided exactly as before;
--   - the pages that get an exception of their own are picked out of the list before they are joined to the page rows.
--   - row counts the planner can trust (script_stats_refresh), once the locks are held and again with the pages in;
-- and (m1) a file that is processed settles the exception an earlier failed prepare of it raised
-- (script_upload_processed), before its scripts are worked out.
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
  v_cands jsonb;
  v_else uuid[];
  v_one jsonb;
  v_flagged jsonb;
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
  -- Every lock this needs is held now. Row counts the planner can trust, when they are far behind (Ruling R40, I1).
  perform public.script_stats_refresh();

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
      perform public.script_upload_processed(v_up.id, v_now);
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
  perform public.script_stats_refresh();  -- with this file's pages in

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
      -- The candidate's scanned pages that may fill a slot, by copy page, read once for the booking, and which of them
      -- another script shows (Ruling R40, I1). Deciding one slot changes nothing about the pages of another.
      select coalesce(jsonb_object_agg(t.copy_page::text, t.pages), '{}'::jsonb) into v_cands
      from (
        select p.copy_page, jsonb_agg(jsonb_build_object('id', p.id, 'state', p.state)) as pages
        from public.script_pages p
        where p.replaced_at is null and p.booking_id = v_b and p.state in ('matched', 'duplicate')
          and exists (select 1 from public.script_uploads u where u.id = p.upload_id and u.submission_id is null)
        group by p.copy_page
      ) t;
      v_else := public.script_pages_elsewhere(
        array(select (j ->> 'id')::uuid from jsonb_each(v_cands) c cross join lateral jsonb_array_elements(c.value) j), v_x.id);
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
        -- The usual slot: one scanned page of this candidate for it, the script shows nothing else there, and no other
        -- script shows that page. That page is kept; what follows for the general case would find the same and change
        -- nothing else, so it is not run (Ruling R40, I1).
        v_one := v_cands -> v_slot::text;
        if jsonb_array_length(coalesce(v_one, '[]'::jsonb)) = 1
           and (v_linked is null or v_linked = (v_one -> 0 ->> 'id')::uuid)
           and not (v_one -> 0 ->> 'id')::uuid = any (v_else) then
          v_winner := (v_one -> 0 ->> 'id')::uuid;
          if v_one -> 0 ->> 'state' <> 'matched' then
            update public.script_pages p set state = 'matched' where p.id = v_winner;
          end if;
          delete from public.script_exceptions e
          where e.state = 'open' and e.kind = 'duplicate' and e.page_id = v_winner
            and (coalesce(e.details ->> 'reason', '') <> 'in_other_script'
                 or (v_x.id is not null and public.script_slot_staff_placed(v_x.id, v_slot, v_winner)));
          v_links := v_links || jsonb_build_object(v_slot::text, v_winner);
          continue;
        end if;
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

  -- Exceptions about single pages (the pages that have one are picked out first: usually none).
  select jsonb_agg(x) into v_flagged from jsonb_array_elements(v_found) x
  where (x ->> 'finding' in ('unknown_code', 'other_exam', 'not_expected') or (x ->> 'finding' = 'no_code' and not v_home));
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
  from jsonb_array_elements(coalesce(v_flagged, '[]'::jsonb)) x
  join public.script_pages p on p.upload_id = v_up.id and p.replaced_at is null and p.source_index = (x ->> 'idx')::int;

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

  perform public.script_upload_processed(v_up.id, v_now);
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
