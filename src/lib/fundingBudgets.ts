import { validateMoney } from "./money";
import { sumAmounts } from "./home";
import type { BudgetModel, FundingBudgetUsage, Money } from "../types/finance";

// Solo el editor de un período abierto propone la conversión del límite general.
// Nunca cambia la lectura histórica ni inventa una asignación ya guardada.
export function editableFundingBudgets(summary: {
  budget_model: BudgetModel; legacy_general_budget: string | null;
  funding_budgets: FundingBudgetUsage[]; period: { status: "open" | "closed" };
}) {
  if (summary.budget_model !== "legacy_total" || summary.period.status !== "open") return summary.funding_budgets;
  return summary.funding_budgets.map((row) => row.funding_type === "available"
    ? { ...row, budget_amount: summary.legacy_general_budget } : row);
}

export const fundingKey = (row: FundingBudgetUsage) => row.external_source_id ?? "available";
export function fundingBudgetDraft(rows: FundingBudgetUsage[]) {
  return Object.fromEntries(rows.map((row) => [fundingKey(row), row.budget_amount?.replace(".", ",") ?? ""]));
}
export function fundingBudgetValues(rows: FundingBudgetUsage[], draft: Record<string, string>) {
  return rows.map((row) => {
    try { return { row, amount: validateMoney(draft[fundingKey(row)] ?? "", { optional: true }) }; }
    catch (failure) { throw new Error(`${row.name}: ${(failure as Error).message}`); }
  });
}
// Preview de entradas aún sin guardar. Los totales persistidos y todos los saldos
// proceden de las RPC; esta suma exacta nunca calcula Disponible ni Ahorro.
export function draftBudgetTotal(rows: FundingBudgetUsage[], draft: Record<string, string>) {
  const assigned = fundingBudgetValues(rows, draft).flatMap(({ amount }) => amount === null ? [] : [amount]);
  return assigned.length ? sumAmounts(assigned) : null;
}
export function fundingBudgetParameters(periodId: string, version: number, rows: FundingBudgetUsage[], draft: Record<string, string>) {
  const values = fundingBudgetValues(rows, draft);
  const normalized = (value: string | null) => value === null ? null : sumAmounts([value]);
  return {
    p_period_id: periodId,
    p_expected_version: version,
    p_available_budget: values.find(({ row }) => row.funding_type === "available")!.amount,
    // Solo se mandan cambios: una fuente inactiva sin asignación no se intenta crear.
    p_external_budgets: values.filter(({ row, amount }) => row.funding_type === "external"
      && normalized(amount) !== normalized(row.budget_amount))
      .map(({ row, amount }) => ({ external_source_id: row.external_source_id, amount })),
  };
}

// Solo presentación. El remanente llega calculado por el backend.
export function budgetProgress(spent: Money, budget: Money | null, remaining: Money | null) {
  const used = budget !== null && Number(budget) > 0 ? Number(spent) / Number(budget) * 100 : null;
  const exceeded = remaining !== null && Number(remaining) < 0;
  return {
    used,
    exceeded,
    fill: budget === null ? null : Math.max(0, Math.min(100, used ?? (Number(spent) > 0 ? 100 : 0))),
    excessPercent: exceeded && used !== null ? used - 100 : null,
  };
}
export const percentLabel = (value: number) => `${new Intl.NumberFormat("es-ES", { maximumFractionDigits: 1 }).format(value)} %`;
