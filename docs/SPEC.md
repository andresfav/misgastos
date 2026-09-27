# MisGastos — Especificación funcional

## Propósito y alcance inicial

MisGastos es una aplicación de finanzas personales multiusuario. Cada usuario gestiona exclusivamente sus datos: gastos, ingresos, dinero disponible, períodos financieros, ahorro y presupuestos.

La primera versión incluye estas entidades y las reglas descritas a continuación, junto con categorías, métodos de pago y configuración personal. El proyecto empieza desde cero, sin reutilizar ni adaptar código de expense-tracker ni importar su historial.

Este documento define el comportamiento funcional; no incluye SQL, conexiones a Supabase ni diseño de pantallas o estructura frontend. El backend se construirá primero. El frontend posterior será nuevo, responsive, mobile-first y PWA.

## Entidades

### Gastos

Un gasto es una salida de dinero disponible y pertenece a un período financiero según su fecha.

- Datos obligatorios: fecha, importe y categoría.
- Datos opcionales: descripción, método de pago, comercio, nota e indicación de recurrente.

La indicación de recurrente no implica generación automática de gastos en esta versión. No se permiten gastos directos desde ahorro.

### Ingresos

Un ingreso es dinero nuevo que entra desde fuera. Tiene fecha, importe y un destino: dinero disponible o una cuenta de ahorro.

Los ingresos se atribuyen al período correspondiente a su fecha. Todos cuentan como ingresos para las estadísticas. Un ingreso dirigido directamente a ahorro aumenta esa cuenta, pero no el dinero disponible. Las transferencias internas y los saldos iniciales no son ingresos.

### Dinero disponible

Es el saldo para gastar dentro de un período, calculado a partir de su saldo inicial y los movimientos acumulados hasta la fecha consultada:

```text
Disponible = saldo inicial del período
           + ingresos dirigidos a disponible
           + transferencias ahorro → disponible
           - transferencias disponible → ahorro
           - gastos
```

Los ingresos directos a ahorro, las transferencias entre cuentas de ahorro y los presupuestos no modifican el disponible.

El disponible puede quedar negativo por gastos, correcciones o arrastre negativo. Sin embargo, una transferencia de disponible a ahorro se rechaza si deja el disponible por debajo de cero en la fecha de la transferencia. La validación utiliza el saldo de esa fecha, no solo el saldo actual.

### Períodos financieros

Cada usuario tiene una única línea temporal de períodos, sin solapamientos, y como máximo un período financiero abierto. Los modos son:

- `monthly`: mes natural completo.
- `annual`: año natural completo.
- `custom`: fechas de inicio y fin elegidas por el usuario.
- `between_paydays`: fecha inicial obligatoria y fecha final opcional; al comenzar el siguiente período, el anterior termina el día anterior.

Cada período tiene una fecha de inicio, una fecha final cuando esté determinada, un saldo inicial y un estado abierto o cerrado. El primer período requiere que el usuario confirme su saldo inicial.

Los gastos, ingresos y transferencias se encuadran en el período correspondiente a su fecha, incluidos los movimientos que solo afectan al ahorro.

Al cerrar un período se conserva su saldo final. Al comenzar el siguiente, su saldo inicial es automáticamente el saldo final del anterior, tanto si es positivo como si es negativo. El arrastre no cuenta como ingreso.

En v1 no se pueden crear, editar ni borrar gastos, ingresos o transferencias pertenecientes a un período cerrado. Tampoco se modifican sus presupuestos. La reapertura y la edición histórica quedan fuera de alcance.

### Cuentas de ahorro y transferencias

El usuario puede crear varias cuentas de ahorro. Cada una tiene nombre, fecha inicial, saldo inicial y estado activa o inactiva. Su saldo se calcula a partir del saldo inicial y los movimientos; no se edita directamente. La inactividad no elimina su historial.

Un ingreso directo a ahorro aumenta el saldo de la cuenta destinataria. Las transferencias tienen fecha, importe, origen y destino, y permiten mover dinero en estas direcciones:

- Disponible → ahorro: reduce el disponible y aumenta la cuenta destinataria.
- Ahorro → disponible: reduce la cuenta de origen y aumenta el disponible.
- Ahorro → otro ahorro: reduce la cuenta de origen y aumenta la destinataria.

Las transferencias no son gastos ni ingresos y no deben contarse como tales en las estadísticas. Sus dos efectos se aplican como una única operación.

Ninguna cuenta de ahorro puede terminar con saldo negativo al final de una fecha afectada. La validación incluye el saldo inicial y, ante movimientos retroactivos o correcciones, todos los saldos posteriores afectados; no basta con comprobar el saldo actual.

### Presupuestos

Son límites informativos para planificar y comparar gastos. Puede existir un presupuesto general del período y presupuestos por categoría dentro de ese período.

No representan dinero, no reservan saldo, no modifican el disponible y no bloquean gastos por superar el límite.

### Categorías y métodos de pago

Cada usuario puede crear, renombrar, desactivar y restaurar sus categorías y métodos de pago. Las categorías clasifican gastos; el método de pago es opcional.

Desactivar impide su selección en nuevos gastos, pero conserva las referencias en los movimientos históricos. Restaurar permite volver a utilizarlos.

### Configuración personal

Cada usuario tiene una moneda financiera y una zona horaria elegida o confirmada por él.

Las monedas iniciales admitidas son EUR, USD y PYG. Todos los importes de un usuario se expresan en su única moneda financiera. Una vez iniciado el historial financiero, no se ofrece un cambio ordinario de moneda ni conversión automática.

## Reglas comunes e integridad financiera

- No se permiten nuevos gastos, ingresos ni transferencias con fecha futura respecto al día actual en la zona horaria del usuario.
- Los importes de gastos, ingresos y transferencias son positivos; su efecto sobre el saldo lo determina el tipo de movimiento. Los saldos del disponible pueden ser negativos según las reglas anteriores.
- Todos los importes se almacenan con hasta dos decimales. Los cálculos monetarios son exactos; nunca se usa `float`. PYG admite decimales igual que EUR y USD, aunque el frontend podrá mostrar PYG sin decimales.
- Los movimientos de un período abierto pueden editarse o borrarse. Cada modificación vuelve a validar fechas, período, disponible y saldos de ahorro afectados. Una edición no puede trasladar un movimiento a un período cerrado ni inexistente.
- Toda operación o corrección debe conservar la coherencia entre fechas, períodos, movimientos y saldos, y volver a comprobar las restricciones financieras afectadas.
- Los presupuestos y las transferencias internas nunca se contabilizan como dinero nuevo.

## Seguridad, concurrencia e idempotencia

La autenticación utilizará Supabase Auth y RLS será obligatorio. Un usuario nunca podrá leer ni modificar datos de otro, incluidos los datos relacionados mediante categorías, períodos o cuentas de ahorro.

La lógica monetaria sensible se ejecutará de forma segura y transaccional en el backend. La validación del frontend será complementaria y nunca la única protección. Una operación se completa íntegramente o no produce cambios.

Las operaciones monetarias importantes deben ser idempotentes: un doble clic o reintento de la misma operación no genera movimientos duplicados. Ante dos peticiones simultáneas, las comprobaciones de saldo y la escritura deben mantener las restricciones, evitando que ambas utilicen un saldo que ya no está disponible.

## Opción futura: Empezar de cero

Se prevé una opción «Empezar de cero» que elimine todos los datos financieros del usuario y conserve su cuenta de Auth. Solo afectará a ese usuario. Su implementación queda para una versión posterior.

## Fuera de alcance por ahora

- Múltiples monedas simultáneas por usuario.
- Conversión FX y cambio ordinario de moneda con historial iniciado.
- Cuentas bancarias sincronizadas.
- Inversiones.
- Deudas y préstamos.
- Gastos directos desde ahorro.
- Reapertura y edición histórica de períodos cerrados, incluidos sus movimientos y presupuestos.
- Importación del histórico de expense-tracker y reutilización o adaptación de su código.
- Generación automática de movimientos recurrentes.
- Implementación de «Empezar de cero» en la primera versión.
- Diseño de pantallas y estructura frontend en esta fase.
