import { createClient } from "@supabase/supabase-js";

const url = import.meta.env.VITE_SUPABASE_URL?.trim();
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY?.trim();
let validUrl = false;
try {
  validUrl = ["https:", "http:"].includes(new URL(url || "").protocol);
} catch {
  /* configuración pendiente */
}
export const configurationError =
  !validUrl || !key
    ? "Falta configurar Supabase. Copia .env.example a .env.local y completa VITE_SUPABASE_URL y VITE_SUPABASE_PUBLISHABLE_KEY. Después reinicia npm run dev."
    : null;
export const supabase = configurationError
  ? null
  : createClient(url!, key!, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
      },
    });
export function client() {
  if (!supabase) throw new Error("Supabase no está configurado");
  return supabase;
}
