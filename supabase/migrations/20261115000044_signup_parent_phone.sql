-- Registration now asks for the parent's phone. register-student validates it and puts it in the sign-up
-- metadata as parent_phone; this trigger copies it to student_details.parent_phone, where the admin sees it
-- before approving and profile completion pre-fills it. A missing or malformed value is stored as null (the
-- student then enters it at profile completion, as before). Otherwise identical to 20261108000025's definition.
create or replace function public.handle_new_user()
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
  v_phone text := nullif(regexp_replace(btrim(coalesce(v_meta ->> 'parent_phone', '')), '\s+', ' ', 'g'), '');
  v_dob date;
begin
  begin
    v_dob := nullif(btrim(v_meta ->> 'date_of_birth'), '')::date;
  exception when others then
    v_dob := null;
  end;

  -- Same rule as register-student: 10 to 15 digits, optional leading +, spaces, brackets, dots or hyphens.
  if v_phone is not null and (
    length(v_phone) > 30
    or v_phone !~ '^\+?[0-9 ().-]+$'
    or length(regexp_replace(v_phone, '[^0-9]', '', 'g')) not between 10 and 15
  ) then
    v_phone := null;
  end if;

  insert into public.profiles (id, role, status, first_name, last_name, email)
  values (
    new.id, 'student',
    case when new.email_confirmed_at is not null then 'pending'::public.account_status
         else 'unconfirmed'::public.account_status end,
    v_first, v_last, v_email);

  insert into public.student_details (profile_id, date_of_birth, school, signup_parent_name, signup_parent_email, parent_phone)
  values (
    new.id,
    v_dob,
    v_meta ->> 'school',
    v_meta ->> 'parent_name',
    lower(btrim(v_meta ->> 'parent_email')),
    v_phone
  );

  return new;
end;
$$;
