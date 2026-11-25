// /demo (solo pruebas locales): los 4 canales lado a lado contra la API real y los escenarios
// narrados para el jurado. La supervisión queda visible todo el tiempo y entra sola como admin.
import { useEffect, useRef, useState } from 'react'
import { navegar } from '../App'
import { crearCliente, enNube, nuevaSesionAnonima, reiniciarDemo } from '../api'
import { ConsolaPersonal } from '../paneles/ConsolaPersonal'
import { PanelPaciente } from '../paneles/PanelPaciente'
import { PanelTelefono } from '../paneles/PanelTelefono'
import { DemoDetenida, detener, esperar, reanudar, resaltar, texto, type IdPanel } from './dom'
import { ESCENARIOS, type Escenario } from './escenarios'

const URL = import.meta.env.VITE_SUPABASE_URL as string
const CLAVE = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string

// Una sesión por persona (storageKey propio): paciente, teléfono, personal y supervisión
const clientes = {
  web: crearCliente(URL, CLAVE, 'demo-web'),
  telefono: crearCliente(URL, CLAVE, 'demo-telefono'),
  personal: crearCliente(URL, CLAVE, 'demo-personal'),
  supervision: crearCliente(URL, CLAVE, 'demo-supervision'),
}

/** Números de [auth.sms.test_otp] en supabase/config.toml (código 123456). */
const TELEFONOS_PRUEBA = ['528661234567', '528661234568', '528661234569', '528661234570', '528661234571']

type Narracion = { panel: IdPanel | null; texto: string; error?: boolean }

/** En modo nube /demo no existe: mezclaría la base en línea con el teléfono simulado (solo local). */
export default function AppDemo() {
  if (enNube) {
    return (
      <div className="sitio"><main className="sitio-cuerpo">
        <div className="panel">
          <h2>/demo solo existe en local</h2>
          <p>El demo usa el teléfono simulado y reinicia datos de prueba: no se mezcla con la base en línea.</p>
          <p className="tenue">Para usarlo: <code>npm run dev</code> (Supabase local). En la nube usa <a href="/">el sitio</a> o <a href="/personal">/personal</a>.</p>
        </div>
      </main></div>
    )
  }
  return <AppDemoLocal />
}

function AppDemoLocal() {
  const [telefono, setTelefono] = useState(TELEFONOS_PRUEBA[0])
  const [borradorWhatsApp, setBorradorWhatsApp] = useState('')
  const [version, setVersion] = useState(0)          // remonta los paneles tras reiniciar
  const [corriendo, setCorriendo] = useState<Escenario | null>(null)
  const [narracion, setNarracion] = useState<Narracion | null>(null)
  const [historial, setHistorial] = useState<string[]>([])
  const telefonoRef = useRef(telefono)
  telefonoRef.current = telefono

  const narrar = (panel: IdPanel | null, t: string, error = false) => {
    setNarracion({ panel, texto: t, error })
    if (!error) setHistorial((h) => [t, ...h].slice(0, 30))
  }

  const correr = async (e: Escenario) => {
    reanudar()
    setCorriendo(e)
    setHistorial([])
    narrar(null, `▶ Escenario ${e.id}: ${e.titulo}`)
    try {
      await e.correr({
        narrar,
        sim: clientes.telefono,
        usarTelefono: async (t) => {
          setTelefono(t)
          await esperar(() => texto('telefono').includes(`+${t}`) && telefonoRef.current === t, 'cambio de teléfono')
        },
      })
    } catch (err) {
      narrar(null, err instanceof DemoDetenida ? '⏹ Demo detenida.' : `⚠ Se detuvo: ${(err as Error).message}`, !(err instanceof DemoDetenida))
    } finally {
      resaltar(null)
      setCorriendo(null)
    }
  }

  const reiniciar = async () => {
    detener()
    narrar(null, '↺ Reiniciando: se borran solo los datos de los teléfonos de prueba…')
    try {
      const r = await reiniciarDemo(clientes.telefono)
      await nuevaSesionAnonima(clientes.web)
      await nuevaSesionAnonima(clientes.telefono)
      setBorradorWhatsApp('')
      setVersion((v) => v + 1)
      setHistorial([])
      narrar(null, `↺ Demo reiniciada (${r.pacientes_borrados} pacientes de prueba borrados). Elige un escenario.`)
    } catch (err) {
      narrar(null, `⚠ No se pudo reiniciar: ${(err as Error).message}`, true)
    } finally {
      reanudar()
    }
  }

  useEffect(() => () => detener(), [])

  return (
    <div className="app">
      <header className="barra">
        <h1>Salud Digna · demo omnicanal</h1>
        <label>
          Teléfono de prueba{' '}
          <select value={telefono} disabled={!!corriendo} onChange={(e) => setTelefono(e.target.value)}>
            {TELEFONOS_PRUEBA.map((t) => <option key={t} value={t}>+{t}</option>)}
          </select>
        </label>
        <div className="escenarios">
          {ESCENARIOS.map((e) => (
            <button key={e.id} disabled={!!corriendo} className={corriendo?.id === e.id ? 'activo' : ''} onClick={() => void correr(e)}>
              ▶ {e.id}. {e.titulo}
            </button>
          ))}
          {corriendo && <button className="secundario" onClick={detener}>⏹ Detener</button>}
          <button className="secundario" disabled={!!corriendo} onClick={() => void reiniciar()}>↺ Reiniciar demo</button>
        </div>
        <a className="derecha tenue" href="/" onClick={(e) => { e.preventDefault(); navegar('/') }}>sitio</a>
      </header>
      {narracion && (
        <div className={`narracion ${narracion.error ? 'error' : ''}`}>
          <b>{narracion.texto}</b>
          {historial.length > 1 && (
            <details><summary className="tenue">Pasos anteriores</summary>
              <ol className="historial">{historial.slice(1).map((h, i) => <li key={i}>{h}</li>)}</ol>
            </details>
          )}
        </div>
      )}
      <main className="columnas" key={version}>
        <PanelPaciente cliente={clientes.web} telefono={telefono} escribirEnWhatsApp={setBorradorWhatsApp} />
        <PanelTelefono cliente={clientes.telefono} telefono={telefono} borrador={borradorWhatsApp} setBorrador={setBorradorWhatsApp} />
        <ConsolaPersonal cliente={clientes.personal} telefono={telefono} titulo="Personal (call center / recepción)"
          emailInicial="asesor@demo.mx" soloPestanas={['llamada', 'recepcion']} idPanel="personal" />
        <ConsolaPersonal cliente={clientes.supervision} titulo="Supervisión" emailInicial="admin@demo.mx"
          soloPestanas={['supervision']} idPanel="supervision" autoEntrar />
      </main>
    </div>
  )
}
