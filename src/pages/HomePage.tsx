import { Link } from "react-router-dom";
import { useRemote } from "../hooks/useRemote";
import { readFinancialState } from "../lib/finance";
import { formatMoney } from "../lib/money";
import { formatDate } from "../lib/dates";
import { useSetup } from "../hooks/useSetup";
import { ErrorMessage, Loading } from "../components/Feedback";
import { HomeInsights } from "../components/HomeInsights";

export function HomePage() {
  const { settings } = useSetup();
  const { data, error, loading, reload } = useRemote(readFinancialState);
  const money = (value: number | string | null) => formatMoney(value, settings!.currency);
  return (
    <div className="home-page">
      <div className="page-heading home-heading"><h1>Inicio</h1></div>
      <ErrorMessage message={error} />
      {error && <button className="button-secondary" onClick={reload}>Reintentar resumen</button>}
      {loading ? <Loading text="Cargando tu resumen…" /> : !error && data && <>
        <section className="home-balance" aria-labelledby="available-title">
          {data.current_period ? <div className="current-period">
            <span>Período actual</span>
            <strong>{formatDate(data.current_period.start_date)} → {data.current_period.end_date
              ? formatDate(data.current_period.end_date)
              : data.current_period.mode === "between_paydays" ? "próximo cobro" : "período abierto"}</strong>
          </div> : <div className="current-period">
            <span>No hay un período abierto.</span>
            <Link to="/ajustes/periodos">Gestionar períodos →</Link>
          </div>}
          <h2 id="available-title">Disponible actual</h2>
          <strong className="available-amount">{money(data.available)}</strong>
          <p>Tu dinero disponible, sin contar el ahorro.</p>
          {data.available !== null && Number(data.available) < 0 &&
            <p className="negative-balance">Saldo negativo · El disponible está por debajo de cero.</p>}
          {data.current_period && <dl className="home-totals" aria-label="Totales del período">
            <div><dt>Gastos</dt><dd>{money(data.expenses_total)}</dd></div>
            <div><dt>Ingresos</dt><dd>{money(data.income_total)}</dd></div>
          </dl>}
          <p className="home-note summary-date">
            Resumen a {formatDate(data.as_of_date)}<br />
            <small>Los ingresos incluyen los de ahorro.</small>
          </p>
        </section>
        <HomeInsights data={data} currency={settings!.currency} />
      </>}
    </div>
  );
}
