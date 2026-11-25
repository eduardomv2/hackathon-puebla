// Consola del personal: inicio de sesión (correo y contraseña) y pestañas según el rol.
//   asesor     → Call center
//   recepcion  → Recepción (de su clínica)
//   supervisor → Supervisión (de su clínica, si tiene)
//   admin      → Supervisión, Call center y Recepción
// La usan /personal (con cierre automático tras 30 min sin actividad) y las columnas de /demo.
import { useEffect, useState } from 'react'
import { cerrarSesion, directorioClinicas, iniciarSesionPersonal, sesionVigente, type Cliente } from '../api'
import { Avisos, useAvisos } from '../ui/comunes'
import { useCierrePorInactividad } from '../ui/inactividad'
import { Atencion, Login } from './PanelAsesor'
import { Recepcion } from './Recepcion'
import { Supervision } from './Supervision'

export type Pestana = 'llamada' | 'recepcion' | 'supervision'
type Personal = { email: string; rol: string | null; clinica_id: string | null }

const NOMBRE: Record<Pestana, string> = { llamada: 'Call center', recepcion: 'Recepción', supervision: 'Supervisión' }
export function pestanasDeRol(rol: string | null): Pestana[] {
  switch (rol) {
    case 'asesor': return ['llamada']
    case 'recepcion': return ['recepcion']
    case 'supervisor': return ['supervision']
    case 'admin': return ['supervision', 'llamada', 'recepcion']
    default: return []
  }
}

export function ConsolaPersonal({ cliente, telefono = '', titulo = 'Personal', emailInicial = '', soloPestanas, inactividadMin = 0, idPanel, autoEntrar = false }: {
  cliente: Cliente
  /** Teléfono sugerido para atender (en la demo, el teléfono de prueba elegido) */
  telefono?: string
  titulo?: string
  emailInicial?: string
  /** Limita las pestañas (p. ej. la columna de supervisión de la demo) */
  soloPestanas?: Pestana[]
  /** Cierra la sesión tras estos minutos sin actividad (0 = nunca) */
  inactividadMin?: number
  idPanel?: string
  /** Demo: entra solo con emailInicial y la contraseña de prueba */
  autoEntrar?: boolean
}) {
  const av = useAvisos()
  const [yo, setYo] = useState<Personal | null>(null)
  const [revisada, setRevisada] = useState(false)
  const [pestana, setPestana] = useState<Pestana | null>(null)
  const [vivo, setVivo] = useState('')

  // Sesión guardada: solo si su usuario sigue existiendo (tras un db reset queda huérfana)
  useEffect(() => {
    void (async () => {
      if (await sesionVigente(cliente)) {
        const { data } = await cliente.auth.getUser()
        if (data.user) setYo({ email: data.user.email ?? '', rol: data.user.app_metadata?.rol ?? null, clinica_id: data.user.app_metadata?.clinica_id ?? null })
      } else if (autoEntrar && emailInicial) {
        const r = await av.accion(() => iniciarSesionPersonal(cliente, emailInicial, 'demo1234'))
        if (r) setYo({ email: emailInicial, ...r })
      }
      setRevisada(true)
    })()
  }, [cliente])

  const pestanas = pestanasDeRol(yo?.rol ?? null).filter((p) => !soloPestanas || soloPestanas.includes(p))
  useEffect(() => { setPestana(pestanas[0] ?? null) }, [yo?.rol]) // eslint-disable-line
  // La clínica de la cuenta (recepción y supervisión): solo opera sobre sus citas
  const [nombreClinica, setNombreClinica] = useState<string | null>(null)
  useEffect(() => {
    setNombreClinica(null)
    if (!yo?.clinica_id) return
    void directorioClinicas(cliente, { limite: 300 })
      .then((l) => setNombreClinica(l.find((c) => c.id === yo.clinica_id)?.nombre ?? 'sin nombre'))
      .catch(() => {})
  }, [cliente, yo?.clinica_id])

  const salir = async (motivo?: string) => {
    await cerrarSesion(cliente)
    setYo(null)
    if (motivo) av.info(motivo)
  }
  useCierrePorInactividad(Boolean(yo) && inactividadMin > 0, inactividadMin,
    () => void salir(`Sesión cerrada tras ${inactividadMin} min sin actividad.`))

  return (
    <div className="panel" data-panel={idPanel}>
      <header>
        <h2>{titulo}</h2>
        {pestana === 'supervision' && <span className={`vivo ${vivo === 'SUBSCRIBED' ? 'on' : ''}`}>● en vivo</span>}
        {pestanas.length > 1 && (
          <div className="interruptor">
            {pestanas.map((p) => (
              <button key={p} className={pestana === p ? 'activo' : ''} onClick={() => setPestana(p)}>{NOMBRE[p]}</button>
            ))}
          </div>
        )}
      </header>
      <Avisos avisador={av} />
      {!revisada ? null : !yo
        ? <Login cliente={cliente} av={av} emailInicial={emailInicial} alEntrar={(p) => setYo(p)} />
        : <>
            <div className="fila tenue">
              {yo.email} · {yo.rol}{yo.clinica_id && <> · clínica <b>{nombreClinica ?? '…'}</b></>}
              <button className="secundario chico" onClick={() => void salir()}>Salir</button>
            </div>
            {!pestanas.length && <p className="tenue">Este usuario no tiene acceso a esta sección.</p>}
            {pestana === 'llamada' && <Atencion cliente={cliente} telefono={telefono} av={av} />}
            {pestana === 'recepcion' && <Recepcion cliente={cliente} telefono={telefono} av={av} clinicaFija={yo.clinica_id} />}
            {pestana === 'supervision' && <Supervision cliente={cliente} av={av} alEstadoVivo={setVivo} />}
          </>}
    </div>
  )
}
