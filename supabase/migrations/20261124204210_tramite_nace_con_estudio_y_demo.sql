-- =====================================================================
-- El trámite nace con estudio + herramientas de demo
--   · api.iniciar_tramite exige el estudio (y opcionalmente para quién): el
--     trámite nace en seleccion_clinica y la regla de duplicados aplica
--     desde el inicio. Ya no se crean trámites vacíos.
--   · Red de seguridad para los que ya existan sin estudio: no aparecen en
--     "Tienes pendiente" y pg_cron los cancela a las 24 h (motivo 'sin_estudio').
--   · Esquema simulador (solo pruebas, protegido por su interruptor):
--     reiniciar_demo() y forzar_recordatorio(folio).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. iniciar_tramite(interaccion, estudio, beneficiario)
-- ---------------------------------------------------------------------
drop function api.iniciar_tramite(uuid, text);

create function api.iniciar_tramite(
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
begin
  if v_int.nivel_verificacion = 'declarada' then
    raise exception 'Verifica la identidad antes de operar el trámite' using errcode = '42501';
  end if;
  if v_int.canal in ('web', 'app') and v_int.nivel_verificacion <> 'verificada' then
    raise exception 'Verifica tu celular con el código (OTP) para iniciar un trámite' using errcode = '42501';
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
revoke execute on function api.iniciar_tramite(uuid, uuid, uuid, text) from public, anon;
grant execute on function api.iniciar_tramite(uuid, uuid, uuid, text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. Los trámites sin estudio no se ofrecen en "Tienes pendiente"
-- ---------------------------------------------------------------------
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
                                 'requiere_verificacion', false),
    'paciente', jsonb_build_object(
      'id', v_pac.id,
      'estado', v_pac.estado,
      'nombre', case when v_nivel = 2 then concat_ws(' ', v_pac.nombre, v_pac.apellido_paterno, v_pac.apellido_materno)
                     else v_pac.nombre end,
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

-- pg_cron: los que sigan sin estudio a las 24 h se cancelan
create or replace function core.cancelar_tramites_sin_estudio()
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
    update core.tramites set estado = 'cancelado', finalizado_en = now(),
                             atendido_por_interaccion = null, atencion_hasta = null
    where estado in ('activo', 'pausado') and eliminado_en is null
      and not (contexto ? 'estudio_id') and creado_en < now() - interval '24 hours'
    returning paciente_id, id, folio
  loop
    perform core.registrar_evento(r.paciente_id, r.id, null, 'tramite_cancelado',
                                  jsonb_build_object('motivo', 'sin_estudio', 'folio', r.folio));
    n := n + 1;
  end loop;
  return n;
end
$$;
revoke execute on function core.cancelar_tramites_sin_estudio() from public, anon, authenticated, service_role;
select cron.schedule('sd-cancelar-sin-estudio', '23 * * * *', $$select core.cancelar_tramites_sin_estudio()$$);

-- ---------------------------------------------------------------------
-- 3. ⚠️ SOLO PRUEBAS: herramientas de demo en el esquema simulador
--    (apagadas fuera de local por simulador.config.habilitado)
-- ---------------------------------------------------------------------
alter table simulador.config add column telefonos_prueba text[] not null
  default '{+528661234567,+528661234568,+528661234569,+528661234570,+528661234571}';


-- Los triggers de protección dejan pasar el reinicio de la demo SOLO con la marca
-- app.operacion = 'reinicio_demo' y el simulador encendido. En producción el
-- interruptor está apagado: la marca no abre nada. (Ninguna API deja fijar la marca.)
create or replace function simulador.reinicio_permitido()
returns boolean
language plpgsql stable
set search_path = ''
as $$
begin
  return current_setting('app.operacion', true) = 'reinicio_demo'
     and coalesce((select habilitado from simulador.config), false);
end
$$;
revoke execute on function simulador.reinicio_permitido() from public, anon, authenticated, service_role;

create or replace function core.trg_bloquear_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_setting('app.operacion', true) = 'reinicio_demo' then
    if simulador.reinicio_permitido() then return old; end if;
  end if;
  raise exception 'Borrado físico no permitido en %.%: usa borrado lógico (eliminado_en)',
    tg_table_schema, tg_table_name using errcode = '42501';
end
$$;

create or replace function core.trg_solo_insercion()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if current_setting('app.operacion', true) = 'fusion' then
      return new;
    end if;
    -- (tg_table_name es el de la partición, p. ej. mensajes_202611: se valida por columnas)
    if current_setting('app.operacion', true) = 'cifrado' and to_jsonb(new) ? 'contenido_cifrado'
       and (to_jsonb(new) - 'contenido_cifrado' - 'clave_version') = (to_jsonb(old) - 'contenido_cifrado' - 'clave_version') then
      return new;
    end if;
  end if;
  if tg_op = 'DELETE' and current_setting('app.operacion', true) = 'reinicio_demo' then
    if simulador.reinicio_permitido() then return old; end if;
  end if;
  raise exception '%.% solo admite inserciones', tg_table_schema, tg_table_name using errcode = '42501';
end
$$;

create or replace function audit.trg_inmutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and current_setting('app.operacion', true) = 'reinicio_demo' then
    if simulador.reinicio_permitido() then return old; end if;
  end if;
  raise exception 'La bitácora de auditoría es inmutable' using errcode = '42501';
end
$$;

create or replace function audit.trg_registrar()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_antes   jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_despues jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_fila    jsonb := coalesce(v_despues, v_antes);
  v_campos  text[];
  v_accion  text  := tg_op;
  v_ignorar text[] := array['actualizado_en', 'actualizado_por', 'resumen_pendiente',
                            'ultima_actividad_en', 'expira_en', 'recordatorio_enviado_en', 'atencion_hasta'];
begin
  -- Re-cifrar no es un cambio de negocio; el reinicio de la demo tampoco se registra
  if current_setting('app.operacion', true) in ('cifrado', 'reinicio_demo') then
    return null;
  end if;

  if tg_op = 'UPDATE' then
    select array_agg(k order by k) into v_campos
    from jsonb_object_keys(v_despues) as k
    where not k = any (v_ignorar)
      and (v_antes -> k) is distinct from (v_despues -> k);
    if v_campos is null then
      return null;  -- solo cambiaron columnas operativas
    end if;
    if (v_antes ->> 'eliminado_en') is null and (v_despues ->> 'eliminado_en') is not null then
      v_accion := 'BORRADO_LOGICO';
    end if;
  end if;

  if v_antes is not null then
    select jsonb_object_agg(key, case when key like '%\_cifrado' and value <> 'null' then to_jsonb('[cifrado]'::text) else value end)
    into v_antes from jsonb_each(v_antes);
  end if;
  if v_despues is not null then
    select jsonb_object_agg(key, case when key like '%\_cifrado' and value <> 'null' then to_jsonb('[cifrado]'::text) else value end)
    into v_despues from jsonb_each(v_despues);
  end if;

  insert into audit.registro (tabla, registro_id, paciente_id, accion, antes, despues,
                              campos_cambiados, actor_id, actor_tipo, canal, ip)
  values (
    tg_table_schema || '.' || tg_table_name,
    coalesce(v_fila ->> 'id',
             (v_fila ->> 'tipo') || ':' || (v_fila ->> 'valor'),
             (v_fila ->> 'clinica_id') || ':' || (v_fila ->> 'estudio_id'),
             (v_fila ->> 'titular_id') || ':' || (v_fila ->> 'beneficiario_id'),
             (v_fila ->> 'clinica_id') || ':' || (v_fila ->> 'dia_semana'),
             v_fila ->> 'nombre'),
    case when tg_table_name = 'pacientes' then (v_fila ->> 'id')::uuid
         else coalesce(v_fila ->> 'paciente_id', v_fila ->> 'titular_id')::uuid end,
    v_accion, v_antes, v_despues, v_campos,
    core.actor_id(), core.actor_tipo(), core.canal_actual(), core.ip_actual()
  );
  return null;
end
$$;

-- Borra TODO lo de los pacientes de los teléfonos de prueba (y sus familiares,
-- cuentas de Auth y bandeja) para repetir las demos. Solo esos teléfonos.
create or replace function simulador.reiniciar_demo()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_tels  text[];
  v_pac   uuid[];
  v_todos uuid[];
  v_uids  uuid[];
  v_n     int;
begin
  perform simulador.exigir_habilitado();
  select telefonos_prueba into v_tels from simulador.config;

  select coalesce(array_agg(distinct paciente_id), '{}') into v_pac
  from core.identidades_paciente where tipo = 'telefono' and valor = any (v_tels);
  -- registros fusionados en ellos y sus familiares declarados
  v_todos := v_pac
    || coalesce((select array_agg(id) from core.pacientes where fusionado_en = any (v_pac)), '{}')
    || coalesce((select array_agg(beneficiario_id) from core.relaciones_paciente where titular_id = any (v_pac)), '{}');
  select coalesce(array_agg(valor::uuid), '{}') into v_uids
  from core.identidades_paciente where tipo = 'auth_uid' and paciente_id = any (v_todos);

  -- El borrado físico y la bitácora inmutable están prohibidos por diseño; los triggers
  -- lo permiten solo con esta marca Y el simulador encendido (ver más abajo).
  perform set_config('app.operacion', 'reinicio_demo', true);
  delete from core.agenda_clinica          where paciente_id = any (v_todos) or beneficiario_id = any (v_todos);
  delete from core.pagos                   where paciente_id = any (v_todos);
  delete from core.citas                   where paciente_id = any (v_todos) or beneficiario_id = any (v_todos);
  delete from core.eventos_tramite         where paciente_id = any (v_todos);
  delete from core.mensajes                where paciente_id = any (v_todos);
  delete from core.otp                     where paciente_id = any (v_todos);
  delete from core.consentimientos_avisos  where paciente_id = any (v_todos);
  delete from core.interacciones           where paciente_id = any (v_todos);
  delete from core.idempotencia            where paciente_id = any (v_todos);
  delete from core.tramites                where paciente_id = any (v_todos);
  delete from core.relaciones_paciente     where titular_id = any (v_todos) or beneficiario_id = any (v_todos);
  delete from core.identidades_paciente    where paciente_id = any (v_todos);
  delete from core.paciente_fusiones       where paciente_origen = any (v_todos) or paciente_destino = any (v_todos);
  delete from core.pacientes               where id = any (v_todos);
  get diagnostics v_n = row_count;
  delete from audit.registro               where paciente_id = any (v_todos);
  delete from pgmq.q_avisos_whatsapp  where message ->> 'paciente_id' = any (v_todos::text[]);
  delete from pgmq.q_resumen_tramite  where message ->> 'paciente_id' = any (v_todos::text[]);
  delete from pgmq.q_recordatorios    where message ->> 'paciente_id' = any (v_todos::text[]);
  delete from core.rate_limit where clave = any (select 'api:tel:' || t from unnest(v_tels) t);
  delete from simulador.bandeja where telefono = any (v_tels);
  delete from auth.users where id = any (v_uids) or phone = any (select ltrim(t, '+') from unnest(v_tels) t);
  perform set_config('app.operacion', '', true);

  return jsonb_build_object('pacientes_borrados', v_n, 'telefonos', v_tels);
end
$$;

-- Demo del recordatorio: deja el trámite como inactivo hace 3 h y corre el
-- programador de recordatorios (lo que pg_cron haría cada 5 min).
create or replace function simulador.forzar_recordatorio(p_folio text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  t core.tramites;
begin
  perform simulador.exigir_habilitado();
  select * into t from core.tramites where folio = upper(btrim(p_folio));
  if not found then
    raise exception 'Trámite no encontrado' using errcode = 'PT404';
  end if;
  if not exists (select 1 from core.identidades_paciente i, simulador.config c
                 where i.paciente_id = t.paciente_id and i.tipo = 'telefono' and i.valor = any (c.telefonos_prueba)) then
    raise exception 'Solo trámites de los teléfonos de prueba' using errcode = '42501';
  end if;
  update core.tramites set ultima_actividad_en = now() - interval '3 hours', recordatorio_enviado_en = null,
                           estado = 'activo'
  where paciente_id = t.paciente_id and id = t.id;
  return jsonb_build_object('folio', t.folio, 'recordatorios_programados', core.programar_recordatorios());
end
$$;

revoke execute on function simulador.reiniciar_demo(), simulador.forzar_recordatorio(text) from public;
grant execute on function simulador.reiniciar_demo(), simulador.forzar_recordatorio(text) to anon, authenticated, service_role;
