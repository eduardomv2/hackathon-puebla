-- Catálogo público de estudios y clínicas.
create extension if not exists pgtap with schema extensions;
begin;
select plan(10);
\ir ../helpers.psql

select tests.como_anon();
select is(jsonb_array_length(api.catalogo_estudios()), 6, 'anon puede consultar el catálogo');
select is(jsonb_array_length(api.catalogo_estudios('ultrasonido')), 2, 'La búsqueda encuentra los dos ultrasonidos');
select is(jsonb_array_length(api.catalogo_estudios('ULTRASONÍDO')), 2, 'sin distinguir mayúsculas ni acentos');
select is(api.catalogo_estudios('obstetrico') -> 0 ->> 'clave', 'US-OBS', '"obstetrico" encuentra "Ultrasonido obstétrico"');
select is(jsonb_array_length(api.clinicas_para_estudio(tests.estudio('BH'), 'puebla')), 8,
          'clinicas_para_estudio filtra por ciudad (8 clínicas en la ciudad de Puebla)');

-- Lo inactivo no aparece
select tests.como_postgres();
update core.estudios set activo = false where clave = 'QS6';
update core.clinicas set activa = false where clave = 'MTY-CEN';
select tests.como_anon();
select ok(not exists (select 1 from jsonb_array_elements(api.catalogo_estudios()) e where e ->> 'clave' = 'QS6'),
          'Un estudio inactivo no aparece');
select ok(not exists (select 1 from jsonb_array_elements(api.clinicas_para_estudio(tests.estudio('BH'), 'monterrey')) c
                      where c ->> 'clave' = 'MTY-CEN'), 'Una clínica inactiva no aparece');
select throws_ok(format('select api.clinicas_para_estudio(%L)', tests.estudio('QS6')), 'PT404', 'Estudio no encontrado',
                 'Pedir clínicas de un estudio inactivo responde PT404');

-- Rate limit: son VOLATILE (y la API solo acepta POST), así que cada consulta cuenta
select tests.como_postgres();
select is((select count(*)::int from pg_proc where proname in ('catalogo_estudios', 'clinicas_para_estudio')
           and pronamespace = 'api'::regnamespace and provolatile = 'v'), 2, 'Ambas funciones son VOLATILE');
select tests.como_anon();
select set_config('request.headers', '{"x-forwarded-for": "198.51.100.20"}', true) is not null as h \gset
select count(*) from (select core.verificar_peticion(), api.catalogo_estudios() from generate_series(1, 30)) x;
select throws_ok('select core.verificar_peticion()', 'PT429', 'Demasiadas solicitudes',
                 'anon que pasa de 30 consultas por minuto recibe PT429');

select finish();
rollback;
