-- Conflicto de versión (PT409), idempotencia, rate limit (PT429), cupo por
-- horario, validación de p_datos y "no existe" (PT404).
create extension if not exists pgtap with schema extensions;
begin;
select plan(14);
\ir ../helpers.psql


select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '2221110100', 'ia', 'canal') #>> '{sesion,interaccion_id}' as i \gset
select tests.registrar(:'i');
select api.iniciar_tramite(:'i', tests.estudio('BH')) ->> 'id' as t \gset

-- ---------------------------------------------------------------------
-- Dos canales con la misma versión: el segundo recibe PT409
-- ---------------------------------------------------------------------
select api.avanzar_tramite(:'i', :'t', 1, 'seleccion_clinica', jsonb_build_object('estudio_id', tests.estudio('BH')), 'idem-1')
       ->> 'version' as v \gset
select throws_ok(format('select api.avanzar_tramite(%L, %L, 1, %L, %L)', :'i', :'t', 'seleccion_clinica',
                        jsonb_build_object('estudio_id', tests.estudio('QS6'))),
                 'PT409', 'conflicto_de_version', 'Otro canal con una versión vieja recibe conflicto');

-- ---------------------------------------------------------------------
-- Idempotencia: el reintento de un webhook devuelve lo mismo sin repetir
-- ---------------------------------------------------------------------
select is(api.avanzar_tramite(:'i', :'t', 1, 'seleccion_clinica', jsonb_build_object('estudio_id', tests.estudio('BH')), 'idem-1')
          ->> 'version', :'v', 'Un reintento con la misma llave devuelve la misma respuesta');
select tests.como_postgres();
select is((select count(*)::int from core.eventos_tramite where tramite_id = :'t' and tipo_evento = 'paso_avanzado'), 1,
          'y no avanza el trámite dos veces');
select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '2221110101', 'ia', 'canal') #>> '{sesion,interaccion_id}' as i2 \gset
select tests.registrar(:'i2');
select api.iniciar_tramite(:'i2', tests.estudio('BH')) ->> 'id' as t2 \gset
select throws_ok(format('select api.avanzar_tramite(%L, %L, 1, %L, %L, %L)', :'i2', :'t2', 'seleccion_clinica',
                        jsonb_build_object('estudio_id', tests.estudio('BH')), 'idem-1'),
                 'PT409', 'clave_idempotencia_en_uso', 'Otro paciente con la misma llave no recibe la respuesta ajena');

-- ---------------------------------------------------------------------
-- Rate limit
-- ---------------------------------------------------------------------
select count(api.solicitar_otp(:'i')) from generate_series(1, 3);
select throws_ok(format('select api.solicitar_otp(%L)', :'i'), 'PT429', 'Demasiados códigos solicitados',
                 'Máximo 3 OTP cada 10 minutos');

-- 3 fechas de nacimiento equivocadas bloquean la verificación 15 minutos
select api.guardar_datos_paciente(:'i', 'Rosa', null, null, '1970-01-01') is not null as d \gset
select count(api.verificar_identidad(:'i', ('1999-0' || n || '-01')::date)) from generate_series(1, 3) n;
select throws_ok(format('select api.verificar_identidad(%L, %L)', :'i', '1970-01-01'), 'PT429', 'Verificación bloqueada temporalmente',
                 'Tras 3 fechas equivocadas la verificación queda bloqueada');

-- Pre-request de la Data API: anon tiene 30 peticiones por minuto por IP
select tests.como_anon();
select set_config('request.headers', '{"x-forwarded-for": "203.0.113.7"}', true) is not null as h \gset
select count(core.verificar_peticion()) from generate_series(1, 30);
select throws_ok('select core.verificar_peticion()', 'PT429', 'Demasiadas solicitudes', 'La petición 31 de la misma IP recibe 429');
select set_config('request.headers', '{"x-forwarded-for": "203.0.113.8"}', true) is not null as h \gset
select lives_ok('select core.verificar_peticion()', 'Otra IP no se ve afectada');
select tests.como_servicio();
select lives_ok('select core.verificar_peticion() from generate_series(1, 200)', 'service_role está exento');

-- ---------------------------------------------------------------------
-- Cupo por horario (imagen: 2 por horario)
-- ---------------------------------------------------------------------
select set_config('prueba.fecha', tests.en_dias(4)::text, true) is not null as f \gset
do $$
begin
  for n in 1 .. 2 loop
    declare
      v_int uuid := (api.iniciar_contacto('whatsapp', '22211102' || lpad(n::text, 2, '0'), 'ia', 'canal') #>> '{sesion,interaccion_id}')::uuid;
      v_t   uuid;
    begin
      perform tests.registrar(v_int);
      v_t := (api.iniciar_tramite(v_int, tests.estudio('US-OBS')) ->> 'id')::uuid;
      perform api.reservar_cita(v_int, v_t, tests.hasta_horario(v_int, v_t, 1, 'US-OBS'), current_setting('prueba.fecha')::timestamptz);
    end;
  end loop;
end $$;
select api.iniciar_contacto('whatsapp', '2221110299', 'ia', 'canal') #>> '{sesion,interaccion_id}' as i3 \gset
select tests.registrar(:'i3');
select api.iniciar_tramite(:'i3', tests.estudio('US-OBS')) ->> 'id' as t3 \gset
select tests.hasta_horario(:'i3', :'t3', 1, 'US-OBS') as v3 \gset
select throws_ok(format('select api.reservar_cita(%L, %L, %s, %L)', :'i3', :'t3', :v3, current_setting('prueba.fecha')),
                 'PT409', 'horario_sin_cupo', 'El tercer paciente en el mismo horario no tiene cupo');

-- ---------------------------------------------------------------------
-- p_datos solo acepta IDs conocidos (nada de texto libre)
-- ---------------------------------------------------------------------
select throws_ok(format($q$select api.avanzar_tramite(%L, %L, %s, 'seleccion_clinica', '{"notas": "tengo cáncer"}')$q$, :'i3', :'t3', :v3),
                 '22023', 'Datos no permitidos: notas. Solo se aceptan estudio_id, clinica_id y beneficiario_id',
                 'Una llave desconocida se rechaza');
select throws_ok(format($q$select api.avanzar_tramite(%L, %L, %s, 'seleccion_clinica', '{"estudio_id": "tengo cáncer"}')$q$, :'i3', :'t3', :v3),
                 '22023', 'Los valores de p_datos deben ser identificadores (uuid)', 'Un valor que no es uuid se rechaza');

-- ---------------------------------------------------------------------
-- "No existe" usa PT404 (HTTP 404). P0002 llegaba como HTTP 500.
-- ---------------------------------------------------------------------
select throws_ok($$select api.obtener_contexto('00000000-0000-0000-0000-000000000000')$$,
                 'PT404', 'Interacción no encontrada', 'Una interacción inexistente responde PT404');
select tests.como_postgres();
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname in ('api', 'core', 'audit') and p.prosrc like '%P0002%'), 0,
          'Ninguna función usa P0002 (PostgREST lo convierte en HTTP 500)');

select finish();
rollback;
