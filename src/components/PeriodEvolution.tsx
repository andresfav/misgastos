import { useId } from "react";
import { formatDate } from "../lib/dates";
import { formatMoney } from "../lib/money";
import type { ExpenseBreakdown } from "../lib/home";
import type { Currency, FinancialState } from "../types/finance";

export function Evolution({ data, expenses, currency }: { data: FinancialState; expenses: ExpenseBreakdown; currency: Currency }) {
  const chartId = useId();
  const period = data.current_period!;
  const dateNumber = (date: string) => Date.parse(`${date}T00:00:00Z`) / 86400000;
  const start = dateNumber(period.start_date);
  const hasReference = period.end_date !== null && data.general_budget !== null;
  const endDate = hasReference ? period.end_date! : data.as_of_date;
  const days = Math.max(1, dateNumber(endDate) - start + 1);
  const elapsed = Math.max(0, Math.min(days, dateNumber(data.as_of_date) - start + 1));
  const spent = Number(expenses.days.at(-1)?.cumulative ?? 0);
  const budget = Number(data.general_budget);
  const max = Math.max(spent, hasReference ? budget : 0, 1);
  const x = (day: number) => 64 + day / days * 510;
  const y = (amount: number) => 178 - amount / max * 150;
  let actualPath = `M ${x(0)} ${y(0)}`;
  for (const point of expenses.days) {
    const day = Math.max(0, Math.min(days, dateNumber(point.date) - start + 1));
    actualPath += ` H ${x(day)} V ${y(Number(point.cumulative))}`;
  }
  actualPath += ` H ${x(elapsed)}`;
  const reference = hasReference ? budget * elapsed / days : null;
  const pace = reference === null ? "" : spent > reference
    ? "El gasto va por encima del ritmo proporcional del presupuesto."
    : spent < reference ? "El gasto va por debajo del ritmo proporcional del presupuesto."
      : "El gasto coincide con el ritmo proporcional del presupuesto.";
  return <>
    <p className="home-note">Gasto acumulado hasta {formatDate(data.as_of_date)}: <strong>{formatMoney(expenses.days.at(-1)?.cumulative ?? "0", currency)}</strong>.</p>
    {pace && <p className="pace-description">{pace}</p>}
    <svg className="period-chart" viewBox="0 0 600 216" role="img" aria-labelledby={`${chartId}-title ${chartId}-desc`}>
      <title id={`${chartId}-title`}>Evolución del período</title>
      <desc id={`${chartId}-desc`}>Gasto acumulado real desde {formatDate(period.start_date)} hasta {formatDate(data.as_of_date)}. {pace} {hasReference ? "Línea discontinua: referencia proporcional del presupuesto, no una predicción." : "Sin proyección de gasto."}</desc>
      {[0, 0.5, 1].map((fraction) => <g key={fraction}>
        <line x1="64" x2="574" y1={y(max * fraction)} y2={y(max * fraction)} className="chart-grid" />
        <text x="56" y={y(max * fraction) + 4} textAnchor="end">{new Intl.NumberFormat("es-ES", { notation: "compact", maximumFractionDigits: 1 }).format(max * fraction)}</text>
      </g>)}
      <text x="64" y="16">{currency}</text>
      {hasReference && <path d={`M ${x(0)} ${y(0)} L ${x(days)} ${y(budget)}`} className="chart-reference" />}
      <path d={actualPath} className="chart-actual" />
      <circle cx={x(elapsed)} cy={y(spent)} r="4" className="chart-point" />
      <text x="64" y="205">{formatDate(period.start_date)}</text>
      <text x="574" y="205" textAnchor="end">{formatDate(endDate)}</text>
    </svg>
    <div className="chart-legend"><span><i className="actual-key" />Gasto real</span>
      {hasReference && <span><i className="reference-key" />Ritmo del presupuesto</span>}</div>
    <p className="home-note">{hasReference
      ? "La referencia reparte el presupuesto entre los días del período. Es una guía de ritmo, no una predicción."
      : "Se muestra solo el gasto real. Para comparar el ritmo hacen falta un presupuesto y una fecha final conocida."}</p>
    {!expenses.days.length && <p className="home-note">Aún no hay gastos en este período.</p>}
  </>;
}
