-- Una mamá agenda para su hijo: titular ≠ beneficiario. Además: reutilización,
-- tope de 10, beneficiarios ajenos, agenda de la clínica, verificación
-- presencial y la regla de que un paciente 'declarado' nunca se fusiona.
create extension if not exists pgtap with schema extensions;
begin;
select plan(20);
\ir ../helpers.psql

\set recep '00000000-0000-0000-0000-00000000c002'
select tests.crear_staff(:'recep', 'asesor', tests.clinica('PUE-ANG'));

-- La mamá escribe por WhatsApp y registra a su hijo
select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '2221110002', 'ia', 'canal') #>> '{sesion,interaccion_id}' as mi \gset
select api.guardar_datos_paciente(:'mi', 'María', 'López', 'Ruiz', '1985-03-10', 'F') #>> '{paciente,id}' as mama \gset
select api.agregar_beneficiario(:'mi', 'Luis', 'López', null, '2016-07-01', 'M', 'hijo', true) as b \gset
select is((:'b')::jsonb ->> 'reutilizado', 'false', 'Se crea el beneficiario');
select (:'b')::jsonb ->> 'beneficiario_id' as hijo \gset
select is(api.agregar_beneficiario(:'mi', '  luis ', 'LÓPEZ', null, '2016-07-01', 'M', 'hijo', true) ->> 'beneficiario_id',
          :'hijo', 'Mismo nombre (sin importar espacios ni mayúsculas) y fecha: se reutiliza');
select is(api.mis_beneficiarios(:'mi') -> 0 ->> 'nombre', 'Luis', 'mis_beneficiarios lo lista');
select is(api.mis_beneficiarios(:'mi') -> 0 ->> 'fecha_nacimiento', null, 'con nivel canal sin fecha de nacimiento');

select tests.como_postgres();
select is((select estado from core.pacientes where id = :'hijo'), 'declarado', 'El hijo queda como paciente declarado');
select is((select count(*)::int from core.identidades_paciente where paciente_id = :'hijo'), 0, 'sin identidades propias');

-- Cita para el hijo
select tests.como_servicio();
select api.iniciar_tramite(:'mi', tests.estudio('US-ABD'), :'hijo') ->> 'id' as t \gset
select tests.hasta_horario(:'mi', :'t', 1, 'US-ABD', 'PUE-ANG', :'hijo') as v \gset
select is(api.reservar_cita(:'mi', :'t', :v, tests.en_dias(3)) #>> '{beneficiario,relacion}', 'hijo',
          'El trámite dice para quién es');
select api.obtener_contexto(:'mi') #> '{citas_proximas,0}' as cita \gset
select is((:'cita')::jsonb #>> '{beneficiario,id}', :'hijo', 'La cita en el contexto es del hijo');
select is((:'cita')::jsonb #>> '{beneficiario,relacion}', 'hijo', 'con su relación');
select tests.como_postgres();
select is((select paciente_id from core.citas where id = ((:'cita')::jsonb ->> 'id')::uuid), :'mama'::uuid,
          'pero la cita (llave y pago) es de la mamá');

-- Otro titular no puede usar a ese hijo
select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '2221110003', 'ia', 'canal') #>> '{sesion,interaccion_id}' as otra \gset
select tests.registrar(:'otra');
select api.iniciar_tramite(:'otra', tests.estudio('BH')) ->> 'id' as t2 \gset
select throws_ok(format('select api.avanzar_tramite(%L, %L, 1, %L, %L)', :'otra', :'t2', 'seleccion_clinica',
                        jsonb_build_object('estudio_id', tests.estudio('BH'), 'beneficiario_id', :'hijo')),
                 '22023', 'El beneficiario no pertenece a este titular', 'No se agenda para el hijo de otra persona');

-- Tope de 10 beneficiarios
select count(api.agregar_beneficiario(:'mi', 'Familiar ' || n, null, null, '2010-01-01', null, 'otro', false))
from generate_series(1, 9) n;
select throws_ok(format('select api.agregar_beneficiario(%L, %L, null, null, %L, null, %L, false)',
                        :'mi', 'Familiar 10', '2010-01-01', 'otro'),
                 'PT409', 'limite_beneficiarios', 'Máximo 10 beneficiarios por titular');

-- En la clínica: agenda y verificación presencial
select tests.como_staff(:'recep', 'asesor', tests.clinica('PUE-ANG'));
select api.agenda_clinica(tests.clinica('PUE-ANG'), (tests.en_dias(3) at time zone 'America/Mexico_City')::date) -> 0 as ag \gset
select is((:'ag')::jsonb ->> 'paciente', 'Luis L.', 'La agenda muestra a quien se atiende');
select is((:'ag')::jsonb ->> 'agendada_por', 'María L.', 'y quién agendó');
select is(api.verificar_presencial(((:'cita')::jsonb ->> 'id')::uuid, 'acta_nacimiento') ->> 'tipo_documento',
          'acta_nacimiento', 'El personal de clínica verifica al hijo en persona');
select tests.como_postgres();
select isnt((select verificado_presencial_en from core.pacientes where id = :'hijo'), null, 'queda la marca presencial');
select is((select array_agg(k order by k) from core.eventos_tramite e, jsonb_object_keys(e.payload) k
           where e.tipo_evento = 'identidad_presencial_verificada'),
          array['beneficiario_id', 'cita_id', 'relacion', 'tipo_documento'],
          'El evento guarda el tipo de documento, nunca su número');
select tests.como_paciente('00000000-0000-0000-0000-00000000a099');
select throws_ok(format('select api.verificar_presencial(%L, %L)', (:'cita')::jsonb ->> 'id', 'ine'),
                 '42501', null, 'Un paciente no puede marcarse verificado en persona');

-- Un declarado nunca se fusiona
select tests.como_postgres();
select throws_ok(format('select core.fusionar_pacientes(%L, %L, %L)', :'hijo', :'mama', 'prueba'),
                 '42501', 'Un paciente declarado por un tercero nunca se fusiona', 'Declarado → titular: no se fusiona');
select throws_ok(format('select core.vincular_identidad(%L, %L, %L, %L, %L)', :'hijo', 'telefono', '2221110002', 'verificada', 'whatsapp'),
                 '42501', 'Un paciente declarado no tiene identidades propias', 'Ni se le liga un teléfono');

select finish();
rollback;
