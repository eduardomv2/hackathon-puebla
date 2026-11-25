-- =====================================================================
-- Supervisión: bandeja de atención y búsqueda de pacientes
--   · api.bandeja_atencion: conteos por categoría y la lista paginada (cursor) de UNA categoría:
--       atorados        trámites activos sin actividad en más de 2 h
--       pago_por_vencer links de pago pendientes que vencen en menos de 2 h
--       en_atencion     trámites bloqueados ahora por personal (call center o recepción)
--       seguridad       verificaciones fallidas o bloqueos por intentos en las últimas 24 h (por paciente)
--       llegadas_hoy    citas en clínica (llegaron) que aún no se atienden
--     Filtros: clínica, canal, estado del trámite y rango de fechas. Nunca lista todo: sin categoría solo
--     hay conteos, y cada página trae como máximo 50.
--   · api.buscar_pacientes: por celular, folio o nombre (mínimo 3 caracteres) → para abrir el journey.
--   · Nuevo evento verificacion_bloqueada (fecha de nacimiento: 3 fallos; OTP: 5 intentos).
-- =====================================================================

insert into core.catalogo_eventos (tipo_evento, categoria, descripcion, dispara_resumen) values
  ('verificacion_bloqueada', 'seguridad', 'Bloqueo temporal por demasiados intentos de verificación', false);

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
  if v_pac.intentos_verificacion_fallidos + 1 >= 3 then
    perform core.registrar_evento(v_pac.id, v_int.tramite_id, v_int.id, 'verificacion_bloqueada',
                                  jsonb_build_object('metodo', 'fecha_nacimiento', 'minutos', 15));
  end if;
  return jsonb_build_object('verificado', false, 'motivo', 'dato_no_coincide');
end
$$;

create or replace function api.validar_otp(p_interaccion_id uuid, p_codigo text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_otp core.otp;
begin
  select * into v_otp from core.otp
  where interaccion_id = v_int.id and usado_en is null and expira_en > now()
  order by creado_en desc limit 1 for update;

  if v_otp.id is null or v_otp.intentos >= 5 then
    return jsonb_build_object('verificado', false, 'motivo', 'sin_codigo_vigente');
  end if;

  if v_otp.codigo_hash = encode(extensions.digest(p_codigo || v_int.id::text, 'sha256'), 'hex') then
    update core.otp set usado_en = now() where id = v_otp.id;
    update core.interacciones set nivel_verificacion = 'verificada', metodo_verificacion = 'otp'
    where paciente_id = v_int.paciente_id and id = v_int.id;
    -- Se verifica el teléfono al que se ENVIÓ el código (filas previas: el de mayor confianza)
    perform core.vincular_identidad(v_int.paciente_id, 'telefono',
      coalesce(v_otp.telefono_destino, core.telefono_destino(v_int.paciente_id)), 'verificada', v_int.canal);
    perform core.registrar_evento(v_int.paciente_id, v_int.tramite_id, v_int.id, 'identidad_verificada',
                                  jsonb_build_object('metodo', 'otp'));
    return jsonb_build_object('verificado', true,
                              'contexto', core.contexto_json(core.cargar_interaccion(p_interaccion_id)));
  end if;

  update core.otp set intentos = intentos + 1 where id = v_otp.id;
  perform core.registrar_evento(v_int.paciente_id, v_int.tramite_id, v_int.id, 'verificacion_fallida',
                                jsonb_build_object('metodo', 'otp'));
  if v_otp.intentos + 1 >= 5 then
    perform core.registrar_evento(v_int.paciente_id, v_int.tramite_id, v_int.id, 'verificacion_bloqueada',
                                  jsonb_build_object('metodo', 'otp'));
  end if;
  return jsonb_build_object('verificado', false, 'motivo', 'codigo_incorrecto');
end
$$;

-- Índices de la bandeja
create index citas_en_clinica_idx on core.citas (clinica_id, llegada_en) where estado = 'en_clinica';
create index tramites_en_atencion_idx on core.tramites (atencion_hasta) where atendido_por_interaccion is not null;
create index eventos_tramite_seguridad_idx on core.eventos_tramite (ocurrido_en desc)
  where tipo_evento in ('verificacion_fallida', 'verificacion_bloqueada');

-- "3 h 10 min" / "45 min"
create or replace function core.duracion_texto(p interval)
returns text
language sql immutable
set search_path = ''
as $$
  select case
    when p is null then null
    when p < interval '1 minute' then 'menos de 1 min'
    when p < interval '1 hour' then floor(extract(epoch from p) / 60)::int || ' min'
    else floor(extract(epoch from p) / 3600)::int || ' h' ||
         case when floor(extract(epoch from p) / 60)::int % 60 > 0
              then ' ' || floor(extract(epoch from p) / 60)::int % 60 || ' min' else '' end
  end
$$;

create or replace function api.bandeja_atencion(
  p_clinica_id uuid default null, p_categoria text default null, p_limite int default 20, p_cursor text default null,
  p_canal text default null, p_estado text default null, p_desde date default null, p_hasta date default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rol      text := core.exigir_rol('supervisor', 'admin');
  v_clinica  uuid := p_clinica_id;
  v_limite   int := least(greatest(coalesce(p_limite, 20), 1), 50);
  v_cur_t    timestamptz;
  v_cur_id   uuid;
  v_desde    timestamptz;
  v_hasta    timestamptz;
  v_conteos  jsonb;
  v_items    jsonb;
  v_siguiente text;
begin
  perform core.establecer_actor('panel');
  -- Un supervisor con clínica solo ve la suya
  if v_rol = 'supervisor' and v_clinica is null then
    v_clinica := nullif(auth.jwt() -> 'app_metadata' ->> 'clinica_id', '')::uuid;
  end if;
  if v_clinica is not null then
    perform core.validar_alcance_clinica(v_clinica);
  end if;
  if p_categoria is not null
     and p_categoria not in ('atorados', 'pago_por_vencer', 'en_atencion', 'seguridad', 'llegadas_hoy') then
    raise exception 'Categoría desconocida: %', p_categoria using errcode = '22023';
  end if;
  if p_canal is not null and p_canal not in ('web', 'app', 'whatsapp', 'call_center', 'clinica') then
    raise exception 'Canal inválido: %', p_canal using errcode = '22023';
  end if;
  if p_estado is not null and p_estado not in ('activo', 'pausado', 'completado', 'abandonado', 'cancelado') then
    raise exception 'Estado inválido: %', p_estado using errcode = '22023';
  end if;
  if p_cursor is not null then
    begin
      v_cur_t  := split_part(p_cursor, '|', 1)::timestamptz;
      v_cur_id := split_part(p_cursor, '|', 2)::uuid;
    exception when others then
      raise exception 'Cursor inválido' using errcode = '22023';
    end;
  end if;
  -- Rango de fechas (día de México): cuándo se inició el trámite o, en seguridad, cuándo ocurrió
  v_desde := (p_desde::timestamp at time zone 'America/Mexico_City');
  v_hasta := ((p_hasta + 1)::timestamp at time zone 'America/Mexico_City');

  with b (categoria, orden, id, item) as (
    -- Atorados: activos (o pausados) sin actividad en más de 2 h. Primero los más viejos.
    select 'atorados', t.ultima_actividad_en, t.id, core.item_bandeja(t,
             'Sin actividad hace ' || core.duracion_texto(now() - t.ultima_actividad_en) || ' · ' ||
             coalesce((select descripcion from core.flujo_tramite where tipo_tramite = t.tipo and paso = t.paso_actual), t.paso_actual),
             t.ultima_actividad_en)
    from core.tramites t
    where t.estado in ('activo', 'pausado') and t.eliminado_en is null
      and t.ultima_actividad_en < now() - interval '2 hours'
      and (v_clinica is null or t.clinica_id = v_clinica)
      and (p_canal is null or t.ultimo_canal = p_canal)
      and (p_estado is null or t.estado = p_estado)
      and (v_desde is null or t.creado_en >= v_desde) and (v_hasta is null or t.creado_en < v_hasta)
    union all
    -- Pago por vencer: link pendiente que vence en menos de 2 h. Primero el que vence antes.
    select 'pago_por_vencer', p.expira_en, p.id, core.item_bandeja(t,
             'El link de pago vence en ' || core.duracion_texto(p.expira_en - now()) || ' · $' || p.monto, p.expira_en)
             || jsonb_build_object('pago_id', p.id, 'monto', p.monto)
    from core.pagos p
    join core.citas c on c.paciente_id = p.paciente_id and c.id = p.cita_id
    join core.tramites t on t.paciente_id = c.paciente_id and t.id = c.tramite_id
    where p.estado = 'pendiente' and p.expira_en > now() and p.expira_en < now() + interval '2 hours'
      and (v_clinica is null or c.clinica_id = v_clinica)
      and (p_canal is null or t.ultimo_canal = p_canal)
      and (p_estado is null or t.estado = p_estado)
      and (v_desde is null or t.creado_en >= v_desde) and (v_hasta is null or t.creado_en < v_hasta)
    union all
    -- En atención: bloqueados ahora por personal. Primero el que se libera antes.
    select 'en_atencion', t.atencion_hasta, t.id, core.item_bandeja(t,
             'Lo atiende ' || coalesce(s.nombre, 'personal') ||
             (case i.canal when 'clinica' then ' en recepción' else ' por teléfono' end) ||
             ' · se libera en ' || core.duracion_texto(t.atencion_hasta - now()), t.atencion_hasta)
             || jsonb_build_object('atiende', s.nombre, 'canal_atencion', i.canal)
    from core.tramites t
    join core.interacciones i on i.paciente_id = t.paciente_id and i.id = t.atendido_por_interaccion
    left join core.staff s on s.id = i.staff_id
    where t.atendido_por_interaccion is not null and t.atencion_hasta > now() and t.eliminado_en is null
      and (v_clinica is null or t.clinica_id = v_clinica or i.canal = 'clinica' and s.clinica_id = v_clinica)
      and (p_canal is null or t.ultimo_canal = p_canal)
      and (p_estado is null or t.estado = p_estado)
      and (v_desde is null or t.creado_en >= v_desde) and (v_hasta is null or t.creado_en < v_hasta)
    union all
    -- Seguridad: por paciente, fallos y bloqueos de las últimas 24 h. Primero lo más reciente.
    select 'seguridad', max(ev.ocurrido_en), ev.paciente_id, jsonb_build_object(
             'categoria', 'seguridad', 'paciente_id', ev.paciente_id,
             'paciente', core.nombre_para_mostrar(ev.paciente_id, false),
             'momento', max(ev.ocurrido_en),
             'canal', (array_agg(ev.canal order by ev.ocurrido_en desc))[1],
             'fallidas', count(*) filter (where ev.tipo_evento = 'verificacion_fallida'),
             'bloqueos', count(*) filter (where ev.tipo_evento = 'verificacion_bloqueada'),
             'metodos', to_jsonb(array_agg(distinct ev.payload ->> 'metodo')),
             'detalle', count(*) filter (where ev.tipo_evento = 'verificacion_fallida') || ' verificaciones fallidas' ||
                        case when count(*) filter (where ev.tipo_evento = 'verificacion_bloqueada') > 0
                             then ' y ' || count(*) filter (where ev.tipo_evento = 'verificacion_bloqueada') || ' bloqueo(s)'
                             else '' end || ' en 24 h (' || string_agg(distinct ev.payload ->> 'metodo', ', ') || ')',
             'bloqueado_hasta', (select case when p.bloqueado_hasta > now() then p.bloqueado_hasta end
                                 from core.pacientes p where p.id = ev.paciente_id))
    from core.eventos_tramite ev
    where ev.tipo_evento in ('verificacion_fallida', 'verificacion_bloqueada')
      and ev.ocurrido_en > now() - interval '24 hours'
      -- Con filtro de clínica: pacientes con trámites en esa clínica (el estado no aplica aquí)
      and (v_clinica is null or exists (select 1 from core.tramites t where t.paciente_id = ev.paciente_id
                                                                         and t.clinica_id = v_clinica))
      and (p_canal is null or ev.canal = p_canal)
      and (v_desde is null or ev.ocurrido_en >= v_desde) and (v_hasta is null or ev.ocurrido_en < v_hasta)
    group by ev.paciente_id
    union all
    -- Llegadas de hoy: en clínica sin atender. Primero quien lleva más tiempo esperando.
    select 'llegadas_hoy', c.llegada_en, c.id, core.item_bandeja(t,
             'Turno ' || coalesce(c.turno, '—') || ' · ' || core.nombre_area(e.area) || ' · espera ' ||
             core.duracion_texto(now() - c.llegada_en) ||
             case when exists (select 1 from core.pagos pg where pg.paciente_id = c.paciente_id and pg.cita_id = c.id
                                                          and pg.estado = 'pagado')
                  then ' · pagado' else ' · pago pendiente' end, c.llegada_en)
             || jsonb_build_object('cita_id', c.id, 'turno', c.turno, 'area', e.area,
                                   'paciente', core.nombre_para_mostrar(c.beneficiario_id, false))
    from core.citas c
    join core.clinicas cl on cl.id = c.clinica_id
    join core.estudios e on e.id = c.estudio_id
    left join core.tramites t on t.paciente_id = c.paciente_id and t.id = c.tramite_id
    where c.estado = 'en_clinica' and c.eliminado_en is null
      and (c.llegada_en at time zone cl.zona_horaria)::date = (now() at time zone cl.zona_horaria)::date
      and (v_clinica is null or c.clinica_id = v_clinica)
      and (p_canal is null or t.ultimo_canal = p_canal)
      and (p_estado is null or t.estado = p_estado)
  ),
  pagina as (
    -- Seguridad va de lo más reciente a lo más viejo, las demás al revés (lo más urgente primero)
    select b.*, row_number() over (order by
             case when p_categoria = 'seguridad' then null else b.orden end asc,
             case when p_categoria = 'seguridad' then b.orden end desc, b.id) as n
    from b
    where b.categoria = p_categoria
      and (v_cur_t is null
           or (p_categoria = 'seguridad' and (b.orden, b.id) < (v_cur_t, v_cur_id))
           or (p_categoria <> 'seguridad' and (b.orden, b.id) > (v_cur_t, v_cur_id))))
  select
    (select jsonb_object_agg(k, coalesce(x.n, 0))
     from unnest(array['atorados', 'pago_por_vencer', 'en_atencion', 'seguridad', 'llegadas_hoy']) k
     left join (select categoria, count(*)::int as n from b group by categoria) x on x.categoria = k),
    (select jsonb_agg(item || jsonb_build_object('categoria', categoria) order by n) from pagina where n <= v_limite),
    (select orden::text || '|' || id::text from pagina
     where n = v_limite and exists (select 1 from pagina where n = v_limite + 1))
  into v_conteos, v_items, v_siguiente;

  return jsonb_build_object(
    'conteos', v_conteos,
    'categoria', p_categoria,
    'items', coalesce(v_items, '[]'),
    'siguiente_cursor', v_siguiente,
    'filtros', jsonb_strip_nulls(jsonb_build_object('clinica_id', v_clinica, 'canal', p_canal, 'estado', p_estado,
                                                    'desde', p_desde, 'hasta', p_hasta, 'limite', v_limite)));
end
$$;

-- Renglón de la bandeja para un trámite
create or replace function core.item_bandeja(t core.tramites, p_detalle text, p_momento timestamptz)
returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'categoria', null, 'tramite_id', t.id, 'paciente_id', t.paciente_id,
    'paciente', core.nombre_para_mostrar(t.paciente_id, false),
    'folio', t.folio, 'etiqueta', core.etiqueta_tramite(t),
    'clinica', (select nombre from core.clinicas where id = t.clinica_id),
    'canal', t.ultimo_canal, 'paso', t.paso_actual, 'estado', t.estado,
    'momento', p_momento, 'detalle', p_detalle)
$$;

-- Búsqueda de pacientes para abrir su journey
create or replace function api.buscar_pacientes(p_texto text, p_limite int default 20)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rol     text := core.exigir_rol('supervisor', 'admin');
  v_texto   text := btrim(coalesce(p_texto, ''));
  v_digitos text := regexp_replace(coalesce(p_texto, ''), '\D', '', 'g');
  v_clinica uuid := case when core.rol_actual() = 'supervisor'
                         then nullif(auth.jwt() -> 'app_metadata' ->> 'clinica_id', '')::uuid end;
  v_tipo    text;
  v_ids     uuid[];
begin
  perform core.establecer_actor('panel');
  if length(v_texto) < 3 then
    raise exception 'Escribe al menos 3 caracteres (celular, folio o nombre)' using errcode = '22023';
  end if;

  if upper(v_texto) ~ '^SD-?[A-Z0-9]{4}$' then
    v_tipo := 'folio';
    select array_agg(distinct t.paciente_id) into v_ids from core.tramites t
    where t.folio = 'SD-' || right(upper(v_texto), 4);
  elsif v_texto ~ '^[0-9 +()-]+$' and length(v_digitos) >= 7 then
    v_tipo := 'telefono';
    select array_agg(distinct i.paciente_id) into v_ids from core.identidades_paciente i
    where i.tipo = 'telefono' and i.eliminado_en is null and i.valor like '%' || right(v_digitos, 10);
  else
    v_tipo := 'nombre';
    select array_agg(p.id) into v_ids from (
      select p.id from core.pacientes p
      where p.eliminado_en is null and p.estado <> 'fusionado' and p.nombre is not null
        and not exists (select 1 from unnest(string_to_array(core.texto_busqueda(v_texto), ' ')) w
                        where w <> '' and core.texto_busqueda(concat_ws(' ', p.nombre, p.apellido_paterno, p.apellido_materno))
                                          not like '%' || w || '%')
      limit 200) p;
  end if;

  perform audit.registrar_lectura('core.pacientes', 'busqueda', null,
                                  jsonb_build_object('tipo', v_tipo, 'resultados', coalesce(cardinality(v_ids), 0)));

  return (
    select coalesce(jsonb_agg(x order by x ->> 'ultima_actividad_en' desc nulls last), '[]') from (
      select jsonb_build_object(
        'paciente_id', p.id,
        'nombre', core.nombre_para_mostrar(p.id, true),
        'telefono', (select core.enmascarar_telefono(i.valor) from core.identidades_paciente i
                     where i.paciente_id = p.id and i.tipo = 'telefono' and i.eliminado_en is null
                     order by core.rango_nivel(i.nivel_confianza) desc limit 1),
        'estado', p.estado,
        -- Un familiar declarado no tiene journey propio: se abre el de su titular
        'titular_id', (select r.titular_id from core.relaciones_paciente r
                       where r.beneficiario_id = p.id and r.eliminado_en is null limit 1),
        'tramites_abiertos', (select count(*) from core.tramites t
                              where t.paciente_id = p.id and t.estado in ('activo', 'pausado') and t.eliminado_en is null),
        'ultimo_folio', (select t.folio from core.tramites t where t.paciente_id = p.id order by t.creado_en desc limit 1),
        'ultima_actividad_en', (select max(t.ultima_actividad_en) from core.tramites t where t.paciente_id = p.id),
        'coincide_por', v_tipo) as x
      from core.pacientes p
      where p.id = any (coalesce(v_ids, '{}'))
        -- Supervisor de clínica: solo pacientes con trámites o citas en su clínica
        and (v_clinica is null
             or exists (select 1 from core.tramites t where t.paciente_id = p.id and t.clinica_id = v_clinica)
             or exists (select 1 from core.citas c where c.beneficiario_id = p.id and c.clinica_id = v_clinica))
      limit least(greatest(coalesce(p_limite, 20), 1), 50)) s);
end
$$;

revoke execute on function api.bandeja_atencion(uuid, text, int, text, text, text, date, date),
  api.buscar_pacientes(text, int) from public, anon;
grant execute on function api.bandeja_atencion(uuid, text, int, text, text, text, date, date),
  api.buscar_pacientes(text, int) to authenticated;
revoke execute on function core.duracion_texto(interval), core.item_bandeja(core.tramites, text, timestamptz)
  from public, anon, authenticated, service_role;
