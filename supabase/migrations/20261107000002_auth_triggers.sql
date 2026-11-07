-- Invitations: staff roles are chosen server-side (service role) by writing a row here.
-- The sign-up trigger consumes the row when a user with that email is created.
create table public.pending_invites (
  email extensions.citext primary key,
  role public.app_role not null check (role <> 'student'),
  invited_by uuid,
  created_at timestamptz not null default now()
);
alter table public.pending_invites enable row level security;
revoke all on public.pending_invites from anon, authenticated;

-- Sign-up: build the profile. Role and status are never taken from client metadata.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text := lower(btrim(coalesce(new.email, '')));
  v_meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_first text := coalesce(v_meta ->> 'first_name', '');
  v_last text := coalesce(v_meta ->> 'last_name', '');
  v_invite_role public.app_role;
  v_dob date;
begin
  select i.role into v_invite_role
  from public.pending_invites i
  where lower(i.email::text) = v_email;

  if v_invite_role is not null then
    insert into public.profiles (id, role, status, first_name, last_name, email)
    values (new.id, v_invite_role, 'active', v_first, v_last, v_email);
    delete from public.pending_invites where lower(email::text) = v_email;
    return new;
  end if;

  begin
    v_dob := nullif(btrim(v_meta ->> 'date_of_birth'), '')::date;
  exception when others then
    v_dob := null;
  end;

  insert into public.profiles (id, role, status, first_name, last_name, email)
  values (new.id, 'student', 'unconfirmed', v_first, v_last, v_email);

  insert into public.student_details (profile_id, date_of_birth, school, signup_parent_name, signup_parent_email)
  values (
    new.id,
    v_dob,
    v_meta ->> 'school',
    v_meta ->> 'parent_name',
    lower(btrim(v_meta ->> 'parent_email'))
  );

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Email confirmation: unconfirmed -> pending (never touches any other status).
create function public.handle_email_confirmed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.email_confirmed_at is null and new.email_confirmed_at is not null then
    perform set_config('app.bypass_guard', 'on', true);
    update public.profiles
      set status = 'pending'
      where id = new.id and status = 'unconfirmed';
    perform set_config('app.bypass_guard', 'off', true);
  end if;
  return new;
end;
$$;

create trigger on_auth_user_email_confirmed
  after update of email_confirmed_at on auth.users
  for each row execute function public.handle_email_confirmed();

-- Guard: role, status and index_number change only via bypass or service role.
create function public.guard_protected_columns()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_changed boolean;
begin
  if tg_table_name = 'profiles' then
    v_changed := new.role is distinct from old.role or new.status is distinct from old.status;
  else
    v_changed := new.index_number is distinct from old.index_number;
  end if;

  if v_changed
     and coalesce(current_setting('app.bypass_guard', true), '') <> 'on'
     and coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'protected column change not permitted' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger guard_profiles_protected
  before update on public.profiles
  for each row execute function public.guard_protected_columns();

create trigger guard_student_details_protected
  before update on public.student_details
  for each row execute function public.guard_protected_columns();

revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.handle_email_confirmed() from public, anon, authenticated;
revoke execute on function public.guard_protected_columns() from public, anon, authenticated;
