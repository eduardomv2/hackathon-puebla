-- =====================================================================
-- 0400 · Motor de contexto (lógica interna en core)
--   eventos + tiempo real, resumen asíncrono, vinculación y fusión de
--   identidades, sesiones por canal y armado del contexto unificado
-- =====================================================================

create or replace function core.registrar_evento(
  p_paciente_id uuid, p_tramite_id uuid, p_interaccion_id uuid, p_tipo text, p_payload jsonb default '{}')
returns uuid
language sql
set search_path = ''
as $$
  insert into core.eventos_tramite (paciente_id, tramite_id, interaccion_id, tipo_evento, canal, actor_tipo, actor_id, payload)
  values (p_paciente_id, p_tramite_id, p_interaccion_id, p_tipo,
          core.canal_actual(), core.actor_tipo(), core.actor_id(), coalesce(p_payload, '{}'))
  returning id
$$;

-- Pide un resumen nuevo del trámite. La bandera evita encolar 20 veces el mismo
-- trámite en una ráfaga; el retraso de 3 s agrupa eventos seguidos.
create or replace function core.solicitar_resumen(p_tramite_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_paciente uuid;
begin
  update core.tramites set resumen_pendiente = true
  where id = p_tramite_id and not resumen_pendiente
  returning paciente_id into v_paciente;

  if v_paciente is not null then
    perform pgmq.send('resumen_tramite',
                      jsonb_build_object('tramite_id', p_tramite_id, 'paciente_id', v_paciente), 3);
  end if;
end
$$;

-- Después de cada evento: aviso en tiempo real al panel y al paciente, y resumen si aplica
create or replace function core.trg_evento_publicado()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mensaje jsonb := jsonb_build_object(
    'evento_id', new.id, 'paciente_id', new.paciente_id, 'tramite_id', new.tramite_id,
    'tipo_evento', new.tipo_evento, 'canal', new.canal, 'actor_tipo', new.actor_tipo,
    'ocurrido_en', new.ocurrido_en);
begin
  perform realtime.send(v_mensaje, new.tipo_evento, 'journey:global', true);
  perform realtime.send(v_mensaje, new.tipo_evento, 'paciente:' || new.paciente_id, true);

  if new.tramite_id is not null
     and (select dispara_resumen from core.catalogo_eventos where tipo_evento = new.tipo_evento) then
    perform core.solicitar_resumen(new.tramite_id);
  end if;
  return null;
end
$$;
create trigger trg_70_publicar after insert on core.eventos_tramite
  for each row execute function core.trg_evento_publicado();

-- ---------------------------------------------------------------------
-- Fusión de pacientes: mueve todo de "origen" a "destino" en una transacción
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

  -- tramites arrastra en cascada a interacciones, citas y pagos ligados
  update core.tramites            set paciente_id = p_destino where paciente_id = p_origen;
  update core.interacciones       set paciente_id = p_destino where paciente_id = p_origen;
  update core.citas               set paciente_id = p_destino where paciente_id = p_origen;
  update core.pagos               set paciente_id = p_destino where paciente_id = p_origen;
  update core.eventos_tramite     set paciente_id = p_destino where paciente_id = p_origen;
  update core.mensajes            set paciente_id = p_destino where paciente_id = p_origen;
  update core.otp                 set paciente_id = p_destino where paciente_id = p_origen;
  update core.identidades_paciente set paciente_id = p_destino where paciente_id = p_origen;

  -- Completar datos que el destino no tenga
  update core.pacientes d
  set nombre           = coalesce(d.nombre, o.nombre),
      apellido_paterno = coalesce(d.apellido_paterno, o.apellido_paterno),
      apellido_materno = coalesce(d.apellido_materno, o.apellido_materno),
      fecha_nacimiento = coalesce(d.fecha_nacimiento, o.fecha_nacimiento),
      sexo             = coalesce(d.sexo, o.sexo),
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

-- ---------------------------------------------------------------------
-- Vincula una identidad a un paciente.
--   · Identidad nueva                 → se agrega al paciente.
--   · Ya es suya                      → sube de nivel si la prueba es mejor.
--   · Es de otro paciente + verificada → se fusionan (el dueño se conserva).
--   · Es de otro paciente sin verificar → NO se fusiona; queda evento de conflicto.
-- Devuelve el paciente con el que hay que seguir.
-- ---------------------------------------------------------------------
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

  elsif p_nivel = 'verificada' then
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

-- Liga el teléfono y correo que Supabase Auth ya verificó (OTP) en la cuenta web/app
create or replace function core.vincular_identidades_auth(p_paciente_id uuid, p_canal text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  u        record;
  v_actual uuid := p_paciente_id;
begin
  select phone, phone_confirmed_at, email, email_confirmed_at into u from auth.users where id = auth.uid();
  if u.phone is not null and u.phone <> '' and u.phone_confirmed_at is not null then
    v_actual := core.vincular_identidad(v_actual, 'telefono', u.phone, 'verificada', p_canal);
  end if;
  if u.email is not null and u.email <> '' and u.email_confirmed_at is not null then
    v_actual := core.vincular_identidad(v_actual, 'email', u.email, 'verificada', p_canal);
  end if;
  return v_actual;
end
$$;

-- ---------------------------------------------------------------------
-- Sesiones por canal
-- ---------------------------------------------------------------------
create or replace function core.tramite_abierto(p_paciente_id uuid)
returns core.tramites
language sql stable
set search_path = ''
as $$
  select * from core.tramites
  where paciente_id = p_paciente_id and estado in ('activo', 'pausado') and eliminado_en is null
  order by ultima_actividad_en desc
  limit 1
$$;

-- Abre (o reutiliza) la sesión del paciente en un canal y detecta el cambio de canal
create or replace function core.abrir_interaccion(
  p_paciente_id uuid, p_canal text, p_agente text, p_nivel text, p_staff_id uuid default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_id      uuid;
  v_tramite core.tramites := core.tramite_abierto(p_paciente_id);
begin
  -- Reutiliza una sesión abierta reciente del mismo canal (p. ej. mensajes seguidos de WhatsApp)
  select id into v_id from core.interacciones
  where paciente_id = p_paciente_id and canal = p_canal and finalizada_en is null
    and staff_id is not distinct from p_staff_id
    and ultima_actividad_en > now() - interval '30 minutes'
  order by ultima_actividad_en desc limit 1;

  if v_id is not null then
    update core.interacciones
    set ultima_actividad_en = now(),
        nivel_verificacion = case when core.rango_nivel(p_nivel) > core.rango_nivel(nivel_verificacion)
                                  then p_nivel else nivel_verificacion end
    where paciente_id = p_paciente_id and id = v_id;
    return v_id;
  end if;

  insert into core.interacciones (paciente_id, tramite_id, canal, agente, staff_id, nivel_verificacion)
  values (p_paciente_id, v_tramite.id, p_canal, p_agente, p_staff_id, p_nivel)
  returning id into v_id;

  perform core.registrar_evento(p_paciente_id, v_tramite.id, v_id, 'interaccion_iniciada',
                                jsonb_build_object('agente', p_agente, 'nivel', p_nivel));

  if v_tramite.id is not null and v_tramite.ultimo_canal <> p_canal then
    update core.tramites set ultimo_canal = p_canal, ultima_actividad_en = now()
    where paciente_id = p_paciente_id and id = v_tramite.id;
    perform core.registrar_evento(p_paciente_id, v_tramite.id, v_id, 'canal_cambiado',
                                  jsonb_build_object('de', v_tramite.ultimo_canal, 'a', p_canal,
                                                     'paso_actual', v_tramite.paso_actual));
  end if;
  return v_id;
end
$$;

-- Autoriza el uso de una sesión y fija canal/actor de la transacción
create or replace function core.cargar_interaccion(p_interaccion_id uuid)
returns core.interacciones
language plpgsql
set search_path = ''
as $$
declare
  v     core.interacciones;
  v_rol text := core.rol_actual();
  v_actor text;
begin
  select * into v from core.interacciones where id = p_interaccion_id for update;
  if not found then
    raise exception 'Interacción no encontrada' using errcode = 'P0002';
  end if;
  if v.finalizada_en is not null then
    raise exception 'La interacción ya fue cerrada' using errcode = 'P0001';
  end if;

  case v_rol
    when 'paciente' then
      if v.paciente_id is distinct from core.mi_paciente_id() then
        raise exception 'Interacción no encontrada' using errcode = 'P0002';
      end if;
      v_actor := 'paciente';
    when 'asesor', 'supervisor' then
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
$$;

-- ---------------------------------------------------------------------
-- Armado del contexto
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

-- Contexto completo de una sesión. Lo que se muestra depende del nivel de verificación:
--   declarada  → solo que existe un trámite y en qué paso va (sin datos personales)
--   canal      → contexto del trámite, mensajes y citas; datos personales enmascarados
--   verificada → todo lo anterior + nombre completo
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
                                                   'estudio', e.nombre, 'clinica', cl.nombre, 'precio', c.precio)
                                order by c.fecha_hora), '[]')
      from core.citas c join core.estudios e on e.id = c.estudio_id join core.clinicas cl on cl.id = c.clinica_id
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
