import { useState } from "react";
import { useRemote } from "../hooks/useRemote";
import { readCatalogManagement } from "../lib/movements";
import { CatalogManager } from "./CatalogManager";
import { ErrorMessage, Loading } from "./Feedback";
import type { CatalogKind } from "../types/movements";

export function CatalogSettings({ kind }: { kind: CatalogKind }) {
  const { data, error, loading, reload } = useRemote(readCatalogManagement);
  const [message, setMessage] = useState("");
  return <>
    {message && <p className="notice success" role="status">{message}</p>}
    <ErrorMessage message={error} />
    {error && <button onClick={reload} disabled={loading}>Reintentar</button>}
    {loading && !data && <Loading />}
    {data && <fieldset className="catalog-loading" disabled={loading || !!error} aria-busy={loading}>
      {loading && <Loading text="Actualizando…" />}
      <CatalogManager kind={kind} items={kind === "category" ? data.categories : data.methods} onMessage={setMessage} />
    </fieldset>}
  </>;
}
