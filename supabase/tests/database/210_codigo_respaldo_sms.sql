-- Código de verificación: se guarda (cifrado, 10 min, un solo uso) para mandarlo por SMS
-- si Meta avisa que no se entregó por WhatsApp.
create extension if not exists pgtap with schema extensions;
begin;
select plan(10);
\ir ../helpers.psql

select tests.como_servicio();
select api.registrar_codigo_enviado('wamid.prueba1', '525512340010', '765432');
select api.registrar_codigo_enviado('wamid.prueba2', '525512340011', '111222');

select tests.como_postgres();
select ok((select codigo_cifrado from core.codigos_enviados where mensaje_id = 'wamid.prueba1') is not null
          and position('765432' in encode((select codigo_cifrado from core.codigos_enviados where mensaje_id = 'wamid.prueba1'), 'escape')) = 0,
          'El código se guarda cifrado');
select is((select expira_en - enviado_en from core.codigos_enviados where mensaje_id = 'wamid.prueba1'), interval '10 minutes',
          'y vence en 10 minutos');

-- Falló la entrega: devuelve el código una sola vez
select tests.como_servicio();
select is(api.resolver_codigo_enviado('wamid.prueba1', false), '{"telefono": "525512340010", "codigo": "765432"}',
          'WhatsApp falló: devuelve teléfono y código para el SMS');
select is(api.resolver_codigo_enviado('wamid.prueba1', false), null, 'de un solo uso');

-- Entregado: no devuelve nada y se borra
select is(api.resolver_codigo_enviado('wamid.prueba2', true), null, 'Entregado: no hay SMS');
select tests.como_postgres();
select is((select count(*)::int from core.codigos_enviados where mensaje_id = 'wamid.prueba2'), 0, 'y ya no se guarda');

-- Vencido: aunque falle, no se reenvía
select tests.como_servicio();
select api.registrar_codigo_enviado('wamid.prueba3', '525512340012', '333444');
select tests.como_postgres();
update core.codigos_enviados set expira_en = now() - interval '1 second' where mensaje_id = 'wamid.prueba3';
select tests.como_servicio();
select is(api.resolver_codigo_enviado('wamid.prueba3', false), null, 'Vencido: no se manda por SMS');

-- Datos y permisos
select throws_ok($$select api.registrar_codigo_enviado('wamid.x', '123', '765432')$$, '22023', null, 'Teléfono inválido: 22023');
select tests.como_anon();
select throws_ok($$select api.resolver_codigo_enviado('wamid.prueba1', false)$$, '42501', null, 'anon no los lee');
select tests.como_postgres();
select ok(not has_function_privilege('authenticated', 'api.resolver_codigo_enviado(text, boolean)', 'execute'),
          'ni un usuario con sesión');

select finish();
rollback;
