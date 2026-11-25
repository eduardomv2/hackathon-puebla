// procesar-resumenes: vacía la cola resumen_tramite y guarda el resumen de cada trámite.
//
//   La invoca pg_cron (core.despachar_worker cada 5 s, solo si hay trabajo) con
//   Authorization: Bearer <worker_token de Vault> = la clave de servicio.
//
//   api.cola_leer → api.material_resumen → resumen (Claude o plantilla) → api.guardar_resumen
//   → api.cola_confirmar. La respuesta dice qué método se usó en cada trámite, y el texto
//   guardado empieza con "[ia]" o "[plantilla]" para que la UI lo muestre.
//   El resumen se guarda cifrado y lo ven la consola del asesor y el journey del panel.
import { clienteServicio, rpc } from '../_shared/supabase.ts'
import { json, respuestaDeError, esLlamadaInterna } from '../_shared/http.ts'
import { resumir } from './resumen.ts'

type MensajeCola = { msg_id: number; intento: number; mensaje: { tramite_id: string; paciente_id: string } }

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ code: 'PT405', message: 'Usa POST' }, 405)
  if (!esLlamadaInterna(req)) {
    return json({ code: '42501', message: 'Solo el despachador interno puede invocar esta función' }, 401)
  }

  try {
    const api = clienteServicio()   // sin x-sd-telefono: tarea interna
    const resultados: { tramite_id: string; metodo?: string; motivo?: string; error?: string }[] = []
    for (let vuelta = 0; vuelta < 3; vuelta++) {
      const lote = await rpc<MensajeCola[]>(api, 'cola_leer', { p_cola: 'resumen_tramite', p_cantidad: 10, p_visibilidad_seg: 60 })
      if (!lote.length) break
      for (const m of lote) {
        try {
          const material = await rpc(api, 'material_resumen', { p_tramite_id: m.mensaje.tramite_id })
          const r = await resumir(material)
          await rpc(api, 'guardar_resumen', { p_tramite_id: m.mensaje.tramite_id, p_resumen: `[${r.metodo}] ${r.texto}`, p_leido_en: material.leido_en })
          await rpc(api, 'cola_confirmar', { p_cola: 'resumen_tramite', p_msg_id: m.msg_id })
          resultados.push({ tramite_id: m.mensaje.tramite_id, metodo: r.metodo, motivo: r.motivo })
        } catch (e) {
          // Se queda en la cola: se reintenta al vencer la invisibilidad (máx. 5 intentos, luego archivo)
          console.error('procesar-resumenes', m.mensaje.tramite_id, e)
          resultados.push({ tramite_id: m.mensaje.tramite_id, error: e instanceof Error ? e.message : String(e) })
        }
      }
    }
    return json({ procesados: resultados.length, resultados })
  } catch (e) {
    return respuestaDeError(e)
  }
})
