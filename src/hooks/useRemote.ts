import { useCallback, useEffect, useState } from "react";
import { friendlyError } from "../lib/errors";
import { DATA_CHANGED } from "../lib/refresh";

// Cada pantalla lee al entrar; este evento actualiza también las ya montadas.
export function useRemote<T>(load: () => Promise<T>) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [revision, setRevision] = useState(0);
  const reload = useCallback(() => setRevision((value) => value + 1), []);
  useEffect(() => {
    window.addEventListener(DATA_CHANGED, reload);
    return () => window.removeEventListener(DATA_CHANGED, reload);
  }, [reload]);
  useEffect(() => {
    let active = true;
    setLoading(true);
    setError("");
    void load()
      .then((next) => {
        if (active) setData(next);
      })
      .catch((failure) => {
        if (active) setError(friendlyError(failure));
      })
      .finally(() => {
        if (active) setLoading(false);
      });
    return () => {
      active = false;
    };
  }, [load, revision]);
  return { data, error, loading, reload };
}
