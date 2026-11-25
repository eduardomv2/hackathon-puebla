// Asistente del trámite "agendar estudio", compartido por la web/app y el asesor.
// El paso lo dice la base (tramite_activo.paso_actual); las opciones también
// (catálogo, beneficiarios, horarios). Aquí solo se elige y se llama a la API.
import { useEffect, useState } from 'react'
import {
  agregarBeneficiario, avanzarTramite, catalogoEstudios, clinicasParaEstudio, generarPago, horariosDisponibles,
  iniciarTramite, misBeneficiarios, obtenerContexto, pagarSimulado, referenciaDeLink, reservarCita, retomarTramite,
  ubicacionesClinicas,
  type Beneficiario, type Cliente, type Clinica, type Contexto, type Estudio, type Horario, type Pago, type Relacion,
  type Ubicacion,
} from '../api'
import { dia, dinero, fechaHora, RELACION, type Avisador } from './comunes'

type Props = {
  cliente: Cliente
  ctx: Contexto
  alCambiar: (ctx: Contexto) => void
  av: Avisador
  /** Teléfono al que el simulador avisa del pago (opcional) */
  telefonoAviso?: string
}

export function AsistenteTramite({ cliente, ctx, alCambiar, av, telefonoAviso }: Props) {
  const int = ctx.sesion.interaccion_id
  const t = ctx.tramite_activo
  const recargar = async () => alCambiar(await obtenerContexto(cliente, int))
  /**
   * Acción + recarga del contexto. Ante un error también se recarga (otro canal pudo cambiar el
   * trámite o tomarlo un asesor) y, si el estudio ya estaba pedido para esa persona, se continúa ese.
   */
  const hacer = (fn: () => Promise<unknown>) =>
    av.accion(async () => { await fn(); await recargar() }, (e) => {
      if (e.code === 'PT409' && e.message === 'tramite_duplicado' && e.detalle.tramite_id) {
        void av.accion(async () => { await retomarTramite(cliente, int, e.detalle.tramite_id); await recargar() })
        return
      }
      if (['PT409', 'PT423', 'P0001'].includes(e.code)) void recargar()
    })

  if (ctx.sesion.nivel_verificacion === 'declarada') {
    return <p className="tenue">Verifique la identidad para operar el trámite.</p>
  }
  if (!t) return <p className="tenue">Elija un trámite pendiente o empiece otro.</p>
  if (t.en_atencion_de_otro) {
    return (
      <div className="nota-bloqueo">
        🔒 {ctx.tramites_abiertos.find((x) => x.id === t.id)?.atencion_canal === 'clinica' ? 'Recepción de la clínica está' : 'Un asesor está'} atendiendo{' '}
        <b>{t.etiqueta}</b> ({t.folio}). Puede verlo, pero no cambiarlo
        hasta que termine{t.atencion_hasta ? ` (a más tardar ${new Date(t.atencion_hasta).toLocaleTimeString('es-MX', { timeStyle: 'short' })})` : ''}.
      </div>
    )
  }
  const encabezado = <p className="tenue">{t.etiqueta} · {t.folio}{t.atendido_por_mi && ' · 🎧 bloqueado para otros canales mientras lo atiende'}</p>
  switch (t.paso_actual) {
    case 'seleccion_estudio':
      return <>{encabezado}<PasoEstudio {...{ cliente, ctx, av, hacer }} /></>
    case 'seleccion_clinica':
      return <>{encabezado}<PasoClinica {...{ cliente, ctx, av, hacer }} /></>
    case 'seleccion_horario':
      return <>{encabezado}<PasoHorario {...{ cliente, ctx, av, hacer }} /></>
    case 'pago':
      return <>{encabezado}<PasoPago {...{ cliente, ctx, av, hacer, telefonoAviso }} /></>
    default:
      return <p className="tenue">Trámite en paso {t.paso_actual}.</p>
  }
}

type PasoProps = { cliente: Cliente; ctx: Contexto; av: Avisador; hacer: (fn: () => Promise<unknown>) => Promise<unknown> }

// ---------------------------------------------------------------------
// "Empezar otro": primero el estudio, luego para quién. El trámite nace completo
// (nunca vacío) y la base aplica la regla de duplicados desde el inicio.
// ---------------------------------------------------------------------
export function NuevoTramite({ cliente, ctx, av, alCambiar, alCancelar }: {
  cliente: Cliente; ctx: Contexto; av: Avisador; alCambiar: (ctx: Contexto) => void; alCancelar: () => void
}) {
  const int = ctx.sesion.interaccion_id
  const [busqueda, setBusqueda] = useState('')
  const [estudios, setEstudios] = useState<Estudio[]>([])
  const [estudio, setEstudio] = useState<Estudio | null>(null)
  const [familia, setFamilia] = useState<Beneficiario[]>([])
  const [para, setPara] = useState<string>(ctx.paciente.id)
  const [agregando, setAgregando] = useState(false)

  useEffect(() => { void av.accion(async () => setFamilia(await misBeneficiarios(cliente, int))) }, [cliente, int]) // eslint-disable-line
  useEffect(() => {
    const h = setTimeout(() => void av.accion(async () => setEstudios(await catalogoEstudios(cliente, busqueda))), 250)
    return () => clearTimeout(h)
  }, [cliente, busqueda]) // eslint-disable-line

  const recargar = async () => alCambiar(await obtenerContexto(cliente, int))
  const iniciar = () => av.accion(async () => {
    await iniciarTramite(cliente, int, estudio!.id, para === ctx.paciente.id ? null : para)
    await recargar()
  }, (e) => {
    // Ya lo tenía abierto para esa persona: se continúa ese
    if (e.code === 'PT409' && e.message === 'tramite_duplicado' && e.detalle.tramite_id) {
      void av.accion(async () => { await retomarTramite(cliente, int, e.detalle.tramite_id); await recargar() })
    }
  })

  if (!estudio) {
    return (
      <div className="paso">
        <h4>Nuevo trámite · 1) ¿Qué estudio?</h4>
        <input placeholder="Buscar (sin acentos: obstetrico, biometria…)" value={busqueda} onChange={(e) => setBusqueda(e.target.value)} />
        <div className="lista">
          {estudios.map((e) => (
            <label key={e.id} className="opcion">
              <input type="radio" name="nuevo-estudio" onChange={() => setEstudio(e)} />
              {e.nombre} <span className="tenue">desde {dinero(e.precio_base)}</span>
            </label>
          ))}
        </div>
        <button className="secundario" onClick={alCancelar}>Cancelar</button>
      </div>
    )
  }
  return (
    <div className="paso">
      <h4>Nuevo trámite · 2) {estudio.nombre}: ¿para quién?</h4>
      <label className="opcion"><input type="radio" checked={para === ctx.paciente.id} onChange={() => setPara(ctx.paciente.id)} /> Para mí</label>
      {familia.map((b) => (
        <label key={b.id} className="opcion">
          <input type="radio" checked={para === b.id} onChange={() => setPara(b.id)} /> {b.nombre_completo ?? b.nombre} <span className="tenue">({RELACION[b.relacion]})</span>
        </label>
      ))}
      {agregando
        ? <FormFamiliar cliente={cliente} int={int} av={av} alListo={async (id) => {
            setAgregando(false); setFamilia(await misBeneficiarios(cliente, int)); setPara(id)
          }} alCancelar={() => setAgregando(false)} />
        : <button className="secundario" onClick={() => setAgregando(true)}>+ Agregar familiar</button>}
      <div className="fila">
        <button className="secundario" onClick={() => setEstudio(null)}>← Otro estudio</button>
        <button disabled={av.ocupado} onClick={iniciar}>Iniciar trámite</button>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------
// 1. ¿Para quién? + estudio
// ---------------------------------------------------------------------
function PasoEstudio({ cliente, ctx, av, hacer }: PasoProps) {
  const int = ctx.sesion.interaccion_id
  const t = ctx.tramite_activo!
  const [familia, setFamilia] = useState<Beneficiario[]>([])
  const [para, setPara] = useState<string>(t.contexto.beneficiario_id ?? ctx.paciente.id)
  const [agregando, setAgregando] = useState(false)
  const [busqueda, setBusqueda] = useState('')
  const [estudios, setEstudios] = useState<Estudio[]>([])
  const [estudio, setEstudio] = useState<string>(t.contexto.estudio_id ?? '')

  useEffect(() => { void av.accion(async () => setFamilia(await misBeneficiarios(cliente, int))) }, [cliente, int]) // eslint-disable-line
  useEffect(() => {
    const h = setTimeout(() => void av.accion(async () => setEstudios(await catalogoEstudios(cliente, busqueda))), 250)
    return () => clearTimeout(h)
  }, [cliente, busqueda]) // eslint-disable-line

  return (
    <div className="paso">
      <h4>¿Para quién es el estudio?</h4>
      <label className="opcion"><input type="radio" checked={para === ctx.paciente.id} onChange={() => setPara(ctx.paciente.id)} /> Para mí</label>
      {familia.map((b) => (
        <label key={b.id} className="opcion">
          <input type="radio" checked={para === b.id} onChange={() => setPara(b.id)} /> {b.nombre_completo ?? b.nombre} <span className="tenue">({RELACION[b.relacion]})</span>
        </label>
      ))}
      {agregando
        ? <FormFamiliar cliente={cliente} int={int} av={av} alListo={async (id) => {
            setAgregando(false); setFamilia(await misBeneficiarios(cliente, int)); setPara(id)
          }} alCancelar={() => setAgregando(false)} />
        : <button className="secundario" onClick={() => setAgregando(true)}>+ Agregar familiar</button>}

      <h4>Estudio</h4>
      <input placeholder="Buscar (sin acentos: obstetrico, biometria…)" value={busqueda} onChange={(e) => setBusqueda(e.target.value)} />
      <div className="lista">
        {estudios.map((e) => (
          <label key={e.id} className="opcion">
            <input type="radio" checked={estudio === e.id} onChange={() => setEstudio(e.id)} />
            {e.nombre} <span className="tenue">desde {dinero(e.precio_base)}</span>
          </label>
        ))}
      </div>
      <button disabled={!estudio || av.ocupado}
        onClick={() => hacer(() => avanzarTramite(cliente, int, t, 'seleccion_clinica', { estudio_id: estudio, beneficiario_id: para }))}>
        Continuar
      </button>
    </div>
  )
}

function FormFamiliar({ cliente, int, av, alListo, alCancelar }: {
  cliente: Cliente; int: string; av: Avisador; alListo: (id: string) => void; alCancelar: () => void
}) {
  const [f, setF] = useState({ nombre: '', apellido_paterno: '', apellido_materno: '', fecha_nacimiento: '', relacion: 'hijo', sexo: '', tutor: true })
  const cambiar = (k: string, v: string | boolean) => setF({ ...f, [k]: v })
  return (
    <div className="form">
      <div className="fila">
        <input placeholder="Nombre" value={f.nombre} onChange={(e) => cambiar('nombre', e.target.value)} />
        <input placeholder="Apellido paterno" value={f.apellido_paterno} onChange={(e) => cambiar('apellido_paterno', e.target.value)} />
      </div>
      <div className="fila">
        <input placeholder="Apellido materno" value={f.apellido_materno} onChange={(e) => cambiar('apellido_materno', e.target.value)} />
        <input type="date" value={f.fecha_nacimiento} onChange={(e) => cambiar('fecha_nacimiento', e.target.value)} />
      </div>
      <div className="fila">
        <select value={f.relacion} onChange={(e) => cambiar('relacion', e.target.value)}>
          {(['hijo', 'hija', 'madre', 'padre', 'conyuge', 'otro'] as const).map((r) => <option key={r} value={r}>{RELACION[r]}</option>)}
        </select>
        <select value={f.sexo} onChange={(e) => cambiar('sexo', e.target.value)}>
          <option value="">Sexo (opcional)</option><option value="F">F</option><option value="M">M</option><option value="X">X</option>
        </select>
        <label className="opcion"><input type="checkbox" checked={f.tutor} onChange={(e) => cambiar('tutor', e.target.checked)} /> tutor legal</label>
      </div>
      <div className="fila">
        <button disabled={av.ocupado} onClick={async () => {
          const r = await av.accion(() => agregarBeneficiario(cliente, int, {
            nombre: f.nombre, apellido_paterno: f.apellido_paterno || undefined, apellido_materno: f.apellido_materno || undefined,
            fecha_nacimiento: f.fecha_nacimiento, relacion: f.relacion as Exclude<Relacion, 'titular'>,
            sexo: (f.sexo || undefined) as 'F' | 'M' | 'X' | undefined, es_tutor_legal: f.tutor,
          }))
          if (r) { if (r.reutilizado) av.info(`${f.nombre} ya estaba registrado: se reutiliza.`); alListo(r.beneficiario_id) }
        }}>Guardar familiar</button>
        <button className="secundario" onClick={alCancelar}>Cancelar</button>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------
// 2. Clínica
// ---------------------------------------------------------------------
function PasoClinica({ cliente, ctx, av, hacer }: PasoProps) {
  const int = ctx.sesion.interaccion_id
  const t = ctx.tramite_activo!
  const estudio = t.contexto.estudio_id!
  const [ubicaciones, setUbicaciones] = useState<Ubicacion[]>([])
  const [estado, setEstado] = useState('')
  const [ciudad, setCiudad] = useState('')
  const [cerca, setCerca] = useState<{ lat: number; lng: number } | null>(null)
  const [clinicas, setClinicas] = useState<Clinica[]>([])

  // Primero dónde (estado y ciudad; Puebla de inicio) y luego cuál
  useEffect(() => {
    void av.accion(async () => {
      const u = await ubicacionesClinicas(cliente, estudio)
      setUbicaciones(u)
      const e = u.find((x) => x.estado === 'Puebla') ?? u[0]
      setEstado(e?.estado ?? '')
      setCiudad(e?.ciudades.find((c) => c.ciudad === 'Puebla')?.ciudad ?? '')
    })
  }, [cliente, estudio]) // eslint-disable-line
  useEffect(() => {
    if (!estado && !cerca) return
    void av.accion(async () => setClinicas(await clinicasParaEstudio(cliente, estudio,
      cerca ? { ...cerca, limite: 10 } : { estado, ciudad })))
  }, [cliente, estudio, estado, ciudad, cerca]) // eslint-disable-line

  const ubicarme = () => {
    if (!navigator.geolocation) return av.info('Este navegador no comparte la ubicación.')
    navigator.geolocation.getCurrentPosition(
      (p) => setCerca({ lat: p.coords.latitude, lng: p.coords.longitude }),
      () => av.info('No se pudo obtener tu ubicación. Elige estado y ciudad.'),
      { timeout: 10000 })
  }
  const ciudades = ubicaciones.find((u) => u.estado === estado)?.ciudades ?? []

  return (
    <div className="paso">
      <h4>{t.estudio?.nombre} {t.beneficiario && t.beneficiario.relacion !== 'titular' && <span className="tenue">para {t.beneficiario.nombre}</span>}</h4>
      {t.estudio?.preparacion && <p className="tenue">Preparación: {t.estudio.preparacion}</p>}
      <h4>¿En qué clínica?</h4>
      <div className="fila">
        <select value={estado} onChange={(e) => { setCerca(null); setEstado(e.target.value); setCiudad('') }}>
          {ubicaciones.map((u) => <option key={u.estado} value={u.estado}>{u.estado} ({u.clinicas})</option>)}
        </select>
        <select value={ciudad} onChange={(e) => { setCerca(null); setCiudad(e.target.value) }}>
          <option value="">Todas las ciudades</option>
          {ciudades.map((c) => <option key={c.ciudad} value={c.ciudad}>{c.ciudad} ({c.clinicas})</option>)}
        </select>
        <button className="secundario chico" disabled={av.ocupado} onClick={ubicarme}>📍 Cerca de mí</button>
      </div>
      {cerca && <p className="tenue">Las 10 más cercanas a tu ubicación.</p>}
      {clinicas.map((c) => (
        <button key={c.id} className="opcion-boton" disabled={av.ocupado} title={[c.direccion, c.telefono, c.horario].filter(Boolean).join('\n')}
          onClick={() => hacer(() => avanzarTramite(cliente, int, t, 'seleccion_horario', { clinica_id: c.id }))}>
          {c.nombre} <span className="tenue">· {c.ciudad}{c.distancia_km != null && ` · ${c.distancia_km} km`} · {dinero(c.precio)}</span>
        </button>
      ))}
      <button className="secundario" disabled={av.ocupado} onClick={() => hacer(() => avanzarTramite(cliente, int, t, 'seleccion_estudio'))}>← Cambiar estudio</button>
    </div>
  )
}

// ---------------------------------------------------------------------
// 3. Horario
// ---------------------------------------------------------------------
function PasoHorario({ cliente, ctx, av, hacer }: PasoProps) {
  const int = ctx.sesion.interaccion_id
  const t = ctx.tramite_activo!
  const [horarios, setHorarios] = useState<Horario[]>([])
  const mostrador = ctx.sesion.canal === 'clinica'   // en la clínica también el horario en curso (paciente sin cita)
  const cargar = () => av.accion(async () => setHorarios(
    await horariosDisponibles(cliente, t.contexto.clinica_id!, t.contexto.estudio_id!, undefined, undefined, mostrador)))
  useEffect(() => { void cargar() }, [cliente, t.contexto.clinica_id, t.contexto.estudio_id]) // eslint-disable-line
  const porDia = new Map<string, Horario[]>()
  horarios.forEach((h) => porDia.set(h.fecha, [...(porDia.get(h.fecha) ?? []), h]))
  return (
    <div className="paso">
      <h4>Horarios en {t.clinica?.nombre}</h4>
      {!horarios.length && <p className="tenue">Sin horarios disponibles en los próximos 7 días.</p>}
      {[...porDia].slice(0, 3).map(([fecha, hs]) => (
        <div key={fecha} className="dia">
          <span className="tenue">{dia(fecha)}</span>
          <div className="horas">
            {hs.map((h) => (
              <button key={h.fecha_hora} className="hora-boton" disabled={av.ocupado} title={`${h.disponibles} lugares`}
                onClick={() => hacer(() => reservarCita(cliente, int, t, h.fecha_hora)).then(() => cargar())}>
                {h.hora}
              </button>
            ))}
          </div>
        </div>
      ))}
      <button className="secundario" disabled={av.ocupado} onClick={() => hacer(() => avanzarTramite(cliente, int, t, 'seleccion_clinica'))}>← Cambiar clínica</button>
    </div>
  )
}

// ---------------------------------------------------------------------
// 4. Pago
// ---------------------------------------------------------------------
function PasoPago({ cliente, ctx, av, hacer, telefonoAviso }: PasoProps & { telefonoAviso?: string }) {
  const int = ctx.sesion.interaccion_id
  const t = ctx.tramite_activo!
  const pendiente = ctx.pagos_pendientes?.[0]
  const [pago, setPago] = useState<Pago | null>(null)
  const link = pago?.link_pago ?? pendiente?.link_pago
  return (
    <div className="paso">
      <h4>Cita apartada</h4>
      <p>{t.estudio?.nombre} · {t.clinica?.nombre} · {fechaHora(t.contexto.fecha_hora)} · <b>{dinero(t.contexto.precio)}</b>
        {t.beneficiario && t.beneficiario.relacion !== 'titular' && <span className="tenue"> · para {t.beneficiario.nombre}</span>}</p>
      {link
        ? <>
            <p className="link">{link}</p>
            <button disabled={av.ocupado} onClick={() => hacer(() => pagarSimulado(cliente, referenciaDeLink(link), telefonoAviso))}>
              Pagar (proveedor simulado)
            </button>
          </>
        : <button disabled={av.ocupado} onClick={() => av.accion(async () => setPago(await generarPago(cliente, int, t)))}>Generar link de pago</button>}
      <button className="secundario" disabled={av.ocupado} onClick={() => hacer(() => avanzarTramite(cliente, int, t, 'seleccion_horario'))}>← Cambiar horario</button>
    </div>
  )
}
