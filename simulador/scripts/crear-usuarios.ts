/**
 * Crea (o actualiza) el personal de prueba del simulador.
 *
 *   npm run usuarios
 *
 * - Usuarios de Auth: con la API admin de Supabase (clave secreta, solo en este script de Node).
 * - core.staff: con SQL directo a la base local. core no se expone en la Data API (a propósito),
 *   así que no hay RPC para dar de alta personal. El trigger de core.staff copia el rol al JWT
 *   (app_metadata.rol).
 *
 * Toma URL y llaves de `npx supabase status` (o de API_URL, SERVICE_ROLE_KEY, ANON_KEY y DB_URL).
 * Es idempotente: se puede correr las veces que haga falta.
 */
import { execSync } from 'node:child_process'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createClient } from '@supabase/supabase-js'
import postgres from 'postgres'

// Auth exige al menos 6 caracteres. En supabase.com usa otra: CONTRASENA=… npm run usuarios
const CONTRASENA = process.env.CONTRASENA || 'demo1234'

const PERSONAL = [
  { email: 'asesor@demo.mx', nombre: 'Asesora Demo (call center)', rol: 'asesor', clinica: null },
  { email: 'clinica@demo.mx', nombre: 'Supervisora Demo (Puebla centro, PUE-CEN)', rol: 'supervisor', clinica: 'PUE-CEN' },
  { email: 'recepcion@demo.mx', nombre: 'Recepción Demo (Puebla centro, PUE-CEN)', rol: 'recepcion', clinica: 'PUE-CEN' },
  { email: 'admin@demo.mx', nombre: 'Admin Demo', rol: 'admin', clinica: null },
] as const

type Config = { API_URL: string; SERVICE_ROLE_KEY: string; ANON_KEY: string; DB_URL: string }

function leerConfig(): Config {
  const env = process.env
  if (env.API_URL && env.SERVICE_ROLE_KEY && env.ANON_KEY && env.DB_URL) {
    return { API_URL: env.API_URL, SERVICE_ROLE_KEY: env.SERVICE_ROLE_KEY, ANON_KEY: env.ANON_KEY, DB_URL: env.DB_URL }
  }
  const raiz = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
  // stdin cerrado: algunos comandos de la CLI esperan datos si stdin no es una terminal
  const salida = execSync('npx supabase status -o json', { cwd: raiz, stdio: ['ignore', 'pipe', 'ignore'] }).toString()
  return JSON.parse(salida.slice(salida.indexOf('{')))
}

function rolEnJwt(token: string): string | undefined {
  const payload = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString())
  return payload.app_metadata?.rol
}

async function main() {
  const cfg = leerConfig()
  const admin = createClient(cfg.API_URL, cfg.SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } })
  const sql = postgres(cfg.DB_URL, { max: 1, onnotice: () => {} })

  try {
    const { data: lista, error: errLista } = await admin.auth.admin.listUsers({ perPage: 1000 })
    if (errLista) throw errLista

    for (const p of PERSONAL) {
      const existente = lista.users.find((u) => u.email === p.email)
      let id: string
      if (existente) {
        const { error } = await admin.auth.admin.updateUserById(existente.id, { password: CONTRASENA, email_confirm: true })
        if (error) throw error
        id = existente.id
      } else {
        const { data, error } = await admin.auth.admin.createUser({ email: p.email, password: CONTRASENA, email_confirm: true })
        if (error) throw error
        id = data.user.id
      }

      await sql`
        insert into core.staff (id, nombre, email, rol, clinica_id)
        values (${id}, ${p.nombre}, ${p.email}, ${p.rol},
                (select id from core.clinicas where clave = ${p.clinica}))
        on conflict (id) do update
          set nombre = excluded.nombre, email = excluded.email, rol = excluded.rol,
              clinica_id = excluded.clinica_id, activo = true, eliminado_en = null`
    }

    // Comprobación: cada usuario inicia sesión y su JWT trae el rol
    console.log('\nPersonal de prueba (contraseña: %s)\n', process.env.CONTRASENA ? 'la de CONTRASENA' : CONTRASENA)
    for (const p of PERSONAL) {
      const cliente = createClient(cfg.API_URL, cfg.ANON_KEY, { auth: { persistSession: false } })
      const { data, error } = await cliente.auth.signInWithPassword({ email: p.email, password: CONTRASENA })
      if (error) throw new Error(`${p.email}: ${error.message}`)
      const rol = rolEnJwt(data.session.access_token)
      const ok = rol === p.rol ? 'ok' : `ERROR: el JWT trae rol=${rol}`
      console.log(`  ${p.email.padEnd(18)} ${p.rol.padEnd(11)} ${(p.clinica ?? '—').padEnd(8)} ${ok}`)
    }
    console.log('')
  } finally {
    await sql.end()
  }
}

main().catch((e) => {
  console.error('No se pudo crear el personal de prueba:', e.message ?? e)
  process.exit(1)
})
