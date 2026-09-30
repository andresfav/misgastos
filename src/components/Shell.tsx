import { NavLink, Outlet } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { useSubmit } from "../hooks/useSubmit";
import { ErrorMessage } from "./Feedback";
import { NavIcon } from "./NavIcon";
const links = [
  ["/", "Inicio"],
  ["/movimientos", "Movimientos"],
  ["/anadir", "Añadir"],
  ["/ahorro", "Ahorro"],
  ["/ajustes", "Ajustes"],
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
      </header>
      <nav className="navigation" aria-label="Navegación principal">
        {links.map(([to, title]) => (
          <NavLink key={to} to={to} end={to === "/"}
            className={({ isActive }) => [isActive ? "active" : "", to === "/anadir" ? "nav-add" : ""].join(" ")}>
            <span className="nav-icon"><NavIcon name={to} /></span>
            {title}
          </NavLink>
        ))}
      </nav>
      <main id="main" className="main-content" tabIndex={-1}>
        <Outlet />
      </main>
    </div>
  );
}
