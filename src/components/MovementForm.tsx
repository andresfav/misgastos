import { useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { useSetup } from "../hooks/useSetup";
import { useSubmit } from "../hooks/useSubmit";
import { useRequestAttempt } from "../hooks/useRequestAttempt";
import { todayIn } from "../lib/dates";
import { mutateMovement } from "../lib/movements";
import {
  movementDraft,
  movementParameters,
  type MovementDraft,
} from "../lib/movementForm";
import { isStaleData, movementError } from "../lib/errors";
import { refreshFinancialData } from "../lib/refresh";
import {
  movementLabels,
  type Movement,
  type MovementKind,
  type References,
} from "../types/movements";
import { ErrorMessage } from "./Feedback";
import { AutoGrowingNote } from "./AutoGrowingNote";

export function MovementForm({
  kind,
  refs,
  row,
  onSaved,
  onConflict,
  onCancel,
  initialTransfer,
  initialDate,
}: {
  kind: MovementKind;
  refs: References;
  row?: Movement;
  onSaved: () => void;
  onConflict: () => void;
  onCancel?: () => void;
  initialDate?: string;
  initialTransfer?: { from: string; to: string };
}) {
  const { settings } = useSetup();
  const today = todayIn(settings!.timezone);
  const [draft, setDraft] = useState(() => ({
    ...movementDraft(!row && initialDate ? initialDate : today, row),
    ...(!row && kind === "transfer" ? initialTransfer : {}),
  }));
  const { busy, error, setError, submit } = useSubmit(movementError);
  const attempt = useRequestAttempt(
    `${row ? `update:${row.id}` : "create"}:${kind}`,
  );
  const set = <K extends keyof MovementDraft>(
    key: K,
    value: MovementDraft[K],
  ) => setDraft((d) => ({ ...d, [key]: value }));
  const oldExpense = row?.kind === "expense" ? row : undefined;
  const categories = refs.categories.filter(
    (c) => c.is_active || c.id === oldExpense?.category_id,
  );
  const methods = refs.methods.filter(
    (m) => m.is_active || m.id === oldExpense?.payment_method_id,
  );
  const accounts = (oldId?: string | null) =>
    refs.accounts.filter((a) => a.is_active || a.id === oldId);
  const accountOptions = (oldId?: string | null, excluded?: string) =>
    accounts(oldId).map((a) => (
      <option key={a.id} value={a.id} disabled={a.id === excluded}>
        {a.name}
        {!a.is_active ? " (inactiva, actual)" : ""}
      </option>
    ));
  const periodOpen = row
    ? refs.periods.some((p) => p.id === row.period_id && p.status === "open")
    : refs.periods.some((p) => p.status === "open");
  const noCategory = kind === "expense" && !categories.length;
  const noAccounts =
    kind === "transfer" &&
    !accounts(row?.kind === "transfer" ? row.from_savings_account_id : null)
      .length &&
    !accounts(row?.kind === "transfer" ? row.to_savings_account_id : null)
      .length;
  const save = (event: FormEvent) => {
    event.preventDefault();
    let parameters: Record<string, unknown>;
    try {
      parameters = movementParameters(
        kind,
        draft,
        todayIn(settings!.timezone),
        refs,
        row,
      );
    } catch (failure) {
      setError((failure as Error).message);
      return;
    }
    void submit(async () => {
      try {
        await mutateMovement(
          row ? "update" : "create",
          kind,
          parameters,
          attempt.requestId(parameters),
        );
      } catch (failure) {
        if (isStaleData(failure)) {
          attempt.clear();
          onConflict();
          refreshFinancialData();
        }
        throw failure;
      }
      attempt.clear();
      setDraft(movementDraft(todayIn(settings!.timezone)));
      onSaved();
      refreshFinancialData();
    });
  };
  return (
    <form className="movement-form" onSubmit={save}>
      <ErrorMessage message={error} />
      {!periodOpen && (
        <p className="notice">
          No hay un período abierto para este movimiento. Los períodos cerrados
          son de solo lectura.
        </p>
      )}
      {noCategory && (
        <p className="notice">
          Necesitas una categoría para registrar gastos.{" "}
          <Link to="/ajustes">Crear una categoría en Ajustes</Link>.
        </p>
      )}
      {kind !== "expense" && !refs.accounts.some((a) => a.is_active) && (
        <p className="notice">
          No tienes cuentas de ahorro activas.{" "}
          {kind === "income" ? "Puedes ingresar dinero en Disponible. " : ""}La
          creación de cuentas está disponible en <Link to="/ahorro">Ahorro</Link>.
        </p>
      )}
      <fieldset disabled={busy || !periodOpen}>
        <div className="form-row">
          <label>
            Fecha
            <input
              type="date"
              required
              max={today}
              value={draft.date}
              onChange={(e) => set("date", e.target.value)}
            />
          </label>
          <label>
            Importe ({settings!.currency})
            <input
              inputMode="decimal"
              required
              value={draft.amount}
              onChange={(e) => set("amount", e.target.value)}
              placeholder="0,00"
            />
            <small>Mayor que 0, con hasta dos decimales.</small>
          </label>
        </div>
        {kind === "expense" && (
          <>
            <label>
              Categoría
              <select
                required
                value={draft.category}
                onChange={(e) => set("category", e.target.value)}
              >
                <option value="">Selecciona una categoría</option>
                {categories.map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.name}
                    {!c.is_active ? " (inactiva, actual)" : ""}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Método de pago <span className="optional">Opcional</span>
              <select
                value={draft.method}
                onChange={(e) => set("method", e.target.value)}
              >
                <option value="">Sin método de pago</option>
                {methods.map((m) => (
                  <option key={m.id} value={m.id}>
                    {m.name}
                    {!m.is_active ? " (inactivo, actual)" : ""}
                  </option>
                ))}
              </select>
            </label>
          </>
        )}
        {kind === "income" && (
          <label>
            Destino
            <select
              value={draft.account}
              onChange={(e) => set("account", e.target.value)}
            >
              <option value="">Disponible</option>
              {accountOptions(
                row?.kind === "income" ? row.savings_account_id : null,
              )}
            </select>
          </label>
        )}
        {kind === "transfer" && (
          <div className="form-row">
            <label>
              Origen
              <select
                value={draft.from}
                onChange={(e) => set("from", e.target.value)}
              >
                <option value="">Disponible</option>
                {accountOptions(
                  row?.kind === "transfer" ? row.from_savings_account_id : null,
                  draft.to,
                )}
              </select>
            </label>
            <label>
              Destino
              <select
                value={draft.to}
                onChange={(e) => set("to", e.target.value)}
              >
                <option value="" disabled={!draft.from}>
                  Disponible
                </option>
                {accountOptions(
                  row?.kind === "transfer" ? row.to_savings_account_id : null,
                  draft.from,
                )}
              </select>
            </label>
          </div>
        )}
        <label>
          Descripción <span className="optional">Opcional</span>
          <input
            value={draft.description}
            onChange={(e) => set("description", e.target.value)}
          />
        </label>
        {kind === "expense" && (
          <>
            <label>
              Comercio <span className="optional">Opcional</span>
              <input
                value={draft.merchant}
                onChange={(e) => set("merchant", e.target.value)}
              />
            </label>
            <label>
              Nota <span className="optional">Opcional</span>
              <AutoGrowingNote
                value={draft.note}
                onChange={(e) => set("note", e.target.value)}
              />
            </label>
            <label className="checkbox-label">
              <input
                type="checkbox"
                checked={draft.recurring}
                onChange={(e) => set("recurring", e.target.checked)}
              />
              Gasto recurrente
            </label>
            <small>Solo lo marca; no genera gastos automáticamente.</small>
          </>
        )}
        <div className="form-actions">
          <button disabled={noCategory || noAccounts} type="submit">
            {busy
              ? "Guardando…"
              : row
                ? "Guardar cambios"
                : `Guardar ${movementLabels[kind].toLowerCase()}`}
          </button>
        </div>
      </fieldset>
      {onCancel && (
        <button
          type="button"
          className="button-secondary"
          disabled={busy}
          onClick={onCancel}
        >
          Cancelar
        </button>
      )}
    </form>
  );
}
