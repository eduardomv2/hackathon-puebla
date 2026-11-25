// Registro mínimo del titular: nombre + apellido paterno (materno opcional).
// Lo usan la web/app (después del OTP), la consola del asesor y recepción.
import { useState } from 'react'
import { guardarDatosPaciente, type CampoRegistro, type Cliente, type Contexto } from '../api'
import type { Avisador } from './comunes'

export type DatosNombre = { nombre: string; apellido_paterno: string; apellido_materno: string }
export const NOMBRE_VACIO: DatosNombre = { nombre: '', apellido_paterno: '', apellido_materno: '' }

/** Faltan nombre o apellido (el celular verificado se resuelve con el OTP) */
export const faltaNombre = (ctx: Contexto | null) =>
  (ctx?.sesion.requiere_registro ?? []).some((c) => c === 'nombre' || c === 'apellido_paterno')

const ETIQUETA: Record<CampoRegistro, string> = {
  nombre: 'nombre', apellido_paterno: 'apellido paterno', celular_verificado: 'celular verificado (OTP)',
}
export const textoFaltantes = (ctx: Contexto | null) =>
  (ctx?.sesion.requiere_registro ?? []).map((c) => ETIQUETA[c]).join(', ')

export function CamposNombre({ datos, cambiar }: { datos: DatosNombre; cambiar: (d: DatosNombre) => void }) {
  const campo = (k: keyof DatosNombre, ph: string) => (
    <input placeholder={ph} value={datos[k]} onChange={(e) => cambiar({ ...datos, [k]: e.target.value })} />
  )
  return (
    <>
      <div className="fila">{campo('nombre', 'Nombre(s)')}{campo('apellido_paterno', 'Apellido paterno')}</div>
      <div className="fila">{campo('apellido_materno', 'Apellido materno (opcional)')}</div>
    </>
  )
}

export const nombreCompleto = (d: DatosNombre) => Boolean(d.nombre.trim() && d.apellido_paterno.trim())

/** Formulario "Completa el registro" para una sesión ya abierta (paciente o personal) */
export function FormRegistro({ cliente, ctx, av, alCambiar, titulo = 'Completa tu registro para agendar' }: {
  cliente: Cliente; ctx: Contexto; av: Avisador; alCambiar: (ctx: Contexto) => void; titulo?: string
}) {
  const [d, setD] = useState<DatosNombre>(NOMBRE_VACIO)
  return (
    <div className="paso registro">
      <h4>{titulo}</h4>
      <p className="tenue">Falta: {textoFaltantes(ctx)}</p>
      <CamposNombre datos={d} cambiar={setD} />
      <button disabled={!nombreCompleto(d) || av.ocupado} onClick={() => av.accion(async () => {
        alCambiar(await guardarDatosPaciente(cliente, ctx.sesion.interaccion_id, {
          nombre: d.nombre.trim(), apellido_paterno: d.apellido_paterno.trim(), apellido_materno: d.apellido_materno.trim() || null,
        }))
        av.ok('Registro guardado.')
      })}>Guardar registro</button>
    </div>
  )
}
