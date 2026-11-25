// Pruebas unitarias de fechas en lenguaje natural. "Hoy" = martes 24 de noviembre de 2026.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { fechaLarga, interpretarFecha, interpretarHora, resolverDiaMes } from './fechas.ts'

const HOY = '2026-11-24'
const f = (texto: string) => interpretarFecha(texto, HOY)
const dia = (fecha: string, hora: string | null = null) => ({ tipo: 'fecha', fecha, hora })

test('hoy, mañana, pasado mañana', () => {
  assert.deepEqual(f('hoy'), dia('2026-11-24'))
  assert.deepEqual(f('mañana'), dia('2026-11-25'))
  assert.deepEqual(f('Mañana por favor'), dia('2026-11-25'))
  assert.deepEqual(f('pasado mañana'), dia('2026-11-26'))
})

test('días de la semana = el próximo', () => {
  assert.deepEqual(f('jueves'), dia('2026-11-26'))
  assert.deepEqual(f('el viernes'), dia('2026-11-27'))
  assert.deepEqual(f('sábado'), dia('2026-11-28'))
  assert.deepEqual(f('domingo'), dia('2026-11-29'))
  assert.deepEqual(f('lunes'), dia('2026-11-30'))
  assert.deepEqual(f('miercoles'), dia('2026-11-25'))
  assert.deepEqual(f('martes'), dia('2026-12-01'), 'hoy es martes: "martes" es el de la semana que entra')
  assert.deepEqual(f('el próximo jueves'), dia('2026-11-26'))
})

test('fechas escritas', () => {
  assert.deepEqual(f('26 de noviembre'), dia('2026-11-26'))
  assert.deepEqual(f('el 27 de nov'), dia('2026-11-27'))
  assert.deepEqual(f('26/11'), dia('2026-11-26'))
  assert.deepEqual(f('26-11-2026'), dia('2026-11-26'))
  assert.deepEqual(f('jueves 26 de noviembre'), dia('2026-11-26'))
  assert.deepEqual(f('2 de diciembre'), dia('2026-12-02'))
})

test('día y hora juntos', () => {
  assert.deepEqual(f('jueves 7am'), dia('2026-11-26', '07:00'))
  assert.deepEqual(f('jueves a las 7 am'), dia('2026-11-26', '07:00'))
  assert.deepEqual(f('mañana a las 10'), dia('2026-11-25', '10:00'))
  assert.deepEqual(f('mañana 8 de la mañana'), dia('2026-11-25', '08:00'))
  assert.deepEqual(f('26/11 10:30'), dia('2026-11-26', '10:30'))
  assert.deepEqual(f('hoy 2 de la tarde'), dia('2026-11-24', '14:00'))
  assert.deepEqual(f('viernes a las 3'), dia('2026-11-27', '15:00'), 'sin am/pm, 1 a 6 es por la tarde')
})

test('pasadas o a más de 14 días', () => {
  assert.deepEqual(f('20 de noviembre'), { tipo: 'pasada', fecha: '2026-11-20' })
  assert.deepEqual(f('23/11'), { tipo: 'pasada', fecha: '2026-11-23' })
  assert.deepEqual(f('15 de diciembre'), { tipo: 'lejana', fecha: '2026-12-15' })
  assert.deepEqual(f('8/12'), dia('2026-12-08'), 'justo 14 días: sí se puede')
  assert.deepEqual(f('9/12'), { tipo: 'lejana', fecha: '2026-12-09' })
})

test('no es una fecha', () => {
  assert.equal(f('hola'), null)
  assert.equal(f('3'), null)
  assert.equal(f('31/02'), null, 'fecha imposible')
})

test('auxiliares', () => {
  assert.equal(fechaLarga('2026-11-26'), 'jueves 26 de noviembre')
  assert.equal(fechaLarga('2026-11-25'), 'miércoles 25 de noviembre')
  assert.equal(resolverDiaMes(5, 1, '2026-12-28'), '2027-01-05', 'enero visto desde diciembre')
  assert.equal(interpretarHora('7:30 pm'), '19:30')
  assert.equal(interpretarHora('12'), '12:00')
})
