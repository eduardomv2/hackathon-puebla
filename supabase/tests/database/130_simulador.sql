-- Bandeja del teléfono simulado (solo pruebas): apagada por defecto.
create extension if not exists pgtap with schema extensions;
begin;
select plan(8);
\ir ../helpers.psql

select is((select column_default from information_schema.columns
           where table_schema = 'simulador' and table_name = 'config' and column_name = 'habilitado'), 'false',
          'Las migraciones la dejan apagada (solo seed.sql la enciende)');

-- Apagada: nada funciona
select tests.como_postgres();
update simulador.config set habilitado = false;
select tests.como_servicio();
select throws_ok($$select simulador.enviar('528669990001', 'otp', 'Tu código es 123456')$$,
                 '42501', 'El simulador está apagado (solo existe en desarrollo local)', 'Apagada, no se puede escribir');
select tests.como_anon();
select throws_ok($$select simulador.leer('528669990001')$$,
                 '42501', 'El simulador está apagado (solo existe en desarrollo local)', 'ni leer');

-- Encendida
select tests.como_postgres();
update simulador.config set habilitado = true;
select tests.como_servicio();
select lives_ok($$select simulador.enviar('528669990001', 'otp', 'Tu código es 123456')$$, 'Encendida, la Edge Function escribe');
select tests.como_anon();
select is(simulador.leer('866 999 0001') -> -1 ->> 'contenido', 'Tu código es 123456',
          'y el teléfono simulado lee (el número se normaliza)');
select throws_ok($$select simulador.enviar('528669990001', 'bot', 'falso')$$, '42501', null,
                 'El navegador (anon) no puede escribir en la bandeja');

-- Limpieza: nada dura más de 1 hora
select tests.como_postgres();
insert into simulador.bandeja (telefono, tipo, contenido, creado_en)
values ('+528669990001', 'bot', 'mensaje viejo', now() - interval '2 hours');
select simulador.limpiar() as borrados \gset
select ok(not exists (select 1 from simulador.bandeja where contenido = 'mensaje viejo'),
          'pg_cron borra lo que tiene más de 1 hora');
select is((select count(*)::int from simulador.bandeja where telefono = '+528669990001'), 1, 'y conserva lo reciente');

select finish();
rollback;
