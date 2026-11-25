// 2. Teléfono simulado: chat de WhatsApp (→ Edge Function whatsapp-webhook) y bandeja
//    con lo que "le llega" al teléfono: OTP, links de pago, respuestas del bot.
import { useEffect, useRef, useState } from 'react'
import { asegurarSesionAnonima, enviarWhatsApp, leerBandeja, pagarSimulado, referenciaDeLink, type Cliente, type MensajeBandeja } from '../api'
import { Avisos, hora, Seccion, useAvisos } from '../ui/comunes'

type Props = { cliente: Cliente; telefono: string; borrador: string; setBorrador: (t: string) => void }
type Burbuja = { id: string; de: 'yo' | 'bot'; texto: string; en: string }

export function PanelTelefono({ cliente, telefono, borrador, setBorrador }: Props) {
  const av = useAvisos()
  const [enviados, setEnviados] = useState<Burbuja[]>([])
  const [bandeja, setBandeja] = useState<MensajeBandeja[]>([])
  const [pagados, setPagados] = useState<Set<string>>(new Set())
  const ultimo = useRef(0)
  const fin = useRef<HTMLDivElement>(null)

  // Bandeja por sondeo cada 3 s. El teléfono simulado tiene su propia sesión anónima de Auth:
  // así cuenta en el rate limit por usuario (120/min) y no en el de anon por IP (30/min),
  // que en local comparte todo el tráfico del navegador (misma IP interna de podman).
  useEffect(() => {
    setEnviados([]); setBandeja([]); ultimo.current = 0
    let vivo = true
    const leer = async () => {
      try {
        await asegurarSesionAnonima(cliente)
        const nuevos = await leerBandeja(cliente, telefono, ultimo.current)
        if (!vivo || !nuevos.length) return
        ultimo.current = nuevos[nuevos.length - 1].id
        setBandeja((b) => [...b, ...nuevos])
      } catch (e) { if (vivo) void av.accion(() => Promise.reject(e)) }
    }
    void leer()
    const h = setInterval(leer, 3000)
    return () => { vivo = false; clearInterval(h) }
  }, [cliente, telefono]) // eslint-disable-line

  const chat: Burbuja[] = [
    ...enviados,
    ...bandeja.filter((m) => m.tipo === 'bot').map((m) => ({ id: `b${m.id}`, de: 'bot' as const, texto: m.contenido, en: m.creado_en })),
  ].sort((a, b) => Date.parse(a.en) - Date.parse(b.en))
  useEffect(() => { fin.current?.scrollIntoView({ block: 'nearest' }) }, [chat.length])

  const enviar = async () => {
    const texto = borrador.trim()
    if (!texto) return
    setEnviados((e) => [...e, { id: `y${Date.now()}`, de: 'yo', texto, en: new Date().toISOString() }])
    setBorrador('')
    await av.accion(async () => {
      const r = await enviarWhatsApp(cliente, telefono, texto)
      const error = r.resultados?.[0]?.error
      if (error) throw new Error(error)
    })
  }

  const otros = bandeja.filter((m) => m.tipo !== 'bot').slice().reverse()
  return (
    <div className="panel" data-panel="telefono">
      <header><h2>Teléfono simulado</h2><span className="tenue">+{telefono}</span></header>
      <Avisos avisador={av} />

      <Seccion titulo="WhatsApp">
        <div className="chat">
          {chat.map((b) => (
            <div key={b.id} className={`burbuja ${b.de}`}>
              {b.texto}
              <span className="hora">{hora(b.en)}</span>
            </div>
          ))}
          <div ref={fin} />
        </div>
        <div className="fila">
          <input value={borrador} placeholder="Escribe un mensaje…" onChange={(e) => setBorrador(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter') void enviar() }} />
          <button disabled={av.ocupado} onClick={() => void enviar()}>Enviar</button>
        </div>
      </Seccion>

      <Seccion titulo="Bandeja (SMS, links, avisos)">
        {!otros.length && <p className="tenue">Vacía.</p>}
        {otros.map((m) => (
          <div key={m.id} className={`bandeja bandeja-${m.tipo}`}>
            <span className="hora">{hora(m.creado_en)}</span>
            {m.tipo === 'otp' && <><b>SMS</b> {m.contenido}</>}
            {m.tipo === 'sistema' && <><b>Aviso</b> {m.contenido}</>}
            {m.tipo === 'link_pago' && (
              <>
                <b>Link de pago</b> <span className="link">{m.contenido}</span>
                {pagados.has(m.contenido)
                  ? <span className="estado estado-confirmada">pagado</span>
                  : <button className="chico" disabled={av.ocupado} onClick={() => av.accion(async () => {
                      await pagarSimulado(cliente, referenciaDeLink(m.contenido), telefono)
                      setPagados((p) => new Set(p).add(m.contenido))
                    })}>Pagar</button>}
              </>
            )}
          </div>
        ))}
      </Seccion>
    </div>
  )
}
