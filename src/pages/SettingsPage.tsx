import { useState } from "react";
import { Link } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { useSetup } from "../hooks/useSetup";
import { useRemote } from "../hooks/useRemote";
import { readReferences } from "../lib/movements";
import { CatalogManager } from "../components/CatalogManager";
import { ErrorMessage, Loading } from "../components/Feedback";
export function SettingsPage() {
  const { session } = useAuth();
  const { settings } = useSetup();
  const { data, error, loading, reload } = useRemote(readReferences);
  const [message, setMessage] = useState("");
  return (
    <>
      <div className="page-heading">
        <div>
          <p className="eyebrow">TU ESPACIO</p>
          <h1>Ajustes</h1>
        </div>
        <button
          className="button-secondary"
          disabled={loading}
          onClick={reload}
        >
          Actualizar
        </button>
      </div>
      <section className="card">
        <h2>Configuración actual</h2>
        <dl className="settings-list">
          <div>
            <dt>Cuenta</dt>
            <dd>{session?.user.email}</dd>
          </div>
          <div>
            <dt>Moneda</dt>
            <dd>{settings!.currency}</dd>
          </div>
          <div>
            <dt>Zona horaria</dt>
            <dd>{settings!.timezone}</dd>
          </div>
        </dl>
      </section>
      <section className="card period-settings-link">
        <h2>Períodos y presupuestos</h2>
        <p>Consulta tu período actual, abre el siguiente y planifica tus gastos.</p>
        <Link className="button" to="/ajustes/periodos">Gestionar períodos y presupuestos</Link>
      </section>
      {message && (
        <p className="notice" role="status">
          {message}
        </p>
      )}
      <ErrorMessage message={error} />
      {error && <button onClick={reload}>Reintentar</button>}
      {loading ? (
        <Loading />
      ) : (
        data &&
        !error && (
          <div className="catalog-grid">
            <CatalogManager
              kind="category"
              items={data.categories}
              onMessage={setMessage}
            />
            <CatalogManager
              kind="payment_method"
              items={data.methods}
              onMessage={setMessage}
            />
          </div>
        )
      )}
    </>
  );
}
