-- =====================================================================
-- Directorio de clínicas (las 261 sucursales reales, ver supabase/seeds/)
--   · core.clinicas: id del directorio (id_externo), slug, teléfono,
--     coordenadas y el horario tal como se publica (horario_texto).
--   · api.clinicas_para_estudio: además de ciudad y estado, busca por texto
--     (nombre, ciudad, estado, colonia) y ordena por cercanía con p_lat/p_lng.
--     Devuelve los campos nuevos y distancia_km. Las llamadas de antes siguen
--     funcionando igual (mismos parámetros, mismo orden por ciudad y nombre).
--   · api.directorio_clinicas: todas las clínicas activas (para el mapa y el
--     directorio de la interfaz), con los mismos filtros.
--   · api.ubicaciones_clinicas: estados y ciudades con clínica (para elegir
--     primero dónde y luego cuál).
-- =====================================================================

alter table core.clinicas
  add column id_externo    int unique,
  add column slug          text unique,
  add column telefono      text,
  add column lat           double precision,
  add column lng           double precision,
  add column horario_texto text,
  add constraint clinicas_coordenadas check (
    (lat is null) = (lng is null)
    and (lat is null or (lat between -90 and 90 and lng between -180 and 180)));

comment on column core.clinicas.id_externo is 'id de la sucursal en el directorio público (clinicasData.ts)';
comment on column core.clinicas.horario_texto is 'Horario como se publica. Los turnos de cita salen de core.horarios_clinica';

-- Distancia en km entre dos puntos (fórmula del haversine). Nula si falta algún dato.
create function core.distancia_km(p_lat1 double precision, p_lng1 double precision,
                                  p_lat2 double precision, p_lng2 double precision)
returns double precision
language sql immutable strict
set search_path = ''
as $$
  select 6371.0 * 2 * asin(least(1.0, sqrt(
    power(sin(radians(p_lat2 - p_lat1) / 2), 2)
    + cos(radians(p_lat1)) * cos(radians(p_lat2)) * power(sin(radians(p_lng2 - p_lng1) / 2), 2))))
$$;
revoke execute on function core.distancia_km(double precision, double precision, double precision, double precision)
  from public, anon, authenticated, service_role;

-- Búsqueda de clínicas activas, común a las funciones api.
--   p_estudio_id: solo las que hacen ese estudio (y agrega su precio). Nulo: todas.
--   p_busqueda: cada palabra debe aparecer en nombre, ciudad, estado o dirección
--     (sin acentos ni mayúsculas). Primero las que coinciden con la ciudad o el nombre.
--   p_lat/p_lng: ordena por cercanía y agrega distancia_km.
--   p_limite: entre 1 y 300.
create function core.buscar_clinicas(p_estudio_id uuid, p_ciudad text, p_estado text, p_busqueda text,
                                     p_lat double precision, p_lng double precision, p_limite int)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_busqueda text := nullif(core.texto_busqueda(p_busqueda), '');
  v_limite   int  := least(greatest(coalesce(p_limite, 50), 1), 300);
begin
  if (p_lat is null) <> (p_lng is null) or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'coordenadas_invalidas' using errcode = '22023',
      hint = 'Manda p_lat y p_lng juntos, en grados decimales.';
  end if;
  return (
    select coalesce(jsonb_agg(
             jsonb_strip_nulls(jsonb_build_object(
               'id', x.id, 'clave', x.clave, 'id_externo', x.id_externo, 'slug', x.slug,
               'nombre', x.nombre, 'ciudad', x.ciudad, 'estado', x.estado, 'direccion', x.direccion,
               'telefono', x.telefono, 'lat', x.lat, 'lng', x.lng, 'horario', x.horario_texto,
               'zona_horaria', x.zona_horaria, 'precio', x.precio,
               'distancia_km', round(x.distancia::numeric, 1)))
             order by x.distancia nulls last, x.rango, x.ciudad, x.nombre), '[]')
    from (select c.*, ce.precio,
                 core.distancia_km(p_lat, p_lng, c.lat, c.lng) as distancia,
                 (v_busqueda is not null
                  and core.texto_busqueda(c.ciudad) <> v_busqueda
                  and core.texto_busqueda(c.nombre) <> v_busqueda)::int
                 + (v_busqueda is not null
                    and strpos(core.texto_busqueda(c.nombre), v_busqueda) = 0)::int as rango
          from core.clinicas c
          left join lateral (
            select coalesce(r.precio, e.precio_base) as precio
            from core.clinica_estudios r
            join core.estudios e on e.id = r.estudio_id
            where r.clinica_id = c.id and r.estudio_id = p_estudio_id
              and r.activo and r.eliminado_en is null) ce on true
          where c.activa and c.eliminado_en is null
            and (p_estudio_id is null or ce.precio is not null)
            and (p_ciudad is null or core.texto_busqueda(c.ciudad) = core.texto_busqueda(p_ciudad))
            and (p_estado is null or core.texto_busqueda(c.estado) = core.texto_busqueda(p_estado))
            and (v_busqueda is null or not exists (
                  select 1 from unnest(string_to_array(v_busqueda, ' ')) w
                  where w <> '' and strpos(core.texto_busqueda(concat_ws(' ', c.nombre, c.ciudad, c.estado, c.direccion)), w) = 0))
          order by distancia nulls last, rango, c.ciudad, c.nombre
          limit v_limite) x);
end
$$;
revoke execute on function core.buscar_clinicas(uuid, text, text, text, double precision, double precision, int)
  from public, anon, authenticated, service_role;

-- Misma firma de antes + parámetros opcionales al final (se borra la anterior
-- para que no haya dos versiones de la función).
drop function api.clinicas_para_estudio(uuid, text, text);
create function api.clinicas_para_estudio(p_estudio_id uuid, p_ciudad text default null, p_estado text default null,
                                          p_busqueda text default null, p_lat double precision default null,
                                          p_lng double precision default null, p_limite int default 50)
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
  return core.buscar_clinicas(p_estudio_id, p_ciudad, p_estado, p_busqueda, p_lat, p_lng, p_limite);
end
$$;

create function api.directorio_clinicas(p_busqueda text default null, p_estado text default null, p_ciudad text default null,
                                        p_lat double precision default null, p_lng double precision default null,
                                        p_limite int default 300)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  return core.buscar_clinicas(null, p_ciudad, p_estado, p_busqueda, p_lat, p_lng, p_limite);
end
$$;

-- [{ estado, clinicas, ciudades: [{ ciudad, clinicas }] }] por orden alfabético
create function api.ubicaciones_clinicas(p_estudio_id uuid default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if p_estudio_id is not null
     and not exists (select 1 from core.estudios where id = p_estudio_id and activo and eliminado_en is null) then
    raise exception 'Estudio no encontrado' using errcode = 'PT404';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object('estado', e.estado, 'clinicas', e.total, 'ciudades', e.ciudades)
                              order by e.estado), '[]')
    from (select x.estado, sum(x.n)::int as total,
                 jsonb_agg(jsonb_build_object('ciudad', x.ciudad, 'clinicas', x.n) order by x.ciudad) as ciudades
          from (select c.estado, c.ciudad, count(*)::int as n
                from core.clinicas c
                where c.activa and c.eliminado_en is null
                  and (p_estudio_id is null or exists (
                        select 1 from core.clinica_estudios r
                        where r.clinica_id = c.id and r.estudio_id = p_estudio_id and r.activo and r.eliminado_en is null))
                group by c.estado, c.ciudad) x
          group by x.estado) e);
end
$$;

revoke execute on function
  api.clinicas_para_estudio(uuid, text, text, text, double precision, double precision, int),
  api.directorio_clinicas(text, text, text, double precision, double precision, int),
  api.ubicaciones_clinicas(uuid)
  from public;
grant execute on function
  api.clinicas_para_estudio(uuid, text, text, text, double precision, double precision, int),
  api.directorio_clinicas(text, text, text, double precision, double precision, int),
  api.ubicaciones_clinicas(uuid)
  to anon, authenticated, service_role;
