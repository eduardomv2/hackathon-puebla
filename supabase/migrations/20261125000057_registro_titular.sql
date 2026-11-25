-- =====================================================================
-- Registro mínimo del titular antes del primer trámite
--   · nombre + apellido paterno (el materno es opcional) + celular verificado.
--     "Celular verificado" = posesión probada del número: OTP (nivel 'verificada') o
--     WhatsApp (nivel 'canal', que solo el servicio de WhatsApp puede afirmar). Un número
--     dictado al asesor o en mostrador ('declarada') no cuenta hasta validar el OTP.
--   · api.iniciar_tramite responde 22023 'faltan_datos_titular' (details: {"faltan": [...]}).
--   · El contexto trae sesion.requiere_registro con los campos que faltan.
--   · Los datos se capturan con api.guardar_datos_paciente (paciente, bot o personal).
--   · Pacientes sin nombre (anteriores a esta regla) se muestran con el teléfono enmascarado.
-- =====================================================================

-- Campos que le faltan al titular para iniciar trámites
create or replace function core.faltantes_registro(p_paciente_id uuid)
returns text[]
language sql stable
set search_path = ''
as $$
  select array_remove(array[
    case when nullif(btrim(p.nombre), '') is null then 'nombre' end,
    case when nullif(btrim(p.apellido_paterno), '') is null then 'apellido_paterno' end,
    case when not exists (select 1 from core.identidades_paciente i
                          where i.paciente_id = p.id and i.tipo = 'telefono' and i.eliminado_en is null
                            and i.nivel_confianza in ('canal', 'verificada')) then 'celular_verificado' end
  ], null)
  from core.pacientes p where p.id = p_paciente_id
$$;

-- Nombre para listas y paneles: "Ana L." / "Ana López García"; sin nombre, el teléfono enmascarado
create or replace function core.nombre_para_mostrar(p_paciente_id uuid, p_completo boolean default false)
returns text
language sql stable
set search_path = ''
as $$
  select coalesce(
    case when nullif(btrim(p.nombre), '') is not null then
      case when p_completo then concat_ws(' ', p.nombre, p.apellido_paterno, p.apellido_materno)
           else concat_ws(' ', p.nombre, left(p.apellido_paterno, 1) || '.') end end,
    (select 'Paciente ' || core.enmascarar_telefono(i.valor) from core.identidades_paciente i
     where i.paciente_id = p.id and i.tipo = 'telefono' and i.eliminado_en is null
     order by core.rango_nivel(i.nivel_confianza) desc limit 1),
    'Paciente sin datos')
  from core.pacientes p where p.id = p_paciente_id
$$;

create or replace function api.iniciar_tramite(
  p_interaccion_id uuid, p_estudio_id uuid, p_beneficiario_id uuid default null, p_tipo text default 'agendar_estudio')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int     core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_benef   uuid;
  v_paso    text;
  v_tramite core.tramites;
  v_faltan  text[];
begin
  if v_int.nivel_verificacion = 'declarada' then
    raise exception 'Verifica la identidad antes de operar el trámite' using errcode = '42501';
  end if;
  if v_int.canal in ('web', 'app') and v_int.nivel_verificacion <> 'verificada' then
    raise exception 'Verifica tu celular con el código (OTP) para iniciar un trámite' using errcode = '42501';
  end if;
  -- Registro mínimo del titular: nombre, apellido paterno y celular verificado
  v_faltan := core.faltantes_registro(v_int.paciente_id);
  if cardinality(v_faltan) > 0 then
    raise exception 'faltan_datos_titular' using errcode = '22023',
      detail = jsonb_build_object('faltan', to_jsonb(v_faltan))::text,
      hint = 'Antes del primer trámite registra nombre, apellido paterno y celular verificado';
  end if;
  -- El paso siguiente al de elegir estudio (el trámite nace con el estudio ya elegido)
  select paso into v_paso from core.flujo_tramite where tipo_tramite = p_tipo and orden = 2;
  if v_paso is null then
    raise exception 'Tipo de trámite desconocido: %', p_tipo using errcode = '22023';
  end if;
  if p_estudio_id is null then
    raise exception 'Elige el estudio para iniciar el trámite' using errcode = '22023';
  end if;
  if not exists (select 1 from core.estudios where id = p_estudio_id and activo and eliminado_en is null) then
    raise exception 'Estudio no disponible' using errcode = '22023';
  end if;
  v_benef := coalesce(p_beneficiario_id, v_int.paciente_id);
  if core.relacion_beneficiario(v_int.paciente_id, v_benef) is null then
    raise exception 'El beneficiario no pertenece a este titular' using errcode = '22023';
  end if;

  -- Sin duplicados desde el inicio (ningún trámite propio todavía: id nulo)
  perform core.verificar_duplicado(v_int.paciente_id, '00000000-0000-0000-0000-000000000000'::uuid, p_estudio_id, v_benef);

  insert into core.tramites (paciente_id, tipo, paso_actual, canal_origen, ultimo_canal, contexto)
  values (v_int.paciente_id, p_tipo, v_paso, v_int.canal, v_int.canal,
          jsonb_strip_nulls(jsonb_build_object('estudio_id', p_estudio_id, 'beneficiario_id', p_beneficiario_id)))
  returning * into v_tramite;
  perform core.registrar_evento(v_int.paciente_id, v_tramite.id, v_int.id, 'tramite_iniciado',
    jsonb_strip_nulls(jsonb_build_object('tipo', p_tipo, 'folio', v_tramite.folio, 'estudio_id', p_estudio_id,
                                         'beneficiario_id', p_beneficiario_id)));
  update core.interacciones set tramite_id = v_tramite.id
  where paciente_id = v_int.paciente_id and id = v_int.id;
  v_tramite := core.exigir_atencion(v_int, v_tramite);  -- un asesor lo toma al crearlo
  return core.tramite_json(v_tramite);
end
$$;

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
                                                   'beneficiario', jsonb_build_object('id', b.id, 'nombre', b.nombre,
                                                                                      'relacion', c.relacion))
                                order by c.fecha_hora), '[]')
      from core.citas c
      join core.estudios e on e.id = c.estudio_id
      join core.clinicas cl on cl.id = c.clinica_id
      join core.pacientes b on b.id = c.beneficiario_id
      left join core.tramites t on t.paciente_id = c.paciente_id and t.id = c.tramite_id
      where c.paciente_id = v_pac.id and c.estado in ('reservada', 'confirmada')
        and c.fecha_hora >= now() and c.eliminado_en is null),
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

-- Listas del personal: sin nombre → teléfono enmascarado
create or replace function api.tramites_en_curso(
  p_clinica_id uuid default null, p_paso text default null, p_limite int default 50, p_antes_de timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform core.exigir_rol('supervisor', 'admin');
  if p_clinica_id is not null then perform core.validar_alcance_clinica(p_clinica_id); end if;
  perform core.establecer_actor('panel');

  return (
    select coalesce(jsonb_agg(x order by (x ->> 'ultima_actividad_en') desc), '[]') from (
      select jsonb_build_object(
        'tramite_id', t.id, 'paciente_id', t.paciente_id,
        'paciente', core.nombre_para_mostrar(p.id, false),
        'tipo', t.tipo, 'paso_actual', t.paso_actual, 'estado', t.estado,
        'canal_origen', t.canal_origen, 'ultimo_canal', t.ultimo_canal,
        'clinica', c.nombre, 'ultima_actividad_en', t.ultima_actividad_en,
        'minutos_inactivo', (extract(epoch from now() - t.ultima_actividad_en) / 60)::int,
        'resumen', core.descifrar(t.resumen_cifrado, t.resumen_clave_version)) as x
      from core.tramites t
      join core.pacientes p on p.id = t.paciente_id
      left join core.clinicas c on c.id = t.clinica_id
      where t.estado in ('activo', 'pausado') and t.eliminado_en is null
        and (p_clinica_id is null or t.clinica_id = p_clinica_id)
        and (p_paso is null or t.paso_actual = p_paso)
        and (p_antes_de is null or t.ultima_actividad_en < p_antes_de)
      order by t.ultima_actividad_en desc
      limit least(greatest(p_limite, 1), 200)) s);
end
$$;

create or replace function api.journey_paciente(p_paciente_id uuid, p_limite int default 100)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform core.exigir_rol('supervisor', 'admin');
  perform core.establecer_actor('panel');
  perform audit.registrar_lectura('core.journey', p_paciente_id::text, p_paciente_id, null);

  return jsonb_build_object(
    'paciente', (select jsonb_build_object('id', p.id, 'estado', p.estado,
                   'nombre', core.nombre_para_mostrar(p.id, true))
                 from core.pacientes p where p.id = p_paciente_id),
    'tramites', (select coalesce(jsonb_agg(core.tramite_json(t) order by t.creado_en desc), '[]')
                 from core.tramites t where t.paciente_id = p_paciente_id and t.eliminado_en is null),
    'interacciones', (select coalesce(jsonb_agg(jsonb_build_object(
                         'id', i.id, 'canal', i.canal, 'agente', i.agente, 'nivel', i.nivel_verificacion,
                         'iniciada_en', i.iniciada_en, 'finalizada_en', i.finalizada_en, 'resultado', i.resultado)
                       order by i.iniciada_en desc), '[]')
                      from core.interacciones i where i.paciente_id = p_paciente_id),
    'linea_tiempo', (select coalesce(jsonb_agg(x order by x ->> 'ocurrido_en' desc), '[]') from (
                       select jsonb_build_object('ocurrido_en', ev.ocurrido_en, 'tipo_evento', ev.tipo_evento,
                                                 'canal', ev.canal, 'actor_tipo', ev.actor_tipo, 'payload', ev.payload) as x
                       from core.eventos_tramite ev where ev.paciente_id = p_paciente_id
                       order by ev.ocurrido_en desc limit least(greatest(p_limite, 1), 500)) s));
end
$$;

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
             'paciente', core.nombre_para_mostrar(b.id, false),
             'es_titular', a.beneficiario_id = a.paciente_id,
             'agendada_por', case when a.beneficiario_id <> a.paciente_id
                                  then core.nombre_para_mostrar(t.id, false) end,
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

revoke execute on function core.faltantes_registro(uuid), core.nombre_para_mostrar(uuid, boolean)
  from public, anon, authenticated, service_role;
