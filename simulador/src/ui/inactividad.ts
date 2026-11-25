// Cierre de sesión automático tras N minutos sin actividad (teclado, clic, scroll).
import { useEffect } from 'react'

export function useCierrePorInactividad(activo: boolean, minutos: number, alCerrar: () => void) {
  useEffect(() => {
    if (!activo || minutos <= 0) return
    let reloj: ReturnType<typeof setTimeout>
    const reiniciar = () => { clearTimeout(reloj); reloj = setTimeout(alCerrar, minutos * 60_000) }
    const eventos = ['pointerdown', 'keydown', 'scroll', 'touchstart'] as const
    eventos.forEach((e) => window.addEventListener(e, reiniciar, { passive: true }))
    reiniciar()
    return () => { clearTimeout(reloj); eventos.forEach((e) => window.removeEventListener(e, reiniciar)) }
  }, [activo, minutos]) // eslint-disable-line
}
