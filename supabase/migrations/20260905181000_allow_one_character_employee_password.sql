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
  if char_length(clean_name) < 1 or char_length(clean_name) > 30 then raise exception '姓名必須是 1 到 30 個字'; end if;
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

revoke all on function public.admin_create_employee(text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.admin_create_employee(text, text, text, text, text) to anon, authenticated;
