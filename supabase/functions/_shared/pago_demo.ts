// Pago de prueba (PAGO_DEMO=true): confirma un pago SIN pasarela, por el mismo camino que el
// webhook real (api.confirmar_pago), marcando el evento como simulado.
//   · Solo el dueño del pago: se busca con api.pago_del_paciente usando la interacción del
//     paciente (su sesión en la web/app, o la conversación de su teléfono en WhatsApp).
//   · Solo pagos pendientes y sin vencer; pagar uno ya pagado responde igual (idempotente).
//   · Apagado (por omisión): no hay forma de pagar así.
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { clienteServicio, ErrorApi, rpc } from './supabase.ts'

export const pagoDemoActivo = () => Deno.env.get('PAGO_DEMO') === 'true'

export type PagoPendiente = {
  referencia: string; monto: number; moneda: string; estudio: string; etiqueta: string; folio: string
  tramite_id: string; fecha_hora: string; expira_en: string; link_pago: string | null
}

/**
 * @param cliente  cliente con el que se consulta el pago: el del paciente (JWT) o el de servicio (bot)
 * @param interaccion interacción del paciente que paga
 */
export async function pagarDemo(cliente: SupabaseClient, interaccion: string, referencia: string) {
  if (!pagoDemoActivo()) throw new ErrorApi('PT404', 'Pago de prueba no disponible')
  const pago = await rpc<{ estado: string; vencido: boolean } | null>(cliente, 'pago_del_paciente', {
    p_interaccion_id: interaccion, p_referencia: referencia,
  })
  if (!pago) throw new ErrorApi('PT404', 'Pago no encontrado')
  if (pago.estado === 'pendiente' && pago.vencido) throw new ErrorApi('P0001', 'El link de pago venció')
  if (pago.estado !== 'pendiente' && pago.estado !== 'pagado') throw new ErrorApi('P0001', `El pago está ${pago.estado}`)
  // Mismo camino que el webhook del proveedor (solo service_role puede confirmar)
  return await rpc<{ estado: string; repetido?: boolean; tramite_id?: string }>(clienteServicio(), 'confirmar_pago', {
    p_referencia: referencia, p_estado: 'pagado', p_datos: { origen: 'pago_demo', simulado: true },
  })
}
