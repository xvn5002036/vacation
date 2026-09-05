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
