import {
  createContext,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import type { Session } from "@supabase/supabase-js";
import { client } from "../lib/supabase";
import { friendlyError } from "../lib/errors";

type AuthValue = {
  session: Session | null;
  loading: boolean;
  error: string;
  expired: boolean;
  recovery: boolean;
  finishRecovery: () => void;
  logout: () => Promise<void>;
};
const AuthContext = createContext<AuthValue | null>(null);
export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [expired, setExpired] = useState(false);
  const [recovery, setRecovery] = useState(false);
  const intentionalLogout = useRef(false);
  const hadSession = useRef(false);
  useEffect(() => {
    let active = true;
    let eventReceived = false;
    const apply = (next: Session | null) => {
      if (!active) return;
      if (!next && hadSession.current && !intentionalLogout.current)
        setExpired(true);
      if (next) {
        setExpired(false);
        setError("");
      }
      hadSession.current = Boolean(next);
      setSession(next);
      setLoading(false);
    };
    const {
      data: { subscription },
    } = client().auth.onAuthStateChange((event, next) => {
      if (!active) return;
      eventReceived = true;
      if (event === "PASSWORD_RECOVERY") setRecovery(true);
      if (event === "SIGNED_OUT") {
        setRecovery(false);
        if (!intentionalLogout.current) setExpired(true);
      }
      apply(next);
    });
    void client()
      .auth.getSession()
      .then(({ data, error: failure }) => {
        if (!active || eventReceived) return;
        if (failure) setError(friendlyError(failure));
        apply(data.session);
      })
      .catch((failure) => {
        if (active) {
          setError(friendlyError(failure));
          setLoading(false);
        }
      });
    const expire = () => {
      setExpired(true);
      setSession(null);
      setRecovery(false);
      void client().auth.signOut({ scope: "local" }).catch((failure) => {
        if (import.meta.env.DEV) console.error("[MisGastos]", failure);
      });
    };
    window.addEventListener("misgastos:session-expired", expire);
    return () => {
      active = false;
      subscription.unsubscribe();
      window.removeEventListener("misgastos:session-expired", expire);
    };
  }, []);
  const logout = async () => {
    intentionalLogout.current = true;
    try {
      const { error } = await client().auth.signOut({ scope: "local" });
      if (error) throw error;
      setSession(null);
      setExpired(false);
    } finally {
      intentionalLogout.current = false;
    }
  };
  return (
    <AuthContext.Provider
      value={{
        session,
        loading,
        error,
        expired,
        recovery,
        finishRecovery: () => setRecovery(false),
        logout,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
}
export function useAuth() {
  const auth = useContext(AuthContext);
  if (!auth) throw new Error("AuthProvider requerido");
  return auth;
}
