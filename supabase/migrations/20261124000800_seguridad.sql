-- =====================================================================
-- 0800 · Seguridad: rate limit, permisos, RLS y canales de tiempo real
-- =====================================================================

-- ---------------------------------------------------------------------
-- Rate limit por ventana fija (por usuario o IP)
--   UNLOGGED: no escribe WAL (rápido); si la base se reinicia se vacía, aceptable.
-- ---------------------------------------------------------------------
create unlogged table core.rate_limit (
  clave    text not null,
  ventana  timestamptz not null,
  conteo   int not null default 0,
  primary key (clave, ventana)
);

create or replace function core.consumir_limite(p_clave text, p_limite int, p_ventana_seg int default 60)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ventana timestamptz := to_timestamp(floor(extract(epoch from now()) / p_ventana_seg) * p_ventana_seg);
  v_conteo  int;
begin
  insert into core.rate_limit as rl (clave, ventana, conteo) values (p_clave, v_ventana, 1)
  on conflict (clave, ventana) do update set conteo = rl.conteo + 1
  returning conteo into v_conteo;
  return v_conteo <= p_limite;
end
$$;

-- Se ejecuta antes de CADA petición a la Data API (pgrst.db_pre_request).
-- Responde HTTP 429 al pasar el límite. Los servicios internos (service_role) quedan exentos.
create or replace function core.verificar_peticion()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rol    text := core.rol_actual();
  v_clave  text;
  v_limite int;
begin
  if v_rol = 'servicio' or current_setting('transaction_read_only', true) = 'on' then
    return;
  end if;
  v_clave  := coalesce(auth.uid()::text, 'ip:' || core.ip_actual(), 'desconocido');
  v_limite := case v_rol when 'anonimo' then 30 when 'paciente' then 120 else 600 end;
  if not core.consumir_limite('api:' || v_clave, v_limite, 60) then
    raise sqlstate 'PT429' using message = 'Demasiadas solicitudes', hint = 'Intenta de nuevo en un minuto';
  end if;
end
$$;

alter role authenticator set pgrst.db_pre_request = 'core.verificar_peticion';
notify pgrst, 'reload config';

create or replace function core.limpieza()
returns void
language sql
security definer
set search_path = ''
as $$
  delete from core.idempotencia where creado_en < now() - interval '24 hours';
  delete from core.rate_limit   where ventana   < now() - interval '10 minutes';
  delete from core.otp          where expira_en < now() - interval '1 day';
$$;

-- ---------------------------------------------------------------------
-- Permisos
--   · anon: nada (la web usa inicio de sesión anónimo → authenticated)
--   · authenticated: funciones api; cada una valida el rol del JWT
--   · service_role: además, las funciones de webhooks y workers
--   · Ninguna tabla tiene grants: todo pasa por funciones auditadas
-- ---------------------------------------------------------------------
revoke all on all tables    in schema core, audit from public, anon, authenticated, service_role;
revoke all on all sequences in schema core, audit from public, anon, authenticated, service_role;
revoke execute on all functions in schema core, audit, api from public, anon, authenticated;

grant execute on all functions in schema api to authenticated, service_role;
revoke execute on function
  api.solicitar_otp(uuid),
  api.confirmar_pago(text, text, jsonb),
  api.cola_leer(text, int, int),
  api.cola_confirmar(text, bigint),
  api.material_resumen(uuid),
  api.guardar_resumen(uuid, text, timestamptz)
from authenticated;

-- Funciones que evalúan políticas RLS y el pre-request (corren con el rol de la petición)
grant execute on function core.rol_actual(), core.mi_paciente_id(), core.ip_actual(),
                          core.verificar_peticion(), core.consumir_limite(text, int, int)
  to anon, authenticated;

-- RLS activo en todas las tablas, sin políticas = denegado por defecto.
-- Las funciones api (SECURITY DEFINER, dueño postgres) son la única vía de acceso.
do $$
declare
  r record;
begin
  for r in
    select n.nspname, c.relname
    from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('core', 'audit') and c.relkind in ('r', 'p')
  loop
    execute format('alter table %I.%I enable row level security', r.nspname, r.relname);
  end loop;
end
$$;

-- ---------------------------------------------------------------------
-- Tiempo real (Broadcast privado desde la base)
--   journey:global      → panel de supervisores y administradores
--   paciente:<id>       → la web/app del propio paciente
-- ---------------------------------------------------------------------
create policy "personal recibe el journey global"
  on realtime.messages for select to authenticated
  using (realtime.topic() = 'journey:global' and core.rol_actual() in ('supervisor', 'admin'));

create policy "paciente recibe sus propios eventos"
  on realtime.messages for select to authenticated
  using (realtime.topic() = 'paciente:' || core.mi_paciente_id()::text);
