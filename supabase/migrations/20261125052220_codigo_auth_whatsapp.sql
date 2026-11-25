-- =====================================================================
-- Código de verificación del celular por WhatsApp (sin proveedor de SMS)
--   Supabase Auth genera el código cuando la web/app verifica un celular
--   (updateUser({ phone }) o signInWithOtp({ phone })) y, en lugar de un SMS,
--   llama a este hook ("Send SMS Hook", tipo Postgres):
--     hooks.enviar_codigo_auth(evento) → {} y pide a la Edge Function
--     enviar-codigo-auth (por pg_net, con URL y token de Vault, como los
--     workers) que lo entregue por WhatsApp. En local llega al teléfono
--     simulado, con cualquier número.
--   Límite: 5 códigos por teléfono cada 10 minutos (además de los de Auth).
--   Se activa en supabase/config.toml [auth.hook.send_sms] y, en producción,
--   en el panel: Authentication → Hooks → Send SMS → Postgres.
--   Evento de Auth: { sms: { otp, phone }, user: { phone, new_phone, … }, metadata }
-- =====================================================================

create schema if not exists hooks;
revoke all on schema hooks from public, anon, authenticated, service_role;
grant usage on schema hooks to supabase_auth_admin;

create function hooks.enviar_codigo_auth(p_evento jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_telefono text := regexp_replace(coalesce(nullif(p_evento #>> '{sms,phone}', ''), nullif(p_evento #>> '{user,new_phone}', ''),
                                             p_evento #>> '{user,phone}', ''), '\D', '', 'g');
  v_codigo   text := p_evento #>> '{sms,otp}';
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
