import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { useSubmit } from "../hooks/useSubmit";
import { useRequestAttempt } from "../hooks/useRequestAttempt";
import { mutateMovement } from "../lib/movements";
import { formatMoney } from "../lib/money";
import { formatDate } from "../lib/dates";
import { movementError, isStaleData } from "../lib/errors";
import { refreshFinancialData } from "../lib/refresh";
import { accountName, movementContext } from "../lib/movementHistory";
import { movementLabels, type Movement, type References } from "../types/movements";
import type { Currency } from "../types/finance";
import { ErrorMessage } from "./Feedback";
function DeleteMovement({
  row,
  onDone,
  onCancel,
  onConflict,
  onBusy,
}: {
  row: Movement;
  onDone: () => void;
  onCancel: () => void;
  onConflict: () => void;
  onBusy: (busy: boolean) => void;
}) {
  const { busy, error, submit } = useSubmit(movementError);
  useEffect(() => onBusy(busy), [busy, onBusy]);
  const attempt = useRequestAttempt(`delete:${row.kind}:${row.id}`);
  const remove = () =>
    void submit(async () => {
      const parameters = { p_id: row.id, p_expected_version: row.version };
      try {
        await mutateMovement(
          "delete",
          row.kind,
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
      onDone();
      refreshFinancialData();
    });
  return (
    <div className="delete-confirm">
      <p>
        ¿Borrar este movimiento? Se actualizarán los saldos afectados. Esta
        acción no se puede deshacer.
      </p>
      <ErrorMessage message={error} />
      <div className="form-actions">
        <button className="button-danger" disabled={busy} onClick={remove}>
          {busy ? "Borrando…" : "Confirmar borrado"}
        </button>
        <button className="button-secondary" autoFocus disabled={busy} onClick={onCancel}>
          Cancelar
        </button>
      </div>
    </div>
  );
}
export function MovementDetail({ row, refs, currency, returnTo, onClose, onDeleted, onConflict }: {
  row: Movement; refs: References; currency: Currency; returnTo: string;
  onClose: () => void; onDeleted: () => void; onConflict: () => void;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [deleting, setDeleting] = useState(false);
  const [busy, setBusy] = useState(false);
  const label = movementLabels[row.kind].toLowerCase();
  const period = refs.periods.find((item) => item.id === row.period_id);
  const editable = period?.status === "open";
  useEffect(() => {
    const node = dialog.current!;
    node.showModal();
    return () => node.close();
  }, []);
  return <dialog ref={dialog} className="movement-dialog" aria-labelledby="movement-detail-title"
    onCancel={(event) => { event.preventDefault(); if (!busy) onClose(); }}>
    <div className="detail-heading"><h2 id="movement-detail-title">{movementLabels[row.kind]}</h2>
      <button className="button-quiet" onClick={onClose} disabled={busy}>Cerrar</button></div>
    <p className={`detail-amount history-amount ${row.kind}`}>{row.kind === "expense" ? "−" : row.kind === "income" ? "+" : ""}{formatMoney(row.amount, currency)}</p>
    <dl className="detail-facts">
      <div><dt>Fecha</dt><dd>{formatDate(row.date)}</dd></div>
      {row.kind === "expense" && <>
        <div><dt>Categoría</dt><dd>{movementContext(row, refs)}</dd></div>
        <div><dt>Método de pago</dt><dd>{row.payment_method_id ? refs.methods.find((method) => method.id === row.payment_method_id)?.name || "Método no disponible" : "Sin método"}</dd></div>
        <div><dt>Comercio</dt><dd>{row.merchant || "Sin comercio"}</dd></div>
      </>}
      {row.kind === "transfer" && <div><dt>Origen</dt><dd>{accountName(row.from_savings_account_id, refs)}</dd></div>}
      {row.kind !== "expense" && <div><dt>Destino</dt><dd>{accountName(row.kind === "income" ? row.savings_account_id : row.to_savings_account_id, refs)}</dd></div>}
      <div className="detail-full"><dt>Descripción</dt><dd>{row.description || "Sin descripción"}</dd></div>
      {row.kind === "expense" && <>
        <div><dt>Recurrente</dt><dd>{row.is_recurring ? "Sí" : "No"}</dd></div>
        <div className="detail-full"><dt>Nota</dt><dd>{row.note || "Sin nota"}</dd></div>
      </>}
    </dl>
    {!editable ? <p className="notice"><strong>{period?.status === "closed" ? "Período cerrado" : "Período no disponible"}</strong><br />Este movimiento es de solo lectura.</p>
      : deleting ? <DeleteMovement row={row} onDone={onDeleted} onCancel={() => setDeleting(false)} onConflict={onConflict} onBusy={setBusy} />
      : <div className="form-actions detail-actions">
        <Link className="button" to={`/anadir?tipo=${row.kind}&editar=${encodeURIComponent(row.id)}`} state={{ returnTo }}>Editar {label}</Link>
        <button className="button-secondary danger-text" onClick={() => setDeleting(true)}>Eliminar {label}</button>
      </div>}
  </dialog>;
}
