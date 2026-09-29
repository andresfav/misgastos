import { NavLink, Outlet } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { useSubmit } from "../hooks/useSubmit";
import { ErrorMessage } from "./Feedback";
const links = [
  ["/", "Inicio", "⌂"],
  ["/movimientos", "Movimientos", "↔"],
  ["/anadir", "Añadir", "+"],
  ["/ahorro", "Ahorro", "◇"],
  ["/ajustes", "Ajustes", "⚙"],
];
export function LogoutButton() {
  const { logout } = useAuth();
  const { busy, error, submit } = useSubmit();
  return (
    <div>
      <button
        className="button-quiet"
        disabled={busy}
        onClick={() => void submit(logout)}
      >
        {busy ? "Saliendo…" : "Cerrar sesión"}
      </button>
      <ErrorMessage message={error} />
    </div>
  );
}
export function Shell() {
  return (
    <div className="app-shell">
      <a className="skip-link" href="#main">
        Ir al contenido
      </a>
      <header className="app-header">
        <NavLink className="brand" to="/">
          <span className="brand-mark">M</span>MisGastos
        </NavLink>
        <LogoutButton />
      </header>
      <nav className="navigation" aria-label="Navegación principal">
        {links.map(([to, title, symbol]) => (
          <NavLink key={to} to={to} end={to === "/"}>
            <span aria-hidden="true">{symbol}</span>
            {title}
          </NavLink>
        ))}
      </nav>
      <main id="main" className="main-content">
        <Outlet />
      </main>
    </div>
  );
}
