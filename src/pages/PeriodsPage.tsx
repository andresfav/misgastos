import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import { Link, useLocation, useParams } from "react-router-dom";
import { ErrorMessage, Loading } from "../components/Feedback";
import { AdvancePeriodForm } from "../components/AdvancePeriodForm";
import { CategoryBudgets, GeneralBudget, HistoricalCategoryBudgets } from "../components/PeriodBudgets";
import { useRemote } from "../hooks/useRemote";
import { useSetup } from "../hooks/useSetup";
import { formatDate } from "../lib/dates";
import { formatMoney } from "../lib/money";
import { readReferences } from "../lib/movements";
import { periodLabels, readPeriodDetail, readPeriods, type BudgetPeriod, type PeriodSummary } from "../lib/periods";
import { refreshFinancialData } from "../lib/refresh";
import type { Money } from "../types/finance";

function periodRange(period: BudgetPeriod) {
  return `${formatDate(period.start_date)} → ${period.end_date ? formatDate(period.end_date) : "próximo cobro"}`;
}
function Accordion({ title, children, initiallyOpen = false }: { title: string; children: ReactNode; initiallyOpen?: boolean }) {
  const [open, setOpen] = useState(initiallyOpen);
  return <details className="home-accordion" open={open} onToggle={(event) => setOpen(event.currentTarget.open)}>
    <summary className="accordion-heading-only" aria-expanded={open}><span className="accordion-title">{title}</span><span className="accordion-chevron" aria-hidden="true">⌄</span></summary>
    <div className="accordion-content">{children}</div>
  </details>;
}
function PeriodFacts({ period }: { period: BudgetPeriod }) {
  const { settings } = useSetup();
  return <dl className="budget-facts">
    <div><dt>Tipo</dt><dd>{periodLabels[period.mode]}</dd></div>
    <div><dt>Período</dt><dd>{periodRange(period)}</dd></div>
    <div><dt>Estado</dt><dd>{period.status === "open" ? "Abierto" : "Cerrado"}</dd></div>
    <div><dt>Saldo inicial</dt><dd>{formatMoney(period.opening_balance, settings!.currency)}</dd></div>
    {period.status === "closed" && <div><dt>Saldo final</dt><dd>{formatMoney(period.closing_balance, settings!.currency)}</dd></div>}
    <div><dt>Presupuesto general</dt><dd>{period.general_budget === null ? "Sin presupuesto" : formatMoney(period.general_budget, settings!.currency)}</dd></div>
  </dl>;
}
function Summary({ summary }: { summary: PeriodSummary }) {
  const { settings } = useSetup();
  const amounts: [string, Money | null][] = [
    [summary.period.status === "closed" ? "Disponible al cierre" : "Disponible actual", summary.available],
    ["Ingresos", summary.income_total], ["Gastos", summary.expenses_total],
    ["Presupuesto general", summary.general_budget], ["Restante del presupuesto general", summary.general_budget_remaining],
    ["Ingresos a disponible", summary.income_to_available], ["Ingresos a ahorro", summary.income_to_savings],
    ["Transferencias de disponible a ahorro", summary.transfer_to_savings_total], ["Transferencias de ahorro a disponible", summary.transfer_from_savings_total],
  ];
  return <>
    <p className="muted">A {formatDate(summary.as_of_date)}. Totales calculados por el backend.</p>
    <dl className="budget-facts">{amounts.map(([label, amount]) => <div key={label}><dt>{label}</dt><dd>{amount === null ? "Sin presupuesto" : formatMoney(amount, settings!.currency)}</dd></div>)}</dl>
  </>;
}
function AdvanceSuccess({ period }: { period: BudgetPeriod }) {
  const { settings } = useSetup();
  return <div className="period-success">
    <div role="status"><h3>✓ Nuevo período iniciado</h3>
      <p>{periodRange(period)}</p>
      <dl className="budget-facts"><div><dt>Saldo trasladado</dt><dd>{formatMoney(period.opening_balance, settings!.currency)}</dd></div></dl>
      <p>El dinero que quedaba del período anterior se ha trasladado automáticamente. No es un ingreso.</p>
    </div>
    <Link className="button" to={`/anadir?tipo=income&fecha=${period.start_date}`}>Añadir ingreso</Link>
    <p className="muted">¿Acabas de cobrar? Registra ahora tu nómina u otro ingreso del nuevo período.</p>
  </div>;
}
async function readScreen() {
  const [periods, refs] = await Promise.all([readPeriods(), readReferences()]);
  const current = periods.find((period) => period.status === "open");
  const detail = current ? await readPeriodDetail(current.id) : null;
  return { periods, categories: refs.categories, current, detail };
}
function CurrentPeriods() {
  const { data, loading, error } = useRemote(readScreen);
  const { settings } = useSetup();
  const location = useLocation();
  const [message, setMessage] = useState("");
  const [success, setSuccess] = useState<BudgetPeriod | null>(null);
  const heading = useRef<HTMLHeadingElement>(null);
  useEffect(() => { heading.current?.focus(); window.scrollTo(0, 0); }, []);
  const current = data?.current;
  const historical = data?.periods.filter((period) => period.status === "closed") ?? [];
  const editable = current?.status === "open" && data?.detail?.summary.period.status === "open";
  return <div className="periods-page">
    <Link className="settings-back" to="/ajustes">← Ajustes</Link>
    <div className="page-heading"><div><p className="eyebrow">PLANIFICACIÓN</p><h1 ref={heading} tabIndex={-1}>Períodos y presupuestos</h1></div><button className="button-secondary" disabled={loading} onClick={refreshFinancialData}>Actualizar</button></div>
    {message && <p className="notice" role="status">{message}</p>}
    <ErrorMessage message={error} />
    {error && <button onClick={refreshFinancialData}>Reintentar carga</button>}
    {loading && !data && <Loading />}
    {loading && data && <p role="status">Actualizando períodos…</p>}
    {data && <fieldset disabled={loading || !!error} className="period-layout">
      {current ? <section className="card"><h2>Período actual</h2><PeriodFacts period={current} /></section>
        : <section className="card"><h2>No hay un período abierto</h2><p>Puedes consultar el historial de períodos cerrados.</p></section>}
      <div className="card period-accordions">
        <Accordion title="Resumen del período">{data.detail ? <Summary summary={data.detail.summary} /> : <p>No hay un período abierto.</p>}</Accordion>
        <Accordion title="Cerrar período y abrir el siguiente">
          {success ? <AdvanceSuccess period={success} /> : current && editable ? <AdvancePeriodForm key={`${current.id}:${current.version}`} period={current} onMessage={setMessage} onAdvanced={setSuccess} /> : <p>No hay un período abierto que cerrar.</p>}
        </Accordion>
        <Accordion title="Presupuesto general">{current && editable ? <GeneralBudget key={`${current.id}:${current.version}`} period={current} onMessage={setMessage} /> : <p>No hay un período abierto editable.</p>}</Accordion>
        <Accordion title="Presupuestos por categoría">{current && editable && data.detail ? <CategoryBudgets key={`${current.id}:${JSON.stringify(data.detail.usage)}:${JSON.stringify(data.categories)}`} period={current} rows={data.detail.usage} categories={data.categories} onMessage={setMessage} /> : <p>No hay un período abierto editable.</p>}</Accordion>
        <Accordion title="Historial de períodos" initiallyOpen={location.state?.showHistory === true}>
          {historical.length ? <ul className="period-history">{historical.map((period) => <li key={period.id}>
            <Link className="period-history-link" to={`/ajustes/periodos/${period.id}`}>
              <span><strong>{periodRange(period)}</strong><small>{periodLabels[period.mode]} · Cerrado</small><span className="period-history-balance">Saldo final <strong>{formatMoney(period.closing_balance, settings!.currency)}</strong></span></span>
              <span aria-hidden="true">›</span>
            </Link>
          </li>)}</ul> : <p className="empty">Aún no tienes períodos anteriores.</p>}
        </Accordion>
      </div>
    </fieldset>}
  </div>;
}
function HistoricalPeriod({ id }: { id: string }) {
  const load = useCallback(() => readPeriodDetail(id), [id]);
  const { data, error, loading, reload } = useRemote(load);
  const heading = useRef<HTMLHeadingElement>(null);
  useEffect(() => { heading.current?.focus(); window.scrollTo(0, 0); }, [id, data?.summary.period.id]);
  const period = data?.summary.period;
  return <div className="periods-page">
    <Link className="settings-back" to="/ajustes/periodos" state={{ showHistory: true }}>← Historial de períodos</Link>
    <ErrorMessage message={error} />
    {error && <button onClick={reload}>Reintentar carga</button>}
    {loading && <Loading />}
    {data && period && !error && period.status === "closed" && <>
      <h1 ref={heading} tabIndex={-1}>{periodRange(period)}</h1>
      <section className="card"><PeriodFacts period={period} /><h2>Resumen</h2><Summary summary={data.summary} /></section>
      <section className="card"><HistoricalCategoryBudgets rows={data.usage} /></section>
      <p className="muted">Este período está cerrado y no puede modificarse.</p>
    </>}
    {period && period.status !== "closed" && <p>Este período no pertenece al historial de períodos cerrados.</p>}
  </div>;
}
export function PeriodsPage() {
  const { periodId } = useParams();
  return periodId ? <HistoricalPeriod key={periodId} id={periodId} /> : <CurrentPeriods />;
}
