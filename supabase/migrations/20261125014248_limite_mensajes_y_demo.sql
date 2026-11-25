-- =====================================================================
-- Límite por mensajes y utilidad de demo
--   · WhatsApp: máximo 10 mensajes entrantes por minuto por teléfono (PT429 demasiados_mensajes),
--     contados en api.registrar_mensaje. Las peticiones de las Edge Functions por teléfono
--     (x-sd-telefono) suben a 300/min: ya no son el límite, solo una red de seguridad.
--   · simulador.adelantar_cita(folio): solo teléfonos de prueba y con el simulador encendido;
--     pone la cita del trámite en este momento para mostrar la llegada a la clínica a cualquier hora.
--   · simulador.reiniciar_demo también limpia los contadores de mensajes.
-- =====================================================================

-- Teléfono con el que se cuenta el límite: el del header de la Edge Function o el de mayor confianza
create or replace function core.telefono_de_interaccion(p_int core.interacciones)
returns text
language plpgsql stable
set search_path = ''
as $$
declare
  v_tel text := nullif(btrim(coalesce(nullif(current_setting('request.headers', true), ''), '{}')::json ->> 'x-sd-telefono'), '');
begin
  if v_tel is not null then
    begin
      return core.normalizar_identidad('telefono', v_tel);
    exception when others then
      null;
    end;
  end if;
  return coalesce((select i.valor from core.identidades_paciente i
                   where i.paciente_id = p_int.paciente_id and i.tipo = 'telefono' and i.eliminado_en is null
                   order by core.rango_nivel(i.nivel_confianza) desc limit 1),
                  p_int.paciente_id::text);
end
$$;
revoke execute on function core.telefono_de_interaccion(core.interacciones) from public, anon, authenticated, service_role;

create or replace function core.verificar_peticion()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rol    text := core.rol_actual();
  v_tel    text;
  v_clave  text;
  v_limite int;
begin
  if current_setting('transaction_read_only', true) = 'on' then
    raise sqlstate 'PT405' using message = 'Usa POST', hint = 'Todas las funciones de la API se llaman con POST';
  end if;

  if v_rol = 'servicio' then
    v_tel := nullif(btrim(coalesce(nullif(current_setting('request.headers', true), ''), '{}')::json ->> 'x-sd-telefono'), '');
    if v_tel is null then
      return;  -- tareas internas: exentas
    end if;
    begin
      v_tel := core.normalizar_identidad('telefono', v_tel);
    exception when others then
      raise exception 'Header x-sd-telefono inválido' using errcode = '22023';
    end;
    v_clave  := 'tel:' || v_tel;
    v_limite := 300;   -- red de seguridad contra bucles, el límite real es por mensaje (api.registrar_mensaje)
  else
    v_clave  := coalesce(auth.uid()::text, 'ip:' || core.ip_actual(), 'desconocido');
    v_limite := case v_rol when 'anonimo' then 30 when 'paciente' then 120 else 600 end;
  end if;

  if not core.consumir_limite('api:' || v_clave, v_limite, 60) then
    raise sqlstate 'PT429' using message = 'Demasiadas solicitudes', hint = 'Intenta de nuevo en un minuto';
  end if;
end
$$;

create or replace function api.registrar_mensaje(
  p_interaccion_id uuid, p_direccion text, p_autor text, p_contenido text, p_metadatos jsonb default '{}')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int     core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_version smallint := core.version_cifrado_activa();
  v_id      uuid;
begin
  if core.rol_actual() = 'paciente' and (p_autor <> 'paciente' or p_direccion <> 'entrante') then
    raise exception 'Un paciente solo registra sus propios mensajes' using errcode = '42501';
  end if;
  if p_contenido is null or btrim(p_contenido) = '' then
    raise exception 'El mensaje está vacío' using errcode = '22023';
  end if;
  -- Máximo 10 mensajes entrantes de WhatsApp por minuto por teléfono
  if v_int.canal = 'whatsapp' and p_direccion = 'entrante'
     and not core.consumir_limite('msg:tel:' || core.telefono_de_interaccion(v_int), 10, 60) then
    raise sqlstate 'PT429' using message = 'demasiados_mensajes',
      hint = 'Máximo 10 mensajes por minuto: espera un momento';
  end if;
  insert into core.mensajes (paciente_id, interaccion_id, canal, direccion, autor, contenido_cifrado, clave_version, metadatos)
  values (v_int.paciente_id, v_int.id, v_int.canal, p_direccion, p_autor,
          core.cifrar(p_contenido, v_version), v_version, coalesce(p_metadatos, '{}'))
  returning id into v_id;
  if v_int.tramite_id is not null then
    update core.tramites set ultima_actividad_en = now(), expira_en = greatest(expira_en, now() + interval '72 hours')
    where paciente_id = v_int.paciente_id and id = v_int.tramite_id and estado in ('activo', 'pausado');
  end if;
  return v_id;
end
$$;

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
  delete from core.rate_limit where clave = any (select 'api:tel:' || t from unnest(v_tels) t)
                                 or clave = any (select 'msg:tel:' || t from unnest(v_tels) t);
  delete from simulador.bandeja where telefono = any (v_tels);
  delete from auth.users where id = any (v_uids) or phone = any (select ltrim(t, '+') from unnest(v_tels) t);
  perform set_config('app.operacion', '', true);

  return jsonb_build_object('pacientes_borrados', v_n, 'telefonos', v_tels);
end
$$;

create or replace function simulador.adelantar_cita(p_folio text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  t core.tramites;
  c core.citas;
begin
  perform simulador.exigir_habilitado();
  select * into t from core.tramites where folio = upper(btrim(p_folio));
  if not found then
    raise exception 'Trámite no encontrado' using errcode = 'PT404';
  end if;
  if not exists (select 1 from core.identidades_paciente i, simulador.config cf
                 where i.paciente_id = t.paciente_id and i.tipo = 'telefono' and i.valor = any (cf.telefonos_prueba)) then
    raise exception 'Solo trámites de los teléfonos de prueba' using errcode = '42501';
  end if;
  select * into c from core.citas
  where paciente_id = t.paciente_id and tramite_id = t.id and estado in ('reservada', 'confirmada') and eliminado_en is null
  order by creado_en desc limit 1;
  if not found then
    raise exception 'El trámite no tiene una cita apartada' using errcode = 'P0001';
  end if;
  update core.citas set fecha_hora = now() where paciente_id = c.paciente_id and id = c.id;
  update core.tramites set contexto = contexto || jsonb_build_object('fecha_hora', now())
  where paciente_id = t.paciente_id and id = t.id;
  return jsonb_build_object('folio', t.folio, 'cita_id', c.id, 'fecha_hora', now());
end
$$;
revoke execute on function simulador.adelantar_cita(text) from public;
grant execute on function simulador.adelantar_cita(text) to anon, authenticated, service_role;
