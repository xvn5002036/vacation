create or replace function public.admin_get_manageable_employees(admin_code text)
returns table (
  employee_id uuid,
  employee_name text,
  login_username text,
  color text
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  admin_hash text;
begin
  select c.admin_code_hash into admin_hash
  from private.app_config c
  where c.singleton;

  if admin_hash is null or extensions.crypt(coalesce(admin_code, ''), admin_hash) <> admin_hash then
    raise exception '管理密碼不正確';
  end if;

  return query
  select e.id, e.name, e.login_username, e.color
  from private.employees e
  where e.active
  order by e.created_at, e.name;
end;
$function$;

create or replace function public.admin_update_employee_name(
  admin_code text,
  employee_id uuid,
  new_employee_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  admin_hash text;
  clean_name text := btrim(coalesce(new_employee_name, ''));
  updated_id uuid;
begin
  select c.admin_code_hash into admin_hash
  from private.app_config c
  where c.singleton;

  if admin_hash is null or extensions.crypt(coalesce(admin_code, ''), admin_hash) <> admin_hash then
    raise exception '管理密碼不正確';
  end if;
  if char_length(clean_name) <> 3 then
    raise exception '姓名必須剛好是 3 個字';
  end if;

  update private.employees e
  set name = clean_name
  where e.id = employee_id and e.active
  returning e.id into updated_id;

  if updated_id is null then
    raise exception '找不到這位員工';
  end if;

  return jsonb_build_object(
    'ok', true,
    'employee_id', updated_id,
    'employee_name', clean_name
  );
exception
  when unique_violation then raise exception '這個姓名已經存在';
end;
$function$;

revoke all on function public.admin_get_manageable_employees(text) from public, anon, authenticated;
revoke all on function public.admin_update_employee_name(text, uuid, text) from public, anon, authenticated;
grant execute on function public.admin_get_manageable_employees(text) to anon, authenticated;
grant execute on function public.admin_update_employee_name(text, uuid, text) to anon, authenticated;
