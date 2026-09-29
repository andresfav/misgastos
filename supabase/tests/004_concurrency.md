# 004: pruebas manuales de concurrencia (preparadas, NO ejecutadas)

Usar exclusivamente una base de pruebas con 001–004 aplicadas. Dos terminales
SQL independientes conectadas al mismo servidor como propietario, capaces de
`SET ROLE authenticated`. No usar el editor como sustituto de dos conexiones.
Los comandos de este documento se ejecutarán solo cuando se autorice probarlos.

Todas las transacciones usan **READ COMMITTED**. El advisory lock de 003 se
mantiene hasta COMMIT/ROLLBACK, incluso cuando termina la llamada RPC. Las RPC
004 rechazan otros niveles con `25001`: esperar el lock con un snapshot antiguo
no garantiza ver el saldo confirmado por la otra sesión.

## Preparación de fixtures

Crear un usuario sintético **distinto por escenario**, sin datos previos, mediante
el siguiente bloque como propietario. Sustituir `USER_UUID` por un UUID nuevo y
conservarlo para ambas sesiones. El COMMIT de preparación es necesario para que
las dos conexiones vean los mismos fixtures. Estas son instrucciones futuras;
no forman parte del smoke que termina en ROLLBACK.

```sql
BEGIN ISOLATION LEVEL READ COMMITTED;
INSERT INTO auth.users(id) VALUES ('USER_UUID');
SELECT set_config('request.jwt.claim.sub','USER_UUID',true);
SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub','USER_UUID','role','authenticated')::text,true);
SET LOCAL ROLE authenticated;
SELECT public.configure_user_settings('EUR','UTC');
SELECT public.create_first_period(
    'custom', (clock_timestamp() AT TIME ZONE 'UTC')::date - 1,
    (clock_timestamp() AT TIME ZONE 'UTC')::date + 1, 100, gen_random_uuid());
SELECT public.create_savings_account('Reserva',
    (clock_timestamp() AT TIME ZONE 'UTC')::date - 1, 100, gen_random_uuid());
COMMIT;
```

Guardar el `id` devuelto por la cuenta como `ACCOUNT_UUID`. Usar como `DAY` la
fecha UTC de preparación, literal `YYYY-MM-DD`, idéntica en ambas sesiones.
No cambiar de día durante el escenario. Cada `REQUEST_A`, `REQUEST_B` o
`SHARED_REQUEST` representa un UUID literal generado previamente. No sustituir
un request compartido por dos llamadas a `gen_random_uuid()`.

Abrir **en ambas sesiones**, antes de las llamadas del escenario:

```sql
BEGIN ISOLATION LEVEL READ COMMITTED;
SET LOCAL statement_timeout = '2min';
SELECT set_config('request.jwt.claim.sub','USER_UUID',true);
SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub','USER_UUID','role','authenticated')::text,true);
SET LOCAL ROLE authenticated;
```

Lanzar primero la RPC de sesión A; dejar su transacción abierta. Lanzar la RPC
de sesión B: debe quedar esperando. Mientras B espera, ejecutar `COMMIT` en A.
Tras un error, B debe ejecutar `ROLLBACK`; tras éxito, `COMMIT`.

## 1. Dos transferencias desde disponible

Disponible inicial 100, sin otros movimientos. Peticiones distintas:

Sesión A:

```sql
SELECT public.create_transfer('DAY',80,NULL,'ACCOUNT_UUID',NULL,'REQUEST_A');
-- Dejar abierto hasta que B esté esperando; después COMMIT.
```

Sesión B:

```sql
SELECT public.create_transfer('DAY',80,NULL,'ACCOUNT_UUID',NULL,'REQUEST_B');
```

Resultado esperado: A confirma una transferencia de 80. B despierta, ve el
saldo confirmado y falla `22023`. Disponible final 20. No queda movimiento ni
`financial_operations` con `REQUEST_B`.

## 2. Dos retiradas de la misma cuenta de ahorro

Fixture nuevo, ahorro inicial 100. Repetir el protocolo anterior con:

```sql
-- A
SELECT public.create_transfer('DAY',80,'ACCOUNT_UUID',NULL,NULL,'REQUEST_A');
-- B
SELECT public.create_transfer('DAY',80,'ACCOUNT_UUID',NULL,NULL,'REQUEST_B');
```

A confirma; B falla `22023`. Ahorro final 20, una sola transferencia y ningún
registro para `REQUEST_B`.

## 3. Dos requests idénticas simultáneas

Fixture nuevo. En **ambas** sesiones enviar exactamente:

```sql
SELECT public.create_transfer('DAY',80,NULL,'ACCOUNT_UUID',NULL,'SHARED_REQUEST');
```

B espera hasta COMMIT de A y devuelve el JSONB original, incluidos `id`,
`version`, `created_at` y `updated_at`. Guardar y comparar ambos resultados.
Ambas transacciones confirman, pero hay una sola transferencia y un solo
registro de operación para `SHARED_REQUEST`; disponible final 20.

Repetir con fixture nuevo haciendo **ROLLBACK en A**: B debe crear el único
efecto confirmado, porque el registro no confirmado de A desapareció.

Variante útil: repetir con un request compartido y distinto importe en B.
Tras COMMIT de A, B debe fallar `22023` por reutilización del request, sin otro
efecto. Esto se comprueba antes de evaluar los saldos.

## 4. Ediciones simultáneas con la misma versión

Fixture nuevo. Crear y confirmar previamente un ingreso:

```sql
-- Transacción autenticada de preparación usando el encabezado común.
SELECT public.create_income('DAY',10,NULL,'original',gen_random_uuid());
COMMIT;
```

Guardar su `id` como `INCOME_UUID`; la versión inicial debe ser 1. Abrir las
transacciones de ambas sesiones con el encabezado común.

```sql
-- A, mantener abierta hasta que B espere:
SELECT public.update_income('INCOME_UUID',1,'DAY',20,NULL,'A','REQUEST_A');
-- B:
SELECT public.update_income('INCOME_UUID',1,'DAY',30,NULL,'B','REQUEST_B');
```

Después de COMMIT de A, B falla `40001` y hace ROLLBACK. El ingreso debe tener
amount 20, description `A` y version 2; solo existe el registro de `REQUEST_A`.
Una petición nueva requiere releer la versión. Un retry exacto de `REQUEST_A`
con expected_version 1 debe devolver el resultado original aunque la fila ya
sea versión 2.

## Comprobaciones y limpieza

Tras finalizar las dos sesiones, inspeccionar como propietario (nunca conceder
al cliente acceso a `financial_operations`):

```sql
SELECT id, date, amount, from_savings_account_id, to_savings_account_id, version
FROM public.transfers WHERE user_id='USER_UUID';
SELECT id, date, amount, description, version
FROM public.incomes WHERE user_id='USER_UUID';
SELECT idempotency_key, operation_type, result
FROM public.financial_operations WHERE user_id='USER_UUID'
ORDER BY created_at, id;
```

Para 1–3 comprobar explícitamente una sola transferencia y un solo registro
`create_transfer`. Las dos operaciones de preparación (período y cuenta)
también están en `financial_operations`: no contarlas como efectos duplicados.
En 4 comparar la fila y las claves de edición con los resultados esperados.

Solo después de cerrar las transacciones y revisar resultados, eliminar como
propietario **únicamente** los usuarios sintéticos creados para estas pruebas:

```sql
BEGIN;
DELETE FROM auth.users WHERE id='USER_UUID';
COMMIT;
```

Las FK del esquema borran sus datos asociados. No reutilizar UUID de un usuario
real. Ninguno de estos escenarios sustituye las pruebas temporales A–E del smoke.
