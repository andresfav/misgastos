import { useState, type FormEvent } from "react";
import { useSetup } from "../hooks/useSetup";
import { useSubmit } from "../hooks/useSubmit";
import { updateTimezone } from "../lib/finance";
import { friendlyError } from "../lib/errors";
import { refreshFinancialData } from "../lib/refresh";
import { ErrorMessage } from "./Feedback";

export function PreferencesSettings() {
  const { settings, replaceSettings, reload } = useSetup();
  const [timezone, setTimezone] = useState(settings!.timezone);
  const [message, setMessage] = useState("");
  const { busy, error, setError, submit } = useSubmit((failure) =>
    (failure as { code?: string })?.code === "22023"
      ? "No se pudo guardar. Revisa la zona horaria; la moneda se mantiene sin cambios."
      : friendlyError(failure),
  );
  function save(event: FormEvent) {
    event.preventDefault();
    setMessage("");
    if (!timezone.trim()) { setError("Introduce una zona horaria."); return; }
    void submit(async () => {
      const next = await updateTimezone(settings!, timezone.trim());
      replaceSettings(next);
      setTimezone(next.timezone);
      refreshFinancialData();
      setMessage("Zona horaria guardada.");
    });
  }
  return (
    <section className="settings-content" aria-label="Preferencias financieras">
      <dl className="settings-list">
        <div><dt>Moneda</dt><dd>{settings!.currency}</dd></div>
      </dl>
      <p className="muted">{settings!.currency_locked_at
        ? "La moneda queda fijada mientras exista historial financiero."
        : "La moneda se muestra en modo de solo lectura. Podrás elegirla de nuevo después de Empezar de cero."}</p>
      <details className="settings-disclosure">
        <summary className="settings-row"><span><strong>Zona horaria</strong><small>{settings!.timezone}</small></span><span className="settings-chevron" aria-hidden="true">⌄</span></summary>
      <form onSubmit={save}>
        <fieldset disabled={busy}>
          <label>Zona horaria
            <input required value={timezone} onChange={(e) => setTimezone(e.target.value)} autoCapitalize="none" spellCheck={false} aria-describedby="timezone-help" />
            <small id="timezone-help">Por ejemplo, Europe/Madrid o America/Asuncion. Se usa para determinar el día actual.</small>
          </label>
          <button type="submit" disabled={timezone.trim() === settings!.timezone}>{busy ? "Guardando…" : "Guardar zona horaria"}</button>
        </fieldset>
        <ErrorMessage message={error} />
        {error && <button type="button" className="button-secondary" disabled={busy} onClick={() => void reload()}>Consultar configuración actual</button>}
        {message && <p className="notice success" role="status">{message}</p>}
      </form>
      </details>
    </section>
  );
}
