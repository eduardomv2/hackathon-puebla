# Orquestador omnicanal Salud Digna

> El paciente cambia de canal y el sistema sigue donde se quedó.

Base de datos y API del "cerebro" que une web, app, WhatsApp, call center, recepción de clínica y supervisión
en **un solo paciente y los mismos trámites**. Los canales no tienen lógica propia: pintan pantallas y llaman a
la API. Corre en Supabase (PostgreSQL 17). Prototipo de hackathon (HackaTec Puebla, noviembre 2026).

```mermaid
flowchart LR
  subgraph Canales
    A[Web / PWA paciente]
    B[WhatsApp - bot]
    C[Voz con IA]
    D[Call center - asesor]
    E[Recepción de clínica]
    F[Supervisión / Admin]
  end
  API["API única (esquema api, RPC por POST)"]
  DB[("PostgreSQL<br/>trámites · citas · pagos · eventos")]
  A & B & C & D & E & F --> API --> DB
  DB -. tiempo real .-> A & D & E & F
  DB -. pg_cron / pg_net .-> W["Edge Functions"]
  W --> API
```

## Qué resuelve

| Necesidad | Cómo |
|---|---|
| Que no pidan lo mismo dos veces | El mismo celular es el mismo paciente en todos los canales |
| Empezar en la web y seguir por WhatsApp | Cada trámite tiene folio y estado; cualquier canal lo retoma |
| Que no se agende dos veces lo mismo | Duplicados y cupo se validan en la base |
| Que dos canales no se pisen | Versión del trámite y bloqueo mientras el personal atiende |
| Privacidad de datos de salud | Niveles de verificación, cifrado, bitácora y ninguna tabla expuesta |
| Que supervisión vea todo | Línea de tiempo en vivo, bandeja de atención y métricas permanentes |

## En números

| | |
|---|---|
| Funciones de la API pública (`api.*`) | 50 |
| Migraciones | 38 |
| Pruebas pgTAP | 403 en 31 archivos |
| Edge Functions | 8 |
| Clínicas reales con horarios y zona horaria | 261 |
| Rendimiento medido en local (100 mil pacientes, 2 M de eventos) | 9.5 ms promedio, 841 operaciones/s, 0 errores en `api.iniciar_contacto` |

## Documentación

| Documento | Para qué |
|---|---|
| [`docs/arquitectura/`](docs/arquitectura/README.md) | Resumen ejecutivo, diagramas, modelo de datos, conexión omnicanal, seguridad, escalabilidad, por qué Supabase y decisiones |
| [`docs/GUIA_APP_PWA.md`](docs/GUIA_APP_PWA.md) | **Léela antes de construir o validar** la app/PWA del paciente o las consolas del personal: flujo por rol, llamadas, errores y checklist |
| [`docs/api/openapi.json`](docs/api/openapi.json) | Swagger / OpenAPI de las 50 funciones: parámetros, roles, respuestas y errores |
| [`docs/arquitectura/10_pitch.md`](docs/arquitectura/10_pitch.md) | Pitch: diapositiva y guion de 1 minuto (versión web en `pitch.html`) |
| [`simulador/README.md`](simulador/README.md) | App de prueba: rutas, scripts y estructura |

Para ver el Swagger: `cd docs/api && python3 -m http.server 8766` y abre <http://127.0.0.1:8766>. Se regenera
desde la base local con `npm run openapi` (en `simulador/`).

## Estado

**Hecho:** identidad y verificación; catálogo, clínicas, horarios y festivos; trámites con folio (varios a la vez,
duplicados, bloqueo); citas (reservar, cambiar, cancelar, llegada, atendida); pagos (link, pago de prueba, cobro en
caja, reembolso marcado al cancelar); comprobante en PDF; bot de WhatsApp, código de verificación, avisos y
recordatorio de trámite pendiente; consolas de asesor, recepción, supervisor y admin; tiempo real, bandeja,
journey y métricas; cifrado, bitácora, límites y particiones; resumen para el asesor.

**Solo de demostración:**
- El pago es simulado (`PAGO_DEMO`): no hay pasarela real.
- WhatsApp usa el número de prueba de Meta: solo llega a celulares registrados y el texto libre solo dentro de 24 h.
- El esquema `simulador` (apagado en producción), las cuentas `@demo.mx` y los números con código fijo `123456`
  (vigentes hasta el 31/01/2027).

**Pendiente:**

| Pendiente | Nota |
|---|---|
| Pasarela de pagos real con `pagos-webhook` firmado | Hoy se usa `pago-demo` |
| Número propio de WhatsApp y plantillas aprobadas en Meta | Para salir del número de prueba |
| `pago_url_base` en Vault | Cuando la app esté publicada |
| Avisos por WhatsApp de cita cancelada y reprogramada | Aún no los envía el disparador de avisos |
| Cancelar y reprogramar en el bot de la Edge Function | Hoy solo en el bot Node (ver [Bot de WhatsApp](#bot-de-whatsapp)) |
| SMS de respaldo del código (Vonage) | El código está listo; falta configurar la cuenta |
| Recordatorio el día antes de la cita | Solo existe el de trámite pendiente (2 h sin actividad) |
| Resultados de estudios e integración con el sistema clínico | No existe |
| Retención de datos y cumplimiento (LFPDPPP, NOM-024, aviso de privacidad) | No evaluado |
| Plan de Supabase para operar | Hoy plan gratis (se pausa por inactividad) |

## Arranque rápido (local)

Requiere Node y Docker o Podman (detalle en [Desarrollo local](#desarrollo-local)).

```bash
cp supabase/functions/.env.example supabase/functions/.env   # una vez
cp simulador/.env.example simulador/.env.local                 # una vez
npx supabase start
npx supabase functions serve          # dejar corriendo en otra terminal
cd simulador && npm install
npm run usuarios                      # personal de prueba (repetir tras cada db reset)
npm run dev                           # http://localhost:5173  (/, /personal, /demo)
```

## Conectarse al proyecto en línea (equipo)

Proyecto de Supabase **hackathon-omnicanal** (plan gratis, us-east-1). Las apps se conectan así:

```ts
import { createClient } from '@supabase/supabase-js'
const supabase = createClient(
  'https://bdkjkmynxaphqcnapmjk.supabase.co',
  'sb_publishable_wrZ4EDTapWIzEm9WMowSSg_GG653EUj',      // clave publishable: es pública, va en la app
  { db: { schema: 'api' } },                  // todo es RPC POST: supabase.rpc('catalogo_estudios')
)
```

- Solo se expone el esquema `api` (ver "Roles y vistas" y la tabla de funciones). Las tablas no se leen directo.
- **Pacientes**: `signInAnonymously()` para catálogo y clínicas; para agendar, verificar el celular con
  `updateUser({ phone })` + `verifyOtp({ type: 'phone_change' })`. El código llega por WhatsApp.
  Para pruebas: **866 123 4567 a 866 123 4571 (52 + 10 dígitos) con código fijo `123456`** (vigentes hasta
  el 31/01/2027). Con el número de prueba de Meta, el WhatsApp real solo llega a los celulares registrados
  en la app de Meta.
- **Personal**: `asesor@demo.mx`, `recepcion@demo.mx` y `clinica@demo.mx` (Puebla centro, `PUE-CEN`),
  `admin@demo.mx`. La contraseña **no** es `demo1234`: pídesela a Eduardo (no va en el repositorio).
- Datos: 261 clínicas reales con horarios, 6 estudios de ejemplo. El simulador está apagado.
- Nunca uses la clave secreta (`sb_secret_…` / service_role) en una app: solo va en Edge Functions.
- **Pago de prueba** (`PAGO_DEMO=true` en el proyecto en línea; no hay pasarela real):
  - App: la pantalla de pago llama `supabase.functions.invoke('pago-demo', { body: { interaccion_id, referencia } })`
    con la sesión del paciente. Solo el dueño del pago; pagar dos veces responde igual (`repetido: true`).
    `api.pagos_pendientes(interaccion)` da lo que tiene por pagar (monto, estudio, para quién, referencia).
  - WhatsApp: el paciente responde **PAGAR** → "Vas a pagar $450 por …. Responde SÍ" → cita confirmada.
  - El link de pago es `<pago_url_base>/pagar/<referencia>` (secreto `pago_url_base` en Vault). Mientras la
    app no esté publicada no existe y el bot indica "responde PAGAR". Al publicarla:
    `select vault.create_secret('https://<app>', 'pago_url_base');` y la app atiende `/pagar/:referencia`.
  - Todo termina en `api.confirmar_pago` (el mismo camino del webhook real); el evento `pago_confirmado`
    lleva `simulado: true`. Con `PAGO_DEMO` apagado, `pago-demo` responde 404 y el bot ignora "PAGAR".

### Simulador: local o nube

| Comando (en `simulador/`) | Base | Qué funciona |
|---|---|---|
| `npm run dev` | Supabase local (`.env.local`) | Todo: `/`, `/personal`, `/demo`, teléfono simulado |
| `npm run dev:prod` | supabase.com (`.env.produccion`) | `/` y `/personal` contra la base en línea; `/demo` y el teléfono simulado muestran que solo existen en local |

`.env.produccion` solo tiene la URL y la clave publishable (está en el repositorio). El simulador se niega a
arrancar si recibe una clave secreta. En la nube el botón de pago es el de prueba (`pago-demo`).

## Canales

| Canal | Credencial | Entrada |
|---|---|---|
| Web / app (PWA) | JWT del paciente (anónimo o con cuenta) | `api.iniciar_sesion_paciente(p_canal)` |
| WhatsApp (agente IA) | Edge Function con clave secreta | `api.iniciar_contacto('whatsapp', tel, 'ia', 'canal')` |
| Voz con IA | Edge Function con clave secreta | `api.iniciar_contacto('call_center', tel, 'ia')` |
| Asesor de call center | JWT del asesor | `api.iniciar_contacto('call_center', tel, 'humano')` |
| Recepción de clínica | JWT de recepción | `api.iniciar_contacto('clinica', tel, 'humano')` (mostrador), `api.agenda_clinica`, `api.registrar_llegada` |
| Supervisión | JWT de supervisor/admin | `api.bandeja_atencion`, `api.buscar_pacientes`, `api.journey_paciente`, `api.metricas` |

Todas las entradas devuelven el **contexto unificado** (trámite, línea de tiempo,
mensajes, citas y pagos) según el nivel de verificación de la sesión.

## Roles y vistas (para construir las apps)

Cada app usa la clave **publicable** de Supabase y el JWT de quien la usa; la clave secreta
(`service_role`) solo vive en las Edge Functions. Todas las funciones se llaman por RPC con POST
(`supabase.rpc(...)` con `db: { schema: 'api' }`).

| Rol | Cómo entra | Canal | Qué ve y qué hace | Funciones principales |
|---|---|---|---|---|
| **Paciente** (web/app) | Supabase Auth: sesión anónima para ver catálogo; para agendar, OTP de su celular (`updateUser({ phone })` + `verifyOtp(type: 'phone_change')`, o `signInWithOtp` si el número ya tiene cuenta) | `web`, `app` | Catálogo, precios y horarios libres. Con el celular verificado: registro (nombre + apellido), sus trámites (varios, con folio y etiqueta), familiares, citas, pago, aviso por WhatsApp (casilla de consentimiento) | `iniciar_sesion_paciente`, `guardar_datos_paciente`, `registrar_consentimiento_avisos`, `iniciar_tramite`, `retomar_tramite`, `avanzar_tramite`, `reservar_cita`, `generar_pago`, `agregar_beneficiario`, `mis_beneficiarios`, `catalogo_estudios`, `clinicas_para_estudio`, `ubicaciones_clinicas`, `directorio_clinicas`, `horarios_disponibles` |
| **WhatsApp (bot)** | Edge Function `whatsapp-webhook` (clave secreta + `x-sd-telefono`) | `whatsapp` | El número ya está probado (nivel `canal`). Pide el nombre si falta, ofrece "Tienes pendiente", fechas por menú | `iniciar_contacto('whatsapp', tel, 'ia', 'canal')` y las mismas del paciente |
| **Asesor** (`asesor`) | Correo y contraseña; el JWT trae `app_metadata.rol` | `call_center` | Busca por teléfono (sesión `declarada`), verifica con OTP (`enviar-otp` → `validar_otp`), ve resumen, línea de tiempo y WhatsApp en vivo, captura el registro, toma trámites (los bloquea para otros canales), agenda y genera el pago. Cuelga con `cerrar_interaccion` | `iniciar_contacto`, `obtener_contexto`, `validar_otp`, `verificar_identidad`, `retomar_tramite`, y las del trámite |
| **Recepción** (`recepcion`, siempre con `app_metadata.clinica_id`) | Correo y contraseña | `clinica` | Solo su clínica. **Mostrador:** busca por celular, "Verificar INE" (`verificar_presencial` con `p_interaccion_id`) y opera como el asesor (agenda también para hoy). **Llegadas:** agenda del día → `registrar_llegada` (identificación de quien recibe el estudio, preparación, turno, caja o área) | `iniciar_contacto('clinica', …)`, `verificar_presencial`, `agenda_clinica`, `registrar_llegada`, `horarios_disponibles(p_inmediato => true)` |
| **Supervisor** (`supervisor`, con o sin `clinica_id`) | Correo y contraseña | `panel` | Bandeja de atención (atorados, pago por vencer, en atención, seguridad, llegadas de hoy), buscar paciente → journey, métricas y la línea de tiempo en vivo. Con clínica: solo la suya | `bandeja_atencion`, `buscar_pacientes`, `journey_paciente`, `metricas`, `tramites_en_curso` |
| **Admin** (`admin`) | Correo y contraseña | todos | Todo lo anterior, en todas las clínicas | todas |

- **Alta de personal:** fila en `core.staff` (id = usuario de Auth); un trigger copia `rol` y `clinica_id`
  al JWT (`app_metadata`). En local: `cd simulador && npm run usuarios`.
- **Tiempo real** (Broadcast privado): `paciente:<id>` para el paciente y el personal que lo atiende;
  `journey:global` para supervisión. Los mensajes llegan sin texto (están cifrados): se leen con
  `obtener_contexto`.
- **Sesión del personal:** guárdenla aparte de la del paciente (otro `storageKey` de supabase-js) y
  ciérrenla tras 30 min sin actividad, como hace el simulador en `/personal`.
- **Sesión huérfana:** tras `db reset` el token guardado puede apuntar a un usuario que ya no existe
  (`User from sub claim in JWT does not exist`). Validen con `auth.getUser()` al arrancar y, si falla,
  `signOut({ scope: 'local' })` y vuelvan a entrar.

### Niveles de verificación

| Nivel | Se obtiene con | Qué ve la sesión |
|---|---|---|
| `declarada` | Identificador de llamada | Solo que hay un trámite y en qué paso va |
| `canal` | Número de WhatsApp, sesión web anónima, cuenta solo con correo, **fecha de nacimiento** | Trámite, mensajes, citas; datos enmascarados y nombre de pila |
| `verificada` | `api.validar_otp`, o una cuenta de Auth con **teléfono confirmado** | Todo, con nombre completo |

La fecha de nacimiento nunca da `verificada`: es un dato que la familia conoce.

### Errores

| Código | HTTP | Significado |
|---|---|---|
| `42501` | 401 (anon) / 403 | Sin permiso (rol, canal o nivel de verificación insuficiente) |
| `PT404` | 404 | No existe (interacción, trámite, cita, pago) |
| `22023` | 400 | Dato inválido (incluye `horario_fuera_de_atencion` y `faltan_datos_titular` con `details.faltan`) |
| `P0001` | 400 | Regla de negocio (saltar pasos, interacción cerrada, trámite ya cerrado) |
| `PT405` | 405 | La API solo acepta POST (`Usa POST`) |
| `PT409` | 409 | Conflicto (versión, cupo, límite de beneficiarios, llave de idempotencia ajena, `tramite_duplicado`, `cita_duplicada`) |
| `PT423` | 423 | `tramite_en_atencion`: el personal (asesor o recepción, `details.canal`) tiene el trámite; se puede ver, no cambiar |
| `PT429` | 429 | Límite de solicitudes, o `demasiados_mensajes` (WhatsApp) |
| `XX000` | 500 | Falta configuración del servidor (llave de cifrado) |

Los clientes deben decidir por el campo `code` del JSON de error, no solo por el estado HTTP.

### Límites de solicitudes (PT429)

**Todas las funciones se llaman con POST** (supabase-js ya lo hace; nunca `rpc(..., { get: true })`).
PostgREST ejecuta los GET en solo lectura, donde no se puede contar, así que se rechazan con PT405
para todos los roles. Antes de cada petición, `core.verificar_peticion()` cuenta por minuto:

| Quién | Contador | Límite |
|---|---|---|
| Sin sesión (`anon`) | IP | 30 |
| Paciente | su usuario de Auth | 120 |
| Personal | su usuario de Auth | 600 |
| Edge Function (`service_role`) **con** header `x-sd-telefono` | teléfono del paciente (normalizado) | 300 (red de seguridad) |
| Mensajes **entrantes de WhatsApp** (`api.registrar_mensaje`) | teléfono del paciente | **10** (`PT429 demasiados_mensajes`; el bot responde "espera un minuto") |
| `service_role` sin ese header (pagos, workers, cron) | — | exento |

Toda Edge Function que actúe por un paciente (p. ej. el webhook de WhatsApp) debe mandar
`x-sd-telefono` con el teléfono de ese paciente. Además, algunas funciones tienen su propio límite:
3 OTP por paciente cada 10 min y 3 fechas de nacimiento equivocadas por paciente cada 15 min.

**Única excepción:** `api.reservar_cita` al rebasar 5 citas futuras no lanza excepción.
Responde HTTP 409 con `{"error": "limite_citas", "citas_futuras": 5}` y confirma la
transacción, para que el evento `limite_citas_alcanzado` quede guardado como señal antispam.

## Omnicanal en tiempo real

La paciente no tiene que "pasarse" de canal: el mismo número es el mismo paciente en todos.

- **Identidad:** en la web/app ver catálogo, precios y horarios es libre; para **iniciar un trámite** hay
  que verificar el celular con OTP (Supabase Auth). Si ese número ya tiene cuenta, el OTP inicia sesión
  con ella. Desde ahí, WhatsApp (por el número) y el call center (tras OTP) ven lo mismo.
- **Varios trámites a la vez** (p. ej. uno para ella y otro para su hijo). Cada uno tiene **folio**
  (`SD-4K7Q`) y **etiqueta** (`Mastografía · para ti`). Cada sesión trabaja con uno (`tramite_activo`);
  el contexto trae todos en `tramites_abiertos`, recientes primero. Al entrar por cualquier canal:
  "Tienes pendiente: 1) Mastografía · para ti, eligiendo clínica 2) … 3) Empezar otro".
- **Sin duplicados:** mismo estudio + misma persona con otro trámite abierto o una cita futura →
  PT409 `tramite_duplicado` / `cita_duplicada`, con el folio del existente en `details` para
  ofrecer "continuar ese". Al fusionar pacientes, el duplicado con menos actividad se cancela.
- **El asesor manda:** el trámite que un asesor abre o retoma queda bloqueado para su interacción
  10 minutos, que se renuevan con cada acción. Los demás canales lo ven pero no lo cambian:
  PT423 `tramite_en_atencion` (WhatsApp responde con la plantilla `asesor_atendiendo`; la web
  deshabilita los botones). Es por trámite: con otro trámite se sigue normal. Se libera al colgar,
  por inactividad o al vencer (`sd-liberar-atenciones`). Un segundo asesor también recibe PT423.
- **Tiempo real:** web, app y la consola escuchan el canal Broadcast privado `paciente:<id>` y se
  actualizan con un aviso de qué cambió y en qué canal. El asesor solo puede escuchar al paciente
  que está atendiendo (RLS) y ve en vivo lo que la paciente escribe por WhatsApp. Los mensajes se
  anuncian sin su texto (está cifrado): se leen con `obtener_contexto`.
- **Avisos proactivos por WhatsApp** (`avisos-whatsapp`, cada ~5 s): todo cambio de un trámite hecho
  fuera de WhatsApp, solo a teléfonos **verificados que aceptaron** avisos.
  - Dentro de la ventana de 24 h (la paciente escribió por WhatsApp): texto libre, solo de lo
    ocurrido después de que empezó a escribir.
  - Fuera de la ventana: solo plantillas (`core.plantillas_whatsapp`, simuladas como aprobadas):
    `recordatorio_tramite_pendiente`, `link_pago`, `cita_confirmada`, `asesor_atendiendo`.
    TODO: registrarlas en Meta y enviarlas con `type=template`.

- **Registro mínimo del titular** antes del primer trámite: nombre, apellido paterno (el materno es
  opcional) y **celular verificado** (posesión probada: OTP o escribir desde ese WhatsApp; un número
  dictado al asesor no cuenta hasta validar el OTP). Si falta algo, `api.iniciar_tramite` responde
  22023 `faltan_datos_titular` con `details: {"faltan": [...]}`, y el contexto trae
  `sesion.requiere_registro` (vacío = completo). Se captura con `api.guardar_datos_paciente`:
  - Web/app: pantalla "Regístrate para agendar" (nombre, apellidos, celular, OTP y casilla de avisos).
  - WhatsApp: el bot pregunta "¿A nombre de quién registramos tu cuenta?" antes del primer trámite.
  - Call center / recepción: el personal lo captura (tras validar el OTP).
  - Pacientes anteriores sin nombre: las listas del personal los muestran como `Paciente +52******4567`
    (`paciente.nombre_mostrar` en el contexto).
- **Clínicas: primero dónde, luego cuál.** Son 261 sucursales reales (`supabase/seeds/clinicasData.ts`).
  Para actualizarlas: reemplazar ese archivo, `npm run clinicas` (en `simulador/`) y `npx supabase db reset`.
  - Claves: el slug de cada sucursal (`puebla-capu`, `tijuana-centro`…). Tres conservan su clave de siempre
    porque las usan pruebas, demo y usuarios de prueba: `PUE-CEN` = Puebla (Av. 2 Pte., Centro),
    `PUE-ANG` = Puebla Angelopolis, `MTY-CEN` = Monterrey (Centro).
  - Turnos de cita = horario publicado de cada sucursal (domingo incluido si abre); sin horario publicado,
    lunes a viernes 7:00–15:00 y sábado 7:00–12:00. Zona horaria por estado (Tijuana, Hermosillo, Mazatlán,
    Chihuahua, Cancún…) y las fronterizas con la suya (Ciudad Juárez, Matamoros, Reynosa, Nuevo Laredo).
  - Web/app: estado y ciudad (`ubicaciones_clinicas`) o "📍 Cerca de mí" (las 10 más cercanas).
  - WhatsApp: "¿En qué ciudad o municipio quieres tu cita?" → lista numerada de ese lugar (máx. 12; si son más,
    pide alcaldía o colonia; "Puebla" muestra las de la ciudad). Entiende cdmx, edomex, gdl, mty… y
    "mejor en Cholula" para cambiar de lugar.
- **WhatsApp: elegir fecha por menú.** Tras la clínica, el bot pregunta "¿Qué día te gustaría?" y entiende
  hoy, mañana, pasado mañana, lunes…domingo (= el próximo; si hoy es jueves, "jueves" es el de la semana
  que entra), "26 de noviembre", "26 nov", "26/11". Responde con el menú del día
  ("Horarios del jueves 26 de noviembre en Puebla Capu:"): horas libres numeradas
  (`api.horarios_disponibles`), separadas en mañana y tarde, máximo 10 y "Ver más"; se elige con el número.
  - Día sin lugar o clínica cerrada: "Ese día no hay horarios; el próximo con lugar es el viernes 27…" y su menú.
  - Día y hora juntos ("jueves 7am", "mañana a las 10"): si está libre pide confirmación (sí/no); si no,
    muestra el menú de ese día.
  - Fechas pasadas o a más de 14 días: lo explica y vuelve a preguntar.
  - La lógica vive en funciones puras: `fechas.ts` (fechas en lenguaje natural) e `interpretar.ts`;
    "hoy" llega como parámetro (zona de México), sin leer el reloj. Pruebas: `npm run probar-bot`.
- **Recepción de clínica** (rol `recepcion`, siempre con `clinica_id`; solo canal `clinica` y solo su clínica):
  - Mostrador: `iniciar_contacto('clinica', tel, 'humano')` → "Verificar INE" (`verificar_presencial` con la
    sesión). Con la sesión verificada usa las mismas funciones que el asesor: registro, iniciar trámite,
    agendar (también para hoy), cambiar el horario de una cita no pagada (`reservar_cita` otra vez) y pago.
    El celular sigue siendo requisito para iniciar trámites: si solo lo dictó, se valida con OTP.
  - Llegadas (agenda del día, `api.agenda_clinica` trae turno, área, preparación y si ya pagó):
    "Registrar llegada" → identificación de quien recibe el estudio, "¿Cumplió la preparación?",
    turno y a dónde va (caja si no ha pagado; si paga en caja la cita sigue `en_clinica`).
  - El personal manda también aquí: lo que recepción atiende queda bloqueado (PT423 con `details.canal =
    'clinica'`; WhatsApp usa la plantilla `recepcion_atendiendo`).
  - Cada estudio tiene `area` (laboratorio, ultrasonido, rayos_x, mastografia). Las citas `en_clinica` ocupan
    cupo, cuentan para duplicados y, si están pagadas, para ingresos.
- **Trámites sin estudio:** ya no se crean. Los que hubiera de antes no aparecen en "Tienes pendiente"
  y `sd-cancelar-sin-estudio` (cada hora) los cancela a las 24 h con el evento `tramite_cancelado`
  (`motivo: sin_estudio`).

## Citas, pagos y comprobante

Estas acciones funcionan aunque el trámite ya esté cerrado (cita pagada).

| Función | Quién | Reglas |
|---|---|---|
| `api.reprogramar_cita(interaccion, cita, fecha_hora)` | Paciente, asesor, recepción, servicio | Misma clínica y estudio; cita reservada o confirmada y futura; horario distinto, con cupo, dentro de atención y con 1 h de anticipación |
| `api.cancelar_cita(interaccion, cita, motivo?)` | Paciente, asesor, recepción, servicio | Pagada → pago `reembolsado`; sin pagar → el link expira. El trámite abierto se cancela |
| `api.generar_pago(interaccion, tramite, version)` | Paciente, personal, servicio | Referencia y link `<pago_url_base>/pagar/<referencia>` (nulo si no hay app publicada) |
| `api.pagos_pendientes(interaccion)`, `api.pago_del_paciente(interaccion, referencia)` | Paciente (solo lo suyo), servicio | Lo que tiene por pagar y la pantalla de pago |
| `api.confirmar_pago(referencia, estado, datos?)` | Solo servicio | La llaman `pagos-webhook` y `pago-demo`; idempotente (`repetido: true`) |
| `api.cobrar_en_caja(cita, metodo?)` | Recepción de esa clínica, supervisor, admin | Efectivo o tarjeta; usa el pago pendiente o crea uno `CJ-…`; no se cobra dos veces; otra sucursal: 42501 |
| `api.marcar_atendida(cita)` | Recepción de esa clínica, supervisor, admin | Solo citas `en_clinica` |
| `api.comprobante_cita(interaccion, cita)` | Paciente y personal con identidad verificada | Datos del comprobante; el PDF lo dibuja la app (`simulador/src/pdf/comprobante.ts`, jsPDF) |

El personal **elige la cita antes de verificar**: sin verificar solo ve folio, fecha y estado; al verificar se abren
estudio, clínica y si está pagada.

`api.solicitar_agente` y `api.solicitudes_agente` siguen en la base, pero la web ya no ofrece "Hablar con una
persona": el paciente gestiona sus citas solo.

## Bot de WhatsApp

Hay dos formas de conectarlo. Ambas usan la misma API, así que se intercambian sin tocar la base.

| | Edge Function `whatsapp-webhook` (este repo) | Bot Node ([salud-digna-chatbot](https://github.com/IsraelCarry22/salud-digna-chatbot)) |
|---|---|---|
| Papel | La que atiende hoy a Meta | Interfaz de conversación del compañero sobre nuestra API |
| Hospedaje | Dentro de Supabase | Aparte (Docker); incluye un teléfono virtual en `:8090` |
| Credencial | Secreto de la función | `SUPABASE_SERVICE_ROLE_KEY` en su servidor, con `x-sd-telefono` |
| Agendar y pagar | Sí | Sí |
| Cancelar y reprogramar | Todavía no | Sí |

Si se decide hospedar el bot Node, el plan es que Meta siga apuntando a nuestro webhook y este le reenvíe los
mensajes. La base sigue siendo la fuente de verdad.

## Referencia de funciones

| Función | Quién | Qué hace |
|---|---|---|
| `api.agregar_beneficiario(interaccion, nombre, ap_paterno, ap_materno, fecha_nac, sexo, relacion, es_tutor_legal)` | Sesión `canal`+ | Registra a un familiar (paciente `declarado`, sin identidades). Reutiliza si el mismo titular ya lo tiene con el mismo nombre y fecha. Máximo 10 por titular |
| `api.mis_beneficiarios(interaccion)` | Sesión `canal`+ | Nombre de pila y relación; con `verificada`, también nombre completo y fecha de nacimiento |
| `api.iniciar_tramite(interaccion, estudio, beneficiario?, tipo?)` | — | Crea uno **nuevo** (conviven varios) **ya con su estudio y para quién**: nace en "elegir clínica" y la regla de duplicados (PT409) aplica desde el inicio. Sin estudio: 22023. En web/app exige teléfono verificado (OTP). Los canales preguntan primero el estudio y luego para quién |
| `api.retomar_tramite(interaccion, tramite)` | Cualquier canal `canal`+ | La sesión sigue con un trámite pendiente. Si es un asesor, lo toma (bloqueo) |
| `api.registrar_consentimiento_avisos(interaccion, acepta)` | Sesión `verificada` | Casilla "Acepto recibir avisos por WhatsApp" (con fecha y canal) |
| `api.procesar_aviso_whatsapp(...)`, `api.texto_asesor_atendiendo(...)` | Solo service_role | Usadas por `avisos-whatsapp` y el bot |
| `api.verificar_presencial(p_tipo_documento, p_interaccion_id \| p_cita_id)` | Recepción / personal | Con `p_interaccion_id` (mostrador, canal clínica): la identificación oficial sube **esa sesión** a `verificada` (método `identificacion`). Con `p_cita_id`: verifica en persona a quien recibe el estudio. Guarda solo el tipo de documento, nunca su número |
| `api.registrar_llegada(cita, tipo_documento, cumplio_preparacion)` | Recepción, supervisor, admin | Solo citas de hoy de su clínica: verifica la identificación del beneficiario, cita → `en_clinica` (`llegada_en`), turno por área y día (`A-001` laboratorio, `U-` ultrasonido, `R-` rayos X, `M-` mastografía), evento `llegada_registrada` con la respuesta de preparación. Responde turno, área, preparación, pago e `indicacion` ("Pasar a caja" / "Pasar a Ultrasonido") |
| `api.bandeja_atencion(p_clinica_id, p_categoria, p_limite, p_cursor, p_canal, p_estado, p_desde, p_hasta)` | Supervisor, admin | `{conteos, categoria, items, siguiente_cursor, filtros}`. Categorías: `atorados` (activos sin actividad > 2 h), `pago_por_vencer` (link vence < 2 h), `en_atencion` (bloqueados por personal ahora), `seguridad` (fallos y bloqueos de verificación en 24 h, por paciente), `llegadas_hoy` (en clínica sin atender). Sin categoría solo conteos; máximo 50 por página; cada renglón trae `detalle` listo para mostrar. Supervisor con clínica: solo la suya. Fechas = cuándo se inició el trámite (seguridad: cuándo ocurrió) |
| `api.buscar_pacientes(p_texto, p_limite)` | Supervisor, admin | Por folio (`SD-4K7Q`), celular (últimos 10 dígitos) o nombre (sin acentos, todas las palabras); mínimo 3 caracteres, máximo 50. Un familiar trae `titular_id` (su journey es el del titular). Queda en la bitácora de lecturas |
| `api.horarios_disponibles(..., p_inmediato)` | Público | `p_inmediato` (solo personal de clínica): incluye el horario en curso para agendar hoy a quien llega sin cita; `reservar_cita` lo acepta en el canal clínica |
| `api.avanzar_tramite` | — | `p_datos` acepta solo `estudio_id`, `clinica_id` y `beneficiario_id` (uuid); el beneficiario debe ser el titular o uno de sus beneficiarios |
| `api.reservar_cita` | — | La cita es del titular y la atiende el beneficiario del trámite; máximo 5 citas futuras por titular |
| `api.verificar_identidad` | — | Acertar la fecha de nacimiento sube la sesión solo a `canal` |
| `api.agenda_clinica` | — | Muestra a quien se atiende (beneficiario) y quién agendó |
| `api.metricas(desde, hasta, clinica)` | Supervisor/admin | Cualquier rango, comparado con el mismo periodo del año anterior (`actual`, `anio_anterior`, `variacion_pct`) |
| `api.catalogo_estudios(busqueda, categoria)` | Público (anon incluido) | Estudios activos con preparación y precio base; búsqueda sin acentos ni mayúsculas. Máx. 50 |
| `api.clinicas_para_estudio(estudio, ciudad, estado, busqueda, lat, lng, limite)` | Público | Clínicas activas que ofrecen el estudio, con precio, dirección, teléfono, `lat`/`lng`, `horario` (texto publicado), `id_externo` (id de `clinicasData.ts`) y `slug`. `busqueda`: cada palabra en nombre, ciudad, estado o dirección, sin acentos. Con `lat`+`lng` ordena por cercanía y agrega `distancia_km` (solo una: 22023 `coordenadas_invalidas`). `limite` 1–300, por omisión 50 |
| `api.directorio_clinicas(busqueda, estado, ciudad, lat, lng, limite)` | Público | Todas las clínicas activas (por omisión hasta 300: el directorio completo), mismos campos sin precio. Para el mapa / directorio de la interfaz |
| `api.ubicaciones_clinicas(estudio)` | Público | `[{estado, clinicas, ciudades: [{ciudad, clinicas}]}]`: para elegir primero estado y ciudad. Con estudio, solo donde se hace |
| `api.horarios_disponibles(clinica, estudio, desde, dias)` | Público | Horarios con cupo en la zona horaria de la clínica (1 a 14 días, máx. 100), con al menos 1 h de anticipación |
| `api.solicitar_otp(interaccion)` | Solo service_role | Envía al teléfono **registrado** de mayor confianza (no al que llama). Devuelve `codigo`, `telefono` y `telefono_enmascarado`; al asesor solo le llega lo enmascarado (Edge Function `enviar-otp`) |
| `api.reservar_cita` (horario) | — | Rechaza horas fuera de atención, no alineadas al intervalo o en día inhábil: 22023 `horario_fuera_de_atencion` |

Las 50 funciones, con todos sus parámetros, están en el [OpenAPI](docs/api/openapi.json); citas y pagos, en
[Citas, pagos y comprobante](#citas-pagos-y-comprobante).

## Resumen para el asesor (`procesar-resumenes`)

Cada evento de un trámite pide un resumen nuevo (cola `resumen_tramite`). pg_cron
(`sd-resumenes`, cada 5 s) invoca la Edge Function `procesar-resumenes`:
`api.cola_leer` → `api.material_resumen` → modelo → `api.guardar_resumen` → `api.cola_confirmar`.

- **Con LLM:** si la función tiene el secreto `ANTHROPIC_API_KEY`, Claude (`claude-opus-5-5`, esfuerzo
  bajo) escribe 2–3 líneas: para quién, estudio, clínica, paso, canales usados y qué falta, sin inventar.
  En producción: `npx supabase secrets set ANTHROPIC_API_KEY=...`; en local, en `supabase/functions/.env`.
- **Respaldo por plantilla (sin LLM):** sin clave, ante cualquier error o rechazo, o si el LLM tarda más
  de 8 s, el resumen se arma con los datos del trámite. Las demos no dependen de internet.
- El texto guardado (cifrado) empieza con `[ia]` o `[plantilla]`; la consola del asesor y el journey
  del panel lo muestran como insignia. La respuesta de la función también trae `metodo` y `motivo`.

## Cifrado a nivel columna

- Se cifran con AES-256 (`pgp_sym_encrypt`) los mensajes (`core.mensajes.contenido_cifrado`)
  y el resumen del trámite (`core.tramites.resumen_cifrado`). Cada fila guarda la versión de llave.
- Solo las funciones `api` que devuelven el dato a quien está autorizado lo descifran.
  Un `select` directo, un respaldo o una exportación solo ven bytes.
- La bitácora registra que esas columnas cambiaron, pero guarda `"[cifrado]"` en lugar del valor.
- Los embeddings para RAG o antispam se calculan **antes** de cifrar, en la Edge Function.
- Llaves en Supabase Vault: `clave_cifrado_v1`, `clave_cifrado_v2`, … En local las crea `seed.sql`
  al azar; en producción, el paso 1 de la instalación.

**Rotar la llave** (SQL Editor):

```sql
select vault.create_secret(encode(extensions.gen_random_bytes(32), 'base64'), 'clave_cifrado_v2');
select core.rotar_clave(2::smallint);
```

Lo nuevo se cifra con v2 al instante. La tarea `sd-rotacion-cifrado` re-cifra lo anterior por lotes
cada minuto; mientras tanto todo sigue legible con su llave anterior. No borres las llaves viejas.

## Métricas

`api.metricas` lee tablas permanentes (`core.metricas_tramites_diarias`, `metricas_canales_diarias`,
`metricas_citas_diarias`), no vistas de 90 días.

- **Cada 5 min** (`sd-metricas` → `core.recalcular_metricas()`) se recalculan solo los días afectados:
  días de creación de los trámites que cambiaron, días de las citas que cambiaron, más ayer y hoy.
  Los días que nadie tocó no se recalculan.
- **Reparación manual**: `select core.recalcular_metricas_rango('2026-01-01', '2026-12-31');`
- Trámites y cambios de canal se agrupan por hora de México; las citas por la hora local de la clínica.
  `ingresos` = precio de las citas pagadas (confirmada, atendida o no asistió).

## Retención

No se borra ni se archiva nada con datos de pacientes. Lo único que se limpia son los contadores
técnicos del rate limit (`core.rate_limit`, más de 1 hora) y la bandeja de pruebas del esquema `simulador`. Las particiones mensuales se crean solas
(`sd-particiones`) en el esquema `particiones`.

## Desarrollo local

Requiere Node (para `npx`) y Docker o Podman.

```bash
# Solo con Podman: exponer su socket como si fuera Docker
systemctl --user enable --now podman.socket
export DOCKER_HOST=unix:///run/user/$(id -u)/podman/podman.sock

cp supabase/functions/.env.example supabase/functions/.env   # una vez (activa MODO_SIMULADOR)
cp simulador/.env.example simulador/.env.local                 # una vez (URL y clave publicable local)

npx supabase start        # levanta todo y aplica migraciones + seed
npx supabase status       # URLs y llaves locales
npx supabase db reset     # borra todo y vuelve a aplicar migraciones + seed
npx supabase stop         # apaga (conserva los datos)
```

- **Studio** (tablas, relaciones, SQL): http://127.0.0.1:54323 →
  Database → Schema Visualizer → esquema `core`.
- **API**: http://127.0.0.1:54321/rest/v1/rpc/<función> con el header `Content-Profile: api`.
- **Base directa**: `postgresql://postgres:postgres@127.0.0.1:54322/postgres`.
- **Cambios de esquema**: siempre con una migración nueva (`npx supabase migration new <nombre> < /dev/null`),
  nunca editando las existentes. (Sin `< /dev/null` la CLI se queda esperando SQL por la entrada estándar.)
- **Edge Functions**: `npx supabase functions serve` (lee `supabase/functions/.env`, que activa
  `MODO_SIMULADOR`). Los mensajes al "teléfono" caen en la bandeja del esquema `simulador`.
- **Ojo con la CLI**: al dividir el archivo en sentencias se confunde con un `if … case … end then`
  dentro de una función, y con `--` comentarios que tengan `;` o comillas; reescribe la condición
  sin `case` (el error que da es "syntax error at end of input").
- **Fedora / SELinux**: si una función responde `BOOT_ERROR` ("failed to determine entrypoint"),
  el contenedor no puede leer la carpeta. Reetiquetarla una vez:
  `chcon -R -t container_file_t supabase/functions` (se revierte con `-t unlabeled_t`).
- **OTP por teléfono en local**: sin proveedor de SMS. El hook `[auth.hook.send_sms]` de `config.toml`
  manda el código al WhatsApp simulado (necesita `npx supabase functions serve` corriendo). Los números de
  `[auth.sms.test_otp]` (528661234567 a 528661234571) usan siempre `123456`. Nunca hagas `config push`.

## Pruebas

```bash
npx supabase test db
```

Corre las pruebas pgTAP de `supabase/tests/database/` contra la base local. Cada archivo
trabaja dentro de una transacción que se deshace al final, así que no deja datos.
Los roles se simulan igual que PostgREST: `set local role` más `request.jwt.claims`
(ver `supabase/tests/helpers.psql`).

| Archivo | Qué cubre |
|---|---|
| `001_acceso_directo` | Ninguna sesión lee core, audit ni particiones; solo 5 funciones de core son ejecutables |
| `010_recorrido_ana` | Web (OTP obligatorio) → WhatsApp ve el pendiente → call center con OTP toma el trámite → pago → app |
| `020_beneficiarios` | Una mamá agenda para su hijo; tope de 10; verificación presencial; un declarado nunca se fusiona |
| `030_varios_tramites` | Varios trámites abiertos, etiqueta y folio, duplicados (PT409), fusión sin duplicados |
| `035_atencion_asesor` | El asesor bloquea el trámite: PT423 desde WhatsApp y web, segundo asesor, se libera al colgar y al vencer |
| `038_avisos_whatsapp` | Sin consentimiento no hay avisos, ventana de 24 h, plantillas, quién escucha en tiempo real |
| `040_verificacion` | La fecha de nacimiento da `canal`, nunca `verificada` |
| `050_limite_citas` | 5 citas futuras como máximo; HTTP 409 con el evento guardado |
| `060_cifrado` | Nada legible en tablas ni bitácora; rotación de llave |
| `070_particiones_metricas` | Particiones en su esquema; recálculo incremental de métricas |
| `080_concurrencia_y_limites` | PT409 por versión, idempotencia, PT429, cupo por horario, `p_datos`, PT404 |
| `090_rate_limit_telefono` | Edge Functions: 300 por minuto por teléfono con `x-sd-telefono` (red de seguridad); sin header, exentas; GET → PT405 |
| `100_otp_destino` | El OTP va al teléfono verificado, no al que llama; solo service_role lo pide |
| `110_catalogo` | Catálogo público, búsqueda sin acentos, inactivos ocultos, rate limit de anon |
| `120_horarios` | Horario real (domingo 6:30–14:00, lunes 6:00–19:00), clínica cerrada en domingo, festivos sin horarios, horario lleno oculto, 3:00 y 9:10 rechazados, zona horaria |
| `130_simulador` | Apagado por defecto (42501), encendido funciona, limpieza a la hora |
| `140_tramite_con_estudio_y_demo` | Sin estudio no hay trámite (22023), nace en "elegir clínica", duplicados desde el inicio, los vacíos no se ofrecen y se cancelan a las 24 h; reiniciar demo y forzar recordatorio |
| `150_registro_titular` | Sin nombre/apellido/celular verificado no hay trámite (22023 `faltan_datos_titular`), `requiere_registro`, el asesor captura y valida OTP, pacientes sin nombre con teléfono enmascarado |
| `160_recepcion` | Rol con clínica obligatoria, solo canal clínica y solo su clínica, INE verifica la sesión, PT423 con plantilla de clínica, llegada: turno U-001/U-002, caja, preparación en el evento, pagar en caja sigue en clínica, solo citas de hoy |
| `170_bandeja_atencion` | Conteos de las 5 categorías, sin categoría no lista, detalle por categoría, cursor, máximo 50, filtros de canal y fechas, alcance por clínica, asesor sin acceso, búsqueda por folio/celular/nombre, mínimo 3 caracteres |
| `180_limite_mensajes_y_demo` | WhatsApp: el mensaje 11 del minuto recibe PT429, las respuestas no cuentan, cada teléfono su cupo; `adelantar_cita` solo para teléfonos de prueba; reiniciar limpia contadores |
| `190_directorio_clinicas` | 261 clínicas con id del directorio, zona horaria por estado/ciudad, horario leído del texto (sin domingo = cerrado), directorio para anon, búsqueda por varias palabras y en la dirección, cercanía con distancia, 22023 sin lng, 32 estados con sus ciudades |
| `200_codigo_auth_whatsapp` | Solo Auth ejecuta el hook, responde `{}` y encola la llamada a `enviar-codigo-auth` con el worker_token, 400 sin código, usa `new_phone` si falta `sms.phone`, 429 al sexto código en 10 min |
| `210_codigo_respaldo_sms` | Código guardado cifrado y por 10 min, si falló se devuelve una sola vez, entregado o vencido no se reenvía, 22023 con teléfono inválido, ni anon ni usuarios lo leen |
| `220_codigo_auth_sesion_reciente` | Dos sesiones esperan el mismo número: al pedir código, la vieja lo pierde (y su token), la nueva lo conserva, otros números no se tocan |
| `230_pago_demo` | Link = pago_url_base/pagar/referencia (sin él, nulo), solo el dueño ve y encuentra su pago, el personal no, solo el servidor confirma, evento con `simulado: true`, pagar dos veces es idempotente |
| `240_acciones_citas` | Reprogramar (mismo horario, fuera de horario, <1 h, ajena, conserva estado, agenda y evento con canal), cancelar con y sin pago (reembolso, link expirado, trámite abierto cancelado, completado intacto), pedir agente y verlo solo el personal, marcar atendida (llegada previa, otra clínica, doble marca) |
| `250_citas_sin_verificar` | Sin verificar el personal ve citas con folio, fecha y estado y nada más; al verificar se abre estudio y clínica |
| `260_cobro_en_caja` | Solo recepción de esa clínica cobra, efectivo o tarjeta, usa el pago del link si existe o crea uno de caja, cita confirmada (o sigue en clínica si ya llegó), trámite completado y los mismos eventos, no se cobra dos veces |
| `270_citas_con_ids` | Ids de clínica y estudio y `pagada` solo con identidad verificada; el asesor reprograma una cita pagada (trámite cerrado) y queda el evento con su canal |
| `280_comprobante_cita` | Sin verificar no hay comprobante, apartada trae pago pendiente, pagada trae método, otro paciente PT404, recepción de otra clínica 42501, cobro en caja trae efectivo y `en_caja` |

Pruebas unitarias del bot (función pura `interpretar`): `cd simulador && npm run probar-bot`
(o `deno test supabase/functions/whatsapp-webhook/`).

Para agregar una prueba: un archivo nuevo en `supabase/tests/database/` que empiece con
`create extension if not exists pgtap with schema extensions;`, luego `begin;`,
`select plan(N);`, `\ir ../helpers.psql`, las pruebas, `select finish();` y `rollback;`.

## Simulador

Una sola app (Vite + React) que usa la API real. `cd simulador && npm install && npm run dev` →
http://localhost:5173 (necesita `npx supabase start`, `npx supabase functions serve` y
`npm run usuarios`).

| Ruta | Qué es |
|---|---|
| `/` | Sitio del paciente (web/app): catálogo, registro con OTP de cualquier celular (el código aparece en el WhatsApp simulado que se abre al lado; 866 123 4567 a 4571: código fijo 123456), trámites, citas y comprobante en PDF. En el pie, la liga discreta **Acceso personal** |
| `/personal` | Consola del personal. Se carga solo al entrar (lazy), con su propia sesión (`storageKey` `sd-personal`) y cierre automático tras 30 min sin actividad. El rol decide las pestañas: asesor → Call center; recepción → Recepción; supervisor → Supervisión; admin → las tres |
| `/demo` | Los 4 canales lado a lado (paciente, teléfono simulado, personal, supervisión siempre visible) y los escenarios para el jurado |

Usuarios de prueba (contraseña `demo1234`): `asesor@demo.mx`, `recepcion@demo.mx` (Puebla Centro),
`clinica@demo.mx` (supervisora de Puebla Centro), `admin@demo.mx`.

**Escenarios de `/demo`** (narración en pantalla, pausa de 1.5 s por paso, sin depender de internet:
sin LLM el resumen sale por plantilla):

1. **Recorrido de Ana:** web (registro, OTP, avisos, estudio y clínica) → WhatsApp ("hola", "Tienes
   pendiente", día y hora por menú) → llamada (OTP; la asesora ve resumen y línea de tiempo, toma el
   trámite) → pago → app (cita confirmada) → llegada a la clínica (INE, preparación, turno).
2. **Mamá agenda para su hijo:** su hijo como beneficiario, dos trámites abiertos con su etiqueta,
   pago y en la clínica se verifica la identificación del hijo.
3. **El asesor manda:** durante la llamada Ana escribe por WhatsApp; su trámite está bloqueado
   (PT423 + plantilla) pero avanza otro; al colgar se libera y se le avisa.
4. **Duplicado y recordatorio:** el mismo estudio para la misma persona → "continuar ese" (web y
   WhatsApp); se deja inactivo y llega el recordatorio por plantilla.

**↺ Reiniciar demo** llama a `simulador.reiniciar_demo()`: borra solo los datos de los teléfonos de
prueba (y sus familiares, mensajes, colas y contadores). Utilidades de demo, también solo para
teléfonos de prueba: `simulador.adelantar_cita(folio)` (la cita pasa a este momento para mostrar la
llegada) y `simulador.forzar_recordatorio(folio)`. Todas exigen el simulador encendido (42501 si no).

## Esquema simulador (solo pruebas)

Bandeja del "teléfono" del simulador: ahí caen los OTP, los links de pago y las respuestas del bot
cuando las Edge Functions corren con `MODO_SIMULADOR=true`.

- `simulador.leer(telefono, despues_de)`: cualquiera la puede llamar (anon incluido) y ve los mensajes
  de **cualquier** teléfono. Por eso solo funciona con `simulador.config.habilitado = true`, que solo
  enciende `seed.sql`; ninguna función api permite cambiarlo.
- `simulador.enviar(...)`: solo service_role (las Edge Functions).
- Solo se expone en la API local (`config.toml`); nada dura más de 1 hora (`sd-simulador-limpieza`).

## Prueba de rendimiento

Contra la base local (ojo: carga 100 mil pacientes; después corre `npx supabase db reset`):

```bash
DB=supabase_db_salud-digna-db   # contenedor de la base (podman ps / docker ps)
podman cp tests/20_carga_volumen.sql $DB:/tmp/ && podman exec $DB psql -U postgres -f /tmp/20_carga_volumen.sql
podman cp tests/21_pgbench_contacto.sql $DB:/tmp/ && \
  podman exec $DB pgbench -U postgres -h localhost -n -c 8 -j 4 -T 20 -f /tmp/21_pgbench_contacto.sql postgres
```

Resultado en una laptop (i7-10750H, Supabase local en Podman), con 100 mil pacientes y 2 M de eventos:
**9.5 ms promedio, 841 operaciones/s, 0 errores** en `api.iniciar_contacto` con 8 clientes.

## Instalar en Supabase

1. Crear la llave de cifrado de columnas **antes** de aplicar las migraciones
   (SQL Editor del proyecto). Se genera dentro de la base, así que nunca pasa
   por tu terminal, el repositorio ni el historial:
   ```sql
   select vault.create_secret(encode(extensions.gen_random_bytes(32), 'base64'),
                              'clave_cifrado_v1', 'Llave de cifrado de columnas v1');
   ```
   - No la borres nunca: sin ella los mensajes y resúmenes cifrados con v1 son ilegibles.
   - Si falta, cualquier operación que cifre o descifre falla con
     `Falta la llave de cifrado clave_cifrado_v1 en Supabase Vault` (HTTP 500).
   - Rotar: ver [Cifrado](#cifrado-a-nivel-columna).
2. Enlazar el proyecto y aplicar las migraciones:
   ```bash
   supabase link --project-ref <ref>
   supabase db push                      # aplica supabase/migrations en orden
   ```
   - **No ejecutar `seed.sql` en producción**: trae datos ficticios y enciende el simulador,
     que deja leer los OTP de cualquier teléfono.
   - El esquema `simulador` llega con las migraciones pero queda **apagado** (sus funciones
     responden 42501). Se puede borrar completo:
     `drop schema simulador cascade; select cron.unschedule('sd-simulador-limpieza');`
   - Cargar el catálogo real (`core.estudios`, `core.clinica_estudios`) y los festivos (`core.dias_inhabiles`).
     Las clínicas y sus **horarios de atención** se pueden cargar con `supabase/seeds/clinicas.sql`
     (no trae nada ficticio ni enciende nada). Sin horarios, una clínica no ofrece horarios ni acepta reservas.
3. Guardar los secretos que usa la base para llamar a las Edge Functions (workers y hook del código).
   `worker_token` es un secreto aleatorio propio (no la clave de Supabase): el **mismo valor** va en Vault
   y en el secreto `WORKER_TOKEN` de las funciones (en local, sin `WORKER_TOKEN`, se usa la clave de servicio):
   ```sql
   select vault.create_secret('https://<ref>.supabase.co', 'project_url');
   select vault.create_secret('<secreto aleatorio>', 'worker_token');
   ```
   ```bash
   supabase secrets set WORKER_TOKEN=<el mismo secreto>
   ```
4. Dashboard → Settings → Data API → **Exposed schemas**: dejar solo `api` (nunca `simulador`).
5. Dashboard → Authentication:
   - Activar **Anonymous sign-ins** (la web empieza sin cuenta).
   - Activar el proveedor **Phone** con **Confirm phone activado** (no hace falta Twilio ni
     ningún proveedor de SMS: el código lo manda el hook del punto siguiente). Es obligatorio: si está apagado, Auth marca un teléfono nuevo
     como confirmado sin OTP, y como `core.vincular_identidades_auth` confía en
     `phone_confirmed_at`, cualquier sesión web podría apropiarse del historial de otro paciente.
   - **Hooks → Send SMS → Postgres**: esquema `hooks`, función `enviar_codigo_auth`. Así el código
     del celular llega por WhatsApp (ver "Código de verificación por WhatsApp"). Revisar en
     Rate Limits el máximo de mensajes por hora (es para todo el proyecto).
6. Dar de alta al personal: crear el usuario en Auth e insertarlo en `core.staff`;
   un trigger copia su rol al JWT (`app_metadata.rol`).
7. Edge Functions: `supabase functions deploy` y sus secretos
   (`supabase secrets set NOMBRE=valor`). **`MODO_SIMULADOR` no debe existir en producción.**

   | Variable | Función | Para qué |
   |---|---|---|
   | `WHATSAPP_APP_SECRET` | whatsapp-webhook | Verificar la firma `X-Hub-Signature-256` de Meta |
   | `WHATSAPP_VERIFY_TOKEN` | whatsapp-webhook | Verificación GET al registrar el webhook en Meta |
   | `PAGOS_WEBHOOK_SECRET` | pagos-webhook | Verificar el header `x-firma` (HMAC-SHA256 del cuerpo) |
   | `PAGO_DEMO` | pago-demo, whatsapp-webhook | `true` = pago de prueba sin pasarela (por omisión apagado) |
   | `WORKER_TOKEN` | avisos-whatsapp, procesar-resumenes, enviar-codigo-auth | Igual a `worker_token` de Vault: solo la base puede invocarlas |
   | `WHATSAPP_TOKEN` | todas las que envían | Token de acceso de WhatsApp Cloud API (usuario del sistema de Meta Business) |
   | `WHATSAPP_PHONE_NUMBER_ID` | todas las que envían | Id del número que envía (en Meta → WhatsApp → API Setup) |
   | `WHATSAPP_PLANTILLA_OTP` | enviar-codigo-auth, enviar-otp | Nombre de la plantilla de **Autenticación** aprobada (botón "Copiar código") |
   | `WHATSAPP_IDIOMA` | enviar-codigo-auth, enviar-otp | Idioma de esa plantilla (por omisión `es_MX`) |
   | `CANAL_CODIGO` | enviar-codigo-auth, enviar-otp | `whatsapp_y_sms` (por omisión), `whatsapp` o `sms` |
   | `VONAGE_API_KEY`, `VONAGE_API_SECRET`, `VONAGE_REMITENTE` | enviar-codigo-auth, enviar-otp, whatsapp-webhook | SMS de respaldo del código (Vonage; remitente = número o nombre que envía) |

   Sin su secreto, cada webhook responde 401 (salvo en `MODO_SIMULADOR`). Sin `WHATSAPP_TOKEN` y
   `WHATSAPP_PHONE_NUMBER_ID`, enviar falla de forma explícita (un código no enviado no parece enviado).

### Código de verificación por WhatsApp

La web/app verifica el celular con Supabase Auth (`updateUser({ phone })` o `signInWithOtp({ phone })`).
Auth genera el código y, en vez de mandarlo por SMS, llama al **Send SMS Hook**
`hooks.enviar_codigo_auth` (función de Postgres, solo la ejecuta Auth). Esta revisa el límite
(5 códigos por teléfono cada 10 minutos → 429) y pide a la Edge Function `enviar-codigo-auth`
(por `pg_net`, con `project_url` y `worker_token` de Vault, igual que los workers) que lo entregue:

**WhatsApp y, si falla, SMS** (`CANAL_CODIGO=whatsapp_y_sms`, el de omisión):
- Si el envío por WhatsApp da error (token, plantilla, número inválido), el código sale por SMS al momento.
- Si el número no tiene WhatsApp, Meta acepta el envío y avisa segundos después por el webhook
  (`statuses: failed`). Para mandar entonces el **mismo** código por SMS, se guarda mientras tanto en
  `core.codigos_enviados`: cifrado, máximo 10 minutos, de un solo uso (se borra al llegar "entregado" o
  "fallido") y solo para service_role (`api.registrar_codigo_enviado`, `api.resolver_codigo_enviado`).
- El SMS se manda con Vonage (sin Twilio). En el simulador llega a la bandeja como "Código (SMS)".
- El código que pide el asesor (`enviar-otp`) usa el mismo camino.
- Si la paciente recarga la página mientras espera el código, queda otra sesión anónima esperando el mismo
  número y Auth verificaría contra la vieja ("token has expired or is invalid"). El hook se lo quita a las
  demás sesiones: siempre gana la que pidió el código al último.

- **Local** (`MODO_SIMULADOR=true`): llega al WhatsApp simulado del simulador, **con cualquier número**.
  Los números `528661234567`–`528661234571` siguen con código fijo `123456` (los usan los escenarios de `/demo`).
- **Producción**: WhatsApp Cloud API de Meta, con la plantilla de autenticación. Para probar sin esperar
  aprobaciones, Meta da un número de prueba que puede enviar a hasta 5 teléfonos registrados en la app;
  para el público hay que registrar un número propio y que Meta apruebe la plantilla (puede tardar días).
  El resto de los mensajes (bot, links, avisos) se envían como texto: Meta solo los entrega dentro de
  las 24 h desde el último mensaje del paciente.

## Estructura

```
supabase/
  config.toml                               configuración local (API expone solo el esquema api)
  migrations/
    20261124000100_base.sql                 extensiones, esquemas, UUIDv7, actor, auditoría, particiones
    20261124000200_catalogos_identidad.sql  clínicas, estudios, personal, pacientes e identidades
    20261124000300_tramites_eventos.sql     trámites, sesiones, eventos, mensajes, citas, pagos, agenda
    20261124000400_motor_contexto.sql       vinculación y fusión, sesiones por canal, contexto unificado
    20261124000500_api.sql                  API pública (RPC) para canales y panel
    20261124000600_rag_conocimiento.sql     base de conocimiento con pgvector + búsqueda híbrida
    20261124000700_procesos_asincronos.sql  colas, resumen con IA, recordatorios, expiración
    20261124000800_seguridad.sql            rate limit, permisos, RLS, tiempo real
    20261124000900_tareas_programadas.sql   pg_cron
    20261124001000_permisos_service_role.sql           pre-request también para service_role
    20261124145122_beneficiarios_continuidad_estructura.sql  titular/beneficiario (y códigos de continuidad, ya retirados)
    20261124150342_beneficiarios_continuidad_funciones.sql   funciones de beneficiarios y verificación
    20261124151135_cifrado_columnas.sql      cifrado de mensajes y resúmenes, rotación de llave
    20261124151929_particiones_y_metricas.sql esquema particiones, métricas permanentes, p_datos acotado
    20261124162837_errores_no_encontrado_404.sql "no existe" responde HTTP 404 (PT404 en vez de P0002)
    20261124164413_rate_limit_por_telefono.sql   rate limit de Edge Functions por teléfono (x-sd-telefono)
    20261124165913_solo_post.sql             la API solo acepta POST (GET/HEAD → PT405)
    20261124165916_otp_destino.sql           el OTP va al teléfono registrado de mayor confianza
    20261124165919_catalogo.sql              api.catalogo_estudios, api.clinicas_para_estudio
    20261124165922_horarios_atencion.sql     horarios de atención, días inhábiles, api.horarios_disponibles
    20261124165925_simulador_bandeja.sql     ⚠️ solo pruebas: esquema simulador (apagado por defecto)
    20261124192520_omnicanal_tramites.sql    varios trámites con folio, duplicados, bloqueo del asesor, tiempo real
    20261124192524_omnicanal_avisos_whatsapp.sql  consentimiento, ventana de 24 h, plantillas y cola de avisos
    20261124204210_tramite_nace_con_estudio_y_demo.sql  el trámite nace con estudio; reinicio y recordatorio de demo
    20261125000057_registro_titular.sql      nombre + apellido + celular verificado antes del primer trámite
    20261125001957_recepcion_clinica.sql     rol recepcion, INE en mostrador, llegada con turno por área, en_clinica
    20261125003528_bandeja_atencion.sql      bandeja de supervisión, búsqueda de pacientes, evento verificacion_bloqueada
    20261125014248_limite_mensajes_y_demo.sql  10 mensajes de WhatsApp por minuto, simulador.adelantar_cita
    20261125045534_directorio_clinicas.sql   teléfono, coordenadas y horario de cada clínica; búsqueda y cercanía
    20261125052220_codigo_auth_whatsapp.sql  Send SMS Hook: el código del celular va por WhatsApp
    20261125053539_codigo_respaldo_sms.sql   si WhatsApp no lo entrega, el mismo código por SMS
    20261125063632_codigo_auth_sesion_reciente.sql  al pedir código, solo esa sesión queda esperando el número
    20261125082051_pago_demo.sql             link de pago configurable (pago_url_base), pagos_pendientes, pago simulado
    20261125114816_acciones_citas.sql        marcar_atendida, cancelar_cita, reprogramar_cita, solicitar_agente, solicitudes_agente
    20261125123609_contexto_citas_sin_verificar.sql  el personal ve citas por folio y fecha antes de verificar identidad
    20261125124957_cobro_en_caja.sql         recepción cobra en caja (efectivo o tarjeta) una cita apartada sin pagar
    20261125131032_citas_con_ids.sql         ya verificada, la cita trae ids de clínica y estudio y si está pagada
    20261125151322_comprobante_cita.sql      api.comprobante_cita: datos del comprobante de pago y cita (PDF en la app)
  functions/                                Edge Functions (Deno)
    whatsapp-webhook/                       webhook de WhatsApp Cloud API + agente guiado (interpretar.ts, fechas.ts)
    enviar-otp/                             el asesor pide un OTP; el código va al teléfono del paciente
    pagos-webhook/                          aviso del proveedor de pagos → api.confirmar_pago
    enviar-recordatorios/                   worker: vacía la cola de recordatorios (el aviso sale por avisos-whatsapp)
    avisos-whatsapp/                        worker: entrega a WhatsApp lo que pasa en otros canales
    procesar-resumenes/                     worker: resumen del trámite para el asesor (Claude o plantilla)
    enviar-codigo-auth/                     entrega el código de verificación de Auth (hook): WhatsApp y, si falla, SMS
    pago-demo/                              pago de prueba sin pasarela (solo con PAGO_DEMO=true)
    _shared/                                clientes de Supabase, envío al paciente, HTTP
  seeds/clinicasData.ts                     directorio de las 261 clínicas (el mismo que usa la interfaz)
  seeds/clinicas.sql                        GENERADO (npm run clinicas en simulador/): clínicas + horarios de atención
  seed.sql                                  ⚠️ solo local: estudios de ejemplo, precios, llave, simulador encendido
  tests/
    helpers.psql                            utilidades compartidas de las pruebas
    database/*.sql                          pruebas pgTAP (npx supabase test db)
tests/
  20_carga_volumen.sql                      carga de 100 mil pacientes y 2 M de eventos
  21_pgbench_contacto.sql                   prueba de carga de api.iniciar_contacto
simulador/                                  app de prueba (/, /personal; /demo solo local); ver su README
  scripts/                                  usuarios de prueba, clínicas, OpenAPI y recorrido de la API
docs/
  arquitectura/                             documentación de arquitectura y pitch
  api/                                      openapi.json y visor Swagger UI
  GUIA_APP_PWA.md                           guía para la app del paciente y las consolas
```

Esquemas: `api` es la única superficie pública (funciones RPC). `core` tiene las tablas y la
lógica interna, `audit` la bitácora inmutable y `particiones` las particiones mensuales. Ninguna
sesión (`anon`, `authenticated`, `service_role`) puede leer tablas directamente. `simulador` existe
solo para el simulador local (ver [Simulador](#esquema-simulador-solo-pruebas)).
