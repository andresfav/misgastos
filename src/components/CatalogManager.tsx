import { useRef, useState, type FormEvent } from "react";
import { useSubmit } from "../hooks/useSubmit";
import { mutateCatalog } from "../lib/movements";
import { isStaleData } from "../lib/errors";
import { refreshFinancialData } from "../lib/refresh";
import type { CatalogItem, CatalogKind } from "../types/movements";
import { ErrorMessage } from "./Feedback";

function CatalogRow({
  item,
  kind,
  onMessage,
}: {
  item: CatalogItem;
  kind: CatalogKind;
  onMessage: (message: string) => void;
}) {
  const detail = useRef<HTMLDetailsElement>(null);
  const summary = useRef<HTMLElement>(null);
  const [editing, setEditing] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [name, setName] = useState(item.name);
  const { busy, error, setError, submit } = useSubmit();
  const mutate = (action: "rename" | "delete") => {
    if (action === "rename" && !name.trim()) {
      setError("Introduce un nombre.");
      return;
    }
    void submit(async () => {
      try {
        const result = await mutateCatalog(kind, action, {
          p_id: item.id,
          p_expected_version: item.version,
          ...(action === "rename"
            ? { p_name: name.trim() }
            : {}),
        });
        if (action === "delete") {
          onMessage(result?.mode === "hard_deleted"
            ? kind === "category" ? "Categoría eliminada definitivamente." : "Método eliminado definitivamente."
            : kind === "category" ? "Categoría borrada. Su historial se conserva." : "Método borrado. Su historial se conserva.");
        }
      } catch (failure) {
        if (isStaleData(failure)) {
          onMessage(
            "Los datos han cambiado. Se ha actualizado la lista; revisa el elemento antes de volver a guardar.",
          );
          refreshFinancialData();
        }
        throw failure;
      }
      setEditing(false);
      setDeleting(false);
      if (detail.current) detail.current.open = false;
      summary.current?.focus();
      if (action === "rename") onMessage("Nombre actualizado.");
      refreshFinancialData();
    });
  };
  return (
    <li>
      <details ref={detail} className="settings-disclosure">
        <summary ref={summary} className="settings-row"><span>{item.name}</span><span className="settings-chevron" aria-hidden="true">⌄</span></summary>
        <div className="settings-row-detail">
      <ErrorMessage message={error} />
      {editing ? (
        <form
          onSubmit={(e) => {
            e.preventDefault();
            mutate("rename");
          }}
        >
          <fieldset disabled={busy}>
            <label>
              Nuevo nombre
              <input
                autoFocus
                required
                value={name}
                onChange={(e) => setName(e.target.value)}
              />
            </label>
            <div className="form-actions">
              <button type="submit">
                {busy ? "Guardando…" : "Guardar nombre"}
              </button>
              <button
                type="button"
                className="button-secondary"
                onClick={() => { setEditing(false); summary.current?.focus(); }}
              >
                Cancelar
              </button>
            </div>
          </fieldset>
        </form>
      ) : deleting ? (
        <div className="delete-confirm">
          <p><strong>{item.has_history ? "Borrar" : "Eliminar"} {kind === "category" ? "categoría" : "método"}</strong></p>
          <p>{item.has_history
            ? `Dejará de aparecer en Ajustes y en los nuevos gastos. ${kind === "category" ? "Los gastos y presupuestos" : "Los gastos"} anteriores conservarán su nombre.`
            : "Nunca se ha utilizado y se eliminará definitivamente. Esta acción no se puede deshacer."}</p>
          <div className="form-actions">
            <button className="button-danger" disabled={busy} onClick={() => mutate("delete")}>
              {busy ? "Guardando…" : item.has_history ? "Borrar" : "Eliminar"}
            </button>
            <button className="button-secondary" disabled={busy} onClick={() => setDeleting(false)}>Cancelar</button>
          </div>
        </div>
      ) : (
        <div className="form-actions">
          <button
            className="button-secondary"
            disabled={busy}
            onClick={() => {
              setName(item.name);
              setEditing(true);
            }}
          >
            Renombrar
          </button>
          <button
            className="button-quiet danger-text"
            disabled={busy}
            onClick={() => setDeleting(true)}
          >
            {item.has_history ? "Borrar" : "Eliminar"}
          </button>
        </div>
      )}
        </div>
      </details>
    </li>
  );
}
export function CatalogManager({
  kind,
  items,
  onMessage,
}: {
  kind: CatalogKind;
  items: CatalogItem[];
  onMessage: (message: string) => void;
}) {
  const creator = useRef<HTMLDetailsElement>(null);
  const createTrigger = useRef<HTMLElement>(null);
  const listHeading = useRef<HTMLHeadingElement>(null);
  const [name, setName] = useState("");
  const { busy, error, setError, submit } = useSubmit();
  const title = kind === "category" ? "Categorías" : "Métodos de pago";
  const create = (event: FormEvent) => {
    event.preventDefault();
    if (!name.trim()) {
      setError("Introduce un nombre.");
      return;
    }
    void submit(async () => {
      await mutateCatalog(kind, "create", { p_name: name.trim() });
      setName("");
      if (creator.current) creator.current.open = false;
      createTrigger.current?.focus();
      onMessage(
        kind === "category" ? "Categoría creada." : "Método de pago creado.",
      );
      refreshFinancialData();
    });
  };
  const sorted = [...items].sort((a, b) => a.name.localeCompare(b.name, "es"));
  const active = sorted.filter((item) => item.is_active);
  const rows = (entries: CatalogItem[]) => <ul className="settings-catalog-list">
    {entries.map((item) => <CatalogRow key={item.id} item={item} kind={kind} onMessage={(message) => {
      // A state change moves the row to another list; keep keyboard focus in the catalog.
      listHeading.current?.focus();
      onMessage(message);
    }} />)}
  </ul>;
  return (
    <section className="settings-content" aria-label={title}>
      <details ref={creator} className="settings-disclosure settings-create">
        <summary ref={createTrigger} className="button button-secondary">{kind === "category" ? "+ Nueva categoría" : "+ Nuevo método"}</summary>
        <form onSubmit={create}>
          <fieldset disabled={busy}>
            <label>Nombre
              <input required value={name} onChange={(e) => setName(e.target.value)} placeholder={kind === "category" ? "Por ejemplo, Alimentación" : "Por ejemplo, Tarjeta"} />
            </label>
            <div className="form-actions">
              <button type="submit">{busy ? "Creando…" : kind === "category" ? "Crear categoría" : "Crear método"}</button>
              <button type="button" className="button-secondary" onClick={() => {
                if (creator.current) creator.current.open = false;
                setName(""); setError(""); createTrigger.current?.focus();
              }}>Cancelar</button>
            </div>
          </fieldset>
          <ErrorMessage message={error} />
        </form>
      </details>
      <h2 ref={listHeading} tabIndex={-1} className="settings-catalog-heading">{title}</h2>
      {active.length ? rows(active) : <p className="muted">{kind === "category" ? "No hay categorías activas." : "No hay métodos activos."}</p>}
      <p className="muted settings-catalog-help">Los elementos usados se borran de las vistas normales sin perder su historial.</p>
    </section>
  );
}
