-- =====================================================================
-- 0500 · API pública (esquema api, expuesto en la Data API de Supabase)
--   Cada función: autoriza por rol → fija canal/actor → opera → registra evento.
--   Todas son SECURITY DEFINER con search_path vacío.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Entrada de cada canal
-- ---------------------------------------------------------------------

-- Web / app: el paciente con sesión de Supabase Auth (anónima o verificada)
create or replace function api.iniciar_sesion_paciente(p_canal text default 'web')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_anonimo  boolean := coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false);
  v_paciente uuid;
  v_int      uuid;
begin
  perform core.exigir_rol('paciente');
  perform core.establecer_actor(p_canal);
  perform pg_advisory_xact_lock(hashtextextended('auth:' || auth.uid()::text, 0));

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
                                  case when v_anonimo then 'canal' else 'verificada' end);
  return core.contexto_json(core.cargar_interaccion(v_int));
end
$$;

-- WhatsApp, voz con IA y call center: identifican por teléfono
--   p_nivel: 'canal' (número de WhatsApp) o 'declarada' (identificador de llamada)
create or replace function api.iniciar_contacto(
  p_canal text, p_telefono text, p_agente text, p_nivel text default 'declarada')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rol      text := core.exigir_rol('servicio', 'asesor', 'supervisor', 'admin');
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

-- ---------------------------------------------------------------------
-- Verificación de identidad dentro de una sesión
-- ---------------------------------------------------------------------

-- Por fecha de nacimiento (call center, voz). 3 errores bloquean 15 minutos.
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
    update core.interacciones set nivel_verificacion = 'verificada', metodo_verificacion = 'fecha_nacimiento'
    where paciente_id = v_int.paciente_id and id = v_int.id;
    perform core.registrar_evento(v_pac.id, v_int.tramite_id, v_int.id, 'identidad_verificada',
                                  jsonb_build_object('metodo', 'fecha_nacimiento'));
    return jsonb_build_object('verificado', true,
                              'contexto', core.contexto_json(core.cargar_interaccion(p_interaccion_id)));
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

-- OTP para canales sin sesión: la base genera el código y guarda solo su hash;
-- el servicio lo envía por WhatsApp/SMS. Máximo 3 códigos cada 10 minutos.
create or replace function api.solicitar_otp(p_interaccion_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int    core.interacciones;
  v_codigo text;
begin
  perform core.exigir_rol('servicio');
  v_int := core.cargar_interaccion(p_interaccion_id);
  if not core.consumir_limite('otp:' || v_int.paciente_id, 3, 600) then
    raise sqlstate 'PT429' using message = 'Demasiados códigos solicitados';
  end if;
  v_codigo := lpad((('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint % 1000000)::text, 6, '0');
  insert into core.otp (paciente_id, interaccion_id, codigo_hash)
  values (v_int.paciente_id, v_int.id, encode(extensions.digest(v_codigo || v_int.id::text, 'sha256'), 'hex'));
  perform core.registrar_evento(v_int.paciente_id, v_int.tramite_id, v_int.id, 'otp_enviado', '{}');
  return jsonb_build_object('codigo', v_codigo, 'expira_en', now() + interval '5 minutes');
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
    perform core.vincular_identidad(v_int.paciente_id, 'telefono',
      (select valor from core.identidades_paciente where paciente_id = v_int.paciente_id and tipo = 'telefono' limit 1),
      'verificada', v_int.canal);
    perform core.registrar_evento(v_int.paciente_id, v_int.tramite_id, v_int.id, 'identidad_verificada',
                                  jsonb_build_object('metodo', 'otp'));
    return jsonb_build_object('verificado', true,
                              'contexto', core.contexto_json(core.cargar_interaccion(p_interaccion_id)));
  end if;

  update core.otp set intentos = intentos + 1 where id = v_otp.id;
  perform core.registrar_evento(v_int.paciente_id, v_int.tramite_id, v_int.id, 'verificacion_fallida',
                                jsonb_build_object('metodo', 'otp'));
  return jsonb_build_object('verificado', false, 'motivo', 'codigo_incorrecto');
end
$$;

-- ---------------------------------------------------------------------
-- Contexto
-- ---------------------------------------------------------------------
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
  if core.rol_actual() in ('asesor', 'supervisor', 'admin') and v_int.nivel_verificacion <> 'declarada' then
    perform audit.registrar_lectura('core.contexto', v_int.paciente_id::text, v_int.paciente_id,
                                    jsonb_build_object('interaccion_id', v_int.id));
    perform core.registrar_evento(v_int.paciente_id, v_int.tramite_id, v_int.id, 'asesor_consulto_contexto', '{}');
  end if;
  return v_ctx;
end
$$;

-- Datos demográficos: una sesión no verificada solo puede llenar huecos, no sobrescribir
create or replace function api.guardar_datos_paciente(
  p_interaccion_id uuid, p_nombre text default null, p_apellido_paterno text default null,
  p_apellido_materno text default null, p_fecha_nacimiento date default null, p_sexo text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int       core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_verificada boolean := v_int.nivel_verificacion = 'verificada';
begin
  if p_fecha_nacimiento is not null and (p_fecha_nacimiento > current_date or p_fecha_nacimiento < date '1900-01-01') then
    raise exception 'Fecha de nacimiento inválida' using errcode = '22023';
  end if;
  update core.pacientes set
    nombre           = case when v_verificada or nombre is null then coalesce(nullif(btrim(p_nombre), ''), nombre) else nombre end,
    apellido_paterno = case when v_verificada or apellido_paterno is null then coalesce(nullif(btrim(p_apellido_paterno), ''), apellido_paterno) else apellido_paterno end,
    apellido_materno = case when v_verificada or apellido_materno is null then coalesce(nullif(btrim(p_apellido_materno), ''), apellido_materno) else apellido_materno end,
    fecha_nacimiento = case when v_verificada or fecha_nacimiento is null then coalesce(p_fecha_nacimiento, fecha_nacimiento) else fecha_nacimiento end,
    sexo             = case when v_verificada or sexo is null then coalesce(p_sexo, sexo) else sexo end
  where id = v_int.paciente_id;
  perform core.registrar_evento(v_int.paciente_id, v_int.tramite_id, v_int.id, 'datos_paciente_actualizados',
    jsonb_build_object('campos', (select coalesce(jsonb_agg(k), '[]') from unnest(array[
      case when p_nombre is not null then 'nombre' end, case when p_apellido_paterno is not null then 'apellido_paterno' end,
      case when p_apellido_materno is not null then 'apellido_materno' end, case when p_fecha_nacimiento is not null then 'fecha_nacimiento' end,
      case when p_sexo is not null then 'sexo' end]) k where k is not null)));
  return core.contexto_json(core.cargar_interaccion(p_interaccion_id));
end
$$;

-- ---------------------------------------------------------------------
-- Trámite
-- ---------------------------------------------------------------------

-- Retoma el trámite abierto o inicia uno nuevo
create or replace function api.iniciar_tramite(p_interaccion_id uuid, p_tipo text default 'agendar_estudio')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int     core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_tramite core.tramites;
begin
  if v_int.nivel_verificacion = 'declarada' then
    raise exception 'Verifica la identidad antes de operar el trámite' using errcode = '42501';
  end if;

  select * into v_tramite from core.tramites
  where paciente_id = v_int.paciente_id and tipo = p_tipo and estado in ('activo', 'pausado') and eliminado_en is null
  for update;

  if found then
    update core.tramites set estado = 'activo', ultimo_canal = v_int.canal, ultima_actividad_en = now(),
                             expira_en = now() + interval '72 hours'
    where paciente_id = v_tramite.paciente_id and id = v_tramite.id
    returning * into v_tramite;
    perform core.registrar_evento(v_int.paciente_id, v_tramite.id, v_int.id, 'tramite_retomado',
                                  jsonb_build_object('paso_actual', v_tramite.paso_actual));
  else
    insert into core.tramites (paciente_id, tipo, paso_actual, canal_origen, ultimo_canal)
    values (v_int.paciente_id, p_tipo,
            (select paso from core.flujo_tramite where tipo_tramite = p_tipo and orden = 1),
            v_int.canal, v_int.canal)
    returning * into v_tramite;
    if v_tramite.paso_actual is null then
      raise exception 'Tipo de trámite desconocido: %', p_tipo using errcode = '22023';
    end if;
    perform core.registrar_evento(v_int.paciente_id, v_tramite.id, v_int.id, 'tramite_iniciado',
                                  jsonb_build_object('tipo', p_tipo));
  end if;

  update core.interacciones set tramite_id = v_tramite.id
  where paciente_id = v_int.paciente_id and id = v_int.id and tramite_id is distinct from v_tramite.id;
  return core.tramite_json(v_tramite);
end
$$;

-- Carga y bloquea un trámite de la sesión, validando versión (bloqueo optimista)
create or replace function core.bloquear_tramite(p_int core.interacciones, p_tramite_id uuid, p_version int)
returns core.tramites
language plpgsql
set search_path = ''
as $$
declare
  v core.tramites;
begin
  if p_int.nivel_verificacion = 'declarada' then
    raise exception 'Verifica la identidad antes de operar el trámite' using errcode = '42501';
  end if;
  select * into v from core.tramites
  where paciente_id = p_int.paciente_id and id = p_tramite_id and eliminado_en is null
  for update;
  if not found then
    raise exception 'Trámite no encontrado' using errcode = 'P0002';
  end if;
  if v.estado not in ('activo', 'pausado') then
    raise exception 'El trámite está %', v.estado using errcode = 'P0001';
  end if;
  if v.version <> p_version then
    raise sqlstate 'PT409' using message = 'conflicto_de_version',
      detail = jsonb_build_object('version_actual', v.version, 'paso_actual', v.paso_actual)::text,
      hint = 'Otro canal actualizó el trámite; vuelve a leer el contexto';
  end if;
  return v;
end
$$;

-- Avanza (o regresa) de paso y guarda datos capturados.
-- cita_id y pago_id no se aceptan aquí: solo los fijan reservar_cita y confirmar_pago.
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

-- Aparta un horario respetando el cupo de la clínica y mueve el trámite a "pago"
create or replace function api.reservar_cita(
  p_interaccion_id uuid, p_tramite_id uuid, p_version int, p_fecha_hora timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int     core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_tramite core.tramites;
  v_ce      core.clinica_estudios;
  v_clinica uuid;
  v_estudio uuid;
  v_precio  numeric;
  v_cita    uuid;
  v_ocupados int;
begin
  v_tramite := core.bloquear_tramite(v_int, p_tramite_id, p_version);
  if v_tramite.paso_actual not in ('seleccion_horario', 'pago') then
    raise exception 'El trámite debe estar en selección de horario' using errcode = 'P0001';
  end if;
  if p_fecha_hora <= now() + interval '1 hour' then
    raise exception 'El horario debe ser al menos una hora en el futuro' using errcode = '22023';
  end if;

  v_clinica := (v_tramite.contexto ->> 'clinica_id')::uuid;
  v_estudio := (v_tramite.contexto ->> 'estudio_id')::uuid;
  select * into v_ce from core.clinica_estudios
  where clinica_id = v_clinica and estudio_id = v_estudio and activo and eliminado_en is null;
  if not found then
    raise exception 'La clínica no ofrece ese estudio' using errcode = '22023';
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
  insert into core.citas (paciente_id, tramite_id, clinica_id, estudio_id, fecha_hora, precio)
  values (v_tramite.paciente_id, v_tramite.id, v_clinica, v_estudio, p_fecha_hora, v_precio)
  returning id into v_cita;

  update core.tramites
  set contexto = contexto || jsonb_build_object('cita_id', v_cita, 'fecha_hora', p_fecha_hora, 'precio', v_precio),
      paso_actual = 'pago', version = version + 1, ultimo_canal = v_int.canal,
      ultima_actividad_en = now(), expira_en = now() + interval '72 hours', recordatorio_enviado_en = null
  where paciente_id = v_tramite.paciente_id and id = v_tramite.id
  returning * into v_tramite;

  perform core.registrar_evento(v_int.paciente_id, v_tramite.id, v_int.id, 'cita_reservada',
    jsonb_build_object('cita_id', v_cita, 'clinica_id', v_clinica, 'estudio_id', v_estudio,
                       'fecha_hora', p_fecha_hora, 'precio', v_precio));
  return core.tramite_json(v_tramite);
end
$$;

-- Genera (o reutiliza) el link de pago de la cita del trámite
create or replace function api.generar_pago(p_interaccion_id uuid, p_tramite_id uuid, p_version int)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int     core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_tramite core.tramites;
  v_pago    core.pagos;
  v_cita    core.citas;
  v_ref     text;
begin
  v_tramite := core.bloquear_tramite(v_int, p_tramite_id, p_version);
  if v_tramite.paso_actual <> 'pago' then
    raise exception 'El trámite no está en el paso de pago' using errcode = 'P0001';
  end if;
  select * into v_cita from core.citas
  where paciente_id = v_tramite.paciente_id and id = (v_tramite.contexto ->> 'cita_id')::uuid;

  select * into v_pago from core.pagos
  where paciente_id = v_cita.paciente_id and cita_id = v_cita.id and estado = 'pendiente' and expira_en > now()
  order by creado_en desc limit 1;

  if not found then
    v_ref := 'SD-' || upper(encode(extensions.gen_random_bytes(6), 'hex'));
    insert into core.pagos (paciente_id, cita_id, monto, referencia_externa, link_pago, expira_en)
    values (v_cita.paciente_id, v_cita.id, v_cita.precio, v_ref,
            'https://pagos.ejemplo.mx/checkout/' || v_ref,  -- la Edge Function de pagos lo sustituye por el del proveedor
            least(now() + interval '24 hours', v_cita.fecha_hora - interval '1 hour'))
    returning * into v_pago;
    perform core.registrar_evento(v_int.paciente_id, v_tramite.id, v_int.id, 'pago_generado',
      jsonb_build_object('pago_id', v_pago.id, 'monto', v_pago.monto, 'referencia', v_ref));
  end if;

  update core.tramites
  set contexto = contexto || jsonb_build_object('pago_id', v_pago.id),
      version = version + 1, ultimo_canal = v_int.canal, ultima_actividad_en = now()
  where paciente_id = v_tramite.paciente_id and id = v_tramite.id;

  return jsonb_build_object('pago_id', v_pago.id, 'monto', v_pago.monto, 'moneda', v_pago.moneda,
                            'link_pago', v_pago.link_pago, 'expira_en', v_pago.expira_en,
                            'version', v_tramite.version + 1);
end
$$;

-- Webhook del proveedor de pagos (solo servicio). Idempotente por referencia.
create or replace function api.confirmar_pago(p_referencia text, p_estado text, p_datos jsonb default '{}')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
    raise exception 'Pago no encontrado' using errcode = 'P0002';
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

  update core.citas set estado = 'confirmada' where paciente_id = v_cita.paciente_id and id = v_cita.id;
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
$$;

-- ---------------------------------------------------------------------
-- Conversación y cierre de sesión
-- ---------------------------------------------------------------------
create or replace function api.registrar_mensaje(
  p_interaccion_id uuid, p_direccion text, p_autor text, p_contenido text, p_metadatos jsonb default '{}')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_id  uuid;
begin
  if core.rol_actual() = 'paciente' and (p_autor <> 'paciente' or p_direccion <> 'entrante') then
    raise exception 'Un paciente solo registra sus propios mensajes' using errcode = '42501';
  end if;
  insert into core.mensajes (paciente_id, interaccion_id, canal, direccion, autor, contenido, metadatos)
  values (v_int.paciente_id, v_int.id, v_int.canal, p_direccion, p_autor, p_contenido, coalesce(p_metadatos, '{}'))
  returning id into v_id;
  if v_int.tramite_id is not null then
    update core.tramites set ultima_actividad_en = now(), expira_en = greatest(expira_en, now() + interval '72 hours')
    where paciente_id = v_int.paciente_id and id = v_int.tramite_id and estado in ('activo', 'pausado');
  end if;
  return v_id;
end
$$;

create or replace function api.cerrar_interaccion(p_interaccion_id uuid, p_resultado text default 'finalizada')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int core.interacciones := core.cargar_interaccion(p_interaccion_id);
begin
  update core.interacciones set finalizada_en = now(), resultado = p_resultado
  where paciente_id = v_int.paciente_id and id = v_int.id;
  perform core.registrar_evento(v_int.paciente_id, v_int.tramite_id, v_int.id, 'interaccion_finalizada',
    jsonb_build_object('resultado', p_resultado,
                       'duracion_seg', extract(epoch from now() - v_int.iniciada_en)::int));
end
$$;

-- ---------------------------------------------------------------------
-- Personal y panel administrativo
-- ---------------------------------------------------------------------
create or replace function core.validar_alcance_clinica(p_clinica_id uuid)
returns void
language plpgsql stable
set search_path = ''
as $$
declare
  v_clinica uuid := nullif(auth.jwt() -> 'app_metadata' ->> 'clinica_id', '')::uuid;
begin
  if core.rol_actual() <> 'admin' and v_clinica is not null and v_clinica <> p_clinica_id then
    raise exception 'Fuera del alcance de tu clínica' using errcode = '42501';
  end if;
end
$$;

-- Agenda del día de una clínica (lee el modelo de lectura, no las citas de todos)
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
             'paciente', concat_ws(' ', p.nombre, left(p.apellido_paterno, 1) || '.'))
           order by a.fecha_hora), '[]')
    from core.agenda_clinica a
    join core.estudios e on e.id = a.estudio_id
    join core.pacientes p on p.id = a.paciente_id
    where a.clinica_id = p_clinica_id
      and a.fecha_hora >= (p_fecha::timestamp at time zone v_zona)
      and a.fecha_hora <  ((p_fecha + 1)::timestamp at time zone v_zona));
end
$$;

-- Trámites abiertos para el tablero del panel (paginado por actividad)
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
        'paciente', concat_ws(' ', p.nombre, left(p.apellido_paterno, 1) || '.'),
        'tipo', t.tipo, 'paso_actual', t.paso_actual, 'estado', t.estado,
        'canal_origen', t.canal_origen, 'ultimo_canal', t.ultimo_canal,
        'clinica', c.nombre, 'ultima_actividad_en', t.ultima_actividad_en,
        'minutos_inactivo', (extract(epoch from now() - t.ultima_actividad_en) / 60)::int,
        'resumen', t.resumen) as x
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

-- Patient journey completo de un paciente (queda registrado como lectura)
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
                   'nombre', concat_ws(' ', p.nombre, p.apellido_paterno, p.apellido_materno))
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
