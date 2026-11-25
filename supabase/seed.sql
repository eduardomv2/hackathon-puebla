-- =====================================================================
-- ⚠️  SOLO DESARROLLO LOCAL (`supabase db reset`). NO ejecutar en producción:
--     enciende el simulador, que deja leer los OTP de cualquier teléfono.
-- =====================================================================

-- Llave de cifrado de columnas: se genera al azar en cada reset.
select vault.create_secret(encode(extensions.gen_random_bytes(32), 'base64'), 'clave_cifrado_v1',
                           'Llave de cifrado de columnas v1')
where not exists (select 1 from vault.secrets where name = 'clave_cifrado_v1');

-- Despachador de workers (pg_cron + pg_net → Edge Functions). Desde el contenedor de
-- la base, la API local se alcanza como http://kong:8000. La clave es la service_role
-- de DEMOSTRACIÓN de Supabase local (pública); en producción se crean a mano (README).
select vault.create_secret('http://kong:8000', 'project_url', 'URL interna de la API (local)')
where not exists (select 1 from vault.secrets where name = 'project_url');
select vault.create_secret('eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU',
                           'worker_token', 'service_role de demostración (solo local)')
where not exists (select 1 from vault.secrets where name = 'worker_token');

-- Catálogo inicial (datos de ejemplo: precios y clínicas ficticios)
insert into core.clinicas (clave, nombre, ciudad, estado, direccion) values
  ('PUE-CEN', 'Clínica Puebla Centro',   'Puebla',    'Puebla',   'Av. Reforma 100, Centro'),
  ('PUE-ANG', 'Clínica Puebla Angelópolis', 'Puebla', 'Puebla',   'Blvd. del Niño Poblano 2000'),
  ('MTY-CEN', 'Clínica Monterrey Centro', 'Monterrey', 'Nuevo León', 'Av. Constitución 300');

-- area: a qué área se dirige al paciente al llegar (y la letra de su turno: A, U, R, M)
insert into core.estudios (clave, nombre, categoria, area, preparacion, duracion_min, precio_base) values
  ('US-OBS', 'Ultrasonido obstétrico', 'imagen',      'ultrasonido', 'Vejiga llena: tomar 1 litro de agua una hora antes.', 30, 450.00),
  ('US-ABD', 'Ultrasonido abdominal',  'imagen',      'ultrasonido', 'Ayuno de 8 horas.',                                     30, 450.00),
  ('MASTO',  'Mastografía',            'imagen',      'mastografia', 'Sin desodorante ni talco el día del estudio.',          20, 550.00),
  ('RX-TOR', 'Rayos X de tórax',       'imagen',      'rayos_x',     'Sin objetos metálicos (collares, aretes).',              15, 300.00),
  ('BH',     'Biometría hemática',     'laboratorio', 'laboratorio', 'No requiere ayuno.',                                    10, 120.00),
  ('QS6',    'Química sanguínea de 6 elementos', 'laboratorio', 'laboratorio', 'Ayuno de 8 a 12 horas.',                     10, 180.00);

insert into core.clinica_estudios (clinica_id, estudio_id, capacidad_por_horario)
select c.id, e.id, case when e.categoria = 'imagen' then 2 else 10 end
from core.clinicas c cross join core.estudios e;

-- Horario de atención: lunes a viernes 7:00–15:00, sábado 7:00–12:00, cada 30 min.
-- Domingo sin renglón = cerrado.
insert into core.horarios_clinica (clinica_id, dia_semana, abre, cierra)
select c.id, d, '07:00', case when d = 6 then time '12:00' else time '15:00' end
from core.clinicas c cross join generate_series(1, 6) d;

-- Simulador (bandeja del teléfono de prueba): encendido solo aquí
update simulador.config set habilitado = true;
