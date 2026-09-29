import { validateMoney } from "./money";
import type { Movement, MovementKind, References } from "../types/movements";
export interface MovementDraft {
  date: string;
  amount: string;
  description: string;
  category: string;
  method: string;
  merchant: string;
  note: string;
  recurring: boolean;
  account: string;
  from: string;
  to: string;
}
export function movementDraft(today: string, row?: Movement): MovementDraft {
  return {
    date: row?.date || today,
    amount: row ? String(row.amount) : "",
    description: row?.description || "",
    category: row?.kind === "expense" ? row.category_id : "",
    method: row?.kind === "expense" ? row.payment_method_id || "" : "",
    merchant: row?.kind === "expense" ? row.merchant || "" : "",
    note: row?.kind === "expense" ? row.note || "" : "",
    recurring: row?.kind === "expense" ? row.is_recurring : false,
    account: row?.kind === "income" ? row.savings_account_id || "" : "",
    from: row?.kind === "transfer" ? row.from_savings_account_id || "" : "",
    to: row?.kind === "transfer" ? row.to_savings_account_id || "" : "",
  };
}
export function movementParameters(
  kind: MovementKind,
  draft: MovementDraft,
  today: string,
  refs: References,
  row?: Movement,
): Record<string, unknown> {
  if (!draft.date || draft.date > today)
    throw new Error("Elige una fecha válida que no sea futura.");
  const period = refs.periods.find(
    (p) =>
      p.status === "open" &&
      p.start_date <= draft.date &&
      (!p.end_date || p.end_date >= draft.date),
  );
  if (!period || (row && row.period_id !== period.id))
    throw new Error(
      "La fecha debe pertenecer al período abierto. No se pueden modificar períodos cerrados.",
    );
  if (!draft.amount.trim())
    throw new Error("Introduce el importe del movimiento.");
  const amount = validateMoney(draft.amount)!;
  if (!/[1-9]/.test(amount))
    throw new Error("El importe debe ser mayor que 0.");
  const optional = (value: string) => value.trim() || null;
  const base = {
    p_date: draft.date,
    p_amount: amount,
    p_description: optional(draft.description),
    ...(row ? { p_id: row.id, p_expected_version: row.version } : {}),
  };
  const validAccount = (id: string, oldId?: string | null) => {
    if (
      id &&
      !refs.accounts.some(
        (a) =>
          a.id === id &&
          (a.is_active || a.id === oldId) &&
          a.start_date <= draft.date,
      )
    )
      throw new Error(
        "Elige una cuenta activa cuya fecha inicial no sea posterior al movimiento.",
      );
  };
  if (kind === "expense") {
    const old = row?.kind === "expense" ? row : undefined;
    if (
      !refs.categories.some(
        (c) =>
          c.id === draft.category && (c.is_active || c.id === old?.category_id),
      )
    )
      throw new Error(
        "Selecciona una categoría activa. Puedes crearla desde Ajustes.",
      );
    if (
      draft.method &&
      !refs.methods.some(
        (m) =>
          m.id === draft.method &&
          (m.is_active || m.id === old?.payment_method_id),
      )
    )
      throw new Error(
        "Selecciona un método de pago activo o deja el campo vacío.",
      );
    return {
      ...base,
      p_category_id: draft.category,
      p_payment_method_id: draft.method || null,
      p_merchant: optional(draft.merchant),
      p_note: optional(draft.note),
      p_is_recurring: draft.recurring,
    };
  }
  if (kind === "income") {
    validAccount(
      draft.account,
      row?.kind === "income" ? row.savings_account_id : null,
    );
    return { ...base, p_savings_account_id: draft.account || null };
  }
  if (draft.from === draft.to)
    throw new Error(
      "Origen y destino deben ser distintos e incluir una cuenta de ahorro.",
    );
  validAccount(
    draft.from,
    row?.kind === "transfer" ? row.from_savings_account_id : null,
  );
  validAccount(
    draft.to,
    row?.kind === "transfer" ? row.to_savings_account_id : null,
  );
  return {
    ...base,
    p_from_savings_account_id: draft.from || null,
    p_to_savings_account_id: draft.to || null,
  };
}
