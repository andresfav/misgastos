import type { HistoryFilters as Filters, HistoryKind } from "../lib/movementHistory";
import type { References } from "../types/movements";
export const filterKeys = ["category", "method", "origin", "destination", "from", "until", "search"] as const;
export function HistoryFilters({ kind, filters, refs, onChange, onClear }: {
  kind: HistoryKind; filters: Filters; refs: References;
  onChange: (field: keyof Filters, value: string) => void; onClear: () => void;
}) {
  const title = { expense: "Filtrar gastos", income: "Filtrar ingresos", transfer: "Filtrar transferencias", all: "Filtrar movimientos" }[kind];
  const fields: (keyof Filters)[] = ["from", "until", "search", ...(kind === "expense" ? ["category", "method"] as const : kind === "income" ? ["destination"] as const : kind === "transfer" ? ["origin", "destination"] as const : [])];
  const active = fields.filter((key) => filters[key].trim()).length;
  const accounts = (exclude = "") => <><option value="">Todos</option><option value="available" disabled={exclude === "available"}>Disponible</option>
    {refs.accounts.map((account) => <option key={account.id} value={account.id} disabled={exclude === account.id}>{account.name}{!account.is_active ? " · Inactiva" : ""}</option>)}</>;
  const invalidDates = !!filters.from && !!filters.until && filters.from > filters.until;
  return <details className="history-filters" key={kind}>
    <summary>{title}{active > 0 && <small> · {active} activos</small>} <span aria-hidden="true">⌄</span></summary>
    <div className="history-filter-fields">
      {kind === "expense" && <>
        <label>Categoría<select value={filters.category} onChange={(e) => onChange("category", e.target.value)}><option value="">Todas</option>{refs.categories.map((category) => <option key={category.id} value={category.id}>{category.name}{!category.is_active ? " · Inactiva" : ""}</option>)}</select></label>
        <label>Método de pago<select value={filters.method} onChange={(e) => onChange("method", e.target.value)}><option value="">Todos</option><option value="none">Sin método</option>{refs.methods.map((method) => <option key={method.id} value={method.id}>{method.name}{!method.is_active ? " · Inactivo" : ""}</option>)}</select></label>
      </>}
      {kind === "transfer" && <label>Origen<select value={filters.origin} onChange={(e) => onChange("origin", e.target.value)}>{accounts(filters.destination)}</select></label>}
      {(kind === "transfer" || kind === "income") && <label>Destino<select value={filters.destination} onChange={(e) => onChange("destination", e.target.value)}>{accounts(kind === "transfer" ? filters.origin : "")}</select></label>}
      <label>Desde<input type="date" value={filters.from} max={filters.until || undefined} aria-invalid={invalidDates} onChange={(e) => onChange("from", e.target.value)} /></label>
      <label>Hasta<input type="date" value={filters.until} min={filters.from || undefined} aria-invalid={invalidDates} onChange={(e) => onChange("until", e.target.value)} /></label>
      <label className="history-search">Buscar<input type="search" value={filters.search} placeholder="Descripción o datos relacionados" onChange={(e) => onChange("search", e.target.value)} /></label>
    </div>
    {invalidDates && <p className="notice error" role="alert">La fecha Desde debe ser anterior o igual a Hasta.</p>}
    {kind === "transfer" && filters.origin && filters.origin === filters.destination && <p className="notice error" role="alert">El origen y el destino deben ser distintos.</p>}
    <button className="button-quiet" onClick={onClear}>Limpiar filtros</button>
  </details>;
}
