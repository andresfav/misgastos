import { client } from "./supabase";
import type { Money } from "../types/finance";
import type { SavingsOption, Income, Transfer } from "../types/movements";
import { sortMovements } from "./movements";

export interface SavingsAccount extends SavingsOption {
  opening_balance: Money;
  current_balance: Money;
  has_history: boolean;
  can_hard_delete: boolean;
  can_correct_opening_balance: boolean;
}
export type DeleteSavingsResult =
  | { mode: "hard_deleted" | "soft_deleted" }
  | { mode: "blocked"; code: "ACCOUNT_HAS_BALANCE"; balance: Money };
export async function readSavings(): Promise<SavingsAccount[]> {
  const { data, error } = await client().rpc("get_savings_balances");
  if (error) throw error;
  // Mantener el orden de la RPC: activas, nombre normalizado, id.
  return data as SavingsAccount[];
}
export async function createSavings(
  input: { p_name: string; p_start_date: string; p_opening_balance: string },
  requestId: string,
) {
  const { error } = await client().rpc("create_savings_account", {
    ...input, p_request_id: requestId,
  });
  if (error) throw error;
}
export async function renameSavings(account: SavingsAccount, name: string) {
  const { error } = await client().rpc("rename_savings_account", {
    p_id: account.id, p_name: name, p_expected_version: account.version,
  });
  if (error) throw error;
}
export async function setSavingsActive(account: SavingsAccount) {
  const { error } = await client().rpc("set_savings_account_active", {
    p_id: account.id, p_is_active: !account.is_active, p_expected_version: account.version,
  });
  if (error) throw error;
}
export async function correctSavingsOpeningBalance(
  account: SavingsAccount,
  openingBalance: string,
  requestId: string,
) {
  const { error } = await client().rpc("correct_savings_opening_balance", {
    p_id: account.id,
    p_opening_balance: openingBalance,
    p_expected_version: account.version,
    p_request_id: requestId,
  });
  if (error) throw error;
}
export async function deleteSavings(account: SavingsAccount, requestId: string) {
  const { data, error } = await client().rpc("delete_savings_account", {
    p_id: account.id,
    p_expected_version: account.version,
    p_request_id: requestId,
  });
  if (error) throw error;
  return data as DeleteSavingsResult;
}
export async function readSavingsHistory(id: string) {
  const groups = await Promise.all((["income", "transfer"] as const).map(async (kind) => {
    const rows: (Income | Transfer)[] = [];
    for (let offset = 0; ; offset += 500) {
      const common = "id,period_id,date,amount::text,description,created_at,version";
      const query = kind === "income"
        ? client().from("incomes").select(`${common},savings_account_id`).eq("savings_account_id", id)
        : client().from("transfers").select(`${common},from_savings_account_id,to_savings_account_id`)
          .or(`from_savings_account_id.eq.${id},to_savings_account_id.eq.${id}`);
      const { data, error } = await query.order("date", { ascending: false })
        .order("created_at", { ascending: false }).order("id", { ascending: false })
        .range(offset, offset + 499);
      if (error) throw error;
      rows.push(...data.map((row) => ({ ...row, kind }) as unknown as Income | Transfer));
      if (data.length < 500) return rows;
    }
  }));
  return sortMovements(groups.flat());
}
