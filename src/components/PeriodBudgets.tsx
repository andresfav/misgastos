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
    <h3>Presupuesto general</h3>
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
function CategoryBudgetRow({ row, period, onMessage }: { row: BudgetUsage; period: BudgetPeriod; onMessage: (text: string) => void }) {
  const { settings } = useSetup();
  const money = (amount: BudgetUsage["budget_amount"]) => formatMoney(amount, settings!.currency);
  const [amount, setAmount] = useState(row.budget_amount === null ? "" : String(row.budget_amount));
  const { busy, error, setError, save } = useBudgetMutation(onMessage);
  const editable = period.status === "open" && (row.budget_id !== null || row.category_is_active);
  return <li className="catalog-row">
    <div className="catalog-name"><strong>{row.category_name}</strong>{!row.category_is_active && <span className="muted">Categoría inactiva</span>}</div>
    <dl className="budget-facts">
      <div><dt>Presupuesto</dt><dd>{row.budget_amount === null ? "Sin presupuesto" : money(row.budget_amount)}</dd></div>
      <div><dt>Gasto utilizado</dt><dd>{money(row.spent)}</dd></div>
      <div><dt>Restante del presupuesto</dt><dd>{money(row.remaining)}</dd></div>
      <div><dt>Porcentaje utilizado</dt><dd>{usagePercent(row)}</dd></div>
    </dl>
    {editable && <>
      <ErrorMessage message={error} />
      <form onSubmit={(e) => {
        e.preventDefault();
        try {
          if (!amount.trim()) throw new Error("Introduce el presupuesto; puede ser 0.");
          const value = validateMoney(amount)!;
          if (row.budget_id) save("update_category_budget", { p_id: row.budget_id, p_expected_version: row.budget_version, p_amount: value });
          else save("create_category_budget", { p_period_id: period.id, p_category_id: row.category_id, p_amount: value });
        } catch (failure) { setError((failure as Error).message); }
      }}><fieldset disabled={busy}>
        <label>Presupuesto de {row.category_name} ({settings!.currency})<input required inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} /></label>
        <div className="form-actions"><button type="submit">{busy ? "Guardando…" : row.budget_id ? "Guardar" : "Crear presupuesto"}</button>
          {row.budget_id && <button type="button" className="button-secondary" onClick={() => save("delete_category_budget", { p_id: row.budget_id, p_expected_version: row.budget_version })}>Quitar</button>}
        </div>
      </fieldset></form>
    </>}
  </li>;
}
export function CategoryBudgets({ period, rows, categories, onMessage }: { period: BudgetPeriod; rows: BudgetUsage[]; categories: CatalogItem[]; onMessage: (text: string) => void }) {
  const all = [...rows];
  if (period.status === "open") {
    for (const category of categories) {
      if (category.is_active && !rows.some((row) => row.category_id === category.id)) {
        // Ausente de la RPC significa sin gasto y sin presupuesto.
        all.push({ category_id: category.id, category_name: category.name, category_is_active: true, budget_id: null, budget_version: null, budget_amount: null, spent: "0", remaining: null });
      }
    }
  }
  return <section className="period-section">
    <h3>Presupuestos por categoría</h3>
    <p>El restante de un presupuesto es un límite de planificación, no dinero disponible. Guarda cada categoría por separado.</p>
    {all.length ? <ul className="catalog-list">{all.map((row) => <CategoryBudgetRow key={`${row.category_id}:${row.budget_id}:${row.budget_version}:${period.status}`} row={row} period={period} onMessage={onMessage} />)}</ul> : <p className="empty">{period.status === "open" ? "No hay categorías activas. Puedes crearlas en Ajustes." : "No hay gastos ni presupuestos por categoría en este período."}</p>}
  </section>;
}
