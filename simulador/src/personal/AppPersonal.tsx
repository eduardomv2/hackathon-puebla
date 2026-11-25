// /personal: se carga solo al entrar (lazy). Su sesión se guarda aparte de la del paciente
// (storageKey 'sd-personal') y se cierra sola tras 30 min sin actividad.
import { navegar } from '../App'
import { crearCliente, enNube } from '../api'
import { ConsolaPersonal } from '../paneles/ConsolaPersonal'

const cliente = crearCliente(import.meta.env.VITE_SUPABASE_URL as string,
  import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string, 'personal')

export default function AppPersonal() {
  return (
    <div className="sitio sitio-personal">
      <header className="barra">
        <h1>Salud Digna · Personal</h1>
        <span className="tenue">{enNube
          ? 'Usuarios: asesor@demo.mx, recepcion@demo.mx, clinica@demo.mx (supervisión), admin@demo.mx · la contraseña te la da el equipo'
          : 'Usuarios de prueba: asesor@demo.mx, recepcion@demo.mx, clinica@demo.mx (supervisión), admin@demo.mx · demo1234'}</span>
        <a className="derecha" href="/" onClick={(e) => { e.preventDefault(); navegar('/') }}>← Sitio de pacientes</a>
      </header>
      <main className="sitio-cuerpo">
        <ConsolaPersonal cliente={cliente} titulo="Consola" inactividadMin={30} />
      </main>
    </div>
  )
}
