import { useEffect, useMemo, useState } from "react";
import { useSetup } from "../hooks/useSetup";
import {
  downloadCompleteXlsx,
  downloadCsv,
  downloadHistoryXlsx,
  readDataExport,
} from "../lib/dataExport";
import { todayIn } from "../lib/dates";
import { friendlyError } from "../lib/errors";
import { periodLabels, readPeriods, type BudgetPeriod } from "../lib/periods";
import { formatDate } from "../lib/dates";
import { ErrorMessage } from "./Feedback";
import { ResetFinancialData } from "./ResetFinancialData";

type RangeMode = "all" | "current" | "period" | "custom";

function periodLabel(period: BudgetPeriod) {
  const dates = period.end_date
    ? `${formatDate(period.start_date)} – ${formatDate(period.end_date)}`
    : `Desde ${formatDate(period.start_date)}`;
  return `${dates} · ${periodLabels[period.mode]} · ${period.status === "open" ? "Actual" : "Cerrado"}`;
}

function ExportData() {
  const { settings } = useSetup();
  const today = todayIn(settings!.timezone);
  const [periods, setPeriods] = useState<BudgetPeriod[]>([]);
  const [loadingPeriods, setLoadingPeriods] = useState(true);
  const [mode, setMode] = useState<RangeMode>("all");
  const [periodId, setPeriodId] = useState("");
  const [start, setStart] = useState("");
  const [end, setEnd] = useState(today);
  const [format, setFormat] = useState<"csv" | "xlsx">("csv");
  const [busy, setBusy] = useState<"history" | "complete" | null>(null);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");

  useEffect(() => {
    let active = true;
    void readPeriods().then((rows) => {
      if (!active) return;
      setPeriods(rows);
      setPeriodId(rows[0]?.id ?? "");
    }).catch((failure) => active && setError(friendlyError(failure)))
      .finally(() => active && setLoadingPeriods(false));
    return () => { active = false; };
  }, []);

  const current = useMemo(() => periods.find((period) => period.status === "open") ?? null, [periods]);
  const chosen = periods.find((period) => period.id === periodId) ?? null;

  function selectedRange() {
    if (mode === "all") return { startDate: null, endDate: null, file: "all" as const, open: false };
    if (mode === "custom") {
      if (!start || !end) throw new Error("Indica la fecha de inicio y la fecha de fin.");
      if (start > end) throw new Error("La fecha de inicio no puede ser posterior a la fecha de fin.");
      if (end > today) throw new Error("La fecha final no puede ser posterior a hoy.");
      return { startDate: start, endDate: end, file: "range" as const, open: false };
    }
    const period = mode === "current" ? current : chosen;
    if (!period) throw new Error(mode === "current" ? "No hay un período actual." : "Elige un período.");
    return {
      startDate: period.start_date,
      endDate: period.status === "open" ? today : period.end_date!,
      file: "period" as const,
      open: period.status === "open",
    };
  }

  async function exportHistory() {
    if (busy) return;
    setError(""); setMessage("");
    try {
      const range = selectedRange();
      setBusy("history");
      const data = await readDataExport(range.startDate, range.endDate);
      const baseName = range.file === "all"
        ? `misgastos-todo-${data.range.as_of_date}`
        : range.file === "period"
          ? `misgastos-periodo-${data.range.start_date}-${range.open ? "hasta-" : ""}${data.range.end_date}`
          : `misgastos-rango-${data.range.start_date}-${data.range.end_date}`;
      if (format === "csv") {
        downloadCsv(data, `${baseName}.csv`, range.file, range.open);
        setMessage("Descarga CSV iniciada.");
      } else {
        await downloadHistoryXlsx(data, `${baseName}.xlsx`, range.file, range.open);
        setMessage("Descarga Excel completada.");
      }
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : friendlyError(failure));
    } finally { setBusy(null); }
  }

  async function exportComplete() {
    if (busy) return;
    setError(""); setMessage(""); setBusy("complete");
    try {
      const data = await readDataExport(null, null);
      await downloadCompleteXlsx(data, `misgastos-datos-completos-${data.range.as_of_date}.xlsx`);
      setMessage("Descarga Excel completada.");
    } catch (failure) { setError(friendlyError(failure)); }
    finally { setBusy(null); }
  }

  return <div className="export-settings">
    <section aria-labelledby="export-history-title">
      <h3 id="export-history-title">Exportar historial</h3>
      <p>Descarga tus saldos y movimientos para trabajar con ellos en Excel o Google Sheets.</p>
      <fieldset className="export-range" disabled={busy !== null || loadingPeriods}>
        <legend>Qué quieres exportar</legend>
        <label><input type="radio" name="export-range" checked={mode === "all"} onChange={() => setMode("all")} /> Todo el historial</label>
        <label><input type="radio" name="export-range" checked={mode === "current"} disabled={!current} onChange={() => setMode("current")} /> Período actual</label>
        <label><input type="radio" name="export-range" checked={mode === "period"} disabled={!periods.length} onChange={() => setMode("period")} /> Elegir período</label>
        {mode === "period" && <label className="export-subfield">Período
          <select value={periodId} onChange={(event) => setPeriodId(event.target.value)}>
            {periods.map((period) => <option key={period.id} value={period.id}>{periodLabel(period)}</option>)}
          </select>
        </label>}
        <label><input type="radio" name="export-range" checked={mode === "custom"} onChange={() => setMode("custom")} /> Rango personalizado</label>
        {mode === "custom" && <div className="export-date-range">
          <label>Fecha de inicio<input type="date" max={today} value={start} onChange={(event) => setStart(event.target.value)} /></label>
          <label>Fecha de fin<input type="date" max={today} value={end} onChange={(event) => setEnd(event.target.value)} /></label>
        </div>}
      </fieldset>
      <fieldset className="export-range" disabled={busy !== null}>
        <legend>Formato</legend>
        <label><input type="radio" name="export-format" checked={format === "csv"} onChange={() => setFormat("csv")} /> CSV</label>
        <label><input type="radio" name="export-format" checked={format === "xlsx"} onChange={() => setFormat("xlsx")} /> Excel (.xlsx)</label>
      </fieldset>
      <button type="button" disabled={busy !== null || loadingPeriods} onClick={() => void exportHistory()}>{busy === "history" ? "Preparando archivo…" : "Descargar"}</button>
    </section>
    <section aria-labelledby="export-complete-title">
      <h3 id="export-complete-title">Exportar datos completos (.xlsx)</h3>
      <p>Descarga una copia legible de tus datos financieros de MisGastos.</p>
      <button type="button" disabled={busy !== null} onClick={() => void exportComplete()}>{busy === "complete" ? "Preparando archivo…" : "Descargar Excel"}</button>
    </section>
    <ErrorMessage message={error} />
    {message && <p className="notice success" role="status">{message}</p>}
  </div>;
}

export function DataSettings() {
  return <section className="settings-content data-settings" aria-label="Gestión de datos">
    <details className="settings-disclosure data-disclosure">
      <summary className="settings-row"><span><strong>Exportar datos</strong><small>Historial o copia completa en Excel</small></span><span className="settings-chevron" aria-hidden="true">⌄</span></summary>
      <div className="settings-row-detail"><ExportData /></div>
    </details>
    <details className="settings-disclosure data-disclosure danger-disclosure">
      <summary className="settings-row"><span><strong>Empezar de cero</strong><small>Elimina tus datos financieros</small></span><span className="settings-chevron" aria-hidden="true">⌄</span></summary>
      <div className="settings-row-detail"><ResetFinancialData /></div>
    </details>
  </section>;
}
