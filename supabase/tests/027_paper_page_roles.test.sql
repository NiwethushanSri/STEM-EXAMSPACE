begin;
create extension if not exists pgtap with schema extensions;
select plan(42);
select tests.assert_no_owner();

-- Fixtures: an admin, a teacher, a student, one exam with a 3-page paper (v1) later replaced by a 4-page paper (v2).
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active'));
insert into c values ('teacher', tests.create_user('teacher', 'active'));
insert into c values ('s1', tests.create_user('student', 'active'));
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create temp table kv (name text primary key, id uuid not null);
grant select on kv to public;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text) to public;

insert into public.subjects (name, kind) values ('ZZ Roles', 'school');
with x as (
  insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, price_pence,
    price_confirmed, booking_deadline, status)
  values ((select id from public.subjects where name = 'ZZ Roles'), 'ZZ Roles exam', 'Paper 1', 'online',
    '2031-06-07 10:00 Europe/London', 90, 0, true, '2031-06-06 10:00 Europe/London', 'published')
  returning id)
insert into kv select 'exam', id from x;
with x as (
  insert into public.exam_papers (exam_id, kind, title, version, storage_path, page_count, byte_size)
  select id, 'paper', 'Paper', 1, id::text || '/' || gen_random_uuid()::text || '.pdf', 3, 1000 from kv where name = 'exam'
  returning id)
insert into kv select 'v1', id from x;

-- Schema.
select is((select array_agg(e.enumlabel::text order by e.enumsortorder) from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'page_role'),
  array['answer', 'cover', 'blank', 'information'], 'page_role labels');
select has_column('public', 'exam_papers', 'pages_reviewed_at', 'papers record when roles were reviewed');

-- roles_default_answer_on_register
select is((select count(*)::int from public.paper_page_roles where paper_id = pg_temp.k('v1')), 3, 'roles_default_answer_on_register: one row per page');
select is((select count(*)::int from public.paper_page_roles where paper_id = pg_temp.k('v1') and role = 'answer'), 3, 'roles_default_answer_on_register: all answer');
select is((select pages_reviewed_at from public.exam_papers where id = pg_temp.k('v1')), null, 'a new paper is unreviewed');

-- Teachers and families cannot read or write.
select tests.as_user(pg_temp.uid('teacher'));
select is(public.set_paper_page_roles(pg_temp.k('v1'), '[{"page":1,"role":"cover"},{"page":2,"role":"answer"},{"page":3,"role":"answer"}]') ->> 'code', 'forbidden', 'roles_teacher_forbidden: set roles');
select is(public.set_paper_hidden_areas(pg_temp.k('v1'), '[]') ->> 'code', 'forbidden', 'roles_teacher_forbidden: set areas');
select is(public.paper_page_layout(pg_temp.k('v1')) ->> 'code', 'forbidden', 'roles_teacher_forbidden: layout');
select is((select count(*)::int from public.paper_page_roles), 0, 'a teacher reads no roles');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(public.set_paper_page_roles(pg_temp.k('v1'), '[{"page":1,"role":"cover"},{"page":2,"role":"answer"},{"page":3,"role":"answer"}]') ->> 'code', 'forbidden', 'a student cannot set roles');
select is((select count(*)::int from public.paper_hidden_areas), 0, 'a student reads no areas');
select tests.as_postgres();

-- roles_must_cover_every_page
select tests.as_user(pg_temp.uid('admin'));
select is(public.set_paper_page_roles(pg_temp.k('v1'), '[{"page":1,"role":"cover"},{"page":2,"role":"answer"}]') ->> 'code', 'invalid_input', 'roles_must_cover_every_page: a missing page');
select is(public.set_paper_page_roles(pg_temp.k('v1'), '[{"page":1,"role":"cover"},{"page":1,"role":"blank"},{"page":2,"role":"answer"}]') ->> 'code', 'invalid_input', 'roles_must_cover_every_page: a duplicate page');
select is(public.set_paper_page_roles(pg_temp.k('v1'), '[{"page":1,"role":"cover"},{"page":2,"role":"answer"},{"page":3,"role":"answer"},{"page":4,"role":"answer"}]') ->> 'code', 'invalid_input', 'roles_must_cover_every_page: a page past the end');
select is(public.set_paper_page_roles(pg_temp.k('v1'), '[{"page":1,"role":"cover"},{"page":2,"role":"bogus"},{"page":3,"role":"answer"}]') ->> 'code', 'invalid_input', 'an unknown role');
select is(public.set_paper_page_roles(pg_temp.k('v1'), '{"page":1}') ->> 'code', 'invalid_input', 'not an array');
select is(public.set_paper_page_roles(gen_random_uuid(), '[]') ->> 'code', 'not_found', 'an unknown paper');
select is((select count(*)::int from public.paper_page_roles where paper_id = pg_temp.k('v1') and role = 'answer'), 3, 'refused calls change nothing');

-- A good call, roles_set_writes_audit.
select is(public.set_paper_page_roles(pg_temp.k('v1'), '[{"page":3,"role":"information"},{"page":1,"role":"cover"},{"page":2,"role":"answer"}]') ->> 'ok', 'true', 'an admin sets the roles (any order)');
select is((select array_agg(role::text order by page) from public.paper_page_roles where paper_id = pg_temp.k('v1')), array['cover', 'answer', 'information'], 'the roles are stored');
select isnt((select pages_reviewed_at from public.exam_papers where id = pg_temp.k('v1')), null, 'setting roles marks the paper reviewed');
select tests.as_postgres();
select is((select count(*)::int from public.audit_log where action = 'paper_page_roles_set' and target_type = 'exam_paper' and target_id = pg_temp.k('v1') and actor_id = pg_temp.uid('admin')), 1, 'roles_set_writes_audit');
select tests.as_user(pg_temp.uid('admin'));

-- areas_out_of_bounds_refused
select is(public.set_paper_hidden_areas(pg_temp.k('v1'), '[{"page":1,"x":0.5,"y":0.1,"w":0.6,"h":0.1}]') ->> 'code', 'invalid_input', 'areas_out_of_bounds_refused: runs off the right edge');
select is(public.set_paper_hidden_areas(pg_temp.k('v1'), '[{"page":1,"x":-0.1,"y":0.1,"w":0.2,"h":0.1}]') ->> 'code', 'invalid_input', 'areas_out_of_bounds_refused: negative x');
select is(public.set_paper_hidden_areas(pg_temp.k('v1'), '[{"page":1,"x":0.1,"y":0.1,"w":0,"h":0.1}]') ->> 'code', 'invalid_input', 'areas_out_of_bounds_refused: zero width');
select is(public.set_paper_hidden_areas(pg_temp.k('v1'), '[{"page":9,"x":0.1,"y":0.1,"w":0.1,"h":0.1}]') ->> 'code', 'invalid_input', 'areas_out_of_bounds_refused: a page the paper does not have');
select is(public.set_paper_hidden_areas(pg_temp.k('v1'),
  (select jsonb_agg(jsonb_build_object('page', 1, 'x', 0.01 * i, 'y', 0.1, 'w', 0.005, 'h', 0.1)) from generate_series(1, 21) i)) ->> 'code', 'invalid_input', 'at most 20 areas on a page');
select is((select count(*)::int from public.paper_hidden_areas where paper_id = pg_temp.k('v1')), 0, 'refused calls store nothing');

-- A good call reports the pages that changed.
select is(public.set_paper_hidden_areas(pg_temp.k('v1'), '[{"page":1,"x":0.1,"y":0.1,"w":0.3,"h":0.05},{"page":3,"x":0,"y":0.9,"w":1,"h":0.1}]'),
  '{"ok": true, "changed_pages": [1, 3]}'::jsonb, 'areas are set and the changed pages reported');
select is(public.set_paper_hidden_areas(pg_temp.k('v1'), '[{"page":1,"x":0.1,"y":0.1,"w":0.3,"h":0.05}]') -> 'changed_pages', '[3]'::jsonb, 'only the page that changed is reported');
select is(public.set_paper_hidden_areas(pg_temp.k('v1'), '[{"page":1,"x":0.1,"y":0.1,"w":0.3,"h":0.05}]') -> 'changed_pages', '[]'::jsonb, 'saving the same areas changes no pages');
select is(public.paper_page_layout(pg_temp.k('v1')) -> 'pages', '[{"page":1,"role":"cover"},{"page":2,"role":"answer"},{"page":3,"role":"information"}]'::jsonb, 'the layout lists the pages');
select is(jsonb_array_length(public.paper_page_layout(pg_temp.k('v1')) -> 'areas'), 1, 'the layout lists the areas');
select is(public.set_paper_hidden_areas(pg_temp.k('v1'), '[{"page":1,"x":0.1,"y":0.1,"w":0.3,"h":0.05}]') ->> 'ok', 'true', 'saving again is accepted');

-- roles_copied_to_new_version and areas_copied_to_new_version
select tests.as_postgres();
update public.exam_papers set superseded_at = now() where id = pg_temp.k('v1');
with x as (
  insert into public.exam_papers (exam_id, kind, title, version, storage_path, page_count, byte_size)
  select id, 'paper', 'Paper', 2, id::text || '/' || gen_random_uuid()::text || '.pdf', 4, 1000 from kv where name = 'exam'
  returning id)
insert into kv select 'v2', id from x;
select is((select array_agg(role::text order by page) from public.paper_page_roles where paper_id = pg_temp.k('v2')), array['cover', 'answer', 'information', 'answer'], 'roles_copied_to_new_version (the new page 4 is an answer page)');
select is((select pages_reviewed_at from public.exam_papers where id = pg_temp.k('v2')), null, 'a new version must be reviewed again');
select is((select count(*)::int from public.paper_hidden_areas where paper_id = pg_temp.k('v2') and page = 1 and x = 0.1 and w = 0.3), 1, 'areas_copied_to_new_version');
select is((select count(*)::int from public.paper_hidden_areas where paper_id = pg_temp.k('v1')), 1, 'the old version keeps its own areas');
insert into public.exam_papers (exam_id, kind, title, version, storage_path, page_count, byte_size)
select id, 'insert', 'Formula sheet', 1, id::text || '/' || gen_random_uuid()::text || '.pdf', 1, 1000 from kv where name = 'exam';
select is((select count(*)::int from public.paper_page_roles r join public.exam_papers p on p.id = r.paper_id where p.kind = 'insert'), 0, 'inserts get no roles');

-- Roles lock once a script is attached (script_pages arrives with the scripts tables; a real script page proves the guard).
select tests.as_user(pg_temp.uid('admin'));
select is(public.set_paper_page_roles(pg_temp.k('v2'), '[{"page":1,"role":"answer"},{"page":2,"role":"answer"},{"page":3,"role":"answer"},{"page":4,"role":"answer"}]') ->> 'ok', 'true', 'roles can change while no script exists');
select tests.as_postgres();
with b as (
  insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting)
  select id, pg_temp.uid('s1'), pg_temp.uid('s1'), 'paid', 0, 'home' from kv where name = 'exam' returning id)
insert into public.paper_copies (code, booking_id, paper_id, page_count)
select public.copy_code_new(), b.id, pg_temp.k('v2'), 6 from b;
with sub as (
  insert into public.home_submissions (booking_id, seq) select booking_id, 1 from public.paper_copies where paper_id = pg_temp.k('v2') returning id, booking_id),
up as (
  insert into public.script_uploads (exam_id, booking_id, submission_id, kind, storage_path, mime, byte_size, uploaded_by)
  select (select id from kv where name = 'exam'), sub.booking_id, sub.id, 'home_photo', 'home/' || gen_random_uuid()::text || '.jpg', 'image/jpeg', 1000, pg_temp.uid('s1')
  from sub returning id, booking_id)
insert into public.script_pages (upload_id, source_index, exam_id, copy_id, copy_page, booking_id, state, full_path)
select up.id, 0, (select id from kv where name = 'exam'), c.id, 1, up.booking_id, 'matched', 'x/0-full.jpg'
from up join public.paper_copies c on c.booking_id = up.booking_id and c.paper_id = pg_temp.k('v2');
select tests.as_user(pg_temp.uid('admin'));
select is(public.set_paper_page_roles(pg_temp.k('v2'), '[{"page":1,"role":"cover"},{"page":2,"role":"answer"},{"page":3,"role":"answer"},{"page":4,"role":"answer"}]') ->> 'code', 'conflict', 'roles are locked once a script page exists');
select is(public.set_paper_hidden_areas(pg_temp.k('v2'), '[]') ->> 'ok', 'true', 'hidden areas can still change');
select tests.as_postgres();

select * from finish();
rollback;
