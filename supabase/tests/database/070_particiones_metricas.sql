-- Particiones en su propio esquema y métricas permanentes con recálculo
-- solo de los días afectados.
create extension if not exists pgtap with schema extensions;
begin;
select plan(13);
\ir ../helpers.psql

-- ---------------------------------------------------------------------
-- Particiones
-- ---------------------------------------------------------------------
select is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where c.relispartition and n.nspname in ('core', 'audit')), 0,
          'core y audit no contienen particiones');
select is((select count(*)::int from pg_inherits i join pg_class c on c.oid = i.inhrelid
           join pg_namespace n on n.oid = c.relnamespace
           where i.inhparent in ('core.eventos_tramite'::regclass, 'core.mensajes'::regclass, 'audit.registro'::regclass)
             and n.nspname <> 'particiones'), 0,
          'Todas las particiones de eventos, mensajes y bitácora están en el esquema particiones');
select ok(core.asegurar_particiones('core.eventos_tramite', 0, 8) > 0, 'asegurar_particiones crea las nuevas');
select is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'particiones' and c.relkind = 'r' and not c.relrowsecurity), 0,
          'y todas tienen RLS');
select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '2221110090', 'ia', 'canal') #>> '{sesion,interaccion_id}' as i \gset
select tests.como_postgres();
select is((select distinct relnamespace::regnamespace::text from core.eventos_tramite e join pg_class c on c.oid = e.tableoid),
          'particiones', 'Se inserta por el padre y la fila cae en particiones');

-- ---------------------------------------------------------------------
-- Métricas: un trámite creado hace 5 días que se completa hoy
-- ---------------------------------------------------------------------
select paciente_id as p from core.interacciones where id = :'i' \gset
\set d5 '(now() at time zone ''America/Mexico_City'' - interval ''5 days'')::date'
\set d8 '(now() at time zone ''America/Mexico_City'' - interval ''8 days'')::date'

-- Datos "del pasado": se insertan con creado_en y actualizado_en antiguos
alter table core.tramites disable trigger trg_10_columnas;
insert into core.tramites (paciente_id, tipo, paso_actual, canal_origen, ultimo_canal, creado_en, actualizado_en)
values (:'p', 'agendar_estudio', 'seleccion_estudio', 'web', 'web', now() - interval '5 days', now() - interval '5 days')
returning id as t5 \gset
insert into core.tramites (paciente_id, tipo, paso_actual, canal_origen, ultimo_canal, estado, creado_en, actualizado_en)
values (:'p', 'agendar_estudio', 'seleccion_estudio', 'web', 'web', 'abandonado', now() - interval '8 days', now() - interval '8 days'),
       (:'p', 'agendar_estudio', 'seleccion_estudio', 'whatsapp', 'whatsapp', 'completado',
        now() - interval '1 year 2 days', now() - interval '1 year');
alter table core.tramites enable trigger trg_10_columnas;

-- Carga inicial y una corrida previa "hace una hora"
select core.recalcular_metricas_rango((now() - interval '1 year 10 days')::date, current_date) is not null as carga \gset
update core.estado_metricas set ultima_corrida = now() - interval '1 hour';
update core.metricas_tramites_diarias set calculado_en = '2000-01-01';
select is((select estado from core.metricas_tramites_diarias where dia = :d5), 'activo', 'Antes: el trámite de hace 5 días está activo');

-- Hoy se completa y corre el cron
update core.tramites set estado = 'completado', finalizado_en = now() where id = :'t5';
select core.recalcular_metricas() -> 'dias_tramites' as dias \gset
select is((select estado from core.metricas_tramites_diarias where dia = :d5), 'completado',
          'Después: aparece como completado en su día de creación');
select is((select count(*)::int from core.metricas_tramites_diarias where dia = :d5 and estado = 'activo'), 0,
          'y ya no cuenta como activo');
select is((:'dias')::jsonb, jsonb_build_array(:d5, (now() at time zone 'America/Mexico_City')::date - 1,
                                              (now() at time zone 'America/Mexico_City')::date),
          'Solo se recalculan su día, ayer y hoy');
select is((select calculado_en from core.metricas_tramites_diarias where dia = :d8), '2000-01-01'::timestamptz,
          'El día que nadie tocó no se recalcula y sus métricas sobreviven');
select is((select ultima_corrida from core.estado_metricas), now(), 'ultima_corrida se fija al inicio de la corrida');

-- ---------------------------------------------------------------------
-- api.metricas compara con el mismo periodo del año anterior
-- ---------------------------------------------------------------------
select tests.como_staff('00000000-0000-0000-0000-0000000000ad', 'admin');
select api.metricas(current_date - 10, current_date) as m \gset
select is(((:'m')::jsonb #>> '{anio_anterior,tramites}')::int, 1, 'Cuenta los trámites del mismo periodo del año anterior');
select throws_ok('select api.metricas(current_date, current_date - 1)', '22023', 'Rango de fechas inválido',
                 'Un rango invertido es un error');

select finish();
rollback;
