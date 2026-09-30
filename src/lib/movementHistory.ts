import { movementLabels, type Movement, type References } from "../types/movements";
export type HistoryKind = Movement["kind"] | "all";
export const historyLabels: Record<HistoryKind, string> = { expense: "Gastos", income: "Ingresos", transfer: "Transferencias", all: "Todos" };
export interface HistoryFilters { category: string; method: string; origin: string; destination: string; from: string; until: string; search: string }
export function accountName(id: string | null, refs: References) {
  return id === null ? "Disponible" : refs.accounts.find((account) => account.id === id)?.name || "Cuenta no disponible";
}
export function movementContext(row: Movement, refs: References) {
  if (row.kind === "expense") return refs.categories.find((category) => category.id === row.category_id)?.name || "Categoría no disponible";
  if (row.kind === "income") return accountName(row.savings_account_id, refs);
  return `${accountName(row.from_savings_account_id, refs)} → ${accountName(row.to_savings_account_id, refs)}`;
}
export function movementDescription(row: Movement) {
  return row.description || (row.kind === "expense" ? row.merchant : null) || "Sin descripción";
}
const normalize = (text: string) => text.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLocaleLowerCase("es");
const matchesAccount = (filter: string, id: string | null) => !filter || filter === (id ?? "available");
export function filterHistory(rows: Movement[], kind: HistoryKind, filters: HistoryFilters, refs: References) {
  return rows.filter((row) => {
    if (kind !== "all" && row.kind !== kind) return false;
    if (filters.from && row.date < filters.from || filters.until && row.date > filters.until) return false;
    if (kind === "expense" && row.kind === "expense") {
      if (filters.category && row.category_id !== filters.category) return false;
      if (filters.method && (row.payment_method_id ?? "none") !== filters.method) return false;
    }
    if (kind === "income" && row.kind === "income" && !matchesAccount(filters.destination, row.savings_account_id)) return false;
    if (kind === "transfer" && row.kind === "transfer" && (!matchesAccount(filters.origin, row.from_savings_account_id) || !matchesAccount(filters.destination, row.to_savings_account_id))) return false;
    const search = normalize(filters.search.trim());
    const related = row.kind === "expense" ? [row.merchant, row.note, refs.methods.find((method) => method.id === row.payment_method_id)?.name] : [];
    return !search || normalize([row.description, movementContext(row, refs), movementLabels[row.kind], ...related].filter(Boolean).join(" ")).includes(search);
  });
}
export type HistorySort = "date" | "amount" | "context";
// Importes exactos para ordenar, sin convertir a Number ni recalcular saldos.
function cents(amount: string) { const [whole, fraction = ""] = amount.split("."); return BigInt(whole) * 100n + BigInt(fraction.padEnd(2, "0")); }
export function sortHistory(rows: Movement[], sort: HistorySort, direction: "asc" | "desc", kind: HistoryKind, refs: References) {
  return [...rows].sort((a, b) => {
    let result = 0;
    if (sort === "amount") result = cents(a.amount) < cents(b.amount) ? -1 : cents(a.amount) > cents(b.amount) ? 1 : 0;
    else if (sort === "context") result = (kind === "all" ? movementLabels[a.kind] : movementContext(a, refs)).localeCompare(kind === "all" ? movementLabels[b.kind] : movementContext(b, refs), "es");
    else result = a.date.localeCompare(b.date);
    return result * (direction === "asc" ? 1 : -1) || b.date.localeCompare(a.date) || b.created_at.localeCompare(a.created_at) || b.id.localeCompare(a.id);
  });
}
