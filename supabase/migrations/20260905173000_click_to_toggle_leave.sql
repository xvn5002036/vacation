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
