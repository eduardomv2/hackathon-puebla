// Supervisión (supervisor y admin): bandeja de atención, búsqueda, journey de un paciente,
// métricas y la línea de tiempo en vivo (Broadcast privado journey:global).
// El inicio de sesión lo hace ConsolaPersonal. La demo puede pedir abrir el journey de un
// teléfono con el evento de ventana 'sd:abrir-journey' (detail = teléfono).
import { useEffect, useRef, useState } from 'react'
import {
  buscarPacientes, journeyPaciente, metricas, suscribirJourneyGlobal,
  type Cliente, type EventoEnVivo, type Journey, type Metricas,
} from '../api'
import { Bandeja, Buscar } from '../ui/Supervision'
import { dinero, hora, hoyLocal, LineaTiempo, Resumen, Seccion, type Avisador } from '../ui/comunes'

const haceDias = (n: number) => new Date(Date.now() - n * 86400000).toISOString().slice(0, 10)

export function Supervision({ cliente, av, alEstadoVivo }: { cliente: Cliente; av: Avisador; alEstadoVivo?: (estado: string) => void }) {
  const [pestana, setPestana] = useState<'bandeja' | 'buscar'>('bandeja')
  const [recargar, setRecargar] = useState(0)
  const [seleccion, setSeleccion] = useState<string | null>(null)
  const [journey, setJourney] = useState<Journey | null>(null)
  const [enVivo, setEnVivo] = useState<EventoEnVivo[]>([])
  const [estadoCanal, setEstadoCanal] = useState('')
  const [rango, setRango] = useState({ desde: haceDias(30), hasta: hoyLocal() })
  const [m, setM] = useState<Metricas | null>(null)
  const seleccionRef = useRef<string | null>(null)
  seleccionRef.current = seleccion

  useEffect(() => { alEstadoVivo?.(estadoCanal) }, [estadoCanal]) // eslint-disable-line

  // Demo: abrir el journey de un teléfono
  useEffect(() => {
    const abrirTel = (e: Event) => {
      const tel = (e as CustomEvent<string>).detail
      void av.accion(async () => {
        const r = await buscarPacientes(cliente, tel)
        if (r[0]) abrir(r[0].titular_id ?? r[0].paciente_id)
      })
    }
    window.addEventListener('sd:abrir-journey', abrirTel)
    return () => window.removeEventListener('sd:abrir-journey', abrirTel)
  }, [cliente]) // eslint-disable-line

  const cargarJourney = (paciente: string) => av.accion(async () => setJourney(await journeyPaciente(cliente, paciente, 60)))
  const abrir = (paciente: string) => { setSeleccion(paciente); void cargarJourney(paciente) }
  const cargarMetricas = () => av.accion(async () => setM(await metricas(cliente, rango.desde, rango.hasta)))

  // Tiempo real: cada evento refresca (con un pequeño retraso para agrupar ráfagas)
  useEffect(() => {
    void cargarMetricas()
    let dejar: (() => void) | undefined
    let espera: ReturnType<typeof setTimeout> | undefined
    let cancelado = false
    void suscribirJourneyGlobal(cliente, (e) => {
      if (cancelado) return
      setEnVivo((v) => (v.some((x) => x.evento_id === e.evento_id) ? v : [e, ...v].slice(0, 25)))
      clearTimeout(espera)
      espera = setTimeout(() => {
        setRecargar((n) => n + 1)
        if (seleccionRef.current === e.paciente_id) void journeyPaciente(cliente, e.paciente_id, 60).then(setJourney).catch(() => {})
      }, 600)
    }, setEstadoCanal).then((f) => { if (!cancelado) dejar = f })
    return () => { cancelado = true; dejar?.(); clearTimeout(espera) }
  }, [cliente]) // eslint-disable-line

  const v = m?.variacion_pct
  const pct = (x: number | null | undefined) => (x == null ? 'sin datos del año anterior' : `${x > 0 ? '+' : ''}${x}%`)
  return (
    <>
      <Seccion titulo="Bandeja de atención" extra={
        <div className="interruptor">
          <button className={pestana === 'bandeja' ? 'activo' : ''} onClick={() => setPestana('bandeja')}>Bandeja</button>
          <button className={pestana === 'buscar' ? 'activo' : ''} onClick={() => setPestana('buscar')}>Buscar</button>
        </div>}>
        {pestana === 'bandeja'
          ? <Bandeja cliente={cliente} av={av} recargar={recargar} alAbrir={abrir} />
          : <Buscar cliente={cliente} av={av} alAbrir={abrir} />}
      </Seccion>

      {journey && (
        <Seccion titulo={`Journey: ${journey.paciente.nombre.trim() || 'Sin nombre'}`} extra={<span className="tenue">{journey.paciente.estado}</span>}>
          <div className="tenue">
            {journey.interacciones.slice(0, 6).map((i) => `${i.canal} (${i.agente}, ${i.nivel})`).join(' · ')}
          </div>
          {journey.tramites.slice(0, 3).map((t) => t.resumen && <Resumen key={t.id} texto={t.resumen} />)}
          <LineaTiempo eventos={journey.linea_tiempo.filter((e) => e.tipo_evento !== 'asesor_consulto_contexto')} max={25} />
        </Seccion>
      )}

      <Seccion titulo="Métricas">
        <div className="fila">
          <input type="date" value={rango.desde} onChange={(e) => setRango({ ...rango, desde: e.target.value })} />
          <input type="date" value={rango.hasta} onChange={(e) => setRango({ ...rango, hasta: e.target.value })} />
          <button className="chico" onClick={() => void cargarMetricas()}>Consultar</button>
        </div>
        <p className="tenue">Se recalculan cada 5 minutos (no son instantáneas).</p>
        {m && (
          <>
            <div className="kpis">
              {([['Trámites', m.actual.tramites, m.anio_anterior.tramites, v?.tramites, (x: number) => String(x)],
                 ['Citas', m.actual.citas, m.anio_anterior.citas, v?.citas, (x: number) => String(x)],
                 ['Ingresos', m.actual.ingresos, m.anio_anterior.ingresos, v?.ingresos, dinero]] as const).map(([nombre, act, ant, var_, f]) => (
                <div key={nombre} className="kpi">
                  <span className="tenue">{nombre}</span>
                  <b>{f(act)}</b>
                  <span className="tenue">año anterior: {f(ant)}</span>
                  <span className={var_ == null ? 'tenue' : var_ >= 0 ? 'sube' : 'baja'}>{pct(var_)}</span>
                </div>
              ))}
            </div>
            <details>
              <summary>Embudo y canales</summary>
              <table>
                <tbody>
                  {m.actual.embudo.map((e, i) => <tr key={i}><td>{e.paso}</td><td>{e.estado}</td><td>{e.tramites}</td></tr>)}
                </tbody>
              </table>
              <p className="tenue">Origen: {Object.entries(m.actual.por_canal_origen).map(([c, n]) => `${c} ${n}`).join(' · ') || '—'}</p>
              <p className="tenue">Cambios de canal: {m.actual.transiciones_de_canal.map((t) => `${t.de}→${t.a} ${t.total}`).join(' · ') || '—'}</p>
            </details>
          </>
        )}
      </Seccion>

      <Seccion titulo="En vivo (journey:global)">
        {!enVivo.length && <p className="tenue">Esperando eventos…</p>}
        <ol className="linea-tiempo">
          {enVivo.map((e, i) => (
            <li key={`${e.evento_id}-${i}`}>
              <span className="hora">{hora(e.ocurrido_en)}</span>
              <span className={`canal canal-${e.canal}`}>{e.canal}</span> <b>{e.tipo_evento}</b>
            </li>
          ))}
        </ol>
      </Seccion>
    </>
  )
}
