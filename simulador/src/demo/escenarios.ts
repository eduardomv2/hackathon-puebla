// Escenarios para el jurado. Cada paso: narración breve (qué pasa y en qué canal), la acción
// sobre el panel como lo haría una persona, y una pausa de 1.5 s. No dependen de internet:
// sin LLM, el resumen del asesor sale por plantilla.
import { adelantarCita, forzarRecordatorio, type Cliente } from '../api'
import {
  clic, clicUltimo, contar, enRenglon, escribir, esperar, esperarNuevo, esperarTexto, fecha, marcar, pausa, resaltar,
  seleccionar, texto, type IdPanel,
} from './dom'

export interface ContextoDemo {
  narrar: (panel: IdPanel | null, texto: string) => void
  /** Cambia el teléfono de prueba de los paneles y espera a que lo tomen */
  usarTelefono: (telefono: string) => Promise<void>
  /** Cliente para las funciones del esquema simulador */
  sim: Cliente
}
export interface Escenario { id: number; titulo: string; telefono: string; correr: (c: ContextoDemo) => Promise<void> }

const PAUSA = 1500

async function paso(c: ContextoDemo, panel: IdPanel | null, narracion: string, accion: () => Promise<unknown> = async () => {}) {
  c.narrar(panel, narracion)
  resaltar(panel)
  await accion()
  await pausa(PAUSA)
}

// ---------------------------------------------------------------------
// Bloques reutilizables
// ---------------------------------------------------------------------
async function registrarseEnWeb(nombre: string, paterno: string, materno = '') {
  await clic('paciente', 'Otra persona')
  await esperarTexto('paciente', /regístrate para agendar/i)
  await escribir('paciente', 'Nombre(s)', nombre)
  await escribir('paciente', 'Apellido paterno', paterno)
  if (materno) await escribir('paciente', 'Apellido materno', materno)
  await clic('paciente', /^Enviar código a/)
  await escribir('paciente', 'Código', '123456')
  await clic('paciente', 'Verificar')
  await esperarTexto('paciente', 'Empezar otro')
}

async function empezarTramiteEnWeb(estudio: string, para = 'Para mí') {
  await clic('paciente', 'Empezar otro')
  await marcar('paciente', estudio)
  await marcar('paciente', para)
  await clic('paciente', 'Iniciar trámite')
}

/** Manda un WhatsApp desde el teléfono simulado y espera una respuesta NUEVA del bot */
async function whatsapp(mensaje: string, respuesta: RegExp) {
  const antes = contar('telefono', respuesta)
  await escribir('telefono', 'Escribe un mensaje', mensaje)
  await clic('telefono', 'Enviar')
  await esperarNuevo('telefono', respuesta, antes)
}

const ultimoDelBot = () => [...document.querySelectorAll<HTMLElement>('[data-panel="telefono"] .burbuja.bot')].at(-1)?.innerText ?? ''
const numeroDe = (opcion: RegExp) => ultimoDelBot().match(new RegExp(`(\\d+)\\) ${opcion.source}`))?.[1] ?? '1'
const folioEn = (p: IdPanel, junto?: RegExp) =>
  (junto ? texto(p).match(new RegExp(`${junto.source}[^\\n]*?(SD-[A-Z0-9]{4})`)) : texto(p).match(/(SD-[A-Z0-9]{4})/))?.[1] ?? ''

/** El personal de la demo cambia de usuario (asesor ↔ recepción) */
async function entrarComo(email: string) {
  if (texto('personal').includes(email) && texto('personal').includes('Salir')) return
  if (texto('personal').includes('Salir')) await clic('personal', 'Salir')
  await escribir('personal', 'Correo', email)
  await escribir('personal', 'Contraseña', 'demo1234')
  await clic('personal', 'Iniciar sesión')
  await esperarTexto('personal', email)
}

async function atenderLlamadaConOtp(telefono: string) {
  await entrarComo('asesor@demo.mx')
  await escribir('personal', 'Teléfono', telefono)
  await clic('personal', /^Atender$/)
  await esperarTexto('personal', 'Enviar OTP')
}

async function validarOtpDictado() {
  const re = /código de verificación es (\d{6})/g
  const antes = contar('telefono', re)
  await clic('personal', 'Enviar OTP')
  await esperarNuevo('telefono', re, antes)
  const codigo = [...texto('telefono').matchAll(re)].at(-1)![1]
  await escribir('personal', 'Código que dicta', codigo)
  await clic('personal', 'Validar')
  await esperar(() => !texto('personal').includes('Enviar OTP'), 'sesión verificada en la llamada')
}

async function registrarLlegada(paciente: string, documento: string) {
  await entrarComo('recepcion@demo.mx')
  await clic('personal', 'Llegadas de hoy')
  await clic('personal', 'Actualizar')
  await clic('personal', 'Registrar llegada', enRenglon('.cita-agenda', paciente))
  await seleccionar('personal', documento)
  await marcar('personal', /^Sí$/)
}

const abrirJourney = (telefono: string) => window.dispatchEvent(new CustomEvent('sd:abrir-journey', { detail: telefono }))

// ---------------------------------------------------------------------
// 1. Recorrido de Ana
// ---------------------------------------------------------------------
const recorridoDeAna: Escenario = {
  id: 1, titulo: 'Recorrido de Ana', telefono: '528661234567',
  async correr(c) {
    await c.usarTelefono(this.telefono)
    await paso(c, 'paciente', '🌐 Web · Ana se registra: nombre, celular y código OTP; acepta avisos por WhatsApp.',
      () => registrarseEnWeb('Ana', 'López', 'García'))
    await paso(c, 'paciente', '🌐 Web · Elige el estudio (Ultrasonido obstétrico) y para quién: para ella.',
      () => empezarTramiteEnWeb('Ultrasonido obstétrico'))
    await paso(c, 'paciente', '🌐 Web · Elige la clínica Puebla (centro)… y cierra la página sin elegir hora.', async () => {
      await clic('paciente', /^Puebla ·/)
      await esperarTexto('paciente', /Horarios en/)
      abrirJourney(this.telefono)
    })
    const folio = folioEn('paciente')
    await paso(c, 'telefono', '💬 WhatsApp · Horas después escribe «hola»: sin códigos, el bot ya sabe lo que tiene pendiente.',
      () => whatsapp('hola', /Tienes pendiente:/))
    await paso(c, 'telefono', '💬 WhatsApp · Continúa ese trámite y el bot le pregunta el día.',
      () => whatsapp('1', /¿Qué día te gustaría\?/))
    await paso(c, 'telefono', '💬 WhatsApp · Pide «mañana» y recibe el menú de horas libres.',
      () => whatsapp('mañana', /Horarios del /))
    await paso(c, 'telefono', '💬 WhatsApp · Elige la primera hora: la cita queda apartada y le llega el link de pago.',
      () => whatsapp('1', /Paga aquí/))
    await paso(c, 'personal', '📞 Call center · Ana llama. La asesora la busca por su número…',
      () => atenderLlamadaConOtp(this.telefono))
    await paso(c, 'personal', '📞 Call center · …le envía un código por WhatsApp y Ana se lo dicta: identidad verificada.', validarOtpDictado)
    await paso(c, 'personal', '📞 Call center · Ve el resumen y la línea de tiempo de todos los canales y toma el trámite (queda bloqueado para los demás).',
      () => clic('personal', 'Tomar', enRenglon('.tarjeta-tramite', folio)))
    await paso(c, 'personal', '📞 Call center · Revisa el pago pendiente con Ana y cuelga: el trámite se libera.', async () => {
      await esperarTexto('personal', /Cita apartada/i)
      await pausa(PAUSA)
      await clic('personal', 'Colgar')
    })
    await paso(c, 'telefono', '💳 Pago · Ana paga con el link que recibió (proveedor de pagos simulado).', async () => {
      await clicUltimo('telefono', 'Pagar')
      await esperarTexto('telefono', /quedó confirmada/, 25000)
    })
    await paso(c, 'paciente', '📱 App · Abre la app: su cita aparece confirmada.', async () => {
      await clic('paciente', /^app$/)
      await esperarTexto('paciente', /confirmada/)
    })
    await paso(c, 'supervision', '⏩ (Demo) Adelantamos la cita a este momento para mostrar la llegada.',
      () => adelantarCita(c.sim, folio))
    await paso(c, 'personal', '🏥 Clínica · Ana llega. Recepción verifica su INE y pregunta por la preparación (vejiga llena).',
      () => registrarLlegada('Ana L.', 'ine'))
    await paso(c, 'personal', '🏥 Clínica · Turno asignado: pasa directo a Ultrasonido porque ya pagó.', async () => {
      await clic('personal', 'Confirmar llegada')
      await esperarTexto('personal', /U-\d{3}/)
    })
    c.narrar(null, '✅ Fin: web → WhatsApp → llamada → pago → app → clínica, el mismo trámite sin repetir datos.')
  },
}

// ---------------------------------------------------------------------
// 2. Mamá agenda para su hijo
// ---------------------------------------------------------------------
const mamaParaSuHijo: Escenario = {
  id: 2, titulo: 'Mamá agenda para su hijo', telefono: '528661234568',
  async correr(c) {
    await c.usarTelefono(this.telefono)
    await paso(c, 'paciente', '🌐 Web · María se registra con su celular.', () => registrarseEnWeb('María', 'López', 'Ruiz'))
    await paso(c, 'paciente', '🌐 Web · Agenda un Ultrasonido abdominal para su hijo Luis: lo agrega como familiar.', async () => {
      await clic('paciente', 'Empezar otro')
      await marcar('paciente', 'Ultrasonido abdominal')
      await clic('paciente', 'Agregar familiar')
      await escribir('paciente', 'Nombre', 'Luis')
      await escribir('paciente', 'Apellido paterno', 'López')
      await fecha('paciente', '2004-05-12')
      await clic('paciente', 'Guardar familiar')
      await esperarTexto('paciente', /Luis/)
      await clic('paciente', 'Iniciar trámite')
      abrirJourney(this.telefono)
    })
    await paso(c, 'paciente', '🌐 Web · Clínica Puebla (centro) y hora: la cita de Luis queda apartada.', async () => {
      await clic('paciente', /^Puebla ·/)
      await clic('paciente', /^\d\d:\d\d$/)
      await esperarTexto('paciente', /Cita apartada/i)
    })
    await paso(c, 'paciente', '🌐 Web · Y empieza otro para ella: Biometría hemática. Tiene dos trámites abiertos, cada uno con su etiqueta.',
      () => empezarTramiteEnWeb('Biometría hemática'))
    await paso(c, 'telefono', '💬 WhatsApp · Escribe «hola» y ve los dos: «… · para Luis» y «… · para ti».',
      () => whatsapp('hola', /Tienes pendiente:/))
    const n = numeroDe(/Ultrasonido abdominal · para Luis/)
    const folio = folioEn('telefono', /para Luis/)
    await paso(c, 'telefono', '💬 WhatsApp · Elige el de Luis y el bot le manda el link de pago.', () => whatsapp(n, /Paga aquí/))
    await paso(c, 'telefono', '💳 Pago · Paga la cita de Luis.', async () => {
      await clicUltimo('telefono', 'Pagar')
      await esperarTexto('telefono', /quedó confirmada/, 25000)
    })
    await paso(c, 'supervision', '⏩ (Demo) Adelantamos la cita de Luis a este momento.', () => adelantarCita(c.sim, folio))
    await paso(c, 'personal', '🏥 Clínica · Llegan a recepción: se verifica la INE de Luis, que es quien recibe el estudio.',
      () => registrarLlegada('Luis L.', 'ine'))
    await paso(c, 'personal', '🏥 Clínica · Turno para Luis: pasa a Ultrasonido.', async () => {
      await clic('personal', 'Confirmar llegada')
      await esperarTexto('personal', /U-\d{3}/)
    })
    c.narrar(null, '✅ Fin: un titular, dos personas, dos trámites con su etiqueta y la identificación de quien se atiende.')
  },
}

// ---------------------------------------------------------------------
// 3. El asesor manda
// ---------------------------------------------------------------------
const elAsesorManda: Escenario = {
  id: 3, titulo: 'El asesor manda', telefono: '528661234569',
  async correr(c) {
    await c.usarTelefono(this.telefono)
    await paso(c, 'paciente', '🌐 Web · Ana se registra y empieza una Mastografía en Puebla (centro).', async () => {
      await registrarseEnWeb('Ana', 'Torres')
      await empezarTramiteEnWeb('Mastografía')
      await clic('paciente', /^Puebla ·/)
      abrirJourney(this.telefono)
    })
    await paso(c, 'personal', '📞 Call center · Ana llama; la asesora la verifica con OTP…', async () => {
      await atenderLlamadaConOtp(this.telefono)
      await validarOtpDictado()
    })
    await paso(c, 'personal', '📞 Call center · …y toma la Mastografía: ahora solo ella puede cambiarla.',
      () => clic('personal', 'Tomar', enRenglon('.tarjeta-tramite', 'Mastografía')))
    await paso(c, 'telefono', '💬 WhatsApp · Durante la llamada, Ana escribe por WhatsApp: el bot le dice que un asesor la atiende.',
      () => whatsapp('hola', /Tienes pendiente:/))
    await paso(c, 'telefono', '💬 WhatsApp · Intenta seguir con la Mastografía: está bloqueada (PT423) y recibe la plantilla.',
      () => whatsapp('1', /Un asesor está atendiendo/))
    await paso(c, 'personal', '📞 Call center · La asesora ve en vivo lo que Ana escribe por WhatsApp.')
    await paso(c, 'telefono', '💬 WhatsApp · Pero sí puede avanzar OTRO trámite: empieza una Biometría.', async () => {
      await whatsapp('menu', /Tienes pendiente:/)
      await whatsapp(numeroDe(/Empezar otro/), /qué estudio necesitas/)
      await whatsapp('biometria', /para quién es/)
      await whatsapp('1', /En qué ciudad o municipio/)
    })
    await paso(c, 'personal', '📞 Call center · La asesora cuelga: la Mastografía se libera y WhatsApp le avisa a Ana.', async () => {
      await clic('personal', 'Colgar')
      await esperarTexto('telefono', /El asesor terminó de atender/, 25000)
    })
    c.narrar(null, '✅ Fin: el personal manda sobre el trámite que atiende; lo demás sigue funcionando en cualquier canal.')
  },
}

// ---------------------------------------------------------------------
// 4. Duplicado y recordatorio
// ---------------------------------------------------------------------
const duplicadoYRecordatorio: Escenario = {
  id: 4, titulo: 'Duplicado y recordatorio', telefono: '528661234570',
  async correr(c) {
    await c.usarTelefono(this.telefono)
    await paso(c, 'paciente', '🌐 Web · Laura se registra (acepta avisos por WhatsApp) y empieza una Biometría hemática.', async () => {
      await registrarseEnWeb('Laura', 'Méndez')
      await empezarTramiteEnWeb('Biometría hemática')
      await esperarTexto('paciente', /En qué clínica/i)
      abrirJourney(this.telefono)
    })
    const folio = folioEn('paciente')
    await paso(c, 'paciente', '🌐 Web · Intenta empezar otra vez la misma Biometría para ella: la base lo detecta (PT409) y continúa la que ya tenía.', async () => {
      await empezarTramiteEnWeb('Biometría hemática')
      await esperarTexto('paciente', /Ya hay un trámite abierto/)
    })
    await paso(c, 'telefono', '💬 WhatsApp · Por WhatsApp pasa lo mismo…', async () => {
      await whatsapp('hola', /Tienes pendiente:/)
      await whatsapp(numeroDe(/Empezar otro/), /qué estudio necesitas/)
      await whatsapp('biometria', /para quién es/)
    })
    await paso(c, 'telefono', '💬 WhatsApp · …el bot la lleva al trámite que ya tenía («continuar ese»).',
      () => whatsapp('1', /Ya tienes .* abierto/))
    await paso(c, 'supervision', '⏩ (Demo) Laura deja el trámite sin tocar: lo marcamos inactivo 3 h y corre el recordatorio.',
      () => forzarRecordatorio(c.sim, folio))
    await paso(c, 'telefono', '💬 WhatsApp · Le llega el recordatorio con la plantilla aprobada «recordatorio_tramite_pendiente».',
      () => esperarTexto('telefono', /pendiente tu trámite/, 30000))
    c.narrar(null, '✅ Fin: sin duplicados entre canales y con recordatorios automáticos.')
  },
}

export const ESCENARIOS: Escenario[] = [recorridoDeAna, mamaParaSuHijo, elAsesorManda, duplicadoYRecordatorio]
