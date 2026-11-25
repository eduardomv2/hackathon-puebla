// Atención a un paciente por call center o en mostrador (y el inicio de sesión del personal).
//   El asesor manda: el trámite que toma queda bloqueado para los demás canales
//   (10 min que se renuevan con cada acción; se libera al colgar).
//   Mientras atiende, escucha en vivo el canal del paciente (cambios y mensajes de WhatsApp).
import { useEffect, useRef, useState } from 'react'
import {
  cancelarCita, cerrarInteraccion, cobrarEnCaja, enviarOtp, horariosDisponibles, reprogramarCita, iniciarContacto,
  iniciarSesionPersonal, obtenerContexto, retomarTramite, solicitudesAgente, suscribirPaciente, TIPOS_DOCUMENTO, validarOtp,
  verificarIdentidad, verificarIdentificacion,
  type Cliente, type Contexto, type Horario, type SolicitudAgente, type TipoDocumento,
} from '../api'
import { AsistenteTramite, NuevoTramite } from '../ui/Tramite'
import { faltaNombre, FormRegistro } from '../ui/Registro'
import {
  describirEvento, dia, dinero, fechaHora, hora, RELACION, Seccion, TarjetasTramites, VistaContexto, type Avisador,
} from '../ui/comunes'

type Personal = { email: string; rol: string | null; clinica_id: string | null }

export function Login({ cliente, av, emailInicial, alEntrar }: {
  cliente: Cliente; av: Avisador; emailInicial: string; alEntrar: (p: Personal) => void
}) {
  const [email, setEmail] = useState(emailInicial)
  // En la demo el correo viene puesto y la contraseña de prueba también
  const [contrasena, setContrasena] = useState(emailInicial ? 'demo1234' : '')
  return (
    <div className="form">
      <input placeholder="Correo" type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
      <input placeholder="Contraseña" type="password" value={contrasena} onChange={(e) => setContrasena(e.target.value)} />
      <button disabled={av.ocupado} onClick={() => av.accion(async () => {
        const r = await iniciarSesionPersonal(cliente, email, contrasena)
        alEntrar({ email, ...r })
      })}>Iniciar sesión</button>
    </div>
  )
}

// ---------------------------------------------------------------------
// Llamada: buscar por teléfono, verificar, elegir/tomar trámite y operarlo
// ---------------------------------------------------------------------
/** Atención a un paciente: llamada (call center) o mostrador (recepción, canal clínica). */
export function Atencion({ cliente, telefono, av, canal = 'call_center' }: {
  cliente: Cliente; telefono: string; av: Avisador; canal?: 'call_center' | 'clinica'
}) {
  const mostrador = canal === 'clinica'
  const [documento, setDocumento] = useState<TipoDocumento>('ine')
  const [tel, setTel] = useState(telefono)
  const [ctx, setCtx] = useState<Contexto | null>(null)
  const [fecha, setFecha] = useState('')
  const [otpEnviado, setOtpEnviado] = useState<{ expira_en: string; telefono_enmascarado: string } | null>(null)
  const [otp, setOtp] = useState('')
  const [enVivo, setEnVivo] = useState('')
  const [nuevo, setNuevo] = useState(false)
  const [citaSel, setCitaSel] = useState<string | null>(null)
  const ctxRef = useRef<Contexto | null>(null)
  ctxRef.current = ctx
  useEffect(() => setTel(telefono), [telefono])

  const int = ctx?.sesion.interaccion_id ?? ''
  const nivel = ctx?.sesion.nivel_verificacion
  const recargar = async () => { const actual = ctxRef.current; if (actual) setCtx(await obtenerContexto(cliente, actual.sesion.interaccion_id)) }

  // En vivo mientras atiende: cambios de otros canales y mensajes que la paciente manda por WhatsApp
  const pacienteId = ctx?.paciente.id
  useEffect(() => {
    if (!pacienteId || !int) return
    let dejar: (() => void) | undefined
    let cancelado = false
    let espera: ReturnType<typeof setTimeout> | undefined
    void suscribirPaciente(cliente, pacienteId, (e) => {
      if (cancelado) return   // montaje descartado (modo estricto): el canal es compartido
      if (e.tipo === 'evento' && e.evento.canal !== canal) {
        const texto = describirEvento(e.evento.tipo_evento, e.evento.canal)
        if (texto) av.info(texto)
      }
      if (e.tipo === 'mensaje_nuevo' && e.mensaje.canal === 'whatsapp' && e.mensaje.autor === 'paciente') {
        av.info('La paciente escribió por WhatsApp (ver "Mensajes recientes").')
      }
      clearTimeout(espera)
      espera = setTimeout(() => void recargar().catch(() => {}), 400)
    }, setEnVivo).then((f) => { if (!cancelado) dejar = f })
    return () => { cancelado = true; dejar?.(); clearTimeout(espera) }
  }, [cliente, pacienteId, int]) // eslint-disable-line

  const whatsapp = (ctx?.mensajes_recientes ?? []).filter((m) => m.canal === 'whatsapp').slice(-6)
  return (
    <>
      {!mostrador && <SolicitudesAgente cliente={cliente} />}
      <Seccion titulo={mostrador ? 'Mostrador: buscar por celular' : 'Atender llamada'} extra={ctx && <span className={`vivo ${enVivo === 'SUBSCRIBED' ? 'on' : ''}`}>● en vivo</span>}>
        <div className="fila">
          <input value={tel} onChange={(e) => setTel(e.target.value)} placeholder="Teléfono" />
          <button disabled={av.ocupado} onClick={() => av.accion(async () => {
            setOtpEnviado(null); setOtp(''); setFecha(''); setCitaSel(null)
            setCtx(await iniciarContacto(cliente, canal, tel))
          })}>{mostrador ? 'Buscar' : 'Atender'}</button>
          {ctx && <button className="secundario" disabled={av.ocupado} onClick={() => av.accion(async () => {
            await cerrarInteraccion(cliente, int, mostrador ? 'atencion_terminada' : 'llamada_terminada'); setCtx(null)
            av.ok(`${mostrador ? 'Atención terminada' : 'Llamada terminada'}: los trámites que atendía quedaron libres para los demás canales.`)
          })}>{mostrador ? 'Terminar atención' : 'Colgar'}</button>}
        </div>
      </Seccion>

      {ctx && (
        <>
          {mostrador && nivel !== 'verificada' && (
            <Seccion titulo="Verificar identidad (en persona)">
              <div className="fila">
                <select value={documento} onChange={(e) => setDocumento(e.target.value as TipoDocumento)}>
                  {TIPOS_DOCUMENTO.map((d) => <option key={d} value={d}>{d.replace('_', ' ')}</option>)}
                </select>
                <button disabled={av.ocupado} onClick={() => av.accion(async () => {
                  setCtx(await verificarIdentificacion(cliente, int, documento))
                  av.ok('Identificación verificada: la sesión queda verificada (solo se guardó el tipo de documento).')
                })}>Verificar INE</button>
              </div>
            </Seccion>
          )}
          {(nivel !== 'verificada' && !mostrador || nivel === 'verificada' && ctx.sesion.requiere_registro?.includes('celular_verificado')) && (
            <Seccion titulo={nivel === 'verificada' ? 'Verificar el celular (requisito para iniciar trámites)' : 'Verificar identidad'}>
              {!mostrador && nivel !== 'verificada' && <div className="fila">
                <input type="date" value={fecha} onChange={(e) => setFecha(e.target.value)} />
                <button disabled={!fecha || av.ocupado} onClick={() => av.accion(async () => {
                  const r = await verificarIdentidad(cliente, int, fecha)
                  if (!r.verificado) av.info(r.motivo === 'sin_fecha_registrada' ? 'No tiene fecha registrada: use OTP.' : 'La fecha no coincide.')
                  else { av.info('La fecha coincide: la sesión sube solo a "canal". Para "verificada" use OTP.'); if (r.contexto) setCtx(r.contexto) }
                })}>Fecha de nacimiento</button>
              </div>}
              <div className="fila">
                <button disabled={av.ocupado} onClick={() => av.accion(async () => setOtpEnviado(await enviarOtp(cliente, int)))}>Enviar OTP</button>
                {otpEnviado && <>
                  <input placeholder="Código que dicta el paciente" value={otp} onChange={(e) => setOtp(e.target.value)} />
                  <button disabled={av.ocupado} onClick={() => av.accion(async () => {
                    const r = await validarOtp(cliente, int, otp)
                    if (!r.verificado) av.info(r.motivo === 'codigo_incorrecto' ? 'Código incorrecto.' : 'No hay un código vigente.')
                    else { setOtpEnviado(null); setOtp(''); if (r.contexto) setCtx(r.contexto) }
                  })}>Validar</button>
                </>}
              </div>
              {otpEnviado && <p className="tenue">Código enviado al número terminado en {otpEnviado.telefono_enmascarado.slice(-4)} · vence {hora(otpEnviado.expira_en)}</p>}
            </Seccion>
          )}

          {!!ctx.citas_proximas?.length && (
            <Seccion titulo={`Citas del paciente (${ctx.citas_proximas.length})`}>
              {nivel === 'declarada' && <p className="tenue">Elija la cita que menciona el paciente y verifique su identidad para abrir el detalle.</p>}
              {ctx.citas_proximas.map((c) => {
                const elegida = citaSel === c.id
                return (
                  <div key={c.id} className={`tarjeta-tramite ${elegida ? 'activa' : ''}`}>
                    <div className="fila">
                      <b>{c.folio ?? 'Cita'}</b> · {fechaHora(c.fecha_hora)} ·{' '}
                      <span className={`estado estado-${c.estado}`}>{c.estado === 'en_clinica' ? 'en clínica' : c.estado}</span>
                      <button className="chico secundario derecha" onClick={() => setCitaSel(elegida ? null : c.id)}>{elegida ? 'Quitar' : 'Elegir'}</button>
                    </div>
                    {elegida && nivel === 'declarada' && <p className="tenue">Verifique la identidad (fecha de nacimiento u OTP) para ver el detalle.</p>}
                    {elegida && nivel !== 'declarada' && (
                      <AccionesCita cliente={cliente} int={int} cita={c} av={av} mostrador={mostrador}
                        alTerminar={async (quitar) => { if (quitar) setCitaSel(null); await recargar() }} />
                    )}
                  </div>
                )
              })}
            </Seccion>
          )}
          {nivel === 'verificada' && faltaNombre(ctx) && (
            <FormRegistro cliente={cliente} ctx={ctx} av={av} alCambiar={setCtx} titulo="Capture el registro del titular (antes del primer trámite)" />
          )}
          <Seccion titulo={`Trámites pendientes (${ctx.tramites_abiertos.length})`}>
            {nivel === 'declarada'
              ? <p className="tenue">{ctx.tramites_abiertos.map((t) => t.folio).join(', ') || 'Ninguno'} · verifique para ver el detalle y tomarlos.</p>
              : <TarjetasTramites tramites={ctx.tramites_abiertos} activo={ctx.tramite_activo?.id} ocupado={av.ocupado} textoElegir="Tomar"
                  alElegir={(id) => av.accion(async () => { await retomarTramite(cliente, int, id); await recargar() }, () => void recargar())}
                  alNuevo={faltaNombre(ctx) ? undefined : () => setNuevo(true)} />}
            {nuevo && nivel !== 'declarada' && <NuevoTramite cliente={cliente} ctx={ctx} av={av} alCancelar={() => setNuevo(false)}
              alCambiar={(c) => { setNuevo(false); setCtx(c) }} />}
          </Seccion>

          {ctx.tramite_activo && nivel !== 'declarada' && (
            <Seccion titulo="Trámite que atiende">
              <AsistenteTramite cliente={cliente} ctx={ctx} alCambiar={setCtx} av={av} telefonoAviso={tel} />
            </Seccion>
          )}

          {!!whatsapp.length && (
            <Seccion titulo="WhatsApp de la paciente (en vivo, solo lectura)">
              {whatsapp.map((m, i) => (
                <div key={i} className={`msg msg-${m.autor === 'paciente' ? 'in' : 'out'}`}>
                  <span className="tenue">{hora(m.creado_en)} · {m.autor === 'paciente' ? 'paciente' : 'bot'}:</span> {m.contenido}
                </div>
              ))}
            </Seccion>
          )}

          <Seccion titulo="Contexto del paciente">
            <VistaContexto ctx={ctx} mostrarMensajes={false} />
          </Seccion>
        </>
      )}
    </>
  )
}

/** Pacientes que pidieron hablar con una persona (por cualquier canal) y aún nadie atiende. */
function SolicitudesAgente({ cliente }: { cliente: Cliente }) {
  const [lista, setLista] = useState<SolicitudAgente[]>([])
  useEffect(() => {
    let vivo = true
    const cargar = () => solicitudesAgente(cliente).then((l) => { if (vivo) setLista(l) }).catch(() => {})
    void cargar()
    const t = setInterval(cargar, 10000)
    return () => { vivo = false; clearInterval(t) }
  }, [cliente])
  if (!lista.length) return null
  return (
    <Seccion titulo={`Piden hablar con una persona (${lista.length})`}>
      {lista.map((x) => (
        <div key={`${x.paciente_id}${x.momento}`} className="aviso aviso-aviso">
          <span><b>{x.paciente}</b> · {x.canal}{x.folio && ` · ${x.folio}`} · {fechaHora(x.momento)}{x.motivo && <span className="tenue"> · {x.motivo}</span>}</span>
        </div>
      ))}
    </Seccion>
  )
}

type CitaCtx = NonNullable<Contexto['citas_proximas']>[number]

/**
 * Lo que el personal hace con la cita elegida (ya verificada la identidad), aunque su trámite ya cerró:
 * cambiar fecha u hora, cobrar en caja (solo mostrador y solo citas de su clínica) y cancelar.
 */
function AccionesCita({ cliente, int, cita: c, av, mostrador, alTerminar }: {
  cliente: Cliente; int: string; cita: CitaCtx; av: Avisador; mostrador: boolean; alTerminar: (quitar: boolean) => Promise<void>
}) {
  const [horarios, setHorarios] = useState<Horario[] | null>(null)
  const [metodo, setMetodo] = useState<'efectivo' | 'tarjeta'>('efectivo')
  const [miClinica, setMiClinica] = useState<string | null>(null)
  useEffect(() => {
    void cliente.auth.getUser().then(({ data }) => setMiClinica(data.user?.app_metadata?.clinica_id ?? null))
  }, [cliente])
  const editable = ['reservada', 'confirmada'].includes(c.estado)
  const porCobrar = mostrador && !c.pagada && ['reservada', 'en_clinica'].includes(c.estado)
  const otraClinica = Boolean(miClinica && c.clinica_id && miClinica !== c.clinica_id)
  const dias = horarios ? [...new Set(horarios.map((h) => h.fecha))].slice(0, 4) : []

  return (
    <>
      <div>{c.estudio} · {c.clinica}{c.precio != null && ` · ${dinero(c.precio)}`} · {c.pagada ? 'pagada' : 'sin pagar'}</div>
      {c.beneficiario && c.beneficiario.relacion !== 'titular' && <div className="tenue">Para {c.beneficiario.nombre} ({RELACION[c.beneficiario.relacion]})</div>}
      {c.turno && <div>Turno {c.turno} · {c.area}</div>}

      <div className="fila">
        {editable && c.clinica_id && c.estudio_id && (
          <button className="chico" disabled={av.ocupado} onClick={() => horarios ? setHorarios(null) : av.accion(async () =>
            setHorarios((await horariosDisponibles(cliente, c.clinica_id!, c.estudio_id!, undefined, 7)).filter((h) => h.disponibles > 0)))}>
            {horarios ? 'Cerrar horarios' : 'Cambiar fecha u hora'}
          </button>
        )}
        {porCobrar && !otraClinica && (
          <>
            <select value={metodo} onChange={(e) => setMetodo(e.target.value as 'efectivo' | 'tarjeta')}>
              <option value="efectivo">efectivo</option>
              <option value="tarjeta">tarjeta</option>
            </select>
            <button className="chico" disabled={av.ocupado} onClick={() => av.accion(async () => {
              const r = await cobrarEnCaja(cliente, c.id, metodo)
              av.ok(`Cobrado en caja: ${dinero(r.monto)} en ${r.metodo}. La cita quedó confirmada.`)
              await alTerminar(false)
            })}>Cobrar en caja{c.precio != null && ` ${dinero(c.precio)}`}</button>
          </>
        )}
        {editable && (
          <button className="chico secundario" disabled={av.ocupado} onClick={() => {
            if (!window.confirm(`¿Cancelar la cita ${c.folio ?? ''} de ${c.estudio}?${c.pagada ? ' Ya está pagada: se marcará el reembolso.' : ''}`)) return
            void av.accion(async () => {
              const r = await cancelarCita(cliente, int, c.id, `cancelada por ${mostrador ? 'recepción' : 'call center'}`)
              av.ok(`Cita ${r.folio} cancelada${r.reembolso ? ' (pago marcado para reembolso)' : ''}.`)
              await alTerminar(true)
            })
          }}>Cancelar cita</button>
        )}
      </div>
      {porCobrar && otraClinica && (
        <p className="nota-bloqueo">Esta cita es en <b>{c.clinica}</b>: se cobra en la caja de esa sucursal, o el paciente paga en línea.</p>
      )}

      {horarios && (
        <div className="form">
          <b>Nuevo horario en {c.clinica}</b>
          {!dias.length && <p className="tenue">No hay horarios libres en los próximos días.</p>}
          {dias.map((d) => (
            <div key={d} className="dia">
              <span className="tenue">{dia(d)}</span>
              <div className="horas">
                {horarios.filter((h) => h.fecha === d).map((h) => (
                  <button key={h.fecha_hora} className="hora-boton" disabled={av.ocupado || h.fecha_hora === c.fecha_hora}
                    onClick={() => av.accion(async () => {
                      await reprogramarCita(cliente, int, c.id, h.fecha_hora)
                      av.ok(`Cita ${c.folio ?? ''} movida al ${fechaHora(h.fecha_hora)}`)
                      setHorarios(null); await alTerminar(false)
                    })}>{h.hora}</button>
                ))}
              </div>
            </div>
          ))}
        </div>
      )}
    </>
  )
}
