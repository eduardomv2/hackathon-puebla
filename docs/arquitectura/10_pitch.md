# Pitch: un solo cerebro, todos los canales

> El paciente cambia de canal y el sistema sigue donde se quedó.

## Diapositiva

| Un paciente, un trámite | Reglas en un solo lugar | Seguro y probado |
|---|---|---|
| WhatsApp, web, llamada y clínica comparten el mismo trámite, con versión y bloqueo. | 50 funciones en la base. Un canal nuevo solo llama a la API. | Verificación por WhatsApp, RLS y auditoría. 403 pruebas y 38 migraciones. |

9.5 ms por operación · 841 ops/s con 100 mil pacientes · API en Swagger · PostgreSQL estándar.

## Guion de 1 minuto

Un paciente empieza a agendar por WhatsApp, sigue en la web y paga en la clínica. Normalmente repetiría sus datos en cada paso. Aquí no.

Construimos un orquestador único sobre Supabase y PostgreSQL. La base de datos es el cerebro: guarda al paciente y su trámite, con pasos, versión y bloqueo para que dos canales no se pisen. WhatsApp, web, recepción y asesor son clientes delgados de la misma API de 50 funciones.

Las reglas (cupos, pagos, cancelaciones, comprobantes) viven una sola vez en la base. Agregar un canal nuevo es cuestión de horas.

La seguridad también está en la base. Los datos sensibles exigen verificar al paciente con un código por WhatsApp. Usamos RLS y auditoría, y la clave maestra nunca llega al navegador.

Todo está probado: 403 pruebas automáticas y 38 migraciones versionadas. Medimos 9.5 ms por operación con 100 mil pacientes simulados. La API está documentada en Swagger y es PostgreSQL estándar, sin encierro con el proveedor.

Falta conectar la pasarela de pago real, un número propio de WhatsApp Business y definir retención y cumplimiento (LFPDPPP, NOM-024). La base ya está lista para eso.

## Si preguntan por qué Supabase

Un equipo pequeño entrega rápido, empieza en plan gratuito, pagos y citas necesitan transacciones relacionales y la salida a otro Postgres es sencilla.
