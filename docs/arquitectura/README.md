# Documentación de arquitectura — Orquestador omnicanal Salud Digna

Documentación pensada para dos usos: **explicar** el proyecto (jurado, equipo) y **servir de fuente** para
generar diagramas y presentaciones. Todos los diagramas están en [Mermaid](https://mermaid.js.org/): se ven
en GitHub y se pegan en <https://mermaid.live> para exportarlos como imagen.

| # | Documento | Para qué sirve |
|---|---|---|
| 1 | [Resumen ejecutivo](01_resumen_ejecutivo.md) | El problema, la solución y los números clave en una página |
| 2 | [Arquitectura y diagramas](02_arquitectura_y_diagramas.md) | Capas, componentes, secuencias de los flujos principales |
| 3 | [Modelo de datos](03_modelo_de_datos.md) | Tablas, relaciones (diagrama ER) y estados |
| 4 | [Conexión omnicanal](04_conexion_omnicanal.md) | Cómo debe conectarse cada aplicación y qué contrato respeta |
| 5 | [Seguridad y privacidad](05_seguridad.md) | Identidad, roles, cifrado, bitácora, límites |
| 6 | [Escalabilidad](06_escalabilidad.md) | Qué aguanta hoy, qué medimos, cómo crece y dónde está el tope |
| 7 | [Por qué Supabase](07_por_que_supabase.md) | Comparación con alternativas, ventajas y riesgos reales |
| 8 | [Bitácora de decisiones](08_decisiones.md) | Cada decisión tomada, el porqué y lo que se descartó |
| 9 | [Estado y pendientes](09_estado_y_pendientes.md) | Qué está hecho, qué falta y qué es solo de demostración |

Documentos relacionados (ya existentes): [`../../README.md`](../../README.md) (operación y referencia de la API),
[`../GUIA_APP_PWA.md`](../GUIA_APP_PWA.md) (guía para construir la app del paciente y las consolas).

## Cómo leerla según lo que necesites

- **Presentar al jurado:** 1 → 7 → 6 → los diagramas de 2.
- **Dibujar diagramas:** 2 y 3 ya traen Mermaid; 4 trae las secuencias por canal.
- **Construir una aplicación nueva:** 4 → `../GUIA_APP_PWA.md`.
- **Defender decisiones técnicas ante preguntas:** 8.

## Convención sobre las cifras

Toda cifra está marcada como **medida** (se corrió una prueba y está en el repositorio), **dato del proyecto**
(sale del código o de los datos cargados) o **estimación** (se calcula con supuestos que se escriben al lado).
No se usan datos internos reales de Salud Digna: no los tenemos.
