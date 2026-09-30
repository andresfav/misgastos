import { useState, type FormEvent } from "react";
import { useAuth } from "../hooks/useAuth";
import { useSubmit } from "../hooks/useSubmit";
import { client } from "../lib/supabase";
import { ErrorMessage } from "./Feedback";
import { LogoutButton } from "./Shell";

export function AccountSettings() {
  const { session } = useAuth();
  const [password, setPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [message, setMessage] = useState("");
  const { busy, error, setError, submit } = useSubmit();
  function save(event: FormEvent) {
    event.preventDefault();
    setMessage("");
    if (password.length < 8 || password !== confirmation) {
      setError("Usa al menos 8 caracteres y repite la misma contraseña.");
      return;
    }
    void submit(async () => {
      const { error: failure } = await client().auth.updateUser({ password });
      if (failure) throw failure;
      setPassword("");
      setConfirmation("");
      setMessage("Contraseña actualizada.");
    });
  }
  return (
    <section className="settings-content" aria-label="Datos de cuenta">
      <dl className="settings-list"><div><dt>Email</dt><dd>{session?.user.email}</dd></div></dl>
      <details className="settings-disclosure">
        <summary className="settings-row"><span>Cambiar contraseña</span><span className="settings-chevron" aria-hidden="true">⌄</span></summary>
        <form onSubmit={save}>
          <fieldset disabled={busy}>
            <label>Nueva contraseña
              <input type="password" required minLength={8} autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} />
              <small>Al menos 8 caracteres. Combina letras, números y símbolos.</small>
            </label>
            <label>Repite la contraseña
              <input type="password" required minLength={8} autoComplete="new-password" value={confirmation} onChange={(e) => setConfirmation(e.target.value)} />
            </label>
            <button type="submit">{busy ? "Guardando…" : "Guardar contraseña"}</button>
          </fieldset>
          <ErrorMessage message={error} />
          {message && <p className="notice success" role="status">{message}</p>}
        </form>
      </details>
      <div className="settings-logout"><LogoutButton /></div>
    </section>
  );
}
