// whatsapp-webhook: recibe mensajes en el formato del webhook de WhatsApp Cloud API.
//
//   GET  ?hub.mode=subscribe&hub.verify_token=…&hub.challenge=…  → verificación de Meta
//   POST { "object": "whatsapp_business_account",
//          "entry": [{ "changes": [{ "value": { "messages": [{ "from": "5218661234567",
//                      "id": "wamid…", "type": "text", "text": { "body": "hola" } }] } }] }] }
//   Meta también avisa aquí el estado de lo que enviamos (value.statuses: sent, delivered, read,
//   failed): si un código de verificación no se entregó por WhatsApp, se manda por SMS.
//
// Autenticación:
//   · Con WHATSAPP_APP_SECRET: X-Hub-Signature-256 = "sha256=" + HMAC-SHA256(cuerpo).
//   · Sin secreto, solo se acepta en MODO_SIMULADOR (el chat del teléfono simulado).
//   · Ni una ni otra: 401.
// La respuesta incluye lo que contestó el bot (útil para el simulador; Meta la ignora).
import { modoSimulador } from '../_shared/supabase.ts'
import { cors, firmaValida, json } from '../_shared/http.ts'
import { resolverEstadoDeMensaje } from '../_shared/enviar.ts'
import { atenderMensaje } from './agente.ts'

type MensajeWhatsApp = { from: string; id: string; type: string; text?: { body: string } }
type EstadoWhatsApp = { id: string; status: string; recipient_id?: string }

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })

  // Verificación del webhook (Meta la hace una vez al configurarlo)
  if (req.method === 'GET') {
    const p = new URL(req.url).searchParams
    const token = Deno.env.get('WHATSAPP_VERIFY_TOKEN')
    if (p.get('hub.mode') === 'subscribe' && token && p.get('hub.verify_token') === token) {
      return new Response(p.get('hub.challenge') ?? '', { status: 200 })
    }
    return new Response('Forbidden', { status: 403 })
  }
  if (req.method !== 'POST') return json({ code: 'PT405', message: 'Usa POST' }, 405)

  const cuerpo = await req.text()
  const secreto = Deno.env.get('WHATSAPP_APP_SECRET')
  if (secreto) {
    const firma = req.headers.get('x-hub-signature-256')?.replace(/^sha256=/, '') ?? null
    if (!(await firmaValida(secreto, cuerpo, firma))) return json({ code: '42501', message: 'Firma inválida' }, 401)
  } else if (!modoSimulador) {
    return json({ code: '42501', message: 'Webhook sin WHATSAPP_APP_SECRET configurado' }, 401)
  }

  let datos: { entry?: { changes?: { value?: { messages?: MensajeWhatsApp[]; statuses?: EstadoWhatsApp[] } }[] }[] }
  try { datos = JSON.parse(cuerpo) } catch { return json({ code: '22023', message: 'JSON inválido' }, 400) }

  const cambios = (datos.entry ?? []).flatMap((e) => e.changes ?? [])
  const mensajes = cambios.flatMap((c) => c.value?.messages ?? [])
  const resultados = []

  // Estados de lo enviado: un código no entregado se reenvía por SMS
  const estados = []
  for (const s of cambios.flatMap((c) => c.value?.statuses ?? [])) {
    try {
      const respaldo = await resolverEstadoDeMensaje(s.id, s.status)
      if (respaldo) estados.push({ id: s.id, status: s.status, respaldo })
    } catch (e) {
      console.error('whatsapp-webhook estado', s.id, e)
      estados.push({ id: s.id, status: s.status, error: e instanceof Error ? e.message : String(e) })
    }
  }

  for (const m of mensajes) {
    try {
      if (m.type !== 'text' || !m.text?.body?.trim()) {
        resultados.push({ id: m.id, from: m.from, respuestas: [], aviso: 'Por ahora solo se procesan mensajes de texto' })
        continue
      }
      const r = await atenderMensaje(m.from, m.text.body)
      resultados.push({ id: m.id, from: m.from, ...r })
    } catch (e) {
      // A Meta siempre se le contesta 200 (si no, reintenta el mismo mensaje sin fin)
      console.error('whatsapp-webhook', m.id, e)
      resultados.push({ id: m.id, from: m.from, error: e instanceof Error ? e.message : String(e) })
    }
  }
  return json({ resultados, estados })
})
