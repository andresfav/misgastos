import { useState, type FormEvent } from "react";
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
      onMessage("Cambios guardados.");
      refreshFinancialData();
    });
  };
  return (
    <li className="catalog-row">
      <div className="catalog-name">
        <strong>{item.name}</strong>
        <span className="muted">{item.is_active ? "Activo" : "Inactivo"}</span>
      </div>
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
                onClick={() => setEditing(false)}
              >
                Cancelar
              </button>
            </div>
          </fieldset>
        </form>
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
            className="button-quiet"
            disabled={busy}
            onClick={() => mutate("set")}
          >
            {busy ? "Guardando…" : item.is_active ? "Desactivar" : "Restaurar"}
          </button>
        </div>
      )}
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
      onMessage(
        kind === "category" ? "Categoría creada." : "Método de pago creado.",
      );
      refreshFinancialData();
    });
  };
  return (
    <section className="card">
      <h2>{title}</h2>
      <p>
        Desactivar conserva el historial. Puedes restaurar cualquier elemento
        más adelante.
      </p>
      <ErrorMessage message={error} />
      <form onSubmit={create}>
        <fieldset disabled={busy}>
          <label>
            {kind === "category" ? "Nueva categoría" : "Nuevo método de pago"}
            <input
              required
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder={
                kind === "category"
                  ? "Por ejemplo, Alimentación"
                  : "Por ejemplo, Tarjeta"
              }
            />
          </label>
          <button type="submit">{busy ? "Creando…" : "Crear"}</button>
        </fieldset>
      </form>
      {items.length ? (
        <ul className="catalog-list">
          {[...items]
            .sort(
              (a, b) =>
                Number(b.is_active) - Number(a.is_active) ||
                a.name.localeCompare(b.name, "es"),
            )
            .map((item) => (
              <CatalogRow
                key={`${item.id}:${item.version}`}
                item={item}
                kind={kind}
                onMessage={onMessage}
              />
            ))}
        </ul>
      ) : (
        <p className="empty">Todavía no hay {title.toLowerCase()}.</p>
      )}
    </section>
  );
}
