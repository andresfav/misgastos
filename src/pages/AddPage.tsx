import { useState } from "react";
import { useRemote } from "../hooks/useRemote";
import { readReferences } from "../lib/movements";
import { movementLabels, type MovementKind } from "../types/movements";
import { ErrorMessage, Loading } from "../components/Feedback";
import { MovementForm } from "../components/MovementForm";
export function AddPage() {
  const { data, error, loading, reload } = useRemote(readReferences);
  const [kind, setKind] = useState<MovementKind>("expense");
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
              setKind(value);
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
              key={kind}
              kind={kind}
              refs={data}
              onSaved={() =>
                setMessage(`${movementLabels[kind]} guardado correctamente.`)
              }
              onConflict={reload}
            />
          </section>
        )
      )}
    </>
  );
}
