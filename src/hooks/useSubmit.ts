import { useRef, useState } from "react";
import { friendlyError } from "../lib/errors";
export function useSubmit(
  errorMessage: (error: unknown) => string = friendlyError,
) {
  const locked = useRef(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function submit(action: () => Promise<void>) {
    if (locked.current) return;
    locked.current = true;
    setBusy(true);
    setError("");
    try {
      await action();
    } catch (failure) {
      setError(errorMessage(failure));
    } finally {
      locked.current = false;
      setBusy(false);
    }
  }
  return { busy, error, setError, submit };
}
