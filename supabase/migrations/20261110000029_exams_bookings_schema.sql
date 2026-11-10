-- Part 2 Task 1: exams, venues, bookings, attendance, row-level security, public timetable view.
-- Clients never write these tables; all writes go through definer functions / Edge Functions (later tasks).

create type public.exam_format as enum ('in_person', 'online');
create type public.exam_status as enum ('draft', 'published', 'cancelled', 'completed');
create type public.booking_status as enum
  ('awaiting_payment', 'paid', 'cancel_requested', 'refunded', 'part_refunded', 'cancelled', 'expired');
create type public.attendance_status as enum ('present', 'late', 'absent');

create table public.venues (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  rooms text[] not null default '{}',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.exams (
  id uuid primary key default gen_random_uuid(),
  subject_id bigint not null references public.subjects (id),
  title text not null,
  paper text not null,
  format public.exam_format not null,
  venue_id uuid references public.venues (id),
  room text,
  starts_at timestamptz not null,
  duration_minutes int not null check (duration_minutes > 0),
  seat_limit int not null check (seat_limit > 0),
  price_pence int not null check (price_pence >= 0),
  currency text not null default 'gbp' check (currency = 'gbp'),
  booking_deadline timestamptz not null,
  status public.exam_status not null default 'draft',
  created_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint exams_deadline_before_start check (booking_deadline <= starts_at),
  constraint exams_venue_matches_format check (
    (format = 'online' and venue_id is null)
    or (format = 'in_person' and venue_id is not null))
);
create index exams_subject_idx on public.exams (subject_id);
create index exams_status_starts_idx on public.exams (status, starts_at);

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.exams (id),
  student_id uuid not null references public.profiles (id),
  booked_by uuid not null references public.profiles (id),
  status public.booking_status not null,
  amount_pence int not null check (amount_pence >= 0),
  refunded_pence int not null default 0 check (refunded_pence >= 0),
  stripe_checkout_session_id text,
  stripe_payment_intent_id text,
  hold_expires_at timestamptz,
  paid_offline boolean not null default false,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index bookings_one_active_per_student_exam
  on public.bookings (exam_id, student_id)
  where status in ('awaiting_payment', 'paid', 'cancel_requested');
create index bookings_student_idx on public.bookings (student_id);
create index bookings_exam_idx on public.bookings (exam_id);

create table public.attendance (
  exam_id uuid not null references public.exams (id),
  student_id uuid not null references public.profiles (id),
  status public.attendance_status not null,
  marked_by uuid not null references public.profiles (id),
  marked_at timestamptz not null default now(),
  primary key (exam_id, student_id)
);
create index attendance_student_idx on public.attendance (student_id);

alter table public.venues enable row level security;
alter table public.exams enable row level security;
alter table public.bookings enable row level security;
alter table public.attendance enable row level security;

-- Seats taken: awaiting_payment, paid, cancel_requested. Definer so the owner-run public view can call it.
create function public.seats_taken(p_exam uuid)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int
  from public.bookings b
  where b.exam_id = p_exam
    and b.status in ('awaiting_payment', 'paid', 'cancel_requested')
$$;
revoke execute on function public.seats_taken(uuid) from public, anon, authenticated;
grant execute on function public.seats_taken(uuid) to authenticated, service_role;

-- Privileges: anon nothing; authenticated read-only; no client writes.
revoke all on public.venues, public.exams, public.bookings, public.attendance from anon, authenticated;
grant select on public.venues, public.exams, public.bookings, public.attendance to authenticated;

-- Exams: published for any non-suspended signed-in user; owner/admin all; teacher also drafts of own subjects.
create policy exams_select on public.exams for select to authenticated
using (
  (select public.my_role()) is not null
  and (
    status = 'published'
    or (select public.is_staff_admin())
    or (
      (select public.my_role()) = 'teacher'
      and exists (
        select 1 from public.teacher_subjects ts
        where ts.teacher_id = (select auth.uid()) and ts.subject_id = exams.subject_id)
    )
  )
);

create policy venues_select on public.venues for select to authenticated
using ((select public.my_role()) is not null);

-- Bookings / attendance share one visibility rule.
create policy bookings_select on public.bookings for select to authenticated
using (
  (select public.is_staff_admin())
  or (student_id = (select auth.uid()) and (select public.my_role()) = 'student')
  or (
    (select public.my_role()) = 'parent'
    and exists (
      select 1 from public.parent_children pc
      where pc.parent_id = (select auth.uid()) and pc.student_id = bookings.student_id)
  )
  or (
    (select public.my_role()) = 'tutor'
    and exists (
      select 1 from public.tutor_students ts
      where ts.tutor_id = (select auth.uid()) and ts.student_id = bookings.student_id)
  )
  or (
    (select public.my_role()) = 'teacher'
    and exists (
      select 1 from public.exams e
      join public.teacher_subjects tsub on tsub.subject_id = e.subject_id
      where e.id = bookings.exam_id and tsub.teacher_id = (select auth.uid()))
  )
);

create policy attendance_select on public.attendance for select to authenticated
using (
  (select public.is_staff_admin())
  or (student_id = (select auth.uid()) and (select public.my_role()) = 'student')
  or (
    (select public.my_role()) = 'parent'
    and exists (
      select 1 from public.parent_children pc
      where pc.parent_id = (select auth.uid()) and pc.student_id = attendance.student_id)
  )
  or (
    (select public.my_role()) = 'tutor'
    and exists (
      select 1 from public.tutor_students ts
      where ts.tutor_id = (select auth.uid()) and ts.student_id = attendance.student_id)
  )
  or (
    (select public.my_role()) = 'teacher'
    and exists (
      select 1 from public.exams e
      join public.teacher_subjects tsub on tsub.subject_id = e.subject_id
      where e.id = attendance.exam_id and tsub.teacher_id = (select auth.uid()))
  )
);

-- Public timetable: owned by postgres (bypasses RLS by design), published exams only, no personal data.
create view public.exams_public as
select
  e.id,
  s.name as subject,
  e.title,
  e.paper,
  e.format,
  v.name as venue,
  e.room,
  e.starts_at,
  e.duration_minutes,
  e.price_pence,
  e.booking_deadline,
  greatest(e.seat_limit - public.seats_taken(e.id), 0) as seats_left
from public.exams e
join public.subjects s on s.id = e.subject_id
left join public.venues v on v.id = e.venue_id
where e.status = 'published';

revoke all on public.exams_public from public, anon, authenticated;
grant select on public.exams_public to anon, authenticated;
