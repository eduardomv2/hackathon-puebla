-- =====================================================================
-- Omnicanal en tiempo real (2/2): avisos proactivos por WhatsApp
--   · Solo a teléfonos VERIFICADOS que aceptaron recibir avisos
--     (core.consentimientos_avisos, con fecha y canal).
--   · Ventana de 24 h de WhatsApp: si la paciente escribió por WhatsApp en
--     las últimas 24 h se manda texto libre; si no, solo plantillas
--     (simuladas como aprobadas; TODO conectarlas a Meta).
--   · Cada evento de un trámite ocurrido FUERA de WhatsApp entra a la cola
--     avisos_whatsapp; la Edge Function avisos-whatsapp la vacía (pg_cron
--     cada 5 s). Los eventos de WhatsApp no se avisan a WhatsApp.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Consentimiento
-- ---------------------------------------------------------------------
create or replace function api.registrar_consentimiento_avisos(p_interaccion_id uuid, p_acepta boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_tel text;
begin
  if v_int.nivel_verificacion <> 'verificada' then
    raise exception 'Verifica tu celular antes de aceptar avisos' using errcode = '42501';
  end if;
  select valor into v_tel from core.identidades_paciente
  where paciente_id = v_int.paciente_id and tipo = 'telefono' and nivel_confianza = 'verificada' and eliminado_en is null
  order by verificada_en desc nulls last limit 1;
  if v_tel is null then
    raise exception 'No hay un teléfono verificado' using errcode = '22023';
  end if;
  insert into core.consentimientos_avisos (paciente_id, telefono, acepta, canal, actor_id)
  values (v_int.paciente_id, v_tel, coalesce(p_acepta, false), v_int.canal, core.actor_id());
  perform core.registrar_evento(v_int.paciente_id, null, v_int.id, 'consentimiento_avisos',
    jsonb_build_object('acepta', coalesce(p_acepta, false), 'telefono', core.enmascarar_telefono(v_tel)));
  return jsonb_build_object('acepta', coalesce(p_acepta, false), 'telefono', core.enmascarar_telefono(v_tel),
                            'registrado_en', now());
end
$$;

-- ---------------------------------------------------------------------
-- Plantillas de WhatsApp (simuladas como aprobadas)
-- TODO(Meta): registrar cada plantilla en WhatsApp Manager, guardar su id en
-- meta_template_id y enviarlas con type=template desde la Edge Function.
-- ---------------------------------------------------------------------
create table core.plantillas_whatsapp (
  nombre            text primary key,
  categoria         text not null check (categoria in ('utility', 'marketing', 'authentication')),
  idioma            text not null default 'es_MX',
  texto             text not null,          -- con variables {{nombre}}
  variables         text[] not null,
  estado            text not null default 'aprobada_simulada' check (estado in ('aprobada_simulada', 'aprobada', 'rechazada')),
  meta_template_id  text,
  creado_en         timestamptz not null default now(),
  creado_por        uuid,
  actualizado_en    timestamptz not null default now(),
  actualizado_por   uuid,
  eliminado_en      timestamptz,
  eliminado_por     uuid
);
select core.habilitar_auditoria('core.plantillas_whatsapp');
alter table core.plantillas_whatsapp enable row level security;
revoke all on core.plantillas_whatsapp from public, anon, authenticated, service_role;

insert into core.plantillas_whatsapp (nombre, categoria, texto, variables) values
  ('recordatorio_tramite_pendiente', 'utility',
   'Hola, tienes pendiente tu trámite {{etiqueta}} (folio {{folio}}): {{paso}}. Responde a este mensaje para continuar.',
   '{etiqueta,folio,paso}'),
  ('link_pago', 'utility',
   'Tu cita de {{etiqueta}} (folio {{folio}}) está apartada para el {{fecha}}. Paga aquí para confirmarla: {{link}}',
   '{etiqueta,folio,fecha,link}'),
  ('cita_confirmada', 'utility',
   'Tu cita de {{etiqueta}} quedó confirmada para el {{fecha}} en {{clinica}}. Folio {{folio}}.',
   '{etiqueta,folio,fecha,clinica}'),
  ('asesor_atendiendo', 'utility',
   'Un asesor está atendiendo tu trámite {{etiqueta}} (folio {{folio}}) por teléfono; al terminar puedes seguir aquí.',
   '{etiqueta,folio}');

create or replace function core.render_plantilla(p_nombre text, p_variables jsonb)
returns text
language plpgsql stable
set search_path = ''
as $$
declare
  v_texto text;
  r record;
begin
  select texto into v_texto from core.plantillas_whatsapp where nombre = p_nombre and eliminado_en is null;
  if v_texto is null then
    raise exception 'Plantilla de WhatsApp desconocida: %', p_nombre using errcode = 'PT404';
  end if;
  for r in select key, value from jsonb_each_text(p_variables) loop
    v_texto := replace(v_texto, '{{' || r.key || '}}', coalesce(r.value, ''));
  end loop;
  return v_texto;
end
$$;

-- La paciente escribió por WhatsApp en las últimas 24 h (ventana de servicio de Meta)
create or replace function core.ventana_whatsapp_abierta(p_paciente_id uuid)
returns boolean
language sql stable
set search_path = ''
as $$
  select exists (select 1 from core.mensajes
                 where paciente_id = p_paciente_id and canal = 'whatsapp' and direccion = 'entrante'
                   and creado_en > now() - interval '24 hours')
$$;

-- Plantilla asesor_atendiendo para un trámite (la usa el bot al recibir PT423)
create or replace function api.texto_asesor_atendiendo(p_interaccion_id uuid, p_tramite_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int core.interacciones := core.cargar_interaccion(p_interaccion_id);
  t     core.tramites;
begin
  perform core.exigir_rol('servicio');
  select * into t from core.tramites where paciente_id = v_int.paciente_id and id = p_tramite_id;
  if not found then
    raise exception 'Trámite no encontrado' using errcode = 'PT404';
  end if;
  return core.render_plantilla('asesor_atendiendo', jsonb_build_object('etiqueta', core.etiqueta_tramite(t), 'folio', t.folio));
end
$$;

-- ---------------------------------------------------------------------
-- Qué avisar de cada evento
--   plantilla: se manda también fuera de la ventana de 24 h
--   texto:     solo dentro de la ventana
-- ---------------------------------------------------------------------
create or replace function core.armar_aviso(ev core.eventos_tramite)
returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  t        core.tramites;
  v_et     text;
  v_canal  text := case ev.canal when 'web' then 'la web' when 'app' then 'la app' when 'call_center' then 'la llamada'
                                 when 'clinica' then 'la clínica' else null end;
  v_desde  text;
  v_fecha  text;
  v_zona   text;
  v_link   text;
  v_clin   text;
begin
  select * into t from core.tramites where paciente_id = ev.paciente_id and id = ev.tramite_id;
  if not found then return null; end if;
  v_et    := core.etiqueta_tramite(t);
  v_desde := case when v_canal is null then '' else 'Desde ' || v_canal || ': ' end;
  select c.zona_horaria, c.nombre into v_zona, v_clin from core.clinicas c where c.id = t.clinica_id;
  v_fecha := to_char((t.contexto ->> 'fecha_hora')::timestamptz at time zone coalesce(v_zona, 'America/Mexico_City'),
                     'DD/MM/YYYY "a las" HH24:MI');

  case ev.tipo_evento
    when 'pago_generado' then
      select link_pago into v_link from core.pagos where paciente_id = ev.paciente_id and id = (ev.payload ->> 'pago_id')::uuid;
      return jsonb_build_object('plantilla', 'link_pago', 'variables',
        jsonb_build_object('etiqueta', v_et, 'folio', t.folio, 'fecha', v_fecha, 'link', v_link));
    when 'cita_confirmada' then
      return jsonb_build_object('plantilla', 'cita_confirmada', 'variables',
        jsonb_build_object('etiqueta', v_et, 'folio', t.folio, 'fecha', v_fecha, 'clinica', v_clin));
    when 'atencion_iniciada' then
      return jsonb_build_object('plantilla', 'asesor_atendiendo', 'variables',
        jsonb_build_object('etiqueta', v_et, 'folio', t.folio));
    when 'recordatorio_programado' then
      return jsonb_build_object('plantilla', 'recordatorio_tramite_pendiente', 'variables',
        jsonb_build_object('etiqueta', v_et, 'folio', t.folio,
                           'paso', (select descripcion from core.flujo_tramite where tipo_tramite = t.tipo and paso = t.paso_actual)));
    when 'tramite_iniciado' then
      return jsonb_build_object('texto', v_desde || 'iniciaste el trámite ' || v_et || ' (folio ' || t.folio || ').');
    when 'paso_avanzado' then
      return jsonb_build_object('texto', v_desde || v_et || ' (folio ' || t.folio || ') ahora va en «' ||
        (select descripcion from core.flujo_tramite where tipo_tramite = t.tipo and paso = ev.payload ->> 'a') || '».');
    when 'cita_reservada' then
      return jsonb_build_object('texto', v_desde || 'se apartó tu cita de ' || v_et || ' para el ' || v_fecha || '.');
    when 'pago_fallido' then
      return jsonb_build_object('texto', 'El pago de ' || v_et || ' (folio ' || t.folio || ') fue rechazado. Puedes intentarlo de nuevo.');
    when 'tramite_cancelado' then
      return jsonb_build_object('texto', 'Se canceló tu trámite ' || v_et || ' (folio ' || t.folio || ').');
    when 'tramite_abandonado' then
      return jsonb_build_object('texto', 'Tu trámite ' || v_et || ' (folio ' || t.folio || ') venció por inactividad.');
    when 'atencion_liberada' then
      return jsonb_build_object('texto', 'El asesor terminó de atender ' || v_et || ' (folio ' || t.folio || '); puedes seguir por aquí.');
    else
      return null;
  end case;
end
$$;

-- ---------------------------------------------------------------------
-- Cola: cada evento avisable de un trámite, ocurrido fuera de WhatsApp,
-- para un paciente con teléfono verificado que aceptó avisos.
-- ---------------------------------------------------------------------
select pgmq.create('avisos_whatsapp');

create or replace function core.trg_encolar_aviso()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.tramite_id is not null and new.canal <> 'whatsapp'
     and new.tipo_evento in ('tramite_iniciado', 'paso_avanzado', 'cita_reservada', 'pago_generado', 'cita_confirmada',
                             'pago_fallido', 'tramite_cancelado', 'tramite_abandonado', 'atencion_iniciada',
                             'atencion_liberada', 'recordatorio_programado')
     and core.telefono_avisos(new.paciente_id) is not null then
    perform pgmq.send('avisos_whatsapp',
      jsonb_build_object('evento_id', new.id, 'paciente_id', new.paciente_id, 'ocurrido_en', new.ocurrido_en), 0);
  end if;
  return null;
end
$$;
create trigger trg_80_avisos after insert on core.eventos_tramite
  for each row execute function core.trg_encolar_aviso();

-- La Edge Function avisos-whatsapp llama esto por cada mensaje de la cola.
-- Revisa de nuevo consentimiento y ventana (pudieron cambiar), arma el texto,
-- lo registra como mensaje saliente (cifrado) y dice a qué teléfono enviarlo.
create or replace function api.procesar_aviso_whatsapp(p_evento_id uuid, p_paciente_id uuid, p_ocurrido_en timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  ev       core.eventos_tramite;
  v_tel    text;
  v_aviso  jsonb;
  v_texto  text;
  v_tipo   text;
  v_int    uuid;
  v_ver    smallint := core.version_cifrado_activa();
begin
  perform core.exigir_rol('servicio');
  select * into ev from core.eventos_tramite
  where paciente_id = p_paciente_id and ocurrido_en = p_ocurrido_en and id = p_evento_id;
  if not found then
    return jsonb_build_object('enviar', false, 'motivo', 'evento_no_encontrado');
  end if;
  v_tel := core.telefono_avisos(p_paciente_id);
  if v_tel is null then
    return jsonb_build_object('enviar', false, 'motivo', 'sin_consentimiento');
  end if;
  v_aviso := core.armar_aviso(ev);
  if v_aviso is null then
    return jsonb_build_object('enviar', false, 'motivo', 'evento_no_avisable');
  end if;

  if core.ventana_whatsapp_abierta(p_paciente_id) then
    -- Lo que pasó antes de que empezara la conversación ya lo resume "Tienes pendiente"
    if v_aviso ? 'texto' and ev.ocurrido_en < (
         select min(creado_en) from core.mensajes
         where paciente_id = p_paciente_id and canal = 'whatsapp' and direccion = 'entrante'
           and creado_en > now() - interval '24 hours') then
      return jsonb_build_object('enviar', false, 'motivo', 'anterior_a_la_conversacion');
    end if;
    v_tipo  := 'texto';
    v_texto := coalesce(v_aviso ->> 'texto', core.render_plantilla(v_aviso ->> 'plantilla', v_aviso -> 'variables'));
  elsif v_aviso ? 'plantilla' then
    v_tipo  := 'plantilla';
    v_texto := core.render_plantilla(v_aviso ->> 'plantilla', v_aviso -> 'variables');
  else
    return jsonb_build_object('enviar', false, 'motivo', 'fuera_de_ventana_sin_plantilla');
  end if;

  -- Queda en la conversación de WhatsApp del paciente (y se anuncia en tiempo real)
  perform core.establecer_actor('whatsapp', 'sistema');
  v_int := core.abrir_interaccion(p_paciente_id, 'whatsapp', 'ia', 'canal');
  insert into core.mensajes (paciente_id, interaccion_id, canal, direccion, autor, contenido_cifrado, clave_version, metadatos)
  values (p_paciente_id, v_int, 'whatsapp', 'saliente', 'sistema', core.cifrar(v_texto, v_ver), v_ver,
          jsonb_build_object('aviso_de', ev.tipo_evento, 'evento_id', ev.id, 'tipo', v_tipo,
                             'plantilla', v_aviso ->> 'plantilla'));

  return jsonb_build_object('enviar', true, 'telefono', v_tel, 'tipo', v_tipo,
                            'plantilla', v_aviso ->> 'plantilla', 'texto', v_texto);
end
$$;

-- Los workers pueden leer y confirmar también la cola de avisos
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
  if p_cola not in ('resumen_tramite', 'recordatorios', 'avisos_whatsapp') then
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
  if p_cola not in ('resumen_tramite', 'recordatorios', 'avisos_whatsapp') then
    raise exception 'Cola desconocida: %', p_cola using errcode = '22023';
  end if;
  return pgmq.delete(p_cola, p_msg_id);
end
$$;

-- pg_cron: cada 5 s invoca la Edge Function si hay avisos en cola
select cron.schedule('sd-avisos-whatsapp', '5 seconds', $$select core.despachar_worker('avisos_whatsapp', 'avisos-whatsapp')$$);

-- ---------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------
revoke execute on function core.render_plantilla(text, jsonb), core.ventana_whatsapp_abierta(uuid),
  core.armar_aviso(core.eventos_tramite), core.trg_encolar_aviso()
from public, anon, authenticated, service_role;

revoke execute on function api.registrar_consentimiento_avisos(uuid, boolean), api.procesar_aviso_whatsapp(uuid, uuid, timestamptz),
  api.texto_asesor_atendiendo(uuid, uuid) from public, anon;
grant execute on function api.registrar_consentimiento_avisos(uuid, boolean) to authenticated, service_role;
grant execute on function api.procesar_aviso_whatsapp(uuid, uuid, timestamptz), api.texto_asesor_atendiendo(uuid, uuid) to service_role;
