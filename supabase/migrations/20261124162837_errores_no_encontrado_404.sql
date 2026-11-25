-- =====================================================================
-- "No existe" responde HTTP 404
--   Se usaba P0002 (no_data_found), pero PostgREST solo traduce P0001 a
--   400; cualquier otro P0xxx llega como HTTP 500, como si fuera un error
--   del servidor. Los códigos PTxxx son el mecanismo de PostgREST para fijar
--   el estado HTTP: PT404 → 404, igual que PT409 y PT429.
--   Cambio único en estas funciones: errcode 'P0002' → 'PT404'.
--   (Definiciones tomadas de la base después de la migración 151929.)
-- =====================================================================

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
$function$
;

CREATE OR REPLACE FUNCTION api.generar_codigo_continuidad(p_interaccion_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    raise exception 'No hay un trámite abierto para continuar' using errcode = 'PT404';
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
$function$
;

CREATE OR REPLACE FUNCTION api.guardar_resumen(p_tramite_id uuid, p_resumen text, p_leido_en timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_paciente uuid;
  v_version  smallint := core.version_cifrado_activa();
begin
  perform core.exigir_rol('servicio');
  perform core.establecer_actor('sistema', 'agente_ia');

  update core.tramites
  set resumen_cifrado = core.cifrar(p_resumen, v_version),
      resumen_clave_version = case when p_resumen is null then null else v_version end,
      resumen_actualizado_en = p_leido_en, resumen_pendiente = false
  where id = p_tramite_id
  returning paciente_id into v_paciente;
  if v_paciente is null then
    raise exception 'Trámite no encontrado' using errcode = 'PT404';
  end if;

  perform core.registrar_evento(v_paciente, p_tramite_id, null, 'resumen_actualizado', '{}');

  if exists (select 1 from core.eventos_tramite ev
             join core.catalogo_eventos c on c.tipo_evento = ev.tipo_evento and c.dispara_resumen
             where ev.paciente_id = v_paciente and ev.tramite_id = p_tramite_id and ev.ocurrido_en > p_leido_en) then
    perform core.solicitar_resumen(p_tramite_id);
  end if;
end
$function$
;

CREATE OR REPLACE FUNCTION api.material_resumen(p_tramite_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  t       core.tramites;
  v_desde timestamptz;
begin
  perform core.exigir_rol('servicio');
  select * into t from core.tramites where id = p_tramite_id;
  if not found then
    raise exception 'Trámite no encontrado' using errcode = 'PT404';
  end if;
  v_desde := coalesce(t.resumen_actualizado_en, '-infinity'::timestamptz);

  return jsonb_build_object(
    'leido_en', now(),
    'tramite', core.tramite_json(t),
    'resumen_anterior', core.descifrar(t.resumen_cifrado, t.resumen_clave_version),
    'eventos_nuevos', (
      select coalesce(jsonb_agg(jsonb_build_object('ocurrido_en', ev.ocurrido_en, 'tipo_evento', ev.tipo_evento,
                                                   'canal', ev.canal, 'actor_tipo', ev.actor_tipo, 'payload', ev.payload)
                                order by ev.ocurrido_en), '[]')
      from core.eventos_tramite ev
      where ev.paciente_id = t.paciente_id and ev.tramite_id = t.id and ev.ocurrido_en > v_desde
        and ev.tipo_evento not in ('asesor_consulto_contexto', 'resumen_actualizado')),
    'mensajes_nuevos', (
      select coalesce(jsonb_agg(jsonb_build_object('creado_en', s.creado_en, 'canal', s.canal, 'autor', s.autor,
                                                   'contenido', core.descifrar(s.contenido_cifrado, s.clave_version))
                                order by s.creado_en), '[]')
      from (select m.creado_en, m.canal, m.autor, m.contenido_cifrado, m.clave_version
            from core.mensajes m
            join core.interacciones i on i.paciente_id = m.paciente_id and i.id = m.interaccion_id
            where m.paciente_id = t.paciente_id and i.tramite_id = t.id and m.creado_en > v_desde
            order by m.creado_en desc limit 100) s));
end
$function$
;

CREATE OR REPLACE FUNCTION api.verificar_presencial(p_cita_id uuid, p_tipo_documento text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    raise exception 'Cita no encontrada' using errcode = 'PT404';
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
$function$
;

CREATE OR REPLACE FUNCTION core.bloquear_tramite(p_int core.interacciones, p_tramite_id uuid, p_version integer)
 RETURNS core.tramites
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
    raise exception 'Trámite no encontrado' using errcode = 'PT404';
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
$function$
;

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
$function$
;
