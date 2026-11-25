-- Rate limit de las Edge Functions (service_role) por teléfono del paciente,
-- declarado en el header x-sd-telefono. Y la API solo acepta POST (PT405).
create extension if not exists pgtap with schema extensions;
begin;
select plan(9);
\ir ../helpers.psql

select tests.como_servicio();

-- Sin header: tareas internas exentas
select set_config('request.headers', '{}', true) is not null as h \gset
select lives_ok('select core.verificar_peticion() from generate_series(1, 200)',
                'Sin x-sd-telefono, service_role sigue exento');

-- Con header: 300 peticiones por minuto por teléfono (red de seguridad; el límite real es por mensaje)
select set_config('request.headers', '{"x-sd-telefono": "5212221110500"}', true) is not null as h \gset
select lives_ok('select core.verificar_peticion() from generate_series(1, 300)', '300 peticiones del mismo teléfono pasan');
select throws_ok('select core.verificar_peticion()', 'PT429', 'Demasiadas solicitudes', 'La 301 recibe PT429');

-- El mismo número en otro formato cuenta en el mismo contador
select set_config('request.headers', '{"x-sd-telefono": "222 111 0500"}', true) is not null as h \gset
select throws_ok('select core.verificar_peticion()', 'PT429', 'Demasiadas solicitudes',
                 'El mismo teléfono escrito distinto comparte contador');

-- Otro teléfono no se ve afectado
select set_config('request.headers', '{"x-sd-telefono": "2221110501"}', true) is not null as h \gset
select lives_ok('select core.verificar_peticion()', 'Otro teléfono tiene su propio cupo');

-- Header inválido
select set_config('request.headers', '{"x-sd-telefono": "abc"}', true) is not null as h \gset
select throws_ok('select core.verificar_peticion()', '22023', 'Header x-sd-telefono inválido', 'Un teléfono inválido se rechaza');

-- Los pacientes siguen contándose por su usuario, no por el header
select tests.como_paciente('00000000-0000-0000-0000-00000000f090');
select set_config('request.headers', '{"x-sd-telefono": "5212221110500"}', true) is not null as h \gset
select lives_ok('select core.verificar_peticion()', 'Un paciente no puede usar el header para cambiar de contador');

-- Toda petición de solo lectura (GET/HEAD en PostgREST) se rechaza, para todos los roles.
-- Va al final: la transacción ya no puede volver a lectura-escritura.
select tests.como_servicio();
set transaction_read_only = on;
select throws_ok('select core.verificar_peticion()', 'PT405', 'Usa POST', 'service_role por GET recibe PT405');
select tests.como_anon();
select throws_ok('select core.verificar_peticion()', 'PT405', 'Usa POST', 'anon por GET recibe PT405');

select finish();
rollback;
