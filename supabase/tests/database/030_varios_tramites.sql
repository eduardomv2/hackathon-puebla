-- Varios trámites abiertos a la vez, su etiqueta y folio, y la regla de
-- duplicados (mismo estudio + misma persona). También la fusión.
create extension if not exists pgtap with schema extensions;
begin;
select plan(12);
\ir ../helpers.psql

select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '2221110800', 'ia', 'canal') #>> '{sesion,interaccion_id}' as i \gset
select tests.registrar(:'i');
select api.agregar_beneficiario(:'i', 'Luis', 'López', null, '2016-07-01', null, 'hijo', true) ->> 'beneficiario_id' as hijo \gset
select api.obtener_contexto(:'i') #>> '{paciente,id}' as mama \gset

-- Dos trámites a la vez: mastografía para ella y ultrasonido para su hijo
select api.iniciar_tramite(:'i', tests.estudio('MASTO')) ->> 'id' as t1 \gset
select api.iniciar_tramite(:'i', tests.estudio('US-ABD'), :'hijo') ->> 'id' as t2 \gset

select api.obtener_contexto(:'i') as ctx \gset
select is(jsonb_array_length((:'ctx')::jsonb -> 'tramites_abiertos'), 2, 'Conviven dos trámites abiertos');
select set_eq(format($q$select x ->> 'etiqueta' from jsonb_array_elements(%L::jsonb) x$q$, (:'ctx')::jsonb -> 'tramites_abiertos'),
              array['Mastografía · para ti', 'Ultrasonido abdominal · para Luis'],
              'Cada uno con su etiqueta "<estudio> · para <ti | nombre>"');
select ok((select bool_and(x ->> 'folio' ~ '^SD-[A-HJ-NP-Z2-9]{4}$') from jsonb_array_elements((:'ctx')::jsonb -> 'tramites_abiertos') x),
          'y un folio corto legible');
select is((:'ctx')::jsonb #>> '{tramite_activo,id}', :'t2', 'El trámite activo de la sesión es con el que trabajó al final');
select is(api.retomar_tramite(:'i', :'t1') ->> 'id', :'t1', 'retomar_tramite cambia de trámite');
select is(api.obtener_contexto(:'i') #>> '{tramite_activo,etiqueta}', 'Mastografía · para ti', 'y el contexto lo refleja');

-- Duplicado: otra mastografía para ella mientras la primera sigue abierta
select tests.error_de(format('select api.iniciar_tramite(%L, %L)', :'i', tests.estudio('MASTO'))) as e \gset
select is((:'e')::jsonb ->> 'message', 'tramite_duplicado', 'Iniciar el mismo estudio para la misma persona con otro abierto → PT409 tramite_duplicado');
select is((:'e')::jsonb #>> '{detail,tramite_id}', :'t1', 'e indica cuál existe, para ofrecer continuar ese');

-- Mismo estudio para otra persona sí se permite
select lives_ok(format('select api.iniciar_tramite(%L, %L, %L)', :'i', tests.estudio('MASTO'), :'hijo'),
                'El mismo estudio para otra persona se permite');

-- Cita futura: cuando la mastografía de ella ya tiene cita, otro trámite igual tampoco
select tests.hasta_horario(:'i', :'t1', 1, 'MASTO') as v \gset
select api.reservar_cita(:'i', :'t1', :v, tests.en_dias(3)) is not null as r \gset
select tests.como_postgres();
update core.tramites set estado = 'completado' where id = :'t1';   -- como si ya hubiera pagado
select tests.como_servicio();
select is(tests.error_de(format('select api.iniciar_tramite(%L, %L)', :'i', tests.estudio('MASTO'))) ->> 'message',
          'cita_duplicada', 'Con una cita futura del mismo estudio y persona → PT409 cita_duplicada');

-- Fusión: los trámites pasan al paciente conservado; los duplicados se resuelven
select api.iniciar_contacto('whatsapp', '2221110801', 'ia', 'canal') #>> '{sesion,interaccion_id}' as j \gset
select tests.registrar(:'j');
select api.obtener_contexto(:'j') #>> '{paciente,id}' as otro \gset
select api.iniciar_tramite(:'j', tests.estudio('QS6')) ->> 'id' as viejo \gset
select api.iniciar_tramite(:'i', tests.estudio('QS6')) ->> 'id' as nuevo \gset
select tests.como_postgres();
update core.tramites set ultima_actividad_en = now() - interval '1 day' where id = :'viejo';
select core.fusionar_pacientes(:'otro', :'mama', 'prueba');
select is((select estado from core.tramites where id = :'viejo'), 'cancelado', 'Al fusionar, el duplicado con menos actividad se cancela');
select is((select payload ->> 'motivo' from core.eventos_tramite where tramite_id = :'viejo' and tipo_evento = 'tramite_cancelado'),
          'duplicado_por_fusion', 'con su evento');

select finish();
rollback;
