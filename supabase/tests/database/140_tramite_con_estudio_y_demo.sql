-- El trámite nace con estudio; los vacíos no se ofrecen y se cancelan a las 24 h.
-- Herramientas de demo del simulador (reiniciar y forzar recordatorio).
create extension if not exists pgtap with schema extensions;
begin;
select plan(13);
\ir ../helpers.psql

select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '5218661234567', 'ia', 'canal') #>> '{sesion,interaccion_id}' as i \gset
select tests.registrar(:'i');
select api.obtener_contexto(:'i') #>> '{paciente,id}' as p \gset
select api.agregar_beneficiario(:'i', 'Luis', 'López', null, '2016-07-01', null, 'hijo', true) ->> 'beneficiario_id' as hijo \gset

-- No hay trámites vacíos: el estudio es obligatorio y el trámite nace en "elegir clínica"
select throws_ok(format('select api.iniciar_tramite(%L, null)', :'i'), '22023', 'Elige el estudio para iniciar el trámite',
                 'Sin estudio no se inicia un trámite');
select api.iniciar_tramite(:'i', tests.estudio('BH'), :'hijo') as t \gset
select is((:'t')::jsonb ->> 'paso_actual', 'seleccion_clinica', 'El trámite nace en "elegir clínica"');
select is((:'t')::jsonb ->> 'etiqueta', 'Biometría hemática · para Luis', 'con su estudio y para quién desde el inicio');
select is(tests.error_de(format('select api.iniciar_tramite(%L, %L, %L)', :'i', tests.estudio('BH'), :'hijo')) ->> 'message',
          'tramite_duplicado', 'La regla de duplicados aplica desde el inicio');

-- Red de seguridad: trámites viejos sin estudio
select tests.como_postgres();
insert into core.tramites (paciente_id, tipo, paso_actual, canal_origen, ultimo_canal, creado_en)
values (:'p', 'agendar_estudio', 'seleccion_estudio', 'web', 'web', now() - interval '25 hours') returning id as vacio_viejo \gset
insert into core.tramites (paciente_id, tipo, paso_actual, canal_origen, ultimo_canal)
values (:'p', 'agendar_estudio', 'seleccion_estudio', 'web', 'web') returning id as vacio_nuevo \gset
select tests.como_servicio();
select is(jsonb_array_length(api.obtener_contexto(:'i') -> 'tramites_abiertos'), 1,
          'Los trámites sin estudio no aparecen en "Tienes pendiente"');
select tests.como_postgres();
select ok(core.cancelar_tramites_sin_estudio() >= 1, 'pg_cron cancela los que siguen sin estudio a las 24 h');
select is((select estado from core.tramites where id = :'vacio_viejo'), 'cancelado', 'el de hace 25 h queda cancelado');
select is((select payload ->> 'motivo' from core.eventos_tramite where tramite_id = :'vacio_viejo' and tipo_evento = 'tramite_cancelado'),
          'sin_estudio', 'con su evento (motivo sin_estudio)');
select is((select estado from core.tramites where id = :'vacio_nuevo'), 'activo', 'el reciente todavía no');

-- Demo: forzar el recordatorio por plantilla
select ok((simulador.forzar_recordatorio((:'t')::jsonb ->> 'folio') ->> 'recordatorios_programados')::int >= 1,
          'forzar_recordatorio deja el trámite inactivo y programa el recordatorio');

-- Demo: reiniciar borra solo lo de los teléfonos de prueba (y sus familiares)
select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '2221119000', 'ia', 'canal') #>> '{paciente,id}' as ajeno \gset
select tests.como_postgres();
update simulador.config set habilitado = false;
select throws_ok('select simulador.reiniciar_demo()', '42501', null, 'Con el simulador apagado no se puede reiniciar');
update simulador.config set habilitado = true;
select simulador.reiniciar_demo() is not null as r \gset
select is((select count(*)::int from core.pacientes where id in (:'p', :'hijo')), 0, 'Reiniciar borra la paciente de prueba y a su familiar');
select is((select count(*)::int from core.pacientes where id = :'ajeno'), 1, 'pero no a un paciente que no es de prueba');

select finish();
rollback;
