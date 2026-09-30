import { registerSW } from "virtual:pwa-register";

let registration: ServiceWorkerRegistration | undefined;
let refreshAvailable = false;
let reloadRequested = false;
const listeners = new Set<() => void>();
function notifyUpdate() {
  refreshAvailable = true;
  listeners.forEach((listener) => listener());
}

// Un solo registro, fuera del ciclo de montaje de React/StrictMode.
const activateUpdate = import.meta.env.PROD
  ? registerSW({
      onRegisteredSW(_url, next) { registration = next; },
      onNeedRefresh: notifyUpdate,
      onNeedReload() {
        // Otra pestaña puede activar el worker: nunca recargar este formulario
        // si el usuario no ha pulsado Actualizar en esta misma ventana.
        if (reloadRequested) window.location.reload();
        else notifyUpdate();
      },
    })
  : undefined;

export function subscribeToUpdate(listener: () => void) {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}
export const hasUpdate = () => refreshAvailable;

let lastCheck = 0;
export async function checkForUpdate() {
  if (!registration || !navigator.onLine || document.visibilityState !== "visible") return;
  if (Date.now() - lastCheck < 60_000) return;
  lastCheck = Date.now();
  // onLine es una pista: un fallo real no debe interrumpir la aplicación.
  try { await registration.update(); } catch { /* Se comprobará más tarde. */ }
}

export async function applyUpdate() {
  reloadRequested = true;
  try {
    if (registration?.waiting) await activateUpdate?.();
    else window.location.reload();
  } catch (error) {
    reloadRequested = false;
    throw error;
  }
}
