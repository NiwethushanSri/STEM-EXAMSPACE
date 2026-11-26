-- Test helpers: injected by scripts/db-test.mjs right after each test file's first `begin;`.
-- They live inside the test transaction and roll back with it.
create schema if not exists tests;

-- Fails fast when a persistent owner (created before this transaction) exists on the dev project.
create or replace function tests.assert_no_owner()
returns void
language plpgsql
as $$
begin
  if exists (select 1 from public.profiles where role = 'owner' and created_at < now()) then
    raise exception 'A real owner exists on the dev project % tests need it removed', chr(8212);
  end if;
end;
$$;

-- Creates an auth user (the sign-up trigger builds the profile), then sets role/status as postgres.
create or replace function tests.create_user(p_role public.app_role, p_status public.account_status)
returns uuid
language plpgsql
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  if p_role = 'owner' then
    perform tests.assert_no_owner();
  end if;
  insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data, created_at, instance_id, aud, role)
  values (v_id, p_role::text || '-' || v_id::text || '@test.example',
    '{}'::jsonb, '{}'::jsonb, now(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated');
  update public.profiles set role = p_role, status = p_status where id = v_id;
  if p_role <> 'student' then
    delete from public.student_details where profile_id = v_id;
  end if;
  return v_id;
end;
$$;

-- Acts as the given signed-in user until reset role / end of transaction.
create or replace function tests.as_user(p_uid uuid)
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  set local role authenticated;
end;
$$;

create or replace function tests.as_postgres()
returns void
language plpgsql
as $$
begin
  reset role;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Marking fixtures (Phase 3A). Call them as postgres. They write the rows Phase 2 leaves behind, without running
-- the hand-in and processing functions.
-- ---------------------------------------------------------------------------------------------

-- A published exam (both sittings, 90 minutes) that finished 2 days ago, with its exam code, its release notice
-- sent, and a current 3-page question paper (every page an answer page) whose pages are reviewed. Its exam_marking row
-- is written with double marking, seeds and practice off (Phase 3B): the Phase 3A tests run as they did before the
-- checks existed, and a Phase 3B test switches on what it tests (tests.open_marking, or the row directly).
create or replace function tests.marking_exam(p_subject bigint default 1)
returns uuid
language plpgsql
as $$
declare
  v_start timestamptz := now() - interval '2 days' - interval '90 minutes';
  v_exam uuid;
begin
  insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, price_pence, price_confirmed,
    booking_deadline, status, release_notified_at)
  values (p_subject, 'ZZ Marking exam', 'Paper 1', 'both', v_start, 90, 0, true, v_start - interval '7 days', 'published',
    v_start - interval '10 minutes')
  returning id into v_exam;
  insert into public.exam_papers (exam_id, kind, title, version, storage_path, page_count, byte_size, pages_reviewed_at)
  values (v_exam, 'paper', 'Question paper', 1, v_exam::text || '/' || gen_random_uuid()::text || '.pdf', 3, 1000, now());
  insert into public.exam_marking (exam_id, double_marking, seeds, practice) values (v_exam, false, false, false);
  return v_exam;
end;
$$;

-- A verified, complete script of p_pages pages (copy pages 1..p_pages) for a new active student with a name and an
-- index number: a paid booking, a copy of the current paper, a processed upload (home: a received hand-in's PDF;
-- centre: a scan file of the exam's first centre's batch, both made with an admin on first use) whose prepare job is
-- done, matched pages each with a full and a marking picture, and version 1 linking them. Handed in or scanned
-- 15 minutes after the finish.
create or replace function tests.verified_script(p_exam uuid, p_source public.script_source default 'home', p_pages int default 3)
returns uuid
language plpgsql
as $$
declare
  v_e public.exams%rowtype;
  v_paper public.exam_papers%rowtype;
  v_at timestamptz;
  v_student uuid := tests.create_user('student', 'active');
  v_venue uuid;
  v_centre uuid;
  v_batch uuid;
  v_staff uuid;
  v_booking uuid;
  v_copy uuid;
  v_sub uuid;
  v_upload uuid := gen_random_uuid();
  v_job bigint;
  v_dir text;
  v_script uuid;
begin
  select * into strict v_e from public.exams e where e.id = p_exam;
  select * into strict v_paper from public.exam_papers p where p.exam_id = p_exam and p.kind = 'paper' and p.superseded_at is null;
  v_at := v_e.starts_at + make_interval(mins => v_e.duration_minutes) + interval '15 minutes';

  update public.profiles set first_name = 'Wilhelmina', last_name = 'Quarterfield' where id = v_student;
  update public.student_details
  set index_number = (
    select 'SE-2099-' || lpad((coalesce(max(substring(d.index_number from '^SE-2099-([0-9]+)$')::int), 0) + 1)::text, 4, '0')
    from public.student_details d where d.index_number ~ '^SE-2099-[0-9]+$')
  where profile_id = v_student;

  if p_source = 'centre' then
    select ec.id into v_centre from public.exam_centres ec
    where ec.exam_id = p_exam and ec.removed_at is null order by ec.created_at, ec.id limit 1;
    if v_centre is null then
      insert into public.venues (name, rooms) values ('ZZ Marking hall', array['R1']) returning id into v_venue;
      insert into public.exam_centres (exam_id, venue_id, room, seat_limit) values (p_exam, v_venue, 'R1', 1000)
      returning id into v_centre;
    end if;
    select b.id, b.created_by into v_batch, v_staff from public.scan_batches b
    where b.exam_id = p_exam and b.centre_id = v_centre and b.created_by is not null order by b.created_at, b.id limit 1;
    if v_batch is null then
      v_staff := tests.create_user('admin', 'active');
      insert into public.scan_batches (exam_id, centre_id, number, created_by, created_at, submitted_at)
      select p_exam, v_centre, 'B-' || v_e.exam_code || '-' || lpad((count(*) + 1)::text, 2, '0'), v_staff, v_at, v_at
      from public.scan_batches b where b.exam_id = p_exam
      returning id into v_batch;
    end if;
  end if;

  insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id)
  values (p_exam, v_student, v_student, 'paid', v_e.price_pence, p_source::text::public.sitting_mode, v_centre)
  returning id into v_booking;
  insert into public.paper_copies (code, booking_id, paper_id, page_count, created_at)
  values (public.copy_code_new(), v_booking, v_paper.id, greatest(v_paper.page_count + v_e.spare_pages, p_pages), v_e.starts_at)
  returning id into v_copy;

  if p_source = 'home' then
    insert into public.home_submissions (booking_id, seq, state, submitted_by, submitted_at, checked_at)
    values (v_booking, 1, 'received', v_student, v_at, v_at)
    returning id into v_sub;
    insert into public.script_uploads (id, exam_id, booking_id, submission_id, kind, position, storage_path, mime, byte_size,
      sha256, state, uploaded_by, created_at, stored_at)
    values (v_upload, p_exam, v_booking, v_sub, 'home_pdf', 1, 'home/' || v_booking::text || '/' || v_upload::text || '.pdf',
      'application/pdf', 100000, encode(sha256(convert_to(v_upload::text, 'UTF8')), 'hex'), 'processed', v_student, v_at, v_at);
  else
    insert into public.attendance (exam_id, student_id, status, marked_by, marked_at)
    values (p_exam, v_student, 'present', v_staff, v_e.starts_at);
    insert into public.script_uploads (id, exam_id, batch_id, kind, position, storage_path, mime, byte_size, sha256, state,
      uploaded_by, created_at, stored_at)
    select v_upload, p_exam, v_batch, 'scan_file', coalesce(max(u.position), 0) + 1,
      'batch/' || v_batch::text || '/' || v_upload::text || '.pdf', 'application/pdf', 100000,
      encode(sha256(convert_to(v_upload::text, 'UTF8')), 'hex'), 'processed', v_staff, v_at, v_at
    from public.script_uploads u where u.batch_id = v_batch;
  end if;

  insert into public.processing_jobs (upload_id, kind, state, attempts, run_after, created_at, finished_at)
  values (v_upload, 'prepare', 'done', 1, v_at, v_at, v_at)
  returning id into v_job;
  v_dir := p_exam::text || '/' || v_upload::text || '/' || v_job::text || '-1/';
  insert into public.script_pages (upload_id, source_index, exam_id, copy_id, copy_page, booking_id, state, quality, rotation,
    full_path, marking_path, created_at)
  select v_upload, g.i - 1, p_exam, v_copy, g.i, v_booking, 'matched',
    jsonb_build_object('sharpness', 200, 'brightness', 180, 'cut_off', false, 'flags', '[]'::jsonb), 0,
    v_dir || (g.i - 1) || '-full.jpg', v_dir || (g.i - 1) || '-marking.jpg', v_at
  from generate_series(1, p_pages) g(i);

  insert into public.scripts (booking_id, exam_id, source, number, state, version, complete, received_at, created_at)
  values (v_booking, p_exam, p_source, public.script_number_next(p_exam), 'verified', 1, true, v_at, v_at)
  returning id into v_script;
  insert into public.script_versions (script_id, version, created_at, reason, submission_id, upload_id)
  values (v_script, 1, v_at, case when p_source = 'home' then 'home_submission' else 'scan_upload' end, v_sub,
    case when p_source = 'centre' then v_upload end);
  insert into public.script_page_links (script_id, version, copy_page, page_id)
  select v_script, 1, p.copy_page, p.id from public.script_pages p where p.upload_id = v_upload;
  return v_script;
end;
$$;

-- The test structure: question 1 (3 marks, page 1) and question 2 with parts (a) (2 marks, page 2) and (b) (5 marks,
-- page 3), entered directly as postgres.
create or replace function tests.structure(p_exam uuid)
returns void
language plpgsql
as $$
declare
  v_two uuid;
begin
  insert into public.exam_questions (exam_id, label, position, max_mark, pages) values (p_exam, '1', 1, 3, '{1}');
  insert into public.exam_questions (exam_id, label, position, pages) values (p_exam, '2', 2, '{2,3}') returning id into v_two;
  insert into public.exam_questions (exam_id, parent_id, label, position, max_mark, pages)
  values (p_exam, v_two, 'a', 1, 2, '{2}'), (p_exam, v_two, 'b', 2, 5, '{3}');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Marking fixtures (Phase 3B). Call them as postgres.
-- ---------------------------------------------------------------------------------------------

-- A new active corrector approved to mark the subject; its lead marker when p_lead.
create or replace function tests.marker(p_subject bigint default 1, p_lead boolean default false)
returns uuid
language plpgsql
as $$
declare
  v_id uuid := tests.create_user('corrector', 'active');
begin
  insert into public.marker_approvals (marker_id, subject_id, lead, approved_at) values (v_id, p_subject, p_lead, now());
  return v_id;
end;
$$;

-- Opens the exam's marking as postgres, without marking_open's rules (nobody is recorded as opening it): the checks
-- p_checks names are written first (any of double_marking, sample_percent, tolerance_percent, seeds, seed_every and
-- practice; the others stay as they are), then the verified scripts that may be handed out are made ready
-- (marking_exam_sync). By default the three checks are off.
create or replace function tests.open_marking(p_exam uuid,
  p_checks jsonb default '{"double_marking": false, "seeds": false, "practice": false}')
returns void
language plpgsql
as $$
begin
  insert into public.exam_marking (exam_id) values (p_exam) on conflict (exam_id) do nothing;
  update public.exam_marking m set
    double_marking = coalesce((p_checks ->> 'double_marking')::boolean, m.double_marking),
    sample_percent = coalesce((p_checks ->> 'sample_percent')::int, m.sample_percent),
    tolerance_percent = coalesce((p_checks ->> 'tolerance_percent')::int, m.tolerance_percent),
    seeds = coalesce((p_checks ->> 'seeds')::boolean, m.seeds),
    seed_every = coalesce((p_checks ->> 'seed_every')::int, m.seed_every),
    practice = coalesce((p_checks ->> 'practice')::boolean, m.practice),
    opened_at = coalesce(m.opened_at, now()), closed_at = null, closed_by = null, updated_at = now()
  where m.exam_id = p_exam;
  perform public.marking_exam_sync(p_exam, null);
end;
$$;

-- The marker marks the piece: they take it as Next script does once its rules pass (a 2-hour hold; nothing is taken
-- when they hold it already), then, signed in as them, open it, save a mark for each of its questions in paper order
-- (p_marks[i], 0 when not given) and submit it. Returns the marking's id, as postgres. Any refusal raises.
create or replace function tests.mark_piece(p_unit uuid, p_marker uuid, p_marks numeric[] default null)
returns uuid
language plpgsql
as $$
declare
  v_why text;
  v_ops jsonb;
  v_r jsonb;
  v_marking uuid;
begin
  if not exists (select 1 from public.marking_assignments a where a.unit_id = p_unit and a.marker_id = p_marker and a.ended_at is null) then
    v_why := coalesce(public.marking_unit_blocked(p_unit, p_marker, null, true),
                      (select 'not_open' from public.marking_units u where u.id = p_unit and u.state <> 'open'));
    if v_why is not null then
      raise exception 'tests.mark_piece: the piece cannot be handed to this marker (%)', v_why;
    end if;
    perform public.marking_unit_take(p_unit, p_marker, 'next', null, now() + interval '2 hours');
  end if;
  select jsonb_agg(jsonb_build_object('op', 'mark', 'question_id', q.question_id, 'mark', coalesce(p_marks[q.n], 0), 'na', false) order by q.n)
  into v_ops
  from (select t.question_id, row_number() over (order by t.path) as n from public.marking_unit_questions(p_unit) t where t.leaf) q;

  perform tests.as_user(p_marker);
  v_r := public.marking_unit_open(p_unit);
  if not coalesce((v_r ->> 'ok')::boolean, false) then
    raise exception 'tests.mark_piece: opening was refused (%)', v_r ->> 'code';
  end if;
  v_marking := (v_r #>> '{marking,id}')::uuid;
  v_r := public.marking_save(v_marking, (v_r #>> '{marking,rev}')::int, v_ops);
  if not coalesce((v_r ->> 'ok')::boolean, false) then
    raise exception 'tests.mark_piece: saving was refused (%)', v_r ->> 'code';
  end if;
  v_r := public.marking_submit(v_marking, (v_r ->> 'rev')::int);
  if not coalesce((v_r ->> 'ok')::boolean, false) then
    raise exception 'tests.mark_piece: submitting was refused (%)', v_r ->> 'code';
  end if;
  perform tests.as_postgres();
  return v_marking;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Results fixture (Phase 4A). Call it as postgres.
--
-- tests.results_exam(p_home, p_centre, p_totals, p_subject) returns the exam's id. An exam (tests.marking_exam) whose
-- marking is finished and approved (exam_marking.approved_at set, by a new admin), with candidates whose scripts are
-- checked, each with a final mark for every leaf question.
--   p_home    int        candidates who sat at home (default 2); their bookings are sitting 'home', paid.
--   p_centre  int        candidates who sat at a centre (default 1); sitting 'centre', paid.
--   p_totals  numeric[]  each candidate's total, in order: the home candidates first, then the centre ones. Default: the
--             first candidate gets the paper's maximum (24) and each next one 2 marks fewer (22, 20, ...), never below 0.
--             A total is spread over the leaves in paper order (1, 2a, 2b, 3, then 4 last), so a total up to 24 is
--             counted whole by script_final_total. A total above 24 or below 0, or fewer entries than candidates, raises.
--   p_subject bigint     the exam's subject (default 1).
-- The paper (maximum 24): question 1 (10 marks); question 2 with parts (a) 3 and (b) 5; question 3 (6); question 4 (5).
-- Questions 2, 3 and 4 are one option group "Answer 2 of 3" (choose 2): the best two of 8, 6 and 5 count.
-- The scripts are those of tests.verified_script, made 'checked'; each has one marking unit (submitted, checked) with
-- its final marks (source 'first'). No result rows are made: Task 3's preparing does that.
-- ---------------------------------------------------------------------------------------------
create or replace function tests.results_exam(p_home int default 2, p_centre int default 1,
  p_totals numeric[] default null, p_subject bigint default 1)
returns uuid
language plpgsql
as $$
declare
  v_exam uuid := tests.marking_exam(p_subject);
  v_admin uuid := tests.create_user('admin', 'active');
  v_og uuid;
  v_two uuid;
  v_n int := p_home + p_centre;
  v_i int;
  v_total numeric;
  v_left numeric;
  v_script uuid;
  v_unit uuid;
  v_q record;
  v_put numeric;
begin
  if p_totals is not null and cardinality(p_totals) < v_n then
    raise exception 'tests.results_exam: % totals given for % candidates', cardinality(p_totals), v_n;
  end if;
  insert into public.exam_option_groups (exam_id, label, choose) values (v_exam, 'Answer 2 of 3', 2) returning id into v_og;
  insert into public.exam_questions (exam_id, label, position, max_mark, pages) values (v_exam, '1', 1, 10, '{1}');
  insert into public.exam_questions (exam_id, label, position, pages, option_group_id) values (v_exam, '2', 2, '{2}', v_og)
  returning id into v_two;
  insert into public.exam_questions (exam_id, parent_id, label, position, max_mark, pages)
  values (v_exam, v_two, 'a', 1, 3, '{2}'), (v_exam, v_two, 'b', 2, 5, '{2}');
  insert into public.exam_questions (exam_id, label, position, max_mark, pages, option_group_id)
  values (v_exam, '3', 3, 6, '{3}', v_og), (v_exam, '4', 4, 5, '{3}', v_og);

  for v_i in 1 .. v_n loop
    v_total := coalesce(p_totals[v_i], greatest(24 - 2 * (v_i - 1), 0));
    if v_total < 0 or v_total > 24 then
      raise exception 'tests.results_exam: total % is outside 0 to 24', v_total;
    end if;
    v_script := tests.verified_script(v_exam, (case when v_i <= p_home then 'home' else 'centre' end)::public.script_source);
    update public.scripts set state = 'checked' where id = v_script;
    insert into public.marking_units (script_id, exam_id, state, check_state, checked_at)
    values (v_script, v_exam, 'submitted', 'checked', now()) returning id into v_unit;
    v_left := v_total;
    for v_q in
      select q.id, q.max_mark from public.exam_questions q
      where q.exam_id = v_exam and q.max_mark is not null
      order by case q.label when '1' then 1 when 'a' then 2 when 'b' then 3 when '3' then 4 else 5 end
    loop
      v_put := least(v_left, v_q.max_mark);
      v_left := v_left - v_put;
      insert into public.final_marks (unit_id, question_id, mark, source, reason) values (v_unit, v_q.id, v_put, 'first', 'fixture');
    end loop;
  end loop;

  update public.exam_marking set opened_at = now() - interval '1 day', approved_at = now(), approved_by = v_admin
  where exam_id = v_exam;
  return v_exam;
end;
$$;

grant usage on schema tests to anon, authenticated;
grant execute on function tests.as_postgres() to anon, authenticated;
