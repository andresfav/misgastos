import { useRef, useState, type FormEvent } from "react";
import { Navigate, useNavigate } from "react-router-dom";
import { useSetup } from "../hooks/useSetup";
import { useAuth } from "../hooks/useAuth";
import { useSubmit } from "../hooks/useSubmit";
import { configureSettings, createFirstPeriod } from "../lib/finance";
import { todayIn, periodDates, formatDate } from "../lib/dates";
import { validateMoney } from "../lib/money";
import type { Currency, FirstPeriodInput, PeriodMode } from "../types/finance";
import { ErrorMessage } from "../components/Feedback";
import { LogoutButton } from "../components/Shell";

export function OnboardingPage() {
  const setup = useSetup();
  const { session } = useAuth();
  const navigate = useNavigate();
  const { busy, error, setError, submit } = useSubmit();
  const [currency, setCurrency] = useState<Currency>("EUR");
  const [timezone, setTimezone] = useState(
    () => Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC",
  );
  const [mode, setMode] = useState<PeriodMode>("monthly");
  const today = todayIn(
    setup.settings?.timezone ||
      Intl.DateTimeFormat().resolvedOptions().timeZone ||
      "UTC",
  );
  const [start, setStart] = useState(today);
  const [end, setEnd] = useState(today);
  const [balance, setBalance] = useState("");
  const [budget, setBudget] = useState("");
  const [done, setDone] = useState(false);
  const attempt = useRef<{ fingerprint: string; id: string } | null>(null);
  const storageKey = `misgastos:first-period:${session!.user.id}`;
  if (setup.hasPeriods && !done) return <Navigate to="/" replace />;
  const step = done ? 3 : setup.settings ? 2 : 1;
  const configure = (event: FormEvent) => {
    event.preventDefault();
    try {
      new Intl.DateTimeFormat("es", { timeZone: timezone.trim() }).format();
    } catch {
      setError(
        "Introduce una zona horaria válida, por ejemplo Europe/Madrid o America/Asuncion.",
      );
      return;
    }
    void submit(async () => {
      await configureSettings(currency, timezone.trim());
      await setup.reload();
    });
  };
  const create = (event: FormEvent) => {
    event.preventDefault();
    let input: FirstPeriodInput;
    try {
      input = {
        p_mode: mode,
        ...periodDates(mode, todayIn(setup.settings!.timezone), start, end),
        p_opening_balance: validateMoney(balance, { negative: true })!,
        p_general_budget: validateMoney(budget, { optional: true }),
      };
    } catch (failure) {
      setError((failure as Error).message);
      return;
    }
    void submit(async () => {
      const fingerprint = JSON.stringify(input);
      // Persistir solo la identidad del intento permite reintentar tras recargar.
      // Nunca se usa este dato local para decidir si existe configuración/historial.
      if (!attempt.current) {
        try {
          const saved = JSON.parse(
            sessionStorage.getItem(storageKey) || "null",
          );
          if (
            typeof saved?.fingerprint === "string" &&
            typeof saved?.id === "string"
          )
            attempt.current = saved;
        } catch {
          /* sessionStorage puede estar deshabilitado */
        }
      }
      if (attempt.current?.fingerprint !== fingerprint)
        attempt.current = { fingerprint, id: crypto.randomUUID() };
      try {
        sessionStorage.setItem(storageKey, JSON.stringify(attempt.current));
      } catch {
        /* se mantiene en memoria */
      }
      await createFirstPeriod(input, attempt.current.id);
      try {
        sessionStorage.removeItem(storageKey);
      } catch {
        /* opcional */
      }
      setDone(true);
    });
  };
  const finish = () =>
    void submit(async () => {
      await setup.reload();
      navigate("/", { replace: true });
    });
  return (
    <div className="onboarding-layout">
      <header className="app-header">
        <span className="brand">
          <span className="brand-mark">M</span>MisGastos
        </span>
        <LogoutButton />
      </header>
      <main className="onboarding card">
        <ol className="steps" aria-label="Progreso">
          {["Configuración", "Primer período", "Listo"].map((title, i) => (
            <li
              key={title}
              className={
                step === i + 1 ? "current" : step > i + 1 ? "complete" : ""
              }
              aria-current={step === i + 1 ? "step" : undefined}
            >
              <span>{i + 1}</span>
              {title}
            </li>
          ))}
        </ol>
        <ErrorMessage message={error} />
        {step === 1 && (
          <>
            <p className="eyebrow">PASO 1 DE 3</p>
            <h1>Hagámoslo tuyo.</h1>
            <p>
              Confirma la moneda y la zona horaria con las que vas a llevar tus
              finanzas.
            </p>
            <form onSubmit={configure}>
              <fieldset disabled={busy}>
                <label>
                  Moneda
                  <select
                    value={currency}
                    onChange={(e) => setCurrency(e.target.value as Currency)}
                  >
                    <option value="EUR">EUR · Euro</option>
                    <option value="USD">USD · Dólar estadounidense</option>
                    <option value="PYG">PYG · Guaraní paraguayo</option>
                  </select>
                  <small>
                    Al iniciar tu historial, la moneda quedará fijada.
                  </small>
                </label>
                <label>
                  Zona horaria
                  <input
                    required
                    value={timezone}
                    onChange={(e) => setTimezone(e.target.value)}
                    list="timezones"
                    autoComplete="off"
                  />
                  <small>
                    Detectada automáticamente. Puedes cambiarla si lo necesitas.
                  </small>
                </label>
                <datalist id="timezones">
                  <option value="Europe/Madrid" />
                  <option value="America/Asuncion" />
                  <option value="America/New_York" />
                  <option value="UTC" />
                </datalist>
                <button type="submit">
                  {busy ? "Guardando…" : "Continuar"}
                </button>
              </fieldset>
            </form>
          </>
        )}
        {step === 2 && (
          <>
            <p className="eyebrow">PASO 2 DE 3 · {setup.settings!.currency}</p>
            <h1>Tu punto de partida.</h1>
            <p>
              Elige cómo organizar tu dinero y confirma cuánto tienes
              disponible.
            </p>
            <form onSubmit={create}>
              <fieldset disabled={busy}>
                <label>
                  Tipo de período
                  <select
                    value={mode}
                    onChange={(e) => setMode(e.target.value as PeriodMode)}
                  >
                    <option value="monthly">Mensual</option>
                    <option value="annual">Anual</option>
                    <option value="custom">Personalizado</option>
                    <option value="between_paydays">Entre nóminas</option>
                  </select>
                </label>
                {["monthly", "annual"].includes(mode) ? (
                  <p className="notice">
                    {mode === "monthly"
                      ? "Mes natural actual"
                      : "Año natural actual"}
                    :{" "}
                    {formatDate(
                      periodDates(mode, today, start, end).p_start_date,
                    )}{" "}
                    —{" "}
                    {formatDate(
                      periodDates(mode, today, start, end).p_end_date!,
                    )}
                    .
                  </p>
                ) : (
                  <div className="form-row">
                    <label>
                      Fecha inicial
                      <input
                        type="date"
                        required
                        max={today}
                        value={start}
                        onChange={(e) => setStart(e.target.value)}
                      />
                    </label>
                    {mode === "custom" && (
                      <label>
                        Fecha final
                        <input
                          type="date"
                          required
                          min={today}
                          value={end}
                          onChange={(e) => setEnd(e.target.value)}
                        />
                      </label>
                    )}
                  </div>
                )}
                {mode === "between_paydays" && (
                  <p className="muted">
                    El primer período queda sin fecha final. Se cerrará cuando
                    empieces el siguiente.
                  </p>
                )}
                <label>
                  Saldo disponible inicial ({setup.settings!.currency})
                  <input
                    inputMode="decimal"
                    required
                    value={balance}
                    onChange={(e) => setBalance(e.target.value)}
                    placeholder="0,00"
                  />
                  <small>
                    Solo el dinero disponible para gastar. Puede ser 0 o
                    negativo; no incluyas el ahorro.
                  </small>
                </label>
                <label>
                  Presupuesto general ({setup.settings!.currency}){" "}
                  <span className="optional">Opcional</span>
                  <input
                    inputMode="decimal"
                    value={budget}
                    onChange={(e) => setBudget(e.target.value)}
                    placeholder="Sin presupuesto"
                  />
                  <small>
                    Un límite para orientarte. No modifica tu saldo.
                  </small>
                </label>
                <button type="submit">
                  {busy ? "Creando período…" : "Confirmar y crear período"}
                </button>
              </fieldset>
            </form>
            <button
              className="button-quiet"
              disabled={busy}
              onClick={() => void setup.reload()}
            >
              Comprobar si el período ya se creó
            </button>
          </>
        )}
        {step === 3 && (
          <div className="completion">
            <span className="completion-mark" aria-hidden="true">
              ✓
            </span>
            <p className="eyebrow">TODO PREPARADO</p>
            <h1>Ya tienes un comienzo.</h1>
            <p>
              Tu primer período está creado. Más adelante podrás añadir tus
              cuentas de ahorro.
            </p>
            <button disabled={busy} onClick={finish}>
              {busy ? "Entrando…" : "Ir a Inicio"}
            </button>
          </div>
        )}
      </main>
    </div>
  );
}
