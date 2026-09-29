import { useSetup } from "../hooks/useSetup";
import { useAuth } from "../hooks/useAuth";
const content = {
  movimientos: [
    "Movimientos",
    "Cada movimiento, en su sitio.",
    "Aquí podrás consultar tus gastos, ingresos y transferencias.",
  ],
  anadir: [
    "Añadir",
    "Anota lo que pasa con tu dinero.",
    "Aquí podrás registrar gastos, ingresos y transferencias.",
  ],
  ahorro: [
    "Ahorro",
    "Un espacio para tus objetivos.",
    "Aquí podrás crear y gestionar tus cuentas de ahorro.",
  ],
  ajustes: [
    "Ajustes",
    "Tu espacio, a tu manera.",
    "La edición de preferencias estará disponible en el próximo bloque.",
  ],
};
export function PlaceholderPage({ page }: { page: keyof typeof content }) {
  const { settings } = useSetup();
  const { session } = useAuth();
  const [title, heading, text] = content[page];
  return (
    <>
      <div className="page-heading">
        <div>
          <p className="eyebrow">MISGASTOS</p>
          <h1>{title}</h1>
        </div>
      </div>
      <section className="card empty">
        <span className="badge">Próximamente</span>
        <h2>{heading}</h2>
        <p>{text}</p>
        {page === "ajustes" && (
          <dl className="settings-list">
            <div>
              <dt>Cuenta</dt>
              <dd>{session?.user.email}</dd>
            </div>
            <div>
              <dt>Moneda</dt>
              <dd>{settings?.currency}</dd>
            </div>
            <div>
              <dt>Zona horaria</dt>
              <dd>{settings?.timezone}</dd>
            </div>
          </dl>
        )}
      </section>
    </>
  );
}
