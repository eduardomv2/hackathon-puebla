-- =====================================================================
-- Etapa 4 · Particiones ordenadas, métricas permanentes y p_datos acotado
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Esquema particiones
--   Las particiones mensuales viven aparte para que core y audit muestren
--   solo tablas "lógicas". La aplicación consulta siempre al padre.
--   Sin grants para anon, authenticated ni service_role (ni usage).
-- ---------------------------------------------------------------------
create schema if not exists particiones;
revoke all on schema particiones from public, anon, authenticated, service_role;
alter default privileges in schema particiones revoke all on tables from public, anon, authenticated, service_role;

create or replace function core.asegurar_particiones(p_tabla regclass, p_meses_atras int default 1, p_meses_adelante int default 3)
returns int
language plpgsql
set search_path = ''
as $$
declare
  v_nombre  text;
  v_inicio  timestamptz;
  v_part    text;
  v_creadas int := 0;
begin
  select c.relname into v_nombre from pg_catalog.pg_class c where c.oid = p_tabla;

  for i in -p_meses_atras .. p_meses_adelante loop
    v_inicio := (date_trunc('month', now() at time zone 'UTC') + make_interval(months => i)) at time zone 'UTC';
    v_part   := v_nombre || '_' || to_char(v_inicio at time zone 'UTC', 'YYYYMM');

    if exists (select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
               where n.nspname = 'particiones' and c.relname = v_part) then
      if not exists (select 1 from pg_catalog.pg_inherits i join pg_catalog.pg_class c on c.oid = i.inhrelid
                     join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                     where i.inhparent = p_tabla and n.nspname = 'particiones' and c.relname = v_part) then
        raise exception 'particiones.% ya existe y no es partición de %', v_part, p_tabla using errcode = '42P07';
      end if;
      continue;
    end if;

    execute format('create table particiones.%I partition of %s for values from (%L) to (%L)',
                   v_part, p_tabla, v_inicio, v_inicio + interval '1 month');
    -- RLS y sin grants también en la partición (se podría consultar directo)
    execute format('alter table particiones.%I enable row level security', v_part);
    execute format('revoke all on particiones.%I from public, anon, authenticated, service_role', v_part);
    v_creadas := v_creadas + 1;
  end loop;
  return v_creadas;
end
$$;

-- Mueve las particiones que ya existen (mensuales y default)
do $$
declare
  r record;
begin
  for r in
    select c.oid::regclass as particion, c.relname
    from pg_catalog.pg_inherits i
    join pg_catalog.pg_class c on c.oid = i.inhrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where i.inhparent in ('core.eventos_tramite'::regclass, 'core.mensajes'::regclass, 'audit.registro'::regclass)
      and n.nspname <> 'particiones'
  loop
    execute format('alter table %s set schema particiones', r.particion);
    execute format('alter table particiones.%I enable row level security', r.relname);
    execute format('revoke all on particiones.%I from public, anon, authenticated, service_role', r.relname);
  end loop;
end
$$;

-- ---------------------------------------------------------------------
-- 2. Métricas permanentes (reemplazan a las vistas materializadas de 90 días)
--   Un PRIMARY KEY no admite columnas nulas (clinica_id es nula en trámites
--   sin clínica elegida), así que la llave compuesta es un
--   UNIQUE NULLS NOT DISTINCT: dos nulos cuentan como el mismo valor.
-- ---------------------------------------------------------------------
create table core.metricas_tramites_diarias (
  dia           date not null,   -- día de creación del trámite (hora de México)
  clinica_id    uuid,
  tipo          text not null,
  paso          text not null,
  estado        text not null,
  canal_origen  text not null,
  ultimo_canal  text not null,
  tramites      int  not null,
  calculado_en  timestamptz not null default now(),
  constraint metricas_tramites_diarias_llave
    unique nulls not distinct (dia, clinica_id, tipo, paso, estado, canal_origen, ultimo_canal)
);

create table core.metricas_canales_diarias (
  dia           date not null,   -- día del evento canal_cambiado (hora de México)
  canal_desde   text,
  canal_hacia   text,
  paso          text,
  transiciones  int  not null,
  calculado_en  timestamptz not null default now(),
  constraint metricas_canales_diarias_llave
    unique nulls not distinct (dia, canal_desde, canal_hacia, paso)
);

create table core.metricas_citas_diarias (
  dia           date not null,   -- día de la cita, en la zona horaria de la clínica
  clinica_id    uuid not null,
  estudio_id    uuid not null,
  estado        text not null,
  citas         int  not null,
  ingresos      numeric(12, 2) not null,  -- precio de citas pagadas (confirmada, atendida, no_asistio)
  calculado_en  timestamptz not null default now(),
  constraint metricas_citas_diarias_llave
    unique nulls not distinct (dia, clinica_id, estudio_id, estado)
);

-- Cuándo empezó la última corrida incremental
create table core.estado_metricas (
  id              boolean primary key default true check (id),  -- fila única
  ultima_corrida  timestamptz not null default '-infinity'
);
insert into core.estado_metricas default values;

alter table core.metricas_tramites_diarias enable row level security;
alter table core.metricas_canales_diarias  enable row level security;
alter table core.metricas_citas_diarias    enable row level security;
alter table core.estado_metricas           enable row level security;
revoke all on core.metricas_tramites_diarias, core.metricas_canales_diarias, core.metricas_citas_diarias,
              core.estado_metricas
from public, anon, authenticated, service_role;

-- Para encontrar rápido lo que cambió y lo de cada día
create index on core.tramites (actualizado_en);
create index on core.tramites (creado_en);
create index on core.citas (actualizado_en);
create index on core.citas (fecha_hora);

-- Recalcula exactamente los días indicados (borra y vuelve a insertar
-- SOLO esos días; los demás no se tocan). Son datos derivados: se pueden
-- reconstruir en cualquier momento desde trámites, citas y eventos.
create or replace function core.recalcular_metricas_dias(
  p_dias_tramites date[], p_dias_citas date[], p_dias_canales date[])
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_t int;
  v_c int;
  v_k int;
begin
  -- Trámites, por día de creación
  delete from core.metricas_tramites_diarias where dia = any (p_dias_tramites);
  insert into core.metricas_tramites_diarias (dia, clinica_id, tipo, paso, estado, canal_origen, ultimo_canal, tramites)
  select d.dia, t.clinica_id, t.tipo, t.paso_actual, t.estado, t.canal_origen, t.ultimo_canal, count(*)::int
  from (select distinct unnest(p_dias_tramites) as dia) d
  join core.tramites t
    on t.creado_en >= (d.dia::timestamp at time zone 'America/Mexico_City')
   and t.creado_en <  ((d.dia + 1)::timestamp at time zone 'America/Mexico_City')
  where t.eliminado_en is null
  group by 1, 2, 3, 4, 5, 6, 7;
  get diagnostics v_t = row_count;

  -- Citas, por día local de la clínica
  delete from core.metricas_citas_diarias where dia = any (p_dias_citas);
  insert into core.metricas_citas_diarias (dia, clinica_id, estudio_id, estado, citas, ingresos)
  select x.dia, c.clinica_id, c.estudio_id, c.estado, count(*)::int,
         coalesce(sum(c.precio) filter (where c.estado in ('confirmada', 'atendida', 'no_asistio')), 0)
  from core.citas c
  join core.clinicas cl on cl.id = c.clinica_id
  cross join lateral (select (c.fecha_hora at time zone cl.zona_horaria)::date as dia) x
  where c.eliminado_en is null
    -- rango amplio (±1 día por zonas horarias) para usar el índice; luego el día exacto
    and c.fecha_hora >= ((select min(d) from unnest(p_dias_citas) d) - 1)::timestamp at time zone 'UTC'
    and c.fecha_hora <  ((select max(d) from unnest(p_dias_citas) d) + 2)::timestamp at time zone 'UTC'
    and x.dia = any (p_dias_citas)
  group by 1, 2, 3, 4;
  get diagnostics v_c = row_count;

  -- Cambios de canal, por día del evento
  delete from core.metricas_canales_diarias where dia = any (p_dias_canales);
  insert into core.metricas_canales_diarias (dia, canal_desde, canal_hacia, paso, transiciones)
  select d.dia, ev.payload ->> 'de', ev.payload ->> 'a', ev.payload ->> 'paso_actual', count(*)::int
  from (select distinct unnest(p_dias_canales) as dia) d
  join core.eventos_tramite ev
    on ev.ocurrido_en >= (d.dia::timestamp at time zone 'America/Mexico_City')
   and ev.ocurrido_en <  ((d.dia + 1)::timestamp at time zone 'America/Mexico_City')
  where ev.tipo_evento = 'canal_cambiado'
  group by 1, 2, 3, 4;
  get diagnostics v_k = row_count;

  return jsonb_build_object('filas_tramites', v_t, 'filas_citas', v_c, 'filas_canales', v_k);
end
$$;

-- Corrida incremental (pg_cron cada 5 min). Recalcula solo los días afectados:
--   · trámites: días de creación de los trámites que cambiaron + ayer y hoy
--   · citas   : días de las citas que cambiaron + ayer y hoy
--   · canales : ayer y hoy (salen de eventos, que nunca cambian)
-- ultima_corrida se fija al INICIO: lo que cambie mientras corre entra en la
-- siguiente. Se busca con 10 min de margen porque actualizado_en es la hora
-- de inicio de la transacción que escribió, y una transacción larga puede
-- confirmar después de que esta corrida leyó.
create or replace function core.recalcular_metricas()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_desde timestamptz;
  v_hoy   date := (now() at time zone 'America/Mexico_City')::date;
  v_dt    date[];
  v_dc    date[];
begin
  select ultima_corrida into v_desde from core.estado_metricas for update;  -- una corrida a la vez
  update core.estado_metricas set ultima_corrida = now();
  v_desde := v_desde - interval '10 minutes';

  select array_agg(distinct dia order by dia) into v_dt from (
    select (creado_en at time zone 'America/Mexico_City')::date as dia
    from core.tramites where actualizado_en > v_desde
    union all select v_hoy - 1
    union all select v_hoy) s;

  select array_agg(distinct dia order by dia) into v_dc from (
    select (c.fecha_hora at time zone cl.zona_horaria)::date as dia
    from core.citas c join core.clinicas cl on cl.id = c.clinica_id
    where c.actualizado_en > v_desde
    union all select v_hoy - 1
    union all select v_hoy) s;

  return core.recalcular_metricas_dias(v_dt, v_dc, array[v_hoy - 1, v_hoy])
         || jsonb_build_object('dias_tramites', v_dt, 'dias_citas', v_dc);
end
$$;

-- Carga inicial y reparaciones manuales: recalcula todo un rango de días
create or replace function core.recalcular_metricas_rango(p_desde date, p_hasta date)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_dias date[];
begin
  if p_desde is null or p_hasta is null or p_desde > p_hasta then
    raise exception 'Rango de fechas inválido' using errcode = '22023';
  end if;
  select array_agg(d::date order by d) into v_dias from generate_series(p_desde, p_hasta, interval '1 day') d;
  return core.recalcular_metricas_dias(v_dias, v_dias, v_dias);
end
$$;

revoke execute on function
  core.recalcular_metricas_dias(date[], date[], date[]),
  core.recalcular_metricas(),
  core.recalcular_metricas_rango(date, date)
from public, anon, authenticated, service_role;

-- Carga inicial con todo el histórico (incluye citas futuras)
select core.recalcular_metricas_rango(
  coalesce(least((select min(creado_en at time zone 'America/Mexico_City')::date from core.tramites),
                 (select min(fecha_hora at time zone 'America/Mexico_City')::date from core.citas),
                 (select min(ocurrido_en at time zone 'America/Mexico_City')::date from core.eventos_tramite
                  where tipo_evento = 'canal_cambiado')),
           (now() at time zone 'America/Mexico_City')::date),
  greatest((now() at time zone 'America/Mexico_City')::date,
           coalesce((select max(fecha_hora at time zone 'America/Mexico_City')::date + 1 from core.citas),
                    (now() at time zone 'America/Mexico_City')::date)));
update core.estado_metricas set ultima_corrida = now();

-- pg_cron: mismo nombre de tarea → se reemplaza el comando anterior
select cron.schedule('sd-metricas', '*/5 * * * *', $$select core.recalcular_metricas()$$);

drop function core.refrescar_metricas();
drop materialized view core.mv_embudo_diario;
drop materialized view core.mv_transiciones_canal_diario;

-- ---------------------------------------------------------------------
-- 3. api.metricas: cualquier rango, comparado con el mismo periodo del año anterior
-- ---------------------------------------------------------------------
create or replace function core.metricas_periodo(p_desde date, p_hasta date, p_clinica_id uuid)
returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'desde', p_desde,
    'hasta', p_hasta,
    'tramites', (select coalesce(sum(tramites), 0)::int from core.metricas_tramites_diarias
                 where dia between p_desde and p_hasta and (p_clinica_id is null or clinica_id = p_clinica_id)),
    'embudo', (select coalesce(jsonb_agg(jsonb_build_object('paso', paso, 'estado', estado, 'tramites', n)
                                         order by paso, estado), '[]')
               from (select paso, estado, sum(tramites)::int as n from core.metricas_tramites_diarias
                     where dia between p_desde and p_hasta and (p_clinica_id is null or clinica_id = p_clinica_id)
                     group by 1, 2) s),
    'por_canal_origen', (select coalesce(jsonb_object_agg(canal_origen, n), '{}')
               from (select canal_origen, sum(tramites)::int as n from core.metricas_tramites_diarias
                     where dia between p_desde and p_hasta and (p_clinica_id is null or clinica_id = p_clinica_id)
                     group by 1) s),
    'transiciones_de_canal', (select coalesce(jsonb_agg(jsonb_build_object('de', canal_desde, 'a', canal_hacia, 'total', n)
                                                        order by n desc), '[]')
               from (select canal_desde, canal_hacia, sum(transiciones)::int as n from core.metricas_canales_diarias
                     where dia between p_desde and p_hasta group by 1, 2) s),
    'citas', (select coalesce(sum(citas), 0)::int from core.metricas_citas_diarias
              where dia between p_desde and p_hasta and (p_clinica_id is null or clinica_id = p_clinica_id)),
    'citas_por_estado', (select coalesce(jsonb_object_agg(estado, n), '{}')
               from (select estado, sum(citas)::int as n from core.metricas_citas_diarias
                     where dia between p_desde and p_hasta and (p_clinica_id is null or clinica_id = p_clinica_id)
                     group by 1) s),
    'ingresos', (select coalesce(sum(ingresos), 0) from core.metricas_citas_diarias
                 where dia between p_desde and p_hasta and (p_clinica_id is null or clinica_id = p_clinica_id)))
$$;

-- Variación porcentual; null si el periodo anterior es cero (no hay base)
create or replace function core.variacion_pct(p_actual numeric, p_anterior numeric)
returns numeric
language sql immutable
set search_path = ''
as $$
  select case when coalesce(p_anterior, 0) = 0 then null
              else round((coalesce(p_actual, 0) - p_anterior) / p_anterior * 100, 1) end
$$;

revoke execute on function core.metricas_periodo(date, date, uuid), core.variacion_pct(numeric, numeric)
from public, anon, authenticated, service_role;

create or replace function api.metricas(p_desde date, p_hasta date, p_clinica_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actual   jsonb;
  v_anterior jsonb;
begin
  perform core.exigir_rol('supervisor', 'admin');
  if p_clinica_id is not null then perform core.validar_alcance_clinica(p_clinica_id); end if;
  if p_desde is null or p_hasta is null or p_desde > p_hasta then
    raise exception 'Rango de fechas inválido' using errcode = '22023';
  end if;

  v_actual   := core.metricas_periodo(p_desde, p_hasta, p_clinica_id);
  -- Mismo periodo del año anterior (29 de febrero → 28 de febrero)
  v_anterior := core.metricas_periodo((p_desde - interval '1 year')::date, (p_hasta - interval '1 year')::date, p_clinica_id);

  return jsonb_build_object(
    'actual', v_actual,
    'anio_anterior', v_anterior,
    'variacion_pct', jsonb_build_object(
      'tramites', core.variacion_pct((v_actual ->> 'tramites')::numeric, (v_anterior ->> 'tramites')::numeric),
      'citas',    core.variacion_pct((v_actual ->> 'citas')::numeric,    (v_anterior ->> 'citas')::numeric),
      'ingresos', core.variacion_pct((v_actual ->> 'ingresos')::numeric, (v_anterior ->> 'ingresos')::numeric)));
end
$$;

-- ---------------------------------------------------------------------
-- 4. avanzar_tramite: p_datos solo acepta llaves conocidas
--   Antes aceptaba cualquier llave y la copiaba al contexto y al evento
--   paso_avanzado: un canal podía meter texto libre (datos de salud) que
--   quedaría sin cifrar. Ahora solo IDs: estudio_id, clinica_id, beneficiario_id.
--   cita_id, pago_id, precio y fecha_hora los fijan reservar_cita y los pagos.
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
