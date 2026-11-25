-- Comprobante de pago y cita: todo lo que lleva el PDF en una sola llamada.
-- Lo piden el paciente (su cita) y el personal con la identidad ya verificada (recepción solo de su clínica).
-- El PDF lo arma cada app con estos datos: aquí no hay lógica de presentación.

create or replace function api.comprobante_cita(p_interaccion_id uuid, p_cita_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int  core.interacciones := core.cargar_interaccion(p_interaccion_id);
  v_cita core.citas;
  v_pago core.pagos;
  v_ev   jsonb;
begin
  if v_int.nivel_verificacion <> 'verificada' then
    raise exception 'Verifica la identidad para ver el comprobante' using errcode = '42501';
  end if;

  select * into v_cita from core.citas
  where id = p_cita_id and paciente_id = v_int.paciente_id and eliminado_en is null;
  if not found then
    raise exception 'Cita no encontrada' using errcode = 'PT404';
  end if;
  if core.rol_actual() = 'recepcion' then
    perform core.validar_alcance_clinica(v_cita.clinica_id);
  end if;

  -- El pago que cuenta: el pagado o reembolsado, si no el más reciente
  select * into v_pago from core.pagos
  where paciente_id = v_cita.paciente_id and cita_id = v_cita.id and eliminado_en is null
  order by (estado in ('pagado', 'reembolsado')) desc, creado_en desc limit 1;

  if v_pago.id is not null then
    select payload into v_ev from core.eventos_tramite
    where paciente_id = v_cita.paciente_id and tramite_id = v_cita.tramite_id
      and tipo_evento = 'pago_confirmado' and payload ->> 'pago_id' = v_pago.id::text
    order by ocurrido_en desc limit 1;
  end if;

  return jsonb_build_object(
    'folio', (select t.folio from core.tramites t where t.paciente_id = v_cita.paciente_id and t.id = v_cita.tramite_id),
    'emitido_en', now(),
    'cita', jsonb_build_object('id', v_cita.id, 'estado', v_cita.estado, 'fecha_hora', v_cita.fecha_hora,
                               'turno', v_cita.turno, 'precio', v_cita.precio),
    'titular', (select nullif(btrim(concat_ws(' ', p.nombre, p.apellido_paterno, p.apellido_materno)), '')
                from core.pacientes p where p.id = v_cita.paciente_id),
    'paciente', (select jsonb_build_object('nombre', nullif(btrim(concat_ws(' ', b.nombre, b.apellido_paterno, b.apellido_materno)), ''),
                                           'relacion', v_cita.relacion)
                 from core.pacientes b where b.id = v_cita.beneficiario_id),
    'estudio', (select jsonb_build_object('nombre', e.nombre, 'preparacion', e.preparacion, 'duracion_min', e.duracion_min,
                                          'area', core.nombre_area(e.area))
                from core.estudios e where e.id = v_cita.estudio_id),
    'clinica', (select jsonb_build_object('nombre', c.nombre, 'direccion', c.direccion, 'ciudad', c.ciudad,
                                          'estado', c.estado, 'telefono', c.telefono, 'zona_horaria', c.zona_horaria)
                from core.clinicas c where c.id = v_cita.clinica_id),
    'pago', case when v_pago.id is null then null else jsonb_build_object(
              'referencia', v_pago.referencia_externa, 'estado', v_pago.estado, 'monto', v_pago.monto,
              'moneda', v_pago.moneda, 'pagado_en', v_pago.pagado_en,
              'metodo', coalesce(v_ev ->> 'metodo', case when coalesce((v_ev ->> 'simulado')::boolean, false) then 'en_linea_prueba' when v_ev is not null then 'en_linea' end),
              'en_caja', coalesce((v_ev ->> 'en_caja')::boolean, false),
              'simulado', coalesce((v_ev ->> 'simulado')::boolean, false)) end);
end
$$;
revoke execute on function api.comprobante_cita(uuid, uuid) from public, anon;
grant execute on function api.comprobante_cita(uuid, uuid) to authenticated, service_role;
