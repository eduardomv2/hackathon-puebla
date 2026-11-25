// Genera docs/api/openapi.json a partir de la base (firmas, tipos, valores por omisión y permisos) más las
// descripciones de este archivo. Uso: npm run openapi (necesita la base local encendida).
import postgres from 'postgres'
import { writeFileSync } from 'node:fs'

const sql = postgres(process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres')

type Meta = { tag: string; resumen: string; desc: string; roles: string; sale: string; errores?: string[] }
const T = {
  sesion: 'Sesión y contexto', catalogo: 'Catálogo (público)', tramite: 'Trámite', cita: 'Citas', pago: 'Pagos',
  paciente: 'Datos y verificación', personal: 'Personal (asesor y recepción)', sup: 'Supervisión', srv: 'Servicio (Edge Functions y workers)',
} as const
const CTX = 'Contexto unificado (sesion, paciente, tramite_activo, tramites_abiertos, citas_proximas, linea_tiempo, ...). Lo que trae depende del nivel de verificación.'

const META: Record<string, Meta> = {
  iniciar_sesion_paciente: { tag: T.sesion, resumen: 'Abrir la sesión del paciente (web o app)', roles: 'paciente',
    desc: 'Crea o retoma la interacción del paciente autenticado. Con sesión anónima el nivel es `canal`; con celular confirmado en Auth, `verificada`.', sale: CTX },
  iniciar_contacto: { tag: T.sesion, resumen: 'Abrir un contacto por un canal', roles: 'servicio, asesor, recepcion, supervisor, admin',
    desc: 'Busca o crea al paciente por su celular y abre una interacción. WhatsApp usa `servicio` con `p_agente=ia` y `p_nivel=canal`; call center usa `asesor` (nivel `declarada`); mostrador usa `recepcion` con canal `clinica`. Exige el header `x-sd-telefono` cuando lo llama un servicio.', sale: CTX },
  obtener_contexto: { tag: T.sesion, resumen: 'Leer el contexto de una interacción', roles: 'paciente, servicio, asesor, recepcion, supervisor, admin',
    desc: 'Devuelve lo que la sesión puede ver según su nivel de verificación. Sin verificar, el personal ve solo las citas con folio, fecha y estado.', sale: CTX },
  cerrar_interaccion: { tag: T.sesion, resumen: 'Cerrar la interacción (colgar)', roles: 'dueño de la interacción',
    desc: 'Cierra la interacción y libera el bloqueo de atención de los trámites que tenía tomados.', sale: 'Sin cuerpo.' },
  registrar_mensaje: { tag: T.sesion, resumen: 'Guardar un mensaje de la conversación', roles: 'servicio, paciente, personal',
    desc: 'Guarda el mensaje cifrado. Los mensajes entrantes de WhatsApp tienen un tope de 10 por minuto por teléfono (`PT429 demasiados_mensajes`).', sale: 'Id del mensaje (uuid).', errores: ['PT429'] },
  registrar_consentimiento_avisos: { tag: T.sesion, resumen: 'Aceptar o rechazar avisos por WhatsApp', roles: 'paciente, servicio',
    desc: 'Sin consentimiento no se envían avisos proactivos. Requiere teléfono verificado.', sale: 'Estado del consentimiento.' },

  catalogo_estudios: { tag: T.catalogo, resumen: 'Estudios disponibles', roles: 'público (anon incluido)',
    desc: 'Lista estudios activos con precio base y preparación. Búsqueda sin acentos.', sale: 'Lista de estudios (id, clave, nombre, categoría, preparación, duración, precio_base).' },
  clinicas_para_estudio: { tag: T.catalogo, resumen: 'Clínicas que ofrecen un estudio', roles: 'público',
    desc: 'Filtra por estado, ciudad, texto o cercanía (`p_lat` y `p_lng` devuelven las más cercanas con `distancia_km`). Trae precio, horario y zona horaria.', sale: 'Lista de clínicas.' },
  directorio_clinicas: { tag: T.catalogo, resumen: 'Directorio de las 261 clínicas', roles: 'público', desc: 'Directorio con teléfono, coordenadas y horario publicado.', sale: 'Lista de clínicas.' },
  ubicaciones_clinicas: { tag: T.catalogo, resumen: 'Estados y ciudades con clínicas', roles: 'público', desc: 'Para el selector «primero dónde, luego cuál».', sale: 'Estados con sus ciudades y conteos.' },
  horarios_disponibles: { tag: T.catalogo, resumen: 'Horarios con cupo', roles: 'público (`p_inmediato` solo recepcion, supervisor, admin)',
    desc: 'Horas libres por clínica y estudio dentro del horario de atención, sin festivos y con cupo. `p_inmediato` incluye horarios de hoy (mostrador).', sale: 'Lista de horarios (fecha_hora, fecha, hora, disponibles).' },

  iniciar_tramite: { tag: T.tramite, resumen: 'Iniciar un trámite de agendar estudio', roles: 'paciente, servicio, personal',
    desc: 'El trámite nace con estudio y folio. Pide el registro del titular (nombre, apellido y celular verificado): si falta, `22023 faltan_datos_titular` con `details.faltan`. Evita duplicados (`PT409 tramite_duplicado`).', sale: 'Trámite creado (id, folio, paso_actual, version).', errores: ['PT409'] },
  avanzar_tramite: { tag: T.tramite, resumen: 'Avanzar un paso del trámite', roles: 'paciente, servicio, personal',
    desc: 'Cambia de paso con control de versión (`PT409` si otro canal lo movió) y llave de idempotencia opcional.', sale: 'Trámite actualizado con la nueva version.', errores: ['PT409', 'PT423'] },
  retomar_tramite: { tag: T.tramite, resumen: 'Retomar un trámite pendiente', roles: 'dueño de la interacción',
    desc: 'La sesión trabaja con este trámite. Si lo hace personal, queda bloqueado 10 minutos para otros canales.', sale: CTX },
  mis_beneficiarios: { tag: T.tramite, resumen: 'Familiares registrados', roles: 'paciente, servicio, personal verificado', desc: 'Titular y beneficiarios para agendar por otra persona.', sale: 'Lista de beneficiarios.' },
  agregar_beneficiario: { tag: T.tramite, resumen: 'Registrar a un familiar', roles: 'paciente, servicio, personal verificado',
    desc: 'Máximo 10 por titular (`PT409`). Reutiliza al familiar si ya existía.', sale: 'Beneficiario (beneficiario_id, reutilizado).', errores: ['PT409'] },

  reservar_cita: { tag: T.cita, resumen: 'Reservar una cita', roles: 'paciente, servicio, personal',
    desc: 'Valida horario de atención, cupo (`PT409 horario_sin_cupo`) y duplicados (`PT409 cita_duplicada`). Con más de 5 citas futuras responde HTTP 409 con `{"error":"limite_citas"}` y guarda el evento.', sale: 'Trámite con la cita y la nueva version.', errores: ['PT409', 'PT423'] },
  reprogramar_cita: { tag: T.cita, resumen: 'Cambiar fecha u hora', roles: 'paciente, servicio, asesor, recepcion',
    desc: 'Misma clínica y estudio. Al menos 1 hora de anticipación, dentro del horario de atención, con cupo y distinto del actual. Solo citas reservada o confirmada y futuras.', sale: '`{cita_id, estado, fecha_hora, folio}`.', errores: ['PT409'] },
  cancelar_cita: { tag: T.cita, resumen: 'Cancelar una cita', roles: 'paciente, servicio, asesor, recepcion',
    desc: 'Si estaba pagada, el pago queda `reembolsado`. Si no, el link expira. El trámite abierto se cancela.', sale: '`{cita_id, estado, reembolso, folio}`.' },
  marcar_atendida: { tag: T.cita, resumen: 'Marcar la cita como atendida', roles: 'recepcion (su clínica), supervisor, admin',
    desc: 'La cita debe estar `en_clinica`.', sale: '`{cita_id, estado: "atendida"}`.' },
  comprobante_cita: { tag: T.cita, resumen: 'Datos del comprobante de pago y cita', roles: 'paciente, servicio, personal (identidad verificada)',
    desc: 'Todo lo que lleva el PDF: folio, paciente, estudio, preparación, clínica, fecha en la zona de la clínica y pago con método. Sin identidad verificada: `42501`. Recepción solo de su clínica.', sale: 'Comprobante (folio, cita, titular, paciente, estudio, clinica, pago).', errores: ['PT404'] },

  generar_pago: { tag: T.pago, resumen: 'Generar el pago de la cita', roles: 'paciente, servicio, personal',
    desc: 'Crea el pago pendiente con referencia y link (`<pago_url_base>/pagar/<referencia>`; nulo si la app aún no está publicada).', sale: 'Pago (pago_id, referencia, monto, moneda, link_pago, expira_en, version).' },
  pagos_pendientes: { tag: T.pago, resumen: 'Pagos por pagar del paciente', roles: 'paciente, servicio', desc: 'Referencia, monto, estudio, para quién y vencimiento.', sale: 'Lista de pagos por pagar.' },
  pago_del_paciente: { tag: T.pago, resumen: 'Consultar un pago por referencia', roles: 'paciente (solo el suyo), servicio',
    desc: 'Lo usa la pantalla de pago. El personal no lo consulta por aquí.', sale: '`{referencia, estado, monto, moneda, estudio, folio, expira_en, vencido}`.' },
  cobrar_en_caja: { tag: T.pago, resumen: 'Cobrar en caja una cita apartada', roles: 'recepcion (su clínica), supervisor, admin',
    desc: 'Usa el pago pendiente o crea uno de caja (`CJ-…`). Deja cita confirmada (o en_clinica), trámite completado y los mismos eventos que un pago en línea. Otra clínica: `42501`.', sale: '`{pago_id, estado, monto, metodo, cita_id, folio}`.' },
  confirmar_pago: { tag: T.pago, resumen: 'Confirmar un pago (pasarela o pago de prueba)', roles: 'servicio',
    desc: 'Lo llaman `pagos-webhook` (firma HMAC) y `pago-demo`. Idempotente: pagar dos veces responde igual con `repetido: true`.', sale: '`{estado, repetido?}`.' },

  guardar_datos_paciente: { tag: T.paciente, resumen: 'Registrar o completar los datos del titular', roles: 'paciente, servicio, personal verificado',
    desc: 'Nombre, apellidos, nacimiento y sexo. Requisito antes del primer trámite.', sale: CTX },
  verificar_identidad: { tag: T.paciente, resumen: 'Verificar con fecha de nacimiento', roles: 'paciente, servicio',
    desc: 'Da nivel `canal`, nunca `verificada`. 3 intentos fallidos cada 15 min bloquean temporalmente (`PT429`).', sale: CTX, errores: ['PT429'] },
  validar_otp: { tag: T.paciente, resumen: 'Validar el código que el paciente dicta', roles: 'asesor, recepcion, servicio',
    desc: 'Sube la sesión a `verificada`.', sale: CTX },
  verificar_presencial: { tag: T.paciente, resumen: 'Verificar con la identificación en mostrador', roles: 'recepcion, asesor, supervisor, admin',
    desc: 'Con `p_interaccion_id` y `p_tipo_documento` verifica esa sesión. Con `p_cita_id` verifica al beneficiario de la cita.', sale: CTX },

  agenda_clinica: { tag: T.personal, resumen: 'Agenda del día de una clínica', roles: 'recepcion (su clínica), asesor, supervisor, admin',
    desc: 'Citas del día con turno, área, preparación y si ya pagó.', sale: 'Lista de citas.' },
  registrar_llegada: { tag: T.personal, resumen: 'Registrar la llegada del paciente', roles: 'recepcion (su clínica), supervisor, admin',
    desc: 'Identificación de quien recibe el estudio, preparación cumplida, turno por área y a dónde ir (caja si no ha pagado). La cita pasa a `en_clinica`.', sale: 'Llegada (turno, área, pago).' },
  solicitar_agente: { tag: T.personal, resumen: 'Pedir una persona (sin interfaz hoy)', roles: 'dueño de la interacción', desc: 'Registra el evento `agente_solicitado`. La interfaz ya no lo ofrece.', sale: '`{solicitado, mensaje}`.' },
  solicitudes_agente: { tag: T.personal, resumen: 'Solicitudes de agente sin atender', roles: 'asesor, supervisor, admin', desc: 'Últimas 12 horas.', sale: 'Lista de solicitudes.' },

  bandeja_atencion: { tag: T.sup, resumen: 'Bandeja de atención', roles: 'supervisor, admin',
    desc: 'Cinco categorías: `atorados`, `pago_por_vencer`, `en_atencion`, `seguridad`, `llegadas_hoy`. Sin categoría devuelve conteos. Paginación por cursor, máximo 50.', sale: 'Conteos o lista de la categoría.' },
  buscar_pacientes: { tag: T.sup, resumen: 'Buscar paciente', roles: 'supervisor, admin', desc: 'Por folio, celular o nombre.', sale: 'Lista de pacientes.' },
  journey_paciente: { tag: T.sup, resumen: 'Recorrido completo de un paciente', roles: 'supervisor, admin', desc: 'Línea de tiempo con canales, resumen y eventos.', sale: 'Journey.' },
  tramites_en_curso: { tag: T.sup, resumen: 'Trámites abiertos', roles: 'supervisor, admin', desc: 'Filtros por clínica y paso.', sale: 'Lista de trámites.' },
  metricas: { tag: T.sup, resumen: 'Métricas por rango de fechas', roles: 'supervisor, admin', desc: 'Lee tablas permanentes recalculadas cada 5 minutos: trámites, canales y citas (ingresos = citas pagadas).', sale: 'Métricas por día.' },

  solicitar_otp: { tag: T.srv, resumen: 'Generar el OTP que se manda al paciente', roles: 'servicio', desc: 'Lo usa `enviar-otp`. Va al teléfono de mayor confianza. 3 por paciente cada 10 min.', sale: 'Código y destino.', errores: ['PT429'] },
  registrar_codigo_enviado: { tag: T.srv, resumen: 'Guardar un código enviado (respaldo SMS)', roles: 'servicio', desc: 'Cifrado, 10 minutos, un solo uso.', sale: 'Sin cuerpo.' },
  resolver_codigo_enviado: { tag: T.srv, resumen: 'Resolver el estado de un código enviado', roles: 'servicio', desc: 'Si Meta avisa que falló, devuelve el código una sola vez para mandarlo por SMS.', sale: 'Estado.' },
  cola_leer: { tag: T.srv, resumen: 'Leer mensajes de una cola', roles: 'servicio', desc: 'Colas `resumen_tramite`, `recordatorios`, `avisos_whatsapp`.', sale: 'Mensajes.' },
  cola_confirmar: { tag: T.srv, resumen: 'Confirmar un mensaje de cola', roles: 'servicio', desc: 'Lo borra de la cola.', sale: 'Booleano.' },
  material_resumen: { tag: T.srv, resumen: 'Material para el resumen del asesor', roles: 'servicio', desc: 'Lo lee `procesar-resumenes`.', sale: 'Datos del trámite.' },
  guardar_resumen: { tag: T.srv, resumen: 'Guardar el resumen (cifrado)', roles: 'servicio', desc: 'Empieza con `[ia]` o `[plantilla]`.', sale: 'Sin cuerpo.' },
  procesar_aviso_whatsapp: { tag: T.srv, resumen: 'Decidir el aviso de WhatsApp de un evento', roles: 'servicio', desc: 'Solo a teléfonos verificados que aceptaron, con texto en ventana de 24 h o plantilla fuera de ella.', sale: 'Aviso a enviar.' },
  texto_asesor_atendiendo: { tag: T.srv, resumen: 'Texto cuando un asesor tiene el trámite', roles: 'servicio', desc: 'Para responder `PT423` en WhatsApp.', sale: 'Texto.' },
  kb_guardar_documento: { tag: T.srv, resumen: 'Cargar un documento a la base de conocimiento', roles: 'servicio, admin', desc: 'Fragmentos con embedding (pgvector).', sale: 'Id del documento.' },
  buscar_conocimiento: { tag: T.srv, resumen: 'Búsqueda híbrida en la base de conocimiento', roles: 'servicio, personal, paciente', desc: 'Texto más vector.', sale: 'Fragmentos con puntaje.' },
}

const PARAMS: Record<string, { d: string; enum?: string[] }> = {
  p_interaccion_id: { d: 'Id de la interacción: `sesion.interaccion_id` del contexto.' },
  p_tramite_id: { d: 'Id del trámite.' }, p_cita_id: { d: 'Id de la cita.' }, p_clinica_id: { d: 'Id de la clínica.' }, p_estudio_id: { d: 'Id del estudio.' },
  p_version: { d: 'Versión del trámite que viste. Si otro canal lo cambió: `PT409`.' },
  p_canal: { d: 'Canal.', enum: ['web', 'app', 'whatsapp', 'call_center', 'clinica'] },
  p_telefono: { d: 'Celular con lada país: 52 y 10 dígitos.' },
  p_agente: { d: 'Quién atiende.', enum: ['ia', 'humano'] },
  p_nivel: { d: 'Nivel inicial de verificación.', enum: ['declarada', 'canal', 'verificada'] },
  p_metodo: { d: 'Método de cobro en caja.', enum: ['efectivo', 'tarjeta'] },
  p_fecha_hora: { d: 'Fecha y hora con zona (ISO 8601). Usa un `fecha_hora` de `horarios_disponibles`.' },
  p_motivo: { d: 'Motivo, opcional.' }, p_referencia: { d: 'Referencia del pago.' },
  p_estado: { d: 'Estado.' }, p_tipo_documento: { d: 'Tipo de identificación.', enum: ['ine', 'pasaporte', 'licencia', 'cedula_profesional', 'cartilla_militar', 'acta_nacimiento', 'curp', 'otro'] },
  p_relacion: { d: 'Relación con el titular.', enum: ['hijo', 'hija', 'madre', 'padre', 'conyuge', 'otro'] },
  p_sexo: { d: 'Sexo.', enum: ['F', 'M', 'X'] },
  p_direccion: { d: 'Dirección del mensaje.', enum: ['entrante', 'saliente'] },
  p_autor: { d: 'Quién lo escribió.', enum: ['paciente', 'agente_ia', 'asesor', 'sistema'] },
  p_categoria: { d: 'Categoría.' },
  p_clave_idempotencia: { d: 'Llave para reintentar sin duplicar.' }, p_datos: { d: 'Datos adicionales (objeto).' },
  p_fecha_nacimiento: { d: 'Fecha de nacimiento.' }, p_limite: { d: 'Máximo de resultados.' }, p_codigo: { d: 'Código de 6 dígitos.' },
  p_lat: { d: 'Latitud para ordenar por cercanía.' }, p_lng: { d: 'Longitud para ordenar por cercanía.' },
  p_inmediato: { d: 'Incluir horarios de hoy (solo mostrador).' }, p_acepta: { d: 'Acepta avisos por WhatsApp.' },
  p_es_tutor_legal: { d: 'El titular es tutor legal.' }, p_cumplio_preparacion: { d: 'El paciente cumplió la preparación.' },
  p_resultado: { d: 'Resultado de la interacción.' }, p_busqueda: { d: 'Texto de búsqueda (sin acentos).' }, p_texto: { d: 'Texto de búsqueda.' },
}

const tipo = (t: string): Record<string, unknown> => {
  const b = t.toLowerCase()
  if (b === 'uuid') return { type: 'string', format: 'uuid' }
  if (b.startsWith('timestamp')) return { type: 'string', format: 'date-time' }
  if (b === 'date') return { type: 'string', format: 'date' }
  if (b === 'integer' || b === 'bigint' || b === 'smallint') return { type: 'integer' }
  if (b === 'double precision' || b === 'numeric') return { type: 'number' }
  if (b === 'boolean') return { type: 'boolean' }
  if (b === 'jsonb' || b === 'json') return { type: 'object' }
  if (b === 'vector') return { type: 'array', items: { type: 'number' }, description: 'Embedding' }
  return { type: 'string' }
}
const parseArgs = (s: string) => {
  const out: { n: string; t: string; def?: string }[] = []
  let dep = 0, cur = ''
  for (const ch of s) { if (ch === '(') dep++; if (ch === ')') dep--; if (ch === ',' && !dep) { out.push(cur.trim() as never); cur = '' } else cur += ch }
  if (cur.trim()) out.push(cur.trim() as never)
  return (out as unknown as string[]).map((a) => {
    const [izq, def] = a.split(/ DEFAULT /i)
    const sp = izq.trim().indexOf(' ')
    return { n: izq.trim().slice(0, sp), t: izq.trim().slice(sp + 1), def: def?.replace(/::[\w\s]+$/, '').replace(/^'|'$/g, '') }
  })
}
const HTTP: Record<string, [string, string]> = {
  '42501': ['403', 'Sin permiso: rol, nivel de verificación o alcance de clínica insuficientes (401 si no hay sesión).'],
  PT404: ['404', 'No existe (interacción, trámite, cita o pago).'],
  '22023': ['400', 'Dato inválido (incluye `horario_fuera_de_atencion` y `faltan_datos_titular`).'],
  P0001: ['400', 'Regla de negocio (saltar pasos, interacción cerrada, ya pagada…).'],
  PT409: ['409', 'Conflicto: versión, cupo, duplicado, límite de beneficiarios.'],
  PT423: ['423', '`tramite_en_atencion`: el personal tiene el trámite; se puede ver pero no cambiar.'],
  PT429: ['429', 'Límite de solicitudes o `demasiados_mensajes`.'],
}

const filas = await sql<{ proname: string; args: string; res: string; anon: boolean; auth: boolean; srv: boolean }[]>`
  select p.proname, pg_get_function_arguments(p.oid) as args, pg_get_function_result(p.oid) as res,
         has_function_privilege('anon', p.oid, 'execute') as anon,
         has_function_privilege('authenticated', p.oid, 'execute') as auth,
         has_function_privilege('service_role', p.oid, 'execute') as srv
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'api' order by 1`
await sql.end()

const faltan = filas.filter((f) => !META[f.proname]).map((f) => f.proname)
if (faltan.length) throw new Error('Sin descripción en META: ' + faltan.join(', '))
const sobran = Object.keys(META).filter((k) => !filas.some((f) => f.proname === k))
if (sobran.length) throw new Error('META de funciones que ya no existen: ' + sobran.join(', '))

const S = (props: Record<string, unknown>) => ({ type: 'object', properties: props })
const str = (example?: string, extra: object = {}) => ({ type: 'string', ...(example ? { example } : {}), ...extra })
const num = (example: number) => ({ type: 'number', example })
const schemas: Record<string, unknown> = {
  Contexto: S({
    sesion: S({ interaccion_id: str('0192…', { format: 'uuid' }), canal: str('web'), nivel_verificacion: str('verificada', { enum: ['declarada', 'canal', 'verificada'] }), requiere_verificacion: { type: 'boolean' }, requiere_registro: { type: 'array', items: { type: 'string' }, description: 'Vacío = registro completo' } }),
    paciente: S({ nombre: str('Ana Pérez'), nombre_mostrar: str(), telefono: str('+52 866 123 4567') }),
    tramite_activo: { type: 'object', nullable: true, description: 'El trámite con el que trabaja esta sesión: id, folio, paso_actual, version, estudio, clinica, beneficiario, resumen.' },
    tramites_abiertos: { type: 'array', items: { type: 'object' }, description: 'Todos los trámites abiertos, recientes primero.' },
    citas_proximas: { type: 'array', items: { $ref: '#/components/schemas/CitaProxima' }, description: 'Sin verificar solo trae id, folio, fecha_hora y estado.' },
    pagos_pendientes: { type: 'array', items: S({ id: str(), monto: num(450), link_pago: str(), expira_en: str(), folio: str('SD-4K7Q') }) },
    linea_tiempo: { type: 'array', items: { type: 'object' } }, mensajes_recientes: { type: 'array', items: { type: 'object' } },
  }),
  CitaProxima: S({
    id: str('0192…', { format: 'uuid' }), folio: str('SD-4K7Q'), fecha_hora: str('2026-11-27T16:30:00Z'),
    estado: str('confirmada', { enum: ['reservada', 'confirmada', 'en_clinica'] }), estudio: str('Biometría hemática'), clinica: str('Puebla Centro'),
    precio: num(450), clinica_id: str(), estudio_id: str(), pagada: { type: 'boolean' }, turno: str('U-001'), area: str('Laboratorio'),
    beneficiario: S({ id: str(), nombre: str('Luis'), relacion: str('hijo') }),
  }),
  Pago: S({ pago_id: str('', { format: 'uuid' }), referencia: str('PD-9F3A2B'), monto: num(450), moneda: str('MXN'), link_pago: str('https://app/pagar/PD-9F3A2B', { nullable: true }), expira_en: str(), version: { type: 'integer' } }),
  CobroCaja: S({ pago_id: str(), estado: str('pagado'), monto: num(450), metodo: str('efectivo', { enum: ['efectivo', 'tarjeta'] }), cita_id: str(), folio: str('SD-4K7Q') }),
  CitaCancelada: S({ cita_id: str(), estado: str('cancelada'), reembolso: { type: 'boolean' }, folio: str('SD-4K7Q') }),
  PagoDelPaciente: S({ referencia: str('PD-9F3A2B'), estado: str('pendiente'), monto: num(450), moneda: str('MXN'), estudio: str(), folio: str(), expira_en: str(), vencido: { type: 'boolean' } }),
  Comprobante: S({
    folio: str('SD-4K7Q'), emitido_en: str(), titular: str('Ana Pérez López'),
    paciente: S({ nombre: str('Luis Pérez Ruiz'), relacion: str('hijo') }),
    cita: S({ id: str(), estado: str('confirmada'), fecha_hora: str('2026-11-27T16:30:00Z'), turno: str(undefined, { nullable: true }), precio: num(450) }),
    estudio: S({ nombre: str('Biometría hemática'), preparacion: str('Ayuno de 8 horas', { nullable: true }), duracion_min: { type: 'integer', example: 15 }, area: str('Laboratorio') }),
    clinica: S({ nombre: str('Puebla Centro'), direccion: str(), ciudad: str('Puebla'), estado: str('Puebla'), telefono: str(), zona_horaria: str('America/Mexico_City') }),
    pago: S({ referencia: str('CJ-A1B2C3D4E5F6'), estado: str('pagado', { enum: ['pendiente', 'pagado', 'fallido', 'expirado', 'reembolsado'] }), monto: num(450), moneda: str('MXN'), pagado_en: str(), metodo: str('efectivo', { enum: ['efectivo', 'tarjeta', 'en_linea', 'en_linea_prueba'], nullable: true }), en_caja: { type: 'boolean' }, simulado: { type: 'boolean' } }),
  }),
  Error: undefined,
}
const RESP: Record<string, unknown> = {
  iniciar_sesion_paciente: { $ref: '#/components/schemas/Contexto' }, iniciar_contacto: { $ref: '#/components/schemas/Contexto' }, obtener_contexto: { $ref: '#/components/schemas/Contexto' },
  retomar_tramite: { $ref: '#/components/schemas/Contexto' }, guardar_datos_paciente: { $ref: '#/components/schemas/Contexto' }, verificar_identidad: { $ref: '#/components/schemas/Contexto' },
  validar_otp: { $ref: '#/components/schemas/Contexto' }, verificar_presencial: { $ref: '#/components/schemas/Contexto' },
  generar_pago: { $ref: '#/components/schemas/Pago' }, cobrar_en_caja: { $ref: '#/components/schemas/CobroCaja' }, cancelar_cita: { $ref: '#/components/schemas/CitaCancelada' },
  pago_del_paciente: { $ref: '#/components/schemas/PagoDelPaciente' }, comprobante_cita: { $ref: '#/components/schemas/Comprobante' },
  pagos_pendientes: { type: 'array', items: { type: 'object', properties: { referencia: { type: 'string' }, monto: { type: 'number' }, estudio: { type: 'string' }, etiqueta: { type: 'string' }, folio: { type: 'string' }, fecha_hora: { type: 'string' }, expira_en: { type: 'string' }, link_pago: { type: 'string', nullable: true } } } },
}
const paths: Record<string, unknown> = {}
for (const f of filas) {
  const m = META[f.proname]
  const args = f.args ? parseArgs(f.args) : []
  const props: Record<string, unknown> = {}
  const req: string[] = []
  for (const a of args) {
    const info = PARAMS[a.n]
    props[a.n] = { ...tipo(a.t), ...(info ? { description: info.d } : {}), ...(info?.enum ? { enum: info.enum } : {}), ...(a.def && a.def !== 'NULL' ? { default: a.def } : {}) }
    if (a.def === undefined) req.push(a.n)
  }
  const quien = [f.anon && 'anon', f.auth && 'authenticated', f.srv && 'service_role'].filter(Boolean).join(', ')
  const errs = new Set<string>(['42501', ...(m.errores ?? [])])
  if (req.length) errs.add('22023')
  const responses: Record<string, unknown> = {
    '200': { description: m.sale, content: f.res === 'void' ? undefined : { 'application/json': { schema: RESP[f.proname] ?? (f.res.startsWith('TABLE') ? { type: 'array', items: { type: 'object' } } : tipo(f.res.replace(/^SETOF /, ''))) } } },
  }
  if (f.res === 'void') responses['204'] = { description: m.sale }
  for (const c of [...errs]) { const h = HTTP[c]; if (h) responses[h[0]] = { description: h[1], content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } } } }
  responses['429'] ??= { description: HTTP.PT429[1], content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } } }
  paths['/' + f.proname] = {
    post: {
      tags: [m.tag], summary: m.resumen, operationId: f.proname,
      description: `${m.desc}\n\n**Quién puede llamarla:** ${m.roles}.\n\n**Credenciales con permiso de ejecución:** ${quien}.`,
      'x-roles': m.roles,
      parameters: [{ $ref: '#/components/parameters/ContentProfile' }],
      requestBody: { required: req.length > 0, content: { 'application/json': { schema: { type: 'object', properties: props, ...(req.length ? { required: req } : {}) } } } },
      responses,
    },
  }
}
const tags = Object.values(T).map((name) => ({ name }))
const doc = {
  openapi: '3.0.3',
  info: {
    title: 'API del orquestador omnicanal Salud Digna',
    version: '1.0.0',
    description: [
      'Todo el negocio vive en la base. Cada función del esquema `api` es un endpoint **POST** con cuerpo JSON (PostgREST).',
      '',
      '**Reglas**',
      '- Solo POST. Un GET responde `PT405`.',
      '- Cabeceras: `apikey` (clave publishable) y `Authorization: Bearer <JWT>`. Con supabase-js basta `createClient(url, publishable, { db: { schema: "api" } })`.',
      '- La clave secreta (`service_role`) **nunca** va en un navegador: solo en Edge Functions o servidores.',
      '- Decide por el campo `code` del error, no por el texto.',
      '- Mande el header `x-sd-telefono` cuando un servicio actúa por un paciente (límite por teléfono).',
      '',
      '**¿Por qué todo es POST?** Es una decisión de diseño. Cada función de la base se expone como RPC y el verbo no significa «leer» o «escribir», solo «ejecutar». PostgREST corre los GET en una transacción de solo lectura, donde no se puede contar el límite de solicitudes por minuto (`core.verificar_peticion()` escribe un contador); permitirlos dejaría saltarse los límites, así que responden `PT405`. Además casi toda función registra algo (bloqueo de la interacción, eventos, contadores). Lo que se pierde: la semántica REST clásica y la caché HTTP del catálogo, que a esta escala no hace falta; si algún día se requiere, se puede poner una Edge Function con caché delante del catálogo público.',
      '',
      '**Niveles de verificación:** `declarada` (solo ve que hay un trámite), `canal` (datos enmascarados) y `verificada` (todo).',
      '',
      '**Límites por minuto:** anónimo 30 (IP), paciente 120, personal 600, servicio 300 por teléfono.',
      '',
      'Guía de uso por rol: `docs/GUIA_APP_PWA.md`. Generado de la base con `npm run openapi` (en `simulador/`).',
    ].join('\n'),
  },
  servers: [
    { url: 'https://bdkjkmynxaphqcnapmjk.supabase.co/rest/v1/rpc', description: 'Nube (proyecto hackathon-omnicanal)' },
    { url: 'http://127.0.0.1:54321/rest/v1/rpc', description: 'Local (supabase start)' },
  ],
  tags,
  security: [{ apikey: [], bearer: [] }],
  paths,
  components: {
    securitySchemes: {
      apikey: { type: 'apiKey', in: 'header', name: 'apikey', description: 'Clave publishable (`sb_publishable_…`).' },
      bearer: { type: 'http', scheme: 'bearer', bearerFormat: 'JWT', description: 'JWT del usuario (Supabase Auth) o la clave de servicio en servidores.' },
    },
    parameters: {
      ContentProfile: { name: 'Content-Profile', in: 'header', required: true, schema: { type: 'string', enum: ['api'], default: 'api' }, description: 'Esquema expuesto. supabase-js lo agrega con `db.schema`.' },
    },
    schemas: {
      ...Object.fromEntries(Object.entries(schemas).filter(([, v]) => v)),
      Error: {
        type: 'object', properties: {
          code: { type: 'string', example: 'PT409', description: '42501, PT404, 22023, P0001, PT409, PT423, PT429, PT405' },
          message: { type: 'string', example: 'horario_sin_cupo' }, details: { type: 'string', nullable: true }, hint: { type: 'string', nullable: true },
        },
      },
    },
  },
}
writeFileSync(new URL('../../docs/api/openapi.json', import.meta.url), JSON.stringify(doc, null, 2) + '\n')
console.log(`openapi.json: ${filas.length} funciones, ${tags.length} grupos`)
