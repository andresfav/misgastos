# MisGastos — Modelo de datos v1

Modelo para construir el backend desde cero, conforme a [SPEC.md](SPEC.md). Describe tablas y reglas; no contiene SQL, políticas RLS ni funciones completas.

## Convenciones

- Todas las entidades nuevas tienen clave primaria `id uuid`, salvo `user_settings`, cuya clave es `user_id uuid`.
- Todas las tablas tienen `user_id uuid` obligatorio, relacionado con `auth.users(id)`. La identidad se obtiene de la sesión autenticada, no de un propietario elegido libremente por el cliente.
- Todas incluyen `created_at timestamptz`. Las tablas editables incluyen además `updated_at timestamptz`; `financial_operations` conserva registros inmutables y no lo necesita.
- `user_settings`, `categories`, `payment_methods`, `budget_periods`, `expenses`, `incomes`, `savings_accounts`, `transfers` y `period_category_budgets` incluyen `version bigint NOT NULL DEFAULT 1`, siempre positiva. Las futuras RPC de update/delete reciben `expected_version` y rechazan la operación si la versión actual no coincide con la leída por el cliente. Cada update incrementa la versión en la misma transacción. `financial_operations` es inmutable y no tiene versión.
- Los importes y saldos usan `numeric(20,2)`, también para PYG. Los cálculos son exactos, nunca `float`. El backend rechaza entradas con más de dos decimales para evitar redondeos silenciosos. En el transporte se preserva la precisión mediante representaciones decimales exactas.
- Las fechas financieras son `date`; los instantes técnicos, `timestamptz`. El día actual se obtiene usando la zona horaria del usuario.
- Las columnas son obligatorias salvo que se indique «opcional». Los estados y tipos enumerados abajo son valores cerrados; no necesitan tablas de catálogo adicionales.
- Las referencias entre datos financieros deben pertenecer al mismo usuario. Se prevén claves únicas `(user_id, id)` en las tablas referenciadas y FK compuestas `(user_id, referencia_id)`. Una FK por `id` solamente no garantiza esta regla.
- Todas las FK `user_id → auth.users(id)` usan `ON DELETE CASCADE`. Las relaciones internas financieras y de catálogos usan `ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED` en 001, nunca cascadas que borren movimientos accidentalmente. La comprobación diferida permite eliminar todo el grafo al borrar un usuario antes de validar las FK internas. Desde 008, los elementos nunca utilizados pueden eliminarse físicamente mediante RPC; los utilizados se borran lógicamente para conservar sus referencias.
- Los nombres activos de categorías, métodos de pago y cuentas de ahorro son únicos por usuario mediante índices parciales sobre `lower(btrim(name))`. Los espacios exteriores y las diferencias de mayúsculas no permiten dos duplicados activos; un nombre borrado lógicamente puede reutilizarse.

## Tablas

### 1. `user_settings`

**Propósito:** configuración financiera personal. La serialización por usuario usa el bloqueo común descrito más abajo, disponible incluso antes de crear esta fila.

**PK y relación:** `user_id uuid`, FK a `auth.users(id)`; una fila por usuario.

**Columnas principales:**

- `currency text`: `EUR`, `USD` o `PYG`.
- `timezone text`: identificador de zona horaria válido, elegido o confirmado por el usuario.
- `currency_locked_at timestamptz`, opcional: momento en que comienza el historial financiero.

**Restricciones:** configuración confirmada antes de iniciar el historial. La moneda queda bloqueada al crear el primer período o la primera cuenta de ahorro, lo que ocurra antes. No hay cambio ordinario posterior. La zona horaria debe validarse en el backend.

### 2. `categories`

**Propósito:** categorías propias para clasificar gastos y asignar presupuestos.

**PK:** `id uuid`.

**Columnas principales:** `user_id`, `name text`, `is_active boolean` (inicialmente verdadero).

**Relaciones:** propietario en `auth.users`; referenciada por gastos y presupuestos por categoría.

**Restricciones:** nombre no vacío. Una categoría sin gastos ni presupuestos se elimina físicamente; si cualquiera de esas referencias existe, se marca inactiva. El borrado lógico la excluye de nuevas asignaciones sin eliminar gastos ni presupuestos históricos. Renombrar actualiza el nombre mostrado también en el historial.

### 3. `payment_methods`

**Propósito:** métodos de pago propios que pueden asociarse a gastos.

**PK:** `id uuid`.

**Columnas principales:** `user_id`, `name text`, `is_active boolean` (inicialmente verdadero).

**Relaciones:** propietario en `auth.users`; referenciada opcionalmente por gastos.

**Restricciones:** nombre no vacío. Un método nunca usado se elimina físicamente; uno referenciado por gastos se marca inactivo y conserva esas referencias. Un método de pago no es una cuenta ni tiene saldo.

### 4. `budget_periods`

**Propósito:** única línea temporal financiera del usuario, con saldo inicial, cierre y presupuesto general.

**PK:** `id uuid`.

**Columnas principales:**

- `user_id`.
- `mode text`: `monthly`, `annual`, `custom` o `between_paydays`.
- `start_date date`; `end_date date`, opcional solo para `between_paydays` abierto.
- `status text`: `open` o `closed`.
- `opening_balance numeric(20,2)`: puede ser negativo.
- `closing_balance numeric(20,2)`, opcional mientras está abierto; puede ser negativo.
- `general_budget numeric(20,2)`, opcional: ausencia significa que no se ha fijado límite.
- `closed_at timestamptz`, opcional mientras está abierto.

**Relaciones:** propietario en `auth.users`; referenciada por gastos, ingresos, transferencias y presupuestos por categoría.

**Restricciones:**

- Como máximo un período `open` por usuario, protegido mediante unicidad condicional.
- Rangos de fechas inclusivos sin solapamientos por usuario, protegidos en la base de datos. Una fecha final ausente representa un rango sin límite superior.
- Fecha final mayor o igual a la inicial. `monthly` abarca del primer al último día de un mes natural; `annual`, del 1 de enero al 31 de diciembre; `custom` requiere ambas fechas.
- Un período cerrado tiene fecha final, saldo final y momento de cierre. Un período abierto no tiene saldo final ni momento de cierre.
- Presupuesto general, si existe, mayor o igual a cero. Cero es un límite válido, distinto de ausencia de presupuesto.
- El primer saldo inicial se confirma explícitamente. Los siguientes se copian automáticamente del saldo final del período anterior en orden cronológico, sin crear ingresos.
- No se insertan períodos históricos entre períodos ya establecidos. Abrir el siguiente y cerrar el anterior es una transición transaccional. Para `between_paydays`, fija el final anterior al día previo al nuevo inicio; para los demás modos respeta sus fechas definidas.
- No se permite un cierre o cambio de límite que deje movimientos fuera de su período. Los períodos cerrados, sus movimientos y sus presupuestos son inmutables en v1.

No se añade `previous_period_id`: el orden de la línea temporal y la operación de apertura determinan el anterior. El saldo final guardado fija el arrastre sin recalcular historia cerrada.

### 5. `expenses`

**Propósito:** consumo registrado, financiado desde Disponible o desde un origen externo.

**PK:** `id uuid`.

**Columnas principales:**

- `user_id`, `period_id uuid`, `date date`, `amount numeric(20,2)`.
- `category_id uuid`.
- Desde 011: `funding_type text NOT NULL DEFAULT 'available'` (`available` / `external`); `external_source_id uuid` opcional. Un check exige origen solo para `external`; FK compuesta `(user_id, external_source_id)` al catálogo propio.
- `description text`, `payment_method_id uuid`, `merchant text`, `note text`: opcionales.
- `is_recurring boolean`: inicialmente falso; solo una marca, sin automatización.

**Relaciones:** propietario en `auth.users`; FK compuestas al período, categoría y método de pago opcional.

**Restricciones:** importe positivo; fecha no futura y dentro de un período existente y abierto al crear, editar o borrar. Categoría y método activos para nuevas asignaciones; una edición puede conservar una referencia histórica desactivada. No existe cuenta de ahorro de origen. Un gasto puede dejar negativo el disponible.

### 6. `incomes`

**Propósito:** dinero nuevo recibido desde fuera, para disponible o ahorro.

**PK:** `id uuid`.

**Columnas principales:** `user_id`, `period_id uuid`, `date date`, `amount numeric(20,2)`, `savings_account_id uuid` opcional, `description text` opcional.

**Relaciones:** propietario en `auth.users`; FK compuestas al período y a la cuenta de ahorro opcional.

**Restricciones:** importe positivo; mismas reglas de fecha y período abierto que los gastos. `savings_account_id` ausente significa destino disponible; presente significa destino ahorro. No se duplica el destino en otra columna. Un ingreso a ahorro no aumenta el disponible. Todos los ingresos cuentan en las estadísticas del período.

### 7. `savings_accounts`

**Propósito:** cuentas personales de ahorro con saldo derivado.

**PK:** `id uuid`.

**Columnas principales:** `user_id`, `name text`, `start_date date`, `opening_balance numeric(20,2)`, `is_active boolean` (inicialmente verdadero).

**Relaciones:** propietario en `auth.users`; referenciada por ingresos y por los extremos de las transferencias.

**Restricciones:** nombre no vacío; saldo inicial no negativo. Ningún movimiento de la cuenta puede preceder a su fecha inicial. No se guarda ni se edita un saldo actual: se obtiene del saldo inicial, ingresos y transferencias.

La apertura puede corregirse únicamente mientras la cuenta no tenga movimientos y su fecha inicial no alcance ningún período cerrado. El nombre y el estado pueden cambiar. Una cuenta inactiva conserva su historial; no se usa en nuevos movimientos ni como nueva asignación en una edición. Una corrección de un movimiento existente puede mantener su cuenta inactiva, validando los saldos.

Desde 008, una cuenta sin ingresos ni transferencias se elimina físicamente si su apertura tampoco alcanza un período cerrado; el saldo inicial por sí solo no se considera movimiento. En cualquier otro caso solo puede borrarse lógicamente, y únicamente con saldo derivado actual exactamente cero. Una cuenta con saldo distinto de cero se conserva. Las cuentas inactivas heredadas con saldo cero se ocultan de las vistas normales; las que mantienen saldo aparecen como pendientes de revisión y siguen formando parte del total hasta resolverlas.

El saldo de cada cuenta al final de toda fecha afectada debe ser no negativo, incluyendo las fechas posteriores afectadas por ediciones o borrados retroactivos.

### 8. `transfers`

**Propósito:** movimientos internos de dinero, sin considerarlos ingresos ni gastos.

**PK:** `id uuid`.

**Columnas principales:** `user_id`, `period_id uuid`, `date date`, `amount numeric(20,2)`, `from_savings_account_id uuid` opcional, `to_savings_account_id uuid` opcional, `description text` opcional.

**Relaciones:** propietario en `auth.users`; FK compuestas al período y a cada cuenta de ahorro indicada.

**Restricciones:** importe positivo; fecha no futura y perteneciente a un período abierto para cualquier mutación, incluso entre dos cuentas de ahorro. Los extremos solo permiten estas combinaciones:

| Origen ahorro | Destino ahorro | Significado |
| --- | --- | --- |
| Ausente | Cuenta | Disponible → ahorro |
| Cuenta | Ausente | Ahorro → disponible |
| Cuenta A | Cuenta B distinta | Ahorro → ahorro |

Ambos extremos ausentes o la misma cuenta en ambos extremos son inválidos. El tipo se deduce de los extremos; no requiere otra columna.

Cada transferencia tiene una única fila y sus efectos se aplican atómicamente. Disponible → ahorro debe dejar disponible no negativo en su fecha. Las cuentas de ahorro afectadas deben conservar saldos diarios no negativos. Los gastos posteriores pueden dejar negativo el disponible; esta restricción no convierte el disponible en un saldo siempre no negativo.

### 9. `period_category_budgets`

**Propósito:** límites de gasto por categoría dentro de un período.

**PK:** `id uuid`.

**Columnas principales:** `user_id`, `period_id uuid`, `category_id uuid`, `amount numeric(20,2)`.

**Relaciones:** propietario en `auth.users`; FK compuestas al período y a la categoría.

**Restricciones:** unicidad de `(user_id, period_id, category_id)`; importe mayor o igual a cero. Crear, editar o borrar solo en período abierto. Las nuevas asignaciones usan categorías activas; desactivarlas conserva presupuestos existentes. El presupuesto general y los de categoría son límites independientes: no se exige que sumen lo mismo ni alteran saldos.

### 10. `financial_operations`

**Propósito:** idempotencia de las peticiones monetarias; no es un libro de movimientos ni una segunda fuente para calcular saldos.

**PK:** `id uuid`.

**Columnas principales:**

- `user_id`, `idempotency_key uuid`: clave reutilizada por el cliente al reintentar una misma acción.
- `operation_type text`: tipo de acción admitida por el backend, incluida creación, edición, borrado y transición de períodos.
- `request_hash text`: huella calculada por el backend sobre el tipo y los parámetros normalizados.
- `result jsonb`: respuesta estable, con los identificadores y datos necesarios para responder a un reintento.

**Relaciones:** propietario en `auth.users`. Los identificadores incluidos en el resultado son comprobantes de la operación, sin FK al movimiento: deben conservarse aunque este se borre posteriormente.

**Restricciones:** unicidad de `(user_id, idempotency_key)`. Una misma clave con parámetros distintos se rechaza. Una misma clave con los mismos parámetros devuelve el resultado guardado sin repetir los efectos, incluso si el período ya se cerró o el movimiento fue borrado después.

Solo se persisten operaciones completadas, en la misma transacción que sus cambios financieros. Un fallo revierte tanto los cambios como su registro; no hace falta un estado «pendiente». Las filas confirmadas son inmutables y no se borran al borrar movimientos.

En 003, `create_first_period` y `create_savings_account` reciben `p_request_id uuid`, almacenado como `idempotency_key`. Tras adquirir el bloqueo común, normalizan los importes a `numeric(20,2)` sin redondear entradas inválidas y los nombres con `btrim`. El helper privado `financial_request_hash` calcula SHA-256 nativo de PostgreSQL sobre JSONB con el tipo de operación y sus parámetros normalizados. No incluye la fecha actual ni valores derivados de la configuración que puedan cambiar entre reintentos.

Si la clave ya existe, se comparan tipo y huella: una petición distinta falla; la misma devuelve la instantánea JSONB de la fila creada, guardada en `result`, sin repetir efectos ni reevaluar reglas temporales. La respuesta sigue siendo la original aunque después se renombre la cuenta. La creación, el bloqueo de moneda y el registro se confirman en la misma transacción. Al establecer `currency_locked_at` por primera vez, también se incrementan la versión y el timestamp de configuración; un retry no los modifica.

## Saldos y validaciones transaccionales

El disponible se calcula con la fórmula de la especificación dentro de su período. El ahorro se calcula por cuenta a lo largo del tiempo, sin reiniciarse al cambiar de período. No hacen falta tablas adicionales de balances, asientos duplicados ni resúmenes diarios.

Las siguientes operaciones necesitarán RPC/transacciones seguras posteriormente:

- Crear, editar o borrar gastos, ingresos y transferencias: comprobar propietario, fecha local, período abierto, referencias y saldos afectados. Una edición valida tanto los datos anteriores como los nuevos; nunca traslada un movimiento a un período cerrado o inexistente.
- Validar cambios retroactivos desde la primera fecha afectada. En ahorro se recalculan los cierres diarios posteriores de todas las cuentas afectadas. En disponible se comprueba la restricción de las transferencias hacia ahorro afectadas por el cambio, manteniendo permitidos los negativos causados por gastos o arrastre.
- Crear la primera cuenta de ahorro y el primer período: validar saldos iniciales, confirmar el saldo inicial del primer período y bloquear la moneda.
- Cerrar un período y abrir el siguiente: validar límites y movimientos existentes, calcular y guardar el saldo final, cerrar el anterior y copiar automáticamente el arrastre. Todo se confirma junto; no hay dos períodos abiertos transitoriamente para otras peticiones.
- Cambiar presupuestos: comprobar dentro de la transacción que el período sigue abierto.

Desde 003, `private.lock_current_user()` obtiene `auth.uid()`, rechaza sesiones sin usuario y adquiere un advisory lock transaccional mediante `pg_advisory_xact_lock(hashtextextended(uuid::text, 0))`. No recibe un propietario del cliente ni requiere que exista `user_settings`; se libera automáticamente al terminar la transacción. Una colisión del hash solo serializa usuarios independientes, sin mezclar sus datos. El helper no es ejecutable por `anon` ni `authenticated`.

Las siete RPC mutantes de 002 se reemplazan en 003 para usar este mismo bloqueo como primera acción, manteniendo sus contratos. También lo usan todas las RPC de períodos y ahorro de 003; las futuras mutaciones financieras deberán seguir el mismo mecanismo. Las creaciones consultan `financial_operations` bajo el bloqueo antes de aplicar efectos; la unicidad de la clave por usuario es una protección adicional contra duplicados.

001 habilita RLS en las diez tablas, sin policies: quedan cerradas por defecto para los roles sujetos a RLS hasta la siguiente migración de seguridad/API. La implementación posterior deberá impedir escrituras directas que eludan las validaciones transaccionales, obtener el usuario autenticado en el backend y verificar también sus referencias. Aquí no se definen políticas ni funciones SQL.

### Límite de la migración 001

`001_initial_schema.sql` garantiza estructura, tipos, checks locales, unicidades, ownership por FK diferidas y exclusión de períodos solapados; también habilita RLS sin policies. Los defaults inicializan timestamps y versiones; no los actualizan automáticamente.

Quedan para la siguiente migración de lógica backend: policies RLS y acceso autorizado, `expected_version` e incremento de versión/`updated_at`, inmutabilidad de operaciones y períodos cerrados, idempotencia completa, bloqueo de moneda, validación de zona horaria, fechas no futuras y pertenencia a los límites del período, referencias activas, fechas iniciales de ahorro, saldos y arrastre, confirmación inicial y transiciones cronológicas. También se validará la precisión de entrada antes de convertir a `numeric(20,2)`, ya que el tipo por sí solo redondea decimales adicionales. No se intenta resolver estas reglas con checks que consulten otras filas ni con triggers en 001.

## Decisiones de alcance

Las migraciones 001–010 tienen las diez tablas anteriores. 011 añade `external_expense_sources`. El presupuesto general reside en `budget_periods`; los presupuestos de categoría necesitan su tabla por ser múltiples. Disponible no es una cuenta persistida, y los destinos de ingresos y transferencias se deducen de sus referencias opcionales.

No se añaden tablas para comercios, notas, recurrencias automáticas, monedas, tipos de período ni perfiles que dupliquen Auth. Tampoco hace falta un libro mayor adicional: gastos, ingresos y transferencias son la fuente de los movimientos; solo el cierre de período conserva un saldo final.

La futura opción «Empezar de cero» no necesita tabla propia. Deberá borrar transaccionalmente los datos financieros del usuario, incluido su registro de operaciones, conservar `auth.users` y permitir reiniciar la configuración financiera bloqueada. Su implementación sigue fuera de v1.

## Semántica temporal implementada en 004

004 añade creación, edición y borrado de gastos, ingresos y transferencias. El
cliente envía fechas `date`, nunca `period_id`: el servidor obtiene el único
período `open`, comprueba sus límites inclusivos y el día local del usuario. Una
edición conserva el período original. Los importes se validan antes de convertir
a `numeric(20,2)`, sin redondeo y sin valores no finitos.

Cada fecha se interpreta como un **cierre diario neto**, sin orden intradía por
UUID, creación o actualización. El disponible al cierre de D es el saldo inicial
del período, más ingresos a disponible y transferencias ahorro → disponible con
fecha ≤ D, menos gastos con `funding_type = 'available'` y transferencias disponible → ahorro con fecha ≤ D (desde 011).
Solo se exige disponible ≥ 0 en fechas que contienen al menos una transferencia
disponible → ahorro. En el mismo día, todos los movimientos se compensan; un
ingreso de un día posterior nunca financia una transferencia anterior. Un gasto
posterior sí puede dejar negativo el disponible. Un gasto del mismo día que una
transferencia a ahorro se rechaza si hace negativo ese cierre diario.

El ahorro al cierre de D suma opening_balance, ingresos directos y transferencias
recibidas hasta D, menos transferencias enviadas hasta D, incluyendo todos los
períodos. Se exige no negatividad en todas las fechas afectadas. No se almacenan
balances diarios ni saldo actual. Los días sin movimientos conservan su saldo.

Después de aplicar provisionalmente la mutación se recalculan acumulados sobre
el historial completo; solo se filtran los cierres a comprobar **después** de
calcular la ventana. Para disponible se empieza por la menor fecha original/nueva;
para ahorro se agrupan las cuentas de ambas versiones del movimiento y se usa la
menor fecha afectada de cada cuenta. Se incluye esa fecha incluso si se borró su
último movimiento. Cualquier violación aborta movimiento, versión, timestamp y
registro de idempotencia. Así, con opening 100, transferir 80 el día 1 y gastar 50
el día 2 es válido; transferir 120 el día 1 no se rescata con un ingreso el día 2.

Las nueve RPC adquieren primero `private.lock_current_user()`. Bajo ese bloqueo,
la huella SHA-256 de 003 incluye todos los campos de la petición y, para editar o
borrar, id y expected_version. Se normaliza amount; los textos se conservan
exactamente (NULL y texto vacío son distintos). El retry precede a la búsqueda
de la fila y a las reglas dependientes del estado: devuelve el JSONB original
aunque la fila se haya editado/borrado. Create/update devuelven la fila; delete
retorna `{"deleted": true, "movement": <fila anterior>}`. Las referencias inactivas
solo pueden conservarse en el mismo campo; intercambiar extremos de una
transferencia constituye nuevas asignaciones.

Las RPC 004 requieren READ COMMITTED y rechazan otros niveles con `25001`.
Esto asegura que las consultas VOLATILE posteriores a la espera del advisory
lock puedan ver el commit anterior; un snapshot fijado antes del bloqueo sería
insuficiente para proteger las sumas. El lock dura hasta terminar la transacción.
Los helpers tienen search_path vacío y no son ejecutables por PUBLIC, anon ni
authenticated; se mantienen las políticas de lectura propia y la prohibición de
DML directo de 002. Las transiciones de período y presupuestos se añaden en 005.


## Transiciones y presupuestos implementados en 005

`advance_period(current_period_id, expected_version, mode, start_date, end_date,
request_id, general_budget DEFAULT NULL)` cierra y abre en una sola transacción.
No recibe saldo inicial nuevo. Devuelve `{"closed_period": <fila>,
"opened_period": <fila>}` y registra esa instantánea en `financial_operations`.
Primero adquiere el lock común; después valida la clave y huella, antes de
consultar el período actual o el día local. Un retry exacto conserva su respuesta
incluso después del cierre; cambiar cualquier parámetro, incluida la versión,
con la misma clave produce `22023`. La versión obsoleta produce `40001`; un
período ajeno, inexistente o cerrado produce `P0002` en la API de presupuestos y
transiciones. Solo hay una firma de cada RPC.

El nuevo período debe contener hoy según la timezone del usuario: mes/año
natural actual, custom con ambas fechas o between_paydays con inicio no futuro
y final NULL. El **modo anterior** determina el cierre: si era between_paydays,
su final pasa a `new_start - 1`; si tenía fechas fijas, conserva su final. Se
permiten huecos, sin generar períodos vacíos. Se rechaza cualquier movimiento
que quedaría fuera del período anterior; no se trasladan movimientos. No se
permite insertar un período antes de historia ya existente.

El cierre usa exclusivamente disponible: saldo inicial + ingresos a disponible
+ transferencias ahorro → disponible − transferencias disponible → ahorro −
gastos con `funding_type = 'available'` (desde 011). Excluye gastos externos, ingresos directos a ahorro, transferencias entre ahorros y todos
los presupuestos. `private.available_daily` centraliza esta fórmula y el neto
por DATE; 005 reemplaza `private.check_available` para consumirla, conservando
las reglas de 004. `private.available_at` toma el último cierre diario hasta la
fecha pedida, incluyendo el saldo inicial cuando no hay movimientos. Los
archivos 001–004 no cambian. Un cierre fuera del rango de numeric(20,2) se
rechaza sin efectos.

El cierre incrementa versión y updated_at, fija closed_at y guarda closing_balance.
El nuevo período tiene versión 1 y exactamente ese saldo inicial, incluso
negativo; no genera ningún ingreso ni transferencia. No hay reapertura ni
mutación de períodos cerrados mediante estas RPC. Los retries financieros
siguen devolviendo resultados históricos sin ejecutar nuevas mutaciones.

`set_general_budget(period_id, general_budget, expected_version)` admite NULL
para quitar el límite, cero o positivo. `create_category_budget(period_id,
category_id, amount)`, `update_category_budget(id, expected_version, amount)` y
`delete_category_budget(id, expected_version)` requieren un período propio
abierto. Crear exige categoría activa; actualizar o borrar permite conservar
una categoría desactivada. No se cambian category_id ni period_id al actualizar.
Crear/actualizar devuelven la fila; borrar devuelve `{"deleted": true,
"budget": <fila anterior>}` y elimina físicamente esa fila. La unicidad de
categoría/período rechaza duplicados con `23505`. Actualizar incrementa versión
y updated_at; borrar valida expected_version antes de eliminar.

Los presupuestos son planificación: no alteran saldos ni movimientos, no se
registran en financial_operations y gastar por encima de ellos está permitido.
El general y los de categoría son independientes, sin obligación de que sumen
lo mismo. No se arrastra presupuesto sin usar ni se copia al siguiente período.
El general nuevo solo se establece si se envía; NULL significa sin límite.
`private.budget_amount` valida precisión, finitud, rango y no negatividad antes
del cast; el importe por categoría nunca admite NULL.

Las cinco RPC adquieren `private.lock_current_user()` como primera acción y
requieren READ COMMITTED. `private.open_budget_period` comprueba aislamiento y
período propio abierto bajo ese lock. Se mantienen RLS de lectura propia, DML
directo prohibido y journal privado; helpers sin EXECUTE para PUBLIC, anon ni
authenticated y RPC públicas con EXECUTE explícito solo para authenticated.
Las cinco RPC adquieren `private.lock_current_user()` como primera acción y
requieren READ COMMITTED. `private.open_budget_period` comprueba aislamiento y
período propio abierto bajo ese lock. Se mantienen RLS de lectura propia, DML
directo prohibido y journal privado; helpers sin EXECUTE para PUBLIC, anon ni
authenticated y RPC públicas con EXECUTE explícito solo para authenticated.

## API derivada de lectura en 006

006 añade cuatro RPC `STABLE`, `SECURITY DEFINER`, con `search_path` vacío,
identidad derivada de `auth.uid()` y ownership explícito en todas las consultas.
No reciben user_id, no toman advisory locks, no escriben datos ni journal y no
incrementan versiones. Se mantienen las lecturas de filas mediante RLS: estas
RPC solo devuelven cálculos derivados. Todos los resultados son JSONB, con
importes calculados como numeric, sin float ni porcentajes.

`private.read_today()` exige sesión (`28000`) y configuración (`P0002`). Usa
`statement_timestamp()` en la timezone configurada: el día queda fijo durante
la llamada, sin depender de la timezone del servidor ni del inicio de una
transacción larga. Todas las RPC de esta capa requieren configuración.

- `get_current_financial_state()` devuelve `as_of_date`, `current_period`,
  disponible, ingresos externos separados por destino, gastos, transferencias
  hacia/desde disponible y presupuesto general con gasto y remanente. Incluye
  `savings_balances`. Sin período abierto, los campos del período y sus totales
  son NULL; el ahorro existente sigue apareciendo. Con período vacío, sus
  totales son cero y available es opening_balance.
- `get_savings_balances()` devuelve un array, vacío si no hay cuentas. Incluye
  activas e inactivas con id, nombre, fecha inicial, saldo inicial, estado,
  versión y current_balance. Desde 008, `private.savings_balances_at(date)` usa
  `private.savings_account_balances_at(date)`, la misma fuente canónica
  que valida el borrado, para sumar saldo inicial, ingresos directos y
  transferencias hasta el día local a través de todos los períodos. Orden:
  activas primero, lower(btrim(name)), id. `check_savings` sigue dedicado a
  validar toda la historia diaria, no a devolver un saldo puntual.
- `get_period_summary(period_id)` usa `private.period_summary_at(period_id,
  today)`, compartido con el estado actual. Devuelve `period` y los mismos
  totales al día local para open o al end_date para closed. Incluye tanto
  opening_balance como closing_balance almacenado y available derivado.
  No sustituye ni corrige un cierre almacenado distinto del cálculo; ambos
  valores permiten detectar la incoherencia. UUID ajeno, inexistente o NULL
  produce `P0002` sin revelar datos. Solo las transferencias entre disponible
  y ahorro cuentan en transfer_to_savings_total/transfer_from_savings_total.
- `get_category_budget_usage(period_id)` devuelve un array con la unión de
  categorías presupuestadas o con gasto, incluyendo categorías inactivas.
  Cada objeto contiene category_id/name/is_active, budget_id/amount/version,
  spent y remaining. Sin presupuesto, sus campos y remaining son NULL; sin
  gasto, spent es cero. Orden: spent descendente, nombre normalizado, id.
  Categorías sin gasto ni presupuesto no aparecen. También valida ownership.

Los presupuestos no alteran available: general_budget_spent es expenses_total
y remaining es presupuesto menos gasto; NULL conserva ausencia de límite,
cero es válido y los remanentes negativos se muestran sin restringir el gasto.
No hay índices, tablas, vistas materializadas ni saldos persistidos nuevos.

### Snapshot compartido y reutilización del disponible

006 cambia **solo el atributo de volatilidad** de `private.available_daily` y
`private.available_at` a STABLE, conservando sus cuerpos, firmas y ACL. Ambos
son exclusivamente SELECT. Esto es necesario para reutilizar la fórmula de 005
sin que un helper VOLATILE adquiera un snapshot posterior dentro de una lectura
compuesta. Toda la cadena de lecturas es STABLE y usa el snapshot de la sentencia.
Véase la [semántica de volatilidad de PostgreSQL](https://www.postgresql.org/docs/current/xfunc-volatility.html).

Los archivos 001–005 permanecen intactos. Las RPC mutantes y `check_available`
siguen VOLATILE: después del bloqueo y del DML provisional ejecutan otra consulta.
Los helpers STABLE heredan el snapshot de **esa consulta posterior**, que ya ve
sus cambios, no el snapshot de entrada de la RPC mutante. No se cambia el lock,
el aislamiento requerido ni la fórmula de validación. El smoke 006 incluye create/update/delete y rechazos por saldo insuficiente para
comprobar esta integración, además de cierres positivos y negativos mediante 005.

## Borrado de catálogos y ahorro en 008

008 añade `delete_category` y `delete_payment_method`, ambas con lock por usuario,
ownership y `expected_version`. Eliminan físicamente una fila nunca utilizada;
si existen gastos o presupuestos que la referencian, solo fijan `is_active=false`.
Las FK continúan en `NO ACTION` y ninguna operación borra movimientos ni
presupuestos. `get_catalog_management()` devuelve únicamente los elementos
activos y el indicador de uso que permite presentar «Eliminar» o «Borrar»; la
decisión se vuelve a calcular dentro de la mutación.

`delete_savings_account(id,expected_version,request_id)` usa el mismo advisory
lock, huella y journal idempotente que las mutaciones financieras. Tras el lock
vuelve a comprobar versión, propietario, ingresos, ambos extremos de
transferencias, contexto histórico cerrado y saldo canónico actual. Sin
movimientos y sin alcanzar un período cerrado hace hard delete. En los demás
casos solo hace soft delete cuando el saldo es exactamente cero. Con saldo no
cero responde `{"mode":"blocked","code":"ACCOUNT_HAS_BALANCE","balance":...}`
sin mutar ni registrar un éxito. Hard y soft delete devuelven un `mode` estable
y sí quedan en `financial_operations` para que el retry sea idéntico.

`correct_savings_opening_balance` es la única vía para corregir la apertura:
requiere ausencia de movimientos y de períodos cerrados alcanzados por la fecha
inicial, además de versión e idempotencia. Los tres índices de nombres pasan a
ser únicos parciales sobre filas activas. No se transforma ninguna fila inactiva
existente: saldo cero se oculta del uso normal y saldo distinto de cero permanece
en totales y en la sección de compatibilidad «Cuentas por revisar».

## Contrato de exportación en 010

`get_data_export(start_date DEFAULT NULL, end_date DEFAULT NULL)` es una RPC
`STABLE`, `SECURITY DEFINER`, de solo lectura. Obtiene la identidad exclusivamente
de `auth.uid()`, exige configuración financiera y filtra por propietario en cada
tabla y relación. `anon` y `PUBLIC` no pueden ejecutarla. Dos fechas `NULL`
significan todo el historial hasta el día local; de lo contrario ambas son
obligatorias, inclusivas, ordenadas y no posteriores a `private.read_today()`.

El resultado contiene `settings` no sensibles, `range`, movimientos reales,
snapshots de saldo, cuentas de ahorro, períodos, presupuestos, categorías y
métodos de pago. No incluye Auth, secretos ni `financial_operations`. Los
importes se devuelven como texto decimal exacto para que JSON/JavaScript no los
convierta implícitamente a coma flotante. Las referencias inactivas conservadas
por historia se resuelven mediante sus filas existentes.

`movements` contiene exclusivamente ingresos, gastos y transferencias. Cada
transferencia aparece una vez. `balances` contiene registros sintéticos
`opening`/`closing`, separados de los movimientos y sin `referencia_id`. Para
Disponible reutiliza `private.available_at`; para ahorro reutiliza
`private.savings_account_balances_at`. En un rango, el snapshot inicial refleja
el estado anterior a los movimientos del primer día y el final incluye todos los
movimientos del último día. Las cuentas que empiezan dentro del rango presentan
su `opening_balance` en su fecha real de inicio.

Los `opening_balance` de períodos y cuentas siguen siendo estado inicial, nunca
filas de `incomes`. El saldo inicial de un período posterior sigue siendo el
arrastre de su predecesor: puede repetirse como snapshot junto al saldo final
anterior para explicar la frontera, pero no se suma como dinero nuevo. La
exportación no persiste saldos, no modifica estadísticas y no cambia ninguna
fórmula financiera.

El CSV cliente combina ambas colecciones con `clase = Movimiento|Saldo`; usa
punto y coma, CRLF y UTF-8 con BOM, sin línea `sep=`, y conserva importes sin
símbolo con la moneda separada. El XLSX mantiene movimientos y saldos en hojas
distintas y añade las hojas de configuración legible. La construcción del XLSX
es local y no altera el contrato SQL.


## 011 — Orígenes externos de gastos

Los gastos externos **sí son gastos**: consumen presupuesto general y por categoría
y cuentan en estadísticas, evolución y totales de consumo. **No reducen Disponible**.
El origen financiero es independiente de `payment_methods`: por ejemplo, método
Tarjeta y origen externo Itaú. El catálogo no tiene saldo y no modela deuda,
tarjetas de crédito ni una segunda cuenta financiera.

### `external_expense_sources`

`id`, `user_id`, `name`, `is_active`, `created_at`, `updated_at`, `version`.
Nombres no vacíos; únicos por usuario entre activos sobre `lower(btrim(name))`.
RLS permite solo SELECT propio; no hay DML directo para clientes. Crear,
renombrar y borrar usan el lock común; renombrar y borrar exigen `expected_version`.
Sin referencias se elimina físicamente; con gastos históricos se desactiva.
El nombre desactivado sigue resolviendo en historial, desgloses y exportaciones;
puede reutilizarse para una fuente nueva con otro UUID. Renombrar cambia también
el nombre mostrado en historia, igual que categorías y métodos.

Todos los gastos anteriores reciben `available` mediante el default NOT NULL.
El check exige `external_source_id IS NULL` para `available` y una fuente para
`external`; la FK compuesta impide referencias cruzadas entre usuarios.
Una edición puede conservar su propia fuente inactiva; un alta o nueva asignación
requiere una fuente activa.

Disponible = saldo inicial + ingresos a Disponible + ahorro → Disponible
− Disponible → ahorro − **solo gastos available**.
`private.available_daily` sigue siendo la fuente canónica para `available_at`,
`check_available`, cierres, arrastres y snapshots exportados. Las ediciones
validan desde la menor fecha original/nueva; los cambios de financiación no
pueden invalidar retiradas posteriores a ahorro. Se conservan fechas locales,
período abierto, ownership, lock común, expected_version e idempotencia.

`private.expense_funding_breakdown` agrupa por tipo y UUID de origen, con importes
exactos en texto. Resúmenes exponen `expenses_funding_breakdown`; presupuesto
por categoría expone `funding_breakdown`. No se filtran externos en los totales
presupuestarios. El cliente presenta el desglose y no calcula Disponible.

Las RPC `create_expense_with_funding` / `update_expense_with_funding` reciben
`p_funding_type` y `p_external_source_id`. Las firmas originales permanecen:
crear usa Disponible y editar conserva el origen existente. Ambas APIs llaman
al mismo core privado; la antigua mantiene la huella original de idempotencia,
incluidos reintentos registrados antes de 011. Delete reutiliza el helper
canónico sin cambiar su contrato. No hay overloads ambiguos en PostgREST.

`get_data_export` añade `funding_type` y `external_source` a movimientos y el
catálogo `external_sources`. `origin` resuelve el nombre de la fuente para gastos
externos. CSV y XLSX de historial añaden al final `origen_gasto` (Disponible /
Externo) y `origen_externo`; los movimientos que no son gasto y las filas de saldo
los dejan vacíos. XLSX completo añade columnas equivalentes y hoja de orígenes.
No se crean snapshots de saldo para fuentes externas.

Reset borra gastos antes del catálogo de orígenes, en la misma transacción,
y conserva el usuario Auth. No se crea Itaú automáticamente: se registra como
un nombre de catálogo desde Ajustes → Orígenes externos.

Despliegue: **migración 011 → deploy del frontend**. El frontend previo sigue
operando mediante las firmas antiguas; el nuevo requiere la tabla y RPC de 011.
La migración notifica a PostgREST para recargar su esquema. Consultar
[EXTERNAL_EXPENSES_TESTING.md](EXTERNAL_EXPENSES_TESTING.md) antes de producción.


## 012 — Presupuestos distribuidos por origen

### Dos significados explícitos, sin reinterpretar la historia

`budget_periods.budget_model` distingue `legacy_total` de `by_origin`. Al añadir
la columna, **todos los períodos existentes**, abiertos y cerrados, quedan en
`legacy_total`; después se cambia el default de inserción a `by_origin` para los
períodos nuevos. No se actualizan importes, movimientos, versiones ni timestamps
anteriores. La única adición a las filas existentes es esta clasificación.

- En `legacy_total`, el campo físico `budget_periods.general_budget` conserva su
  significado original: límite para **todos** los gastos, incluidos los externos.
  No constituye una asignación a Disponible. No se generan asignaciones por origen
  ni siquiera para períodos históricos sin gastos externos.
- En `by_origin`, ese campo físico representa el componente Disponible, por
  compatibilidad de esquema. El total es la suma de este y las asignaciones
  externas. No existe un total editable adicional.

Un período abierto anterior conserva su modelo general hasta que el usuario
guarda explícitamente la distribución mediante `set_funding_budgets`. El editor
propone el importe anterior para Disponible y avisa del cambio de significado;
el usuario puede ajustarlo. Si conserva 2.000 y añade 500 a Itaú, el total es
2.500. La conversión se confirma junto con los importes y el recibo idempotente;
si falla, permanece el modelo anterior. Un período cerrado nunca se convierte.

### Asignaciones y concurrencia

`period_external_source_budgets` guarda `id`, `user_id`, `period_id`,
`external_source_id`, `amount`, `created_at`, `updated_at`. Hay unicidad por
usuario/período/origen, importe no negativo y FK compuestas con el mismo
propietario. RLS permite SELECT propio, sin DML directo de clientes. La versión
del conjunto es `budget_periods.version`.

`private.period_funding_allocations` devuelve asignaciones únicamente para
`by_origin`. `private.period_budget_total` devuelve el límite original para
`legacy_total` y la suma de asignaciones para `by_origin`. NULL significa sin
presupuesto; cero es un límite explícito. Los presupuestos de categoría son otra
dimensión: no se suman al total y consumen todos los gastos de su categoría.

`set_funding_budgets(p_period_id, p_available_budget, p_external_budgets,
p_expected_version, p_request_id)` adquiere el lock común, normaliza entradas y
ordena orígenes para el hash, reutiliza `movement_retry`, exige READ COMMITTED,
período abierto y versión vigente. Guarda todo, cambia el modelo a `by_origin`,
incrementa una vez la versión y registra el recibo en la misma transacción.
La lista externa es un patch: NULL quita una asignación, cero crea un límite
cero, los orígenes omitidos se conservan. Un retry devuelve el resultado original
incluso después del cierre, sin restaurar importes posteriores.

Una fuente inactiva puede conservar/corregir/quitar una asignación existente en
un período abierto, pero no recibir una nueva. Usarla solo en presupuestos
cuenta como historial para soft-delete. Reset elimina asignaciones antes de
fuentes y períodos, sin cambiar Auth.

### Protección de la RPC antigua

El frontend 011 lee `general_budget::text` directamente de `budget_periods` y lo
edita mediante `set_general_budget` con la etiqueta «Presupuesto». No conoce las
partes externas, aunque sus resúmenes puedan mostrar el total de 012. Por eso
no es seguro inferir qué quiso decir el usuario con un importe de un cliente
antiguo ni restar automáticamente los externos para reinterpretarlo.

`set_general_budget` conserva su firma, lock y control de versión, pero **rechaza
sin efectos cualquier guardado si el período tiene asignaciones externas**,
incluidas asignaciones de cero y peticiones NULL. Con Disponible 2.000 y externo
500, enviar 2.600 no produce 3.100 ni modifica ninguna parte o versión. Debe
actualizarse el frontend y usarse la RPC explícita por origen.

Sin asignaciones externas la RPC sigue funcionando, porque el total y el único
importe editable coinciden: en `legacy_total` modifica el límite general y
conserva el modelo; en `by_origin` modifica el único componente. No se convierte
un período legacy por una llamada antigua. La comprobación de versión precede
al bloqueo de compatibilidad; un editor obsoleto sigue recibiendo `40001`.

Las firmas e idempotencia de creación/transición de períodos permanecen. Sus
nuevos INSERT usan `by_origin`; `p_general_budget` inicializa su único componente,
y NULL no copia presupuestos previos. Cerrar un período legacy conserva su
modelo, importe y significado.

### Contrato de lectura y consumidores

`period.general_budget` es el valor físico, cuyo significado depende del modelo.
**No se usa para mostrar un total ni para editar desde el frontend nuevo**:
se elimina del tipo `BudgetPeriod` y de la consulta `readPeriods`.

`general_budget` **del resumen** siempre es el total canónico del período,
histórico o derivado. `general_budget_spent` incluye todos los gastos y
`general_budget_remaining` resta ese consumo total. `budget_model` declara la
semántica, y `legacy_general_budget` transporta en texto el total heredado para
la propuesta de conversión del editor de un período abierto.

`private.period_funding_usage_at` reutiliza las asignaciones canónicas y el
desglose de gastos de 011. En legacy las filas de gasto pueden mostrarse, pero
`budget_amount` y `remaining` son NULL: no se inventan límites de origen.
En by_origin se muestran límites y consumos propios. La suma de gasto por
origen coincide con `expenses_total`.

Consumidores auditados:

- Inicio, detalle del período y evolución: total canónico del resumen.
- Editor de distribución: asignaciones exactas en texto; en un legacy abierto,
  propuesta separada a partir de `legacy_general_budget`, con aviso al guardar.
- Historial: presupuesto general contra todos los gastos. Solo períodos
  `by_origin` muestran tarjetas de límites por origen.
- Lista de períodos y navegación: metadatos y saldos, sin leer el campo físico
  de presupuesto. Onboarding inicializa el presupuesto; avanzar envía NULL.
- Exportación: total canónico y modelo explícito, sin asignaciones históricas
  ficticias a Disponible.

`expenses_available_total` alimenta «Gasto» de Inicio. Estadísticas, categorías,
evolución y presupuesto total conservan todo el consumo. Los desgloses por origen
se ocultan para usuarios sin fuentes/historial externo. Los porcentajes son de
presentación: se muestra el real, con barra hasta 100 %, exceso en rojo, y se
distinguen presupuesto cero y ausencia de límite. El total del borrador se suma
en céntimos; los totales guardados y saldos proceden del backend.

### Exportación y despliegue

`get_data_export.periods[].general_budget` siempre es total. Añade `budget_model`
y `available_budget`: este último es NULL en legacy, y el componente Disponible
en by_origin. `funding_budgets` exporta solo asignaciones reales de by_origin.
XLSX mantiene el presupuesto histórico en sus hojas de totales/períodos, indica
«General histórico» o «Por origen» y añade las asignaciones reales en
«Presupuestos por origen». CSV/XLSX de historial mantiene el contrato de 011.

Orden seguro: **migración 012 → recarga PostgREST → deploy frontend**. Hasta que
haya asignaciones externas, la edición antigua sigue funcionando. Después,
los clientes antiguos deben actualizarse para editar presupuestos distribuidos;
sus peticiones ambiguas se rechazan conservando los datos. Consultar
[FUNDING_BUDGETS_TESTING.md](FUNDING_BUDGETS_TESTING.md).
