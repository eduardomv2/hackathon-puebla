// avisos-whatsapp: vacía la cola avisos_whatsapp y entrega cada aviso al teléfono.
//
//   La invoca pg_cron (core.despachar_worker cada 5 s, solo si hay avisos) con
//   Authorization: Bearer <worker_token de Vault> = la clave de servicio.
//
// Qué avisar y cómo (consentimiento, ventana de 24 h, plantilla o texto) lo decide
// la base en api.procesar_aviso_whatsapp, que además registra el mensaje saliente.
// Aquí solo se entrega: bandeja simulada en MODO_SIMULADOR, WhatsApp real (TODO) si no.
import { clienteServicio, rpc } from '../_shared/supabase.ts'
import { enviarAlPaciente } from '../_shared/enviar.ts'
import { json, respuestaDeError, esLlamadaInterna } from '../_shared/http.ts'

type MensajeCola = { msg_id: number; intento: number; mensaje: { evento_id: string; paciente_id: string; ocurrido_en: string } }
type Aviso = { enviar: boolean; motivo?: string; telefono?: string; tipo?: 'texto' | 'plantilla'; plantilla?: string; texto?: string }

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ code: 'PT405', message: 'Usa POST' }, 405)
  if (!esLlamadaInterna(req)) {
    return json({ code: '42501', message: 'Solo el despachador interno puede invocar esta función' }, 401)
  }

  try {
    const api = clienteServicio()   // sin x-sd-telefono: tarea interna
    const resumen = { procesados: 0, enviados: 0, omitidos: 0, fallidos: 0 }
    for (let vuelta = 0; vuelta < 5; vuelta++) {
      const lote = await rpc<MensajeCola[]>(api, 'cola_leer', { p_cola: 'avisos_whatsapp', p_cantidad: 20, p_visibilidad_seg: 30 })
      if (!lote.length) break
      for (const m of lote) {
        resumen.procesados++
        try {
          const aviso = await rpc<Aviso>(api, 'procesar_aviso_whatsapp', {
            p_evento_id: m.mensaje.evento_id, p_paciente_id: m.mensaje.paciente_id, p_ocurrido_en: m.mensaje.ocurrido_en,
          })
          if (aviso.enviar && aviso.telefono && aviso.texto) {
            // TODO(Meta): si aviso.tipo === 'plantilla', enviar type=template con su meta_template_id
            await enviarAlPaciente(aviso.telefono, 'bot', aviso.texto)
            resumen.enviados++
          } else {
            resumen.omitidos++
          }
          await rpc(api, 'cola_confirmar', { p_cola: 'avisos_whatsapp', p_msg_id: m.msg_id })
        } catch (e) {
          // Se queda en la cola: se reintenta al vencer la invisibilidad (máx. 5 intentos, luego archivo)
          console.error('avisos-whatsapp', m.msg_id, e)
          resumen.fallidos++
        }
      }
    }
    return json(resumen)
  } catch (e) {
    return respuestaDeError(e)
  }
})
