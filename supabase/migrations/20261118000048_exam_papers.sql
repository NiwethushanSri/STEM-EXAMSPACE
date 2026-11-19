-- Phase 1A Task 5: question papers, personalised copies and timed release.
--
-- An admin uploads the paper once (private bucket exam-papers, <exam id>/<uuid>.pdf), then registers it here.
-- Every candidate's copy is a paper_copies row: booking + paper version + a random copy code, so downloading again
-- or reprinting gives the same codes. Edge Function paper-copy builds the PDF: it calls paper_copy_issue with the
-- caller's own JWT (every permission and release rule is checked here), reads the stored paper with the service
-- role, and logs the download with paper_download_log once the PDF is built.
--
-- Release: paper_release_at = released_early_at, else starts_at minus release_minutes_before. Home copies can be
-- had from the release until the scheduled end plus 2 hours, unless held or the exam is cancelled. The time window
-- decides, not exams.status: complete_finished_exams completes exams at about the moment the window closes and can
-- lag a few minutes. Only the database clock decides: p_now is honoured for direct database sessions (tests, jobs)
-- and ignored for API calls (paper_clock).
--
-- Families never read the paper tables or the paper files; they get a copy only through paper-copy. Copy records
-- and download logs are never deleted: a cancelled booking keeps its codes for the scan check.

-- ---------------------------------------------------------------------------------------------
-- Staff actions on papers are audited with the admin's reason.
-- ---------------------------------------------------------------------------------------------
-- An admin's own reason is 3 to 300 characters; a settings change also records the old and new values with it.
alter table public.audit_log add column reason text;
alter table public.audit_log add constraint audit_log_reason_length check (reason is null or char_length(reason) <= 600);

-- ---------------------------------------------------------------------------------------------
-- Exam paper settings.
-- ---------------------------------------------------------------------------------------------
alter table public.exams
  add column exam_code text,
  add column release_minutes_before int not null default 10,
  add column spare_pages int not null default 2,
  add column release_held boolean not null default false,
  add column released_early_at timestamptz,
  add column release_notified_at timestamptz,
  add constraint exams_release_minutes_range check (release_minutes_before between 0 and 120),
  add constraint exams_spare_pages_range check (spare_pages between 0 and 6);

-- <SUBJECT>-<PAPER initials>-<YYYY>-<MM> (London month), e.g. MATHS-P1H-2027-06. The subject keeps its letters and
-- digits (at most 16); the paper gives the first letter of each word and every number ("Paper 1 Higher" is P1H).
create function public.exam_code_base(p_subject bigint, p_paper text, p_starts_at timestamptz)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select left(coalesce(nullif(regexp_replace(upper(coalesce(
           (select s.name from public.subjects s where s.id = p_subject), '')), '[^A-Z0-9]+', '', 'g'), ''), 'EXAM'), 16)
    || coalesce('-' || nullif(left((
         select string_agg(case when m.t[1] ~ '^[0-9]' then m.t[1] else left(m.t[1], 1) end, '' order by m.o)
         from regexp_matches(upper(coalesce(p_paper, '')), '[A-Z]+|[0-9]+', 'g') with ordinality as m(t, o)), 8), ''), '')
    || '-' || to_char(p_starts_at at time zone 'Europe/London', 'YYYY-MM')
$$;

-- The base code, or the base with -2, -3 ... when another exam already has it.
create function public.exam_code_generate(p_subject bigint, p_paper text, p_starts_at timestamptz, p_self uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_base text := public.exam_code_base(p_subject, p_paper, p_starts_at);
  v_code text := v_base;
  v_n int := 1;
begin
  -- Two exams created at once with the same base take turns here.
  perform pg_advisory_xact_lock(hashtextextended('exam_code:' || v_base, 0));
  while exists (select 1 from public.exams e where e.exam_code = v_code and e.id is distinct from p_self) loop
    v_n := v_n + 1;
    v_code := v_base || '-' || v_n;
  end loop;
  return v_code;
end;
$$;

-- Backfill existing exams in the order they were created. Their history (updated_at) is unchanged.
alter table public.exams disable trigger exams_touch_updated_at;
do $$
declare
  r record;
begin
  for r in
    select e.id, e.subject_id, e.paper, e.starts_at from public.exams e
    where e.exam_code is null order by e.created_at, e.id
  loop
    update public.exams set exam_code = public.exam_code_generate(r.subject_id, r.paper, r.starts_at, r.id)
    where id = r.id;
  end loop;
end;
$$;
alter table public.exams enable trigger exams_touch_updated_at;

alter table public.exams
  alter column exam_code set not null,
  add constraint exams_exam_code_key unique (exam_code),
  add constraint exams_exam_code_format check (exam_code ~ '^[A-Z0-9-]{3,40}$');

-- New exams get their code when created; admins can change it until the first copy (set_exam_paper_settings).
create function public.exams_set_exam_code()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.exam_code is null then
    new.exam_code := public.exam_code_generate(new.subject_id, new.paper, new.starts_at, new.id);
  end if;
  return new;
end;
$$;
create trigger exams_set_exam_code before insert on public.exams
  for each row execute function public.exams_set_exam_code();

-- An exam moved to another time is released relative to its new start: an early release (and the notice sent
-- for it) no longer applies.
create function public.exams_release_follows_start()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.released_early_at := null;
  new.release_notified_at := null;
  return new;
end;
$$;
create trigger exams_release_follows_start before update of starts_at on public.exams
  for each row when (old.starts_at is distinct from new.starts_at)
  execute function public.exams_release_follows_start();

revoke execute on function public.exam_code_base(bigint, text, timestamptz) from public, anon, authenticated;
revoke execute on function public.exam_code_generate(bigint, text, timestamptz, uuid) from public, anon, authenticated;
revoke execute on function public.exams_set_exam_code() from public, anon, authenticated;
revoke execute on function public.exams_release_follows_start() from public, anon, authenticated;

-- Invoker: a signed-in caller gets a time only for exams they can see.
create function public.paper_release_at(p_exam uuid)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select coalesce(e.released_early_at, e.starts_at - e.release_minutes_before * interval '1 minute')
  from public.exams e
  where e.id = p_exam
$$;
revoke execute on function public.paper_release_at(uuid) from public, anon;
grant execute on function public.paper_release_at(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Papers, copies and downloads.
-- ---------------------------------------------------------------------------------------------
create type public.paper_kind as enum ('paper', 'insert');
create type public.paper_download_kind as enum ('home', 'print_pack', 'reprint', 'admin_preview');

-- Every uploaded version is kept: copies made from it may already be printed. The current paper of an exam is its
-- kind = 'paper' row with superseded_at null. Inserts (data booklets, formula sheets) are released with the paper
-- and not personalised; removing one sets superseded_at.
create table public.exam_papers (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.exams (id) on delete cascade,
  kind public.paper_kind not null,
  title text not null check (char_length(title) between 1 and 120),
  version int not null check (version > 0),
  storage_path text not null unique,
  page_count int not null check (page_count > 0),
  byte_size bigint not null check (byte_size between 1 and 20971520),
  uploaded_by uuid references public.profiles (id) on delete set null,
  uploaded_at timestamptz not null default now(),
  replace_reason text check (replace_reason is null or char_length(replace_reason) between 3 and 300),
  superseded_at timestamptz,
  corrected_notified_at timestamptz,
  constraint exam_papers_path_in_exam check (split_part(storage_path, '/', 1) = exam_id::text),
  constraint exam_papers_exam_kind_version_key unique (exam_id, kind, version)
);
create unique index exam_papers_one_current_paper on public.exam_papers (exam_id)
  where kind = 'paper' and superseded_at is null;

-- One copy per booking and paper version. The code is 8 random Crockford base32 characters (40 bits) plus the
-- mod-37 check symbol; codes are unique across all exams and, as copies are never deleted, never reused.
-- page_count includes the spare answer pages the exam had when the copy was made.
create table public.paper_copies (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  booking_id uuid not null references public.bookings (id),
  paper_id uuid not null references public.exam_papers (id),
  page_count int not null check (page_count > 0),
  created_at timestamptz not null default now(),
  constraint paper_copies_booking_paper_key unique (booking_id, paper_id),
  constraint paper_copies_code_format
    check (code ~ '^[0123456789ABCDEFGHJKMNPQRSTVWXYZ]{8}[0123456789ABCDEFGHJKMNPQRSTVWXYZ*~$=U]$')
);
create index paper_copies_paper_idx on public.paper_copies (paper_id);

create table public.paper_downloads (
  id bigint generated always as identity primary key,
  copy_id uuid not null references public.paper_copies (id),
  downloaded_by uuid references public.profiles (id) on delete set null,
  kind public.paper_download_kind not null,
  at timestamptz not null default now()
);
create index paper_downloads_copy_at_idx on public.paper_downloads (copy_id, at);

alter table public.exam_papers enable row level security;
alter table public.paper_copies enable row level security;
alter table public.paper_downloads enable row level security;
revoke all on public.exam_papers, public.paper_copies, public.paper_downloads from anon, authenticated;
revoke all on sequence public.paper_downloads_id_seq from anon, authenticated;
grant select on public.exam_papers, public.paper_copies, public.paper_downloads to authenticated;

create policy exam_papers_select on public.exam_papers for select to authenticated
using ((select public.is_staff_admin()));
create policy paper_copies_select on public.paper_copies for select to authenticated
using ((select public.is_staff_admin()));
create policy paper_downloads_select on public.paper_downloads for select to authenticated
using ((select public.is_staff_admin()));

-- ---------------------------------------------------------------------------------------------
-- Private bucket for paper files: owner/admin only. A registered paper file cannot be deleted from the API
-- (copies made from it may be printed); the paper-register Edge Function removes refused uploads with the
-- service role. There is no update policy, so a stored file is never overwritten.
-- ---------------------------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('exam-papers', 'exam-papers', false, 20971520, array['application/pdf'])
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create policy exam_papers_objects_insert on storage.objects for insert to authenticated
with check (
  bucket_id = 'exam-papers'
  and (select public.is_staff_admin())
  and name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.pdf$'
);

create policy exam_papers_objects_select on storage.objects for select to authenticated
using (bucket_id = 'exam-papers' and (select public.is_staff_admin()));

create policy exam_papers_objects_delete on storage.objects for delete to authenticated
using (
  bucket_id = 'exam-papers'
  and (select public.is_staff_admin())
  and not exists (select 1 from public.exam_papers p where p.storage_path = objects.name)
);

-- ---------------------------------------------------------------------------------------------
-- Copy codes.
-- ---------------------------------------------------------------------------------------------
create function public.copy_code_new()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_alpha constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  v_check constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ*~$=U';
  v_bytes bytea := extensions.gen_random_bytes(5);
  v_val bigint := 0;
  v_out text := '';
begin
  for i in 0 .. 4 loop
    v_val := v_val * 256 + get_byte(v_bytes, i);
  end loop;
  for i in reverse 7 .. 0 loop
    v_out := v_out || substr(v_alpha, ((v_val >> (5 * i)) & 31)::int + 1, 1);
  end loop;
  return v_out || substr(v_check, (v_val % 37)::int + 1, 1);
end;
$$;

create function public.copy_code_valid(p_code text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_alpha constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  v_check constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ*~$=U';
  v_val bigint := 0;
begin
  if p_code is null
     or p_code !~ '^[0123456789ABCDEFGHJKMNPQRSTVWXYZ]{8}[0123456789ABCDEFGHJKMNPQRSTVWXYZ*~$=U]$' then
    return false;
  end if;
  for i in 1 .. 8 loop
    v_val := v_val * 32 + strpos(v_alpha, substr(p_code, i, 1)) - 1;
  end loop;
  return substr(p_code, 9, 1) = substr(v_check, (v_val % 37)::int + 1, 1);
end;
$$;

revoke execute on function public.copy_code_new() from public, anon, authenticated;
grant execute on function public.copy_code_new() to service_role;
revoke execute on function public.copy_code_valid(text) from public, anon;
grant execute on function public.copy_code_valid(text) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Internal rules (definer callers only).
-- ---------------------------------------------------------------------------------------------

-- The clock for release checks. p_now is honoured only for direct database sessions (pgTAP, jobs); a call through
-- the API (PostgREST connects as authenticator and sets request.method) always uses the database clock.
create function public.paper_clock(p_now timestamptz)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select case
    when p_now is null
      or session_user = 'authenticator'
      or coalesce(current_setting('request.method', true), '') <> '' then now()
    else p_now
  end
$$;

-- Why a home copy cannot be had at p_now (null: it can). The window, the hold and a cancelled exam decide; a
-- completed exam inside its window is still open.
create function public.paper_window_code(p_exam public.exams, p_now timestamptz)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_exam.status = 'cancelled'
      or p_now >= p_exam.starts_at + p_exam.duration_minutes * interval '1 minute' + interval '2 hours' then 'paper_closed'
    when p_exam.status = 'draft' then 'paper_not_released'
    when p_exam.release_held then 'paper_held'
    when p_now < public.paper_release_at(p_exam.id) then 'paper_not_released'
  end
$$;

-- Who may have a copy of this booking's paper, of this kind, at p_now (null: allowed).
--   home: the active candidate or an active linked parent; a paid or cancel_requested home booking of an active
--         candidate; inside the window (paper_window_code).
--   print_pack, reprint: owner/admin; a paid or cancel_requested centre booking; any time.
--   admin_preview: owner/admin; any booking, any time.
create function public.paper_access_code(
  p_actor uuid,
  p_booking public.bookings,
  p_exam public.exams,
  p_kind public.paper_download_kind,
  p_now timestamptz
)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role public.app_role;
begin
  select a.role into v_role from public.profiles a where a.id = p_actor and a.status = 'active';
  if v_role is null or p_kind is null then
    return 'forbidden';
  end if;
  if p_kind = 'home' then
    if p_booking.student_id is null
       or not ((v_role = 'student' and p_actor = p_booking.student_id)
               or (v_role = 'parent' and exists (
                     select 1 from public.parent_children pc
                     where pc.parent_id = p_actor and pc.student_id = p_booking.student_id)))
       or not exists (
         select 1 from public.profiles s
         where s.id = p_booking.student_id and s.role = 'student' and s.status = 'active') then
      return 'forbidden';
    end if;
    if p_booking.sitting <> 'home' then
      return 'wrong_sitting';
    end if;
    if p_booking.status not in ('paid', 'cancel_requested') then
      return 'forbidden';
    end if;
    return public.paper_window_code(p_exam, p_now);
  end if;
  if v_role not in ('owner', 'admin') then
    return 'forbidden';
  end if;
  if p_kind = 'admin_preview' then
    return null;
  end if;
  if p_booking.sitting <> 'centre' then
    return 'wrong_sitting';
  end if;
  if p_booking.status not in ('paid', 'cancel_requested') then
    return 'forbidden';
  end if;
  return null;
end;
$$;

-- Home downloads of a booking (any version) in the hour up to p_now.
create function public.paper_home_downloads_last_hour(p_booking uuid, p_now timestamptz)
returns int
language sql
stable
set search_path = ''
as $$
  select count(*)::int
  from public.paper_downloads d
  join public.paper_copies c on c.id = d.copy_id
  where c.booking_id = p_booking and d.kind = 'home'
    and d.at > p_now - interval '1 hour' and d.at <= p_now
$$;

create function public.paper_exam_title(p_title text, p_paper text)
returns text
language sql
immutable
set search_path = ''
as $$
  select p_title || case when coalesce(p_paper, '') <> '' then ' (' || p_paper || ')' else '' end
$$;

revoke execute on function public.paper_clock(timestamptz) from public, anon, authenticated;
revoke execute on function public.paper_window_code(public.exams, timestamptz) from public, anon, authenticated;
revoke execute on function public.paper_access_code(uuid, public.bookings, public.exams, public.paper_download_kind, timestamptz)
  from public, anon, authenticated;
revoke execute on function public.paper_home_downloads_last_hour(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.paper_exam_title(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- Admin: settings, papers, inserts, release.
-- ---------------------------------------------------------------------------------------------

-- Exam code (locked once any copy of the exam exists), release minutes and spare pages. A copy keeps the spare
-- pages it was made with. Changing the release minutes of a published exam needs a reason of 3 to 300 characters
-- (moving the release earlier is in effect an early release). The audit row records the old and new values and
-- the reason. A release moved to a time still to come is announced again at that time.
create function public.set_exam_paper_settings(
  p_exam uuid,
  p_exam_code text,
  p_release_minutes_before int,
  p_spare_pages int,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_code text := upper(btrim(coalesce(p_exam_code, '')));
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_exam public.exams%rowtype;
  v_minutes_changed boolean;
  v_new_release timestamptz;
begin
  if not exists (
    select 1 from public.profiles a
    where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin') for share) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null or v_code !~ '^[A-Z0-9-]{3,40}$'
     or p_release_minutes_before is null or p_release_minutes_before not between 0 and 120
     or p_spare_pages is null or p_spare_pages not between 0 and 6
     or (v_reason is not null and char_length(v_reason) not between 3 and 300) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_exam from public.exams e where e.id = p_exam for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_exam.status in ('cancelled', 'completed') then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  v_minutes_changed := p_release_minutes_before <> v_exam.release_minutes_before;
  if v_minutes_changed and v_exam.status = 'published' and v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if v_code <> v_exam.exam_code and exists (
    select 1 from public.paper_copies c
    join public.exam_papers p on p.id = c.paper_id
    where p.exam_id = v_exam.id) then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  v_new_release := coalesce(v_exam.released_early_at, v_exam.starts_at - p_release_minutes_before * interval '1 minute');
  begin
    update public.exams
    set exam_code = v_code, release_minutes_before = p_release_minutes_before, spare_pages = p_spare_pages,
        release_notified_at = case when v_minutes_changed and v_new_release > now() then null
                                   else release_notified_at end
    where id = v_exam.id;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'exam_paper_settings_changed', 'exam', v_exam.id,
    'exam code ' || v_exam.exam_code || ' -> ' || v_code
    || '; release ' || v_exam.release_minutes_before || ' -> ' || p_release_minutes_before || ' minutes before the start'
    || '; spare pages ' || v_exam.spare_pages || ' -> ' || p_spare_pages
    || coalesce('; reason: ' || v_reason, ''));
  return jsonb_build_object('ok', true, 'id', v_exam.id, 'exam_code', v_code);
end;
$$;

-- Registers a PDF already uploaded to exam-papers/<exam id>/<uuid>.pdf (paper-register has checked the file and
-- counted its pages). A new paper supersedes the current one; once any copy of that one exists, a reason of 3 to
-- 300 characters is required. An insert needs a title.
create function public.register_exam_paper(
  p_exam uuid,
  p_kind public.paper_kind,
  p_title text,
  p_storage_path text,
  p_page_count int,
  p_byte_size bigint,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_exam public.exams%rowtype;
  v_prev public.exam_papers%rowtype;
  v_version int;
  v_id uuid;
  v_uuid constant text := '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
begin
  if not exists (
    select 1 from public.profiles a
    where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin') for share) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_kind = 'paper' then
    v_title := coalesce(v_title, 'Question paper');
  end if;
  if p_exam is null or p_kind is null or v_title is null or char_length(v_title) > 120
     or p_storage_path is null or p_storage_path !~ ('^' || p_exam::text || '/' || v_uuid || '\.pdf$')
     or p_page_count is null or p_page_count not between 1 and 500
     or p_byte_size is null or p_byte_size not between 1 and 20971520
     or (v_reason is not null and char_length(v_reason) not between 3 and 300) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  -- The exam lock orders this with copies being issued: they see either the old paper or the new one.
  select * into v_exam from public.exams e where e.id = p_exam for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_exam.status in ('cancelled', 'completed') then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  if exists (select 1 from public.exam_papers p where p.storage_path = p_storage_path) then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  if not exists (
    select 1 from storage.objects o where o.bucket_id = 'exam-papers' and o.name = p_storage_path) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  if p_kind = 'paper' then
    select * into v_prev from public.exam_papers p
    where p.exam_id = v_exam.id and p.kind = 'paper' and p.superseded_at is null
    for update;
    if v_prev.id is not null then
      if v_reason is null and exists (select 1 from public.paper_copies c where c.paper_id = v_prev.id) then
        return jsonb_build_object('ok', false, 'code', 'invalid_input');
      end if;
      update public.exam_papers set superseded_at = now() where id = v_prev.id;
    end if;
  end if;

  select coalesce(max(p.version), 0) + 1 into v_version
  from public.exam_papers p where p.exam_id = v_exam.id and p.kind = p_kind;
  insert into public.exam_papers (exam_id, kind, title, version, storage_path, page_count, byte_size, uploaded_by,
    replace_reason)
  values (v_exam.id, p_kind, v_title, v_version, p_storage_path, p_page_count, p_byte_size, v_actor,
    case when v_prev.id is not null then v_reason end)
  returning id into v_id;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, case when v_prev.id is not null then 'paper_replaced' else 'paper_uploaded' end, 'exam_paper', v_id,
    case when v_prev.id is not null then v_reason end);
  return jsonb_build_object('ok', true, 'id', v_id, 'version', v_version, 'page_count', p_page_count);
end;
$$;

create function public.remove_exam_insert(p_paper uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := btrim(coalesce(p_reason, ''));
  v_p public.exam_papers%rowtype;
begin
  if not exists (
    select 1 from public.profiles a
    where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin') for share) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_paper is null or char_length(v_reason) not between 3 and 300 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_p from public.exam_papers p where p.id = p_paper and p.kind = 'insert' for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_p.superseded_at is not null then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  update public.exam_papers set superseded_at = now() where id = v_p.id;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'insert_removed', 'exam_paper', v_p.id, v_reason);
  return jsonb_build_object('ok', true, 'id', v_p.id);
end;
$$;

-- Release now (before the release time, with a current paper; also lifts a hold), hold and resume. Each needs a
-- reason and is audited with it. Only published exams.
create function public.paper_release_now(p_exam uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := btrim(coalesce(p_reason, ''));
  v_exam public.exams%rowtype;
begin
  if not exists (
    select 1 from public.profiles a
    where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin') for share) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null or char_length(v_reason) not between 3 and 300 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_exam from public.exams e where e.id = p_exam for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_exam.status <> 'published'
     or public.paper_release_at(v_exam.id) <= now()
     or not exists (
       select 1 from public.exam_papers p
       where p.exam_id = v_exam.id and p.kind = 'paper' and p.superseded_at is null) then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  update public.exams set released_early_at = now(), release_held = false where id = v_exam.id;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'paper_released_early', 'exam', v_exam.id, v_reason);
  return jsonb_build_object('ok', true, 'id', v_exam.id, 'release_at', now());
end;
$$;

create function public.paper_hold(p_exam uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := btrim(coalesce(p_reason, ''));
  v_exam public.exams%rowtype;
begin
  if not exists (
    select 1 from public.profiles a
    where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin') for share) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null or char_length(v_reason) not between 3 and 300 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  -- The exam lock waits for copies being issued at this moment; later ones see the hold.
  select * into v_exam from public.exams e where e.id = p_exam for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_exam.status <> 'published' or v_exam.release_held then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  update public.exams set release_held = true where id = v_exam.id;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'paper_held', 'exam', v_exam.id, v_reason);
  return jsonb_build_object('ok', true, 'id', v_exam.id);
end;
$$;

create function public.paper_resume(p_exam uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := btrim(coalesce(p_reason, ''));
  v_exam public.exams%rowtype;
begin
  if not exists (
    select 1 from public.profiles a
    where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin') for share) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null or char_length(v_reason) not between 3 and 300 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_exam from public.exams e where e.id = p_exam for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_exam.status <> 'published' or not v_exam.release_held then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  update public.exams set release_held = false where id = v_exam.id;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'paper_resumed', 'exam', v_exam.id, v_reason);
  return jsonb_build_object('ok', true, 'id', v_exam.id);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Copies and downloads.
-- ---------------------------------------------------------------------------------------------

-- Decides whether the caller may have this booking's copy now, then creates or reuses the copy of the current
-- paper. Returns what paper-copy needs to build it. differs_from_previous: the last copy handed out for this
-- booking (home, print pack or reprint) was of another paper version.
create function public.paper_copy_issue(
  p_booking uuid,
  p_kind public.paper_download_kind,
  p_now timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_admin boolean;
  v_b public.bookings%rowtype;
  v_e public.exams%rowtype;
  v_p public.exam_papers%rowtype;
  v_c public.paper_copies%rowtype;
  v_refusal text;
  v_last uuid;
  v_tries int := 0;
begin
  if p_booking is null or p_kind is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  v_admin := exists (
    select 1 from public.profiles a where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin'));
  select * into v_b from public.bookings b where b.id = p_booking;
  if not found then
    -- Families get the same answer for a missing booking as for someone else's.
    return jsonb_build_object('ok', false, 'code', case when v_admin then 'not_found' else 'forbidden' end);
  end if;
  -- Shared lock: a hold, a replacement or an exam-code change waits for this call, and this call sees theirs.
  select * into v_e from public.exams e where e.id = v_b.exam_id for share;

  v_refusal := public.paper_access_code(v_actor, v_b, v_e, p_kind, v_now);
  if v_refusal is not null then
    return jsonb_build_object('ok', false, 'code', v_refusal);
  end if;
  select * into v_p from public.exam_papers p
  where p.exam_id = v_e.id and p.kind = 'paper' and p.superseded_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'paper_missing');
  end if;
  if p_kind = 'home' and public.paper_home_downloads_last_hour(v_b.id, v_now) >= 20 then
    return jsonb_build_object('ok', false, 'code', 'rate_limited');
  end if;

  -- One copy per booking and paper version. A concurrent call for the same copy waits on the insert and then
  -- reads that copy; a code that is already taken (1 in 2^40 per copy) is drawn again.
  loop
    select * into v_c from public.paper_copies c where c.booking_id = v_b.id and c.paper_id = v_p.id;
    exit when found;
    insert into public.paper_copies (code, booking_id, paper_id, page_count)
    values (public.copy_code_new(), v_b.id, v_p.id, v_p.page_count + v_e.spare_pages)
    on conflict do nothing
    returning * into v_c;
    exit when found;
    v_tries := v_tries + 1;
    if v_tries >= 5 then
      raise exception 'no free copy code after % tries', v_tries;
    end if;
  end loop;

  select c.paper_id into v_last
  from public.paper_downloads d
  join public.paper_copies c on c.id = d.copy_id
  where c.booking_id = v_b.id and d.kind <> 'admin_preview'
  order by d.at desc, d.id desc
  limit 1;

  return jsonb_build_object(
    'ok', true,
    'copy_id', v_c.id,
    'code', v_c.code,
    'page_count', v_c.page_count,
    'spare_pages', v_c.page_count - v_p.page_count,
    'storage_path', v_p.storage_path,
    'paper_version', v_p.version,
    'candidate_name', coalesce((
      select btrim(s.first_name || ' ' || s.last_name) from public.profiles s where s.id = v_b.student_id), ''),
    'index_number', coalesce((
      select d.index_number from public.student_details d where d.profile_id = v_b.student_id), ''),
    'exam_code', v_e.exam_code,
    'exam_title', public.paper_exam_title(v_e.title, v_e.paper),
    'starts_at', v_e.starts_at,
    'differs_from_previous', coalesce(v_last <> v_p.id, false));
end;
$$;

-- Logs one download of a copy, with the same permission as issuing it (and, for home downloads, the same hourly
-- limit). Always the database clock. paper-copy calls it once the PDF is built.
create function public.paper_download_log(p_copy uuid, p_kind public.paper_download_kind)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_admin boolean;
  v_c public.paper_copies%rowtype;
  v_b public.bookings%rowtype;
  v_e public.exams%rowtype;
  v_refusal text;
  v_id bigint;
begin
  if p_copy is null or p_kind is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  v_admin := exists (
    select 1 from public.profiles a where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin'));
  select * into v_c from public.paper_copies c where c.id = p_copy;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when v_admin then 'not_found' else 'forbidden' end);
  end if;
  select * into v_b from public.bookings b where b.id = v_c.booking_id;
  select * into v_e from public.exams e where e.id = v_b.exam_id;
  v_refusal := public.paper_access_code(v_actor, v_b, v_e, p_kind, now());
  if v_refusal is not null then
    return jsonb_build_object('ok', false, 'code', v_refusal);
  end if;
  if p_kind = 'home' and public.paper_home_downloads_last_hour(v_b.id, now()) >= 20 then
    return jsonb_build_object('ok', false, 'code', 'rate_limited');
  end if;
  insert into public.paper_downloads (copy_id, downloaded_by, kind, at)
  values (v_c.id, v_actor, p_kind, now())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- An insert of the booking's exam: the home rules, or owner/admin at any time.
create function public.paper_insert_issue(p_booking uuid, p_insert uuid, p_now timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_admin boolean;
  v_b public.bookings%rowtype;
  v_e public.exams%rowtype;
  v_p public.exam_papers%rowtype;
  v_refusal text;
begin
  if p_booking is null or p_insert is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  v_admin := exists (
    select 1 from public.profiles a where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin'));
  select * into v_b from public.bookings b where b.id = p_booking;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when v_admin then 'not_found' else 'forbidden' end);
  end if;
  select * into v_e from public.exams e where e.id = v_b.exam_id;
  -- The release rules come first, so nothing about an insert is told before its release.
  if not v_admin then
    v_refusal := public.paper_access_code(v_actor, v_b, v_e, 'home', v_now);
    if v_refusal is not null then
      return jsonb_build_object('ok', false, 'code', v_refusal);
    end if;
  end if;
  select * into v_p from public.exam_papers p
  where p.id = p_insert and p.exam_id = v_e.id and p.kind = 'insert' and p.superseded_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  return jsonb_build_object('ok', true, 'storage_path', v_p.storage_path, 'title', v_p.title);
end;
$$;

-- What the family sees about the paper on a booking (also readable by owner/admin).
--   status: centre (a centre booking), closed (no paper for this booking: not paid or cancel_requested, candidate
--   not active, exam cancelled, or the window is over), held, not_yet (before the release), missing (released
--   with no paper), open.
--   last_download: the latest home download. corrected: that download was of an older version than the current
--   paper. inserts: listed once released.
create function public.booking_paper_state(p_booking uuid, p_now timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_role public.app_role;
  v_admin boolean;
  v_b public.bookings%rowtype;
  v_e public.exams%rowtype;
  v_current uuid;
  v_status text;
  v_last record;
  v_inserts jsonb := '[]'::jsonb;
begin
  if p_booking is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select a.role into v_role from public.profiles a where a.id = v_actor and a.status = 'active';
  v_admin := v_role in ('owner', 'admin');
  select * into v_b from public.bookings b where b.id = p_booking;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when v_admin then 'not_found' else 'forbidden' end);
  end if;
  if not coalesce(v_admin, false) and not (
    v_b.student_id is not null
    and ((v_role = 'student' and v_actor = v_b.student_id)
         or (v_role = 'parent' and exists (
               select 1 from public.parent_children pc
               where pc.parent_id = v_actor and pc.student_id = v_b.student_id)))) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into v_e from public.exams e where e.id = v_b.exam_id;
  select p.id into v_current from public.exam_papers p
  where p.exam_id = v_e.id and p.kind = 'paper' and p.superseded_at is null;

  if v_b.sitting = 'centre' then
    v_status := 'centre';
  elsif v_b.status not in ('paid', 'cancel_requested')
        or not exists (
          select 1 from public.profiles s
          where s.id = v_b.student_id and s.role = 'student' and s.status = 'active') then
    v_status := 'closed';
  else
    v_status := case public.paper_window_code(v_e, v_now)
      when 'paper_closed' then 'closed'
      when 'paper_held' then 'held'
      when 'paper_not_released' then 'not_yet'
      else case when v_current is null then 'missing' else 'open' end
    end;
  end if;

  select d.at, c.paper_id, nullif(btrim(coalesce(pr.first_name, '') || ' ' || coalesce(pr.last_name, '')), '') as by_name
  into v_last
  from public.paper_downloads d
  join public.paper_copies c on c.id = d.copy_id
  left join public.profiles pr on pr.id = d.downloaded_by
  where c.booking_id = v_b.id and d.kind = 'home'
  order by d.at desc, d.id desc
  limit 1;

  if v_status in ('open', 'missing') then
    select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'title', p.title) order by p.version), '[]'::jsonb)
    into v_inserts
    from public.exam_papers p
    where p.exam_id = v_e.id and p.kind = 'insert' and p.superseded_at is null;
  end if;

  return jsonb_build_object(
    'ok', true,
    'sitting', v_b.sitting,
    'status', v_status,
    'release_at', public.paper_release_at(v_e.id),
    -- the database clock that decided the status, so a page can wait for the release without trusting the device
    'server_now', v_now,
    'last_download', case when v_last.at is null then null
                          else jsonb_build_object('at', v_last.at, 'by_name', v_last.by_name) end,
    'corrected', v_b.sitting = 'home' and v_current is not null and v_last.paper_id is not null
                 and v_last.paper_id <> v_current,
    'inserts', v_inserts);
end;
$$;

-- Scan check (owner/admin): [{code, page}] in, one answer per item out, in order. found: the code is a copy and
-- the page is one of its pages. Codes of superseded papers and cancelled bookings still look up (current false).
create function public.paper_lookup_codes(p_items jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.profiles a
    where a.id = auth.uid() and a.status = 'active' and a.role in ('owner', 'admin')) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if jsonb_array_length(p_items) > 1000
     or exists (
       select 1 from jsonb_array_elements(p_items) i
       where jsonb_typeof(i) <> 'object'
          or jsonb_typeof(i -> 'code') is distinct from 'string'
          or jsonb_typeof(i -> 'page') is distinct from 'number'
          or char_length(i ->> 'code') > 40
          or (i ->> 'page') !~ '^[0-9]{1,6}$') then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  return (
    select coalesce(jsonb_agg(
      case when c.id is not null and t.page between 1 and c.page_count then
        jsonb_build_object('code', t.code, 'page', t.page, 'found', true,
          'exam_code', e.exam_code, 'exam_title', public.paper_exam_title(e.title, e.paper),
          'index_number', d.index_number, 'page_count', c.page_count, 'paper_version', p.version,
          'current', p.superseded_at is null)
      else
        jsonb_build_object('code', t.code, 'page', t.page, 'found', false,
          'exam_code', null, 'exam_title', null, 'index_number', null, 'page_count', null,
          'paper_version', null, 'current', null)
      end order by t.o), '[]'::jsonb)
    from (
      select x.i ->> 'code' as code, (x.i ->> 'page')::int as page, x.o
      from jsonb_array_elements(p_items) with ordinality as x(i, o)
    ) t
    left join public.paper_copies c on c.code = t.code
    left join public.exam_papers p on p.id = c.paper_id
    left join public.exams e on e.id = p.exam_id
    left join public.bookings b on b.id = c.booking_id
    left join public.student_details d on d.profile_id = b.student_id
  );
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Grants: signed-in callers (every check is inside); service_role for the Edge Function tests.
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.set_exam_paper_settings(uuid, text, int, int, text) from public, anon;
revoke execute on function public.register_exam_paper(uuid, public.paper_kind, text, text, int, bigint, text) from public, anon;
revoke execute on function public.remove_exam_insert(uuid, text) from public, anon;
revoke execute on function public.paper_release_now(uuid, text) from public, anon;
revoke execute on function public.paper_hold(uuid, text) from public, anon;
revoke execute on function public.paper_resume(uuid, text) from public, anon;
revoke execute on function public.paper_copy_issue(uuid, public.paper_download_kind, timestamptz) from public, anon;
revoke execute on function public.paper_download_log(uuid, public.paper_download_kind) from public, anon;
revoke execute on function public.paper_insert_issue(uuid, uuid, timestamptz) from public, anon;
revoke execute on function public.booking_paper_state(uuid, timestamptz) from public, anon;
revoke execute on function public.paper_lookup_codes(jsonb) from public, anon;

grant execute on function public.set_exam_paper_settings(uuid, text, int, int, text) to authenticated;
grant execute on function public.register_exam_paper(uuid, public.paper_kind, text, text, int, bigint, text) to authenticated;
grant execute on function public.remove_exam_insert(uuid, text) to authenticated;
grant execute on function public.paper_release_now(uuid, text) to authenticated;
grant execute on function public.paper_hold(uuid, text) to authenticated;
grant execute on function public.paper_resume(uuid, text) to authenticated;
grant execute on function public.paper_copy_issue(uuid, public.paper_download_kind, timestamptz) to authenticated, service_role;
grant execute on function public.paper_download_log(uuid, public.paper_download_kind) to authenticated, service_role;
grant execute on function public.paper_insert_issue(uuid, uuid, timestamptz) to authenticated, service_role;
grant execute on function public.booking_paper_state(uuid, timestamptz) to authenticated, service_role;
grant execute on function public.paper_lookup_codes(jsonb) to authenticated;
