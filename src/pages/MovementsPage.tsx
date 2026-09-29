import { useState } from "react";
import { Link } from "react-router-dom";
import { useRemote } from "../hooks/useRemote";
import { useSetup } from "../hooks/useSetup";
import { useSubmit } from "../hooks/useSubmit";
import { useRequestAttempt } from "../hooks/useRequestAttempt";
import { readMovementScreen, mutateMovement } from "../lib/movements";
import { formatMoney } from "../lib/money";
import { formatDate } from "../lib/dates";
import { movementError, isStaleData } from "../lib/errors";
import { refreshFinancialData } from "../lib/refresh";
import {
  movementLabels,
  type Movement,
  type MovementKind,
  type References,
} from "../types/movements";
import { ErrorMessage, Loading } from "../components/Feedback";
import { MovementForm } from "../components/MovementForm";

function DeleteMovement({
  row,
  onDone,
  onCancel,
  onConflict,
}: {
  row: Movement;
  onDone: () => void;
  onCancel: () => void;
  onConflict: () => void;
}) {
  const { busy, error, submit } = useSubmit(movementError);
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
        <button className="button-secondary" disabled={busy} onClick={onCancel}>
          Cancelar
        </button>
      </div>
    </div>
  );
}
function MovementDetails({ row, refs }: { row: Movement; refs: References }) {
  const account = (id: string | null) =>
    id
      ? refs.accounts.find((a) => a.id === id)?.name || "Cuenta no disponible"
      : "Disponible";
  return (
    <div className="movement-details">
      {row.kind === "expense" && (
        <>
          <span>
            {refs.categories.find((c) => c.id === row.category_id)?.name ||
              "Categoría no disponible"}
          </span>
          {row.payment_method_id && (
            <span>
              Método:{" "}
              {refs.methods.find((m) => m.id === row.payment_method_id)?.name ||
                "No disponible"}
            </span>
          )}
          {row.merchant && <span>Comercio: {row.merchant}</span>}
          {row.note && <span>Nota: {row.note}</span>}
          {row.is_recurring && <span>Recurrente</span>}
        </>
      )}
      {row.kind === "income" && (
        <span>Destino: {account(row.savings_account_id)}</span>
      )}
      {row.kind === "transfer" && (
        <span>
          {account(row.from_savings_account_id)} →{" "}
          {account(row.to_savings_account_id)}
        </span>
      )}
    </div>
  );
}
export function MovementsPage() {
  const { data, loading, error, reload } = useRemote(readMovementScreen);
  const { settings } = useSetup();
  const [filter, setFilter] = useState<MovementKind | "all">("all");
  const [selected, setSelected] = useState<{
    row: Movement;
    action: "edit" | "delete";
  } | null>(null);
  const [message, setMessage] = useState("");
  const conflict = () => {
    setSelected(null);
    setMessage(
      "Los datos han cambiado o ya no existen. Se ha actualizado la lista; revisa el movimiento antes de volver a intentarlo.",
    );
  };
  const rows =
    data?.rows.filter((row) => filter === "all" || row.kind === filter) || [];
  return (
    <>
      <div className="page-heading">
        <div>
          <p className="eyebrow">TU ACTIVIDAD</p>
          <h1>Movimientos</h1>
        </div>
        <button
          className="button-secondary"
          disabled={loading || !!selected}
          onClick={reload}
        >
          Actualizar
        </button>
      </div>
      {message && (
        <p className="notice" role="status">
          {message}
        </p>
      )}
      {selected && data ? (
        <section className="card form-card">
          <h2>
            {selected.action === "edit" ? "Editar" : "Borrar"}{" "}
            {movementLabels[selected.row.kind].toLowerCase()}
          </h2>
          <p>
            {formatDate(selected.row.date)} ·{" "}
            {formatMoney(selected.row.amount, settings!.currency)}
          </p>
          {selected.action === "edit" ? (
            <MovementForm
              key={`${selected.row.id}:${selected.row.version}`}
              kind={selected.row.kind}
              row={selected.row}
              refs={data.refs}
              onCancel={() => setSelected(null)}
              onConflict={conflict}
              onSaved={() => {
                setSelected(null);
                setMessage("Movimiento actualizado.");
              }}
            />
          ) : (
            <DeleteMovement
              key={selected.row.id}
              row={selected.row}
              onCancel={() => setSelected(null)}
              onConflict={conflict}
              onDone={() => {
                setSelected(null);
                setMessage("Movimiento borrado.");
              }}
            />
          )}
        </section>
      ) : (
        <>
          <div
            className="segmented"
            role="group"
            aria-label="Filtrar movimientos"
          >
            {(["all", "expense", "income", "transfer"] as const).map(
              (value) => (
                <button
                  key={value}
                  aria-pressed={filter === value}
                  onClick={() => setFilter(value)}
                >
                  {value === "all" ? "Todos" : movementLabels[value]}
                </button>
              ),
            )}
          </div>
          <p className="muted">
            Hasta 100 movimientos recientes por tipo. Ordenados por fecha y
            momento de creación, del más reciente al más antiguo.
          </p>
          <ErrorMessage message={error} />
          {error && <button onClick={reload}>Reintentar</button>}
          {loading ? (
            <Loading />
          ) : (
            !error &&
            data &&
            (rows.length ? (
              <ul className="movement-list">
                {rows.map((row) => {
                  const open = data.refs.periods.some(
                    (p) => p.id === row.period_id && p.status === "open",
                  );
                  return (
                    <li key={`${row.kind}:${row.id}`} className="card">
                      <div className="movement-heading">
                        <div>
                          <span className={`movement-type ${row.kind}`}>
                            {movementLabels[row.kind]}
                          </span>
                          <time dateTime={row.date}>
                            {formatDate(row.date)}
                          </time>
                        </div>
                        <strong>
                          {formatMoney(row.amount, settings!.currency)}
                        </strong>
                      </div>
                      <h2>
                        {row.description ||
                          (row.kind === "expense"
                            ? row.merchant || "Gasto sin descripción"
                            : `${movementLabels[row.kind]} sin descripción`)}
                      </h2>
                      <MovementDetails row={row} refs={data.refs} />
                      {open ? (
                        <div className="form-actions">
                          <button
                            className="button-secondary"
                            onClick={() => {
                              setSelected({ row, action: "edit" });
                              setMessage("");
                            }}
                          >
                            Editar
                          </button>
                          <button
                            className="button-quiet danger-text"
                            onClick={() => {
                              setSelected({ row, action: "delete" });
                              setMessage("");
                            }}
                          >
                            Borrar
                          </button>
                        </div>
                      ) : (
                        <p className="muted">Período cerrado · Solo lectura</p>
                      )}
                    </li>
                  );
                })}
              </ul>
            ) : (
              <section className="card empty">
                <h2>
                  No hay movimientos{filter === "all" ? "" : " de este tipo"}
                </h2>
                <p>
                  Tu actividad aparecerá aquí cuando registres un movimiento.
                </p>
                <Link className="button" to="/anadir">
                  Añadir movimiento
                </Link>
              </section>
            ))
          )}
        </>
      )}
    </>
  );
}
