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
  const [name, setName] = useState(item.name);
  const { busy, error, setError, submit } = useSubmit();
  const mutate = (action: "rename" | "set") => {
    if (action === "rename" && !name.trim()) {
      setError("Introduce un nombre.");
      return;
    }
    void submit(async () => {
      try {
        await mutateCatalog(kind, action, {
          p_id: item.id,
          p_expected_version: item.version,
          ...(action === "rename"
            ? { p_name: name.trim() }
            : { p_is_active: !item.is_active }),
        });
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
      if (detail.current) detail.current.open = false;
      summary.current?.focus();
      onMessage("Cambios guardados.");
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
      ) : (
        <div className="form-actions">
          {item.is_active && <button
            className="button-secondary"
            disabled={busy}
            onClick={() => {
              setName(item.name);
              setEditing(true);
            }}
          >
            Renombrar
          </button>}
          <button
            className="button-quiet"
            disabled={busy}
            onClick={() => mutate("set")}
          >
            {busy ? "Guardando…" : item.is_active ? "Desactivar" : "Restaurar"}
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
  const inactive = sorted.filter((item) => !item.is_active);
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
      <h2 ref={listHeading} tabIndex={-1} className="settings-catalog-heading">{kind === "category" ? "Activas" : "Activos"}</h2>
      {active.length ? rows(active) : <p className="muted">{kind === "category" ? "No hay categorías activas." : "No hay métodos activos."}</p>}
      {inactive.length > 0 && <details className="settings-disclosure settings-inactive">
        <summary className="settings-row"><span>{kind === "category" ? "Categorías inactivas" : "Métodos inactivos"} · {inactive.length}</span><span className="settings-chevron" aria-hidden="true">⌄</span></summary>
        {rows(inactive)}
      </details>}
      <p className="muted settings-catalog-help">Desactivar conserva el historial. Puedes restaurar cualquier elemento más adelante.</p>
    </section>
  );
}
