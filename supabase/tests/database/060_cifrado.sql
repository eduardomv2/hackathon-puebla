-- Cifrado a nivel columna: el texto de salud no queda legible en la tabla ni
-- en la bitácora; el contexto sí lo devuelve; la rotación no rompe nada.
create extension if not exists pgtap with schema extensions;
begin;
select plan(14);
\ir ../helpers.psql

select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '2221110080', 'ia', 'canal') #>> '{sesion,interaccion_id}' as i \gset
select tests.registrar(:'i');
select api.iniciar_tramite(:'i', tests.estudio('BH')) ->> 'id' as t \gset
select api.registrar_mensaje(:'i', 'entrante', 'paciente', 'Tengo VIH-PRUEBA y necesito estudios') is not null as m1 \gset
select api.registrar_mensaje(:'i', 'saliente', 'agente_ia', 'Claro, te ayudo con VIH-PRUEBA') is not null as m2 \gset
select api.guardar_resumen(:'t', 'Paciente con VIH-PRUEBA busca estudios', now()) is null as g \gset

-- Un select directo como postgres no ve el texto
select tests.como_postgres();
select is((select count(*)::int from core.mensajes m where m::text like '%VIH-PRUEBA%'), 0,
          'core.mensajes no contiene el texto original');
select is((select count(*)::int from core.tramites x where x::text like '%VIH-PRUEBA%'), 0,
          'core.tramites no contiene el resumen original');
select is((select count(*)::int from audit.registro r where r::text like '%VIH-PRUEBA%'), 0,
          'La bitácora no tiene texto en claro');
select is((select despues ->> 'resumen_cifrado' from audit.registro
           where tabla = 'core.tramites' and 'resumen_cifrado' = any (campos_cambiados) limit 1), '[cifrado]',
          'La bitácora registra que cambió el resumen, sin copiar su valor');

-- El contexto (función api autorizada) sí lo devuelve
select tests.como_servicio();
select api.obtener_contexto(:'i') as ctx \gset
select is((:'ctx')::jsonb #>> '{mensajes_recientes,0,contenido}', 'Tengo VIH-PRUEBA y necesito estudios', 'El contexto descifra los mensajes');
select is((:'ctx')::jsonb #>> '{tramite_activo,resumen}', 'Paciente con VIH-PRUEBA busca estudios', 'y el resumen');

-- Rotación v1 → v2 por lotes
select tests.como_postgres();
select vault.create_secret(encode(extensions.gen_random_bytes(32), 'base64'), 'clave_cifrado_v2') is not null as k \gset
select is(core.rotar_clave(2::smallint, 1) ->> 'pendiente', 'true', 'La rotación avanza por lotes');
select is((select count(distinct clave_version)::int from core.mensajes), 2,
          'A media rotación conviven las versiones 1 y 2');
select tests.como_servicio();
select is(jsonb_array_length(api.obtener_contexto(:'i') -> 'mensajes_recientes'), 2, 'y todo sigue legible');
select tests.como_postgres();
select core.continuar_rotacion();
select is((select count(*)::int from core.mensajes where clave_version < 2)
          + (select count(*)::int from core.tramites where resumen_clave_version < 2), 0, 'pg_cron termina la rotación');
select tests.como_servicio();
select is(api.obtener_contexto(:'i') #>> '{tramite_activo,resumen}', 'Paciente con VIH-PRUEBA busca estudios',
          'Después de rotar todo sigue legible');

-- Sin llave: error claro, nunca texto vacío
select tests.como_postgres();
select throws_ok('select core.rotar_clave(9::smallint)', 'XX000', 'Falta la llave de cifrado clave_cifrado_v9 en Supabase Vault',
                 'Si falta la llave el error lo dice');

-- La respuesta guardada para idempotencia no copia el resumen
select tests.como_servicio();
select api.avanzar_tramite(:'i', :'t', 1, 'seleccion_clinica', jsonb_build_object('estudio_id', tests.estudio('BH')), 'idem-cifrado')
       is not null as a \gset
select is(api.avanzar_tramite(:'i', :'t', 1, 'seleccion_clinica', '{}', 'idem-cifrado') ->> 'resumen',
          'Paciente con VIH-PRUEBA busca estudios', 'Al repetir con la misma llave se devuelve el resumen actual');
select tests.como_postgres();
select ok(not (select resultado ? 'resumen' from core.idempotencia where clave = 'idem-cifrado'),
          'pero core.idempotencia no guarda una copia en claro');

select finish();
rollback;
