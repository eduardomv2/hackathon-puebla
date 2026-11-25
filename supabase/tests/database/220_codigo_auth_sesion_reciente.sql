-- Código del celular: si dos sesiones esperan el mismo número, gana la que pidió el código al último.
create extension if not exists pgtap with schema extensions;
begin;
select plan(5);
\ir ../helpers.psql

\set vieja  '00000000-0000-0000-0000-00000000a220'
\set nueva  '00000000-0000-0000-0000-00000000a221'
\set otra   '00000000-0000-0000-0000-00000000a222'

-- La paciente pidió código (sesión vieja), recargó la página (sesión nueva) y lo pidió otra vez.
-- Otra persona espera un número distinto.
insert into auth.users (id, aud, role, is_anonymous, phone_change, phone_change_token, phone_change_sent_at) values
  (:'vieja', 'authenticated', 'authenticated', true, '525512340220', 'hash-viejo', now() - interval '2 minutes'),
  (:'nueva', 'authenticated', 'authenticated', true, '525512340220', 'hash-nuevo', now()),
  (:'otra',  'authenticated', 'authenticated', true, '525512340299', 'hash-otra',  now());
insert into auth.one_time_tokens (id, user_id, token_type, token_hash, relates_to) values
  (gen_random_uuid(), :'vieja', 'phone_change_token', 'hash-viejo', '525512340220'),
  (gen_random_uuid(), :'nueva', 'phone_change_token', 'hash-nuevo', '525512340220');

select is(hooks.enviar_codigo_auth(jsonb_build_object(
            'sms', jsonb_build_object('otp', '220220', 'phone', '525512340220'),
            'user', jsonb_build_object('id', :'nueva', 'phone', '', 'new_phone', '525512340220'))),
          '{}'::jsonb, 'El hook envía el código de la sesión nueva');

select is((select phone_change from auth.users where id = :'vieja'), '', 'La sesión vieja deja de esperar ese número');
select is((select count(*)::int from auth.one_time_tokens where user_id = :'vieja'), 0, 'y pierde su token');
select is((select phone_change || ' ' || phone_change_token from auth.users where id = :'nueva'), '525512340220 hash-nuevo',
          'La sesión nueva lo conserva (solo ella queda esperando)');
select is((select phone_change from auth.users where id = :'otra'), '525512340299', 'Otro número no se toca');

select finish();
rollback;
