-- El OTP va al teléfono REGISTRADO de mayor confianza, no al que llama.
create extension if not exists pgtap with schema extensions;
begin;
select plan(6);
\ir ../helpers.psql

\set asesor '00000000-0000-0000-0000-00000000c100'
select tests.crear_staff(:'asesor', 'asesor');

-- Paciente con dos teléfonos: A (WhatsApp, se marca verificada) y B (declarado)
select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '2221110700', 'ia', 'canal') #>> '{paciente,id}' as p \gset
select tests.como_postgres();
update core.identidades_paciente set nivel_confianza = 'verificada', verificada_en = now()
where tipo = 'telefono' and valor = '+522221110700';
insert into core.identidades_paciente (tipo, valor, paciente_id, nivel_confianza, origen_canal)
values ('telefono', '+522221110701', :'p', 'declarada', 'call_center');

-- Alguien llama desde B (podría estar falsificado)
select tests.como_staff(:'asesor', 'asesor');
select api.iniciar_contacto('call_center', '2221110701', 'humano') #>> '{sesion,interaccion_id}' as cc \gset
select tests.como_servicio();
select api.solicitar_otp(:'cc') as otp \gset
select is((:'otp')::jsonb ->> 'telefono', '+522221110700', 'El código va al teléfono verificado, no al que llama');
select is((:'otp')::jsonb ->> 'telefono_enmascarado', '+52******0700', 'y la consola solo puede mostrar el enmascarado');

select tests.como_staff(:'asesor', 'asesor');
select is(api.validar_otp(:'cc', (:'otp')::jsonb ->> 'codigo') ->> 'verificado', 'true', 'El código correcto verifica la sesión');
select tests.como_postgres();
select is((select nivel_confianza from core.identidades_paciente where valor = '+522221110701'), 'declarada',
          'validar_otp no verifica el número desde el que llamaron');

-- Si solo tiene un teléfono declarado, se manda a ese
select tests.como_staff(:'asesor', 'asesor');
select api.iniciar_contacto('call_center', '2221110702', 'humano') #>> '{sesion,interaccion_id}' as cc2 \gset
select tests.como_servicio();
select is(api.solicitar_otp(:'cc2') ->> 'telefono', '+522221110702', 'Con un solo teléfono declarado, va a ese');

-- Solo service_role (la Edge Function) puede pedir un OTP
select tests.como_staff(:'asesor', 'asesor');
select throws_ok(format('select api.solicitar_otp(%L)', :'cc2'), '42501', null,
                 'authenticated no puede ejecutar solicitar_otp');

select finish();
rollback;
