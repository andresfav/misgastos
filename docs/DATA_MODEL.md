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
- Todas las FK `user_id → auth.users(id)` usan `ON DELETE CASCADE`. Las relaciones internas financieras y de catálogos usan `ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED` en 001, nunca cascadas que borren movimientos accidentalmente. La comprobación diferida permite eliminar todo el grafo al borrar un usuario antes de validar las FK internas. Categorías, métodos y cuentas se desactivan en el uso ordinario.
- Los nombres de categorías, métodos de pago y cuentas de ahorro son únicos por usuario mediante `lower(btrim(name))`, incluyendo entidades inactivas. Los espacios exteriores y las diferencias de mayúsculas no permiten duplicados.

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

**Restricciones:** nombre no vacío. Desactivar y restaurar solo cambia su disponibilidad para nuevas asignaciones; no elimina referencias históricas. Renombrar actualiza el nombre mostrado también en el historial, sin duplicar categorías.

### 3. `payment_methods`

**Propósito:** métodos de pago propios que pueden asociarse a gastos.

**PK:** `id uuid`.

**Columnas principales:** `user_id`, `name text`, `is_active boolean` (inicialmente verdadero).

**Relaciones:** propietario en `auth.users`; referenciada opcionalmente por gastos.

**Restricciones:** nombre no vacío. Misma regla de desactivación, restauración y renombrado que las categorías. Un método de pago no es una cuenta ni tiene saldo.

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

**Propósito:** salidas de dinero disponible.

**PK:** `id uuid`.

**Columnas principales:**

- `user_id`, `period_id uuid`, `date date`, `amount numeric(20,2)`.
- `category_id uuid`.
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

La fecha y el saldo inicial quedan fijados al crear la cuenta para impedir cambios indirectos del historial. El nombre y el estado pueden cambiar. Una cuenta inactiva conserva su historial; no se usa en nuevos movimientos ni como nueva asignación en una edición. Una corrección de un movimiento existente puede mantener su cuenta inactiva, validando los saldos.

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

Se proponen exactamente las diez tablas anteriores. El presupuesto general reside en `budget_periods`; los presupuestos de categoría necesitan su tabla por ser múltiples. Disponible no es una cuenta persistida, y los destinos de ingresos y transferencias se deducen de sus referencias opcionales.

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
fecha ≤ D, menos gastos y transferencias disponible → ahorro con fecha ≤ D.
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
DML directo de 002. No se implementan transiciones de período ni presupuestos.
