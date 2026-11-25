-- Acciones sobre citas ya hechas: atendida (recepción), cancelar y reprogramar (paciente, por cualquier
-- canal), y pedir un agente humano. Todo deja evento, así que la web, WhatsApp y el personal lo ven.

insert into core.catalogo_eventos (tipo_evento, categoria, descripcion, dispara_resumen) values
  ('cita_atendida',      'cita',     'La clínica terminó de atender el estudio', true),
  ('cita_reprogramada',  'cita',     'La cita cambió de fecha u hora', true),
  ('agente_solicitado',  'interaccion', 'El paciente pidió hablar con una persona', true);

-- ---------------------------------------------------------------------
-- Recepción: la cita que estaba en la clínica ya fue atendida
-- ---------------------------------------------------------------------
create or replace function api.marcar_atendida(p_cita_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cita core.citas;
begin
  perform core.exigir_rol('recepcion', 'supervisor', 'admin');
  perform core.establecer_actor('clinica');
  select * into v_cita from core.citas where id = p_cita_id and eliminado_en is null for update;
  if not found then
    raise exception 'Cita no encontrada' using errcode = 'PT404';
  end if;
  perform core.validar_alcance_clinica(v_cita.clinica_id);
  if v_cita.estado = 'atendida' then
    raise exception 'La cita ya estaba atendida' using errcode = 'P0001';
  end if;
  if v_cita.estado <> 'en_clinica' then
    raise exception 'La cita está %: primero se registra la llegada', v_cita.estado using errcode = '22023';
  end if;

  update core.citas set estado = 'atendida' where paciente_id = v_cita.paciente_id and id = v_cita.id;
  perform core.registrar_evento(v_cita.paciente_id, v_cita.tramite_id, null, 'cita_atendida',
    jsonb_build_object('cita_id', v_cita.id, 'beneficiario_id', v_cita.beneficiario_id, 'turno', v_cita.turno));
  return jsonb_build_object('cita_id', v_cita.id, 'estado', 'atendida');
end
$$;
revoke execute on function api.marcar_atendida(uuid) from public, anon;
grant execute on function api.marcar_atendida(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Paciente: cancelar una cita (si ya pagó, el pago queda marcado como reembolsado)
-- ---------------------------------------------------------------------
create or replace function api.cancelar_cita(p_interaccion_id uuid, p_cita_id uuid, p_motivo text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int     core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_cita    core.citas;
  v_pagado  boolean := false;
  v_tramite core.tramites;
begin
  select * into v_cita from core.citas
  where id = p_cita_id and paciente_id = v_int.paciente_id and eliminado_en is null for update;
  if not found then
    raise exception 'Cita no encontrada' using errcode = 'PT404';
  end if;
  if v_cita.estado not in ('reservada', 'confirmada') then
    raise exception 'La cita está %', v_cita.estado using errcode = '22023';
  end if;
  if v_cita.fecha_hora <= now() then
    raise exception 'La cita ya pasó' using errcode = '22023';
  end if;

  update core.citas set estado = 'cancelada' where paciente_id = v_cita.paciente_id and id = v_cita.id;

  update core.pagos set estado = 'reembolsado'
  where paciente_id = v_cita.paciente_id and cita_id = v_cita.id and estado = 'pagado';
  v_pagado := found;
  update core.pagos set estado = 'expirado'
  where paciente_id = v_cita.paciente_id and cita_id = v_cita.id and estado = 'pendiente';

  perform core.registrar_evento(v_cita.paciente_id, v_cita.tramite_id, v_int.id, 'cita_cancelada',
    jsonb_build_object('cita_id', v_cita.id, 'motivo', coalesce(nullif(btrim(p_motivo), ''), 'solicitud_del_paciente'),
                       'reembolso', v_pagado));

  -- El trámite que seguía abierto se cancela; uno ya completado se queda como historial
  update core.tramites set estado = 'cancelado', version = version + 1, ultimo_canal = v_int.canal,
                           ultima_actividad_en = now()
  where paciente_id = v_cita.paciente_id and id = v_cita.tramite_id and estado in ('activo', 'pausado')
  returning * into v_tramite;
  if found then
    perform core.registrar_evento(v_cita.paciente_id, v_tramite.id, v_int.id, 'tramite_cancelado',
                                  jsonb_build_object('motivo', 'cita_cancelada'));
  end if;

  return jsonb_build_object('cita_id', v_cita.id, 'estado', 'cancelada', 'reembolso', v_pagado,
                            'folio', (select folio from core.tramites where paciente_id = v_cita.paciente_id and id = v_cita.tramite_id));
end
$$;
revoke execute on function api.cancelar_cita(uuid, uuid, text) from public, anon;
grant execute on function api.cancelar_cita(uuid, uuid, text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Paciente: cambiar la fecha u hora (misma clínica y estudio, con cupo y en horario de atención)
-- ---------------------------------------------------------------------
create or replace function api.reprogramar_cita(p_interaccion_id uuid, p_cita_id uuid, p_fecha_hora timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int      core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_cita     core.citas;
  v_ce       core.clinica_estudios;
  v_ocupados int;
  v_antes    timestamptz;
begin
  select * into v_cita from core.citas
  where id = p_cita_id and paciente_id = v_int.paciente_id and eliminado_en is null for update;
  if not found then
    raise exception 'Cita no encontrada' using errcode = 'PT404';
  end if;
  if v_cita.estado not in ('reservada', 'confirmada') then
    raise exception 'La cita está %', v_cita.estado using errcode = '22023';
  end if;
  if v_cita.fecha_hora <= now() then
    raise exception 'La cita ya pasó' using errcode = '22023';
  end if;
  if p_fecha_hora <= now() + interval '1 hour' then
    raise exception 'El horario debe ser al menos una hora en el futuro' using errcode = '22023';
  end if;
  if p_fecha_hora = v_cita.fecha_hora then
    raise exception 'Elige un horario distinto al actual' using errcode = '22023';
  end if;

  select * into v_ce from core.clinica_estudios
  where clinica_id = v_cita.clinica_id and estudio_id = v_cita.estudio_id and activo and eliminado_en is null;
  if not found then
    raise exception 'La clínica ya no ofrece ese estudio' using errcode = '22023';
  end if;
  if not core.en_horario_atencion(v_cita.clinica_id, p_fecha_hora) then
    raise exception 'horario_fuera_de_atencion' using errcode = '22023',
      hint = 'Elige un horario de api.horarios_disponibles';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_cita.clinica_id::text || v_cita.estudio_id::text || p_fecha_hora::text, 0));
  select count(*) into v_ocupados from core.agenda_clinica
  where clinica_id = v_cita.clinica_id and estudio_id = v_cita.estudio_id and fecha_hora = p_fecha_hora
    and estado in ('reservada', 'confirmada', 'en_clinica', 'atendida');
  if v_ocupados >= v_ce.capacidad_por_horario then
    raise sqlstate 'PT409' using message = 'horario_sin_cupo', hint = 'Elige otro horario';
  end if;

  v_antes := v_cita.fecha_hora;
  update core.citas set fecha_hora = p_fecha_hora where paciente_id = v_cita.paciente_id and id = v_cita.id;
  update core.tramites
  set contexto = contexto || jsonb_build_object('fecha_hora', p_fecha_hora), version = version + 1,
      ultimo_canal = v_int.canal, ultima_actividad_en = now()
  where paciente_id = v_cita.paciente_id and id = v_cita.tramite_id;

  perform core.registrar_evento(v_cita.paciente_id, v_cita.tramite_id, v_int.id, 'cita_reprogramada',
    jsonb_build_object('cita_id', v_cita.id, 'de', v_antes, 'a', p_fecha_hora));
  return jsonb_build_object('cita_id', v_cita.id, 'estado', v_cita.estado, 'fecha_hora', p_fecha_hora,
                            'folio', (select folio from core.tramites where paciente_id = v_cita.paciente_id and id = v_cita.tramite_id));
end
$$;
revoke execute on function api.reprogramar_cita(uuid, uuid, timestamptz) from public, anon;
grant execute on function api.reprogramar_cita(uuid, uuid, timestamptz) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Pedir un agente humano, y la lista de quienes lo esperan
-- ---------------------------------------------------------------------
create or replace function api.solicitar_agente(p_interaccion_id uuid, p_motivo text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int core.interacciones := core.cargar_interaccion(p_interaccion_id);
begin
  perform core.registrar_evento(v_int.paciente_id, v_int.tramite_id, v_int.id, 'agente_solicitado',
    jsonb_build_object('motivo', left(coalesce(nullif(btrim(p_motivo), ''), 'sin_motivo'), 300)));
  return jsonb_build_object('solicitado', true,
    'mensaje', 'Avisamos al equipo: una persona te contactará por este mismo medio.');
end
$$;
revoke execute on function api.solicitar_agente(uuid, text) from public, anon;
grant execute on function api.solicitar_agente(uuid, text) to authenticated, service_role;

-- Solicitudes de las últimas 12 horas que nadie ha empezado a atender
create or replace function api.solicitudes_agente(p_limite int default 30)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform core.exigir_rol('asesor', 'supervisor', 'admin');
  perform core.establecer_actor('panel');
  return (
    select coalesce(jsonb_agg(x order by x ->> 'momento'), '[]') from (
      select jsonb_build_object(
        'paciente_id', ev.paciente_id,
        'paciente', core.nombre_para_mostrar(ev.paciente_id, false),
        'canal', ev.canal, 'momento', ev.ocurrido_en, 'motivo', ev.payload ->> 'motivo',
        'tramite_id', ev.tramite_id,
        'folio', (select t.folio from core.tramites t where t.paciente_id = ev.paciente_id and t.id = ev.tramite_id)) as x
      from core.eventos_tramite ev
      where ev.tipo_evento = 'agente_solicitado' and ev.ocurrido_en > now() - interval '12 hours'
        and not exists (select 1 from core.eventos_tramite a
                        where a.paciente_id = ev.paciente_id and a.tipo_evento = 'atencion_iniciada'
                          and a.ocurrido_en > ev.ocurrido_en)
      order by ev.ocurrido_en
      limit least(greatest(coalesce(p_limite, 30), 1), 100)) s);
end
$$;
revoke execute on function api.solicitudes_agente(int) from public, anon;
grant execute on function api.solicitudes_agente(int) to authenticated;
