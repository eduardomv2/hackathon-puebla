# 9. Estado y pendientes

## 9.1 Hecho y probado contra la base en la nube

| Área | Estado |
|---|---|
| Identidad y niveles de verificación | Hecho |
| Catálogo, 261 clínicas, horarios, festivos | Hecho |
| Trámites con folio, varios a la vez, duplicados, bloqueo por atención | Hecho |
| Citas: reservar, cambiar horario, cancelar, llegada, atendida | Hecho |
| Pagos: link, pago de prueba, cobro en caja, reembolso al cancelar | Hecho (pasarela real: no) |
| WhatsApp: bot guiado, OTP, avisos proactivos, recordatorios | Hecho (número de prueba de Meta) |
| Recepción, asesor, supervisor, admin (consola `/personal`) | Hecho |
| Tiempo real, bandeja de atención, journey, métricas | Hecho |
| Cifrado, bitácora, límites, particiones | Hecho |
| Resumen para el asesor (Claude o plantilla) | Hecho (con `ANTHROPIC_API_KEY` usa Claude) |
| Pruebas | 403 pruebas pgTAP en 31 archivos, todas pasan |
| Comprobante de pago y cita en PDF | `api.comprobante_cita` + PDF en el simulador (jsPDF) |
| Guía para la app/PWA del paciente | `docs/GUIA_APP_PWA.md` |

## 9.2 Solo de demostración

- Pago simulado (`PAGO_DEMO`), sin pasarela.
- WhatsApp con el número de prueba de Meta: solo recibe un puñado de celulares registrados y con ventana de 24 h.
- Esquema `simulador` y los números con código fijo `123456` (apagado en producción; los 5 números fijos siguen
  vigentes hasta 2027-01-31).
- Cuentas del personal `@demo.mx`.

## 9.3 Pendiente

| Pendiente | Nota |
|---|---|
| `git push` de los commits locales | Lo hace Eduardo (el agente no tiene credenciales) |
| Entregar la clave de servicio al compañero (bot Node) | Por canal privado |
| Pasarela de pagos real + `pagos-webhook` firmado | Hoy se usa `pago-demo` |
| Número propio de WhatsApp y plantillas aprobadas en Meta | Para salir del número de prueba |
| `pago_url_base` en Vault | Cuando la PWA esté publicada |
| Avisos por WhatsApp de `cita_cancelada` y `cita_reprogramada` | Aún no están en el disparador |
| SMS de respaldo con Vonage | Sin configurar |
| Cancelar/reprogramar por WhatsApp en la Edge Function | Hoy solo en el bot Node (fase 2) |
| Opción "6. Hablar con un agente" del bot Node | Decidir si se quita, como en la web |
| Retención/archivo de datos | Hoy no se borra nada; necesario a escala nacional (ver [escalabilidad](06_escalabilidad.md)) |
| Cumplimiento (LFPDPPP, NOM-024) y aviso de privacidad | No evaluado |
| Selector de método de pago más amable en recepción | Hoy usa `window.confirm` |
| Más cuentas de recepción (una por clínica) | Si se necesitan |
| Plan de pago de Supabase para operar | Hoy plan gratis (se pausa por inactividad) |
| Medir la mezcla real de operaciones | Ver [escalabilidad](06_escalabilidad.md) |
| Fase 3 (Meta → nuestro webhook → reenviar al bot Node) | Solo si deciden hospedar el bot |

## 9.4 Cómo reproducir el estado

```bash
# Base local y pruebas
export DOCKER_HOST=unix:///run/user/$(id -u)/podman/podman.sock   # solo con Podman
npx supabase start && npx supabase db reset && npx supabase test db   # 403 pruebas

# Simulador contra la nube / local
cd simulador && npm run dev:prod    # nube
cd simulador && npm run dev         # local
```
