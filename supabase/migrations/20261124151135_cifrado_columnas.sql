-- =====================================================================
-- Etapa 3 · Cifrado a nivel columna
--   El texto libre que puede traer datos de salud (mensajes de la
--   conversación y resumen del trámite hecho por la IA) nunca queda legible
--   en la tabla, en exportaciones (pg_dump, réplicas, respaldos) ni en la
--   bitácora. Solo lo descifran las funciones api que lo devuelven a quien
--   ya está autorizado (contexto, material para la IA, panel).
--
-- Llaves: Supabase Vault, secretos 'clave_cifrado_v1', 'clave_cifrado_v2', …
--   Nunca en el repositorio. En local las crea supabase/seed.sql con un
--   valor aleatorio; en producción se crean a mano (ver README).
--
-- RAG y antispam: los embeddings se calculan ANTES de cifrar, en la Edge
--   Function que recibe el mensaje, porque sobre texto cifrado no se puede
--   buscar ni clasificar. La base solo recibe el vector (kb_fragmentos es
--   conocimiento público de Salud Digna, no datos de pacientes, y no se cifra).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1–2. Configuración y funciones de cifrado (solo core, sin grants)
-- ---------------------------------------------------------------------
create table core.config_cifrado (
  id                    boolean primary key default true check (id),  -- fila única
  version_activa        smallint not null check (version_activa > 0),
  rotacion_pendiente    boolean not null default false,
  rotacion_iniciada_en  timestamptz,
  actualizado_en        timestamptz not null default now()
);
insert into core.config_cifrado (version_activa) values (1);
alter table core.config_cifrado enable row level security;
revoke all on core.config_cifrado from public, anon, authenticated, service_role;

create or replace function core.version_cifrado_activa()
returns smallint
language sql stable
set search_path = ''
as $$
  select version_activa from core.config_cifrado
$$;

-- Lee la llave de Vault. Si falta, error claro (nunca texto vacío ni nulo).
-- XX000 → HTTP 500: es un error de configuración del servidor, no del cliente.
create or replace function core.clave_cifrado(p_version smallint)
returns text
language plpgsql stable
set search_path = ''
as $$
declare
  v_clave text;
begin
  select decrypted_secret into v_clave from vault.decrypted_secrets
  where name = 'clave_cifrado_v' || p_version;
  if v_clave is null or v_clave = '' then
    raise exception 'Falta la llave de cifrado clave_cifrado_v% en Supabase Vault', p_version
      using errcode = 'XX000', hint = 'Créala con vault.create_secret (ver README)';
  end if;
  return v_clave;
end
$$;

-- AES-256. s2k-mode=1 (sin miles de rondas de derivación): la llave ya es
-- de 32 bytes aleatorios, así que estirarla no agrega seguridad y cuesta
-- ~1 ms por operación (75 veces más lento).
-- p_version: quien guarda el dato debe guardar también la versión usada;
-- por eso la lee una vez y la pasa aquí. Sin ella usa la activa.
create or replace function core.cifrar(p_texto text, p_version smallint default null)
returns bytea
language plpgsql volatile
set search_path = ''
as $$
begin
  if p_texto is null then
    return null;
  end if;
  return extensions.pgp_sym_encrypt(p_texto,
                                    core.clave_cifrado(coalesce(p_version, core.version_cifrado_activa())),
                                    'cipher-algo=aes256, s2k-mode=1, s2k-digest-algo=sha256');
end
$$;

create or replace function core.descifrar(p_dato bytea, p_version smallint)
returns text
language plpgsql stable
set search_path = ''
as $$
begin
  if p_dato is null then
    return null;
  end if;
  return extensions.pgp_sym_decrypt(p_dato, core.clave_cifrado(p_version));
end
$$;

revoke execute on function
  core.version_cifrado_activa(), core.clave_cifrado(smallint),
  core.cifrar(text, smallint), core.descifrar(bytea, smallint)
from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- Mensajes y eventos son de solo inserción. Excepciones controladas:
--   · fusion  : mover filas a otro paciente
--   · cifrado : re-cifrar un mensaje (solo cambian contenido_cifrado y clave_version)
-- ---------------------------------------------------------------------
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
  raise exception '%.% solo admite inserciones', tg_table_schema, tg_table_name using errcode = '42501';
end
$$;

-- ---------------------------------------------------------------------
-- 5. Bitácora: nunca texto descifrado ni copias del cifrado
--   Las columnas *_cifrado se registran como "[cifrado]": queda constancia
--   de QUE cambiaron (campos_cambiados), no de su valor. Así la bitácora
--   tampoco depende de las llaves ni hay que re-cifrarla al rotar.
--   La re-cifra por rotación no es un cambio de negocio: no se registra.
-- ---------------------------------------------------------------------
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
                            'ultima_actividad_en', 'expira_en', 'recordatorio_enviado_en'];
begin
  if current_setting('app.operacion', true) = 'cifrado' then
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
             (v_fila ->> 'titular_id') || ':' || (v_fila ->> 'beneficiario_id')),
    case when tg_table_name = 'pacientes' then (v_fila ->> 'id')::uuid
         else coalesce(v_fila ->> 'paciente_id', v_fila ->> 'titular_id')::uuid end,
    v_accion, v_antes, v_despues, v_campos,
    core.actor_id(), core.actor_tipo(), core.canal_actual(), core.ip_actual()
  );
  return null;
end
$$;

-- ---------------------------------------------------------------------
-- 3. Columnas cifradas + migración de datos existentes
--   Si ya hay datos y falta la llave v1 en Vault, la migración falla con
--   el error de core.clave_cifrado (crea la llave antes del db push).
-- ---------------------------------------------------------------------
alter table core.mensajes
  add column contenido_cifrado bytea,
  add column clave_version smallint;

select set_config('app.operacion', 'cifrado', true);
update core.mensajes
set contenido_cifrado = core.cifrar(contenido, 1::smallint), clave_version = 1;
select set_config('app.operacion', '', true);

alter table core.mensajes
  alter column contenido_cifrado set not null,
  alter column clave_version set not null,
  drop column contenido;
create index on core.mensajes (clave_version);

alter table core.tramites
  add column resumen_cifrado bytea,
  add column resumen_clave_version smallint,
  add constraint tramites_resumen_cifrado_check check ((resumen_cifrado is null) = (resumen_clave_version is null));

select set_config('app.operacion', 'cifrado', true);
update core.tramites
set resumen_cifrado = core.cifrar(resumen, 1::smallint), resumen_clave_version = 1
where resumen is not null;
select set_config('app.operacion', '', true);

alter table core.tramites drop column resumen;
create index on core.tramites (resumen_clave_version) where resumen_clave_version is not null;

-- Texto en claro que ya existía fuera de las tablas:
--   · Bitácora: filas de core.tramites con el resumen en antes/despues.
--     Es la ÚNICA modificación a la bitácora inmutable, y solo borra texto
--     de salud; se hace una vez, aquí, con el trigger de inmutabilidad apagado.
--   · Idempotencia: respuestas guardadas de avanzar_tramite con el resumen.
alter table audit.registro disable trigger trg_inmutable;
update audit.registro
set antes   = case when antes   ->> 'resumen' is not null then jsonb_set(antes,   '{resumen}', to_jsonb('[cifrado]'::text)) else antes end,
    despues = case when despues ->> 'resumen' is not null then jsonb_set(despues, '{resumen}', to_jsonb('[cifrado]'::text)) else despues end
where tabla = 'core.tramites' and (antes ->> 'resumen' is not null or despues ->> 'resumen' is not null);
alter table audit.registro enable trigger trg_inmutable;

update core.idempotencia set resultado = resultado - 'resumen' where resultado ? 'resumen';

-- ---------------------------------------------------------------------
-- 4. Funciones que leen o escriben las columnas cifradas
-- ---------------------------------------------------------------------

-- Solo se llama desde funciones api, después de autorizar la sesión
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
    'resumen', core.descifrar(t.resumen_cifrado, t.resumen_clave_version),
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

-- Solo se llama desde funciones api, después de autorizar la sesión
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

-- Material para que la IA actualice el resumen (solo servicio)
create or replace function api.material_resumen(p_tramite_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  t       core.tramites;
  v_desde timestamptz;
begin
  perform core.exigir_rol('servicio');
  select * into t from core.tramites where id = p_tramite_id;
  if not found then
    raise exception 'Trámite no encontrado' using errcode = 'P0002';
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
$$;

create or replace function api.guardar_resumen(p_tramite_id uuid, p_resumen text, p_leido_en timestamptz)
returns void
language plpgsql
security definer
set search_path = ''
as $$
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
    raise exception 'Trámite no encontrado' using errcode = 'P0002';
  end if;

  perform core.registrar_evento(v_paciente, p_tramite_id, null, 'resumen_actualizado', '{}');

  if exists (select 1 from core.eventos_tramite ev
             join core.catalogo_eventos c on c.tipo_evento = ev.tipo_evento and c.dispara_resumen
             where ev.paciente_id = v_paciente and ev.tramite_id = p_tramite_id and ev.ocurrido_en > p_leido_en) then
    perform core.solicitar_resumen(p_tramite_id);
  end if;
end
$$;

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
-- api.journey_paciente no cambia: obtiene el resumen descifrado a través de core.tramite_json.

-- La respuesta guardada para reintentos NO incluye el resumen (sería una
-- copia en claro, permanente). Al repetir, se devuelve con el resumen actual.
-- Además la llave de idempotencia ahora se respeta solo para el mismo
-- paciente: antes, otro paciente con la misma llave recibía esa respuesta.
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
  v_pac_idem uuid;
begin
  if p_clave_idempotencia is not null then
    select resultado, paciente_id into v_res, v_pac_idem from core.idempotencia where clave = p_clave_idempotencia;
    if found then
      if v_pac_idem is distinct from v_int.paciente_id then
        raise sqlstate 'PT409' using message = 'clave_idempotencia_en_uso', hint = 'Usa una llave de idempotencia única';
      end if;
      return v_res || jsonb_build_object('resumen',
        (select core.descifrar(t.resumen_cifrado, t.resumen_clave_version)
         from core.tramites t where t.paciente_id = v_int.paciente_id and t.id = (v_res ->> 'id')::uuid));
    end if;
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
    insert into core.idempotencia (clave, paciente_id, resultado)
    values (p_clave_idempotencia, v_int.paciente_id, v_res - 'resumen');
  end if;
  return v_res;
end
$$;

-- ---------------------------------------------------------------------
-- 6. Rotación de llave
--   1) Crear en Vault 'clave_cifrado_v<N>'.
--   2) select core.rotar_clave(N);
--      · Cambia la versión activa de inmediato (lo nuevo se cifra con vN).
--      · Re-cifra un lote; pg_cron (sd-rotacion-cifrado) sigue con los
--        demás lotes cada minuto hasta terminar.
--   Cada fila guarda su versión, así que durante la rotación todo sigue
--   legible: lo viejo con su llave anterior, lo nuevo con la nueva.
--   Las llaves anteriores NO se borran de Vault.
-- ---------------------------------------------------------------------
create or replace function core.rotar_clave(p_nueva_version smallint, p_lote int default 5000)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_cfg core.config_cifrado;
  v_m   int;
  v_t   int;
  v_pendiente boolean;
begin
  perform core.clave_cifrado(p_nueva_version);  -- la llave nueva debe existir
  select * into v_cfg from core.config_cifrado for update;
  if p_nueva_version < v_cfg.version_activa then
    raise exception 'La versión % es anterior a la activa (%)', p_nueva_version, v_cfg.version_activa using errcode = '22023';
  end if;
  if p_nueva_version > v_cfg.version_activa then
    update core.config_cifrado
    set version_activa = p_nueva_version, rotacion_pendiente = true, rotacion_iniciada_en = now(), actualizado_en = now();
  end if;

  perform set_config('app.operacion', 'cifrado', true);

  with lote as (
    select paciente_id, creado_en, id from core.mensajes
    where clave_version < p_nueva_version
    limit p_lote for update skip locked)
  update core.mensajes m
  set contenido_cifrado = core.cifrar(core.descifrar(m.contenido_cifrado, m.clave_version), p_nueva_version),
      clave_version = p_nueva_version
  from lote l
  where m.paciente_id = l.paciente_id and m.creado_en = l.creado_en and m.id = l.id;
  get diagnostics v_m = row_count;

  with lote as (
    select paciente_id, id from core.tramites
    where resumen_clave_version < p_nueva_version
    limit p_lote for update skip locked)
  update core.tramites t
  set resumen_cifrado = core.cifrar(core.descifrar(t.resumen_cifrado, t.resumen_clave_version), p_nueva_version),
      resumen_clave_version = p_nueva_version
  from lote l
  where t.paciente_id = l.paciente_id and t.id = l.id;
  get diagnostics v_t = row_count;

  perform set_config('app.operacion', '', true);

  v_pendiente := exists (select 1 from core.mensajes where clave_version < p_nueva_version)
              or exists (select 1 from core.tramites where resumen_clave_version < p_nueva_version);
  if not v_pendiente then
    update core.config_cifrado set rotacion_pendiente = false, actualizado_en = now() where rotacion_pendiente;
  end if;

  return jsonb_build_object('version_activa', p_nueva_version, 'mensajes', v_m, 'tramites', v_t,
                            'pendiente', v_pendiente);
end
$$;

create or replace function core.continuar_rotacion()
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_version smallint;
begin
  select version_activa into v_version from core.config_cifrado where rotacion_pendiente;
  if found then
    perform core.rotar_clave(v_version);
  end if;
end
$$;

revoke execute on function core.rotar_clave(smallint, int), core.continuar_rotacion()
from public, anon, authenticated, service_role;

select cron.schedule('sd-rotacion-cifrado', '* * * * *', $$select core.continuar_rotacion()$$);
