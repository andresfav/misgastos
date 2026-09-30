import { useRef, useState, type FormEvent } from "react";
import { useSetup } from "../hooks/useSetup";

export function ResetFinancialData() {
  const { reset } = useSetup();
  const dialog = useRef<HTMLDialogElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const locked = useRef(false);
  const [confirmation, setConfirmation] = useState("");
  const [busy, setBusy] = useState(false);
  function confirm(event: FormEvent) {
    event.preventDefault();
    if (locked.current || confirmation !== "BORRAR") return;
    locked.current = true;
    setBusy(true);
    void reset(confirmation);
  }
  return (
    <section className="card reset-settings" id="datos">
      <h2>Datos / Empezar de cero</h2>
      <p>Borra todos tus datos financieros para volver a la configuración inicial. Tu cuenta y tu sesión se conservan.</p>
      <button ref={trigger} className="button-danger" onClick={() => { setConfirmation(""); dialog.current?.showModal(); }}>Empezar de cero</button>
      <dialog ref={dialog} className="reset-dialog card" aria-labelledby="reset-title" aria-describedby="reset-description" onCancel={(event) => { if (locked.current) event.preventDefault(); }} onClose={() => trigger.current?.focus()}>
        <h2 id="reset-title">¿Empezar de cero?</h2>
        <div id="reset-description">
          <p>Se eliminarán todos tus datos financieros:</p>
          <ul>
            <li>Movimientos: gastos, ingresos y transferencias.</li>
            <li>Períodos y presupuestos.</li>
            <li>Cuentas de ahorro.</li>
            <li>Categorías y métodos de pago.</li>
            <li>Configuración financiera.</li>
          </ul>
          <p>Conservarás tu cuenta, email, contraseña y sesión. Después volverás al inicio de la configuración.</p>
          <p className="danger-text"><strong>Esta acción no se puede deshacer.</strong></p>
        </div>
        <form onSubmit={confirm}>
          <fieldset disabled={busy}>
            <label>Escribe exactamente BORRAR para confirmar
              <input autoComplete="off" spellCheck={false} value={confirmation} onChange={(event) => setConfirmation(event.target.value)} />
            </label>
            <div className="form-actions">
              <button type="button" className="button-secondary" autoFocus onClick={() => dialog.current?.close()}>Cancelar</button>
              <button type="submit" className="button-danger" disabled={confirmation !== "BORRAR"}>{busy ? "Borrando…" : "Borrar todos los datos financieros"}</button>
            </div>
          </fieldset>
        </form>
      </dialog>
    </section>
  );
}
