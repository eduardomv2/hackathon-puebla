import { comprobanteCita, type Cliente } from '../api'
import { descargarComprobante } from '../pdf/comprobante'
import type { Avisador } from './comunes'

/** Descarga el PDF de pago y cita. Los datos salen de la API, que exige identidad verificada. */
export function BotonComprobante({ cliente, interaccion, citaId, av, texto = 'Comprobante PDF' }: {
  cliente: Cliente; interaccion: string; citaId: string; av: Avisador; texto?: string
}) {
  return (
    <button className="chico secundario" disabled={av.ocupado} onClick={() => av.accion(async () => {
      await descargarComprobante(await comprobanteCita(cliente, interaccion, citaId))
      av.ok('Comprobante descargado.')
    })}>{texto}</button>
  )
}
