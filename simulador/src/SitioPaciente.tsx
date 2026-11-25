// Sitio del paciente (web/app): catálogo, registro con OTP, trámites y citas.
// Al lado, el WhatsApp simulado del celular que se escribe: ahí llega el código de verificación
// (Send SMS Hook → enviar-codigo-auth) y lo que el bot o el sistema le mandan.
import { useState } from 'react'
import { navegar } from './App'
import { crearCliente } from './api'
import { PanelPaciente } from './paneles/PanelPaciente'
import { PanelTelefono } from './paneles/PanelTelefono'

const URL = import.meta.env.VITE_SUPABASE_URL as string
const CLAVE = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string
const cliente = crearCliente(URL, CLAVE, 'paciente')
const clienteTelefono = crearCliente(URL, CLAVE, 'sitio-telefono')

export function SitioPaciente() {
  const [celular, setCelular] = useState('')
  const [borrador, setBorrador] = useState('')
  const conTelefono = /^\d{12,15}$/.test(celular)
  return (
    <div className={`sitio ${conTelefono ? 'sitio-con-telefono' : ''}`}>
      <header className="barra"><h1>Salud Digna</h1><span className="tenue">Agenda tus estudios</span></header>
      <main className="sitio-cuerpo">
        <PanelPaciente cliente={cliente} alCambiarCelular={setCelular} escribirEnWhatsApp={setBorrador} />
        {conTelefono && (
          <aside className="sitio-telefono">
            <p className="tenue">📱 WhatsApp simulado de +{celular} (solo pruebas): aquí llega el código.</p>
            <PanelTelefono key={celular} cliente={clienteTelefono} telefono={celular} borrador={borrador} setBorrador={setBorrador} />
          </aside>
        )}
      </main>
      <footer className="pie">
        <span className="tenue">Cualquier celular recibe su código en el WhatsApp simulado · 866 123 4567 a 4571: código fijo 123456</span>
        <a href="/personal" onClick={(e) => { e.preventDefault(); navegar('/personal') }}>Acceso personal</a>
      </footer>
    </div>
  )
}
