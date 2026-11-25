-- =====================================================================
-- Código de verificación: WhatsApp y, si no se entrega, SMS
--   Meta acepta el envío aunque el número no tenga WhatsApp y avisa después,
--   por el webhook (statuses: failed). Para poder mandar el MISMO código por
--   SMS en ese momento, se guarda mientras tanto:
--     · cifrado (core.cifrar, con la versión de la llave),
--     · máximo 10 minutos (el código de Auth vence antes),
--     · de un solo uso: al resolverse (entregado o fallido) se borra,
--     · solo service_role (las Edge Functions) lo registra y lo resuelve.
--   api.registrar_codigo_enviado(mensaje_id, telefono, codigo)
--   api.resolver_codigo_enviado(mensaje_id, entregado) → {telefono, codigo}
--     solo si NO se entregó y no ha vencido; si no, null.
-- =====================================================================

create table core.codigos_enviados (
  mensaje_id      text primary key,
  telefono        text not null,
  codigo_cifrado  bytea not null,
  version_llave   smallint not null,
  enviado_en      timestamptz not null default now(),
  expira_en       timestamptz not null default now() + interval '10 minutes'
);
create index on core.codigos_enviados (expira_en);
alter table core.codigos_enviados enable row level security;
revoke all on core.codigos_enviados from public, anon, authenticated, service_role;

create function api.registrar_codigo_enviado(p_mensaje_id text, p_telefono text, p_codigo text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_version smallint := core.version_cifrado_activa();
begin
  if core.rol_actual() <> 'servicio' then
    raise exception 'Solo el servidor registra códigos' using errcode = '42501';
  end if;
  if coalesce(p_mensaje_id, '') = '' or coalesce(p_telefono, '') !~ '^\d{10,15}$' or coalesce(p_codigo, '') !~ '^\d{4,10}$' then
    raise exception 'datos_invalidos' using errcode = '22023';
  end if;
  insert into core.codigos_enviados (mensaje_id, telefono, codigo_cifrado, version_llave)
  values (p_mensaje_id, p_telefono, core.cifrar(p_codigo, v_version), v_version)
  on conflict (mensaje_id) do nothing;
end
$$;

create function api.resolver_codigo_enviado(p_mensaje_id text, p_entregado boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v core.codigos_enviados;
begin
  if core.rol_actual() <> 'servicio' then
    raise exception 'Solo el servidor resuelve códigos' using errcode = '42501';
  end if;
  delete from core.codigos_enviados where mensaje_id = p_mensaje_id returning * into v;
  if v.mensaje_id is null or p_entregado or v.expira_en < now() then
    return null;
  end if;
  return jsonb_build_object('telefono', v.telefono, 'codigo', core.descifrar(v.codigo_cifrado, v.version_llave));
end
$$;

revoke execute on function api.registrar_codigo_enviado(text, text, text), api.resolver_codigo_enviado(text, boolean)
  from public, anon, authenticated;
grant execute on function api.registrar_codigo_enviado(text, text, text), api.resolver_codigo_enviado(text, boolean)
  to service_role;

-- Los que nunca recibieron estado (ni entregado ni fallido) se borran al vencer
select cron.schedule('sd-codigos-vencidos', '*/5 * * * *',
  $$delete from core.codigos_enviados where expira_en < now()$$);
