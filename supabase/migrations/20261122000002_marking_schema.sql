-- Phase 3A Task 1: the marking tables, their internal predicates and the mark scheme bucket.
--
-- An exam's structure (questions, parts, marking points, question groups, optional questions) and its marking settings;
-- the markers approved per subject, one lead marker per subject, and declared conflicts; the units a script is marked
-- in (the whole script, or one question group of it), the markings (one marker's pass on a unit, of a kind), who
-- holds a unit, the marks, their history, the annotations on the pages, and alerts for the lead marker and admins.
--
-- Nothing here is written by a signed-in user directly: later tasks add security definer functions for every write
-- and every marker-facing read. Markers have no table access that returns rows: like the script tables, each table
-- grants select to authenticated under one policy, staff admins only.
--
-- A marking carries a kind, so Phase 3B adds second, seed, practice and re-mark passes without new tables. The unique
-- indexes are per unit and kind: one live (second, re-mark) marking per unit unless set aside, and one open
-- assignment per unit and kind.
--
-- Also: scripts.taken_back_at, taken_back_by and taken_back_reason (Task 7 takes a script back from marking). No
-- earlier function is changed.

create type public.marking_kind as enum ('live', 'second', 'seed', 'practice', 'remark');
create type public.marking_mode as enum ('whole', 'by_question');

-- ---------------------------------------------------------------------------------------------
-- Structure.
-- ---------------------------------------------------------------------------------------------

-- An exam's marking settings. structure_version goes up by one at every structure save.
create table public.exam_marking (
  exam_id uuid primary key references public.exams (id) on delete cascade,
  mode public.marking_mode not null default 'whole',
  deadline timestamptz,
  structure_version int not null default 0,
  opened_at timestamptz,
  opened_by uuid,
  closed_at timestamptz,
  closed_by uuid,
  updated_at timestamptz not null default now()
);

-- Question groups: the units of an exam marked by question.
create table public.question_groups (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null,
  label text not null check (char_length(label) between 1 and 40),
  position int not null,
  unique (exam_id, label)
);

-- Optional questions: "Answer {choose} of these".
create table public.exam_option_groups (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null,
  label text not null check (char_length(label) between 1 and 60),
  choose int not null check (choose >= 1)
);
create index exam_option_groups_exam_idx on public.exam_option_groups (exam_id);

-- Questions and their parts. A question with parts has no max_mark; a leaf has one.
create table public.exam_questions (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.exams (id) on delete cascade,
  parent_id uuid references public.exam_questions (id) on delete cascade,
  label text not null check (char_length(label) between 1 and 20),
  position int not null,
  max_mark numeric(5,1) check (max_mark between 0.5 and 100),
  mark_step numeric(2,1) not null default 1 check (mark_step in (0.5, 1)),
  levels boolean not null default false,
  pages int[] not null default '{}',
  areas jsonb not null default '[]',
  group_id uuid references public.question_groups (id),
  option_group_id uuid references public.exam_option_groups (id),
  guidance text check (char_length(guidance) <= 4000),
  alternatives text check (char_length(alternatives) <= 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index exam_questions_exam_idx on public.exam_questions (exam_id);
create index exam_questions_parent_idx on public.exam_questions (parent_id) where parent_id is not null;

-- Marking points of a question. marks_to set makes a level band marks..marks_to.
create table public.mark_scheme_points (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.exam_questions (id) on delete cascade,
  position int not null,
  label text check (char_length(label) <= 12),
  marks numeric(4,1) not null,
  marks_to numeric(4,1),
  text text not null check (char_length(text) between 1 and 500)
);
create index mark_scheme_points_question_idx on public.mark_scheme_points (question_id);

-- The mark scheme PDF, in the private bucket mark-schemes at <exam>/<file id>.pdf.
create table public.exam_mark_scheme_files (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null,
  storage_path text unique not null,
  byte_size bigint not null check (byte_size between 1 and 20971520),
  state text not null default 'pending' check (state in ('pending', 'stored', 'removed')),
  uploaded_by uuid not null,
  uploaded_at timestamptz,
  removed_at timestamptz,
  constraint exam_mark_scheme_files_path check (storage_path = exam_id::text || '/' || id::text || '.pdf')
);
create index exam_mark_scheme_files_exam_idx on public.exam_mark_scheme_files (exam_id);

-- ---------------------------------------------------------------------------------------------
-- Markers.
-- ---------------------------------------------------------------------------------------------

-- Who may mark a subject; lead marks the subject's one lead marker.
create table public.marker_approvals (
  marker_id uuid references public.profiles (id) on delete cascade,
  subject_id bigint references public.subjects (id),
  lead boolean not null default false,
  approved_by uuid,
  approved_at timestamptz not null,
  primary key (marker_id, subject_id)
);
create unique index marker_approvals_one_lead on public.marker_approvals (subject_id) where lead;
create index marker_approvals_subject_idx on public.marker_approvals (subject_id);

-- A candidate a marker must never mark.
create table public.marker_conflicts (
  marker_id uuid references public.profiles (id) on delete cascade,
  student_id uuid references public.profiles (id) on delete cascade,
  note text check (char_length(note) <= 300),
  recorded_by uuid,
  recorded_at timestamptz not null,
  primary key (marker_id, student_id)
);
create index marker_conflicts_student_idx on public.marker_conflicts (student_id);

-- ---------------------------------------------------------------------------------------------
-- Marking.
-- ---------------------------------------------------------------------------------------------

-- What is handed out: a whole script (group_id null) or one question group of it. state is the live pass's.
create table public.marking_units (
  id uuid primary key default gen_random_uuid(),
  script_id uuid not null references public.scripts (id),
  exam_id uuid not null,
  group_id uuid references public.question_groups (id),
  state text not null default 'open' check (state in ('open', 'taken', 'submitted')),
  on_hold boolean not null default false,
  hold_reason text check (hold_reason in ('picture_changed', 'picture_missing', 'name_visible', 'taken_back', 'withdrawn')),
  created_at timestamptz not null default now(),
  unique nulls not distinct (script_id, group_id)
);
create index marking_units_exam_state_idx on public.marking_units (exam_id, state);

-- A marker "Next script" does not offer this unit to again (they saw a name on it).
create table public.marking_unit_exclusions (
  unit_id uuid references public.marking_units (id),
  marker_id uuid,
  reason text not null check (reason in ('name_seen')),
  created_at timestamptz not null default now(),
  primary key (unit_id, marker_id)
);

-- One marker's pass on a unit. rev counts saves (a stale screen's save is refused).
create table public.markings (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references public.marking_units (id),
  kind public.marking_kind not null default 'live',
  marker_id uuid not null references public.profiles (id),
  status text not null default 'in_progress' check (status in ('in_progress', 'submitted', 'set_aside')),
  rev int not null default 0,
  structure_version int,
  total numeric(6,1),
  lead_note text check (char_length(lead_note) <= 1000),
  active_seconds int not null default 0,
  pages_key text,
  pages_changed_at timestamptz,
  started_at timestamptz not null default now(),
  last_saved_at timestamptz,
  submitted_at timestamptz,
  set_aside_at timestamptz,
  set_aside_reason text,
  unique (unit_id, kind, marker_id)
);
-- Never marked twice by mistake: one standing live (second, re-mark) marking per unit. Seed and practice passes may
-- have many markers.
create unique index markings_one_per_unit_kind on public.markings (unit_id, kind)
  where status <> 'set_aside' and kind in ('live', 'second', 'remark');
create index markings_marker_idx on public.markings (marker_id);

-- Who holds a unit, for a pass. hold_until is null for a unit an admin assigned (no time limit).
create table public.marking_assignments (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references public.marking_units (id),
  kind public.marking_kind not null default 'live',
  marker_id uuid not null references public.profiles (id),
  how text not null check (how in ('next', 'assigned')),
  assigned_by uuid,
  hold_until timestamptz,
  created_at timestamptz not null default now(),
  ended_at timestamptz,
  end_reason text check (end_reason in ('submitted', 'expired', 'given_back', 'taken_back', 'name_seen', 'unapproved', 'conflict', 'withdrawn'))
);
-- Never two holders of a unit for the same pass.
create unique index marking_assignments_one_holder on public.marking_assignments (unit_id, kind) where ended_at is null;
create index marking_assignments_marker_idx on public.marking_assignments (marker_id) where ended_at is null;

-- A marking's mark for a leaf question. "No response" (NR) is not_attempted, not a zero.
create table public.question_marks (
  marking_id uuid references public.markings (id),
  question_id uuid references public.exam_questions (id),
  mark numeric(5,1),
  not_attempted boolean not null default false,
  source text not null default 'marker' check (source in ('marker')),
  updated_at timestamptz not null default now(),
  primary key (marking_id, question_id),
  check (not (not_attempted and mark is not null))
);
create index question_marks_question_idx on public.question_marks (question_id);

-- Every mark as it was set: who, when, and (after submit) why.
create table public.question_mark_history (
  id bigint generated always as identity primary key,
  marking_id uuid not null,
  question_id uuid not null,
  mark numeric(5,1),
  not_attempted boolean not null,
  source text not null,
  changed_by uuid not null,
  changed_at timestamptz not null,
  after_submit boolean not null,
  reason text
);
create index question_mark_history_marking_idx on public.question_mark_history (marking_id, question_id);

-- Marks drawn on a page, x and y as fractions of the page. page_id has no foreign key on purpose: a page row replaced
-- after a take-back may be deleted by Phase 2; the annotation stays as a record and is not shown. Deleting an
-- annotation sets deleted_at.
create table public.page_annotations (
  id uuid primary key default gen_random_uuid(),
  marking_id uuid not null references public.markings (id),
  page_id uuid not null,
  page_rotation int not null,
  kind text not null check (kind in ('tick', 'cross', 'error', 'caret', 'XP', 'SEEN', 'SF', 'TE', 'BP', 'AE', 'ECF', 'L1', 'L2', 'L3',
                                     'POT', 'BOD', 'CON', 'pen', 'highlight', 'text', 'ruler')),
  x numeric not null check (x between 0 and 1),
  y numeric not null check (y between 0 and 1),
  points jsonb,
  text text check (char_length(text) <= 500),
  question_id uuid,
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index page_annotations_marking_page_idx on public.page_annotations (marking_id, page_id) where deleted_at is null;

-- What the lead marker and admins are told about a script being marked. One open alert per script and kind.
create table public.marking_alerts (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null,
  kind text not null check (kind in ('picture_changed', 'picture_missing', 'name_visible', 'pages_set_aside', 'pages_changed')),
  script_id uuid not null,
  unit_id uuid,
  page_id uuid,
  state text not null default 'open' check (state in ('open', 'closed')),
  created_at timestamptz not null default now(),
  closed_by uuid,
  closed_at timestamptz,
  resolution text check (resolution in ('released', 'handed_back', 'noted')),
  reason text
);
create unique index marking_alerts_one_open on public.marking_alerts (script_id, kind) where state = 'open';
create index marking_alerts_exam_state_idx on public.marking_alerts (exam_id, state);

-- A script taken back from marking (Task 7).
alter table public.scripts
  add column taken_back_at timestamptz,
  add column taken_back_by uuid,
  add column taken_back_reason text;

-- ---------------------------------------------------------------------------------------------
-- Access: staff admins read; nobody but definer functions and the service role writes.
-- ---------------------------------------------------------------------------------------------
alter table public.exam_marking enable row level security;
alter table public.question_groups enable row level security;
alter table public.exam_option_groups enable row level security;
alter table public.exam_questions enable row level security;
alter table public.mark_scheme_points enable row level security;
alter table public.exam_mark_scheme_files enable row level security;
alter table public.marker_approvals enable row level security;
alter table public.marker_conflicts enable row level security;
alter table public.marking_units enable row level security;
alter table public.marking_unit_exclusions enable row level security;
alter table public.markings enable row level security;
alter table public.marking_assignments enable row level security;
alter table public.question_marks enable row level security;
alter table public.question_mark_history enable row level security;
alter table public.page_annotations enable row level security;
alter table public.marking_alerts enable row level security;

revoke all on public.exam_marking, public.question_groups, public.exam_option_groups, public.exam_questions,
  public.mark_scheme_points, public.exam_mark_scheme_files, public.marker_approvals, public.marker_conflicts,
  public.marking_units, public.marking_unit_exclusions, public.markings, public.marking_assignments, public.question_marks,
  public.question_mark_history, public.page_annotations, public.marking_alerts
  from anon, authenticated;
revoke all on sequence public.question_mark_history_id_seq from anon, authenticated;
grant select on public.exam_marking, public.question_groups, public.exam_option_groups, public.exam_questions,
  public.mark_scheme_points, public.exam_mark_scheme_files, public.marker_approvals, public.marker_conflicts,
  public.marking_units, public.marking_unit_exclusions, public.markings, public.marking_assignments, public.question_marks,
  public.question_mark_history, public.page_annotations, public.marking_alerts
  to authenticated;

create policy exam_marking_select on public.exam_marking for select to authenticated using ((select public.is_staff_admin()));
create policy question_groups_select on public.question_groups for select to authenticated using ((select public.is_staff_admin()));
create policy exam_option_groups_select on public.exam_option_groups for select to authenticated using ((select public.is_staff_admin()));
create policy exam_questions_select on public.exam_questions for select to authenticated using ((select public.is_staff_admin()));
create policy mark_scheme_points_select on public.mark_scheme_points for select to authenticated using ((select public.is_staff_admin()));
create policy exam_mark_scheme_files_select on public.exam_mark_scheme_files for select to authenticated using ((select public.is_staff_admin()));
create policy marker_approvals_select on public.marker_approvals for select to authenticated using ((select public.is_staff_admin()));
create policy marker_conflicts_select on public.marker_conflicts for select to authenticated using ((select public.is_staff_admin()));
create policy marking_units_select on public.marking_units for select to authenticated using ((select public.is_staff_admin()));
create policy marking_unit_exclusions_select on public.marking_unit_exclusions for select to authenticated using ((select public.is_staff_admin()));
create policy markings_select on public.markings for select to authenticated using ((select public.is_staff_admin()));
create policy marking_assignments_select on public.marking_assignments for select to authenticated using ((select public.is_staff_admin()));
create policy question_marks_select on public.question_marks for select to authenticated using ((select public.is_staff_admin()));
create policy question_mark_history_select on public.question_mark_history for select to authenticated using ((select public.is_staff_admin()));
create policy page_annotations_select on public.page_annotations for select to authenticated using ((select public.is_staff_admin()));
create policy marking_alerts_select on public.marking_alerts for select to authenticated using ((select public.is_staff_admin()));

-- The mark scheme PDF has its own private bucket (Builder's call 18), so nothing built for papers can hand it to a
-- family. Its storage policies come with the upload functions (Task 2).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('mark-schemes', 'mark-schemes', false, 20971520, array['application/pdf'])
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- ---------------------------------------------------------------------------------------------
-- Internal predicates (definer callers only).
-- ---------------------------------------------------------------------------------------------

-- An active corrector or teacher approved to mark the subject.
create function public.is_marker_for(p_user uuid, p_subject bigint)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    join public.marker_approvals a on a.marker_id = p.id
    where p.id = p_user and p.status = 'active' and p.role in ('corrector', 'teacher') and a.subject_id = p_subject)
$$;

-- The subject's lead marker (an active approved marker with the lead flag).
create function public.is_lead_for(p_user uuid, p_subject bigint)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    join public.marker_approvals a on a.marker_id = p.id
    where p.id = p_user and p.status = 'active' and p.role in ('corrector', 'teacher') and a.subject_id = p_subject and a.lead)
$$;

-- Who may enter an exam's questions and mark scheme: an active owner or admin, or an active teacher of its subject.
create function public.structure_can_edit(p_user uuid, p_exam uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select public.attendance_can_manage(p_user, e.subject_id) from public.exams e where e.id = p_exam), false)
$$;

-- A marker must not mark this candidate: a declared conflict, or the marker is linked to them as their tutor.
create function public.marking_marker_blocked(p_marker uuid, p_student uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.marker_conflicts c where c.marker_id = p_marker and c.student_id = p_student)
      or exists (select 1 from public.tutor_students t where t.tutor_id = p_marker and t.student_id = p_student)
$$;

revoke execute on function public.is_marker_for(uuid, bigint) from public, anon, authenticated;
revoke execute on function public.is_lead_for(uuid, bigint) from public, anon, authenticated;
revoke execute on function public.structure_can_edit(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.marking_marker_blocked(uuid, uuid) from public, anon, authenticated;
