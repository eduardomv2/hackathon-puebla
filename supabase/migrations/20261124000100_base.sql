-- =====================================================================
-- 0100 · Base: extensiones, esquemas, utilidades, contexto del actor,
--        auditoría genérica y particiones mensuales
-- =====================================================================

-- Extensiones (todas disponibles en Supabase)
create extension if not exists pgcrypto with schema extensions;
create extension if not exists vector   with schema extensions;
create extension if not exists pg_net   with schema extensions;
create extension if not exists pgmq;
create extension if not exists pg_cron;

-- Esquemas
--   core  : tablas y lógica interna. NO se expone en la Data API.
--   audit : bitácora inmutable de cambios y lecturas sensibles.
--   api   : única superficie pública (funciones RPC). Se expone en la Data API.
create schema if not exists core;
create schema if not exists audit;
create schema if not exists api;

revoke all on schema core, audit, api from public;
grant usage on schema api  to anon, authenticated, service_role;
-- core: solo "usage" para que políticas RLS y el pre-request puedan llamar
-- a funciones puntuales; las tablas no tienen ningún grant.
grant usage on schema core to anon, authenticated;

-- Nada se ejecuta por defecto: cada función recibe su grant explícito.
alter default privileges in schema core  revoke execute on functions from public;
alter default privileges in schema audit revoke execute on functions from public;
alter default privileges in schema api   revoke execute on functions from public;
alter default privileges in schema core  revoke all on tables from public, anon, authenticated;
alter default privileges in schema audit revoke all on tables from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- UUIDv7 (ordenado por tiempo). Postgres 17 no trae uuidv7() nativo;
-- esta versión es portable y se reemplaza por la nativa en Postgres 18.
-- ---------------------------------------------------------------------
create or replace function core.uuid_v7()
returns uuid
language sql volatile parallel safe
set search_path = ''
as $$
  select encode(
    set_bit(set_bit(
      overlay(uuid_send(gen_random_uuid())
              placing substring(int8send(floor(extract(epoch from clock_timestamp()) * 1000)::bigint) from 3)
              from 1 for 6),
      52, 1), 53, 1),
    'hex')::uuid
$$;

-- ---------------------------------------------------------------------
-- Rol y actor de la petición
--   rol_actual(): se deriva SOLO del JWT (no se puede falsificar desde SQL).
--   actor/canal : los fija cada función api después de autorizar.
-- ---------------------------------------------------------------------
create or replace function core.rol_actual()
returns text
language sql stable
set search_path = ''
as $$
  select case
    when auth.role() = 'service_role' then 'servicio'
    when auth.jwt() -> 'app_metadata' ->> 'rol' in ('asesor', 'supervisor', 'admin')
      then auth.jwt() -> 'app_metadata' ->> 'rol'
    when auth.role() = 'authenticated' then 'paciente'
    else 'anonimo'
  end
$$;

create or replace function core.actor_id()
returns uuid
language sql stable
set search_path = ''
as $$
  select coalesce(nullif(current_setting('app.actor_id', true), '')::uuid, auth.uid())
$$;

create or replace function core.actor_tipo()
returns text
language sql stable
set search_path = ''
as $$
  select coalesce(
    nullif(current_setting('app.actor_tipo', true), ''),
    case core.rol_actual() when 'servicio' then 'sistema' when 'anonimo' then 'sistema' else core.rol_actual() end)
$$;

create or replace function core.canal_actual()
returns text
language sql stable
set search_path = ''
as $$
  select coalesce(nullif(current_setting('app.canal', true), ''), 'sistema')
$$;

create or replace function core.exigir_rol(variadic p_roles text[])
returns text
language plpgsql stable
set search_path = ''
as $$
declare
  v_rol text := core.rol_actual();
begin
  if not v_rol = any (p_roles) then
    raise exception 'Acceso denegado para el rol %', v_rol using errcode = '42501';
  end if;
  return v_rol;
end
$$;

-- Fija canal y actor para la transacción, validando qué canal puede usar cada rol.
create or replace function core.establecer_actor(p_canal text, p_actor_tipo text default null)
returns void
language plpgsql volatile
set search_path = ''
as $$
declare
  v_rol   text := core.rol_actual();
  v_actor text;
begin
  if p_canal is null or p_canal not in ('web', 'app', 'whatsapp', 'call_center', 'clinica', 'panel', 'sistema') then
    raise exception 'Canal inválido: %', p_canal using errcode = '22023';
  end if;

  case v_rol
    when 'paciente' then
      if p_canal not in ('web', 'app') then
        raise exception 'Un paciente solo opera por web o app' using errcode = '42501';
      end if;
      v_actor := 'paciente';
    when 'asesor', 'supervisor' then
      if p_canal not in ('call_center', 'clinica', 'panel') then
        raise exception 'El personal opera por call center, clínica o panel' using errcode = '42501';
      end if;
      v_actor := v_rol;
    when 'admin' then
      v_actor := 'admin';
    when 'servicio' then
      v_actor := coalesce(p_actor_tipo, 'sistema');
      if v_actor not in ('paciente', 'agente_ia', 'asesor', 'sistema') then
        raise exception 'Actor inválido: %', v_actor using errcode = '22023';
      end if;
    else
      raise exception 'Acceso denegado' using errcode = '42501';
  end case;

  perform set_config('app.canal', p_canal, true);
  perform set_config('app.actor_tipo', v_actor, true);
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
end
$$;

-- ---------------------------------------------------------------------
-- Columnas de auditoría, borrado lógico y bloqueo de borrado físico
-- ---------------------------------------------------------------------
create or replace function core.trg_columnas_auditoria()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.creado_en  := coalesce(new.creado_en, now());
    new.creado_por := coalesce(new.creado_por, core.actor_id());
  else
    new.creado_en  := old.creado_en;
    new.creado_por := old.creado_por;
    if old.eliminado_en is null and new.eliminado_en is not null then
      new.eliminado_por := coalesce(new.eliminado_por, core.actor_id());
    end if;
  end if;
  new.actualizado_en  := now();
  new.actualizado_por := core.actor_id();
  return new;
end
$$;

create or replace function core.trg_bloquear_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Borrado físico no permitido en %.%: usa borrado lógico (eliminado_en)',
    tg_table_schema, tg_table_name using errcode = '42501';
end
$$;

-- Bitácora inmutable
create table audit.registro (
  id               uuid        not null default core.uuid_v7(),
  ocurrido_en      timestamptz not null default now(),
  tabla            text        not null,
  registro_id      text        not null,
  paciente_id      uuid,
  accion           text        not null check (accion in ('INSERT', 'UPDATE', 'DELETE', 'BORRADO_LOGICO', 'LECTURA')),
  antes            jsonb,
  despues          jsonb,
  campos_cambiados text[],
  actor_id         uuid,
  actor_tipo       text,
  canal            text,
  ip               text,
  txid             bigint      not null default txid_current(),
  primary key (ocurrido_en, id)
) partition by range (ocurrido_en);

create table audit.registro_default partition of audit.registro default;
create index on audit.registro (tabla, registro_id, ocurrido_en desc);
create index on audit.registro (paciente_id, ocurrido_en desc);
create index on audit.registro (actor_id, ocurrido_en desc);

create or replace function core.ip_actual()
returns text
language sql stable
set search_path = ''
as $$
  select nullif(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1), '')
$$;

-- Columnas que cambian por operación normal y no son un "cambio" auditable
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

  insert into audit.registro (tabla, registro_id, paciente_id, accion, antes, despues,
                              campos_cambiados, actor_id, actor_tipo, canal, ip)
  values (
    tg_table_schema || '.' || tg_table_name,
    coalesce(v_fila ->> 'id',
             (v_fila ->> 'tipo') || ':' || (v_fila ->> 'valor'),
             (v_fila ->> 'clinica_id') || ':' || (v_fila ->> 'estudio_id')),
    case when tg_table_name = 'pacientes' then (v_fila ->> 'id')::uuid
         else (v_fila ->> 'paciente_id')::uuid end,
    v_accion, v_antes, v_despues, v_campos,
    core.actor_id(), core.actor_tipo(), core.canal_actual(), core.ip_actual()
  );
  return null;
end
$$;

create or replace function audit.trg_inmutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'La bitácora de auditoría es inmutable' using errcode = '42501';
end
$$;

create trigger trg_inmutable before update or delete on audit.registro
  for each row execute function audit.trg_inmutable();

-- Registro explícito de lecturas sensibles (el personal abrió datos de un paciente)
create or replace function audit.registrar_lectura(p_tabla text, p_registro_id text, p_paciente_id uuid, p_detalle jsonb default null)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into audit.registro (tabla, registro_id, paciente_id, accion, despues, actor_id, actor_tipo, canal, ip)
  values (p_tabla, p_registro_id, p_paciente_id, 'LECTURA', p_detalle,
          core.actor_id(), core.actor_tipo(), core.canal_actual(), core.ip_actual())
$$;

-- Engancha columnas de auditoría, bitácora y bloqueo de borrado a una tabla
create or replace function core.habilitar_auditoria(p_tabla regclass, p_bitacora boolean default true, p_bloquear_delete boolean default true)
returns void
language plpgsql
set search_path = ''
as $$
begin
  execute format('create trigger trg_10_columnas before insert or update on %s
                  for each row execute function core.trg_columnas_auditoria()', p_tabla);
  if p_bitacora then
    execute format('create trigger trg_90_bitacora after insert or update or delete on %s
                    for each row execute function audit.trg_registrar()', p_tabla);
  end if;
  if p_bloquear_delete then
    execute format('create trigger trg_00_sin_delete before delete on %s
                    for each row execute function core.trg_bloquear_delete()', p_tabla);
  end if;
end
$$;

-- ---------------------------------------------------------------------
-- Particiones mensuales (eventos, mensajes, auditoría)
-- Crea las particiones del mes anterior al actual + N meses adelante.
-- pg_cron la ejecuta a diario; es idempotente.
-- ---------------------------------------------------------------------
create or replace function core.asegurar_particiones(p_tabla regclass, p_meses_atras int default 1, p_meses_adelante int default 3)
returns int
language plpgsql
set search_path = ''
as $$
declare
  v_esquema text;
  v_nombre  text;
  v_inicio  timestamptz;
  v_part    text;
  v_creadas int := 0;
begin
  select n.nspname, c.relname into v_esquema, v_nombre
  from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where c.oid = p_tabla;

  for i in -p_meses_atras .. p_meses_adelante loop
    v_inicio := (date_trunc('month', now() at time zone 'UTC') + make_interval(months => i)) at time zone 'UTC';
    v_part   := v_nombre || '_' || to_char(v_inicio at time zone 'UTC', 'YYYYMM');
    if not exists (select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                   where n.nspname = v_esquema and c.relname = v_part) then
      execute format('create table %I.%I partition of %s for values from (%L) to (%L)',
                     v_esquema, v_part, p_tabla, v_inicio, v_inicio + interval '1 month');
      v_creadas := v_creadas + 1;
    end if;
  end loop;
  return v_creadas;
end
$$;

select core.asegurar_particiones('audit.registro');
