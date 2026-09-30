import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { readSetup, resetFinancialData } from "../lib/finance";
import { friendlyError } from "../lib/errors";
import type { Settings } from "../types/finance";
import { useAuth } from "./useAuth";

type Setup = { settings: Settings | null; hasPeriods: boolean };
type SetupValue = Setup & {
  loading: boolean;
  error: string;
  reload: () => Promise<void>;
  reset: (confirmation: string) => Promise<void>;
  resetting: boolean;
  replaceSettings: (settings: Settings) => void;
};
const SetupContext = createContext<SetupValue | null>(null);
export function SetupProvider({ children }: { children: ReactNode }) {
  const { session } = useAuth();
  const userId = session!.user.id;
  const [data, setData] = useState<Setup>({
    settings: null,
    hasPeriods: false,
  });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const generation = useRef(0);
  const resetLock = useRef(false);
  const [resetting, setResetting] = useState(false);
  const clearFinancialAttempts = useCallback(() => {
    try {
      const prefix = `misgastos:attempt:${userId}:`;
      Object.keys(sessionStorage).forEach((key) => {
        if (key.startsWith(prefix) || key === `misgastos:first-period:${userId}`)
          sessionStorage.removeItem(key);
      });
    } catch {
      // El almacenamiento local es opcional; el backend decide el onboarding.
    }
  }, [userId]);
  const reload = useCallback(async () => {
    if (resetLock.current) return;
    const current = ++generation.current;
    setLoading(true);
    setError("");
    try {
      const next = await readSetup(userId);
      if (current === generation.current) {
        if (!next.settings) clearFinancialAttempts();
        setData(next);
      }
    } catch (failure) {
      if (current === generation.current) setError(friendlyError(failure));
    } finally {
      if (current === generation.current) setLoading(false);
    }
  }, [userId, clearFinancialAttempts]);
  const reset = useCallback(async (confirmation: string) => {
    if (resetLock.current || confirmation !== "BORRAR") return;
    resetLock.current = true;
    const current = ++generation.current;
    setResetting(true);
    setLoading(true);
    setError("");
    // SetupGate desmonta todas las pantallas y sus datos locales inmediatamente.
    setData({ settings: null, hasPeriods: false });
    let confirmed = false;
    try {
      await resetFinancialData(confirmation);
      confirmed = true;
    } catch {
      // Incluso ante una respuesta perdida se consulta antes de permitir repetir.
    }
    try {
      const next = await readSetup(userId);
      if (current !== generation.current) return;
      if (!next.settings) clearFinancialAttempts();
      setData(next);
      if (next.settings) {
        setError(confirmed
          ? "Existe configuración financiera en el servidor. Pulsa Reintentar para cargar su estado actual antes de continuar."
          : "No se ha confirmado el borrado y tu configuración sigue existiendo. Pulsa Reintentar para cargar los datos actuales antes de decidir si vuelves a empezar de cero.");
      }
    } catch {
      if (current === generation.current) setError(
        "No pudimos comprobar el estado de tus datos tras solicitar el borrado. Comprueba la conexión y pulsa Reintentar: solo consultaremos el estado, sin repetir el borrado.",
      );
    } finally {
      resetLock.current = false;
      if (current === generation.current) {
        setResetting(false);
        setLoading(false);
      }
    }
  }, [userId, clearFinancialAttempts]);
  useEffect(() => {
    void reload();
    return () => {
      generation.current++;
    };
  }, [reload]);
  return (
    <SetupContext.Provider value={{ ...data, loading, error, reload, reset, resetting,
      replaceSettings: (settings) => setData((previous) => ({ ...previous, settings })),
    }}>
      {children}
    </SetupContext.Provider>
  );
}
export function useSetup() {
  const value = useContext(SetupContext);
  if (!value) throw new Error("SetupProvider requerido");
  return value;
}
