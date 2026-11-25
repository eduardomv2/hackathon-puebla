-- =====================================================================
-- Etapa 1 · Titular, beneficiario y código de continuidad (estructura)
--   · pacientes: estado 'declarado' (datos dados por un tercero) y
--     verificación presencial en clínica
--   · relaciones_paciente: quién agenda por quién (titular → beneficiario)
--   · citas y agenda_clinica: la cita es DEL titular (llave y pago) pero
--     la atiende el beneficiario
--   · codigos_continuidad: pasar un trámite de la web/app a otro canal
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Pacientes
-- ---------------------------------------------------------------------
alter table core.pacientes drop constraint pacientes_estado_check;
alter table core.pacientes add constraint pacientes_estado_check
  check (estado in ('anonimo', 'declarado', 'identificado', 'verificado', 'fusionado'));

-- Se llena cuando el personal de la clínica revisa una identificación oficial
alter table core.pacientes add column verificado_presencial_en timestamptz;

-- ---------------------------------------------------------------------
-- 2. Relaciones titular → beneficiario
--   El titular es quien agenda y paga (mamá); el beneficiario es quien se
--   atiende (hijo). El beneficiario no tiene identidades propias.
-- ---------------------------------------------------------------------
create table core.relaciones_paciente (
  titular_id                 uuid not null references core.pacientes (id),
  beneficiario_id            uuid not null references core.pacientes (id),
  relacion                   text not null check (relacion in ('hijo', 'hija', 'madre', 'padre', 'conyuge', 'otro')),
  es_tutor_legal             boolean not null default false,
  consentimiento_resultados  boolean not null default false,
  consentimiento_en          timestamptz,
  creado_en                  timestamptz not null default now(),
  creado_por                 uuid,
  actualizado_en             timestamptz not null default now(),
  actualizado_por            uuid,
  eliminado_en               timestamptz,
  eliminado_por              uuid,
  primary key (titular_id, beneficiario_id),
  check (titular_id <> beneficiario_id),
  check (not consentimiento_resultados or consentimiento_en is not null)
);
create index on core.relaciones_paciente (beneficiario_id);
select core.habilitar_auditoria('core.relaciones_paciente');

-- La bitácora identifica cada fila por su llave. relaciones_paciente no tiene
-- columna id: se usa "titular:beneficiario" y se asocia al titular.
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
-- 3. Citas: la llave sigue siendo (paciente_id, id) = titular
-- ---------------------------------------------------------------------
alter table core.citas
  add column beneficiario_id uuid references core.pacientes (id),
  add column relacion text not null default 'titular'
    check (relacion in ('titular', 'hijo', 'hija', 'madre', 'padre', 'conyuge', 'otro'));
update core.citas set beneficiario_id = paciente_id where beneficiario_id is null;
alter table core.citas alter column beneficiario_id set not null;
create index on core.citas (beneficiario_id);

-- Si quien inserta no indica beneficiario, la cita es para el propio titular.
-- (Mantiene funcionando a reservar_cita hasta que la Etapa 2 lo llene explícitamente.)
create or replace function core.trg_cita_beneficiario()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.beneficiario_id := coalesce(new.beneficiario_id, new.paciente_id);
  return new;
end
$$;
create trigger trg_05_beneficiario before insert on core.citas
  for each row execute function core.trg_cita_beneficiario();

-- ---------------------------------------------------------------------
-- 4. Agenda por clínica: también sabe quién se atiende
-- ---------------------------------------------------------------------
alter table core.agenda_clinica add column beneficiario_id uuid;
update core.agenda_clinica a set beneficiario_id = c.beneficiario_id
from core.citas c where c.id = a.cita_id and a.beneficiario_id is null;
alter table core.agenda_clinica alter column beneficiario_id set not null;

create or replace function core.trg_proyectar_agenda()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  insert into core.agenda_clinica (clinica_id, cita_id, fecha_hora, paciente_id, beneficiario_id, estudio_id, estado)
  values (new.clinica_id, new.id, new.fecha_hora, new.paciente_id, new.beneficiario_id, new.estudio_id, new.estado)
  on conflict (clinica_id, cita_id) do update
    set fecha_hora = excluded.fecha_hora, paciente_id = excluded.paciente_id,
        beneficiario_id = excluded.beneficiario_id,
        estudio_id = excluded.estudio_id, estado = excluded.estado, actualizado_en = now();
  return null;
end
$$;

-- ---------------------------------------------------------------------
-- 5. Códigos de continuidad (web/app → WhatsApp, call center o clínica)
--   Solo se guarda el hash; el código en claro existe únicamente en la
--   respuesta a quien lo generó. Nunca se borran.
-- ---------------------------------------------------------------------
create table core.codigos_continuidad (
  id                     uuid primary key default core.uuid_v7(),
  codigo_hash            text not null unique,
  paciente_id            uuid not null references core.pacientes (id),
  tramite_id             uuid not null,
  interaccion_origen_id  uuid not null,
  canal_origen           text not null check (canal_origen in ('web', 'app')),
  intentos               int  not null default 0,
  expira_en              timestamptz not null default now() + interval '15 minutes',
  usado_en               timestamptz,
  usado_en_canal         text check (usado_en_canal in ('whatsapp', 'call_center', 'clinica')),
  creado_en              timestamptz not null default now(),
  -- Si el trámite cambia de paciente (fusión o continuidad), el código lo sigue
  foreign key (paciente_id, tramite_id) references core.tramites (paciente_id, id) on update cascade,
  check ((usado_en is null) = (usado_en_canal is null))
);
create index on core.codigos_continuidad (paciente_id, creado_en desc);
create trigger trg_00_sin_delete before delete on core.codigos_continuidad
  for each row execute function core.trg_bloquear_delete();

-- ---------------------------------------------------------------------
-- RLS y permisos: igual que el resto de core (sin políticas ni grants)
-- ---------------------------------------------------------------------
alter table core.relaciones_paciente enable row level security;
alter table core.codigos_continuidad enable row level security;
revoke all on core.relaciones_paciente, core.codigos_continuidad from public, anon, authenticated, service_role;
revoke execute on function core.trg_cita_beneficiario() from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 6. Eventos nuevos
-- ---------------------------------------------------------------------
insert into core.catalogo_eventos (tipo_evento, categoria, descripcion, dispara_resumen) values
  ('beneficiario_agregado',           'identidad',   'El titular registró a un familiar como beneficiario', false),
  ('codigo_continuidad_generado',     'interaccion', 'Se generó un código para continuar el trámite en otro canal', false),
  ('codigo_continuidad_usado',        'interaccion', 'El trámite continuó en otro canal con un código', true),
  ('identidad_presencial_verificada', 'identidad',   'El personal de clínica verificó una identificación oficial', false),
  ('limite_citas_alcanzado',          'cita',        'Se rechazó una reserva por exceder el máximo de citas futuras', true);
