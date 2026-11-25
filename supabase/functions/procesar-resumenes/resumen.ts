// Resumen del trámite para el asesor: LLM (Claude) con respaldo por plantilla.
//
//   · Con ANTHROPIC_API_KEY: Claude resume en 2-3 líneas a partir de api.material_resumen.
//     El SDK se importa solo si hay clave, así que sin clave ni internet nada falla.
//   · Respaldo sin LLM (sin clave, error, rechazo o más de 8 s): plantilla armada con los
//     datos del trámite. Nunca inventa: solo usa lo que trae la base.

// deno-lint-ignore no-explicit-any
type Material = any

export type Resumen = { texto: string; metodo: 'llm' | 'plantilla'; motivo?: string }

const MODELO = 'claude-opus-5-5'
const LIMITE_MS = 8000

const CANAL: Record<string, string> = {
  web: 'web', app: 'app', whatsapp: 'WhatsApp', call_center: 'llamada', clinica: 'clínica',
}
const PASO: Record<string, string> = {
  seleccion_estudio: 'elegir estudio', seleccion_clinica: 'elegir clínica', seleccion_horario: 'elegir horario',
  pago: 'pagar la cita', confirmada: 'nada: cita confirmada',
}

/** Respaldo determinista: solo datos que ya están en el trámite. */
export function resumenPorPlantilla(m: Material): string {
  const t = m.tramite ?? {}
  const para = t.beneficiario?.relacion && t.beneficiario.relacion !== 'titular'
    ? `${t.beneficiario.nombre ?? 'un familiar'} (${t.beneficiario.relacion})` : 'el titular'
  const estudio = t.estudio?.nombre ?? 'estudio sin elegir'
  const clinica = t.clinica?.nombre ?? 'clínica sin elegir'
  const canales = (t.canales_usados ?? []).map((c: string) => CANAL[c] ?? c).join(', ') || CANAL[t.canal_origen] || '—'
  const cita = t.contexto?.fecha_hora
    ? ` Cita apartada: ${new Intl.DateTimeFormat('es-MX', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'America/Mexico_City' })
        .format(new Date(t.contexto.fecha_hora)).replace(/\.$/, '')}.` : ''
  const falta = t.estado === 'completado' ? 'nada: trámite completado'
    : (PASO[t.paso_actual] ?? t.paso_descripcion ?? t.paso_actual)
  return `${t.folio ?? ''} · ${estudio} para ${para} en ${clinica}. Va en «${t.paso_descripcion ?? t.paso_actual}»; ` +
    `canales: ${canales}.${cita}\nFalta: ${falta}.`
}

const INSTRUCCIONES = `Eres el asistente de un asesor de call center de Salud Digna (laboratorio y estudios de imagen en México).
Escribe un resumen del trámite de 2 a 3 líneas, en español, para que el asesor lo lea de un vistazo durante la llamada.
Incluye: para quién es (el titular o un familiar suyo), estudio, clínica, en qué paso va, por qué canales ha pasado y qué falta.
Usa solo los datos del material; si algo no está, dilo ("clínica sin elegir") en lugar de suponerlo.
No incluyas saludos, viñetas ni encabezados: solo el resumen.`

/** Llama a Claude con un límite de 8 s. Devuelve null si no hay clave (sin importar el SDK). */
async function resumenPorLlm(m: Material): Promise<string | null> {
  const clave = Deno.env.get('ANTHROPIC_API_KEY')
  if (!clave) return null
  const { default: Anthropic } = await import('npm:@anthropic-ai/sdk')
  const cliente = new Anthropic({ apiKey: clave })
  const respuesta = await cliente.beta.messages.create(
    {
      model: MODELO,
      max_tokens: 4000,
      output_config: { effort: 'low' },
      // Si el modelo declina la petición, la API la reintenta con otro modelo (respaldo de modelo)
      betas: ['server-side-fallback-2026-07-01'],
      fallbacks: 'default',
      system: INSTRUCCIONES,
      messages: [{
        role: 'user',
        content: `Material del trámite (JSON):\n${JSON.stringify({
          tramite: { ...m.tramite, resumen: undefined }, resumen_anterior: m.resumen_anterior?.replace(/^\[(ia|plantilla)\]\s*/, ''),
          eventos_nuevos: m.eventos_nuevos, mensajes_nuevos: m.mensajes_nuevos,
        })}`,
      }],
    } as never,
    { timeout: LIMITE_MS, maxRetries: 0 },
  ) as { stop_reason: string; content: { type: string; text?: string }[] }
  if (respuesta.stop_reason === 'refusal') throw new Error('El modelo declinó la petición')
  const texto = respuesta.content.filter((b) => b.type === 'text').map((b) => b.text).join('').trim()
  if (!texto) throw new Error('Respuesta vacía')
  return texto
}

export async function resumir(m: Material): Promise<Resumen> {
  let reloj: number | undefined
  try {
    // El límite cubre todo el camino del LLM (incluida la primera carga del SDK), no solo la petición
    const limite = new Promise<never>((_, no) => { reloj = setTimeout(() => no(new Error(`El LLM tardó más de ${LIMITE_MS / 1000} s`)), LIMITE_MS) })
    const texto = await Promise.race([resumenPorLlm(m), limite])
    if (texto) return { texto, metodo: 'llm' }
    return { texto: resumenPorPlantilla(m), metodo: 'plantilla', motivo: 'sin ANTHROPIC_API_KEY' }
  } catch (e) {
    return { texto: resumenPorPlantilla(m), metodo: 'plantilla', motivo: e instanceof Error ? e.message : String(e) }
  } finally {
    clearTimeout(reloj)
  }
}
