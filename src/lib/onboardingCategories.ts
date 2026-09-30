import { client } from "./supabase";
import { mutateCatalog } from "./movements";

const initialCategories = ["Alimentación", "Hogar", "Transporte", "Salud", "Ocio"];

export async function createInitialCategories() {
  // Incluye inactivas: un catálogo existente nunca se completa ni se restaura.
  const { data, error } = await client().from("categories").select("id").limit(1);
  if (error) throw error;
  if (data.length > 0) return;

  for (const name of initialCategories) {
    try {
      await mutateCatalog("category", "create", { p_name: name });
    } catch (failure) {
      // Otra pestaña puede haber creado el mismo nombre tras la lectura inicial.
      if ((failure as { code?: string })?.code !== "23505") throw failure;
    }
  }
}
