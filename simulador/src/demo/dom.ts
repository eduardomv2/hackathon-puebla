// Utilidades de la demo: actúan sobre los paneles como lo haría una persona (clics y teclado),
// así el jurado ve cada canal moverse. Cada panel se identifica con data-panel.
export type IdPanel = 'paciente' | 'telefono' | 'personal' | 'supervision'

export class DemoDetenida extends Error {}
let detenida = false
export const detener = () => { detenida = true }
export const reanudar = () => { detenida = false }

const panel = (p: IdPanel) => document.querySelector<HTMLElement>(`[data-panel="${p}"]`)
export const texto = (p: IdPanel) => panel(p)?.innerText ?? ''
const coincide = (t: string, q: string | RegExp) => (typeof q === 'string' ? t.includes(q) : q.test(t))

export const pausa = (ms = 1500) => new Promise<void>((r) => setTimeout(r, ms))

/** Espera hasta que `fn` devuelva algo (o falla con una descripción clara). */
export async function esperar<T>(fn: () => T | null | undefined | false, descripcion: string, ms = 15000): Promise<T> {
  const fin = Date.now() + ms
  for (;;) {
    if (detenida) throw new DemoDetenida('Demo detenida')
    const r = fn()
    if (r) return r
    if (Date.now() > fin) throw new Error(`No apareció: ${descripcion}`)
    await pausa(150)
  }
}

export async function clic(p: IdPanel, q: string | RegExp, dentro?: (el: HTMLElement) => boolean) {
  const b = await esperar(() => [...(panel(p)?.querySelectorAll<HTMLButtonElement>('button') ?? [])]
    .filter((x) => !x.disabled && coincide(x.innerText.trim(), q) && (!dentro || dentro(x))).at(0), `botón «${q}» en ${p}`)
  b.scrollIntoView({ block: 'nearest' })
  b.click()
}

/** Último botón que coincide (p. ej. el link de pago más reciente) */
export async function clicUltimo(p: IdPanel, q: string | RegExp) {
  const b = await esperar(() => [...(panel(p)?.querySelectorAll<HTMLButtonElement>('button') ?? [])]
    .filter((x) => !x.disabled && coincide(x.innerText.trim(), q)).at(-1), `botón «${q}» en ${p}`)
  b.scrollIntoView({ block: 'nearest' })
  b.click()
}

function asignar(el: HTMLInputElement | HTMLSelectElement, valor: string) {
  const proto = el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype
  Object.getOwnPropertyDescriptor(proto, 'value')!.set!.call(el, valor)
  el.dispatchEvent(new Event(el instanceof HTMLSelectElement ? 'change' : 'input', { bubbles: true }))
}

export async function escribir(p: IdPanel, placeholder: string, valor: string) {
  const el = await esperar(() => [...(panel(p)?.querySelectorAll<HTMLInputElement>('input') ?? [])]
    .find((i) => !i.disabled && i.placeholder.startsWith(placeholder)), `campo «${placeholder}» en ${p}`)
  el.scrollIntoView({ block: 'nearest' })
  asignar(el, valor)
}

export async function fecha(p: IdPanel, valor: string) {
  const el = await esperar(() => panel(p)?.querySelector<HTMLInputElement>('input[type="date"]'), `fecha en ${p}`)
  asignar(el, valor)
}

/** Elige una opción de radio por el texto de su etiqueta */
export async function marcar(p: IdPanel, etiqueta: string | RegExp) {
  const l = await esperar(() => [...(panel(p)?.querySelectorAll<HTMLLabelElement>('label') ?? [])]
    .find((x) => coincide(x.innerText.trim(), etiqueta) && x.querySelector('input')), `opción «${etiqueta}» en ${p}`)
  l.querySelector('input')!.click()
}

/** Elige en el primer <select> que tenga esa opción */
export async function seleccionar(p: IdPanel, valor: string) {
  const s = await esperar(() => [...(panel(p)?.querySelectorAll<HTMLSelectElement>('select') ?? [])]
    .find((x) => [...x.options].some((o) => o.value === valor)), `lista con «${valor}» en ${p}`)
  asignar(s, valor)
}

export const esperarTexto = (p: IdPanel, q: string | RegExp, ms?: number) =>
  esperar(() => coincide(texto(p), q), `«${q}» en ${p}`, ms)

/** Cuántas veces aparece un texto: para esperar respuestas NUEVAS del bot */
export const contar = (p: IdPanel, re: RegExp) => (texto(p).match(new RegExp(re.source, 'g' + re.flags.replace('g', ''))) ?? []).length

export async function esperarNuevo(p: IdPanel, re: RegExp, antes: number, ms = 20000) {
  await esperar(() => contar(p, re) > antes, `nueva respuesta «${re.source}» en ${p}`, ms)
}

/** Botón dentro del renglón (tarjeta) que contiene un texto */
export const enRenglon = (selector: string, contiene: string | RegExp) => (el: HTMLElement) => {
  const r = el.closest<HTMLElement>(selector)
  return Boolean(r && coincide(r.innerText, contiene))
}

/** Resalta el panel activo */
export function resaltar(p: IdPanel | null) {
  document.querySelectorAll('[data-panel]').forEach((el) => el.classList.toggle('demo-activo', el.getAttribute('data-panel') === p))
}
