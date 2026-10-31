import type { Currency } from "../types/finance";
import type { PeriodSummary } from "../lib/periods";
import { BudgetDetail } from "./BudgetDetail";

export function HistoricalFundingBudgets({ summary, currency }: { summary: PeriodSummary; currency: Currency }) {
  if (summary.budget_model === "legacy_total") return <p className="muted">El presupuesto general histórico cubre todos los gastos del período, incluidos los externos. No tiene una distribución por origen.</p>;
  if (!summary.has_external_sources) return null;
  return <section className="card"><h2>Presupuestos por origen</h2>
    <div className="funding-budget-cards">{summary.funding_budgets.map((row) => <section className="funding-budget-card" key={row.external_source_id ?? "available"}>
      <h3>{row.name}{!row.is_active && <small> · Inactivo</small>}</h3>
      <BudgetDetail spent={row.spent} budget={row.budget_amount} remaining={row.remaining} currency={currency} />
    </section>)}</div>
  </section>;
}
