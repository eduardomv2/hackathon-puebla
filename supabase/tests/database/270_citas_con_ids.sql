-- Ya verificada, la cita trae ids de clínica y estudio y si está pagada; el personal la opera desde ahí.
create extension if not exists pgtap with schema extensions;
begin;
select plan(7);
\ir ../helpers.psql

\set aseso '00000000-0000-0000-0000-00000000a270'
select tests.crear_staff(:'aseso', 'asesor');

select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '5218661270001', 'ia', 'canal') #>> '{sesion,interaccion_id}' as ana \gset
select tests.registrar(:'ana', 'Ana', 'Ids');
select api.iniciar_tramite(:'ana', tests.estudio('BH')) ->> 'id' as t \gset
select tests.hasta_horario(:'ana', :'t', 1, 'BH') as v \gset
select api.reservar_cita(:'ana', :'t', :v, tests.en_dias(2)) ->> 'version' as v2 \gset

select is(api.obtener_contexto(:'ana') #>> '{citas_proximas,0,clinica_id}', tests.clinica('PUE-CEN')::text, 'Trae el id de la clínica');
select is(api.obtener_contexto(:'ana') #>> '{citas_proximas,0,estudio_id}', tests.estudio('BH')::text, 'y el del estudio');
select is(api.obtener_contexto(:'ana') #>> '{citas_proximas,0,pagada}', 'false', 'Apartada: sin pagar');
select tests.pagar(:'ana', :'t', :v2::int) is not null as pagada \gset
select is(api.obtener_contexto(:'ana') #>> '{citas_proximas,0,pagada}', 'true', 'Pagada: lo indica');
select tests.como_postgres();
select id as cita from core.citas where tramite_id = :'t' \gset

-- Sin verificar no se ven los ids
select tests.como_staff(:'aseso', 'asesor');
select api.iniciar_contacto('call_center', '5218661270001', 'humano') as c \gset
select is((:'c')::jsonb #> '{citas_proximas,0}' ? 'clinica_id', false, 'Sin verificar no trae ids');

-- El asesor mueve una cita ya pagada (trámite cerrado) desde la cita
select (:'c')::jsonb #>> '{sesion,interaccion_id}' as ia \gset
select tests.como_postgres();
update core.interacciones set nivel_verificacion = 'verificada' where id = :'ia';
select tests.como_staff(:'aseso', 'asesor');
select is(api.reprogramar_cita(:'ia', :'cita', tests.en_dias(3)) ->> 'estado', 'confirmada', 'Una cita pagada se reprograma y sigue confirmada');
select tests.como_postgres();
select is((select canal from core.eventos_tramite where tipo_evento = 'cita_reprogramada' and tramite_id = :'t'), 'call_center',
          'queda registrado desde el call center');

select * from finish();
rollback;
