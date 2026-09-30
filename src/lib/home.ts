import { client } from "./supabase";
import type { Money } from "../types/finance";
import type { BudgetUsage } from "./periods";

// Agregaciones de presentación en céntimos: no reconstruyen saldos ni usan
// aritmética de coma flotante para sumar importes.
export function moneyUnits(value: Money): bigint {
  const raw = String(value);
  const negative = raw.startsWith("-");
  const [whole, fraction = ""] = raw.replace(/^-/, "").split(".");
  const units = BigInt(whole) * 100n + BigInt(fraction.padEnd(2, "0").slice(0, 2));
  return negative ? -units : units;
}
export function unitsMoney(units: bigint): string {
  const absolute = units < 0n ? -units : units;
  return `${units < 0n ? "-" : ""}${absolute / 100n}.${String(absolute % 100n).padStart(2, "0")}`;
}
export function sumAmounts(values: Money[]): string {
  return unitsMoney(values.reduce<bigint>((sum, value) => sum + moneyUnits(value), 0n));
}
export async function readHomeCategories(periodId: string) {
  const { data, error } = await client().rpc("get_category_budget_usage", { p_period_id: periodId });
  if (error) throw error;
  return data as BudgetUsage[];
}
export interface ExpenseBreakdown {
  methods: { id: string | null; name: string; amount: string }[];
  days: { date: string; cumulative: string }[];
}
export async function readExpenseBreakdown(periodId: string, asOfDate: string): Promise<ExpenseBreakdown> {
  const expenses: { id: string; date: string; amount: string; payment_method_id: string | null }[] = [];
  // Leer el período completo: el historial reciente está limitado por tipo.
  for (let offset = 0; ; offset += 500) {
    const { data, error } = await client().from("expenses")
      .select("id,date,amount::text,payment_method_id")
      .eq("period_id", periodId).lte("date", asOfDate)
      .order("date").order("id").range(offset, offset + 499);
    if (error) throw error;
    expenses.push(...data);
    if (data.length < 500) break;
  }
  const methods = new Map<string, string>();
  for (let offset = 0; ; offset += 500) {
    const { data, error } = await client().from("payment_methods")
      .select("id,name").order("id").range(offset, offset + 499);
    if (error) throw error;
    data.forEach((row) => methods.set(row.id, row.name));
    if (data.length < 500) break;
  }
  const byMethod = new Map<string | null, bigint>();
  const byDay = new Map<string, bigint>();
  for (const row of expenses) {
    const amount = moneyUnits(row.amount);
    byMethod.set(row.payment_method_id, (byMethod.get(row.payment_method_id) || 0n) + amount);
    byDay.set(row.date, (byDay.get(row.date) || 0n) + amount);
  }
  let cumulative = 0n;
  return {
    methods: [...byMethod].map(([id, amount]) => ({
      id, name: id === null ? "Sin método" : methods.get(id) || "Método no disponible", amount: unitsMoney(amount),
    })).sort((a, b) => Number(b.amount) - Number(a.amount)),
    days: [...byDay].map(([date, amount]) => {
      cumulative += amount;
      return { date, cumulative: unitsMoney(cumulative) };
    }),
  };
}
