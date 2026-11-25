-- =====================================================================
-- Pago de prueba (PAGO_DEMO) y link de pago configurable
--   · Link de pago: <pago_url_base>/pagar/<referencia>, con pago_url_base en
--     Vault (la URL de la app que tiene la pantalla de pago). Sin ese secreto,
--     link_pago queda nulo: los canales indican cómo pagar (p. ej. "responde
--     PAGAR" en WhatsApp con el pago de prueba encendido).
--   · api.pagos_pendientes(interaccion): los pagos pendientes y sin vencer del
--     paciente de la interacción, con monto, estudio y para quién. Solo el
--     propio paciente (su sesión) o el servidor (el bot); el personal no.
--   · api.pago_del_paciente(interaccion, referencia): ese pago si es suyo
--     (pendiente, pagado o vencido); si no, null.
--   · api.confirmar_pago guarda en el evento pago_confirmado si fue simulado
--     (p_datos.simulado = true), para distinguirlo del webhook real.
--   Pagar sigue siendo SOLO del servidor (api.confirmar_pago exige service_role):
--   la Edge Function pago-demo y el bot llaman ese mismo camino.
-- =====================================================================

create or replace function core.link_pago(p_referencia text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select rtrim(decrypted_secret, '/') || '/pagar/' || p_referencia
  from vault.decrypted_secrets where name = 'pago_url_base' and coalesce(decrypted_secret, '') <> ''
$$;
revoke execute on function core.link_pago(text) from public, anon, authenticated, service_role;

create or replace function api.generar_pago(p_interaccion_id uuid, p_tramite_id uuid, p_version int)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int     core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_tramite core.tramites;
  v_pago    core.pagos;
  v_cita    core.citas;
  v_ref     text;
begin
  v_tramite := core.bloquear_tramite(v_int, p_tramite_id, p_version);
  if v_tramite.paso_actual <> 'pago' then
    raise exception 'El trámite no está en el paso de pago' using errcode = 'P0001';
  end if;
  select * into v_cita from core.citas
  where paciente_id = v_tramite.paciente_id and id = (v_tramite.contexto ->> 'cita_id')::uuid;

  select * into v_pago from core.pagos
  where paciente_id = v_cita.paciente_id and cita_id = v_cita.id and estado = 'pendiente' and expira_en > now()
  order by creado_en desc limit 1;

  if not found then
    v_ref := 'SD-' || upper(encode(extensions.gen_random_bytes(6), 'hex'));
    insert into core.pagos (paciente_id, cita_id, monto, referencia_externa, link_pago, expira_en)
    values (v_cita.paciente_id, v_cita.id, v_cita.precio, v_ref, core.link_pago(v_ref),
            least(now() + interval '24 hours', v_cita.fecha_hora - interval '1 hour'))
    returning * into v_pago;
    perform core.registrar_evento(v_int.paciente_id, v_tramite.id, v_int.id, 'pago_generado',
      jsonb_build_object('pago_id', v_pago.id, 'monto', v_pago.monto, 'referencia', v_ref));
  end if;

  update core.tramites
  set contexto = contexto || jsonb_build_object('pago_id', v_pago.id),
      version = version + 1, ultimo_canal = v_int.canal, ultima_actividad_en = now()
  where paciente_id = v_tramite.paciente_id and id = v_tramite.id;

  return jsonb_build_object('pago_id', v_pago.id, 'referencia', v_pago.referencia_externa,
                            'monto', v_pago.monto, 'moneda', v_pago.moneda,
                            'link_pago', v_pago.link_pago, 'expira_en', v_pago.expira_en,
                            'version', v_tramite.version + 1);
end
$$;

create or replace function api.pagos_pendientes(p_interaccion_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_int core.interacciones := core.cargar_interaccion(p_interaccion_id);
begin
  if core.rol_actual() not in ('paciente', 'servicio') then
    raise exception 'Solo el paciente ve sus pagos pendientes' using errcode = '42501';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'referencia', p.referencia_externa, 'monto', p.monto, 'moneda', p.moneda,
             'estudio', e.nombre, 'etiqueta', core.etiqueta_tramite(t), 'folio', t.folio,
             'tramite_id', t.id, 'fecha_hora', c.fecha_hora, 'expira_en', p.expira_en,
             'link_pago', p.link_pago)
           order by p.creado_en), '[]')
    from core.pagos p
    join core.citas c on c.paciente_id = p.paciente_id and c.id = p.cita_id
    join core.tramites t on t.paciente_id = c.paciente_id and t.id = c.tramite_id
    join core.estudios e on e.id = c.estudio_id
    where p.paciente_id = v_int.paciente_id
      and p.estado = 'pendiente' and p.expira_en > now() and p.eliminado_en is null);
end
$$;

revoke execute on function api.pagos_pendientes(uuid) from public, anon;
grant execute on function api.pagos_pendientes(uuid) to authenticated, service_role;

-- Un pago del paciente de la interacción por su referencia (pendiente, pagado o vencido);
-- null si no existe o es de otra persona. Para que pagar dos veces responda igual.
create or replace function api.pago_del_paciente(p_interaccion_id uuid, p_referencia text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_int core.interacciones := core.cargar_interaccion(p_interaccion_id);
begin
  if core.rol_actual() not in ('paciente', 'servicio') then
    raise exception 'Solo el paciente consulta sus pagos' using errcode = '42501';
  end if;
  return (
    select jsonb_build_object('referencia', p.referencia_externa, 'estado', p.estado, 'monto', p.monto,
             'moneda', p.moneda, 'estudio', e.nombre, 'folio', t.folio, 'expira_en', p.expira_en,
             'vencido', p.expira_en <= now())
    from core.pagos p
    join core.citas c on c.paciente_id = p.paciente_id and c.id = p.cita_id
    join core.tramites t on t.paciente_id = c.paciente_id and t.id = c.tramite_id
    join core.estudios e on e.id = c.estudio_id
    where p.paciente_id = v_int.paciente_id and p.referencia_externa = p_referencia and p.eliminado_en is null);
end
$$;

revoke execute on function api.pago_del_paciente(uuid, text) from public, anon;
grant execute on function api.pago_del_paciente(uuid, text) to authenticated, service_role;

create or replace function api.confirmar_pago(p_referencia text, p_estado text, p_datos jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pago core.pagos;
  v_cita core.citas;
  v_tramite core.tramites;
begin
  perform core.exigir_rol('servicio');
  perform core.establecer_actor('sistema', 'sistema');
  if p_estado not in ('pagado', 'fallido') then
    raise exception 'Estado de pago inválido: %', p_estado using errcode = '22023';
  end if;

  select * into v_pago from core.pagos where referencia_externa = p_referencia for update;
  if not found then
    raise exception 'Pago no encontrado' using errcode = 'PT404';
  end if;
  if v_pago.estado = p_estado then
    return jsonb_build_object('pago_id', v_pago.id, 'estado', v_pago.estado, 'repetido', true);
  end if;
  if v_pago.estado <> 'pendiente' then
    raise exception 'El pago ya está %', v_pago.estado using errcode = 'P0001';
  end if;

  update core.pagos set estado = p_estado, pagado_en = case when p_estado = 'pagado' then now() end
  where paciente_id = v_pago.paciente_id and id = v_pago.id;
  select * into v_cita from core.citas where paciente_id = v_pago.paciente_id and id = v_pago.cita_id;

  if p_estado = 'fallido' then
    perform core.registrar_evento(v_pago.paciente_id, v_cita.tramite_id, null, 'pago_fallido',
                                  jsonb_build_object('pago_id', v_pago.id, 'detalle', p_datos));
    return jsonb_build_object('pago_id', v_pago.id, 'estado', 'fallido');
  end if;

  -- Si ya llegó a la clínica (pagó en caja), sigue en_clinica
  update core.citas set estado = case when estado = 'en_clinica' then estado else 'confirmada' end where paciente_id = v_cita.paciente_id and id = v_cita.id;
  update core.tramites
  set contexto = contexto || jsonb_build_object('pago_id', v_pago.id),
      paso_actual = 'confirmada', estado = 'completado', finalizado_en = now(),
      version = version + 1, ultima_actividad_en = now()
  where paciente_id = v_cita.paciente_id and id = v_cita.tramite_id
  returning * into v_tramite;

  perform core.registrar_evento(v_pago.paciente_id, v_cita.tramite_id, null, 'pago_confirmado',
                                jsonb_strip_nulls(jsonb_build_object('pago_id', v_pago.id, 'monto', v_pago.monto,
                                  'simulado', nullif(coalesce(p_datos ->> 'simulado', '') = 'true', false))));
  perform core.registrar_evento(v_pago.paciente_id, v_cita.tramite_id, null, 'cita_confirmada',
                                jsonb_build_object('cita_id', v_cita.id, 'fecha_hora', v_cita.fecha_hora));
  perform core.registrar_evento(v_pago.paciente_id, v_cita.tramite_id, null, 'tramite_completado', '{}');
  return jsonb_build_object('pago_id', v_pago.id, 'estado', 'pagado', 'cita_id', v_cita.id, 'tramite_id', v_tramite.id);
end
$$;

-- Aviso por plantilla del link de pago: sin link (no hay pago_url_base), indica responder PAGAR
create or replace function core.armar_aviso(ev core.eventos_tramite)
returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  t        core.tramites;
  v_et     text;
  v_canal  text := case ev.canal when 'web' then 'la web' when 'app' then 'la app' when 'call_center' then 'la llamada'
                                 when 'clinica' then 'la clínica' else null end;
  v_desde  text;
  v_fecha  text;
  v_zona   text;
  v_link   text;
  v_clin   text;
begin
  select * into t from core.tramites where paciente_id = ev.paciente_id and id = ev.tramite_id;
  if not found then return null; end if;
  v_et    := core.etiqueta_tramite(t);
  v_desde := case when v_canal is null then '' else 'Desde ' || v_canal || ': ' end;
  select c.zona_horaria, c.nombre into v_zona, v_clin from core.clinicas c where c.id = t.clinica_id;
  v_fecha := to_char((t.contexto ->> 'fecha_hora')::timestamptz at time zone coalesce(v_zona, 'America/Mexico_City'),
                     'DD/MM/YYYY "a las" HH24:MI');

  case ev.tipo_evento
    when 'pago_generado' then
      select link_pago into v_link from core.pagos where paciente_id = ev.paciente_id and id = (ev.payload ->> 'pago_id')::uuid;
      return jsonb_build_object('plantilla', 'link_pago', 'variables',
        jsonb_build_object('etiqueta', v_et, 'folio', t.folio, 'fecha', v_fecha,
          'link', coalesce(v_link, 'responde PAGAR en este chat')));
    when 'cita_confirmada' then
      return jsonb_build_object('plantilla', 'cita_confirmada', 'variables',
        jsonb_build_object('etiqueta', v_et, 'folio', t.folio, 'fecha', v_fecha, 'clinica', v_clin));
    when 'atencion_iniciada' then
      return jsonb_build_object('plantilla', case when ev.canal = 'clinica' then 'recepcion_atendiendo' else 'asesor_atendiendo' end,
        'variables',
        jsonb_build_object('etiqueta', v_et, 'folio', t.folio));
    when 'recordatorio_programado' then
      return jsonb_build_object('plantilla', 'recordatorio_tramite_pendiente', 'variables',
        jsonb_build_object('etiqueta', v_et, 'folio', t.folio,
                           'paso', (select descripcion from core.flujo_tramite where tipo_tramite = t.tipo and paso = t.paso_actual)));
    when 'tramite_iniciado' then
      return jsonb_build_object('texto', v_desde || 'iniciaste el trámite ' || v_et || ' (folio ' || t.folio || ').');
    when 'paso_avanzado' then
      return jsonb_build_object('texto', v_desde || v_et || ' (folio ' || t.folio || ') ahora va en «' ||
        (select descripcion from core.flujo_tramite where tipo_tramite = t.tipo and paso = ev.payload ->> 'a') || '».');
    when 'cita_reservada' then
      return jsonb_build_object('texto', v_desde || 'se apartó tu cita de ' || v_et || ' para el ' || v_fecha || '.');
    when 'pago_fallido' then
      return jsonb_build_object('texto', 'El pago de ' || v_et || ' (folio ' || t.folio || ') fue rechazado. Puedes intentarlo de nuevo.');
    when 'tramite_cancelado' then
      return jsonb_build_object('texto', 'Se canceló tu trámite ' || v_et || ' (folio ' || t.folio || ').');
    when 'tramite_abandonado' then
      return jsonb_build_object('texto', 'Tu trámite ' || v_et || ' (folio ' || t.folio || ') venció por inactividad.');
    when 'atencion_liberada' then
      return jsonb_build_object('texto', 'El asesor terminó de atender ' || v_et || ' (folio ' || t.folio || '); puedes seguir por aquí.');
    else
      return null;
  end case;
end
$$;

-- Los pagos pendientes con el link de ejemplo anterior pasan al formato nuevo (o a nulo sin pago_url_base)
update core.pagos set link_pago = core.link_pago(referencia_externa)
where link_pago like 'https://pagos.ejemplo.mx/checkout/%';
