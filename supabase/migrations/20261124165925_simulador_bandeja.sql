-- =====================================================================
-- ⚠️  SOLO PARA PRUEBAS: bandeja del teléfono simulado
--   Donde "llegan" los OTP, los links de pago y las respuestas del bot
--   cuando las Edge Functions corren con MODO_SIMULADOR=true.
--   · Esquema propio: se borra completo con
--       drop schema simulador cascade;
--       select cron.unschedule('sd-simulador-limpieza');
--   · APAGADO por defecto. Solo supabase/seed.sql (desarrollo local) lo
--     enciende. Apagado, sus funciones responden 42501 aunque existan.
--     Ninguna función api permite encenderlo.
--   · La lectura deja ver los mensajes de CUALQUIER teléfono (incluidos
--     OTP): por eso jamás debe estar encendido fuera de local.
--   · El texto se guarda en claro: es una bandeja de prueba, no datos de
--     pacientes. Se borra a la hora (pg_cron).
-- =====================================================================
create schema simulador;
revoke all on schema simulador from public;
-- usage solo para poder llamar sus funciones; las tablas no tienen grants
grant usage on schema simulador to anon, authenticated, service_role;
alter default privileges in schema simulador revoke execute on functions from public;
alter default privileges in schema simulador revoke all on tables from public, anon, authenticated, service_role;

create table simulador.config (
  id          boolean primary key default true check (id),  -- fila única
  habilitado  boolean not null default false
);
insert into simulador.config default values;

create table simulador.bandeja (
  id          bigint generated always as identity primary key,
  telefono    text not null,
  tipo        text not null check (tipo in ('otp', 'link_pago', 'bot', 'sistema')),
  contenido   text not null,
  creado_en   timestamptz not null default now()
);
create index on simulador.bandeja (telefono, id);
create index on simulador.bandeja (creado_en);

alter table simulador.config  enable row level security;
alter table simulador.bandeja enable row level security;
revoke all on simulador.config, simulador.bandeja from public, anon, authenticated, service_role;

create or replace function simulador.exigir_habilitado()
returns void
language plpgsql stable
set search_path = ''
as $$
begin
  if not coalesce((select habilitado from simulador.config), false) then
    raise exception 'El simulador está apagado (solo existe en desarrollo local)' using errcode = '42501';
  end if;
end
$$;

-- Escribe en la bandeja de un teléfono (solo las Edge Functions, con la clave secreta)
create or replace function simulador.enviar(p_telefono text, p_tipo text, p_contenido text)
returns bigint
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  perform simulador.exigir_habilitado();
  perform core.exigir_rol('servicio');
  if p_tipo is null or p_tipo not in ('otp', 'link_pago', 'bot', 'sistema') then
    raise exception 'Tipo de mensaje inválido: %', p_tipo using errcode = '22023';
  end if;
  insert into simulador.bandeja (telefono, tipo, contenido)
  values (core.normalizar_identidad('telefono', p_telefono), p_tipo, coalesce(p_contenido, ''))
  returning id into v_id;
  return v_id;
end
$$;

-- Lee la bandeja de un teléfono (el panel "teléfono simulado" del navegador).
-- VOLATILE y solo POST: cada consulta cuenta en el rate limit.
create or replace function simulador.leer(p_telefono text, p_despues_de bigint default 0)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform simulador.exigir_habilitado();
  return (
    select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'tipo', b.tipo, 'contenido', b.contenido,
                                                 'creado_en', b.creado_en) order by b.id), '[]')
    from (select * from simulador.bandeja
          where telefono = core.normalizar_identidad('telefono', p_telefono) and id > coalesce(p_despues_de, 0)
          order by id limit 100) b);
end
$$;

-- pg_cron: la bandeja no guarda nada más de 1 hora
create or replace function simulador.limpiar()
returns int
language plpgsql
set search_path = ''
as $$
declare
  n int;
begin
  delete from simulador.bandeja where creado_en < now() - interval '1 hour';
  get diagnostics n = row_count;
  return n;
end
$$;

revoke execute on all functions in schema simulador from public, anon, authenticated, service_role;
grant execute on function simulador.leer(text, bigint) to anon, authenticated, service_role;
grant execute on function simulador.enviar(text, text, text) to service_role;

select cron.schedule('sd-simulador-limpieza', '*/10 * * * *', $$select simulador.limpiar()$$);
