// Utilidades HTTP comunes: CORS (el simulador llama desde el navegador),
// respuestas JSON y verificación de firmas HMAC de los webhooks.
import { ErrorApi } from './supabase.ts'

export const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info, x-hub-signature-256, x-firma',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
}

export function json(cuerpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(cuerpo), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
}

/** Convierte un error en respuesta JSON con el mismo `code` que usa la API. */
export function respuestaDeError(e: unknown): Response {
  if (e instanceof ErrorApi) {
    const status =
      e.code === 'limite_citas' ? 409
      : e.code.startsWith('PT') ? Number(e.code.slice(2))
      : e.code === '42501' ? 403
      : e.code === 'XX000' ? 500
      : 400
    return json({ code: e.code, message: e.message, hint: e.hint ?? null }, status)
  }
  console.error(e)
  return json({ code: 'error_interno', message: e instanceof Error ? e.message : String(e) }, 500)
}

/** HMAC-SHA256 en hexadecimal, comparado en tiempo constante. */
export async function firmaValida(secreto: string, cuerpo: string, firmaHex: string | null): Promise<boolean> {
  if (!firmaHex) return false
  const clave = await crypto.subtle.importKey('raw', new TextEncoder().encode(secreto), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const firma = new Uint8Array(await crypto.subtle.sign('HMAC', clave, new TextEncoder().encode(cuerpo)))
  const esperada = Array.from(firma, (b) => b.toString(16).padStart(2, '0')).join('')
  if (esperada.length !== firmaHex.length) return false
  let dif = 0
  for (let i = 0; i < esperada.length; i++) dif |= esperada.charCodeAt(i) ^ firmaHex.charCodeAt(i)
  return dif === 0
}
