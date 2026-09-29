export const DATA_CHANGED = "misgastos:data-changed";
export function refreshFinancialData() {
  window.dispatchEvent(new Event(DATA_CHANGED));
}
