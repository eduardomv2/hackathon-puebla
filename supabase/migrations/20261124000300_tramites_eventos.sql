-- =====================================================================
-- 0300 · Trámites, interacciones, eventos, mensajes, citas y pagos
--   Todas las tablas del paciente llevan paciente_id y su llave primaria
--   empieza por él: es la llave de distribución si se reparte en nodos.
-- =====================================================================

-- Catálogo de eventos: ningún canal puede inventar un tipo de evento
create table core.catalogo_eventos (
  tipo_evento      text primary key,
  categoria        text not null check (categoria in ('identidad', 'tramite', 'interaccion', 'cita', 'pago', 'seguridad', 'sistema')),
  descripcion      text not null,
  dispara_resumen  boolean not null default false
);

insert into core.catalogo_eventos (tipo_evento, categoria, descripcion, dispara_resumen) values
  ('paciente_creado',             'identidad',   'Se creó el registro del paciente', false),
  ('identidad_agregada',          'identidad',   'Se ligó un teléfono, correo o cuenta al paciente', false),
  ('identidad_verificada',        'identidad',   'Una identidad o sesión subió de nivel de confianza', false),
  ('identidad_en_conflicto',      'seguridad',   'Una identidad no verificada pertenece a otro paciente; no se fusionó', false),
  ('pacientes_fusionados',        'identidad',   'Dos registros del mismo paciente se unificaron', true),
  ('datos_paciente_actualizados', 'identidad',   'Se capturaron datos demográficos', false),
  ('verificacion_fallida',        'seguridad',   'Falló una verificación de identidad', false),
  ('otp_enviado',                 'seguridad',   'Se generó un código de verificación', false),
  ('tramite_iniciado',            'tramite',     'Inició un trámite', true),
  ('tramite_retomado',            'tramite',     'El paciente retomó un trámite pendiente', true),
  ('paso_avanzado',               'tramite',     'El trámite cambió de paso o guardó datos', true),
  ('tramite_completado',          'tramite',     'El trámite terminó con éxito', true),
  ('tramite_abandonado',          'tramite',     'El trámite expiró por inactividad', true),
  ('tramite_cancelado',           'tramite',     'El trámite se canceló', true),
  ('canal_cambiado',              'interaccion', 'El paciente continuó en otro canal', true),
  ('interaccion_iniciada',        'interaccion', 'Inició una sesión en un canal', false),
  ('interaccion_finalizada',      'interaccion', 'Terminó una sesión en un canal', true),
  ('asesor_consulto_contexto',    'seguridad',   'Personal abrió el contexto del paciente', false),
  ('cita_reservada',              'cita',        'Se apartó un horario', true),
  ('cita_confirmada',             'cita',        'La cita quedó confirmada', true),
  ('cita_cancelada',              'cita',        'Se canceló una cita', true),
  ('pago_generado',               'pago',        'Se generó un link de pago', true),
  ('pago_confirmado',             'pago',        'El pago se acreditó', true),
  ('pago_fallido',                'pago',        'El pago fue rechazado', true),
  ('pago_expirado',               'pago',        'El link de pago venció', false),
  ('recordatorio_programado',     'sistema',     'Se programó un recordatorio para retomar', false),
  ('resumen_actualizado',         'sistema',     'La IA actualizó el resumen del trámite', false);

-- Máquina de estados de cada tipo de trámite.
-- "requiere" = datos que deben existir en el contexto para ENTRAR al paso.
create table core.flujo_tramite (
  tipo_tramite  text not null,
  paso          text not null,
  orden         int  not null,
  descripcion   text not null,
  requiere      text[] not null default '{}',
  primary key (tipo_tramite, paso),
  unique (tipo_tramite, orden)
);

insert into core.flujo_tramite (tipo_tramite, paso, orden, descripcion, requiere) values
  ('agendar_estudio', 'seleccion_estudio', 1, 'Elegir el estudio',                '{}'),
  ('agendar_estudio', 'seleccion_clinica', 2, 'Elegir la clínica',                '{estudio_id}'),
  ('agendar_estudio', 'seleccion_horario', 3, 'Elegir fecha y hora',              '{estudio_id,clinica_id}'),
  ('agendar_estudio', 'pago',              4, 'Pagar la cita',                    '{estudio_id,clinica_id,cita_id}'),
  ('agendar_estudio', 'confirmada',        5, 'Cita pagada y confirmada',         '{cita_id,pago_id}');

create table core.tramites (
  paciente_id              uuid not null references core.pacientes (id),
  id                       uuid not null default core.uuid_v7(),
  tipo                     text not null,
  estado                   text not null default 'activo'
                           check (estado in ('activo', 'pausado', 'completado', 'abandonado', 'cancelado')),
  paso_actual              text not null,
  contexto                 jsonb not null default '{}',
  clinica_id               uuid references core.clinicas (id),
  resumen                  text,
  resumen_actualizado_en   timestamptz,
  resumen_pendiente        boolean not null default false,
  version                  int  not null default 1,
  canal_origen             text not null,
  ultimo_canal             text not null,
  ultima_actividad_en      timestamptz not null default now(),
  expira_en                timestamptz not null default now() + interval '72 hours',
  recordatorio_enviado_en  timestamptz,
  finalizado_en            timestamptz,
  creado_en                timestamptz not null default now(),
  creado_por               uuid,
  actualizado_en           timestamptz not null default now(),
  actualizado_por          uuid,
  eliminado_en             timestamptz,
  eliminado_por            uuid,
  primary key (paciente_id, id),
  foreign key (tipo, paso_actual) references core.flujo_tramite (tipo_tramite, paso)
);
-- Un solo trámite abierto por paciente y tipo: es lo que permite "retomar"
create unique index tramites_uno_abierto on core.tramites (paciente_id, tipo)
  where estado in ('activo', 'pausado') and eliminado_en is null;
create index on core.tramites (id);
create index on core.tramites (estado, expira_en) where estado in ('activo', 'pausado');
create index on core.tramites (estado, ultima_actividad_en) where estado in ('activo', 'pausado');
create index on core.tramites (clinica_id, estado);

-- La clínica elegida se copia a una columna para filtrar y agregar por clínica
create or replace function core.trg_tramite_derivados()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.clinica_id := nullif(new.contexto ->> 'clinica_id', '')::uuid;
  return new;
end
$$;
create trigger trg_20_derivados before insert or update on core.tramites
  for each row execute function core.trg_tramite_derivados();

select core.habilitar_auditoria('core.tramites');

-- Cada sesión del paciente en un canal
create table core.interacciones (
  paciente_id          uuid not null references core.pacientes (id),
  id                   uuid not null default core.uuid_v7(),
  tramite_id           uuid,
  canal                text not null check (canal in ('web', 'app', 'whatsapp', 'call_center', 'clinica')),
  agente               text not null check (agente in ('autoservicio', 'ia', 'humano')),
  staff_id             uuid references core.staff (id),
  nivel_verificacion   text not null default 'declarada' check (nivel_verificacion in ('declarada', 'canal', 'verificada')),
  metodo_verificacion  text,
  iniciada_en          timestamptz not null default now(),
  ultima_actividad_en  timestamptz not null default now(),
  finalizada_en        timestamptz,
  resultado            text,
  creado_en            timestamptz not null default now(),
  creado_por           uuid,
  actualizado_en       timestamptz not null default now(),
  actualizado_por      uuid,
  eliminado_en         timestamptz,
  eliminado_por        uuid,
  primary key (paciente_id, id),
  foreign key (paciente_id, tramite_id) references core.tramites (paciente_id, id) on update cascade
);
create index on core.interacciones (id);
create index on core.interacciones (paciente_id, iniciada_en desc);
create index on core.interacciones (ultima_actividad_en) where finalizada_en is null;
-- Las interacciones se registran como eventos; aquí solo columnas y sin borrado físico
select core.habilitar_auditoria('core.interacciones', false, true);

-- Línea de tiempo unificada (solo inserción)
create table core.eventos_tramite (
  paciente_id     uuid not null,
  id              uuid not null default core.uuid_v7(),
  ocurrido_en     timestamptz not null default now(),
  tramite_id      uuid,
  interaccion_id  uuid,
  tipo_evento     text not null references core.catalogo_eventos (tipo_evento),
  canal           text not null check (canal in ('web', 'app', 'whatsapp', 'call_center', 'clinica', 'panel', 'sistema')),
  actor_tipo      text not null check (actor_tipo in ('paciente', 'asesor', 'supervisor', 'admin', 'agente_ia', 'sistema')),
  actor_id        uuid,
  payload         jsonb not null default '{}',
  primary key (paciente_id, ocurrido_en, id)
) partition by range (ocurrido_en);
create table core.eventos_tramite_default partition of core.eventos_tramite default;
create index on core.eventos_tramite (paciente_id, ocurrido_en desc);
create index on core.eventos_tramite (tramite_id, ocurrido_en desc);
create index on core.eventos_tramite using brin (ocurrido_en);
select core.asegurar_particiones('core.eventos_tramite');

-- Conversación de cada interacción (WhatsApp, chat web, transcripción de llamada)
create table core.mensajes (
  paciente_id     uuid not null,
  id              uuid not null default core.uuid_v7(),
  creado_en       timestamptz not null default now(),
  interaccion_id  uuid not null,
  canal           text not null,
  direccion       text not null check (direccion in ('entrante', 'saliente')),
  autor           text not null check (autor in ('paciente', 'agente_ia', 'asesor', 'sistema')),
  contenido       text not null,
  metadatos       jsonb not null default '{}',
  primary key (paciente_id, creado_en, id)
) partition by range (creado_en);
create table core.mensajes_default partition of core.mensajes default;
create index on core.mensajes (interaccion_id, creado_en);
create index on core.mensajes (paciente_id, creado_en desc);
select core.asegurar_particiones('core.mensajes');

-- Eventos y mensajes son inmutables; la única excepción es la fusión de pacientes
create or replace function core.trg_solo_insercion()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_setting('app.operacion', true) = 'fusion' and tg_op = 'UPDATE' then
    return new;
  end if;
  raise exception '%.% solo admite inserciones', tg_table_schema, tg_table_name using errcode = '42501';
end
$$;
create trigger trg_00_solo_insercion before update or delete on core.eventos_tramite
  for each row execute function core.trg_solo_insercion();
create trigger trg_00_solo_insercion before update or delete on core.mensajes
  for each row execute function core.trg_solo_insercion();

create table core.citas (
  paciente_id      uuid not null references core.pacientes (id),
  id               uuid not null default core.uuid_v7(),
  tramite_id       uuid,
  clinica_id       uuid not null references core.clinicas (id),
  estudio_id       uuid not null references core.estudios (id),
  fecha_hora       timestamptz not null,
  estado           text not null default 'reservada'
                   check (estado in ('reservada', 'confirmada', 'cancelada', 'atendida', 'no_asistio')),
  precio           numeric(10, 2) not null check (precio >= 0),
  creado_en        timestamptz not null default now(),
  creado_por       uuid,
  actualizado_en   timestamptz not null default now(),
  actualizado_por  uuid,
  eliminado_en     timestamptz,
  eliminado_por    uuid,
  primary key (paciente_id, id),
  foreign key (paciente_id, tramite_id) references core.tramites (paciente_id, id) on update cascade
);
create index on core.citas (id);
create index on core.citas (tramite_id);
select core.habilitar_auditoria('core.citas');

create table core.pagos (
  paciente_id         uuid not null references core.pacientes (id),
  id                  uuid not null default core.uuid_v7(),
  cita_id             uuid not null,
  monto               numeric(10, 2) not null check (monto > 0),
  moneda              char(3) not null default 'MXN',
  estado              text not null default 'pendiente'
                      check (estado in ('pendiente', 'pagado', 'fallido', 'expirado', 'reembolsado')),
  proveedor           text not null default 'simulado',
  referencia_externa  text not null,
  link_pago           text,
  expira_en           timestamptz not null default now() + interval '24 hours',
  pagado_en           timestamptz,
  creado_en           timestamptz not null default now(),
  creado_por          uuid,
  actualizado_en      timestamptz not null default now(),
  actualizado_por     uuid,
  eliminado_en        timestamptz,
  eliminado_por       uuid,
  primary key (paciente_id, id),
  foreign key (paciente_id, cita_id) references core.citas (paciente_id, id) on update cascade
);
create index on core.pagos (referencia_externa);
create index on core.pagos (estado, expira_en) where estado = 'pendiente';
select core.habilitar_auditoria('core.pagos');

-- ---------------------------------------------------------------------
-- Agenda por clínica: modelo de lectura (CQRS) indexado por clínica.
-- Responde "citas de hoy en la clínica X" y controla el cupo por horario
-- sin recorrer las citas de todos los pacientes. Si la base se distribuye,
-- esta tabla se reparte por clinica_id.
-- ---------------------------------------------------------------------
create table core.agenda_clinica (
  clinica_id      uuid not null,
  cita_id         uuid not null,
  fecha_hora      timestamptz not null,
  paciente_id     uuid not null,
  estudio_id      uuid not null,
  estado          text not null,
  actualizado_en  timestamptz not null default now(),
  primary key (clinica_id, cita_id)
);
create index on core.agenda_clinica (clinica_id, fecha_hora);
create index on core.agenda_clinica (clinica_id, estudio_id, fecha_hora) where estado in ('reservada', 'confirmada');

create or replace function core.trg_proyectar_agenda()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  insert into core.agenda_clinica (clinica_id, cita_id, fecha_hora, paciente_id, estudio_id, estado)
  values (new.clinica_id, new.id, new.fecha_hora, new.paciente_id, new.estudio_id, new.estado)
  on conflict (clinica_id, cita_id) do update
    set fecha_hora = excluded.fecha_hora, paciente_id = excluded.paciente_id,
        estudio_id = excluded.estudio_id, estado = excluded.estado, actualizado_en = now();
  return null;
end
$$;
create trigger trg_60_agenda after insert or update on core.citas
  for each row execute function core.trg_proyectar_agenda();

-- Respuestas guardadas por llave de idempotencia (reintentos de webhooks)
create table core.idempotencia (
  clave        text primary key,
  paciente_id  uuid,
  resultado    jsonb not null,
  creado_en    timestamptz not null default now()
);

-- Códigos de verificación para canales sin sesión (llamada, WhatsApp)
create table core.otp (
  id              uuid primary key default core.uuid_v7(),
  paciente_id     uuid not null references core.pacientes (id),
  interaccion_id  uuid not null,
  codigo_hash     text not null,
  intentos        int  not null default 0,
  expira_en       timestamptz not null default now() + interval '5 minutes',
  usado_en        timestamptz,
  creado_en       timestamptz not null default now()
);
create index on core.otp (interaccion_id, creado_en desc);
