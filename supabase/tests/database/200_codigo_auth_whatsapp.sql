-- Código de verificación del celular por WhatsApp: el Send SMS Hook de Auth.
create extension if not exists pgtap with schema extensions;
begin;
select plan(11);
\ir ../helpers.psql

-- Solo Auth puede ejecutarlo
select ok(has_function_privilege('supabase_auth_admin', 'hooks.enviar_codigo_auth(jsonb)', 'execute'), 'Auth (supabase_auth_admin) ejecuta el hook');
select ok(not has_function_privilege('anon', 'hooks.enviar_codigo_auth(jsonb)', 'execute')
          and not has_function_privilege('authenticated', 'hooks.enviar_codigo_auth(jsonb)', 'execute')
          and not has_function_privilege('service_role', 'hooks.enviar_codigo_auth(jsonb)', 'execute'),
          'nadie más (anon, authenticated, service_role)');
select ok(not has_schema_privilege('anon', 'hooks', 'usage'), 'el esquema hooks no se expone');

-- Evento como lo manda Auth: el código se pide a la Edge Function por pg_net
select count(*) as antes from net.http_request_queue \gset
select is(hooks.enviar_codigo_auth('{"sms": {"otp": "481516", "phone": "525512340001"}, "user": {"phone": "", "new_phone": "525512340001"}}'),
          '{}'::jsonb, 'Responde {} a Auth');
select is((select count(*) from net.http_request_queue) - :antes, 1::bigint, 'y encola una llamada');
select q.url as url, convert_from(q.body, 'utf8')::jsonb as cuerpo, q.headers as cab
from net.http_request_queue q order by q.id desc limit 1 \gset
select matches(:'url'::text, '/functions/v1/enviar-codigo-auth$', 'a la Edge Function enviar-codigo-auth');
select is((:'cuerpo')::jsonb, '{"telefono": "525512340001", "codigo": "481516"}', 'con teléfono y código');
select ok((:'cab')::jsonb ->> 'Authorization' = 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'worker_token'),
          'autenticada con el worker_token de Vault');

-- Datos incompletos
select is(hooks.enviar_codigo_auth('{"sms": {"otp": ""}, "user": {"phone": "525512340002"}}') #>> '{error,http_code}', '400',
          'Sin código: error 400 para Auth');
select is(hooks.enviar_codigo_auth('{"sms": {"otp": "111111"}, "user": {"phone": "", "new_phone": "+52 55 1234 0003"}}'), '{}'::jsonb,
          'Sin sms.phone usa user.new_phone (y limpia + y espacios)');

-- Límite: 5 códigos por teléfono cada 10 minutos
select count(hooks.enviar_codigo_auth('{"sms": {"otp": "222222", "phone": "525512340004"}}')) from generate_series(1, 5);
select is(hooks.enviar_codigo_auth('{"sms": {"otp": "222222", "phone": "525512340004"}}') #>> '{error,http_code}', '429',
          'El sexto código en 10 minutos: 429');

select finish();
rollback;
