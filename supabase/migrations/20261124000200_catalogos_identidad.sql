-- =====================================================================
-- 0200 · Catálogos (clínicas, estudios, personal) e identidad del paciente
-- =====================================================================

create table core.clinicas (
  id               uuid primary key default core.uuid_v7(),
  clave            text not null unique,
  nombre           text not null,
  ciudad           text not null,
  estado           text not null,
  direccion        text,
  zona_horaria     text not null default 'America/Mexico_City',
  activa           boolean not null default true,
  creado_en        timestamptz not null default now(),
  creado_por       uuid,
  actualizado_en   timestamptz not null default now(),
  actualizado_por  uuid,
  eliminado_en     timestamptz,
  eliminado_por    uuid
);

create table core.estudios (
  id               uuid primary key default core.uuid_v7(),
  clave            text not null unique,
  nombre           text not null,
  categoria        text not null,
  descripcion      text,
  preparacion      text,
  duracion_min     int  not null default 30 check (duracion_min > 0),
  precio_base      numeric(10, 2) not null check (precio_base >= 0),
  activo           boolean not null default true,
  creado_en        timestamptz not null default now(),
  creado_por       uuid,
  actualizado_en   timestamptz not null default now(),
  actualizado_por  uuid,
  eliminado_en     timestamptz,
  eliminado_por    uuid
);

-- Qué estudios ofrece cada clínica, a qué precio y cuántos pacientes por horario
create table core.clinica_estudios (
  clinica_id             uuid not null references core.clinicas (id),
  estudio_id             uuid not null references core.estudios (id),
  precio                 numeric(10, 2) check (precio >= 0),
  capacidad_por_horario  int not null default 4 check (capacidad_por_horario > 0),
  activo                 boolean not null default true,
  creado_en              timestamptz not null default now(),
  creado_por             uuid,
  actualizado_en         timestamptz not null default now(),
  actualizado_por        uuid,
  eliminado_en           timestamptz,
  eliminado_por          uuid,
  primary key (clinica_id, estudio_id)
);

-- Personal (asesores de call center, supervisores, administradores)
create table core.staff (
  id               uuid primary key references auth.users (id),
  nombre           text not null,
  email            text not null,
  rol              text not null check (rol in ('asesor', 'supervisor', 'admin')),
  clinica_id       uuid references core.clinicas (id),
  activo           boolean not null default true,
  creado_en        timestamptz not null default now(),
  creado_por       uuid,
  actualizado_en   timestamptz not null default now(),
  actualizado_por  uuid,
  eliminado_en     timestamptz,
  eliminado_por    uuid
);

-- El rol viaja en el JWT (app_metadata.rol) para no consultar la tabla en cada petición
create or replace function core.trg_sincronizar_rol_staff()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update auth.users
  set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb)
      || jsonb_build_object(
           'rol',        case when new.activo and new.eliminado_en is null then new.rol end,
           'clinica_id', new.clinica_id)
  where id = new.id;
  return new;
end
$$;

create trigger trg_50_sincronizar_rol after insert or update on core.staff
  for each row execute function core.trg_sincronizar_rol_staff();

select core.habilitar_auditoria('core.clinicas');
select core.habilitar_auditoria('core.estudios');
select core.habilitar_auditoria('core.clinica_estudios');
select core.habilitar_auditoria('core.staff');

-- ---------------------------------------------------------------------
-- Identidad
--   pacientes             : la persona, única entre canales
--   identidades_paciente  : cada forma de reconocerla (teléfono, correo,
--                           cuenta de app/web), con su nivel de confianza
--   paciente_fusiones     : registro de cada unificación de dos registros
-- ---------------------------------------------------------------------
create table core.pacientes (
  id                              uuid primary key default core.uuid_v7(),
  nombre                          text,
  apellido_paterno                text,
  apellido_materno                text,
  fecha_nacimiento                date,
  sexo                            text check (sexo in ('F', 'M', 'X')),
  estado                          text not null default 'anonimo'
                                  check (estado in ('anonimo', 'identificado', 'verificado', 'fusionado')),
  fusionado_en                    uuid references core.pacientes (id),
  intentos_verificacion_fallidos  int not null default 0,
  bloqueado_hasta                 timestamptz,
  creado_en                       timestamptz not null default now(),
  creado_por                      uuid,
  actualizado_en                  timestamptz not null default now(),
  actualizado_por                 uuid,
  eliminado_en                    timestamptz,
  eliminado_por                   uuid,
  check ((estado = 'fusionado') = (fusionado_en is not null))
);

create table core.identidades_paciente (
  tipo             text not null check (tipo in ('telefono', 'email', 'auth_uid', 'whatsapp_id')),
  valor            text not null,
  paciente_id      uuid not null references core.pacientes (id),
  nivel_confianza  text not null check (nivel_confianza in ('declarada', 'canal', 'verificada')),
  verificada_en    timestamptz,
  origen_canal     text not null,
  creado_en        timestamptz not null default now(),
  creado_por       uuid,
  actualizado_en   timestamptz not null default now(),
  actualizado_por  uuid,
  eliminado_en     timestamptz,
  eliminado_por    uuid,
  -- Llave = el valor: al distribuir, esta tabla se reparte por "valor"
  -- porque un mensaje entrante solo trae el teléfono.
  primary key (valor, tipo)
);
create index on core.identidades_paciente (paciente_id);

create table core.paciente_fusiones (
  id                uuid primary key default core.uuid_v7(),
  paciente_origen   uuid not null references core.pacientes (id),
  paciente_destino  uuid not null references core.pacientes (id),
  motivo            text not null,
  identidad_tipo    text,
  identidad_valor   text,
  actor_id          uuid,
  actor_tipo        text,
  canal             text,
  realizada_en      timestamptz not null default now()
);

select core.habilitar_auditoria('core.pacientes');
select core.habilitar_auditoria('core.identidades_paciente');

-- Normaliza para que el mismo teléfono/correo coincida venga del canal que venga
--   WhatsApp: 5218661234567 · Supabase Auth: 528661234567 · call center: 866 123 4567
create or replace function core.normalizar_identidad(p_tipo text, p_valor text)
returns text
language plpgsql immutable
set search_path = ''
as $$
declare
  d text;
begin
  if p_valor is null or btrim(p_valor) = '' then
    raise exception 'Identidad vacía' using errcode = '22023';
  end if;
  if p_tipo = 'telefono' then
    d := regexp_replace(p_valor, '\D', '', 'g');
    if length(d) = 10 then return '+52' || d; end if;
    if length(d) = 13 and left(d, 3) = '521' then return '+52' || right(d, 10); end if;
    if length(d) = 12 and left(d, 2) = '52' then return '+' || d; end if;
    if length(d) between 8 and 15 then return '+' || d; end if;
    raise exception 'Teléfono inválido' using errcode = '22023';
  elsif p_tipo = 'email' then
    return lower(btrim(p_valor));
  else
    return btrim(p_valor);
  end if;
end
$$;

create or replace function core.rango_nivel(p_nivel text)
returns int
language sql immutable
set search_path = ''
as $$
  select case p_nivel when 'verificada' then 2 when 'canal' then 1 else 0 end
$$;

create or replace function core.enmascarar_telefono(p_valor text)
returns text
language sql immutable
set search_path = ''
as $$
  select case when p_valor is null then null else left(p_valor, 3) || '******' || right(p_valor, 4) end
$$;

-- Paciente de la sesión web/app (por su cuenta de Supabase Auth)
create or replace function core.mi_paciente_id()
returns uuid
language sql stable
security definer
set search_path = ''
as $$
  select paciente_id
  from core.identidades_paciente
  where tipo = 'auth_uid' and valor = auth.uid()::text and eliminado_en is null
$$;
