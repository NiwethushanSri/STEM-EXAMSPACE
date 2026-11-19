begin;
create extension if not exists pgtap with schema extensions;
select plan(200);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. s1 (Amara) has a linked parent p1 (Nimal) and a suspended linked parent p3; p2 is unlinked.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active'));
insert into c values ('teacher', tests.create_user('teacher', 'active'));
insert into c values ('p1', tests.create_user('parent', 'active'));
insert into c values ('p2', tests.create_user('parent', 'active'));
insert into c values ('p3', tests.create_user('parent', 'suspended'));
insert into c select 's' || i, tests.create_user('student', 'active') from generate_series(1, 9) i;
insert into public.parent_children values
  ((select id from c where name = 'p1'), (select id from c where name = 's1')),
  ((select id from c where name = 'p3'), (select id from c where name = 's1'));
update public.profiles set first_name = 'Amara', last_name = 'Perera' where id = (select id from c where name = 's1');
update public.profiles set first_name = 'Nimal', last_name = 'Perera' where id = (select id from c where name = 'p1');
update public.student_details d set index_number = 'SE-2031-92' || lpad(substr(c.name, 2), 2, '0')
from c where c.name like 's%' and d.profile_id = c.id;

insert into public.subjects (name, kind) values ('ZZ Papers', 'school');
insert into public.venues (name, rooms) values ('ZZ Paper Hall', array['R1']);

create temp table ex (name text primary key, id uuid not null);
grant select on ex to public;
create temp table bk (name text primary key, id uuid not null);
grant select on bk to public;
create temp table pp (name text primary key, path text not null, id uuid);
grant all on pp to public;
create temp table r (name text primary key, j jsonb);
grant all on r to public;

create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.eid(p text) returns uuid language sql stable as $$ select id from ex where name = p $$;
create function pg_temp.bid(p text) returns uuid language sql stable as $$ select id from bk where name = p $$;
create function pg_temp.pid(p text) returns uuid language sql stable as $$ select id from pp where name = p $$;
create function pg_temp.path(p text) returns text language sql stable as $$ select path from pp where name = p $$;
create function pg_temp.res(p text) returns jsonb language sql stable as $$ select j from r where name = p $$;
create function pg_temp.copy(p text) returns uuid language sql stable as $$ select (j ->> 'copy_id')::uuid from r where name = p $$;
create function pg_temp.issue(p_bk text, p_kind text, p_now timestamptz default now()) returns jsonb
language sql as $$ select public.paper_copy_issue(pg_temp.bid(p_bk), p_kind::public.paper_download_kind, p_now) $$;
create function pg_temp.state(p_bk text, p_now timestamptz default now()) returns jsonb
language sql as $$ select public.booking_paper_state(pg_temp.bid(p_bk), p_now) $$;
create function pg_temp.dl(p_copy uuid, p_kind text) returns jsonb
language sql as $$ select public.paper_download_log(p_copy, p_kind::public.paper_download_kind) $$;
-- Logs n downloads one call at a time and counts the ones accepted.
create function pg_temp.dl_n(p_copy uuid, p_n int) returns int language plpgsql as $$
declare v_ok int := 0;
begin
  for i in 1 .. p_n loop
    if public.paper_download_log(p_copy, 'home') ->> 'ok' = 'true' then v_ok := v_ok + 1; end if;
  end loop;
  return v_ok;
end $$;
-- Registers the stored object p_key as a paper or insert of p_exam and remembers the new id.
create function pg_temp.reg(p_key text, p_exam text, p_kind text, p_title text, p_pages int, p_reason text default null)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  v := public.register_exam_paper(pg_temp.eid(p_exam), p_kind::public.paper_kind, p_title, pg_temp.path(p_key), p_pages, 1000, p_reason);
  if v ->> 'ok' = 'true' then update pp set id = (v ->> 'id')::uuid where name = p_key; end if;
  return v;
end $$;
grant execute on function pg_temp.uid(text), pg_temp.eid(text), pg_temp.bid(text), pg_temp.pid(text), pg_temp.path(text),
  pg_temp.res(text), pg_temp.copy(text), pg_temp.issue(text, text, timestamptz), pg_temp.state(text, timestamptz),
  pg_temp.dl(uuid, text), pg_temp.dl_n(uuid, int), pg_temp.reg(text, text, text, text, int, text) to public;

-- Published exams, 90 minutes long. "fixed" starts at 10:00 London on 7 June 2031.
create function pg_temp.mk_exam(p_name text, p_format public.exam_format, p_starts timestamptz, p_paper text default 'Paper 1 Higher')
returns void language sql as $$
  with x as (
    insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, price_pence,
      price_confirmed, booking_deadline, status)
    values ((select id from public.subjects where name = 'ZZ Papers'), 'ZZ ' || p_name, p_paper, p_format, p_starts, 90,
      0, true, p_starts - interval '1 day', 'published')
    returning id)
  insert into ex select p_name, x.id from x
$$;
select pg_temp.mk_exam('fixed', 'online', '2031-06-07 10:00 Europe/London');
select pg_temp.mk_exam('fixed2', 'online', '2031-06-21 10:00 Europe/London');
select pg_temp.mk_exam('nopaper', 'online', '2031-06-28 10:00 Europe/London', '');
select pg_temp.mk_exam('move', 'online', '2031-07-01 10:00 Europe/London');
select pg_temp.mk_exam('live', 'online', now() + interval '5 minutes');
select pg_temp.mk_exam('mixed', 'both', now() + interval '5 minutes');
select pg_temp.mk_exam('future', 'online', now() + interval '2 days');
select pg_temp.mk_exam('empty', 'online', now() + interval '5 minutes');
insert into public.exam_centres (exam_id, venue_id, room, seat_limit)
values (pg_temp.eid('mixed'), (select id from public.venues where name = 'ZZ Paper Hall'), 'R1', 10);

-- Bookings written directly: at home, or (p_centre) at the exam's only centre.
create function pg_temp.book(p_key text, p_exam text, p_student text, p_status public.booking_status, p_centre boolean default false)
returns void language sql as $$
  with b as (
    insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id)
    values (pg_temp.eid(p_exam), pg_temp.uid(p_student), pg_temp.uid(p_student), p_status, 0,
      case when p_centre then 'centre'::public.sitting_mode else 'home'::public.sitting_mode end,
      case when p_centre then (select ec.id from public.exam_centres ec where ec.exam_id = pg_temp.eid(p_exam)) end)
    returning id)
  insert into bk select p_key, b.id from b
$$;
select pg_temp.book('fx', 'fixed', 's7', 'paid');
select pg_temp.book('mv', 'move', 's7', 'paid');
select pg_temp.book('lv1', 'live', 's1', 'paid');
select pg_temp.book('lv2', 'live', 's2', 'paid');
select pg_temp.book('lv3', 'live', 's3', 'paid');
select pg_temp.book('lv5', 'live', 's5', 'awaiting_payment');
select pg_temp.book('lv6', 'live', 's6', 'cancel_requested');
select pg_temp.book('lv8', 'live', 's8', 'refunded');
select pg_temp.book('mxc', 'mixed', 's4', 'paid', true);
select pg_temp.book('mxh', 'mixed', 's9', 'paid');
select pg_temp.book('ft', 'future', 's8', 'paid');
select pg_temp.book('em', 'empty', 's9', 'paid');

-- Stored PDFs in the private bucket (written as postgres, as the storage service would).
create function pg_temp.obj(p_key text, p_exam text) returns void language sql as $$
  with o as (
    insert into storage.objects (bucket_id, name)
    values ('exam-papers', pg_temp.eid(p_exam)::text || '/' || gen_random_uuid()::text || '.pdf')
    returning name)
  insert into pp (name, path) select p_key, o.name from o
$$;
select pg_temp.obj('lv_v1', 'live');
select pg_temp.obj('lv_v2', 'live');
select pg_temp.obj('lv_ins', 'live');
select pg_temp.obj('fx', 'fixed');
select pg_temp.obj('fx_ins', 'fixed');
select pg_temp.obj('mv', 'move');
select pg_temp.obj('mx', 'mixed');
select pg_temp.obj('ft', 'future');
select pg_temp.obj('spare', 'live');

-- ---------------------------------------------------------------------------------------------
-- Schema and privileges.
-- ---------------------------------------------------------------------------------------------
select is((select array_agg(e.enumlabel::text order by e.enumsortorder) from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'paper_kind'),
  array['paper', 'insert'], 'paper_kind labels');
select is((select array_agg(e.enumlabel::text order by e.enumsortorder) from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'paper_download_kind'),
  array['home', 'print_pack', 'reprint', 'admin_preview'], 'paper_download_kind labels');
select is((select count(*)::int from pg_class k join pg_namespace n on n.oid = k.relnamespace
  where n.nspname = 'public' and k.relname in ('exam_papers', 'paper_copies', 'paper_downloads') and k.relkind = 'r' and k.relrowsecurity),
  3, 'the three paper tables exist with RLS enabled');
select is((select count(*)::int from unnest(array['exam_papers', 'paper_copies', 'paper_downloads']) t,
  unnest(array['insert', 'update', 'delete', 'truncate']) pr, unnest(array['anon', 'authenticated']) ro
  where has_table_privilege(ro, 'public.' || t, pr)), 0, 'no direct writes for anon or authenticated');
select is((select count(*)::int from unnest(array['exam_papers', 'paper_copies', 'paper_downloads']) t
  where has_table_privilege('anon', 'public.' || t, 'select')), 0, 'anon cannot read the paper tables');
select results_eq($q$select public, file_size_limit, allowed_mime_types from storage.buckets where id = 'exam-papers'$q$,
  $q$values (false, 20971520::bigint, array['application/pdf'])$q$, 'exam-papers is a private 20 MB PDF bucket');
select is((select release_minutes_before || '/' || spare_pages || '/' || release_held || '/'
  || coalesce(released_early_at::text, 'none') || '/' || coalesce(release_notified_at::text, 'none') from public.exams where id = pg_temp.eid('live')),
  '10/2/false/none/none', 'new exams release 10 minutes early, with 2 spare pages, not held');
select throws_ok($$update public.exams set release_minutes_before = 121 where id = pg_temp.eid('live')$$, '23514', null, 'release minutes are at most 120');
select throws_ok($$update public.exams set spare_pages = 7 where id = pg_temp.eid('live')$$, '23514', null, 'spare pages are at most 6');
select ok((select bool_and(has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute'))
  from unnest(array[
    'public.paper_copy_issue(uuid,public.paper_download_kind,timestamptz)',
    'public.paper_download_log(uuid,public.paper_download_kind)',
    'public.paper_insert_issue(uuid,uuid,timestamptz)',
    'public.booking_paper_state(uuid,timestamptz)',
    'public.paper_lookup_codes(jsonb)',
    'public.register_exam_paper(uuid,public.paper_kind,text,text,int,bigint,text)',
    'public.set_exam_paper_settings(uuid,text,int,int)',
    'public.remove_exam_insert(uuid,text)',
    'public.paper_release_now(uuid,text)',
    'public.paper_hold(uuid,text)',
    'public.paper_resume(uuid,text)',
    'public.paper_release_at(uuid)',
    'public.copy_code_valid(text)']) f), 'paper functions: signed-in callers only, with the exact signatures');
select ok(not has_function_privilege('authenticated', 'public.copy_code_new()', 'execute')
  and not has_function_privilege('anon', 'public.copy_code_new()', 'execute')
  and has_function_privilege('service_role', 'public.paper_copy_issue(uuid,public.paper_download_kind,timestamptz)', 'execute')
  and has_function_privilege('service_role', 'public.paper_download_log(uuid,public.paper_download_kind)', 'execute'),
  'copy_code_new is internal; service_role can issue and log copies');

-- Exam codes: <SUBJECT>-<PAPER initials>-<YYYY>-<MM>, with -2, -3 on collision.
select is((select exam_code from public.exams where id = pg_temp.eid('fixed')), 'ZZPAPERS-P1H-2031-06', 'exam code from subject, paper initials and London month');
select is((select exam_code from public.exams where id = pg_temp.eid('fixed2')), 'ZZPAPERS-P1H-2031-06-2', 'a second exam with the same code gets -2');
select is((select exam_code from public.exams where id = pg_temp.eid('nopaper')), 'ZZPAPERS-2031-06', 'no paper name, no initials');
select throws_ok($$update public.exams set exam_code = 'ZZPAPERS-P1H-2031-06' where id = pg_temp.eid('fixed2')$$, '23505', null, 'exam codes are unique');
select throws_ok($$update public.exams set exam_code = 'bad code' where id = pg_temp.eid('fixed2')$$, '23514', null, 'exam codes are upper-case letters, digits and dashes');
select throws_ok($$update public.exams set exam_code = null where id = pg_temp.eid('fixed2')$$, '23502', null, 'every exam has a code');

-- ---------------------------------------------------------------------------------------------
-- copy_code_check_character: 8 Crockford characters plus the mod-37 check symbol.
-- ---------------------------------------------------------------------------------------------
select ok(public.copy_code_valid('000000000') and public.copy_code_valid('7KQ2M9XDF') and public.copy_code_valid('ZZZZZZZZF')
  and public.copy_code_valid('00000010*') and public.copy_code_valid('00000014U'), 'copy_code_check_character: valid codes pass (check symbols 0, F, *, U)');
select is(public.copy_code_valid('7KQ2M9XEF'), false, 'copy_code_check_character: one changed character fails');
select ok(not public.copy_code_valid('7KQ2M9XDQ') and not public.copy_code_valid('7kq2m9xdf') and not public.copy_code_valid('7KQ2M9XIF')
  and not public.copy_code_valid('7KQ2M9XD') and not public.copy_code_valid('7KQ2M9XDFF') and not public.copy_code_valid(''),
  'a wrong check symbol, lower case, I/L/O/U or the wrong length fail');
select is(public.copy_code_valid(null), false, 'a missing code is not valid');
select ok((select bool_and(public.copy_code_valid(x) and char_length(x) = 9) and count(distinct x) = 200
  from (select public.copy_code_new() x from generate_series(1, 200)) t), 'new codes are valid, 9 characters and distinct');

-- ---------------------------------------------------------------------------------------------
-- Registering papers and inserts.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.reg('lv_v1', 'live', 'paper', null, 3) ->> 'version', '1', 'the first paper is version 1');
select is((select title || '/' || page_count || '/' || byte_size || '/' || (uploaded_by = pg_temp.uid('admin')) || '/' || (superseded_at is null)
  from public.exam_papers where id = pg_temp.pid('lv_v1')), 'Question paper/3/1000/true/true', 'stored with a default title, size and uploader, current');
select is(public.register_exam_paper(pg_temp.eid('live'), 'paper', null, pg_temp.path('fx'), 3, 1000, 'Wrong exam') ->> 'code',
  'invalid_input', 'a stored file under another exam is refused');
select is(public.register_exam_paper(pg_temp.eid('live'), 'paper', null, pg_temp.eid('live')::text || '/' || gen_random_uuid()::text || '.pdf', 3, 1000, null) ->> 'code',
  'invalid_input', 'a path with no stored file is refused');
select ok(public.register_exam_paper(pg_temp.eid('live'), 'paper', null, pg_temp.path('lv_v2'), 0, 1000, 'Some reason') ->> 'code' = 'invalid_input'
  and public.register_exam_paper(pg_temp.eid('live'), 'paper', null, pg_temp.path('lv_v2'), 3, 20971521, 'Some reason') ->> 'code' = 'invalid_input'
  and public.register_exam_paper(pg_temp.eid('live'), 'paper', null, pg_temp.eid('live')::text || '/paper.txt', 3, 1000, 'Some reason') ->> 'code' = 'invalid_input'
  and public.register_exam_paper(pg_temp.eid('live'), 'paper', repeat('t', 121), pg_temp.path('lv_v2'), 3, 1000, 'Some reason') ->> 'code' = 'invalid_input',
  'no pages, over 20 MB, a non-PDF path or an over-long title is refused');
select is(public.register_exam_paper(pg_temp.eid('live'), 'paper', null, pg_temp.path('lv_v1'), 3, 1000, 'Again') ->> 'code', 'conflict', 'a stored file is registered once');
select is(pg_temp.reg('lv_ins', 'live', 'insert', ' ', 1) ->> 'code', 'invalid_input', 'an insert needs a title');
select is(pg_temp.reg('lv_ins', 'live', 'insert', 'Formula sheet', 1) ->> 'ok', 'true', 'an insert is registered');
select ok(pg_temp.reg('fx', 'fixed', 'paper', null, 3) ->> 'ok' = 'true'
  and pg_temp.reg('fx_ins', 'fixed', 'insert', 'Data booklet', 2) ->> 'ok' = 'true'
  and pg_temp.reg('mv', 'move', 'paper', null, 3) ->> 'ok' = 'true'
  and pg_temp.reg('mx', 'mixed', 'paper', null, 3) ->> 'ok' = 'true'
  and pg_temp.reg('ft', 'future', 'paper', null, 3) ->> 'ok' = 'true', 'papers for the other exams are registered');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(public.register_exam_paper(pg_temp.eid('live'), 'paper', null, pg_temp.path('lv_v2'), 3, 1000, 'Mine') ->> 'code', 'forbidden', 'a student cannot register a paper');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher'));
select is(public.register_exam_paper(pg_temp.eid('live'), 'paper', null, pg_temp.path('lv_v2'), 3, 1000, 'Mine') ->> 'code', 'forbidden', 'a teacher cannot register a paper');
select tests.as_postgres();
select is((select count(*)::int from public.audit_log where action = 'paper_uploaded' and actor_id = pg_temp.uid('admin') and target_type = 'exam_paper'
  and target_id in (select id from pp)), 7, 'each upload is audited');
select throws_ok(format($q$insert into public.exam_papers (exam_id, kind, title, version, storage_path, page_count, byte_size)
  values (%L, 'paper', 'Extra', 9, %L, 1, 1)$q$, pg_temp.eid('live'), pg_temp.eid('live')::text || '/extra.pdf'), '23505', null, 'an exam has one current paper');

-- ---------------------------------------------------------------------------------------------
-- family_cannot_read_paper_objects: only owner/admin read, add or delete paper files.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('s1'));
select is((select count(*)::int from storage.objects where bucket_id = 'exam-papers'), 0, 'family_cannot_read_paper_objects: a student sees no paper files');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p1'));
select is((select count(*)::int from storage.objects where bucket_id = 'exam-papers'), 0, 'a parent sees no paper files');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher'));
select is((select count(*)::int from storage.objects where bucket_id = 'exam-papers'), 0, 'a teacher sees no paper files');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is((select count(*)::int from storage.objects where bucket_id = 'exam-papers' and name in (select path from pp)), 9, 'an admin sees every paper file');
select tests.as_postgres();
insert into pp (name, path) values ('admin_up', pg_temp.eid('live')::text || '/' || gen_random_uuid()::text || '.pdf');
select tests.as_user(pg_temp.uid('s1'));
select throws_ok(format($q$insert into storage.objects (bucket_id, name) values ('exam-papers', %L)$q$,
  pg_temp.eid('live')::text || '/' || gen_random_uuid()::text || '.pdf'), '42501', null, 'a student cannot upload a paper file');
select set_config('storage.allow_delete_query', 'true', true);
delete from storage.objects where bucket_id = 'exam-papers' and name = pg_temp.path('spare');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select throws_ok($q$insert into storage.objects (bucket_id, name) values ('exam-papers', 'loose.pdf')$q$, '42501', null, 'paper files live at <exam id>/<uuid>.pdf');
select lives_ok(format($q$insert into storage.objects (bucket_id, name) values ('exam-papers', %L)$q$, pg_temp.path('admin_up')), 'an admin uploads a paper file');
delete from storage.objects where bucket_id = 'exam-papers' and name in (pg_temp.path('lv_v1'), pg_temp.path('admin_up'));
select set_config('storage.allow_delete_query', '', true);
select tests.as_postgres();
select is((select count(*)::int from storage.objects where bucket_id = 'exam-papers' and name = pg_temp.path('spare')), 1, 'a student cannot delete a paper file');
select is((select count(*)::int from storage.objects where bucket_id = 'exam-papers' and name = pg_temp.path('lv_v1')), 1, 'a registered paper file cannot be deleted, even by an admin');
select is((select count(*)::int from storage.objects where bucket_id = 'exam-papers' and name = pg_temp.path('admin_up')), 0, 'an admin can delete a file that is not a registered paper');

-- ---------------------------------------------------------------------------------------------
-- release_boundary_uses_server_time: start 10:00, release 09:50 (fixed exam, s7 at home).
-- ---------------------------------------------------------------------------------------------
select is(public.paper_release_at(pg_temp.eid('fixed')), '2031-06-07 09:50 Europe/London'::timestamptz, 'release is the start minus 10 minutes');
select tests.as_user(pg_temp.uid('s7'));
select is(pg_temp.issue('fx', 'home', '2031-06-07 09:49:59 Europe/London') ->> 'code', 'paper_not_released', 'release_boundary_uses_server_time: 09:49:59 is refused');
select is(pg_temp.issue('fx', 'home', '2031-06-07 09:50:00 Europe/London') ->> 'ok', 'true', 'release_boundary_uses_server_time: 09:50:00 is allowed');
select is(pg_temp.state('fx', '2031-06-07 09:49:59 Europe/London') ->> 'status', 'not_yet', 'the paper state says not yet before release');
select is((pg_temp.state('fx', '2031-06-07 09:49:59 Europe/London') ->> 'release_at')::timestamptz, '2031-06-07 09:50 Europe/London'::timestamptz, 'and gives the release time');
-- A call through the API (PostgREST sets request.method) cannot choose its own clock: the database clock decides.
select set_config('request.method', 'POST', true);
select is(pg_temp.issue('fx', 'home', '2031-06-07 09:55 Europe/London') ->> 'code', 'paper_not_released', 'an API caller cannot move the clock forward');
select is(pg_temp.state('fx', '2031-06-07 09:55 Europe/London') ->> 'status', 'not_yet', 'nor in the paper state');
select is(public.paper_insert_issue(pg_temp.bid('fx'), pg_temp.pid('fx_ins'), '2031-06-07 09:55 Europe/London') ->> 'code', 'paper_not_released', 'nor for inserts');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(pg_temp.issue('lv1', 'home', '2000-01-01 00:00 Europe/London') ->> 'ok', 'true', 'nor back: the database clock opens an exam that is released');
select set_config('request.method', '', true);

-- closed_two_hours_after_end: the 90-minute exam ends at 11:30, so home copies stop at 13:30.
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s7'));
select is(pg_temp.issue('fx', 'home', '2031-06-07 13:29:59 Europe/London') ->> 'ok', 'true', 'still open a second before the end plus 2 hours');
select is(pg_temp.issue('fx', 'home', '2031-06-07 13:30:00 Europe/London') ->> 'code', 'paper_closed', 'closed_two_hours_after_end');
select is(pg_temp.state('fx', '2031-06-07 13:30:00 Europe/London') ->> 'status', 'closed', 'the paper state says closed');
select tests.as_postgres();
update public.exams set status = 'completed' where id = pg_temp.eid('fixed');
select tests.as_user(pg_temp.uid('s7'));
select is(pg_temp.issue('fx', 'home', '2031-06-07 13:00 Europe/London') ->> 'ok', 'true', 'the window decides, not the status: completed early by the job, still open');
select tests.as_postgres();
update public.exams set status = 'cancelled' where id = pg_temp.eid('fixed');
select tests.as_user(pg_temp.uid('s7'));
select is(pg_temp.issue('fx', 'home', '2031-06-07 10:30 Europe/London') ->> 'code', 'paper_closed', 'a cancelled exam gives no paper');
select is(pg_temp.state('fx', '2031-06-07 10:30 Europe/London') ->> 'status', 'closed', 'and its paper state is closed');
select tests.as_postgres();
update public.exams set status = 'published' where id = pg_temp.eid('fixed');

-- ---------------------------------------------------------------------------------------------
-- release_follows_reschedule
-- ---------------------------------------------------------------------------------------------
select is(public.paper_release_at(pg_temp.eid('move')), '2031-07-01 09:50 Europe/London'::timestamptz, 'release before the move');
select tests.as_user(pg_temp.uid('s7'));
select is(pg_temp.issue('mv', 'home', '2031-07-01 09:55 Europe/London') ->> 'ok', 'true', 'open at the first date');
select tests.as_postgres();
update public.exams set starts_at = '2031-07-08 10:00 Europe/London' where id = pg_temp.eid('move');
select is(public.paper_release_at(pg_temp.eid('move')), '2031-07-08 09:50 Europe/London'::timestamptz, 'release_follows_reschedule: the release time moves with the exam');
select tests.as_user(pg_temp.uid('s7'));
select is(pg_temp.issue('mv', 'home', '2031-07-01 09:55 Europe/London') ->> 'code', 'paper_not_released', 'the old release time no longer opens it');
select is(pg_temp.issue('mv', 'home', '2031-07-08 09:50 Europe/London') ->> 'ok', 'true', 'the new release time does');
select tests.as_postgres();
update public.exams set released_early_at = '2031-07-05 12:00 Europe/London', release_notified_at = '2031-07-05 12:01 Europe/London' where id = pg_temp.eid('move');
select is(public.paper_release_at(pg_temp.eid('move')), '2031-07-05 12:00 Europe/London'::timestamptz, 'an early release comes first');
update public.exams set starts_at = '2031-07-15 10:00 Europe/London' where id = pg_temp.eid('move');
select is((select coalesce(released_early_at::text, 'none') || '/' || coalesce(release_notified_at::text, 'none') from public.exams where id = pg_temp.eid('move')),
  'none/none', 'moving the exam clears an early release and its notice');
select is(public.paper_release_at(pg_temp.eid('move')), '2031-07-15 09:50 Europe/London'::timestamptz, 'so the release follows the new start');

-- ---------------------------------------------------------------------------------------------
-- release_now_and_hold_are_audited (future exam in two days, s8 at home).
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('s8'));
select is(pg_temp.issue('ft', 'home') ->> 'code', 'paper_not_released', 'two days before the exam the paper is not released');
select is(public.paper_release_now(pg_temp.eid('future'), 'Start moved forward') ->> 'code', 'forbidden', 'a family cannot release a paper');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(public.paper_release_now(pg_temp.eid('future'), '  ') ->> 'code', 'invalid_input', 'release now needs a reason');
select is(public.paper_release_now(pg_temp.eid('future'), 'Start moved forward') ->> 'ok', 'true', 'an admin releases now');
select is(public.paper_release_at(pg_temp.eid('future')), now(), 'released at the database time');
select is(public.paper_release_now(pg_temp.eid('future'), 'Start moved forward') ->> 'code', 'conflict', 'a released paper cannot be released again');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s8'));
insert into r select 'ft1', pg_temp.issue('ft', 'home');
select is(pg_temp.res('ft1') ->> 'ok', 'true', 'after release now the family downloads');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(public.paper_hold(pg_temp.eid('future'), 'Typo on page 2') ->> 'ok', 'true', 'an admin holds the paper');
select is(public.paper_hold(pg_temp.eid('future'), 'Typo on page 2') ->> 'code', 'conflict', 'a held paper cannot be held again');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s8'));
select is(pg_temp.issue('ft', 'home') ->> 'code', 'paper_held', 'release_now_and_hold_are_audited: a held paper is refused');
select is(pg_temp.dl(pg_temp.copy('ft1'), 'home') ->> 'code', 'paper_held', 'a held paper cannot be logged as downloaded');
select is(pg_temp.state('ft') ->> 'status', 'held', 'the paper state says held');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(public.paper_resume(pg_temp.eid('future'), 'Corrected') ->> 'ok', 'true', 'an admin resumes the release');
select is(public.paper_resume(pg_temp.eid('future'), 'Corrected') ->> 'code', 'conflict', 'a paper that is not held cannot be resumed');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s8'));
select is(pg_temp.issue('ft', 'home') ->> 'ok', 'true', 'resume restores downloads');
select tests.as_postgres();
select is((select count(*)::int from public.audit_log where target_type = 'exam' and target_id = pg_temp.eid('future')), 3,
  'release_now_and_hold_are_audited: three audit rows');
select is((select string_agg(action || ':' || reason || ':' || (actor_id = pg_temp.uid('admin')), ', ' order by id) from public.audit_log
  where target_type = 'exam' and target_id = pg_temp.eid('future')),
  'paper_released_early:Start moved forward:true, paper_held:Typo on page 2:true, paper_resumed:Corrected:true', 'each with the admin and the reason');

-- ---------------------------------------------------------------------------------------------
-- linked_parent_allowed_other_parent_refused (live exam, released 5 minutes ago; s1 at home).
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('s1'));
insert into r select 's1_v1', pg_temp.issue('lv1', 'home');
select is(pg_temp.res('s1_v1') ->> 'ok', 'true', 'the student gets a copy');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p1'));
insert into r select 'p1_v1', pg_temp.issue('lv1', 'home');
select is(pg_temp.res('p1_v1') ->> 'code', pg_temp.res('s1_v1') ->> 'code', 'linked_parent_allowed_other_parent_refused: the linked parent gets the same copy');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p2'));
select is(pg_temp.issue('lv1', 'home') ->> 'code', 'forbidden', 'linked_parent_allowed_other_parent_refused: another parent is refused');
select is(pg_temp.dl(pg_temp.copy('s1_v1'), 'home') ->> 'code', 'forbidden', 'and cannot log a download of the copy');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p3'));
select is(pg_temp.issue('lv1', 'home') ->> 'code', 'forbidden', 'a suspended linked parent is refused');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher'));
select is(pg_temp.issue('lv1', 'home') ->> 'code', 'forbidden', 'a teacher is refused');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s2'));
select is(pg_temp.issue('lv1', 'home') ->> 'code', 'forbidden', 'another student is refused');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.issue('lv1', 'home') ->> 'code', 'forbidden', 'admins take a preview, not a home download');
select is(public.paper_copy_issue(gen_random_uuid(), 'admin_preview') ->> 'code', 'not_found', 'an admin is told a booking does not exist');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(public.paper_copy_issue(gen_random_uuid(), 'home') ->> 'code', 'forbidden', 'a family gets the same answer for a missing booking as for a foreign one');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p1'));
select is(pg_temp.dl(pg_temp.copy('p1_v1'), 'home') ->> 'ok', 'true', 'the parent''s download is logged');
select tests.as_postgres();
select is((select string_agg((downloaded_by = pg_temp.uid('p1')) || '/' || kind || '/' || (at = now()), ',') from public.paper_downloads
  where copy_id = pg_temp.copy('p1_v1')), 'true/home/true', 'with who, which kind and when');

-- same_copy_code_on_repeat
select tests.as_user(pg_temp.uid('s1'));
insert into r select 's1_v1b', pg_temp.issue('lv1', 'home');
select is(pg_temp.copy('s1_v1b'), pg_temp.copy('s1_v1'), 'same_copy_code_on_repeat: the same copy');
select is(pg_temp.res('s1_v1b') ->> 'code', pg_temp.res('s1_v1') ->> 'code', 'same_copy_code_on_repeat: the same code');
select tests.as_postgres();
select is((select count(*)::int from public.paper_copies where booking_id = pg_temp.bid('lv1')), 1, 'same_copy_code_on_repeat: one paper_copies row');
select is(pg_temp.res('s1_v1') - 'copy_id' - 'code' - 'storage_path' - 'exam_code' - 'starts_at',
  jsonb_build_object('ok', true, 'page_count', 5, 'spare_pages', 2, 'paper_version', 1, 'candidate_name', 'Amara Perera',
    'index_number', 'SE-2031-9201', 'exam_title', 'ZZ live (Paper 1 Higher)', 'differs_from_previous', false),
  'the copy: 3 pages plus 2 spare, version 1, the candidate and the exam');
select ok(pg_temp.res('s1_v1') ->> 'storage_path' = pg_temp.path('lv_v1')
  and pg_temp.res('s1_v1') ->> 'exam_code' = (select exam_code from public.exams where id = pg_temp.eid('live'))
  and (pg_temp.res('s1_v1') ->> 'starts_at')::timestamptz = (select starts_at from public.exams where id = pg_temp.eid('live'))
  and public.copy_code_valid(pg_temp.res('s1_v1') ->> 'code')
  and (select code from public.paper_copies where id = pg_temp.copy('s1_v1')) = pg_temp.res('s1_v1') ->> 'code',
  'the stored paper, the exam code and start, and a valid copy code');

-- booking_paper_state before any replacement.
select tests.as_user(pg_temp.uid('s1'));
insert into r select 'st1', pg_temp.state('lv1');
select tests.as_postgres();
select is(pg_temp.res('st1') ->> 'sitting', 'home', 'the paper state gives the sitting');
select is(pg_temp.res('st1') ->> 'status', 'open', 'released and not held: open');
select is(pg_temp.res('st1') ->> 'corrected', 'false', 'not corrected before any replacement');
select is(pg_temp.res('st1') -> 'last_download' ->> 'by_name', 'Nimal Perera', 'the last download names the parent');
select is((pg_temp.res('st1') -> 'last_download' ->> 'at')::timestamptz, now(), 'and its time');
select is(pg_temp.res('st1') -> 'inserts', jsonb_build_array(jsonb_build_object('id', pg_temp.pid('lv_ins'), 'title', 'Formula sheet')), 'the released insert is listed');

-- ---------------------------------------------------------------------------------------------
-- centre_booking_gets_wrong_sitting_for_home (mixed exam: s4 at the centre, s9 at home).
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('s4'));
select is(pg_temp.issue('mxc', 'home') ->> 'code', 'wrong_sitting', 'centre_booking_gets_wrong_sitting_for_home');
select is(pg_temp.state('mxc') ->> 'status', 'centre', 'the paper state says the centre');
select is(pg_temp.issue('mxc', 'print_pack') ->> 'code', 'forbidden', 'a family cannot print packs');
select is(pg_temp.issue('mxc', 'admin_preview') ->> 'code', 'forbidden', 'or take a preview');
select is(public.paper_insert_issue(pg_temp.bid('mxc'), pg_temp.pid('lv_ins')) ->> 'code', 'wrong_sitting', 'or take an insert for a centre booking');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
insert into r select 'pk', pg_temp.issue('mxc', 'print_pack');
insert into r select 'rp', pg_temp.issue('mxc', 'reprint');
select is(pg_temp.res('pk') ->> 'ok', 'true', 'an admin prints the centre booking');
select is(pg_temp.res('rp') ->> 'code', pg_temp.res('pk') ->> 'code', 'a reprint has the same codes');
select is(pg_temp.res('rp') ->> 'differs_from_previous', 'false', 'and does not differ');
select is(pg_temp.issue('mxh', 'print_pack') ->> 'code', 'wrong_sitting', 'a home booking is not in the print pack');
select is(pg_temp.issue('mxh', 'admin_preview') ->> 'ok', 'true', 'an admin previews a home booking');
select is(pg_temp.dl(pg_temp.copy('pk'), 'print_pack') ->> 'ok', 'true', 'a print-pack copy is logged');
select tests.as_postgres();
select is((select (downloaded_by = pg_temp.uid('admin')) || '/' || kind from public.paper_downloads where copy_id = pg_temp.copy('pk')),
  'true/print_pack', 'logged as a print pack by the admin');

-- unpaid_refused_cancel_requested_allowed
select tests.as_user(pg_temp.uid('s5'));
select is(pg_temp.issue('lv5', 'home') ->> 'code', 'forbidden', 'unpaid_refused_cancel_requested_allowed: an unpaid booking is refused');
select is(pg_temp.state('lv5') ->> 'status', 'closed', 'an unpaid booking''s paper state is closed');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s6'));
select is(pg_temp.issue('lv6', 'home') ->> 'ok', 'true', 'unpaid_refused_cancel_requested_allowed: a cancellation request still gets the paper');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s8'));
select is(pg_temp.issue('lv8', 'home') ->> 'code', 'forbidden', 'a refunded booking is refused');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.issue('lv5', 'admin_preview') ->> 'ok', 'true', 'an admin previews any booking, even unpaid');

-- Paper missing at release.
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s9'));
select is(pg_temp.issue('em', 'home') ->> 'code', 'paper_missing', 'released with no paper: paper_missing');
select is(pg_temp.state('em') ->> 'status', 'missing', 'the paper state says missing');

-- ---------------------------------------------------------------------------------------------
-- twenty_first_download_in_an_hour_rate_limited (s3).
-- ---------------------------------------------------------------------------------------------
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s3'));
insert into r select 'rl', pg_temp.issue('lv3', 'home');
select is(pg_temp.dl_n(pg_temp.copy('rl'), 20), 20, 'twenty home downloads in an hour are logged');
select is(pg_temp.issue('lv3', 'home') ->> 'code', 'rate_limited', 'twenty_first_download_in_an_hour_rate_limited');
select is(pg_temp.dl(pg_temp.copy('rl'), 'home') ->> 'code', 'rate_limited', 'a 21st download cannot be logged either');
select tests.as_postgres();
update public.paper_downloads set at = at - interval '61 minutes' where copy_id = pg_temp.copy('rl');
select tests.as_user(pg_temp.uid('s3'));
select is(pg_temp.issue('lv3', 'home') ->> 'ok', 'true', 'downloads older than an hour no longer count');

-- ---------------------------------------------------------------------------------------------
-- cancelled_booking_keeps_copy_but_cannot_download (s2).
-- ---------------------------------------------------------------------------------------------
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s2'));
insert into r select 'cx', pg_temp.issue('lv2', 'home');
select is(pg_temp.dl(pg_temp.copy('cx'), 'home') ->> 'ok', 'true', 'downloaded before the cancellation');
select tests.as_postgres();
update public.bookings set status = 'cancelled' where id = pg_temp.bid('lv2');
select tests.as_user(pg_temp.uid('s2'));
select is(pg_temp.issue('lv2', 'home') ->> 'code', 'forbidden', 'cancelled_booking_keeps_copy_but_cannot_download: no new download');
select is(pg_temp.dl(pg_temp.copy('cx'), 'home') ->> 'code', 'forbidden', 'and no download can be logged');
select is(pg_temp.state('lv2') ->> 'status', 'closed', 'the paper state says closed');
select tests.as_postgres();
select is((select count(*)::int from public.paper_copies where booking_id = pg_temp.bid('lv2')), 1, 'cancelled_booking_keeps_copy_but_cannot_download: the copy record is kept');
select is((select count(*)::int from public.paper_downloads where copy_id = pg_temp.copy('cx')), 1, 'and its download log');

-- ---------------------------------------------------------------------------------------------
-- replaced_paper_new_copy_old_code_still_found (live exam: copies of version 1 exist).
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.reg('lv_v2', 'live', 'paper', null, 4) ->> 'code', 'invalid_input', 'replaced_paper_new_copy_old_code_still_found: replacing after a copy needs a reason');
select is(pg_temp.reg('lv_v2', 'live', 'paper', null, 4, 'ab') ->> 'code', 'invalid_input', 'a reason shorter than 3 characters is refused');
select is(pg_temp.reg('lv_v2', 'live', 'paper', null, 4, 'Question 3 misprinted') ->> 'version', '2', 'with a reason the replacement is version 2');
select is((select string_agg(version || ':' || (superseded_at is not null) || ':' || coalesce(replace_reason, '-'), ', ' order by version)
  from public.exam_papers where exam_id = pg_temp.eid('live') and kind = 'paper'),
  '1:true:-, 2:false:Question 3 misprinted', 'version 1 is kept and superseded; version 2 is current with the reason');
select tests.as_postgres();
select is((select action || ':' || reason from public.audit_log where target_id = pg_temp.pid('lv_v2')), 'paper_replaced:Question 3 misprinted', 'the replacement is audited with its reason');
select tests.as_user(pg_temp.uid('s1'));
insert into r select 's1_v2', pg_temp.issue('lv1', 'home');
select isnt(pg_temp.res('s1_v2') ->> 'code', pg_temp.res('s1_v1') ->> 'code', 'replaced_paper_new_copy_old_code_still_found: the new version gets a new code');
select is((pg_temp.res('s1_v2') ->> 'paper_version') || '/' || (pg_temp.res('s1_v2') ->> 'page_count') || '/' || (pg_temp.res('s1_v2') ->> 'differs_from_previous'),
  '2/6/true', 'version 2, 4 pages plus 2 spare, different from the copy last downloaded');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
insert into r select 'lk', public.paper_lookup_codes(jsonb_build_array(
  jsonb_build_object('code', pg_temp.res('s1_v1') ->> 'code', 'page', 1),
  jsonb_build_object('code', pg_temp.res('s1_v2') ->> 'code', 'page', 6),
  jsonb_build_object('code', pg_temp.res('s1_v2') ->> 'code', 'page', 7),
  jsonb_build_object('code', '7KQ2M9XDF', 'page', 1),
  jsonb_build_object('code', pg_temp.res('cx') ->> 'code', 'page', 2)));
select tests.as_postgres();
select is(jsonb_array_length(pg_temp.res('lk')), 5, 'one answer per code, in order');
select is(pg_temp.res('lk') -> 0, jsonb_build_object('code', pg_temp.res('s1_v1') ->> 'code', 'page', 1, 'found', true,
    'exam_code', (select exam_code from public.exams where id = pg_temp.eid('live')), 'exam_title', 'ZZ live (Paper 1 Higher)',
    'index_number', 'SE-2031-9201', 'page_count', 5, 'paper_version', 1, 'current', false),
  'replaced_paper_new_copy_old_code_still_found: the version 1 code still looks up, not current');
select is((pg_temp.res('lk') -> 1 ->> 'found') || '/' || (pg_temp.res('lk') -> 1 ->> 'paper_version') || '/' || (pg_temp.res('lk') -> 1 ->> 'current'),
  'true/2/true', 'replaced_paper_new_copy_old_code_still_found: the version 2 code is current');
select is(pg_temp.res('lk') -> 2 ->> 'found', 'false', 'a page past the end of the copy is not found');
select is(pg_temp.res('lk') -> 3, jsonb_build_object('code', '7KQ2M9XDF', 'page', 1, 'found', false, 'exam_code', null, 'exam_title', null,
  'index_number', null, 'page_count', null, 'paper_version', null, 'current', null), 'an unknown code is not found');
select is((pg_temp.res('lk') -> 4 ->> 'found') || '/' || (pg_temp.res('lk') -> 4 ->> 'index_number'), 'true/SE-2031-9202',
  'cancelled_booking_keeps_copy_but_cannot_download: its code still looks up');
select tests.as_user(pg_temp.uid('s1'));
select is(public.paper_lookup_codes('[]') ->> 'code', 'forbidden', 'families cannot look up codes');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select ok(public.paper_lookup_codes('{}') ->> 'code' = 'invalid_input'
  and public.paper_lookup_codes('[{"code": 1, "page": 1}]') ->> 'code' = 'invalid_input'
  and public.paper_lookup_codes('[{"code": "7KQ2M9XDF", "page": 1.5}]') ->> 'code' = 'invalid_input'
  and public.paper_lookup_codes(null) ->> 'code' = 'invalid_input', 'lookups need a list of {code, page}');
select is(public.paper_lookup_codes('[]'), '[]'::jsonb, 'an empty list gives an empty answer');

-- booking_paper_state_reports_corrected: version 1 was downloaded (by p1), then the paper was replaced.
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(pg_temp.state('lv1') ->> 'corrected', 'true', 'booking_paper_state_reports_corrected: after a download of version 1 and a replacement');
select is(pg_temp.dl(pg_temp.copy('s1_v2'), 'home') ->> 'ok', 'true', 'version 2 is downloaded');
select is(pg_temp.state('lv1') ->> 'corrected', 'false', 'booking_paper_state_reports_corrected: after downloading version 2');
select is(pg_temp.state('lv1') -> 'last_download' ->> 'by_name', 'Amara Perera', 'downloaded by the student');

-- ---------------------------------------------------------------------------------------------
-- exam_code_locked_after_first_copy, and the other paper settings.
-- ---------------------------------------------------------------------------------------------
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(public.set_exam_paper_settings(pg_temp.eid('nopaper'), ' zz-new-code ', 15, 3) ->> 'ok', 'true', 'settings save before any copy');
select is((select exam_code || '/' || release_minutes_before || '/' || spare_pages from public.exams where id = pg_temp.eid('nopaper')),
  'ZZ-NEW-CODE/15/3', 'the code is upper-cased; minutes and spare pages are saved');
select ok((select bool_and(public.set_exam_paper_settings(pg_temp.eid('nopaper'), t.code, t.mins, t.spare) ->> 'code' = 'invalid_input')
  from (values ('A B', 10, 2), ('AB', 10, 2), (repeat('A', 41), 10, 2), (null, 10, 2), ('ZZ-OK', 121, 2), ('ZZ-OK', -1, 2),
    ('ZZ-OK', 10, 7), ('ZZ-OK', null, 2), ('ZZ-OK', 10, null)) as t(code, mins, spare)), 'bad codes, minutes or spare pages are refused');
select is(public.set_exam_paper_settings(gen_random_uuid(), 'ZZ-OK', 10, 2) ->> 'code', 'not_found', 'an unknown exam');
select is(public.set_exam_paper_settings(pg_temp.eid('nopaper'), 'ZZPAPERS-P1H-2031-06', 15, 3) ->> 'code', 'conflict', 'a code another exam uses');
select is(public.set_exam_paper_settings(pg_temp.eid('live'), 'ZZ-OTHER', 10, 2) ->> 'code', 'conflict', 'exam_code_locked_after_first_copy');
select is(public.set_exam_paper_settings(pg_temp.eid('live'), (select exam_code from public.exams where id = pg_temp.eid('live')), 20, 4) ->> 'ok', 'true',
  'release minutes and spare pages still change after the first copy');
select is(public.paper_release_at(pg_temp.eid('live')), (select starts_at - interval '20 minutes' from public.exams where id = pg_temp.eid('live')), 'the release follows the new minutes');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(public.set_exam_paper_settings(pg_temp.eid('live'), 'ZZ-OTHER', 10, 2) ->> 'code', 'forbidden', 'a family cannot change settings');
select is(pg_temp.issue('lv1', 'home') ->> 'page_count', '6', 'an existing copy keeps its pages when spare pages change');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s6'));
select is((pg_temp.issue('lv6', 'home') ->> 'page_count') || '/' || (pg_temp.issue('lv6', 'home') ->> 'spare_pages'), '8/4', 'a new copy takes the new spare pages');
select tests.as_postgres();
select is((select count(*)::int from public.audit_log where action = 'exam_paper_settings_changed' and actor_id = pg_temp.uid('admin')
  and target_id in (pg_temp.eid('nopaper'), pg_temp.eid('live'))), 2, 'each settings change is audited');

-- ---------------------------------------------------------------------------------------------
-- Inserts: released with the paper, not personalised.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('s1'));
select is(public.paper_insert_issue(pg_temp.bid('lv1'), pg_temp.pid('lv_ins')),
  jsonb_build_object('ok', true, 'storage_path', pg_temp.path('lv_ins'), 'title', 'Formula sheet'), 'a home candidate gets a released insert');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s7'));
select is(public.paper_insert_issue(pg_temp.bid('fx'), pg_temp.pid('fx_ins')) ->> 'code', 'paper_not_released', 'inserts follow the release time');
select is(public.paper_insert_issue(pg_temp.bid('fx'), pg_temp.pid('fx_ins'), '2031-06-07 09:55 Europe/London') ->> 'ok', 'true', 'and open with it');
select is(public.paper_insert_issue(pg_temp.bid('fx'), pg_temp.pid('lv_ins'), '2031-06-07 09:55 Europe/London') ->> 'code', 'not_found', 'an insert of another exam is not found');
select is(public.paper_insert_issue(pg_temp.bid('fx'), pg_temp.pid('fx'), '2031-06-07 09:55 Europe/London') ->> 'code', 'not_found', 'the question paper is not an insert');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p2'));
select is(public.paper_insert_issue(pg_temp.bid('lv1'), pg_temp.pid('lv_ins')) ->> 'code', 'forbidden', 'another family cannot take an insert');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(public.paper_insert_issue(pg_temp.bid('fx'), pg_temp.pid('fx_ins')) ->> 'ok', 'true', 'admins take inserts at any time');
select is(public.remove_exam_insert(pg_temp.pid('lv_ins'), ' ') ->> 'code', 'invalid_input', 'removing an insert needs a reason');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(public.remove_exam_insert(pg_temp.pid('lv_ins'), 'Wrong booklet') ->> 'code', 'forbidden', 'a family cannot remove an insert');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(public.remove_exam_insert(pg_temp.pid('lv_ins'), 'Wrong booklet') ->> 'ok', 'true', 'an admin removes an insert');
select is(public.remove_exam_insert(pg_temp.pid('lv_ins'), 'Wrong booklet') ->> 'code', 'conflict', 'a removed insert cannot be removed again');
select is(public.remove_exam_insert(pg_temp.pid('lv_v2'), 'Not an insert') ->> 'code', 'not_found', 'the question paper is not removed this way');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(public.paper_insert_issue(pg_temp.bid('lv1'), pg_temp.pid('lv_ins')) ->> 'code', 'not_found', 'a removed insert cannot be downloaded');
select is(pg_temp.state('lv1') -> 'inserts', '[]'::jsonb, 'nor is it listed');
select tests.as_postgres();
select is((select action || ':' || reason || ':' || (superseded_at is not null) from public.audit_log a join public.exam_papers p on p.id = a.target_id
  where a.target_id = pg_temp.pid('lv_ins') and a.action <> 'paper_uploaded'), 'insert_removed:Wrong booklet:true', 'the removal is audited with its reason');
select tests.as_user(pg_temp.uid('s7'));
select is(pg_temp.state('fx', '2031-06-07 09:49:59 Europe/London') -> 'inserts', '[]'::jsonb, 'inserts are not listed before release');
select is(pg_temp.state('fx', '2031-06-07 09:50:00 Europe/London') -> 'inserts' -> 0 ->> 'title', 'Data booklet', 'and are listed from the release');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- Rows in the three tables: owner/admin only.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('s1'));
select is((select count(*)::int from public.exam_papers) + (select count(*)::int from public.paper_copies) + (select count(*)::int from public.paper_downloads),
  0, 'a student reads no paper, copy or download rows');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p1'));
select is((select count(*)::int from public.exam_papers) + (select count(*)::int from public.paper_copies) + (select count(*)::int from public.paper_downloads),
  0, 'a parent reads none');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher'));
select is((select count(*)::int from public.exam_papers) + (select count(*)::int from public.paper_copies) + (select count(*)::int from public.paper_downloads),
  0, 'a teacher reads none');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select ok((select count(*) from public.exam_papers) > 0 and (select count(*) from public.paper_copies) > 0 and (select count(*) from public.paper_downloads) > 0,
  'an admin reads them all');

-- booking_paper_state is for the family and admins.
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p1'));
select is(pg_temp.state('lv1') ->> 'status', 'open', 'the linked parent reads the paper state');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p2'));
select is(pg_temp.state('lv1') ->> 'code', 'forbidden', 'another parent cannot');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher'));
select is(pg_temp.state('lv1') ->> 'code', 'forbidden', 'nor a teacher');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.state('lv1') ->> 'status', 'open', 'an admin reads it');

-- Logging needs a real copy and the right kind.
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(pg_temp.dl(gen_random_uuid(), 'home') ->> 'code', 'forbidden', 'a family logging an unknown copy is refused');
select is(pg_temp.dl(pg_temp.copy('s1_v2'), 'print_pack') ->> 'code', 'forbidden', 'a family cannot log a print pack');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.dl(gen_random_uuid(), 'admin_preview') ->> 'code', 'not_found', 'an admin is told the copy does not exist');
select is(pg_temp.dl(pg_temp.copy('s1_v2'), 'admin_preview') ->> 'ok', 'true', 'an admin preview is logged');
select tests.as_postgres();
select is((select count(*)::int from public.paper_downloads where copy_id = pg_temp.copy('s1_v2') and kind = 'admin_preview'), 1, 'logged as an admin preview');
select tests.as_user(pg_temp.uid('s1'));
select is(pg_temp.state('lv1') -> 'last_download' ->> 'by_name', 'Amara Perera', 'an admin preview is not the family''s last download');
select tests.as_postgres();

select * from finish();
rollback;
