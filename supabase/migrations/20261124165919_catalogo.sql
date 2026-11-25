-- =====================================================================
-- Catálogo público: estudios y clínicas que los ofrecen
--   Datos públicos (la web los muestra antes de cualquier sesión): grant a
--   anon, authenticated y service_role. VOLATILE y la API solo acepta POST,
--   así que cada consulta pasa por el rate limit.
--   Búsqueda sin distinguir acentos ni mayúsculas. Máximo 50 resultados.
-- =====================================================================
create extension if not exists unaccent with schema extensions;

create or replace function core.texto_busqueda(p_texto text)
returns text
language sql stable
set search_path = ''
as $$
  select lower(extensions.unaccent(btrim(p_texto)))
$$;
revoke execute on function core.texto_busqueda(text) from public, anon, authenticated, service_role;

create or replace function api.catalogo_estudios(p_busqueda text default null, p_categoria text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_busqueda text := nullif(core.texto_busqueda(p_busqueda), '');
begin
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', e.id, 'clave', e.clave, 'nombre', e.nombre, 'categoria', e.categoria,
             'descripcion', e.descripcion, 'preparacion', e.preparacion,
             'duracion_min', e.duracion_min, 'precio_base', e.precio_base)
           order by e.nombre), '[]')
    from (select * from core.estudios e
          where e.activo and e.eliminado_en is null
            and (p_categoria is null or e.categoria = p_categoria)
            and (v_busqueda is null
                 or strpos(core.texto_busqueda(e.nombre), v_busqueda) > 0
                 or strpos(core.texto_busqueda(e.categoria), v_busqueda) > 0)
          order by e.nombre
          limit 50) e);
end
$$;

create or replace function api.clinicas_para_estudio(p_estudio_id uuid, p_ciudad text default null, p_estado text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from core.estudios where id = p_estudio_id and activo and eliminado_en is null) then
    raise exception 'Estudio no encontrado' using errcode = 'PT404';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', x.id, 'clave', x.clave, 'nombre', x.nombre, 'ciudad', x.ciudad, 'estado', x.estado,
             'direccion', x.direccion, 'zona_horaria', x.zona_horaria, 'precio', x.precio)
           order by x.ciudad, x.nombre), '[]')
    from (select c.id, c.clave, c.nombre, c.ciudad, c.estado, c.direccion, c.zona_horaria,
                 coalesce(ce.precio, e.precio_base) as precio
          from core.clinica_estudios ce
          join core.clinicas c on c.id = ce.clinica_id
          join core.estudios e on e.id = ce.estudio_id
          where ce.estudio_id = p_estudio_id
            and ce.activo and ce.eliminado_en is null
            and c.activa and c.eliminado_en is null
            and (p_ciudad is null or core.texto_busqueda(c.ciudad) = core.texto_busqueda(p_ciudad))
            and (p_estado is null or core.texto_busqueda(c.estado) = core.texto_busqueda(p_estado))
          order by c.ciudad, c.nombre
          limit 50) x);
end
$$;

revoke execute on function api.catalogo_estudios(text, text), api.clinicas_para_estudio(uuid, text, text) from public;
grant execute on function api.catalogo_estudios(text, text), api.clinicas_para_estudio(uuid, text, text)
  to anon, authenticated, service_role;
