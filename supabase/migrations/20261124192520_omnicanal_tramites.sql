-- =====================================================================
-- Omnicanal en tiempo real (1/2): trámites
--   · Se elimina el código de continuidad: la identidad la une el OTP
--     (obligatorio para iniciar un trámite en la web o la app).
--   · Varios trámites abiertos a la vez. Cada interacción trabaja con uno
--     (interacciones.tramite_id); el contexto lista los abiertos con su
--     folio (SD-4K7Q) y su etiqueta ("Mastografía · para ti").
--   · Sin duplicados: mismo estudio + misma persona → PT409.
--   · El asesor manda: el trámite que abre o retoma queda bloqueado para
--     su interacción 10 min (se renuevan con cada acción). Los demás
--     canales lo ven pero no lo cambian: PT423 'tramite_en_atencion'.
--   · Tiempo real: el asesor puede escuchar el canal del paciente que
--     atiende; los mensajes nuevos también se anuncian (sin su texto).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Fuera el código de continuidad
-- ---------------------------------------------------------------------
drop function api.resolver_continuidad(uuid, text, text);
drop function api.generar_codigo_continuidad(uuid);
drop function api.iniciar_contacto(text, text, text, text, text);
drop function core.mover_tramite_continuidad(core.codigos_continuidad, uuid);
drop function core.opcion_continuidad(core.tramites, text);
drop function core.puede_resolver_continuidad(core.interacciones);
drop function core.consumir_codigo(uuid, uuid, uuid, uuid, text);
drop function core.registrar_fallo_codigo(text, uuid, uuid);
drop function core.codigo_vigente(core.codigos_continuidad);
drop function core.hash_codigo(text);
drop table core.codigos_continuidad;
-- (los tipos de evento codigo_continuidad_* se quedan en el catálogo: hay historia que los usa)

-- ---------------------------------------------------------------------
-- 2. Varios trámites abiertos, con folio y bloqueo de atención
-- ---------------------------------------------------------------------
drop index core.tramites_uno_abierto;

alter table core.tramites
  add column folio text,
  add column atendido_por_interaccion uuid,   -- interacción del asesor que lo tiene en atención
  add column atencion_hasta timestamptz;      -- vence si el asesor no hace nada en 10 min

-- Folio corto y legible para distinguir trámites al hablar o escribir: SD-4K7Q
create or replace function core.nuevo_folio()
returns text
language plpgsql volatile
set search_path = ''
as $$
declare
  c_alfabeto constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- sin 0/O/1/I
  v_bytes bytea;
  v_folio text;
begin
  loop
    v_bytes := extensions.gen_random_bytes(4);
    select 'SD-' || string_agg(substr(c_alfabeto, get_byte(v_bytes, n) % 32 + 1, 1), '' order by n)
    into v_folio from generate_series(0, 3) n;
    exit when not exists (select 1 from core.tramites where folio = v_folio);
  end loop;
  return v_folio;
end
$$;

create or replace function core.trg_tramite_folio()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.folio := coalesce(new.folio, core.nuevo_folio());
  return new;
end
$$;
create trigger trg_15_folio before insert on core.tramites
  for each row execute function core.trg_tramite_folio();

update core.tramites set folio = core.nuevo_folio() where folio is null;
alter table core.tramites alter column folio set not null;
create unique index tramites_folio on core.tramites (folio);
create index on core.tramites (atendido_por_interaccion) where atendido_por_interaccion is not null;
create index on core.interacciones (staff_id) where finalizada_en is null and staff_id is not null;

-- La renovación del bloqueo (atencion_hasta) no es un cambio auditable; el
-- cambio de quién atiende (atendido_por_interaccion) sí. Además las tablas
-- sin id usan "nombre" como llave (plantillas de WhatsApp).
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

-- Eventos nuevos
insert into core.catalogo_eventos (tipo_evento, categoria, descripcion, dispara_resumen) values
  ('atencion_iniciada',    'interaccion', 'Un asesor tomó el trámite: los demás canales solo lo ven', false),
  ('atencion_liberada',    'interaccion', 'El asesor soltó el trámite (colgó o venció la atención)', false),
  ('consentimiento_avisos', 'identidad',  'El paciente aceptó o rechazó recibir avisos por WhatsApp', false);

-- ---------------------------------------------------------------------
-- 3. Consentimiento de avisos (lo usa la parte 2; aquí para que la fusión lo mueva)
--    Solo inserciones: el último registro por paciente es el vigente.
-- ---------------------------------------------------------------------
create table core.consentimientos_avisos (
  paciente_id    uuid not null references core.pacientes (id),
  id             uuid not null default core.uuid_v7(),
  telefono       text not null,     -- teléfono verificado al que se aceptó (o rechazó)
  acepta         boolean not null,
  canal          text not null check (canal in ('web', 'app', 'whatsapp', 'call_center', 'clinica')),
  registrado_en  timestamptz not null default clock_timestamp(),  -- hora real: varios cambios en una transacción se ordenan
  actor_id       uuid,
  primary key (paciente_id, id)
);
create index on core.consentimientos_avisos (paciente_id, registrado_en desc);
create trigger trg_00_solo_insercion before update or delete on core.consentimientos_avisos
  for each row execute function core.trg_solo_insercion();
alter table core.consentimientos_avisos enable row level security;
revoke all on core.consentimientos_avisos from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4. Etiqueta, atención y JSON de trámites
-- ---------------------------------------------------------------------
-- "<estudio> · para <ti | nombre o relación>"
create or replace function core.etiqueta_tramite(t core.tramites)
returns text
language sql stable
set search_path = ''
as $$
  select coalesce(e.nombre, 'Estudio por elegir') || ' · para ' ||
         case when x.b = t.paciente_id then 'ti'
              else coalesce(nullif(btrim(p.nombre), ''),
                            case r.relacion when 'madre' then 'tu mamá' when 'padre' then 'tu papá'
                                            when 'hijo' then 'tu hijo' when 'hija' then 'tu hija'
                                            when 'conyuge' then 'tu pareja' else 'un familiar' end)
         end
  from (select coalesce(nullif(t.contexto ->> 'beneficiario_id', '')::uuid, t.paciente_id) as b) x
  left join core.estudios e on e.id = nullif(t.contexto ->> 'estudio_id', '')::uuid
  left join core.pacientes p on p.id = x.b
  left join core.relaciones_paciente r on r.titular_id = t.paciente_id and r.beneficiario_id = x.b and r.eliminado_en is null
$$;

-- ¿Lo tiene en atención OTRA interacción (bloqueo vigente)?
create or replace function core.en_atencion_de_otro(t core.tramites, p_interaccion_id uuid)
returns boolean
language sql stable
set search_path = ''
as $$
  select t.atendido_por_interaccion is not null and t.atencion_hasta > now()
     and t.atendido_por_interaccion is distinct from p_interaccion_id
$$;

create or replace function core.tramite_json(t core.tramites)
returns jsonb
language sql stable
set search_path = ''
as $$
  select case when t.id is null then null else jsonb_build_object(
    'id', t.id,
    'folio', t.folio,
    'etiqueta', core.etiqueta_tramite(t),
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
    'en_atencion', t.atendido_por_interaccion is not null and t.atencion_hasta > now(),
    'atencion_hasta', case when t.atencion_hasta > now() then t.atencion_hasta end,
    'ultima_actividad_en', t.ultima_actividad_en,
    'expira_en', t.expira_en
  ) end
$$;

-- Tarjeta de un trámite abierto, desde el punto de vista de una interacción
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
    'atendido_por_mi', t.atendido_por_interaccion = p_interaccion_id and t.atencion_hasta > now())
$$;

-- Teléfono verificado que aceptó avisos (null si no hay)
create or replace function core.telefono_avisos(p_paciente_id uuid)
returns text
language sql stable
set search_path = ''
as $$
  select c.telefono
  from (select telefono, acepta from core.consentimientos_avisos
        where paciente_id = p_paciente_id order by registrado_en desc, id desc limit 1) c
  join core.identidades_paciente i
    on i.tipo = 'telefono' and i.valor = c.telefono and i.paciente_id = p_paciente_id
   and i.nivel_confianza = 'verificada' and i.eliminado_en is null
  where c.acepta
$$;

-- Contexto de una sesión. tramite_activo = el trámite con el que trabaja ESTA
-- interacción; tramites_abiertos = todos los abiertos del paciente, recientes primero.
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
        where t.paciente_id = v_pac.id and t.estado in ('activo', 'pausado') and t.eliminado_en is null));
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
      where t.paciente_id = v_pac.id and t.estado in ('activo', 'pausado') and t.eliminado_en is null),
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

-- ---------------------------------------------------------------------
-- 5. Sesiones: una interacción nueva empieza SIN trámite; el canal le
--    pregunta a la paciente con cuál seguir (retomar) o si empieza otro.
-- ---------------------------------------------------------------------
create or replace function core.abrir_interaccion(
  p_paciente_id uuid, p_canal text, p_agente text, p_nivel text, p_staff_id uuid default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
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

  insert into core.interacciones (paciente_id, canal, agente, staff_id, nivel_verificacion)
  values (p_paciente_id, p_canal, p_agente, p_staff_id, p_nivel)
  returning id into v_id;
  perform core.registrar_evento(p_paciente_id, null, v_id, 'interaccion_iniciada',
                                jsonb_build_object('agente', p_agente, 'nivel', p_nivel));
  return v_id;
end
$$;

-- WhatsApp, voz con IA y call center: identifican por teléfono (ya sin código de continuidad)
create function api.iniciar_contacto(
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
-- 6. Bloqueo de atención del asesor
-- ---------------------------------------------------------------------
create or replace function core.liberar_atencion(p_interaccion_id uuid, p_motivo text)
returns int
language plpgsql
set search_path = ''
as $$
declare
  r record;
  n int := 0;
begin
  for r in
    update core.tramites set atendido_por_interaccion = null, atencion_hasta = null
    where atendido_por_interaccion = p_interaccion_id
    returning paciente_id, id, folio
  loop
    perform core.registrar_evento(r.paciente_id, r.id, p_interaccion_id, 'atencion_liberada',
                                  jsonb_build_object('folio', r.folio, 'motivo', p_motivo));
    n := n + 1;
  end loop;
  return n;
end
$$;

-- Un asesor (interacción con staff) toma el trámite o renueva su atención.
-- Cualquier otro canal: si el trámite está en atención de otro → PT423.
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
                                  'atencion_hasta', t.atencion_hasta)::text,
      hint = 'Un asesor está atendiendo este trámite por teléfono; se puede ver pero no cambiar';
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

-- Suelta los demás trámites que tenga una interacción (al cambiar de trámite)
create or replace function core.liberar_atencion_de(p_interaccion_id uuid, p_excepto uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  for r in
    update core.tramites set atendido_por_interaccion = null, atencion_hasta = null
    where atendido_por_interaccion = p_interaccion_id and id <> p_excepto
    returning paciente_id, id, folio
  loop
    perform core.registrar_evento(r.paciente_id, r.id, p_interaccion_id, 'atencion_liberada',
                                  jsonb_build_object('folio', r.folio, 'motivo', 'cambio_de_tramite'));
  end loop;
end
$$;

-- pg_cron: atenciones vencidas (el asesor no hizo nada en 10 min)
create or replace function core.liberar_atenciones_vencidas()
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
    update core.tramites set atendido_por_interaccion = null, atencion_hasta = null
    where atendido_por_interaccion is not null and atencion_hasta <= now()
    returning paciente_id, id, folio
  loop
    perform core.registrar_evento(r.paciente_id, r.id, null, 'atencion_liberada',
                                  jsonb_build_object('folio', r.folio, 'motivo', 'vencida'));
    n := n + 1;
  end loop;
  return n;
end
$$;
select cron.schedule('sd-liberar-atenciones', '30 seconds', $$select core.liberar_atenciones_vencidas()$$);

-- Carga y bloquea un trámite para modificarlo: atención del asesor (PT423) y versión (PT409)
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
    raise exception 'Trámite no encontrado' using errcode = 'PT404';
  end if;
  if v.estado not in ('activo', 'pausado') then
    raise exception 'El trámite está %', v.estado using errcode = 'P0001';
  end if;
  v := core.exigir_atencion(p_int, v);
  if v.version <> p_version then
    raise sqlstate 'PT409' using message = 'conflicto_de_version',
      detail = jsonb_build_object('version_actual', v.version, 'paso_actual', v.paso_actual)::text,
      hint = 'Otro canal actualizó el trámite; vuelve a leer el contexto';
  end if;
  return v;
end
$$;

-- ---------------------------------------------------------------------
-- 7. Duplicados: mismo estudio + misma persona mientras haya otro trámite
--    abierto o una cita futura → PT409 con cuál existe (para "continuar ese")
-- ---------------------------------------------------------------------
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
    and estado in ('reservada', 'confirmada') and fecha_hora > now() and eliminado_en is null
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

-- ---------------------------------------------------------------------
-- 8. Trámite: iniciar (siempre uno nuevo) y retomar
-- ---------------------------------------------------------------------
drop function api.iniciar_tramite(uuid, text);

-- Inicia un trámite NUEVO (conviven varios). En web/app exige teléfono verificado (OTP).
create function api.iniciar_tramite(p_interaccion_id uuid, p_tipo text default 'agendar_estudio')
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
  if v_int.canal in ('web', 'app') and v_int.nivel_verificacion <> 'verificada' then
    raise exception 'Verifica tu celular con el código (OTP) para iniciar un trámite' using errcode = '42501';
  end if;
  if not exists (select 1 from core.flujo_tramite where tipo_tramite = p_tipo) then
    raise exception 'Tipo de trámite desconocido: %', p_tipo using errcode = '22023';
  end if;

  insert into core.tramites (paciente_id, tipo, paso_actual, canal_origen, ultimo_canal)
  values (v_int.paciente_id, p_tipo,
          (select paso from core.flujo_tramite where tipo_tramite = p_tipo and orden = 1),
          v_int.canal, v_int.canal)
  returning * into v_tramite;
  perform core.registrar_evento(v_int.paciente_id, v_tramite.id, v_int.id, 'tramite_iniciado',
                                jsonb_build_object('tipo', p_tipo, 'folio', v_tramite.folio));
  update core.interacciones set tramite_id = v_tramite.id
  where paciente_id = v_int.paciente_id and id = v_int.id;
  v_tramite := core.exigir_atencion(v_int, v_tramite);  -- un asesor lo toma al crearlo
  return core.tramite_json(v_tramite);
end
$$;

-- La interacción sigue con un trámite abierto del paciente. Un asesor lo toma
-- (PT423 si lo tiene otro asesor). Los demás canales pueden retomarlo aunque
-- esté en atención: lo ven, pero no lo cambian.
create or replace function api.retomar_tramite(p_interaccion_id uuid, p_tramite_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v     core.tramites;
begin
  if v_int.nivel_verificacion = 'declarada' then
    raise exception 'Verifica la identidad antes de operar el trámite' using errcode = '42501';
  end if;
  select * into v from core.tramites
  where paciente_id = v_int.paciente_id and id = p_tramite_id and eliminado_en is null
  for update;
  if not found then
    raise exception 'Trámite no encontrado' using errcode = 'PT404';
  end if;
  if v.estado not in ('activo', 'pausado') then
    raise exception 'El trámite está %', v.estado using errcode = 'P0001';
  end if;

  if v_int.staff_id is not null then
    v := core.exigir_atencion(v_int, v);
  end if;
  update core.interacciones set tramite_id = v.id
  where paciente_id = v_int.paciente_id and id = v_int.id;

  if not core.en_atencion_de_otro(v, v_int.id) then
    if v.ultimo_canal <> v_int.canal then
      perform core.registrar_evento(v.paciente_id, v.id, v_int.id, 'canal_cambiado',
        jsonb_build_object('de', v.ultimo_canal, 'a', v_int.canal, 'paso_actual', v.paso_actual));
    end if;
    update core.tramites set estado = 'activo', ultimo_canal = v_int.canal, ultima_actividad_en = now(),
                             expira_en = greatest(expira_en, now() + interval '72 hours')
    where paciente_id = v.paciente_id and id = v.id
    returning * into v;
    perform core.registrar_evento(v.paciente_id, v.id, v_int.id, 'tramite_retomado',
                                  jsonb_build_object('paso_actual', v.paso_actual, 'folio', v.folio));
  end if;
  return core.tramite_json(v) || jsonb_build_object('en_atencion_de_otro', core.en_atencion_de_otro(v, v_int.id));
end
$$;

-- avanzar_tramite: igual que en la etapa 4 + verificación de duplicados
create or replace function api.avanzar_tramite(
  p_interaccion_id uuid, p_tramite_id uuid, p_version int, p_paso text,
  p_datos jsonb default '{}', p_clave_idempotencia text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_permitidas constant text[] := array['estudio_id', 'clinica_id', 'beneficiario_id'];
  v_int      core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_tramite  core.tramites;
  v_destino  core.flujo_tramite;
  v_orden    int;
  v_datos    jsonb;
  v_extra    text[];
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

  if p_datos is not null and jsonb_typeof(p_datos) <> 'object' then
    raise exception 'p_datos debe ser un objeto JSON' using errcode = '22023';
  end if;
  v_datos := jsonb_strip_nulls(coalesce(p_datos, '{}'));
  select array_agg(k order by k) into v_extra from jsonb_object_keys(v_datos) k where not k = any (c_permitidas);
  if v_extra is not null then
    raise exception 'Datos no permitidos: %. Solo se aceptan estudio_id, clinica_id y beneficiario_id',
      array_to_string(v_extra, ', ') using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_each(v_datos)
             where jsonb_typeof(value) <> 'string'
                or value #>> '{}' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
    raise exception 'Los valores de p_datos deben ser identificadores (uuid)' using errcode = '22023';
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
  if v_datos ? 'beneficiario_id'
     and core.relacion_beneficiario(v_tramite.paciente_id, (v_datos ->> 'beneficiario_id')::uuid) is null then
    raise exception 'El beneficiario no pertenece a este titular' using errcode = '22023';
  end if;

  v_ctx := v_tramite.contexto || v_datos;
  select array_agg(r) into v_faltan from unnest(v_destino.requiere) r where not v_ctx ? r;
  if v_faltan is not null then
    raise exception 'Faltan datos para %: %', p_paso, array_to_string(v_faltan, ', ') using errcode = '22023';
  end if;

  -- Sin duplicados: mismo estudio para la misma persona
  if v_datos ? 'estudio_id' or v_datos ? 'beneficiario_id' then
    perform core.verificar_duplicado(v_tramite.paciente_id, v_tramite.id, nullif(v_ctx ->> 'estudio_id', '')::uuid,
                                     coalesce(nullif(v_ctx ->> 'beneficiario_id', '')::uuid, v_tramite.paciente_id));
  end if;

  update core.tramites
  set contexto = v_ctx, paso_actual = p_paso, version = version + 1, estado = 'activo',
      ultimo_canal = v_int.canal, ultima_actividad_en = now(), expira_en = now() + interval '72 hours',
      recordatorio_enviado_en = null
  where paciente_id = v_tramite.paciente_id and id = v_tramite.id
  returning * into v_tramite;

  update core.interacciones set tramite_id = v_tramite.id
  where paciente_id = v_int.paciente_id and id = v_int.id and tramite_id is distinct from v_tramite.id;

  perform core.registrar_evento(v_int.paciente_id, v_tramite.id, v_int.id, 'paso_avanzado',
    jsonb_build_object('de', (select paso from core.flujo_tramite where tipo_tramite = v_tramite.tipo and orden = v_orden),
                       'a', p_paso, 'datos', v_datos, 'version', v_tramite.version, 'folio', v_tramite.folio));

  v_res := core.tramite_json(v_tramite);
  if p_clave_idempotencia is not null then
    insert into core.idempotencia (clave, paciente_id, resultado)
    values (p_clave_idempotencia, v_int.paciente_id, v_res - 'resumen');
  end if;
  return v_res;
end
$$;

-- reservar_cita: igual que en horarios + duplicados (protección ante dos canales a la vez)
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
    and estado in ('reservada', 'confirmada');
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

-- ---------------------------------------------------------------------
-- 9. Fin de la atención: colgar o inactividad
-- ---------------------------------------------------------------------
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
  perform core.liberar_atencion(v_int.id, 'interaccion_cerrada');
  perform core.registrar_evento(v_int.paciente_id, v_int.tramite_id, v_int.id, 'interaccion_finalizada',
    jsonb_build_object('resultado', p_resultado,
                       'duracion_seg', extract(epoch from now() - v_int.iniciada_en)::int));
end
$$;

create or replace function core.cerrar_interacciones_inactivas()
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
    update core.interacciones set finalizada_en = now(), resultado = 'inactiva'
    where finalizada_en is null and ultima_actividad_en < now() - interval '30 minutes'
    returning paciente_id, id, tramite_id
  loop
    perform core.liberar_atencion(r.id, 'interaccion_inactiva');
    perform core.registrar_evento(r.paciente_id, r.tramite_id, r.id, 'interaccion_finalizada',
                                  jsonb_build_object('resultado', 'inactiva'));
    n := n + 1;
  end loop;
  return n;
end
$$;

-- ---------------------------------------------------------------------
-- 10. Fusión: todos los trámites pasan al paciente conservado. Si eso crea
--     duplicados (mismo estudio y persona), se queda el de actividad más
--     reciente y el otro se cancela con su evento.
-- ---------------------------------------------------------------------
create or replace function core.fusionar_pacientes(
  p_origen uuid, p_destino uuid, p_motivo text, p_tipo text default null, p_valor text default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  dup record;
begin
  if p_origen = p_destino then
    return p_destino;
  end if;

  perform 1 from core.pacientes where id in (p_origen, p_destino) order by id for update;
  if exists (select 1 from core.pacientes where id in (p_origen, p_destino) and estado = 'declarado') then
    raise exception 'Un paciente declarado por un tercero nunca se fusiona' using errcode = '42501';
  end if;
  if (select estado from core.pacientes where id = p_origen) = 'fusionado' then
    raise exception 'El paciente origen ya fue fusionado' using errcode = 'P0001';
  end if;

  perform set_config('app.operacion', 'fusion', true);
  update core.tramites               set paciente_id = p_destino where paciente_id = p_origen;
  update core.interacciones          set paciente_id = p_destino where paciente_id = p_origen;
  update core.citas                  set paciente_id = p_destino where paciente_id = p_origen;
  update core.pagos                  set paciente_id = p_destino where paciente_id = p_origen;
  update core.eventos_tramite        set paciente_id = p_destino where paciente_id = p_origen;
  update core.mensajes               set paciente_id = p_destino where paciente_id = p_origen;
  update core.otp                    set paciente_id = p_destino where paciente_id = p_origen;
  update core.identidades_paciente   set paciente_id = p_destino where paciente_id = p_origen;
  update core.consentimientos_avisos set paciente_id = p_destino where paciente_id = p_origen;

  update core.citas set beneficiario_id = p_destino where beneficiario_id = p_origen;
  update core.tramites set contexto = contexto || jsonb_build_object('beneficiario_id', p_destino)
  where paciente_id = p_destino and contexto ->> 'beneficiario_id' = p_origen::text;

  -- (alias "rel": un alias "r" chocaría con la variable record r de esta función)
  update core.relaciones_paciente rel set titular_id = p_destino
  where rel.titular_id = p_origen
    and not exists (select 1 from core.relaciones_paciente d
                    where d.titular_id = p_destino and d.beneficiario_id = rel.beneficiario_id);
  update core.relaciones_paciente set eliminado_en = now()
  where titular_id = p_origen and eliminado_en is null;
  perform set_config('app.operacion', '', true);

  -- Duplicados creados por la fusión
  for dup in
    select x.id, x.conservado
    from (select t.id,
                 first_value(t.id) over w as conservado,
                 row_number() over w as n
          from core.tramites t
          where t.paciente_id = p_destino and t.estado in ('activo', 'pausado') and t.eliminado_en is null
            and t.contexto ? 'estudio_id'
          window w as (partition by t.contexto ->> 'estudio_id',
                                    coalesce(nullif(t.contexto ->> 'beneficiario_id', '')::uuid, t.paciente_id)
                       order by t.ultima_actividad_en desc)) x
    where x.n > 1
  loop
    update core.tramites set estado = 'cancelado', finalizado_en = now(),
                             atendido_por_interaccion = null, atencion_hasta = null
    where paciente_id = p_destino and id = dup.id;
    perform core.registrar_evento(p_destino, dup.id, null, 'tramite_cancelado',
      jsonb_build_object('motivo', 'duplicado_por_fusion', 'conservado', dup.conservado));
  end loop;

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

  perform core.registrar_evento(p_destino, null, null, 'pacientes_fusionados',
                                jsonb_build_object('origen', p_origen, 'motivo', p_motivo, 'identidad_tipo', p_tipo));
  return p_destino;
end
$$;

-- ---------------------------------------------------------------------
-- 11. Tiempo real
--   · El asesor puede escuchar 'paciente:<id>' mientras tiene una
--     interacción abierta con ese paciente.
--   · Cada mensaje nuevo se anuncia en ese canal SIN su texto (está
--     cifrado): quien escucha lo lee con obtener_contexto.
-- ---------------------------------------------------------------------
create or replace function core.puede_escuchar_paciente(p_topic text)
returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select core.rol_actual() in ('asesor', 'supervisor', 'admin')
     and exists (select 1 from core.interacciones i
                 where i.staff_id = auth.uid() and i.finalizada_en is null
                   and 'paciente:' || i.paciente_id::text = p_topic)
$$;
revoke execute on function core.puede_escuchar_paciente(text) from public, anon, service_role;
grant execute on function core.puede_escuchar_paciente(text) to authenticated;

create policy "personal escucha al paciente que atiende"
  on realtime.messages for select to authenticated
  using (core.puede_escuchar_paciente(realtime.topic()));

create or replace function core.trg_mensaje_publicado()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform realtime.send(
    jsonb_build_object('paciente_id', new.paciente_id, 'interaccion_id', new.interaccion_id, 'canal', new.canal,
                       'autor', new.autor, 'direccion', new.direccion, 'creado_en', new.creado_en),
    'mensaje_nuevo', 'paciente:' || new.paciente_id, true);
  return null;
end
$$;
create trigger trg_70_publicar after insert on core.mensajes
  for each row execute function core.trg_mensaje_publicado();

-- ---------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------
revoke execute on function
  core.nuevo_folio(), core.trg_tramite_folio(), core.etiqueta_tramite(core.tramites),
  core.en_atencion_de_otro(core.tramites, uuid), core.tramite_tarjeta(core.tramites, uuid),
  core.telefono_avisos(uuid), core.liberar_atencion(uuid, text), core.exigir_atencion(core.interacciones, core.tramites),
  core.liberar_atencion_de(uuid, uuid), core.liberar_atenciones_vencidas(), core.verificar_duplicado(uuid, uuid, uuid, uuid),
  core.trg_mensaje_publicado()
from public, anon, authenticated, service_role;

revoke execute on function api.iniciar_contacto(text, text, text, text), api.iniciar_tramite(uuid, text),
  api.retomar_tramite(uuid, uuid) from public, anon;
grant execute on function api.iniciar_contacto(text, text, text, text), api.iniciar_tramite(uuid, text),
  api.retomar_tramite(uuid, uuid) to authenticated, service_role;
