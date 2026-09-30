import { useCallback, useState } from "react";
import { Link } from "react-router-dom";
import { ErrorMessage, Loading } from "../components/Feedback";
import { AdvancePeriodForm } from "../components/AdvancePeriodForm";
import { CategoryBudgets, GeneralBudget } from "../components/PeriodBudgets";
import { useRemote } from "../hooks/useRemote";
import { useSetup } from "../hooks/useSetup";
import { formatDate } from "../lib/dates";
import { formatMoney } from "../lib/money";
import { readReferences } from "../lib/movements";
import { periodLabels, readPeriodDetail, readPeriods, type BudgetPeriod } from "../lib/periods";
import { refreshFinancialData } from "../lib/refresh";
import type { Money } from "../types/finance";
import type { CatalogItem } from "../types/movements";

function PeriodFacts({ period }: { period: BudgetPeriod }) {
  const { settings } = useSetup();
  return <dl className="budget-facts">
    <div><dt>Tipo</dt><dd>{periodLabels[period.mode]}</dd></div>
    <div><dt>Inicio</dt><dd>{formatDate(period.start_date)}</dd></div>
    <div><dt>Final</dt><dd>{period.end_date ? formatDate(period.end_date) : "Abierto, hasta el próximo cobro"}</dd></div>
    <div><dt>Estado</dt><dd>{period.status === "open" ? "Abierto" : "Cerrado · solo lectura"}</dd></div>
    <div><dt>Saldo inicial</dt><dd>{formatMoney(period.opening_balance, settings!.currency)}</dd></div>
    {period.status === "closed" && <div><dt>Saldo final</dt><dd>{formatMoney(period.closing_balance, settings!.currency)}</dd></div>}
    <div><dt>Presupuesto general</dt><dd>{period.general_budget === null ? "Sin presupuesto" : formatMoney(period.general_budget, settings!.currency)}</dd></div>
  </dl>;
}
function PeriodDetail({ period, categories, onMessage }: { period: BudgetPeriod; categories: CatalogItem[]; onMessage: (text: string) => void }) {
  const { settings } = useSetup();
  const load = useCallback(() => readPeriodDetail(period.id), [period.id]);
  const { data, error, loading, reload } = useRemote(load);
  const summary = data?.summary;
  const amounts: [string, Money | null][] = summary ? [
    [period.status === "closed" ? "Disponible al cierre" : "Disponible actual", summary.available],
    ["Ingresos", summary.income_total], ["Gastos", summary.expenses_total],
    ["Presupuesto general", summary.general_budget], ["Restante del presupuesto general", summary.general_budget_remaining],
    ["Ingresos a disponible", summary.income_to_available], ["Ingresos a ahorro", summary.income_to_savings],
    ["Transferencias de disponible a ahorro", summary.transfer_to_savings_total], ["Transferencias de ahorro a disponible", summary.transfer_from_savings_total],
  ] : [];
  return <>
    <ErrorMessage message={error} />
    {error && <button onClick={reload}>Reintentar resumen</button>}
    {loading && <p role="status">Actualizando resumen y presupuestos…</p>}
    {data && !error && <fieldset disabled={loading}>
      <section className="period-section">
        <h3>Resumen del período</h3>
        <p className="muted">A {formatDate(data.summary.as_of_date)}. Totales calculados por el backend.</p>
        <dl className="budget-facts">{amounts.map(([label, amount]) => <div key={label}><dt>{label}</dt><dd>{amount === null ? "Sin presupuesto" : formatMoney(amount, settings!.currency)}</dd></div>)}</dl>
      </section>
      {period.status === "open" && data.summary.period.status === "open" && <AdvancePeriodForm key={`advance:${period.id}:${period.version}`} period={period} onMessage={onMessage} />}
      {period.status === "open" && data.summary.period.status === "open" && <GeneralBudget key={`${period.id}:${period.version}`} period={period} onMessage={onMessage} />}
      <CategoryBudgets period={data.summary.period.status === "closed" ? { ...period, status: "closed" } : period} rows={data.usage} categories={categories} onMessage={onMessage} />
    </fieldset>}
  </>;
}
async function readScreen() {
  const [periods, refs] = await Promise.all([readPeriods(), readReferences()]);
  return { periods, categories: refs.categories };
}
export function PeriodsPage() {
  const { data, loading, error } = useRemote(readScreen);
  const [message, setMessage] = useState("");
  const [selected, setSelected] = useState<string | null>(null);
  const current = data?.periods.find((p) => p.status === "open");
  const historical = data?.periods.filter((p) => p.status === "closed") ?? [];
  return <>
    <Link to="/ajustes">← Ajustes</Link>
    <div className="page-heading"><div><p className="eyebrow">PLANIFICACIÓN</p><h1>Períodos y presupuestos</h1></div><button className="button-secondary" disabled={loading} onClick={refreshFinancialData}>Actualizar</button></div>
    {message && <p className="notice" role="status">{message}</p>}
    <ErrorMessage message={error} />
    {error && <button onClick={refreshFinancialData}>Reintentar carga</button>}
    {loading && !data && <Loading />}
    {loading && data && <p role="status">Actualizando períodos…</p>}
    {data && !error && <fieldset disabled={loading} className="period-layout">
      {current ? <section className="card" key={current.id}>
        <h2>Período actual</h2>
        <PeriodFacts period={current} />
        <PeriodDetail period={current} categories={data.categories} onMessage={setMessage} />
      </section> : <section className="card"><h2>No hay un período abierto</h2><p>Puedes consultar el historial de períodos cerrados.</p></section>}
      <section className="card">
        <h2>Historial de períodos</h2>
        <p>Los períodos cerrados son de solo lectura.</p>
        {historical.length ? <ul className="catalog-list">{historical.map((period) => <li key={period.id} className="catalog-row">
          <h3>{periodLabels[period.mode]} · {formatDate(period.start_date)}</h3>
          <PeriodFacts period={period} />
          <button className="button-secondary" aria-expanded={selected === period.id} onClick={() => setSelected(selected === period.id ? null : period.id)}>{selected === period.id ? "Ocultar detalle" : "Ver resumen y presupuestos"}</button>
          {selected === period.id && <PeriodDetail period={period} categories={data.categories} onMessage={setMessage} />}
        </li>)}</ul> : <p className="empty">Todavía no hay períodos cerrados.</p>}
      </section>
    </fieldset>}
  </>;
}
