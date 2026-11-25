-- =====================================================================
-- Horarios de atención y días inhábiles
--   · core.horarios_clinica: un renglón por clínica y día de la semana
--     (0 = domingo … 6 = sábado). Un día sin renglón = cerrado.
--   · core.dias_inhabiles: festivos y cierres (clinica_id nulo = todas).
--   · api.horarios_disponibles: lo que el bot y la web ofrecen.
--   · api.reservar_cita: rechaza horas fuera de atención (22023).
--   En producción hay que cargar los horarios reales: sin renglones, la
--   clínica no ofrece horarios y no acepta reservas.
-- =====================================================================
create table core.horarios_clinica (
  clinica_id       uuid not null references core.clinicas (id),
  dia_semana       smallint not null check (dia_semana between 0 and 6),
  abre             time not null,
  cierra           time not null,
  intervalo_min    int  not null default 30 check (intervalo_min between 5 and 240),
  creado_en        timestamptz not null default now(),
  creado_por       uuid,
  actualizado_en   timestamptz not null default now(),
  actualizado_por  uuid,
  eliminado_en     timestamptz,
  eliminado_por    uuid,
  primary key (clinica_id, dia_semana),
  check (cierra > abre)
);

create table core.dias_inhabiles (
  id               uuid primary key default core.uuid_v7(),
  clinica_id       uuid references core.clinicas (id),   -- nulo = todas las clínicas
  fecha            date not null,
  motivo           text not null,
  creado_en        timestamptz not null default now(),
  creado_por       uuid,
  actualizado_en   timestamptz not null default now(),
  actualizado_por  uuid,
  eliminado_en     timestamptz,
  eliminado_por    uuid,
  constraint dias_inhabiles_llave unique nulls not distinct (clinica_id, fecha)
);
create index on core.dias_inhabiles (fecha);

-- La bitácora identifica las filas de horarios_clinica por "clinica:dia_semana"
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
             (v_fila ->> 'titular_id') || ':' || (v_fila ->> 'beneficiario_id'),
             (v_fila ->> 'clinica_id') || ':' || (v_fila ->> 'dia_semana')),
    case when tg_table_name = 'pacientes' then (v_fila ->> 'id')::uuid
         else coalesce(v_fila ->> 'paciente_id', v_fila ->> 'titular_id')::uuid end,
    v_accion, v_antes, v_despues, v_campos,
    core.actor_id(), core.actor_tipo(), core.canal_actual(), core.ip_actual()
  );
  return null;
end
$$;

select core.habilitar_auditoria('core.horarios_clinica');
select core.habilitar_auditoria('core.dias_inhabiles');
alter table core.horarios_clinica enable row level security;
alter table core.dias_inhabiles   enable row level security;
revoke all on core.horarios_clinica, core.dias_inhabiles from public, anon, authenticated, service_role;

-- ¿La hora cae en un turno de atención de la clínica? (hora local de la clínica)
--   Turno válido: día con horario, no inhábil, inicio >= abre, inicio +
--   intervalo <= cierra y alineado al intervalo (9:00, 9:30… no 9:10).
create or replace function core.en_horario_atencion(p_clinica_id uuid, p_fecha_hora timestamptz)
returns boolean
language sql stable
set search_path = ''
as $$
  select exists (
    select 1
    from core.clinicas c
    cross join lateral (select (p_fecha_hora at time zone c.zona_horaria) as l) loc
    join core.horarios_clinica h
      on h.clinica_id = c.id and h.dia_semana = extract(dow from loc.l) and h.eliminado_en is null
    where c.id = p_clinica_id
      and loc.l::time >= h.abre
      -- con intervalos (time - time) para que no "dé la vuelta" a medianoche
      and (loc.l::time - h.abre) + make_interval(mins => h.intervalo_min) <= (h.cierra - h.abre)
      and date_trunc('minute', loc.l) = loc.l
      and (extract(epoch from (loc.l::time - h.abre)) / 60)::int % h.intervalo_min = 0
      and not exists (select 1 from core.dias_inhabiles i
                      where (i.clinica_id = c.id or i.clinica_id is null)
                        and i.fecha = loc.l::date and i.eliminado_en is null))
$$;
revoke execute on function core.en_horario_atencion(uuid, timestamptz) from public, anon, authenticated, service_role;

-- Horarios con cupo libre. Datos públicos (anon incluido). VOLATILE + solo
-- POST, así que cada consulta cuenta en el rate limit.
--   p_desde: día local de la clínica (por omisión, hoy). p_dias: 1 a 14.
--   Sin horas pasadas ni con menos de 1 hora de anticipación. Máximo 100.
create or replace function api.horarios_disponibles(
  p_clinica_id uuid, p_estudio_id uuid, p_desde date default null, p_dias int default 7)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_zona  text;
  v_cap   int;
  v_desde date;
  v_dias  int := least(greatest(coalesce(p_dias, 7), 1), 14);
begin
  select zona_horaria into v_zona from core.clinicas where id = p_clinica_id and activa and eliminado_en is null;
  if v_zona is null then
    raise exception 'Clínica no encontrada' using errcode = 'PT404';
  end if;
  select ce.capacidad_por_horario into v_cap
  from core.clinica_estudios ce join core.estudios e on e.id = ce.estudio_id
  where ce.clinica_id = p_clinica_id and ce.estudio_id = p_estudio_id
    and ce.activo and ce.eliminado_en is null and e.activo and e.eliminado_en is null;
  if v_cap is null then
    raise exception 'La clínica no ofrece ese estudio' using errcode = '22023';
  end if;
  v_desde := coalesce(p_desde, (now() at time zone v_zona)::date);

  -- (el limit va en la subconsulta: en el select del agregado no limitaría nada)
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'fecha_hora', x.fecha_hora,
             'fecha', x.fecha,
             'hora', to_char(x.inicio, 'HH24:MI'),
             'disponibles', v_cap - x.ocupados)
           order by x.fecha_hora), '[]')
    from (
      select s.* from (
        select t.fecha, t.inicio, t.fecha_hora,
               (select count(*)::int from core.agenda_clinica a
                where a.clinica_id = p_clinica_id and a.estudio_id = p_estudio_id
                  and a.fecha_hora = t.fecha_hora and a.estado in ('reservada', 'confirmada')) as ocupados
        from (
          select d.fecha, (h.abre + make_interval(mins => k * h.intervalo_min))::time as inicio,
                 ((d.fecha + h.abre + make_interval(mins => k * h.intervalo_min)) at time zone v_zona) as fecha_hora
          from (select v_desde + g as fecha from generate_series(0, v_dias - 1) g) d
          join core.horarios_clinica h
            on h.clinica_id = p_clinica_id and h.dia_semana = extract(dow from d.fecha) and h.eliminado_en is null
          cross join lateral generate_series(
            0, (extract(epoch from (h.cierra - h.abre)) / 60)::int / h.intervalo_min - 1) k
          where not exists (select 1 from core.dias_inhabiles i
                            where (i.clinica_id = p_clinica_id or i.clinica_id is null)
                              and i.fecha = d.fecha and i.eliminado_en is null)
        ) t
        where t.fecha_hora >= now() + interval '1 hour'
      ) s
      where s.ocupados < v_cap
      order by s.fecha_hora
      limit 100
    ) x);
end
$$;
revoke execute on function api.horarios_disponibles(uuid, uuid, date, int) from public;
grant execute on function api.horarios_disponibles(uuid, uuid, date, int) to anon, authenticated, service_role;

-- reservar_cita: igual que en la etapa 2 + validación del horario de atención
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

  -- Límite por titular: máximo 5 citas futuras reservadas o confirmadas.
  -- La reserva de este mismo trámite no cuenta (se reemplaza al cambiar horario).
  -- (Única excepción a la convención de errores: ver etapa 2.)
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
  insert into core.citas (paciente_id, tramite_id, clinica_id, estudio_id, fecha_hora, precio, beneficiario_id, relacion)
  values (v_tramite.paciente_id, v_tramite.id, v_clinica, v_estudio, p_fecha_hora, v_precio, v_benef, v_relacion)
  returning id into v_cita;

  update core.tramites
  set contexto = contexto || jsonb_build_object('cita_id', v_cita, 'fecha_hora', p_fecha_hora, 'precio', v_precio),
      paso_actual = 'pago', version = version + 1, ultimo_canal = v_int.canal,
      ultima_actividad_en = now(), expira_en = now() + interval '72 hours', recordatorio_enviado_en = null
  where paciente_id = v_tramite.paciente_id and id = v_tramite.id
  returning * into v_tramite;

  perform core.registrar_evento(v_int.paciente_id, v_tramite.id, v_int.id, 'cita_reservada',
    jsonb_build_object('cita_id', v_cita, 'clinica_id', v_clinica, 'estudio_id', v_estudio,
                       'fecha_hora', p_fecha_hora, 'precio', v_precio,
                       'beneficiario_id', v_benef, 'relacion', v_relacion));
  return core.tramite_json(v_tramite);
end
$$;
