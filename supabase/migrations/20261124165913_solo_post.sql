-- =====================================================================
-- La API solo acepta POST
--   PostgREST ejecuta todo GET/HEAD en una transacción de solo lectura,
--   aunque la función sea VOLATILE. El contador del rate limit escribe en
--   core.rate_limit, así que no puede contar esas peticiones: con GET se
--   podía llamar cualquier función de lectura sin límite.
--   Ahora toda petición de solo lectura se rechaza con PT405 (HTTP 405),
--   para TODOS los roles (incluido service_role), sin excepciones.
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
    raise sqlstate 'PT405' using message = 'Usa POST', hint = 'Todas las funciones de la API se llaman con POST';
  end if;

  if v_rol = 'servicio' then
    v_tel := nullif(btrim(coalesce(nullif(current_setting('request.headers', true), ''), '{}')::json ->> 'x-sd-telefono'), '');
    if v_tel is null then
      return;  -- tareas internas: exentas
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
