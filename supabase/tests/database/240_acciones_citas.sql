-- Acciones sobre citas: reprogramar, cancelar (con y sin pago), pedir agente y marcar atendida.
create extension if not exists pgtap with schema extensions;
begin;
select plan(27);
\ir ../helpers.psql

\set rec   '00000000-0000-0000-0000-00000000a240'
\set rec2  '00000000-0000-0000-0000-00000000a241'
\set aseso '00000000-0000-0000-0000-00000000a242'
select tests.clinica('PUE-CEN') as cen \gset
select tests.clinica('PUE-ANG') as ang \gset
select tests.crear_staff(:'rec', 'recepcion', :'cen');
select tests.crear_staff(:'rec2', 'recepcion', :'ang');
select tests.crear_staff(:'aseso', 'asesor');

-- Ana: cita pagada. Bea: cita sin pagar. Cleo: otra paciente
select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '5218661240001', 'ia', 'canal') #>> '{sesion,interaccion_id}' as ana \gset
select tests.registrar(:'ana', 'Ana', 'Acciones');
select api.iniciar_tramite(:'ana', tests.estudio('BH')) ->> 'id' as ta \gset
select tests.hasta_horario(:'ana', :'ta', 1, 'BH') as va \gset
select api.reservar_cita(:'ana', :'ta', :va, tests.en_dias(1)) ->> 'version' as va2 \gset
select tests.pagar(:'ana', :'ta', :va2::int) is not null as pagada \gset
select tests.como_postgres();
select id as cita_ana from core.citas where tramite_id = :'ta' \gset
select tests.como_servicio();

select api.iniciar_contacto('whatsapp', '5218661240002', 'ia', 'canal') #>> '{sesion,interaccion_id}' as bea \gset
select tests.registrar(:'bea', 'Bea', 'Acciones');
select api.iniciar_tramite(:'bea', tests.estudio('BH')) ->> 'id' as tb \gset
select tests.hasta_horario(:'bea', :'tb', 1, 'BH') as vb \gset
select api.reservar_cita(:'bea', :'tb', :vb, tests.en_dias(2)) ->> 'version' as vb2 \gset
select api.generar_pago(:'bea', :'tb', :vb2::int) is not null as pendiente \gset
select tests.como_postgres();
select id as cita_bea from core.citas where tramite_id = :'tb' \gset
select tests.como_servicio();

select api.iniciar_contacto('whatsapp', '5218661240003', 'ia', 'canal') #>> '{sesion,interaccion_id}' as cleo \gset
select tests.registrar(:'cleo', 'Cleo', 'Acciones');

-- Reprogramar
select is(tests.error_de(format('select api.reprogramar_cita(%L, %L, %L)', :'ana', :'cita_ana', tests.en_dias(1))) ->> 'code',
          '22023', 'Elegir el mismo horario se rechaza');
select is(tests.error_de(format('select api.reprogramar_cita(%L, %L, %L)', :'ana', :'cita_ana', tests.en_dias(3) - interval '7 hours')) ->> 'code',
          '22023', 'Fuera del horario de atención se rechaza');
select is(tests.error_de(format('select api.reprogramar_cita(%L, %L, %L)', :'ana', :'cita_ana', now() + interval '10 minutes')) ->> 'code',
          '22023', 'Con menos de una hora de anticipación se rechaza');
select is(tests.error_de(format('select api.reprogramar_cita(%L, %L, %L)', :'cleo', :'cita_ana', tests.en_dias(3))) ->> 'code',
          'PT404', 'Otra paciente no puede mover la cita');
select is(api.reprogramar_cita(:'ana', :'cita_ana', tests.en_dias(3)) ->> 'estado', 'confirmada',
          'Reprogramar conserva el estado confirmada');
select tests.como_postgres();
select is((select fecha_hora from core.citas where id = :'cita_ana'), tests.en_dias(3), 'La cita quedó en el horario nuevo');
select is((select fecha_hora from core.agenda_clinica where cita_id = :'cita_ana'), tests.en_dias(3), 'y la agenda de la clínica también');
select is((select payload ->> 'a' from core.eventos_tramite where tipo_evento = 'cita_reprogramada' and tramite_id = :'ta')::timestamptz,
          tests.en_dias(3), 'Queda el evento cita_reprogramada (lo ven todos los canales)');
select is((select canal from core.eventos_tramite where tipo_evento = 'cita_reprogramada' and tramite_id = :'ta'), 'whatsapp',
          'con el canal desde el que se pidió');

-- Cancelar con pago: se reembolsa
select tests.como_servicio();
select is(api.cancelar_cita(:'ana', :'cita_ana', 'ya no puedo') ->> 'reembolso', 'true', 'Cancelar una cita pagada marca reembolso');
select is(tests.error_de(format('select api.cancelar_cita(%L, %L)', :'ana', :'cita_ana')) ->> 'code', '22023', 'No se cancela dos veces');
select is(tests.error_de(format('select api.reprogramar_cita(%L, %L, %L)', :'ana', :'cita_ana', tests.en_dias(4))) ->> 'code', '22023',
          'Ni se reprograma una cita cancelada');
select tests.como_postgres();
select is((select estado from core.pagos where cita_id = :'cita_ana'), 'reembolsado', 'El pago queda reembolsado');
select is((select estado from core.tramites where id = :'ta'), 'completado', 'El trámite completado se queda como historial');
select is((select payload ->> 'motivo' from core.eventos_tramite where tipo_evento = 'cita_cancelada' and tramite_id = :'ta'),
          'ya no puedo', 'El motivo queda en el evento');

-- Cancelar sin pagar: expira el pago y se cancela el trámite abierto
select tests.como_servicio();
select is(api.cancelar_cita(:'bea', :'cita_bea') ->> 'reembolso', 'false', 'Sin pago no hay reembolso');
select tests.como_postgres();
select is((select estado from core.pagos where cita_id = :'cita_bea'), 'expirado', 'El link de pago pendiente deja de servir');
select is((select estado from core.tramites where id = :'tb'), 'cancelado', 'El trámite abierto se cancela');

-- Pedir agente
select tests.como_servicio();
select is(api.solicitar_agente(:'cleo', 'quiero hablar con alguien') ->> 'solicitado', 'true', 'Cleo pide un agente');
select tests.como_staff(:'aseso', 'asesor');
select is(jsonb_array_length(api.solicitudes_agente()), 1, 'El asesor ve la solicitud pendiente');
select is(api.solicitudes_agente() #>> '{0,motivo}', 'quiero hablar con alguien', 'con su motivo');
select tests.como_paciente('00000000-0000-0000-0000-00000000a249');
select throws_ok($$select api.solicitudes_agente()$$, '42501', null, 'Un paciente no ve la lista de solicitudes');

-- Marcar atendida (recepción)
select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '5218661240004', 'ia', 'canal') #>> '{sesion,interaccion_id}' as dan \gset
select tests.registrar(:'dan', 'Dan', 'Acciones');
select api.iniciar_tramite(:'dan', tests.estudio('BH')) ->> 'id' as td \gset
select tests.hasta_horario(:'dan', :'td', 1, 'BH') as vd \gset
select api.reservar_cita(:'dan', :'td', :vd, tests.en_dias(1)) ->> 'version' as vd2 \gset
select tests.pagar(:'dan', :'td', :vd2::int) is not null as pagada_d \gset
select tests.como_postgres();
select id as cita_dan from core.citas where tramite_id = :'td' \gset
select tests.como_servicio();
select tests.como_postgres();
update core.citas set fecha_hora = now() where id = :'cita_dan';
select tests.como_staff(:'rec', 'recepcion', :'cen');
select throws_ok(format('select api.marcar_atendida(%L)', :'cita_dan'), '22023', null, 'Sin registrar la llegada no se marca atendida');
select api.registrar_llegada(:'cita_dan', 'ine', true) is not null as llego \gset
select tests.como_staff(:'rec2', 'recepcion', :'ang');
select throws_ok(format('select api.marcar_atendida(%L)', :'cita_dan'), '42501', null, 'Recepción de otra clínica no puede');
select tests.como_staff(:'rec', 'recepcion', :'cen');
select is(api.marcar_atendida(:'cita_dan') ->> 'estado', 'atendida', 'Recepción marca la cita como atendida');
select throws_ok(format('select api.marcar_atendida(%L)', :'cita_dan'), 'P0001', null, 'No se marca dos veces');
select tests.como_postgres();
select is((select count(*)::int from core.eventos_tramite where tipo_evento = 'cita_atendida' and tramite_id = :'td'), 1,
          'Queda el evento cita_atendida');

select * from finish();
rollback;
