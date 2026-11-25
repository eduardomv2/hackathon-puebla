# 7. Por qué Supabase

> Comparación **cualitativa**. No se incluyen precios: cambian y deben verificarse en cada proveedor.
> Se compara contra las alternativas que un equipo normalmente consideraría para este problema.

## 7.1 Qué necesitaba el proyecto

| Necesidad | Por qué importa en un orquestador omnicanal |
|---|---|
| Base **relacional** con transacciones | Cupos, pagos y estados no pueden quedar a medias |
| **Reglas dentro de la base** | Varias apps escritas por distintas personas no deben reimplementarlas |
| Autenticación con **OTP por celular** y roles | Identidad por niveles y personal por rol |
| **Tiempo real** | El asesor ve en vivo lo que el paciente hace en otro canal |
| **Colas y tareas programadas** | Avisos, recordatorios, resúmenes, expiración |
| **Funciones de servidor** para webhooks | WhatsApp, pagos |
| **Búsqueda semántica** (vectores) | Agente con base de conocimiento |
| Cifrado y **secretos** | Datos de salud |
| **Sin costo** y arranque rápido | Hackathon: días, no semanas |
| **Salida fácil** | No quedar atrapados |

## 7.2 Comparación

| Criterio | **Supabase** | **Firebase** | **Backend propio** (Node + PostgreSQL hospedado) | **AWS** (RDS + Lambda + API Gateway + Cognito) | **Azure** (SQL/Postgres + Functions + AD B2C) |
|---|---|---|---|---|---|
| Modelo de datos | PostgreSQL relacional | NoSQL de documentos | PostgreSQL (o lo que elijas) | PostgreSQL/MySQL | SQL Server o PostgreSQL |
| Transacciones y restricciones (cupo, duplicados) | Nativas, con SQL | Limitadas; hay que simular con reglas y transacciones de documento | Nativas | Nativas | Nativas |
| Lógica en la base (funciones, triggers) | Sí, es PostgreSQL completo | No; va en Cloud Functions | Sí, pero hay que decidir y mantener | Sí | Sí |
| API lista | Sí (PostgREST: cada función es un endpoint) | Sí (SDK, reglas de seguridad) | **La escribes tú** | **La armas** (API Gateway + Lambda) | **La armas** |
| Auth con OTP de celular + hook propio | Incluido; el hook permite mandar el código por WhatsApp | Incluido (verifica por SMS de pago) | **Lo construyes** o integras | Cognito (SMS vía servicio de pago) | Entra External ID / AD B2C (SMS) |
| Seguridad por fila (RLS) y roles en JWT | Sí, en la base | Reglas propias, otro lenguaje | Lo programas | IAM + lo tuyo | RLS en SQL Server / lo tuyo |
| Tiempo real | Incluido (Broadcast, con autorización por RLS) | Excelente | Lo construyes (WebSockets) | AppSync/IoT, aparte | SignalR, aparte |
| Colas / cron / HTTP desde la base | `pgmq`, `pg_cron`, `pg_net` incluidos | Cloud Tasks/Scheduler aparte | Lo montas (BullMQ, cron) | SQS/EventBridge aparte | Service Bus aparte |
| Vectores (RAG) | `pgvector` en la misma base | Servicio aparte | Extensión si la instalas | Aurora pgvector / otros | Extensiones/otros |
| Cifrado y secretos | `pgcrypto` + Vault | Gestor de claves aparte | Lo eliges tú | KMS + Secrets Manager | Key Vault |
| Pruebas de la base | pgTAP, base local idéntica en un contenedor | Emuladores parciales | Lo que montes | LocalStack / parcial | Emuladores parciales |
| Tiempo para tener algo funcionando | **Horas/días** | Horas, pero el modelo no encaja | Semanas | Semanas | Semanas |
| Opción sin pago para arrancar | Plan gratis | Plan gratis (con límites) | Hospedaje gratis limitado | Capa gratuita temporal | Créditos temporales |
| Dependencia del proveedor | **Baja**: es PostgreSQL estándar; se puede llevar a otro Postgres | **Alta**: modelo y reglas propietarios | Ninguna | Media-alta (servicios propios) | Media-alta |
| Operación que te toca | Poca | Poca | **Toda** | Mucha (configuración) | Mucha |
| Control fino/cumplimiento corporativo | Medio (opción autoalojada o plan empresarial) | Medio | **Total** | **Total** | **Total** (habitual en corporativo/salud) |

## 7.3 Por qué descartamos cada alternativa

- **Firebase:** el problema es relacional (citas con cupo, pagos, duplicados, fusión de pacientes). En un modelo de
  documentos esas garantías se simulan con código y se rompen con concurrencia. Además, las reglas viven en un
  lenguaje propietario y la salida es costosa.
- **Backend propio:** es el camino más flexible, pero obliga a construir y mantener la API, la autenticación, el tiempo
  real, las colas y el despliegue. En un hackathon eso es el 80 % del tiempo sin aportar al problema de negocio.
- **AWS / Azure:** son lo correcto para una operación grande con equipo de infraestructura, pero montar el equivalente
  (API Gateway, funciones, colas, auth, secretos, redes) cuesta semanas y exige conocimiento específico. Siguen siendo
  una **ruta de salida válida** (ver 7.5).

## 7.4 Lo que Supabase nos dio concretamente

| Pieza usada | Qué resolvió |
|---|---|
| PostgreSQL 17 | Transacciones, restricciones, particiones, funciones en PL/pgSQL |
| PostgREST | 56 funciones convertidas en endpoints sin escribir un servidor |
| Auth + Send SMS Hook | OTP por WhatsApp (con SMS de respaldo) sin proveedor de SMS obligatorio |
| Realtime Broadcast privado | Línea de tiempo en vivo con autorización por RLS |
| `pgmq` + `pg_cron` + `pg_net` | Resúmenes, avisos, recordatorios y expiraciones dentro de la propia base |
| Edge Functions (Deno) | Webhooks de WhatsApp y pagos, workers |
| Vault | Llaves de cifrado y secretos de la base |
| `pgvector` | Base de conocimiento para el agente |
| CLI + base local en contenedor | Mismo entorno en cada laptop, migraciones versionadas, `db reset` y pgTAP |

## 7.5 Riesgos reales de Supabase (y cómo se mitigan)

| Riesgo | Detalle | Mitigación |
|---|---|---|
| Plan gratis | Se **pausa** tras una semana sin actividad; cómputo compartido; sin respaldo con recuperación puntual | Para operar de verdad: plan de pago; mientras tanto, avisar al equipo y reactivar |
| Cumplimiento | No evaluado para datos clínicos reales (LFPDPPP, NOM-024) | Revisión formal antes de producción; hay opción de autoalojar |
| Límites de Realtime y Edge Functions | Dependen del plan; arranque en frío | Medir con carga real; mantener los webhooks pequeños |
| Región | El proyecto está en us-east-1 | Elegir región cercana a México al pasar a producción |
| Lógica en SQL | Menos gente la domina que Node; depuración distinta | 392 pruebas pgTAP, migraciones versionadas, documentación (esta carpeta) |
| Acoplamiento a extensiones propias | `pgmq`, `pg_cron`, Vault, `realtime.send` | Están aisladas en pocas funciones (`despachar_worker`, `cola_*`, broadcast); se reemplazan sin tocar las reglas de negocio |

**Estrategia de salida:** todo el negocio es SQL estándar más extensiones de uso común. Para migrar a RDS/Azure
Postgres/otro: exportar con `pg_dump`, reemplazar Auth por Cognito/otro (los roles ya viajan como claims del JWT),
reemplazar Edge Functions por Lambda/Functions (son TypeScript de fetch), y reemplazar `pgmq/pg_cron` por SQS/cron.
**Las reglas de negocio y las pruebas se conservan.**

## 7.6 Conclusión para el jurado

> Elegimos Supabase porque el problema es **relacional y de reglas** (cupo, pagos, identidad, concurrencia), y
> PostgreSQL es la herramienta correcta para eso. Supabase nos regaló la infraestructura alrededor (API, auth,
> tiempo real, colas, funciones) y nos dejó dedicar el tiempo a lo que importa: **una sola fuente de verdad para
> todos los canales**. Como es PostgreSQL estándar, no nos ata: si la operación crece o la normativa lo exige,
> la misma base y las mismas pruebas pueden vivir en otro proveedor o en infraestructura propia.
