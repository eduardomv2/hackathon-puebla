// enviar-otp: el asesor pide un código de verificación para el paciente que atiende.
//
//   POST { "interaccion_id": "<uuid>" }   Authorization: Bearer <JWT del asesor>
//   → { "expira_en": "...", "telefono_enmascarado": "+52******4567" }
//
// El código se envía al teléfono REGISTRADO del paciente (lo decide api.solicitar_otp)
// y nunca llega al navegador del asesor: ni el código ni el teléfono completo.
import { clienteServicio, clienteUsuario, ErrorApi, rpc } from '../_shared/supabase.ts'
import { enviarAlPaciente } from '../_shared/enviar.ts'
import { cors, json, respuestaDeError } from '../_shared/http.ts'

const ROLES_PERSONAL = ['asesor', 'recepcion', 'supervisor', 'admin']

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ code: 'PT405', message: 'Usa POST' }, 405)

  try {
    const jwt = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '')
    if (!jwt) throw new ErrorApi('42501', 'Falta el JWT del asesor')

    const { interaccion_id } = await req.json().catch(() => ({}))
    if (typeof interaccion_id !== 'string') throw new ErrorApi('22023', 'Falta interaccion_id')

    // 1. ¿Quién llama? (Auth valida la firma y la vigencia del JWT)
    const asesor = clienteUsuario(jwt)
    const { data: usuario, error } = await asesor.auth.getUser(jwt)
    if (error || !usuario.user) throw new ErrorApi('42501', 'Sesión inválida o vencida')
    if (!ROLES_PERSONAL.includes(usuario.user.app_metadata?.rol)) {
      throw new ErrorApi('42501', 'Solo el personal puede pedir un código de verificación')
    }

    // 2. ¿La interacción es suya? cargar_interaccion lo valida con su propio JWT
    //    (42501 si es de otro asesor, PT404 si no existe).
    await rpc(asesor, 'obtener_contexto', { p_interaccion_id: interaccion_id })

    // 3. Generar el código (solo service_role) y enviarlo al teléfono registrado
    const otp = await rpc<{ codigo: string; expira_en: string; telefono: string; telefono_enmascarado: string }>(
      clienteServicio(), 'solicitar_otp', { p_interaccion_id: interaccion_id })
    await enviarAlPaciente(otp.telefono, 'otp',
      `Salud Digna: tu código de verificación es ${otp.codigo}. Vence en 5 minutos. ` +
      'Díselo solo al asesor que te está atendiendo.')

    return json({ expira_en: otp.expira_en, telefono_enmascarado: otp.telefono_enmascarado })
  } catch (e) {
    return respuestaDeError(e)
  }
})
