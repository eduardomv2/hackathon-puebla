-- =====================================================================
-- 1000 · Corrección: el pre-request (core.verificar_peticion) corre con el
--        rol de la petición también para service_role. Sin estos permisos,
--        TODA llamada con la clave secreta falla con
--        "permission denied for schema core".
--        (Las tablas de core siguen sin grants: solo se habilita la función.)
-- =====================================================================
grant usage on schema core to service_role;
grant execute on function core.verificar_peticion() to service_role;
