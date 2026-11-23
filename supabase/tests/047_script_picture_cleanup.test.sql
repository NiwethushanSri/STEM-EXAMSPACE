begin;
create extension if not exists pgtap with schema extensions;
select plan(21);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Exam e holds two verified home scripts: s1 (upload u1) and s2 (upload u2). The test makes its own
-- storage.objects rows (the fixtures make none), always with a created_at of its own so the 24-hour rule is exact.
-- A name is <exam>/<upload>/<job>-<attempt>/<source_index>-full.jpg or -marking.jpg.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active'));
create temp table kv (name text primary key, v text);
grant all on kv to public;
create function pg_temp.k(p text) returns text language sql stable as $$ select v from kv where name = p $$;
-- A picture object p_name of the bucket, created p_age ago, in upload p_upload's folder.
create function pg_temp.obj(p_name text, p_upload text, p_file text, p_age interval, p_bucket text default 'script-pages') returns void language plpgsql as $$
begin
  insert into storage.objects (bucket_id, name, created_at)
  values (p_bucket, pg_temp.k('e') || '/' || pg_temp.k(p_upload) || '/' || p_file, now() - p_age);
  insert into kv values (p_name, pg_temp.k('e') || '/' || pg_temp.k(p_upload) || '/' || p_file);
end $$;
-- The names the function lists, as the processing server reads them, sorted.
create function pg_temp.listed(p_now timestamptz default null) returns text[] language sql as $$
  select coalesce(array_agg(x ->> 'name' order by x ->> 'name'), '{}')
  from jsonb_array_elements(public.script_pictures_unused_take(1000, p_now)) x $$;
create function pg_temp.has(p_name text, p_now timestamptz default null) returns boolean language sql as $$
  select pg_temp.k(p_name) = any (pg_temp.listed(p_now)) $$;
grant execute on function pg_temp.k(text), pg_temp.obj(text, text, text, interval, text), pg_temp.listed(timestamptz),
  pg_temp.has(text, timestamptz) to public;

insert into public.subjects (name, kind) values ('ZZ Picture cleanup', 'school');
insert into kv values ('e', tests.marking_exam((select id from public.subjects where name = 'ZZ Picture cleanup'))::text);
insert into kv values ('s1', tests.verified_script(pg_temp.k('e')::uuid, 'home')::text);
insert into kv values ('s2', tests.verified_script(pg_temp.k('e')::uuid, 'home')::text);
insert into kv select 'u1', p.upload_id::text from public.script_pages p join public.script_page_links l on l.page_id = p.id
  where l.script_id = pg_temp.k('s1')::uuid limit 1;
insert into kv select 'u2', p.upload_id::text from public.script_pages p join public.script_page_links l on l.page_id = p.id
  where l.script_id = pg_temp.k('s2')::uuid limit 1;
-- The pictures s1's pages point at are objects too, three days old.
insert into storage.objects (bucket_id, name, created_at)
select 'script-pages', n, now() - interval '3 days'
from (select p.full_path as n from public.script_pages p where p.upload_id = pg_temp.k('u1')::uuid
      union select p.marking_path from public.script_pages p where p.upload_id = pg_temp.k('u1')::uuid and p.marking_path is not null) x;
insert into kv select 'cur_full', min(full_path) from public.script_pages where upload_id = pg_temp.k('u1')::uuid;
insert into kv select 'cur_marking', min(marking_path) from public.script_pages where upload_id = pg_temp.k('u1')::uuid and marking_path is not null;

-- ---------------------------------------------------------------------------------------------
-- never_lists_a_current_full_or_marking_picture
-- ---------------------------------------------------------------------------------------------
select isnt(pg_temp.k('cur_full'), null, 'fixture: a page has a full picture');
select isnt(pg_temp.k('cur_marking'), null, 'fixture: a page has a marking picture');
select is(pg_temp.listed(), '{}'::text[], 'never_lists_a_current_full_or_marking_picture: nothing is listed while every picture is in use');

-- ---------------------------------------------------------------------------------------------
-- lists_a_replaced_marking_picture_after_24_hours: a remask made a newer marking picture; the old one is nobody's.
-- ---------------------------------------------------------------------------------------------
select pg_temp.obj('old_marking', 'u1', '5-1/0-marking.jpg', interval '3 days');
select pg_temp.obj('old_full', 'u1', '5-1/0-full.jpg', interval '3 days');
select ok(pg_temp.has('old_marking'), 'lists_a_replaced_marking_picture_after_24_hours: the old marking picture is listed');
select ok(pg_temp.has('old_full'), 'and so is an old full picture of a retried attempt');
select ok(not (pg_temp.k('cur_full') = any (pg_temp.listed())) and not (pg_temp.k('cur_marking') = any (pg_temp.listed())),
  'while the current ones stay');

-- ---------------------------------------------------------------------------------------------
-- keeps_pictures_of_a_replaced_page_row_that_still_exists
-- ---------------------------------------------------------------------------------------------
select pg_temp.obj('rep_full', 'u1', '6-1/0-full.jpg', interval '3 days');
select pg_temp.obj('rep_marking', 'u1', '6-1/0-marking.jpg', interval '3 days');
select ok(pg_temp.has('rep_full') and pg_temp.has('rep_marking'), 'fixture: before a row points at them, both are listed');
insert into public.script_pages (upload_id, source_index, exam_id, state, quality, rotation, full_path, marking_path, replaced_at)
values (pg_temp.k('u1')::uuid, 0, pg_temp.k('e')::uuid, 'unmatched', '{"flags": []}'::jsonb, 0,
        pg_temp.k('rep_full'), pg_temp.k('rep_marking'), now() - interval '2 days');
select ok(not pg_temp.has('rep_full') and not pg_temp.has('rep_marking'),
  'keeps_pictures_of_a_replaced_page_row_that_still_exists: a replaced row that still exists still uses its pictures');

-- A picture only named as the one that was checked is not in use.
select pg_temp.obj('checked_only', 'u1', '7-1/1-marking.jpg', interval '3 days');
update public.script_pages set marking_checked_path = pg_temp.k('checked_only') where full_path = pg_temp.k('cur_full');
select ok(pg_temp.has('checked_only'), 'a picture only named in marking_checked_path is not in use, so it is listed');

-- ---------------------------------------------------------------------------------------------
-- skips_an_upload_with_a_job_queued_or_running
-- ---------------------------------------------------------------------------------------------
select pg_temp.obj('busy', 'u2', '5-1/0-marking.jpg', interval '3 days');
insert into public.processing_jobs (upload_id, kind, state) values (pg_temp.k('u2')::uuid, 'remask', 'queued');
select ok(not pg_temp.has('busy'), 'skips_an_upload_with_a_job_queued_or_running: nothing of an upload with a queued job is listed');
update public.processing_jobs set state = 'running', locked_by = 'w', locked_at = now() where upload_id = pg_temp.k('u2')::uuid and state = 'queued';
select ok(not pg_temp.has('busy'), 'nor with a running job');
select ok(pg_temp.has('old_marking'), 'while another upload''s are still listed');
update public.processing_jobs set state = 'done', finished_at = now() where upload_id = pg_temp.k('u2')::uuid and state = 'running';
select ok(pg_temp.has('busy'), 'once the job is done they are listed');

-- ---------------------------------------------------------------------------------------------
-- nothing_younger_than_24_hours
-- ---------------------------------------------------------------------------------------------
select pg_temp.obj('young', 'u1', '8-1/0-marking.jpg', interval '23 hours');
select pg_temp.obj('day', 'u1', '8-1/1-marking.jpg', interval '25 hours');
select ok(not pg_temp.has('young'), 'nothing_younger_than_24_hours: an object made 23 hours ago is kept');
select ok(pg_temp.has('day'), 'one made 25 hours ago is listed');
select ok(pg_temp.has('young', now() + interval '2 hours'), 'and the young one is listed once it is over 24 hours old');

-- ---------------------------------------------------------------------------------------------
-- never_lists_script_uploads: originals are never listed, whatever they look like; nor is a name of another shape.
-- ---------------------------------------------------------------------------------------------
select pg_temp.obj('orig', 'u1', '9-1/0-marking.jpg', interval '30 days', 'script-uploads');
select pg_temp.obj('orig2', 'u1', 'original.pdf', interval '30 days', 'script-uploads');
insert into storage.objects (bucket_id, name, created_at) values ('script-pages', 'junk.jpg', now() - interval '30 days');
select ok(not pg_temp.has('orig') and not pg_temp.has('orig2'), 'never_lists_script_uploads: the originals bucket is never listed');
select is((select count(*)::int from unnest(pg_temp.listed()) n where n = 'junk.jpg'), 0, 'a name that is not a picture of the processing server is never listed');

-- ---------------------------------------------------------------------------------------------
-- not_granted_to_authenticated
-- ---------------------------------------------------------------------------------------------
select ok(not has_function_privilege('anon', 'public.script_pictures_unused_take(int, timestamptz)', 'execute')
  and not has_function_privilege('authenticated', 'public.script_pictures_unused_take(int, timestamptz)', 'execute')
  and has_function_privilege('service_role', 'public.script_pictures_unused_take(int, timestamptz)', 'execute'),
  'not_granted_to_authenticated: only the service role may run it');
select tests.as_user((select id from c where name = 'admin'));
select throws_ok($$select public.script_pictures_unused_take()$$, '42501', null, 'a signed-in admin cannot run it');
select tests.as_postgres();
select is(jsonb_typeof(public.script_pictures_unused_take(1)), 'array', 'the answer is a list');

select * from finish();
rollback;
