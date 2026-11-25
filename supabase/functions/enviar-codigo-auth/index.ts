// enviar-codigo-auth: entrega el código con el que la web/app verifica un celular (WhatsApp; si falla, SMS).
//
//   La invoca la base (hooks.enviar_codigo_auth, el "Send SMS Hook" de Supabase Auth) por pg_net:
//   POST { "telefono": "52…", "codigo": "123456" }   Authorization: Bearer <worker_token de Vault>
//
//   · local (MODO_SIMULADOR=true): a la bandeja del teléfono simulado, con CUALQUIER número.
//   · producción: WhatsApp (plantilla de autenticación) y, si no se entrega, SMS (CANAL_CODIGO,
//     ver _shared/enviar.ts).
import { enviarCodigo } from '../_shared/enviar.ts'
import { json, esLlamadaInterna } from '../_shared/http.ts'

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ code: 'PT405', message: 'Usa POST' }, 405)
  if (!esLlamadaInterna(req)) {
    return json({ code: '42501', message: 'Solo la base puede invocar esta función' }, 401)
  }
  const { telefono, codigo } = await req.json().catch(() => ({}))
  if (typeof telefono !== 'string' || !/^\d{10,15}$/.test(telefono) || typeof codigo !== 'string' || !/^\d{4,10}$/.test(codigo)) {
    return json({ code: '22023', message: 'Faltan el teléfono o el código' }, 400)
  }
  try {
    const canal = await enviarCodigo(telefono, codigo,
      `Salud Digna: tu código de verificación es ${codigo}. Vence en 5 minutos. No lo compartas con nadie.`)
    return json({ enviado: true, canal })
  } catch (e) {
    console.error('enviar-codigo-auth:', e)
    return json({ code: 'XX000', message: 'No se pudo enviar el código ni por WhatsApp ni por SMS' }, 502)
  }
})
