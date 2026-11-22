begin;
create extension if not exists pgtap with schema extensions;
select plan(122);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Subject s1 ('ZZ Marking holds'): correctors m1, m2, m3 and the lead marker are approved for it; corr is
-- never approved. Subject s2 has its own lead, lead2, and m3 marks it too. Exams (tests.marking_exam: finished 2 days
-- ago) with the test structure (1: 3 marks; 2(a): 2; 2(b): 5): e (whole scripts: a1, a2, a3, and the centre script
-- c1), eq (by question, G1 = question 1, G2 = question 2: g1), en (never opened: v1) and e2 (subject s2: b1). A unit is
-- kept as 'u:<script>' or 'u:<script>/<group>'; a marking as 'mk:<piece>'; a question as 'q:<exam>:<label>'; a page as
-- 'p:<script>:<copy page>'. Pieces are handed out as Next script and an admin's assignment do (marking_unit_take).
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values
  ('admin', tests.create_user('admin', 'active')),
  ('m1', tests.create_user('corrector', 'active')),
  ('m2', tests.create_user('corrector', 'active')),
  ('m3', tests.create_user('corrector', 'active')),
  ('lead', tests.create_user('corrector', 'active')),
  ('lead2', tests.create_user('corrector', 'active')),
  ('corr', tests.create_user('corrector', 'active'));
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table res (name text primary key, j jsonb);
grant all on res to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.u(p text) returns uuid language sql stable as $$ select id from kv where name = 'u:' || p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
create function pg_temp.s1() returns bigint language sql stable as $$ select id from public.subjects where name = 'ZZ Marking holds' $$;
create function pg_temp.s2() returns bigint language sql stable as $$ select id from public.subjects where name = 'ZZ Marking holds two' $$;
create function pg_temp.code(j jsonb) returns text language sql immutable as $$
  select case when (j ->> 'ok')::boolean then 'ok' else coalesce(j ->> 'code', 'none') end $$;
-- 'conflict reason' for a conflict, else the code.
create function pg_temp.why(j jsonb) returns text language sql immutable as $$
  select case when j ->> 'code' = 'conflict' then 'conflict ' || coalesce(j ->> 'reason', '-') else pg_temp.code(j) end $$;
create function pg_temp.mk(p_q uuid, p_mark numeric) returns jsonb language sql immutable as $$
  select jsonb_build_object('op', 'mark', 'question_id', p_q, 'mark', p_mark, 'na', false) $$;
create function pg_temp.tick(p_page uuid) returns jsonb language sql volatile as $$
  select jsonb_build_object('op', 'ann_put', 'id', gen_random_uuid(), 'page_id', p_page, 'kind', 'tick', 'x', 0.5, 'y', 0.5) $$;
create function pg_temp.rev(p text) returns int language sql stable security definer as $$
  select rev from public.markings where id = pg_temp.k(p) $$;
create function pg_temp.path(p_page text) returns text language sql stable security definer as $$
  select marking_path from public.script_pages where id = pg_temp.k(p_page) $$;
create function pg_temp.full(p_page text) returns text language sql stable security definer as $$
  select full_path from public.script_pages where id = pg_temp.k(p_page) $$;
create function pg_temp.seen(p_names text[]) returns int language sql stable as $$
  select count(*)::int from storage.objects where bucket_id = 'script-pages' and name = any (p_names) $$;
create function pg_temp.put(p_names text[]) returns void language sql as $$
  insert into storage.objects (bucket_id, name) select 'script-pages', n from unnest(p_names) n on conflict do nothing $$;
-- A new verified script of an exam, and its pages.
create function pg_temp.script(p_name text, p_exam text, p_source public.script_source default 'home') returns void language plpgsql as $$
begin
  insert into kv values (p_name, tests.verified_script(pg_temp.k(p_exam), p_source));
  insert into kv select 'p:' || p_name || ':' || l.copy_page, l.page_id
  from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version where s.id = pg_temp.k(p_name);
end $$;
create function pg_temp.structure(p_exam text) returns void language plpgsql as $$
begin
  perform tests.structure(pg_temp.k(p_exam));
  insert into kv select 'q:' || p_exam || ':' || coalesce(p.label || '(' || q.label || ')', q.label), q.id
  from public.exam_questions q left join public.exam_questions p on p.id = q.parent_id where q.exam_id = pg_temp.k(p_exam);
end $$;
-- Opens an exam's marking (as marking_open would), makes its verified scripts ready, and keeps their units.
create function pg_temp.open(p text) returns void language plpgsql as $$
begin
  insert into public.exam_marking (exam_id, opened_at, opened_by) values (pg_temp.k(p), now(), pg_temp.uid('admin'))
  on conflict (exam_id) do update set opened_at = excluded.opened_at, closed_at = null;
  perform public.marking_exam_sync(pg_temp.k(p), null);
  insert into kv select 'u:' || x.name || coalesce('/' || g.label, ''), u.id
  from kv x join public.marking_units u on u.script_id = x.id left join public.question_groups g on g.id = u.group_id
  on conflict (name) do nothing;
end $$;
create function pg_temp.take(p text, p_marker text, p_how text default 'next') returns void language sql as $$
  select public.marking_unit_take(pg_temp.u(p), pg_temp.uid(p_marker), p_how,
    case when p_how = 'assigned' then pg_temp.uid('admin') end,
    case when p_how = 'next' then now() + interval '2 hours' end) $$;
create function pg_temp.keep(p text, p_marker text) returns void language sql as $$
  insert into kv select 'mk:' || p, m.id from public.markings m
  where m.unit_id = pg_temp.u(p) and m.kind = 'live' and m.marker_id = pg_temp.uid(p_marker) $$;
-- A marking's marks in paper order: '1=2,2(a)=1'.
create function pg_temp.marks(p text) returns text language sql stable as $$
  select coalesce(string_agg(coalesce(pq.label || '(' || q.label || ')', q.label) || '=' || coalesce(trim_scale(m.mark)::text, 'NR'),
                             ',' order by coalesce(pq.position, q.position), pq.id is not null, q.position), '')
  from public.question_marks m join public.exam_questions q on q.id = m.question_id
  left join public.exam_questions pq on pq.id = q.parent_id
  where m.marking_id = pg_temp.k(p) $$;
create function pg_temp.st(p text) returns text language sql stable as $$ select state::text from public.scripts where id = pg_temp.k(p) $$;
create function pg_temp.us(p text) returns text language sql stable as $$ select state from public.marking_units where id = pg_temp.u(p) $$;
-- A piece's hold: its reason, or '-' when it is not on hold.
create function pg_temp.hold(p text) returns text language sql stable as $$
  select case when on_hold then coalesce(hold_reason, '?') else '-' end from public.marking_units where id = pg_temp.u(p) $$;
create function pg_temp.who(p uuid) returns text language sql stable as $$ select coalesce((select name from c where id = p), '?') $$;
-- Who holds a piece, and how ('-' for nobody).
create function pg_temp.holder(p text) returns text language sql stable as $$
  select coalesce(string_agg(pg_temp.who(a.marker_id) || ' ' || a.how, ',' order by a.created_at), '-')
  from public.marking_assignments a where a.unit_id = pg_temp.u(p) and a.kind = 'live' and a.ended_at is null $$;
-- A marker's live marking on a piece: its status and why it was set aside.
create function pg_temp.ms(p text, p_marker text) returns text language sql stable as $$
  select coalesce((select m.status || coalesce(' ' || m.set_aside_reason, '') from public.markings m
                   where m.unit_id = pg_temp.u(p) and m.kind = 'live' and m.marker_id = pg_temp.uid(p_marker)), '-') $$;
-- A script's alerts: 'kind state[ resolution]', by kind.
create function pg_temp.alerts(p text) returns text language sql stable as $$
  select coalesce(string_agg(a.kind || ' ' || a.state || coalesce(' ' || a.resolution, ''), ',' order by a.kind, a.state, a.created_at), '')
  from public.marking_alerts a where a.script_id = pg_temp.k(p) $$;
create function pg_temp.alert(p text, p_kind text) returns uuid language sql stable security definer as $$
  select a.id from public.marking_alerts a where a.script_id = pg_temp.k(p) and a.kind = p_kind order by a.created_at desc limit 1 $$;
-- How many marking alert emails are queued about a script.
create function pg_temp.notices(p text) returns int language sql stable as $$
  select count(*)::int from public.script_notices n where n.kind = 'marking_alert' and n.script_id = pg_temp.k(p) $$;
create function pg_temp.audits(p_action text, p_target uuid) returns int language sql stable as $$
  select count(*)::int from public.audit_log a where a.action = p_action and a.target_id = p_target $$;
create function pg_temp.student(p text) returns uuid language sql stable as $$
  select b.student_id from public.scripts s join public.bookings b on b.id = s.booking_id where s.id = pg_temp.k(p) $$;
create function pg_temp.upload(p text) returns uuid language sql stable as $$
  select pg.upload_id from public.script_pages pg where pg.id = pg_temp.k('p:' || p || ':1') $$;
-- What would give a candidate away: their first and last name, email, booking id and student id.
create function pg_temp.names(p_script text) returns text[] language sql stable as $$
  select array['Wilhelmina', 'Quarterfield', (select pr.email::text from public.profiles pr where pr.id = pg_temp.student(p_script)),
               (select s.booking_id::text from public.scripts s where s.id = pg_temp.k(p_script)), pg_temp.student(p_script)::text] $$;
create function pg_temp.found_in(p_names text[], p_text text) returns text[] language sql immutable as $$
  select array(select x from unnest(p_names) x where position(lower(x) in lower(p_text)) > 0) $$;
-- A scanned page of a centre script's copy, set aside as script_pages_record does for a script being marked: a page
-- row of a later scan file, refused, and a not_expected exception whose details give the reason script_locked (the
-- script is found by the booking, then written onto the exception, as at the end of the record). Kept as 'x:<script>'.
create function pg_temp.set_aside(p_script text, p_copy_page int) returns uuid language plpgsql as $$
declare
  v_s public.scripts%rowtype;
  v_batch uuid;
  v_staff uuid;
  v_copy uuid;
  v_up uuid := gen_random_uuid();
  v_page uuid;
  v_x uuid;
begin
  select * into v_s from public.scripts where id = pg_temp.k(p_script);
  select u.batch_id, u.uploaded_by into v_batch, v_staff from public.script_uploads u where u.id = pg_temp.upload(p_script);
  select pc.id into v_copy from public.paper_copies pc where pc.booking_id = v_s.booking_id;
  insert into public.script_uploads (id, exam_id, batch_id, kind, position, storage_path, mime, byte_size, sha256, state,
    uploaded_by, created_at, stored_at)
  select v_up, v_s.exam_id, v_batch, 'scan_file', coalesce(max(u.position), 0) + 1, 'batch/' || v_batch || '/' || v_up || '.pdf',
    'application/pdf', 100000, encode(sha256(convert_to(v_up::text, 'UTF8')), 'hex'), 'processed', v_staff, now(), now()
  from public.script_uploads u where u.batch_id = v_batch;
  insert into public.script_pages (upload_id, source_index, exam_id, copy_id, copy_page, state, quality, rotation, full_path, marking_path)
  values (v_up, 0, v_s.exam_id, v_copy, p_copy_page, 'rejected',
    jsonb_build_object('sharpness', 200, 'brightness', 180, 'cut_off', false, 'flags', '[]'::jsonb), 0,
    v_s.exam_id || '/' || v_up || '/1-1/0-full.jpg', v_s.exam_id || '/' || v_up || '/1-1/0-marking.jpg')
  returning id into v_page;
  insert into public.script_exceptions (exam_id, kind, booking_id, page_id, upload_id, details)
  values (v_s.exam_id, 'not_expected', v_s.booking_id, v_page, v_up,
    jsonb_build_object('copy_id', v_copy, 'copy_page', p_copy_page, 'reason', 'script_locked'))
  returning id into v_x;
  update public.script_exceptions set script_id = v_s.id where id = v_x;
  insert into kv values ('x:' || p_script, v_x), ('set_aside:' || p_script, v_page);
  return v_page;
end $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.u(text), pg_temp.r(text), pg_temp.code(jsonb), pg_temp.why(jsonb),
  pg_temp.mk(uuid, numeric), pg_temp.tick(uuid), pg_temp.rev(text), pg_temp.path(text), pg_temp.full(text), pg_temp.seen(text[]),
  pg_temp.found_in(text[], text), pg_temp.alert(text, text) to public;

insert into public.subjects (name, kind) values ('ZZ Marking holds', 'school'), ('ZZ Marking holds two', 'school');
insert into public.marker_approvals (marker_id, subject_id, lead, approved_at)
select c.id, pg_temp.s1(), c.name = 'lead', now() from c where c.name in ('m1', 'm2', 'm3', 'lead');
insert into public.marker_approvals (marker_id, subject_id, lead, approved_at)
values (pg_temp.uid('lead2'), pg_temp.s2(), true, now()), (pg_temp.uid('m3'), pg_temp.s2(), false, now());
update public.profiles set first_name = 'Mara', last_name = 'One' where id = pg_temp.uid('m1');

-- Exam e: whole scripts. c1 is a centre script whose centre has declared its scans complete.
insert into kv values ('e', tests.marking_exam(pg_temp.s1()));
select pg_temp.structure('e');
select pg_temp.script('a1', 'e');
select pg_temp.script('a2', 'e');
select pg_temp.script('a3', 'e');
select pg_temp.script('c1', 'e', 'centre');
insert into public.audit_log (actor_id, action, target_type, target_id)
select pg_temp.uid('admin'), 'scan_centre_completed', 'exam_centre', b.centre_id
from public.scripts s join public.bookings b on b.id = s.booking_id where s.id = pg_temp.k('c1');
select pg_temp.open('e');
-- Exam eq: by question.
insert into kv values ('eq', tests.marking_exam(pg_temp.s1()));
select pg_temp.structure('eq');
insert into public.question_groups (exam_id, label, position) values (pg_temp.k('eq'), 'G1', 1), (pg_temp.k('eq'), 'G2', 2);
update public.exam_questions q set group_id = g.id from public.question_groups g
where q.exam_id = pg_temp.k('eq') and q.parent_id is null and g.exam_id = q.exam_id and g.label = 'G' || q.label;
insert into public.exam_marking (exam_id, mode) values (pg_temp.k('eq'), 'by_question');
select pg_temp.script('g1', 'eq');
select pg_temp.open('eq');
-- Exam en: never opened.
insert into kv values ('en', tests.marking_exam(pg_temp.s1()));
select pg_temp.structure('en');
select pg_temp.script('v1', 'en');
-- Exam e2, of subject s2.
insert into kv values ('e2', tests.marking_exam(pg_temp.s2()));
select pg_temp.structure('e2');
select pg_temp.script('b1', 'e2');
select pg_temp.open('e2');
select pg_temp.take('b1', 'm3');

-- ---------------------------------------------------------------------------------------------
-- picture_change_holds_pieces_and_tells_lead (Review Focus 5): m1 holds a1, has opened it and saved a mark and a tick;
-- then a hidden area changes and the remask gives page 2 a new marking picture.
-- ---------------------------------------------------------------------------------------------
select pg_temp.take('a1', 'm1');
select tests.as_user(pg_temp.uid('m1'));
select public.marking_unit_open(pg_temp.u('a1'));
select tests.as_postgres();
select pg_temp.keep('a1', 'm1');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('s_a1', public.marking_save(pg_temp.k('mk:a1'), 0, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 2), pg_temp.tick(pg_temp.k('p:a1:1')))));
select tests.as_postgres();
insert into res select 'old_a1', to_jsonb(pg_temp.path('p:a1:2'));
update public.script_pages set marking_path = replace(marking_path, '-marking.jpg', '-remask-marking.jpg') where id = pg_temp.k('p:a1:2');
select is(array[pg_temp.code(pg_temp.r('s_a1')), pg_temp.us('a1'), pg_temp.hold('a1')], array['ok', 'taken', 'picture_changed'],
  'picture_change_holds_pieces_and_tells_lead: the piece m1 holds is on hold because a picture changed');
select is(pg_temp.alerts('a1'), 'picture_changed open', 'one open alert');
select is((select array[a.exam_id, a.page_id] from public.marking_alerts a where a.id = pg_temp.alert('a1', 'picture_changed')),
  array[pg_temp.k('e'), pg_temp.k('p:a1:2')], 'about the exam and the page whose picture changed');
select is((select count(*)::int from public.script_notices n
           where n.kind = 'marking_alert' and n.alert_id = pg_temp.alert('a1', 'picture_changed') and n.exam_id = pg_temp.k('e')
             and n.script_id = pg_temp.k('a1') and n.sent_at is null),
  1, 'one marking_alert email is queued for it');
select is((select array_agg((r ->> 'profile_id')::uuid order by r ->> 'profile_id')
           from public.script_notices n, jsonb_array_elements(public.script_notice_recipients(n)) r
           where n.kind = 'marking_alert' and n.script_id = pg_temp.k('a1')),
  (select array_agg(p.id order by p.id::text) from public.profiles p
   where p.status = 'active' and (p.role in ('owner', 'admin') or p.id = pg_temp.uid('lead'))),
  'it goes to the subject''s lead marker and the active owner and admin accounts');
insert into res select 'content_a1', public.script_notice_content(n) from public.script_notices n
where n.kind = 'marking_alert' and n.script_id = pg_temp.k('a1');
select is(array[pg_temp.r('content_a1') ->> 'alert_kind', pg_temp.r('content_a1') ->> 'exam', pg_temp.r('content_a1') ->> 'script_number'],
  array['picture_changed', 'ZZ Marking exam Paper 1', (select number from public.scripts where id = pg_temp.k('a1'))],
  'the email says the kind of alert, the exam and the script number');
select is(pg_temp.found_in(pg_temp.names('a1') || array['Mara'], pg_temp.r('content_a1')::text), '{}'::text[],
  'and names neither the candidate nor the marker');
select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.code(public.marking_unit_open(pg_temp.u('a1'))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 1, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 3))))],
  array['on_hold', 'on_hold'], 'the piece neither opens nor saves');
select tests.as_postgres();
select is(array[pg_temp.marks('mk:a1'), pg_temp.rev('mk:a1')::text,
                (select count(*)::text from public.page_annotations a where a.marking_id = pg_temp.k('mk:a1') and a.deleted_at is null)],
  array['1=2', '1', '1'], 'the marks and the tick are as m1 saved them');
select pg_temp.put(array[pg_temp.r('old_a1') #>> '{}', pg_temp.path('p:a1:2'), pg_temp.path('p:a1:1'), pg_temp.full('p:a1:2')]);
select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.seen(array[pg_temp.r('old_a1') #>> '{}', pg_temp.path('p:a1:2'), pg_temp.path('p:a1:1')]), 0,
  'm1 reads neither the old picture nor the new one, nor the piece''s other pages');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('lead'));
select is(array[pg_temp.seen(array[pg_temp.path('p:a1:2')]), pg_temp.seen(array[pg_temp.path('p:a1:1')]),
                pg_temp.seen(array[pg_temp.r('old_a1') #>> '{}']), pg_temp.seen(array[pg_temp.full('p:a1:2')])],
  array[1, 1, 0, 0], 'the lead reads the script''s marking pictures while the alert is open: never the old one or a full picture');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('lead2'));
select is(pg_temp.seen(array[pg_temp.path('p:a1:2'), pg_temp.path('p:a1:1')]), 0, 'the lead of another subject reads none');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m2'));
select is(pg_temp.seen(array[pg_temp.path('p:a1:2'), pg_temp.path('p:a1:1')]), 0, 'nor another marker');
select tests.as_postgres();
update public.script_pages set marking_path = replace(marking_path, '-remask-marking.jpg', '-again-marking.jpg') where id = pg_temp.k('p:a1:2');
select is(array[pg_temp.alerts('a1'), pg_temp.notices('a1')::text], array['picture_changed open', '1'],
  'a second change while the alert is open raises no second alert or email');
select pg_temp.put(array[pg_temp.path('p:a1:2')]);
-- b1 (subject s2), held by m3: its picture changes too.
update public.script_pages set marking_path = replace(marking_path, '-marking.jpg', '-remask-marking.jpg') where id = pg_temp.k('p:b1:1');
select is(array[pg_temp.hold('b1'), pg_temp.alerts('b1')], array['picture_changed', 'picture_changed open'], 'b1 is held and has its alert');

-- ---------------------------------------------------------------------------------------------
-- lead_of_other_subject_cannot_release
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('lead2'));
select is(pg_temp.code(public.marking_alert_release(pg_temp.alert('a1', 'picture_changed'), 'Looks fine to me')), 'forbidden',
  'lead_of_other_subject_cannot_release: the lead of subject s2 cannot release a1''s alert');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m2'));
select is(pg_temp.code(public.marking_alert_release(pg_temp.alert('a1', 'picture_changed'), 'Looks fine to me')), 'forbidden',
  'nor a marker who leads no subject');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('corr'));
select is(pg_temp.code(public.marking_alert_release(pg_temp.alert('a1', 'picture_changed'), 'Looks fine to me')), 'forbidden',
  'nor a corrector who is not approved');
select tests.as_postgres();
select is(array[pg_temp.alerts('a1'), pg_temp.hold('a1')], array['picture_changed open', 'picture_changed'], 'the alert is still open and the piece held');

-- ---------------------------------------------------------------------------------------------
-- lead_releases_and_marker_carries_on: m1's hold had 10 minutes left.
-- ---------------------------------------------------------------------------------------------
update public.marking_assignments set hold_until = now() + interval '10 minutes' where unit_id = pg_temp.u('a1') and ended_at is null;
select tests.as_user(pg_temp.uid('lead'));
select is(pg_temp.code(public.marking_alert_release(pg_temp.alert('a1', 'picture_changed'), 'ab')), 'reason_required',
  'lead_releases_and_marker_carries_on: a release needs a reason');
insert into res values ('rel_a1', public.marking_alert_release(pg_temp.alert('a1', 'picture_changed'), 'The new picture hides the name'));
insert into res values ('rel_a1b', public.marking_alert_release(pg_temp.alert('a1', 'picture_changed'), 'The new picture hides the name'));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('rel_a1')), pg_temp.hold('a1'), pg_temp.alerts('a1')], array['ok', '-', 'picture_changed closed released'],
  'the lead releases the alert: the piece is no longer on hold');
select is((select array[a.closed_by::text, a.reason, (a.closed_at = now())::text] from public.marking_alerts a where a.id = pg_temp.alert('a1', 'picture_changed')),
  array[pg_temp.uid('lead')::text, 'The new picture hides the name', 'true'], 'the alert says who released it, when and why');
select is((select a.hold_until from public.marking_assignments a where a.unit_id = pg_temp.u('a1') and a.ended_at is null),
  now() + interval '2 hours', 'm1''s hold restarts at now + 2 hours');
select is((select count(*)::int from public.audit_log a where a.action = 'marking_alert_released' and a.target_id = pg_temp.alert('a1', 'picture_changed')
             and a.actor_id = pg_temp.uid('lead') and a.reason = 'The new picture hides the name'),
  1, 'an audit row with the reason');
select is(pg_temp.why(pg_temp.r('rel_a1b')), 'conflict closed', 'a closed alert is not released again');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('open_a1', public.marking_unit_open(pg_temp.u('a1')));
insert into res values ('s_a1b', public.marking_save(pg_temp.k('mk:a1'), 1, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 3))));
select is(array[pg_temp.code(pg_temp.r('open_a1')), pg_temp.code(pg_temp.r('s_a1b')), pg_temp.seen(array[pg_temp.path('p:a1:2')])::text],
  array['ok', 'ok', '1'], 'm1 carries on: the piece opens, saves and shows its new picture');
select tests.as_postgres();
select is(pg_temp.marks('mk:a1'), '1=3', 'with the new mark');
select tests.as_user(pg_temp.uid('lead'));
select is(pg_temp.seen(array[pg_temp.path('p:a1:2')]), 0, 'the lead reads a1''s pictures no more: it has no open alert');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- picture_removed_holds_and_cannot_be_released: m1 holds a2; page 3 loses its marking picture, then page 1 gets a new
-- one.
-- ---------------------------------------------------------------------------------------------
select pg_temp.take('a2', 'm1');
update public.script_pages set marking_path = null where id = pg_temp.k('p:a2:3');
select is(array[pg_temp.hold('a2'), pg_temp.alerts('a2'), pg_temp.notices('a2')::text], array['picture_missing', 'picture_missing open', '1'],
  'picture_removed_holds_and_cannot_be_released: the piece is held because a picture is missing; one alert, one email');
update public.script_pages set marking_path = replace(marking_path, '-marking.jpg', '-remask-marking.jpg') where id = pg_temp.k('p:a2:1');
select is(array[pg_temp.hold('a2'), pg_temp.alerts('a2'), pg_temp.notices('a2')::text],
  array['picture_missing', 'picture_changed open,picture_missing open', '2'],
  'a picture change after it raises its own alert; the piece stays held for the missing picture');
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('list_lead', public.marking_alerts_list());
select is(array[pg_temp.code(public.marking_alert_release(pg_temp.alert('a2', 'picture_missing'), 'Looks fine to me')),
                pg_temp.why(public.marking_alert_release(pg_temp.alert('a2', 'picture_changed'), 'Looks fine to me'))],
  array['wrong_kind', 'conflict picture_missing'],
  'a missing picture is never released, and neither is a change while a page has no picture');
select tests.as_postgres();
select is((select array_agg((a ->> 'can_release') || ' ' || (a ->> 'kind') order by a ->> 'kind') from jsonb_array_elements(pg_temp.r('list_lead') -> 'alerts') a
           where (a ->> 'script_id')::uuid = pg_temp.k('a2')),
  array['false picture_changed', 'false picture_missing'], 'the list says neither alert of a2 can be released');
select is(array[pg_temp.hold('a2'), pg_temp.alerts('a2')], array['picture_missing', 'picture_changed open,picture_missing open'], 'nothing changed');

-- ---------------------------------------------------------------------------------------------
-- picture_change_on_unlocked_script_raises_nothing: v1 is verified (its exam's marking never opened).
-- ---------------------------------------------------------------------------------------------
update public.script_pages set marking_path = replace(marking_path, '-marking.jpg', '-remask-marking.jpg') where id = pg_temp.k('p:v1:1');
update public.script_pages set marking_path = null where id = pg_temp.k('p:v1:2');
select is(array[pg_temp.st('v1'), pg_temp.alerts('v1'), pg_temp.notices('v1')::text,
                (select count(*)::text from public.marking_units u where u.script_id = pg_temp.k('v1'))],
  array['verified', '', '0', '0'], 'picture_change_on_unlocked_script_raises_nothing: no alert, no email, no piece');

-- ---------------------------------------------------------------------------------------------
-- name_visible_takes_script_back_and_excludes_reporter: g1 is marked by question; m1 holds G2 and m2 holds G1, and each
-- has saved a mark. A name shows on page 2 of G2.
-- ---------------------------------------------------------------------------------------------
select pg_temp.take('g1/G2', 'm1');
select pg_temp.take('g1/G1', 'm2');
select tests.as_user(pg_temp.uid('m1'));
select public.marking_unit_open(pg_temp.u('g1/G2'));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m2'));
select public.marking_unit_open(pg_temp.u('g1/G1'));
select tests.as_postgres();
select pg_temp.keep('g1/G2', 'm1');
select pg_temp.keep('g1/G1', 'm2');
select tests.as_user(pg_temp.uid('m1'));
select public.marking_save(pg_temp.k('mk:g1/G2'), 0, jsonb_build_array(pg_temp.mk(pg_temp.k('q:eq:2(a)'), 1)));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m2'));
select public.marking_save(pg_temp.k('mk:g1/G1'), 0, jsonb_build_array(pg_temp.mk(pg_temp.k('q:eq:1'), 2)));
select tests.as_postgres();
-- staff_can_hide_the_name_after_take_back, before: the script is being marked.
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.script_page_set_hidden_areas(pg_temp.k('p:g1:2'), '[{"x":0.1,"y":0.05,"w":0.4,"h":0.08}]', 'Hide the name')),
  'script_locked', 'staff_can_hide_the_name_after_take_back: while g1 is being marked its page cannot be changed');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m3'));
select is(pg_temp.code(public.marking_name_visible(pg_temp.u('g1/G2'), pg_temp.k('p:g1:2'))), 'forbidden',
  'name_visible_takes_script_back_and_excludes_reporter: a marker who does not hold the piece cannot report a name on it');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.code(public.marking_name_visible(pg_temp.u('g1/G2'), pg_temp.k('p:a1:2'))),
                pg_temp.code(public.marking_name_visible(pg_temp.u('g1/G2'), gen_random_uuid())),
                pg_temp.code(public.marking_name_visible(pg_temp.u('g1/G2'), null))],
  array['invalid_input', 'invalid_input', 'invalid_input'], 'the page must be one of the piece''s');
insert into res values ('nv', public.marking_name_visible(pg_temp.u('g1/G2'), pg_temp.k('p:g1:2')));
select tests.as_postgres();
select is(pg_temp.r('nv'), '{"ok": true}'::jsonb, 'm1 reports the name on page 2');
select is((select array[s.state::text, (s.taken_back_at = now())::text, pg_temp.who(s.taken_back_by), s.taken_back_reason]
           from public.scripts s where s.id = pg_temp.k('g1')),
  array['needs_attention', 'true', 'm1', 'name_visible'], 'the script is taken back from the markers and needs attention');
select is((select array[e.state, e.details ->> 'from', e.script_id::text, e.booking_id::text, e.upload_id::text]
           from public.script_exceptions e where e.page_id = pg_temp.k('p:g1:2') and e.kind = 'name_visible'),
  array['open', 'marker', pg_temp.k('g1')::text, (select booking_id::text from public.scripts where id = pg_temp.k('g1')), pg_temp.upload('g1')::text],
  'a name_visible exception is open for the page, from the marker');
select is(array[pg_temp.ms('g1/G2', 'm1'), pg_temp.holder('g1/G2'), pg_temp.us('g1/G2'), pg_temp.hold('g1/G2')],
  array['set_aside name_seen', '-', 'open', 'name_visible'], 'm1''s marking is set aside, their hold ends and the piece is open, on hold');
select is((select a.end_reason from public.marking_assignments a where a.unit_id = pg_temp.u('g1/G2') and a.marker_id = pg_temp.uid('m1')),
  'name_seen', 'their assignment ended because they saw a name');
select is((select array_agg(x.reason) from public.marking_unit_exclusions x where x.unit_id = pg_temp.u('g1/G2') and x.marker_id = pg_temp.uid('m1')),
  array['name_seen'], 'Next script will not offer them the piece again');
select is(array[pg_temp.ms('g1/G1', 'm2'), pg_temp.holder('g1/G1'), pg_temp.us('g1/G1'), pg_temp.hold('g1/G1'), pg_temp.marks('mk:g1/G1')],
  array['in_progress', 'm2 next', 'taken', 'name_visible', '1=2'], 'the other group stays with m2, on hold, with their mark');
select is((select bool_or(public.script_page_locked(l.page_id)) from public.script_page_links l
           join public.scripts s on s.id = l.script_id and l.version = s.version where s.id = pg_temp.k('g1')),
  false, 'no page of the script is locked any more');
select is(array[pg_temp.alerts('g1'), pg_temp.notices('g1')::text], array['name_visible open', '1'], 'a name_visible alert, and its email');
select is((select array[a.unit_id, a.page_id] from public.marking_alerts a where a.id = pg_temp.alert('g1', 'name_visible')),
  array[pg_temp.u('g1/G2'), pg_temp.k('p:g1:2')], 'about the piece and the page');
select is(array[pg_temp.audits('marking_name_visible', pg_temp.u('g1/G2')), pg_temp.audits('marking_script_taken_back', pg_temp.k('g1'))],
  array[1, 1], 'audited: the report and the take-back');
select tests.as_user(pg_temp.uid('m2'));
select is(pg_temp.code(public.marking_unit_open(pg_temp.u('g1/G1'))), 'on_hold', 'm2''s piece does not open while the script is back with staff');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.code(public.marking_name_visible(pg_temp.u('g1/G2'), pg_temp.k('p:g1:2'))), 'forbidden', 'm1 cannot report it twice');
select tests.as_postgres();
select pg_temp.put(array[pg_temp.path('p:g1:2'), pg_temp.path('p:g1:1')]);
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.seen(array[pg_temp.path('p:g1:2'), pg_temp.path('p:g1:1')]), 2, 'staff read the script''s marking pictures');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('lead'));
select is(pg_temp.seen(array[pg_temp.path('p:g1:2'), pg_temp.path('p:g1:1')]), 0,
  'the lead reads no picture of a script whose name shows');
select tests.as_postgres();
-- Not even with another alert open on the script (made here for the check, then removed).
insert into public.marking_alerts (exam_id, kind, script_id) values (pg_temp.k('eq'), 'pages_set_aside', pg_temp.k('g1'));
select tests.as_user(pg_temp.uid('lead'));
select is(pg_temp.seen(array[pg_temp.path('p:g1:1')]), 0, 'not even while another alert of the script is open');
select tests.as_postgres();
delete from public.marking_alerts where script_id = pg_temp.k('g1') and kind = 'pages_set_aside';

-- ---------------------------------------------------------------------------------------------
-- name_visible_takes_no_free_text
-- ---------------------------------------------------------------------------------------------
select is((select array[p.pronargs::text, oidvectortypes(p.proargtypes)] from pg_proc p
           where p.oid = 'public.marking_name_visible(uuid, uuid)'::regprocedure),
  array['2', 'uuid, uuid'], 'name_visible_takes_no_free_text: the function takes the piece and the page only');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = 'marking_name_visible'),
  1, 'and there is no other version of it');

-- ---------------------------------------------------------------------------------------------
-- staff_can_hide_the_name_after_take_back, hand_back_needs_verified_and_not_busy
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.why(public.marking_script_hand_back(pg_temp.k('g1'))), 'conflict not_verified',
  'hand_back_needs_verified_and_not_busy: a script that needs attention is not handed back');
select is(pg_temp.code(public.script_page_set_hidden_areas(pg_temp.k('p:g1:2'), '[{"x":0.1,"y":0.05,"w":0.4,"h":0.08}]', 'Hide the name')),
  'ok', 'staff hide the name on the page');
select is(pg_temp.code(public.script_exception_confirm((select e.id from public.script_exceptions e where e.page_id = pg_temp.k('p:g1:2') and e.kind = 'name_visible'),
                                                       'The name is hidden now')),
  'ok', 'and confirm it, which they could not do while the script was being marked');
select tests.as_postgres();
select is(array[pg_temp.st('g1'), public.marking_script_busy(pg_temp.k('g1'))::text], array['verified', 'true'],
  'the script is verified; its new marking pictures are being made');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.why(public.marking_script_hand_back(pg_temp.k('g1'))), 'conflict pictures_updating', 'so it is not handed back yet');
select tests.as_postgres();
-- The remask finishes: page 2 gets its new marking picture. The script is not being marked, so nothing is held.
update public.processing_jobs set state = 'done', finished_at = now() where upload_id = pg_temp.upload('g1') and kind = 'remask' and state in ('queued', 'running');
update public.script_pages set marking_path = replace(marking_path, '-marking.jpg', '-remask-marking.jpg') where id = pg_temp.k('p:g1:2');
select is(array[pg_temp.alerts('g1'), public.marking_script_busy(pg_temp.k('g1'))::text], array['name_visible open', 'false'],
  'the new picture raises nothing: the script is with staff');

-- ---------------------------------------------------------------------------------------------
-- hand_back_returns_pieces_to_their_markers: m2's hold had 5 minutes left.
-- ---------------------------------------------------------------------------------------------
update public.marking_assignments set hold_until = now() + interval '5 minutes' where unit_id = pg_temp.u('g1/G1') and ended_at is null;
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('hb_g1', public.marking_script_hand_back(pg_temp.k('g1')));
insert into res values ('hb_g1b', public.marking_script_hand_back(pg_temp.k('g1')));
select tests.as_postgres();
select is(pg_temp.r('hb_g1'), '{"ok": true, "state": "marking", "reopened": 0}'::jsonb,
  'hand_back_returns_pieces_to_their_markers: the script is handed back and is being marked again');
select is((select array[s.taken_back_at::text, s.taken_back_by::text, s.taken_back_reason, s.extras_locked::text] from public.scripts s where s.id = pg_temp.k('g1')),
  array[null, null, null, '[]'], 'it is no longer taken back, and its extra pages are written down again');
select is(array[pg_temp.holder('g1/G1'), pg_temp.hold('g1/G1'), pg_temp.ms('g1/G1', 'm2')], array['m2 next', '-', 'in_progress'],
  'G1 is m2''s again, no longer on hold');
select is((select a.hold_until from public.marking_assignments a where a.unit_id = pg_temp.u('g1/G1') and a.ended_at is null),
  now() + interval '2 hours', 'and m2''s hold restarts at now + 2 hours');
select is(array[pg_temp.us('g1/G2'), pg_temp.hold('g1/G2'), pg_temp.ms('g1/G2', 'm1'),
                public.marking_unit_blocked(pg_temp.u('g1/G2'), pg_temp.uid('m1'), null, true),
                coalesce(public.marking_unit_blocked(pg_temp.u('g1/G2'), pg_temp.uid('m3'), null, true), 'free')],
  array['open', '-', 'set_aside name_seen', 'name_seen', 'free'], 'G2 is free for another marker, not for m1');
select is(pg_temp.alerts('g1'), 'name_visible closed handed_back', 'the alert closes');
select is((select count(*)::int from public.audit_log a where a.action = 'marking_script_handed_back' and a.target_id = pg_temp.k('g1')
             and a.actor_id = pg_temp.uid('admin')),
  1, 'audited');
select is(pg_temp.why(pg_temp.r('hb_g1b')), 'conflict not_taken_back', 'a script not taken back is not handed back');
select tests.as_user(pg_temp.uid('m2'));
insert into res values ('open_g1', public.marking_unit_open(pg_temp.u('g1/G1')));
select is(array[pg_temp.code(pg_temp.r('open_g1')), pg_temp.r('open_g1') -> 'marking' ->> 'pages_changed', jsonb_array_length(pg_temp.r('open_g1') -> 'marks')::text,
                pg_temp.code(public.marking_save(pg_temp.k('mk:g1/G1'), pg_temp.rev('mk:g1/G1'), jsonb_build_array(pg_temp.mk(pg_temp.k('q:eq:1'), 3))))],
  array['ok', 'false', '1', 'ok'], 'm2 opens G1 with their mark, the same pages, and saves');
select tests.as_postgres();
select is(pg_temp.marks('mk:g1/G1'), '1=3', 'their work goes on');

-- ---------------------------------------------------------------------------------------------
-- hand_back_with_same_pages_keeps_submitted, manual_take_back_stays_back_until_handed_back: m2 marked a3 (assigned).
-- ---------------------------------------------------------------------------------------------
select pg_temp.take('a3', 'm2', 'assigned');
select tests.as_user(pg_temp.uid('m2'));
select public.marking_unit_open(pg_temp.u('a3'));
select tests.as_postgres();
select pg_temp.keep('a3', 'm2');
select tests.as_user(pg_temp.uid('m2'));
select public.marking_save(pg_temp.k('mk:a3'), 0, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 1), pg_temp.mk(pg_temp.k('q:e:2(a)'), 1),
                                                                     pg_temp.mk(pg_temp.k('q:e:2(b)'), 1)));
select public.marking_submit(pg_temp.k('mk:a3'), 1);
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_script_take_back(pg_temp.k('a3'), 'ab')), 'reason_required',
  'manual_take_back_stays_back_until_handed_back: taking a script back needs a reason');
select is(pg_temp.code(public.marking_script_take_back(null, 'Check the pages')), 'invalid_input', 'and a script');
select is(pg_temp.code(public.marking_script_take_back(gen_random_uuid(), 'Check the pages')), 'not_found', 'one that exists');
insert into res values ('tb_a3', public.marking_script_take_back(pg_temp.k('a3'), 'Check the pages'));
insert into res values ('tb_a3b', public.marking_script_take_back(pg_temp.k('a3'), 'Check the pages'));
select tests.as_postgres();
select is(pg_temp.r('tb_a3'), '{"ok": true, "state": "verified"}'::jsonb, 'an admin takes the marked script back; with nothing open it is verified');
select is((select array[(s.taken_back_at = now())::text, pg_temp.who(s.taken_back_by), s.taken_back_reason] from public.scripts s where s.id = pg_temp.k('a3')),
  array['true', 'admin', 'Check the pages'], 'who took it back, when and why');
select is(array[pg_temp.us('a3'), pg_temp.hold('a3'), pg_temp.ms('a3', 'm2'), pg_temp.alerts('a3')], array['submitted', 'taken_back', 'submitted', ''],
  'its piece is on hold, the submitted marking is kept; no alert');
select is((select count(*)::int from public.audit_log a where a.action = 'marking_script_taken_back' and a.target_id = pg_temp.k('a3')
             and a.reason = 'Check the pages' and a.actor_id = pg_temp.uid('admin')),
  1, 'audited with the reason');
select is(pg_temp.why(pg_temp.r('tb_a3b')), 'conflict taken_back', 'it is not taken back twice');
select public.marking_exam_sync(pg_temp.k('e'), null);
select is(array[pg_temp.st('a3'), public.marking_script_blocked(pg_temp.k('a3'), null)], array['verified', 'taken_back'],
  'the minute job does not make it ready: it stays back until handed back');
select tests.as_user(pg_temp.uid('m2'));
select is(pg_temp.code(public.marking_unit_open(pg_temp.u('a3'))), 'on_hold', 'its marker cannot open it meanwhile');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_script_hand_back(pg_temp.k('a3'), 'ab')), 'reason_required', 'hand_back_with_same_pages_keeps_submitted: a reason given is 3 to 300 characters');
insert into res values ('hb_a3', public.marking_script_hand_back(pg_temp.k('a3'), 'Pages are fine'));
select tests.as_postgres();
select is(pg_temp.r('hb_a3'), '{"ok": true, "state": "marked", "reopened": 0}'::jsonb, 'handed back with the same pages, the script is marked again');
select is(array[pg_temp.us('a3'), pg_temp.hold('a3'), pg_temp.ms('a3', 'm2'), pg_temp.holder('a3'), pg_temp.alerts('a3'), pg_temp.marks('mk:a3')],
  array['submitted', '-', 'submitted', '-', '', '1=1,2(a)=1,2(b)=1'], 'the submitted marking is kept as it was; nothing to check');
select is((select pages_changed_at from public.markings where id = pg_temp.k('mk:a3')), null::timestamptz, 'and its pages are not marked as changed');

-- ---------------------------------------------------------------------------------------------
-- set_aside_scan_page_raises_alert_and_adds_nothing: m1 marked c1 (centre). A later scan file holds a page of c1's copy
-- (copy page 4, a spare page), set aside because the script is being marked.
-- ---------------------------------------------------------------------------------------------
select pg_temp.take('c1', 'm1', 'assigned');
select tests.as_user(pg_temp.uid('m1'));
select public.marking_unit_open(pg_temp.u('c1'));
select tests.as_postgres();
select pg_temp.keep('c1', 'm1');
select tests.as_user(pg_temp.uid('m1'));
select public.marking_save(pg_temp.k('mk:c1'), 0, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 2), pg_temp.mk(pg_temp.k('q:e:2(a)'), 2),
                                                                     pg_temp.mk(pg_temp.k('q:e:2(b)'), 4)));
select public.marking_submit(pg_temp.k('mk:c1'), 1);
select tests.as_postgres();
insert into res select 'key_c1', to_jsonb(public.marking_pages_key(pg_temp.k('c1')));
select pg_temp.set_aside('c1', 4);
select is(array[pg_temp.st('c1'), pg_temp.alerts('c1'), pg_temp.notices('c1')::text], array['marked', 'pages_set_aside open', '1'],
  'set_aside_scan_page_raises_alert_and_adds_nothing: an alert that pages were set aside, and its email');
select is((select array[a.page_id::text, coalesce(a.unit_id::text, '-')] from public.marking_alerts a where a.id = pg_temp.alert('c1', 'pages_set_aside')),
  array[pg_temp.k('set_aside:c1')::text, '-'], 'about the page set aside');
select is(array[pg_temp.hold('c1'), pg_temp.ms('c1', 'm1'), (public.marking_pages_key(pg_temp.k('c1')) = pg_temp.r('key_c1') #>> '{}')::text,
                (select count(*)::text from public.marking_script_pages(pg_temp.k('c1')))],
  array['-', 'submitted', 'true', '3'], 'nothing is held and the piece''s pages are unchanged');
select tests.as_user(pg_temp.uid('lead'));
select is(pg_temp.code(public.marking_alert_note(pg_temp.alert('a2', 'picture_changed'), 'Seen it')), 'wrong_kind',
  'marking_alert_note closes only alerts about pages set aside or changed');
insert into res values ('note_c1', public.marking_alert_note(pg_temp.alert('c1', 'pages_set_aside'), 'Staff will place it'));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('note_c1')), pg_temp.alerts('c1'), pg_temp.audits('marking_alert_noted', pg_temp.alert('c1', 'pages_set_aside'))::text],
  array['ok', 'pages_set_aside closed noted', '1'], 'the lead notes the alert (audited)');

-- ---------------------------------------------------------------------------------------------
-- set_aside_page_can_be_placed_after_take_back, hand_back_reopens_submitted_piece_when_pages_changed
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.script_exception_assign(pg_temp.k('x:c1'), (select booking_id from public.scripts where id = pg_temp.k('c1')), 4,
                                                      'A spare page of this candidate')),
  'script_locked', 'set_aside_page_can_be_placed_after_take_back: the page cannot be placed while the script is being marked');
insert into res values ('tb_c1', public.marking_script_take_back(pg_temp.k('c1'), 'Place the page set aside'));
insert into res values ('as_c1', public.script_exception_assign(pg_temp.k('x:c1'), (select booking_id from public.scripts where id = pg_temp.k('c1')), 4,
                                                                'A spare page of this candidate'));
select tests.as_postgres();
select is(pg_temp.r('tb_c1'), '{"ok": true, "state": "needs_attention"}'::jsonb, 'taken back, the script needs attention (the page set aside is open)');
select is(array[pg_temp.code(pg_temp.r('as_c1')), pg_temp.st('c1'),
                (select string_agg(l.copy_page::text, ',' order by l.copy_page) from public.scripts s
                 join public.script_page_links l on l.script_id = s.id and l.version = s.version where s.id = pg_temp.k('c1'))],
  array['ok', 'verified', '1,2,3,4'], 'staff place the page: the script shows it and is verified');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('hb_c1', public.marking_script_hand_back(pg_temp.k('c1')));
select tests.as_postgres();
select is(pg_temp.r('hb_c1'), '{"ok": true, "state": "marking", "reopened": 1}'::jsonb,
  'hand_back_reopens_submitted_piece_when_pages_changed: one submitted piece reopens, and the script is being marked');
select is((select array[m.status, (m.pages_key = public.marking_pages_key(pg_temp.k('c1')))::text, (m.pages_changed_at = now())::text,
                        (m.submitted_at is null)::text, m.rev::text]
           from public.markings m where m.id = pg_temp.k('mk:c1')),
  array['in_progress', 'true', 'true', 'true', '3'], 'm1''s marking is in progress again, with the new pages; its rev moves on');
select is(array[pg_temp.us('c1'), pg_temp.hold('c1'), pg_temp.holder('c1'), pg_temp.marks('mk:c1')],
  array['taken', '-', 'm1 assigned', '1=2,2(a)=2,2(b)=4'], 'the piece is m1''s again, with no time limit, and their marks are kept');
select is(array[pg_temp.alerts('c1'), pg_temp.notices('c1')::text], array['pages_changed open,pages_set_aside closed noted', '2'],
  'a pages_changed alert, and its email');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('open_c1', public.marking_unit_open(pg_temp.u('c1')));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('open_c1')), pg_temp.r('open_c1') -> 'marking' ->> 'pages_changed',
                jsonb_array_length(pg_temp.r('open_c1') -> 'pages')::text, pg_temp.r('open_c1') -> 'marking' ->> 'status'],
  array['ok', 'true', '4', 'in_progress'], 'm1 opens it: four pages, and it says they changed');

-- ---------------------------------------------------------------------------------------------
-- alerts_list_has_no_name
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('list_admin', public.marking_alerts_list());
insert into res values ('list_all', public.marking_alerts_list(null, null));
insert into res values ('list_closed', public.marking_alerts_list(pg_temp.k('e'), 'closed'));
select is(pg_temp.code(public.marking_alerts_list(null, 'nope')), 'invalid_input', 'alerts_list_has_no_name: the state is open, closed or none (all)');
select is(pg_temp.code(public.marking_alerts_list(gen_random_uuid())), 'not_found', 'an unknown exam is not found');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('lead'));
insert into res values ('list_lead2', public.marking_alerts_list());
select is(pg_temp.code(public.marking_alerts_list(pg_temp.k('e2'))), 'forbidden', 'a lead asks for an exam of their subject only');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('lead2'));
insert into res values ('list_lead_two', public.marking_alerts_list());
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.code(public.marking_alerts_list()), 'forbidden', 'a marker who leads no subject sees no alerts');
select tests.as_postgres();
select is((select array_agg(pg_temp.alerts(x) order by x) from unnest(array['a2', 'b1', 'c1']) x),
  array['picture_changed open,picture_missing open', 'picture_changed open', 'pages_changed open,pages_set_aside closed noted'],
  'the alerts still open: a2''s two, b1''s and c1''s pages_changed');
select is((select array_agg(x order by x) from (
             select (a ->> 'kind') || ' ' || (select name from kv where id = (a ->> 'script_id')::uuid and name !~ ':') as x
             from jsonb_array_elements(pg_temp.r('list_admin') -> 'alerts') a where (a ->> 'script_id')::uuid in (select id from kv)) t),
  array['pages_changed c1', 'picture_changed a2', 'picture_changed b1', 'picture_missing a2'], 'an admin sees every open alert');
select is((select count(*)::int from jsonb_array_elements(pg_temp.r('list_all') -> 'alerts') a where (a ->> 'script_id')::uuid in (select id from kv)),
  7, 'open and closed alike when no state is asked for');
select is((select array_agg(x order by x) from (
             select (a ->> 'kind') || ' ' || (select name from kv where id = (a ->> 'script_id')::uuid and name !~ ':') as x
             from jsonb_array_elements(pg_temp.r('list_closed') -> 'alerts') a) t),
  array['pages_set_aside c1', 'picture_changed a1'], 'the closed alerts of exam e');
select is((select a from jsonb_array_elements(pg_temp.r('list_admin') -> 'alerts') a where (a ->> 'script_id')::uuid = pg_temp.k('a2') and a ->> 'kind' = 'picture_missing'),
  (select jsonb_build_object('id', al.id, 'kind', 'picture_missing', 'exam_id', pg_temp.k('e'), 'exam_title', 'ZZ Marking exam', 'script_id', pg_temp.k('a2'),
     'script_number', s.number, 'index_number', d.index_number, 'page_n', 3, 'unit_id', null, 'created_at', al.created_at, 'can_release', false)
   from public.marking_alerts al join public.scripts s on s.id = al.script_id join public.bookings b on b.id = s.booking_id
   join public.student_details d on d.profile_id = b.student_id
   where al.id = pg_temp.alert('a2', 'picture_missing')),
  'each alert: its exam, script number, index number, the page (by its number in the piece) and whether it can be released');
select is((select array_agg(a ->> 'kind' order by a ->> 'kind') from jsonb_array_elements(pg_temp.r('list_lead2') -> 'alerts') a
           where (a ->> 'script_id')::uuid in (select id from kv)),
  array['pages_changed', 'picture_changed', 'picture_missing'], 'the lead sees the open alerts of their subject only (not b1''s)');
select is((select array_agg((a ->> 'script_id')::uuid) from jsonb_array_elements(pg_temp.r('list_lead_two') -> 'alerts') a
           where (a ->> 'script_id')::uuid in (select id from kv)),
  array[pg_temp.k('b1')], 'the lead of subject s2 sees b1''s alert only');
select is(pg_temp.found_in(pg_temp.names('a2') || pg_temp.names('b1') || pg_temp.names('c1') || pg_temp.names('a1') || array['Mara'],
                           pg_temp.r('list_all')::text || pg_temp.r('list_lead2')::text || pg_temp.r('list_lead_two')::text),
  '{}'::text[], 'no list names a candidate (first or last name, email, booking id, student id) or a marker');
select is((select bool_and(position(d.index_number in pg_temp.r('list_all')::text) > 0)
           from public.scripts s join public.bookings b on b.id = s.booking_id join public.student_details d on d.profile_id = b.student_id
           where s.id in (pg_temp.k('a2'), pg_temp.k('b1'), pg_temp.k('c1'))),
  true, 'they show the index number');

-- ---------------------------------------------------------------------------------------------
-- A missing picture is put right by taking the script back: a2.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('tb_a2', public.marking_script_take_back(pg_temp.k('a2'), 'A page lost its marking picture'));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('tb_a2')), pg_temp.st('a2'), pg_temp.hold('a2'), pg_temp.holder('a2')],
  array['ok', 'needs_attention', 'taken_back', 'm1 next'], 'an admin takes a2 back: it needs attention (a page has no marking picture); m1 keeps the piece');
-- Staff have the marking picture made again (as the remask records it, then works the script out again).
update public.script_pages set marking_path = replace(pg_temp.full('p:a2:3'), '-full.jpg', '-remask-marking.jpg') where id = pg_temp.k('p:a2:3');
select public.script_evaluate(pg_temp.k('a2'));
select is(array[pg_temp.st('a2'), pg_temp.alerts('a2')], array['verified', 'picture_changed open,picture_missing open'],
  'with the picture back it is verified; no new alert while it is with staff');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('hb_a2', public.marking_script_hand_back(pg_temp.k('a2'), 'The picture is back'));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('hb_a2')), pg_temp.r('hb_a2') ->> 'state', pg_temp.hold('a2'), pg_temp.holder('a2'), pg_temp.alerts('a2')],
  array['ok', 'marking', '-', 'm1 next', 'picture_changed closed handed_back,picture_missing closed handed_back'],
  'handed back: the piece is m1''s again, not on hold, and both alerts close');

-- ---------------------------------------------------------------------------------------------
-- corrector_cannot_take_back_or_hand_back
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.code(public.marking_script_take_back(pg_temp.k('a1'), 'I want it back')), pg_temp.code(public.marking_script_hand_back(pg_temp.k('a3')))],
  array['forbidden', 'forbidden'], 'corrector_cannot_take_back_or_hand_back: a marker can do neither');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('lead'));
select is(array[pg_temp.code(public.marking_script_take_back(pg_temp.k('a1'), 'I want it back')), pg_temp.code(public.marking_script_hand_back(pg_temp.k('a3')))],
  array['forbidden', 'forbidden'], 'nor the lead marker');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('corr'));
select is(array[pg_temp.code(public.marking_script_take_back(pg_temp.k('a1'), 'I want it back')), pg_temp.code(public.marking_script_hand_back(pg_temp.k('a3')))],
  array['forbidden', 'forbidden'], 'nor a corrector who is not approved');
select tests.as_postgres();
select is(array[pg_temp.st('a1'), pg_temp.hold('a1')], array['marking', '-'], 'a1 is still being marked');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.why(public.marking_script_take_back(pg_temp.k('v1'), 'Not being marked')), 'conflict not_marking',
  'an admin cannot take back a script that is not being marked');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- Privileges.
-- ---------------------------------------------------------------------------------------------
select is(array(select f from unnest(array[
    'public.marking_script_hold(uuid, text, text, uuid)', 'public.marking_alert_raise(uuid, text, uuid, uuid)',
    'public.marking_script_take_back_as(uuid, uuid, text)', 'public.marking_units_refresh(uuid)', 'public.marking_script_lock(uuid)',
    'public.marking_alert_can_release(uuid)', 'public.marking_on_page_picture()', 'public.marking_on_set_aside()']) f
  where has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')
     or has_function_privilege('service_role', f, 'execute')), '{}'::text[],
  'the internal functions cannot be called from the API, nor by the service role');
select is(array(select f from unnest(array[
    'public.marking_name_visible(uuid, uuid)', 'public.marking_script_take_back(uuid, text)', 'public.marking_script_hand_back(uuid, text)',
    'public.marking_alerts_list(uuid, text)', 'public.marking_alert_release(uuid, text)', 'public.marking_alert_note(uuid, text)',
    'public.marking_picture_allowed(text)']) f
  where has_function_privilege('anon', f, 'execute') or not has_function_privilege('authenticated', f, 'execute')), '{}'::text[],
  'the others are for signed-in users only');
select is((select array_agg(t.tgname::text order by t.tgname) from pg_trigger t
           where t.tgname in ('marking_on_page_picture', 'marking_on_set_aside') and not t.tgisinternal),
  array['marking_on_page_picture', 'marking_on_set_aside'], 'the two triggers are in place');

select * from finish();
rollback;
