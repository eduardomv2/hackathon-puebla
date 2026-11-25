-- El personal ve las citas por folio y fecha antes de verificar identidad, sin más detalle.
create extension if not exists pgtap with schema extensions;
begin;
select plan(7);
\ir ../helpers.psql

\set aseso '00000000-0000-0000-0000-00000000a250'
select tests.crear_staff(:'aseso', 'asesor');

-- Ana tiene una cita pagada y su fecha de nacimiento registrada
select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '5218661250001', 'ia', 'canal') #>> '{sesion,interaccion_id}' as ana \gset
select tests.registrar(:'ana', 'Ana', 'Citas');
select api.iniciar_tramite(:'ana', tests.estudio('BH')) ->> 'id' as t \gset
select tests.hasta_horario(:'ana', :'t', 1, 'BH') as v \gset
select api.reservar_cita(:'ana', :'t', :v, tests.en_dias(2)) ->> 'version' as v2 \gset
select tests.pagar(:'ana', :'t', :v2::int) is not null as pagada \gset
select tests.como_postgres();
update core.pacientes set fecha_nacimiento = date '1990-05-04' where nombre = 'Ana' and apellido_paterno = 'Citas';
select folio as folio_ana from core.tramites where id = :'t' \gset

-- El asesor atiende la llamada: sin verificar ve folio, fecha y estado
select tests.como_staff(:'aseso', 'asesor');
select api.iniciar_contacto('call_center', '5218661250001', 'humano') as c \gset
select (:'c')::jsonb #>> '{sesion,interaccion_id}' as ia \gset
select is((:'c')::jsonb #>> '{sesion,nivel_verificacion}', 'declarada', 'Empieza sin verificar');
select is((:'c')::jsonb #>> '{citas_proximas,0,folio}', :'folio_ana', 'Ve la cita por su folio');
select is((select array_agg(k order by k) from jsonb_object_keys((:'c')::jsonb #> '{citas_proximas,0}') k),
          array['estado', 'fecha_hora', 'folio', 'id'], 'y solo folio, fecha y estado (sin estudio, clínica ni nombre)');
select is((:'c')::jsonb #>> '{citas_proximas,0,estado}', 'confirmada', 'con su estado');

-- Al verificar se abre el detalle completo
select is(api.verificar_identidad(:'ia', date '1990-05-04') ->> 'verificado', 'true', 'La fecha de nacimiento coincide');
select is(api.obtener_contexto(:'ia') #>> '{citas_proximas,0,estudio}', 'Biometría hemática', 'Ya verificada ve el estudio');
select is(api.obtener_contexto(:'ia') #>> '{citas_proximas,0,clinica}' is not null, true, 'y la clínica');

select * from finish();
rollback;
