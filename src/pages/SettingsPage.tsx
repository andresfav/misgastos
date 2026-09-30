import { useEffect, useRef, useState, type ReactNode } from "react";
import { Link, Navigate, useParams } from "react-router-dom";
import { useRemote } from "../hooks/useRemote";
import { readReferences } from "../lib/movements";
import { CatalogManager } from "../components/CatalogManager";
import { ErrorMessage, Loading } from "../components/Feedback";
import { AccountSettings } from "../components/AccountSettings";
import { PreferencesSettings } from "../components/PreferencesSettings";
import { ResetFinancialData } from "../components/ResetFinancialData";
import { AppSignature } from "../components/AppSignature";
import type { CatalogKind } from "../types/movements";

const sections = [
  ["cuenta", "Cuenta", "Email, contraseña y sesión"],
  ["preferencias", "Preferencias", "Moneda y zona horaria"],
  ["categorias", "Categorías", "Organiza tus tipos de gasto"],
  ["metodos", "Métodos de pago", "Tarjetas, efectivo, etc."],
  ["periodos", "Períodos y presupuestos", "Período actual y planificación"],
  ["datos", "Datos", "Empezar de cero"],
];

function SettingsView({ title, children }: { title: string; children: ReactNode }) {
  const heading = useRef<HTMLHeadingElement>(null);
  useEffect(() => {
    heading.current?.focus();
    window.scrollTo(0, 0);
  }, [title]);
  return <div className="settings-page">
    <Link className="settings-back" to="/ajustes">← Ajustes</Link>
    <h1 ref={heading} tabIndex={-1}>{title}</h1>
    {children}
  </div>;
}

function CatalogSettings({ kind }: { kind: CatalogKind }) {
  const { data, error, loading, reload } = useRemote(readReferences);
  const [message, setMessage] = useState("");
  return <>
    {message && <p className="notice success" role="status">{message}</p>}
    <ErrorMessage message={error} />
    {error && <button onClick={reload} disabled={loading}>Reintentar</button>}
    {loading && !data && <Loading />}
    {data && <CatalogManager kind={kind} items={kind === "category" ? data.categories : data.methods} onMessage={setMessage} />}
  </>;
}

export function SettingsPage() {
  const { section } = useParams();
  const indexHeading = useRef<HTMLHeadingElement>(null);
  useEffect(() => {
    if (!section) {
      indexHeading.current?.focus();
      window.scrollTo(0, 0);
    }
  }, [section]);
  if (!section) return <div className="settings-page">
    <div className="page-heading"><h1 ref={indexHeading} tabIndex={-1}>Ajustes</h1></div>
    <nav aria-label="Secciones de ajustes" className="settings-index">
      {sections.map(([path, title, description]) => <Link key={path} to={`/ajustes/${path}`} className="settings-row">
        <span><strong>{title}</strong><small>{description}</small></span>
        <span className="settings-chevron" aria-hidden="true">›</span>
      </Link>)}
    </nav>
    <AppSignature showAppInfo />
  </div>;
  const title = sections.find(([path]) => path === section)?.[1];
  if (!title) return <Navigate to="/ajustes" replace />;
  return <SettingsView title={title} key={section}>
    {section === "cuenta" && <AccountSettings />}
    {section === "preferencias" && <PreferencesSettings />}
    {section === "categorias" && <CatalogSettings kind="category" />}
    {section === "metodos" && <CatalogSettings kind="payment_method" />}
    {section === "datos" && <ResetFinancialData />}
  </SettingsView>;
}
