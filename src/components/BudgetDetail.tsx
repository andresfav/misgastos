import type { Currency, Money } from "../types/finance";
import { formatMoney } from "../lib/money";
import { budgetProgress, percentLabel } from "../lib/fundingBudgets";

export function BudgetDetail({ spent, budget, remaining, currency }: {
  spent: Money; budget: Money | null; remaining: Money | null; currency: Currency;
}) {
  const { used, exceeded, fill, excessPercent } = budgetProgress(spent, budget, remaining);
  const money = (amount: Money | null) => formatMoney(amount, currency);
  return <div className="home-budget-detail">
    <p className="budget-amounts"><strong>{money(spent)}</strong> / {budget === null ? "Sin presupuesto asignado" : money(budget)}</p>
    {budget !== null && <>
      <p className={exceeded ? "danger-text" : "muted"}>{used === null ? "Presupuesto de importe cero" : `${percentLabel(used)} utilizado`}</p>
      <progress className={`budget-progress${exceeded ? " exceeded" : ""}`} max={100} value={fill!}
        aria-label={`${money(spent)} gastados de ${money(budget)}`}
        aria-valuetext={used === null ? "Presupuesto de importe cero" : `${percentLabel(used)} utilizado`} />
      <p className={exceeded ? "danger-text" : "budget-remaining"}>
        {exceeded ? <><strong>{money(String(remaining).replace(/^-/, ""))}</strong> por encima{excessPercent !== null && ` (+${percentLabel(excessPercent)})`}</>
          : <><strong>{money(remaining)}</strong> restantes</>}
      </p>
    </>}
  </div>;
}
