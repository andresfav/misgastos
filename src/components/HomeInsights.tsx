import { useCallback, useId, type CSSProperties, type ReactNode } from "react";
import { Link } from "react-router-dom";
import { useRemote } from "../hooks/useRemote";
import { formatDate } from "../lib/dates";
import { formatMoney } from "../lib/money";
import { readHomeCategories, readExpenseBreakdown, sumAmounts, moneyUnits, type ExpenseBreakdown } from "../lib/home";
import type { Currency, FinancialState, Money } from "../types/finance";
import { ErrorMessage, Loading } from "./Feedback";

const percentage = (spent: Money, budget: Money) => Number(budget) > 0 ? Number(spent) / Number(budget) * 100 : null;
const percentLabel = (value: number) => `${new Intl.NumberFormat("es-ES", { maximumFractionDigits: 1 }).format(value)} %`;
const positive = (value: Money) => String(value).replace(/^-/, "");

function Accordion({ title, summary, children }: { title: string; summary?: ReactNode; children: ReactNode }) {
  return <details className="home-accordion">
    <summary className={summary == null ? "accordion-heading-only" : undefined}><span className="accordion-title">{title}</span>{summary != null && <span className="accordion-summary">{summary}</span>}<span className="accordion-chevron" aria-hidden="true">⌄</span></summary>
    <div className="accordion-content">{children}</div>
  </details>;
}
function Progress({ value, label, exceeded = false }: { value: number; label: string; exceeded?: boolean }) {
  return <progress className={`budget-progress${exceeded ? " exceeded" : ""}`} max={100}
    value={Math.max(0, Math.min(100, value))} aria-label={label} aria-valuetext={label} />;
}
function BudgetDetail({ spent, budget, remaining, currency }: { spent: Money; budget: Money; remaining: Money | null; currency: Currency }) {
  const used = percentage(spent, budget);
  const exceeded = remaining !== null && Number(remaining) < 0;
  const money = (amount: Money | null) => formatMoney(amount, currency);
  return <div className="home-budget-detail">
    <dl className="home-budget-facts">
      <div><dt>Gastado</dt><dd>{money(spent)} / {money(budget)}</dd>
        <small>{used === null ? "Presupuesto fijado en cero" : `${percentLabel(used)} utilizado`}</small></div>
    </dl>
    <Progress value={used ?? (Number(spent) > 0 ? 100 : 0)} exceeded={exceeded}
      label={`${money(spent)} gastados de ${money(budget)}`} />
    <dl className="home-budget-facts">
      <div><dt>{exceeded ? "Presupuesto excedido" : "Restante del presupuesto"}</dt>
        <dd className={exceeded ? "danger-text" : ""}>{money(exceeded ? positive(remaining!) : remaining)}</dd>
        {!exceeded && remaining !== null && Number(budget) > 0 && <small>{percentLabel(Number(remaining) / Number(budget) * 100)} restante</small>}
      </div>
    </dl>
  </div>;
}
function Evolution({ data, expenses, currency }: { data: FinancialState; expenses: ExpenseBreakdown; currency: Currency }) {
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
function PeriodInsights({ data, currency }: { data: FinancialState; currency: Currency }) {
  const periodId = data.current_period!.id;
  const categories = useRemote(useCallback(() => readHomeCategories(periodId), [periodId]));
  const budgetCategories = categories.data?.filter((row) => row.budget_id !== null) ?? [];
  const spendingCategories = categories.data?.filter((row) => moneyUnits(row.spent) > 0n)
    .sort((a, b) => moneyUnits(a.spent) > moneyUnits(b.spent) ? -1 : moneyUnits(a.spent) < moneyUnits(b.spent) ? 1 : a.category_name.localeCompare(b.category_name, "es")) ?? [];
  const categoryColors = ["#17634e", "#526b87", "#84693f", "#77647e", "#527b78"];
  const expenses = useRemote(useCallback(() => readExpenseBreakdown(periodId, data.as_of_date), [periodId, data.as_of_date]));
  const totalSpent = expenses.data ? sumAmounts(expenses.data.methods.map((method) => method.amount)) : "0";
  return <>
    <Accordion title="Presupuesto por categoría">
      <ErrorMessage message={categories.error} />
      {categories.error && <button className="button-secondary" onClick={categories.reload}>Reintentar</button>}
      {categories.loading ? <Loading text="Cargando presupuestos…" /> : !categories.error && <>
        {budgetCategories.length ? <ul className="insight-list">{budgetCategories.map((row) => <li key={row.category_id}>
          <h3>{row.category_name}{!row.category_is_active && <small> · Inactiva</small>}</h3>
          <BudgetDetail spent={row.spent} budget={row.budget_amount!} remaining={row.remaining} currency={currency} />
        </li>)}</ul> : <p>No has fijado presupuestos por categoría para este período.</p>}
      </>}
      <Link className="text-link" to="/ajustes/periodos">Configurar presupuestos →</Link>
    </Accordion>
    <Accordion title="Gastos por categoría">
      <ErrorMessage message={categories.error} />
      {categories.error && <button className="button-secondary" onClick={categories.reload}>Reintentar</button>}
      {categories.loading ? <Loading text="Cargando gastos…" /> : !categories.error && (
        spendingCategories.length ? <>
          <p>Total gastado: <strong>{formatMoney(data.expenses_total, currency)}</strong></p>
          <ul className="insight-list category-spending">{spendingCategories.map((row, index) => {
            const share = percentage(row.spent, data.expenses_total ?? "0") ?? 0;
            return <li key={row.category_id} style={{ "--category-color": categoryColors[index % categoryColors.length] } as CSSProperties}>
              <div className="category-spending-heading">
                <h3><span className="category-dot" aria-hidden="true" />{row.category_name}{!row.category_is_active && <small> · Inactiva</small>}</h3>
                <span><strong>{formatMoney(row.spent, currency)}</strong> · {percentLabel(share)}</span>
              </div>
              <Progress value={share} label={`${row.category_name}: ${percentLabel(share)} del total de gastos del período`} />
            </li>;
          })}</ul>
        </> : <p>Aún no hay gastos en este período.</p>
      )}
    </Accordion>
    <Accordion title="Gastos por método de pago">
      <ErrorMessage message={expenses.error} />
      {expenses.error && <button className="button-secondary" onClick={expenses.reload}>Reintentar</button>}
      {expenses.loading ? <Loading text="Cargando gastos…" /> : !expenses.error && (
        expenses.data?.methods.length ? <ul className="insight-list">{expenses.data.methods.map((method) => {
          const share = percentage(method.amount, totalSpent) ?? 0;
          return <li key={method.id ?? "no-method"}>
            <h3>{method.name}</h3>
            <div className="insight-values"><strong>{formatMoney(method.amount, currency)}</strong><span>{percentLabel(share)}</span></div>
            <Progress value={share} label={`${method.name}: ${percentLabel(share)} de los gastos del período`} />
          </li>;
        })}</ul> : <p>Aún no hay gastos en este período.</p>
      )}
    </Accordion>
    <Accordion title="Evolución del período" summary={expenses.loading ? "Cargando…" : expenses.error ? "No disponible" : "Hasta hoy"}>
      <ErrorMessage message={expenses.error} />
      {expenses.error && <button className="button-secondary" onClick={expenses.reload}>Reintentar</button>}
      {expenses.loading ? <Loading text="Cargando evolución…" /> : !expenses.error && expenses.data && <Evolution data={data} expenses={expenses.data} currency={currency} />}
    </Accordion>
  </>;
}
function SavingsInsight({ data, currency }: { data: FinancialState; currency: Currency }) {
  const total = sumAmounts(data.savings_balances.map((account) => account.current_balance));
  const accounts = [...data.savings_balances].sort((a, b) =>
    moneyUnits(a.current_balance) > moneyUnits(b.current_balance) ? -1
      : moneyUnits(a.current_balance) < moneyUnits(b.current_balance) ? 1 : a.name.localeCompare(b.name, "es"));
  return <Accordion title="Ahorro" summary={formatMoney(total, currency)}>
    <dl className="home-budget-facts"><div><dt>Total ahorrado</dt><dd>{formatMoney(total, currency)}</dd></div></dl>
    {accounts.length ? <ul className="insight-list category-spending savings-distribution">{accounts.map((account) => {
      const share = percentage(account.current_balance, total) ?? 0;
      return <li key={account.id} className={account.is_active ? undefined : "is-inactive"}>
        <div className="category-spending-heading">
          <h3>{account.name}{!account.is_active && <small> · Inactiva</small>}</h3>
          <span><strong>{formatMoney(account.current_balance, currency)}</strong> · {percentLabel(share)}</span>
        </div>
        <Progress value={share} label={`${account.name}: ${percentLabel(share)} del ahorro total`} />
      </li>;
    })}</ul> : <p>Aún no tienes cuentas de ahorro.</p>}
    <Link className="text-link" to="/ahorro">Ver ahorro →</Link>
  </Accordion>;
}
export function HomeInsights({ data, currency }: { data: FinancialState; currency: Currency }) {
  const spent = data.expenses_total ?? "0";
  const used = data.general_budget === null ? null : percentage(spent, data.general_budget);
  const budgetSummary = !data.current_period ? "Sin período abierto" : data.general_budget === null ? "Sin configurar"
    : used === null ? "— %" : percentLabel(used);
  return <div className="home-accordions">
    <Accordion title="Presupuesto" summary={budgetSummary}>
      {data.current_period && data.general_budget !== null ? <>
        <BudgetDetail spent={spent} budget={data.general_budget} remaining={data.general_budget_remaining} currency={currency} />
        <p className="home-note">El presupuesto es tu límite de gasto; no cambia tu dinero disponible.</p>
      </> : <p>{data.current_period ? "No has fijado un presupuesto para este período." : "No hay un período abierto."}</p>}
      <Link className="text-link" to="/ajustes/periodos">Configurar →</Link>
    </Accordion>
    <SavingsInsight data={data} currency={currency} />
    {data.current_period ? <PeriodInsights key={data.current_period.id} data={data} currency={currency} /> : <>
      <Accordion title="Presupuesto por categoría"><Link className="text-link" to="/ajustes/periodos">Gestionar períodos →</Link></Accordion>
      <Accordion title="Gastos por categoría"><p>Abre un período para consultar sus gastos.</p></Accordion>
      <Accordion title="Gastos por método de pago"><p>Abre un período para consultar sus gastos.</p></Accordion>
      <Accordion title="Evolución del período" summary="Sin período abierto"><p>Abre un período para consultar su evolución.</p></Accordion>
    </>}
  </div>;
}
