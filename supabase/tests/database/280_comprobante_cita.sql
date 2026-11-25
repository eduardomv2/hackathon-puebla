-- Comprobante de pago y cita: solo con identidad verificada, de la propia cita y, en recepción, de su clínica.
create extension if not exists pgtap with schema extensions;
begin;
select plan(11);
\ir ../helpers.psql

\set rec   '00000000-0000-0000-0000-00000000a280'
\set rec2  '00000000-0000-0000-0000-00000000a281'
select tests.clinica('PUE-CEN') as cen \gset
select tests.clinica('PUE-ANG') as ang \gset
select tests.crear_staff(:'rec', 'recepcion', :'cen');
select tests.crear_staff(:'rec2', 'recepcion', :'ang');

-- Ana aparta por WhatsApp
select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '5218661280001', 'ia', 'canal') #>> '{sesion,interaccion_id}' as ana \gset
select tests.registrar(:'ana', 'Ana', 'Recibo');
select api.iniciar_tramite(:'ana', tests.estudio('BH')) ->> 'id' as ta \gset
select tests.hasta_horario(:'ana', :'ta', 1, 'BH') as va \gset
select api.reservar_cita(:'ana', :'ta', :va, tests.en_dias(2)) ->> 'version' as va2 \gset
select api.generar_pago(:'ana', :'ta', :va2::int) ->> 'referencia' as ref_ana \gset
select tests.como_postgres();
select id as cita_ana from core.citas where tramite_id = :'ta' \gset

-- Beto aparta y paga en caja
select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '5218661280002', 'ia', 'canal') #>> '{sesion,interaccion_id}' as beto \gset
select tests.registrar(:'beto', 'Beto', 'Caja');
select api.iniciar_tramite(:'beto', tests.estudio('BH')) ->> 'id' as tb \gset
select tests.hasta_horario(:'beto', :'tb', 1, 'BH') as vb \gset
select api.reservar_cita(:'beto', :'tb', :vb, tests.en_dias(2)) ->> 'version' as vb2 \gset
select tests.como_postgres();
select id as cita_beto from core.citas where tramite_id = :'tb' \gset

-- Sin identidad verificada no hay comprobante
select tests.como_servicio();
select throws_ok(format('select api.comprobante_cita(%L, %L)', :'ana', :'cita_ana'), '42501', null, 'Sin verificar no hay comprobante');
select tests.como_postgres();
update core.interacciones set nivel_verificacion = 'verificada' where id in (:'ana', :'beto');

-- Apartada: trae la cita y el pago pendiente
select tests.como_servicio();
select api.comprobante_cita(:'ana', :'cita_ana') as c1 \gset
select is((:'c1')::jsonb #>> '{pago,estado}', 'pendiente', 'Apartada: pago pendiente');
select is((:'c1')::jsonb ->> 'titular', 'Ana Recibo', 'Trae el nombre del titular');
select ok((:'c1')::jsonb #>> '{clinica,nombre}' is not null and (:'c1')::jsonb ->> 'folio' is not null, 'Trae clínica y folio');

-- Pagada en línea
select api.confirmar_pago(:'ref_ana', 'pagado') is not null as pagada \gset
select api.comprobante_cita(:'ana', :'cita_ana') as c2 \gset
select is((:'c2')::jsonb #>> '{pago,estado}', 'pagado', 'Pagada: lo indica');
select is((:'c2')::jsonb #>> '{pago,metodo}', 'en_linea', 'Método en línea');

-- Otro paciente no ve la cita de Ana
select throws_ok(format('select api.comprobante_cita(%L, %L)', :'beto', :'cita_ana'), 'PT404', null, 'No se ve la cita de otra persona');

-- Recepción: la de otra clínica no, la de su clínica sí y con método de caja
select tests.como_staff(:'rec2', 'recepcion', :'ang');
select api.iniciar_contacto('clinica', '5218661280002', 'humano') #>> '{sesion,interaccion_id}' as r2 \gset
select tests.como_postgres();
update core.interacciones set nivel_verificacion = 'verificada' where id = :'r2';
select tests.como_staff(:'rec2', 'recepcion', :'ang');
select throws_ok(format('select api.comprobante_cita(%L, %L)', :'r2', :'cita_beto'), '42501', null, 'Recepción de otra clínica no lo ve');

select tests.como_staff(:'rec', 'recepcion', :'cen');
select api.iniciar_contacto('clinica', '5218661280002', 'humano') #>> '{sesion,interaccion_id}' as r1 \gset
select tests.como_postgres();
update core.interacciones set nivel_verificacion = 'verificada' where id = :'r1';
select tests.como_staff(:'rec', 'recepcion', :'cen');
select api.cobrar_en_caja(:'cita_beto', 'efectivo') is not null as cobrada \gset
select api.comprobante_cita(:'r1', :'cita_beto') as c3 \gset
select is((:'c3')::jsonb #>> '{pago,metodo}', 'efectivo', 'Cobro en caja: método efectivo');
select is((:'c3')::jsonb #>> '{pago,en_caja}', 'true', 'y marcado como pagado en caja');
select tests.como_postgres();
select is((select count(*)::int from core.pagos where cita_id = :'cita_beto' and estado = 'pagado'), 1, 'Un solo pago cobrado');

select * from finish();
rollback;
