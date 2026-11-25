-- Avisos proactivos por WhatsApp: consentimiento, ventana de 24 h y plantillas.
-- También quién puede escuchar en tiempo real el canal de un paciente.
create extension if not exists pgtap with schema extensions;
begin;
select plan(13);
\ir ../helpers.psql

\set ana    '00000000-0000-0000-0000-00000000a380'
\set asesor '00000000-0000-0000-0000-00000000c380'
select tests.crear_usuario(:'ana', false, '528661234580');
select tests.crear_staff(:'asesor', 'asesor');

create function tests.en_cola(p_paciente text) returns int language sql security definer as $$
  select count(*)::int from pgmq.q_avisos_whatsapp where message ->> 'paciente_id' = p_paciente $$;
grant execute on function tests.en_cola(text) to anon, authenticated, service_role;

select tests.como_paciente(:'ana', false);
select api.iniciar_sesion_paciente('web') as w \gset
select (:'w')::jsonb #>> '{sesion,interaccion_id}' as wi \gset
select tests.registrar(:'wi', 'Ana', 'López');
select (:'w')::jsonb #>> '{paciente,id}' as p \gset

-- Sin consentimiento no se encola nada
select api.iniciar_tramite(:'wi', tests.estudio('BH')) ->> 'id' as t \gset
select is(tests.en_cola(:'p'), 0, 'Sin consentimiento no hay avisos proactivos');

-- Acepta: los cambios hechos fuera de WhatsApp se encolan
select is(api.registrar_consentimiento_avisos(:'wi', true) ->> 'telefono', '+52******4580', 'Guarda el consentimiento con su teléfono verificado');
select is(api.obtener_contexto(:'wi') #>> '{paciente,avisos_whatsapp}', 'true', 'y el contexto lo muestra');
select api.avanzar_tramite(:'wi', :'t', 1, 'seleccion_clinica', jsonb_build_object('estudio_id', tests.estudio('BH'))) is not null as a \gset
select is(tests.en_cola(:'p'), 1, 'Un cambio en la web se encola para avisar por WhatsApp');

-- Los cambios hechos en WhatsApp no se avisan a WhatsApp
select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '5218661234580', 'ia', 'canal') #>> '{sesion,interaccion_id}' as wa \gset
select api.retomar_tramite(:'wa', :'t') is not null as r \gset
select api.avanzar_tramite(:'wa', :'t', 2, 'seleccion_horario', jsonb_build_object('clinica_id', tests.clinica('PUE-CEN'))) is not null as a \gset
select is(tests.en_cola(:'p'), 1, 'Un cambio hecho en WhatsApp no se avisa a WhatsApp');

-- Fuera de la ventana de 24 h: solo plantillas
select tests.como_postgres();
select id as ev_paso, ocurrido_en as ev_paso_en from core.eventos_tramite
where tramite_id = :'t' and tipo_evento = 'paso_avanzado' and canal = 'web' \gset
select tests.como_servicio();
select is(api.procesar_aviso_whatsapp(:'ev_paso', :'p', :'ev_paso_en') ->> 'motivo', 'fuera_de_ventana_sin_plantilla',
          'Fuera de la ventana, un cambio de paso (texto libre) no se envía');

-- El link de pago generado en la web sí sale, con su plantilla
select tests.como_paciente(:'ana', false);
-- La web regresa al paso de horario y reserva
select tests.hasta_horario(:'wi', :'t', 3, 'BH', 'PUE-CEN') as v \gset
select api.reservar_cita(:'wi', :'t', :v, tests.en_dias(2)) ->> 'version' as v \gset
select api.generar_pago(:'wi', (select :'t')::uuid, :v) is not null as g \gset
select tests.como_postgres();
select id as ev_pago, ocurrido_en as ev_pago_en from core.eventos_tramite where tramite_id = :'t' and tipo_evento = 'pago_generado' \gset
select tests.como_servicio();
select api.procesar_aviso_whatsapp(:'ev_pago', :'p', :'ev_pago_en') as av \gset
select is((:'av')::jsonb ->> 'plantilla', 'link_pago', 'Fuera de la ventana, el link de pago usa la plantilla link_pago');
select matches((:'av')::jsonb ->> 'texto', 'Paga aquí para confirmarla: https://pagos\.ejemplo\.mx/checkout/SD-', 'con las variables llenas');

-- Dentro de la ventana (escribió por WhatsApp hace poco). En una transacción now() no avanza:
-- el cambio de paso se mueve un minuto atrás para que quede antes de la conversación.
select tests.como_postgres();
select set_config('app.operacion', 'fusion', true) is not null as x \gset
update core.eventos_tramite set ocurrido_en = now() - interval '1 minute' where id = :'ev_paso';
select set_config('app.operacion', '', true) is not null as x \gset
select ocurrido_en as ev_paso_en from core.eventos_tramite where id = :'ev_paso' \gset
select tests.como_servicio();
select api.registrar_mensaje(:'wa', 'entrante', 'paciente', 'hola') is not null as m \gset
select is(api.procesar_aviso_whatsapp(:'ev_paso', :'p', :'ev_paso_en') ->> 'motivo', 'anterior_a_la_conversacion',
          'Lo ocurrido antes de que escribiera no se repite (ya lo resume "Tienes pendiente")');
-- Un cambio en la web DESPUÉS de que escribió: texto libre
select tests.como_paciente(:'ana', false);
select api.avanzar_tramite(:'wi', :'t', (api.obtener_contexto(:'wi') #>> '{tramite_activo,version}')::int, 'seleccion_horario') is not null as a \gset
select tests.como_postgres();
select id as ev_nuevo, ocurrido_en as ev_nuevo_en from core.eventos_tramite
where tramite_id = :'t' and tipo_evento = 'paso_avanzado' and canal = 'web' order by ocurrido_en desc, id desc limit 1 \gset
select tests.como_servicio();
select is(api.procesar_aviso_whatsapp(:'ev_nuevo', :'p', :'ev_nuevo_en') ->> 'tipo', 'texto',
          'Dentro de la ventana de 24 h, un cambio posterior se manda como texto libre');

-- Si retira el consentimiento, ya no se envía nada
select tests.como_paciente(:'ana', false);
select api.registrar_consentimiento_avisos(:'wi', false) is not null as c \gset
select tests.como_servicio();
select is(api.procesar_aviso_whatsapp(:'ev_pago', :'p', :'ev_pago_en') ->> 'motivo', 'sin_consentimiento',
          'Sin consentimiento vigente no se envía');

-- Tiempo real: el asesor solo escucha al paciente que está atendiendo
select tests.como_staff(:'asesor', 'asesor');
select api.iniciar_contacto('call_center', '8661234580', 'humano') is not null as c \gset
select ok(core.puede_escuchar_paciente('paciente:' || :'p'), 'El asesor puede escuchar al paciente que atiende');
select ok(not core.puede_escuchar_paciente('paciente:00000000-0000-0000-0000-000000000000'), 'pero no a cualquier otro');

select finish();
rollback;
