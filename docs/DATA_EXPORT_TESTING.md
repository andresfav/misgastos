# Prueba manual de exportación

El proyecto no incorpora un runner de tests frontend. La serialización CSV está
aislada en `src/lib/dataExport.ts`; además del smoke SQL 010, validar manualmente
estos casos después de aplicar la migración en una base de pruebas:

1. Crear un gasto cuyos textos contengan `;`, comillas dobles, un salto de línea
   y Unicode (por ejemplo `Café ☕`). Descargar el período como CSV.
2. Comprobar que el fichero comienza con los bytes BOM UTF-8 `EF BB BF`, usa
   punto y coma como separador, CRLF entre registros y no contiene una fila
   `sep=...`.
3. Abrirlo directamente en Excel con configuración española e importarlo en
   Google Sheets. Debe producir 17 columnas; los textos deben conservarse y
   `importe` no debe contener símbolo de moneda.
4. Confirmar que cada transferencia ocupa una fila y que todos los tipos de
   saldo específicos tienen `clase = Saldo` y `referencia_id` vacío. No debe
   aparecer la palabra `Snapshot`.
5. Descargar dos períodos consecutivos y verificar que el saldo final del
   primero coincide con el inicial del segundo sin aparecer como ingreso.
6. Probar un rango que cruce períodos y una cuenta de ahorro creada dentro del
   rango. Los snapshots inicial/final deben reconciliar sus movimientos.
7. Descargar el XLSX y abrir las ocho hojas. Verificar encabezados, anchos,
   importes numéricos y presencia de catálogos inactivos con historia.

Ejecutar `supabase/tests/010_data_export_smoke.sql` únicamente contra una base de
pruebas preparada con 001–010. El propio script usa `ROLLBACK`.
