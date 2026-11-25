-- =====================================================================
-- Recepción de clínica (canal 'clinica')
--   · Rol de personal 'recepcion' con clínica obligatoria: solo opera en su clínica y solo
--     por el canal 'clinica' (mostrador).
--   · Mostrador: iniciar_contacto('clinica', tel, 'humano') → "Verificar INE":
--     api.verificar_presencial(p_interaccion_id, p_tipo_documento) sube ESA sesión a 'verificada'
--     (metodo 'identificacion') y guarda solo el tipo de documento. Con la sesión verificada usa
--     las mismas funciones del asesor (iniciar, agendar, cambiar horario con reservar_cita, pagar).
--     En mostrador se puede agendar para hoy desde el horario en curso (sin la hora de anticipación).
--   · Llegada: api.registrar_llegada(cita, documento, ¿cumplió preparación?) verifica la INE de
--     quien recibe el estudio, pasa la cita a 'en_clinica' (llegada_en), da turno por área y día
--     (A-001, U-003…) y registra llegada_registrada; responde a dónde dirigirlo (caja o área).
--   · "El personal manda": lo que recepción atiende queda bloqueado para otros canales (PT423),
--     con textos que ya no dicen "por teléfono" cuando es en la clínica.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Rol recepcion
-- ---------------------------------------------------------------------
alter table core.staff drop constraint staff_rol_check;
alter table core.staff add constraint staff_rol_check check (rol in ('asesor', 'supervisor', 'admin', 'recepcion'));
alter table core.staff add constraint staff_recepcion_con_clinica check (rol <> 'recepcion' or clinica_id is not null);

alter table core.eventos_tramite drop constraint eventos_tramite_actor_tipo_check;
alter table core.eventos_tramite add constraint eventos_tramite_actor_tipo_check
  check (actor_tipo in ('paciente', 'asesor', 'supervisor', 'admin', 'recepcion', 'agente_ia', 'sistema'));

create or replace function core.rol_actual()
returns text
language sql stable
set search_path = ''
as $$
  select case
    when auth.role() = 'service_role' then 'servicio'
    when auth.jwt() -> 'app_metadata' ->> 'rol' in ('asesor', 'supervisor', 'admin', 'recepcion')
      then auth.jwt() -> 'app_metadata' ->> 'rol'
    when auth.role() = 'authenticated' then 'paciente'
    else 'anonimo'
  end
$$;

create or replace function core.establecer_actor(p_canal text, p_actor_tipo text default null)
returns void
language plpgsql volatile
set search_path = ''
as $$
declare
  v_rol   text := core.rol_actual();
  v_actor text;
begin
  if p_canal is null or p_canal not in ('web', 'app', 'whatsapp', 'call_center', 'clinica', 'panel', 'sistema') then
    raise exception 'Canal inválido: %', p_canal using errcode = '22023';
  end if;

  case v_rol
    when 'paciente' then
      if p_canal not in ('web', 'app') then
        raise exception 'Un paciente solo opera por web o app' using errcode = '42501';
      end if;
      v_actor := 'paciente';
    when 'asesor', 'supervisor' then
      if p_canal not in ('call_center', 'clinica', 'panel') then
        raise exception 'El personal opera por call center, clínica o panel' using errcode = '42501';
      end if;
      v_actor := v_rol;
    when 'recepcion' then
      if p_canal <> 'clinica' then
        raise exception 'Recepción solo opera en la clínica' using errcode = '42501';
      end if;
      v_actor := 'recepcion';
    when 'admin' then
      v_actor := 'admin';
    when 'servicio' then
      v_actor := coalesce(p_actor_tipo, 'sistema');
      if v_actor not in ('paciente', 'agente_ia', 'asesor', 'sistema') then
        raise exception 'Actor inválido: %', v_actor using errcode = '22023';
      end if;
    else
      raise exception 'Acceso denegado' using errcode = '42501';
  end case;

  perform set_config('app.canal', p_canal, true);
  perform set_config('app.actor_tipo', v_actor, true);
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
end
$$;

-- Recepción siempre tiene clínica: sin ella en el JWT no opera nada
create or replace function core.validar_alcance_clinica(p_clinica_id uuid)
returns void
language plpgsql stable
set search_path = ''
as $$
declare
  v_clinica uuid := nullif(auth.jwt() -> 'app_metadata' ->> 'clinica_id', '')::uuid;
  v_rol     text := core.rol_actual();
begin
  if v_rol = 'recepcion' and v_clinica is null then
    raise exception 'Recepción sin clínica asignada' using errcode = '42501';
  end if;
  if v_rol <> 'admin' and v_clinica is not null and v_clinica is distinct from p_clinica_id then
    raise exception 'Fuera del alcance de tu clínica' using errcode = '42501';
  end if;
end
$$;

CREATE OR REPLACE FUNCTION core.cargar_interaccion(p_interaccion_id uuid)
 RETURNS core.interacciones
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v     core.interacciones;
  v_rol text := core.rol_actual();
  v_actor text;
begin
  select * into v from core.interacciones where id = p_interaccion_id for update;
  if not found then
    raise exception 'Interacción no encontrada' using errcode = 'PT404';
  end if;
  if v.finalizada_en is not null then
    raise exception 'La interacción ya fue cerrada' using errcode = 'P0001';
  end if;

  case v_rol
    when 'paciente' then
      if v.paciente_id is distinct from core.mi_paciente_id() then
        raise exception 'Interacción no encontrada' using errcode = 'PT404';
      end if;
      v_actor := 'paciente';
    when 'asesor', 'supervisor', 'recepcion' then
      if v.staff_id is distinct from auth.uid() then
        raise exception 'La interacción pertenece a otro asesor' using errcode = '42501';
      end if;
      v_actor := v_rol;
    when 'admin' then
      v_actor := 'admin';
    when 'servicio' then
      v_actor := case v.agente when 'ia' then 'agente_ia' when 'humano' then 'asesor' else 'paciente' end;
    else
      raise exception 'Acceso denegado' using errcode = '42501';
  end case;

  perform set_config('app.canal', v.canal, true);
  perform set_config('app.actor_tipo', v_actor, true);
  perform set_config('app.actor_id', coalesce(auth.uid()::text, v.staff_id::text, ''), true);

  update core.interacciones set ultima_actividad_en = now()
  where paciente_id = v.paciente_id and id = v.id;
  return v;
end
$function$
;

create or replace function core.puede_escuchar_paciente(p_topic text)
returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select core.rol_actual() in ('asesor', 'supervisor', 'admin', 'recepcion')
     and exists (select 1 from core.interacciones i
                 where i.staff_id = auth.uid() and i.finalizada_en is null
                   and 'paciente:' || i.paciente_id::text = p_topic)
$$;

create or replace function api.iniciar_contacto(
  p_canal text, p_telefono text, p_agente text, p_nivel text default 'declarada')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rol      text := core.exigir_rol('servicio', 'asesor', 'supervisor', 'admin', 'recepcion');
  v_valor    text := core.normalizar_identidad('telefono', p_telefono);
  v_nivel    text := p_nivel;
  v_staff    uuid;
  v_paciente uuid;
  v_int      uuid;
begin
  if p_canal not in ('whatsapp', 'call_center', 'clinica') then
    raise exception 'Canal inválido para contacto: %', p_canal using errcode = '22023';
  end if;
  if p_agente not in ('ia', 'humano') then
    raise exception 'Agente inválido: %', p_agente using errcode = '22023';
  end if;
  if v_nivel not in ('declarada', 'canal') then
    raise exception 'El nivel inicial solo puede ser declarada o canal' using errcode = '22023';
  end if;
  -- Solo el servicio de WhatsApp puede afirmar posesión del número
  if v_rol <> 'servicio' then
    v_nivel := 'declarada';
    v_staff := auth.uid();
  end if;

  perform core.establecer_actor(p_canal, case when p_agente = 'ia' then 'agente_ia' else 'asesor' end);
  perform pg_advisory_xact_lock(hashtextextended('telefono:' || v_valor, 0));

  select paciente_id into v_paciente from core.identidades_paciente
  where tipo = 'telefono' and valor = v_valor and eliminado_en is null;
  if v_paciente is null then
    insert into core.pacientes (estado) values ('identificado') returning id into v_paciente;
    perform core.registrar_evento(v_paciente, null, null, 'paciente_creado', jsonb_build_object('canal', p_canal));
  end if;
  v_paciente := core.vincular_identidad(v_paciente, 'telefono', v_valor, v_nivel, p_canal);

  v_int := core.abrir_interaccion(v_paciente, p_canal, p_agente, v_nivel, v_staff);
  return core.contexto_json(core.cargar_interaccion(v_int));
end
$$;

create or replace function api.obtener_contexto(p_interaccion_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_ctx jsonb := core.contexto_json(v_int);
begin
  -- Toda lectura del personal queda en la bitácora y en la línea de tiempo
  if core.rol_actual() in ('asesor', 'supervisor', 'admin', 'recepcion') and v_int.nivel_verificacion <> 'declarada' then
    perform audit.registrar_lectura('core.contexto', v_int.paciente_id::text, v_int.paciente_id,
                                    jsonb_build_object('interaccion_id', v_int.id));
    perform core.registrar_evento(v_int.paciente_id, v_int.tramite_id, v_int.id, 'asesor_consulto_contexto', '{}');
  end if;
  return v_ctx;
end
$$;

create or replace function api.mis_beneficiarios(p_interaccion_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int  core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_completo boolean := v_int.nivel_verificacion = 'verificada';
begin
  if v_int.nivel_verificacion = 'declarada' then
    raise exception 'Verifica la identidad para ver a tus beneficiarios' using errcode = '42501';
  end if;
  if v_completo and core.rol_actual() in ('asesor', 'supervisor', 'admin', 'recepcion') then
    perform audit.registrar_lectura('core.relaciones_paciente', v_int.paciente_id::text, v_int.paciente_id,
                                    jsonb_build_object('interaccion_id', v_int.id));
  end if;

  return (
    select coalesce(jsonb_agg(
             jsonb_build_object('id', p.id, 'nombre', p.nombre, 'relacion', r.relacion)
             || case when v_completo then jsonb_build_object(
                  'nombre_completo', concat_ws(' ', p.nombre, p.apellido_paterno, p.apellido_materno),
                  'fecha_nacimiento', p.fecha_nacimiento,
                  'es_tutor_legal', r.es_tutor_legal)
                else '{}'::jsonb end
             order by r.creado_en), '[]')
    from core.relaciones_paciente r
    join core.pacientes p on p.id = r.beneficiario_id
    where r.titular_id = v_int.paciente_id and r.eliminado_en is null);
end
$$;

create or replace function api.buscar_conocimiento(
  p_consulta text, p_embedding extensions.vector(1536), p_limite int default 5, p_categoria text default null)
returns table (fragmento_id uuid, documento_id uuid, titulo text, categoria text, contenido text, puntaje double precision)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int := least(greatest(p_limite, 1), 20);
begin
  perform core.exigir_rol('servicio', 'asesor', 'supervisor', 'admin', 'recepcion', 'paciente');
  return query
  with semantico as (
    select f.id, row_number() over (order by f.embedding operator(extensions.<=>) p_embedding) as r
    from core.kb_fragmentos f
    join core.kb_documentos d on d.id = f.documento_id
    where d.vigente and d.eliminado_en is null and (p_categoria is null or d.categoria = p_categoria)
    order by f.embedding operator(extensions.<=>) p_embedding
    limit v_n * 4
  ),
  texto as (
    select f.id, row_number() over (order by ts_rank_cd(f.fts, q) desc) as r
    from core.kb_fragmentos f
    join core.kb_documentos d on d.id = f.documento_id,
         websearch_to_tsquery('spanish', coalesce(p_consulta, '')) q
    where f.fts @@ q and d.vigente and d.eliminado_en is null and (p_categoria is null or d.categoria = p_categoria)
    order by ts_rank_cd(f.fts, q) desc
    limit v_n * 4
  ),
  fusion as (
    select coalesce(s.id, t.id) as id,
           coalesce(1.0 / (60 + s.r), 0) + coalesce(1.0 / (60 + t.r), 0) as puntaje
    from semantico s full join texto t on t.id = s.id
  )
  select f.id, f.documento_id, d.titulo, d.categoria, f.contenido, fu.puntaje::double precision
  from fusion fu
  join core.kb_fragmentos f on f.id = fu.id
  join core.kb_documentos d on d.id = f.documento_id
  order by fu.puntaje desc
  limit v_n;
end
$$;

-- Recepción solo agenda en su clínica (citas y trámites, venga de la función que venga)
create or replace function core.trg_alcance_recepcion()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if core.rol_actual() = 'recepcion' and new.clinica_id is not null
     and (tg_op = 'INSERT' or new.clinica_id is distinct from old.clinica_id) then
    perform core.validar_alcance_clinica(new.clinica_id);
  end if;
  return new;
end
$$;
-- (después de trg_20_derivados, que calcula tramites.clinica_id desde el contexto)
create trigger trg_25_alcance_recepcion before insert or update on core.citas
  for each row execute function core.trg_alcance_recepcion();
create trigger trg_25_alcance_recepcion before insert or update on core.tramites
  for each row execute function core.trg_alcance_recepcion();

-- ---------------------------------------------------------------------
-- 2. "El personal manda" también en la clínica
-- ---------------------------------------------------------------------
-- Canal desde el que el personal atiende el trámite ahora ('call_center' o 'clinica'); null si nadie
create or replace function core.canal_atencion(t core.tramites)
returns text
language sql stable
set search_path = ''
as $$
  select i.canal from core.interacciones i
  where i.paciente_id = t.paciente_id and i.id = t.atendido_por_interaccion and t.atencion_hasta > now()
$$;

create or replace function core.exigir_atencion(p_int core.interacciones, t core.tramites)
returns core.tramites
language plpgsql
set search_path = ''
as $$
declare
  v core.tramites := t;
begin
  if core.en_atencion_de_otro(t, p_int.id) then
    raise sqlstate 'PT423' using message = 'tramite_en_atencion',
      detail = jsonb_build_object('tramite_id', t.id, 'folio', t.folio, 'etiqueta', core.etiqueta_tramite(t),
                                  'atencion_hasta', t.atencion_hasta, 'canal', core.canal_atencion(t))::text,
      hint = 'El personal está atendiendo este trámite (por teléfono o en la clínica); se puede ver pero no cambiar';
  end if;

  if p_int.staff_id is not null then
    if t.atendido_por_interaccion is distinct from p_int.id or t.atencion_hasta <= now() then
      -- Toma nueva: suelta el trámite que esta misma interacción tuviera antes
      perform core.liberar_atencion_de(p_int.id, t.id);
      update core.tramites set atendido_por_interaccion = p_int.id, atencion_hasta = now() + interval '10 minutes'
      where paciente_id = t.paciente_id and id = t.id
      returning * into v;
      perform core.registrar_evento(t.paciente_id, t.id, p_int.id, 'atencion_iniciada',
                                    jsonb_build_object('folio', t.folio, 'hasta', v.atencion_hasta));
    else
      update core.tramites set atencion_hasta = now() + interval '10 minutes'
      where paciente_id = t.paciente_id and id = t.id
      returning * into v;
    end if;
  end if;
  return v;
end
$$;

create or replace function core.tramite_tarjeta(t core.tramites, p_interaccion_id uuid)
returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', t.id,
    'folio', t.folio,
    'etiqueta', core.etiqueta_tramite(t),
    'paso_actual', t.paso_actual,
    'paso_descripcion', (select descripcion from core.flujo_tramite where tipo_tramite = t.tipo and paso = t.paso_actual),
    'ultimo_canal', t.ultimo_canal,
    'ultima_actividad_en', t.ultima_actividad_en,
    'beneficiario', (select jsonb_build_object('id', b.id, 'nombre', b.nombre,
                                               'relacion', core.relacion_beneficiario(t.paciente_id, b.id))
                     from core.pacientes b
                     where b.id = coalesce(nullif(t.contexto ->> 'beneficiario_id', '')::uuid, t.paciente_id)),
    'en_atencion_de_otro', core.en_atencion_de_otro(t, p_interaccion_id),
    'atendido_por_mi', t.atendido_por_interaccion = p_interaccion_id and t.atencion_hasta > now(),
    -- Dónde lo atienden: call_center (asesor por teléfono) o clinica (recepción)
    'atencion_canal', case when core.en_atencion_de_otro(t, p_interaccion_id) then core.canal_atencion(t) end)
$$;

insert into core.plantillas_whatsapp (nombre, categoria, texto, variables) values
  ('recepcion_atendiendo', 'utility',
   'Te están atendiendo en la clínica tu trámite {{etiqueta}} (folio {{folio}}); al terminar puedes seguir aquí.',
   '{etiqueta,folio}');

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
  return core.render_plantilla(case when core.canal_atencion(t) = 'clinica' then 'recepcion_atendiendo' else 'asesor_atendiendo' end, jsonb_build_object('etiqueta', core.etiqueta_tramite(t), 'folio', t.folio));
end
$$;

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
      return jsonb_build_object('plantilla', case when ev.canal = 'clinica' then 'recepcion_atendiendo' else 'asesor_atendiendo' end,
        'variables',
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
-- 3. Áreas, turnos y llegada
-- ---------------------------------------------------------------------
alter table core.estudios add column area text not null default 'laboratorio'
  check (area in ('laboratorio', 'ultrasonido', 'rayos_x', 'mastografia'));
update core.estudios set area = case
    when nombre ilike 'ultrasonido%' or clave ilike 'US-%' then 'ultrasonido'
    when nombre ilike 'mastograf%' then 'mastografia'
    when nombre ilike 'rayos%' or nombre ilike 'radiograf%' then 'rayos_x'
    else 'laboratorio' end;

create or replace function core.nombre_area(p_area text)
returns text
language sql immutable
set search_path = ''
as $$
  select case p_area when 'laboratorio' then 'Laboratorio' when 'ultrasonido' then 'Ultrasonido'
                     when 'rayos_x' then 'Rayos X' when 'mastografia' then 'Mastografía' end
$$;

-- Letra del turno: A (análisis de laboratorio), U, R, M
create or replace function core.prefijo_turno(p_area text)
returns text
language sql immutable
set search_path = ''
as $$
  select case p_area when 'laboratorio' then 'A' when 'ultrasonido' then 'U'
                     when 'rayos_x' then 'R' when 'mastografia' then 'M' end
$$;

-- Contador de turnos por clínica, área y día (local de la clínica)
create table core.turnos_dia (
  clinica_id  uuid not null references core.clinicas (id),
  area        text not null,
  fecha       date not null,
  ultimo      int not null default 0,
  primary key (clinica_id, area, fecha)
);
alter table core.turnos_dia enable row level security;
revoke all on core.turnos_dia from public, anon, authenticated, service_role;

create or replace function core.siguiente_turno(p_clinica_id uuid, p_area text, p_fecha date)
returns text
language sql
set search_path = ''
as $$
  insert into core.turnos_dia as t (clinica_id, area, fecha, ultimo) values (p_clinica_id, p_area, p_fecha, 1)
  on conflict (clinica_id, area, fecha) do update set ultimo = t.ultimo + 1
  returning core.prefijo_turno(p_area) || '-' || lpad(ultimo::text, 3, '0')
$$;

alter table core.citas drop constraint citas_estado_check;
alter table core.citas add constraint citas_estado_check
  check (estado in ('reservada', 'confirmada', 'en_clinica', 'cancelada', 'atendida', 'no_asistio'));
alter table core.citas
  add column llegada_en timestamptz,
  add column turno text;

-- El cupo cuenta también a quien ya está en la clínica
drop index core.agenda_clinica_clinica_id_estudio_id_fecha_hora_idx;
create index agenda_clinica_cupo_idx on core.agenda_clinica (clinica_id, estudio_id, fecha_hora)
  where estado in ('reservada', 'confirmada', 'en_clinica', 'atendida');

insert into core.catalogo_eventos (tipo_evento, categoria, descripcion, dispara_resumen) values
  ('llegada_registrada', 'cita', 'Llegó a la clínica: INE de quien recibe el estudio, turno y preparación', true);

create or replace function core.verificar_duplicado(p_titular uuid, p_tramite_id uuid, p_estudio_id uuid, p_beneficiario_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  t core.tramites;
  c core.citas;
begin
  if p_estudio_id is null then
    return;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('duplicado:' || p_titular::text, 0));

  select * into t from core.tramites
  where paciente_id = p_titular and id <> p_tramite_id and estado in ('activo', 'pausado') and eliminado_en is null
    and contexto ->> 'estudio_id' = p_estudio_id::text
    and coalesce(nullif(contexto ->> 'beneficiario_id', '')::uuid, paciente_id) = p_beneficiario_id
  order by ultima_actividad_en desc limit 1;
  if found then
    raise sqlstate 'PT409' using message = 'tramite_duplicado',
      detail = jsonb_build_object('tramite_id', t.id, 'folio', t.folio, 'etiqueta', core.etiqueta_tramite(t))::text,
      hint = 'Ya hay un trámite abierto de ese estudio para esa persona: continúa ese';
  end if;

  select * into c from core.citas
  where beneficiario_id = p_beneficiario_id and estudio_id = p_estudio_id
    and (estado in ('reservada', 'confirmada') and fecha_hora > now() or estado = 'en_clinica') and eliminado_en is null
    and tramite_id is distinct from p_tramite_id
  order by fecha_hora limit 1;
  if found then
    select * into t from core.tramites where paciente_id = c.paciente_id and id = c.tramite_id;
    raise sqlstate 'PT409' using message = 'cita_duplicada',
      detail = jsonb_build_object('cita_id', c.id, 'fecha_hora', c.fecha_hora, 'tramite_id', t.id,
                                  'folio', t.folio, 'etiqueta', core.etiqueta_tramite(t))::text,
      hint = 'Esa persona ya tiene una cita futura de ese estudio';
  end if;
end
$$;

CREATE OR REPLACE FUNCTION api.confirmar_pago(p_referencia text, p_estado text, p_datos jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_pago core.pagos;
  v_cita core.citas;
  v_tramite core.tramites;
begin
  perform core.exigir_rol('servicio');
  perform core.establecer_actor('sistema', 'sistema');
  if p_estado not in ('pagado', 'fallido') then
    raise exception 'Estado de pago inválido: %', p_estado using errcode = '22023';
  end if;

  select * into v_pago from core.pagos where referencia_externa = p_referencia for update;
  if not found then
    raise exception 'Pago no encontrado' using errcode = 'PT404';
  end if;
  if v_pago.estado = p_estado then
    return jsonb_build_object('pago_id', v_pago.id, 'estado', v_pago.estado, 'repetido', true);
  end if;
  if v_pago.estado <> 'pendiente' then
    raise exception 'El pago ya está %', v_pago.estado using errcode = 'P0001';
  end if;

  update core.pagos set estado = p_estado, pagado_en = case when p_estado = 'pagado' then now() end
  where paciente_id = v_pago.paciente_id and id = v_pago.id;
  select * into v_cita from core.citas where paciente_id = v_pago.paciente_id and id = v_pago.cita_id;

  if p_estado = 'fallido' then
    perform core.registrar_evento(v_pago.paciente_id, v_cita.tramite_id, null, 'pago_fallido',
                                  jsonb_build_object('pago_id', v_pago.id, 'detalle', p_datos));
    return jsonb_build_object('pago_id', v_pago.id, 'estado', 'fallido');
  end if;

  -- Si ya llegó a la clínica (pagó en caja), sigue en_clinica
  update core.citas set estado = case when estado = 'en_clinica' then estado else 'confirmada' end where paciente_id = v_cita.paciente_id and id = v_cita.id;
  update core.tramites
  set contexto = contexto || jsonb_build_object('pago_id', v_pago.id),
      paso_actual = 'confirmada', estado = 'completado', finalizado_en = now(),
      version = version + 1, ultima_actividad_en = now()
  where paciente_id = v_cita.paciente_id and id = v_cita.tramite_id
  returning * into v_tramite;

  perform core.registrar_evento(v_pago.paciente_id, v_cita.tramite_id, null, 'pago_confirmado',
                                jsonb_build_object('pago_id', v_pago.id, 'monto', v_pago.monto));
  perform core.registrar_evento(v_pago.paciente_id, v_cita.tramite_id, null, 'cita_confirmada',
                                jsonb_build_object('cita_id', v_cita.id, 'fecha_hora', v_cita.fecha_hora));
  perform core.registrar_evento(v_pago.paciente_id, v_cita.tramite_id, null, 'tramite_completado', '{}');
  return jsonb_build_object('pago_id', v_pago.id, 'estado', 'pagado', 'cita_id', v_cita.id, 'tramite_id', v_tramite.id);
end
$function$
;

create or replace function core.recalcular_metricas_dias(
  p_dias_tramites date[], p_dias_citas date[], p_dias_canales date[])
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_t int;
  v_c int;
  v_k int;
begin
  -- Trámites, por día de creación
  delete from core.metricas_tramites_diarias where dia = any (p_dias_tramites);
  insert into core.metricas_tramites_diarias (dia, clinica_id, tipo, paso, estado, canal_origen, ultimo_canal, tramites)
  select d.dia, t.clinica_id, t.tipo, t.paso_actual, t.estado, t.canal_origen, t.ultimo_canal, count(*)::int
  from (select distinct unnest(p_dias_tramites) as dia) d
  join core.tramites t
    on t.creado_en >= (d.dia::timestamp at time zone 'America/Mexico_City')
   and t.creado_en <  ((d.dia + 1)::timestamp at time zone 'America/Mexico_City')
  where t.eliminado_en is null
  group by 1, 2, 3, 4, 5, 6, 7;
  get diagnostics v_t = row_count;

  -- Citas, por día local de la clínica
  delete from core.metricas_citas_diarias where dia = any (p_dias_citas);
  insert into core.metricas_citas_diarias (dia, clinica_id, estudio_id, estado, citas, ingresos)
  select x.dia, c.clinica_id, c.estudio_id, c.estado, count(*)::int,
         coalesce(sum(c.precio) filter (where c.estado in ('confirmada', 'atendida', 'no_asistio')
                                           or (c.estado = 'en_clinica' and exists (
                                                 select 1 from core.pagos p where p.paciente_id = c.paciente_id
                                                   and p.cita_id = c.id and p.estado = 'pagado'))), 0)
  from core.citas c
  join core.clinicas cl on cl.id = c.clinica_id
  cross join lateral (select (c.fecha_hora at time zone cl.zona_horaria)::date as dia) x
  where c.eliminado_en is null
    -- rango amplio (±1 día por zonas horarias) para usar el índice; luego el día exacto
    and c.fecha_hora >= ((select min(d) from unnest(p_dias_citas) d) - 1)::timestamp at time zone 'UTC'
    and c.fecha_hora <  ((select max(d) from unnest(p_dias_citas) d) + 2)::timestamp at time zone 'UTC'
    and x.dia = any (p_dias_citas)
  group by 1, 2, 3, 4;
  get diagnostics v_c = row_count;

  -- Cambios de canal, por día del evento
  delete from core.metricas_canales_diarias where dia = any (p_dias_canales);
  insert into core.metricas_canales_diarias (dia, canal_desde, canal_hacia, paso, transiciones)
  select d.dia, ev.payload ->> 'de', ev.payload ->> 'a', ev.payload ->> 'paso_actual', count(*)::int
  from (select distinct unnest(p_dias_canales) as dia) d
  join core.eventos_tramite ev
    on ev.ocurrido_en >= (d.dia::timestamp at time zone 'America/Mexico_City')
   and ev.ocurrido_en <  ((d.dia + 1)::timestamp at time zone 'America/Mexico_City')
  where ev.tipo_evento = 'canal_cambiado'
  group by 1, 2, 3, 4;
  get diagnostics v_k = row_count;

  return jsonb_build_object('filas_tramites', v_t, 'filas_citas', v_c, 'filas_canales', v_k);
end
$$;

create or replace function api.reservar_cita(
  p_interaccion_id uuid, p_tramite_id uuid, p_version int, p_fecha_hora timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int      core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_tramite  core.tramites;
  v_ce       core.clinica_estudios;
  v_clinica  uuid;
  v_estudio  uuid;
  v_benef    uuid;
  v_relacion text;
  v_precio   numeric;
  v_cita     uuid;
  v_ocupados int;
  v_futuras  int;
begin
  v_tramite := core.bloquear_tramite(v_int, p_tramite_id, p_version);
  if v_tramite.paso_actual not in ('seleccion_horario', 'pago') then
    raise exception 'El trámite debe estar en selección de horario' using errcode = 'P0001';
  end if;
  if p_fecha_hora <= now() + interval '1 hour'
     and not (v_int.canal = 'clinica' and p_fecha_hora > now() - interval '15 minutes') then
    raise exception 'El horario debe ser al menos una hora en el futuro' using errcode = '22023';
  end if;

  v_benef    := coalesce(nullif(v_tramite.contexto ->> 'beneficiario_id', '')::uuid, v_tramite.paciente_id);
  v_relacion := core.relacion_beneficiario(v_tramite.paciente_id, v_benef);
  if v_relacion is null then
    raise exception 'El beneficiario ya no está ligado a este titular' using errcode = '22023';
  end if;

  v_clinica := (v_tramite.contexto ->> 'clinica_id')::uuid;
  v_estudio := (v_tramite.contexto ->> 'estudio_id')::uuid;
  select * into v_ce from core.clinica_estudios
  where clinica_id = v_clinica and estudio_id = v_estudio and activo and eliminado_en is null;
  if not found then
    raise exception 'La clínica no ofrece ese estudio' using errcode = '22023';
  end if;
  if not core.en_horario_atencion(v_clinica, p_fecha_hora) then
    raise exception 'horario_fuera_de_atencion' using errcode = '22023',
      hint = 'Elige un horario de api.horarios_disponibles';
  end if;

  perform core.verificar_duplicado(v_tramite.paciente_id, v_tramite.id, v_estudio, v_benef);

  -- Límite por titular: máximo 5 citas futuras (única excepción a la convención de errores)
  perform pg_advisory_xact_lock(hashtextextended('citas:' || v_tramite.paciente_id::text, 0));
  select count(*) into v_futuras from core.citas
  where paciente_id = v_tramite.paciente_id and estado in ('reservada', 'confirmada')
    and fecha_hora > now() and eliminado_en is null
    and not (tramite_id is not distinct from v_tramite.id and estado = 'reservada');
  if v_futuras >= 5 then
    perform core.registrar_evento(v_int.paciente_id, v_tramite.id, v_int.id, 'limite_citas_alcanzado',
                                  jsonb_build_object('citas_futuras', v_futuras, 'maximo', 5));
    perform set_config('response.status', '409', true);
    return jsonb_build_object('error', 'limite_citas', 'citas_futuras', v_futuras);
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_clinica::text || v_estudio::text || p_fecha_hora::text, 0));
  select count(*) into v_ocupados from core.agenda_clinica
  where clinica_id = v_clinica and estudio_id = v_estudio and fecha_hora = p_fecha_hora
    and estado in ('reservada', 'confirmada', 'en_clinica', 'atendida');
  if v_ocupados >= v_ce.capacidad_por_horario then
    raise sqlstate 'PT409' using message = 'horario_sin_cupo', hint = 'Elige otro horario';
  end if;

  update core.citas set estado = 'cancelada'
  where paciente_id = v_tramite.paciente_id and tramite_id = v_tramite.id and estado = 'reservada';
  if found then
    perform core.registrar_evento(v_int.paciente_id, v_tramite.id, v_int.id, 'cita_cancelada',
                                  jsonb_build_object('motivo', 'cambio_de_horario'));
  end if;

  select coalesce(v_ce.precio, precio_base) into v_precio from core.estudios where id = v_estudio;
  insert into core.citas (paciente_id, tramite_id, clinica_id, estudio_id, fecha_hora, precio, beneficiario_id, relacion)
  values (v_tramite.paciente_id, v_tramite.id, v_clinica, v_estudio, p_fecha_hora, v_precio, v_benef, v_relacion)
  returning id into v_cita;

  update core.tramites
  set contexto = contexto || jsonb_build_object('cita_id', v_cita, 'fecha_hora', p_fecha_hora, 'precio', v_precio),
      paso_actual = 'pago', version = version + 1, ultimo_canal = v_int.canal,
      ultima_actividad_en = now(), expira_en = now() + interval '72 hours', recordatorio_enviado_en = null
  where paciente_id = v_tramite.paciente_id and id = v_tramite.id
  returning * into v_tramite;

  update core.interacciones set tramite_id = v_tramite.id
  where paciente_id = v_int.paciente_id and id = v_int.id and tramite_id is distinct from v_tramite.id;

  perform core.registrar_evento(v_int.paciente_id, v_tramite.id, v_int.id, 'cita_reservada',
    jsonb_build_object('cita_id', v_cita, 'clinica_id', v_clinica, 'estudio_id', v_estudio,
                       'fecha_hora', p_fecha_hora, 'precio', v_precio,
                       'beneficiario_id', v_benef, 'relacion', v_relacion, 'folio', v_tramite.folio));
  return core.tramite_json(v_tramite);
end
$$;

drop function api.horarios_disponibles(uuid, uuid, date, int);
create function api.horarios_disponibles(
  p_clinica_id uuid, p_estudio_id uuid, p_desde date default null, p_dias int default 7,
  p_inmediato boolean default false)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_zona  text;
  v_cap   int;
  v_desde date;
  v_dias  int := least(greatest(coalesce(p_dias, 7), 1), 14);
  -- p_inmediato: en mostrador (personal de la clínica) también el horario en curso, si no 1 h de anticipación
  v_desde_hora timestamptz := case when coalesce(p_inmediato, false)
                                         and core.rol_actual() in ('recepcion', 'supervisor', 'admin')
                                    then now() - interval '15 minutes' else now() + interval '1 hour' end;
begin
  select zona_horaria into v_zona from core.clinicas where id = p_clinica_id and activa and eliminado_en is null;
  if v_zona is null then
    raise exception 'Clínica no encontrada' using errcode = 'PT404';
  end if;
  select ce.capacidad_por_horario into v_cap
  from core.clinica_estudios ce join core.estudios e on e.id = ce.estudio_id
  where ce.clinica_id = p_clinica_id and ce.estudio_id = p_estudio_id
    and ce.activo and ce.eliminado_en is null and e.activo and e.eliminado_en is null;
  if v_cap is null then
    raise exception 'La clínica no ofrece ese estudio' using errcode = '22023';
  end if;
  v_desde := coalesce(p_desde, (now() at time zone v_zona)::date);

  -- (el limit va en la subconsulta: en el select del agregado no limitaría nada)
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'fecha_hora', x.fecha_hora,
             'fecha', x.fecha,
             'hora', to_char(x.inicio, 'HH24:MI'),
             'disponibles', v_cap - x.ocupados)
           order by x.fecha_hora), '[]')
    from (
      select s.* from (
        select t.fecha, t.inicio, t.fecha_hora,
               (select count(*)::int from core.agenda_clinica a
                where a.clinica_id = p_clinica_id and a.estudio_id = p_estudio_id
                  and a.fecha_hora = t.fecha_hora and a.estado in ('reservada', 'confirmada', 'en_clinica', 'atendida')) as ocupados
        from (
          select d.fecha, (h.abre + make_interval(mins => k * h.intervalo_min))::time as inicio,
                 ((d.fecha + h.abre + make_interval(mins => k * h.intervalo_min)) at time zone v_zona) as fecha_hora
          from (select v_desde + g as fecha from generate_series(0, v_dias - 1) g) d
          join core.horarios_clinica h
            on h.clinica_id = p_clinica_id and h.dia_semana = extract(dow from d.fecha) and h.eliminado_en is null
          cross join lateral generate_series(
            0, (extract(epoch from (h.cierra - h.abre)) / 60)::int / h.intervalo_min - 1) k
          where not exists (select 1 from core.dias_inhabiles i
                            where (i.clinica_id = p_clinica_id or i.clinica_id is null)
                              and i.fecha = d.fecha and i.eliminado_en is null)
        ) t
        where t.fecha_hora >= v_desde_hora
      ) s
      where s.ocupados < v_cap
      order by s.fecha_hora
      limit 100
    ) x);
end
$$;
grant execute on function api.horarios_disponibles(uuid, uuid, date, int, boolean) to anon, authenticated, service_role;

create or replace function core.contexto_json(p_interaccion core.interacciones)
returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  v_pac      core.pacientes;
  v_tramite  core.tramites;
  v_nivel    int := core.rango_nivel(p_interaccion.nivel_verificacion);
  v_telefono text;
begin
  select * into v_pac from core.pacientes where id = p_interaccion.paciente_id;
  select * into v_tramite from core.tramites
  where paciente_id = p_interaccion.paciente_id and id = p_interaccion.tramite_id
    and estado in ('activo', 'pausado') and eliminado_en is null;
  select valor into v_telefono from core.identidades_paciente
  where paciente_id = v_pac.id and tipo = 'telefono' and eliminado_en is null
  order by core.rango_nivel(nivel_confianza) desc limit 1;

  if v_nivel = 0 then
    -- Sin verificar: solo cuántos trámites hay, su folio y su paso (sin estudio ni persona)
    return jsonb_build_object(
      'sesion', jsonb_build_object('interaccion_id', p_interaccion.id, 'canal', p_interaccion.canal,
                                   'nivel_verificacion', p_interaccion.nivel_verificacion,
                                   'requiere_verificacion', true,
                                   'metodos', jsonb_build_array('fecha_nacimiento', 'otp')),
      'paciente', jsonb_build_object('id', v_pac.id, 'tiene_fecha_nacimiento', v_pac.fecha_nacimiento is not null),
      'tramite_activo', case when v_tramite.id is null then null else jsonb_build_object(
                          'id', v_tramite.id, 'folio', v_tramite.folio, 'tipo', v_tramite.tipo,
                          'paso_actual', v_tramite.paso_actual) end,
      'tramites_abiertos', (
        select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'folio', t.folio, 'paso_actual', t.paso_actual)
                                  order by t.ultima_actividad_en desc), '[]')
        from core.tramites t
        where t.paciente_id = v_pac.id and t.estado in ('activo', 'pausado') and t.eliminado_en is null
          and t.contexto ? 'estudio_id' /* los trámites sin estudio no se ofrecen */));
  end if;

  return jsonb_build_object(
    'sesion', jsonb_build_object('interaccion_id', p_interaccion.id, 'canal', p_interaccion.canal,
                                 'nivel_verificacion', p_interaccion.nivel_verificacion,
                                 'requiere_verificacion', false,
                                 -- Campos que faltan para iniciar trámites (vacío = registro completo)
                                 'requiere_registro', to_jsonb(core.faltantes_registro(v_pac.id))),
    'paciente', jsonb_build_object(
      'id', v_pac.id,
      'estado', v_pac.estado,
      'nombre', case when v_nivel = 2 then nullif(concat_ws(' ', v_pac.nombre, v_pac.apellido_paterno, v_pac.apellido_materno), '')
                     else v_pac.nombre end,
      'nombre_mostrar', core.nombre_para_mostrar(v_pac.id, v_nivel = 2),
      'telefono', core.enmascarar_telefono(v_telefono),
      'tiene_fecha_nacimiento', v_pac.fecha_nacimiento is not null,
      'avisos_whatsapp', core.telefono_avisos(v_pac.id) is not null),
    'tramite_activo', case when v_tramite.id is null then null
                           else core.tramite_json(v_tramite) || jsonb_build_object(
                             'en_atencion_de_otro', core.en_atencion_de_otro(v_tramite, p_interaccion.id),
                             'atendido_por_mi', v_tramite.atendido_por_interaccion = p_interaccion.id
                                                and v_tramite.atencion_hasta > now()) end,
    'tramites_abiertos', (
      select coalesce(jsonb_agg(core.tramite_tarjeta(t, p_interaccion.id) order by t.ultima_actividad_en desc), '[]')
      from core.tramites t
      where t.paciente_id = v_pac.id and t.estado in ('activo', 'pausado') and t.eliminado_en is null
          and t.contexto ? 'estudio_id' /* los trámites sin estudio no se ofrecen */),
    'linea_tiempo', (
      select coalesce(jsonb_agg(x order by x ->> 'ocurrido_en' desc), '[]') from (
        select jsonb_build_object('ocurrido_en', ev.ocurrido_en, 'tipo_evento', ev.tipo_evento, 'canal', ev.canal,
                                  'actor_tipo', ev.actor_tipo, 'tramite_id', ev.tramite_id, 'payload', ev.payload) as x
        from core.eventos_tramite ev
        where ev.paciente_id = v_pac.id
          and ev.tipo_evento not in ('asesor_consulto_contexto', 'resumen_actualizado')
        order by ev.ocurrido_en desc limit 20) s),
    'mensajes_recientes', (
      select coalesce(jsonb_agg(jsonb_build_object('creado_en', s.creado_en, 'canal', s.canal, 'autor', s.autor,
                                                   'contenido', core.descifrar(s.contenido_cifrado, s.clave_version))
                                order by s.creado_en), '[]')
      from (select m.creado_en, m.canal, m.autor, m.contenido_cifrado, m.clave_version
            from core.mensajes m
            where m.paciente_id = v_pac.id
            order by m.creado_en desc limit 10) s),
    'citas_proximas', (
      select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'fecha_hora', c.fecha_hora, 'estado', c.estado,
                                                   'estudio', e.nombre, 'clinica', cl.nombre, 'precio', c.precio,
                                                   'folio', t.folio,
                                                   'turno', c.turno, 'llegada_en', c.llegada_en,
                                                   'area', core.nombre_area(e.area),
                                                   'beneficiario', jsonb_build_object('id', b.id, 'nombre', b.nombre,
                                                                                      'relacion', c.relacion))
                                order by c.fecha_hora), '[]')
      from core.citas c
      join core.estudios e on e.id = c.estudio_id
      join core.clinicas cl on cl.id = c.clinica_id
      join core.pacientes b on b.id = c.beneficiario_id
      left join core.tramites t on t.paciente_id = c.paciente_id and t.id = c.tramite_id
      where c.paciente_id = v_pac.id and c.eliminado_en is null
        and (c.estado in ('reservada', 'confirmada') and c.fecha_hora >= now() or c.estado = 'en_clinica')),
    'pagos_pendientes', (
      select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'monto', p.monto, 'link_pago', p.link_pago,
                                                   'expira_en', p.expira_en, 'folio', t.folio)), '[]')
      from core.pagos p
      join core.citas c on c.paciente_id = p.paciente_id and c.id = p.cita_id
      left join core.tramites t on t.paciente_id = c.paciente_id and t.id = c.tramite_id
      where p.paciente_id = v_pac.id and p.estado = 'pendiente' and p.expira_en > now())
  );
end
$$;

-- ---------------------------------------------------------------------
-- 4. Verificación presencial: de la sesión (mostrador) o de quien recibe el estudio (cita)
-- ---------------------------------------------------------------------
drop function api.verificar_presencial(uuid, text);
create function api.verificar_presencial(
  p_cita_id uuid default null, p_tipo_documento text default null, p_interaccion_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cita core.citas;
  v_int  core.interacciones;
  v_en   timestamptz := now();
begin
  perform core.exigir_rol('recepcion', 'asesor', 'supervisor', 'admin');
  if p_tipo_documento is null or p_tipo_documento not in
     ('ine', 'pasaporte', 'licencia', 'cedula_profesional', 'cartilla_militar', 'acta_nacimiento', 'curp', 'otro') then
    raise exception 'Tipo de documento inválido: %', p_tipo_documento using errcode = '22023';
  end if;
  if (p_cita_id is null) = (p_interaccion_id is null) then
    raise exception 'Indica la sesión del mostrador o la cita (una de las dos)' using errcode = '22023';
  end if;

  if p_interaccion_id is not null then
    -- Mostrador: la identificación oficial verifica ESTA sesión (no el teléfono)
    v_int := core.cargar_interaccion(p_interaccion_id);
    if v_int.canal <> 'clinica' then
      raise exception 'La identificación solo se verifica en persona (canal clínica)' using errcode = '42501';
    end if;
    update core.interacciones set nivel_verificacion = 'verificada', metodo_verificacion = 'identificacion'
    where paciente_id = v_int.paciente_id and id = v_int.id;
    update core.pacientes set verificado_presencial_en = v_en where id = v_int.paciente_id;
    perform core.registrar_evento(v_int.paciente_id, v_int.tramite_id, v_int.id, 'identidad_verificada',
      jsonb_build_object('metodo', 'identificacion', 'tipo_documento', p_tipo_documento));
    return core.contexto_json(core.cargar_interaccion(p_interaccion_id));
  end if;

  perform core.establecer_actor('clinica');
  select * into v_cita from core.citas where id = p_cita_id and eliminado_en is null for update;
  if not found then
    raise exception 'Cita no encontrada' using errcode = 'PT404';
  end if;
  perform core.validar_alcance_clinica(v_cita.clinica_id);
  if v_cita.estado not in ('reservada', 'confirmada', 'en_clinica', 'atendida') then
    raise exception 'La cita está %', v_cita.estado using errcode = '22023';
  end if;

  update core.pacientes set verificado_presencial_en = v_en where id = v_cita.beneficiario_id;
  perform core.registrar_evento(v_cita.paciente_id, v_cita.tramite_id, null, 'identidad_presencial_verificada',
    jsonb_build_object('cita_id', v_cita.id, 'beneficiario_id', v_cita.beneficiario_id,
                       'relacion', v_cita.relacion, 'tipo_documento', p_tipo_documento));
  return jsonb_build_object('cita_id', v_cita.id, 'beneficiario_id', v_cita.beneficiario_id,
                            'tipo_documento', p_tipo_documento, 'verificado_presencial_en', v_en);
end
$$;
revoke execute on function api.verificar_presencial(uuid, text, uuid) from public, anon;
grant execute on function api.verificar_presencial(uuid, text, uuid) to authenticated;

-- Llegada a la clínica (desde la agenda del día)
create or replace function api.registrar_llegada(
  p_cita_id uuid, p_tipo_documento text, p_cumplio_preparacion boolean default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cita    core.citas;
  v_estudio core.estudios;
  v_zona    text;
  v_turno   text;
  v_pagado  boolean;
  v_pago    core.pagos;
begin
  perform core.exigir_rol('recepcion', 'supervisor', 'admin');
  select * into v_cita from core.citas where id = p_cita_id and eliminado_en is null;
  if not found then
    raise exception 'Cita no encontrada' using errcode = 'PT404';
  end if;
  perform core.validar_alcance_clinica(v_cita.clinica_id);
  if v_cita.estado = 'en_clinica' then
    raise exception 'La llegada ya está registrada (turno %)', v_cita.turno using errcode = 'P0001';
  end if;
  if v_cita.estado not in ('reservada', 'confirmada') then
    raise exception 'La cita está %', v_cita.estado using errcode = '22023';
  end if;
  select zona_horaria into v_zona from core.clinicas where id = v_cita.clinica_id;
  if (v_cita.fecha_hora at time zone v_zona)::date <> (now() at time zone v_zona)::date then
    raise exception 'La cita no es de hoy' using errcode = '22023';
  end if;

  -- 1. Identificación de quien recibe el estudio (el beneficiario)
  perform api.verificar_presencial(p_cita_id => p_cita_id, p_tipo_documento => p_tipo_documento);

  -- 2. Cita en clínica, con turno por área y día
  select * into v_estudio from core.estudios where id = v_cita.estudio_id;
  v_turno := core.siguiente_turno(v_cita.clinica_id, v_estudio.area, (now() at time zone v_zona)::date);
  update core.citas set estado = 'en_clinica', llegada_en = now(), turno = v_turno
  where paciente_id = v_cita.paciente_id and id = v_cita.id;

  select * into v_pago from core.pagos
  where paciente_id = v_cita.paciente_id and cita_id = v_cita.id order by (estado = 'pagado') desc, creado_en desc limit 1;
  v_pagado := v_pago.estado = 'pagado';

  perform core.registrar_evento(v_cita.paciente_id, v_cita.tramite_id, null, 'llegada_registrada',
    jsonb_build_object('cita_id', v_cita.id, 'beneficiario_id', v_cita.beneficiario_id, 'turno', v_turno,
                       'area', v_estudio.area, 'tipo_documento', p_tipo_documento,
                       'cumplio_preparacion', p_cumplio_preparacion,
                       'pago', case when v_pagado then 'pagado' else 'pendiente' end));

  -- 3. A dónde dirigirlo
  return jsonb_build_object(
    'cita_id', v_cita.id, 'turno', v_turno, 'llegada_en', now(),
    'estudio', v_estudio.nombre, 'preparacion', v_estudio.preparacion,
    'cumplio_preparacion', p_cumplio_preparacion,
    'area', v_estudio.area, 'area_nombre', core.nombre_area(v_estudio.area),
    'pago', jsonb_build_object('estado', case when v_pagado then 'pagado' else 'pendiente' end,
                               'monto', coalesce(v_pago.monto, v_cita.precio)),
    'indicacion', case
      when not coalesce(v_pagado, false) then 'Pasar a caja'
      when p_cumplio_preparacion is false then 'No cumplió la preparación: consultar con ' || core.nombre_area(v_estudio.area)
      else 'Pasar a ' || core.nombre_area(v_estudio.area) end);
end
$$;
revoke execute on function api.registrar_llegada(uuid, text, boolean) from public, anon;
grant execute on function api.registrar_llegada(uuid, text, boolean) to authenticated;

-- Agenda del día: quién llega, su turno, el área y si ya pagó
create or replace function api.agenda_clinica(p_clinica_id uuid, p_fecha date default current_date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_zona text;
begin
  perform core.exigir_rol('recepcion', 'asesor', 'supervisor', 'admin');
  perform core.validar_alcance_clinica(p_clinica_id);
  perform core.establecer_actor(case when core.rol_actual() = 'recepcion' then 'clinica' else 'panel' end);
  select zona_horaria into v_zona from core.clinicas where id = p_clinica_id;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'cita_id', a.cita_id, 'fecha_hora', a.fecha_hora, 'estado', a.estado, 'estudio', e.nombre,
             'preparacion', e.preparacion, 'area', e.area, 'area_nombre', core.nombre_area(e.area),
             'paciente', core.nombre_para_mostrar(b.id, false),
             'es_titular', a.beneficiario_id = a.paciente_id,
             'agendada_por', case when a.beneficiario_id <> a.paciente_id
                                  then core.nombre_para_mostrar(t.id, false) end,
             'verificado_presencial', b.verificado_presencial_en is not null,
             'turno', c.turno, 'llegada_en', c.llegada_en,
             'pagada', exists (select 1 from core.pagos p where p.paciente_id = c.paciente_id
                                 and p.cita_id = c.id and p.estado = 'pagado'),
             'folio', tr.folio)
           order by a.fecha_hora), '[]')
    from core.agenda_clinica a
    join core.estudios e on e.id = a.estudio_id
    join core.pacientes b on b.id = a.beneficiario_id
    join core.pacientes t on t.id = a.paciente_id
    join core.citas c on c.paciente_id = a.paciente_id and c.id = a.cita_id
    left join core.tramites tr on tr.paciente_id = c.paciente_id and tr.id = c.tramite_id
    where a.clinica_id = p_clinica_id
      and a.estado <> 'cancelada'
      and a.fecha_hora >= (p_fecha::timestamp at time zone v_zona)
      and a.fecha_hora <  ((p_fecha + 1)::timestamp at time zone v_zona));
end
$$;

revoke execute on function core.canal_atencion(core.tramites), core.nombre_area(text), core.prefijo_turno(text),
  core.siguiente_turno(uuid, text, date), core.trg_alcance_recepcion()
  from public, anon, authenticated, service_role;
