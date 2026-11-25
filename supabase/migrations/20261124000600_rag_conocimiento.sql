-- =====================================================================
-- 0600 · Base de conocimiento para el agente de voz y WhatsApp (RAG)
--   pgvector (HNSW, coseno) + búsqueda de texto en español,
--   combinadas con Reciprocal Rank Fusion (búsqueda híbrida)
-- =====================================================================

create table core.kb_documentos (
  id               uuid primary key default core.uuid_v7(),
  titulo           text not null,
  categoria        text not null check (categoria in ('estudios', 'preparacion', 'sucursales', 'precios', 'politicas', 'faq')),
  fuente           text,
  vigente          boolean not null default true,
  creado_en        timestamptz not null default now(),
  creado_por       uuid,
  actualizado_en   timestamptz not null default now(),
  actualizado_por  uuid,
  eliminado_en     timestamptz,
  eliminado_por    uuid
);
select core.habilitar_auditoria('core.kb_documentos');

-- 1536 dimensiones = text-embedding-3-small. Cambiar el modelo implica re-embeber.
create table core.kb_fragmentos (
  id            uuid primary key default core.uuid_v7(),
  documento_id  uuid not null references core.kb_documentos (id),
  orden         int  not null,
  contenido     text not null,
  embedding     extensions.vector(1536) not null,
  fts           tsvector generated always as (to_tsvector('spanish', contenido)) stored,
  metadatos     jsonb not null default '{}',
  creado_en     timestamptz not null default now(),
  unique (documento_id, orden)
);
create index on core.kb_fragmentos using hnsw (embedding extensions.vector_cosine_ops);
create index on core.kb_fragmentos using gin (fts);

-- Búsqueda híbrida: el vector entiende la intención ("¿tengo que ir en ayunas?"),
-- el texto asegura coincidencias exactas ("ultrasonido pélvico"). RRF une ambos rankings.
create or replace function api.buscar_conocimiento(
  p_consulta text, p_embedding extensions.vector(1536), p_limite int default 5, p_categoria text default null)
returns table (fragmento_id uuid, documento_id uuid, titulo text, categoria text, contenido text, puntaje double precision)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int := least(greatest(p_limite, 1), 20);
begin
  perform core.exigir_rol('servicio', 'asesor', 'supervisor', 'admin', 'paciente');
  return query
  with semantico as (
    select f.id, row_number() over (order by f.embedding operator(extensions.<=>) p_embedding) as r
    from core.kb_fragmentos f
    join core.kb_documentos d on d.id = f.documento_id
    where d.vigente and d.eliminado_en is null and (p_categoria is null or d.categoria = p_categoria)
    order by f.embedding operator(extensions.<=>) p_embedding
    limit v_n * 4
  ),
  texto as (
    select f.id, row_number() over (order by ts_rank_cd(f.fts, q) desc) as r
    from core.kb_fragmentos f
    join core.kb_documentos d on d.id = f.documento_id,
         websearch_to_tsquery('spanish', coalesce(p_consulta, '')) q
    where f.fts @@ q and d.vigente and d.eliminado_en is null and (p_categoria is null or d.categoria = p_categoria)
    order by ts_rank_cd(f.fts, q) desc
    limit v_n * 4
  ),
  fusion as (
    select coalesce(s.id, t.id) as id,
           coalesce(1.0 / (60 + s.r), 0) + coalesce(1.0 / (60 + t.r), 0) as puntaje
    from semantico s full join texto t on t.id = s.id
  )
  select f.id, f.documento_id, d.titulo, d.categoria, f.contenido, fu.puntaje::double precision
  from fusion fu
  join core.kb_fragmentos f on f.id = fu.id
  join core.kb_documentos d on d.id = f.documento_id
  order by fu.puntaje desc
  limit v_n;
end
$$;

-- Carga un documento ya dividido y embebido (lo llama la Edge Function de ingesta)
--   p_fragmentos = [{"contenido": "...", "embedding": [0.01, ...]}, ...]
create or replace function api.kb_guardar_documento(
  p_titulo text, p_categoria text, p_fuente text, p_fragmentos jsonb, p_reemplaza uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_doc uuid;
begin
  perform core.exigir_rol('servicio', 'admin');
  perform core.establecer_actor('sistema', 'sistema');
  if jsonb_typeof(p_fragmentos) <> 'array' or jsonb_array_length(p_fragmentos) = 0 then
    raise exception 'Se requiere al menos un fragmento' using errcode = '22023';
  end if;

  -- Nueva versión: el documento anterior deja de usarse pero queda en la bitácora
  if p_reemplaza is not null then
    update core.kb_documentos set vigente = false where id = p_reemplaza;
  end if;

  insert into core.kb_documentos (titulo, categoria, fuente) values (p_titulo, p_categoria, p_fuente)
  returning id into v_doc;

  insert into core.kb_fragmentos (documento_id, orden, contenido, embedding, metadatos)
  select v_doc, e.ord::int, e.frag ->> 'contenido',
         (e.frag ->> 'embedding')::extensions.vector(1536),
         coalesce(e.frag -> 'metadatos', '{}')
  from jsonb_array_elements(p_fragmentos) with ordinality as e(frag, ord);
  return v_doc;
end
$$;
