// =====================================================================
// Fechas en lenguaje natural para el bot (funciones PURAS, sin reloj propio:
// "hoy" siempre llega como parámetro, en la zona horaria de la clínica).
//   hoy, mañana, pasado mañana, lunes…domingo (= el próximo),
//   "26 de noviembre", "26 nov", "26/11", "26/11/2026", y hora opcional:
//   "jueves 7am", "mañana a las 10", "26/11 10:30", "hoy 4 de la tarde".
// =====================================================================

/** Días hacia adelante que se pueden agendar (igual que api.horarios_disponibles) */
export const MAX_DIAS = 14

export type FechaInterpretada =
  | { tipo: 'fecha'; fecha: string; hora: string | null }
  | { tipo: 'pasada'; fecha: string }
  | { tipo: 'lejana'; fecha: string }

export function normalizar(texto: string): string {
  return texto.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/\s+/g, ' ').trim()
}

const DIAS_SEMANA = ['domingo', 'lunes', 'martes', 'miercoles', 'jueves', 'viernes', 'sabado']
const MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre']
const MES_CORTO: Record<string, number> = {
  ene: 1, feb: 2, mar: 3, abr: 4, may: 5, jun: 6, jul: 7, ago: 8, sep: 9, sept: 9, set: 9, oct: 10, nov: 11, dic: 12,
}

// --- aritmética de fechas 'AAAA-MM-DD' (en UTC para no depender de la zona del servidor)
const aDate = (f: string) => new Date(`${f}T12:00:00Z`)
const aTexto = (d: Date) => d.toISOString().slice(0, 10)
export const sumarDias = (f: string, n: number) => { const d = aDate(f); d.setUTCDate(d.getUTCDate() + n); return aTexto(d) }
export const diasEntre = (desde: string, hasta: string) => Math.round((aDate(hasta).getTime() - aDate(desde).getTime()) / 86_400_000)
const diaSemana = (f: string) => aDate(f).getUTCDay()

/** "jueves 26 de noviembre" */
export function fechaLarga(f: string): string {
  return `${DIAS_SEMANA[diaSemana(f)].replace('miercoles', 'miércoles').replace('sabado', 'sábado')} ` +
    `${aDate(f).getUTCDate()} de ${MESES[aDate(f).getUTCMonth()]}`
}

/** Fecha 'AAAA-MM-DD' de hoy en una zona horaria */
export function hoyEn(zona = 'America/Mexico_City', ahora = new Date()): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: zona, year: 'numeric', month: '2-digit', day: '2-digit' }).format(ahora)
}

export function mesDe(palabra: string): number | null {
  const i = MESES.indexOf(palabra)
  if (i >= 0) return i + 1
  return MES_CORTO[palabra.replace(/\.$/, '')] ?? null
}

/** Día y mes sin año → la fecha más cercana a hoy (este año, o el siguiente si es enero y estamos en diciembre) */
export function resolverDiaMes(dia: number, mes: number, hoy: string, anio?: number): string | null {
  const intento = (a: number) => {
    const d = new Date(Date.UTC(a, mes - 1, dia, 12))
    return d.getUTCMonth() === mes - 1 && d.getUTCDate() === dia ? aTexto(d) : null
  }
  const actual = Number(hoy.slice(0, 4))
  if (anio) return intento(anio < 100 ? 2000 + anio : anio)
  const este = intento(actual)
  if (!este) return null
  // Si ya pasó hace mucho (p. ej. "5/01" en diciembre), es el del año siguiente
  if (diasEntre(hoy, este) < -MAX_DIAS) return intento(actual + 1)
  return este
}

/** "7am" → 07:00, "4 de la tarde" → 16:00, "10:30" → 10:30, "3" → 15:00 (la clínica abre de 7 a 15) */
export function interpretarHora(texto: string): string | null {
  const t = normalizar(texto)
  const m = t.match(/(?:^|\s)(?:a las?\s+)?(\d{1,2})(?:\s*[:.]\s*(\d{2}))?\s*(a\.?\s?m\.?|p\.?\s?m\.?|hrs?\.?|h|de la manana|de la tarde|de la noche)?(?=\s|$)/)
  if (!m) return null
  let hora = Number(m[1])
  const min = m[2] ? Number(m[2]) : 0
  const sufijo = (m[3] ?? '').replace(/[\s.]/g, '')
  if (hora > 23 || min > 59) return null
  if (/^(pm|delatarde|delanoche)$/.test(sufijo) && hora < 12) hora += 12
  else if (!sufijo && hora >= 1 && hora <= 6) hora += 12   // "a las 3" en una clínica = 15:00
  if (/^(am|delamanana)$/.test(sufijo) && hora === 12) hora = 0
  return `${String(hora).padStart(2, '0')}:${String(min).padStart(2, '0')}`
}

/**
 * Fecha (y hora opcional) de un mensaje. null si el mensaje no menciona un día.
 * Las fechas pasadas o a más de MAX_DIAS días se devuelven marcadas para explicarlo.
 */
export function interpretarFecha(texto: string, hoy: string): FechaInterpretada | null {
  let t = ` ${normalizar(texto).replace(/[¿?¡!,]/g, ' ')} `
  let fecha: string | null = null
  const quitar = (parte: string | RegExp) => { t = t.replace(parte, ' ') }
  const MANANA = /(?<!la)\smanana(?=\s)/   // "mañana" (el día), no "de la mañana" (la hora)

  let m: RegExpMatchArray | null
  if ((m = t.match(/\s(\d{1,2})\s*[/-]\s*(\d{1,2})(?:\s*[/-]\s*(\d{2,4}))?(?=\s)/))) {
    fecha = resolverDiaMes(Number(m[1]), Number(m[2]), hoy, m[3] ? Number(m[3]) : undefined)
    if (!fecha) return null
    quitar(m[0])
  } else if ((m = t.match(/\s(?:el\s+)?(\d{1,2})\s+(?:de\s+)?(\p{L}+\.?)(?:\s+(?:de(?:l)?\s+)?(\d{4}))?(?=\s)/u)) && mesDe(m[2])) {
    fecha = resolverDiaMes(Number(m[1]), mesDe(m[2])!, hoy, m[3] ? Number(m[3]) : undefined)
    if (!fecha) return null
    quitar(m[0])
  } else if (/\spasado\s+manana(?=\s)/.test(t)) {
    fecha = sumarDias(hoy, 2); quitar(/\spasado\s+manana(?=\s)/)
  } else if (MANANA.test(t)) {
    fecha = sumarDias(hoy, 1); quitar(MANANA)
  } else if (/\shoy(?=\s)/.test(t)) {
    fecha = hoy; quitar(/\shoy(?=\s)/)
  } else {
    const dia = DIAS_SEMANA.findIndex((d) => new RegExp(`\\s${d}(?=\\s)`).test(t))
    if (dia < 0) return null
    // El próximo: si hoy es jueves, "jueves" es el de la semana que entra
    const faltan = (dia - diaSemana(hoy) + 7) % 7 || 7
    fecha = sumarDias(hoy, faltan)
    quitar(new RegExp(`\\s(el\\s+)?(proximo\\s+)?${DIAS_SEMANA[dia]}(?=\\s)`))
  }

  const diferencia = diasEntre(hoy, fecha)
  if (diferencia < 0) return { tipo: 'pasada', fecha }
  if (diferencia > MAX_DIAS) return { tipo: 'lejana', fecha }
  return { tipo: 'fecha', fecha, hora: /\d/.test(t) ? interpretarHora(t) : null }
}
