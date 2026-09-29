import type { Period } from "./finance";
export type MovementKind = "expense" | "income" | "transfer";
export type CatalogKind = "category" | "payment_method";
export interface CatalogItem {
  id: string;
  name: string;
  is_active: boolean;
  version: number;
}
export interface SavingsOption extends CatalogItem {
  start_date: string;
}
interface BaseMovement {
  id: string;
  period_id: string;
  date: string;
  amount: string;
  description: string | null;
  created_at: string;
  version: number;
}
export interface Expense extends BaseMovement {
  kind: "expense";
  category_id: string;
  payment_method_id: string | null;
  merchant: string | null;
  note: string | null;
  is_recurring: boolean;
}
export interface Income extends BaseMovement {
  kind: "income";
  savings_account_id: string | null;
}
export interface Transfer extends BaseMovement {
  kind: "transfer";
  from_savings_account_id: string | null;
  to_savings_account_id: string | null;
}
export type Movement = Expense | Income | Transfer;
export interface References {
  categories: CatalogItem[];
  methods: CatalogItem[];
  accounts: SavingsOption[];
  periods: Period[];
}
export const movementLabels: Record<MovementKind, string> = {
  expense: "Gasto",
  income: "Ingreso",
  transfer: "Transferencia",
};
