// Canal de salida hacia el teléfono del paciente.
//   MODO_SIMULADOR=true → escribe en la bandeja simulada (simulador.enviar).
//   Si no             → canal real (WhatsApp Cloud API / SMS). PENDIENTE.
import { createClient } from 'npm:@supabase/supabase-js@2'
import { modoSimulador } from './supabase.ts'

export type TipoEnvio = 'otp' | 'link_pago' | 'bot' | 'sistema'

export async function enviarAlPaciente(telefono: string, tipo: TipoEnvio, contenido: string): Promise<void> {
  if (modoSimulador) {
    const cliente = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
      auth: { persistSession: false },
      db: { schema: 'simulador' },
      global: { headers: { 'x-sd-telefono': telefono } },
    })
    const { error } = await cliente.rpc('enviar', { p_telefono: telefono, p_tipo: tipo, p_contenido: contenido })
    if (error) throw new Error(`No se pudo escribir en la bandeja simulada: ${error.message}`)
    return
  }
  // TODO(canal real): enviar por WhatsApp Cloud API (POST /{phone-number-id}/messages con
  // WHATSAPP_TOKEN) o por SMS. Hasta entonces, fallar explícitamente: un OTP que no se
  // envía no debe parecer enviado.
  throw new Error(`Canal real no configurado: no se envió el mensaje "${tipo}" (define MODO_SIMULADOR=true en local)`)
}
