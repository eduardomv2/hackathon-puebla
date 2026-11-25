-- Registro mínimo del titular: nombre + apellido paterno + celular verificado antes del primer trámite.
create extension if not exists pgtap with schema extensions;
begin;
select plan(14);
\ir ../helpers.psql

\set asesora '00000000-0000-0000-0000-00000000c150'
\set sup     '00000000-0000-0000-0000-00000000c151'
\set web     '00000000-0000-0000-0000-00000000a150'
select tests.crear_staff(:'asesora', 'asesor');
select tests.crear_staff(:'sup', 'admin');
select tests.crear_usuario(:'web');

-- WhatsApp: el número ya está probado (nivel canal), pero falta el nombre
select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '5218661234591', 'ia', 'canal') as c \gset
select (:'c')::jsonb #>> '{sesion,interaccion_id}' as i \gset
select (:'c')::jsonb #>> '{paciente,id}' as p \gset
select is((:'c')::jsonb #> '{sesion,requiere_registro}', '["nombre", "apellido_paterno"]'::jsonb,
          'El contexto dice qué falta registrar');
select is((:'c')::jsonb #>> '{paciente,nombre_mostrar}', 'Paciente +52******4591',
          'Sin nombre se muestra con el teléfono enmascarado');
select is(tests.error_de(format('select api.iniciar_tramite(%L, %L)', :'i', tests.estudio('BH'))),
          jsonb_build_object('code', '22023', 'message', 'faltan_datos_titular',
                             'detail', '{"faltan": ["nombre", "apellido_paterno"]}'::jsonb),
          'Sin nombre no se inicia un trámite: 22023 faltan_datos_titular con los campos');

select api.guardar_datos_paciente(:'i', 'Rosa') #> '{sesion,requiere_registro}' as falta \gset
select is(:'falta'::jsonb, '["apellido_paterno"]'::jsonb, 'Con solo el nombre aún falta el apellido paterno');
select api.guardar_datos_paciente(:'i', null, 'Díaz') #> '{sesion,requiere_registro}' as falta \gset
select is(:'falta'::jsonb, '[]'::jsonb, 'El apellido materno es opcional: registro completo');
select is(api.iniciar_tramite(:'i', tests.estudio('BH')) ->> 'paso_actual', 'seleccion_clinica',
          'Con el registro completo inicia su trámite');

-- Web: el OTP va primero (42501); verificada pero sin nombre → faltan_datos_titular
select tests.como_paciente(:'web');
select api.iniciar_sesion_paciente('web') #>> '{sesion,interaccion_id}' as w \gset
select throws_ok(format('select api.iniciar_tramite(%L, %L)', :'w', tests.estudio('BH')), '42501', null,
                 'En la web sin OTP: primero verificar el celular');
select tests.como_postgres();
select tests.verificar_telefono_auth(:'web', '528661234592');
select tests.como_paciente(:'web', false);
select api.iniciar_sesion_paciente('web') #>> '{sesion,interaccion_id}' as w \gset
select is(api.obtener_contexto(:'w') #> '{sesion,requiere_registro}', '["nombre", "apellido_paterno"]'::jsonb,
          'Con el celular verificado solo faltan nombre y apellido');
select throws_ok(format('select api.iniciar_tramite(%L, %L)', :'w', tests.estudio('BH')), '22023', 'faltan_datos_titular',
                 'y sin ellos no inicia');

-- Call center: el número dictado no cuenta como verificado; el personal captura el nombre
select tests.como_staff(:'asesora', 'asesor');
select api.iniciar_contacto('call_center', '2221115000', 'humano') as cc \gset
select (:'cc')::jsonb #>> '{sesion,interaccion_id}' as cci \gset
select (:'cc')::jsonb #>> '{paciente,id}' as ccp \gset
select api.guardar_datos_paciente(:'cci', 'Luis', 'Pérez', 'Gómez') is not null as d \gset
select tests.como_postgres();
select is(core.faltantes_registro(:'ccp'), array['celular_verificado'],
          'El asesor captura el nombre; el teléfono dictado aún no está verificado');
select tests.como_servicio();
select api.solicitar_otp(:'cci') ->> 'codigo' as otp \gset
select tests.como_staff(:'asesora', 'asesor');
select is(api.validar_otp(:'cci', :'otp') #> '{contexto,sesion,requiere_registro}', '[]'::jsonb,
          'Con el OTP validado el registro queda completo');
select ok(api.iniciar_tramite(:'cci', tests.estudio('BH')) ->> 'id' is not null, 'y el asesor inicia el trámite');

-- Pacientes anteriores sin nombre: las listas del personal muestran el teléfono enmascarado
select tests.como_postgres();
update core.pacientes set nombre = null, apellido_paterno = null where id = :'p';
select tests.como_staff(:'sup', 'admin');
select is((select x ->> 'paciente' from jsonb_array_elements(api.tramites_en_curso()) x where x ->> 'paciente_id' = :'p'),
          'Paciente +52******4591', 'Trámites en curso: sin nombre, teléfono enmascarado');
select is(api.journey_paciente(:'p') #>> '{paciente,nombre}', 'Paciente +52******4591', 'Journey: igual');

select finish();
rollback;
