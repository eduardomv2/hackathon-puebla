# 8. Bitácora de decisiones

Formato: **decisión → por qué → qué se descartó**. Sirve para defender el diseño ante preguntas.

## 8.1 Arquitectura

| # | Decisión | Por qué | Alternativa descartada |
|---|---|---|---|
| D1 | **Toda la lógica de negocio en la base** (funciones `api.*`), las apps solo pintan | Varias apps de distintas personas; una sola versión de cada regla | Lógica duplicada en cada app o en un backend aparte |
| D2 | **Solo se expone el esquema `api`**, solo RPC por **POST** | Superficie mínima; los GET corren en solo lectura y no permiten contar el límite de solicitudes | Exponer tablas con RLS; permitir GET |
| D3 | **Esquemas separados** `api`, `core`, `audit`, `particiones`, `hooks`, `simulador` | Públicas vs internas, y lo que solo es de pruebas queda aislado y apagable | Todo en `public` |
| D4 | **Una migración nueva por cambio + prueba pgTAP**; nunca se edita una ya aplicada | Historial reproducible y revisable | Editar el esquema a mano o reescribir migraciones |
| D5 | **El simulador existe pero apagado en producción** (`habilitado=false`) | Poder demostrar en local sin riesgo en la nube | Código de prueba en producción sin interruptor |
| D6 | **Clave secreta jamás en el navegador**; lo que la necesita va por Edge Function | Una clave de servicio filtrada abre toda la base | Llamar desde la app con clave de servicio |

## 8.2 Identidad y privacidad

| # | Decisión | Por qué | Descartado |
|---|---|---|---|
| D7 | **Niveles de verificación** (`declarada`, `canal`, `verificada`) y recorte automático del contexto | Un número dictado no prueba nada; hay que dar solo lo necesario | Logueado/no logueado |
| D8 | La **fecha de nacimiento nunca da `verificada`** | La conoce la familia | Aceptarla como prueba |
| D9 | **OTP por WhatsApp** mediante el Send SMS Hook, con **SMS de respaldo** (el mismo código) | Sin proveedor de SMS obligatorio; el paciente ya usa WhatsApp | Twilio como único canal |
| D10 | **Confirmar teléfono obligatorio** en Auth | Si no, un teléfono nuevo se marca confirmado sin código y alguien podría apropiarse de un historial | Dejarlo apagado |
| D11 | **Cifrado de columnas** en mensajes y resúmenes, llave en Vault, rotable por lotes | Un respaldo o un `select` no deben mostrar conversaciones | Cifrado solo de disco |
| D12 | **No se borra nada de pacientes**; los triggers bloquean `DELETE` (excepto reinicio de demo) | Trazabilidad y evidencia | Borrado físico / retención automática |
| D13 | **Registro mínimo del titular** (nombre, apellido, celular verificado) antes del primer trámite | Evita trámites anónimos imposibles de contactar | Trámite sin datos |

## 8.3 Omnicanal

| # | Decisión | Por qué | Descartado |
|---|---|---|---|
| D14 | **Un trámite por paciente**, con **folio** (`SD-4K7Q`) y etiqueta; varios a la vez | La mamá agenda para ella y para su hijo | Una sola sesión por paciente |
| D15 | **El trámite nace con estudio** (se eliminaron los trámites vacíos) | Los vacíos ensuciaban "Tienes pendiente" | Crear trámite al abrir la app |
| D16 | **El personal manda**: bloqueo del trámite 10 min (`PT423`) | Evitar que paciente y asesor se pisen | Último en escribir gana |
| D17 | **Concurrencia optimista** con `version` y `PT409` | Sin bloqueos largos entre canales | Bloqueos pesimistas |
| D18 | **Duplicados, cupo y límite de 5 citas dentro de la base** | Una regla para todos los canales | Validar en cada app |
| D19 | **Avisos solo a teléfonos verificados que aceptaron**, dentro de la regla de 24 h de Meta (texto) o con plantilla | Cumplir con Meta y privacidad | Avisar a cualquier número |
| D20 | **Recepción solo opera su clínica** (`clinica_id` en el JWT) | Control de caja y de datos por sucursal. Se confirmó mantenerlo | Recepción global |
| D21 | **Ver citas por folio y fecha antes de verificar identidad** (personal) | Poder elegir la cita primero y verificar después | Ver todo solo tras verificar |
| D22 | **Cobro en caja** (`api.cobrar_en_caja`) deja la cita, el pago y el trámite como un pago en línea | Una cita apartada sin pagar se cobra en recepción | Obligar a pagar en línea |
| D23 | **Admin/asesor/recepción pueden cambiar horario y cobrar** desde la cita | Evitar pasos por canales distintos | Solo el paciente |
| D24 | **Se quitó "Hablar con una persona"** de la interfaz (queda `solicitar_agente` en la base) | Es lo mismo que pedir las citas y modificar | Mantener la opción |
| D25 | Reprogramar exige ≥ 1 h de anticipación; cancelar cita pagada = `reembolsado` | Regla de negocio clara | Cambios libres |

## 8.4 Infraestructura y operación

| # | Decisión | Por qué | Descartado |
|---|---|---|---|
| D26 | **Supabase** como plataforma | Ver [comparación](07_por_que_supabase.md) | Firebase, backend propio, AWS, Azure |
| D27 | **Plan gratis** y nada de pago | Restricción del equipo; si algo indispensable lo exige, se avisa | Servicios de pago |
| D28 | **El bot de WhatsApp vive en Supabase** (`whatsapp-webhook`) en vez de hospedarlo | Cero infraestructura, mismo despliegue; el bot Node del compañero es compatible vía la misma API | Hospedar un servidor para el bot |
| D29 | **Pago de prueba** (`PAGO_DEMO=true`) | No hay pasarela real; el mismo camino (`confirmar_pago`) servirá con una real | Pagos falsos fuera de la API |
| D30 | **Workers disparados desde la base** (`pg_cron` + `pg_net` con `worker_token`) | Sin servidor de colas aparte; solo la base puede invocarlos | Cron externo |
| D31 | **Si un mensaje de WhatsApp no se entrega, no se corta la conversación**: se registra `entrega: fallida` | Un fallo de Meta no debe tumbar el flujo | Abortar la respuesta |
| D32 | **El simulador local y la nube conviven** (`npm run dev` / `dev:prod`) | Demostrar contra la nube real sin perder el laboratorio local | Solo uno de los dos |
| D33 | **Credenciales del equipo en un archivo ignorado por git**; secretos de servidor **no** se comparten con la app | Evitar fugas y que la app se salte la API | Escribir secretos en el README |
| D34 | **Foco en la web contra la nube**; lo local solo al final | Lo que ve el equipo es la nube | Mantener ambos al mismo ritmo |

## 8.5 Cambios de rumbo documentados

| Cambio | Qué pasó |
|---|---|
| Rediseño oscuro con cristal → revertido | "Se ve muy feo"; se volvió al diseño claro |
| Códigos de continuidad | Se implementaron y luego se **retiraron** (siguen en el historial de migraciones) |
| Conflicto de API | Regla del equipo: si algo choca con la API actual, **se pregunta antes de cambiar la base** |
