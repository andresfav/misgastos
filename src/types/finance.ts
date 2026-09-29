export type Currency = "EUR" | "USD" | "PYG";
export type PeriodMode = "monthly" | "annual" | "custom" | "between_paydays";
// PostgREST devuelve numeric en JSON como number. Se usa solo para presentación;
// las entradas monetarias viajan como strings, sin cálculos de saldos en JS.
export type Money = number | string;
export interface Settings {
  user_id: string;
  currency: Currency;
  timezone: string;
  version: number;
  currency_locked_at: string | null;
}
export interface Period {
  id: string;
  mode: PeriodMode;
  start_date: string;
  end_date: string | null;
  status: "open" | "closed";
}
export interface FinancialState {
  as_of_date: string;
  current_period: Period | null;
  available: Money | null;
  expenses_total: Money | null;
  income_total: Money | null;
  general_budget: Money | null;
  general_budget_remaining: Money | null;
  savings_balances: Array<{
    id: string;
    name: string;
    is_active: boolean;
    current_balance: Money;
  }>;
}
export interface FirstPeriodInput {
  p_mode: PeriodMode;
  p_start_date: string;
  p_end_date: string | null;
  p_opening_balance: string;
  p_general_budget: string | null;
}
