-- =====================================================================
-- Etapa 2 · Funciones de identidad, beneficiarios y continuidad
-- =====================================================================

-- ---------------------------------------------------------------------
-- Retención: no se borra nada con datos de pacientes. Solo se limpian los
-- contadores técnicos del rate limit (UNLOGGED, sin datos personales).
-- Ventanas de hasta 15 min (códigos fallidos) → se conserva 1 hora.
-- ---------------------------------------------------------------------
create or replace function core.limpieza()
returns void
language sql
security definer
set search_path = ''
as $$
  delete from core.rate_limit where ventana < now() - interval '1 hour';
$$;

-- Consulta un contador de rate limit sin incrementarlo
create or replace function core.limite_excedido(p_clave text, p_limite int, p_ventana_seg int)
returns boolean
language sql stable
set search_path = ''
as $$
  select coalesce((select conteo from core.rate_limit
                   where clave = p_clave
                     and ventana = to_timestamp(floor(extract(epoch from now()) / p_ventana_seg) * p_ventana_seg)), 0)
         >= p_limite
$$;

-- ---------------------------------------------------------------------
-- Beneficiarios: utilidades
-- ---------------------------------------------------------------------

-- Relación del beneficiario con el titular: 'titular' si es él mismo,
-- la relación registrada si es su beneficiario, null si no tiene nada que ver.
create or replace function core.relacion_beneficiario(p_titular uuid, p_beneficiario uuid)
returns text
language sql stable
set search_path = ''
as $$
  select case
    when p_beneficiario = p_titular then 'titular'
    else (select relacion from core.relaciones_paciente
          where titular_id = p_titular and beneficiario_id = p_beneficiario and eliminado_en is null)
  end
$$;

-- ---------------------------------------------------------------------
-- 9. Fusión y vinculación: un paciente 'declarado' jamás se fusiona.
--    Lo dio de alta un tercero (mamá, esposo) sin ninguna prueba; unirlo
--    con otro registro mezclaría historiales de dos personas distintas.
-- ---------------------------------------------------------------------
create or replace function core.fusionar_pacientes(
  p_origen uuid, p_destino uuid, p_motivo text, p_tipo text default null, p_valor text default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  r record;
  v_cancelar uuid;
begin
  if p_origen = p_destino then
    return p_destino;
  end if;

  -- Bloqueo en orden fijo para evitar interbloqueos entre fusiones simultáneas
  perform 1 from core.pacientes where id in (p_origen, p_destino) order by id for update;
  if exists (select 1 from core.pacientes where id in (p_origen, p_destino) and estado = 'declarado') then
    raise exception 'Un paciente declarado por un tercero nunca se fusiona' using errcode = '42501';
  end if;
  if (select estado from core.pacientes where id = p_origen) = 'fusionado' then
    raise exception 'El paciente origen ya fue fusionado' using errcode = 'P0001';
  end if;

  perform set_config('app.operacion', 'fusion', true);

  -- Si ambos tienen un trámite abierto del mismo tipo, se conserva el más reciente
  for r in
    select o.id as origen_id, d.id as destino_id, o.ultima_actividad_en as o_act, d.ultima_actividad_en as d_act
    from core.tramites o
    join core.tramites d on d.paciente_id = p_destino and d.tipo = o.tipo
                        and d.estado in ('activo', 'pausado') and d.eliminado_en is null
    where o.paciente_id = p_origen and o.estado in ('activo', 'pausado') and o.eliminado_en is null
  loop
    v_cancelar := case when r.o_act >= r.d_act then r.destino_id else r.origen_id end;
    update core.tramites set estado = 'cancelado', finalizado_en = now() where id = v_cancelar;
    perform core.registrar_evento(case when v_cancelar = r.origen_id then p_origen else p_destino end,
                                  v_cancelar, null, 'tramite_cancelado',
                                  jsonb_build_object('motivo', 'fusion_de_pacientes',
                                                     'conservado', case when v_cancelar = r.origen_id then r.destino_id else r.origen_id end));
  end loop;

  -- tramites arrastra en cascada a interacciones, citas, pagos y códigos ligados
  update core.tramites            set paciente_id = p_destino where paciente_id = p_origen;
  update core.interacciones       set paciente_id = p_destino where paciente_id = p_origen;
  update core.citas               set paciente_id = p_destino where paciente_id = p_origen;
  update core.pagos               set paciente_id = p_destino where paciente_id = p_origen;
  update core.eventos_tramite     set paciente_id = p_destino where paciente_id = p_origen;
  update core.mensajes            set paciente_id = p_destino where paciente_id = p_origen;
  update core.otp                 set paciente_id = p_destino where paciente_id = p_origen;
  update core.identidades_paciente set paciente_id = p_destino where paciente_id = p_origen;

  -- Las citas "para el titular" siguen siendo para él
  update core.citas set beneficiario_id = p_destino where beneficiario_id = p_origen;
  update core.tramites set contexto = contexto || jsonb_build_object('beneficiario_id', p_destino)
  where paciente_id = p_destino and contexto ->> 'beneficiario_id' = p_origen::text;

  -- Beneficiarios del origen pasan al destino; si el destino ya tenía al
  -- mismo beneficiario, la relación duplicada se da de baja (lógica).
  update core.relaciones_paciente r set titular_id = p_destino
  where r.titular_id = p_origen
    and not exists (select 1 from core.relaciones_paciente d
                    where d.titular_id = p_destino and d.beneficiario_id = r.beneficiario_id);
  update core.relaciones_paciente set eliminado_en = now()
  where titular_id = p_origen and eliminado_en is null;

  -- Completar datos que el destino no tenga
  update core.pacientes d
  set nombre           = coalesce(d.nombre, o.nombre),
      apellido_paterno = coalesce(d.apellido_paterno, o.apellido_paterno),
      apellido_materno = coalesce(d.apellido_materno, o.apellido_materno),
      fecha_nacimiento = coalesce(d.fecha_nacimiento, o.fecha_nacimiento),
      sexo             = coalesce(d.sexo, o.sexo),
      verificado_presencial_en = greatest(d.verificado_presencial_en, o.verificado_presencial_en),
      estado           = case when 'verificado' in (d.estado, o.estado) then 'verificado' else d.estado end
  from core.pacientes o
  where d.id = p_destino and o.id = p_origen;

  update core.pacientes set estado = 'fusionado', fusionado_en = p_destino where id = p_origen;

  insert into core.paciente_fusiones (paciente_origen, paciente_destino, motivo, identidad_tipo, identidad_valor,
                                      actor_id, actor_tipo, canal)
  values (p_origen, p_destino, p_motivo, p_tipo, p_valor, core.actor_id(), core.actor_tipo(), core.canal_actual());

  perform set_config('app.operacion', '', true);

  perform core.registrar_evento(p_destino, null, null, 'pacientes_fusionados',
                                jsonb_build_object('origen', p_origen, 'motivo', p_motivo, 'identidad_tipo', p_tipo));
  return p_destino;
end
$$;

create or replace function core.vincular_identidad(
  p_paciente_id uuid, p_tipo text, p_valor text, p_nivel text, p_canal text)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_valor text := core.normalizar_identidad(p_tipo, p_valor);
  v_id    core.identidades_paciente;
  v_final uuid;
begin
  -- Un beneficiario declarado no tiene identidades propias (no tiene sesión ni teléfono)
  if (select estado from core.pacientes where id = p_paciente_id) = 'declarado' then
    raise exception 'Un paciente declarado no tiene identidades propias' using errcode = '42501';
  end if;

  select * into v_id from core.identidades_paciente where tipo = p_tipo and valor = v_valor for update;

  if not found then
    insert into core.identidades_paciente (tipo, valor, paciente_id, nivel_confianza, verificada_en, origen_canal)
    values (p_tipo, v_valor, p_paciente_id, p_nivel,
            case when p_nivel = 'verificada' then now() end, p_canal);
    perform core.registrar_evento(p_paciente_id, null, null, 'identidad_agregada',
                                  jsonb_build_object('tipo', p_tipo, 'nivel', p_nivel));
    v_final := p_paciente_id;

  elsif v_id.paciente_id = p_paciente_id then
    if core.rango_nivel(p_nivel) > core.rango_nivel(v_id.nivel_confianza) then
      update core.identidades_paciente
      set nivel_confianza = p_nivel, verificada_en = case when p_nivel = 'verificada' then now() else verificada_en end
      where tipo = p_tipo and valor = v_valor;
      perform core.registrar_evento(p_paciente_id, null, null, 'identidad_verificada',
                                    jsonb_build_object('tipo', p_tipo, 'nivel', p_nivel));
    end if;
    v_final := p_paciente_id;

  elsif p_nivel = 'verificada'
        and (select estado from core.pacientes where id = v_id.paciente_id) <> 'declarado' then
    v_final := core.fusionar_pacientes(p_paciente_id, v_id.paciente_id, 'identidad_verificada_compartida', p_tipo, v_valor);
    update core.identidades_paciente set nivel_confianza = 'verificada', verificada_en = now()
    where tipo = p_tipo and valor = v_valor and nivel_confianza <> 'verificada';

  else
    perform core.registrar_evento(p_paciente_id, null, null, 'identidad_en_conflicto',
                                  jsonb_build_object('tipo', p_tipo, 'nivel', p_nivel));
    v_final := p_paciente_id;
  end if;

  if p_nivel = 'verificada' then
    update core.pacientes set estado = 'verificado' where id = v_final and estado in ('anonimo', 'identificado');
  elsif p_nivel = 'canal' then
    update core.pacientes set estado = 'identificado' where id = v_final and estado = 'anonimo';
  end if;
  return v_final;
end
$$;

-- ---------------------------------------------------------------------
-- 4. Contexto: el trámite y las citas dicen para quién son
-- ---------------------------------------------------------------------
create or replace function core.tramite_json(t core.tramites)
returns jsonb
language sql stable
set search_path = ''
as $$
  select case when t.id is null then null else jsonb_build_object(
    'id', t.id,
    'tipo', t.tipo,
    'estado', t.estado,
    'paso_actual', t.paso_actual,
    'paso_descripcion', (select descripcion from core.flujo_tramite where tipo_tramite = t.tipo and paso = t.paso_actual),
    'siguiente_paso', (select f2.paso from core.flujo_tramite f1
                       join core.flujo_tramite f2 on f2.tipo_tramite = f1.tipo_tramite and f2.orden = f1.orden + 1
                       where f1.tipo_tramite = t.tipo and f1.paso = t.paso_actual),
    'version', t.version,
    'contexto', t.contexto,
    'beneficiario', (select jsonb_build_object('id', b.id, 'nombre', b.nombre,
                                               'relacion', core.relacion_beneficiario(t.paciente_id, b.id))
                     from core.pacientes b
                     where b.id = coalesce(nullif(t.contexto ->> 'beneficiario_id', '')::uuid, t.paciente_id)),
    'estudio', (select jsonb_build_object('id', e.id, 'nombre', e.nombre, 'preparacion', e.preparacion)
                from core.estudios e where e.id = nullif(t.contexto ->> 'estudio_id', '')::uuid),
    'clinica', (select jsonb_build_object('id', c.id, 'nombre', c.nombre, 'ciudad', c.ciudad, 'direccion', c.direccion)
                from core.clinicas c where c.id = t.clinica_id),
    'resumen', t.resumen,
    'resumen_actualizado_en', t.resumen_actualizado_en,
    'canal_origen', t.canal_origen,
    'ultimo_canal', t.ultimo_canal,
    'canales_usados', (select coalesce(jsonb_agg(distinct ev.canal), '[]') from core.eventos_tramite ev
                       where ev.paciente_id = t.paciente_id and ev.tramite_id = t.id
                         and ev.canal not in ('sistema', 'panel')),
    'ultima_actividad_en', t.ultima_actividad_en,
    'expira_en', t.expira_en
  ) end
$$;

create or replace function core.contexto_json(p_interaccion core.interacciones)
returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  v_pac      core.pacientes;
  v_tramite  core.tramites := core.tramite_abierto(p_interaccion.paciente_id);
  v_nivel    int := core.rango_nivel(p_interaccion.nivel_verificacion);
  v_telefono text;
begin
  select * into v_pac from core.pacientes where id = p_interaccion.paciente_id;
  select valor into v_telefono from core.identidades_paciente
  where paciente_id = v_pac.id and tipo = 'telefono' and eliminado_en is null
  order by core.rango_nivel(nivel_confianza) desc limit 1;

  if v_nivel = 0 then
    return jsonb_build_object(
      'sesion', jsonb_build_object('interaccion_id', p_interaccion.id, 'canal', p_interaccion.canal,
                                   'nivel_verificacion', p_interaccion.nivel_verificacion,
                                   'requiere_verificacion', true,
                                   'metodos', jsonb_build_array('fecha_nacimiento', 'otp')),
      'paciente', jsonb_build_object('id', v_pac.id, 'tiene_fecha_nacimiento', v_pac.fecha_nacimiento is not null),
      'tramite_activo', case when v_tramite.id is null then null else jsonb_build_object(
                          'id', v_tramite.id, 'tipo', v_tramite.tipo, 'paso_actual', v_tramite.paso_actual) end);
  end if;

  return jsonb_build_object(
    'sesion', jsonb_build_object('interaccion_id', p_interaccion.id, 'canal', p_interaccion.canal,
                                 'nivel_verificacion', p_interaccion.nivel_verificacion,
                                 'requiere_verificacion', false),
    'paciente', jsonb_build_object(
      'id', v_pac.id,
      'estado', v_pac.estado,
      'nombre', case when v_nivel = 2 then concat_ws(' ', v_pac.nombre, v_pac.apellido_paterno, v_pac.apellido_materno)
                     else v_pac.nombre end,
      'telefono', core.enmascarar_telefono(v_telefono),
      'tiene_fecha_nacimiento', v_pac.fecha_nacimiento is not null),
    'tramite_activo', core.tramite_json(v_tramite),
    'linea_tiempo', (
      select coalesce(jsonb_agg(x order by x ->> 'ocurrido_en' desc), '[]') from (
        select jsonb_build_object('ocurrido_en', ev.ocurrido_en, 'tipo_evento', ev.tipo_evento, 'canal', ev.canal,
                                  'actor_tipo', ev.actor_tipo, 'payload', ev.payload) as x
        from core.eventos_tramite ev
        where ev.paciente_id = v_pac.id
          and ev.tipo_evento not in ('asesor_consulto_contexto', 'resumen_actualizado')
        order by ev.ocurrido_en desc limit 20) s),
    'mensajes_recientes', (
      select coalesce(jsonb_agg(x order by x ->> 'creado_en'), '[]') from (
        select jsonb_build_object('creado_en', m.creado_en, 'canal', m.canal, 'autor', m.autor, 'contenido', m.contenido) as x
        from core.mensajes m
        where m.paciente_id = v_pac.id
        order by m.creado_en desc limit 10) s),
    'citas_proximas', (
      select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'fecha_hora', c.fecha_hora, 'estado', c.estado,
                                                   'estudio', e.nombre, 'clinica', cl.nombre, 'precio', c.precio,
                                                   'beneficiario', jsonb_build_object('id', b.id, 'nombre', b.nombre,
                                                                                      'relacion', c.relacion))
                                order by c.fecha_hora), '[]')
      from core.citas c
      join core.estudios e on e.id = c.estudio_id
      join core.clinicas cl on cl.id = c.clinica_id
      join core.pacientes b on b.id = c.beneficiario_id
      where c.paciente_id = v_pac.id and c.estado in ('reservada', 'confirmada')
        and c.fecha_hora >= now() and c.eliminado_en is null),
    'pagos_pendientes', (
      select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'monto', p.monto, 'link_pago', p.link_pago,
                                                   'expira_en', p.expira_en)), '[]')
      from core.pagos p
      where p.paciente_id = v_pac.id and p.estado = 'pendiente' and p.expira_en > now())
  );
end
$$;

-- ---------------------------------------------------------------------
-- 1. Agregar beneficiario
-- ---------------------------------------------------------------------
create or replace function api.agregar_beneficiario(
  p_interaccion_id uuid, p_nombre text, p_apellido_paterno text, p_apellido_materno text,
  p_fecha_nacimiento date, p_sexo text, p_relacion text, p_es_tutor_legal boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int     core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_titular uuid := v_int.paciente_id;
  v_nombre  text := nullif(btrim(p_nombre), '');
  v_ap      text := nullif(btrim(p_apellido_paterno), '');
  v_am      text := nullif(btrim(p_apellido_materno), '');
  v_benef   uuid;
  v_total   int;
begin
  if v_int.nivel_verificacion = 'declarada' then
    raise exception 'Verifica la identidad antes de agregar beneficiarios' using errcode = '42501';
  end if;
  if v_nombre is null then
    raise exception 'El nombre del beneficiario es obligatorio' using errcode = '22023';
  end if;
  if p_fecha_nacimiento is null or p_fecha_nacimiento > current_date or p_fecha_nacimiento < date '1900-01-01' then
    raise exception 'Fecha de nacimiento inválida' using errcode = '22023';
  end if;
  if p_relacion is null or p_relacion not in ('hijo', 'hija', 'madre', 'padre', 'conyuge', 'otro') then
    raise exception 'Relación inválida: %', p_relacion using errcode = '22023';
  end if;
  if p_sexo is not null and p_sexo not in ('F', 'M', 'X') then
    raise exception 'Sexo inválido: %', p_sexo using errcode = '22023';
  end if;

  -- Serializa por titular (deduplicación y tope de 10)
  perform 1 from core.pacientes where id = v_titular for update;

  -- Solo busca entre los beneficiarios de ESTE titular: nunca en los de otros
  select r.beneficiario_id into v_benef
  from core.relaciones_paciente r
  join core.pacientes p on p.id = r.beneficiario_id
  where r.titular_id = v_titular and r.eliminado_en is null
    and lower(p.nombre) = lower(v_nombre)
    and lower(coalesce(p.apellido_paterno, '')) = lower(coalesce(v_ap, ''))
    and lower(coalesce(p.apellido_materno, '')) = lower(coalesce(v_am, ''))
    and p.fecha_nacimiento = p_fecha_nacimiento
  limit 1;

  if v_benef is not null then
    return jsonb_build_object('beneficiario_id', v_benef, 'reutilizado', true,
                              'relacion', core.relacion_beneficiario(v_titular, v_benef));
  end if;

  select count(*) into v_total from core.relaciones_paciente where titular_id = v_titular and eliminado_en is null;
  if v_total >= 10 then
    raise sqlstate 'PT409' using message = 'limite_beneficiarios', hint = 'Máximo 10 beneficiarios por titular';
  end if;

  insert into core.pacientes (estado, nombre, apellido_paterno, apellido_materno, fecha_nacimiento, sexo)
  values ('declarado', v_nombre, v_ap, v_am, p_fecha_nacimiento, p_sexo)
  returning id into v_benef;
  insert into core.relaciones_paciente (titular_id, beneficiario_id, relacion, es_tutor_legal)
  values (v_titular, v_benef, p_relacion, coalesce(p_es_tutor_legal, false));

  perform core.registrar_evento(v_benef, null, null, 'paciente_creado', jsonb_build_object('declarado_por', v_titular));
  perform core.registrar_evento(v_titular, v_int.tramite_id, v_int.id, 'beneficiario_agregado',
    jsonb_build_object('beneficiario_id', v_benef, 'relacion', p_relacion,
                       'es_tutor_legal', coalesce(p_es_tutor_legal, false)));
  return jsonb_build_object('beneficiario_id', v_benef, 'reutilizado', false, 'relacion', p_relacion);
end
$$;

-- ---------------------------------------------------------------------
-- 2. Mis beneficiarios
--   canal      → id, nombre de pila y relación
--   verificada → además nombre completo y fecha de nacimiento
-- ---------------------------------------------------------------------
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
  if v_completo and core.rol_actual() in ('asesor', 'supervisor', 'admin') then
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

-- ---------------------------------------------------------------------
-- 3. Trámite con beneficiario
-- ---------------------------------------------------------------------
create or replace function api.avanzar_tramite(
  p_interaccion_id uuid, p_tramite_id uuid, p_version int, p_paso text,
  p_datos jsonb default '{}', p_clave_idempotencia text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int      core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_tramite  core.tramites;
  v_destino  core.flujo_tramite;
  v_orden    int;
  v_datos    jsonb := jsonb_strip_nulls(coalesce(p_datos, '{}')) - 'cita_id' - 'pago_id' - 'precio' - 'fecha_hora';
  v_ctx      jsonb;
  v_faltan   text[];
  v_res      jsonb;
begin
  if p_clave_idempotencia is not null then
    select resultado into v_res from core.idempotencia where clave = p_clave_idempotencia;
    if found then return v_res; end if;
  end if;

  v_tramite := core.bloquear_tramite(v_int, p_tramite_id, p_version);

  select * into v_destino from core.flujo_tramite where tipo_tramite = v_tramite.tipo and paso = p_paso;
  if not found then
    raise exception 'Paso desconocido: %', p_paso using errcode = '22023';
  end if;
  select orden into v_orden from core.flujo_tramite where tipo_tramite = v_tramite.tipo and paso = v_tramite.paso_actual;
  if v_destino.orden > v_orden + 1 then
    raise exception 'No se puede saltar de % a %', v_tramite.paso_actual, p_paso using errcode = 'P0001';
  end if;
  if p_paso in ('pago', 'confirmada') and v_destino.orden > v_orden then
    raise exception 'El paso % se alcanza reservando la cita o pagando', p_paso using errcode = 'P0001';
  end if;

  if v_datos ? 'estudio_id' and not exists (select 1 from core.estudios
      where id = (v_datos ->> 'estudio_id')::uuid and activo and eliminado_en is null) then
    raise exception 'Estudio no disponible' using errcode = '22023';
  end if;
  if v_datos ? 'clinica_id' and not exists (select 1 from core.clinica_estudios ce
      where ce.clinica_id = (v_datos ->> 'clinica_id')::uuid and ce.activo and ce.eliminado_en is null
        and ce.estudio_id = coalesce((v_datos ->> 'estudio_id')::uuid, (v_tramite.contexto ->> 'estudio_id')::uuid)) then
    raise exception 'La clínica no ofrece ese estudio' using errcode = '22023';
  end if;
  -- Solo el propio titular o uno de SUS beneficiarios
  if v_datos ? 'beneficiario_id'
     and core.relacion_beneficiario(v_tramite.paciente_id, (v_datos ->> 'beneficiario_id')::uuid) is null then
    raise exception 'El beneficiario no pertenece a este titular' using errcode = '22023';
  end if;

  v_ctx := v_tramite.contexto || v_datos;
  select array_agg(r) into v_faltan from unnest(v_destino.requiere) r where not v_ctx ? r;
  if v_faltan is not null then
    raise exception 'Faltan datos para %: %', p_paso, array_to_string(v_faltan, ', ') using errcode = '22023';
  end if;

  update core.tramites
  set contexto = v_ctx, paso_actual = p_paso, version = version + 1, estado = 'activo',
      ultimo_canal = v_int.canal, ultima_actividad_en = now(), expira_en = now() + interval '72 hours',
      recordatorio_enviado_en = null
  where paciente_id = v_tramite.paciente_id and id = v_tramite.id
  returning * into v_tramite;

  update core.interacciones set tramite_id = v_tramite.id
  where paciente_id = v_int.paciente_id and id = v_int.id and tramite_id is null;

  perform core.registrar_evento(v_int.paciente_id, v_tramite.id, v_int.id, 'paso_avanzado',
    jsonb_build_object('de', (select paso from core.flujo_tramite where tipo_tramite = v_tramite.tipo and orden = v_orden),
                       'a', p_paso, 'datos', v_datos, 'version', v_tramite.version));

  v_res := core.tramite_json(v_tramite);
  if p_clave_idempotencia is not null then
    insert into core.idempotencia (clave, paciente_id, resultado) values (p_clave_idempotencia, v_int.paciente_id, v_res);
  end if;
  return v_res;
end
$$;

-- Aparta un horario para el beneficiario del trámite (o el titular).
--
-- EXCEPCIÓN A LA CONVENCIÓN DE ERRORES (la única): al rebasar el máximo de
-- 5 citas futuras NO se lanza una excepción. Lanzarla desharía la
-- transacción y el evento limite_citas_alcanzado se perdería, y ese evento
-- es la señal que usa el modelo antispam. En su lugar se guarda el evento,
-- se fija response.status = 409 (PostgREST responde HTTP 409) y se devuelve
-- {"error": "limite_citas", "citas_futuras": n}; la transacción se confirma.
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
  if p_fecha_hora <= now() + interval '1 hour' then
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

  -- Límite por titular: máximo 5 citas futuras reservadas o confirmadas.
  -- La reserva de este mismo trámite no cuenta (se reemplaza al cambiar horario).
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

  -- Cupo: serializa solo las reservas del mismo horario, estudio y clínica
  perform pg_advisory_xact_lock(hashtextextended(v_clinica::text || v_estudio::text || p_fecha_hora::text, 0));
  select count(*) into v_ocupados from core.agenda_clinica
  where clinica_id = v_clinica and estudio_id = v_estudio and fecha_hora = p_fecha_hora
    and estado in ('reservada', 'confirmada');
  if v_ocupados >= v_ce.capacidad_por_horario then
    raise sqlstate 'PT409' using message = 'horario_sin_cupo', hint = 'Elige otro horario';
  end if;

  -- Cambio de horario: libera la reserva anterior del mismo trámite
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

  perform core.registrar_evento(v_int.paciente_id, v_tramite.id, v_int.id, 'cita_reservada',
    jsonb_build_object('cita_id', v_cita, 'clinica_id', v_clinica, 'estudio_id', v_estudio,
                       'fecha_hora', p_fecha_hora, 'precio', v_precio,
                       'beneficiario_id', v_benef, 'relacion', v_relacion));
  return core.tramite_json(v_tramite);
end
$$;

-- Agenda del día: muestra a quien se atiende (beneficiario) y quién agendó
create or replace function api.agenda_clinica(p_clinica_id uuid, p_fecha date default current_date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_zona text;
begin
  perform core.exigir_rol('asesor', 'supervisor', 'admin');
  perform core.validar_alcance_clinica(p_clinica_id);
  perform core.establecer_actor('panel');
  select zona_horaria into v_zona from core.clinicas where id = p_clinica_id;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'cita_id', a.cita_id, 'fecha_hora', a.fecha_hora, 'estado', a.estado, 'estudio', e.nombre,
             'paciente', concat_ws(' ', b.nombre, left(b.apellido_paterno, 1) || '.'),
             'es_titular', a.beneficiario_id = a.paciente_id,
             'agendada_por', case when a.beneficiario_id <> a.paciente_id
                                  then concat_ws(' ', t.nombre, left(t.apellido_paterno, 1) || '.') end,
             'verificado_presencial', b.verificado_presencial_en is not null)
           order by a.fecha_hora), '[]')
    from core.agenda_clinica a
    join core.estudios e on e.id = a.estudio_id
    join core.pacientes b on b.id = a.beneficiario_id
    join core.pacientes t on t.id = a.paciente_id
    where a.clinica_id = p_clinica_id
      and a.fecha_hora >= (p_fecha::timestamp at time zone v_zona)
      and a.fecha_hora <  ((p_fecha + 1)::timestamp at time zone v_zona));
end
$$;

-- ---------------------------------------------------------------------
-- 5. Código de continuidad
-- ---------------------------------------------------------------------

-- Normaliza (mayúsculas, sin espacios ni guiones) y calcula el hash
create or replace function core.hash_codigo(p_codigo text)
returns text
language sql immutable
set search_path = ''
as $$
  select encode(extensions.digest(upper(regexp_replace(coalesce(p_codigo, ''), '[^A-Za-z0-9]', '', 'g')), 'sha256'), 'hex')
$$;

create or replace function core.codigo_vigente(c core.codigos_continuidad)
returns boolean
language sql stable
set search_path = ''
as $$
  select c.id is not null and c.usado_en is null and c.expira_en > now() and c.intentos < 5
$$;

create or replace function api.generar_codigo_continuidad(p_interaccion_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- 32 símbolos sin 0/O/1/I: 256 es múltiplo de 32, así que byte % 32 no tiene sesgo
  c_alfabeto constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_int     core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_tramite core.tramites;
  v_bytes   bytea;
  v_codigo  text;
  v_id      uuid;
  v_expira  timestamptz;
begin
  if v_int.canal not in ('web', 'app') then
    raise exception 'El código de continuidad solo se genera desde la web o la app' using errcode = '42501';
  end if;
  v_tramite := core.tramite_abierto(v_int.paciente_id);
  if v_tramite.id is null then
    raise exception 'No hay un trámite abierto para continuar' using errcode = 'P0002';
  end if;
  if not core.consumir_limite('codigo_continuidad:' || v_int.paciente_id, 5, 600) then
    raise sqlstate 'PT429' using message = 'Demasiados códigos generados', hint = 'Intenta de nuevo en 10 minutos';
  end if;

  for i in 1 .. 5 loop
    v_bytes := extensions.gen_random_bytes(8);
    select string_agg(substr(c_alfabeto, get_byte(v_bytes, n) % 32 + 1, 1), '' order by n)
    into v_codigo from generate_series(0, 7) n;

    insert into core.codigos_continuidad (codigo_hash, paciente_id, tramite_id, interaccion_origen_id, canal_origen)
    values (core.hash_codigo(v_codigo), v_int.paciente_id, v_tramite.id, v_int.id, v_int.canal)
    on conflict (codigo_hash) do nothing
    returning id, expira_en into v_id, v_expira;
    exit when v_id is not null;
  end loop;
  if v_id is null then
    raise exception 'No se pudo generar un código único' using errcode = 'P0001';
  end if;

  perform core.registrar_evento(v_int.paciente_id, v_tramite.id, v_int.id, 'codigo_continuidad_generado',
                                jsonb_build_object('codigo_id', v_id, 'expira_en', v_expira));
  return jsonb_build_object('codigo', v_codigo, 'expira_en', v_expira);
end
$$;

-- Código inválido: suma al contador del teléfono (y al código, si existe).
-- Al 5.º fallo en 15 min se invalidan los códigos vigentes del dueño del
-- teléfono y el teléfono queda bloqueado para códigos hasta que pase la ventana.
create or replace function core.registrar_fallo_codigo(p_telefono text, p_codigo_id uuid, p_dueno uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_codigo_id is not null then
    update core.codigos_continuidad set intentos = intentos + 1 where id = p_codigo_id;
  end if;
  if not core.consumir_limite('codigo_fallido:' || p_telefono, 4, 900) then
    update core.codigos_continuidad set expira_en = now()
    where paciente_id = p_dueno and usado_en is null and expira_en > now();
  end if;
end
$$;

create or replace function core.consumir_codigo(p_codigo_id uuid, p_paciente uuid, p_tramite uuid, p_interaccion uuid, p_caso text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  update core.codigos_continuidad set usado_en = now(), usado_en_canal = core.canal_actual() where id = p_codigo_id;
  perform core.registrar_evento(p_paciente, p_tramite, p_interaccion, 'codigo_continuidad_usado',
                                jsonb_build_object('codigo_id', p_codigo_id, 'caso', p_caso));
end
$$;

-- Pasa el trámite del código (con sus interacciones, eventos, mensajes,
-- citas y pagos) al dueño del teléfono. La identidad auth_uid de la sesión
-- web NO se mueve: la sesión web pierde el trámite y nunca gana acceso a
-- los datos que el dueño ya tenía.
create or replace function core.mover_tramite_continuidad(p_codigo core.codigos_continuidad, p_destino uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_origen uuid := p_codigo.paciente_id;
  v_ints   uuid[];
  v_benef  uuid;
begin
  select array_agg(id) into v_ints from core.interacciones
  where paciente_id = v_origen and tramite_id = p_codigo.tramite_id;

  perform set_config('app.operacion', 'fusion', true);
  -- En cascada: interacciones, citas → pagos y códigos del trámite
  update core.tramites set paciente_id = p_destino where paciente_id = v_origen and id = p_codigo.tramite_id;
  update core.eventos_tramite set paciente_id = p_destino
  where paciente_id = v_origen and (tramite_id = p_codigo.tramite_id or interaccion_id = any (v_ints));
  update core.mensajes set paciente_id = p_destino
  where paciente_id = v_origen and interaccion_id = any (v_ints);
  perform set_config('app.operacion', '', true);

  -- Lo que era "para el titular" sigue siendo para el titular (ahora el dueño)
  update core.citas set beneficiario_id = p_destino, relacion = 'titular'
  where paciente_id = p_destino and tramite_id = p_codigo.tramite_id and beneficiario_id = v_origen;
  select nullif(contexto ->> 'beneficiario_id', '')::uuid into v_benef
  from core.tramites where paciente_id = p_destino and id = p_codigo.tramite_id;
  if v_benef = v_origen then
    update core.tramites set contexto = contexto || jsonb_build_object('beneficiario_id', p_destino)
    where paciente_id = p_destino and id = p_codigo.tramite_id;
  end if;

  -- Beneficiarios declarados en la web para este trámite: se ligan también al dueño
  insert into core.relaciones_paciente (titular_id, beneficiario_id, relacion, es_tutor_legal)
  select p_destino, r.beneficiario_id, r.relacion, r.es_tutor_legal
  from core.relaciones_paciente r
  where r.titular_id = v_origen and r.eliminado_en is null and r.beneficiario_id <> p_destino
    and (r.beneficiario_id = v_benef
         or r.beneficiario_id in (select beneficiario_id from core.citas
                                  where paciente_id = p_destino and tramite_id = p_codigo.tramite_id))
  on conflict (titular_id, beneficiario_id) do nothing;

  -- La sesión web de origen ya no puede abrir la interacción movida: se cierra
  update core.interacciones set finalizada_en = now(), resultado = 'continuado_por_otro_paciente'
  where paciente_id = p_destino and id = p_codigo.interaccion_origen_id and finalizada_en is null;
end
$$;

-- Para resolver una colisión hace falta: WhatsApp con nivel 'canal' (Meta ya
-- comprobó el número) o cualquier canal con 'verificada'. Un identificador
-- de llamada solo (call center 'declarada' o 'canal' por fecha) nunca basta.
create or replace function core.puede_resolver_continuidad(p core.interacciones)
returns boolean
language sql immutable
set search_path = ''
as $$
  select (p.canal = 'whatsapp' and core.rango_nivel(p.nivel_verificacion) >= 1)
      or core.rango_nivel(p.nivel_verificacion) = 2
$$;

-- Resumen de un trámite para elegir, sin datos personales
create or replace function core.opcion_continuidad(t core.tramites, p_conservar text)
returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'conservar', p_conservar,
    'tramite_id', t.id,
    'tipo', t.tipo,
    'paso_actual', t.paso_actual,
    'paso_descripcion', (select descripcion from core.flujo_tramite where tipo_tramite = t.tipo and paso = t.paso_actual),
    'estudio', (select nombre from core.estudios where id = nullif(t.contexto ->> 'estudio_id', '')::uuid),
    'clinica', (select nombre from core.clinicas where id = t.clinica_id),
    'ultimo_canal', t.ultimo_canal,
    'ultima_actividad_en', t.ultima_actividad_en)
$$;

-- ---------------------------------------------------------------------
-- 6. iniciar_contacto con código de continuidad (cambia la firma)
-- ---------------------------------------------------------------------
drop function api.iniciar_contacto(text, text, text, text);

-- WhatsApp, voz con IA y call center: identifican por teléfono
--   p_nivel : 'canal' (número de WhatsApp) o 'declarada' (identificador de llamada)
--   p_codigo: código de continuidad generado en la web/app (opcional)
--     · Teléfono sin paciente      → se liga al paciente del código; la sesión queda en 'canal'.
--                                    La identidad telefónica se guarda con el nivel que prueba
--                                    el canal (WhatsApp 'canal', llamada 'declarada').
--     · Teléfono del mismo paciente → sesión en 'canal'.
--     · Teléfono de OTRO paciente  → el trámite pasa al dueño; la sesión conserva el nivel del
--                                    canal (el código no prueba nada sobre el dueño).
--                                    Si el dueño ya tiene un trámite abierto del mismo tipo no se
--                                    mueve nada: decide el dueño con api.resolver_continuidad.
--     · Código inválido            → el contacto sigue normal; la respuesta lo indica.
create function api.iniciar_contacto(
  p_canal text, p_telefono text, p_agente text, p_nivel text default 'declarada', p_codigo text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rol       text := core.exigir_rol('servicio', 'asesor', 'supervisor', 'admin');
  v_valor     text := core.normalizar_identidad('telefono', p_telefono);
  v_nivel     text := p_nivel;
  v_sesion    text;
  v_staff     uuid;
  v_dueno     uuid;
  v_paciente  uuid;
  v_int       uuid;
  v_ses       core.interacciones;
  v_codigo    core.codigos_continuidad;
  v_tramite   core.tramites;
  v_existente core.tramites;
  v_motivo    text;
  v_caso      text;
  v_contin    jsonb;
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
  v_sesion := v_nivel;

  perform core.establecer_actor(p_canal, case when p_agente = 'ia' then 'agente_ia' else 'asesor' end);
  perform pg_advisory_xact_lock(hashtextextended('telefono:' || v_valor, 0));

  select paciente_id into v_dueno from core.identidades_paciente
  where tipo = 'telefono' and valor = v_valor and eliminado_en is null;

  -- Código de continuidad
  if nullif(btrim(p_codigo), '') is not null then
    if core.limite_excedido('codigo_fallido:' || v_valor, 5, 900) then
      raise sqlstate 'PT429' using message = 'Demasiados códigos inválidos desde este teléfono',
                                   hint = 'Intenta de nuevo en 15 minutos';
    end if;
    select * into v_codigo from core.codigos_continuidad where codigo_hash = core.hash_codigo(p_codigo) for update;
    if v_codigo.id is not null then
      select * into v_tramite from core.tramites
      where paciente_id = v_codigo.paciente_id and id = v_codigo.tramite_id for update;
    end if;
    v_motivo := case
      when v_codigo.id is null          then 'no_existe'
      when v_codigo.usado_en is not null then 'usado'
      when v_codigo.intentos >= 5        then 'bloqueado'
      when v_codigo.expira_en <= now()   then 'vencido'
      when v_tramite.estado not in ('activo', 'pausado') or v_tramite.eliminado_en is not null then 'tramite_cerrado'
    end;
    if v_motivo is not null then
      if v_motivo <> 'tramite_cerrado' then
        perform core.registrar_fallo_codigo(v_valor, v_codigo.id, v_dueno);
      end if;
      v_contin := jsonb_build_object('estado', 'codigo_invalido', 'motivo', v_motivo);
      v_codigo := null;
    end if;
  end if;

  if v_codigo.id is null then
    -- Sin código (o inválido): flujo normal
    v_paciente := v_dueno;
    if v_paciente is null then
      insert into core.pacientes (estado) values ('identificado') returning id into v_paciente;
      perform core.registrar_evento(v_paciente, null, null, 'paciente_creado', jsonb_build_object('canal', p_canal));
    end if;
    v_paciente := core.vincular_identidad(v_paciente, 'telefono', v_valor, v_nivel, p_canal);

  elsif v_dueno is null or v_dueno = v_codigo.paciente_id then
    v_paciente := core.vincular_identidad(v_codigo.paciente_id, 'telefono', v_valor, v_nivel, p_canal);
    v_sesion   := 'canal';
    v_caso     := case when v_dueno is null then 'telefono_nuevo' else 'mismo_paciente' end;

  else
    v_paciente := core.vincular_identidad(v_dueno, 'telefono', v_valor, v_nivel, p_canal);
    select * into v_existente from core.tramites
    where paciente_id = v_paciente and tipo = v_tramite.tipo and estado in ('activo', 'pausado') and eliminado_en is null
    for update;
    if v_existente.id is null then
      perform core.mover_tramite_continuidad(v_codigo, v_paciente);
      v_caso := 'telefono_de_otro_paciente';
    end if;
  end if;

  v_int := core.abrir_interaccion(v_paciente, p_canal, p_agente, v_sesion, v_staff);
  v_ses := core.cargar_interaccion(v_int);

  if v_caso is not null then
    perform core.consumir_codigo(v_codigo.id, v_paciente, v_codigo.tramite_id, v_int, v_caso);
    v_contin := jsonb_build_object('estado', 'aplicado', 'caso', v_caso);
  elsif v_codigo.id is not null then
    -- Colisión: nada se mueve ni se consume; decide el dueño
    v_contin := jsonb_build_object(
      'estado', 'requiere_decision',
      'codigo_pendiente', true,
      'expira_en', v_codigo.expira_en,
      'requiere_verificacion', not core.puede_resolver_continuidad(v_ses));
    if core.puede_resolver_continuidad(v_ses) then
      v_contin := v_contin || jsonb_build_object('opciones', jsonb_build_array(
                    core.opcion_continuidad(v_tramite, 'web'),
                    core.opcion_continuidad(v_existente, 'existente')));
    end if;
  end if;

  return core.contexto_json(v_ses)
         || case when v_contin is null then '{}'::jsonb else jsonb_build_object('continuidad', v_contin) end;
end
$$;

-- El dueño del teléfono decide qué trámite conservar cuando el código choca
-- con uno que ya tenía abierto. Llamar después de iniciar_contacto (que no
-- consumió el código) y, en call center, después de validar_otp.
create or replace function api.resolver_continuidad(p_interaccion_id uuid, p_codigo text, p_conservar text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int       core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_codigo    core.codigos_continuidad;
  v_web       core.tramites;
  v_existente core.tramites;
  v_elegido   uuid;
begin
  if p_conservar is null or p_conservar not in ('web', 'existente') then
    raise exception 'p_conservar debe ser web o existente' using errcode = '22023';
  end if;
  if not core.puede_resolver_continuidad(v_int) then
    raise exception 'Verifica la identidad (OTP) antes de decidir' using errcode = '42501';
  end if;

  select * into v_codigo from core.codigos_continuidad where codigo_hash = core.hash_codigo(p_codigo) for update;
  if not core.codigo_vigente(v_codigo) then
    raise exception 'Código inválido, usado o vencido' using errcode = '22023';
  end if;
  if v_codigo.paciente_id = v_int.paciente_id then
    raise exception 'El código ya pertenece a este paciente' using errcode = '22023';
  end if;
  select * into v_web from core.tramites
  where paciente_id = v_codigo.paciente_id and id = v_codigo.tramite_id
    and estado in ('activo', 'pausado') and eliminado_en is null
  for update;
  if not found then
    raise exception 'El trámite del código ya no está abierto' using errcode = '22023';
  end if;
  select * into v_existente from core.tramites
  where paciente_id = v_int.paciente_id and tipo = v_web.tipo and estado in ('activo', 'pausado') and eliminado_en is null
  for update;

  if p_conservar = 'web' then
    if v_existente.id is not null then
      update core.tramites set estado = 'cancelado', finalizado_en = now()
      where paciente_id = v_existente.paciente_id and id = v_existente.id;
      perform core.registrar_evento(v_int.paciente_id, v_existente.id, v_int.id, 'tramite_cancelado',
        jsonb_build_object('motivo', 'continuidad_elegida_por_paciente', 'conservado', v_web.id));
    end if;
    perform core.mover_tramite_continuidad(v_codigo, v_int.paciente_id);
    v_elegido := v_web.id;
  else
    if v_existente.id is null then
      raise exception 'Ya no hay un trámite existente que conservar' using errcode = '22023';
    end if;
    update core.tramites set estado = 'cancelado', finalizado_en = now()
    where paciente_id = v_web.paciente_id and id = v_web.id;
    perform core.registrar_evento(v_web.paciente_id, v_web.id, null, 'tramite_cancelado',
      jsonb_build_object('motivo', 'continuidad_elegida_por_paciente', 'conservado', v_existente.id));
    v_elegido := v_existente.id;
  end if;

  update core.tramites set ultimo_canal = v_int.canal, ultima_actividad_en = now()
  where paciente_id = v_int.paciente_id and id = v_elegido;
  update core.interacciones set tramite_id = v_elegido
  where paciente_id = v_int.paciente_id and id = v_int.id;
  perform core.consumir_codigo(v_codigo.id, v_int.paciente_id, v_elegido, v_int.id, 'decision_' || p_conservar);

  return core.contexto_json(core.cargar_interaccion(p_interaccion_id))
         || jsonb_build_object('continuidad', jsonb_build_object('estado', 'aplicado', 'conservado', p_conservar));
end
$$;

-- ---------------------------------------------------------------------
-- 7. Verificación por fecha de nacimiento → solo 'canal'
-- ---------------------------------------------------------------------
-- La fecha de nacimiento NO verifica identidad: es un dato que la familia
-- (y cualquier persona cercana) conoce. Solo demuestra que quien llama sabe
-- algo del paciente, así que sube la sesión a 'canal' (trámite y datos
-- enmascarados). 'verificada' exige probar posesión del teléfono:
-- api.validar_otp o una cuenta de Supabase Auth con teléfono confirmado.
create or replace function api.verificar_identidad(p_interaccion_id uuid, p_fecha_nacimiento date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_pac core.pacientes;
begin
  select * into v_pac from core.pacientes where id = v_int.paciente_id for update;
  if v_pac.bloqueado_hasta > now() then
    raise sqlstate 'PT429' using message = 'Verificación bloqueada temporalmente',
                                 detail = 'Intenta de nuevo después de ' || v_pac.bloqueado_hasta;
  end if;
  if v_pac.fecha_nacimiento is null then
    return jsonb_build_object('verificado', false, 'motivo', 'sin_fecha_registrada', 'alternativa', 'otp');
  end if;

  if v_pac.fecha_nacimiento = p_fecha_nacimiento then
    update core.pacientes set intentos_verificacion_fallidos = 0, bloqueado_hasta = null where id = v_pac.id;
    update core.interacciones
    set nivel_verificacion  = case when nivel_verificacion = 'declarada' then 'canal' else nivel_verificacion end,
        metodo_verificacion = case when nivel_verificacion = 'declarada' then 'fecha_nacimiento' else metodo_verificacion end
    where paciente_id = v_int.paciente_id and id = v_int.id;
    perform core.registrar_evento(v_pac.id, v_int.tramite_id, v_int.id, 'identidad_verificada',
                                  jsonb_build_object('metodo', 'fecha_nacimiento', 'nivel', 'canal'));
    v_int := core.cargar_interaccion(p_interaccion_id);
    return jsonb_build_object('verificado', true, 'nivel_verificacion', v_int.nivel_verificacion,
                              'alternativa', case when v_int.nivel_verificacion <> 'verificada' then 'otp' end,
                              'contexto', core.contexto_json(v_int));
  end if;

  update core.pacientes
  set intentos_verificacion_fallidos = case when intentos_verificacion_fallidos + 1 >= 3 then 0 else intentos_verificacion_fallidos + 1 end,
      bloqueado_hasta = case when intentos_verificacion_fallidos + 1 >= 3 then now() + interval '15 minutes' end
  where id = v_pac.id;
  perform core.registrar_evento(v_pac.id, v_int.tramite_id, v_int.id, 'verificacion_fallida',
                                jsonb_build_object('metodo', 'fecha_nacimiento'));
  return jsonb_build_object('verificado', false, 'motivo', 'dato_no_coincide');
end
$$;

-- Web / app: 'verificada' solo si la cuenta tiene el teléfono confirmado
-- (una cuenta solo con correo, o anónima, entra como 'canal').
create or replace function api.iniciar_sesion_paciente(p_canal text default 'web')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_anonimo   boolean := coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false);
  v_tel_conf  boolean;
  v_paciente  uuid;
  v_int       uuid;
begin
  perform core.exigir_rol('paciente');
  perform core.establecer_actor(p_canal);
  perform pg_advisory_xact_lock(hashtextextended('auth:' || auth.uid()::text, 0));

  select coalesce(phone, '') <> '' and phone_confirmed_at is not null into v_tel_conf
  from auth.users where id = auth.uid();
  v_tel_conf := coalesce(v_tel_conf, false) and not v_anonimo;

  v_paciente := core.mi_paciente_id();
  if v_paciente is null then
    insert into core.pacientes (estado) values (case when v_anonimo then 'anonimo' else 'identificado' end)
    returning id into v_paciente;
    insert into core.identidades_paciente (tipo, valor, paciente_id, nivel_confianza, verificada_en, origen_canal)
    values ('auth_uid', auth.uid()::text, v_paciente, 'verificada', now(), p_canal);
    perform core.registrar_evento(v_paciente, null, null, 'paciente_creado', jsonb_build_object('anonimo', v_anonimo));
  end if;

  -- Si la cuenta ya verificó teléfono/correo por OTP, se liga (y fusiona si ya existía)
  v_paciente := core.vincular_identidades_auth(v_paciente, p_canal);

  v_int := core.abrir_interaccion(v_paciente, p_canal, 'autoservicio',
                                  case when v_tel_conf then 'verificada' else 'canal' end);
  return core.contexto_json(core.cargar_interaccion(v_int));
end
$$;

-- ---------------------------------------------------------------------
-- 8. Verificación presencial en clínica
--   Se guarda solo el TIPO de documento (en el evento). El número de la
--   INE u otra identificación nunca entra a la base.
-- ---------------------------------------------------------------------
create or replace function api.verificar_presencial(p_cita_id uuid, p_tipo_documento text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cita core.citas;
  v_en   timestamptz := now();
begin
  perform core.exigir_rol('asesor', 'supervisor', 'admin');
  perform core.establecer_actor('clinica');
  if p_tipo_documento is null or p_tipo_documento not in
     ('ine', 'pasaporte', 'licencia', 'cedula_profesional', 'cartilla_militar', 'acta_nacimiento', 'curp', 'otro') then
    raise exception 'Tipo de documento inválido: %', p_tipo_documento using errcode = '22023';
  end if;

  select * into v_cita from core.citas where id = p_cita_id and eliminado_en is null for update;
  if not found then
    raise exception 'Cita no encontrada' using errcode = 'P0002';
  end if;
  perform core.validar_alcance_clinica(v_cita.clinica_id);
  if v_cita.estado not in ('reservada', 'confirmada', 'atendida') then
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

-- ---------------------------------------------------------------------
-- Permisos
--   Funciones api nuevas (o recreadas): authenticated y service_role.
--   Cada una valida el rol del JWT por dentro. Las de core: nadie.
-- ---------------------------------------------------------------------
revoke execute on function
  api.agregar_beneficiario(uuid, text, text, text, date, text, text, boolean),
  api.mis_beneficiarios(uuid),
  api.generar_codigo_continuidad(uuid),
  api.iniciar_contacto(text, text, text, text, text),
  api.resolver_continuidad(uuid, text, text),
  api.verificar_presencial(uuid, text)
from public, anon;
grant execute on function
  api.agregar_beneficiario(uuid, text, text, text, date, text, text, boolean),
  api.mis_beneficiarios(uuid),
  api.generar_codigo_continuidad(uuid),
  api.iniciar_contacto(text, text, text, text, text),
  api.resolver_continuidad(uuid, text, text),
  api.verificar_presencial(uuid, text)
to authenticated, service_role;

revoke execute on function
  core.limite_excedido(text, int, int),
  core.relacion_beneficiario(uuid, uuid),
  core.hash_codigo(text),
  core.codigo_vigente(core.codigos_continuidad),
  core.registrar_fallo_codigo(text, uuid, uuid),
  core.consumir_codigo(uuid, uuid, uuid, uuid, text),
  core.mover_tramite_continuidad(core.codigos_continuidad, uuid),
  core.puede_resolver_continuidad(core.interacciones),
  core.opcion_continuidad(core.tramites, text)
from public, anon, authenticated, service_role;
