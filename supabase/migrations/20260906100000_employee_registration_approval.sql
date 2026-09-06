create table if not exists private.employee_registration_requests (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  login_username text not null,
  password_hash text not null,
  created_at timestamptz not null default now()
);

create unique index if not exists employee_registration_requests_name_key
  on private.employee_registration_requests (name);
create unique index if not exists employee_registration_requests_username_lower_key
  on private.employee_registration_requests (lower(login_username));
alter table private.employee_registration_requests enable row level security;
revoke all on table private.employee_registration_requests from public, anon, authenticated;

create or replace function public.register_employee_request(
  employee_name text,
  login_username text,
  login_password text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  clean_name text := btrim(coalesce(employee_name, ''));
  clean_username text := btrim(coalesce(login_username, ''));
  new_id uuid;
  pending_count integer;
begin
  if char_length(clean_name) <> 3 then
    raise exception '姓名必須剛好是 3 個字';
  end if;
  if char_length(clean_username) < 3 or char_length(clean_username) > 40
     or clean_username !~ '^[A-Za-z0-9._-]+$' then
    raise exception '登入帳號需為 3 到 40 個英數字、句點、底線或連字號';
  end if;
  if char_length(coalesce(login_password, '')) < 1 or char_length(login_password) > 72 then
    raise exception '登入密碼必須是 1 到 72 個字元';
  end if;

  if exists (
    select 1 from private.employees e
    where e.name = clean_name or lower(e.login_username) = lower(clean_username)
  ) then
    raise exception '這個姓名或登入帳號已經存在';
  end if;
  if exists (
    select 1 from private.employee_registration_requests r
    where r.name = clean_name or lower(r.login_username) = lower(clean_username)
  ) then
    raise exception '這個姓名或登入帳號已經送出申請';
  end if;
  select count(*) into pending_count from private.employee_registration_requests;
  if pending_count >= 100 then raise exception '待審核申請已滿，請聯絡管理員'; end if;

  insert into private.employee_registration_requests (name, login_username, password_hash)
  values (clean_name, clean_username, extensions.crypt(login_password, extensions.gen_salt('bf', 10)))
  returning id into new_id;
  return jsonb_build_object('ok', true, 'registration_id', new_id);
exception
  when unique_violation then raise exception '這個姓名或登入帳號已經送出申請';
end;
$function$;

create or replace function public.admin_get_pending_registrations(admin_code text)
returns table (
  registration_id uuid,
  employee_name text,
  login_username text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  admin_hash text;
begin
  select c.admin_code_hash into admin_hash from private.app_config c where c.singleton;
  if admin_hash is null or extensions.crypt(coalesce(admin_code, ''), admin_hash) <> admin_hash then
    raise exception '管理密碼不正確';
  end if;
  return query
  select r.id, r.name, r.login_username, r.created_at
  from private.employee_registration_requests r
  order by r.created_at;
end;
$function$;

create or replace function public.admin_review_registration(
  admin_code text,
  registration_id uuid,
  approve_registration boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  admin_hash text;
  pending_name text;
  pending_username text;
  pending_password_hash text;
  new_employee_id uuid;
  employee_count integer;
  chosen_color text;
  palette text[] := array['#2563eb', '#0f9d78', '#9333ea', '#ea580c', '#db2777', '#0891b2', '#4f46e5', '#65a30d'];
begin
  select c.admin_code_hash into admin_hash from private.app_config c where c.singleton;
  if admin_hash is null or extensions.crypt(coalesce(admin_code, ''), admin_hash) <> admin_hash then
    raise exception '管理密碼不正確';
  end if;

  select r.name, r.login_username, r.password_hash
  into pending_name, pending_username, pending_password_hash
  from private.employee_registration_requests r
  where r.id = registration_id
  for update;
  if pending_name is null then raise exception '找不到這筆待審核申請'; end if;

  if coalesce(approve_registration, false) then
    if exists (
      select 1 from private.employees e
      where e.name = pending_name or lower(e.login_username) = lower(pending_username)
    ) then
      raise exception '這個姓名或登入帳號已經存在';
    end if;
    select count(*) into employee_count from private.employees;
    chosen_color := palette[(employee_count % array_length(palette, 1)) + 1];
    insert into private.employees (name, login_username, password_hash, color)
    values (pending_name, pending_username, pending_password_hash, chosen_color)
    returning id into new_employee_id;
  end if;

  delete from private.employee_registration_requests where id = registration_id;
  return jsonb_build_object(
    'ok', true,
    'approved', coalesce(approve_registration, false),
    'employee_id', new_employee_id
  );
end;
$function$;

create or replace function public.admin_create_employee(
  admin_code text,
  employee_name text,
  login_username text,
  login_password text,
  employee_color text default '#2563eb'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  admin_hash text;
  clean_name text := btrim(coalesce(employee_name, ''));
  clean_username text := btrim(coalesce(login_username, ''));
  new_id uuid;
begin
  select c.admin_code_hash into admin_hash from private.app_config c where c.singleton;
  if admin_hash is null or extensions.crypt(coalesce(admin_code, ''), admin_hash) <> admin_hash then
    raise exception '管理密碼不正確';
  end if;
  if char_length(clean_name) <> 3 then raise exception '姓名必須剛好是 3 個字'; end if;
  if char_length(clean_username) < 3 or char_length(clean_username) > 40
     or clean_username !~ '^[A-Za-z0-9._-]+$' then
    raise exception '登入帳號需為 3 到 40 個英數字、句點、底線或連字號';
  end if;
  if char_length(coalesce(login_password, '')) < 1 or char_length(login_password) > 72 then
    raise exception '登入密碼必須是 1 到 72 個字元';
  end if;
  if employee_color !~ '^#[0-9A-Fa-f]{6}$' then raise exception '顏色格式不正確'; end if;
  insert into private.employees (name, login_username, password_hash, color)
  values (clean_name, clean_username, extensions.crypt(login_password, extensions.gen_salt('bf', 10)), employee_color)
  returning id into new_id;
  return jsonb_build_object('ok', true, 'employee_id', new_id);
exception when unique_violation then raise exception '這個姓名或登入帳號已經存在';
end;
$function$;

revoke all on function public.register_employee_request(text, text, text) from public, anon, authenticated;
revoke all on function public.admin_get_pending_registrations(text) from public, anon, authenticated;
revoke all on function public.admin_review_registration(text, uuid, boolean) from public, anon, authenticated;
revoke all on function public.admin_create_employee(text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.register_employee_request(text, text, text) to anon, authenticated;
grant execute on function public.admin_get_pending_registrations(text) to anon, authenticated;
grant execute on function public.admin_review_registration(text, uuid, boolean) to anon, authenticated;
grant execute on function public.admin_create_employee(text, text, text, text, text) to anon, authenticated;
