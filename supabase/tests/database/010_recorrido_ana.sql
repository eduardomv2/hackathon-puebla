-- Recorrido de Ana, omnicanal sin códigos: web (verifica su celular con OTP)
-- → WhatsApp lo ve en "Tienes pendiente" → call center con OTP (el asesor lo
-- toma) → pago → app. Un solo trámite y un solo paciente en todos los canales.
create extension if not exists pgtap with schema extensions;
begin;
select plan(17);
\ir ../helpers.psql

\set ana     '00000000-0000-0000-0000-00000000a001'
\set asesora '00000000-0000-0000-0000-00000000c001'
select tests.crear_usuario(:'ana');
select tests.crear_staff(:'asesora', 'asesor');

-- 1. Web anónima: puede ver el catálogo, pero no iniciar un trámite sin OTP
select tests.como_paciente(:'ana');
select api.iniciar_sesion_paciente('web') #>> '{sesion,interaccion_id}' as web_int \gset
select ok(jsonb_array_length(api.catalogo_estudios()) > 0, 'Sin verificar puede consultar el catálogo');
select throws_ok(format('select api.iniciar_tramite(%L, %L)', :'web_int', tests.estudio('US-OBS')), '42501',
                 'Verifica tu celular con el código (OTP) para iniciar un trámite', 'Sin OTP no puede iniciar un trámite');

-- 2. Verifica su celular (OTP de Supabase Auth) y acepta avisos por WhatsApp
select tests.como_postgres();
select tests.verificar_telefono_auth(:'ana', '528661234567');
select tests.como_paciente(:'ana', false);
select api.iniciar_sesion_paciente('web') as web \gset
select is((:'web')::jsonb #>> '{sesion,nivel_verificacion}', 'verificada', 'Con el teléfono verificado entra como verificada');
select (:'web')::jsonb #>> '{sesion,interaccion_id}' as web_int \gset
select tests.registrar(:'web_int', 'Ana', 'López');
select is(api.registrar_consentimiento_avisos(:'web_int', true) ->> 'acepta', 'true', 'Acepta recibir avisos por WhatsApp');
select api.iniciar_tramite(:'web_int', tests.estudio('US-OBS')) as t \gset
select (:'t')::jsonb ->> 'id' as tramite \gset
select matches((:'t')::jsonb ->> 'folio', '^SD-[A-HJ-NP-Z2-9]{4}$', 'El trámite tiene un folio corto legible');
select api.avanzar_tramite(:'web_int', :'tramite', 1, 'seleccion_clinica',
                           jsonb_build_object('estudio_id', tests.estudio('US-OBS'))) ->> 'version' as v \gset

-- 3. Se sale de la web y escribe por WhatsApp desde su número: sin códigos
select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '5218661234567', 'ia', 'canal') as wa \gset
select is((:'wa')::jsonb #>> '{tramites_abiertos,0,etiqueta}', 'Ultrasonido obstétrico · para ti',
          'WhatsApp ve el trámite de la web en "Tienes pendiente"');
select is((:'wa')::jsonb -> 'tramite_activo', 'null'::jsonb, 'y espera a que la paciente elija con cuál seguir');
select (:'wa')::jsonb #>> '{sesion,interaccion_id}' as wa_int \gset
select is(api.retomar_tramite(:'wa_int', :'tramite') ->> 'paso_actual', 'seleccion_clinica', 'Lo retoma con el avance de la web');
select api.avanzar_tramite(:'wa_int', :'tramite', :v, 'seleccion_horario',
                           jsonb_build_object('clinica_id', tests.clinica('PUE-CEN'))) ->> 'version' as v \gset
select api.registrar_mensaje(:'wa_int', 'entrante', 'paciente', 'Mejor les llamo para elegir horario') is not null as msg \gset

-- 4. Call center: el identificador de llamada solo declara; el OTP verifica
select tests.como_staff(:'asesora', 'asesor');
select api.iniciar_contacto('call_center', '866 123 4567', 'humano') as cc \gset
select is((:'cc')::jsonb #>> '{sesion,nivel_verificacion}', 'declarada', 'La llamada empieza como declarada');
select is((:'cc')::jsonb #>> '{tramites_abiertos,0,folio}', (:'t')::jsonb ->> 'folio',
          'Sin verificar solo ve el folio del trámite pendiente');
select (:'cc')::jsonb #>> '{sesion,interaccion_id}' as cc_int \gset
select tests.como_servicio();
select api.solicitar_otp(:'cc_int') ->> 'codigo' as otp \gset
select tests.como_staff(:'asesora', 'asesor');
select is(api.validar_otp(:'cc_int', :'otp') #>> '{contexto,sesion,nivel_verificacion}', 'verificada', 'Con el OTP queda verificada');
select api.retomar_tramite(:'cc_int', :'tramite') is not null as r \gset
select is(api.obtener_contexto(:'cc_int') #>> '{tramite_activo,atendido_por_mi}', 'true', 'La asesora toma el trámite');
select is(api.obtener_contexto(:'cc_int') #>> '{mensajes_recientes,0,contenido}', 'Mejor les llamo para elegir horario',
          'y ve lo que Ana escribió por WhatsApp');

-- 5. La asesora reserva, Ana paga y la asesora cuelga
select api.reservar_cita(:'cc_int', :'tramite', :v, tests.en_dias(2)) ->> 'version' as v \gset
select tests.pagar(:'cc_int', :'tramite', :v) is not null as pago \gset
select api.cerrar_interaccion(:'cc_int');

-- 6. App: Ana entra con la misma cuenta
select tests.como_paciente(:'ana', false);
select api.iniciar_sesion_paciente('app') as app \gset
select is((:'app')::jsonb #>> '{citas_proximas,0,estado}', 'confirmada', 'En la app la cita aparece confirmada');
select is(jsonb_array_length((:'app')::jsonb -> 'tramites_abiertos'), 0, 'y ya no tiene trámites pendientes');

select tests.como_postgres();
select set_eq(
  format($q$select distinct canal from core.eventos_tramite where tramite_id = %L and canal not in ('sistema', 'panel')$q$, :'tramite'),
  array['web', 'whatsapp', 'call_center'],
  'Un solo trámite pasó por web, WhatsApp y call center');
select is((select count(distinct paciente_id)::int from core.eventos_tramite where tramite_id = :'tramite'), 1,
          'y todo quedó en un solo paciente');

select finish();
rollback;
