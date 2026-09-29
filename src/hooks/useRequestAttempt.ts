import { useRef } from "react";
import { useAuth } from "./useAuth";

export function useRequestAttempt(scope: string) {
  const { session } = useAuth();
  const key = `misgastos:attempt:${session!.user.id}:${scope}`;
  const attempt = useRef<{ fingerprint: string; id: string } | null>(null);
  function requestId(parameters: Record<string, unknown>) {
    const fingerprint = JSON.stringify(parameters);
    if (!attempt.current) {
      try {
        const saved = JSON.parse(sessionStorage.getItem(key) || "null");
        if (
          typeof saved?.fingerprint === "string" &&
          typeof saved?.id === "string"
        )
          attempt.current = saved;
      } catch {
        /* almacenamiento opcional */
      }
    }
    if (attempt.current?.fingerprint !== fingerprint)
      attempt.current = { fingerprint, id: crypto.randomUUID() };
    try {
      sessionStorage.setItem(key, JSON.stringify(attempt.current));
    } catch {
      /* se conserva en memoria */
    }
    return attempt.current.id;
  }
  function clear() {
    attempt.current = null;
    try {
      sessionStorage.removeItem(key);
    } catch {
      /* almacenamiento opcional */
    }
  }
  return { requestId, clear };
}
