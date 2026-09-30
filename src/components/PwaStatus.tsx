import { useEffect, useState, useSyncExternalStore } from "react";
import { applyUpdate, checkForUpdate, hasUpdate, subscribeToUpdate } from "../lib/pwa";

export function PwaStatus() {
  const [online, setOnline] = useState(navigator.onLine);
  const [error, setError] = useState("");
  const updateAvailable = useSyncExternalStore(subscribeToUpdate, hasUpdate);
  useEffect(() => {
    const connectionChanged = () => {
      setOnline(navigator.onLine);
      void checkForUpdate();
    };
    const check = () => { void checkForUpdate(); };
    window.addEventListener("online", connectionChanged);
    window.addEventListener("offline", connectionChanged);
    document.addEventListener("visibilitychange", check);
    const interval = window.setInterval(check, 60 * 60 * 1000);
    return () => {
      window.removeEventListener("online", connectionChanged);
      window.removeEventListener("offline", connectionChanged);
      document.removeEventListener("visibilitychange", check);
      window.clearInterval(interval);
    };
  }, []);

  return (
    <aside className="pwa-status" aria-label="Estado de la aplicación">
      <div role="status" aria-live="polite" aria-atomic="true">
        {!online && <p><strong>Sin conexión.</strong> Necesitas conexión a Internet para consultar o modificar tus datos.</p>}
        {updateAvailable && <p><strong>Nueva versión disponible.</strong> Guarda tus cambios antes de actualizar.</p>}
      </div>
      {updateAvailable && <button type="button" onClick={() => {
        setError("");
        void applyUpdate().catch(() => setError("No se pudo actualizar. Vuelve a intentarlo."));
      }}>Actualizar</button>}
      {error && <p role="alert">{error}</p>}
    </aside>
  );
}
