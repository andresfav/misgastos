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
- Inicio llama a `get_current_financial_state()` y presenta disponible, gastos, ingresos, presupuesto/restante y la distribución del ahorro. Muestra cuentas activas y cuentas legacy inactivas con saldo; oculta las borradas a cero sin excluir dinero del total. No suma movimientos ni reconstruye saldos.

`src/types/finance.ts` modela los campos consumidos de las migraciones 001–008. No son tipos generados de un proyecto remoto. PostgREST serializa `numeric` como números JSON; cantidades extremas pueden perder precisión al parsearse en JavaScript. Esta base no utiliza esos valores para cálculos ni escrituras. Una futura presentación exacta de todo el rango `numeric(20,2)` requeriría un contrato de lectura decimal en texto o un parser JSON decimal.

## PWA y despliegue

`vite-plugin-pwa` conserva la estrategia `generateSW` y `prompt`. El único registro está en `src/lib/pwa.ts`, mediante el módulo virtual del plugin; está desactivado en desarrollo. No reutilizar el puerto de producción/preview para `vite dev`: si ya existe un worker en ese origen, retirarlo desde DevTools → Application → Service Workers.

El precache incluye exclusivamente los archivos estáticos de `dist/` (HTML, JS, CSS, imágenes y manifest), también los chunks de rutas diferidas. No hay reglas de caché de API, respuestas de Supabase, tokens, cola offline ni sincronización diferida. El fallback sirve el HTML estático para las rutas React, incluidas las de acceso; excluye rutas de API y archivos. Una visita online completa es necesaria antes de poder abrir la shell sin conexión. El aviso «Sin conexión» desaparece al reconectar; los datos y operaciones siguen dependiendo de Supabase y sus errores reales. Los datos ya visibles en memoria pueden permanecer en pantalla.

Las revisiones y hashes del build actualizan el precache; al activar, Workbox elimina únicamente entradas antiguas de su propia caché, identificada por el scope del worker. Se desactiva `cleanupOutdatedCaches` porque su barrido de nombres podría alcanzar cachés de otras aplicaciones. No hay borrado global de Cache Storage.

Una actualización queda esperando y muestra «Nueva versión disponible» con «Actualizar». Se comprueba al registrar, volver a la aplicación, recuperar conexión y cada hora mientras está visible. Solo la ventana que pulsa el botón puede recargarse automáticamente; otra ventana recibe el aviso. Terminar los formularios antes de actualizar y actualizar también las otras ventanas abiertas. La activación natural al cerrar todas las ventanas sigue disponible. Implementación basada en la [integración del plugin](https://vite-pwa-org.netlify.app/frameworks/react.html).

Se conservan los iconos propios de 192/512 px y el SVG. `apple-touch-icon.png` (180 px) y `icon-maskable-512.png` (512 px, con margen seguro) son variantes técnicas del PNG existente. Se mantienen los colores actuales, español, `standalone` y orientación libre. El viewport admite safe areas; navegación inferior, contenido y diálogos tienen en cuenta los insets.

Desplegar `dist/` mediante HTTPS. El hosting debe devolver el `index.html` de la base para las rutas React incluso en la primera visita, sin reescribir archivos inexistentes ni endpoints de API. Servir `sw.js`, `index.html` y `manifest.webmanifest` con revalidación (`Cache-Control: no-cache` o `max-age=0, must-revalidate`); los assets con hash pueden usar caché inmutable. El worker debe servirse como JavaScript, nunca como HTML. Mantener temporalmente los assets del despliegue anterior ayuda a las ventanas que sigan abiertas. La configuración de Vercel para raíz se describe a continuación.

La base actual es `/`. Para una subruta usar una base absoluta de pathname con barra final, por ejemplo `npm run build -- --base=/misgastos/`. Manifest, iconos, registro y React Router siguen esa base; los enlaces de confirmación/recuperación conservan el mismo flujo de Auth y usan esa base. Añadir sus URL exactas a las permitidas en Supabase. No usar `base: "./"` con BrowserRouter.

Validación física pendiente: instalación y arranque en Android/iOS/desktop, recarga de rutas, teclado, rotación, notch/home indicator y actualización con varias ventanas. Safari/iOS puede desalojar la caché; la disponibilidad offline no se garantiza indefinidamente.

## Despliegue en Vercel

1. Cuando decidas desplegar, sube estos cambios a tu repositorio GitHub (sin `.env.local`) y en Vercel selecciona **Add New → Project**, conecta GitHub e importa el repositorio. Este trabajo solo prepara archivos; no realiza commit ni despliegue.
2. Selecciona la carpeta que contiene `package.json` como **Root Directory**. Comprueba el preset **Vite**, **Build Command** `npm run build`, **Output Directory** `dist` e instalación `npm ci`. Selecciona Node **22.x** (el proyecto requiere 22.12+). No añadas `--base=/misgastos/`: la base por defecto ya es `/`.
3. En **Environment Variables**, añade `VITE_SUPABASE_URL` (URL HTTPS del proyecto Supabase) y `VITE_SUPABASE_PUBLISHABLE_KEY` (su clave publicable; también admite la antigua clave pública `anon`). Márcalas para **Production** y, si vas a probar previews, también **Preview**. No añadir `service_role`, claves secretas, contraseña de base de datos ni JWT secret. `.env.local` sigue ignorado y solo se utiliza localmente. Vite incorpora estos valores al compilar: un cambio de variables requiere un nuevo build/despliegue.
4. Pulsa **Deploy** cuando estés listo y copia la URL HTTPS estable de producción que Vercel asigne. No uses como Site URL una URL efímera de un despliegue. Vercel proporciona HTTPS, sin certificados manuales.
5. En Supabase → **Authentication → URL Configuration**, establece **Site URL** en esa URL de producción con `/` final. Añade a **Redirect URLs** esa misma URL raíz (confirmación) y la misma URL seguida de `auth/nueva-contrasena` (recuperación). Conserva `http://localhost:5173/` y `http://localhost:5173/auth/nueva-contrasena`; si usas preview local, añade también `http://localhost:4173/` y `http://localhost:4173/auth/nueva-contrasena`. Para probar Auth en una preview de Vercel, añade sus dos URL exactas; no hace falta permitir todos los dominios Vercel. Para pruebas locales bajo `/misgastos/`, añade igualmente esa base a las dos URL locales.
6. En Supabase Auth, comprueba que el proveedor **Email**, los nuevos registros y **Confirm email** estén habilitados si quieres confirmación. Revisa **Email Templates → Confirm signup / Reset password**: conserva el enlace `{{ .ConfirmationURL }}` de las plantillas estándar, que verifica el token y respeta la redirección solicitada por la app. Un enlace solo a `{{ .SiteURL }}` no sustituye ese flujo. Configura **SMTP** para enviar a usuarios reales: el servicio predeterminado restringe destinatarios a miembros del equipo y tiene límites de prueba. No se modifica nada de Supabase desde este repositorio.

`vercel.json` añade únicamente el fallback SPA a `/index.html`: excluye archivos con punto, `/assets` y prefijos de API para que un JS, manifest o worker ausente devuelva 404 y no HTML. Las rutas actuales no contienen puntos. Los archivos existentes se sirven normalmente. No se añaden headers: la política predeterminada de Vercel exige revalidación (`public, max-age=0, must-revalidate`), sin forzar caché prolongada para HTML, manifest o worker. Se conserva la gestión de assets con hash del preset. La configuración es para desplegar en raíz; el build local con `--base=/misgastos/` sigue disponible.

Comprobación final sobre la URL HTTPS real:

- Abrir y recargar directamente `/`, `/auth/login`, `/auth/registro`, `/auth/recuperar`, `/auth/nueva-contrasena`, `/onboarding`, `/movimientos`, `/anadir`, `/ahorro`, `/ajustes` y `/ajustes/periodos`. Probar `/ajustes/periodos/<id-real>` con un período existente. Las rutas protegidas pueden pedir login/onboarding; nunca deben devolver un 404 del hosting. Probar una primera visita sin service worker para comprobar el fallback de Vercel.
- Completar registro → correo → confirmación → login/logout, y recuperación → correo → `/auth/nueva-contrasena` → contraseña nueva → login. Comprobar también ambos correos desde localhost. Confirmar lecturas de Supabase y carga de las páginas diferidas sin errores de red.
- Abrir `/manifest.webmanifest`, `/sw.js`, `/icon-192.png`, `/icon-512.png`, `/icon-maskable-512.png` y `/apple-touch-icon.png`. Manifest: `start_url` y `scope` resuelven a `/`; worker: JavaScript con scope `/`. En Network, comprobar assets/chunks con estado 200, ausencia de contenido mixto y revalidación de HTML, manifest y worker. `/assets/no-existe.js` debe devolver 404, no el HTML de la app.
- Instalar y abrir la PWA en dispositivos compatibles. Tras un futuro despliegue con cambios, comprobar el aviso **Nueva versión disponible**, **Actualizar** y el comportamiento con dos ventanas. Instalación, correos y actualización real requieren estas pruebas posteriores; el build local no las certifica.

Referencias: [Vite en Vercel](https://vercel.com/docs/frameworks/frontend/vite), [rewrites](https://vercel.com/docs/project-configuration/vercel-json#rewrites), [caché](https://vercel.com/docs/caching/cache-control-headers), [redirects de Supabase](https://supabase.com/docs/guides/auth/redirect-urls), [plantillas](https://supabase.com/docs/guides/auth/auth-email-templates) y [SMTP](https://supabase.com/docs/guides/auth/auth-smtp).

## Movimientos, Añadir y catálogos

Movimientos consulta `expenses`, `incomes` y `transfers` mediante SELECT con RLS. Muestra hasta 100 filas recientes por tipo, ordenadas conjuntamente por fecha descendente, `created_at` descendente e ID como último desempate, con filtros por tipo. Los catálogos y los períodos se consultan completos en lotes de 500. Se conservan los nombres de las referencias inactivas en el historial.

Añadir crea gastos, ingresos y transferencias con las firmas de 004. Los importes viajan como texto decimal positivo, con máximo dos decimales. Las lecturas de movimientos solicitan `amount::text` mediante la [selección de columnas de PostgREST](https://postgrest.org/en/v12/references/api/tables_views.html#casting-columns), para conservar exactamente el importe al editar, sin cambios de SQL ni de backend. La fecha inicial usa la zona horaria configurada; se rechazan fechas futuras y fuera del período abierto. Los movimientos se editan mediante las RPC `update_*` y se borran, tras confirmación, con `delete_*`; siempre se envía la versión real de la fila. No se envía `user_id` ni `period_id` a estas RPC.

Cada intento de create/update/delete tiene un UUID propio asociado a sus parámetros, conservado en memoria y `sessionStorage` hasta confirmar éxito. Un reintento idéntico mantiene ese UUID, incluso al volver a abrir el formulario e introducir los mismos datos. Cambiar parámetros o terminar con éxito inicia otro intento. Si el almacenamiento está bloqueado, la persistencia dura mientras el formulario permanezca montado. Los formularios se limpian tras éxito; no se borra su contenido al fallar una petición de guardado normal.

Los períodos cerrados son de solo lectura. Ante una versión obsoleta se avisa, se cierra la edición pendiente y se vuelve a consultar la lista antes de otro intento. Las referencias inactivas solo se pueden conservar en el campo original de una edición, tal como permite 004; no se ofrecen para movimientos nuevos. El backend sigue validando los saldos, incluidas todas las fechas afectadas por una corrección o borrado.

Ajustes permite crear, renombrar y eliminar/borrar categorías y métodos de pago. Las RPC de 008 hacen borrado físico si nunca se usaron y lógico si conservan referencias históricas; los inactivos no forman una lista cotidiana. Los cambios de filas existentes envían `p_expected_version`.

Cada página carga al entrar. Un evento local sencillo (`misgastos:data-changed`) invalida las lecturas montadas después de una mutación; Inicio vuelve a consultar su RPC y no reconstruye saldos. No hay caché global ni suscripciones Realtime.

## Siguiente bloque

Altas y gestión de ahorro, gestión de períodos, paginación para consultar más de 100 movimientos por tipo y edición de preferencias personales. Ahorro sigue siendo un placeholder explícito; los ingresos a Disponible se pueden utilizar sin cuentas de ahorro. No se ha añadido el reset financiero a la UI.

Con un proyecto de pruebas configurado, comprobar manualmente registro/confirmación, login/logout, recovery, sesión caducada, onboarding interrumpido y cada tipo de período, y contrastar Inicio con las RPC. El build por sí solo no verifica correos ni conectividad con un proyecto Supabase.
