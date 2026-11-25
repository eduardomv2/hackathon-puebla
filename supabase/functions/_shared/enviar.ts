// Canal de salida hacia el teléfono del paciente.
//   MODO_SIMULADOR=true → escribe en la bandeja simulada (simulador.enviar).
//   Si no:
//     WhatsApp Cloud API (Meta)
//       WHATSAPP_TOKEN            token de acceso (usuario del sistema de Meta Business)
//       WHATSAPP_PHONE_NUMBER_ID  id del número que envía (no es el teléfono)
//       WHATSAPP_PLANTILLA_OTP    plantilla aprobada de categoría "Autenticación" con botón
//                                 "Copiar código" (Meta exige plantilla para los códigos)
//       WHATSAPP_IDIOMA           idioma de la plantilla (por omisión es_MX)
//       Los demás mensajes se mandan como texto: Meta solo los entrega dentro de las 24 h
//       desde el último mensaje del paciente (fuera de esa ventana hacen falta plantillas).
//     SMS (solo códigos de verificación), con Vonage
//       VONAGE_API_KEY, VONAGE_API_SECRET, VONAGE_REMITENTE (número o nombre que envía)
//
// Códigos de verificación (enviarCodigo), según CANAL_CODIGO:
//   whatsapp_y_sms (por omisión) · WhatsApp; si falla al enviar, SMS al momento; si Meta
//                                  avisa después que no se entregó (webhook, statuses: failed),
//                                  whatsapp-webhook manda el mismo código por SMS.
//   whatsapp · solo WhatsApp      sms · solo SMS
//
// Pruebas con teléfonos reales en local: TELEFONOS_REALES=528661234567,52… (separados por
// comas). Aun con MODO_SIMULADOR, a esos números se les envía de verdad (WhatsApp de Meta;
// con el número de prueba de Meta deben estar en su lista de destinatarios). Los demás
// siguen en la bandeja simulada. Sin plantilla (WHATSAPP_PLANTILLA_OTP), el código va como
// texto: Meta solo lo entrega si el paciente escribió al número en las últimas 24 h.
import { createClient } from 'npm:@supabase/supabase-js@2'
import { clienteServicio, modoSimulador, rpc } from './supabase.ts'

export type TipoEnvio = 'otp' | 'link_pago' | 'bot' | 'sistema'

const API_META = 'https://graph.facebook.com/v23.0'
const API_VONAGE = 'https://rest.nexmo.com/sms/json'

/**
 * fetch con un reintento si falla la RED (DNS, conexión caída, sin respuesta en 10 s): espera
 * 1 s y vuelve a intentar una vez. Si el servicio SÍ responde (aunque sea con error), no se
 * repite: ese error no se arregla reintentando.
 */
async function fetchConReintento(url: string, init: RequestInit): Promise<Response> {
  try {
    return await fetch(url, { ...init, signal: AbortSignal.timeout(10_000) })
  } catch (e) {
    console.warn(`Falla de red con ${new URL(url).host}; reintento en 1 s:`, e instanceof Error ? e.message : e)
    await new Promise((r) => setTimeout(r, 1000))
    return await fetch(url, { ...init, signal: AbortSignal.timeout(10_000) })
  }
}

/** Últimos 10 dígitos (México: 52 y 521 son el mismo celular) */
const diezDigitos = (t: string) => t.replace(/\D/g, '').slice(-10)
const TELEFONOS_REALES = new Set((Deno.env.get('TELEFONOS_REALES') ?? '').split(',').map(diezDigitos).filter((t) => t.length === 10))
/** ¿Este teléfono se simula? (todo en MODO_SIMULADOR, salvo los TELEFONOS_REALES) */
const simulado = (telefono: string) => modoSimulador && !TELEFONOS_REALES.has(diezDigitos(telefono))

async function aBandejaSimulada(telefono: string, tipo: TipoEnvio, contenido: string) {
  const cliente = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false },
    db: { schema: 'simulador' },
    global: { headers: { 'x-sd-telefono': telefono } },
  })
  const { error } = await cliente.rpc('enviar', { p_telefono: telefono, p_tipo: tipo, p_contenido: contenido })
  if (error) throw new Error(`No se pudo escribir en la bandeja simulada: ${error.message}`)
}

/** Envía por WhatsApp. Devuelve el id del mensaje (para relacionar el estado que Meta avise después). */
export async function enviarAlPaciente(telefono: string, tipo: TipoEnvio, contenido: string,
                                       extra: { codigo?: string } = {}): Promise<{ mensaje_id?: string }> {
  if (simulado(telefono)) {
    await aBandejaSimulada(telefono, tipo, contenido)
    return { mensaje_id: `sim.${crypto.randomUUID()}` }
  }
  return { mensaje_id: await enviarPorWhatsApp(telefono, tipo, contenido, extra.codigo) }
}

/** Código de verificación por WhatsApp y, si no se entrega, por SMS. Devuelve el canal usado. */
export async function enviarCodigo(telefono: string, codigo: string, texto: string): Promise<'whatsapp' | 'sms'> {
  const canal = Deno.env.get('CANAL_CODIGO') ?? 'whatsapp_y_sms'
  if (canal === 'sms') {
    await enviarSms(telefono, textoSms(codigo))
    return 'sms'
  }
  let mensajeId: string | undefined
  try {
    mensajeId = (await enviarAlPaciente(telefono, 'otp', texto, { codigo })).mensaje_id
  } catch (e) {
    if (canal !== 'whatsapp_y_sms') throw e
    console.error('El código no salió por WhatsApp; va por SMS:', e instanceof Error ? e.message : e)
    await enviarSms(telefono, textoSms(codigo))
    return 'sms'
  }
  // Se guarda (cifrado, 10 min) por si Meta avisa que no se entregó
  if (canal === 'whatsapp_y_sms' && mensajeId) {
    try {
      await rpc(clienteServicio(telefono), 'registrar_codigo_enviado', {
        p_mensaje_id: mensajeId, p_telefono: telefono.replace(/\D/g, ''), p_codigo: codigo,
      })
    } catch (e) {
      console.error('No se pudo registrar el código para el respaldo por SMS:', e)
    }
  }
  return 'whatsapp'
}

/** Estado de un mensaje que avisa Meta (webhook): si era un código y falló, va por SMS. */
export async function resolverEstadoDeMensaje(mensajeId: string, estado: string): Promise<'sms' | null> {
  if (!['failed', 'delivered', 'read'].includes(estado)) return null
  const pendiente = await rpc<{ telefono: string; codigo: string } | null>(clienteServicio(), 'resolver_codigo_enviado', {
    p_mensaje_id: mensajeId, p_entregado: estado !== 'failed',
  })
  if (!pendiente) return null
  await enviarSms(pendiente.telefono, textoSms(pendiente.codigo))
  return 'sms'
}

const textoSms = (codigo: string) => `Salud Digna: tu código de verificación es ${codigo}. Vence en 5 minutos.`

export async function enviarSms(telefono: string, texto: string): Promise<void> {
  const [clave, secreto, remitente] = ['VONAGE_API_KEY', 'VONAGE_API_SECRET', 'VONAGE_REMITENTE'].map((v) => Deno.env.get(v))
  // En local, un teléfono real sin Vonage configurado recibe el SMS en la bandeja simulada
  if (simulado(telefono) || (modoSimulador && !(clave && secreto && remitente))) {
    return aBandejaSimulada(telefono, 'otp', `[SMS] ${texto}`)
  }
  if (!clave || !secreto || !remitente) {
    throw new Error('SMS no configurado (VONAGE_API_KEY, VONAGE_API_SECRET, VONAGE_REMITENTE)')
  }
  const r = await fetchConReintento(API_VONAGE, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      api_key: clave, api_secret: secreto, from: remitente, to: telefono.replace(/\D/g, ''), text: texto, type: 'unicode',
    }),
  })
  const cuerpo = await r.json().catch(() => ({})) as { messages?: { status?: string; 'error-text'?: string }[] }
  const m = cuerpo.messages?.[0]
  if (!r.ok || m?.status !== '0') {
    throw new Error(`SMS no enviado (Vonage ${r.status}, estado ${m?.status ?? '?'}): ${m?.['error-text'] ?? 'sin detalle'}`)
  }
}

async function enviarPorWhatsApp(telefono: string, tipo: TipoEnvio, contenido: string, codigo?: string): Promise<string | undefined> {
  const token = Deno.env.get('WHATSAPP_TOKEN')
  const numeroId = Deno.env.get('WHATSAPP_PHONE_NUMBER_ID')
  // Un código que no se envía no debe parecer enviado: sin configuración, se falla
  if (!token || !numeroId) {
    throw new Error(`WhatsApp no configurado (WHATSAPP_TOKEN, WHATSAPP_PHONE_NUMBER_ID): no se envió "${tipo}"`)
  }
  const to = telefono.replace(/\D/g, '')
  const plantilla = Deno.env.get('WHATSAPP_PLANTILLA_OTP')
  let mensaje: Record<string, unknown>
  if (tipo === 'otp' && codigo && plantilla) {
    // Plantilla de autenticación: el código va en el cuerpo y en el botón "Copiar código"
    mensaje = {
      type: 'template',
      template: {
        name: plantilla,
        language: { code: Deno.env.get('WHATSAPP_IDIOMA') ?? 'es_MX' },
        components: [
          { type: 'body', parameters: [{ type: 'text', text: codigo }] },
          { type: 'button', sub_type: 'url', index: '0', parameters: [{ type: 'text', text: codigo }] },
        ],
      },
    }
  } else {
    mensaje = { type: 'text', text: { body: contenido, preview_url: tipo === 'link_pago' } }
  }
  const enviar = async (destino: string) => {
    const r = await fetchConReintento(`${API_META}/${numeroId}/messages`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ messaging_product: 'whatsapp', recipient_type: 'individual', to: destino, ...mensaje }),
    })
    return { r, cuerpo: await r.json().catch(() => ({})) as { messages?: { id?: string }[]; error?: { message?: string; code?: number } } }
  }
  let { r, cuerpo } = await enviar(to)
  // México: Meta a veces registra el celular como 521XXXXXXXXXX y otras como 52XXXXXXXXXX.
  // Si responde "no está en la lista de destinatarios" (131030), se intenta el otro formato.
  if (!r.ok && cuerpo.error?.code === 131030 && /^521?\d{10}$/.test(to)) {
    ;({ r, cuerpo } = await enviar(to.length === 12 ? `521${to.slice(2)}` : `52${to.slice(3)}`))
  }
  if (!r.ok) {
    throw new Error(`WhatsApp respondió ${r.status}: ${cuerpo.error?.message ?? 'sin detalle'} (código ${cuerpo.error?.code ?? '?'})`)
  }
  return cuerpo.messages?.[0]?.id
}
