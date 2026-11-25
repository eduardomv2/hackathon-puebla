-- Horarios de atención, días inhábiles y horarios disponibles.
create extension if not exists pgtap with schema extensions;
begin;
select plan(10);
\ir ../helpers.psql

-- El próximo domingo (a partir de mañana) y los días siguientes, en hora de México
select d as domingo, d + 1 as lunes, d + 2 as martes
from (select m + ((7 - extract(dow from m)::int) % 7) as d
      from (select (now() at time zone 'America/Mexico_City')::date + 1 as m) x) y \gset

-- Horario real de Puebla (PUE-CEN): lunes a viernes 6:00 a 19:00, domingo 6:30 a 14:00
select tests.como_anon();
select api.horarios_disponibles(tests.clinica('PUE-CEN'), tests.estudio('BH'), :'domingo', 1) as dom \gset
select is(jsonb_array_length((:'dom')::jsonb), 15, 'El domingo, de 6:30 a 14:00 cada 30 min: 15 horarios');
select is(jsonb_array_length(api.horarios_disponibles(tests.clinica('gran-terraza-coapa-tlalpan'), tests.estudio('BH'), :'domingo', 1)), 0,
          'Una clínica que no abre en domingo no ofrece horarios');
select api.horarios_disponibles(tests.clinica('PUE-CEN'), tests.estudio('BH'), :'lunes', 1) as lun \gset
select is(jsonb_array_length((:'lun')::jsonb), 26, 'El lunes, de 6:00 a 19:00 cada 30 min: 26 horarios');
select is((:'lun')::jsonb -> 0 ->> 'hora', '06:00', 'empezando a las 6:00');

-- Día inhábil para todas las clínicas
select tests.como_postgres();
insert into core.dias_inhabiles (clinica_id, fecha, motivo) values (null, :'lunes', 'Festivo de prueba');
select tests.como_anon();
select is(jsonb_array_length(api.horarios_disponibles(tests.clinica('PUE-CEN'), tests.estudio('BH'), :'lunes', 1)), 0,
          'Un día inhábil no ofrece horarios');

-- Un horario lleno desaparece (ultrasonido: 2 por horario)
select ((:'martes'::date + time '10:00') at time zone 'America/Mexico_City') as diez \gset
select set_config('prueba.diez', :'diez', true) is not null as x \gset
select tests.como_servicio();
do $$
begin
  for n in 1 .. 2 loop
    declare
      v_int uuid := (api.iniciar_contacto('whatsapp', '22211103' || lpad(n::text, 2, '0'), 'ia', 'canal') #>> '{sesion,interaccion_id}')::uuid;
      v_t   uuid;
    begin
      perform tests.registrar(v_int);
      v_t := (api.iniciar_tramite(v_int, tests.estudio('US-OBS')) ->> 'id')::uuid;
      perform api.reservar_cita(v_int, v_t, tests.hasta_horario(v_int, v_t, 1, 'US-OBS'), current_setting('prueba.diez')::timestamptz);
    end;
  end loop;
end $$;
select ok(not exists (select 1 from jsonb_array_elements(api.horarios_disponibles(tests.clinica('PUE-CEN'), tests.estudio('US-OBS'), :'martes', 1)) h
                      where h ->> 'hora' = '10:00'),
          'Un horario lleno ya no se ofrece');

-- Reservar fuera del horario de atención
select api.iniciar_contacto('whatsapp', '2221110399', 'ia', 'canal') #>> '{sesion,interaccion_id}' as i \gset
select tests.registrar(:'i');
select api.iniciar_tramite(:'i', tests.estudio('BH')) ->> 'id' as t \gset
select tests.hasta_horario(:'i', :'t', 1) as v \gset
select throws_ok(format('select api.reservar_cita(%L, %L, %s, %L)', :'i', :'t', :v,
                        (:'martes'::date + time '03:00') at time zone 'America/Mexico_City'),
                 '22023', 'horario_fuera_de_atencion', 'Reservar a las 3:00 falla');
select throws_ok(format('select api.reservar_cita(%L, %L, %s, %L)', :'i', :'t', :v,
                        (:'martes'::date + time '09:10') at time zone 'America/Mexico_City'),
                 '22023', 'horario_fuera_de_atencion', 'Reservar a las 9:10 (fuera del intervalo) falla');

-- La zona horaria de la clínica se respeta
select tests.como_postgres();
update core.clinicas set zona_horaria = 'America/Tijuana' where clave = 'MTY-CEN';
select tests.como_anon();
select api.horarios_disponibles(tests.clinica('MTY-CEN'), tests.estudio('BH'), :'martes', 1) -> 0 as tj \gset
select is((:'tj')::jsonb ->> 'hora', '06:00', 'La primera hora es 6:00 local de la clínica');
select is(((:'tj')::jsonb ->> 'fecha_hora')::timestamptz, (:'martes'::date + time '06:00') at time zone 'America/Tijuana',
          'que corresponde a las 6:00 de Tijuana, no de Monterrey');

select finish();
rollback;
