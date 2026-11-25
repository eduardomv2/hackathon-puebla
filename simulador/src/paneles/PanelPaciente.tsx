// 1. Web / App de la paciente.
//   · Sin verificar: catálogo y precios libres. Para iniciar un trámite: OTP del celular
//     (y la casilla de avisos por WhatsApp).
//   · Verificada: sus trámites pendientes como tarjetas (puede tener varios) y el asistente.
//   · En vivo: escucha su canal 'paciente:<id>'; si algo cambia en otro canal, se actualiza y lo dice.
import { useCallback, useEffect, useRef, useState } from 'react'
import {
  asegurarSesionAnonima, cancelarCita, catalogoEstudios, confirmarOtpTelefono, guardarDatosPaciente, iniciarSesionPaciente, nuevaSesionAnonima,
  obtenerContexto, pedirOtpTelefono, registrarConsentimientoAvisos, retomarTramite, suscribirPaciente,
  type Cliente, type Contexto, type Estudio, type ModoOtp,
} from '../api'
import { AsistenteTramite, NuevoTramite } from '../ui/Tramite'
import { CamposNombre, type DatosNombre, faltaNombre, FormRegistro, NOMBRE_VACIO, nombreCompleto } from '../ui/Registro'
import {
  Avisos, describirEvento, dinero, fechaHora, Nivel, RELACION, Seccion, TarjetasTramites, useAvisos,
} from '../ui/comunes'
import { BotonComprobante } from '../ui/BotonComprobante'

type Props = {
  cliente: Cliente
  /** Demo: el teléfono de prueba elegido (fijo). Sin él, la paciente escribe su celular. */
  telefono?: string
  /** Demo: deja un mensaje escrito en el chat del teléfono simulado */
  escribirEnWhatsApp?: (texto: string) => void
  /** Sitio: avisa qué celular se escribió (para mostrar su WhatsApp simulado con el código) */
  alCambiarCelular?: (telefono: string) => void
}

/** "866 123 4567" → "528661234567" (México: 10 dígitos + 52) */
const aTelefono = (texto: string) => {
  const d = texto.replace(/\D/g, '')
  return d.length === 10 ? `52${d}` : d
}

export function PanelPaciente({ cliente, telefono: telefonoDemo, escribirEnWhatsApp, alCambiarCelular }: Props) {
  const [celular, setCelular] = useState('')
  const telefono = telefonoDemo ?? aTelefono(celular)
  const av = useAvisos()
  const [canal, setCanal] = useState<'web' | 'app'>('web')
  const [ctx, setCtx] = useState<Contexto | null>(null)
  const [nuevo, setNuevo] = useState(false)
  const [registro, setRegistro] = useState<DatosNombre>(NOMBRE_VACIO)
  const [estudios, setEstudios] = useState<Estudio[]>([])
  const [otpPedido, setOtpPedido] = useState<ModoOtp | null>(null)
  const [codigoOtp, setCodigoOtp] = useState('')
  const [aceptaAvisos, setAceptaAvisos] = useState(true)
  const [enVivo, setEnVivo] = useState('')
  const ctxRef = useRef<Contexto | null>(null)
  // El celular escrito o, con sesión, el de la cuenta
  const celularActual = /^\d{12,15}$/.test(telefono) ? telefono : (ctx?.paciente?.telefono ?? '').replace(/\D/g, '')
  useEffect(() => { alCambiarCelular?.(celularActual) }, [celularActual]) // eslint-disable-line
  ctxRef.current = ctx

  const entrar = useCallback((c: 'web' | 'app') => av.accion(async () => {
    await asegurarSesionAnonima(cliente)
    setCtx(await iniciarSesionPaciente(cliente, c))
  }), [cliente]) // eslint-disable-line

  useEffect(() => { void entrar(canal) }, [canal, entrar])
  useEffect(() => { void catalogoEstudios(cliente).then(setEstudios).catch(() => {}) }, [cliente])

  // Tiempo real: cambios del paciente en cualquier canal
  const pacienteId = ctx?.paciente.id
  useEffect(() => {
    if (!pacienteId) return
    let dejar: (() => void) | undefined
    let cancelado = false
    let espera: ReturnType<typeof setTimeout> | undefined
    void suscribirPaciente(cliente, pacienteId, (e) => {
      if (cancelado) return   // montaje descartado (modo estricto): el canal es compartido
      if (e.tipo === 'evento' && e.evento.canal !== canal) {
        const texto = describirEvento(e.evento.tipo_evento, e.evento.canal)
        const folio = ctxRef.current?.tramites_abiertos.find((t) => t.id === e.evento.tramite_id)?.folio
        if (texto) av.info(`${texto}${folio ? ` (${folio})` : ''}`)
      }
      clearTimeout(espera)
      espera = setTimeout(() => {
        const actual = ctxRef.current
        if (actual) void obtenerContexto(cliente, actual.sesion.interaccion_id).then(setCtx).catch(() => {})
      }, 400)
    }, setEnVivo).then((f) => { if (!cancelado) dejar = f })
    return () => { cancelado = true; dejar?.(); clearTimeout(espera) }
  }, [cliente, pacienteId, canal]) // eslint-disable-line

  const verificada = ctx?.sesion.nivel_verificacion === 'verificada'
  const int = ctx?.sesion.interaccion_id ?? ''
  return (
    <div className="panel" data-panel="paciente">
      <header>
        <h2>Web / App</h2>
        <span className={`vivo ${enVivo === 'SUBSCRIBED' ? 'on' : ''}`}>● en vivo</span>
        <div className="interruptor">
          {(['web', 'app'] as const).map((c) => (
            <button key={c} className={canal === c ? 'activo' : ''} onClick={() => setCanal(c)}>{c}</button>
          ))}
        </div>
      </header>
      <Avisos avisador={av} />

      {ctx && (
        <>
          <div className="fila">
            <Nivel nivel={ctx.sesion.nivel_verificacion} />
            <span>{ctx.paciente.nombre ?? (verificada ? ctx.paciente.nombre_mostrar : 'Visitante')} <span className="tenue">{ctx.paciente.telefono ?? 'sin teléfono'}</span></span>
            <button className="secundario chico" onClick={() => av.accion(async () => {
              await nuevaSesionAnonima(cliente); setOtpPedido(null); setCtx(await iniciarSesionPaciente(cliente, canal))
            })}>Otra persona</button>
          </div>

          {!verificada && (
            <>
              <Seccion titulo="Catálogo (libre, sin cuenta)">
                {estudios.map((e) => <div key={e.id} className="cita">{e.nombre} <span className="tenue">desde {dinero(e.precio_base)}</span></div>)}
              </Seccion>
              <Seccion titulo="Regístrate para agendar" extra={<span className="tenue">el código llega por WhatsApp</span>}>
                <CamposNombre datos={registro} cambiar={setRegistro} />
                <div className="fila">
                  {telefonoDemo
                    ? <input value={`Celular: +${telefono}`} disabled />
                    : <input placeholder="Celular (10 dígitos)" inputMode="tel" value={celular} onChange={(e) => setCelular(e.target.value)} />}
                </div>
                {!otpPedido
                  ? <button disabled={av.ocupado || telefono.length < 12} onClick={() => av.accion(async () => {
                      const modo = await pedirOtpTelefono(cliente, telefono); setOtpPedido(modo)
                      av.info(modo === 'agregar' ? `Enviamos un código al ${telefono}.`
                        : `Ese número ya tiene cuenta: enviamos un código al ${telefono} para entrar con ella.`)
                    })}>Enviar código a {telefono}</button>
                  : <>
                      <div className="fila">
                        <input placeholder="Código" value={codigoOtp} onChange={(e) => setCodigoOtp(e.target.value)} />
                        <button disabled={av.ocupado} onClick={() => av.accion(async () => {
                          await confirmarOtpTelefono(cliente, telefono, codigoOtp, otpPedido!)
                          setOtpPedido(null); setCodigoOtp('')
                          let nuevo = await iniciarSesionPaciente(cliente, canal)
                          // Si el número ya tenía cuenta con nombre, se conserva lo que escribió aquí (sesión verificada)
                          if (nombreCompleto(registro)) {
                            nuevo = await guardarDatosPaciente(cliente, nuevo.sesion.interaccion_id, {
                              nombre: registro.nombre.trim(), apellido_paterno: registro.apellido_paterno.trim(),
                              apellido_materno: registro.apellido_materno.trim() || null,
                            })
                          }
                          setRegistro(NOMBRE_VACIO)
                          if (aceptaAvisos) await registrarConsentimientoAvisos(cliente, nuevo.sesion.interaccion_id, true)
                          setCtx(await obtenerContexto(cliente, nuevo.sesion.interaccion_id))
                        })}>Verificar</button>
                      </div>
                      <label className="opcion">
                        <input type="checkbox" checked={aceptaAvisos} onChange={(e) => setAceptaAvisos(e.target.checked)} />
                        Acepto recibir avisos por WhatsApp
                      </label>
                    </>}
              </Seccion>
            </>
          )}

          {verificada && (
            <>
              {faltaNombre(ctx) && <FormRegistro cliente={cliente} ctx={ctx} av={av} alCambiar={setCtx} />}
              <Seccion titulo={`Tus trámites (${ctx.tramites_abiertos.length})`}>
                <TarjetasTramites tramites={ctx.tramites_abiertos} activo={ctx.tramite_activo?.id} ocupado={av.ocupado}
                  alElegir={(id) => av.accion(async () => { await retomarTramite(cliente, int, id); setCtx(await obtenerContexto(cliente, int)) })}
                  alNuevo={faltaNombre(ctx) ? undefined : () => setNuevo(true)} />
                {nuevo && <NuevoTramite cliente={cliente} ctx={ctx} av={av} alCancelar={() => setNuevo(false)}
                  alCambiar={(c) => { setNuevo(false); setCtx(c) }} />}
              </Seccion>
              {ctx.tramite_activo && (
                <Seccion titulo="Trámite">
                  <AsistenteTramite cliente={cliente} ctx={ctx} alCambiar={setCtx} av={av} />
                </Seccion>
              )}
              <Seccion titulo="Avisos por WhatsApp">
                <div className="fila">
                  {ctx.paciente.avisos_whatsapp ? '✔ Recibes avisos en tu WhatsApp' : 'No recibes avisos por WhatsApp'}
                  <button className="secundario chico" disabled={av.ocupado} onClick={() => av.accion(async () => {
                    await registrarConsentimientoAvisos(cliente, int, !ctx.paciente.avisos_whatsapp)
                    setCtx(await obtenerContexto(cliente, int))
                  })}>{ctx.paciente.avisos_whatsapp ? 'Dejar de recibir' : 'Aceptar avisos'}</button>
                </div>
                {escribirEnWhatsApp && <button className="secundario chico" onClick={() => escribirEnWhatsApp('Hola')}>Seguir por WhatsApp</button>}
              </Seccion>
            </>
          )}

          <Seccion titulo="Mis citas">
            {ctx.citas_proximas?.length
              ? ctx.citas_proximas.map((c) => (
                  <div key={c.id} className="cita">
                    {fechaHora(c.fecha_hora)} · {c.estudio ?? c.folio ?? 'Cita'}{c.clinica && ` · ${c.clinica}`} · <span className={`estado estado-${c.estado}`}>{c.estado === 'en_clinica' ? 'en clínica' : c.estado}</span>
              {c.turno && <span className="turno">Turno {c.turno} · {c.area}</span>}
                    {c.beneficiario && c.beneficiario.relacion !== 'titular' && <span className="tenue"> · para {c.beneficiario.nombre} ({RELACION[c.beneficiario.relacion]})</span>}
                    <span style={{ marginLeft: 8 }}><BotonComprobante cliente={cliente} interaccion={ctx.sesion.interaccion_id} citaId={c.id} av={av} /></span>
                    {['reservada', 'confirmada'].includes(c.estado) && (
                      <button className="chico secundario" style={{ marginLeft: 8 }} disabled={av.ocupado} onClick={() => {
                        if (!window.confirm(`¿Cancelar la cita de ${c.estudio}?${c.estado === 'confirmada' ? ' Ya está pagada: se marcará el reembolso.' : ''}`)) return
                        void av.accion(async () => {
                          const r = await cancelarCita(cliente, ctx.sesion.interaccion_id, c.id, 'cancelada desde la web')
                          av.ok(`Cita ${r.folio} cancelada${r.reembolso ? ' (pago marcado para reembolso)' : ''}.`)
                          setCtx(await obtenerContexto(cliente, ctx.sesion.interaccion_id))
                        })
                      }}>Cancelar</button>
                    )}
                  </div>))
              : <p className="tenue">Sin citas próximas.</p>}
          </Seccion>
        </>
      )}
    </div>
  )
}
