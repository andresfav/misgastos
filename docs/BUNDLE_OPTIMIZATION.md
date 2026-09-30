# Diagnóstico y carga diferida del frontend

Medición del 30 de septiembre de 2026 con `npm run build` (TypeScript y Vite
8.3.1). Tamaños en kB decimales, tal como los muestra Vite; gzip entre
paréntesis. No se instaló ningún analizador ni se cambiaron dependencias,
límites de warning o reglas de partición del bundler.

## Diagnóstico antes de editar

Las rutas Movimientos, Añadir, Ahorro, Ajustes, Períodos y Onboarding ya usaban
`React.lazy`. Inicio, autenticación, proveedores y shell eran eager. El shell
ya tenía un `Suspense` alrededor de su `Outlet`, conservando la navegación.

El chunk principal medía **511,59 kB (148,80 gzip)**. Predominan React/React DOM,
router y Supabase. Se contrastaron los imports con los módulos del entry
expuestos por `generateBundle` de Vite en un build temporal: aproximadamente
563 kB de React/React DOM/scheduler, 95 kB de router, 379 kB de Supabase y
dependencias transitivas, y 71 kB del grupo aplicación/virtuales. Estos son
`renderedLength` antes de la minificación final: sirven para atribuir peso,
no para sumarlos o compararlos directamente con los tamaños de entrega.

Supabase usa el `createClient` público de `@supabase/supabase-js`; sus módulos
Auth, PostgREST, Storage, Realtime, Functions y dependencias transitivas
explican su peso. No se altera el cliente, su sesión ni sus contratos.

No hay librería de gráficos: Evolución es SVG propio, y las barras usan
`progress` y CSS. Workbox Window ya se genera aparte, con 5,65 kB. El worker
se ejecuta por separado. No se encontraron dependencias npm sin uso; las de
desarrollo corresponden a TypeScript, tipos, Vite, React y PWA. Los imports
usan APIs públicas, y los imports de tipos se eliminan al compilar.

## Cambios

- El componente SVG `PeriodEvolution` se importa al abrir por primera vez
  su acordeón. Después permanece montado aunque se cierre. Las consultas,
  resúmenes, cálculos y barras existentes se conservan.
- Cuenta, Preferencias, Catálogos y Datos se importan al entrar a su sección.
  Categorías y Métodos comparten `CatalogSettings`. El índice de Ajustes ya
  no carga todos esos formularios.
- Los nuevos límites `Suspense` usan el componente `Loading` existente con
  «Cargando…». El de Ajustes conserva el título y enlace de vuelta; el del
  gráfico queda dentro de su acordeón. El shell y las rutas no cambian.

## Antes y después

Se omiten los hashes, que cambian entre builds.

| Chunk | Antes kB (gzip) | Después kB (gzip) |
| --- | ---: | ---: |
| index JS | 511,59 (148,80) | 283,00 (89,71) |
| errors, compartido inicial | incluido en index | 217,11 (56,35) |
| jsx-runtime, compartido inicial | incluido en index | 8,77 (3,33) |
| **JS inicial estático total** | **511,59 (148,80)** | **508,88 (149,39)** |
| SettingsPage | 12,68 (3,73) | 2,85 (1,19) |
| AccountSettings | incluido en SettingsPage | 1,93 (0,87) |
| PreferencesSettings | incluido en SettingsPage | 2,27 (1,09) |
| CatalogSettings | incluido en SettingsPage | 5,04 (1,79) |
| ResetFinancialData | incluido en SettingsPage | 2,35 (1,03) |
| PeriodEvolution | incluido en index | 2,93 (1,29) |
| MovementsPage | 13,92 (4,42) | 13,99 (4,45) |
| AddPage | 3,00 (1,37) | 3,05 (1,39) |
| SavingsPage | 11,30 (3,62) | 11,38 (3,64) |
| PeriodsPage | 19,61 (6,10) | 19,68 (6,12) |
| OnboardingPage | 6,67 (2,58) | 6,74 (2,61) |
| MovementForm | 8,16 (2,82) | 8,23 (2,85) |
| movements, utilidades | 1,84 (0,83) | 1,84 (0,82) |
| movements, etiquetas | 0,08 (0,09) | 0,08 (0,09) |
| useRequestAttempt | 0,62 (0,35) | 0,66 (0,38) |
| workbox-window | 5,65 (2,20) | 5,65 (2,20) |
| CSS | 31,80 (6,87) | 31,80 (6,87) |

Vite extrajo automáticamente dos módulos compartidos al cambiar el grafo de
imports. `errors` incluye Supabase y utilidades compartidas; su nombre no
significa que contenga 217 kB de mensajes de error. Tanto este archivo como
`jsx-runtime` están en los `modulepreload` del HTML y se necesitan al arrancar.

**La reducción real del JS inicial es solo 2,71 kB, aproximadamente el 0,53 %.**
La suma gzip crece 0,59 kB por el coste de comprimir archivos separados.
Workbox Window añade los mismos 5,65 kB (2,20 gzip) a ambos arranques cuando se
registra la PWA. No se afirma una mejora de latencia medida.

El índice de Ajustes reduce su chunk en 9,83 kB, aproximadamente el 77,5 %;
sus subpantallas pasan a cargarse según uso. Los tamaños por pantalla de la
tabla no incluyen sus dependencias compartidas.

El warning desaparece porque ningún archivo supera 500 kB, aunque el conjunto
inicial sigue superando ese tamaño. No se justifica fragmentar más las
dependencias fundamentales para reducirlo artificialmente.

## Comprobaciones y PWA

- `npm run build`: correcto, sin warning de tamaño; 19 chunks JS en assets.
- Chrome headless contra el build de producción: Inicio no carga el gráfico
  cerrado; abrirlo solicita su chunk y dibuja el SVG. Ajustes no carga sus
  subpantallas hasta seleccionarlas.
- Retraso deliberado de un chunk: fallback visible y mismo nodo de navegación,
  manteniendo el título de la sección. Sin pantallas blancas ni excepciones JS.
- Navegación por las cinco secciones de Ajustes, rutas directas de Movimientos,
  Añadir, Ahorro, Períodos e histórico; recarga y atrás en Cuenta: correctos.
- Manifest standalone válido, service worker activo y los 19 chunks JS
  presentes en su caché. Apertura directa offline de Categorías con shell y
  chunk servidos por el worker: correcta.
- Pruebas con sesión y respuestas ficticias interceptadas en el navegador;
  ninguna petición de esas pruebas llega a Supabase. No validan datos reales
  ni sustituyen una prueba de instalación desde la interfaz del dispositivo.

La configuración PWA, safe areas, manifest y actualización manual permanecen
intactos. El precache automático pasa de 23 entradas (626,86 KiB) a 30
(629,40 KiB), e incluye los nuevos chunks mediante el glob existente. Solo
contiene recursos del origen local, sin respuestas de Supabase.

El precache sigue descargando los chunks secundarios al instalar el worker:
la carga diferida evita su evaluación hasta usarlos, pero no elimina esa
descarga total de instalación. Hay más archivos y una pequeña latencia posible
en la primera apertura si todavía no están en caché.

Durante una actualización en espera, el worker activo conserva sus assets y
el nuevo todavía no toma el control. Persiste el riesgo previo de una pestaña
antigua abierta después de que otra active una versión: la activación puede
limpiar chunks viejos y una importación posterior fallar si el despliegue ya
los retiró. También puede ocurrir sin worker controlador. Se mantiene el aviso
y la actualización manual existentes; no se fuerza recarga ni se descartan
formularios. Conviene conservar assets versionados durante el despliegue y
actualizar las demás ventanas tras terminar los formularios, como ya indica
el README. No se añadió un sistema de recuperación de chunks.
