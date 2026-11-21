begin;
create extension if not exists pgtap with schema extensions;
select plan(73);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Subjects subj and subj2. The teacher teaches subj; teacher2 teaches nothing. Correctors m1, m2 and m3,
-- a suspended corrector, a tutor, a parent and a student. Exam e (subj) and exam e2 (subj2) hold the scripts:
-- sa, sb, sc, sd (exam e) and se (exam e2), each for a different student.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values
  ('admin', tests.create_user('admin', 'active')),
  ('teacher', tests.create_user('teacher', 'active')),
  ('teacher2', tests.create_user('teacher', 'active')),
  ('m1', tests.create_user('corrector', 'active')),
  ('m2', tests.create_user('corrector', 'active')),
  ('m3', tests.create_user('corrector', 'active')),
  ('m4', tests.create_user('corrector', 'active')),
  ('susp', tests.create_user('corrector', 'suspended')),
  ('tutor', tests.create_user('tutor', 'active')),
  ('parent', tests.create_user('parent', 'active')),
  ('stu', tests.create_user('student', 'active'));
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table res (name text primary key, j jsonb);
grant all on res to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
create function pg_temp.subj(p text) returns bigint language sql stable as $$
  select id from public.subjects where name = case p when 'subj' then 'ZZ Markers' else 'ZZ Markers other' end $$;
-- The student of a script.
create function pg_temp.stud(p_script uuid) returns uuid language sql stable as $$
  select b.student_id from public.scripts s join public.bookings b on b.id = s.booking_id where s.id = p_script $$;
-- A marking unit of a script, taken by a marker with an open assignment (no time limit, as an admin gives it).
create function pg_temp.taken(p_script uuid, p_marker text) returns uuid language plpgsql as $$
declare v_u uuid;
begin
  insert into public.marking_units (script_id, exam_id, state) select s.id, s.exam_id, 'taken' from public.scripts s where s.id = p_script
  returning id into v_u;
  insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by) values (v_u, 'live', pg_temp.uid(p_marker), 'assigned', pg_temp.uid('admin'));
  insert into public.markings (unit_id, kind, marker_id) values (v_u, 'live', pg_temp.uid(p_marker));
  return v_u;
end $$;
-- A unit a marker has submitted: its assignment ended, its marking submitted.
create function pg_temp.done(p_script uuid, p_marker text) returns uuid language plpgsql as $$
declare v_u uuid;
begin
  insert into public.marking_units (script_id, exam_id, state) select s.id, s.exam_id, 'submitted' from public.scripts s where s.id = p_script
  returning id into v_u;
  insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by, ended_at, end_reason)
  values (v_u, 'live', pg_temp.uid(p_marker), 'assigned', pg_temp.uid('admin'), now(), 'submitted');
  insert into public.markings (unit_id, kind, marker_id, status, submitted_at) values (v_u, 'live', pg_temp.uid(p_marker), 'submitted', now());
  return v_u;
end $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.r(text), pg_temp.subj(text), pg_temp.stud(uuid),
  pg_temp.taken(uuid, text), pg_temp.done(uuid, text) to public;

insert into public.subjects (name, kind) values ('ZZ Markers', 'school'), ('ZZ Markers other', 'school');
insert into public.teacher_subjects values (pg_temp.uid('teacher'), pg_temp.subj('subj'));
update public.profiles set first_name = 'Mina', last_name = 'Marker' where id = pg_temp.uid('m1');
insert into kv values ('e', tests.marking_exam(pg_temp.subj('subj')));
insert into kv values ('e2', tests.marking_exam(pg_temp.subj('subj2')));
insert into kv values ('sa', tests.verified_script(pg_temp.k('e')));
insert into kv values ('sb', tests.verified_script(pg_temp.k('e')));
insert into kv values ('sc', tests.verified_script(pg_temp.k('e')));
insert into kv values ('sd', tests.verified_script(pg_temp.k('e')));
insert into kv values ('se', tests.verified_script(pg_temp.k('e2')));
update public.student_details set index_number = 'SE-2099-7001' where profile_id = pg_temp.stud(pg_temp.k('sa'));
update public.profiles set first_name = 'Zebediah', last_name = 'Quill' where id = pg_temp.stud(pg_temp.k('sb'));
insert into kv values ('ua', pg_temp.taken(pg_temp.k('sa'), 'm1'));
insert into kv values ('ue', pg_temp.taken(pg_temp.k('se'), 'm1'));
insert into kv values ('ub', pg_temp.done(pg_temp.k('sb'), 'm1'));
insert into kv values ('uc', pg_temp.taken(pg_temp.k('sc'), 'm2'));
insert into kv values ('ud', pg_temp.done(pg_temp.k('sd'), 'm2'));

-- ---------------------------------------------------------------------------------------------
-- corrector_approved_for_any_subject
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('ap1', public.marker_approve(pg_temp.uid('m1'), pg_temp.subj('subj'), 'Marks maths for us'));
insert into res values ('ap2', public.marker_approve(pg_temp.uid('m1'), pg_temp.subj('subj2'), 'Marks physics for us'));
select is(pg_temp.r('ap1') ->> 'ok', 'true', 'corrector_approved_for_any_subject: approved for the first subject');
select is(pg_temp.r('ap2') ->> 'ok', 'true', 'and for another, which no teaching link is needed for');
select tests.as_postgres();
select is((select count(*)::int from public.marker_approvals where marker_id = pg_temp.uid('m1') and approved_by = pg_temp.uid('admin')),
  2, 'both approvals are recorded with who gave them');
select tests.as_user(pg_temp.uid('admin'));
select is(public.marker_approve(pg_temp.uid('m1'), pg_temp.subj('subj'), 'Again, in error') ->> 'ok', 'true', 'approving twice is allowed');
select tests.as_postgres();
select is((select count(*)::int from public.marker_approvals where marker_id = pg_temp.uid('m1')), 2, 'and adds nothing');

-- ---------------------------------------------------------------------------------------------
-- teacher_only_for_subjects_they_teach
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(public.marker_approve(pg_temp.uid('teacher'), pg_temp.subj('subj'), 'Teaches it') ->> 'ok', 'true',
  'teacher_only_for_subjects_they_teach: a teacher is approved for a subject they teach');
select is(public.marker_approve(pg_temp.uid('teacher'), pg_temp.subj('subj2'), 'Does not teach it') ->> 'code', 'not_approved',
  'but not for one they do not teach');
select is(public.marker_approve(pg_temp.uid('teacher2'), pg_temp.subj('subj'), 'Teaches nothing') ->> 'code', 'not_approved',
  'nor a teacher with no subjects');

-- ---------------------------------------------------------------------------------------------
-- tutor_student_parent_cannot_be_approved, suspended_account_cannot_be_approved
-- ---------------------------------------------------------------------------------------------
select is(public.marker_approve(pg_temp.uid('tutor'), pg_temp.subj('subj'), 'A tutor') ->> 'code', 'not_approved',
  'tutor_student_parent_cannot_be_approved: a tutor');
select is(public.marker_approve(pg_temp.uid('stu'), pg_temp.subj('subj'), 'A student') ->> 'code', 'not_approved', 'a student');
select is(public.marker_approve(pg_temp.uid('parent'), pg_temp.subj('subj'), 'A parent') ->> 'code', 'not_approved', 'a parent');
select is(public.marker_approve(pg_temp.uid('admin'), pg_temp.subj('subj'), 'An admin') ->> 'code', 'not_approved', 'an admin');
select is(public.marker_approve(pg_temp.uid('susp'), pg_temp.subj('subj'), 'Suspended') ->> 'code', 'not_approved',
  'suspended_account_cannot_be_approved: a suspended corrector');
select is(public.marker_approve(gen_random_uuid(), pg_temp.subj('subj'), 'Nobody') ->> 'code', 'not_found', 'an account that does not exist is not found');
select is(public.marker_approve(pg_temp.uid('m3'), -1, 'No subject') ->> 'code', 'not_found', 'and so is a subject that does not exist');
select tests.as_postgres();
select is((select count(*)::int from public.marker_approvals where marker_id in (select id from c where name in ('tutor', 'stu', 'parent', 'admin', 'susp', 'm3', 'teacher2'))),
  0, 'none of those refused got an approval');
select is((select count(*)::int from public.marker_approvals where marker_id = pg_temp.uid('teacher')), 1, 'the teacher has the one approval');

-- ---------------------------------------------------------------------------------------------
-- lead_must_be_approved_and_replaces_the_earlier_lead
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select public.marker_approve(pg_temp.uid('m2'), pg_temp.subj('subj'), 'Second marker');
select is(public.marker_set_lead(pg_temp.subj('subj'), pg_temp.uid('m3'), 'Not approved') ->> 'code', 'not_approved',
  'lead_must_be_approved_and_replaces_the_earlier_lead: a marker not approved for the subject cannot lead it');
select is(public.marker_set_lead(pg_temp.subj('subj'), pg_temp.uid('m1'), 'Most experienced') ->> 'ok', 'true', 'an approved marker becomes lead');
select is((select string_agg(marker_id::text, ',') from public.marker_approvals where subject_id = pg_temp.subj('subj') and lead),
  pg_temp.uid('m1')::text, 'the lead is m1');
select is(public.marker_set_lead(pg_temp.subj('subj'), pg_temp.uid('m2'), 'New lead') ->> 'ok', 'true', 'another is made lead');
select is((select string_agg(marker_id::text, ',') from public.marker_approvals where subject_id = pg_temp.subj('subj') and lead),
  pg_temp.uid('m2')::text, 'the earlier lead lost the flag; one lead only');
select is((select count(*)::int from public.marker_approvals where marker_id = pg_temp.uid('m1') and subject_id = pg_temp.subj('subj')), 1,
  'the earlier lead is still approved');
select is((select s ->> 'lead_id' from jsonb_array_elements(public.markers_list() -> 'subjects') s where (s ->> 'id')::bigint = pg_temp.subj('subj')),
  pg_temp.uid('m2')::text, 'the list shows the lead of the subject');
select is(public.marker_set_lead(pg_temp.subj('subj'), null, 'No lead for now') ->> 'ok', 'true', 'a null marker clears the lead');
select is((select count(*)::int from public.marker_approvals where subject_id = pg_temp.subj('subj') and lead), 0, 'no lead remains');
select public.marker_set_lead(pg_temp.subj('subj'), pg_temp.uid('m2'), 'Lead again');

-- ---------------------------------------------------------------------------------------------
-- unapprove_releases_open_pieces_and_keeps_submitted
-- ---------------------------------------------------------------------------------------------
insert into res values ('un', public.marker_unapprove(pg_temp.uid('m1'), pg_temp.subj('subj'), 'Left the panel'));
select is(pg_temp.r('un')::text, '{"ok": true, "released": 1}', 'unapprove_releases_open_pieces_and_keeps_submitted: one open piece released');
select tests.as_postgres();
select is((select concat_ws('/', a.end_reason, (a.ended_at is not null)::text) from public.marking_assignments a where a.unit_id = pg_temp.k('ua')),
  'unapproved/true', 'its assignment ended as unapproved');
select is((select state from public.marking_units where id = pg_temp.k('ua')), 'open', 'its unit is open again');
select is((select status from public.markings where unit_id = pg_temp.k('ua')), 'in_progress', 'the in-progress marking is left as it is');
select is((select count(*)::int from public.marking_assignments where unit_id = pg_temp.k('ue') and ended_at is null), 1,
  'the marker''s open piece of another subject is kept');
select is((select state from public.marking_units where id = pg_temp.k('ue')), 'taken', 'and its unit stays taken');
select is((select concat_ws('/', m.status, a.end_reason) from public.markings m join public.marking_assignments a on a.unit_id = m.unit_id where m.unit_id = pg_temp.k('ub')),
  'submitted/submitted', 'the submitted marking and its assignment stay as they were');
select is((select count(*)::int from public.marker_approvals where marker_id = pg_temp.uid('m1') and subject_id = pg_temp.subj('subj')), 0, 'the approval is gone');
select is((select count(*)::int from public.marker_approvals where marker_id = pg_temp.uid('m1') and subject_id = pg_temp.subj('subj2')), 1, 'the other subject''s approval stays');
select tests.as_user(pg_temp.uid('admin'));
select is(public.marker_unapprove(pg_temp.uid('m1'), pg_temp.subj('subj'), 'Once more') ->> 'code', 'not_found', 'removing an approval that is not there is not found');
-- A lead who is unapproved is no longer lead.
select public.marker_approve(pg_temp.uid('m3'), pg_temp.subj('subj'), 'Joins the panel');
select public.marker_set_lead(pg_temp.subj('subj'), pg_temp.uid('m3'), 'Lead for now');
select is(public.marker_unapprove(pg_temp.uid('m3'), pg_temp.subj('subj'), 'Lead leaves') ->> 'ok', 'true', 'the lead can be unapproved');
select is((select count(*)::int from public.marker_approvals where subject_id = pg_temp.subj('subj') and lead), 0, 'and with the approval the lead flag goes');

-- ---------------------------------------------------------------------------------------------
-- conflict_releases_open_pieces_and_counts_marked
-- ---------------------------------------------------------------------------------------------
insert into res values ('cf1', public.marker_conflict_set(pg_temp.uid('m2'), pg_temp.stud(pg_temp.k('sc')), 'Is their cousin', 'Declared by the family'));
select is(pg_temp.r('cf1')::text, '{"ok": true, "released": 1, "already_marked": 0}',
  'conflict_releases_open_pieces_and_counts_marked: one open piece released, none already marked');
select tests.as_postgres();
select is((select concat_ws('/', a.end_reason, u.state) from public.marking_assignments a join public.marking_units u on u.id = a.unit_id where a.unit_id = pg_temp.k('uc')),
  'conflict/open', 'the assignment ended as conflict and its unit is open');
select is((select note from public.marker_conflicts where marker_id = pg_temp.uid('m2') and student_id = pg_temp.stud(pg_temp.k('sc'))), 'Is their cousin',
  'the conflict and its note are recorded');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('cf2', public.marker_conflict_set(pg_temp.uid('m2'), pg_temp.stud(pg_temp.k('sd')), null, 'Found out later'));
select is(pg_temp.r('cf2')::text, '{"ok": true, "released": 0, "already_marked": 1}', 'a candidate the marker has already marked is counted');
select tests.as_postgres();
select is((select status from public.markings where unit_id = pg_temp.k('ud')), 'submitted', 'and that marking is left for an admin to take back');
select tests.as_user(pg_temp.uid('admin'));
select is(public.marker_conflict_set(pg_temp.uid('m2'), pg_temp.stud(pg_temp.k('sc')), 'Is their sister', 'Corrected the note') ->> 'ok', 'true',
  'declaring it again updates the note');
select is((select count(*)::int || '/' || min(note) from public.marker_conflicts where marker_id = pg_temp.uid('m2') and student_id = pg_temp.stud(pg_temp.k('sc'))),
  '1/Is their sister', 'one row with the new note');
select is(public.marker_conflict_set(pg_temp.uid('m2'), pg_temp.uid('parent'), null, 'Not a student') ->> 'code', 'invalid_input', 'the candidate must be a student');
select is(public.marker_conflict_set(pg_temp.uid('stu'), pg_temp.stud(pg_temp.k('sc')), null, 'Not a marker') ->> 'code', 'not_found', 'the marker must be a corrector or teacher');

-- ---------------------------------------------------------------------------------------------
-- conflict_note_over_300_refused
-- ---------------------------------------------------------------------------------------------
select is(public.marker_conflict_set(pg_temp.uid('m3'), pg_temp.stud(pg_temp.k('sc')), repeat('n', 301), 'Long note') ->> 'code', 'invalid_input',
  'conflict_note_over_300_refused: a note of 301 characters');
select is(public.marker_conflict_set(pg_temp.uid('m3'), pg_temp.stud(pg_temp.k('sc')), repeat('n', 300), 'Long note') ->> 'ok', 'true', 'a note of 300 is allowed');

-- Remove, and search.
select is(public.marker_conflict_remove(pg_temp.uid('m3'), pg_temp.stud(pg_temp.k('sc')), 'Not related after all') ->> 'ok', 'true', 'a conflict is removed');
select is(public.marker_conflict_remove(pg_temp.uid('m3'), pg_temp.stud(pg_temp.k('sc')), 'Again') ->> 'code', 'not_found', 'removing one that is not there is not found');
select is((select jsonb_array_length(public.marker_conflict_candidates('se 2099 7001') -> 'candidates')), 1, 'a candidate is found by index number, spaces and case ignored');
select is(public.marker_conflict_candidates('SE-2099-7001') -> 'candidates' -> 0 ->> 'id', pg_temp.stud(pg_temp.k('sa'))::text, 'and it is the right student');
select is(public.marker_conflict_candidates('zebediah quill') -> 'candidates' -> 0 ->> 'id', pg_temp.stud(pg_temp.k('sb'))::text, 'or by name');
select is(public.marker_conflict_candidates('x') ->> 'code', 'invalid_input', 'a search of under two characters is refused');
select is((select count(*)::int from jsonb_array_elements(public.markers_list() -> 'markers') m where m ->> 'id' in (select id::text from c where name in ('admin', 'tutor', 'parent', 'stu'))),
  0, 'the list holds correctors and teachers only');
select is((select count(*)::int from jsonb_array_elements(public.markers_list() -> 'markers') m where m ->> 'id' = pg_temp.uid('susp')::text), 1, 'a suspended corrector is listed');
select is((select jsonb_array_length(m -> 'conflicts') from jsonb_array_elements(public.markers_list() -> 'markers') m where m ->> 'id' = pg_temp.uid('m2')::text), 2,
  'the list shows the declared conflicts');

-- ---------------------------------------------------------------------------------------------
-- reason_required, each_action_writes_audit_with_reason
-- ---------------------------------------------------------------------------------------------
select tests.as_postgres();
create temp table audit_before as select count(*)::int n from public.audit_log where action like 'marker\_%' escape '\';
grant select on audit_before to public;
select tests.as_user(pg_temp.uid('admin'));
select is(public.marker_approve(pg_temp.uid('m3'), pg_temp.subj('subj'), 'no') ->> 'code', 'reason_required', 'reason_required: approve with a short reason');
select is(public.marker_unapprove(pg_temp.uid('m2'), pg_temp.subj('subj'), null) ->> 'code', 'reason_required', 'unapprove with none');
select is(public.marker_set_lead(pg_temp.subj('subj'), pg_temp.uid('m2'), '  ') ->> 'code', 'reason_required', 'set lead with blanks');
select is(public.marker_conflict_set(pg_temp.uid('m3'), pg_temp.stud(pg_temp.k('sa')), null, repeat('r', 301)) ->> 'code', 'reason_required', 'conflict with a reason over 300');
select is(public.marker_conflict_remove(pg_temp.uid('m2'), pg_temp.stud(pg_temp.k('sc')), 'x') ->> 'code', 'reason_required', 'remove a conflict with a short reason');
select tests.as_postgres();
select is((select count(*)::int from public.audit_log where action like 'marker\_%' escape '\') - (select n from audit_before), 0, 'none of the refused calls wrote an audit row');
select tests.as_user(pg_temp.uid('admin'));
select public.marker_approve(pg_temp.uid('m4'), pg_temp.subj('subj'), 'Audited approval');
select public.marker_unapprove(pg_temp.uid('m4'), pg_temp.subj('subj'), 'Audited removal');
select public.marker_approve(pg_temp.uid('m4'), pg_temp.subj('subj'), 'Audited approval again');
select public.marker_set_lead(pg_temp.subj('subj'), pg_temp.uid('m4'), 'Audited lead');
select public.marker_conflict_set(pg_temp.uid('m4'), pg_temp.stud(pg_temp.k('sa')), null, 'Audited conflict');
select public.marker_conflict_remove(pg_temp.uid('m4'), pg_temp.stud(pg_temp.k('sa')), 'Audited conflict removal');
select tests.as_postgres();
select is((select string_agg(action || ':' || reason, ' | ' order by id) from public.audit_log
           where target_id = pg_temp.uid('m4') and action like 'marker\_%' escape '\' and actor_id = pg_temp.uid('admin')),
  'marker_approved:Audited approval (subject: ZZ Markers) | marker_unapproved:Audited removal (subject: ZZ Markers) | '
  || 'marker_approved:Audited approval again (subject: ZZ Markers) | marker_lead_set:Audited lead (subject: ZZ Markers) | '
  || 'marker_conflict_set:Audited conflict (candidate: SE-2099-7001) | marker_conflict_removed:Audited conflict removal (candidate: SE-2099-7001)',
  'each_action_writes_audit_with_reason: each action wrote its row with the reason');

-- ---------------------------------------------------------------------------------------------
-- non_admin_forbidden
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('teacher'));
select is(public.marker_approve(pg_temp.uid('m3'), pg_temp.subj('subj'), 'Teacher tries') ->> 'code', 'forbidden', 'non_admin_forbidden: a teacher cannot approve');
select is(public.markers_list() ->> 'code', 'forbidden', 'or list the markers');
select is(public.marker_conflict_candidates('se 2099') ->> 'code', 'forbidden', 'or search candidates');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('m2'));
select is(public.marker_set_lead(pg_temp.subj('subj'), pg_temp.uid('m2'), 'Lead makes themselves') ->> 'code', 'forbidden', 'a corrector, even lead, cannot set the lead');
select is(public.marker_unapprove(pg_temp.uid('m3'), pg_temp.subj('subj'), 'Corrector tries') ->> 'code', 'forbidden', 'or remove an approval');
select is(public.marker_conflict_set(pg_temp.uid('m2'), pg_temp.stud(pg_temp.k('sc')), null, 'Corrector tries') ->> 'code', 'forbidden', 'or declare a conflict');
select is(public.marker_conflict_remove(pg_temp.uid('m2'), pg_temp.stud(pg_temp.k('sc')), 'Corrector tries') ->> 'code', 'forbidden', 'or remove one');
select tests.as_postgres();
select is((select count(*)::int from public.marker_conflicts where marker_id = pg_temp.uid('m2')), 2, 'and nothing changed');

select * from finish();
rollback;
