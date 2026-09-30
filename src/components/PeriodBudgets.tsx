import { useState } from "react";
import { useSetup } from "../hooks/useSetup";
import { useSubmit } from "../hooks/useSubmit";
import { isStaleData } from "../lib/errors";
import { formatMoney, validateMoney } from "../lib/money";
import { periodError, periodMutation, type BudgetPeriod, type BudgetUsage } from "../lib/periods";
import { refreshFinancialData } from "../lib/refresh";
import type { CatalogItem } from "../types/movements";
import { ErrorMessage } from "./Feedback";

function useBudgetMutation(onMessage: (text: string) => void) {
  const state = useSubmit(periodError);
  const save = (rpc: Parameters<typeof periodMutation>[0], parameters: Record<string, unknown>) => {
    void state.submit(async () => {
      try { await periodMutation(rpc, parameters); }
      catch (failure) {
        if (isStaleData(failure) || (failure as { code?: string }).code === "23505") {
          onMessage("Los datos han cambiado. Recargando; revisa el presupuesto actual y vuelve a intentarlo.");
          refreshFinancialData();
        }
        throw failure;
      }
      onMessage("Presupuesto actualizado. El disponible no cambia.");
      refreshFinancialData();
    });
  };
  return { ...state, save };
}

export function GeneralBudget({ period, onMessage }: { period: BudgetPeriod; onMessage: (text: string) => void }) {
  const { settings } = useSetup();
  const [amount, setAmount] = useState(period.general_budget ?? "");
  const { busy, error, setError, save } = useBudgetMutation(onMessage);
  return <section className="period-section">
    <p>Es planificación de gastos; no modifica el dinero disponible. Vacío significa sin presupuesto. 0 es un presupuesto válido.</p>
    <ErrorMessage message={error} />
    <form onSubmit={(e) => {
      e.preventDefault();
      try {
        const value = validateMoney(amount, { optional: true });
        save("set_general_budget", { p_period_id: period.id, p_general_budget: value, p_expected_version: period.version });
      } catch (failure) { setError((failure as Error).message); }
    }}><fieldset disabled={busy}>
      <label>Presupuesto ({settings!.currency})<input inputMode="decimal" value={amount} placeholder="Sin presupuesto" onChange={(e) => setAmount(e.target.value)} /></label>
      <div className="form-actions"><button type="submit">{busy ? "Guardando…" : "Guardar presupuesto"}</button>
        {period.general_budget !== null && <button type="button" className="button-secondary" onClick={() => save("set_general_budget", { p_period_id: period.id, p_general_budget: null, p_expected_version: period.version })}>Quitar presupuesto</button>}
      </div>
    </fieldset></form>
  </section>;
}

// La RPC entrega gasto y restante. Solo la proporción visual se calcula aquí.
function usagePercent(row: BudgetUsage) {
  if (row.budget_amount === null) return "Sin presupuesto";
  if (Number(row.budget_amount) === 0) return Number(row.spent) === 0 ? "No aplicable (presupuesto 0, sin gasto)" : "No aplicable (presupuesto 0 superado)";
  return `${new Intl.NumberFormat("es-ES", { maximumFractionDigits: 1 }).format(Number(row.spent) / Number(row.budget_amount) * 100)} %`;
}
// Comparar decimales sin convertir importes a coma flotante.
function normalizedAmount(value: string | number | null) {
  if (value === null) return null;
  const [whole, fraction = ""] = String(value).split(".");
  return `${whole.replace(/^0+(?=\d)/, "")}.${fraction.padEnd(2, "0")}`;
}
export function HistoricalCategoryBudgets({ rows }: { rows: BudgetUsage[] }) {
  const { settings } = useSetup();
  return <section>
    <h2>Presupuesto por categoría</h2>
    {rows.length ? <ul className="catalog-list">{rows.map((row) => <li className="period-usage-row" key={row.category_id}>
      <strong>{row.category_name}</strong>
      {!row.category_is_active && <small className="muted">Categoría inactiva</small>}
      <span>{formatMoney(row.spent, settings!.currency)} / {row.budget_amount === null ? "Sin presupuesto" : formatMoney(row.budget_amount, settings!.currency)}</span>
      <small className="muted">{usagePercent(row)}</small>
    </li>)}</ul> : <p className="empty">No hay gastos ni presupuestos por categoría en este período.</p>}
  </section>;
}
export function CategoryBudgets({ period, rows, categories, onMessage }: { period: BudgetPeriod; rows: BudgetUsage[]; categories: CatalogItem[]; onMessage: (text: string) => void }) {
  const { settings } = useSetup();
  const all = [...rows];
  for (const category of categories) {
    if (category.is_active && !rows.some((row) => row.category_id === category.id)) {
      all.push({ category_id: category.id, category_name: category.name, category_is_active: true, budget_id: null, budget_version: null, budget_amount: null, spent: "0", remaining: null });
    }
  }
  all.sort((a, b) => a.category_name.localeCompare(b.category_name, "es"));
  const [draft, setDraft] = useState<Record<string, string>>(() => Object.fromEntries(all.map((row) => [row.category_id, row.budget_amount === null ? "" : String(row.budget_amount).replace(".", ",")])));
  const { busy, error, setError, submit } = useSubmit(periodError);
  const [saved, setSaved] = useState("");
  const editable = (row: BudgetUsage) => period.status === "open" && (row.budget_id !== null || row.category_is_active);
  function save(event: React.FormEvent) {
    event.preventDefault();
    setSaved("");
    setError("");
    try {
      const changes = all.filter(editable).map((row) => {
        try { return { row, value: validateMoney(draft[row.category_id] ?? "", { optional: true }) }; }
        catch (failure) { throw new Error(`${row.category_name}: ${(failure as Error).message}`); }
      }).filter(({ row, value }) => normalizedAmount(value) !== normalizedAmount(row.budget_amount));
      if (!changes.length) { setSaved("No hay cambios que guardar."); return; }
      void submit(async () => {
        let completed = 0;
        try {
          for (const { row, value } of changes) {
            if (row.budget_id) {
              await periodMutation(value === null ? "delete_category_budget" : "update_category_budget", {
                p_id: row.budget_id, p_expected_version: row.budget_version, ...(value === null ? {} : { p_amount: value }),
              });
            } else if (value !== null) {
              await periodMutation("create_category_budget", { p_period_id: period.id, p_category_id: row.category_id, p_amount: value });
            }
            completed++;
          }
        } catch (failure) {
          onMessage(`${completed ? `Se guardaron ${completed} cambios antes del error. ` : ""}${periodError(failure)} Se recargarán los límites guardados; revisa las categorías pendientes.`);
          refreshFinancialData();
          throw failure;
        }
        onMessage("Presupuestos guardados. El disponible no cambia.");
        refreshFinancialData();
      });
    } catch (failure) { setError((failure as Error).message); }
  }
  return <section className="period-section">
    <p>Define cuánto quieres gastar como máximo en cada categoría durante este período.</p>
    <p className="muted">Vacío significa sin presupuesto. 0 es un límite válido. Importes en {settings!.currency}.</p>
    <ErrorMessage message={error} />
    {saved && <p role="status" className="muted">{saved}</p>}
    {all.length ? <form onSubmit={save}><fieldset disabled={busy || period.status === "closed"}>
      <div className="category-budget-editor">{all.map((row) => <label className="category-budget-input" key={row.category_id}>
        <span>{row.category_name}{!row.category_is_active && <small className="muted">Categoría inactiva</small>}</span>
        <input inputMode="decimal" aria-label={`Presupuesto de ${row.category_name} (${settings!.currency})`} placeholder="Sin límite" disabled={!editable(row)} value={draft[row.category_id] ?? ""} onChange={(e) => { setDraft({ ...draft, [row.category_id]: e.target.value }); setSaved(""); }} />
      </label>)}</div>
      {period.status === "open" && <button type="submit">{busy ? "Guardando…" : "Guardar presupuestos"}</button>}
    </fieldset></form> : <p className="empty">No hay categorías activas. Puedes crearlas en Ajustes.</p>}
  </section>;
}
