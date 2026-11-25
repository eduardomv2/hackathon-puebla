-- Cobro en caja: recepción cobra en la clínica una cita apartada que no se pagó en línea.
-- Deja el pago, la cita y el trámite igual que un pago en línea (api.confirmar_pago) y los mismos
-- eventos, con canal clínica y el método (efectivo o tarjeta), así que todos los canales lo ven.

create or replace function api.cobrar_en_caja(p_cita_id uuid, p_metodo text default 'efectivo')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cita    core.citas;
  v_pago    core.pagos;
  v_folio   text;
  v_ref     text;
begin
  perform core.exigir_rol('recepcion', 'supervisor', 'admin');
  perform core.establecer_actor('clinica');
  if p_metodo is null or p_metodo not in ('efectivo', 'tarjeta') then
    raise exception 'Método de pago inválido: usa efectivo o tarjeta' using errcode = '22023';
  end if;

  select * into v_cita from core.citas where id = p_cita_id and eliminado_en is null for update;
  if not found then
    raise exception 'Cita no encontrada' using errcode = 'PT404';
  end if;
  perform core.validar_alcance_clinica(v_cita.clinica_id);
  if exists (select 1 from core.pagos where paciente_id = v_cita.paciente_id and cita_id = v_cita.id and estado = 'pagado') then
    raise exception 'La cita ya está pagada' using errcode = 'P0001';
  end if;
  if v_cita.estado not in ('reservada', 'en_clinica') then
    raise exception 'La cita está %', v_cita.estado using errcode = '22023';
  end if;

  -- Se usa el pago pendiente que ya exista (link en línea) o se crea uno para la caja
  select * into v_pago from core.pagos
  where paciente_id = v_cita.paciente_id and cita_id = v_cita.id and estado = 'pendiente'
  order by creado_en desc limit 1 for update;
  if not found then
    v_ref := 'CJ-' || upper(encode(extensions.gen_random_bytes(6), 'hex'));
    insert into core.pagos (paciente_id, cita_id, monto, referencia_externa, link_pago, expira_en)
    values (v_cita.paciente_id, v_cita.id, v_cita.precio, v_ref, null, now() + interval '1 hour')
    returning * into v_pago;
    perform core.registrar_evento(v_cita.paciente_id, v_cita.tramite_id, null, 'pago_generado',
      jsonb_build_object('pago_id', v_pago.id, 'monto', v_pago.monto, 'referencia', v_ref, 'en_caja', true));
  end if;

  update core.pagos set estado = 'pagado', pagado_en = now()
  where paciente_id = v_pago.paciente_id and id = v_pago.id;
  -- Si ya llegó, sigue en la clínica
  update core.citas set estado = case when estado = 'en_clinica' then estado else 'confirmada' end
  where paciente_id = v_cita.paciente_id and id = v_cita.id;
  update core.tramites
  set contexto = contexto || jsonb_build_object('pago_id', v_pago.id),
      paso_actual = 'confirmada', estado = 'completado', finalizado_en = now(),
      version = version + 1, ultimo_canal = 'clinica', ultima_actividad_en = now()
  where paciente_id = v_cita.paciente_id and id = v_cita.tramite_id and estado in ('activo', 'pausado')
  returning folio into v_folio;

  perform core.registrar_evento(v_cita.paciente_id, v_cita.tramite_id, null, 'pago_confirmado',
    jsonb_build_object('pago_id', v_pago.id, 'monto', v_pago.monto, 'metodo', p_metodo, 'en_caja', true));
  perform core.registrar_evento(v_cita.paciente_id, v_cita.tramite_id, null, 'cita_confirmada',
    jsonb_build_object('cita_id', v_cita.id, 'fecha_hora', v_cita.fecha_hora));
  if v_folio is not null then
    perform core.registrar_evento(v_cita.paciente_id, v_cita.tramite_id, null, 'tramite_completado', '{}');
  end if;

  return jsonb_build_object('pago_id', v_pago.id, 'estado', 'pagado', 'monto', v_pago.monto, 'metodo', p_metodo,
    'cita_id', v_cita.id,
    'folio', coalesce(v_folio, (select folio from core.tramites where paciente_id = v_cita.paciente_id and id = v_cita.tramite_id)));
end
$$;
revoke execute on function api.cobrar_en_caja(uuid, text) from public, anon;
grant execute on function api.cobrar_en_caja(uuid, text) to authenticated;
