-- Phase 3A Task 6: marking a piece. Opening it, saving marks and annotations with a revision number, submitting it and
-- changing it after submit; and the storage policy that lets a marker read the marking pictures of a piece they hold
-- (or have submitted), and no other picture.
--
-- A piece shows its script's pages that markers mark (marking_script_pages): the current version's pages at an answer
-- page or a spare page (by the page's own copy page, or by the slot the script shows it at, as Phase 2 verifies them;
-- Ruling R33), not refused by staff, in page order, with each confirmed family extra page straight after the page it
-- was placed after. Covers, blank and information pages never appear. The pages a marking was opened with are kept as
-- markings.pages_key (marking_pages_key), for Task 7 to tell when they changed.
--
-- The holder opens a piece (the first open makes their live marking: never a second row for the same marker, as Task
-- 5 revives an earlier one) and saves to it; the marker of a submitted piece may open it and, with a reason, change it
-- until marking closes. Every open, save and submit is refused (marking_work_blocked) when: the caller has no claim on
-- the piece, is no longer approved for the subject or is now blocked for the candidate (forbidden); the piece is on
-- hold (on_hold); their hold has run out, or ended while their marking is in progress, or their marking was set aside
-- (hold_expired); the script is not being marked (forbidden); a file of its pages is being prepared or remasked
-- (pictures_updating); marking has closed (marking_closed; a submitted piece still opens, read only). A save names
-- the rev it follows: a stale one is refused and nothing is written, so two screens never overwrite each other. A save
-- is all or nothing. Every changed mark writes a question_mark_history row; a change after submit asks for a reason and
-- writes an audit row, as a submit does. Draft saves write no audit row (Builder's call 13). Nothing a marker is given
-- names the candidate; the index number is shown (Ruling R4).
--
-- Lock order (Ruling R9): the marker's advisory lock (shared, as every hand-out to them takes it), then the exam's
-- marking row (for share, so a structure save, which holds it for update, cannot change a maximum under a mark being
-- saved), then the script's row (for no key update), then the piece's, then the marking's.
--
-- Storage: the policy script_pages_objects_select_marker lets a marker read a picture of script-pages only when
-- marking_picture_allowed says it is the current marking picture of a page their piece shows, while they may work on
-- the piece. The staff policy (script_pages_objects_select) is unchanged. A new index finds a page by its marking
-- picture.
--
-- 3B: these functions serve the live pass only; other kinds of marking get their own rules.
--
-- No earlier function is changed.

create index script_pages_marking_path_idx on public.script_pages (marking_path) where replaced_at is null and marking_path is not null;

-- ---------------------------------------------------------------------------------------------
-- Internal: the pages of a script that markers mark, numbered from 1 (see the header). copy_page is null for an
-- extra page; marking_path is null for a page with no current marking picture (none, or the page was replaced).
-- ---------------------------------------------------------------------------------------------
create function public.marking_script_pages(p_script uuid)
returns table (n int, page_id uuid, copy_page int, extra boolean, marking_path text, rotation int)
language sql
stable
security definer
set search_path = ''
as $$
  with links as materialized (
    select l.copy_page, l.page_id
    from public.scripts s
    join public.script_page_links l on l.script_id = s.id and l.version = s.version
    where s.id = p_script
  ),
  slot as materialized (
    select public.script_slot_copy(p_script) as copy_id
  ),
  shown as (
    select l.page_id, l.copy_page, false as extra, l.copy_page as after, 0 as tie, 0 as file_position, 0 as source_index
    from links l
    cross join lateral public.script_page_copy(l.page_id) t
    where not public.script_page_refused(l.page_id)
      and (coalesce(public.script_page_is_answer(t.copy_id, t.copy_page), false)
           or coalesce(public.script_page_is_answer((select s.copy_id from slot s), l.copy_page), false))
    union all
    select x.page_id, null, true, x.placed_after, 1, x.file_position, x.source_index
    from public.script_extra_pages(p_script) x
    where not public.script_page_refused(x.page_id)
  )
  select (row_number() over (order by sh.after, sh.tie, sh.file_position, sh.source_index, sh.page_id))::int,
    sh.page_id, sh.copy_page, sh.extra, case when p.replaced_at is null then p.marking_path end, p.rotation
  from shown sh
  join public.script_pages p on p.id = sh.page_id
  order by 1
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the md5 of the ordered page_id:rotation list of marking_script_pages.
-- ---------------------------------------------------------------------------------------------
create function public.marking_pages_key(p_script uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select md5(coalesce(string_agg(x.page_id::text || ':' || x.rotation, ',' order by x.n), ''))
  from public.marking_script_pages(p_script) x
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: a piece's questions: every question of a whole script, or the questions of the group and their parts.
-- label is the label as printed ("2(b)(i)"), path orders them as on the paper, leaf says it is marked.
-- ---------------------------------------------------------------------------------------------
create function public.marking_unit_questions(p_unit uuid)
returns table (question_id uuid, parent_id uuid, top_id uuid, label text, path int[], leaf boolean, max_mark numeric, mark_step numeric)
language sql
stable
security definer
set search_path = ''
as $$
  with recursive t as (
    select q.id, q.parent_id, q.id as top_id, q.label::text as label, array[q.position] as path
    from public.marking_units u
    join public.exam_questions q on q.exam_id = u.exam_id and q.parent_id is null
    where u.id = p_unit and (u.group_id is null or q.group_id = u.group_id)
    union all
    select c.id, c.parent_id, t.top_id, t.label || '(' || c.label || ')', t.path || c.position
    from t join public.exam_questions c on c.parent_id = t.id
  )
  select t.id, t.parent_id, t.top_id, t.label, t.path,
    not exists (select 1 from public.exam_questions k where k.parent_id = t.id), q.max_mark, q.mark_step
  from t join public.exam_questions q on q.id = t.id
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: what a piece is out of: the maxima of its questions, where the optional questions of a group ("Answer
-- {choose} of these") that the piece holds count only their best `choose`. For a whole script this is the paper total
-- (exam_structure_max_total); a question group counts its own optional questions the same way.
-- ---------------------------------------------------------------------------------------------
create function public.marking_unit_max_total(p_unit uuid)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  with tops as (
    select q.top_id, sum(q.max_mark) as total
    from public.marking_unit_questions(p_unit) q
    where q.leaf
    group by q.top_id
  ),
  ranked as (
    select tp.total, top.option_group_id, og.choose,
      row_number() over (partition by top.option_group_id order by tp.total desc) as n
    from tops tp
    join public.exam_questions top on top.id = tp.top_id
    left join public.exam_option_groups og on og.id = top.option_group_id
  )
  select coalesce(sum(r.total) filter (where r.option_group_id is null or r.n <= r.choose), 0)
  from ranked r
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the sum of a marking's marks (NR adds nothing), where the optional questions of a group that the piece
-- holds count only their best `choose` questions (whole script or question group alike, as marking_unit_max_total).
-- ---------------------------------------------------------------------------------------------
create function public.marking_total(p_marking uuid)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  with tops as (
    select q.top_id, sum(coalesce(qm.mark, 0)) as total
    from public.markings m
    cross join lateral public.marking_unit_questions(m.unit_id) q
    join public.question_marks qm on qm.marking_id = m.id and qm.question_id = q.question_id
    where m.id = p_marking
    group by q.top_id
  ),
  ranked as (
    select tp.total, top.option_group_id, og.choose,
      row_number() over (partition by top.option_group_id order by tp.total desc) as n
    from tops tp
    join public.exam_questions top on top.id = tp.top_id
    left join public.exam_option_groups og on og.id = top.option_group_id
  )
  select coalesce(sum(r.total) filter (where r.option_group_id is null or r.n <= r.choose), 0)
  from ranked r
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: why p_user may not work on the piece at p_now (null: they may). The first of:
--   not_found;
--   forbidden: they neither hold it (an open live assignment) nor have a live marking on it, or they are no longer
--     approved for the subject (is_marker_for), or are now blocked for the candidate (marking_marker_blocked);
--   on_hold;
--   hold_expired: their marking was set aside, or it is in progress and they hold the piece no more or their hold ran
--     out (a submitted marking needs no hold);
--   forbidden: the script is not ready to mark, being marked or marked (or was taken back);
--   pictures_updating: a file holding its pages is being prepared or remasked (marking_script_busy);
--   marking_closed.
-- ---------------------------------------------------------------------------------------------
create function public.marking_work_blocked(p_unit uuid, p_user uuid, p_now timestamptz)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := public.paper_clock(p_now);
  v_u public.marking_units%rowtype;
  v_x public.scripts%rowtype;
  v_hold timestamptz;
  v_held boolean;
  v_status text;
  v_subject bigint;
  v_student uuid;
  v_m public.exam_marking%rowtype;
begin
  select * into v_u from public.marking_units u where u.id = p_unit;
  if not found then
    return 'not_found';
  end if;
  select true, a.hold_until into v_held, v_hold from public.marking_assignments a
  where a.unit_id = p_unit and a.kind = 'live' and a.marker_id = p_user and a.ended_at is null;
  v_held := coalesce(v_held, false);
  select m.status into v_status from public.markings m where m.unit_id = p_unit and m.kind = 'live' and m.marker_id = p_user;
  if not v_held and v_status is null then
    return 'forbidden';
  end if;
  select * into v_x from public.scripts s where s.id = v_u.script_id;
  select e.subject_id into v_subject from public.exams e where e.id = v_u.exam_id;
  select b.student_id into v_student from public.bookings b where b.id = v_x.booking_id;
  if not public.is_marker_for(p_user, v_subject) or public.marking_marker_blocked(p_user, v_student) then
    return 'forbidden';
  end if;
  if v_u.on_hold then
    return 'on_hold';
  end if;
  if v_status is not distinct from 'set_aside'
     or (v_status is distinct from 'submitted' and (not v_held or coalesce(v_hold < v_now, false))) then
    return 'hold_expired';
  end if;
  if v_x.state not in ('ready_to_mark', 'marking', 'marked') or v_x.taken_back_at is not null then
    return 'forbidden';
  end if;
  if public.marking_script_busy(v_u.script_id) then
    return 'pictures_updating';
  end if;
  select * into v_m from public.exam_marking m where m.exam_id = v_u.exam_id;
  if v_m.opened_at is null or v_m.closed_at is not null then
    return 'marking_closed';
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the labels of a piece's questions with no mark and no NR in a marking, in paper order.
-- ---------------------------------------------------------------------------------------------
create function public.marking_missing(p_marking uuid, p_unit uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(q.label order by q.path), '[]'::jsonb)
  from public.marking_unit_questions(p_unit) q
  where q.leaf and not exists (select 1 from public.question_marks m where m.marking_id = p_marking and m.question_id = q.question_id)
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: applies a save's operations to the marking, in order (marking_save holds the rows). A refused operation
-- raises (raise_exception) with its code as the message, so the caller undoes them all: invalid_input,
-- mark_out_of_range, or incomplete (p_after: a question of a submitted marking left with no mark and no NR).
--   {op:'mark', question_id, mark|null, na}: a leaf of the piece; a mark from 0 to its maximum, a multiple of its step;
--     NR (na) has no mark; no mark and no NR clears it. A change writes a history row (after_submit, reason).
--   {op:'ann_put', id, page_id, kind, x, y, points?, text?, question_id?}: on a page of the piece, at its rotation;
--     an id of this marking is updated (and undeleted), an id of another marking is refused; at most 1,500 points;
--     a text of at most 500 characters; question_id a leaf of the piece.
--   {op:'ann_del', id} and {op:'ann_restore', id}: an annotation of this marking, deleted (deleted_at) or brought back;
--     it is brought back only while the piece shows its page at the rotation it was drawn at.
--   {op:'note', text}: the note to the lead marker, at most 1,000 characters (trimmed; empty clears it).
-- Then a page may hold at most 500 live annotations of the marking.
-- ---------------------------------------------------------------------------------------------
create function public.marking_ops_apply(p_marking uuid, p_unit uuid, p_script uuid, p_ops jsonb, p_actor uuid, p_after boolean, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uuid constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
  v_kinds constant text[] := array['tick', 'cross', 'error', 'caret', 'XP', 'SEEN', 'SF', 'TE', 'BP', 'AE', 'ECF', 'L1', 'L2', 'L3',
                                   'POT', 'BOD', 'CON', 'pen', 'highlight', 'text', 'ruler'];
  v_pages jsonb;   -- {page id: rotation} of the piece's pages
  v_leaves jsonb;  -- {question id: {max, step}} of the piece's leaves
  v_touched uuid[] := '{}';
  v_op jsonb;
  v_q jsonb;
  v_qid uuid;
  v_mark numeric;
  v_na boolean;
  v_old public.question_marks%rowtype;
  v_id uuid;
  v_page uuid;
  v_a public.page_annotations%rowtype;
  v_text text;
  v_missing jsonb;
begin
  select coalesce(jsonb_object_agg(x.page_id::text, x.rotation), '{}') into v_pages from public.marking_script_pages(p_script) x;
  select coalesce(jsonb_object_agg(q.question_id::text, jsonb_build_object('max', q.max_mark, 'step', q.mark_step)), '{}') into v_leaves
  from public.marking_unit_questions(p_unit) q where q.leaf;

  for v_op in select e from jsonb_array_elements(p_ops) with ordinality t(e, o) order by o loop
    if jsonb_typeof(v_op) <> 'object' or jsonb_typeof(v_op -> 'op') is distinct from 'string' then
      raise exception using errcode = 'P0001', message = 'invalid_input';
    end if;

    if v_op ->> 'op' = 'mark' then
      if jsonb_typeof(v_op -> 'question_id') is distinct from 'string' or (v_op ->> 'question_id') !~ v_uuid
         or coalesce(jsonb_typeof(v_op -> 'mark'), 'null') not in ('null', 'number')
         or jsonb_typeof(v_op -> 'na') is distinct from 'boolean' then
        raise exception using errcode = 'P0001', message = 'invalid_input';
      end if;
      v_qid := (v_op ->> 'question_id')::uuid;
      v_q := v_leaves -> v_qid::text;
      v_mark := (v_op ->> 'mark')::numeric;
      v_na := (v_op ->> 'na')::boolean;
      if v_q is null or (v_na and v_mark is not null) then
        raise exception using errcode = 'P0001', message = 'invalid_input';
      end if;
      if v_mark is not null and (v_mark < 0 or v_mark > (v_q ->> 'max')::numeric or mod(v_mark, (v_q ->> 'step')::numeric) <> 0) then
        raise exception using errcode = 'P0001', message = 'mark_out_of_range';
      end if;
      select * into v_old from public.question_marks m where m.marking_id = p_marking and m.question_id = v_qid for update;
      if v_mark is null and not v_na then
        if v_old.marking_id is not null then
          delete from public.question_marks m where m.marking_id = p_marking and m.question_id = v_qid;
          insert into public.question_mark_history (marking_id, question_id, mark, not_attempted, source, changed_by, changed_at, after_submit, reason)
          values (p_marking, v_qid, null, false, 'marker', p_actor, now(), p_after, p_reason);
        end if;
      elsif v_old.marking_id is null or v_old.mark is distinct from v_mark or v_old.not_attempted <> v_na then
        insert into public.question_marks as m (marking_id, question_id, mark, not_attempted, source, updated_at)
        values (p_marking, v_qid, v_mark, v_na, 'marker', now())
        on conflict (marking_id, question_id) do update set mark = excluded.mark, not_attempted = excluded.not_attempted,
          source = excluded.source, updated_at = excluded.updated_at;
        insert into public.question_mark_history (marking_id, question_id, mark, not_attempted, source, changed_by, changed_at, after_submit, reason)
        values (p_marking, v_qid, v_mark, v_na, 'marker', p_actor, now(), p_after, p_reason);
      end if;

    elsif v_op ->> 'op' = 'ann_put' then
      if jsonb_typeof(v_op -> 'id') is distinct from 'string' or (v_op ->> 'id') !~ v_uuid
         or jsonb_typeof(v_op -> 'page_id') is distinct from 'string' or (v_op ->> 'page_id') !~ v_uuid
         or jsonb_typeof(v_op -> 'kind') is distinct from 'string' or (v_op ->> 'kind') <> all (v_kinds)
         or jsonb_typeof(v_op -> 'x') is distinct from 'number' or jsonb_typeof(v_op -> 'y') is distinct from 'number'
         or coalesce(jsonb_typeof(v_op -> 'points'), 'null') not in ('null', 'array')
         or coalesce(jsonb_typeof(v_op -> 'text'), 'null') not in ('null', 'string')
         or coalesce(jsonb_typeof(v_op -> 'question_id'), 'null') not in ('null', 'string')
         or coalesce(v_op ->> 'question_id', '00000000-0000-0000-0000-000000000000') !~ v_uuid then
        raise exception using errcode = 'P0001', message = 'invalid_input';
      end if;
      v_id := (v_op ->> 'id')::uuid;
      v_page := (v_op ->> 'page_id')::uuid;
      v_qid := (v_op ->> 'question_id')::uuid;
      if not v_pages ? v_page::text
         or (v_op ->> 'x')::numeric not between 0 and 1 or (v_op ->> 'y')::numeric not between 0 and 1
         or coalesce(char_length(v_op ->> 'text'), 0) > 500
         or (v_qid is not null and not v_leaves ? v_qid::text) then
        raise exception using errcode = 'P0001', message = 'invalid_input';
      end if;
      if jsonb_typeof(v_op -> 'points') = 'array' then
        if jsonb_array_length(v_op -> 'points') > 1500
           or exists (select 1 from jsonb_array_elements(v_op -> 'points') pt
                      where case when jsonb_typeof(pt) = 'array'
                                 then jsonb_array_length(pt) <> 2 or jsonb_typeof(pt -> 0) <> 'number' or jsonb_typeof(pt -> 1) <> 'number'
                                 else true end) then
          raise exception using errcode = 'P0001', message = 'invalid_input';
        end if;
      end if;
      select * into v_a from public.page_annotations a where a.id = v_id for update;
      if v_a.id is not null and v_a.marking_id <> p_marking then
        raise exception using errcode = 'P0001', message = 'invalid_input';
      end if;
      if v_a.id is null then
        insert into public.page_annotations (id, marking_id, page_id, page_rotation, kind, x, y, points, text, question_id)
        values (v_id, p_marking, v_page, (v_pages ->> v_page::text)::int, v_op ->> 'kind', (v_op ->> 'x')::numeric, (v_op ->> 'y')::numeric,
          case when jsonb_typeof(v_op -> 'points') = 'array' then v_op -> 'points' end, v_op ->> 'text', v_qid);
      else
        update public.page_annotations set page_id = v_page, page_rotation = (v_pages ->> v_page::text)::int, kind = v_op ->> 'kind',
          x = (v_op ->> 'x')::numeric, y = (v_op ->> 'y')::numeric,
          points = case when jsonb_typeof(v_op -> 'points') = 'array' then v_op -> 'points' end,
          text = v_op ->> 'text', question_id = v_qid, deleted_at = null
        where id = v_id;
      end if;
      v_touched := v_touched || v_page;

    elsif v_op ->> 'op' in ('ann_del', 'ann_restore') then
      if jsonb_typeof(v_op -> 'id') is distinct from 'string' or (v_op ->> 'id') !~ v_uuid then
        raise exception using errcode = 'P0001', message = 'invalid_input';
      end if;
      select * into v_a from public.page_annotations a where a.id = (v_op ->> 'id')::uuid and a.marking_id = p_marking for update;
      if v_a.id is null then
        raise exception using errcode = 'P0001', message = 'invalid_input';
      end if;
      if v_op ->> 'op' = 'ann_del' then
        update public.page_annotations set deleted_at = coalesce(deleted_at, now()) where id = v_a.id;
      else
        -- Only onto a page the piece still shows, turned as it was when the annotation was drawn.
        if not v_pages ? v_a.page_id::text or (v_pages ->> v_a.page_id::text)::int <> v_a.page_rotation then
          raise exception using errcode = 'P0001', message = 'invalid_input';
        end if;
        update public.page_annotations set deleted_at = null where id = v_a.id;
        v_touched := v_touched || v_a.page_id;
      end if;

    elsif v_op ->> 'op' = 'note' then
      if coalesce(jsonb_typeof(v_op -> 'text'), 'null') not in ('null', 'string') then
        raise exception using errcode = 'P0001', message = 'invalid_input';
      end if;
      v_text := nullif(btrim(v_op ->> 'text'), '');
      if char_length(v_text) > 1000 then
        raise exception using errcode = 'P0001', message = 'invalid_input';
      end if;
      update public.markings set lead_note = v_text where id = p_marking;

    else
      raise exception using errcode = 'P0001', message = 'invalid_input';
    end if;
  end loop;

  if cardinality(v_touched) > 0 and exists (
       select 1 from public.page_annotations a
       where a.marking_id = p_marking and a.deleted_at is null and a.page_id = any (v_touched)
       group by a.page_id having count(*) > 500) then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  if p_after then
    v_missing := public.marking_missing(p_marking, p_unit);
    if jsonb_array_length(v_missing) > 0 then
      raise exception using errcode = 'P0001', message = 'incomplete', detail = v_missing::text;
    end if;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_unit_open: the piece for its holder (the first open makes their live marking, with the pages key; a Next
-- script hold is renewed to 2 hours from now) or for the marker of its submitted live marking (read only once marking
-- has closed: unit.closed). Refusals (marking_work_blocked): invalid_input, not_found, forbidden, on_hold,
-- hold_expired, pictures_updating, marking_closed. Returns {ok, unit:{id, exam_title, paper, subject, script_number,
-- index_number, group_label, deadline, hold_until, closed}, marking:{id, rev, status, lead_note, total, max_total,
-- pages_changed}, structure:{version, questions (as exam_structure_get, the piece's only), option_groups (those of its
-- questions), mark_scheme_file}, pages:[{n, page_id, copy_page, extra, marking_path, rotation}], marks:[{question_id,
-- mark, na}], annotations:[{id, page_id, kind, x, y, points, text, question_id}] (not deleted, on a page shown, drawn
-- at its current rotation)}. Nothing in it names the candidate.
-- ---------------------------------------------------------------------------------------------
create function public.marking_unit_open(p_unit uuid, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_u public.marking_units%rowtype;
  v_x public.scripts%rowtype;
  v_e public.exams%rowtype;
  v_m public.exam_marking%rowtype;
  v_a public.marking_assignments%rowtype;
  v_mk public.markings%rowtype;
  v_why text;
  v_pages jsonb;
begin
  if p_unit is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  perform pg_advisory_xact_lock_shared(hashtextextended('marker:' || v_actor::text, 0));
  select * into v_u from public.marking_units u where u.id = p_unit;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  -- Ruling R9: the exam's marking row, the script's row, the piece's, then its assignment and marking.
  select * into v_m from public.exam_marking m where m.exam_id = v_u.exam_id for share;
  select * into v_x from public.scripts s where s.id = v_u.script_id for no key update;
  select * into v_u from public.marking_units u where u.id = p_unit for update;
  select * into v_mk from public.markings m where m.unit_id = p_unit and m.kind = 'live' and m.marker_id = v_actor for update;
  v_why := public.marking_work_blocked(p_unit, v_actor, v_now);
  if v_why is not null and not (v_why = 'marking_closed' and v_mk.status = 'submitted') then
    return jsonb_build_object('ok', false, 'code', v_why);
  end if;

  select * into v_a from public.marking_assignments a
  where a.unit_id = p_unit and a.kind = 'live' and a.marker_id = v_actor and a.ended_at is null for update;
  if v_mk.id is null then
    insert into public.markings (unit_id, kind, marker_id, pages_key)
    values (p_unit, 'live', v_actor, public.marking_pages_key(v_u.script_id))
    returning * into v_mk;
    perform public.marking_script_state(v_u.script_id);
  end if;
  if v_a.how = 'next' then
    update public.marking_assignments set hold_until = v_now + interval '2 hours' where id = v_a.id returning * into v_a;
  end if;
  select * into v_e from public.exams e where e.id = v_u.exam_id;

  select coalesce(jsonb_agg(jsonb_build_object('n', x.n, 'page_id', x.page_id, 'copy_page', x.copy_page, 'extra', x.extra,
                                               'marking_path', x.marking_path, 'rotation', x.rotation) order by x.n), '[]'::jsonb)
  into v_pages
  from public.marking_script_pages(v_u.script_id) x;

  return jsonb_build_object(
    'ok', true,
    'unit', jsonb_build_object(
      'id', v_u.id,
      'exam_title', v_e.title,
      'paper', v_e.paper,
      'subject', (select s.name from public.subjects s where s.id = v_e.subject_id),
      'script_number', v_x.number,
      'index_number', (select d.index_number from public.bookings b join public.student_details d on d.profile_id = b.student_id
                       where b.id = v_x.booking_id),
      'group_label', (select g.label from public.question_groups g where g.id = v_u.group_id),
      'deadline', v_m.deadline,
      'hold_until', v_a.hold_until,
      'closed', v_m.closed_at is not null),
    'marking', jsonb_build_object(
      'id', v_mk.id, 'rev', v_mk.rev, 'status', v_mk.status, 'lead_note', v_mk.lead_note, 'total', v_mk.total,
      'max_total', public.marking_unit_max_total(p_unit), 'pages_changed', v_mk.pages_changed_at is not null),
    'structure', jsonb_build_object(
      'version', coalesce(v_m.structure_version, 0),
      'questions', coalesce((
        select jsonb_agg(jsonb_build_object(
            'id', q.id, 'parent_id', q.parent_id, 'label', q.label, 'position', q.position, 'max_mark', q.max_mark,
            'mark_step', q.mark_step, 'levels', q.levels, 'pages', to_jsonb(q.pages), 'areas', q.areas, 'group_id', q.group_id,
            'option_group_id', q.option_group_id, 'guidance', q.guidance, 'alternatives', q.alternatives,
            'points', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'label', p.label, 'marks', p.marks,
                                                                    'marks_to', p.marks_to, 'text', p.text) order by p.position)
                                from public.mark_scheme_points p where p.question_id = q.id), '[]'::jsonb))
          order by t.path)
        from public.marking_unit_questions(p_unit) t join public.exam_questions q on q.id = t.question_id), '[]'::jsonb),
      'option_groups', coalesce((
        select jsonb_agg(jsonb_build_object('id', o.id, 'label', o.label, 'choose', o.choose) order by o.label, o.id)
        from public.exam_option_groups o
        where o.id in (select q.option_group_id from public.marking_unit_questions(p_unit) t
                       join public.exam_questions q on q.id = t.question_id)), '[]'::jsonb),
      'mark_scheme_file', (select jsonb_build_object('id', f.id, 'storage_path', f.storage_path)
                           from public.exam_mark_scheme_files f where f.exam_id = v_u.exam_id and f.state = 'stored'
                           order by f.uploaded_at desc limit 1)),
    'pages', v_pages,
    'marks', coalesce((
      select jsonb_agg(jsonb_build_object('question_id', m.question_id, 'mark', m.mark, 'na', m.not_attempted) order by t.path)
      from public.question_marks m join public.marking_unit_questions(p_unit) t on t.question_id = m.question_id
      where m.marking_id = v_mk.id), '[]'::jsonb),
    'annotations', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'page_id', a.page_id, 'kind', a.kind, 'x', a.x, 'y', a.y, 'points', a.points,
                                          'text', a.text, 'question_id', a.question_id) order by a.created_at, a.id)
      from public.page_annotations a
      where a.marking_id = v_mk.id and a.deleted_at is null
        and exists (select 1 from jsonb_array_elements(v_pages) p
                    where (p ->> 'page_id')::uuid = a.page_id and (p ->> 'rotation')::int = a.page_rotation)), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_save: the marking's marker saves operations (see marking_ops_apply) after rev p_rev. A marking in progress
-- needs their open, unexpired hold; a submitted one needs a reason (reason_required), must keep a mark or NR for every
-- question (incomplete, with missing) and writes an audit row (marking_changed_after_submit). Refused: invalid_input
-- (also 0 or more than 200 operations), forbidden, conflict (reason set_aside: the marking was set aside), on_hold,
-- hold_expired, pictures_updating, marking_closed, and {ok: false, code: conflict, reason: rev, rev} when p_rev is not
-- the current rev; then nothing is written. Then rev + 1, last_saved_at, active_seconds + at most 300, the total, and
-- a Next script hold renewed to 2 hours from now. Returns {ok, rev, total, hold_until}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_save(p_marking uuid, p_rev int, p_ops jsonb, p_active_seconds int default 0,
  p_reason text default null, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_reason text := public.script_resolution_reason(p_reason);
  v_mk public.markings%rowtype;
  v_u public.marking_units%rowtype;
  v_why text;
  v_after boolean;
  v_hold timestamptz;
  v_detail text;
begin
  if p_marking is null or p_rev is null or jsonb_typeof(p_ops) is distinct from 'array' or jsonb_array_length(p_ops) not between 1 and 200 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  perform pg_advisory_xact_lock_shared(hashtextextended('marker:' || v_actor::text, 0));
  select * into v_mk from public.markings m where m.id = p_marking;
  if not found or v_mk.marker_id is distinct from v_actor or v_mk.kind <> 'live' then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into v_u from public.marking_units u where u.id = v_mk.unit_id;
  -- Ruling R9: the exam's marking row, the script's row, the piece's, then the marking's.
  perform 1 from public.exam_marking m where m.exam_id = v_u.exam_id for share;
  perform 1 from public.scripts s where s.id = v_u.script_id for no key update;
  select * into v_u from public.marking_units u where u.id = v_mk.unit_id for update;
  select * into v_mk from public.markings m where m.id = p_marking for update;
  if v_mk.status = 'set_aside' then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'set_aside');
  end if;
  v_why := public.marking_work_blocked(v_u.id, v_actor, v_now);
  if v_why is not null then
    return jsonb_build_object('ok', false, 'code', v_why);
  end if;
  if p_rev <> v_mk.rev then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'rev', 'rev', v_mk.rev);
  end if;
  v_after := v_mk.status = 'submitted';
  if v_after and v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;

  -- All or nothing: a refused operation undoes the others. Only the operations' own refusals are answered; any other
  -- error is raised again.
  begin
    perform public.marking_ops_apply(v_mk.id, v_u.id, v_u.script_id, p_ops, v_actor, v_after, case when v_after then v_reason end);
  exception when raise_exception then
    get stacked diagnostics v_detail = pg_exception_detail;
    if sqlerrm = 'incomplete' then
      return jsonb_build_object('ok', false, 'code', 'incomplete', 'missing', v_detail::jsonb);
    elsif sqlerrm in ('invalid_input', 'mark_out_of_range') then
      return jsonb_build_object('ok', false, 'code', sqlerrm);
    end if;
    raise;
  end;

  update public.markings
  set rev = rev + 1, last_saved_at = now(), active_seconds = active_seconds + least(greatest(coalesce(p_active_seconds, 0), 0), 300),
    total = public.marking_total(id)
  where id = v_mk.id
  returning * into v_mk;
  update public.marking_assignments a set hold_until = v_now + interval '2 hours'
  where a.unit_id = v_u.id and a.kind = 'live' and a.marker_id = v_actor and a.ended_at is null and a.how = 'next';
  select a.hold_until into v_hold from public.marking_assignments a
  where a.unit_id = v_u.id and a.kind = 'live' and a.marker_id = v_actor and a.ended_at is null;
  if v_after then
    insert into public.audit_log (actor_id, action, target_type, target_id, reason)
    values (v_actor, 'marking_changed_after_submit', 'marking', v_mk.id, v_reason);
  end if;
  return jsonb_build_object('ok', true, 'rev', v_mk.rev, 'total', v_mk.total, 'hold_until', v_hold);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_submit: the holder submits their marking in progress at rev p_rev. The checks of a save; every question of
-- the piece has a mark or NR (incomplete, with missing: their labels). The marking is submitted (with the structure
-- version and the total; pages_changed_at cleared) and its rev moves on, so a screen still at the old rev is told to
-- reload rather than asked for a reason; the hold ends (submitted), the piece is submitted and the script follows
-- (marking_script_state). Refused also: conflict with reason submitted (already submitted). Returns {ok, rev, total,
-- max_total, script_state}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_submit(p_marking uuid, p_rev int, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_mk public.markings%rowtype;
  v_u public.marking_units%rowtype;
  v_version int;
  v_why text;
  v_missing jsonb;
  v_state public.script_state;
begin
  if p_marking is null or p_rev is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  perform pg_advisory_xact_lock_shared(hashtextextended('marker:' || v_actor::text, 0));
  select * into v_mk from public.markings m where m.id = p_marking;
  if not found or v_mk.marker_id is distinct from v_actor or v_mk.kind <> 'live' then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into v_u from public.marking_units u where u.id = v_mk.unit_id;
  -- Ruling R9: the exam's marking row, the script's row, the piece's, then the marking's.
  select m.structure_version into v_version from public.exam_marking m where m.exam_id = v_u.exam_id for share;
  perform 1 from public.scripts s where s.id = v_u.script_id for no key update;
  select * into v_u from public.marking_units u where u.id = v_mk.unit_id for update;
  select * into v_mk from public.markings m where m.id = p_marking for update;
  if v_mk.status in ('set_aside', 'submitted') then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', v_mk.status);
  end if;
  v_why := public.marking_work_blocked(v_u.id, v_actor, v_now);
  if v_why is not null then
    return jsonb_build_object('ok', false, 'code', v_why);
  end if;
  if p_rev <> v_mk.rev then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'rev', 'rev', v_mk.rev);
  end if;
  v_missing := public.marking_missing(v_mk.id, v_u.id);
  if jsonb_array_length(v_missing) > 0 then
    return jsonb_build_object('ok', false, 'code', 'incomplete', 'missing', v_missing);
  end if;

  update public.markings
  set status = 'submitted', rev = rev + 1, submitted_at = now(), structure_version = coalesce(v_version, 0),
    total = public.marking_total(id), pages_changed_at = null
  where id = v_mk.id
  returning * into v_mk;
  update public.marking_assignments a set ended_at = now(), end_reason = 'submitted'
  where a.unit_id = v_u.id and a.kind = 'live' and a.marker_id = v_actor and a.ended_at is null;
  update public.marking_units set state = 'submitted' where id = v_u.id;
  perform public.marking_script_state(v_u.script_id);
  select s.state into v_state from public.scripts s where s.id = v_u.script_id;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'marking_submitted', 'marking', v_mk.id);
  return jsonb_build_object('ok', true, 'rev', v_mk.rev, 'total', v_mk.total, 'max_total', public.marking_unit_max_total(v_u.id),
    'script_state', v_state);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- The storage policy's question: is p_name the current marking picture (not replaced) of a page that a piece shows
-- (marking_script_pages), on which the caller may work now (marking_work_blocked: they hold it, or submitted it, it is
-- not on hold, its script is not busy and marking is open)? The page is found by its marking picture, then the
-- scripts that show it: those whose current version links it, and the home script of the hand-in it came with (an
-- extra page). A full picture never matches.
-- ---------------------------------------------------------------------------------------------
create function public.marking_picture_allowed(p_name text)
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
  select coalesce(p_name is not null and exists (
    select 1 from units u
    where public.marking_work_blocked(u.id, (select auth.uid()), null) is null
      and exists (select 1 from public.marking_script_pages(u.script_id) x where x.marking_path = p_name)), false)
$$;

create policy script_pages_objects_select_marker on storage.objects for select to authenticated
using (bucket_id = 'script-pages' and public.marking_picture_allowed(name));

-- ---------------------------------------------------------------------------------------------
-- Privileges.
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.marking_script_pages(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_pages_key(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_unit_questions(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_unit_max_total(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_total(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_work_blocked(uuid, uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.marking_ops_apply(uuid, uuid, uuid, jsonb, uuid, boolean, text) from public, anon, authenticated, service_role;
revoke execute on function public.marking_missing(uuid, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_unit_open(uuid, timestamptz) from public, anon;
revoke execute on function public.marking_save(uuid, int, jsonb, int, text, timestamptz) from public, anon;
revoke execute on function public.marking_submit(uuid, int, timestamptz) from public, anon;
revoke execute on function public.marking_picture_allowed(text) from public, anon;
grant execute on function public.marking_unit_open(uuid, timestamptz) to authenticated;
grant execute on function public.marking_save(uuid, int, jsonb, int, text, timestamptz) to authenticated;
grant execute on function public.marking_submit(uuid, int, timestamptz) to authenticated;
grant execute on function public.marking_picture_allowed(text) to authenticated;
