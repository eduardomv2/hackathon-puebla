/**
 * Genera supabase/seeds/clinicas.sql a partir de supabase/seeds/clinicasData.ts
 * (el mismo directorio que usa la interfaz).
 *
 *   npm run clinicas        (y luego: npx supabase db reset)
 *
 * - Clave: el slug de la sucursal (culiacan, puebla-capu…), salvo tres que conservan la
 *   clave que usan las pruebas, la demo y los usuarios de prueba: PUE-CEN, PUE-ANG, MTY-CEN.
 * - Horarios de atención: se leen del texto del horario ("Lunes a Viernes: 6:00 am a 7:00 pm ·
 *   Sábado: … · Domingo: No Laboramos"). Sin domingo = cerrado. Sin horario = el de siempre
 *   (lunes a viernes 7:00–15:00, sábado 7:00–12:00).
 * - Zona horaria por estado (y las ciudades fronterizas que tienen la suya).
 * Si algún horario no se entiende, el script falla y dice cuál.
 */
import { writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { CLINICAS_DATOS, type ClinicaDato } from '../../supabase/seeds/clinicasData.ts'

const SALIDA = resolve(dirname(fileURLToPath(import.meta.url)), '../../supabase/seeds/clinicas.sql')

/** Claves fijas (id del directorio → clave) */
const CLAVES_FIJAS: Record<number, string> = { 58: 'PUE-CEN', 357: 'PUE-ANG', 62: 'MTY-CEN' }

const ZONA_ESTADO: Record<string, string> = {
  'Baja California': 'America/Tijuana',
  'Baja California Sur': 'America/Mazatlan',
  Sinaloa: 'America/Mazatlan',
  Nayarit: 'America/Mazatlan',
  Sonora: 'America/Hermosillo',
  Chihuahua: 'America/Chihuahua',
  'Quintana Roo': 'America/Cancun',
  'Nuevo León': 'America/Monterrey',
  Coahuila: 'America/Monterrey',
}
const ZONA_CIUDAD: Record<string, string> = {
  'Ciudad Juárez': 'America/Ciudad_Juarez',
  Matamoros: 'America/Matamoros',
  Reynosa: 'America/Matamoros',
  'Nuevo Laredo': 'America/Matamoros',
}
const zona = (c: ClinicaDato) => ZONA_CIUDAD[c.ciudad] ?? ZONA_ESTADO[c.estado] ?? 'America/Mexico_City'

/** "aguascalientes Universidad", "/torreon-plaza-triana " → aguascalientes-universidad, torreon-plaza-triana */
const slug = (u: string) => u.trim().replace(/^\/+|\/+$/g, '').toLowerCase().replace(/\s+/g, '-')

type Turno = { dia: number; abre: string; cierra: string }   // dia: 0 = domingo … 6 = sábado
const HORARIO_DEFECTO: Turno[] = [1, 2, 3, 4, 5, 6].map((dia) => ({ dia, abre: '07:00', cierra: dia === 6 ? '12:00' : '15:00' }))

/** "6:30 am" → 06:30 · "7:00 pm" → 19:00 · "19:00 pm" → 19:00 (ya en 24 h) · "7:00 a.m." */
function hora(h: string, m: string, sufijo: string): string {
  let n = Number(h)
  if (n <= 12 && sufijo.startsWith('p') && n !== 12) n += 12
  if (n <= 12 && sufijo.startsWith('a') && n === 12) n = 0
  return `${String(n).padStart(2, '0')}:${m}`
}

function dias(etiqueta: string): number[] | null {
  const e = etiqueta.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase().trim()
  if (/^lunes a vie(rnes)?$/.test(e)) return [1, 2, 3, 4, 5]
  if (/^sab(ado)?$/.test(e)) return [6]
  if (/^dom(ingo)?$/.test(e)) return [0]
  return null
}

function turnos(c: ClinicaDato): Turno[] {
  if (!c.horario.trim()) return HORARIO_DEFECTO
  const r: Turno[] = []
  for (const bloque of c.horario.split('·')) {
    const i = bloque.indexOf(':')
    const ds = dias(bloque.slice(0, i))
    const resto = bloque.slice(i + 1).trim()
    if (!ds) throw new Error(`Día no reconocido en «${c.name}»: ${bloque}`)
    if (/^no (se )?labora/i.test(resto)) continue
    const m = resto.match(/^(\d{1,2}):(\d\d)\s*(a\.?m\.?|p\.?m\.?)\s+a\s+(\d{1,2}):(\d\d)\s*(a\.?m\.?|p\.?m\.?)$/i)
    if (!m) throw new Error(`Horario no reconocido en «${c.name}»: ${bloque}`)
    const abre = hora(m[1], m[2], m[3].toLowerCase()), cierra = hora(m[4], m[5], m[6].toLowerCase())
    if (abre >= cierra) throw new Error(`Horario al revés en «${c.name}»: ${bloque}`)
    for (const dia of ds) r.push({ dia, abre, cierra })
  }
  return r
}

const q = (s: string | null | undefined) => (s == null || s.trim() === '' ? 'null' : `'${s.trim().replace(/'/g, "''")}'`)

const claves = new Set<string>()
const filas: string[] = []
const horarios: string[] = []
for (const c of CLINICAS_DATOS) {
  const clave = CLAVES_FIJAS[c.id] ?? slug(c.url)
  if (claves.has(clave)) throw new Error(`Clave repetida: ${clave}`)
  claves.add(clave)
  filas.push(`  (${c.id}, ${q(clave)}, ${q(slug(c.url))}, ${q(c.name)}, ${q(c.ciudad)}, ${q(c.estado)}, ${q(c.address)}, ` +
    `${q(c.phone)}, ${c.lat}, ${c.lng}, ${q(c.horario)}, ${q(zona(c))})`)
  for (const t of turnos(c)) horarios.push(`  (${q(clave)}, ${t.dia}, '${t.abre}', '${t.cierra}')`)
}
for (const id of Object.keys(CLAVES_FIJAS)) {
  if (!CLINICAS_DATOS.some((c) => c.id === Number(id))) throw new Error(`No existe la clínica ${id} del directorio`)
}

writeFileSync(SALIDA, `-- =====================================================================
-- ARCHIVO GENERADO por simulador/scripts/generar-clinicas.ts (npm run clinicas)
-- desde supabase/seeds/clinicasData.ts. No lo edites a mano.
-- ${CLINICAS_DATOS.length} clínicas de Salud Digna y sus horarios de atención.
-- Corre antes de seed.sql (supabase/config.toml → [db.seed] sql_paths).
-- =====================================================================

insert into core.clinicas (id_externo, clave, slug, nombre, ciudad, estado, direccion, telefono, lat, lng, horario_texto, zona_horaria) values
${filas.join(',\n')};

-- Horario de atención por día (0 = domingo … 6 = sábado); un día sin renglón = cerrado.
insert into core.horarios_clinica (clinica_id, dia_semana, abre, cierra)
select c.id, h.dia, h.abre::time, h.cierra::time
from (values
${horarios.join(',\n')}
) h (clave, dia, abre, cierra)
join core.clinicas c on c.clave = h.clave;
`)
console.log(`✓ ${CLINICAS_DATOS.length} clínicas y ${horarios.length} horarios → ${SALIDA}`)
