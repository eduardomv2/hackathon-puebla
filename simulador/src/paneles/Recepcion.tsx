// Recepción de clínica (canal 'clinica'):
//   · Mostrador: buscar por celular → "Verificar INE" (verifica ESA sesión) → mismas funciones
//     del asesor (registro, iniciar trámite, agendar —también para hoy—, cambiar horario, pago).
//   · Llegadas: agenda del día → "Registrar llegada": INE de quien recibe el estudio, pregunta
//     de preparación, turno por área y a dónde dirigirlo (caja o área).
// El trámite que recepción atiende queda bloqueado para los demás canales (el personal manda).
import { useEffect, useState } from 'react'
import {
  agendaClinica, directorioClinicas, registrarLlegada, TIPOS_DOCUMENTO,
  type CitaAgenda, type Cliente, type Clinica, type Llegada, type TipoDocumento,
} from '../api'
import { dinero, hora, hoyLocal, Seccion, type Avisador } from '../ui/comunes'
import { Atencion } from './PanelAsesor'

export function Recepcion({ cliente, telefono, av, clinicaFija }: {
  cliente: Cliente; telefono: string; av: Avisador; clinicaFija: string | null
}) {
  const [vista, setVista] = useState<'mostrador' | 'llegadas'>('llegadas')
  return (
    <>
      <div className="interruptor">
        <button className={vista === 'llegadas' ? 'activo' : ''} onClick={() => setVista('llegadas')}>Llegadas de hoy</button>
        <button className={vista === 'mostrador' ? 'activo' : ''} onClick={() => setVista('mostrador')}>Mostrador</button>
      </div>
      {vista === 'mostrador'
        ? <Atencion cliente={cliente} telefono={telefono} av={av} canal="clinica" />
        : <Llegadas cliente={cliente} av={av} clinicaFija={clinicaFija} />}
    </>
  )
}

function Llegadas({ cliente, av, clinicaFija }: { cliente: Cliente; av: Avisador; clinicaFija: string | null }) {
  const [clinicas, setClinicas] = useState<Clinica[]>([])
  const [clinica, setClinica] = useState(clinicaFija ?? '')
  const [fecha, setFecha] = useState(hoyLocal())
  const [agenda, setAgenda] = useState<CitaAgenda[]>([])
  const [abierta, setAbierta] = useState<string | null>(null)
  const [resultado, setResultado] = useState<Record<string, Llegada>>({})

  // Clínicas del catálogo público (solo admin elige; recepción y supervisión tienen la suya)
  useEffect(() => {
    if (clinicaFija) return
    void av.accion(async () => {
      const lista = (await directorioClinicas(cliente))
        .sort((a, b) => a.estado.localeCompare(b.estado) || a.nombre.localeCompare(b.nombre))
      setClinicas(lista)
      if (!clinica && lista[0]) setClinica((lista.find((c) => c.clave === 'PUE-CEN') ?? lista[0]).id)
    })
  }, [cliente, clinicaFija]) // eslint-disable-line

  const cargar = () => clinica && av.accion(async () => setAgenda(await agendaClinica(cliente, clinica, fecha)))
  useEffect(() => { void cargar() }, [clinica, fecha]) // eslint-disable-line
  const esHoy = fecha === hoyLocal()

  return (
    <Seccion titulo="Agenda del día" extra={<button className="secundario chico" onClick={() => void cargar()}>Actualizar</button>}>
      <div className="fila">
        {!clinicaFija && (
          <select value={clinica} onChange={(e) => setClinica(e.target.value)}>
            {[...new Set(clinicas.map((c) => c.estado))].map((e) => (
              <optgroup key={e} label={e}>
                {clinicas.filter((c) => c.estado === e).map((c) => <option key={c.id} value={c.id}>{c.nombre}</option>)}
              </optgroup>
            ))}
          </select>
        )}
        <input type="date" value={fecha} onChange={(e) => setFecha(e.target.value)} />
      </div>
      {!agenda.length && <p className="tenue">Sin citas este día.</p>}
      <div className="agenda">
        {agenda.map((c) => (
          <div key={c.cita_id} className={`cita-agenda estado-${c.estado}`}>
            <div className="fila">
              <b>{hora(c.fecha_hora)}</b>
              <span><b>{c.paciente}</b>{!c.es_titular && <span className="tenue"> · agendó {c.agendada_por}</span>}</span>
              <span className="tenue">{c.estudio} · {c.area_nombre}{c.folio && ` · ${c.folio}`}</span>
            </div>
            <div className="fila">
              <span className={`estado estado-${c.estado}`}>{c.estado === 'en_clinica' ? 'en clínica' : c.estado}</span>
              {c.turno && <span className="turno">Turno {c.turno}</span>}
              <span className={c.pagada ? 'estado estado-confirmada' : 'estado estado-reservada'}>{c.pagada ? 'pagada' : 'pago pendiente'}</span>
              {esHoy && ['reservada', 'confirmada'].includes(c.estado) && abierta !== c.cita_id && (
                <button className="chico" onClick={() => setAbierta(c.cita_id)}>Registrar llegada</button>
              )}
            </div>
            {abierta === c.cita_id && (
              <FormLlegada cita={c} av={av} alCancelar={() => setAbierta(null)} alRegistrar={async (tipo, cumplio) => {
                const r = await av.accion(() => registrarLlegada(cliente, c.cita_id, tipo, cumplio))
                if (r) { setResultado({ ...resultado, [c.cita_id]: r }); setAbierta(null); await cargar() }
              }} />
            )}
            {resultado[c.cita_id] && <ResultadoLlegada r={resultado[c.cita_id]} />}
          </div>
        ))}
      </div>
    </Seccion>
  )
}

function FormLlegada({ cita, av, alCancelar, alRegistrar }: {
  cita: CitaAgenda; av: Avisador; alCancelar: () => void; alRegistrar: (tipo: TipoDocumento, cumplio: boolean) => void
}) {
  const [tipo, setTipo] = useState<TipoDocumento>(cita.es_titular ? 'ine' : 'acta_nacimiento')
  const [cumplio, setCumplio] = useState<boolean | null>(null)
  return (
    <div className="paso">
      <h4>1. Identificación de quien recibe el estudio: {cita.paciente}</h4>
      <div className="fila">
        <select value={tipo} onChange={(e) => setTipo(e.target.value as TipoDocumento)}>
          {TIPOS_DOCUMENTO.map((d) => <option key={d} value={d}>{d.replace('_', ' ')}</option>)}
        </select>
        <span className="tenue">solo se guarda el tipo de documento</span>
      </div>
      <h4>2. Preparación: {cita.preparacion ?? 'sin indicaciones'}</h4>
      <div className="fila">
        ¿Cumplió la preparación?
        <label className="opcion"><input type="radio" checked={cumplio === true} onChange={() => setCumplio(true)} /> Sí</label>
        <label className="opcion"><input type="radio" checked={cumplio === false} onChange={() => setCumplio(false)} /> No</label>
      </div>
      <div className="fila">
        <button className="secundario" onClick={alCancelar}>Cancelar</button>
        <button disabled={cumplio === null || av.ocupado} onClick={() => alRegistrar(tipo, cumplio!)}>Confirmar llegada</button>
      </div>
    </div>
  )
}

function ResultadoLlegada({ r }: { r: Llegada }) {
  const caja = r.pago.estado !== 'pagado'
  return (
    <div className={`llegada ${caja ? 'caja' : ''}`}>
      <div className="turno-grande">{r.turno}</div>
      <div>
        <b>{r.indicacion}</b>
        <div className="tenue">{r.estudio} · área {r.area_nombre}{caja && ` · por pagar ${dinero(r.pago.monto)}`}
          {r.cumplio_preparacion === false && ' · ⚠ no cumplió la preparación'}</div>
      </div>
    </div>
  )
}
