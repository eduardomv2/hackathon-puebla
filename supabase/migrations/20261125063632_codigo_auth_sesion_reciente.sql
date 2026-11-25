-- =====================================================================
-- Código del celular: gana la sesión que lo pidió al último
--   Si la paciente recarga la página mientras espera el código, la web crea
--   otra sesión anónima y vuelve a pedirlo: quedan DOS usuarios esperando el
--   mismo número (auth.users.phone_change). Al verificar, Auth busca por
--   número, toma el primero (el viejo) y responde "token has expired or is
--   invalid" aunque el código sea el correcto.
--   Arreglo: al pedir un código para un número, el hook le quita ese número
--   pendiente (y su token) a cualquier OTRO usuario que lo estuviera esperando.
-- =====================================================================

create or replace function hooks.enviar_codigo_auth(p_evento jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_telefono text := regexp_replace(coalesce(nullif(p_evento #>> '{sms,phone}', ''), nullif(p_evento #>> '{user,new_phone}', ''),
                                             p_evento #>> '{user,phone}', ''), '\D', '', 'g');
  v_codigo   text := p_evento #>> '{sms,otp}';
  v_usuario  uuid;
  v_url      text;
  v_token    text;
begin
  if v_telefono !~ '^\d{10,15}$' or coalesce(v_codigo, '') !~ '^\d{4,10}$' then
    return jsonb_build_object('error', jsonb_build_object('http_code', 400, 'message', 'Faltan el teléfono o el código'));
  end if;
  if not core.consumir_limite('codigo_auth:' || v_telefono, 5, 600) then
    return jsonb_build_object('error', jsonb_build_object('http_code', 429,
      'message', 'Pediste muchos códigos para este número. Espera 10 minutos e intenta de nuevo.'));
  end if;

  -- Solo la sesión que pide este código queda esperando el número
  if p_evento #>> '{user,id}' ~ '^[0-9a-f-]{36}$' then
    v_usuario := (p_evento #>> '{user,id}')::uuid;
    update auth.users
       set phone_change = '', phone_change_token = '', phone_change_sent_at = null
     where regexp_replace(coalesce(phone_change, ''), '\D', '', 'g') = v_telefono
       and id <> v_usuario;
    delete from auth.one_time_tokens
     where token_type = 'phone_change_token'
       and regexp_replace(relates_to, '\D', '', 'g') = v_telefono
       and user_id <> v_usuario;
  end if;

  select decrypted_secret into v_url   from vault.decrypted_secrets where name = 'project_url';
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'worker_token';
  if v_url is null or v_token is null then
    return jsonb_build_object('error', jsonb_build_object('http_code', 500,
      'message', 'No está configurado el envío de códigos (project_url y worker_token en Vault).'));
  end if;
  perform net.http_post(
    url     := v_url || '/functions/v1/enviar-codigo-auth',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_token),
    body    := jsonb_build_object('telefono', v_telefono, 'codigo', v_codigo));
  return '{}'::jsonb;
end
$$;

revoke execute on function hooks.enviar_codigo_auth(jsonb) from public, anon, authenticated, service_role;
grant execute on function hooks.enviar_codigo_auth(jsonb) to supabase_auth_admin;
