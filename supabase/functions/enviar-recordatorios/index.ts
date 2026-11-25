// enviar-recordatorios: vacía la cola `recordatorios` (la llena core.programar_recordatorios cada 5 min
// con los trámites sin actividad por 2 horas) y la confirma.
//
// El aviso al paciente NO se entrega aquí: al programarse el recordatorio se registra el evento
// recordatorio_programado, y el disparador de avisos lo encola en `avisos_whatsapp`, que entrega
// la función avisos-whatsapp (con consentimiento, ventana de 24 h y plantilla). Aquí solo se
// descartan los mensajes de la cola para que no se acumulen ni se reintenten sin fin.
import { clienteServicio, rpc } from '../_shared/supabase.ts'
import { json, respuestaDeError, esLlamadaInterna } from '../_shared/http.ts'

type MensajeCola = { msg_id: number; intento: number; mensaje: { paciente_id: string; tramite_id: string; paso_actual: string } }

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ code: 'PT405', message: 'Usa POST' }, 405)
  if (!esLlamadaInterna(req)) {
    return json({ code: '42501', message: 'Solo el despachador interno puede invocar esta función' }, 401)
  }
  try {
    const api = clienteServicio()
    const resumen = { procesados: 0, fallidos: 0 }
    for (let vuelta = 0; vuelta < 5; vuelta++) {
      const lote = await rpc<MensajeCola[]>(api, 'cola_leer', { p_cola: 'recordatorios', p_cantidad: 50, p_visibilidad_seg: 30 })
      if (!lote.length) break
      for (const m of lote) {
        try {
          await rpc(api, 'cola_confirmar', { p_cola: 'recordatorios', p_msg_id: m.msg_id })
          resumen.procesados++
        } catch (e) {
          console.error('enviar-recordatorios', m.msg_id, e)
          resumen.fallidos++
        }
      }
    }
    return json(resumen)
  } catch (e) {
    return respuestaDeError(e)
  }
})
