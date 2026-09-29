import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { readSetup } from "../lib/finance";
import { friendlyError } from "../lib/errors";
import type { Settings } from "../types/finance";
import { useAuth } from "./useAuth";

type Setup = { settings: Settings | null; hasPeriods: boolean };
type SetupValue = Setup & {
  loading: boolean;
  error: string;
  reload: () => Promise<void>;
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
  const reload = useCallback(async () => {
    const current = ++generation.current;
    setLoading(true);
    setError("");
    try {
      const next = await readSetup(userId);
      if (current === generation.current) setData(next);
    } catch (failure) {
      if (current === generation.current) setError(friendlyError(failure));
    } finally {
      if (current === generation.current) setLoading(false);
    }
  }, [userId]);
  useEffect(() => {
    void reload();
    return () => {
      generation.current++;
    };
  }, [reload]);
  return (
    <SetupContext.Provider value={{ ...data, loading, error, reload }}>
      {children}
    </SetupContext.Provider>
  );
}
export function useSetup() {
  const value = useContext(SetupContext);
  if (!value) throw new Error("SetupProvider requerido");
  return value;
}
