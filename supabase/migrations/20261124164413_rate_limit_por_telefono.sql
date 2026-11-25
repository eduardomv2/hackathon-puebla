-- =====================================================================
-- Rate limit por teléfono del paciente para las Edge Functions
--   service_role estaba exento del pre-request: un endpoint público como el
--   webhook de WhatsApp podía generar llamadas sin freno. El pre-request no
--   ve el cuerpo de la petición, así que la Edge Function declara el
--   teléfono del paciente en el header x-sd-telefono:
--     · con header  → contador 'tel:<teléfono normalizado>', 60 por minuto
--                     (un mensaje de WhatsApp son 4–6 llamadas)
--     · sin header  → exento (tareas internas: pagos, workers, cron)
--   Solo quien tiene la clave secreta puede mandar el header con rol
--   service_role, así que nadie lo usa para gastar el cupo de otra persona.
--   Las lecturas (GET, transacción de solo lectura) siguen sin contar.
-- =====================================================================
create or replace function core.verificar_peticion()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rol    text := core.rol_actual();
  v_tel    text;
  v_clave  text;
  v_limite int;
begin
  if current_setting('transaction_read_only', true) = 'on' then
    return;
  end if;

  if v_rol = 'servicio' then
    v_tel := nullif(btrim(coalesce(nullif(current_setting('request.headers', true), ''), '{}')::json ->> 'x-sd-telefono'), '');
    if v_tel is null then
      return;
    end if;
    begin
      v_tel := core.normalizar_identidad('telefono', v_tel);
    exception when others then
      raise exception 'Header x-sd-telefono inválido' using errcode = '22023';
    end;
    v_clave  := 'tel:' || v_tel;
    v_limite := 60;
  else
    v_clave  := coalesce(auth.uid()::text, 'ip:' || core.ip_actual(), 'desconocido');
    v_limite := case v_rol when 'anonimo' then 30 when 'paciente' then 120 else 600 end;
  end if;

  if not core.consumir_limite('api:' || v_clave, v_limite, 60) then
    raise sqlstate 'PT429' using message = 'Demasiadas solicitudes', hint = 'Intenta de nuevo en un minuto';
  end if;
end
$$;
