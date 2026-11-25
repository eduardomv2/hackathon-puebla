-- Niveles de verificación: la fecha de nacimiento da 'canal', nunca
-- 'verificada'. 'verificada' solo con OTP o con cuenta de teléfono confirmado.
create extension if not exists pgtap with schema extensions;
begin;
select plan(8);
\ir ../helpers.psql

\set asesor   '00000000-0000-0000-0000-00000000c004'
\set con_tel  '00000000-0000-0000-0000-00000000d001'
\set con_mail '00000000-0000-0000-0000-00000000d002'
select tests.crear_staff(:'asesor', 'asesor');
select tests.crear_usuario(:'con_tel', false, '522221110060');
select tests.crear_usuario(:'con_mail', false, null, 'paciente@correo.test');

-- Paciente con fecha de nacimiento registrada
select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '2221110061', 'ia', 'canal') #>> '{sesion,interaccion_id}' as wa \gset
select api.guardar_datos_paciente(:'wa', 'Rosa', 'Díaz', null, '1970-12-01') is not null as d \gset

-- Llama al call center y da su fecha de nacimiento
select tests.como_staff(:'asesor', 'asesor');
select api.iniciar_contacto('call_center', '2221110061', 'humano') #>> '{sesion,interaccion_id}' as cc \gset
select api.verificar_identidad(:'cc', '1970-12-01') as vf \gset
select is((:'vf')::jsonb ->> 'nivel_verificacion', 'canal', 'La fecha de nacimiento correcta sube la sesión solo a canal');
select isnt((:'vf')::jsonb #>> '{contexto,sesion,nivel_verificacion}', 'verificada', 'nunca a verificada');
select is((:'vf')::jsonb #>> '{contexto,paciente,nombre}', 'Rosa', 'Con canal se ve solo el nombre de pila');
select is(api.verificar_identidad(:'cc', '1971-01-01') ->> 'motivo', 'dato_no_coincide', 'Una fecha equivocada no verifica');

-- El OTP sí verifica
select tests.como_servicio();
select api.solicitar_otp(:'cc') ->> 'codigo' as otp \gset
select tests.como_staff(:'asesor', 'asesor');
select is(api.validar_otp(:'cc', :'otp') #>> '{contexto,sesion,nivel_verificacion}', 'verificada', 'El OTP sí da verificada');
select is(api.obtener_contexto(:'cc') #>> '{paciente,nombre}', 'Rosa Díaz', 'y con verificada se ve el nombre completo');

-- Web / app: cuenta con teléfono confirmado → verificada; solo correo → canal
select tests.como_paciente(:'con_tel', false);
select is(api.iniciar_sesion_paciente('app') #>> '{sesion,nivel_verificacion}', 'verificada',
          'Cuenta con teléfono confirmado entra verificada');
select tests.como_paciente(:'con_mail', false);
select is(api.iniciar_sesion_paciente('web') #>> '{sesion,nivel_verificacion}', 'canal',
          'Cuenta solo con correo entra como canal');

select finish();
rollback;
