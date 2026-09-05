-- Employee accounts plus the monthly planned-leave editing window.

revoke all on function public.register_leave(uuid, text, date) from public, anon, authenticated;
revoke all on function public.admin_create_employee(text, text, text, text) from public, anon, authenticated;
drop function if exists public.register_leave(uuid, text, date);
drop function if exists public.admin_create_employee(text, text, text, text);

alter table private.employees add column if not exists login_username text;
alter table private.employees add column if not exists password_hash text;

-- Preserve existing accounts: the former employee number remains their initial password,
-- and their current name becomes the initial login username.
update private.employees
set login_username = name,
    password_hash = employee_code_hash
where login_username is null or password_hash is null;

alter table private.employees alter column login_username set not null;
alter table private.employees alter column password_hash set not null;
create unique index if not exists employees_login_username_lower_key
  on private.employees (lower(login_username));
alter table private.employees drop column if exists employee_code_hash;

create or replace function public.get_edit_status()
returns table (
  today_date date,
  editing_open boolean,
  deadline_date date,
  next_open_date date
)
language sql
stable
security definer
set search_path = ''
as $function$
  with local_clock as (
    select timezone('Asia/Taipei', now())::date as today
  )
  select
    today,
    extract(day from today) <= 15,
    (date_trunc('month', today)::date + 14),
    (date_trunc('month', today)::date + interval '1 month')::date
  from local_clock;
$function$;

create or replace function public.register_leave(
  selected_employee_id uuid,
  login_username text,
  login_password text,
  selected_date date
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  local_today date := timezone('Asia/Taipei', now())::date;
  stored_hash text;
  new_id bigint;
begin
  if extract(day from local_today) > 15 then
    raise exception '本月預休填寫已截止，次月 1 日重新開放';
  end if;
  if selected_date is null then
    raise exception '請選擇預休日期';
  end if;
  if selected_date < (date_trunc('month', local_today)::date + interval '1 month')::date then
    raise exception '只能登記未來月份的預休';
  end if;
  if selected_date > local_today + 730 then
    raise exception '預休日期最多可登記兩年內';
  end if;

  select e.password_hash into stored_hash
  from private.employees e
  where e.id = selected_employee_id
    and e.active
    and lower(e.login_username) = lower(btrim(coalesce(register_leave.login_username, '')));

  if stored_hash is null or extensions.crypt(coalesce(login_password, ''), stored_hash) <> stored_hash then
    raise exception '姓名、登入帳號或密碼不正確';
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
$function$;

create or replace function public.delete_leave(
  selected_employee_id uuid,
  login_username text,
  login_password text,
  selected_date date
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  local_today date := timezone('Asia/Taipei', now())::date;
  stored_hash text;
  removed_id bigint;
begin
  if extract(day from local_today) > 15 then
    raise exception '本月預休填寫已截止，次月 1 日重新開放';
  end if;
  if selected_date is null then
    raise exception '請選擇預休日期';
  end if;
  if selected_date < (date_trunc('month', local_today)::date + interval '1 month')::date then
    raise exception '只能取消未來月份的預休';
  end if;

  select e.password_hash into stored_hash
  from private.employees e
  where e.id = selected_employee_id
    and e.active
    and lower(e.login_username) = lower(btrim(coalesce(delete_leave.login_username, '')));

  if stored_hash is null or extensions.crypt(coalesce(login_password, ''), stored_hash) <> stored_hash then
    raise exception '姓名、登入帳號或密碼不正確';
  end if;

  delete from private.leave_days
  where employee_id = selected_employee_id and leave_date = selected_date
  returning id into removed_id;

  if removed_id is null then
    raise exception '這一天沒有可取消的預休';
  end if;

  return jsonb_build_object('ok', true, 'leave_id', removed_id);
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
  select c.admin_code_hash into admin_hash
  from private.app_config c
  where c.singleton;

  if admin_hash is null or extensions.crypt(coalesce(admin_code, ''), admin_hash) <> admin_hash then
    raise exception '管理密碼不正確';
  end if;
  if char_length(clean_name) < 1 or char_length(clean_name) > 30 then
    raise exception '姓名必須是 1 到 30 個字';
  end if;
  if char_length(clean_username) < 3 or char_length(clean_username) > 40
     or clean_username !~ '^[A-Za-z0-9._-]+$' then
    raise exception '登入帳號需為 3 到 40 個英數字、句點、底線或連字號';
  end if;
  if char_length(coalesce(login_password, '')) < 6 or char_length(login_password) > 72 then
    raise exception '登入密碼必須是 6 到 72 個字元';
  end if;
  if employee_color !~ '^#[0-9A-Fa-f]{6}$' then
    raise exception '顏色格式不正確';
  end if;

  insert into private.employees (name, login_username, password_hash, color)
  values (clean_name, clean_username, extensions.crypt(login_password, extensions.gen_salt('bf', 10)), employee_color)
  returning id into new_id;

  return jsonb_build_object('ok', true, 'employee_id', new_id);
exception
  when unique_violation then
    raise exception '這個姓名或登入帳號已經存在';
end;
$function$;

revoke all on function public.get_edit_status() from public, anon, authenticated;
revoke all on function public.register_leave(uuid, text, text, date) from public, anon, authenticated;
revoke all on function public.delete_leave(uuid, text, text, date) from public, anon, authenticated;
revoke all on function public.admin_create_employee(text, text, text, text, text) from public, anon, authenticated;

grant execute on function public.get_edit_status() to anon, authenticated;
grant execute on function public.register_leave(uuid, text, text, date) to anon, authenticated;
grant execute on function public.delete_leave(uuid, text, text, date) to anon, authenticated;
grant execute on function public.admin_create_employee(text, text, text, text, text) to anon, authenticated;
