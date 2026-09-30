import { lazy, Suspense } from "react";
import { Navigate, Outlet, Route, Routes, useLocation } from "react-router-dom";
import { AuthProvider, useAuth } from "./hooks/useAuth";
import { SetupProvider, useSetup } from "./hooks/useSetup";
import { configurationError } from "./lib/supabase";
import { ErrorMessage, Loading } from "./components/Feedback";
import { LogoutButton, Shell } from "./components/Shell";
import { AuthPage } from "./pages/AuthPage";
import { HomePage } from "./pages/HomePage";
const SavingsPage = lazy(() =>
  import("./pages/SavingsPage").then((module) => ({ default: module.SavingsPage })),
);

const AddPage = lazy(() =>
  import("./pages/AddPage").then((module) => ({ default: module.AddPage })),
);
const MovementsPage = lazy(() =>
  import("./pages/MovementsPage").then((module) => ({
    default: module.MovementsPage,
  })),
);
const SettingsPage = lazy(() =>
  import("./pages/SettingsPage").then((module) => ({
    default: module.SettingsPage,
  })),
);

const OnboardingPage = lazy(() =>
  import("./pages/OnboardingPage").then((module) => ({
    default: module.OnboardingPage,
  })),
);

function PrivateRoutes() {
  const { session, loading } = useAuth();
  if (loading) return <Loading text="Comprobando sesión…" />;
  if (!session) return <Navigate to="/auth/login" replace />;
  return (
    <SetupProvider key={session.user.id}>
      <SetupGate />
    </SetupProvider>
  );
}
function SetupGate() {
  const setup = useSetup();
  if (setup.loading) return <Loading />;
  if (setup.error)
    return (
      <main className="standalone card">
        <h1>No pudimos cargar tus datos</h1>
        <ErrorMessage message={setup.error} />
        <button onClick={() => void setup.reload()}>Reintentar</button>
        <LogoutButton />
      </main>
    );
  return <Outlet />;
}
function ReadyRoutes() {
  const { settings, hasPeriods } = useSetup();
  return settings && hasPeriods ? (
    <Shell />
  ) : (
    <Navigate to="/onboarding" replace />
  );
}
function AppRoutes() {
  const { recovery } = useAuth();
  const location = useLocation();
  if (recovery && location.pathname !== "/auth/nueva-contrasena")
    return <Navigate to="/auth/nueva-contrasena" replace />;
  return (
    <Routes>
      <Route
        path="/auth/login"
        element={<AuthPage key="login" mode="login" />}
      />
      <Route
        path="/auth/registro"
        element={<AuthPage key="register" mode="register" />}
      />
      <Route
        path="/auth/recuperar"
        element={<AuthPage key="forgot" mode="forgot" />}
      />
      <Route
        path="/auth/nueva-contrasena"
        element={<AuthPage key="reset" mode="reset" />}
      />
      <Route element={<PrivateRoutes />}>
        <Route path="/onboarding" element={<OnboardingPage />} />
        <Route element={<ReadyRoutes />}>
          <Route index element={<HomePage />} />
          <Route path="/movimientos" element={<MovementsPage />} />
          <Route path="/anadir" element={<AddPage />} />
          <Route path="/ahorro" element={<SavingsPage />} />
          <Route path="/ajustes" element={<SettingsPage />} />
        </Route>
      </Route>
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
export default function App() {
  if (configurationError)
    return (
      <main className="standalone card">
        <h1>Configura MisGastos</h1>
        <p role="alert">
          {import.meta.env.DEV
            ? configurationError
            : "La aplicación no está configurada. Contacta con quien administra MisGastos."}
        </p>
      </main>
    );
  return (
    <AuthProvider>
      <Suspense fallback={<Loading />}>
        <AppRoutes />
      </Suspense>
    </AuthProvider>
  );
}
