export type Currency = "EUR" | "USD" | "PYG";
export type PeriodMode = "monthly" | "annual" | "custom" | "between_paydays";
// PostgREST devuelve numeric en JSON como number. Se usa solo para presentación;
// las entradas monetarias viajan como strings, sin cálculos de saldos en JS.
export type BudgetModel = "legacy_total" | "by_origin";
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
export interface FundingBreakdown {
  funding_type: "available" | "external";
  external_source_id: string | null;
  name: string;
  amount: string;
}
export interface FundingBudgetUsage {
  funding_type: "available" | "external";
  external_source_id: string | null;
  name: string;
  is_active: boolean;
  budget_amount: string | null;
  spent: string;
  remaining: string | null;
}
export interface FinancialState {
  as_of_date: string;
  current_period: Period | null;
  available: Money | null;
  expenses_total: Money | null;
  expenses_available_total: Money | null;
  has_external_sources: boolean;
  funding_budgets: FundingBudgetUsage[];
  budget_model: BudgetModel | null;
  legacy_general_budget: string | null;
  expenses_funding_breakdown?: FundingBreakdown[];
  income_total: Money | null;
  // Total canónico: general histórico o suma por origen, según budget_model.
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
