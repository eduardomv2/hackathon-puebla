// Clientes de Supabase para las Edge Functions.
// La clave secreta (service_role) solo existe aquí, del lado del servidor.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2'

const URL = Deno.env.get('SUPABASE_URL')!
const CLAVE_SECRETA = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const CLAVE_PUBLICA = Deno.env.get('SUPABASE_ANON_KEY')!

export const modoSimulador = Deno.env.get('MODO_SIMULADOR') === 'true'

/**
 * Cliente con la clave secreta.
 * @param telefono Teléfono del paciente por el que actúa la función. Se manda en el
 *   header x-sd-telefono para que el rate limit cuente por paciente (60/min).
 *   Sin él (tareas internas como pagos) la petición queda exenta.
 */
export function clienteServicio(telefono?: string): SupabaseClient {
  return createClient(URL, CLAVE_SECRETA, {
    auth: { persistSession: false, autoRefreshToken: false },
    db: { schema: 'api' },
    global: { headers: telefono ? { 'x-sd-telefono': telefono } : {} },
  })
}

/** Cliente que actúa con el JWT de quien llamó (el asesor). */
export function clienteUsuario(jwt: string): SupabaseClient {
  return createClient(URL, CLAVE_PUBLICA, {
    auth: { persistSession: false, autoRefreshToken: false },
    db: { schema: 'api' },
    global: { headers: { Authorization: `Bearer ${jwt}` } },
  })
}

/** Error de la API con el campo `code` (PT404, PT409, PT429, 42501, 22023, P0001, XX000…). */
export class ErrorApi extends Error {
  constructor(
    public code: string,
    message: string,
    public hint?: string | null,
    public cuerpo?: unknown,
  ) {
    super(message)
  }
}

/**
 * Llama una función de la API (siempre POST, esquema api) y devuelve sus datos
 * o lanza ErrorApi. El 409 de limite_citas no trae `code`: se reporta como
 * code 'limite_citas' con el cuerpo original.
 */
export async function rpc<T = any>(cliente: SupabaseClient, funcion: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await cliente.rpc(funcion, args)
  if (error) {
    const e = error as unknown as Record<string, any>
    if (e.error === 'limite_citas') throw new ErrorApi('limite_citas', 'Se alcanzó el máximo de citas futuras', null, e)
    throw new ErrorApi(e.code ?? 'desconocido', e.message ?? String(e.error ?? 'Error desconocido'), e.hint, e)
  }
  return data as T
}
