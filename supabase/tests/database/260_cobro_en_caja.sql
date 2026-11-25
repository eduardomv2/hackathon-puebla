-- Cobro en caja: recepción de la clínica cobra una cita apartada sin pagar.
create extension if not exists pgtap with schema extensions;
begin;
select plan(15);
\ir ../helpers.psql

\set rec   '00000000-0000-0000-0000-00000000a260'
\set rec2  '00000000-0000-0000-0000-00000000a261'
\set aseso '00000000-0000-0000-0000-00000000a262'
select tests.clinica('PUE-CEN') as cen \gset
select tests.clinica('PUE-ANG') as ang \gset
select tests.crear_staff(:'rec', 'recepcion', :'cen');
select tests.crear_staff(:'rec2', 'recepcion', :'ang');
select tests.crear_staff(:'aseso', 'asesor');

-- Ana aparta por WhatsApp y le llega el link, pero no paga
select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '5218661260001', 'ia', 'canal') #>> '{sesion,interaccion_id}' as ana \gset
select tests.registrar(:'ana', 'Ana', 'Caja');
select api.iniciar_tramite(:'ana', tests.estudio('BH')) ->> 'id' as ta \gset
select tests.hasta_horario(:'ana', :'ta', 1, 'BH') as va \gset
select api.reservar_cita(:'ana', :'ta', :va, tests.en_dias(1)) ->> 'version' as va2 \gset
select api.generar_pago(:'ana', :'ta', :va2::int) ->> 'pago_id' as pago_ana \gset
select tests.como_postgres();
select id as cita_ana from core.citas where tramite_id = :'ta' \gset

-- Quién puede cobrar
select tests.como_staff(:'aseso', 'asesor');
select throws_ok(format('select api.cobrar_en_caja(%L)', :'cita_ana'), '42501', null, 'El call center no cobra en caja');
select tests.como_staff(:'rec2', 'recepcion', :'ang');
select throws_ok(format('select api.cobrar_en_caja(%L)', :'cita_ana'), '42501', null, 'Recepción de otra clínica no cobra');
select tests.como_staff(:'rec', 'recepcion', :'cen');
select throws_ok(format('select api.cobrar_en_caja(%L, %L)', :'cita_ana', 'cheque'), '22023', null, 'Solo efectivo o tarjeta');

-- Cobra con tarjeta: usa el mismo pago del link
select is(api.cobrar_en_caja(:'cita_ana', 'tarjeta') ->> 'estado', 'pagado', 'Recepción cobra la cita');
select throws_ok(format('select api.cobrar_en_caja(%L)', :'cita_ana'), 'P0001', null, 'No se cobra dos veces');
select tests.como_postgres();
select is((select estado from core.pagos where id = :'pago_ana'), 'pagado', 'Se pagó el mismo pago del link (no uno nuevo)');
select is((select count(*)::int from core.pagos where cita_id = :'cita_ana'), 1, 'y solo hay un pago');
select is((select estado from core.citas where id = :'cita_ana'), 'confirmada', 'La cita queda confirmada');
select is((select estado || '/' || paso_actual from core.tramites where id = :'ta'), 'completado/confirmada', 'El trámite queda completado');
select is((select canal || '/' || (payload ->> 'metodo') from core.eventos_tramite where tramite_id = :'ta' and tipo_evento = 'pago_confirmado'),
          'clinica/tarjeta', 'El pago queda registrado desde la clínica y con su método');
select is((select count(*)::int from core.eventos_tramite where tramite_id = :'ta' and tipo_evento in ('cita_confirmada', 'tramite_completado')), 2,
          'con los mismos eventos que un pago en línea');

-- Bea llega sin haber pagado ni pedido link: se crea el pago en caja y sigue en la clínica
select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '5218661260002', 'ia', 'canal') #>> '{sesion,interaccion_id}' as bea \gset
select tests.registrar(:'bea', 'Bea', 'Caja');
select api.iniciar_tramite(:'bea', tests.estudio('BH')) ->> 'id' as tb \gset
select tests.hasta_horario(:'bea', :'tb', 1, 'BH') as vb \gset
select api.reservar_cita(:'bea', :'tb', :vb, tests.en_dias(1)) is not null as r \gset
select tests.como_postgres();
select id as cita_bea from core.citas where tramite_id = :'tb' \gset
update core.citas set fecha_hora = now() where id = :'cita_bea';
select tests.como_staff(:'rec', 'recepcion', :'cen');
select is(api.registrar_llegada(:'cita_bea', 'ine', true) ->> 'indicacion', 'Pasar a caja', 'Al llegar sin pagar la mandan a caja');
select is(api.cobrar_en_caja(:'cita_bea') ->> 'metodo', 'efectivo', 'En caja cobra en efectivo (por omisión)');
select tests.como_postgres();
select is((select estado from core.citas where id = :'cita_bea'), 'en_clinica', 'Ya llegó: sigue en la clínica');
select matches((select referencia_externa from core.pagos where cita_id = :'cita_bea'), '^CJ-', 'El pago nuevo lleva referencia de caja');

select * from finish();
rollback;
