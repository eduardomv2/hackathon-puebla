# Simulador omnicanal (solo pruebas locales)

App única de Vite + React que usa la API real de `supabase/` (funciones `api.*`, Edge Functions y
tiempo real). Rutas: `/` (paciente), `/personal` (personal, lazy) y `/demo` (4 canales + escenarios).

```bash
# en la raíz del repo
npx supabase start
npx supabase functions serve          # en otra terminal
# aquí
npm install
npm run usuarios                      # personal de prueba (repetir tras cada db reset)
npm run dev                           # http://localhost:5173
```

| Script | Qué hace |
|---|---|
| `npm run dev` | Servidor de desarrollo |
| `npm run usuarios` | Crea asesor@, recepcion@, clinica@ (supervisora) y admin@demo.mx (contraseña `demo1234`) |
| `npm run tipos` | Regenera `src/database.types.ts` desde la base local |
| `npm run probar-api` | Recorrido completo por la API (web → asesor → pago → app) |
| `npm run probar-bot` | Pruebas unitarias del intérprete del bot (frases de fechas y registro) |

Estructura de `src/`:

- `api.ts`: único cliente de la API (tipos, errores por `code`, sesiones, tiempo real). Sin React.
- `SitioPaciente.tsx`, `personal/AppPersonal.tsx`, `demo/AppDemo.tsx`: las tres rutas (`App.tsx`).
- `paneles/`: paciente, teléfono simulado, consola del personal (pestañas por rol), atención
  (call center / mostrador), recepción y supervisión.
- `ui/`: piezas compartidas (asistente del trámite, registro, bandeja, avisos, inactividad).
- `demo/`: escenarios narrados (`escenarios.ts`) y utilidades que manejan los paneles (`dom.ts`).

Roles, funciones y reglas: ver el README de la raíz ("Roles y vistas").
