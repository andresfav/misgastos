import { BudgetDetail } from "./BudgetDetail";
import { percentLabel } from "../lib/fundingBudgets";
import { FundingBreakdown } from "./FundingBreakdown";
import { lazy, Suspense, useCallback, useState, type CSSProperties, type ReactNode } from "react";
import { Link } from "react-router-dom";
import { useRemote } from "../hooks/useRemote";
import { formatMoney } from "../lib/money";
import { readHomeCategories, readExpenseBreakdown, sumAmounts, moneyUnits } from "../lib/home";
import type { Currency, FinancialState, Money } from "../types/finance";
import { ErrorMessage, Loading } from "./Feedback";

const Evolution = lazy(() => import("./PeriodEvolution").then((module) => ({ default: module.Evolution })));

const percentage = (spent: Money, budget: Money) => Number(budget) > 0 ? Number(spent) / Number(budget) * 100 : null;

function Accordion({ title, summary, children, deferContent = false }: { title: string; summary?: ReactNode; children: ReactNode; deferContent?: boolean }) {
  const [opened, setOpened] = useState(false);
  return <details className="home-accordion" onToggle={deferContent ? (event) => {
    if (event.currentTarget.open) setOpened(true);
  } : undefined}>
    <summary className={summary == null ? "accordion-heading-only" : undefined}><span className="accordion-title">{title}</span>{summary != null && <span className="accordion-summary">{summary}</span>}<span className="accordion-chevron" aria-hidden="true">⌄</span></summary>
    <div className="accordion-content">{(!deferContent || opened) && children}</div>
  </details>;
}
function Progress({ value, label, exceeded = false }: { value: number; label: string; exceeded?: boolean }) {
  return <progress className={`budget-progress${exceeded ? " exceeded" : ""}`} max={100}
    value={Math.max(0, Math.min(100, value))} aria-label={label} aria-valuetext={label} />;
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
          <FundingBreakdown rows={row.funding_breakdown} currency={currency} />
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
    <Accordion deferContent title="Evolución del período" summary={expenses.loading ? "Cargando…" : expenses.error ? "No disponible" : "Hasta hoy"}>
      <ErrorMessage message={expenses.error} />
      {expenses.error && <button className="button-secondary" onClick={expenses.reload}>Reintentar</button>}
      {expenses.loading ? <Loading text="Cargando evolución…" /> : !expenses.error && expenses.data && <Suspense fallback={<Loading text="Cargando…" />}><Evolution data={data} expenses={expenses.data} currency={currency} /></Suspense>}
    </Accordion>
  </>;
}
function SavingsInsight({ data, currency }: { data: FinancialState; currency: Currency }) {
  const total = sumAmounts(data.savings_balances.map((account) => account.current_balance));
  // Las cuentas borradas a cero desaparecen. Una cuenta inactiva legacy con
  // saldo sigue visible para no hacer parecer que el dinero se ha perdido.
  const accounts = data.savings_balances.filter((account) => account.is_active || moneyUnits(account.current_balance) !== 0n).sort((a, b) =>
    moneyUnits(a.current_balance) > moneyUnits(b.current_balance) ? -1
      : moneyUnits(a.current_balance) < moneyUnits(b.current_balance) ? 1 : a.name.localeCompare(b.name, "es"));
  return <Accordion title="Ahorro" summary={formatMoney(total, currency)}>
    <dl className="home-budget-facts"><div><dt>Total ahorrado</dt><dd>{formatMoney(total, currency)}</dd></div></dl>
    {accounts.length ? <ul className="insight-list category-spending savings-distribution">{accounts.map((account) => {
      const share = percentage(account.current_balance, total) ?? 0;
      return <li key={account.id} className={account.is_active ? undefined : "is-inactive"}>
        <div className="category-spending-heading">
          <h3>{account.name}{!account.is_active && <small> · Por revisar</small>}</h3>
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
    : used === null ? "Presupuesto cero" : percentLabel(used);
  return <div className="home-accordions">
    <Accordion title={data.has_external_sources ? "Presupuesto total" : "Presupuesto"} summary={budgetSummary}>
      {data.current_period ? <>
        <BudgetDetail spent={spent} budget={data.general_budget} remaining={data.general_budget_remaining} currency={currency} />
        <p className="home-note">El presupuesto es tu límite de gasto; no cambia tu dinero disponible.</p>
      </> : <p>No hay un período abierto.</p>}
      <Link className="text-link" to="/ajustes/periodos">Configurar →</Link>
    </Accordion>
    {data.current_period && data.has_external_sources && <>
      {data.budget_model === "by_origin" && <Accordion title="Presupuestos por origen">
        <div className="funding-budget-cards">{data.funding_budgets.map((row) => <section className="funding-budget-card" key={row.external_source_id ?? "available"}>
          <h3>{row.name}{!row.is_active && <small> · Inactivo</small>}</h3>
          <BudgetDetail spent={row.spent} budget={row.budget_amount} remaining={row.remaining} currency={currency} />
        </section>)}</div>
        <Link className="text-link" to="/ajustes/periodos">Configurar presupuestos →</Link>
      </Accordion>}
      <Accordion title="Gastos por origen">
        <dl className="budget-facts">{data.funding_budgets.map((row) => <div key={row.external_source_id ?? "available"}>
          <dt>{row.name}{!row.is_active && <small> · Inactivo</small>}</dt><dd>{formatMoney(row.spent, currency)}</dd>
        </div>)}</dl>
        <p className="funding-budget-total">Total de gastos: <strong>{formatMoney(data.expenses_total, currency)}</strong></p>
      </Accordion>
    </>}
    <SavingsInsight data={data} currency={currency} />
    {data.current_period ? <PeriodInsights key={data.current_period.id} data={data} currency={currency} /> : <>
      <Accordion title="Presupuesto por categoría"><Link className="text-link" to="/ajustes/periodos">Gestionar períodos →</Link></Accordion>
      <Accordion title="Gastos por categoría"><p>Abre un período para consultar sus gastos.</p></Accordion>
      <Accordion title="Gastos por método de pago"><p>Abre un período para consultar sus gastos.</p></Accordion>
      <Accordion title="Evolución del período" summary="Sin período abierto"><p>Abre un período para consultar su evolución.</p></Accordion>
    </>}
  </div>;
}
