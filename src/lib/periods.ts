import { client } from "./supabase";
import { friendlyError } from "./errors";
import { periodDates } from "./dates";
import type { Money, Period, PeriodMode } from "../types/finance";

export const periodLabels: Record<PeriodMode, string> = {
  monthly: "Mensual", annual: "Anual", custom: "Personalizado", between_paydays: "Entre cobros",
};
export interface BudgetPeriod extends Period {
  version: number;
  opening_balance: Money;
  closing_balance: Money | null;
  general_budget: string | null;
}
export interface PeriodSummary {
  as_of_date: string;
  period: BudgetPeriod;
  available: Money;
  income_total: Money;
  expenses_total: Money;
  general_budget: Money | null;
  general_budget_remaining: Money | null;
  income_to_available: Money;
  income_to_savings: Money;
  transfer_to_savings_total: Money;
  transfer_from_savings_total: Money;
}
export interface BudgetUsage {
  category_id: string;
  category_name: string;
  category_is_active: boolean;
  budget_id: string | null;
  budget_version: number | null;
  budget_amount: Money | null;
  spent: Money;
  remaining: Money | null;
}
export async function readPeriods() {
  const rows: BudgetPeriod[] = [];
  for (let offset = 0; ; offset += 500) {
    const { data, error } = await client().from("budget_periods")
      .select("id,mode,start_date,end_date,status,version,opening_balance::text,closing_balance::text,general_budget::text")
      .order("start_date", { ascending: false }).order("id").range(offset, offset + 499);
    if (error) throw error;
    rows.push(...data as BudgetPeriod[]);
    if (data.length < 500) return rows;
  }
}
export async function readPeriodDetail(id: string) {
  const [summary, usage] = await Promise.all([
    client().rpc("get_period_summary", { p_period_id: id }),
    client().rpc("get_category_budget_usage", { p_period_id: id }),
  ]);
  if (summary.error) throw summary.error;
  if (usage.error) throw usage.error;
  // Leer entradas editables como texto: no redondear numeric al editar.
  const budgets: { id: string; amount: string; version: number }[] = [];
  for (let offset = 0; ; offset += 500) {
    const { data, error } = await client().from("period_category_budgets")
      .select("id,amount::text,version").eq("period_id", id).order("id").range(offset, offset + 499);
    if (error) throw error;
    budgets.push(...data);
    if (data.length < 500) break;
  }
  const rows = (usage.data as BudgetUsage[]).map((row) => {
    if (!row.budget_id) return row;
    const entry = budgets.find((b) => b.id === row.budget_id && b.version === row.budget_version);
    if (!entry) throw { code: "40001" };
    return { ...row, budget_amount: entry.amount };
  });
  return { summary: summary.data as PeriodSummary, usage: rows };
}
export async function periodMutation(
  rpc: "advance_period" | "set_general_budget" | "create_category_budget" | "update_category_budget" | "delete_category_budget",
  parameters: Record<string, unknown>,
) {
  const { data, error } = await client().rpc(rpc, parameters);
  if (error) throw error;
  return data;
}
export function shiftDay(date: string, days: number) {
  const result = new Date(`${date}T12:00:00Z`);
  result.setUTCDate(result.getUTCDate() + days);
  return result.toISOString().slice(0, 10);
}
export function transitionDates(period: BudgetPeriod, mode: PeriodMode, today: string, start: string, end: string) {
  const dates = periodDates(mode, today, start, end);
  if (dates.p_start_date <= period.start_date || (period.end_date && dates.p_start_date <= period.end_date))
    throw new Error("El nuevo inicio debe ser posterior al período actual. El mes o año natural actual puede solaparse: elige Personalizado o Entre cobros.");
  if (dates.p_end_date && dates.p_end_date < dates.p_start_date)
    throw new Error("La fecha final no puede ser anterior a la inicial.");
  return dates;
}
export function periodError(error: unknown) {
  const { code, message = "" } = error as { code?: string; message?: string };
  if (code === "P0002") return "El período abierto o presupuesto ya no está disponible. Recarga los datos y vuelve a intentarlo.";
  if (code === "23505") return "Esta categoría ya tiene presupuesto. Recarga para editarlo.";
  if (code === "22023") {
    if (/movimientos fuera/i.test(message)) return "El cierre dejaría movimientos fuera del período. Revisa sus fechas o elige un inicio posterior para el siguiente período.";
    if (/solapa|historia|posterior/i.test(message)) return "El nuevo período debe comenzar después del actual y de todos los períodos anteriores.";
    if (/mes natural|año natural/i.test(message)) return "Mensual y anual deben coincidir con el mes o año natural actual. Elige Personalizado si necesitas otras fechas.";
    if (/categoría/i.test(message)) return "La categoría ya no está activa. Actualiza los datos y selecciona otra.";
    if (/presupuesto|amount/i.test(message)) return "Introduce un presupuesto igual o mayor que 0, con hasta dos decimales.";
    if (/Saldo de cierre/i.test(message)) return "El saldo de cierre supera el importe admitido por el sistema. No se puede avanzar el período.";
    return "No se permite esta transición. El inicio debe ser hoy o anterior, el período debe incluir hoy y Entre cobros debe quedar sin fecha final.";
  }
  return friendlyError(error);
}
