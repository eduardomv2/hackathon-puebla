-- Carga 100 mil pacientes y 2 millones de eventos (solo para medir rendimiento).
set session_replication_role = replica;  -- carga masiva sin triggers (solo para el benchmark)
insert into core.pacientes (id, estado, nombre)
select core.uuid_v7(), 'identificado', 'P' || g from generate_series(1, 100000) g;
insert into core.identidades_paciente (tipo, valor, paciente_id, nivel_confianza, origen_canal)
select 'telefono', '+5281' || lpad(row_number() over ()::text, 8, '0'), id, 'canal', 'whatsapp' from core.pacientes where nombre like 'P%';
insert into core.tramites (paciente_id, tipo, paso_actual, canal_origen, ultimo_canal, contexto, estado)
select id, 'agendar_estudio', 'seleccion_clinica', 'web', 'web', '{}', case when random() < 0.3 then 'activo' else 'completado' end
from core.pacientes where nombre like 'P%';
insert into core.eventos_tramite (paciente_id, tramite_id, tipo_evento, canal, actor_tipo, ocurrido_en, payload)
select t.paciente_id, t.id, (array['paso_avanzado','interaccion_iniciada','canal_cambiado','tramite_retomado'])[1 + (g % 4)],
       (array['web','whatsapp','call_center','app'])[1 + (g % 4)], 'paciente',
       now() - (random() * interval '45 days'), '{}'
from core.tramites t cross join generate_series(1, 20) g;
set session_replication_role = origin;
analyze;
select (select count(*) from core.pacientes) pacientes, (select count(*) from core.eventos_tramite) eventos;
