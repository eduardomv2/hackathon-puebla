-- Ninguna sesión (anon, authenticated, service_role) lee tablas de core,
-- audit ni particiones directamente: todo pasa por las funciones api.
create extension if not exists pgtap with schema extensions;
begin;
select plan(14);
\ir ../helpers.psql

-- Privilegios declarados sobre cualquier tabla, vista o partición
select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ('core', 'audit', 'particiones', 'simulador') and c.relkind in ('r', 'p', 'v', 'm')
     and (has_table_privilege(r, c.oid, 'select') or has_table_privilege(r, c.oid, 'insert')
          or has_table_privilege(r, c.oid, 'update') or has_table_privilege(r, c.oid, 'delete'))),
  0, r || ' no tiene privilegios sobre ninguna tabla de core, audit, particiones ni simulador')
from unnest(array['anon', 'authenticated', 'service_role']) r;

select ok(not has_schema_privilege(r, 'particiones', 'usage'), r || ' no puede ni entrar al esquema particiones')
from unnest(array['anon', 'authenticated', 'service_role']) r;

-- Intentos reales con cada rol
select tests.como_anon();
select throws_ok('select * from core.pacientes', '42501', null, 'anon no lee core.pacientes');
select throws_ok($$select api.iniciar_contacto('whatsapp', '2220000000', 'ia')$$, '42501', null, 'anon no ejecuta funciones api');

select tests.como_paciente('00000000-0000-0000-0000-0000000000f1');
select throws_ok('select * from core.mensajes', '42501', null, 'authenticated no lee core.mensajes');
select throws_ok('select * from core.consentimientos_avisos', '42501', null, 'authenticated no lee consentimientos');

select tests.como_servicio();
select throws_ok('select * from core.tramites', '42501', null, 'service_role no lee core.tramites');
select throws_ok('select * from audit.registro', '42501', null, 'service_role no lee la bitácora');

-- Funciones de core: solo las que necesitan RLS y el pre-request
select tests.como_postgres();
select is(
  (select coalesce(array_agg(distinct p.proname::text order by p.proname::text), '{}')
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
        unnest(array['anon', 'authenticated', 'service_role']) r
   where n.nspname = 'core' and has_function_privilege(r, p.oid, 'execute')),
  array['consumir_limite', 'ip_actual', 'mi_paciente_id', 'puede_escuchar_paciente', 'rol_actual', 'verificar_peticion'],
  'Las únicas funciones de core ejecutables desde fuera son las de RLS (incluido tiempo real) y pre-request');
select ok(not has_function_privilege('authenticated', 'core.descifrar(bytea, smallint)', 'execute'),
          'Nadie fuera de las funciones api puede descifrar');
select finish();
rollback;
