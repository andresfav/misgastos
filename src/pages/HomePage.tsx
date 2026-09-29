import { useRemote } from "../hooks/useRemote";
import { readFinancialState } from "../lib/finance";
import { formatMoney } from "../lib/money";
import { formatDate } from "../lib/dates";
import { useSetup } from "../hooks/useSetup";
import { ErrorMessage, Loading } from "../components/Feedback";

export function HomePage() {
  const { settings } = useSetup();
  const { data, error, loading, reload } = useRemote(readFinancialState);
  const money = (value: number | string | null) =>
    formatMoney(value, settings!.currency);
  return (
    <>
      <div className="page-heading">
        <div>
          <p className="eyebrow">TU RESUMEN</p>
          <h1>Inicio</h1>
          <p>Así están tus finanzas.</p>
        </div>
        <button
          className="button-secondary"
          disabled={loading}
          onClick={reload}
        >
          {loading ? "Cargando…" : "Actualizar"}
        </button>
      </div>
      <ErrorMessage message={error} />
      {loading ? (
        <Loading />
      ) : (
        !error &&
        data && (
          <>
            <p className="muted">
              A {formatDate(data.as_of_date)} · {settings!.timezone}
            </p>
            {data.current_period ? (
              <>
                <section className="balance-card">
                  <p>Disponible actual</p>
                  <strong>{money(data.available)}</strong>
                  <span>
                    Período: {formatDate(data.current_period.start_date)}
                    {data.current_period.end_date
                      ? ` — ${formatDate(data.current_period.end_date)}`
                      : " · Sin fecha final"}
                  </span>
                </section>
                <div className="metrics">
                  <section className="card metric">
                    <p>Gastos del período</p>
                    <strong>{money(data.expenses_total)}</strong>
                  </section>
                  <section className="card metric">
                    <p>Ingresos del período</p>
                    <strong>{money(data.income_total)}</strong>
                    <small>Incluye los ingresos destinados a ahorro.</small>
                  </section>
                  <section className="card metric">
                    <p>Presupuesto general</p>
                    <strong>
                      {data.general_budget === null
                        ? "Sin presupuesto"
                        : money(data.general_budget)}
                    </strong>
                    {data.general_budget !== null && (
                      <small>
                        Restante: {money(data.general_budget_remaining)}
                      </small>
                    )}
                  </section>
                </div>
              </>
            ) : (
              <section className="card empty">
                <h2>No hay un período abierto</h2>
                <p>
                  Tu historial está conservado. La gestión de los siguientes
                  períodos llegará en el próximo bloque.
                </p>
              </section>
            )}
            <section className="card savings">
              <h2>Tus cuentas de ahorro</h2>
              {data.savings_balances.length ? (
                <ul className="account-list">
                  {data.savings_balances.map((account) => (
                    <li key={account.id}>
                      <span>
                        {account.name}
                        {!account.is_active && <small>Inactiva</small>}
                      </span>
                      <strong>{money(account.current_balance)}</strong>
                    </li>
                  ))}
                </ul>
              ) : (
                <div className="empty">
                  <span className="empty-symbol" aria-hidden="true">
                    ◇
                  </span>
                  <p>Aún no tienes cuentas de ahorro.</p>
                  <small>
                    Podrás crearlas desde Ahorro en el próximo bloque.
                  </small>
                </div>
              )}
            </section>
          </>
        )
      )}
    </>
  );
}
