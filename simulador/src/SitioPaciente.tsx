// Sitio del paciente (web/app): catálogo, registro con OTP, trámites y citas.
import { navegar } from './App'
import { crearCliente } from './api'
import { PanelPaciente } from './paneles/PanelPaciente'

const cliente = crearCliente(import.meta.env.VITE_SUPABASE_URL as string,
  import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string, 'paciente')

export function SitioPaciente() {
  return (
    <div className="sitio">
      <header className="barra"><h1>Salud Digna</h1><span className="tenue">Agenda tus estudios</span></header>
      <main className="sitio-cuerpo">
        <PanelPaciente cliente={cliente} />
      </main>
      <footer className="pie">
        <span className="tenue">Números de prueba: 866 123 4567 a 866 123 4571 · código 123456</span>
        <a href="/personal" onClick={(e) => { e.preventDefault(); navegar('/personal') }}>Acceso personal</a>
      </footer>
    </div>
  )
}
