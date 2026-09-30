import { useState } from "react";
import { Link } from "react-router-dom";
import { useRemote } from "../hooks/useRemote";
import { readReferences } from "../lib/movements";
import { CatalogManager } from "../components/CatalogManager";
import { ErrorMessage, Loading } from "../components/Feedback";
import { AccountSettings } from "../components/AccountSettings";
import { PreferencesSettings } from "../components/PreferencesSettings";
import { ResetFinancialData } from "../components/ResetFinancialData";

export function SettingsPage() {
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
      <div className="settings-sections">
        <AccountSettings />
        <PreferencesSettings />
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
        <section className="card" id="periodos">
          <h2>Períodos y presupuestos</h2>
          <p>Consulta tu período actual, abre el siguiente y planifica tus gastos.</p>
          <Link className="button" to="/ajustes/periodos">Gestionar períodos y presupuestos</Link>
        </section>
        <ResetFinancialData />
      </div>
    </>
  );
}
