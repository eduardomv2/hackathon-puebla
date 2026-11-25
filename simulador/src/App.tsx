// Una sola aplicación con tres rutas (sin dependencias de router):
//   /          sitio del paciente (web/app). En el pie, la liga discreta "Acceso personal".
//   /personal  consola del personal: se carga solo al entrar (lazy), con su propia sesión
//              (otro storageKey) y cierre automático tras 30 min sin actividad.
//   /demo      los 4 paneles lado a lado (paciente, teléfono simulado, personal, supervisión)
//              con los escenarios narrados para el jurado. Solo pruebas locales.
import { lazy, Suspense, useEffect, useState } from 'react'
import { SitioPaciente } from './SitioPaciente'

const AppPersonal = lazy(() => import('./personal/AppPersonal'))
const AppDemo = lazy(() => import('./demo/AppDemo'))

/** Cambia de ruta sin recargar la página */
export function navegar(ruta: string) {
  window.history.pushState(null, '', ruta)
  window.dispatchEvent(new PopStateEvent('popstate'))
}

function useRuta() {
  const [ruta, setRuta] = useState(window.location.pathname)
  useEffect(() => {
    const cambiar = () => setRuta(window.location.pathname)
    window.addEventListener('popstate', cambiar)
    return () => window.removeEventListener('popstate', cambiar)
  }, [])
  return ruta.replace(/\/+$/, '') || '/'
}

export default function App() {
  const ruta = useRuta()
  return (
    <Suspense fallback={<p className="cargando">Cargando…</p>}>
      {ruta === '/personal' ? <AppPersonal /> : ruta === '/demo' ? <AppDemo /> : <SitioPaciente />}
    </Suspense>
  )
}
