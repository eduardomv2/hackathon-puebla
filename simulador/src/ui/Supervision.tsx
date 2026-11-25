// Supervisión: bandeja de atención (conteos + una categoría a la vez, paginada) y búsqueda.
// Nunca lista todo: sin categoría solo hay conteos; la búsqueda pide al menos 3 caracteres.
import { useEffect, useState } from 'react'
import {
  bandejaAtencion, buscarPacientes, CATEGORIAS_BANDEJA,
  type Bandeja as BandejaT, type CategoriaBandeja, type Cliente, type FiltrosBandeja, type ItemBandeja, type PacienteEncontrado,
} from '../api'
import { CANAL, hora, type Avisador } from './comunes'

const NOMBRE: Record<CategoriaBandeja, string> = {
  atorados: 'Atorados', pago_por_vencer: 'Pago por vencer', en_atencion: 'En atención', seguridad: 'Seguridad',
  llegadas_hoy: 'Llegadas de hoy',
}
const AYUDA: Record<CategoriaBandeja, string> = {
  atorados: 'activos sin actividad en más de 2 h', pago_por_vencer: 'el link vence en menos de 2 h',
  en_atencion: 'bloqueados ahora por personal', seguridad: 'verificaciones fallidas o bloqueos (24 h)',
  llegadas_hoy: 'en clínica sin atender',
}

/** recargar: cambia cuando llega un evento en vivo (para refrescar conteos y la página actual) */
export function Bandeja({ cliente, av, recargar, alAbrir }: {
  cliente: Cliente; av: Avisador; recargar: number; alAbrir: (pacienteId: string) => void
}) {
  const [filtros, setFiltros] = useState<FiltrosBandeja>({})
  const [categoria, setCategoria] = useState<CategoriaBandeja | null>(null)
  const [datos, setDatos] = useState<BandejaT | null>(null)
  const [items, setItems] = useState<ItemBandeja[]>([])

  const cargar = (cursor?: string | null) => av.accion(async () => {
    const r = await bandejaAtencion(cliente, { ...filtros, categoria, cursor, limite: 10 })
    setDatos(r)
    setItems((prev) => (cursor ? [...prev, ...r.items] : r.items))
  })
  useEffect(() => { void cargar() }, [categoria, filtros, recargar]) // eslint-disable-line
  const f = (k: keyof FiltrosBandeja, v: string) => setFiltros({ ...filtros, [k]: v || undefined })

  return (
    <>
      <div className="chips">
        {CATEGORIAS_BANDEJA.map((c) => (
          <button key={c} title={AYUDA[c]} className={`chip ${categoria === c ? 'activo' : ''} ${datos?.conteos[c] ? 'con' : ''}`}
            onClick={() => setCategoria(categoria === c ? null : c)}>
            {NOMBRE[c]} <b>{datos?.conteos[c] ?? '·'}</b>
          </button>
        ))}
      </div>
      <details>
        <summary className="tenue">Filtros</summary>
        <div className="fila">
          <select value={filtros.canal ?? ''} onChange={(e) => f('canal', e.target.value)}>
            <option value="">Todos los canales</option>
            {['web', 'app', 'whatsapp', 'call_center', 'clinica'].map((c) => <option key={c} value={c}>{CANAL[c] ?? c}</option>)}
          </select>
          <select value={filtros.estado ?? ''} onChange={(e) => f('estado', e.target.value)}>
            <option value="">Cualquier estado</option>
            {['activo', 'pausado', 'completado'].map((s) => <option key={s} value={s}>{s}</option>)}
          </select>
        </div>
        <div className="fila">
          <span className="tenue">Iniciados del</span>
          <input type="date" value={filtros.desde ?? ''} onChange={(e) => f('desde', e.target.value)} />
          <span className="tenue">al</span>
          <input type="date" value={filtros.hasta ?? ''} onChange={(e) => f('hasta', e.target.value)} />
        </div>
      </details>
      {!categoria
        ? <p className="tenue">Elige una categoría para ver la lista (nunca se lista todo).</p>
        : <>
            {!items.length && <p className="tenue">Nada en «{NOMBRE[categoria]}». 🎉</p>}
            <div className="lista-bandeja">
              {items.map((it, i) => (
                <div key={`${it.tramite_id ?? it.paciente_id}-${i}`} className={`item-bandeja cat-${it.categoria}`}
                  onClick={() => alAbrir(it.paciente_id)}>
                  <div className="fila">
                    <b>{it.paciente}</b>
                    {it.folio && <span className="tenue">{it.etiqueta} · {it.folio}</span>}
                    <span className="tenue derecha">{hora(it.momento)}</span>
                  </div>
                  <div>{it.detalle}</div>
                  {it.bloqueado_hasta && <div className="candado">🔒 bloqueado hasta {hora(it.bloqueado_hasta)}</div>}
                </div>
              ))}
            </div>
            {datos?.siguiente_cursor && (
              <button className="secundario" disabled={av.ocupado} onClick={() => void cargar(datos.siguiente_cursor)}>Ver más</button>
            )}
          </>}
    </>
  )
}

export function Buscar({ cliente, av, alAbrir }: { cliente: Cliente; av: Avisador; alAbrir: (pacienteId: string) => void }) {
  const [texto, setTexto] = useState('')
  const [res, setRes] = useState<PacienteEncontrado[] | null>(null)
  const buscar = () => av.accion(async () => setRes(await buscarPacientes(cliente, texto)))
  return (
    <>
      <div className="fila">
        <input placeholder="Celular, folio (SD-4K7Q) o nombre" value={texto} onChange={(e) => setTexto(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && texto.trim().length >= 3 && void buscar()} />
        <button disabled={texto.trim().length < 3 || av.ocupado} onClick={() => void buscar()}>Buscar</button>
      </div>
      {res && !res.length && <p className="tenue">Sin resultados.</p>}
      <div className="lista-bandeja">
        {res?.map((p) => (
          <div key={p.paciente_id} className="item-bandeja" onClick={() => alAbrir(p.titular_id ?? p.paciente_id)}>
            <div className="fila"><b>{p.nombre}</b><span className="tenue">{p.telefono ?? 'sin teléfono'}</span>
              <span className="tenue derecha">por {p.coincide_por}</span></div>
            <div className="tenue">
              {p.titular_id ? 'Familiar: se abre el journey de su titular' : `${p.tramites_abiertos} trámite(s) abiertos`}
              {p.ultimo_folio && ` · último ${p.ultimo_folio}`}
            </div>
          </div>
        ))}
      </div>
    </>
  )
}
