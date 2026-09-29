import { client } from "./supabase";
import type {
  Currency,
  FinancialState,
  FirstPeriodInput,
  Settings,
} from "../types/finance";

export async function readSetup(userId: string) {
  const { data, error } = await client()
    .from("user_settings")
    .select("user_id,currency,timezone,version,currency_locked_at")
    .eq("user_id", userId)
    .maybeSingle();
  if (error) throw error;
  if (!data) return { settings: null, hasPeriods: false };
  // Un período cerrado también cuenta como historial: no reiniciar onboarding.
  const periods = await client()
    .from("budget_periods")
    .select("id")
    .eq("user_id", userId)
    .limit(1);
  if (periods.error) throw periods.error;
  return {
    settings: data as Settings,
    hasPeriods: Boolean(periods.data.length),
  };
}
export async function configureSettings(currency: Currency, timezone: string) {
  const { data, error } = await client().rpc("configure_user_settings", {
    p_currency: currency,
    p_timezone: timezone,
  });
  if (error) throw error;
  return data as Settings;
}
export async function createFirstPeriod(
  input: FirstPeriodInput,
  requestId: string,
) {
  const { error } = await client().rpc("create_first_period", {
    ...input,
    p_request_id: requestId,
  });
  if (error) throw error;
}
export async function readFinancialState() {
  const { data, error } = await client().rpc("get_current_financial_state");
  if (error) throw error;
  return data as FinancialState;
}
