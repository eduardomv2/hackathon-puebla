/**
 * Prueba rápida de src/api.ts contra el Supabase local (sin navegador ni React).
 *
 *   npm run probar-api
 *
 * La web verifica su celular (OTP de prueba 123456), agenda y paga, mientras el admin escucha
 * journey:global y la paciente su propio canal. Luego un asesor toma un trámite y la web recibe
 * PT423. Requiere `npx supabase start`, `npx supabase functions serve` y `npm run usuarios`.
 */
import {
  asegurarSesionAnonima, avanzarTramite, catalogoEstudios, clinicasParaEstudio, confirmarOtpTelefono, crearCliente, enviarOtp, ErrorApi,
  generarPago, guardarDatosPaciente, horariosDisponibles, iniciarContacto, iniciarSesionPaciente, iniciarSesionPersonal, iniciarTramite,
  leerBandeja, metricas, nuevaSesionAnonima, pagarSimulado, pedirOtpTelefono, referenciaDeLink, reservarCita,
  retomarTramite, suscribirJourneyGlobal, suscribirPaciente, validarOtp, type EventoEnVivo, type EventoPaciente,
} from '../src/api.ts'

const URL = process.env.VITE_SUPABASE_URL ?? 'http://127.0.0.1:54321'
const CLAVE = process.env.VITE_SUPABASE_PUBLISHABLE_KEY ?? 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH'
const TEL = '528661234569'   // número de prueba de config.toml (OTP 123456)
const esperar = (ms: number) => new Promise((r) => setTimeout(r, ms))
const ok = (cond: boolean, texto: string) => { console.log(`${cond ? '  ok ' : '  FALLA'} ${texto}`); if (!cond) process.exitCode = 1 }

async function main() {
  // Admin escuchando todo
  const admin = crearCliente(URL, CLAVE, 'admin')
  await iniciarSesionPersonal(admin, 'admin@demo.mx', 'demo1234')
  const global: EventoEnVivo[] = []
  let estado = ''
  const dejarGlobal = await suscribirJourneyGlobal(admin, (e) => global.push(e), (s) => { estado = s })
  for (let i = 0; i < 20 && estado !== 'SUBSCRIBED'; i++) await esperar(250)
  ok(estado === 'SUBSCRIBED', 'admin suscrito a journey:global')

  // Web: anónima → OTP del celular → agenda
  const web = crearCliente(URL, CLAVE, 'web')
  await nuevaSesionAnonima(web)
  let ctx = await iniciarSesionPaciente(web, 'web')
  try { await iniciarTramite(web, ctx.sesion.interaccion_id, (await catalogoEstudios(web))[0].id); ok(false, 'sin OTP no debería iniciar') }
  catch (e) { ok(e instanceof ErrorApi && e.code === '42501', 'sin OTP la web no puede iniciar un trámite') }
  const modo = await pedirOtpTelefono(web, TEL)          // 'iniciar_sesion' si el número ya tiene cuenta
  await confirmarOtpTelefono(web, TEL, '123456', modo)
  ctx = await iniciarSesionPaciente(web, 'web')
  const int = ctx.sesion.interaccion_id
  ok(ctx.sesion.nivel_verificacion === 'verificada', 'con OTP la web queda verificada')
  // Registro: sin nombre no hay trámite (re-ejecutable: la segunda vez ya está registrada)
  if (ctx.sesion.requiere_registro?.length) {
    try { await iniciarTramite(web, int, (await catalogoEstudios(web))[0].id); ok(false, 'sin nombre no debería iniciar') }
    catch (e) { ok(e instanceof ErrorApi && e.message === 'faltan_datos_titular', `sin registro: faltan_datos_titular (${ctx.sesion.requiere_registro})`) }
    ctx = await guardarDatosPaciente(web, int, { nombre: 'Ana', apellido_paterno: 'López', apellido_materno: 'García' })
  }
  ok(ctx.sesion.requiere_registro?.length === 0, `registro completo: ${ctx.paciente.nombre}`)

  const propios: EventoPaciente[] = []
  const dejarPaciente = await suscribirPaciente(web, ctx.paciente.id, (e) => propios.push(e))
  // El trámite nace con su estudio. Re-ejecutable: si el estudio ya está pedido para ella, se continúa
  // ese trámite (tramite_duplicado) o se prueba otro estudio (cita_duplicada: ya tiene cita futura)
  let t = undefined as Awaited<ReturnType<typeof iniciarTramite>> | undefined
  let estudio = undefined as Awaited<ReturnType<typeof catalogoEstudios>>[number] | undefined
  for (const e of await catalogoEstudios(web)) {
    try { t = await iniciarTramite(web, int, e.id); estudio = e; break }
    catch (err) {
      if (!(err instanceof ErrorApi) || err.code !== 'PT409') throw err
      if (err.message === 'tramite_duplicado') {
        console.log(`  …  ${err.aviso} (se continúa ese)`)
        t = await retomarTramite(web, int, err.detalle.tramite_id)
        estudio = e; break
      }
    }
  }
  if (!estudio || !t) throw new Error('La paciente ya tiene citas de todos los estudios: corre `npx supabase db reset`')
  ok(/^SD-[A-HJ-NP-Z2-9]{4}$/.test(t.folio), `trámite con folio ${t.folio}, nace en ${t.paso_actual}`)
  const [clinica] = await clinicasParaEstudio(web, estudio.id, 'Puebla')
  if (t.paso_actual !== 'seleccion_clinica') t = await avanzarTramite(web, int, t, 'seleccion_clinica')
  t = await avanzarTramite(web, int, t, 'seleccion_horario', { clinica_id: clinica.id })
  ok(t.etiqueta === `${estudio.nombre} · para ti`, `etiqueta "${t.etiqueta}"`)

  // Un asesor toma el trámite: la web ya no puede cambiarlo (PT423)
  const asesor = crearCliente(URL, CLAVE, 'asesor')
  await iniciarSesionPersonal(asesor, 'asesor@demo.mx', 'demo1234')
  const llamada = await iniciarContacto(asesor, 'call_center', TEL)
  const ci = llamada.sesion.interaccion_id
  await enviarOtp(asesor, ci)
  const telefono = crearCliente(URL, CLAVE, 'telefono')
  await asegurarSesionAnonima(telefono)   // su propio cupo de rate limit
  const bandeja = await leerBandeja(telefono, TEL)
  const otp = bandeja.filter((m) => m.tipo === 'otp').at(-1)!.contenido.match(/(\d{6})/)![1]
  await validarOtp(asesor, ci, otp)
  await retomarTramite(asesor, ci, t.id)
  const horarios = await horariosDisponibles(web, clinica.id, estudio.id)
  try { await reservarCita(web, int, t, horarios[0].fecha_hora); ok(false, 'la web no debería poder reservar') }
  catch (e) { ok(e instanceof ErrorApi && e.code === 'PT423', `asesor atendiendo → web: ${(e as ErrorApi).code} "${(e as ErrorApi).aviso}"`) }

  // El asesor reserva, la paciente paga
  const enLlamada = (await retomarTramite(asesor, ci, t.id))
  t = await reservarCita(asesor, ci, enLlamada, horarios[0].fecha_hora)
  const pago = await generarPago(asesor, ci, t)
  await pagarSimulado(web, referenciaDeLink(pago.link_pago))
  ctx = await iniciarSesionPaciente(web, 'app')
  ok(ctx.citas_proximas?.[0]?.estado === 'confirmada', 'en la app la cita aparece confirmada')

  await esperar(1500)
  const canales = new Set(propios.filter((e) => e.tipo === 'evento').map((e) => e.tipo === 'evento' ? e.evento.canal : ''))
  ok(canales.has('call_center'), `la paciente recibió en vivo eventos de ${[...canales].join(', ')}`)
  ok(global.length > 0, `el admin recibió ${global.length} eventos en vivo`)

  try { await metricas(asesor, '2026-01-01', '2026-12-31'); ok(false, 'el asesor no debería ver métricas') }
  catch (e) { ok(e instanceof ErrorApi && e.code === '42501', `asesor → métricas: ${(e as ErrorApi).code}`) }
  dejarPaciente(); dejarGlobal()
  process.exit()
}

main().catch((e) => { console.error(e instanceof ErrorApi ? `${e.code}: ${e.aviso}` : e); process.exit(1) })
