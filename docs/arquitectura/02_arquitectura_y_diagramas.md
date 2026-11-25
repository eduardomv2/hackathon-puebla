# 2. Arquitectura y diagramas

## 2.1 Vista general (contexto)

```mermaid
flowchart TB
  subgraph Usuarios
    P[Paciente]
    AS[Asesor call center]
    RE[Recepción clínica]
    SU[Supervisor / Admin]
  end

  subgraph Apps["Aplicaciones (sin lógica de negocio)"]
    PWA[PWA / app del paciente]
    WEBP["Web de personal<br/>/personal"]
    BOT["Bot de WhatsApp<br/>(repo salud-digna-chatbot o Edge Function)"]
    VOZ[Voz con IA - futuro]
  end

  subgraph SB["Supabase (proyecto hackathon-omnicanal)"]
    AUTH[Auth<br/>anónimo + celular + correo]
    REST["PostgREST<br/>solo esquema api"]
    EF["Edge Functions (Deno)<br/>webhooks y workers"]
    RT[Realtime Broadcast privado]
    DB[("PostgreSQL 17<br/>core · audit · api · particiones")]
    CRON[pg_cron + pgmq]
    VAULT[Vault<br/>llaves y secretos]
  end

  subgraph Ext["Servicios externos"]
    META[WhatsApp Cloud API - Meta]
    PAGO[Pasarela de pagos - futuro]
    LLM[Claude - resúmenes]
    SMS[Vonage SMS - respaldo]
  end

  P --> PWA & BOT
  AS & RE & SU --> WEBP
  PWA & WEBP -->|JWT del usuario| REST
  PWA & WEBP --> AUTH
  PWA & WEBP -.escucha.-> RT
  BOT -->|clave de servicio| REST
  META <--> EF
  EF -->|clave de servicio| REST
  REST --> DB
  AUTH --> DB
  DB --> RT
  CRON --> DB
  CRON -->|pg_net + worker_token| EF
  EF --> LLM
  EF --> SMS
  PAGO -.webhook firmado.-> EF
  DB --- VAULT
```

**Lectura rápida:** las apps con usuario (web/PWA) hablan con PostgREST con el **JWT del usuario**; todo lo que
necesita la clave de servicio (bot, webhooks, workers) pasa por una **Edge Function** o un servidor propio.
La base empuja eventos a las apps por Realtime y despierta a los workers con `pg_cron` + `pg_net`.

## 2.2 Capas dentro de la base de datos

```mermaid
flowchart TB
  subgraph pub["Superficie pública"]
    API["esquema api<br/>56 funciones RPC (solo POST)"]
  end
  subgraph prv["Interno (nadie lo lee directo)"]
    CORE["esquema core<br/>tablas, reglas, triggers"]
    AUD["esquema audit<br/>bitácora inmutable"]
    PART["esquema particiones<br/>particiones mensuales"]
    HOOKS["esquema hooks<br/>Send SMS hook de Auth"]
  end
  SIM["esquema simulador<br/>solo pruebas - apagado en producción"]
  API -->|security definer| CORE
  CORE --> AUD
  CORE --> PART
```

Principios:

1. **Una sola puerta.** Ni `anon`, ni `authenticated`, ni `service_role` leen tablas. Solo ejecutan funciones `api.*`.
2. **Las funciones validan todo**: rol, nivel de verificación, alcance por clínica, versión, cupo, duplicados.
3. **Todo cambio deja evento** en la línea de tiempo y en la bitácora; es lo que alimenta tiempo real, avisos y métricas.

## 2.3 Ciclo de un trámite

Un trámite de tipo `agendar_estudio` avanza por 5 pasos (tabla `core.flujo_tramite`). El **paso** dice dónde va;
el **estado** del trámite dice si sigue vivo (`activo`, `pausado`, `completado`, `abandonado`, `cancelado`).

```mermaid
stateDiagram-v2
  [*] --> seleccion_estudio: iniciar_tramite
  seleccion_estudio --> seleccion_clinica
  seleccion_clinica --> seleccion_horario
  seleccion_horario --> pago: reservar_cita (cupo, duplicados, límite)
  pago --> confirmada: confirmar_pago o cobrar_en_caja
  confirmada --> [*]: trámite completado
  pago --> [*]: cancelar_cita o el pago expira
  confirmada --> [*]: cancelar_cita (reembolso)
```

La cita tiene su propio ciclo, que es el que ve la clínica:

```mermaid
stateDiagram-v2
  [*] --> reservada: reservar_cita
  reservada --> confirmada: pago
  reservada --> en_clinica: llegada sin pagar (paga en caja)
  confirmada --> en_clinica: registrar_llegada
  en_clinica --> atendida: marcar_atendida
  confirmada --> no_asistio
  reservada --> cancelada: cancelar_cita
  confirmada --> cancelada: cancelar_cita
  reservada --> reservada: reprogramar_cita (nuevo horario)
  confirmada --> confirmada: reprogramar_cita
```

Estados del **pago**: `pendiente`, `pagado`, `fallido`, `expirado`, `reembolsado`.
Reglas: reprogramar exige al menos 1 hora de anticipación y horario de atención con cupo; cancelar una cita
pagada la marca `reembolsado`, una pendiente `expirado`.

## 2.4 Secuencia: paciente agenda en la web y paga

```mermaid
sequenceDiagram
  actor P as Paciente
  participant W as PWA
  participant A as Supabase Auth
  participant API as api (PostgREST)
  participant DB as core (PostgreSQL)
  P->>W: abre la app
  W->>A: signInAnonymously()
  W->>API: catalogo_estudios / clinicas_para_estudio / horarios_disponibles
  P->>W: da su celular
  W->>A: updateUser({phone})
  A->>DB: hook enviar_codigo_auth (encola)
  DB-->>P: código por WhatsApp (o SMS si falla)
  P->>W: escribe el código
  W->>A: verifyOtp(phone_change)
  W->>API: iniciar_sesion_paciente('web')
  API-->>W: contexto (nivel = verificada)
  W->>API: guardar_datos_paciente / iniciar_tramite
  W->>API: reservar_cita (cupo + duplicados + límite)
  W->>API: generar_pago
  P->>W: paga
  W->>API: confirmar_pago (vía pasarela o pago-demo)
  DB-->>W: Realtime paciente:id (cita_confirmada)
```

## 2.5 Secuencia: el mismo trámite continúa en WhatsApp

```mermaid
sequenceDiagram
  actor P as Paciente
  participant M as Meta WhatsApp
  participant EF as Edge Function whatsapp-webhook
  participant API as api
  participant DB as core
  P->>M: "hola"
  M->>EF: webhook firmado (X-Hub-Signature-256)
  EF->>API: iniciar_contacto('whatsapp', tel, 'ia', 'canal')
  API->>DB: busca/crea paciente por celular, une identidades
  API-->>EF: contexto: "Tienes pendiente: Mastografía (SD-4K7Q)"
  EF->>API: registrar_mensaje (cifrado, límite 10/min)
  EF->>M: responde con el menú
  P->>M: elige la cita pendiente
  EF->>API: obtener_contexto / reservar_cita / generar_pago
  DB-->>DB: evento → cola de avisos
  Note over DB,EF: pg_cron cada 5 s → avisos-whatsapp<br/>avisa a los demás canales del cambio
```

## 2.6 Secuencia: el asesor toma un trámite

```mermaid
sequenceDiagram
  actor Pa as Paciente
  actor As as Asesor
  participant C as Consola /personal
  participant API as api
  participant DB as core
  Pa->>As: llama por teléfono
  As->>C: busca por celular
  C->>API: iniciar_contacto('call_center', tel, 'humano')
  API-->>C: nivel "declarada" (solo ve que hay un trámite)
  As->>C: pide verificar
  C->>API: solicitar_otp (Edge: enviar-otp)
  DB-->>Pa: código por WhatsApp
  Pa->>As: dicta el código
  C->>API: validar_otp
  API-->>C: nivel "verificada" (ve todo)
  C->>API: retomar_tramite (bloquea 10 min)
  Note over DB: otros canales reciben PT423<br/>"tramite_en_atencion"
  As->>C: cuelga
  C->>API: cerrar_interaccion (libera el bloqueo)
```

## 2.7 Secuencia: recepción cobra y registra llegada

```mermaid
sequenceDiagram
  actor Pa as Paciente
  actor R as Recepción
  participant C as Consola
  participant API as api
  Pa->>R: llega a la clínica
  R->>C: busca por celular / folio
  C->>API: iniciar_contacto('clinica', tel, 'humano')
  R->>C: verifica INE
  C->>API: verificar_presencial
  R->>C: si no pagó: cobrar en caja
  C->>API: cobrar_en_caja (solo su clínica)
  R->>C: registrar llegada
  C->>API: registrar_llegada (turno, área, preparación)
  Note over API: cita en_clinica → después marcar_atendida
```

## 2.8 Procesos en segundo plano

```mermaid
flowchart LR
  EV[Evento del trámite] -->|trigger| Q1[(cola resumen_tramite)]
  EV -->|trigger| Q2[(cola avisos_whatsapp)]
  CR1[pg_cron 5 s] -->|despachar_worker| W1[procesar-resumenes]
  CR1 --> W2[avisos-whatsapp]
  CR2[pg_cron 30 s] --> W3[enviar-recordatorios]
  Q1 --> W1 -->|Claude o plantilla| R[resumen cifrado en el trámite]
  Q2 --> W2 --> META[WhatsApp]
  CR3["pg_cron 5 min<br/>expirar, cerrar sesiones,<br/>métricas, recordatorios"] --> DB[(core)]
  CR4["pg_cron diario 03:07<br/>particiones"] --> DB
```

Tareas programadas (`pg_cron`): resúmenes (5 s), avisos de WhatsApp (5 s), recordatorios (30 s), liberar atenciones
vencidas (30 s), programar recordatorios / expirar trámites / cerrar sesiones / recalcular métricas (cada 5 min),
limpieza (cada hora), cancelar trámites sin estudio (cada hora), rotación de cifrado (cada minuto, solo si hay
rotación en curso), particiones (diario).

## 2.9 Despliegue

| Entorno | Qué corre | Para qué |
|---|---|---|
| **Producción de pruebas** (supabase.com, `hackathon-omnicanal`, us-east-1, plan gratis) | Base, Auth, API, Edge Functions, Realtime, cron | Es la base real que usa el equipo y la PWA |
| **Local** (Supabase en Podman) | Lo mismo + esquema `simulador` encendido | Desarrollo, pruebas pgTAP, demo |
| **Simulador** (`simulador/`, Vite + React) | Web de pruebas: paciente, personal, demo | Probar contra local o contra la nube (`npm run dev` / `dev:prod`) |
| **Bot de WhatsApp** | Opción A: Edge Function `whatsapp-webhook` en Supabase (decidida). Opción B: bot Node del compañero | Ver [Conexión omnicanal](04_conexion_omnicanal.md) |
