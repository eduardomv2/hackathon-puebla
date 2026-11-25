-- =====================================================================
-- 0700 · Procesos asíncronos y métricas
--   · Colas (pgmq): resumen con IA y recordatorios por WhatsApp
--   · Despachador: pg_cron + pg_net invocan Edge Functions solo si hay trabajo
--   · Expiración de trámites, pagos y sesiones inactivas
--   · Vistas materializadas para el tablero por clínica
-- =====================================================================

select pgmq.create('resumen_tramite');
select pgmq.create('recordatorios');

-- Invoca la Edge Function que consume la cola, solo si hay mensajes.
-- URL y token viven en Supabase Vault (nunca en el código).
create or replace function core.despachar_worker(p_cola text, p_funcion text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pendientes bigint;
  v_url   text;
  v_token text;
begin
  select queue_length into v_pendientes from pgmq.metrics(p_cola);
  if coalesce(v_pendientes, 0) = 0 then
    return;
  end if;
  select decrypted_secret into v_url   from vault.decrypted_secrets where name = 'project_url';
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'worker_token';
  perform net.http_post(
    url     := v_url || '/functions/v1/' || p_funcion,
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_token),
    body    := jsonb_build_object('cola', p_cola, 'pendientes', v_pendientes));
end
$$;

-- ---------------------------------------------------------------------
-- API para los workers (solo servicio)
-- ---------------------------------------------------------------------

-- Lee mensajes con tiempo de invisibilidad; tras 5 intentos van al archivo (cola de errores)
create or replace function api.cola_leer(p_cola text, p_cantidad int default 10, p_visibilidad_seg int default 60)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_salida jsonb := '[]';
begin
  perform core.exigir_rol('servicio');
  if p_cola not in ('resumen_tramite', 'recordatorios') then
    raise exception 'Cola desconocida: %', p_cola using errcode = '22023';
  end if;
  for r in select msg_id, read_ct, message from pgmq.read(p_cola, p_visibilidad_seg, least(greatest(p_cantidad, 1), 50)) loop
    if r.read_ct > 5 then
      perform pgmq.archive(p_cola, r.msg_id);
    else
      v_salida := v_salida || jsonb_build_object('msg_id', r.msg_id, 'intento', r.read_ct, 'mensaje', r.message);
    end if;
  end loop;
  return v_salida;
end
$$;

create or replace function api.cola_confirmar(p_cola text, p_msg_id bigint)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform core.exigir_rol('servicio');
  if p_cola not in ('resumen_tramite', 'recordatorios') then
    raise exception 'Cola desconocida: %', p_cola using errcode = '22023';
  end if;
  return pgmq.delete(p_cola, p_msg_id);
end
$$;

-- Material para que la IA actualice el resumen: resumen previo + lo ocurrido desde entonces
create or replace function api.material_resumen(p_tramite_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  t      core.tramites;
  v_desde timestamptz;
begin
  perform core.exigir_rol('servicio');
  select * into t from core.tramites where id = p_tramite_id;
  if not found then
    raise exception 'Trámite no encontrado' using errcode = 'P0002';
  end if;
  v_desde := coalesce(t.resumen_actualizado_en, '-infinity'::timestamptz);

  return jsonb_build_object(
    'leido_en', now(),
    'tramite', core.tramite_json(t),
    'resumen_anterior', t.resumen,
    'eventos_nuevos', (
      select coalesce(jsonb_agg(jsonb_build_object('ocurrido_en', ev.ocurrido_en, 'tipo_evento', ev.tipo_evento,
                                                   'canal', ev.canal, 'actor_tipo', ev.actor_tipo, 'payload', ev.payload)
                                order by ev.ocurrido_en), '[]')
      from core.eventos_tramite ev
      where ev.paciente_id = t.paciente_id and ev.tramite_id = t.id and ev.ocurrido_en > v_desde
        and ev.tipo_evento not in ('asesor_consulto_contexto', 'resumen_actualizado')),
    'mensajes_nuevos', (
      select coalesce(jsonb_agg(x order by x ->> 'creado_en'), '[]') from (
        select jsonb_build_object('creado_en', m.creado_en, 'canal', m.canal, 'autor', m.autor, 'contenido', m.contenido) as x
        from core.mensajes m
        join core.interacciones i on i.paciente_id = m.paciente_id and i.id = m.interaccion_id
        where m.paciente_id = t.paciente_id and i.tramite_id = t.id and m.creado_en > v_desde
        order by m.creado_en desc limit 100) s));
end
$$;

-- Guarda el resumen. Si llegaron eventos después de leer el material, pide otro.
create or replace function api.guardar_resumen(p_tramite_id uuid, p_resumen text, p_leido_en timestamptz)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_paciente uuid;
begin
  perform core.exigir_rol('servicio');
  perform core.establecer_actor('sistema', 'agente_ia');

  update core.tramites
  set resumen = p_resumen, resumen_actualizado_en = p_leido_en, resumen_pendiente = false
  where id = p_tramite_id
  returning paciente_id into v_paciente;
  if v_paciente is null then
    raise exception 'Trámite no encontrado' using errcode = 'P0002';
  end if;

  perform core.registrar_evento(v_paciente, p_tramite_id, null, 'resumen_actualizado', '{}');

  if exists (select 1 from core.eventos_tramite ev
             join core.catalogo_eventos c on c.tipo_evento = ev.tipo_evento and c.dispara_resumen
             where ev.paciente_id = v_paciente and ev.tramite_id = p_tramite_id and ev.ocurrido_en > p_leido_en) then
    perform core.solicitar_resumen(p_tramite_id);
  end if;
end
$$;

-- ---------------------------------------------------------------------
-- Tareas programadas
-- ---------------------------------------------------------------------

-- Trámites sin actividad por 2 horas: se encola un recordatorio por WhatsApp (una vez)
create or replace function core.programar_recordatorios()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  n int := 0;
begin
  perform set_config('app.canal', 'sistema', true);
  perform set_config('app.actor_tipo', 'sistema', true);
  for r in
    update core.tramites
    set recordatorio_enviado_en = now()
    where estado = 'activo' and recordatorio_enviado_en is null
      and ultima_actividad_en < now() - interval '2 hours' and expira_en > now()
    returning paciente_id, id, paso_actual
  loop
    perform pgmq.send('recordatorios', jsonb_build_object('paciente_id', r.paciente_id, 'tramite_id', r.id,
                                                          'paso_actual', r.paso_actual), 0);
    perform core.registrar_evento(r.paciente_id, r.id, null, 'recordatorio_programado',
                                  jsonb_build_object('paso_actual', r.paso_actual));
    n := n + 1;
  end loop;
  return n;
end
$$;

-- Trámites vencidos → abandonados (no se borran: son parte del historial)
create or replace function core.expirar_tramites()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  n int := 0;
begin
  perform set_config('app.canal', 'sistema', true);
  perform set_config('app.actor_tipo', 'sistema', true);
  for r in
    update core.tramites set estado = 'abandonado', finalizado_en = now()
    where estado in ('activo', 'pausado') and expira_en < now()
    returning paciente_id, id, paso_actual
  loop
    perform core.registrar_evento(r.paciente_id, r.id, null, 'tramite_abandonado',
                                  jsonb_build_object('ultimo_paso', r.paso_actual));
    n := n + 1;
  end loop;

  for r in
    update core.pagos set estado = 'expirado'
    where estado = 'pendiente' and expira_en < now()
    returning paciente_id, id, cita_id
  loop
    perform core.registrar_evento(r.paciente_id,
      (select tramite_id from core.citas where paciente_id = r.paciente_id and id = r.cita_id),
      null, 'pago_expirado', jsonb_build_object('pago_id', r.id));
  end loop;
  return n;
end
$$;

-- Sesiones abiertas sin actividad por 30 minutos se cierran (y disparan resumen)
create or replace function core.cerrar_interacciones_inactivas()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  n int := 0;
begin
  perform set_config('app.canal', 'sistema', true);
  perform set_config('app.actor_tipo', 'sistema', true);
  for r in
    update core.interacciones set finalizada_en = now(), resultado = 'inactiva'
    where finalizada_en is null and ultima_actividad_en < now() - interval '30 minutes'
    returning paciente_id, id, tramite_id
  loop
    perform core.registrar_evento(r.paciente_id, r.tramite_id, r.id, 'interaccion_finalizada',
                                  jsonb_build_object('resultado', 'inactiva'));
    n := n + 1;
  end loop;
  return n;
end
$$;

-- ---------------------------------------------------------------------
-- Métricas por clínica: vistas materializadas (últimos 90 días),
-- refrescadas cada 5 minutos sin bloquear lecturas (CONCURRENTLY)
-- ---------------------------------------------------------------------
create materialized view core.mv_embudo_diario as
select (t.creado_en at time zone 'America/Mexico_City')::date as dia,
       t.clinica_id, t.tipo, t.paso_actual, t.estado, t.canal_origen, t.ultimo_canal,
       count(*)::int as tramites
from core.tramites t
where t.eliminado_en is null and t.creado_en >= now() - interval '90 days'
group by 1, 2, 3, 4, 5, 6, 7;
create unique index on core.mv_embudo_diario (dia, clinica_id, tipo, paso_actual, estado, canal_origen, ultimo_canal) nulls not distinct;

create materialized view core.mv_transiciones_canal_diario as
select (ev.ocurrido_en at time zone 'America/Mexico_City')::date as dia,
       ev.payload ->> 'de' as canal_desde, ev.payload ->> 'a' as canal_hacia,
       ev.payload ->> 'paso_actual' as paso,
       count(*)::int as transiciones
from core.eventos_tramite ev
where ev.tipo_evento = 'canal_cambiado' and ev.ocurrido_en >= now() - interval '90 days'
group by 1, 2, 3, 4;
create unique index on core.mv_transiciones_canal_diario (dia, canal_desde, canal_hacia, paso) nulls not distinct;

create or replace function core.refrescar_metricas()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  refresh materialized view concurrently core.mv_embudo_diario;
  refresh materialized view concurrently core.mv_transiciones_canal_diario;
end
$$;

create or replace function api.metricas(p_desde date, p_hasta date, p_clinica_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform core.exigir_rol('supervisor', 'admin');
  if p_clinica_id is not null then perform core.validar_alcance_clinica(p_clinica_id); end if;

  return jsonb_build_object(
    'embudo', (select coalesce(jsonb_agg(jsonb_build_object('paso', paso_actual, 'estado', estado, 'tramites', n)), '[]')
               from (select paso_actual, estado, sum(tramites)::int as n from core.mv_embudo_diario
                     where dia between p_desde and p_hasta and (p_clinica_id is null or clinica_id = p_clinica_id)
                     group by 1, 2) s),
    'por_canal_origen', (select coalesce(jsonb_object_agg(canal_origen, n), '{}')
               from (select canal_origen, sum(tramites)::int as n from core.mv_embudo_diario
                     where dia between p_desde and p_hasta and (p_clinica_id is null or clinica_id = p_clinica_id)
                     group by 1) s),
    'transiciones_de_canal', (select coalesce(jsonb_agg(jsonb_build_object('de', canal_desde, 'a', canal_hacia, 'total', n)), '[]')
               from (select canal_desde, canal_hacia, sum(transiciones)::int as n from core.mv_transiciones_canal_diario
                     where dia between p_desde and p_hasta group by 1, 2) s));
end
$$;
