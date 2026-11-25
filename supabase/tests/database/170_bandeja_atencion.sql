-- Supervisión: bandeja de atención (conteos + lista paginada de una categoría) y búsqueda de pacientes.
create extension if not exists pgtap with schema extensions;
begin;
select plan(23);
\ir ../helpers.psql

\set sup     '00000000-0000-0000-0000-00000000c170'
\set supang  '00000000-0000-0000-0000-00000000c171'
\set admin   '00000000-0000-0000-0000-00000000c172'
\set asesora '00000000-0000-0000-0000-00000000c173'
\set rec     '00000000-0000-0000-0000-00000000c174'
select tests.clinica('PUE-CEN') as cen \gset
select tests.clinica('PUE-ANG') as ang \gset
select tests.crear_staff(:'sup', 'supervisor', :'cen');
select tests.crear_staff(:'supang', 'supervisor', :'ang');
select tests.crear_staff(:'admin', 'admin');
select tests.crear_staff(:'asesora', 'asesor');
select tests.crear_staff(:'rec', 'recepcion', :'cen');

-- Tres pacientes por WhatsApp con trámite en Puebla Centro (eligiendo horario)
select tests.como_servicio();
create temp table p (n int, i uuid, t uuid, pac uuid) on commit drop;
grant all on p to public;
do $$
declare v_i uuid; v_t uuid;
begin
  for n in 1 .. 3 loop
    v_i := (api.iniciar_contacto('whatsapp', '52186612346' || lpad(n::text, 2, '0'), 'ia', 'canal') #>> '{sesion,interaccion_id}')::uuid;
    perform tests.registrar(v_i, 'Paciente' || n, 'López');
    v_t := (api.iniciar_tramite(v_i, tests.estudio('BH')) ->> 'id')::uuid;
    perform tests.hasta_horario(v_i, v_t, 1, 'BH');
    insert into p values (n, v_i, v_t, (api.obtener_contexto(v_i) #>> '{paciente,id}')::uuid);
  end loop;
end $$;
select i as i1, t as t1, pac as p1 from p where n = 1 \gset
select i as i2, t as t2, pac as p2 from p where n = 2 \gset
select i as i3, t as t3, pac as p3 from p where n = 3 \gset

-- Atorados: 1 y 2 sin actividad hace 3 y 4 h
select tests.como_postgres();
update core.tramites set ultima_actividad_en = now() - interval '3 hours' where id = :'t1';
update core.tramites set ultima_actividad_en = now() - interval '4 hours' where id = :'t2';

-- Pago por vencer: el 3 aparta y su link vence en 1 h
select tests.como_servicio();
select api.reservar_cita(:'i3', :'t3', 3, tests.en_dias(1)) ->> 'version' as v3 \gset
select api.generar_pago(:'i3', :'t3', :v3) is not null as g \gset
select tests.como_postgres();
update core.pagos set expira_en = now() + interval '1 hour' where paciente_id = :'p3';

-- En atención: la asesora toma el trámite 1
select tests.como_staff(:'asesora', 'asesor');
select api.iniciar_contacto('call_center', '5218661234601', 'humano') #>> '{sesion,interaccion_id}' as cc \gset
select tests.como_servicio();
select api.solicitar_otp(:'cc') ->> 'codigo' as otp \gset
select tests.como_staff(:'asesora', 'asesor');
select api.validar_otp(:'cc', :'otp') is not null as ok_otp \gset
select api.retomar_tramite(:'cc', :'t1') is not null as tomado \gset

-- Seguridad: 3 fechas de nacimiento equivocadas → bloqueo
select api.iniciar_contacto('call_center', '5218661234602', 'humano') #>> '{sesion,interaccion_id}' as cc2 \gset
select tests.como_servicio();
select api.guardar_datos_paciente(:'i2', null, null, null, '1980-01-01') is not null as fn \gset
select tests.como_staff(:'asesora', 'asesor');
select count(api.verificar_identidad(:'cc2', '1999-09-09')) from generate_series(1, 3);

-- Llegadas de hoy: la cita del 3 pasa a hoy y llega
select tests.como_postgres();
update core.citas set fecha_hora = now() where paciente_id = :'p3' returning id as cita3 \gset
select (select folio from core.tramites where id = :'t2') as folio2 \gset
select tests.como_staff(:'rec', 'recepcion', :'cen');
select api.registrar_llegada(:'cita3', 'ine', true) is not null as lleg \gset

-- Conteos
select tests.como_staff(:'sup', 'supervisor', :'cen');
select api.bandeja_atencion() as b \gset
select is((:'b')::jsonb -> 'conteos',
          '{"atorados": 1, "pago_por_vencer": 1, "en_atencion": 1, "seguridad": 1, "llegadas_hoy": 1}'::jsonb,
          'Conteos por categoría (el atorado tomado por la asesora dejó de estarlo)');
select is((:'b')::jsonb -> 'items', '[]'::jsonb, 'Sin categoría no lista nada');

select api.bandeja_atencion(p_categoria => 'atorados') -> 'items' -> 0 as a \gset
select is((:'a')::jsonb ->> 'tramite_id', :'t2', 'Atorados: el trámite sin actividad');
select matches((:'a')::jsonb ->> 'detalle', '^Sin actividad hace 4 h', 'con cuánto lleva sin actividad');

select api.bandeja_atencion(p_categoria => 'en_atencion') -> 'items' -> 0 as e \gset
select matches((:'e')::jsonb ->> 'detalle', '^Lo atiende Personal asesor por teléfono', 'En atención: quién y por dónde');

select api.bandeja_atencion(p_categoria => 'seguridad') -> 'items' -> 0 as s \gset
select is(((:'s')::jsonb ->> 'fallidas')::int, 3, 'Seguridad: 3 verificaciones fallidas');
select is(((:'s')::jsonb ->> 'bloqueos')::int, 1, 'y el bloqueo por intentos');

select api.bandeja_atencion(p_categoria => 'llegadas_hoy') -> 'items' -> 0 as l \gset
select matches((:'l')::jsonb ->> 'detalle', '^Turno A-001 · Laboratorio · espera', 'Llegadas: turno, área y espera');

-- Pago por vencer (la cita del 3 ya llegó, pero su link sigue pendiente)
select matches(api.bandeja_atencion(p_categoria => 'pago_por_vencer') #>> '{items,0,detalle}', '^El link de pago vence en',
               'Pago por vencer');

-- Paginación con cursor (máximo 50 por página)
select tests.como_postgres();
update core.tramites set ultima_actividad_en = now() - interval '5 hours' where id = :'t3';
select tests.como_staff(:'sup', 'supervisor', :'cen');
select api.bandeja_atencion(p_categoria => 'atorados', p_limite => 1) as pag1 \gset
select is((:'pag1')::jsonb #>> '{items,0,tramite_id}', :'t3', 'Página 1: el más viejo primero');
select isnt((:'pag1')::jsonb ->> 'siguiente_cursor', null, 'con cursor a la siguiente página');
select api.bandeja_atencion(p_categoria => 'atorados', p_limite => 1, p_cursor => (:'pag1')::jsonb ->> 'siguiente_cursor') as pag2 \gset
select is((:'pag2')::jsonb #>> '{items,0,tramite_id}', :'t2', 'Página 2: el siguiente');
select is((:'pag2')::jsonb ->> 'siguiente_cursor', null, 'y ya no hay más');
select is((api.bandeja_atencion(p_categoria => 'atorados', p_limite => 500) #>> '{filtros,limite}')::int, 50, 'Nunca más de 50 por página');

-- Filtros
select is((api.bandeja_atencion(p_canal => 'web') #>> '{conteos,atorados}')::int, 0, 'Filtro por canal');
select is((api.bandeja_atencion(p_desde => current_date + 1) #>> '{conteos,atorados}')::int, 0, 'Filtro por fechas');

-- Alcance
select tests.como_staff(:'supang', 'supervisor', :'ang');
select is((api.bandeja_atencion() #>> '{conteos,atorados}')::int, 0, 'El supervisor de otra clínica no ve estos trámites');
select throws_ok(format('select api.bandeja_atencion(%L)', :'cen'), '42501', null, 'ni puede pedir otra clínica');
select tests.como_staff(:'asesora', 'asesor');
select throws_ok('select api.bandeja_atencion()', '42501', null, 'Un asesor no ve la bandeja');

-- Buscar
select tests.como_staff(:'admin', 'admin');
select is(api.buscar_pacientes(:'folio2') #>> '{0,paciente_id}', :'p2', 'Buscar por folio');
select is(api.buscar_pacientes('866 123 4602') #>> '{0,paciente_id}', :'p2', 'Buscar por celular');
select is(jsonb_array_length(api.buscar_pacientes('paciente1 lopez')), 1, 'Buscar por nombre, sin acentos ni mayúsculas');
select throws_ok($$select api.buscar_pacientes('lo')$$, '22023', null, 'Nunca sin filtro: mínimo 3 caracteres');

select finish();
rollback;
