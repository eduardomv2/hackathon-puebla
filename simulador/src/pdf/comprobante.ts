// Comprobante de pago y cita en PDF. Todos los datos vienen de api.comprobante_cita: aquí solo se dibuja.
// jsPDF se carga al pedir el primer PDF (no pesa en la carga inicial de la app).
import type { Comprobante } from '../api'

const RELACION: Record<string, string> = { titular: 'Titular', hijo: 'Hijo', hija: 'Hija', madre: 'Madre', padre: 'Padre', conyuge: 'Cónyuge', otro: 'Otro familiar' }
const METODO: Record<string, string> = {
  efectivo: 'Efectivo en caja', tarjeta: 'Tarjeta en caja', en_linea: 'En línea', en_linea_prueba: 'En línea (pago de prueba)',
}
const ESTADO_PAGO: Record<string, string> = {
  pendiente: 'PENDIENTE DE PAGO', pagado: 'PAGADO', fallido: 'FALLIDO', expirado: 'VENCIDO', reembolsado: 'REEMBOLSADO',
}

const fmtFecha = (iso: string, zona: string) =>
  new Intl.DateTimeFormat('es-MX', { timeZone: zona, weekday: 'long', day: 'numeric', month: 'long', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date(iso))
const fmtCorta = (iso: string, zona: string) =>
  new Intl.DateTimeFormat('es-MX', { timeZone: zona, day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date(iso))
const dinero = (n: number, moneda = 'MXN') => n.toLocaleString('es-MX', { style: 'currency', currency: moneda })
const mayus1 = (s: string) => s.charAt(0).toUpperCase() + s.slice(1)

export async function generarComprobantePdf(d: Comprobante) {
  const { jsPDF } = await import('jspdf')
  const doc = new jsPDF({ unit: 'mm', format: 'a4' })
  const W = 210, M = 18
  const zona = d.clinica.zona_horaria
  const pagado = d.pago?.estado === 'pagado'
  const cancelada = d.cita.estado === 'cancelada'
  const verde: [number, number, number] = [10, 110, 130]
  const gris: [number, number, number] = [90, 105, 115]
  const tinta: [number, number, number] = [23, 35, 43]
  let y = 0

  // Encabezado
  doc.setFillColor(...verde); doc.rect(0, 0, W, 34, 'F')
  doc.setTextColor(255, 255, 255); doc.setFont('helvetica', 'bold'); doc.setFontSize(20); doc.text('Salud Digna', M, 16)
  doc.setFont('helvetica', 'normal'); doc.setFontSize(11)
  doc.text(pagado ? 'Comprobante de pago y confirmación de cita' : 'Comprobante de cita', M, 25)
  doc.setFontSize(9); doc.text(`Emitido: ${fmtCorta(d.emitido_en, zona)}`, W - M, 25, { align: 'right' })
  y = 48

  // Folio y estado
  doc.setTextColor(...gris); doc.setFontSize(9); doc.text('FOLIO', M, y)
  doc.setTextColor(...tinta); doc.setFont('helvetica', 'bold'); doc.setFontSize(26); doc.text(d.folio ?? 'sin folio', M, y + 11)
  const etiqueta = cancelada ? 'CITA CANCELADA' : d.pago ? ESTADO_PAGO[d.pago.estado] : 'SIN PAGO'
  const ok = pagado && !cancelada
  doc.setFontSize(11)
  const tw = doc.getTextWidth(etiqueta) + 10
  doc.setFillColor(...(ok ? [221, 241, 235] as [number, number, number] : [250, 235, 215] as [number, number, number]))
  doc.roundedRect(W - M - tw, y - 3, tw, 11, 2, 2, 'F')
  doc.setTextColor(...(ok ? [20, 110, 80] as [number, number, number] : [160, 90, 10] as [number, number, number]))
  doc.text(etiqueta, W - M - tw / 2, y + 4, { align: 'center' })
  y += 24

  const titulo = (t: string) => {
    doc.setDrawColor(...verde); doc.setLineWidth(0.5); doc.line(M, y, W - M, y)
    doc.setTextColor(...verde); doc.setFont('helvetica', 'bold'); doc.setFontSize(10); doc.text(t.toUpperCase(), M, y + 6)
    y += 12
  }
  const fila = (k: string, v: string) => {
    doc.setFont('helvetica', 'normal'); doc.setFontSize(9); doc.setTextColor(...gris); doc.text(k, M, y)
    doc.setFont('helvetica', 'bold'); doc.setFontSize(10.5); doc.setTextColor(...tinta)
    const lineas = doc.splitTextToSize(v, W - M * 2 - 48) as string[]
    doc.text(lineas, M + 48, y)
    y += Math.max(1, lineas.length) * 5.4 + 1.6
  }

  titulo('La cita')
  fila('Estudio', d.estudio.nombre)
  const para = d.paciente?.nombre
  fila('Paciente', para ? `${para}${d.paciente && d.paciente.relacion !== 'titular' ? ` (${RELACION[d.paciente.relacion] ?? d.paciente.relacion})` : ''}` : (d.titular ?? '-'))
  if (para && d.titular && d.titular !== para) fila('Titular de la cuenta', d.titular)
  fila('Fecha y hora', mayus1(fmtFecha(d.cita.fecha_hora, zona)))
  fila('Clínica', d.clinica.nombre)
  const dir = [d.clinica.direccion, `${d.clinica.ciudad}, ${d.clinica.estado}`].filter(Boolean).join('. ')
  fila('Dirección', dir)
  if (d.clinica.telefono) fila('Teléfono de la clínica', d.clinica.telefono)
  if (d.estudio.duracion_min) fila('Duración aproximada', `${d.estudio.duracion_min} minutos`)
  if (d.cita.turno) fila('Turno', `${d.cita.turno}${d.estudio.area ? ` · ${d.estudio.area}` : ''}`)
  y += 4

  titulo('El pago')
  if (d.pago) {
    fila('Monto', dinero(d.pago.monto, d.pago.moneda))
    fila('Estado', ESTADO_PAGO[d.pago.estado] ?? d.pago.estado)
    if (d.pago.pagado_en) fila('Fecha de pago', fmtCorta(d.pago.pagado_en, zona))
    if (d.pago.metodo) fila('Método', METODO[d.pago.metodo] ?? d.pago.metodo)
    fila('Referencia', d.pago.referencia)
  } else {
    fila('Monto de la cita', dinero(d.cita.precio))
    fila('Estado', 'Sin pago generado')
  }
  y += 4

  if (d.estudio.preparacion) {
    titulo('Preparación')
    doc.setFont('helvetica', 'normal'); doc.setFontSize(10); doc.setTextColor(...tinta)
    const l = doc.splitTextToSize(d.estudio.preparacion, W - M * 2) as string[]
    doc.text(l, M, y); y += l.length * 5 + 6
  }

  titulo('Antes de ir')
  doc.setFont('helvetica', 'normal'); doc.setFontSize(10); doc.setTextColor(...tinta)
  const aviso = doc.splitTextToSize(
    'Presenta tu folio y una identificación oficial vigente en la clínica. Llega unos minutos antes de tu hora. '
    + (pagado ? 'Tu pago ya está registrado: no necesitas pagar de nuevo.' : 'Aún falta el pago: puedes hacerlo en línea o en la caja de la clínica.'), W - M * 2) as string[]
  doc.text(aviso, M, y); y += aviso.length * 5 + 4

  // Pie
  doc.setDrawColor(200, 210, 215); doc.line(M, 276, W - M, 276)
  doc.setFontSize(8); doc.setTextColor(...gris)
  const pie = d.pago?.simulado
    ? 'Comprobante generado con un pago de prueba (sin cargo real). Documento informativo, no es una factura.'
    : 'Documento informativo, no es una factura. Para facturar acude a la clínica con este folio.'
  doc.text(doc.splitTextToSize(pie, W - M * 2) as string[], M, 281)
  return doc
}

/** Pide los datos, arma el PDF y lo descarga. */
export async function descargarComprobante(d: Comprobante) {
  const doc = await generarComprobantePdf(d)
  doc.save(`comprobante-${d.folio ?? d.cita.id.slice(0, 8)}.pdf`)
}
