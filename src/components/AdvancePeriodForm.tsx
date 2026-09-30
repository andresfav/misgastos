import { useState, type FormEvent } from "react";
import { useSetup } from "../hooks/useSetup";
import { useSubmit } from "../hooks/useSubmit";
import { useRequestAttempt } from "../hooks/useRequestAttempt";
import { formatDate, periodDates, todayIn } from "../lib/dates";
import { isStaleData } from "../lib/errors";
import { shiftDay, periodError, periodLabels, periodMutation, transitionDates, type BudgetPeriod } from "../lib/periods";
import { refreshFinancialData } from "../lib/refresh";
import type { PeriodMode } from "../types/finance";
import { ErrorMessage } from "./Feedback";

export function AdvancePeriodForm({ period, onMessage, onAdvanced }: { period: BudgetPeriod; onMessage: (text: string) => void; onAdvanced: (period: BudgetPeriod) => void }) {
  const { settings } = useSetup();
  const today = todayIn(settings!.timezone);
  const [mode, setMode] = useState<PeriodMode>(period.mode);
  const [start, setStart] = useState(period.end_date ? shiftDay(period.end_date, 1) : today);
  const [end, setEnd] = useState(today);
  const [confirmation, setConfirmation] = useState<Record<string, unknown> | null>(null);
  const { busy, error, setError, submit } = useSubmit(periodError);
  const attempt = useRequestAttempt(`advance:${period.id}`);
  const natural = mode === "monthly" || mode === "annual";
  const naturalDates = natural ? periodDates(mode, today, "", "") : null;
  function review(event: FormEvent) {
    event.preventDefault();
    try {
      const dates = transitionDates(period, mode, todayIn(settings!.timezone), start, end);
      setError("");
      setConfirmation({ p_current_period_id: period.id, p_expected_version: period.version, p_mode: mode, ...dates, p_general_budget: null });
    } catch (failure) { setError((failure as Error).message); }
  }
  function advance() {
    if (!confirmation) return;
    const parameters = confirmation;
    void submit(async () => {
      try {
        const result = await periodMutation("advance_period", { ...parameters, p_request_id: attempt.requestId(parameters) });
        onAdvanced(result.opened_period as BudgetPeriod);
      } catch (failure) {
        if (isStaleData(failure)) {
          attempt.clear();
          setConfirmation(null);
          onMessage("El período ha cambiado o se ha cerrado. Recargando; revisa los datos y vuelve a intentarlo.");
          refreshFinancialData();
        }
        throw failure;
      }
      attempt.clear();
      onMessage("");
      refreshFinancialData();
    });
  }
  return <section className="period-section">
    <p>Se cerrará el período actual y su disponible final pasará automáticamente al saldo inicial del siguiente. Este arrastre no es un ingreso. El período cerrado quedará inmutable.</p>
    <p className="muted">El nuevo período comienza sin presupuestos. Podrás configurarlos después.</p>
    <ErrorMessage message={error} />
    {confirmation ? <div className="notice" role="region" aria-label="Confirmar transición">
      <h4>Confirma el cierre y la apertura</h4>
      <p>Nuevo período: {periodLabels[mode]}, desde {formatDate(String(confirmation.p_start_date))}{confirmation.p_end_date ? ` hasta ${formatDate(String(confirmation.p_end_date))}` : " → próximo cobro"}.</p>
      <p>El período actual se cerrará el {formatDate(period.mode === "between_paydays" ? shiftDay(String(confirmation.p_start_date), -1) : period.end_date!)}. Después no podrás editar sus movimientos ni presupuestos.</p>
      <div className="form-actions"><button disabled={busy} onClick={advance}>{busy ? "Abriendo período…" : "Cerrar y comenzar nuevo período"}</button><button disabled={busy} className="button-secondary" onClick={() => setConfirmation(null)}>Volver al formulario</button></div>
    </div> : <form onSubmit={review}><fieldset disabled={busy}>
      <label>Tipo de período<select value={mode} onChange={(e) => setMode(e.target.value as PeriodMode)}>{Object.entries(periodLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
      {naturalDates ? <p className="notice">{formatDate(naturalDates.p_start_date)} — {formatDate(naturalDates.p_end_date!)}. Debe coincidir con el {mode === "monthly" ? "mes" : "año"} natural actual completo, sin solapar el período anterior.</p> : <div className="form-row">
        <label>Fecha de inicio del nuevo período<input required type="date" max={today} value={start} onChange={(e) => setStart(e.target.value)} /></label>
        {mode === "custom" && <label>Fecha final del siguiente período<input required type="date" min={start > today ? start : today} value={end} onChange={(e) => setEnd(e.target.value)} /></label>}
      </div>}
      {mode === "custom" && <p className="notice">{start === end ? "Atención: estás creando un período de un solo día." : "El período debe incluir hoy. La fecha final puede ser futura."}</p>}
      {mode === "between_paydays" && <p className="muted">El nuevo período durará hasta el próximo cobro. La fecha de inicio debe ser hoy o anterior.</p>}
      {(naturalDates?.p_start_date || start) && <p className="notice">El período actual terminará el {formatDate(period.mode === "between_paydays" ? shiftDay(naturalDates?.p_start_date ?? start, -1) : period.end_date!)}. El dinero disponible restante se trasladará automáticamente al nuevo período.</p>}
      <button type="submit">Revisar y continuar</button>
    </fieldset></form>}
  </section>;
}
