import { client } from "./supabase";

export interface ExportMovement {
  date: string;
  kind: "income" | "expense" | "transfer";
  id: string;
  amount: string;
  funding_type: "available" | "external" | null;
  external_source: string | null;
  origin: string;
  destination: string;
  category: string | null;
  payment_method: string | null;
  merchant: string | null;
  description: string | null;
  note: string | null;
  is_recurring: boolean | null;
  period_id: string;
  period_start: string;
  period_end: string | null;
  period_status: "open" | "closed";
}

export interface ExportBalance {
  date: string;
  snapshot_kind: "opening" | "closing";
  balance_kind: "available" | "savings";
  account_id: string | null;
  account_name: string;
  amount: string;
  period_id: string | null;
  period_start: string | null;
  period_end: string | null;
  period_status: "open" | "closed" | null;
}

interface ExportPeriod {
  id: string;
  mode: string;
  start_date: string;
  end_date: string | null;
  status: "open" | "closed";
  opening_balance: string;
  closing_balance: string | null;
  general_budget: string | null;
  closed_at: string | null;
  version: number;
}

interface ExportSavingsAccount {
  id: string;
  name: string;
  start_date: string;
  opening_balance: string;
  is_active: boolean;
  current_balance: string;
  version: number;
}

interface ExportBudget {
  id: string;
  period_id: string;
  period_start: string;
  period_end: string | null;
  category: string;
  amount: string;
}

interface ExportCatalogItem {
  id: string;
  name: string;
  is_active: boolean;
  version: number;
}

export interface DataExport {
  range: { start_date: string; end_date: string; as_of_date: string };
  settings: { currency: string; timezone: string };
  movements: ExportMovement[];
  balances: ExportBalance[];
  savings_accounts: ExportSavingsAccount[];
  periods: ExportPeriod[];
  budgets: ExportBudget[];
  categories: ExportCatalogItem[];
  payment_methods: ExportCatalogItem[];
  external_sources: ExportCatalogItem[];
}

export async function readDataExport(startDate: string | null, endDate: string | null) {
  const { data, error } = await client().rpc("get_data_export", {
    p_start_date: startDate,
    p_end_date: endDate,
  });
  if (error) throw error;
  return data as DataExport;
}

export const csvColumns = [
  "fecha", "clase", "tipo", "importe", "moneda", "origen", "destino",
  "categoria", "metodo_pago", "comercio", "descripcion", "nota",
  "recurrente", "periodo_inicio", "periodo_fin", "periodo_estado", "referencia_id", "origen_gasto", "origen_externo",
] as const;

type CsvColumn = typeof csvColumns[number];
export type CsvRow = Record<CsvColumn, string>;
export type ExportRangeKind = "all" | "period" | "range";

const movementTypes = { income: "Ingreso", expense: "Gasto", transfer: "Transferencia" } as const;
const periodModes: Record<string, string> = {
  monthly: "Mensual",
  annual: "Anual",
  custom: "Personalizado",
  between_paydays: "Entre cobros",
};

function balanceType(
  data: DataExport,
  row: ExportBalance,
  rangeKind: ExportRangeKind,
  periodOpen = false,
) {
  if (row.balance_kind === "savings") {
    const account = data.savings_accounts.find((item) => item.id === row.account_id);
    if (row.snapshot_kind === "opening" && account?.start_date === row.date)
      return "Saldo inicial de cuenta";
    if (row.snapshot_kind === "closing") {
      if (rangeKind === "all" || rangeKind === "period" && periodOpen)
        return "Saldo actual";
      return "Saldo al final del rango";
    }
    return "Saldo al inicio del rango";
  }
  if (rangeKind === "range") {
    if (row.snapshot_kind === "opening" && row.date === data.range.start_date)
      return "Saldo al inicio del rango";
    if (row.snapshot_kind === "closing" && row.date === data.range.end_date)
      return "Saldo al final del rango";
  }
  if (row.snapshot_kind === "opening") return "Saldo inicial del período";
  return row.period_status === "open" ? "Saldo actual" : "Saldo final del período";
}

// Fuente común para ambos formatos del historial: CSV y su XLSX de una hoja.
export function exportHistoryRows(data: DataExport, rangeKind: ExportRangeKind, periodOpen = false): CsvRow[] {
  // En una exportación por período, el backend ya identifica el período en los
  // snapshots de Disponible. Reutilizar ese mismo contexto evita inferencias y
  // da a las filas de ahorro exactamente los mismos metadatos del período.
  const selectedPeriod = rangeKind === "period"
    ? data.balances.find((row) => row.balance_kind === "available" && row.period_id !== null)
    : undefined;
  const movements = data.movements.map((row) => ({
    fecha: row.date,
    clase: "Movimiento",
    tipo: movementTypes[row.kind],
    importe: row.amount,
    moneda: data.settings.currency,
    origen: row.origin,
    origen_gasto: row.kind === "expense" ? row.funding_type === "external" ? "Externo" : "Disponible" : "",
    origen_externo: row.external_source ?? "",
    destino: row.destination,
    categoria: row.category ?? "",
    metodo_pago: row.payment_method ?? "",
    comercio: row.merchant ?? "",
    descripcion: row.description ?? "",
    nota: row.note ?? "",
    recurrente: row.kind === "expense" ? (row.is_recurring ? "Sí" : "No") : "",
    periodo_inicio: row.period_start,
    periodo_fin: row.period_end ?? "",
    periodo_estado: row.period_status === "open" ? "Abierto" : "Cerrado",
    referencia_id: row.id,
    _order: 1,
  }));
  const balances = data.balances.map((row) => {
    const period = row.balance_kind === "savings" && selectedPeriod ? selectedPeriod : row;
    return {
      fecha: row.date,
      clase: "Saldo",
      tipo: balanceType(data, row, rangeKind, periodOpen),
      importe: row.amount,
      moneda: data.settings.currency,
      origen: "",
      origen_gasto: "",
      origen_externo: "",
      destino: row.account_name,
      categoria: "",
      metodo_pago: "",
      comercio: "",
      descripcion: "",
      nota: "",
      recurrente: "",
      periodo_inicio: period.period_start ?? "",
      periodo_fin: period.period_end ?? "",
      periodo_estado: period.period_status === "open" ? "Abierto" : period.period_status === "closed" ? "Cerrado" : "",
      referencia_id: "",
      _order: row.snapshot_kind === "opening" ? 0 : 2,
    };
  });
  return [...movements, ...balances]
    .sort((a, b) => a.fecha.localeCompare(b.fecha) || a._order - b._order || a.destino.localeCompare(b.destino, "es"))
    .map(({ _order: _ignored, ...row }) => row);
}

// Conserva el nombre público anterior para quien consuma solo la serialización CSV.
export const exportCsvRows = exportHistoryRows;

function escapeCsv(value: string, separator: string) {
  return value.includes('"') || value.includes("\r") || value.includes("\n") || value.includes(separator)
    ? `"${value.replaceAll('"', '""')}"`
    : value;
}

// Punto y coma: Excel con configuración española lo abre en columnas y Google
// Sheets lo detecta al importar. BOM UTF-8 conserva Unicode; no se añade sep=.
export function serializeCsv(rows: CsvRow[], separator = ";") {
  const lines = [
    csvColumns.join(separator),
    ...rows.map((row) => csvColumns.map((column) => escapeCsv(row[column], separator)).join(separator)),
  ];
  return `\uFEFF${lines.join("\r\n")}\r\n`;
}

export function downloadCsv(data: DataExport, fileName: string, rangeKind: ExportRangeKind, periodOpen = false) {
  const blob = new Blob([serializeCsv(exportHistoryRows(data, rangeKind, periodOpen))], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = fileName;
  link.hidden = true;
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

type ExcelValue = string | number | boolean | null;
const header = (values: string[]) => values.map((value) => ({ value, fontWeight: "bold" as const, backgroundColor: "#E7EFEA" }));
const amount = (value: string | null) => value === null ? null : Number(value);
const active = (value: boolean) => value ? "Activa" : "Inactiva";

function sheet(name: string, headers: string[], rows: ExcelValue[][], widths: number[]) {
  return { sheet: name, data: [header(headers), ...rows], columns: widths.map((width) => ({ width })) };
}

const historyWidths = [12, 14, 24, 14, 10, 20, 20, 20, 20, 20, 28, 28, 12, 14, 14, 16, 38, 20, 24];

export async function downloadHistoryXlsx(
  data: DataExport,
  fileName: string,
  rangeKind: ExportRangeKind,
  periodOpen = false,
) {
  const { default: writeXlsxFile } = await import("write-excel-file/browser");
  const rows = exportHistoryRows(data, rangeKind, periodOpen).map((row) =>
    csvColumns.map((column) => column === "importe" ? amount(row[column]) : row[column]),
  );
  await writeXlsxFile([header([...csvColumns]), ...rows], {
    sheet: "Historial",
    columns: historyWidths.map((width) => ({ width })),
  }).toFile(fileName);
}

export async function downloadCompleteXlsx(data: DataExport, fileName: string) {
  const { default: writeXlsxFile } = await import("write-excel-file/browser");
  const movementRows = data.movements.map((row) => [
    row.date, movementTypes[row.kind], amount(row.amount), data.settings.currency,
    row.origin, row.destination, row.category, row.payment_method, row.merchant,
    row.description, row.note, row.kind === "expense" ? (row.is_recurring ? "Sí" : "No") : null,
    row.period_start, row.period_end, row.period_status === "open" ? "Abierto" : "Cerrado", row.id,
    row.kind === "expense" ? row.funding_type === "external" ? "Externo" : "Disponible" : null, row.external_source,
  ]);
  const balanceRows = data.balances.map((row) => [
    row.date, balanceType(data, row, "all"),
    row.balance_kind === "available" ? "Disponible" : "Ahorro", row.account_name,
    amount(row.amount), data.settings.currency, row.period_start, row.period_end,
    row.period_status === "open" ? "Abierto" : row.period_status === "closed" ? "Cerrado" : null,
  ]);
  const budgetRows: ExcelValue[][] = [];
  for (const period of data.periods) if (period.general_budget !== null) budgetRows.push([
    "General", period.start_date, period.end_date, null, amount(period.general_budget), data.settings.currency,
  ]);
  for (const budget of data.budgets) budgetRows.push([
    "Categoría", budget.period_start, budget.period_end, budget.category, amount(budget.amount), data.settings.currency,
  ]);
  await writeXlsxFile([
    sheet("Movimientos", ["Fecha", "Tipo", "Importe", "Moneda", "Origen", "Destino", "Categoría", "Método de pago", "Comercio", "Descripción", "Nota", "Recurrente", "Período inicio", "Período fin", "Estado período", "Referencia", "Origen del gasto", "Origen externo"], movementRows, [12, 16, 14, 10, 22, 22, 20, 20, 20, 28, 28, 12, 14, 14, 16, 38, 20, 24]),
    sheet("Saldos", ["Fecha", "Tipo", "Ámbito", "Cuenta", "Importe", "Moneda", "Período inicio", "Período fin", "Estado período"], balanceRows, [12, 16, 14, 24, 14, 10, 14, 14, 16]),
    sheet("Cuentas de ahorro", ["Nombre", "Fecha de inicio", "Saldo inicial", "Estado", "Saldo actual", "Moneda", "Versión"], data.savings_accounts.map((row) => [row.name, row.start_date, amount(row.opening_balance), active(row.is_active), amount(row.current_balance), data.settings.currency, row.version]), [24, 16, 16, 12, 16, 10, 10]),
    sheet("Períodos", ["Tipo", "Inicio", "Fin", "Estado", "Saldo inicial", "Saldo final", "Presupuesto general", "Moneda", "Cerrado en"], data.periods.map((row) => [periodModes[row.mode] ?? row.mode, row.start_date, row.end_date, row.status === "open" ? "Abierto" : "Cerrado", amount(row.opening_balance), amount(row.closing_balance), amount(row.general_budget), data.settings.currency, row.closed_at]), [18, 14, 14, 12, 16, 16, 20, 10, 24]),
    sheet("Presupuestos", ["Tipo", "Período inicio", "Período fin", "Categoría", "Importe", "Moneda"], budgetRows, [14, 16, 16, 24, 16, 10]),
    sheet("Categorías", ["Nombre", "Estado", "Versión"], data.categories.map((row) => [row.name, active(row.is_active), row.version]), [28, 14, 10]),
    sheet("Orígenes externos", ["Nombre", "Estado", "Versión"], data.external_sources.map((row) => [row.name, active(row.is_active), row.version]), [28, 14, 10]),
    sheet("Métodos de pago", ["Nombre", "Estado", "Versión"], data.payment_methods.map((row) => [row.name, active(row.is_active), row.version]), [28, 14, 10]),
    sheet("Configuración", ["Campo", "Valor"], [["Moneda", data.settings.currency], ["Zona horaria", data.settings.timezone], ["Exportado a fecha", data.range.as_of_date]], [24, 32]),
  ]).toFile(fileName);
}
