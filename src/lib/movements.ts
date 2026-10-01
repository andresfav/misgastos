import { client } from "./supabase";
import type {
  CatalogItem,
  CatalogKind,
  Movement,
  MovementKind,
  References,
  SavingsOption,
} from "../types/movements";
import type { Period } from "../types/finance";

async function readAll<T>(table: string, columns: string): Promise<T[]> {
  const rows: T[] = [];
  for (let offset = 0; ; offset += 500) {
    const { data, error } = await client()
      .from(table)
      .select(columns)
      .order("id")
      .range(offset, offset + 499);
    if (error) throw error;
    rows.push(...(data as unknown as T[]));
    if (data.length < 500) return rows;
  }
}
export async function readReferences(): Promise<References> {
  const [categories, methods, accounts, periods] = await Promise.all([
    readAll<CatalogItem>("categories", "id,name,is_active,version"),
    readAll<CatalogItem>("payment_methods", "id,name,is_active,version"),
    readAll<SavingsOption>(
      "savings_accounts",
      "id,name,is_active,version,start_date",
    ),
    readAll<Period>("budget_periods", "id,mode,start_date,end_date,status"),
  ]);
  const byName = (a: CatalogItem, b: CatalogItem) =>
    a.name.localeCompare(b.name, "es");
  return {
    categories: categories.sort(byName),
    methods: methods.sort(byName),
    accounts: accounts.sort(byName),
    periods,
  };
}
export async function readExpenseReferences(
  currentCategoryId?: string,
): Promise<References> {
  const [categoryResult, methods, accounts, periods] = await Promise.all([
    client().rpc("get_expense_categories", {
      p_current_category_id: currentCategoryId ?? null,
    }),
    readAll<CatalogItem>("payment_methods", "id,name,is_active,version"),
    readAll<SavingsOption>(
      "savings_accounts",
      "id,name,is_active,version,start_date",
    ),
    readAll<Period>("budget_periods", "id,mode,start_date,end_date,status"),
  ]);
  if (categoryResult.error) throw categoryResult.error;
  const byName = (a: CatalogItem, b: CatalogItem) =>
    a.name.localeCompare(b.name, "es");
  return {
    categories: categoryResult.data as CatalogItem[],
    methods: methods.sort(byName),
    accounts: accounts.sort(byName),
    periods,
  };
}
export async function readCatalogManagement(): Promise<Pick<References, "categories" | "methods">> {
  const { data, error } = await client().rpc("get_catalog_management");
  if (error) throw error;
  return data as Pick<References, "categories" | "methods">;
}
const tables = {
  expense: "expenses",
  income: "incomes",
  transfer: "transfers",
} as const;
// Solicitar el numeric como texto evita redondearlo al abrir una edición.
const common = "id,period_id,date,amount::text,description,created_at,version";
const columns = {
  expense: `${common},category_id,payment_method_id,merchant,note,is_recurring`,
  income: `${common},savings_account_id`,
  transfer: `${common},from_savings_account_id,to_savings_account_id`,
};
export function sortMovements(rows: Movement[]) {
  return rows.sort(
    (a, b) =>
      b.date.localeCompare(a.date) ||
      b.created_at.localeCompare(a.created_at) ||
      b.id.localeCompare(a.id),
  );
}
export async function readMovements() {
  const groups = await Promise.all(
    (Object.keys(tables) as MovementKind[]).map(async (kind) => {
      const { data, error } = await client()
        .from(tables[kind])
        .select(columns[kind])
        .order("date", { ascending: false })
        .order("created_at", { ascending: false })
        .order("id", { ascending: false })
        .limit(100);
      if (error) throw error;
      return (data as unknown as Omit<Movement, "kind">[]).map(
        (row) => ({ ...row, kind }) as Movement,
      );
    }),
  );
  return sortMovements(groups.flat());
}
export async function readMovementForEdit(kind: MovementKind, id: string) {
  const result = await client().from(tables[kind]).select(columns[kind]).eq("id", id).maybeSingle();
  if (result.error) throw result.error;
  const row = result.data
    ? ({ ...(result.data as unknown as Omit<Movement, "kind">), kind } as Movement)
    : null;
  const refs = kind === "expense"
    ? await readExpenseReferences(row?.kind === "expense" ? row.category_id : undefined)
    : await readReferences();
  return { row, refs };
}
export async function readMovementScreen() {
  const [rows, refs] = await Promise.all([readMovements(), readReferences()]);
  return { rows, refs };
}
export async function mutateMovement(
  operation: "create" | "update" | "delete",
  kind: MovementKind,
  parameters: Record<string, unknown>,
  requestId: string,
) {
  const { error } = await client().rpc(`${operation}_${kind}`, {
    ...parameters,
    p_request_id: requestId,
  });
  if (error) throw error;
}
export async function mutateCatalog(
  kind: CatalogKind,
  action: "create" | "rename" | "delete",
  parameters: Record<string, unknown>,
) {
  const { data, error } = await client().rpc(`${action}_${kind}`, parameters);
  if (error) throw error;
  return data as { mode?: "hard_deleted" | "soft_deleted" } | null;
}
