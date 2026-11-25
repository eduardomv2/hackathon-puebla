// =====================================================================
// interpretar(mensaje, contexto) → Intencion
//   Función PURA: no llama a la API ni guarda estado. Recibe el texto del
//   paciente y el contexto del diálogo (en qué paso va y qué opciones se le
//   mostraron) y devuelve una intención estructurada. Para cambiarla por un
//   LLM basta con respetar esta misma firma: el agente (agente.ts) ejecuta la
//   intención contra la API y la base decide si es válida.
// =====================================================================

import { interpretarFecha, interpretarHora, normalizar } from './fechas.ts'
export { normalizar }

export type Paso =
  | 'menu' | 'elegir_tramite' | 'en_atencion'
  | 'registro'                               // falta el nombre del titular: se pide antes de empezar
  | 'nuevo_estudio' | 'nuevo_para'           // "Empezar otro": primero el estudio, luego para quién
  | 'beneficiario' | 'estudio'
  | 'clinica_lugar' | 'clinica'             // ¿en qué ciudad? → clínicas de ese lugar
  | 'horario_dia' | 'horario_menu' | 'horario_confirmar'   // ¿qué día? → menú de horas del día → ¿te aparto…?
  | 'pago'

export type Opcion = { id: string; etiqueta: string }
export type Horario = { fecha_hora: string; fecha: string; hora: string }

export type ContextoDialogo = {
  paso: Paso
  /** Opciones numeradas mostradas en este paso (1 = primera) */
  opciones: Opcion[]
  /** Horarios mostrados (menú del día: 1 = primero; confirmación: el propuesto) */
  horarios: Horario[]
  /** Hoy (AAAA-MM-DD) en la zona de la clínica: interpretar no lee el reloj */
  hoy: string
  /** Día del menú o de la confirmación */
  fecha?: string
  /** Número de la opción "Ver más" del menú (si la hay) */
  ver_mas?: number | null
}

export type DatosFamiliar = {
  nombre: string
  apellido_paterno: string | null
  apellido_materno: string | null
  fecha_nacimiento: string // AAAA-MM-DD
  relacion: 'hijo' | 'hija' | 'madre' | 'padre' | 'conyuge' | 'otro'
}

export type Intencion =
  | { tipo: 'menu' }
  | { tipo: 'ayuda' }
  | { tipo: 'ver_citas' }
  | { tipo: 'nuevo_tramite' }
  | { tipo: 'elegir_tramite'; tramite_id: string }
  | { tipo: 'elegir_beneficiario'; beneficiario_id: string }
  | { tipo: 'pedir_datos_familiar'; error?: string }
  | { tipo: 'agregar_familiar'; datos: DatosFamiliar }
  | { tipo: 'elegir_estudio'; estudio_id: string }
  | { tipo: 'buscar_estudio'; texto: string }
  | { tipo: 'elegir_clinica'; clinica_id: string }
  | { tipo: 'buscar_clinica'; texto: string }
  | { tipo: 'elegir_horario'; fecha_hora: string }
  | { tipo: 'elegir_dia'; fecha: string; hora: string | null }
  | { tipo: 'fecha_invalida'; motivo: 'pasada' | 'lejana' | 'no_entendida'; fecha?: string }
  | { tipo: 'ver_mas' }
  | { tipo: 'pagar' }
  | { tipo: 'registrar_nombre'; nombre: string; apellido_paterno: string; apellido_materno: string | null }
  | { tipo: 'pedir_nombre'; error: string }
  | { tipo: 'no_entendido' }

/** Ids especiales de opciones */
export const OPCION_AGREGAR = '__agregar_familiar'
export const OPCION_NUEVO = '__nuevo_tramite'

// ---------------------------------------------------------------------
// Utilidades de texto
// ---------------------------------------------------------------------

function numeroDeOpcion(t: string, total: number): number | null {
  const m = t.match(/^(?:opcion\s*)?(\d{1,2})[.)]?$/)
  if (!m) return null
  const n = Number(m[1])
  return n >= 1 && n <= total ? n : null
}

const RELACIONES: Record<string, DatosFamiliar['relacion']> = {
  hijo: 'hijo', hija: 'hija', madre: 'madre', mama: 'madre', padre: 'padre', papa: 'padre',
  esposo: 'conyuge', esposa: 'conyuge', conyuge: 'conyuge', pareja: 'conyuge', otro: 'otro', otra: 'otro',
}

function parsearFecha(t: string): string | null {
  let d: number, m: number, a: number
  const dmy = t.match(/(\d{1,2})[/-](\d{1,2})[/-](\d{4})/)
  const ymd = t.match(/(\d{4})-(\d{1,2})-(\d{1,2})/)
  if (ymd) [a, m, d] = [Number(ymd[1]), Number(ymd[2]), Number(ymd[3])]
  else if (dmy) [d, m, a] = [Number(dmy[1]), Number(dmy[2]), Number(dmy[3])]
  else return null
  const fecha = new Date(Date.UTC(a, m - 1, d))
  if (fecha.getUTCDate() !== d || fecha.getUTCMonth() !== m - 1) return null
  return `${a}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`
}

/** "familiar: Luis López Ruiz, 01/07/2016, hijo" */
export function parsearFamiliar(texto: string): DatosFamiliar | string {
  const cuerpo = texto.replace(/^\s*familiar\s*:?\s*/i, '')
  const partes = cuerpo.split(',').map((p) => p.trim()).filter(Boolean)
  if (partes.length < 3) return 'Faltan datos: necesito nombre, fecha de nacimiento y relación.'
  const nombres = partes[0].split(/\s+/)
  const fecha = parsearFecha(partes[1])
  if (!fecha) return 'No entendí la fecha de nacimiento. Escríbela como 01/07/2016.'
  const relacion = RELACIONES[normalizar(partes[2])]
  if (!relacion) return 'No entendí la relación. Usa: hijo, hija, madre, padre, cónyuge u otro.'
  return {
    nombre: nombres[0],
    apellido_paterno: nombres[1] ?? null,
    apellido_materno: nombres.slice(2).join(' ') || null,
    fecha_nacimiento: fecha,
    relacion,
  }
}

const capital = (p: string) => p.toLocaleLowerCase('es-MX').replace(/(^|[\s-])(\p{L})/gu, (_, a, b) => a + b.toLocaleUpperCase('es-MX'))

/**
 * "Ana López García" → nombre Ana, paterno López, materno García.
 * Con 4 palabras o más, las dos últimas son los apellidos ("María José López Ruiz").
 */
export function parsearNombreCompleto(texto: string): { nombre: string; apellido_paterno: string; apellido_materno: string | null } | string {
  const limpio = texto.trim().replace(/^(me llamo|mi nombre es|soy|a nombre de)\s+/i, '').replace(/[.,;]+/g, ' ')
  const partes = limpio.split(/\s+/).filter(Boolean)
  if (partes.some((p) => !/^[\p{L}'-]+$/u.test(p))) return 'Escribe solo tu nombre y apellidos, sin números.'
  if (partes.length < 2) return 'Necesito tu nombre y al menos un apellido.'
  const [nombre, paterno, materno] = partes.length >= 4
    ? [partes.slice(0, -2).join(' '), partes.at(-2)!, partes.at(-1)!]
    : [partes[0], partes[1], partes[2] ?? null]
  return { nombre: capital(nombre), apellido_paterno: capital(paterno), apellido_materno: materno ? capital(materno) : null }
}


/** Día (y hora) del mensaje; null si no menciona ningún día */
function elegirDia(mensaje: string, ctx: ContextoDialogo): Intencion | null {
  const f = interpretarFecha(mensaje, ctx.hoy)
  if (!f) return null
  return f.tipo === 'fecha' ? { tipo: 'elegir_dia', fecha: f.fecha, hora: f.hora } : { tipo: 'fecha_invalida', motivo: f.tipo, fecha: f.fecha }
}

// ---------------------------------------------------------------------
// interpretar
// ---------------------------------------------------------------------
export function interpretar(mensaje: string, ctx: ContextoDialogo): Intencion {
  const t = normalizar(mensaje)

  // Palabras clave que funcionan en cualquier paso
  if (/^(menu|inicio|empezar|pendientes|mis tramites)$/.test(t)) return { tipo: 'menu' }
  if (/^(hola|holi|buen[oa]s?( dias| tardes| noches)?|que tal)\b/.test(t)) return { tipo: 'menu' }
  if (/^(ayuda|\?)$/.test(t)) return { tipo: 'ayuda' }
  if (/^(mis citas|ver (mis )?citas)$/.test(t)) return { tipo: 'ver_citas' }

  const n = numeroDeOpcion(t, ctx.opciones.length)

  switch (ctx.paso) {
    case 'menu':
      if (/^1$/.test(t) || /\b(agendar|agenda|cita nueva|estudio|nuevo|otro)\b/.test(t)) return { tipo: 'nuevo_tramite' }
      if (/^2$/.test(t) || /\bcitas?\b/.test(t)) return { tipo: 'ver_citas' }
      return { tipo: 'no_entendido' }

    case 'elegir_tramite': {
      if (n) {
        const op = ctx.opciones[n - 1]
        return op.id === OPCION_NUEVO ? { tipo: 'nuevo_tramite' } : { tipo: 'elegir_tramite', tramite_id: op.id }
      }
      if (/\b(otro|nuevo|nueva|empezar)\b/.test(t)) return { tipo: 'nuevo_tramite' }
      if (/^(si|continuar|seguir)$/.test(t) && ctx.opciones.length === 2) return { tipo: 'elegir_tramite', tramite_id: ctx.opciones[0].id }
      // Por folio ("SD-4K7Q") o por el nombre del estudio
      const porTexto = ctx.opciones.filter((o) => o.id !== OPCION_NUEVO && t.length >= 3 && normalizar(o.etiqueta).includes(t))
      if (porTexto.length === 1) return { tipo: 'elegir_tramite', tramite_id: porTexto[0].id }
      return { tipo: 'no_entendido' }
    }

    case 'registro': {
      const r = parsearNombreCompleto(mensaje)
      return typeof r === 'string' ? { tipo: 'pedir_nombre', error: r } : { tipo: 'registrar_nombre', ...r }
    }

    case 'en_atencion':
      // Mientras un asesor atiende el trámite solo se puede ver; 'menu' cambia de trámite
      return { tipo: 'no_entendido' }

    case 'nuevo_para':
    case 'beneficiario': {
      if (/^familiar\b/.test(t)) {
        const datos = parsearFamiliar(mensaje)
        return typeof datos === 'string' ? { tipo: 'pedir_datos_familiar', error: datos } : { tipo: 'agregar_familiar', datos }
      }
      if (n) {
        const op = ctx.opciones[n - 1]
        return op.id === OPCION_AGREGAR ? { tipo: 'pedir_datos_familiar' } : { tipo: 'elegir_beneficiario', beneficiario_id: op.id }
      }
      if (/^(para )?(mi|yo|mi mismo|mi misma)$/.test(t)) return { tipo: 'elegir_beneficiario', beneficiario_id: ctx.opciones[0].id }
      if (/\b(agregar|otro familiar|nuevo)\b/.test(t)) return { tipo: 'pedir_datos_familiar' }
      const porNombre = ctx.opciones.find((o) => o.id !== OPCION_AGREGAR && normalizar(o.etiqueta).split(' ')[0] === t)
      if (porNombre) return { tipo: 'elegir_beneficiario', beneficiario_id: porNombre.id }
      return { tipo: 'no_entendido' }
    }

    case 'nuevo_estudio':
    case 'estudio':
      if (n) return { tipo: 'elegir_estudio', estudio_id: ctx.opciones[n - 1].id }
      if (t.length >= 3 && !/^\d+$/.test(t)) return { tipo: 'buscar_estudio', texto: mensaje.trim() }
      return { tipo: 'no_entendido' }

    case 'clinica_lugar':
      // Ciudad, municipio, estado o colonia ("Puebla", "Tlalpan", "cdmx")
      if (t.length >= 3 && !/^\d+$/.test(t)) return { tipo: 'buscar_clinica', texto: mensaje.trim() }
      return { tipo: 'no_entendido' }

    case 'clinica': {
      if (n) return { tipo: 'elegir_clinica', clinica_id: ctx.opciones[n - 1].id }
      const porNombre = ctx.opciones.filter((o) => t.length >= 3 && normalizar(o.etiqueta).includes(t))
      if (porNombre.length === 1) return { tipo: 'elegir_clinica', clinica_id: porNombre[0].id }
      // Otro lugar ("mejor en Cholula")
      if (t.length >= 3 && !/^\d+$/.test(t)) return { tipo: 'buscar_clinica', texto: mensaje.trim().replace(/^(mejor )?(en|por) /i, '') }
      return { tipo: 'no_entendido' }
    }

    case 'horario_dia':
      return elegirDia(mensaje, ctx) ?? { tipo: 'fecha_invalida', motivo: 'no_entendida' }

    case 'horario_menu': {
      const n = numeroDeOpcion(t, ctx.horarios.length + (ctx.ver_mas ? 1 : 0))
      if (n && n === ctx.ver_mas) return { tipo: 'ver_mas' }
      if (n && ctx.horarios[n - 1]) return { tipo: 'elegir_horario', fecha_hora: ctx.horarios[n - 1].fecha_hora }
      if (/^(ver )?mas( horarios)?$|^otros?$/.test(t)) return ctx.ver_mas ? { tipo: 'ver_mas' } : { tipo: 'no_entendido' }
      // Otro día ("mejor el viernes"), u hora del mismo día ("10:30")
      const otroDia = elegirDia(mensaje, ctx)
      if (otroDia) return otroDia
      const hora = /\d/.test(t) && !/^\d{1,2}$/.test(t) ? interpretarHora(t) : null
      if (hora && ctx.fecha) {
        const h = ctx.horarios.find((x) => x.hora === hora)
        return h ? { tipo: 'elegir_horario', fecha_hora: h.fecha_hora } : { tipo: 'elegir_dia', fecha: ctx.fecha, hora }
      }
      return { tipo: 'no_entendido' }
    }

    case 'horario_confirmar':
      if (/^(si|sip|claro|ok|va|dale|confirmo|si,? por favor|correcto)\b/.test(t) && ctx.horarios[0]) {
        return { tipo: 'elegir_horario', fecha_hora: ctx.horarios[0].fecha_hora }
      }
      if (/^(no|nop|mejor no|otra hora|otro)\b/.test(t) && ctx.fecha) return { tipo: 'elegir_dia', fecha: ctx.fecha, hora: null }
      return elegirDia(mensaje, ctx) ?? { tipo: 'no_entendido' }

    case 'pago':
      if (/\b(pagar|pago|link|liga|enlace)\b/.test(t)) return { tipo: 'pagar' }
      return { tipo: 'no_entendido' }
  }
}
