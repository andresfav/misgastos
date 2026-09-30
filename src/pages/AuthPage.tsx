import { useState, type FormEvent } from "react";
import { Link, Navigate } from "react-router-dom";
import { client } from "../lib/supabase";
import { useAuth } from "../hooks/useAuth";
import { useSubmit } from "../hooks/useSubmit";
import { ErrorMessage, Loading } from "../components/Feedback";
import { AppSignature } from "../components/AppSignature";

type Mode = "login" | "register" | "forgot" | "reset";
const titles: Record<Mode, string> = {
  login: "Bienvenido a casa.",
  register: "Empieza con claridad.",
  forgot: "Recupera el acceso.",
  reset: "Tu nueva contraseña.",
};
export function AuthPage({ mode }: { mode: Mode }) {
  const {
    session,
    loading,
    expired,
    error: authError,
    finishRecovery,
  } = useAuth();
  const { busy, error, setError, submit } = useSubmit();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [message, setMessage] = useState("");
  const [done, setDone] = useState(false);
  const callbackError =
    new URLSearchParams(window.location.hash.slice(1)).has("error") ||
    new URLSearchParams(window.location.search).has("error");
  if (loading) return <Loading text="Comprobando sesión…" />;
  if (done || (session && ["login", "register"].includes(mode)))
    return <Navigate to="/" replace />;
  const onSubmit = (event: FormEvent) => {
    event.preventDefault();
    setMessage("");
    if (
      (mode === "register" || mode === "reset") &&
      password !== confirmation
    ) {
      setError("Las contraseñas no coinciden.");
      return;
    }
    void submit(async () => {
      if (mode === "login") {
        const { error } = await client().auth.signInWithPassword({
          email: email.trim(),
          password,
        });
        if (error) throw error;
      } else if (mode === "register") {
        const { data, error } = await client().auth.signUp({
          email: email.trim(),
          password,
          options: { emailRedirectTo: `${window.location.origin}/` },
        });
        if (error) throw error;
        if (!data.session)
          setMessage(
            "Revisa tu correo para confirmar la cuenta. Después podrás iniciar sesión.",
          );
      } else if (mode === "forgot") {
        const { error } = await client().auth.resetPasswordForEmail(
          email.trim(),
          { redirectTo: `${window.location.origin}/auth/nueva-contrasena` },
        );
        if (error) throw error;
        setMessage(
          "Si existe una cuenta con ese email, recibirás un enlace para restablecer tu contraseña.",
        );
      } else {
        const { error } = await client().auth.updateUser({ password });
        if (error) throw error;
        finishRecovery();
        setDone(true);
      }
    });
  };
  return (
    <>
    <main className="auth-layout">
      <section className="auth-intro">
        <Link className="brand" to="/">
          <span className="brand-mark">M</span>MisGastos
        </Link>
        <h1>
          Tu dinero,
          <br />
          con claridad.
        </h1>
        <p>
          Un lugar para entender lo que tienes, lo que gastas y lo que ahorras.
        </p>
        <span className="intro-note">A tu ritmo. Desde el primer día.</span>
      </section>
      <section className="card auth-card">
        <p className="eyebrow">
          {mode === "register" ? "CREA TU CUENTA" : "TU ESPACIO PERSONAL"}
        </p>
        <h2>{titles[mode]}</h2>
        {expired && (
          <p className="notice" role="status">
            Tu sesión ha caducado. Inicia sesión para continuar.
          </p>
        )}
        <ErrorMessage
          message={
            error ||
            authError ||
            (callbackError
              ? "El enlace no es válido o ha caducado. Solicita uno nuevo."
              : "")
          }
        />
        {message && (
          <p className="notice success" role="status">
            {message}
          </p>
        )}
        {mode === "reset" && (!session || callbackError) ? (
          <>
            <p>
              Abre el enlace de recuperación que te enviamos por email. Si ha
              caducado, solicita otro.
            </p>
            <Link className="button" to="/auth/recuperar">
              Solicitar un enlace
            </Link>
          </>
        ) : (
          <form onSubmit={onSubmit}>
            <fieldset disabled={busy}>
              {mode !== "reset" && (
                <label>
                  Email
                  <input
                    type="email"
                    autoComplete="email"
                    required
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    placeholder="tu@email.com"
                  />
                </label>
              )}
              {mode !== "forgot" && (
                <label>
                  {mode === "reset" ? "Nueva contraseña" : "Contraseña"}
                  <input
                    type="password"
                    autoComplete={
                      mode === "login" ? "current-password" : "new-password"
                    }
                    minLength={mode === "login" ? undefined : 8}
                    required
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                  />
                  {mode !== "login" && (
                    <small>
                      Al menos 8 caracteres. Combina letras, números y símbolos.
                    </small>
                  )}
                </label>
              )}
              {["register", "reset"].includes(mode) && (
                <label>
                  Repite la contraseña
                  <input
                    type="password"
                    autoComplete="new-password"
                    minLength={8}
                    required
                    value={confirmation}
                    onChange={(e) => setConfirmation(e.target.value)}
                  />
                </label>
              )}
              <button type="submit">
                {busy
                  ? "Un momento…"
                  : {
                      login: "Entrar",
                      register: "Crear cuenta",
                      forgot: "Enviar enlace",
                      reset: "Guardar contraseña",
                    }[mode]}
              </button>
            </fieldset>
          </form>
        )}
        <div className="auth-links">
          {mode === "login" ? (
            <>
              <Link to="/auth/recuperar">He olvidado mi contraseña</Link>
              <p>
                ¿Primera vez aquí?{" "}
                <Link to="/auth/registro">Crea tu cuenta</Link>
              </p>
            </>
          ) : (
            <Link to="/auth/login">Volver a iniciar sesión</Link>
          )}
        </div>
      </section>
    </main>
    {(mode === "login" || mode === "register") && <AppSignature />}
    </>
  );
}
