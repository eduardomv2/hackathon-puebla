// =====================================================================
// Agente guiado de WhatsApp (sin LLM)
//   1. iniciar_contacto (identifica por el número; sin códigos)
//   2. registrar_mensaje (entrante)
//   3. arma el contexto del diálogo desde la BASE: trámites pendientes, el
//      trámite con el que trabaja esta conversación, catálogo, horarios
//   4. interpretar(texto, contexto) → intención
//   5. la ejecuta con las funciones api y contesta el siguiente paso
//   6. registrar_mensaje (saliente) + envío al teléfono
//   Toda regla de negocio la decide la base; aquí solo hay conversación.
//   Los avisos de lo que pasa en OTROS canales los manda avisos-whatsapp.
// =====================================================================
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { clienteServicio, ErrorApi, rpc } from '../_shared/supabase.ts'
import { enviarAlPaciente } from '../_shared/enviar.ts'
import {
  type ContextoDialogo, type Horario, type Intencion, interpretar, OPCION_AGREGAR, OPCION_NUEVO, type Opcion, type Paso,
} from './interpretar.ts'
import { diasEntre, fechaLarga, hoyEn, MAX_DIAS, mesDe, normalizar, resolverDiaMes, sumarDias } from './fechas.ts'

// Primeras líneas que permiten reconocer, en el siguiente mensaje, a qué pregunta responde
// la paciente (el agente no guarda estado propio: lo lee de la conversación, como haría un LLM).
const MARCA_PENDIENTES = 'Tienes pendiente:'
const MARCA_REGISTRO = '¿A nombre de quién registramos tu cuenta?'
const MARCA_DIA = '¿Qué día te gustaría?'
const MARCA_MENU = /^Horarios del \p{L}+ (\d{1,2}) de (\p{L}+) en /u
const MARCA_CONFIRMAR = /^¿Te aparto el \p{L}+ (\d{1,2}) de (\p{L}+) a las (\d\d:\d\d)/u
const MENU_MAX = 10

/** "26 de noviembre" (de un mensaje del bot) → AAAA-MM-DD */
function fechaDeMensaje(dia: string, mes: string, hoy: string): string | undefined {
  const m = mesDe(normalizar(mes))
  return m ? resolverDiaMes(Number(dia), m, hoy) ?? undefined : undefined
}
const MARCA_NUEVO_ESTUDIO = 'Nuevo trámite: ¿qué estudio necesitas?'
const MARCA_NUEVO_PARA = /^Nuevo trámite de (.+?): ¿para quién es\?/

// deno-lint-ignore no-explicit-any
type Contexto = any

const pesos = (x: unknown) => `$${Number(x).toLocaleString('es-MX', { maximumFractionDigits: 0 })}`
const RELACION: Record<string, string> = {
  titular: 'tú', hijo: 'hijo', hija: 'hija', madre: 'mamá', padre: 'papá', conyuge: 'cónyuge', otro: 'familiar',
}
const EN_PASO: Record<string, string> = {
  seleccion_estudio: 'eligiendo estudio', seleccion_clinica: 'eligiendo clínica',
  seleccion_horario: 'eligiendo horario', pago: 'en pago',
}

function fechaCorta(iso: string, zona = 'America/Mexico_City'): string {
  return new Intl.DateTimeFormat('es-MX', {
    timeZone: zona, weekday: 'short', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false,
  }).format(new Date(iso))
}
/** El detalle (JSON) que la base adjunta a PT409 / PT423 */
function detalle(e: ErrorApi): Record<string, string> {
  try { return JSON.parse((e.cuerpo as { details?: string })?.details ?? '{}') } catch { return {} }
}

export type Resultado = { respuestas: string[] }

export async function atenderMensaje(telefono: string, texto: string): Promise<Resultado> {
  const c = new Conversacion(clienteServicio(telefono), telefono)
  try {
    await c.iniciar(texto)
  } catch (e) {
    // Más de 10 mensajes por minuto: se avisa (sin procesar el mensaje)
    if (e instanceof ErrorApi && e.code === 'PT429' && c.int) {
      c.decir('Recibí muchos mensajes seguidos. Espera un minuto y vuelve a escribir.')
      await c.enviar()
      return { respuestas: c.respuestas }
    }
    throw e
  }
  try {
    const dialogo = await c.dialogo()
    await c.ejecutar(interpretar(texto, dialogo), dialogo)
  } catch (e) {
    await c.manejarError(e)
  }
  await c.enviar()
  return { respuestas: c.respuestas }
}

class Conversacion {
  ctx: Contexto
  int = ''
  respuestas: string[] = []
  private links: string[] = []
  /** En este mensaje ya se respondió a la última pregunta del bot (aún sin registrar la nueva) */
  private tramiteElegido = false
  /** Estudio elegido para el trámite nuevo (paso nuevo_para) */
  private estudioNuevo: { id: string; nombre: string } | null = null

  constructor(private api: SupabaseClient, private telefono: string) {}

  decir(texto: string) { this.respuestas.push(texto) }

  async iniciar(texto: string) {
    this.ctx = await rpc(this.api, 'iniciar_contacto', {
      p_canal: 'whatsapp', p_telefono: this.telefono, p_agente: 'ia', p_nivel: 'canal',
    })
    this.int = this.ctx.sesion.interaccion_id
    await rpc(this.api, 'registrar_mensaje', {
      p_interaccion_id: this.int, p_direccion: 'entrante', p_autor: 'paciente', p_contenido: texto,
    })
  }

  async recargar() {
    this.ctx = await rpc(this.api, 'obtener_contexto', { p_interaccion_id: this.int })
  }

  get tramite() { return this.ctx.tramite_activo }
  /** ¿Falta el nombre del titular? (el celular ya está probado: escribe desde él) */
  get faltaNombre(): boolean {
    return (this.ctx.sesion?.requiere_registro ?? []).some((c: string) => c === 'nombre' || c === 'apellido_paterno')
  }
  get pendientes(): Contexto[] { return this.ctx.tramites_abiertos ?? [] }

  /** Último mensaje del bot (si en este mensaje aún no se respondió a él) */
  private ultimoBot(): string {
    if (this.tramiteElegido) return ''
    const mensajes: { autor: string; contenido: string }[] = this.ctx.mensajes_recientes ?? []
    return [...mensajes].reverse().find((m) => m.autor === 'agente_ia')?.contenido ?? ''
  }

  private paso(): Paso {
    const ultimo = this.ultimoBot()
    if (ultimo.startsWith(MARCA_PENDIENTES)) return 'elegir_tramite'
    if (ultimo.startsWith(MARCA_REGISTRO)) return 'registro'
    if (ultimo.startsWith(MARCA_NUEVO_ESTUDIO)) return 'nuevo_estudio'
    if (MARCA_NUEVO_PARA.test(ultimo)) return 'nuevo_para'
    const t = this.tramite
    if (!t) return this.pendientes.length ? 'elegir_tramite' : 'menu'
    if (t.en_atencion_de_otro) return 'en_atencion'
    switch (t.paso_actual) {
      case 'seleccion_estudio': return t.contexto?.beneficiario_id ? 'estudio' : 'beneficiario'
      case 'seleccion_clinica': return 'clinica'
      case 'seleccion_horario':
        if (MARCA_MENU.test(ultimo)) return 'horario_menu'
        if (MARCA_CONFIRMAR.test(ultimo)) return 'horario_confirmar'
        return 'horario_dia'
      case 'pago': return 'pago'
      default: return 'menu'
    }
  }

  /** Contexto del diálogo: el paso y las opciones que se le muestran, todo desde la base. */
  async dialogo(forzarPaso?: Paso): Promise<ContextoDialogo> {
    const paso = forzarPaso ?? this.paso()
    let opciones: Opcion[] = []
    let horarios: Horario[] = []
    let fecha: string | undefined
    let ver_mas: number | null = null
    const t = this.tramite
    const hoy = hoyEn()

    if (paso === 'elegir_tramite') {
      opciones = [
        ...this.pendientes.map((p) => ({
          id: p.id,
          etiqueta: `${p.etiqueta}, ${EN_PASO[p.paso_actual] ?? p.paso_actual} (${p.folio})${p.en_atencion_de_otro ? (p.atencion_canal === 'clinica' ? ' — te atienden en la clínica' : ' — lo atiende un asesor') : ''}`,
        })),
        { id: OPCION_NUEVO, etiqueta: 'Empezar otro' },
      ]
    } else if (paso === 'nuevo_para' || paso === 'beneficiario') {
      if (paso === 'nuevo_para' && !this.estudioNuevo) {
        const nombre = this.ultimoBot().match(MARCA_NUEVO_PARA)?.[1]
        const e = ((await rpc(this.api, 'catalogo_estudios')) as { id: string; nombre: string }[]).find((x) => x.nombre === nombre)
        if (e) this.estudioNuevo = { id: e.id, nombre: e.nombre }
      }
      const familia: { id: string; nombre: string; relacion: string }[] =
        await rpc(this.api, 'mis_beneficiarios', { p_interaccion_id: this.int })
      opciones = [
        { id: this.ctx.paciente.id, etiqueta: 'Para mí' },
        ...familia.map((b) => ({ id: b.id, etiqueta: `${b.nombre} (${RELACION[b.relacion] ?? b.relacion})` })),
        { id: OPCION_AGREGAR, etiqueta: 'Agregar a un familiar' },
      ]
    } else if (paso === 'estudio' || paso === 'nuevo_estudio') {
      const estudios: { id: string; nombre: string; precio_base: number }[] = await rpc(this.api, 'catalogo_estudios')
      opciones = estudios.map((e) => ({ id: e.id, etiqueta: `${e.nombre} — desde ${pesos(e.precio_base)}` }))
    } else if (paso === 'clinica') {
      const clinicas: { id: string; nombre: string; ciudad: string; precio: number }[] =
        await rpc(this.api, 'clinicas_para_estudio', { p_estudio_id: t.contexto.estudio_id })
      opciones = clinicas.map((c) => ({ id: c.id, etiqueta: `${c.nombre} (${c.ciudad}) — ${pesos(c.precio)}` }))
    } else if (paso === 'horario_menu') {
      // El menú lo reconstruye del último mensaje: "Horarios del jueves 26 de noviembre…" + "1) 07:00"…
      const ultimo = this.ultimoBot()
      const m = ultimo.match(MARCA_MENU)
      fecha = m ? fechaDeMensaje(m[1], m[2], hoy) : undefined
      const dia = fecha ? await this.horariosDe(fecha) : []
      for (const [, , hora] of ultimo.matchAll(/^(\d+)\) (\d\d:\d\d)$/gm)) {
        const h = dia.find((x) => x.hora === hora)
        // Si se ocupó mientras tanto, se deja un hueco (reservar responderá horario_sin_cupo)
        horarios.push(h ?? { fecha: fecha!, hora, fecha_hora: '' })
      }
      ver_mas = Number(ultimo.match(/^(\d+)\) Ver más$/m)?.[1]) || null
    } else if (paso === 'horario_confirmar') {
      const m = this.ultimoBot().match(MARCA_CONFIRMAR)
      fecha = m ? fechaDeMensaje(m[1], m[2], hoy) : undefined
      const h = fecha ? (await this.horariosDe(fecha)).find((x) => x.hora === m![3]) : undefined
      if (h) horarios = [h]
    }
        return { paso, opciones, horarios, hoy, fecha, ver_mas }
  }

  /** Mensaje con la pregunta del paso actual. */
  async preguntar(dialogo?: ContextoDialogo) {
    const d = dialogo ?? (await this.dialogo())
    const lista = (ops: Opcion[]) => ops.map((o, i) => `${i + 1}) ${o.etiqueta}`).join('\n')
    const t = this.tramite
    const cual = t ? ` (${t.etiqueta} · ${t.folio})` : ''
    switch (d.paso) {
      case 'menu':
        return this.decir('¿Qué quieres hacer?\n1) Agendar un estudio\n2) Ver mis citas')
      case 'elegir_tramite':
        return this.decir(`${MARCA_PENDIENTES}\n${lista(d.opciones)}\nResponde con el número.`)
      case 'en_atencion':
        return this.decir(`${await rpc(this.api, 'texto_asesor_atendiendo', { p_interaccion_id: this.int, p_tramite_id: t.id })}\n` +
          'Escribe "menu" para ver tus otros trámites.')
      case 'registro':
        return this.decir(`${MARCA_REGISTRO}\nAntes de empezar, escribe tu nombre y apellidos (por ejemplo: Ana López García).`)
      case 'nuevo_estudio':
        return this.decir(`${MARCA_NUEVO_ESTUDIO}\n${lista(d.opciones)}\nResponde con el número o escribe el nombre.`)
      case 'nuevo_para':
        return this.decir(`Nuevo trámite de ${this.estudioNuevo?.nombre}: ¿para quién es?\n${lista(d.opciones)}`)
      case 'beneficiario':
        return this.decir(`¿Para quién es el estudio?\n${lista(d.opciones)}`)
      case 'estudio':
        return this.decir(`¿Qué estudio necesitas${t.beneficiario && t.beneficiario.relacion !== 'titular' ? ` para ${t.beneficiario.nombre}` : ''}? ` +
          `Responde con el número o escribe el nombre:\n${lista(d.opciones)}`)
      case 'clinica':
        return this.decir(`${t.estudio?.nombre}${cual}. Preparación: ${t.estudio?.preparacion ?? 'sin indicaciones'}\n\n` +
          `¿En qué clínica?\n${lista(d.opciones)}`)
      case 'horario_dia':
        return this.decir(`${MARCA_DIA} ${t.estudio?.nombre} en ${this.clinicaCorta}${cual}.\n` +
          'Escribe hoy, mañana, un día (jueves) o una fecha (26/11). También puedes poner la hora: "jueves 7am".')
      case 'horario_menu':
        return d.fecha ? this.mostrarDia(d.fecha) : this.preguntar(await this.dialogo('horario_dia'))
      case 'horario_confirmar':
        return d.fecha ? this.mostrarDia(d.fecha, d.horarios[0]?.hora ?? null) : this.preguntar(await this.dialogo('horario_dia'))
      case 'pago':
        return this.mandarLinkDePago()
    }
  }

  async mandarLinkDePago() {
    const t = this.tramite
    const pago = await rpc(this.api, 'generar_pago', {
      p_interaccion_id: this.int, p_tramite_id: t.id, p_version: t.version,
    })
    this.links.push(pago.link_pago)
    const cuando = t.contexto?.fecha_hora ? fechaCorta(t.contexto.fecha_hora) : ''
    this.decir(`Tu cita: ${t.etiqueta}, ${t.clinica?.nombre}, ${cuando} (folio ${t.folio}).\n` +
      `Total: ${pesos(pago.monto)}. Paga aquí para confirmarla: ${pago.link_pago}\n(El link vence ${fechaCorta(pago.expira_en)}.)`)
  }

  private async avanzar(paso: string, datos: Record<string, string>) {
    await rpc(this.api, 'avanzar_tramite', {
      p_interaccion_id: this.int, p_tramite_id: this.tramite.id, p_version: this.tramite.version, p_paso: paso, p_datos: datos,
    })
    await this.recargar()
  }

  private async retomar(tramiteId: string) {
    await rpc(this.api, 'retomar_tramite', { p_interaccion_id: this.int, p_tramite_id: tramiteId })
    this.tramiteElegido = true
    await this.recargar()
  }

  async ejecutar(i: Intencion, d: ContextoDialogo) {
    switch (i.tipo) {
      case 'menu': {
        const nombre = this.ctx.paciente?.nombre
        this.decir(`Hola${nombre ? `, ${nombre}` : ''} 👋 Soy el asistente de Salud Digna.`)
        // Con trámites pendientes siempre se ofrece elegir (aunque ya estuviera en uno) o empezar otro
        this.tramiteElegido = false
        return this.preguntar(await this.dialogo(this.pendientes.length ? 'elegir_tramite' : 'menu'))
      }
      case 'ayuda':
        this.decir('Puedo agendar estudios para ti o tu familia y mostrarte tus citas. Escribe "menu" para ver tus trámites ' +
          'pendientes o "mis citas" para ver tus citas.')
        return this.preguntar(d)
      case 'ver_citas': {
        const citas: Contexto[] = this.ctx.citas_proximas ?? []
        this.decir(citas.length
          ? 'Tus próximas citas:\n' + citas.map((c) => `• ${fechaCorta(c.fecha_hora)} — ${c.estudio} en ${c.clinica}` +
              `${c.beneficiario?.relacion !== 'titular' ? ` (para ${c.beneficiario?.nombre})` : ''} — ${c.estado}`).join('\n')
          : 'No tienes citas próximas.')
        return this.preguntar(d)
      }
      case 'nuevo_tramite':
        // Primero el registro (si falta el nombre), luego el estudio y para quién: el trámite nace completo
        this.tramiteElegido = true
        return this.preguntar(await this.dialogo(this.faltaNombre ? 'registro' : 'nuevo_estudio'))
      case 'pedir_nombre':
        return this.decir(`${MARCA_REGISTRO}\n${i.error} Por ejemplo: Ana López García.`)
      case 'registrar_nombre':
        await rpc(this.api, 'guardar_datos_paciente', {
          p_interaccion_id: this.int, p_nombre: i.nombre, p_apellido_paterno: i.apellido_paterno,
          p_apellido_materno: i.apellido_materno,
        })
        await this.recargar()
        this.tramiteElegido = true
        this.decir(`Gracias, ${i.nombre}. Registré tu cuenta a nombre de ${[i.nombre, i.apellido_paterno, i.apellido_materno].filter(Boolean).join(' ')}.`)
        return this.preguntar(await this.dialogo(this.faltaNombre ? 'registro' : 'nuevo_estudio'))
      case 'elegir_tramite':
        await this.retomar(i.tramite_id)
        if (!this.tramite.en_atencion_de_otro) this.decir(`Seguimos con ${this.tramite.etiqueta} (folio ${this.tramite.folio}).`)
        return this.preguntar()
      case 'elegir_beneficiario':
        if (d.paso === 'nuevo_para') return this.crearTramite(i.beneficiario_id)
        await this.avanzar('seleccion_estudio', { beneficiario_id: i.beneficiario_id })
        return this.preguntar()
      case 'pedir_datos_familiar':
        // En un trámite nuevo, la pregunta repite su primera línea para seguir en el mismo paso
        return this.decir(`${d.paso === 'nuevo_para' ? `Nuevo trámite de ${this.estudioNuevo?.nombre}: ¿para quién es?\n` : ''}` +
          `${i.error ? `${i.error}\n` : ''}Escríbeme los datos de tu familiar así:\n` +
          'familiar: Luis López Ruiz, 01/07/2016, hijo\n(relación: hijo, hija, madre, padre, cónyuge u otro)')
      case 'agregar_familiar': {
        const r = await rpc(this.api, 'agregar_beneficiario', {
          p_interaccion_id: this.int, p_nombre: i.datos.nombre, p_apellido_paterno: i.datos.apellido_paterno,
          p_apellido_materno: i.datos.apellido_materno, p_fecha_nacimiento: i.datos.fecha_nacimiento,
          p_sexo: null, p_relacion: i.datos.relacion,
        })
        this.decir(r.reutilizado ? `${i.datos.nombre} ya estaba registrado; lo uso.` : `Registré a ${i.datos.nombre}.`)
        if (d.paso === 'nuevo_para') return this.crearTramite(r.beneficiario_id)
        await this.avanzar('seleccion_estudio', { beneficiario_id: r.beneficiario_id })
        return this.preguntar()
      }
      case 'elegir_estudio':
        if (d.paso === 'nuevo_estudio') return this.pedirParaQuien(i.estudio_id, d)
        await this.avanzar('seleccion_clinica', { estudio_id: i.estudio_id })
        return this.preguntar()
      case 'buscar_estudio': {
        const encontrados: { id: string }[] = await rpc(this.api, 'catalogo_estudios', { p_busqueda: i.texto })
        if (encontrados.length === 1) {
          if (d.paso === 'nuevo_estudio') return this.pedirParaQuien(encontrados[0].id, d)
          await this.avanzar('seleccion_clinica', { estudio_id: encontrados[0].id })
          return this.preguntar()
        }
        if (!encontrados.length) { this.decir(`No encontré "${i.texto}".`); return this.preguntar(d) }
        const ids = new Set(encontrados.map((e) => e.id))
        return this.decir('Encontré estos estudios:\n' + d.opciones.map((o, k) => ids.has(o.id) ? `${k + 1}) ${o.etiqueta}` : null)
          .filter(Boolean).join('\n') + '\nResponde con el número.')
      }
      case 'elegir_clinica':
        await this.avanzar('seleccion_horario', { clinica_id: i.clinica_id })
        return this.preguntar()
      case 'elegir_dia':
        this.tramiteElegido = true
        return this.mostrarDia(i.fecha, i.hora)
      case 'fecha_invalida': {
        const hoy = hoyEn()
        this.decir(i.motivo === 'pasada' ? `El ${fechaLarga(i.fecha!)} ya pasó.`
          : i.motivo === 'lejana' ? `Solo puedo agendar hasta ${MAX_DIAS} días adelante (hasta el ${fechaLarga(sumarDias(hoy, MAX_DIAS))}).`
          : 'No entendí qué día.')
        this.tramiteElegido = true
        return this.preguntar(await this.dialogo('horario_dia'))
      }
      case 'ver_mas': {
        const dia = await this.horariosDe(d.fecha!)
        const ultima = d.horarios.at(-1)?.hora ?? ''
        return this.menu(d.fecha!, dia, dia.filter((h) => h.hora <= ultima).length)
      }
      case 'elegir_horario':
        if (!i.fecha_hora) { this.decir('Ese horario se acaba de ocupar.'); return this.mostrarDia(d.fecha!) }
        await rpc(this.api, 'reservar_cita', {
          p_interaccion_id: this.int, p_tramite_id: this.tramite.id, p_version: this.tramite.version, p_fecha_hora: i.fecha_hora,
        })
        await this.recargar()
        this.decir('¡Apartado! 🎉')
        return this.mandarLinkDePago()
      case 'pagar':
        return this.mandarLinkDePago()
      case 'no_entendido':
        if (d.paso !== 'en_atencion') this.decir('No te entendí 🤔')
        return this.preguntar(d)
    }
  }

  get clinicaCorta(): string { return (this.tramite?.clinica?.nombre ?? 'la clínica').replace(/^Clínica\s+/, '') }

  /** Horas libres de un día en la clínica y estudio del trámite (zona de la clínica) */
  private async horariosDe(fecha: string, dias = 1): Promise<Horario[]> {
    const t = this.tramite
    const todos: Horario[] = await rpc(this.api, 'horarios_disponibles', {
      p_clinica_id: t.contexto.clinica_id, p_estudio_id: t.contexto.estudio_id, p_desde: fecha, p_dias: dias,
    })
    return dias === 1 ? todos.filter((h) => h.fecha === fecha) : todos
  }

  /**
   * Día elegido → con hora libre: pide confirmación; si no, menú de ese día.
   * Sin lugar ese día (o cerrado): "Ese día no hay horarios; el próximo con lugar es…" con su menú.
   */
  private async mostrarDia(fecha: string, hora: string | null = null) {
    const dia = await this.horariosDe(fecha)
    if (hora) {
      if (dia.some((h) => h.hora === hora)) {
        return this.decir(`¿Te aparto el ${fechaLarga(fecha)} a las ${hora} en ${this.clinicaCorta}? Responde sí o no.`)
      }
      if (dia.length) this.decir(`El ${fechaLarga(fecha)} a las ${hora} no hay lugar. Estos son los horarios libres de ese día:`)
    }
    if (dia.length) return this.menu(fecha, dia, 0)
    const restantes = MAX_DIAS - diasEntre(hoyEn(), fecha)
    const siguientes = restantes > 0 ? await this.horariosDe(sumarDias(fecha, 1), Math.min(restantes, 14)) : []
    if (!siguientes.length) {
      return this.decir(`El ${fechaLarga(fecha)} no hay horarios y tampoco encontré lugar en los días siguientes en ${this.clinicaCorta}. ` +
        'Escribe "menu" para empezar de nuevo.')
    }
    const proximo = siguientes[0].fecha
    this.decir(`${fecha === hoyEn() ? 'Hoy ya no hay horarios' : 'Ese día no hay horarios'}; el próximo con lugar es el ${fechaLarga(proximo)}.`)
    return this.menu(proximo, siguientes.filter((h) => h.fecha === proximo), 0)
  }

  /** Menú numerado de un día: hasta 10 horas, separadas en mañana y tarde, y "Ver más" */
  private menu(fecha: string, dia: Horario[], desde: number) {
    const lista = dia.slice(desde, desde + MENU_MAX)
    const lineas: string[] = []
    let n = 0
    const manana = lista.filter((h) => h.hora < '12:00')
    const tarde = lista.filter((h) => h.hora >= '12:00')
    if (manana.length) lineas.push('Mañana:', ...manana.map((h) => `${++n}) ${h.hora}`))
    if (tarde.length) lineas.push('Tarde:', ...tarde.map((h) => `${++n}) ${h.hora}`))
    if (dia.length > desde + MENU_MAX) lineas.push(`${++n}) Ver más`)
    this.decir(`Horarios del ${fechaLarga(fecha)} en ${this.clinicaCorta}${desde ? ' (más tarde)' : ''}:\n${lineas.join('\n')}\n` +
      'Responde con el número.')
  }

  private async pedirParaQuien(estudioId: string, d: ContextoDialogo) {
    const op = d.opciones.find((o) => o.id === estudioId)
    this.estudioNuevo = { id: estudioId, nombre: op?.etiqueta.split(' — ')[0] ?? 'el estudio' }
    this.tramiteElegido = true
    return this.preguntar(await this.dialogo('nuevo_para'))
  }

  /** Crea el trámite ya con estudio y para quién (la base aplica la regla de duplicados). */
  private async crearTramite(beneficiarioId: string) {
    if (!this.estudioNuevo) { this.decir('No encontré el estudio. Escribe "menu" para empezar de nuevo.'); return }
    await rpc(this.api, 'iniciar_tramite', {
      p_interaccion_id: this.int, p_estudio_id: this.estudioNuevo.id,
      p_beneficiario_id: beneficiarioId === this.ctx.paciente.id ? null : beneficiarioId,
    })
    this.tramiteElegido = true
    await this.recargar()
    this.decir(`Empezamos ${this.tramite.etiqueta} (folio ${this.tramite.folio}).`)
    return this.preguntar()
  }

  /** Errores de la API → mensajes entendibles para el paciente (decide por `code`). */
  async manejarError(e: unknown) {
    if (!(e instanceof ErrorApi)) { console.error(e); this.decir('Tuve un problema. Intenta de nuevo en un momento.'); return }
    const det = detalle(e)
    switch (e.code) {
      case 'PT423':
        // Un asesor tiene ese trámite: plantilla asesor_atendiendo
        this.decir(`${await rpc(this.api, 'texto_asesor_atendiendo', { p_interaccion_id: this.int, p_tramite_id: det.tramite_id })}\n` +
          'Escribe "menu" para ver tus otros trámites.')
        return
      case 'PT409':
        if (e.message === 'tramite_duplicado') {
          this.decir(`Ya tienes ${det.etiqueta} abierto (folio ${det.folio}); seguimos con ese.`)
          try { await this.retomar(det.tramite_id); await this.preguntar() } catch { /* ya se avisó */ }
          return
        }
        if (e.message === 'cita_duplicada') {
          this.decir(`${det.etiqueta} ya tiene una cita el ${fechaCorta(det.fecha_hora)} (folio ${det.folio}). Elige otro estudio u otra persona.`)
          break
        }
        this.decir(e.message === 'horario_sin_cupo' ? 'Ese horario se acaba de llenar. Elige otro.' : 'Tu trámite cambió desde otro canal; te muestro cómo va.')
        break
      case 'PT429': return this.decir('Recibí muchos mensajes seguidos. Espera un minuto y vuelve a escribir.')
      case 'limite_citas': this.decir('Ya tienes 5 citas próximas, que es el máximo. Podrás agendar otra cuando pase alguna.'); break
      case '22023':
        if (e.message === 'faltan_datos_titular') {
          this.tramiteElegido = true
          return this.preguntar(await this.dialogo('registro'))
        }
        this.decir(e.message === 'horario_fuera_de_atencion' ? 'Esa hora no está disponible.' : `No pude hacerlo: ${e.message}.`); break
      case 'P0001': this.decir(`No pude hacerlo: ${e.message}.`); break
      case 'PT404': this.decir('No encontré lo que buscabas.'); break
      case '42501': return this.decir('Eso no se puede hacer desde WhatsApp. Escribe "menu" para ver opciones.')
      default: console.error(e); return this.decir('Tuve un problema. Intenta de nuevo en un momento.')
    }
    try { await this.recargar(); await this.preguntar() } catch { /* ya se avisó del error */ }
  }

  /** Registra cada respuesta como mensaje saliente y la envía al teléfono. */
  async enviar() {
    for (const texto of this.respuestas) {
      await rpc(this.api, 'registrar_mensaje', {
        p_interaccion_id: this.int, p_direccion: 'saliente', p_autor: 'agente_ia', p_contenido: texto,
      })
      await enviarAlPaciente(this.telefono, 'bot', texto)
    }
    for (const link of this.links) await enviarAlPaciente(this.telefono, 'link_pago', link)
  }
}
