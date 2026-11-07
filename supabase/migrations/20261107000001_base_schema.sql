create extension if not exists citext with schema extensions;

create type public.app_role as enum
  ('owner', 'admin', 'teacher', 'tutor', 'corrector', 'student', 'parent');
create type public.account_status as enum
  ('unconfirmed', 'pending', 'profile_incomplete', 'active', 'suspended');
create type public.subject_kind as enum ('school', 'entrance');

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  role public.app_role not null,
  status public.account_status not null,
  first_name text not null default '',
  last_name text not null default '',
  email extensions.citext not null unique,
  invite_sent_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.student_details (
  profile_id uuid primary key references public.profiles (id) on delete cascade,
  date_of_birth date,
  school text,
  gender text,
  year_group text,
  index_number text unique,
  signup_parent_name text,
  signup_parent_email text,
  parent_phone text,
  photo_path text
);

create table public.subjects (
  id bigint generated always as identity primary key,
  name text not null unique,
  kind public.subject_kind not null,
  active boolean not null default true
);

create table public.student_subjects (
  student_id uuid not null references public.profiles (id) on delete cascade,
  subject_id bigint not null references public.subjects (id) on delete cascade,
  primary key (student_id, subject_id)
);

create table public.parent_children (
  parent_id uuid not null references public.profiles (id) on delete cascade,
  student_id uuid not null references public.profiles (id) on delete cascade,
  primary key (parent_id, student_id)
);

create table public.teacher_subjects (
  teacher_id uuid not null references public.profiles (id) on delete cascade,
  subject_id bigint not null references public.subjects (id) on delete cascade,
  primary key (teacher_id, subject_id)
);

create table public.tutor_students (
  tutor_id uuid not null references public.profiles (id) on delete cascade,
  student_id uuid not null references public.profiles (id) on delete cascade,
  primary key (tutor_id, student_id)
);

create table public.audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid,
  action text not null,
  target_type text,
  target_id uuid,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
alter table public.student_details enable row level security;
alter table public.subjects enable row level security;
alter table public.student_subjects enable row level security;
alter table public.parent_children enable row level security;
alter table public.teacher_subjects enable row level security;
alter table public.tutor_students enable row level security;
alter table public.audit_log enable row level security;

insert into public.subjects (name, kind) values
  ('Maths', 'school'), ('Further Maths', 'school'), ('Physics', 'school'),
  ('Chemistry', 'school'), ('Biology', 'school'), ('Computer Science', 'school'),
  ('TMUA', 'entrance'), ('FSAT', 'entrance'), ('UCAT', 'entrance')
on conflict (name) do nothing;
