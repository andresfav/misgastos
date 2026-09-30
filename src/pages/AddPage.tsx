import { useState } from "react";
import { useSearchParams } from "react-router-dom";
import { useRemote } from "../hooks/useRemote";
import { readReferences } from "../lib/movements";
import { movementLabels, type MovementKind } from "../types/movements";
import { ErrorMessage, Loading } from "../components/Feedback";
import { EditMovementPage } from "./EditMovementPage";
import { MovementForm } from "../components/MovementForm";
function CreateMovementPage() {
  const { data, error, loading, reload } = useRemote(readReferences);
  const [searchParams, setSearchParams] = useSearchParams();
  const requestedKind = searchParams.get("tipo");
  const kind: MovementKind = requestedKind === "income" || requestedKind === "transfer"
    ? requestedKind : "expense";
  const requestedDate = searchParams.get("fecha");
  const initialDate = kind === "income" && requestedDate && /^\d{4}-\d{2}-\d{2}$/.test(requestedDate)
    && !Number.isNaN(Date.parse(requestedDate)) && new Date(requestedDate).toISOString().slice(0, 10) === requestedDate ? requestedDate : undefined;
  const [message, setMessage] = useState("");
  return (
    <>
      <div className="page-heading">
        <div>
          <p className="eyebrow">UN NUEVO MOVIMIENTO</p>
          <h1>Añadir</h1>
        </div>
      </div>
      <div className="segmented" role="group" aria-label="Tipo de movimiento">
        {(Object.keys(movementLabels) as MovementKind[]).map((value) => (
          <button
            key={value}
            aria-pressed={kind === value}
            onClick={() => {
              setSearchParams({ tipo: value }, { replace: true });
              setMessage("");
            }}
          >
            {movementLabels[value]}
          </button>
        ))}
      </div>
      {message && (
        <p className="notice success" role="status">
          {message}
        </p>
      )}
      <ErrorMessage message={error} />
      {error && <button onClick={reload}>Reintentar carga</button>}
      {loading ? (
        <Loading />
      ) : (
        data &&
        !error && (
          <section className="card form-card">
            <h2>{movementLabels[kind]}</h2>
            <MovementForm
              key={`${kind}:${initialDate ?? ""}`}
              kind={kind}
              initialDate={initialDate}
              refs={data}
              onSaved={() =>
                setMessage(kind === "transfer" ? "Transferencia guardada." : `${movementLabels[kind]} guardado.`)
              }
              onConflict={reload}
            />
          </section>
        )
      )}
    </>
  );
}

export function AddPage() {
  const [params] = useSearchParams();
  const id = params.get("editar");
  const kind = params.get("tipo");
  if (id && (kind === "expense" || kind === "income" || kind === "transfer"))
    return <EditMovementPage key={`${kind}:${id}`} id={id} kind={kind} />;
  return <CreateMovementPage />;
}
