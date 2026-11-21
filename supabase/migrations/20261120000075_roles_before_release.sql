-- Phase 2 final review, fix wave (Ruling R40, I3): page roles are checked before a paper is released.
--
-- The roles (answer, cover, blank, information) default to "answer" and lock for good once a page of the paper has
-- been read. A paper released unchecked had its covers treated as answer pages: blank-page prompts, "missing" covers
-- and marking pictures of covers. Spec 5.1: the roles "must be set before release".
--   paper_release_now: refuses with roles_not_reviewed while the current paper's pages_reviewed_at is null.
--   paper_copy_issue: the automatic release has no step of its own, so the step that makes a candidate's copy refuses
--     the same way, for a home copy, a print pack and a reprint. An admin's preview (and the sample copy the roles
--     panel draws on, which needs no copy row) still works: that is how the roles are checked.
--   booking_paper_state: the family sees "missing" (the paper is not ready) while the roles are unchecked, never a
--     download that would be refused.
-- The three functions keep their access.

create or replace function public.paper_release_now(p_exam uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := btrim(coalesce(p_reason, ''));
  v_exam public.exams%rowtype;
begin
  if not exists (
    select 1 from public.profiles a
    where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin') for share) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null or char_length(v_reason) not between 3 and 300 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_exam from public.exams e where e.id = p_exam for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_exam.status <> 'published'
     or public.paper_release_at(v_exam.id) <= now()
     or not exists (
       select 1 from public.exam_papers p
       where p.exam_id = v_exam.id and p.kind = 'paper' and p.superseded_at is null) then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  -- The page roles decide how the answers are read: they are checked before the paper goes out (Ruling R40, I3).
  if exists (select 1 from public.exam_papers p
             where p.exam_id = v_exam.id and p.kind = 'paper' and p.superseded_at is null and p.pages_reviewed_at is null) then
    return jsonb_build_object('ok', false, 'code', 'roles_not_reviewed');
  end if;
  update public.exams set released_early_at = now(), release_held = false where id = v_exam.id;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'paper_released_early', 'exam', v_exam.id, v_reason);
  return jsonb_build_object('ok', true, 'id', v_exam.id, 'release_at', now());
end;
$$;

create or replace function public.paper_copy_issue(
  p_booking uuid,
  p_kind public.paper_download_kind,
  p_now timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_admin boolean;
  v_b public.bookings%rowtype;
  v_e public.exams%rowtype;
  v_p public.exam_papers%rowtype;
  v_c public.paper_copies%rowtype;
  v_refusal text;
  v_last uuid;
  v_tries int := 0;
begin
  if p_booking is null or p_kind is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  v_admin := exists (
    select 1 from public.profiles a where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin'));
  select * into v_b from public.bookings b where b.id = p_booking;
  if not found then
    -- Families get the same answer for a missing booking as for someone else's.
    return jsonb_build_object('ok', false, 'code', case when v_admin then 'not_found' else 'forbidden' end);
  end if;
  -- Shared lock: a hold, a replacement or an exam-code change waits for this call, and this call sees theirs.
  select * into v_e from public.exams e where e.id = v_b.exam_id for share;

  v_refusal := public.paper_access_code(v_actor, v_b, v_e, p_kind, v_now);
  if v_refusal is not null then
    return jsonb_build_object('ok', false, 'code', v_refusal);
  end if;
  select * into v_p from public.exam_papers p
  where p.exam_id = v_e.id and p.kind = 'paper' and p.superseded_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'paper_missing');
  end if;
  -- No copy leaves for a candidate (at home, in a print pack or as a reprint) before an admin has checked the page
  -- roles of this paper version (Ruling R40, I3). An admin's own preview is how they are checked.
  if p_kind <> 'admin_preview' and v_p.pages_reviewed_at is null then
    return jsonb_build_object('ok', false, 'code', 'roles_not_reviewed');
  end if;
  if p_kind = 'home' and public.paper_home_downloads_last_hour(v_b.id, v_now) >= 20 then
    return jsonb_build_object('ok', false, 'code', 'rate_limited');
  end if;

  -- One copy per booking and paper version. A concurrent call for the same copy waits on the insert and then
  -- reads that copy; a code that is already taken (1 in 2^40 per copy) is drawn again.
  loop
    select * into v_c from public.paper_copies c where c.booking_id = v_b.id and c.paper_id = v_p.id;
    exit when found;
    insert into public.paper_copies (code, booking_id, paper_id, page_count)
    values (public.copy_code_new(), v_b.id, v_p.id, v_p.page_count + v_e.spare_pages)
    on conflict do nothing
    returning * into v_c;
    exit when found;
    v_tries := v_tries + 1;
    if v_tries >= 5 then
      raise exception 'no free copy code after % tries', v_tries;
    end if;
  end loop;

  select c.paper_id into v_last
  from public.paper_downloads d
  join public.paper_copies c on c.id = d.copy_id
  where c.booking_id = v_b.id and d.kind <> 'admin_preview'
  order by d.at desc, d.id desc
  limit 1;

  return jsonb_build_object(
    'ok', true,
    'copy_id', v_c.id,
    'code', v_c.code,
    'page_count', v_c.page_count,
    'spare_pages', v_c.page_count - v_p.page_count,
    'storage_path', v_p.storage_path,
    'paper_version', v_p.version,
    'candidate_name', coalesce((
      select btrim(s.first_name || ' ' || s.last_name) from public.profiles s where s.id = v_b.student_id), ''),
    'index_number', coalesce((
      select d.index_number from public.student_details d where d.profile_id = v_b.student_id), ''),
    'exam_code', v_e.exam_code,
    'exam_title', public.paper_exam_title(v_e.title, v_e.paper),
    'starts_at', v_e.starts_at,
    'differs_from_previous', coalesce(v_last <> v_p.id, false));
end;
$$;

create or replace function public.booking_paper_state(p_booking uuid, p_now timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_role public.app_role;
  v_admin boolean;
  v_b public.bookings%rowtype;
  v_e public.exams%rowtype;
  v_current uuid;
  v_reviewed boolean;
  v_status text;
  v_last record;
  v_inserts jsonb := '[]'::jsonb;
begin
  if p_booking is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select a.role into v_role from public.profiles a where a.id = v_actor and a.status = 'active';
  v_admin := v_role in ('owner', 'admin');
  select * into v_b from public.bookings b where b.id = p_booking;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when v_admin then 'not_found' else 'forbidden' end);
  end if;
  if not coalesce(v_admin, false) and not (
    v_b.student_id is not null
    and ((v_role = 'student' and v_actor = v_b.student_id)
         or (v_role = 'parent' and exists (
               select 1 from public.parent_children pc
               where pc.parent_id = v_actor and pc.student_id = v_b.student_id)))) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into v_e from public.exams e where e.id = v_b.exam_id;
  select p.id, p.pages_reviewed_at is not null into v_current, v_reviewed from public.exam_papers p
  where p.exam_id = v_e.id and p.kind = 'paper' and p.superseded_at is null;

  if v_b.sitting = 'centre' then
    v_status := 'centre';
  elsif v_b.status not in ('paid', 'cancel_requested')
        or not exists (
          select 1 from public.profiles s
          where s.id = v_b.student_id and s.role = 'student' and s.status = 'active') then
    v_status := 'closed';
  else
    v_status := case public.paper_window_code(v_e, v_now)
      when 'paper_closed' then 'closed'
      when 'paper_held' then 'held'
      when 'paper_not_released' then 'not_yet'
      -- a paper whose page roles are not checked yet is not ready either (Ruling R40, I3)
      else case when v_current is null or not coalesce(v_reviewed, false) then 'missing' else 'open' end
    end;
  end if;

  select d.at, c.paper_id, nullif(btrim(coalesce(pr.first_name, '') || ' ' || coalesce(pr.last_name, '')), '') as by_name
  into v_last
  from public.paper_downloads d
  join public.paper_copies c on c.id = d.copy_id
  left join public.profiles pr on pr.id = d.downloaded_by
  where c.booking_id = v_b.id and d.kind = 'home'
  order by d.at desc, d.id desc
  limit 1;

  if v_status in ('open', 'missing') then
    select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'title', p.title) order by p.version), '[]'::jsonb)
    into v_inserts
    from public.exam_papers p
    where p.exam_id = v_e.id and p.kind = 'insert' and p.superseded_at is null;
  end if;

  return jsonb_build_object(
    'ok', true,
    'sitting', v_b.sitting,
    'status', v_status,
    'release_at', public.paper_release_at(v_e.id),
    -- the database clock that decided the status, so a page can wait for the release without trusting the device
    'server_now', v_now,
    'last_download', case when v_last.at is null then null
                          else jsonb_build_object('at', v_last.at, 'by_name', v_last.by_name) end,
    'corrected', v_b.sitting = 'home' and v_current is not null and v_last.paper_id is not null
                 and v_last.paper_id <> v_current,
    'inserts', v_inserts);
end;
$$;
