-- WhatsApp: máximo 10 mensajes entrantes por minuto por teléfono. Utilidad de demo: adelantar una cita.
create extension if not exists pgtap with schema extensions;
begin;
select plan(9);
\ir ../helpers.psql

select tests.como_servicio();
select set_config('request.headers', '{"x-sd-telefono": "5218661234567"}', true) is not null as h \gset
select api.iniciar_contacto('whatsapp', '5218661234567', 'ia', 'canal') #>> '{sesion,interaccion_id}' as i \gset
select lives_ok(format($$select api.registrar_mensaje(%L, 'entrante', 'paciente', 'hola') from generate_series(1, 10)$$, :'i'),
                '10 mensajes en un minuto pasan');
select throws_ok(format($$select api.registrar_mensaje(%L, 'entrante', 'paciente', 'hola')$$, :'i'), 'PT429', 'demasiados_mensajes',
                 'El mensaje 11 recibe PT429');
select lives_ok(format($$select api.registrar_mensaje(%L, 'saliente', 'agente_ia', 'respuesta')$$, :'i'),
                'Las respuestas del bot no cuentan');
select set_config('request.headers', '{"x-sd-telefono": "5218661234568"}', true) is not null as h \gset
select api.iniciar_contacto('whatsapp', '5218661234568', 'ia', 'canal') #>> '{sesion,interaccion_id}' as j \gset
select lives_ok(format($$select api.registrar_mensaje(%L, 'entrante', 'paciente', 'hola')$$, :'j'), 'Otro teléfono tiene su propio cupo');

-- adelantar_cita: solo teléfonos de prueba
select tests.registrar(:'j', 'María', 'López');
select api.iniciar_tramite(:'j', tests.estudio('BH')) ->> 'id' as t \gset
select tests.hasta_horario(:'j', :'t', 1, 'BH') as v \gset
select api.reservar_cita(:'j', :'t', :v, tests.en_dias(2)) #>> '{folio}' as folio \gset
select tests.como_anon();
select ok(abs(extract(epoch from (simulador.adelantar_cita(:'folio') ->> 'fecha_hora')::timestamptz - now())) < 1,
          'adelantar_cita pone la cita en este momento');
select tests.como_postgres();
select ok((select abs(extract(epoch from fecha_hora - now())) < 1 from core.citas where tramite_id = :'t'), 'y la cita queda de hoy');
select tests.como_servicio();
select set_config('request.headers', '{}', true) is not null as h \gset
select api.iniciar_contacto('whatsapp', '2221118000', 'ia', 'canal') #>> '{sesion,interaccion_id}' as k \gset
select tests.registrar(:'k', 'Otra', 'Persona');
select api.iniciar_tramite(:'k', tests.estudio('BH')) ->> 'id' as t2 \gset
select tests.hasta_horario(:'k', :'t2', 1, 'BH') as v2 \gset
select api.reservar_cita(:'k', :'t2', :v2, tests.en_dias(2)) #>> '{folio}' as folio2 \gset
select tests.como_anon();
select throws_ok(format('select simulador.adelantar_cita(%L)', :'folio2'), '42501', null, 'Un trámite real no se adelanta');

-- reiniciar_demo limpia los contadores de mensajes
select tests.como_postgres();
select ok(exists (select 1 from core.rate_limit where clave = 'msg:tel:+528661234567'), 'Hay contador de mensajes');
select simulador.reiniciar_demo() is not null as r \gset
select ok(not exists (select 1 from core.rate_limit where clave like 'msg:tel:+5286612345%'),
          'Reiniciar demo limpia los contadores de los teléfonos de prueba');

select finish();
rollback;
