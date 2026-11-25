// Piezas de interfaz compartidas por los paneles. Sin lógica de negocio:
// todo lo que se muestra viene de las funciones api.
import { useCallback, useState, type ReactNode } from 'react'
import { aErrorApi, type Contexto, type ErrorApi, type Evento, type Relacion, type TramiteAbierto } from '../api'

// ---------------------------------------------------------------------
// Formato
// ---------------------------------------------------------------------
export const fechaHora = (iso?: string | null) =>
  iso ? new Intl.DateTimeFormat('es-MX', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(iso)) : '—'
export const hora = (iso: string) => new Intl.DateTimeFormat('es-MX', { timeStyle: 'short' }).format(new Date(iso))
export const dinero = (n?: number | null) => (n == null ? '—' : Number(n).toLocaleString('es-MX', { style: 'currency', currency: 'MXN' }))
export const dia = (fecha: string) =>
  new Intl.DateTimeFormat('es-MX', { timeZone: 'UTC', weekday: 'short', day: '2-digit', month: 'short' }).format(new Date(`${fecha}T12:00:00Z`))
export const hoyLocal = () => new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 10)

export const RELACION: Record<Relacion, string> = {
  titular: 'titular', hijo: 'hijo', hija: 'hija', madre: 'madre', padre: 'padre', conyuge: 'cónyuge', otro: 'otro',
}

// ---------------------------------------------------------------------
// Avisos por panel: cada error de la API se muestra como texto entendible,
// decidido por su `code` (ver ErrorApi en api.ts).
// ---------------------------------------------------------------------
export type Aviso = { id: number; texto: string; gravedad: 'aviso' | 'error' | 'ok' | 'info' }

export function useAvisos() {
  const [avisos, setAvisos] = useState<Aviso[]>([])
  const [ocupado, setOcupado] = useState(false)

  const agregar = useCallback((texto: string, gravedad: Aviso['gravedad']) => {
    setAvisos((a) => [...a.slice(-3), { id: Date.now() + Math.random(), texto, gravedad }])
  }, [])
  const quitar = useCallback((id: number) => setAvisos((a) => a.filter((x) => x.id !== id)), [])

  /**
   * Ejecuta una acción mostrando "ocupado" y convirtiendo cualquier error en aviso.
   * Devuelve undefined si falló. `alFallar` permite reaccionar (p. ej. recargar ante PT409).
   */
  const accion = useCallback(async <T,>(fn: () => Promise<T>, alFallar?: (e: ErrorApi) => void): Promise<T | undefined> => {
    setOcupado(true)
    try {
      return await fn()
    } catch (e) {
      const err = await aErrorApi(e)
      agregar(err.aviso, err.gravedad)
      alFallar?.(err)
      return undefined
    } finally {
      setOcupado(false)
    }
  }, [agregar])

  return { avisos, quitar, accion, ocupado, ok: (t: string) => agregar(t, 'ok'), info: (t: string) => agregar(t, 'info') }
}
export type Avisador = ReturnType<typeof useAvisos>

export function Avisos({ avisador }: { avisador: Avisador }) {
  if (!avisador.avisos.length) return null
  return (
    <div className="avisos">
      {avisador.avisos.map((a) => (
        <div key={a.id} className={`aviso aviso-${a.gravedad}`}>
          <span>{a.texto}</span>
          <button className="cerrar" onClick={() => avisador.quitar(a.id)} title="Cerrar">×</button>
        </div>
      ))}
    </div>
  )
}

// ---------------------------------------------------------------------
// Bloques visuales
// ---------------------------------------------------------------------
export function Seccion({ titulo, children, extra }: { titulo: string; children: ReactNode; extra?: ReactNode }) {
  return (
    <section className="seccion">
      <h3>{titulo}{extra && <span className="extra">{extra}</span>}</h3>
      {children}
    </section>
  )
}

export function Nivel({ nivel }: { nivel?: string }) {
  return <span className={`nivel nivel-${nivel}`}>{nivel ?? 'sin sesión'}</span>
}

export function LineaTiempo({ eventos, max = 12 }: { eventos?: Evento[]; max?: number }) {
  if (!eventos?.length) return <p className="tenue">Sin eventos.</p>
  return (
    <ol className="linea-tiempo">
      {eventos.slice(0, max).map((e, i) => (
        <li key={i}>
          <span className="hora">{hora(e.ocurrido_en)}</span>
          <span className={`canal canal-${e.canal}`}>{e.canal}</span>
          <b>{e.tipo_evento}</b>
          <span className="tenue"> · {e.actor_tipo}</span>
        </li>
      ))}
    </ol>
  )
}

/** Contexto unificado tal como lo devuelve la API (respeta lo que el nivel permite ver). */
export function VistaContexto({ ctx, mostrarMensajes = true }: { ctx: Contexto; mostrarMensajes?: boolean }) {
  const t = ctx.tramite_activo
  return (
    <div className="contexto">
      <div className="fila">
        <Nivel nivel={ctx.sesion.nivel_verificacion} />
        <span><b>{ctx.paciente.nombre || ctx.paciente.nombre_mostrar || 'Sin nombre'}</b> {ctx.paciente.telefono && <span className="tenue">{ctx.paciente.telefono}</span>}</span>
      </div>
      {ctx.sesion.requiere_verificacion && <p className="tenue">Sesión sin verificar: solo se ve que existe un trámite.</p>}
      {t ? (
        <div className="tarjeta">
          <div><b>Trámite:</b> {t.paso_descripcion ?? t.paso_actual} {t.version != null && <span className="tenue">v{t.version}</span>}</div>
          {t.beneficiario && <div><b>Para:</b> {t.beneficiario.nombre ?? '—'} ({RELACION[t.beneficiario.relacion]})</div>}
          {t.estudio && <div><b>Estudio:</b> {t.estudio.nombre}</div>}
          {t.clinica && <div><b>Clínica:</b> {t.clinica.nombre}</div>}
          {t.canales_usados && <div><b>Canales:</b> {t.canales_usados.join(' → ')}</div>}
          {t.resumen && <Resumen texto={t.resumen} />}
        </div>
      ) : <p className="tenue">Sin trámite abierto.</p>}
      {!!ctx.citas_proximas?.length && (
        <div className="tarjeta">
          <b>Citas próximas</b>
          {ctx.citas_proximas.map((c) => (
            <div key={c.id} className="cita">
              {fechaHora(c.fecha_hora)} · {c.estudio} · {c.clinica} · <span className={`estado estado-${c.estado}`}>{c.estado === 'en_clinica' ? 'en clínica' : c.estado}</span>
              {c.turno && <span className="turno">Turno {c.turno} · {c.area}</span>}
              {c.beneficiario.relacion !== 'titular' && <span className="tenue"> · para {c.beneficiario.nombre} ({RELACION[c.beneficiario.relacion]})</span>}
            </div>
          ))}
        </div>
      )}
      {mostrarMensajes && !!ctx.mensajes_recientes?.length && (
        <details className="tarjeta">
          <summary>Mensajes recientes ({ctx.mensajes_recientes.length})</summary>
          {ctx.mensajes_recientes.map((m, i) => (
            <div key={i} className={`msg msg-${m.autor === 'paciente' ? 'in' : 'out'}`}>
              <span className="tenue">{m.canal} · {m.autor}:</span> {m.contenido}
            </div>
          ))}
        </details>
      )}
      {ctx.linea_tiempo && (
        <details className="tarjeta">
          <summary>Línea de tiempo ({ctx.linea_tiempo.length})</summary>
          <LineaTiempo eventos={ctx.linea_tiempo} max={20} />
        </details>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------
// Trámites pendientes (contexto.tramites_abiertos) como tarjetas
// ---------------------------------------------------------------------
const EN_PASO: Record<string, string> = {
  seleccion_estudio: 'eligiendo estudio', seleccion_clinica: 'eligiendo clínica',
  seleccion_horario: 'eligiendo horario', pago: 'en pago', confirmada: 'confirmada',
}
export const CANAL: Record<string, string> = {
  web: 'la web', app: 'la app', whatsapp: 'WhatsApp', call_center: 'la llamada', clinica: 'la clínica',
  sistema: 'el sistema', panel: 'el panel',
}

/** Resumen para el asesor: "[ia] …" lo escribió Claude; "[plantilla] …", el respaldo sin LLM. */
export function Resumen({ texto }: { texto: string }) {
  const m = texto.match(/^\[(ia|plantilla)\]\s*([\s\S]*)$/)
  const metodo = m?.[1]
  return (
    <div className="resumen">
      <b>Resumen</b>{metodo && <span className={`insignia ${metodo}`}>{metodo === 'ia' ? 'IA' : 'plantilla'}</span>}
      <div style={{ whiteSpace: 'pre-line' }}>{m ? m[2] : texto}</div>
    </div>
  )
}

export function TarjetasTramites({ tramites, activo, alElegir, alNuevo, ocupado, textoElegir = 'Continuar' }: {
  tramites: TramiteAbierto[]; activo?: string | null; alElegir: (id: string) => void; alNuevo?: () => void
  ocupado?: boolean; textoElegir?: string
}) {
  return (
    <div className="tarjetas">
      {tramites.map((t) => {
        const [estudio, para] = (t.etiqueta ?? '').split(' · para ')
        return (
          <div key={t.id} className={`tarjeta-tramite ${t.id === activo ? 'activa' : ''} ${t.en_atencion_de_otro ? 'bloqueada' : ''}`}>
            <div className="persona">{para ? (para === 'ti' ? 'Para ti' : `Para ${para}`) : 'Trámite'}</div>
            <div><b>{estudio || 'Sin estudio aún'}</b></div>
            <div className="tenue">{EN_PASO[t.paso_actual] ?? t.paso_actual} · {t.folio}{t.ultimo_canal && ` · último: ${CANAL[t.ultimo_canal] ?? t.ultimo_canal}`}</div>
            {t.en_atencion_de_otro && <div className="candado">🔒 {t.atencion_canal === 'clinica' ? 'Lo atienden en recepción de la clínica' : 'Lo atiende un asesor por teléfono'}</div>}
            {t.atendido_por_mi && <div className="atiendo">🎧 Lo estás atendiendo</div>}
            {t.id !== activo && <button className="chico" disabled={ocupado} onClick={() => alElegir(t.id)}>{textoElegir}</button>}
          </div>
        )
      })}
      {alNuevo && <button className="secundario" disabled={ocupado} onClick={alNuevo}>+ Empezar otro</button>}
    </div>
  )
}

/** Texto para un aviso en vivo: "Desde WhatsApp: se apartó la cita" */
export function describirEvento(tipo: string, canal: string): string | null {
  const que: Record<string, string> = {
    tramite_iniciado: 'se inició un trámite', paso_avanzado: 'avanzó el trámite', tramite_retomado: 'se retomó el trámite',
    cita_reservada: 'se apartó la cita', llegada_registrada: 'llegó a la clínica (turno asignado)', pago_generado: 'se generó el link de pago', pago_confirmado: 'se acreditó el pago',
    cita_confirmada: 'la cita quedó confirmada', tramite_completado: 'el trámite terminó', tramite_cancelado: 'se canceló un trámite',
    atencion_iniciada: 'un asesor tomó el trámite', atencion_liberada: 'el asesor soltó el trámite',
    beneficiario_agregado: 'se registró un familiar', identidad_verificada: 'se verificó la identidad',
    cita_cancelada: 'se canceló la cita', cita_reprogramada: 'se cambió la fecha de la cita', cita_atendida: 'la cita fue atendida',
    agente_solicitado: 'pidió hablar con una persona',
    pago_fallido: 'el pago fue rechazado', limite_citas_alcanzado: 'se llegó al máximo de citas',
  }
  return que[tipo] ? `Desde ${CANAL[canal] ?? canal}: ${que[tipo]}` : null
}
