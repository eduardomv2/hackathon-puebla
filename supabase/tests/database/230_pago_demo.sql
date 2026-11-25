-- Pago de prueba: link configurable, pagos pendientes solo del dueño, confirmar_pago simulado e idempotente.
create extension if not exists pgtap with schema extensions;
begin;
select plan(17);
\ir ../helpers.psql

\set asesora '00000000-0000-0000-0000-00000000a230'
select tests.crear_staff(:'asesora', 'asesor');

-- Ana (WhatsApp) llega hasta el pago de una Biometría
select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '5218661230230', 'ia', 'canal') #>> '{sesion,interaccion_id}' as ana \gset
select tests.registrar(:'ana', 'Ana', 'Pago');
select api.iniciar_tramite(:'ana', tests.estudio('BH')) ->> 'id' as t \gset
select tests.hasta_horario(:'ana', :'t', 1, 'BH') as v \gset
select api.reservar_cita(:'ana', :'t', :v, tests.en_dias(1)) ->> 'version' as v2 \gset
select api.generar_pago(:'ana', :'t', :v2) as pago \gset
select (:'pago')::jsonb ->> 'referencia' as ref \gset

-- Link de pago
select is((:'pago')::jsonb ->> 'link_pago', 'http://localhost:5173/pagar/' || :'ref', 'Link = pago_url_base/pagar/referencia');
select tests.como_postgres();
delete from vault.secrets where name = 'pago_url_base';
select is(core.link_pago('SD-X'), null, 'Sin pago_url_base no hay link (el canal indica cómo pagar)');

-- Pagos pendientes: el dueño ve el suyo con monto y estudio
select tests.como_servicio();
select api.pagos_pendientes(:'ana') -> 0 as p \gset
select is((:'p')::jsonb ->> 'referencia', :'ref', 'El dueño ve su pago pendiente');
select is((:'p')::jsonb ->> 'estudio', 'Biometría hemática', 'con el estudio');
select is(((:'p')::jsonb ->> 'monto')::numeric, 120.00, 'y el monto');

-- Otra persona no lo ve
select api.iniciar_contacto('whatsapp', '5218661230231', 'ia', 'canal') #>> '{sesion,interaccion_id}' as beto \gset
select is(jsonb_array_length(api.pagos_pendientes(:'beto')), 0, 'Otro paciente no ve pagos ajenos');
select is(api.pago_del_paciente(:'beto', :'ref'), null, 'ni lo encuentra por su referencia');
select is(api.pago_del_paciente(:'ana', :'ref') ->> 'estado', 'pendiente', 'El dueño sí');

-- El personal no usa esta función (solo el paciente o el servidor)
select tests.como_staff(:'asesora', 'asesor');
select api.iniciar_contacto('call_center', '5218661230230', 'humano') #>> '{sesion,interaccion_id}' as cc \gset
select throws_ok(format('select api.pagos_pendientes(%L)', :'cc'), '42501', null, 'El asesor no la usa');

-- Pagar solo lo hace el servidor
select throws_ok(format('select api.confirmar_pago(%L, %L)', :'ref', 'pagado'), '42501', null, 'El personal no puede pagar');
select tests.como_anon();
select throws_ok(format('select api.confirmar_pago(%L, %L)', :'ref', 'pagado'), '42501', null, 'anon tampoco');

-- Pago simulado: el evento lo dice; pagar dos veces es idempotente
select tests.como_servicio();
select api.confirmar_pago(:'ref', 'pagado', '{"origen": "pago_demo", "simulado": true}') ->> 'estado' as e1 \gset
select is(:'e1'::text, 'pagado', 'Pago simulado confirmado');
select tests.como_postgres();
select is((select payload ->> 'simulado' from core.eventos_tramite where tramite_id = :'t' and tipo_evento = 'pago_confirmado'), 'true',
          'El evento pago_confirmado lleva simulado: true');
select is((select paso_actual || '/' || estado from core.tramites where id = :'t'), 'confirmada/completado', 'El trámite queda confirmado');
select tests.como_servicio();
select is(api.confirmar_pago(:'ref', 'pagado', '{"simulado": true}') ->> 'repetido', 'true', 'Pagar dos veces es idempotente');
select is(jsonb_array_length(api.pagos_pendientes(:'ana')), 0, 'Ya no aparece como pendiente');
select is(api.pago_del_paciente(:'ana', :'ref') ->> 'estado', 'pagado', 'y por su referencia aparece pagado');

select finish();
rollback;
