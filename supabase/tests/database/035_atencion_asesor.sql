-- El asesor manda: el trámite que toma queda bloqueado para su interacción.
-- Los demás canales lo ven pero no lo cambian (PT423).
create extension if not exists pgtap with schema extensions;
begin;
select plan(13);
\ir ../helpers.psql

\set a1  '00000000-0000-0000-0000-00000000c350'
\set a2  '00000000-0000-0000-0000-00000000c351'
\set web '00000000-0000-0000-0000-00000000a350'
select tests.crear_staff(:'a1', 'asesor');
select tests.crear_staff(:'a2', 'asesor');
select tests.crear_usuario(:'web', false, '528661234590');

-- La paciente tiene un trámite por WhatsApp
select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '5218661234590', 'ia', 'canal') #>> '{sesion,interaccion_id}' as wa \gset
select tests.registrar(:'wa');
select api.iniciar_tramite(:'wa', tests.estudio('BH')) ->> 'id' as t \gset
select api.avanzar_tramite(:'wa', :'t', 1, 'seleccion_clinica', jsonb_build_object('estudio_id', tests.estudio('BH'))) is not null as a \gset

-- Asesor 1: llamada, OTP y toma el trámite
select tests.como_staff(:'a1', 'asesor');
select api.iniciar_contacto('call_center', '8661234590', 'humano') #>> '{sesion,interaccion_id}' as c1 \gset
select tests.como_servicio();
select api.solicitar_otp(:'c1') ->> 'codigo' as otp \gset
select tests.como_staff(:'a1', 'asesor');
select api.validar_otp(:'c1', :'otp') is not null as ok \gset
select api.retomar_tramite(:'c1', :'t') is not null as r \gset
select is(api.obtener_contexto(:'c1') #>> '{tramite_activo,atendido_por_mi}', 'true', 'El asesor toma el trámite al retomarlo');

-- WhatsApp: lo ve, pero no lo cambia
select tests.como_servicio();
select is(api.iniciar_contacto('whatsapp', '5218661234590', 'ia', 'canal') #>> '{tramites_abiertos,0,en_atencion_de_otro}', 'true',
          'WhatsApp ve que el trámite está en atención');
select is(api.retomar_tramite(:'wa', :'t') ->> 'en_atencion_de_otro', 'true', 'Puede retomarlo para verlo');
select tests.error_de(format('select api.avanzar_tramite(%L, %L, 2, %L, %L)', :'wa', :'t', 'seleccion_horario',
                             jsonb_build_object('clinica_id', tests.clinica('PUE-CEN')))) as e \gset
select is((:'e')::jsonb ->> 'code', 'PT423', 'pero modificarlo responde PT423');
select is((:'e')::jsonb ->> 'message', 'tramite_en_atencion', 'tramite_en_atencion');
select matches(api.texto_asesor_atendiendo(:'wa', :'t'), '^Un asesor está atendiendo tu trámite Biometría hemática · para ti \(folio SD-',
               'El bot contesta con la plantilla asesor_atendiendo');

-- Web de la misma paciente (teléfono verificado → mismo paciente): tampoco lo cambia
select tests.como_paciente(:'web', false);
select api.iniciar_sesion_paciente('web') #>> '{sesion,interaccion_id}' as w \gset
select is(tests.error_de(format('select api.avanzar_tramite(%L, %L, 2, %L, %L)', :'w', :'t', 'seleccion_horario',
                                jsonb_build_object('clinica_id', tests.clinica('PUE-CEN')))) ->> 'code',
          'PT423', 'La web tampoco puede modificarlo');

-- El bloqueo es por trámite: con otro trámite WhatsApp sigue normal
select tests.como_servicio();
select api.iniciar_tramite(:'wa', tests.estudio('QS6')) ->> 'id' as otro \gset
select lives_ok(format('select api.avanzar_tramite(%L, %L, 1, %L, %L)', :'wa', :'otro', 'seleccion_clinica',
                       jsonb_build_object('estudio_id', tests.estudio('QS6'))), 'Otro trámite del mismo paciente sí se modifica');

-- Un segundo asesor recibe PT423
select tests.como_staff(:'a2', 'asesor');
select api.iniciar_contacto('call_center', '8661234590', 'humano') #>> '{sesion,interaccion_id}' as c2 \gset
select tests.como_servicio();
select api.solicitar_otp(:'c2') ->> 'codigo' as otp2 \gset
select tests.como_staff(:'a2', 'asesor');
select api.validar_otp(:'c2', :'otp2') is not null as ok \gset
select is(tests.error_de(format('select api.retomar_tramite(%L, %L)', :'c2', :'t')) ->> 'code', 'PT423',
          'Un segundo asesor no puede tomar un trámite en atención');

-- Cada acción del asesor renueva los 10 minutos
select tests.como_staff(:'a1', 'asesor');
select api.avanzar_tramite(:'c1', :'t', 2, 'seleccion_horario', jsonb_build_object('clinica_id', tests.clinica('PUE-CEN'))) is not null as a \gset
select tests.como_postgres();
select ok((select atencion_hasta > now() + interval '9 minutes' from core.tramites where id = :'t'), 'Cada acción renueva la atención');

-- Se libera al colgar
select tests.como_staff(:'a1', 'asesor');
select api.cerrar_interaccion(:'c1');
select tests.como_servicio();
select lives_ok(format('select api.avanzar_tramite(%L, %L, 3, %L)', :'wa', :'t', 'seleccion_clinica'),
                'Al colgar el asesor, WhatsApp vuelve a poder modificarlo');
select tests.como_postgres();
select is((select payload ->> 'motivo' from core.eventos_tramite where tramite_id = :'t' and tipo_evento = 'atencion_liberada' limit 1),
          'interaccion_cerrada', 'y queda el evento atencion_liberada');

-- Se libera al vencer: el asesor 2 lo toma y "deja de hacer cosas" 10 minutos
select tests.como_staff(:'a2', 'asesor');
select api.retomar_tramite(:'c2', :'t') is not null as r \gset
select tests.como_postgres();
update core.tramites set atencion_hasta = now() - interval '1 second' where id = :'t';
select tests.como_servicio();
select lives_ok(format('select api.avanzar_tramite(%L, %L, 4, %L, %L)', :'wa', :'t', 'seleccion_horario',
                       jsonb_build_object('clinica_id', tests.clinica('PUE-CEN'))),
                'Si la atención venció, los demás canales vuelven a poder modificarlo');

select finish();
rollback;
