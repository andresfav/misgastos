# Presupuestos por origen — 012

Implementación local para revisión. No se aplica SQL a producción, no se hace
commit, push ni despliegue. Se parte de 011 aplicada, según el contexto del usuario.

## Decisiones y compatibilidad revisadas

- Todos los períodos existentes se marcan `budget_model=legacy_total`. Su
  `general_budget` sigue cubriendo todos los gastos. No se cambian importes,
  versiones, timestamps ni movimientos; los cerrados nunca se convierten.
- Un abierto legacy pasa a `by_origin` solo al guardar explícitamente la nueva
  distribución. El editor propone el total anterior para Disponible y avisa del
  cambio. Si se conserva 2.000 y se añaden 500 externos, el total será 2.500.
- Los períodos nuevos se insertan como `by_origin`. El total se deriva de las
  asignaciones; NULL y cero mantienen significados distintos.
- La RPC antigua `set_general_budget` se permite solo sin asignaciones externas.
  Si existe alguna, incluso cero, se rechaza cualquier importe y NULL sin cambiar
  importes ni versión. No se intenta adivinar si el importe recibido era total
  o componente. Las pestañas antiguas deben actualizarse para editar distribución.
- `period.general_budget` es físico y depende del modelo; el frontend nuevo no
  lo declara en su tipo ni lo lee de la tabla. `general_budget` del resumen es
  siempre el total canónico. Editor: `funding_budgets` y `legacy_general_budget`.
- Históricos legacy y exportaciones muestran límite general frente a todo el
  consumo, con límites de origen NULL y sin asignaciones ficticias en Excel.
- El guardado/conversión sigue siendo una transacción con lock común, versión e
  idempotencia. Fuentes inactivas y reset conservan las reglas de 012.

## Pruebas locales

```bash
npm run build
node tests/external-expenses.test.mjs
node tests/funding-budgets.test.mjs
PGLITE_PACKAGE_ROOT=/tmp/misgastos-sql/node_modules/@electric-sql/pglite node tests/run-sql-smoke.mjs
git diff --check
```

Si falta PGlite, instalarlo fuera del repositorio:

```bash
npm install --prefix /tmp/misgastos-sql --no-audit --no-fund @electric-sql/pglite@0.5.13
```

Los tests de componentes usan Vite como cargador de TSX, renderizan los
componentes reales en HTML y sustituyen cliente Supabase/hooks de sesión por
fixtures locales. No hay conexión a Supabase ni puertos de red abiertos.
Se verifican el total del borrador, importes exactos, NULL/cero, componentes
inactivos, porcentajes y HTML del exceso, Gasto de Disponible, progresividad del
dashboard/formulario y contenido de las hojas Excel.

El runner SQL utiliza PostgreSQL embebido en memoria con un harness mínimo de
Auth. Ejecuta las migraciones 001–012 y los smoke 004–012. Conserva la prueba de
actualización 010→011 y añade una actualización real 011→012 con períodos abiertos
y cerrados, presupuestos y gastos externos: compara todos los campos previos antes y después (la única columna añadida es
`budget_model`). Incluye un cerrado anterior con gastos externos: mantiene el
límite sobre todo el consumo y no exporta asignaciones a Disponible. Comprueba
la conversión explícita del abierto, el rollback de una conversión fallida y el
rechazo de una llamada antigua con 2.600 sobre 2.000 + 500.

El smoke 012 cubre los doce grupos solicitados, incluidos rollback de un guardado
parcial, segundo editor con versión obsoleta, idempotencia con entradas reordenadas,
API antigua rechazada con externos, ownership/RLS, fuentes con solo presupuestos, cierre y nuevo período,
exportación y reset. Cada smoke termina con ROLLBACK y está marcado como SOLO BASE
DE PRUEBAS. El test de versiones representa dos editores con la misma lectura;
no es un ensayo de dos conexiones simultáneas. No se altera el mecanismo de lock
ni se ejecuta el harness de concurrencia existente.

## Revisión antes de producción

1. Confirmar que el historial remoto termina en 011 y revisar el SQL 012 y el diff.
2. Disponer de copia recuperable. Aplicar 012 primero en una base Supabase de
   pruebas; allí verificar el smoke y Auth/PostgREST reales. Nunca ejecutar el
   smoke en producción.
3. Probar el frontend anterior sobre la base migrada: crear gastos, modificar su
   presupuesto habitual y avanzar período. Tras crear asignaciones externas con
   el nuevo frontend, comprobar que el antiguo no puede guardar 2.600, NULL ni
   modificar presupuestos con una fuente externa de cero. Probar el nuevo frontend
   en preview y verificar históricos generales cerrados con gastos externos.
4. Confirmar en móvil y escritorio: usuario sin fuentes, con varias fuentes y con
   fuentes inactivas; teclado, acordeones, entradas vacías/cero y textos largos.
   Las pruebas automatizadas de HTML no sustituyen la inspección visual en móvil.
5. Comprobar dos sesiones editando el mismo período, una respuesta de guardado
   perdida y su reintento, y el cierre mientras otro editor tiene el formulario
   abierto. El segundo guardado obsoleto debe rechazarse completo.
6. Abrir el Excel completo y contrastar Total, Categoría y Presupuestos por origen
   con las lecturas del servidor. Verificar reset solo con un usuario de pruebas.

Orden seguro para una aplicación posterior: **migración 012 → recarga de
esquema PostgREST → deploy del frontend**. El nuevo frontend requiere 012.
Los clientes anteriores conservan la edición sin asignaciones externas. Una vez
creadas estas, deben actualizarse: la RPC antigua rechaza el guardado para evitar
interpretaciones incorrectas del total. No retirar la firma legacy durante esta
transición.
