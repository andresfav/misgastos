import type { Currency, FundingBreakdown as FundingRow } from "../types/finance";
import { formatMoney } from "../lib/money";
export function FundingBreakdown({ rows, currency }: { rows?: FundingRow[]; currency: Currency }) {
  if (!rows?.some((row) => row.funding_type === "external")) return null;
  return <details className="funding-breakdown"><summary>Gastos por origen</summary>
    <dl className="budget-facts">{rows.map((row) => <div key={row.external_source_id ?? "available"}>
      <dt>{row.name}</dt><dd>{formatMoney(row.amount, currency)}</dd>
    </div>)}</dl>
  </details>;
}
