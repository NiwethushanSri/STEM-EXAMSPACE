-- ---------------------------------------------------------------------------------------------
-- Phase 4A, Task 4: sign-off and publishing, scheduled by the minute job, with one email per candidate.
--
-- An admin checks the batch totals (results_get, Task 3) and signs off with the version they saw: results_publish
-- publishes at once, or at a time up to 30 days ahead (state scheduled), when the results are still exactly what was
-- checked. Nothing is published on figures nobody checked (Ruling R7): besides the version (a status, a boundary or a
-- new preparation each add 1), every candidate's row is worked out again from the bookings, scripts and final marks as
-- they are now, with Task 3's rules, and must match the prepared rows, so a booking cancelled after the check (its
-- script withdrawn, which leaves the approval fresh and the version as it was), or final marks changed while the
-- approval was withdrawn and then given again, stop the publication until the results are prepared again. A scheduled
-- publication is made by the minute job results_tick, under the same checks; when one fails, the results go back to
-- prepared with the failure recorded (publish_failed_at, publish_failed_reason), and nothing is published or emailed.
--
-- Publishing (results_publish_now): every row whose values differ from its last published version (or that has none)
-- gets a new version, kept in result_versions with what the family sees; on the first publication only, one
-- results_published email per candidate booking that is not withdrawn (Ruling R9; the student and the parents linked
-- when it is sent; it names the exam only, never a mark, grade or rank). Published again after a withdrawal, no email is
-- sent. A status set after publication is a correction (Ruling R1, Call 18): that candidate's row changes and is
-- recorded at once as a new version; no other row, rank or cohort figure moves, and no email is sent. A correction
-- publishes, so it needs the approval in place and not stale, as a publication does.
--
-- Added (admins; each refuses forbidden for anyone else):
--   results_publish(p_exam, p_version, p_at, p_now): {ok, state, publish_at}. p_at null publishes at once (audited
--     results_published); otherwise state scheduled (audited results_scheduled). Refused, in this order: invalid_input
--     (no exam or version; p_at more than a minute past or more than 30 days ahead, by public.paper_clock(p_now)),
--     not_found, marking_not_approved, results_published (published already), already_scheduled (cancel it first),
--     not_prepared (none, or withdrawn and not prepared again), results_changed (p_version is not the results' version),
--     approval_stale (marking_approval_blocks), results_changed (the rows worked out again differ from the prepared ones,
--     or a candidate is missing a script).
--   results_publish_cancel(p_exam): {ok, state, already}. Scheduled -> prepared (audited results_schedule_cancelled);
--     already true when nothing is scheduled; refused results_published once published.
--   results_withdraw(p_exam, p_reason): {ok, state, already}. Published -> withdrawn with a reason of 3 to 300
--     characters (audited results_withdrawn). Refused reason_required, already_scheduled (cancel instead), not_published.
--     Withdrawn results are prepared (Task 3) and published again; no email is sent then.
-- Internal (no client role, the service role included):
--   results_derive(p_exam, p_bookings): the candidates' rows as Task 3's rules make them now (status, total, marks per
--     question, maximum, percentage, grade), writing nothing. With p_bookings null, a row is kept for a booking that is
--     no longer a candidate only if it was ever published (as preparing deletes the others).
--   results_unchanged(p_exam): the derived rows, ranked as results_rank ranks them (result_rank per mode), are exactly
--     the stored ones (the same candidates; script, mode, status, total, maximum, percentage, grade, marks per question,
--     rank and rank_cohort), and no candidate is missing a script.
--   result_versions_record(p_exam, p_bookings, p_reason, p_by, p_at): for each row of the exam (or of those bookings)
--     whose values differ from its last version (or that has none): results.version + 1 and its result_versions row
--     (published_at p_at, the snapshot, the reason, made_by p_by). Returns how many it recorded. Used by
--     results_publish_now (reason null on a first publication, "Published again: <withdrawal reason>" after one), by
--     the correction ("<status>: <reason>") and by Task 9's re-mark for one booking. Ruling R10: a row that has a
--     published version and whose admin-set status differs from it records "<status>: <status reason>" instead.
--   results_publish_now(p_exam, p_by, p_now): records the versions, state published, published_at p_now, published_by
--     p_by (null when the minute job publishes: the admin who scheduled it is in the results_scheduled audit row),
--     first_published_at the first time only, publish_at and the failure cleared; queues the emails on the first
--     publication only, for every row but the withdrawn ones. Returns the number of candidates. Callers hold the locks and write the audit row.
--   results_tick(p_now): the minute job (pg_cron job results-tick, every minute, as postgres): each scheduled exam whose
--     publish_at has passed is published, or skipped with publish_failed_reason marking_not_approved, approval_stale or
--     results_changed (audited results_publish_failed, actor null). One exam's error is its own (a warning with the exam
--     and SQLSTATE only).
-- Notices: script_notices.booking_id (references bookings); kind results_published, owned by booking_id and exam_id,
--   once per booking (script_notices_once_per_booking). It is a family notice, handed out, retried and skipped as one
--   (script_notice_next, script_notice_given_up and script_family_notices_* need no change); script_notice_count gives 1.
--
-- Changed, each from its latest definition:
--   the trigger result_versions_frozen (20261126000001): for each row updated or deleted, plus one for truncate (see
--     below: the statement trigger made removing a never-published row fail).
--   script_notices_kind_check, script_notices_owner (20261123000006): the kind results_published (booking_id, exam_id).
--   script_notice_recipients (20261123000006): a notice about a booking goes to the booking's student and the parents
--     linked to them, active, when it is sent.
--   script_notice_content (20261123000006): a notice about a booking is about the notice's exam.
--   results_write (20261126000002): its rows now come from results_derive (Ruling R7); what it writes is unchanged.
--   result_status_set (20261126000002): after publication it is a correction (above, Ruling R1), refused
--     marking_not_approved or approval_stale as a publication is; while scheduled it is still refused results_published;
--     none, prepared and withdrawn keep Task 3's behaviour. It also answers result_version (the row's published
--     version). Nothing else in it changed.
--
-- Lock order (Phase 4A): exam_marking -> exam_results -> booking advisory lock -> script rows in id order -> ... ->
-- results in booking id order -> result_versions; the emails (script_notices) are queued last.
--   results_publish and results_tick (per exam, in exam id order): the exam's marking row for share (the approval cannot
--     be withdrawn meanwhile), its results row for update (the tick reads its state again then: a hand publication, a
--     cancel or another run that got there first leaves nothing to do), its scripts for share in id order, its results
--     rows for update in booking id order, then result_versions and the notices.
--   results_publish_cancel and results_withdraw: the exam's results row only.
--   result_status_set: the exam's marking row for share, its results row for update, the booking's advisory lock, the
--     script for share (for a correction, all the exam's scripts in id order, before asking what blocks the approval),
--     then the results rows (all of the exam before publication; the candidate's only for a correction), then
--     result_versions.
-- Nothing here is for families except the email, which carries the exam's title only.
-- ---------------------------------------------------------------------------------------------

-- ---------------------------------------------------------------------------------------------
-- result_versions_frozen's trigger (20261126000001) fired once per statement, so the delete that removing a results row
-- cascades to result_versions raised even when that row had no version: preparing again after a booking stopped being
-- a candidate (results_write deletes its never-published row) always failed. It now fires for each version row updated
-- or deleted, and still for any truncate: a published version is still never changed or removed, by anyone. The
-- function is unchanged.
-- ---------------------------------------------------------------------------------------------
drop trigger result_versions_frozen on public.result_versions;
create trigger result_versions_frozen before update or delete on public.result_versions
  for each row execute function public.result_versions_frozen();
create trigger result_versions_frozen_truncate before truncate on public.result_versions
  for each statement execute function public.result_versions_frozen();

-- ---------------------------------------------------------------------------------------------
-- Notices: the kind results_published, one per booking.
-- ---------------------------------------------------------------------------------------------
alter table public.script_notices add column booking_id uuid references public.bookings (id);
alter table public.script_notices drop constraint script_notices_kind_check;
alter table public.script_notices add constraint script_notices_kind_check
  check (kind in ('receipt', 'needs_attention', 'rejected', 'staff_alert', 'marking_alert', 'marker_paused', 'results_published'));
alter table public.script_notices drop constraint script_notices_owner;
alter table public.script_notices add constraint script_notices_owner check (
  (kind = 'staff_alert' and exam_id is not null and exception_kind is not null)
  or (kind = 'marking_alert' and exam_id is not null and alert_id is not null)
  or (kind = 'marker_paused' and exam_id is not null)
  or (kind = 'results_published' and booking_id is not null and exam_id is not null)
  or (kind not in ('staff_alert', 'marking_alert', 'marker_paused', 'results_published') and submission_id is not null));
create unique index script_notices_once_per_booking on public.script_notices (booking_id, kind) where kind = 'results_published';

-- ---------------------------------------------------------------------------------------------
-- script_notice_recipients: as 20261123000006, and a notice about a booking (booking_id) goes to the booking's student
-- and the parents linked to them, active, as they are when it is sent.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_notice_recipients(p_notice public.script_notices)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('profile_id', x.id, 'email', x.email, 'first_name', x.first_name)
    order by lower(x.email)), '[]'::jsonb)
  from (
    select distinct on (lower(r.email)) r.id, r.email, r.first_name
    from (
      select p.id, p.email::text as email, p.first_name, 0 as rnk
      from public.home_submissions h
      join public.bookings b on b.id = h.booking_id
      join public.profiles p on p.id = b.student_id and p.status = 'active'
      where p_notice.kind not in ('staff_alert', 'marking_alert', 'marker_paused') and h.id = p_notice.submission_id
      union all
      select p.id, p.email::text, p.first_name, 1
      from public.home_submissions h
      join public.bookings b on b.id = h.booking_id
      join public.parent_children pc on pc.student_id = b.student_id
      join public.profiles p on p.id = pc.parent_id and p.status = 'active'
      where p_notice.kind not in ('staff_alert', 'marking_alert', 'marker_paused') and h.id = p_notice.submission_id
      union all
      select p.id, p.email::text, p.first_name, 0
      from public.bookings b
      join public.profiles p on p.id = b.student_id and p.status = 'active'
      where p_notice.booking_id is not null and b.id = p_notice.booking_id
      union all
      select p.id, p.email::text, p.first_name, 1
      from public.bookings b
      join public.parent_children pc on pc.student_id = b.student_id
      join public.profiles p on p.id = pc.parent_id and p.status = 'active'
      where p_notice.booking_id is not null and b.id = p_notice.booking_id
      union all
      select p.id, p.email::text, p.first_name, 0
      from public.profiles p
      where p_notice.kind in ('staff_alert', 'marking_alert', 'marker_paused') and p.status = 'active' and p.role in ('owner', 'admin')
      union all
      select p.id, p.email::text, p.first_name, 0
      from public.profiles p
      where p_notice.kind in ('marking_alert', 'marker_paused')
        and public.is_lead_for(p.id, (select e.subject_id from public.exams e where e.id = p_notice.exam_id))
    ) r
    where r.email is not null and r.email <> ''
      and not exists (select 1 from public.script_notices_sent s where s.notice_id = p_notice.id and s.profile_id = r.id)
    order by lower(r.email), r.rnk
  ) x
$$;

-- ---------------------------------------------------------------------------------------------
-- script_notice_content: as 20261123000006, and a notice about a booking (booking_id) is about the notice's exam (it
-- has no script or submission: its email names the exam only).
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_notice_content(p_notice public.script_notices)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_sub public.home_submissions%rowtype;
  v_script public.scripts%rowtype;
  v_exam uuid;
  v_label text;
  v_pages int[];
begin
  if p_notice.kind in ('staff_alert', 'marking_alert', 'marker_paused') or p_notice.booking_id is not null then
    v_exam := p_notice.exam_id;
  else
    select * into v_sub from public.home_submissions h where h.id = p_notice.submission_id;
    select b.exam_id into v_exam from public.bookings b where b.id = v_sub.booking_id;
  end if;
  select * into v_script from public.scripts s where s.id = p_notice.script_id;
  select case when coalesce(btrim(e.paper), '') <> '' and position(lower(btrim(e.paper)) in lower(e.title)) = 0
              then e.title || ' ' || btrim(e.paper) else e.title end
  into v_label from public.exams e where e.id = v_exam;
  select coalesce(array_agg(l.copy_page order by l.copy_page), '{}') into v_pages
  from public.script_page_links l where l.script_id = v_script.id and l.version = v_script.version;

  return jsonb_build_object(
    'exam', v_label,
    'script_number', v_script.number,
    'submission_seq', v_sub.seq,
    'at', coalesce(v_sub.checked_at, v_sub.submitted_at, p_notice.created_at),
    'page_count', cardinality(v_pages),
    'pages', to_jsonb(v_pages),
    'exception_kind', p_notice.exception_kind,
    'count', public.script_notice_count(p_notice),
    'alert_kind', (select a.kind from public.marking_alerts a where a.id = p_notice.alert_id));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the rows of the exam's candidates (all of them when p_bookings is null, else those bookings) as Task 3's
-- rules make them now, from the bookings, the scripts and the final marks: an admin-set status stands; totals, marks per
-- question, the maximum, the percentage and the grade by the saved boundaries. Ranks are not here (results_rank ranks
-- the stored rows; results_unchanged ranks these). With p_bookings null a booking that is no longer a candidate keeps
-- its row only if it was ever published (version > 0), as a full preparation deletes the others. Writes nothing. (The
-- body is 20261126000002's results_write, moved here; Ruling R7.)
-- ---------------------------------------------------------------------------------------------
create function public.results_derive(p_exam uuid, p_bookings uuid[] default null)
returns table (booking_id uuid, student_id uuid, script_id uuid, sitting public.sitting_mode, status public.result_status,
  total numeric, max_total numeric, percentage numeric, grade text, question_marks jsonb)
language sql
stable
security definer
set search_path = ''
as $$
  with q as materialized (
    select x.question_id, x.path from public.results_questions(p_exam) x
  ),
  g as materialized (
    select public.exam_max_total(p_exam) as max_total, public.exam_grades(p_exam) as grades
  ),
  cand as materialized (
    select b.id as booking_id, b.student_id, b.sitting, s.id as script_id, s.state as script_state,
      coalesce(r.status_set, false) as status_set, r.status as kept
    from public.bookings b
    left join public.scripts s on s.booking_id = b.id
    left join public.results r on r.booking_id = b.id
    where b.exam_id = p_exam and (p_bookings is null or b.id = any (p_bookings))
      and (b.status in ('paid', 'part_refunded', 'cancel_requested') or s.id is not null
           or (r.id is not null and (p_bookings is not null or r.version > 0)))
  ),
  d as materialized (
    select c.booking_id, c.student_id, c.sitting, c.script_id,
      (case when c.status_set then c.kept::text
            when c.script_id is null then 'absent'
            when c.script_state = 'withdrawn' then 'withdrawn'
            when c.script_state = 'void' then 'incomplete'
            else 'present' end)::public.result_status as status
    from cand c
  ),
  v as materialized (
    select d.booking_id, d.student_id, d.sitting, d.script_id, d.status,
      case when d.status = 'present' then public.script_final_total(d.script_id) end as total,
      case when d.status = 'present' then (
        select coalesce(jsonb_agg(jsonb_build_object('question_id', f.question_id, 'mark', f.mark,
                 'not_attempted', f.not_attempted, 'changed_on_review', f.source = 'lead') order by q.path nulls last, f.question_id),
               '[]'::jsonb)
        from public.script_final_marks(d.script_id) f left join q on q.question_id = f.question_id)
      else '[]'::jsonb end as question_marks
    from d
  )
  select v.booking_id, v.student_id, v.script_id, v.sitting, v.status, v.total, g.max_total,
    public.result_percentage(v.total, g.max_total), public.result_grade(v.total, g.grades), v.question_marks
  from v cross join g
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: results_write, as 20261126000002, and (Ruling R7) the rows it writes come from results_derive. Preparing
-- the whole exam first removes the rows of bookings that are no longer candidates and were never published. A row whose
-- values did not change is not touched. Callers hold the exam's results row and the results rows, and have refused the
-- missing candidates.
-- ---------------------------------------------------------------------------------------------
create or replace function public.results_write(p_exam uuid, p_bookings uuid[] default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_bookings is null then
    delete from public.results r
    where r.exam_id = p_exam and r.version = 0
      and not exists (select 1 from public.bookings b
                      where b.id = r.booking_id and b.status in ('paid', 'part_refunded', 'cancel_requested'))
      and not exists (select 1 from public.scripts s where s.booking_id = r.booking_id);
  end if;

  insert into public.results as r (exam_id, booking_id, student_id, script_id, sitting, status, total, max_total, percentage,
    grade, question_marks)
  select p_exam, x.booking_id, x.student_id, x.script_id, x.sitting, x.status, x.total, x.max_total, x.percentage, x.grade,
    x.question_marks
  from public.results_derive(p_exam, p_bookings) x
  on conflict (booking_id) do update set
    student_id = excluded.student_id, script_id = excluded.script_id, sitting = excluded.sitting, status = excluded.status,
    total = excluded.total, max_total = excluded.max_total, percentage = excluded.percentage, grade = excluded.grade,
    question_marks = excluded.question_marks
  where (r.student_id, r.script_id, r.sitting, r.status, r.total, r.max_total, r.percentage, r.grade, r.question_marks)
    is distinct from (excluded.student_id, excluded.script_id, excluded.sitting, excluded.status, excluded.total,
                      excluded.max_total, excluded.percentage, excluded.grade, excluded.question_marks);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the prepared rows are still what Task 3's rules make now (see the header). The derived rows are ranked as
-- results_rank ranks the stored ones: result_rank once per mode and distinct total, among the present totals of the mode.
-- ---------------------------------------------------------------------------------------------
create function public.results_unchanged(p_exam uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with d as materialized (
    select * from public.results_derive(p_exam, null)
  ),
  p as materialized (
    select d.sitting, d.total from d where d.status = 'present' and d.total is not null
  ),
  m as materialized (
    select p.sitting, array_agg(p.total) as totals from p group by p.sitting
  ),
  k as materialized (
    select t.sitting, t.total, public.result_rank(t.total, m.totals) as rank, cardinality(m.totals) as n
    from (select distinct p.sitting, p.total from p) t join m on m.sitting = t.sitting
  ),
  x as materialized (
    select d.*, k.rank, case when k.rank is not null then k.n end as rank_cohort
    from d left join k on k.sitting = d.sitting and k.total = d.total and d.status = 'present'
  ),
  s as materialized (
    select r.* from public.results r where r.exam_id = p_exam
  )
  select not exists (
      select 1 from x full join s on s.booking_id = x.booking_id
      where x.booking_id is null or s.booking_id is null
         or (s.student_id, s.script_id, s.sitting, s.status, s.total, s.max_total, s.percentage, s.grade, s.question_marks,
             s.rank, s.rank_cohort)
            is distinct from (x.student_id, x.script_id, x.sitting, x.status, x.total, x.max_total, x.percentage, x.grade,
                              x.question_marks, x.rank, x.rank_cohort))
    and not exists (select 1 from public.results_missing(p_exam))
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: records the new published version of each row of the exam (or of those bookings) whose values differ from
-- its last version, or that has none (see the header). The snapshot is what the family sees of the row. The reason is
-- p_reason, except (Ruling R10) for a row that has a published version and whose status now differs from it because an
-- admin set it: that row records "<status>: <status reason>" (so a status set while the results were withdrawn is kept
-- with its own reason when they are published again; a correction's p_reason is the same text).
-- ---------------------------------------------------------------------------------------------
create function public.result_versions_record(p_exam uuid, p_bookings uuid[], p_reason text, p_by uuid, p_at timestamptz)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  with snap as materialized (
    select r.id, r.version, r.status, r.status_set, r.status_reason,
      jsonb_build_object('sitting', r.sitting, 'status', r.status, 'total', r.total,
      'max_total', r.max_total, 'percentage', r.percentage, 'grade', r.grade, 'rank', r.rank, 'rank_cohort', r.rank_cohort,
      'question_marks', r.question_marks, 'remarked', r.remarked) as snapshot
    from public.results r
    where r.exam_id = p_exam and (p_bookings is null or r.booking_id = any (p_bookings))
  ),
  due as materialized (
    select s.id, s.version + 1 as version, s.snapshot,
      case when v.snapshot is not null and s.status_set and s.status::text is distinct from v.snapshot ->> 'status'
           then s.status || ': ' || s.status_reason else p_reason end as reason
    from snap s
    left join public.result_versions v on v.result_id = s.id and v.version = s.version
    where v.snapshot is distinct from s.snapshot
  ),
  bumped as (
    update public.results r set version = d.version from due d where r.id = d.id
  )
  insert into public.result_versions (result_id, version, published_at, snapshot, reason, made_by)
  select d.id, d.version, p_at, d.snapshot, d.reason, p_by from due d;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: publishes the exam's results at p_now (see the header). Callers hold the exam's marking row, its results row,
-- its scripts and its results rows, have checked that nothing changed, and write the audit row.
-- ---------------------------------------------------------------------------------------------
create function public.results_publish_now(p_exam uuid, p_by uuid, p_now timestamptz)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_er public.exam_results%rowtype;
  v_n int;
begin
  select * into v_er from public.exam_results r where r.exam_id = p_exam;
  perform public.result_versions_record(p_exam, null,
    case when v_er.first_published_at is not null
         then 'Published again: ' || coalesce(v_er.withdraw_reason, 'no reason recorded') end,
    p_by, p_now);
  update public.exam_results r
  set state = 'published', published_at = p_now, published_by = p_by, first_published_at = coalesce(r.first_published_at, p_now),
    publish_at = null, publish_failed_at = null, publish_failed_reason = null
  where r.exam_id = p_exam;
  -- The emails go out on the first publication only (Call 10): one per candidate booking, never a second, and none for
  -- a withdrawn candidate (Ruling R9: the booking was cancelled, refunded or expired; absent, incomplete and
  -- disqualified candidates are told).
  if v_er.first_published_at is null then
    insert into public.script_notices (kind, booking_id, exam_id)
    select 'results_published', r.booking_id, p_exam from public.results r
    where r.exam_id = p_exam and r.status <> 'withdrawn'
    order by r.booking_id
    on conflict do nothing;
  end if;
  select count(*)::int into v_n from public.results r where r.exam_id = p_exam;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- results_publish: see the header.
-- ---------------------------------------------------------------------------------------------
create function public.results_publish(p_exam uuid, p_version int, p_at timestamptz default null, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_approved timestamptz;
  v_er public.exam_results%rowtype;
  v_n int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null or p_version is null
     or (p_at is not null and (p_at < v_now - interval '1 minute' or p_at > v_now + interval '30 days')) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if not exists (select 1 from public.exams e where e.id = p_exam) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  -- The exam's marking row for share: the approval cannot be withdrawn until this ends.
  select m.approved_at into v_approved from public.exam_marking m where m.exam_id = p_exam for share;
  if v_approved is null then
    return jsonb_build_object('ok', false, 'code', 'marking_not_approved');
  end if;
  select * into v_er from public.exam_results r where r.exam_id = p_exam for update;
  if v_er.state = 'published' then
    return jsonb_build_object('ok', false, 'code', 'results_published');
  end if;
  if v_er.state = 'scheduled' then
    return jsonb_build_object('ok', false, 'code', 'already_scheduled');
  end if;
  if v_er.state is distinct from 'prepared' then
    return jsonb_build_object('ok', false, 'code', 'not_prepared');
  end if;
  if v_er.version <> p_version then
    return jsonb_build_object('ok', false, 'code', 'results_changed');
  end if;
  -- The scripts for share before asking what blocks the approval: none changes state until this ends.
  perform 1 from public.scripts s where s.exam_id = p_exam order by s.id for share;
  if jsonb_array_length(public.marking_approval_blocks(p_exam)) > 0 then
    return jsonb_build_object('ok', false, 'code', 'approval_stale');
  end if;
  perform 1 from public.results r where r.exam_id = p_exam order by r.booking_id for update;
  if not public.results_unchanged(p_exam) then
    return jsonb_build_object('ok', false, 'code', 'results_changed');
  end if;

  if p_at is null then
    v_n := public.results_publish_now(p_exam, v_actor, v_now);
    insert into public.audit_log (actor_id, action, target_type, target_id, reason)
    values (v_actor, 'results_published', 'exam', p_exam,
      format('version %s: %s %s%s', v_er.version, v_n, case when v_n = 1 then 'candidate' else 'candidates' end,
        case when v_er.first_published_at is not null then ', published again (no email)' else '' end));
    return jsonb_build_object('ok', true, 'state', 'published', 'publish_at', null);
  end if;
  update public.exam_results r set state = 'scheduled', publish_at = p_at where r.exam_id = p_exam;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'results_scheduled', 'exam', p_exam,
    format('version %s: to publish at %s UTC', v_er.version, to_char(p_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI')));
  return jsonb_build_object('ok', true, 'state', 'scheduled', 'publish_at', p_at);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- results_publish_cancel: see the header.
-- ---------------------------------------------------------------------------------------------
create function public.results_publish_cancel(p_exam uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_er public.exam_results%rowtype;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if not exists (select 1 from public.exams e where e.id = p_exam) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into v_er from public.exam_results r where r.exam_id = p_exam for update;
  if v_er.state = 'published' then
    return jsonb_build_object('ok', false, 'code', 'results_published');
  end if;
  if v_er.state is distinct from 'scheduled' then
    return jsonb_build_object('ok', true, 'state', coalesce(v_er.state, 'none'), 'already', true);
  end if;
  update public.exam_results r set state = 'prepared', publish_at = null where r.exam_id = p_exam;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'results_schedule_cancelled', 'exam', p_exam,
    format('version %s: was to publish at %s UTC', v_er.version, to_char(v_er.publish_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI')));
  return jsonb_build_object('ok', true, 'state', 'prepared', 'already', false);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- results_withdraw: see the header.
-- ---------------------------------------------------------------------------------------------
create function public.results_withdraw(p_exam uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_state public.results_state;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if not exists (select 1 from public.exams e where e.id = p_exam) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select r.state into v_state from public.exam_results r where r.exam_id = p_exam for update;
  if v_state = 'withdrawn' then
    return jsonb_build_object('ok', true, 'state', 'withdrawn', 'already', true);
  end if;
  if v_state = 'scheduled' then
    return jsonb_build_object('ok', false, 'code', 'already_scheduled');
  end if;
  if v_state is distinct from 'published' then
    return jsonb_build_object('ok', false, 'code', 'not_published');
  end if;
  update public.exam_results r set state = 'withdrawn', withdrawn_at = now(), withdrawn_by = v_actor, withdraw_reason = v_reason
  where r.exam_id = p_exam;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'results_withdrawn', 'exam', p_exam, v_reason);
  return jsonb_build_object('ok', true, 'state', 'withdrawn', 'already', false);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the minute job (see the header).
-- ---------------------------------------------------------------------------------------------
create function public.results_tick(p_now timestamptz default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := public.paper_clock(p_now);
  v_exam uuid;
  v_approved timestamptz;
  v_er public.exam_results%rowtype;
  v_code text;
  v_n int;
begin
  for v_exam in
    select r.exam_id from public.exam_results r where r.state = 'scheduled' and r.publish_at <= v_now order by r.exam_id
  loop
    -- One exam's failure is its own: what it did is undone, the others still run, and the next minute tries it again.
    -- The log line names the exam and the error's SQLSTATE only: an error's message can quote a row.
    begin
      select m.approved_at into v_approved from public.exam_marking m where m.exam_id = v_exam for share;
      select * into v_er from public.exam_results r where r.exam_id = v_exam for update;
      -- Published by hand, cancelled, or published by another run since it was listed: nothing to do.
      if v_er.state is distinct from 'scheduled' or v_er.publish_at > v_now then
        continue;
      end if;
      v_code := null;
      if v_approved is null then
        v_code := 'marking_not_approved';
      else
        perform 1 from public.scripts s where s.exam_id = v_exam order by s.id for share;
        if jsonb_array_length(public.marking_approval_blocks(v_exam)) > 0 then
          v_code := 'approval_stale';
        else
          perform 1 from public.results r where r.exam_id = v_exam order by r.booking_id for update;
          if not public.results_unchanged(v_exam) then
            v_code := 'results_changed';
          end if;
        end if;
      end if;

      if v_code is null then
        v_n := public.results_publish_now(v_exam, null, v_now);
        insert into public.audit_log (actor_id, action, target_type, target_id, reason)
        values (null, 'results_published', 'exam', v_exam,
          format('version %s: %s %s at the time set%s', v_er.version, v_n, case when v_n = 1 then 'candidate' else 'candidates' end,
            case when v_er.first_published_at is not null then ', published again (no email)' else '' end));
      else
        update public.exam_results r
        set state = 'prepared', publish_at = null, publish_failed_at = v_now, publish_failed_reason = v_code
        where r.exam_id = v_exam;
        insert into public.audit_log (actor_id, action, target_type, target_id, reason)
        values (null, 'results_publish_failed', 'exam', v_exam, format('version %s: %s', v_er.version, v_code));
      end if;
    exception when others then
      raise warning 'results_tick: the publication of exam % failed (SQLSTATE %)', v_exam, sqlstate;
    end;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- result_status_set: as 20261126000002, and (Ruling R1) after publication it is a correction: only the candidate's row
-- is held and rewritten (status, total, marks, percentage, grade), ranked among the other present rows' current totals
-- in its mode, and recorded at once as a new published version (reason "<status>: <reason>"); no other row's rank, no
-- cohort figure and not the exam's results version move, and no email is sent. A correction publishes, so it is
-- refused, as a publication is, marking_not_approved without the approval and approval_stale while anything blocks it
-- (a script that arrived after publication, say): asked with the exam's scripts held for share (Phase 3B's rule; the
-- task 4 review's Important 1). While scheduled it is still refused results_published. The answer also says
-- result_version (the row's published version).
-- ---------------------------------------------------------------------------------------------
create or replace function public.result_status_set(p_booking uuid, p_status text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_b public.bookings%rowtype;
  v_state public.results_state;
  v_published boolean;
  v_script uuid;
  v_row uuid;
  v_version int;
  v_status public.result_status;
  v_result_version int;
  v_approved timestamptz;
  v_r public.results%rowtype;
  v_totals numeric[];
  v_rank int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_booking is null or p_status is null or p_status not in ('absent', 'incomplete', 'disqualified', 'auto') then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  select * into v_b from public.bookings b where b.id = p_booking;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  select m.approved_at into v_approved from public.exam_marking m where m.exam_id = v_b.exam_id for share;
  insert into public.exam_results (exam_id) values (v_b.exam_id) on conflict (exam_id) do nothing;
  select r.state into v_state from public.exam_results r where r.exam_id = v_b.exam_id for update;
  if v_state = 'scheduled' then
    return jsonb_build_object('ok', false, 'code', 'results_published');
  end if;
  v_published := v_state = 'published';
  perform public.script_bookings_lock(array[p_booking]);
  if v_published then
    -- A correction publishes: only on approved marking that nothing blocks, with the exam's scripts held while that is
    -- asked (as results_publish does).
    if v_approved is null then
      return jsonb_build_object('ok', false, 'code', 'marking_not_approved');
    end if;
    perform 1 from public.scripts s where s.exam_id = v_b.exam_id order by s.id for share;
    if jsonb_array_length(public.marking_approval_blocks(v_b.exam_id)) > 0 then
      return jsonb_build_object('ok', false, 'code', 'approval_stale');
    end if;
  end if;
  select s.id into v_script from public.scripts s where s.booking_id = p_booking for share;
  if v_published then
    -- A correction changes the candidate's row only (Call 18).
    perform 1 from public.results r where r.booking_id = p_booking for update;
  else
    perform 1 from public.results r where r.exam_id = v_b.exam_id order by r.booking_id for update;
  end if;
  select r.id into v_row from public.results r where r.booking_id = p_booking;

  -- A candidate (as results_write counts them).
  if v_b.status not in ('paid', 'part_refunded', 'cancel_requested') and v_script is null and v_row is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  -- auto would make a missing candidate (results_missing) missing again: preparation would stop for them.
  if p_status = 'auto' and v_script is null and v_b.sitting = 'centre'
     and v_b.status in ('paid', 'part_refunded', 'cancel_requested')
     and exists (select 1 from public.attendance a
                 where a.exam_id = v_b.exam_id and a.student_id = v_b.student_id and a.status in ('present', 'late')) then
    return jsonb_build_object('ok', false, 'code', 'missing_scripts', 'count', 1);
  end if;

  insert into public.results as r (exam_id, booking_id, student_id, script_id, sitting, status, status_set, status_reason, max_total)
  values (v_b.exam_id, p_booking, v_b.student_id, v_script, v_b.sitting,
    (case when p_status = 'auto' then 'absent' else p_status end)::public.result_status,
    p_status <> 'auto', case when p_status <> 'auto' then v_reason end, public.exam_max_total(v_b.exam_id))
  on conflict (booking_id) do update set
    status_set = excluded.status_set, status_reason = excluded.status_reason,
    status = case when excluded.status_set then excluded.status else r.status end;
  perform public.results_write(v_b.exam_id, array[p_booking]);

  if v_published then
    -- Its own rank among the present totals of its mode as they stand (its own included); nobody else's moves.
    select * into v_r from public.results r where r.booking_id = p_booking;
    if v_r.status = 'present' and v_r.total is not null then
      select array_agg(o.total) into v_totals from public.results o
      where o.exam_id = v_b.exam_id and o.sitting = v_r.sitting and o.status = 'present' and o.total is not null;
      v_rank := public.result_rank(v_r.total, v_totals);
    end if;
    update public.results r set rank = v_rank, rank_cohort = case when v_rank is not null then cardinality(v_totals) end
    where r.id = v_r.id;
    perform public.result_versions_record(v_b.exam_id, array[p_booking], p_status || ': ' || v_reason, v_actor, now());
    select r.version into v_version from public.exam_results r where r.exam_id = v_b.exam_id;
  else
    perform public.results_rank(v_b.exam_id);
    update public.exam_results r set version = r.version + 1, cohort = public.results_cohort(v_b.exam_id)
    where r.exam_id = v_b.exam_id
    returning r.version into v_version;
  end if;
  select r.status, r.version into v_status, v_result_version from public.results r where r.booking_id = p_booking;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'result_status_set', 'booking', p_booking, p_status || ': ' || v_reason);
  return jsonb_build_object('ok', true, 'version', v_version, 'status', v_status, 'result_version', v_result_version);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- The minute job, scheduled once however often this migration runs (it runs as postgres, as the other minute jobs).
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from cron.job where jobname = 'results-tick') then
    perform cron.unschedule('results-tick');
  end if;
  perform cron.schedule('results-tick', '* * * * *', $job$select public.results_tick()$job$);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges. The internal functions are for definer callers and the minute job only; the publishing functions for
-- signed-in users (they check for an admin). Functions made again by create or replace keep theirs (restated).
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.script_notice_recipients(public.script_notices) from public, anon, authenticated, service_role;
revoke execute on function public.script_notice_content(public.script_notices) from public, anon, authenticated, service_role;
revoke execute on function public.results_derive(uuid, uuid[]) from public, anon, authenticated, service_role;
revoke execute on function public.results_write(uuid, uuid[]) from public, anon, authenticated, service_role;
revoke execute on function public.results_unchanged(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.result_versions_record(uuid, uuid[], text, uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.results_publish_now(uuid, uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.results_tick(timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.results_publish(uuid, int, timestamptz, timestamptz) from public, anon;
revoke execute on function public.results_publish_cancel(uuid) from public, anon;
revoke execute on function public.results_withdraw(uuid, text) from public, anon;
revoke execute on function public.result_status_set(uuid, text, text) from public, anon;
grant execute on function public.results_publish(uuid, int, timestamptz, timestamptz) to authenticated;
grant execute on function public.results_publish_cancel(uuid) to authenticated;
grant execute on function public.results_withdraw(uuid, text) to authenticated;
grant execute on function public.result_status_set(uuid, text, text) to authenticated;
