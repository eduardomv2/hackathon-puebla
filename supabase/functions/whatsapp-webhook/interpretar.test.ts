// Pruebas unitarias del intérprete (función pura). Correr:
//   cd simulador && npm run probar-bot        (Node + tsx)
//   deno test supabase/functions/whatsapp-webhook/   (Deno 2)
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { type ContextoDialogo, interpretar, parsearNombreCompleto } from './interpretar.ts'

const ctx = (paso: ContextoDialogo['paso'], extra: Partial<ContextoDialogo> = {}): ContextoDialogo =>
  ({ paso, opciones: [], horarios: [], hoy: '2026-11-24', ...extra })   // martes

test('registro: nombre y apellidos', () => {
  assert.deepEqual(parsearNombreCompleto('Ana López García'), { nombre: 'Ana', apellido_paterno: 'López', apellido_materno: 'García' })
  assert.deepEqual(parsearNombreCompleto('ana lópez'), { nombre: 'Ana', apellido_paterno: 'López', apellido_materno: null })
  assert.deepEqual(parsearNombreCompleto('Me llamo María José Pérez Ruiz'),
    { nombre: 'María José', apellido_paterno: 'Pérez', apellido_materno: 'Ruiz' })
  assert.equal(typeof parsearNombreCompleto('Ana'), 'string', 'falta apellido')
  assert.equal(typeof parsearNombreCompleto('Ana 123'), 'string', 'con números')
})

test('registro: el intérprete lo usa en el paso registro', () => {
  assert.deepEqual(interpretar('Rosa Díaz', ctx('registro')),
    { tipo: 'registrar_nombre', nombre: 'Rosa', apellido_paterno: 'Díaz', apellido_materno: null })
  assert.equal(interpretar('Rosa', ctx('registro')).tipo, 'pedir_nombre')
  assert.equal(interpretar('menu', ctx('registro')).tipo, 'menu', 'las palabras clave siguen funcionando')
})

test('horario: ¿qué día te gustaría?', () => {
  assert.deepEqual(interpretar('jueves', ctx('horario_dia')), { tipo: 'elegir_dia', fecha: '2026-11-26', hora: null })
  assert.deepEqual(interpretar('jueves 7am', ctx('horario_dia')), { tipo: 'elegir_dia', fecha: '2026-11-26', hora: '07:00' })
  assert.deepEqual(interpretar('20 de noviembre', ctx('horario_dia')), { tipo: 'fecha_invalida', motivo: 'pasada', fecha: '2026-11-20' })
  assert.deepEqual(interpretar('15/12', ctx('horario_dia')), { tipo: 'fecha_invalida', motivo: 'lejana', fecha: '2026-12-15' })
  assert.deepEqual(interpretar('cuando sea', ctx('horario_dia')), { tipo: 'fecha_invalida', motivo: 'no_entendida' })
})

test('horario: menú del día', () => {
  const h = (hora: string) => ({ fecha: '2026-11-26', hora, fecha_hora: `2026-11-26T${hora}:00-06:00` })
  const menu = ctx('horario_menu', { fecha: '2026-11-26', horarios: [h('07:00'), h('07:30')], ver_mas: 3 })
  assert.deepEqual(interpretar('2', menu), { tipo: 'elegir_horario', fecha_hora: '2026-11-26T07:30:00-06:00' })
  assert.deepEqual(interpretar('3', menu), { tipo: 'ver_mas' })
  assert.deepEqual(interpretar('ver más', menu), { tipo: 'ver_mas' })
  assert.deepEqual(interpretar('7:30', menu), { tipo: 'elegir_horario', fecha_hora: '2026-11-26T07:30:00-06:00' })
  assert.deepEqual(interpretar('9:00', menu), { tipo: 'elegir_dia', fecha: '2026-11-26', hora: '09:00' }, 'hora no mostrada: se revisa')
  assert.deepEqual(interpretar('mejor el viernes', menu), { tipo: 'elegir_dia', fecha: '2026-11-27', hora: null })
  assert.equal(interpretar('9', menu).tipo, 'no_entendido', 'número fuera del menú')
})

test('horario: confirmación de día y hora', () => {
  const h = { fecha: '2026-11-26', hora: '07:00', fecha_hora: '2026-11-26T07:00:00-06:00' }
  const conf = ctx('horario_confirmar', { fecha: '2026-11-26', horarios: [h] })
  assert.deepEqual(interpretar('sí', conf), { tipo: 'elegir_horario', fecha_hora: h.fecha_hora })
  assert.deepEqual(interpretar('Si, por favor', conf), { tipo: 'elegir_horario', fecha_hora: h.fecha_hora })
  assert.deepEqual(interpretar('no', conf), { tipo: 'elegir_dia', fecha: '2026-11-26', hora: null })
})
