-- Directorio de clínicas: las 261 sucursales reales, búsqueda, cercanía y ubicaciones.
create extension if not exists pgtap with schema extensions;
begin;
select plan(22);
\ir ../helpers.psql

-- Datos cargados (seeds/clinicas.sql)
select is((select count(*)::int from core.clinicas where activa), 261, 'Están las 261 clínicas del directorio');
select is((select id_externo || ' ' || nombre || ' ' || telefono from core.clinicas where clave = 'PUE-CEN'), '58 Puebla (222) 232 47 09',
          'PUE-CEN es la sucursal real de Puebla centro');
select is((select zona_horaria from core.clinicas where clave = 'tijuana-centro'), 'America/Tijuana', 'Tijuana en su zona horaria');
select is((select zona_horaria from core.clinicas where ciudad = 'Ciudad Juárez' limit 1), 'America/Ciudad_Juarez', 'Ciudad Juárez en la suya');
select is((select count(*)::int from core.horarios_clinica where clinica_id = tests.clinica('gran-terraza-coapa-tlalpan') and dia_semana = 0), 0,
          '"Domingo: No Laboramos" = sin renglón el domingo');
select is((select cierra from core.horarios_clinica where clinica_id = tests.clinica('gustavo-madero') and dia_semana = 6), '12:00'::time,
          'Sin horario publicado: el de siempre (sábado hasta 12:00)');
select throws_ok($$update core.clinicas set lng = null where clave = 'PUE-CEN'$$, '23514', null, 'lat sin lng no se permite');

-- Directorio completo (anon)
select tests.como_anon();
select is(jsonb_array_length(api.directorio_clinicas()), 261, 'anon ve el directorio completo');
select api.directorio_clinicas('puebla capu') -> 0 as capu \gset
select is((:'capu')::jsonb ->> 'clave', 'puebla-capu', 'Búsqueda por varias palabras');
select ok((:'capu')::jsonb ?& array['id_externo', 'slug', 'telefono', 'lat', 'lng', 'horario', 'direccion'],
          'con teléfono, coordenadas y horario');
select is(api.directorio_clinicas('PUEBLA') #>> '{0,clave}', 'PUE-CEN', 'Primero la que se llama como lo buscado');
select is(jsonb_array_length(api.directorio_clinicas('tlalpan')), 2, 'Busca también en la dirección (colonia, alcaldía)');
select is(jsonb_array_length(api.directorio_clinicas(p_estado => 'nuevo leon')), 23, 'Filtro por estado sin acentos');

-- Cercanía: desde el zócalo de Puebla
select api.directorio_clinicas(p_lat => 19.0433, p_lng => -98.1981, p_limite => 3) as cerca \gset
select is((:'cerca')::jsonb #>> '{0,clave}', 'PUE-CEN', 'La más cercana primero');
select is((:'cerca')::jsonb #>> '{0,distancia_km}', '1.0', 'con su distancia en km');
select is(jsonb_array_length((:'cerca')::jsonb), 3, 'respetando el límite');
select throws_ok($$select api.directorio_clinicas(p_lat => 19.04)$$, '22023', 'coordenadas_invalidas', 'lat sin lng: 22023');

-- clinicas_para_estudio: la llamada de antes sigue igual, ahora con los datos nuevos
select is(api.clinicas_para_estudio(tests.estudio('BH'), 'puebla') #>> '{0,precio}', '120.00', 'Con precio del estudio');
select is(api.clinicas_para_estudio(tests.estudio('US-OBS'), p_lat => 32.53, p_lng => -117.03) #>> '{0,ciudad}', 'Tijuana',
          'y también por cercanía');

-- Ubicaciones
select api.ubicaciones_clinicas(tests.estudio('BH')) as u \gset
select is(jsonb_array_length((:'u')::jsonb), 32, 'Los 32 estados');
select is((select e -> 'ciudades' from jsonb_array_elements((:'u')::jsonb) e where e ->> 'estado' = 'Puebla')
            @> '[{"ciudad": "Puebla", "clinicas": 8}]', true, 'Puebla: 8 clínicas en la ciudad');

-- Lo interno no se expone
select throws_ok($$select core.buscar_clinicas(null, null, null, null, null, null, 5)$$, '42501', null,
                 'anon no ejecuta core.buscar_clinicas');

select finish();
rollback;
