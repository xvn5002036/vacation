create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists private;

create table private.employees (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  employee_code_hash text not null,
  color text not null default '#2563eb' check (color ~ '^#[0-9A-Fa-f]{6}$'),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

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
language sql
stable
security definer
set search_path = ''
as $$
  select e.id, e.name, e.color
  from private.employees e
  where e.active
  order by e.created_at, e.name;
$$;

create or replace function public.get_leave_days(
  start_date date,
  end_date date
)
returns table (
  leave_id bigint,
  employee_id uuid,
  employee_name text,
  leave_date date,
  color text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if start_date is null or end_date is null or end_date < start_date then
    raise exception '日期範圍不正確';
  end if;
  if end_date - start_date > 62 then
    raise exception '一次最多查詢 63 天';
  end if;

  return query
  select l.id, e.id, e.name, l.leave_date, e.color
  from private.leave_days l
  join private.employees e on e.id = l.employee_id
  where e.active and l.leave_date between start_date and end_date
  order by l.leave_date, e.created_at, e.name;
end;
$$;

create or replace function public.register_leave(
  selected_employee_id uuid,
  employee_code text,
  selected_date date
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  stored_hash text;
  new_id bigint;
begin
  if selected_date is null then
    raise exception '請選擇休假日期';
  end if;
  if selected_date < current_date - 31 or selected_date > current_date + 730 then
    raise exception '休假日期超出可登記範圍';
  end if;

  select e.employee_code_hash into stored_hash
  from private.employees e
  where e.id = selected_employee_id and e.active;

  if stored_hash is null or extensions.crypt(coalesce(employee_code, ''), stored_hash) <> stored_hash then
    raise exception '姓名或員工編號不正確';
  end if;

  insert into private.leave_days (employee_id, leave_date)
  values (selected_employee_id, selected_date)
  on conflict (employee_id, leave_date) do nothing
  returning id into new_id;

  if new_id is null then
    raise exception '這一天已經登記過了';
  end if;

  return jsonb_build_object('ok', true, 'leave_id', new_id);
end;
$$;

create or replace function public.admin_create_employee(
  admin_code text,
  employee_name text,
  employee_code text,
  employee_color text default '#2563eb'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  admin_hash text;
  clean_name text := btrim(coalesce(employee_name, ''));
  new_id uuid;
begin
  select c.admin_code_hash into admin_hash
  from private.app_config c
  where c.singleton;

  if admin_hash is null or extensions.crypt(coalesce(admin_code, ''), admin_hash) <> admin_hash then
    raise exception '管理密碼不正確';
  end if;
  if char_length(clean_name) < 1 or char_length(clean_name) > 30 then
    raise exception '姓名必須是 1 到 30 個字';
  end if;
  if char_length(coalesce(employee_code, '')) < 4 or char_length(employee_code) > 32 then
    raise exception '員工編號必須是 4 到 32 個字元';
  end if;
  if employee_color !~ '^#[0-9A-Fa-f]{6}$' then
    raise exception '顏色格式不正確';
  end if;

  insert into private.employees (name, employee_code_hash, color)
  values (clean_name, extensions.crypt(employee_code, extensions.gen_salt('bf', 10)), employee_color)
  returning id into new_id;

  return jsonb_build_object('ok', true, 'employee_id', new_id);
exception
  when unique_violation then
    raise exception '這個姓名已經存在';
end;
$$;

create or replace function public.admin_change_code(
  current_admin_code text,
  new_admin_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  admin_hash text;
begin
  select c.admin_code_hash into admin_hash
  from private.app_config c
  where c.singleton;

  if admin_hash is null or extensions.crypt(coalesce(current_admin_code, ''), admin_hash) <> admin_hash then
    raise exception '目前管理密碼不正確';
  end if;
  if char_length(coalesce(new_admin_code, '')) < 8 or char_length(new_admin_code) > 64 then
    raise exception '新管理密碼至少需要 8 個字元';
  end if;

  update private.app_config
  set admin_code_hash = extensions.crypt(new_admin_code, extensions.gen_salt('bf', 10)),
      updated_at = now()
  where singleton;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on schema private from public, anon, authenticated;
revoke all on all tables in schema private from public, anon, authenticated;
revoke all on function public.get_employees() from public, anon, authenticated;
revoke all on function public.get_leave_days(date, date) from public, anon, authenticated;
revoke all on function public.register_leave(uuid, text, date) from public, anon, authenticated;
revoke all on function public.admin_create_employee(text, text, text, text) from public, anon, authenticated;
revoke all on function public.admin_change_code(text, text) from public, anon, authenticated;

grant execute on function public.get_employees() to anon, authenticated;
grant execute on function public.get_leave_days(date, date) to anon, authenticated;
grant execute on function public.register_leave(uuid, text, date) to anon, authenticated;
grant execute on function public.admin_create_employee(text, text, text, text) to anon, authenticated;
grant execute on function public.admin_change_code(text, text) to anon, authenticated;

