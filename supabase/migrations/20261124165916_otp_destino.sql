-- =====================================================================
-- OTP: destino = teléfono REGISTRADO del paciente
--   El código no se manda al número que llama (se puede falsificar el
--   identificador de llamada), sino al teléfono de mayor confianza que el
--   paciente tiene registrado: verificada > canal > declarada. Si alguien
--   suplanta el número, el código le llega a la persona real.
--   Si solo tiene uno declarado, va a ese: el OTP es justo lo que prueba
--   que lo tiene.
--   validar_otp verifica ESE teléfono (antes tomaba cualquiera con limit 1).
-- =====================================================================
alter table core.otp add column telefono_destino text;

create or replace function core.telefono_destino(p_paciente_id uuid)
returns text
language sql stable
set search_path = ''
as $$
  select valor from core.identidades_paciente
  where paciente_id = p_paciente_id and tipo = 'telefono' and eliminado_en is null
  order by core.rango_nivel(nivel_confianza) desc, actualizado_en desc
  limit 1
$$;
revoke execute on function core.telefono_destino(uuid) from public, anon, authenticated, service_role;

-- Solo service_role (la Edge Function enviar-otp). Devuelve el código y el
-- teléfono completo para enviarlo; al asesor solo le llegan expira_en y el
-- teléfono enmascarado. Máximo 3 códigos por paciente cada 10 minutos.
create or replace function api.solicitar_otp(p_interaccion_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int     core.interacciones;
  v_destino text;
  v_codigo  text;
  v_expira  timestamptz := now() + interval '5 minutes';
begin
  perform core.exigir_rol('servicio');
  v_int := core.cargar_interaccion(p_interaccion_id);
  v_destino := core.telefono_destino(v_int.paciente_id);
  if v_destino is null then
    raise exception 'El paciente no tiene un teléfono registrado' using errcode = 'PT404';
  end if;
  if not core.consumir_limite('otp:' || v_int.paciente_id, 3, 600) then
    raise sqlstate 'PT429' using message = 'Demasiados códigos solicitados';
  end if;
  v_codigo := lpad((('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint % 1000000)::text, 6, '0');
  insert into core.otp (paciente_id, interaccion_id, codigo_hash, expira_en, telefono_destino)
  values (v_int.paciente_id, v_int.id, encode(extensions.digest(v_codigo || v_int.id::text, 'sha256'), 'hex'),
          v_expira, v_destino);
  perform core.registrar_evento(v_int.paciente_id, v_int.tramite_id, v_int.id, 'otp_enviado',
                                jsonb_build_object('destino', core.enmascarar_telefono(v_destino)));
  return jsonb_build_object('codigo', v_codigo, 'expira_en', v_expira,
                            'telefono', v_destino, 'telefono_enmascarado', core.enmascarar_telefono(v_destino));
end
$$;

create or replace function api.validar_otp(p_interaccion_id uuid, p_codigo text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_otp core.otp;
begin
  select * into v_otp from core.otp
  where interaccion_id = v_int.id and usado_en is null and expira_en > now()
  order by creado_en desc limit 1 for update;

  if v_otp.id is null or v_otp.intentos >= 5 then
    return jsonb_build_object('verificado', false, 'motivo', 'sin_codigo_vigente');
  end if;

  if v_otp.codigo_hash = encode(extensions.digest(p_codigo || v_int.id::text, 'sha256'), 'hex') then
    update core.otp set usado_en = now() where id = v_otp.id;
    update core.interacciones set nivel_verificacion = 'verificada', metodo_verificacion = 'otp'
    where paciente_id = v_int.paciente_id and id = v_int.id;
    -- Se verifica el teléfono al que se ENVIÓ el código (filas previas: el de mayor confianza)
    perform core.vincular_identidad(v_int.paciente_id, 'telefono',
      coalesce(v_otp.telefono_destino, core.telefono_destino(v_int.paciente_id)), 'verificada', v_int.canal);
    perform core.registrar_evento(v_int.paciente_id, v_int.tramite_id, v_int.id, 'identidad_verificada',
                                  jsonb_build_object('metodo', 'otp'));
    return jsonb_build_object('verificado', true,
                              'contexto', core.contexto_json(core.cargar_interaccion(p_interaccion_id)));
  end if;

  update core.otp set intentos = intentos + 1 where id = v_otp.id;
  perform core.registrar_evento(v_int.paciente_id, v_int.tramite_id, v_int.id, 'verificacion_fallida',
                                jsonb_build_object('metodo', 'otp'));
  return jsonb_build_object('verificado', false, 'motivo', 'codigo_incorrecto');
end
$$;
