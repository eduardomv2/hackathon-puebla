// pagos-webhook: simula al proveedor de pagos que avisa que un pago se acreditó.
//
//   POST { "referencia": "SD-…", "estado": "pagado" | "fallido", "telefono"?: "…" }
//
// Autenticación del proveedor:
//   · Con PAGOS_WEBHOOK_SECRET: el header x-firma debe ser HMAC-SHA256 (hex) del cuerpo.
//   · Sin secreto, solo se acepta en MODO_SIMULADOR (el botón "Pagar" del teléfono simulado).
//   · Ni una ni otra: 401. Nadie puede confirmar pagos sin firma fuera de local.
import { clienteServicio, ErrorApi, modoSimulador, rpc } from '../_shared/supabase.ts'
import { enviarAlPaciente } from '../_shared/enviar.ts'
import { cors, firmaValida, json, respuestaDeError } from '../_shared/http.ts'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ code: 'PT405', message: 'Usa POST' }, 405)

  try {
    const cuerpo = await req.text()
    const secreto = Deno.env.get('PAGOS_WEBHOOK_SECRET')
    if (secreto) {
      if (!(await firmaValida(secreto, cuerpo, req.headers.get('x-firma')))) throw new ErrorApi('42501', 'Firma inválida')
    } else if (!modoSimulador) {
      throw new ErrorApi('42501', 'Webhook de pagos sin PAGOS_WEBHOOK_SECRET configurado')
    }

    const { referencia, estado = 'pagado', telefono } = JSON.parse(cuerpo || '{}')
    if (typeof referencia !== 'string') throw new ErrorApi('22023', 'Falta la referencia del pago')

    // Sin x-sd-telefono: es el proveedor, no un paciente (tarea interna, exenta del rate limit)
    const resultado = await rpc(clienteServicio(), 'confirmar_pago', {
      p_referencia: referencia, p_estado: estado, p_datos: { origen: modoSimulador ? 'simulador' : 'proveedor' },
    })

    // Solo en el simulador: avisar en la bandeja del teléfono que pagó.
    // (En producción el aviso al paciente lo haría el worker de notificaciones.)
    // Si el aviso falla, el pago YA quedó confirmado: no se reporta como error.
    if (modoSimulador && typeof telefono === 'string' && !resultado?.repetido) {
      try {
        await enviarAlPaciente(telefono, 'sistema', estado === 'pagado'
          ? `Recibimos tu pago (referencia ${referencia}). Tu cita quedó confirmada.`
          : `Tu pago con referencia ${referencia} fue rechazado. Puedes intentarlo de nuevo.`)
      } catch (e) {
        console.error('pagos-webhook: pago confirmado, pero no se pudo avisar al paciente:', e instanceof Error ? e.message : e)
      }
    }
    return json(resultado)
  } catch (e) {
    return respuestaDeError(e)
  }
})
