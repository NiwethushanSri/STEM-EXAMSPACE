begin;
create extension if not exists pgtap with schema extensions;
select plan(86);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Admins admin and admin2; teacher, corr (a corrector) and student are not admins. Exam e (tests.marking_exam,
-- never opened) holds home scripts a1 (its page 2 is one the server could not prove), a2 (every page proved) and x1 (a
-- family's extra page staff confirmed); exam f holds t1, which is marked. A page is kept as 'p:<script>:<copy page>'.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values
  ('admin', tests.create_user('admin', 'active')),
  ('admin2', tests.create_user('admin', 'active')),
  ('teacher', tests.create_user('teacher', 'active')),
  ('corr', tests.create_user('corrector', 'active')),
  ('student', tests.create_user('student', 'active'));
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table res (name text primary key, j jsonb);
grant all on res to public;
create temp table old (path text);
grant all on old to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
create function pg_temp.code(j jsonb) returns text language sql immutable as $$
  select case when (j ->> 'ok')::boolean then 'ok' else coalesce(j ->> 'code', 'none') end $$;
-- 'conflict reason' for a conflict, else the code.
create function pg_temp.why(j jsonb) returns text language sql immutable as $$
  select case when j ->> 'code' = 'conflict' then 'conflict ' || coalesce(j ->> 'reason', '-') else pg_temp.code(j) end $$;
create function pg_temp.st(p text) returns text language sql stable security definer as $$
  select state::text from public.scripts where id = pg_temp.k(p) $$;
create function pg_temp.path(p text) returns text language sql stable security definer as $$
  select marking_path from public.script_pages where id = pg_temp.k(p) $$;
create function pg_temp.checked(p text) returns text language sql stable security definer as $$
  select marking_checked_path from public.script_pages where id = pg_temp.k(p) $$;
create function pg_temp.upload(p text) returns uuid language sql stable security definer as $$
  select upload_id from public.script_pages where id = pg_temp.k('p:' || p || ':1') $$;
create function pg_temp.needs(p text) returns boolean language sql stable as $$
  select public.script_page_needs_marking_check(pg_temp.k(p)) $$;
-- The pages of exam p's list of marking pictures to check, as the caller reads it, in its order.
create function pg_temp.listed(p text) returns uuid[] language sql as $$
  select array(select (x ->> 'page_id')::uuid from jsonb_array_elements(public.script_marking_checks_list(pg_temp.k(p)) -> 'items') x) $$;
create function pg_temp.audits(p_action text, p_target uuid) returns int language sql stable security definer as $$
  select count(*)::int from public.audit_log a where a.action = p_action and a.target_id = p_target $$;
-- A new verified home script of an exam, and its pages.
create function pg_temp.script(p_name text, p_exam text) returns void language plpgsql as $$
begin
  insert into kv values (p_name, tests.verified_script(pg_temp.k(p_exam), 'home'));
  insert into kv select 'p:' || p_name || ':' || l.copy_page, l.page_id
  from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version where s.id = pg_temp.k(p_name);
end $$;
-- Page n of a script is one the server could not prove, as a prepare that flagged its layout records it: no marking
-- picture, and an open poor_quality exception ('x:<script>').
create function pg_temp.unproved(p_script text, p_n int) returns void language plpgsql as $$
declare
  v_s public.scripts%rowtype;
  v_p uuid := pg_temp.k('p:' || p_script || ':' || p_n);
begin
  select * into v_s from public.scripts where id = pg_temp.k(p_script);
  update public.script_pages set quality = jsonb_set(quality, '{flags}', '["layout_unexpected"]'), marking_path = null where id = v_p;
  with e as (
    insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
    values (v_s.exam_id, 'poor_quality', v_s.booking_id, v_s.id, v_p, pg_temp.upload(p_script),
      jsonb_build_object('flags', '["layout_unexpected"]'::jsonb, 'copy_page', p_n, 'marking_picture', false))
    returning id)
  insert into kv select 'x:' || p_script, e.id from e;
  perform public.script_evaluate(v_s.id);
end $$;
-- The processing server answers the file's waiting remask job: every page it lists gets a new marking picture in the
-- job's own folder; the job is done. Answers '<pictures made>/<pages>'.
create function pg_temp.sim(p_upload uuid) returns text language plpgsql as $$
declare
  v jsonb;
  r jsonb;
begin
  update public.processing_jobs set run_after = '2000-01-01' where upload_id = p_upload and state = 'queued' and kind = 'remask';
  v := public.processing_job_claim('t-worker');
  if v is null or v -> 'upload' ->> 'id' <> p_upload::text or v -> 'job' ->> 'kind' <> 'remask' then
    raise exception 'claimed another job: %', v -> 'job';
  end if;
  r := public.script_pages_remasked((v -> 'job' ->> 'id')::bigint, 't-worker', (v -> 'job' ->> 'attempts')::int, (
    select coalesce(jsonb_agg(jsonb_build_object('page_id', x ->> 'page_id', 'rotation', (x ->> 'rotation')::int, 'key', x ->> 'key',
      'marking_path', (v -> 'upload' ->> 'exam_id') || '/' || (v -> 'upload' ->> 'id') || '/' || (v -> 'job' ->> 'id') || '-'
        || (v -> 'job' ->> 'attempts') || '/' || (x ->> 'source_index') || '-marking.jpg')), '[]'::jsonb)
    from jsonb_array_elements(v -> 'pages') x));
  perform public.processing_job_finish((v -> 'job' ->> 'id')::bigint, 't-worker', (v -> 'job' ->> 'attempts')::int, true);
  return (r ->> 'marking') || '/' || (r ->> 'pages');
end $$;
-- Staff hide the name on page n of a script and accept it (the poor_quality exception), as the exception queue does.
create function pg_temp.accept(p_script text, p_n int) returns text language plpgsql as $$
declare
  a jsonb;
  b jsonb;
begin
  a := public.script_page_set_hidden_areas(pg_temp.k('p:' || p_script || ':' || p_n), '[{"x":0.1,"y":0.02,"w":0.5,"h":0.08}]', 'Hide the name');
  b := public.script_exception_confirm(pg_temp.k('x:' || p_script));
  return pg_temp.code(a) || '/' || pg_temp.code(b);
end $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.r(text), pg_temp.code(jsonb), pg_temp.why(jsonb), pg_temp.st(text),
  pg_temp.path(text), pg_temp.checked(text), pg_temp.upload(text), pg_temp.listed(text), pg_temp.audits(text, uuid),
  pg_temp.accept(text, int) to public;

insert into public.subjects (name, kind) values ('ZZ Marking checks', 'school');
insert into kv values ('e', tests.marking_exam((select id from public.subjects where name = 'ZZ Marking checks')));
insert into kv values ('f', tests.marking_exam((select id from public.subjects where name = 'ZZ Marking checks')));
select tests.structure(pg_temp.k('f'));
select pg_temp.script('a1', 'e');
select pg_temp.script('a2', 'e');
select pg_temp.script('x1', 'e');
select pg_temp.script('t1', 'f');
select pg_temp.unproved('a1', 2);
select pg_temp.unproved('t1', 2);

-- ---------------------------------------------------------------------------------------------
-- confirmed_page_is_not_verified_until_its_marking_picture_is_checked: staff accept a1's page 2; its marking picture
-- is made (a remask of the whole file).
-- ---------------------------------------------------------------------------------------------
select is(pg_temp.st('a1'), 'needs_attention', 'confirmed_page_is_not_verified_until_its_marking_picture_is_checked: a1 has a page the server could not prove');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.accept('a1', 2), 'ok/ok', 'staff hide the name on it and accept it');
select tests.as_postgres();
select is(pg_temp.st('a1'), 'needs_attention', 'it has no marking picture yet');
select is(pg_temp.sim(pg_temp.upload('a1')), '3/3', 'the remask makes the marking pictures of the file''s three pages');
select isnt(pg_temp.path('p:a1:2'), null, 'page 2 has its marking picture');
select is(pg_temp.st('a1'), 'needs_attention', 'the script is not verified: nobody has looked at that picture yet');
select is(array[pg_temp.needs('p:a1:1'), pg_temp.needs('p:a1:2'), pg_temp.needs('p:a1:3')], array[false, true, false],
  'only the page staff accepted needs a check');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('list1', public.script_marking_checks_list(pg_temp.k('e')));
select tests.as_postgres();
select is(pg_temp.code(pg_temp.r('list1')), 'ok', 'admins read the list of marking pictures to check');
select is((select array_agg(x ->> 'page_id') from jsonb_array_elements(pg_temp.r('list1') -> 'items') x),
  array[pg_temp.k('p:a1:2')::text], 'it holds a1''s page 2, and nothing else');
select is((select array[x ->> 'exam_id', x ->> 'script_number', x -> 'booking' ->> 'name', x ->> 'copy_page', x ->> 'full_path', x ->> 'marking_path']
           from jsonb_array_elements(pg_temp.r('list1') -> 'items') x),
  array[pg_temp.k('e')::text, (select number from public.scripts where id = pg_temp.k('a1')), 'Wilhelmina Quarterfield', '2',
        (select full_path from public.script_pages where id = pg_temp.k('p:a1:2')), pg_temp.path('p:a1:2')],
  'with its exam, script number, candidate, page, full picture and marking picture');
select tests.as_user(pg_temp.uid('admin'));
select is(cardinality(pg_temp.listed('f')), 0, 'the list of another exam does not hold it');
select tests.as_postgres();

-- A family's extra page that staff confirmed counts the same: x1 gets one, with its marking picture.
with p as (
  insert into public.script_pages (upload_id, source_index, exam_id, state, quality, rotation, full_path, marking_path, placed_after)
  select pg_temp.upload('x1'), 3, pg_temp.k('e'), 'unmatched', '{"flags": []}'::jsonb, 0,
    replace(pg_temp.path('p:x1:1'), '0-marking.jpg', '3-full.jpg'), replace(pg_temp.path('p:x1:1'), '0-marking.jpg', '3-marking.jpg'), 2
  returning id)
insert into kv select 'p:x1:extra', p.id from p;
insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details, state, resolution, resolved_by, resolved_at)
select s.exam_id, 'uncoded_family_page', s.booking_id, s.id, pg_temp.k('p:x1:extra'), pg_temp.upload('x1'), '{"after_page": 2}'::jsonb,
  'resolved', 'confirmed', pg_temp.uid('admin'), now()
from public.scripts s where s.id = pg_temp.k('x1');
select public.script_evaluate(pg_temp.k('x1'));
select is(pg_temp.st('x1'), 'needs_attention', 'a family''s confirmed extra page also waits for its check');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('list2', public.script_marking_checks_list(pg_temp.k('e')));
select is((select array_agg(x ->> 'page_id' || ':' || coalesce(x ->> 'copy_page', '-') order by x ->> 'page_id')
           from jsonb_array_elements(pg_temp.r('list2') -> 'items') x),
  (select array_agg(t order by t) from unnest(array[pg_temp.k('p:a1:2') || ':2', pg_temp.k('p:x1:extra') || ':-']) t),
  'the list holds it too, with no copy page');
insert into res values ('ck_x1', public.script_page_marking_checked(pg_temp.k('p:x1:extra'), pg_temp.path('p:x1:extra')));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('ck_x1')), pg_temp.st('x1')], array['ok', 'verified'], 'once checked, x1 is verified');

-- ---------------------------------------------------------------------------------------------
-- check_must_name_the_picture_shown: a check names the marking picture staff were shown.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('stale', public.script_page_marking_checked(pg_temp.k('p:a1:2'), pg_temp.path('p:a1:2') || '.old'));
select is(pg_temp.why(pg_temp.r('stale')), 'conflict changed', 'check_must_name_the_picture_shown: another picture is refused (it changed since it was shown)');
select is(array[pg_temp.code(public.script_page_marking_checked(null, 'x')),
                pg_temp.code(public.script_page_marking_checked(pg_temp.k('p:a1:2'), null)),
                pg_temp.code(public.script_page_marking_checked(pg_temp.k('p:a1:2'), ' ')),
                pg_temp.code(public.script_page_marking_checked(gen_random_uuid(), 'x'))],
  array['invalid_input', 'invalid_input', 'invalid_input', 'not_found'], 'a page and a picture are needed, and the page must exist');
select tests.as_postgres();
select is((select array[marking_checked_path, marking_checked_by::text, marking_checked_at::text] from public.script_pages where id = pg_temp.k('p:a1:2')),
  array[null, null, null]::text[], 'nothing is set');
select is(array[pg_temp.st('a1'), pg_temp.audits('script_page_marking_checked', pg_temp.k('p:a1:2'))::text], array['needs_attention', '0'],
  'the script still needs attention, and nothing is audited');
-- While its file is being remasked, its picture is about to change: it is not offered, and not taken.
select public.script_remask_queue(pg_temp.upload('a1'));
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.listed('e'), array[]::uuid[], 'while a1''s file is remasked its page leaves the list (x1''s left once checked)');
select is(pg_temp.why(public.script_page_marking_checked(pg_temp.k('p:a1:2'), pg_temp.path('p:a1:2'))), 'conflict pictures_updating',
  'and a check is refused until the new picture is made');
select tests.as_postgres();
update public.processing_jobs set state = 'done', finished_at = now() where upload_id = pg_temp.upload('a1') and kind = 'remask' and state = 'queued';
-- The good check.
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.listed('e'), array[pg_temp.k('p:a1:2')], 'once the remask is over the page is listed again');
insert into res values ('ck1', public.script_page_marking_checked(pg_temp.k('p:a1:2'), pg_temp.path('p:a1:2')));
select tests.as_postgres();
select is(pg_temp.r('ck1') - 'script_state', jsonb_build_object('ok', true, 'page_id', pg_temp.k('p:a1:2')), 'the picture shown is checked');
select is(pg_temp.r('ck1') ->> 'script_state', 'verified', 'and the answer says the script is verified now');
select is(pg_temp.st('a1'), 'verified', 'confirmed_page_is_not_verified_until_its_marking_picture_is_checked: once checked, a1 is verified');
select is((select array[marking_checked_path, marking_checked_by::text, (marking_checked_at = now())::text] from public.script_pages where id = pg_temp.k('p:a1:2')),
  array[pg_temp.path('p:a1:2'), pg_temp.uid('admin')::text, 'true'], 'the page says which picture was checked, by whom and when');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.listed('e'), array[]::uuid[], 'nothing is left to check');
select is(pg_temp.why(public.script_page_marking_checked(pg_temp.k('p:a1:2'), pg_temp.path('p:a1:2'))), 'conflict not_needed',
  'a second check of the same picture is refused');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- proven_name_band_page_needs_no_check: a2's pages were all proved by the server; their pictures are made again.
-- ---------------------------------------------------------------------------------------------
select public.script_remask_queue(pg_temp.upload('a2'));
select is(pg_temp.sim(pg_temp.upload('a2')), '3/3', 'proven_name_band_page_needs_no_check: a2''s pictures are made again');
select is(pg_temp.st('a2'), 'verified', 'a2 stays verified: no staff accepted any of its pages');
select is(array[pg_temp.needs('p:a2:1'), pg_temp.needs('p:a2:2'), pg_temp.needs('p:a2:3')], array[false, false, false],
  'none of its pages needs a check');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.listed('e'), array[]::uuid[], 'none is listed');
select is(pg_temp.why(public.script_page_marking_checked(pg_temp.k('p:a2:1'), pg_temp.path('p:a2:1'))), 'conflict not_needed',
  'and checking one is refused: there is nothing to check');
select tests.as_postgres();
-- Only pages markers see wait for a check. Exam g's page 1 is a cover. On c1 staff accept two blurred pages as they are
-- (each keeps the marking picture the server proved): the cover, which markers never see, and answer page 2, which
-- staff accepted and so is checked like any accepted page.
insert into kv values ('g', tests.marking_exam((select id from public.subjects where name = 'ZZ Marking checks')));
update public.paper_page_roles set role = 'cover' where page = 1
  and paper_id = (select id from public.exam_papers where exam_id = pg_temp.k('g') and kind = 'paper');
select pg_temp.script('c1', 'g');
insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
select s.exam_id, 'poor_quality', s.booking_id, s.id, pg_temp.k('p:c1:' || n), pg_temp.upload('c1'),
  jsonb_build_object('flags', '["blurred"]'::jsonb, 'copy_page', n, 'marking_picture', true)
from public.scripts s, generate_series(1, 2) n where s.id = pg_temp.k('c1');
select public.script_evaluate(pg_temp.k('c1'));
select tests.as_user(pg_temp.uid('admin'));
select is((select array_agg(pg_temp.code(public.script_exception_confirm(e.id)) order by e.created_at, e.id) from public.script_exceptions e
           where e.script_id = pg_temp.k('c1') and e.kind = 'poor_quality'),
  array['ok', 'ok'], 'staff accept c1''s blurred cover and page 2 as they are');
select is(pg_temp.listed('g'), array[pg_temp.k('p:c1:2')], 'page 2 waits for a check; the cover does not');
select tests.as_postgres();
select is(pg_temp.st('c1'), 'needs_attention', 'so c1 is not verified yet');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.script_page_marking_checked(pg_temp.k('p:c1:2'), pg_temp.path('p:c1:2'))), 'ok', 'staff check page 2');
select tests.as_postgres();
select is(pg_temp.st('c1'), 'verified', 'and c1 is verified, its cover never checked');

-- ---------------------------------------------------------------------------------------------
-- remask_after_a_check_asks_again: a1's file is remasked after the check; page 2 gets a new marking picture.
-- ---------------------------------------------------------------------------------------------
insert into old select pg_temp.path('p:a1:2');
select public.script_remask_queue(pg_temp.upload('a1'));
select is(pg_temp.sim(pg_temp.upload('a1')), '3/3', 'remask_after_a_check_asks_again: a1''s pictures are made again');
select isnt(pg_temp.path('p:a1:2'), (select path from old), 'page 2 has a new marking picture');
select is(array[pg_temp.needs('p:a1:2')::text, pg_temp.checked('p:a1:2')], array['true', (select path from old)],
  'it needs a check again: the picture checked was the old one');
select is(pg_temp.st('a1'), 'needs_attention', 'and the script needs attention again');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.listed('e'), array[pg_temp.k('p:a1:2')], 'it is listed again');
insert into res values ('list3', public.script_marking_checks_list(pg_temp.k('e')));
select is(pg_temp.r('list3') -> 'items' -> 0 ->> 'marking_path', pg_temp.path('p:a1:2'), 'with its new picture');
select is(pg_temp.why(public.script_page_marking_checked(pg_temp.k('p:a1:2'), (select path from old))), 'conflict changed',
  'the old picture can no longer be checked');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- name_shows_reopens_the_hide_flow: staff see a name on a1's new marking picture.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(array[pg_temp.code(public.script_page_marking_name_shows(pg_temp.k('p:a1:2'), 'ab')),
                pg_temp.code(public.script_page_marking_name_shows(pg_temp.k('p:a1:2'), null)),
                pg_temp.code(public.script_page_marking_name_shows(null, 'A name in the margin')),
                pg_temp.code(public.script_page_marking_name_shows(gen_random_uuid(), 'A name in the margin'))],
  array['reason_required', 'reason_required', 'invalid_input', 'not_found'], 'name_shows_reopens_the_hide_flow: it needs a reason of 3 to 300 characters, and a page that exists');
insert into res values ('ns1', public.script_page_marking_name_shows(pg_temp.k('p:a1:2'), '  A name in the margin  '));
insert into res values ('ns2', public.script_page_marking_name_shows(pg_temp.k('p:a1:2'), 'Still there'));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('ns1')), pg_temp.code(pg_temp.r('ns2'))], array['ok', 'ok'], 'staff say a name still shows (twice)');
select is((select array_agg(array[e.state, e.details::text, e.script_id::text, e.booking_id::text, e.upload_id::text, e.exam_id::text])
           from public.script_exceptions e where e.page_id = pg_temp.k('p:a1:2') and e.kind = 'name_visible'),
  array[array['open', '{"from": "staff_check"}', pg_temp.k('a1')::text, (select booking_id::text from public.scripts where id = pg_temp.k('a1')),
              pg_temp.upload('a1')::text, pg_temp.k('e')::text]],
  'one name_visible exception is open for the page, from the staff check');
select is(pg_temp.r('ns1') ->> 'exception_id', (select e.id::text from public.script_exceptions e where e.page_id = pg_temp.k('p:a1:2') and e.kind = 'name_visible'),
  'the answer names it');
select is(pg_temp.st('a1'), 'needs_attention', 'the script needs attention');
select is((select array_agg(a.reason order by a.created_at, a.id) from public.audit_log a
           where a.action = 'script_page_marking_name_shows' and a.target_id = pg_temp.k('p:a1:2') and a.target_type = 'script_page'
             and a.actor_id = pg_temp.uid('admin')),
  array['A name in the margin', 'Still there'], 'each is audited with its reason, trimmed');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.listed('e'), array[]::uuid[], 'the page leaves the list: it goes through "Hide the name" first');
select is(pg_temp.why(public.script_page_marking_checked(pg_temp.k('p:a1:2'), pg_temp.path('p:a1:2'))), 'conflict name_visible',
  'and it cannot be checked while the name is reported');
-- "Hide the name" again: a wider area, then "Name is hidden" on the exception.
select is(pg_temp.code(public.script_page_set_hidden_areas(pg_temp.k('p:a1:2'),
  '[{"x":0.1,"y":0.02,"w":0.5,"h":0.08},{"x":0.9,"y":0.1,"w":0.08,"h":0.8}]', 'Hide the name in the margin')), 'ok', 'staff hide the name in the margin');
select is(pg_temp.code(public.script_exception_confirm((pg_temp.r('ns1') ->> 'exception_id')::uuid)), 'ok', 'and confirm the name is hidden');
select tests.as_postgres();
delete from old;
insert into old select pg_temp.path('p:a1:2');
select is(pg_temp.sim(pg_temp.upload('a1')), '3/3', 'the new marking picture is made');
select is(array[pg_temp.st('a1'), pg_temp.needs('p:a1:2')::text], array['needs_attention', 'true'], 'and waits for its check');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.listed('e'), array[pg_temp.k('p:a1:2')], 'it is listed again');
select is(pg_temp.code(public.script_page_marking_checked(pg_temp.k('p:a1:2'), pg_temp.path('p:a1:2'))), 'ok', 'staff check it');
select tests.as_postgres();
select is(pg_temp.st('a1'), 'verified', 'and the script is verified');

-- ---------------------------------------------------------------------------------------------
-- checks_list_for_admins_only
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin2'));
select is(pg_temp.code(public.script_marking_checks_list()), 'ok', 'checks_list_for_admins_only: another admin reads the list (every exam)');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('teacher'));
select is(array[pg_temp.code(public.script_marking_checks_list()),
                pg_temp.code(public.script_page_marking_checked(pg_temp.k('p:a1:2'), 'x')),
                pg_temp.code(public.script_page_marking_name_shows(pg_temp.k('p:a1:2'), 'A name shows'))],
  array['forbidden', 'forbidden', 'forbidden'], 'a teacher may not read it, check or say a name shows');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('corr'));
select is(array[pg_temp.code(public.script_marking_checks_list()),
                pg_temp.code(public.script_page_marking_checked(pg_temp.k('p:a1:2'), 'x')),
                pg_temp.code(public.script_page_marking_name_shows(pg_temp.k('p:a1:2'), 'A name shows'))],
  array['forbidden', 'forbidden', 'forbidden'], 'nor a corrector');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('student'));
select is(pg_temp.code(public.script_marking_checks_list()), 'forbidden', 'nor a student');
select tests.as_postgres();
update public.profiles set status = 'suspended' where id = pg_temp.uid('admin2');
select tests.as_user(pg_temp.uid('admin2'));
select is(pg_temp.code(public.script_marking_checks_list()), 'forbidden', 'nor a suspended admin');
select tests.as_postgres();
select ok(not has_function_privilege('anon', 'public.script_marking_checks_list(uuid)', 'execute')
      and not has_function_privilege('anon', 'public.script_page_marking_checked(uuid, text)', 'execute')
      and not has_function_privilege('anon', 'public.script_page_marking_name_shows(uuid, text)', 'execute')
      and has_function_privilege('authenticated', 'public.script_marking_checks_list(uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.script_page_marking_checked(uuid, text)', 'execute')
      and has_function_privilege('authenticated', 'public.script_page_marking_name_shows(uuid, text)', 'execute'),
  'signed-in callers may call the three (each checks for an admin); anon may not');
select ok(not has_function_privilege('authenticated', 'public.script_page_needs_marking_check(uuid)', 'execute')
      and not has_function_privilege('anon', 'public.script_page_needs_marking_check(uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.script_page_needs_marking_check(uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.script_pages_to_check(uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.script_pages_to_check(uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.script_page_pictures_updating(uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.script_page_pictures_updating(uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.script_evaluate_at(uuid, timestamptz)', 'execute'),
  'the helpers, and script_evaluate_at, stay internal');
select is((select array_agg(p.prosecdef::text || ':' || coalesce(array_to_string(p.proconfig, ','), '') order by p.proname)
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('script_marking_checks_list', 'script_page_marking_checked', 'script_page_marking_name_shows',
                                                       'script_page_needs_marking_check', 'script_pages_to_check', 'script_page_pictures_updating')),
  array_fill('true:search_path=""'::text, array[6]), 'each is security definer with an empty search path');

-- ---------------------------------------------------------------------------------------------
-- check_writes_audit
-- ---------------------------------------------------------------------------------------------
select is((select array_agg(array[a.actor_id::text, a.target_type, coalesce(a.reason, '-')] order by a.created_at, a.id) from public.audit_log a
           where a.action = 'script_page_marking_checked' and a.target_id = pg_temp.k('p:a1:2')),
  array[array[pg_temp.uid('admin')::text, 'script_page', '-'], array[pg_temp.uid('admin')::text, 'script_page', '-']],
  'check_writes_audit: each check of a1''s page 2 (two pictures) is one audit row by the admin, about the page');
select is(pg_temp.audits('script_page_marking_checked', pg_temp.k('p:x1:extra')), 1, 'and the check of x1''s extra page is one more');
select is((select count(*)::int from public.audit_log a where a.action = 'script_page_marking_checked'
           and a.target_id in (pg_temp.k('p:a2:1'), pg_temp.k('p:a1:1'))), 0, 'refused checks write none');

-- ---------------------------------------------------------------------------------------------
-- taken_back_script_cannot_be_handed_back_before_the_check: t1 (exam f) has a page staff accepted; it is checked,
-- marked, taken back, and its file remasked meanwhile.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.accept('t1', 2), 'ok/ok', 'taken_back_script_cannot_be_handed_back_before_the_check: t1''s page 2 is accepted');
select tests.as_postgres();
select pg_temp.sim(pg_temp.upload('t1'));
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.script_page_marking_checked(pg_temp.k('p:t1:2'), pg_temp.path('p:t1:2'))), 'ok', 'its marking picture is checked');
select tests.as_postgres();
insert into public.exam_marking (exam_id, opened_at, opened_by) values (pg_temp.k('f'), now(), pg_temp.uid('admin'));
select public.marking_exam_sync(pg_temp.k('f'), null);
select is(pg_temp.st('t1'), 'ready_to_mark', 'marking opens and t1 is ready to mark');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_script_take_back(pg_temp.k('t1'), 'Check the pages')), 'ok', 'an admin takes it back');
select tests.as_postgres();
select is(pg_temp.st('t1'), 'verified', 'it is verified: its pictures are checked');
select public.script_remask_queue(pg_temp.upload('t1'));
select pg_temp.sim(pg_temp.upload('t1'));
select is(array[pg_temp.st('t1'), pg_temp.needs('p:t1:2')::text], array['needs_attention', 'true'],
  'its file is remasked while it is back with staff: page 2''s new picture waits for a check');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.why(public.marking_script_hand_back(pg_temp.k('t1'))), 'conflict not_verified', 'so it cannot be handed back');
select is(pg_temp.listed('f'), array[pg_temp.k('p:t1:2')], 'its page is in the list');
select is(pg_temp.code(public.script_page_marking_checked(pg_temp.k('p:t1:2'), pg_temp.path('p:t1:2'))), 'ok', 'staff check it');
select is(pg_temp.code(public.marking_script_hand_back(pg_temp.k('t1'))), 'ok', 'and then hand it back');
select tests.as_postgres();
select is(pg_temp.st('t1'), 'ready_to_mark', 'it is with the markers again');
-- A name still shows, said from a list read before the script went back to the markers: it is taken back again.
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('ns_t1', public.script_page_marking_name_shows(pg_temp.k('p:t1:2'), 'A name on the old list'));
select tests.as_postgres();
select is(pg_temp.code(pg_temp.r('ns_t1')), 'ok', 'a name still shows on t1''s page while it is being marked');
select is((select array[s.state::text, (s.taken_back_at is not null)::text, s.taken_back_reason] from public.scripts s where s.id = pg_temp.k('t1')),
  array['needs_attention', 'true', 'A name on the old list'], 'the script is taken back from the markers, with the reason');
select is((select array_agg(distinct coalesce(u.hold_reason, '-')) from public.marking_units u where u.script_id = pg_temp.k('t1') and u.on_hold),
  array['taken_back'], 'its pieces are on hold');
select is((select array[e.state, e.details ->> 'from'] from public.script_exceptions e
           where e.page_id = pg_temp.k('p:t1:2') and e.kind = 'name_visible'),
  array['open', 'staff_check'], 'and the page goes through "Hide the name"');

-- ---------------------------------------------------------------------------------------------
-- A verified script whose accepted page was never checked (one verified before this rule) needs attention once worked
-- out again.
-- ---------------------------------------------------------------------------------------------
update public.script_pages set marking_checked_path = null where id = pg_temp.k('p:x1:extra');
update public.scripts set state = 'verified' where id = pg_temp.k('x1');
select public.script_evaluate(pg_temp.k('x1'));
select is(pg_temp.st('x1'), 'needs_attention', 'a page checked by nobody keeps the script from verified');

select * from finish();
rollback;
