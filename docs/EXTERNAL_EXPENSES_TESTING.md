# Gastos externos: validación y despliegue de 011

011 está preparada para revisión; este trabajo no la aplica a ningún proyecto
Supabase, no despliega, no añade al índice de Git y no hace commit.
La numeración local inspeccionada llega a 010; antes de producción confirmar
que el historial remoto sigue terminando en 010, como indica el usuario.

## Pruebas locales reproducibles

Formulario, referencias históricas, filtros y contrato compartido CSV/XLSX:

```bash
node tests/external-expenses.test.mjs
npm run build
git diff --check
```

El test de frontend usa `node:module.stripTypeScriptTypes` (Node 22.13+;
validado con Node 26.12). Carga funciones puras en un directorio temporal y
sustituye el cliente de red por un stub que falla si se intenta utilizar.

Para SQL sin servidor ni credenciales Supabase, instalar PGlite **fuera** del
repositorio. No cambia package.json ni package-lock.json:

```bash
npm install --prefix /tmp/misgastos-sql --no-audit --no-fund @electric-sql/pglite@0.5.13
PGLITE_PACKAGE_ROOT=/tmp/misgastos-sql/node_modules/@electric-sql/pglite node tests/run-sql-smoke.mjs
```

El runner crea PostgreSQL en memoria y un harness mínimo de `auth.users`,
`auth.uid()`, `anon` y `authenticated`. Aplica 001–011 **solo en memoria**.
Antes de 011 crea un gasto real con 010, y después verifica el default/backfill,
el saldo conservado y un reintento idempotente registrado antes de migrar.
Después ejecuta los smoke 004–011, todos con ROLLBACK. No se ejecutan tests de
concurrencia y no se cambia el mecanismo de locking/idempotencia.

El smoke 011 cubre los 20 escenarios solicitados: default, impacto en saldo,
consumo y presupuestos, desglose, ingresos, cambios de origen, transferencia
posterior, ownership, fuentes inactivas y conservación histórica, hard/soft
delete, nombre histórico y reutilización, RLS, reset con dependencias vivas y
exportación. Añade controles de idempotencia, versión, fechas futuras y ACL.
Se corrigieron dos expectativas del smoke 009: tras mover y borrar un gasto,
la categoría original conserva nueve usos y la destino queda con tres; además,
«Ajena» precede a «alfa nueva» en orden alfabético normalizado.

## Antes de producción

1. Revisar SQL 011 y diff completo; comprobar historial remoto 010 y disponer
   de copia de seguridad recuperable.
2. En una **base de pruebas Supabase**, aplicar 011 sobre 001–010 y ejecutar
   `supabase/tests/011_external_expense_sources_smoke.sql` como propietario.
   El smoke dice SOLO BASE DE PRUEBAS y termina con ROLLBACK: nunca ejecutarlo
   en producción. PGlite no sustituye la integración real de Auth/PostgREST.
3. Probar el frontend actual contra esa base ya migrada: crear, editar, borrar
   un gasto normal y reintentar. Probar el nuevo frontend en preview.
4. En móvil: crear Itaú en Ajustes → Orígenes externos; registrar un gasto con
   método Tarjeta y origen Itaú; comprobar Disponible sin cambios y presupuestos
   y Gastos incrementados. Editar ambos sentidos; probar una retirada posterior
   a ahorro; borrar el origen usado, editar su gasto y reutilizar su nombre.
5. Comprobar desgloses de Inicio, presupuesto por categoría e historial, filtros,
   exportación CSV/XLSX de historial y XLSX completo (incluye hoja de orígenes).
   Contrastar aperturas/cierres exportados con el resumen canónico. Verificar
   reset únicamente con un usuario de pruebas.

## Orden de despliegue

**Migración 011 → comprobar recarga de esquema PostgREST → deploy Vercel**.
La infraestructura actual compila Vite en Vercel; Supabase se migra por separado.
No desplegar el nuevo frontend antes: requiere tabla y nuevas RPC de 011.

Las firmas originales `create_expense` y `update_expense` permanecen sin overloads.
La creación antigua sigue usando Disponible; la edición antigua conserva origen.
Sus hashes de idempotencia no cambian. Las nuevas RPC `_with_funding` reciben
ambos campos; comparten el core privado con la API anterior y su mismo lock.
Las lecturas y exportación mantienen campos anteriores y añaden los nuevos.
El frontend previo puede seguir funcionando durante la ventana de despliegue;
solo el nuevo presenta las fuentes externas.

No se crea Itaú automáticamente ni se modifica Auth. Tras el despliegue, el
usuario puede crear «Itaú» como cualquier otro origen externo.
