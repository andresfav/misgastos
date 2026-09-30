import { useCallback, useState } from "react";
import { Link, useLocation, useNavigate } from "react-router-dom";
import { useRemote } from "../hooks/useRemote";
import { readMovementForEdit } from "../lib/movements";
import { movementLabels, type MovementKind } from "../types/movements";
import { MovementForm } from "../components/MovementForm";
import { ErrorMessage, Loading } from "../components/Feedback";

export function EditMovementPage({ id, kind }: { id: string; kind: MovementKind }) {
  const { data, loading, error, reload } = useRemote(useCallback(() => readMovementForEdit(kind, id), [kind, id]));
  const location = useLocation();
  const navigate = useNavigate();
  const [message, setMessage] = useState("");
  const returnTo = typeof location.state?.returnTo === "string" && /^\/movimientos(?:\?|$)/.test(location.state.returnTo) ? location.state.returnTo : `/movimientos?tipo=${kind}`;
  const editable = data?.row && data.refs.periods.some((period) => period.id === data.row!.period_id && period.status === "open");
  return <>
    <div className="page-heading"><h1>Editar {movementLabels[kind].toLowerCase()}</h1></div>
    <Link className="text-link" to={returnTo}>← Volver a Movimientos</Link>
    {message && <p className="notice" role="status">{message}</p>}
    <ErrorMessage message={error} />
    {error && <button onClick={reload}>Reintentar</button>}
    {loading ? <Loading text="Cargando movimiento…" /> : !error && data && (
      !data.row ? <p className="notice">Este movimiento ya no existe o no está disponible.</p>
        : !editable ? <p className="notice"><strong>Este movimiento es de solo lectura.</strong> Su período está cerrado o ya no está disponible.</p>
        : <section className="card form-card"><MovementForm key={`${data.row.id}:${data.row.version}`} kind={kind} row={data.row} refs={data.refs}
          onCancel={() => navigate(returnTo)}
          onConflict={() => { setMessage("Los datos han cambiado. Revisa el movimiento actualizado antes de guardar."); reload(); }}
          onSaved={() => navigate(returnTo, { replace: true, state: { message: "Movimiento actualizado." } })} /></section>
    )}
  </>;
}
