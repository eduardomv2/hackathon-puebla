-- Máximo 5 citas futuras por titular. La 6.ª no lanza excepción: responde
-- HTTP 409 (response.status) y el evento limite_citas_alcanzado QUEDA GUARDADO.
create extension if not exists pgtap with schema extensions;
begin;
select plan(7);
\ir ../helpers.psql

select tests.como_servicio();
select api.iniciar_contacto('whatsapp', '2221110070', 'ia', 'canal') #>> '{sesion,interaccion_id}' as i \gset
select tests.registrar(:'i');
select set_config('prueba.i', :'i', true) is not null as x \gset

-- 5 citas pagadas: 5 estudios distintos (el mismo estudio para la misma persona sería duplicado)
do $$
declare
  v_int uuid := current_setting('prueba.i')::uuid;
  t uuid;
  v int;
  estudios text[] := array['BH', 'QS6', 'US-OBS', 'US-ABD', 'MASTO'];
begin
  for n in 1 .. 5 loop
    t := (api.iniciar_tramite(v_int, tests.estudio(estudios[n])) ->> 'id')::uuid;
    v := tests.hasta_horario(v_int, t, 1, estudios[n]);
    v := (api.reservar_cita(v_int, t, v, tests.en_dias(n)) ->> 'version')::int;
    perform tests.pagar(v_int, t, v);
  end loop;
end $$;

-- La 6.ª: biometría para un familiar (no es duplicado, pero pasa el límite del titular)
select api.agregar_beneficiario(:'i', 'Luis', 'Pérez', null, '2016-07-01', null, 'hijo', true) ->> 'beneficiario_id' as hijo \gset
select api.iniciar_tramite(:'i', tests.estudio('BH'), :'hijo') ->> 'id' as t6 \gset
select tests.hasta_horario(:'i', :'t6', 1, 'BH', 'PUE-CEN', :'hijo') as v6 \gset
select api.reservar_cita(:'i', :'t6', :v6, tests.en_dias(10)) as r \gset
select is((:'r')::jsonb ->> 'error', 'limite_citas', 'La 6.ª cita futura se rechaza');
select is(((:'r')::jsonb ->> 'citas_futuras')::int, 5, 'e informa cuántas tiene');
select is(current_setting('response.status', true), '409', 'PostgREST responde HTTP 409');
select is(api.obtener_contexto(:'i') #>> '{tramite_activo,paso_actual}', 'seleccion_horario', 'El trámite no avanza');

select tests.como_postgres();
select is((select count(*)::int from core.eventos_tramite where tipo_evento = 'limite_citas_alcanzado' and tramite_id = :'t6'), 1,
          'El evento limite_citas_alcanzado queda guardado (señal para antispam)');
select is((select count(*)::int from core.citas c join core.interacciones i on i.paciente_id = c.paciente_id
           where i.id = :'i' and c.estado in ('reservada', 'confirmada')), 5, 'No se creó la 6.ª cita');

-- Se cancela una cita (4 futuras): la 6.ª ya cabe, y cambiarle el horario
-- no cuenta contra el límite (su propia reserva se reemplaza)
update core.citas set estado = 'cancelada'
where id = (select c.id from core.citas c join core.interacciones i on i.paciente_id = c.paciente_id
            where i.id = :'i' and c.estado = 'confirmada' order by c.fecha_hora limit 1);
select tests.como_servicio();
select set_config('response.status', '', true) is not null as x \gset
select api.reservar_cita(:'i', :'t6', :v6, tests.en_dias(10)) ->> 'version' as v7 \gset
select is(api.reservar_cita(:'i', :'t6', :v7, tests.en_dias(11)) ->> 'paso_actual', 'pago',
          'Con 5 citas, cambiar el horario de la propia reserva sí se permite');

select finish();
rollback;
