// pago-demo: pantalla de pago de PRUEBA de las apps (web/app del paciente).
//
//   POST { "interaccion_id": "<uuid>", "referencia": "SD-…" }   Authorization: Bearer <JWT del paciente>
//   → { "estado": "pagado", "repetido"?: true, "tramite_id": … }
//
// Solo existe con PAGO_DEMO=true (si no, 404). Solo el paciente dueño del pago, con un pago
// pendiente y sin vencer; pagar uno ya pagado responde igual. Termina en api.confirmar_pago,
// el mismo camino que el webhook del proveedor real (ver _shared/pago_demo.ts).
import { clienteUsuario, ErrorApi } from '../_shared/supabase.ts'
import { pagarDemo, pagoDemoActivo } from '../_shared/pago_demo.ts'
import { cors, json, respuestaDeError } from '../_shared/http.ts'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (!pagoDemoActivo()) return json({ code: 'PT404', message: 'No disponible' }, 404)
  if (req.method !== 'POST') return json({ code: 'PT405', message: 'Usa POST' }, 405)

  try {
    const jwt = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '')
    if (!jwt) throw new ErrorApi('42501', 'Falta la sesión del paciente')
    const { interaccion_id, referencia } = await req.json().catch(() => ({}))
    if (typeof interaccion_id !== 'string' || typeof referencia !== 'string') {
      throw new ErrorApi('22023', 'Faltan interaccion_id y referencia')
    }
    const paciente = clienteUsuario(jwt)
    const { data, error } = await paciente.auth.getUser(jwt)
    if (error || !data.user) throw new ErrorApi('42501', 'Sesión inválida o vencida')
    if (data.user.app_metadata?.rol) throw new ErrorApi('42501', 'Solo el paciente paga sus citas')
    // pago_del_paciente se consulta con el JWT del paciente: la base valida que la interacción sea suya
    return json(await pagarDemo(paciente, interaccion_id, referencia))
  } catch (e) {
    return respuestaDeError(e)
  }
})
