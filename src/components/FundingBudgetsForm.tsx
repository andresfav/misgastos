import { useState, type FormEvent } from "react";
import { useSetup } from "../hooks/useSetup";
import { useSubmit } from "../hooks/useSubmit";
import { useRequestAttempt } from "../hooks/useRequestAttempt";
import { isStaleData } from "../lib/errors";
import { formatMoney } from "../lib/money";
import { periodError, periodMutation, type PeriodSummary } from "../lib/periods";
import { editableFundingBudgets, draftBudgetTotal, fundingBudgetDraft, fundingBudgetParameters, fundingKey } from "../lib/fundingBudgets";
import { refreshFinancialData } from "../lib/refresh";
import { ErrorMessage } from "./Feedback";

export function FundingBudgetsForm({ summary, onMessage }: { summary: PeriodSummary; onMessage: (message: string) => void }) {
  const { settings } = useSetup();
  const rows = editableFundingBudgets(summary);
  const [draft, setDraft] = useState(() => fundingBudgetDraft(rows));
  const { busy, error, setError, submit } = useSubmit(periodError);
  const attempt = useRequestAttempt(`funding-budgets:${summary.period.id}`);
  let total: string | null = null;
  let validDraft = true;
  try { total = draftBudgetTotal(rows, draft); } catch { validDraft = false; }
  function save(event: FormEvent) {
    event.preventDefault();
    let parameters: ReturnType<typeof fundingBudgetParameters>;
    try { parameters = fundingBudgetParameters(summary.period.id, summary.period.version, rows, draft); }
    catch (failure) { setError((failure as Error).message); return; }
    void submit(async () => {
      try {
        await periodMutation("set_funding_budgets", { ...parameters, p_request_id: attempt.requestId(parameters) });
      } catch (failure) {
        if (isStaleData(failure)) {
          attempt.clear();
          onMessage("Los presupuestos o el período han cambiado. Se han recargado; revisa los importes antes de guardar de nuevo.");
          refreshFinancialData();
        }
        throw failure;
      }
      attempt.clear();
      onMessage("Presupuestos guardados. Tu dinero disponible no cambia.");
      refreshFinancialData();
    });
  }
  return <section className="period-section">
    <p>{summary.has_external_sources ? "Reparte tu límite de gasto entre los orígenes. El total se calcula sumando sus presupuestos." : "Define tu límite de gasto para este período."}</p>
    <p className="muted">Vacío significa sin presupuesto. 0 es un límite de cero. Estos límites no cambian tu dinero disponible.</p>
    {summary.budget_model === "legacy_total" && <p className="notice">El presupuesto actual es general y cuenta todos los gastos. Al guardar pasará a distribuirse por origen: se usará el importe que indiques para Disponible y se sumarán las asignaciones externas.</p>}
    <ErrorMessage message={error} />
    <form onSubmit={save}><fieldset disabled={busy || summary.period.status === "closed"}>
      <div className="category-budget-editor">{rows.map((row) => <label key={fundingKey(row)} className="category-budget-input">
        <span>{summary.has_external_sources ? row.name : "Presupuesto"} ({settings!.currency})
          {!row.is_active && <small>Origen inactivo{row.budget_amount === null ? " · Sin asignación" : " · Conserva su presupuesto"}</small>}</span>
        <input inputMode="decimal" aria-label={`Presupuesto de ${row.name} (${settings!.currency})`} placeholder="Sin asignar"
          disabled={!row.is_active && row.budget_amount === null} value={draft[fundingKey(row)] ?? ""}
          onChange={(e) => setDraft((previous) => ({ ...previous, [fundingKey(row)]: e.target.value }))} />
      </label>)}</div>
      {summary.has_external_sources && <p className="funding-budget-total" aria-live="polite">Presupuesto total calculado: <strong>
        {!validDraft ? "Revisa los importes" : total === null ? "Sin asignar" : formatMoney(total, settings!.currency)}
      </strong></p>}
      <button type="submit">{busy ? "Guardando…" : summary.has_external_sources ? "Guardar presupuestos" : "Guardar presupuesto"}</button>
    </fieldset></form>
  </section>;
}
