import type { PeriodMode } from "../types/finance";
export function todayIn(timezone: string) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date());
  return ["year", "month", "day"]
    .map((type) => parts.find((p) => p.type === type)!.value)
    .join("-");
}
export function periodDates(
  mode: PeriodMode,
  today: string,
  start: string,
  end: string,
) {
  const [year, month] = today.split("-").map(Number);
  if (mode === "monthly") {
    const last = new Date(Date.UTC(year, month, 0)).getUTCDate();
    return {
      p_start_date: `${today.slice(0, 7)}-01`,
      p_end_date: `${today.slice(0, 7)}-${last}`,
    };
  }
  if (mode === "annual")
    return { p_start_date: `${year}-01-01`, p_end_date: `${year}-12-31` };
  if (!start || start > today)
    throw new Error("La fecha de inicio debe ser hoy o anterior.");
  if (mode === "custom" && (!end || end < today))
    throw new Error("La fecha final debe ser hoy o posterior.");
  return { p_start_date: start, p_end_date: mode === "custom" ? end : null };
}
export function formatDate(date: string) {
  return new Intl.DateTimeFormat("es-ES", {
    dateStyle: "medium",
    timeZone: "UTC",
  }).format(new Date(`${date}T12:00:00Z`));
}
