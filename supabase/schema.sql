create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists private;

create table private.employees (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  login_username text not null,
  password_hash text not null,
  color text not null default '#2563eb' check (color ~ '^#[0-9A-Fa-f]{6}$'),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index employees_login_username_lower_key on private.employees (lower(login_username));

create table private.leave_days (
  id bigint generated always as identity primary key,
  employee_id uuid not null references private.employees(id),
  leave_date date not null,
  created_at timestamptz not null default now(),
  unique (employee_id, leave_date)
);

create table private.app_config (
  singleton boolean primary key default true check (singleton),
  admin_code_hash text not null,
  updated_at timestamptz not null default now()
);

alter table private.employees enable row level security;
alter table private.leave_days enable row level security;
alter table private.app_config enable row level security;

create or replace function public.get_employees()
returns table (employee_id uuid, employee_name text, color text)
language sql stable security definer set search_path = ''
as $function$
  select e.id, e.name, e.color from private.employees e
  where e.active order by e.created_at, e.name;
$function$;

create or replace function public.get_leave_days(start_date date, end_date date)
returns table (leave_id bigint, employee_id uuid, employee_name text, leave_date date, color text)
language plpgsql stable security definer set search_path = ''
as $function$
begin
  if start_date is null or end_date is null or end_date < start_date then raise exception '日期範圍不正確'; end if;
  if end_date - start_date > 62 then raise exception '一次最多查詢 63 天'; end if;
  return query
  select l.id, e.id, e.name, l.leave_date, e.color
  from private.leave_days l join private.employees e on e.id = l.employee_id
  where e.active and l.leave_date between start_date and end_date
  order by l.leave_date, e.created_at, e.name;
end;
$function$;

create or replace function public.get_edit_status()
returns table (today_date date, editing_open boolean, deadline_date date, next_open_date date)
language sql stable security definer set search_path = ''
as $function$
  with local_clock as (select timezone('Asia/Taipei', now())::date as today)
  select today, extract(day from today) <= 15,
    date_trunc('month', today)::date + 14,
    (date_trunc('month', today)::date + interval '1 month')::date
  from local_clock;
$function$;

create or replace function public.register_leave(
  selected_employee_id uuid, login_username text, login_password text, selected_date date
)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
  local_today date := timezone('Asia/Taipei', now())::date;
  stored_hash text;
  new_id bigint;
begin
  if extract(day from local_today) > 15 then raise exception '本月預休填寫已截止，次月 1 日重新開放'; end if;
  if selected_date is null then raise exception '請選擇預休日期'; end if;
  if selected_date < (date_trunc('month', local_today)::date + interval '1 month')::date then
    raise exception '只能登記未來月份的預休';
  end if;
  if selected_date > local_today + 730 then raise exception '預休日期最多可登記兩年內'; end if;
  select e.password_hash into stored_hash from private.employees e
  where e.id = selected_employee_id and e.active
    and lower(e.login_username) = lower(btrim(coalesce(register_leave.login_username, '')));
  if stored_hash is null or extensions.crypt(coalesce(login_password, ''), stored_hash) <> stored_hash then
    raise exception '姓名、登入帳號或密碼不正確';
  end if;
  insert into private.leave_days (employee_id, leave_date) values (selected_employee_id, selected_date)
  on conflict (employee_id, leave_date) do nothing returning id into new_id;
  if new_id is null then raise exception '這一天已經登記過了'; end if;
  return jsonb_build_object('ok', true, 'leave_id', new_id);
end;
$function$;

create or replace function public.delete_leave(
  selected_employee_id uuid, login_username text, login_password text, selected_date date
)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
  local_today date := timezone('Asia/Taipei', now())::date;
  stored_hash text;
  removed_id bigint;
begin
  if extract(day from local_today) > 15 then raise exception '本月預休填寫已截止，次月 1 日重新開放'; end if;
  if selected_date is null then raise exception '請選擇預休日期'; end if;
  if selected_date < (date_trunc('month', local_today)::date + interval '1 month')::date then
    raise exception '只能取消未來月份的預休';
  end if;
  select e.password_hash into stored_hash from private.employees e
  where e.id = selected_employee_id and e.active
    and lower(e.login_username) = lower(btrim(coalesce(delete_leave.login_username, '')));
  if stored_hash is null or extensions.crypt(coalesce(login_password, ''), stored_hash) <> stored_hash then
    raise exception '姓名、登入帳號或密碼不正確';
  end if;
  delete from private.leave_days where employee_id = selected_employee_id and leave_date = selected_date
  returning id into removed_id;
  if removed_id is null then raise exception '這一天沒有可取消的預休'; end if;
  return jsonb_build_object('ok', true, 'leave_id', removed_id);
end;
$function$;

create or replace function public.admin_create_employee(
  admin_code text, employee_name text, login_username text, login_password text,
  employee_color text default '#2563eb'
)
returns jsonb language plpgsql security definer set search_path = ''
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
  if char_length(clean_name) < 1 or char_length(clean_name) > 30 then raise exception '姓名必須是 1 到 30 個字'; end if;
  if char_length(clean_username) < 3 or char_length(clean_username) > 40
     or clean_username !~ '^[A-Za-z0-9._-]+$' then
    raise exception '登入帳號需為 3 到 40 個英數字、句點、底線或連字號';
  end if;
  if char_length(coalesce(login_password, '')) < 6 or char_length(login_password) > 72 then
    raise exception '登入密碼必須是 6 到 72 個字元';
  end if;
  if employee_color !~ '^#[0-9A-Fa-f]{6}$' then raise exception '顏色格式不正確'; end if;
  insert into private.employees (name, login_username, password_hash, color)
  values (clean_name, clean_username, extensions.crypt(login_password, extensions.gen_salt('bf', 10)), employee_color)
  returning id into new_id;
  return jsonb_build_object('ok', true, 'employee_id', new_id);
exception when unique_violation then raise exception '這個姓名或登入帳號已經存在';
end;
$function$;

create or replace function public.admin_change_code(current_admin_code text, new_admin_code text)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare admin_hash text;
begin
  select c.admin_code_hash into admin_hash from private.app_config c where c.singleton;
  if admin_hash is null or extensions.crypt(coalesce(current_admin_code, ''), admin_hash) <> admin_hash then
    raise exception '目前管理密碼不正確';
  end if;
  if char_length(coalesce(new_admin_code, '')) < 1 or char_length(new_admin_code) > 64 then
    raise exception '新管理密碼至少需要 1 個字元';
  end if;
  update private.app_config set admin_code_hash = extensions.crypt(new_admin_code, extensions.gen_salt('bf', 10)), updated_at = now()
  where singleton;
  return jsonb_build_object('ok', true);
end;
$function$;

-- Range operations support both one-day and consecutive planned leave.
create or replace function public.register_leave_range_by_employee(
  selected_employee_id uuid,
  login_username text,
  login_password text,
  selected_start_date date,
  selected_end_date date
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  local_today date := timezone('Asia/Taipei', now())::date;
  stored_hash text;
  affected_count integer;
begin
  if extract(day from local_today) > 15 then
    raise exception '本月預休填寫已截止，次月 1 日重新開放';
  end if;
  if selected_start_date is null or selected_end_date is null then
    raise exception '請選擇開始與結束日期';
  end if;
  if selected_end_date < selected_start_date then
    raise exception '結束日期不可早於開始日期';
  end if;
  if selected_end_date - selected_start_date > 30 then
    raise exception '一次最多可登記連續 31 天';
  end if;
  if selected_start_date < (date_trunc('month', local_today)::date + interval '1 month')::date then
    raise exception '只能登記未來月份的預休';
  end if;
  if selected_end_date > local_today + 730 then
    raise exception '預休日期最多可登記兩年內';
  end if;

  select e.password_hash into stored_hash
  from private.employees e
  where e.id = selected_employee_id
    and e.active
    and lower(e.login_username) = lower(btrim(coalesce(register_leave_range_by_employee.login_username, '')));

  if stored_hash is null or extensions.crypt(coalesce(login_password, ''), stored_hash) <> stored_hash then
    raise exception '姓名、登入帳號或密碼不正確';
  end if;

  insert into private.leave_days (employee_id, leave_date)
  select selected_employee_id, day_value::date
  from generate_series(selected_start_date::timestamp, selected_end_date::timestamp, interval '1 day') as day_value
  on conflict (employee_id, leave_date) do nothing;
  get diagnostics affected_count = row_count;

  if affected_count = 0 then
    raise exception '選擇的日期都已經登記過了';
  end if;
  return jsonb_build_object('ok', true, 'affected_days', affected_count);
end;
$function$;

create or replace function public.delete_leave_range_by_employee(
  selected_employee_id uuid,
  login_username text,
  login_password text,
  selected_start_date date,
  selected_end_date date
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  local_today date := timezone('Asia/Taipei', now())::date;
  stored_hash text;
  affected_count integer;
begin
  if extract(day from local_today) > 15 then
    raise exception '本月預休填寫已截止，次月 1 日重新開放';
  end if;
  if selected_start_date is null or selected_end_date is null then
    raise exception '請選擇開始與結束日期';
  end if;
  if selected_end_date < selected_start_date then
    raise exception '結束日期不可早於開始日期';
  end if;
  if selected_end_date - selected_start_date > 30 then
    raise exception '一次最多可取消連續 31 天';
  end if;
  if selected_start_date < (date_trunc('month', local_today)::date + interval '1 month')::date then
    raise exception '只能取消未來月份的預休';
  end if;

  select e.password_hash into stored_hash
  from private.employees e
  where e.id = selected_employee_id
    and e.active
    and lower(e.login_username) = lower(btrim(coalesce(delete_leave_range_by_employee.login_username, '')));

  if stored_hash is null or extensions.crypt(coalesce(login_password, ''), stored_hash) <> stored_hash then
    raise exception '姓名、登入帳號或密碼不正確';
  end if;

  delete from private.leave_days
  where employee_id = selected_employee_id
    and leave_date between selected_start_date and selected_end_date;
  get diagnostics affected_count = row_count;

  if affected_count = 0 then
    raise exception '選擇的日期沒有可取消的預休';
  end if;
  return jsonb_build_object('ok', true, 'affected_days', affected_count);
end;
$function$;

revoke all on function public.register_leave_range_by_employee(uuid, text, text, date, date) from public, anon, authenticated;
revoke all on function public.delete_leave_range_by_employee(uuid, text, text, date, date) from public, anon, authenticated;

revoke all on function public.register_leave_range(uuid, text, text, date, date) from public, anon, authenticated;
revoke all on function public.delete_leave_range(uuid, text, text, date, date) from public, anon, authenticated;
drop function if exists public.register_leave_range(uuid, text, text, date, date);
drop function if exists public.delete_leave_range(uuid, text, text, date, date);

create function public.register_leave_range(
  login_username text,
  login_password text,
  selected_start_date date,
  selected_end_date date
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  local_today date := timezone('Asia/Taipei', now())::date;
  matched_employee_id uuid;
  stored_hash text;
  affected_count integer;
begin
  if extract(day from local_today) > 15 then
    raise exception '本月預休填寫已截止，次月 1 日重新開放';
  end if;
  if selected_start_date is null or selected_end_date is null then
    raise exception '請選擇開始日期與排休天數';
  end if;
  if selected_end_date < selected_start_date then
    raise exception '日期範圍不正確';
  end if;
  if selected_end_date - selected_start_date > 6 then
    raise exception '一次最多可登記連續 7 天';
  end if;
  if selected_start_date < (date_trunc('month', local_today)::date + interval '1 month')::date then
    raise exception '只能登記未來月份的預休';
  end if;
  if selected_end_date > local_today + 730 then
    raise exception '預休日期最多可登記兩年內';
  end if;

  select e.id, e.password_hash into matched_employee_id, stored_hash
  from private.employees e
  where e.active
    and lower(e.login_username) = lower(btrim(coalesce(register_leave_range.login_username, '')));

  if stored_hash is null or extensions.crypt(coalesce(login_password, ''), stored_hash) <> stored_hash then
    raise exception '登入帳號或密碼不正確';
  end if;

  insert into private.leave_days (employee_id, leave_date)
  select matched_employee_id, day_value::date
  from generate_series(selected_start_date::timestamp, selected_end_date::timestamp, interval '1 day') as day_value
  on conflict (employee_id, leave_date) do nothing;
  get diagnostics affected_count = row_count;

  if affected_count = 0 then
    raise exception '選擇的日期都已經登記過了';
  end if;
  return jsonb_build_object('ok', true, 'affected_days', affected_count);
end;
$function$;

create function public.delete_leave_range(
  login_username text,
  login_password text,
  selected_start_date date,
  selected_end_date date
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  local_today date := timezone('Asia/Taipei', now())::date;
  matched_employee_id uuid;
  stored_hash text;
  affected_count integer;
begin
  if extract(day from local_today) > 15 then
    raise exception '本月預休填寫已截止，次月 1 日重新開放';
  end if;
  if selected_start_date is null or selected_end_date is null then
    raise exception '請選擇開始日期與排休天數';
  end if;
  if selected_end_date < selected_start_date then
    raise exception '日期範圍不正確';
  end if;
  if selected_end_date - selected_start_date > 6 then
    raise exception '一次最多可取消連續 7 天';
  end if;
  if selected_start_date < (date_trunc('month', local_today)::date + interval '1 month')::date then
    raise exception '只能取消未來月份的預休';
  end if;

  select e.id, e.password_hash into matched_employee_id, stored_hash
  from private.employees e
  where e.active
    and lower(e.login_username) = lower(btrim(coalesce(delete_leave_range.login_username, '')));

  if stored_hash is null or extensions.crypt(coalesce(login_password, ''), stored_hash) <> stored_hash then
    raise exception '登入帳號或密碼不正確';
  end if;

  delete from private.leave_days
  where employee_id = matched_employee_id
    and leave_date between selected_start_date and selected_end_date;
  get diagnostics affected_count = row_count;

  if affected_count = 0 then
    raise exception '選擇的日期沒有可取消的預休';
  end if;
  return jsonb_build_object('ok', true, 'affected_days', affected_count);
end;
$function$;

revoke all on function public.register_leave_range(text, text, date, date) from public, anon, authenticated;
revoke all on function public.delete_leave_range(text, text, date, date) from public, anon, authenticated;
grant execute on function public.register_leave_range(text, text, date, date) to anon, authenticated;
grant execute on function public.delete_leave_range(text, text, date, date) to anon, authenticated;

create table if not exists private.employee_sessions (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references private.employees(id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index if not exists employee_sessions_employee_id_idx
  on private.employee_sessions (employee_id);

alter table private.employee_sessions enable row level security;
revoke all on table private.employee_sessions from public, anon, authenticated;

create or replace function public.login_employee(login_username text, login_password text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  matched_employee_id uuid;
  matched_employee_name text;
  stored_hash text;
  raw_token text := encode(extensions.gen_random_bytes(32), 'hex');
  session_expiry timestamptz := now() + interval '12 hours';
begin
  select e.id, e.name, e.password_hash
  into matched_employee_id, matched_employee_name, stored_hash
  from private.employees e
  where e.active
    and lower(e.login_username) = lower(btrim(coalesce(login_employee.login_username, '')));

  if stored_hash is null or extensions.crypt(coalesce(login_password, ''), stored_hash) <> stored_hash then
    raise exception '登入帳號或密碼不正確';
  end if;

  delete from private.employee_sessions
  where employee_id = matched_employee_id or expires_at <= now();

  insert into private.employee_sessions (employee_id, token_hash, expires_at)
  values (matched_employee_id, encode(extensions.digest(raw_token, 'sha256'), 'hex'), session_expiry);

  return jsonb_build_object(
    'session_token', raw_token,
    'employee_id', matched_employee_id,
    'employee_name', matched_employee_name,
    'expires_at', session_expiry
  );
end;
$function$;

create or replace function public.get_employee_session(session_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  matched_employee_id uuid;
  matched_employee_name text;
  session_expiry timestamptz;
begin
  select e.id, e.name, s.expires_at
  into matched_employee_id, matched_employee_name, session_expiry
  from private.employee_sessions s
  join private.employees e on e.id = s.employee_id
  where s.token_hash = encode(extensions.digest(coalesce(session_token, ''), 'sha256'), 'hex')
    and s.expires_at > now()
    and e.active;

  if matched_employee_id is null then raise exception '登入已過期，請重新登入'; end if;
  return jsonb_build_object('employee_id', matched_employee_id, 'employee_name', matched_employee_name, 'expires_at', session_expiry);
end;
$function$;

create or replace function public.logout_employee(session_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
begin
  delete from private.employee_sessions
  where token_hash = encode(extensions.digest(coalesce(session_token, ''), 'sha256'), 'hex');
  return jsonb_build_object('ok', true);
end;
$function$;

create or replace function public.toggle_leave_range(
  session_token text,
  selected_start_date date,
  duration_days integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  local_today date := timezone('Asia/Taipei', now())::date;
  matched_employee_id uuid;
  matched_employee_name text;
  selected_end_date date;
  existing_count integer;
  affected_count integer;
  result_action text;
begin
  select e.id, e.name into matched_employee_id, matched_employee_name
  from private.employee_sessions s
  join private.employees e on e.id = s.employee_id
  where s.token_hash = encode(extensions.digest(coalesce(session_token, ''), 'sha256'), 'hex')
    and s.expires_at > now()
    and e.active;

  if matched_employee_id is null then raise exception '登入已過期，請重新登入'; end if;
  if extract(day from local_today) > 15 then raise exception '本月預休填寫已截止，次月 1 日重新開放'; end if;
  if selected_start_date is null then raise exception '請選擇日期'; end if;
  if duration_days is null or duration_days < 1 or duration_days > 7 then raise exception '排休天數必須是 1 到 7 天'; end if;

  selected_end_date := selected_start_date + duration_days - 1;
  if selected_start_date < (date_trunc('month', local_today)::date + interval '1 month')::date then
    raise exception '只能修改未來月份的預休';
  end if;
  if selected_end_date > local_today + 730 then raise exception '預休日期最多可登記兩年內'; end if;

  select count(*) into existing_count
  from private.leave_days
  where employee_id = matched_employee_id
    and leave_date between selected_start_date and selected_end_date;

  if existing_count = duration_days then
    delete from private.leave_days
    where employee_id = matched_employee_id
      and leave_date between selected_start_date and selected_end_date;
    get diagnostics affected_count = row_count;
    result_action := 'removed';
  else
    insert into private.leave_days (employee_id, leave_date)
    select matched_employee_id, day_value::date
    from generate_series(selected_start_date::timestamp, selected_end_date::timestamp, interval '1 day') as day_value
    on conflict (employee_id, leave_date) do nothing;
    get diagnostics affected_count = row_count;
    result_action := 'added';
  end if;

  return jsonb_build_object(
    'ok', true,
    'action', result_action,
    'affected_days', affected_count,
    'employee_name', matched_employee_name
  );
end;
$function$;

revoke all on function public.login_employee(text, text) from public, anon, authenticated;
revoke all on function public.get_employee_session(text) from public, anon, authenticated;
revoke all on function public.logout_employee(text) from public, anon, authenticated;
revoke all on function public.toggle_leave_range(text, date, integer) from public, anon, authenticated;
grant execute on function public.login_employee(text, text) to anon, authenticated;
grant execute on function public.get_employee_session(text) to anon, authenticated;
grant execute on function public.logout_employee(text) to anon, authenticated;
grant execute on function public.toggle_leave_range(text, date, integer) to anon, authenticated;

revoke all on schema private from public, anon, authenticated;
revoke all on all tables in schema private from public, anon, authenticated;
revoke all on function public.get_employees() from public, anon, authenticated;
revoke all on function public.get_leave_days(date, date) from public, anon, authenticated;
revoke all on function public.get_edit_status() from public, anon, authenticated;
revoke all on function public.register_leave(uuid, text, text, date) from public, anon, authenticated;
revoke all on function public.delete_leave(uuid, text, text, date) from public, anon, authenticated;
revoke all on function public.admin_create_employee(text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.admin_change_code(text, text) from public, anon, authenticated;

grant execute on function public.get_employees() to anon, authenticated;
grant execute on function public.get_leave_days(date, date) to anon, authenticated;
grant execute on function public.get_edit_status() to anon, authenticated;
grant execute on function public.register_leave(uuid, text, text, date) to anon, authenticated;
grant execute on function public.delete_leave(uuid, text, text, date) to anon, authenticated;
grant execute on function public.admin_create_employee(text, text, text, text, text) to anon, authenticated;
grant execute on function public.admin_change_code(text, text) to anon, authenticated;
