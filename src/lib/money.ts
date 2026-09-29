import type { Currency, Money } from "../types/finance";

export function validateMoney(
  raw: string,
  { optional = false, negative = false } = {},
): string | null {
  const value = raw.trim().replace(",", ".");
  if (!value) {
    if (optional) return null;
    throw new Error("Introduce el saldo disponible inicial; puede ser 0.");
  }
  if (!(negative ? /^-?\d+(\.\d{1,2})?$/ : /^\d+(\.\d{1,2})?$/).test(value)) {
    throw new Error(
      `Introduce un importe ${negative ? "" : "igual o mayor que 0, "}con un máximo de dos decimales, sin separadores de miles.`,
    );
  }
  if (value.replace("-", "").split(".")[0].replace(/^0+/, "").length > 18) {
    throw new Error("El importe admite como máximo 18 cifras enteras.");
  }
  return value;
}
export function formatMoney(value: Money | null, currency: Currency) {
  if (value === null) return "—";
  const formatter = new Intl.NumberFormat("es-ES", {
    style: "currency",
    currency,
    minimumFractionDigits: currency === "PYG" ? 0 : 2,
    maximumFractionDigits: currency === "PYG" ? 0 : 2,
  });
  // Intl acepta cadenas decimales exactas en navegadores modernos, aunque lib.d.ts
  // solo declara number | bigint. Este cast no convierte el valor a Number.
  return formatter.format(value as number);
}
