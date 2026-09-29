# MisGastos

Frontend nuevo en React + TypeScript + Vite, React Router y Supabase JS. CSS propio mobile-first. El backend existente vive en `supabase/`; sus contratos están descritos en `docs/`.

## Desarrollo

Requiere Node 22.12+ y npm.

```bash
npm install
cp .env.example .env.local
# Completar las dos variables con la URL y la clave publicable del proyecto.
npm run dev
```

`.env` y `.env.*` están ignorados; `.env.example` es la excepción. No usar una clave secreta ni `service_role`. Las variables `VITE_*` se incluyen en el navegador: utilizar exclusivamente la clave publicable.

```bash
npm run build
npm run preview
```

El build comprueba TypeScript y genera `dist/`. No hay lint configurado ni suite E2E en esta base.

## Configuración de Supabase Auth

Activar el proveedor email/contraseña y configurar el envío de correo y la confirmación de email según el entorno. En **Authentication → URL Configuration**, configurar Site URL y añadir las URL exactas permitidas de cada despliegue. En desarrollo:

- `http://localhost:5173/` (confirmación de registro).
- `http://localhost:5173/auth/nueva-contrasena` (recuperación).

Si se usa preview, añadir también las equivalentes en `http://localhost:4173`. En producción usar el dominio HTTPS real. El hosting debe devolver `index.html` para rutas del cliente, incluidas `/auth/nueva-contrasena` y `/onboarding`, conservando los parámetros y fragmentos de la URL.

Supabase gestiona registro, login, persistencia, renovación y eventos de sesión. `PASSWORD_RECOVERY` lleva al formulario que llama a `updateUser`; el enlace de recuperación es procesado por el SDK. Logout cierra la sesión local. Las rutas privadas se desmontan al perder sesión y los datos de un usuario no se reutilizan para otro.

Referencia del flujo de recovery: [Supabase Auth](https://supabase.com/docs/reference/javascript/auth-resetpasswordforemail).

## Flujos y contratos

- Se consulta `user_settings` bajo RLS tras autenticar. Sin configuración, el onboarding comienza en el paso 1. Si existe, se comprueba `budget_periods`: un usuario que interrumpió la configuración continúa en el paso 2. Un historial con todos los períodos cerrados no provoca un nuevo onboarding.
- Configuración: `configure_user_settings(p_currency, p_timezone)`. Se omite `p_expected_version` porque se crea la configuración; esta base no edita preferencias existentes.
- Primer período: `create_first_period(p_mode, p_start_date, p_end_date, p_opening_balance, p_request_id, p_general_budget)`. Mes y año naturales se calculan sobre el día de la zona configurada; personalizado debe contener hoy y entre nóminas se envía con final `null`.
- Los importes de formulario se validan y se envían como texto decimal, admitiendo coma o punto, dos decimales y 18 cifras enteras. El disponible inicial puede ser negativo; el presupuesto, no. No se envía `user_id` a las RPC.
- Se genera un UUID por petición lógica del primer período. Se conserva en memoria y, si está disponible, en `sessionStorage`, asociado a los parámetros. Un reintento idéntico reutiliza el UUID; cambiar parámetros genera otro. Tras éxito se elimina. La existencia del historial siempre se consulta en Supabase. El botón de comprobación permite resolver una respuesta perdida consultando el servidor.
- Inicio llama a `get_current_financial_state()` y presenta disponible, gastos, ingresos, presupuesto/restante y todas las cuentas de ahorro con sus saldos y estado. No suma movimientos ni reconstruye saldos.

`src/types/finance.ts` modela los campos consumidos de las migraciones 001–007. No son tipos generados de un proyecto remoto. PostgREST serializa `numeric` como números JSON; cantidades extremas pueden perder precisión al parsearse en JavaScript. Esta base no utiliza esos valores para cálculos ni escrituras. Una futura presentación exacta de todo el rango `numeric(20,2)` requeriría un contrato de lectura decimal en texto o un parser JSON decimal, fuera de este bloque sin cambios de backend.

## PWA y despliegue

`vite-plugin-pwa` genera manifest y service worker en producción. Se precargan únicamente recursos estáticos; no hay caché de API, Auth ni datos financieros. La app necesita conexión para autenticación y consultas. Las rutas `/auth/` quedan fuera del fallback offline. Las actualizaciones se activan al cerrar las ventanas anteriores y volver a abrir la app, para no recargar un formulario en curso.

Se incluyen iconos **provisionales** propios (M geométrica) de 192 y 512 px; queda pendiente la identidad visual final y un icono maskable. HTTPS es necesario fuera de localhost. Los requisitos de instalación dependen del navegador. Base de configuración: [Vite PWA](https://vite-pwa-org.netlify.app/guide/service-worker-strategies-and-behaviors).

## Siguiente bloque

Implementar listas y formularios reales de movimientos, altas de ahorro, gestión de períodos, categorías, métodos de pago y edición de ajustes. Las rutas Movimientos, Añadir, Ahorro y Ajustes son placeholders explícitos; Ajustes ya muestra la configuración actual. No se ha añadido el reset financiero a la UI.

Con un proyecto de pruebas configurado, comprobar manualmente registro/confirmación, login/logout, recovery, sesión caducada, onboarding interrumpido y cada tipo de período, y contrastar Inicio con las RPC. El build por sí solo no verifica correos ni conectividad con un proyecto Supabase.
