-- Recepción de clínica: rol con clínica, mostrador con INE, "el personal manda", llegada con turno.
create extension if not exists pgtap with schema extensions;
begin;
select plan(24);
\ir ../helpers.psql

\set rec   '00000000-0000-0000-0000-00000000c160'
\set rec2  '00000000-0000-0000-0000-00000000c161'
select throws_ok($$select tests.crear_staff('00000000-0000-0000-0000-00000000c169', 'recepcion')$$, '23514', null,
                 'Recepción sin clínica no se puede dar de alta');
select tests.crear_staff(:'rec', 'recepcion', tests.clinica('PUE-CEN'));
select tests.crear_staff(:'rec2', 'recepcion', tests.clinica('PUE-ANG'));
select tests.clinica('PUE-CEN') as cen \gset
select tests.clinica('PUE-ANG') as ang \gset

-- Rosa ya escribió por WhatsApp (celular probado) y está registrada
select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '5218661234595', 'ia', 'canal') #>> '{sesion,interaccion_id}' as wa \gset
select tests.registrar(:'wa', 'Rosa', 'Díaz');

-- Mostrador: solo canal clínica; la INE verifica ESA sesión
select tests.como_staff(:'rec', 'recepcion', :'cen');
select throws_ok($$select api.iniciar_contacto('call_center', '2221119595', 'humano')$$, '42501',
                 'Recepción solo opera en la clínica', 'Recepción no opera por call center');
select api.iniciar_contacto('clinica', '866 123 4595', 'humano') as m \gset
select (:'m')::jsonb #>> '{sesion,interaccion_id}' as mi \gset
select is((:'m')::jsonb #>> '{sesion,nivel_verificacion}', 'declarada', 'En mostrador empieza como declarada');
select is(api.verificar_presencial(p_interaccion_id => :'mi', p_tipo_documento => 'ine') #>> '{sesion,nivel_verificacion}',
          'verificada', '"Verificar INE" sube la sesión a verificada');
select is(api.obtener_contexto(:'mi') #> '{sesion,requiere_registro}', '[]'::jsonb,
          'Con su WhatsApp ya probado y su nombre, puede iniciar trámites');
select tests.como_postgres();
select is((select metodo_verificacion from core.interacciones where id = :'mi'), 'identificacion', 'Método: identificación');
select is((select payload from core.eventos_tramite where interaccion_id = :'mi' and tipo_evento = 'identidad_verificada'),
          '{"metodo": "identificacion", "tipo_documento": "ine"}'::jsonb, 'Solo se guarda el tipo de documento');

-- Recepción inicia el trámite: queda bloqueado para WhatsApp (el personal manda)
select tests.como_staff(:'rec', 'recepcion', :'cen');
select api.iniciar_tramite(:'mi', tests.estudio('US-OBS')) as t \gset
select (:'t')::jsonb ->> 'id' as tid \gset
select tests.como_servicio();
select is(tests.error_de(format('select api.avanzar_tramite(%L, %L, %s, %L, %L)', :'wa', :'tid', (:'t')::jsonb ->> 'version',
            'seleccion_horario', jsonb_build_object('clinica_id', :'cen'))) ->> 'code', 'PT423',
          'WhatsApp ve el trámite pero no lo cambia (PT423)');
select is(api.obtener_contexto(:'wa') #>> '{tramites_abiertos,0,atencion_canal}', 'clinica', 'y sabe que lo atienden en la clínica');
select matches(api.texto_asesor_atendiendo(:'wa', :'tid'), '^Te están atendiendo en la clínica', 'con su propia plantilla');

-- Solo agenda en su clínica
select tests.como_staff(:'rec', 'recepcion', :'cen');
select throws_ok(format('select api.avanzar_tramite(%L, %L, %s, %L, %L)', :'mi', :'tid', (:'t')::jsonb ->> 'version',
                        'seleccion_horario', jsonb_build_object('clinica_id', :'ang')),
                 '42501', 'Fuera del alcance de tu clínica', 'Recepción no agenda en otra clínica');
select tests.hasta_horario(:'mi', :'tid', ((:'t')::jsonb ->> 'version')::int, 'US-OBS') as v \gset
select api.reservar_cita(:'mi', :'tid', :v, tests.en_dias(1)) #>> '{contexto,cita_id}' as cita \gset

-- Llegada: la cita es de hoy (la movemos como postgres)
select tests.como_postgres();
update core.citas set fecha_hora = now() where id = :'cita';
select tests.como_staff(:'rec2', 'recepcion', :'ang');
select throws_ok(format('select api.registrar_llegada(%L, %L, true)', :'cita', 'ine'), '42501', null,
                 'Recepción de otra clínica no registra la llegada');
select tests.como_staff(:'rec', 'recepcion', :'cen');
select api.registrar_llegada(:'cita', 'ine', true) as l \gset
select is((:'l')::jsonb ->> 'turno', 'U-001', 'Turno por área y día: U-001');
select is((:'l')::jsonb ->> 'indicacion', 'Pasar a caja', 'Sin pago: pasar a caja');
select is((:'l')::jsonb ->> 'preparacion', 'Vejiga llena: tomar 1 litro de agua una hora antes.', 'Muestra la preparación');
select throws_ok(format('select api.registrar_llegada(%L, %L, true)', :'cita', 'ine'), 'P0001', null, 'No se registra dos veces');
select tests.como_postgres();
select is((select estado from core.citas where id = :'cita'), 'en_clinica', 'La cita queda en_clinica');
select ok((select llegada_en is not null from core.citas where id = :'cita'), 'con hora de llegada');
select is((select payload ->> 'cumplio_preparacion' from core.eventos_tramite
           where tramite_id = :'tid' and tipo_evento = 'llegada_registrada'), 'true', 'La respuesta de preparación va en el evento');

-- Paga en caja: sigue en clínica; ahora pasa a Ultrasonido
select tests.como_staff(:'rec', 'recepcion', :'cen');
select tests.pagar(:'mi', :'tid', (api.obtener_contexto(:'mi') #>> '{tramite_activo,version}')::int) is not null as p \gset
select tests.como_postgres();
select is((select estado from core.citas where id = :'cita'), 'en_clinica', 'Pagar en caja no la saca de en_clinica');
select tests.como_staff(:'rec', 'recepcion', :'cen');
select is((select x ->> 'pagada' from jsonb_array_elements(api.agenda_clinica(:'cen', (now() at time zone 'America/Mexico_City')::date)) x
           where x ->> 'cita_id' = :'cita'), 'true', 'La agenda del día muestra que ya pagó');

-- Mamá agenda para su hijo: se verifica la INE (u otro documento) del hijo, turno siguiente del área
select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '5218661234596', 'ia', 'canal') #>> '{sesion,interaccion_id}' as mama \gset
select tests.registrar(:'mama', 'María', 'López');
select api.agregar_beneficiario(:'mama', 'Luis', 'López', null, '2016-07-01', 'M', 'hijo', true) ->> 'beneficiario_id' as hijo \gset
select api.iniciar_tramite(:'mama', tests.estudio('US-ABD'), :'hijo') ->> 'id' as t2 \gset
select tests.hasta_horario(:'mama', :'t2', 1, 'US-ABD', 'PUE-CEN', :'hijo') as v2 \gset
select api.reservar_cita(:'mama', :'t2', :v2, tests.en_dias(1)) #>> '{contexto,cita_id}' as cita2 \gset
select tests.como_postgres();
update core.citas set fecha_hora = now() where id = :'cita2';
select tests.como_staff(:'rec', 'recepcion', :'cen');
select is(api.registrar_llegada(:'cita2', 'acta_nacimiento', false) ->> 'turno', 'U-002', 'El siguiente del área: U-002');
select tests.como_postgres();
select ok((select verificado_presencial_en is not null from core.pacientes where id = :'hijo'),
          'Se verifica a quien recibe el estudio (el hijo)');

-- Una cita que no es de hoy no registra llegada
select tests.como_servicio();
select api.iniciar_tramite(:'mama', tests.estudio('BH')) ->> 'id' as t3 \gset
select tests.hasta_horario(:'mama', :'t3', 1, 'BH') as v3 \gset
select api.reservar_cita(:'mama', :'t3', :v3, tests.en_dias(2)) #>> '{contexto,cita_id}' as cita3 \gset
select tests.como_staff(:'rec', 'recepcion', :'cen');
select throws_ok(format('select api.registrar_llegada(%L, %L, true)', :'cita3', 'ine'), '22023', 'La cita no es de hoy',
                 'Solo citas del día');

select finish();
rollback;
