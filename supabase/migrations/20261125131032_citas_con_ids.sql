-- Ya verificada, cada cita próxima trae los ids de su clínica y estudio y si está pagada,
-- para operarla desde la cita (cambiar horario, cobrar en caja o cancelar) aunque su trámite ya cerró.

CREATE OR REPLACE FUNCTION core.contexto_json(p_interaccion core.interacciones)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_pac      core.pacientes;
  v_tramite  core.tramites;
  v_nivel    int := core.rango_nivel(p_interaccion.nivel_verificacion);
  v_telefono text;
begin
  select * into v_pac from core.pacientes where id = p_interaccion.paciente_id;
  select * into v_tramite from core.tramites
  where paciente_id = p_interaccion.paciente_id and id = p_interaccion.tramite_id
    and estado in ('activo', 'pausado') and eliminado_en is null;
  select valor into v_telefono from core.identidades_paciente
  where paciente_id = v_pac.id and tipo = 'telefono' and eliminado_en is null
  order by core.rango_nivel(nivel_confianza) desc limit 1;

  if v_nivel = 0 then
    -- Sin verificar: solo cuántos trámites hay, su folio y su paso (sin estudio ni persona)
    return jsonb_build_object(
      'sesion', jsonb_build_object('interaccion_id', p_interaccion.id, 'canal', p_interaccion.canal,
                                   'nivel_verificacion', p_interaccion.nivel_verificacion,
                                   'requiere_verificacion', true,
                                   'metodos', jsonb_build_array('fecha_nacimiento', 'otp')),
      'paciente', jsonb_build_object('id', v_pac.id, 'tiene_fecha_nacimiento', v_pac.fecha_nacimiento is not null),
      'tramite_activo', case when v_tramite.id is null then null else jsonb_build_object(
                          'id', v_tramite.id, 'folio', v_tramite.folio, 'tipo', v_tramite.tipo,
                          'paso_actual', v_tramite.paso_actual) end,
      'tramites_abiertos', (
        select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'folio', t.folio, 'paso_actual', t.paso_actual)
                                  order by t.ultima_actividad_en desc), '[]')
        from core.tramites t
        where t.paciente_id = v_pac.id and t.estado in ('activo', 'pausado') and t.eliminado_en is null
          and t.contexto ? 'estudio_id' /* los trámites sin estudio no se ofrecen */),
      'citas_proximas', (
        select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'folio', t.folio, 'fecha_hora', c.fecha_hora,
                                                     'estado', c.estado) order by c.fecha_hora), '[]')
        from core.citas c
        left join core.tramites t on t.paciente_id = c.paciente_id and t.id = c.tramite_id
        where c.paciente_id = v_pac.id and c.estado in ('reservada', 'confirmada', 'en_clinica')
          and c.fecha_hora >= now() - interval '1 day' and c.eliminado_en is null));
  end if;

  return jsonb_build_object(
    'sesion', jsonb_build_object('interaccion_id', p_interaccion.id, 'canal', p_interaccion.canal,
                                 'nivel_verificacion', p_interaccion.nivel_verificacion,
                                 'requiere_verificacion', false,
                                 -- Campos que faltan para iniciar trámites (vacío = registro completo)
                                 'requiere_registro', to_jsonb(core.faltantes_registro(v_pac.id))),
    'paciente', jsonb_build_object(
      'id', v_pac.id,
      'estado', v_pac.estado,
      'nombre', case when v_nivel = 2 then nullif(concat_ws(' ', v_pac.nombre, v_pac.apellido_paterno, v_pac.apellido_materno), '')
                     else v_pac.nombre end,
      'nombre_mostrar', core.nombre_para_mostrar(v_pac.id, v_nivel = 2),
      'telefono', core.enmascarar_telefono(v_telefono),
      'tiene_fecha_nacimiento', v_pac.fecha_nacimiento is not null,
      'avisos_whatsapp', core.telefono_avisos(v_pac.id) is not null),
    'tramite_activo', case when v_tramite.id is null then null
                           else core.tramite_json(v_tramite) || jsonb_build_object(
                             'en_atencion_de_otro', core.en_atencion_de_otro(v_tramite, p_interaccion.id),
                             'atendido_por_mi', v_tramite.atendido_por_interaccion = p_interaccion.id
                                                and v_tramite.atencion_hasta > now()) end,
    'tramites_abiertos', (
      select coalesce(jsonb_agg(core.tramite_tarjeta(t, p_interaccion.id) order by t.ultima_actividad_en desc), '[]')
      from core.tramites t
      where t.paciente_id = v_pac.id and t.estado in ('activo', 'pausado') and t.eliminado_en is null
          and t.contexto ? 'estudio_id' /* los trámites sin estudio no se ofrecen */),
    'linea_tiempo', (
      select coalesce(jsonb_agg(x order by x ->> 'ocurrido_en' desc), '[]') from (
        select jsonb_build_object('ocurrido_en', ev.ocurrido_en, 'tipo_evento', ev.tipo_evento, 'canal', ev.canal,
                                  'actor_tipo', ev.actor_tipo, 'tramite_id', ev.tramite_id, 'payload', ev.payload) as x
        from core.eventos_tramite ev
        where ev.paciente_id = v_pac.id
          and ev.tipo_evento not in ('asesor_consulto_contexto', 'resumen_actualizado')
        order by ev.ocurrido_en desc limit 20) s),
    'mensajes_recientes', (
      select coalesce(jsonb_agg(jsonb_build_object('creado_en', s.creado_en, 'canal', s.canal, 'autor', s.autor,
                                                   'contenido', core.descifrar(s.contenido_cifrado, s.clave_version))
                                order by s.creado_en), '[]')
      from (select m.creado_en, m.canal, m.autor, m.contenido_cifrado, m.clave_version
            from core.mensajes m
            where m.paciente_id = v_pac.id
            order by m.creado_en desc limit 10) s),
    'citas_proximas', (
      select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'fecha_hora', c.fecha_hora, 'estado', c.estado,
                                                   'estudio', e.nombre, 'clinica', cl.nombre, 'precio', c.precio,
                                                   'folio', t.folio,
                                                   'clinica_id', c.clinica_id, 'estudio_id', c.estudio_id,
                                                   'pagada', exists (select 1 from core.pagos p where p.paciente_id = c.paciente_id
                                                                     and p.cita_id = c.id and p.estado = 'pagado'),
                                                   'turno', c.turno, 'llegada_en', c.llegada_en,
                                                   'area', core.nombre_area(e.area),
                                                   'beneficiario', jsonb_build_object('id', b.id, 'nombre', b.nombre,
                                                                                      'relacion', c.relacion))
                                order by c.fecha_hora), '[]')
      from core.citas c
      join core.estudios e on e.id = c.estudio_id
      join core.clinicas cl on cl.id = c.clinica_id
      join core.pacientes b on b.id = c.beneficiario_id
      left join core.tramites t on t.paciente_id = c.paciente_id and t.id = c.tramite_id
      where c.paciente_id = v_pac.id and c.eliminado_en is null
        and (c.estado in ('reservada', 'confirmada') and c.fecha_hora >= now() or c.estado = 'en_clinica')),
    'pagos_pendientes', (
      select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'monto', p.monto, 'link_pago', p.link_pago,
                                                   'expira_en', p.expira_en, 'folio', t.folio)), '[]')
      from core.pagos p
      join core.citas c on c.paciente_id = p.paciente_id and c.id = p.cita_id
      left join core.tramites t on t.paciente_id = c.paciente_id and t.id = c.tramite_id
      where p.paciente_id = v_pac.id and p.estado = 'pendiente' and p.expira_en > now())
  );
end
$function$;
