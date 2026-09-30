import { useState } from "react";
import { Link, useLocation, useSearchParams } from "react-router-dom";
import { useRemote } from "../hooks/useRemote";
import { useSetup } from "../hooks/useSetup";
import { readMovementScreen } from "../lib/movements";
import { formatMoney } from "../lib/money";
import { formatDate } from "../lib/dates";
import { filterHistory, sortHistory, historyLabels, movementContext, movementDescription, type HistoryKind, type HistoryFilters as Filters, type HistorySort } from "../lib/movementHistory";
import { movementLabels, type Movement } from "../types/movements";
import { ErrorMessage, Loading } from "../components/Feedback";
import { HistoryFilters, filterKeys } from "../components/HistoryFilters";
import { MovementDetail } from "../components/MovementDetail";

export function MovementsPage() {
  const { data, loading, error, reload } = useRemote(readMovementScreen);
  const { settings } = useSetup();
  const location = useLocation();
  const [params, setParams] = useSearchParams();
  const requestedKind = params.get("tipo");
  const kind: HistoryKind = requestedKind === "income" || requestedKind === "transfer" || requestedKind === "all" ? requestedKind : "expense";
  const filters = Object.fromEntries(filterKeys.map((key) => [key, params.get(key) || ""])) as unknown as Filters;
  const sort: HistorySort = params.get("orden") === "amount" ? "amount" : params.get("orden") === "context" ? "context" : "date";
  const direction = params.get("direccion") === "asc" ? "asc" : "desc";
  const [selected, setSelected] = useState<Movement | null>(null);
  const [message, setMessage] = useState(location.state?.message || "");
  function changeFilter(field: keyof Filters, value: string) {
    setParams((previous) => { const next = new URLSearchParams(previous); if (value) next.set(field, value); else next.delete(field); return next; }, { replace: true });
  }
  function clearFilters() {
    setParams((previous) => { const next = new URLSearchParams(previous); filterKeys.forEach((key) => next.delete(key)); return next; }, { replace: true });
  }
  function changeSort(value: HistorySort) {
    setParams((previous) => { const next = new URLSearchParams(previous); next.set("orden", value); next.set("direccion", sort === value && direction === "desc" ? "asc" : "desc"); return next; }, { replace: true });
  }
  const filtered = data ? filterHistory(data.rows, kind, filters, data.refs) : [];
  const rows = data ? sortHistory(filtered, sort, direction, kind, data.refs) : [];
  // En móvil se mantiene el orden cronológico sin añadir controles de ordenación.
  const mobileRows = data ? sortHistory(filtered, "date", "desc", kind, data.refs) : [];
  const contextLabel = { expense: "Categoría", income: "Destino", transfer: "Movimiento", all: "Tipo" }[kind];
  const context = (row: Movement) => kind === "all" ? movementLabels[row.kind] : movementContext(row, data!.refs);
  const amount = (row: Movement) => `${row.kind === "expense" ? "−" : row.kind === "income" ? "+" : ""}${formatMoney(row.amount, settings!.currency)}`;
  const hasMovements = data?.rows.some((row) => kind === "all" || row.kind === kind);
  const conflict = () => { setSelected(null); setMessage("Los datos han cambiado o el movimiento ya no está disponible. Revisa la lista actualizada."); reload(); };
  const header = (label: string, field: HistorySort) => <th scope="col" aria-sort={sort === field ? direction === "asc" ? "ascending" : "descending" : "none"}>
    <button className="history-sort" onClick={() => changeSort(field)}>{label} <span aria-hidden="true">{sort === field ? direction === "asc" ? "↑" : "↓" : "↕"}</span></button></th>;
  return <div className="history-page">
    <div className="page-heading"><h1>Movimientos</h1><button className="button-quiet" disabled={loading || !!selected} onClick={reload}>Actualizar</button></div>
    <div className="history-tabs" role="group" aria-label="Tipo de movimiento">
      {(["expense", "income", "transfer", "all"] as const).map((value) => <button key={value} aria-pressed={kind === value} onClick={() => { setParams({ tipo: value }); setMessage(""); }}>{historyLabels[value]}</button>)}
    </div>
    {message && <p className="notice" role="status">{message}</p>}
    <ErrorMessage message={error} />
    {error && <button onClick={reload}>Reintentar</button>}
    {loading ? <Loading text="Cargando movimientos…" /> : !error && data && <>
      <HistoryFilters kind={kind} filters={filters} refs={data.refs} onChange={changeFilter} onClear={clearFilters} />
      <p className="history-scope">Filtros sobre los últimos 100 movimientos de cada tipo.</p>
      <p className="history-result-count" role="status">{rows.length} {rows.length === 1 ? "resultado" : "resultados"}</p>
      {rows.length ? <>
        <table className="history-table">
          <caption className="sr-only">{historyLabels[kind]}. Abre un movimiento para ver sus detalles. El importe se ordena por su valor, sin el signo visual.</caption>
          <colgroup><col className="history-date-col" /><col className="history-amount-col" /><col className="history-context-col" /><col /></colgroup>
          <thead><tr>{header("Fecha", "date")}{header("Importe", "amount")}{header(contextLabel, "context")}<th scope="col">Descripción</th></tr></thead>
          <tbody>{rows.map((row) => <tr key={`${row.kind}:${row.id}`} onClick={() => setSelected(row)}>
            <td><time dateTime={row.date}>{formatDate(row.date)}</time></td>
            <td className={`history-amount ${row.kind}`}>{amount(row)}</td>
            <td><span className="history-truncate" title={context(row)}>{context(row)}</span></td>
            <td><button className="history-open" onClick={() => setSelected(row)} aria-label={`Ver ${movementLabels[row.kind].toLowerCase()} del ${formatDate(row.date)}, ${amount(row)}: ${movementDescription(row)}`}>
              <span className="history-truncate">{movementDescription(row)}</span><span aria-hidden="true">›</span>
            </button></td>
          </tr>)}</tbody>
        </table>
        <ul className="history-mobile">{mobileRows.map((row) => <li key={`${row.kind}:${row.id}`}>
          <button className="history-mobile-row" onClick={() => setSelected(row)}>
            <time dateTime={row.date}>{formatDate(row.date)}</time><strong className={`history-amount ${row.kind}`}>{amount(row)}</strong>
            <span className="history-mobile-context">{row.kind === "transfer" && kind !== "all" && <span className="history-type-label">Transferencia · </span>}{context(row)}</span>
            <span className="history-truncate">{movementDescription(row)}</span><span className="history-chevron" aria-hidden="true">›</span>
          </button>
        </li>)}</ul>
      </> : <section className="history-empty">
        <h2>{hasMovements ? `No hay ${kind === "all" ? "movimientos" : historyLabels[kind].toLowerCase()} que coincidan con estos filtros.` : `No hay ${kind === "all" ? "movimientos" : historyLabels[kind].toLowerCase()} todavía.`}</h2>
        {hasMovements ? <button className="button-secondary" onClick={clearFilters}>Limpiar filtros</button>
          : <Link className="button" to={`/anadir?tipo=${kind === "all" ? "expense" : kind}`}>Registrar {kind === "all" ? "movimiento" : movementLabels[kind].toLowerCase()}</Link>}
      </section>}
    </>}
    {selected && data && <MovementDetail key={`${selected.kind}:${selected.id}`} row={selected} refs={data.refs} currency={settings!.currency}
      returnTo={`${location.pathname}${location.search}`} onClose={() => setSelected(null)} onConflict={conflict}
      onDeleted={() => { setSelected(null); setMessage("Movimiento eliminado."); }} />}
  </div>;
}
