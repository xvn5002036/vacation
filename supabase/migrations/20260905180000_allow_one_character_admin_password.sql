create or replace function public.admin_change_code(
  current_admin_code text,
  new_admin_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  admin_hash text;
begin
  select c.admin_code_hash into admin_hash
  from private.app_config c
  where c.singleton;

  if admin_hash is null or extensions.crypt(coalesce(current_admin_code, ''), admin_hash) <> admin_hash then
    raise exception '目前管理密碼不正確';
  end if;
  if char_length(coalesce(new_admin_code, '')) < 1 or char_length(new_admin_code) > 64 then
    raise exception '新管理密碼至少需要 1 個字元';
  end if;

  update private.app_config
  set admin_code_hash = extensions.crypt(new_admin_code, extensions.gen_salt('bf', 10)),
      updated_at = now()
  where singleton;

  return jsonb_build_object('ok', true);
end;
$function$;

revoke all on function public.admin_change_code(text, text) from public, anon, authenticated;
grant execute on function public.admin_change_code(text, text) to anon, authenticated;
