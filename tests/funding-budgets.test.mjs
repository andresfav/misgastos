// Tests of the actual components and export contracts, using Vite's TSX loader.
// No Supabase connection: the client and authenticated hooks are replaced locally.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'vite';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { MemoryRouter } from 'react-router-dom';
import { writeFileSync, readFileSync } from 'node:fs';

const mocks = {
  supabase: 'export function client(){throw new Error("Network forbidden in component tests")}',
  useSetup: 'export function useSetup(){return {settings:{currency:"EUR",timezone:"Europe/Madrid"}}}',
  useRemote: 'export function useRemote(load){return load.name === "readFinancialState" ? {data:globalThis.__misgastosFinancialFixture,loading:false,error:"",reload(){}} : {data:null,loading:true,error:"",reload(){}}}',
  useSubmit: 'export function useSubmit(){return {busy:false,error:"",setError(){},submit(){}}}',
  useRequestAttempt: 'export function useRequestAttempt(){return {requestId(){return "test"},clear(){}}}',
};
const server = await createServer({
  configFile: false,
  server: { middlewareMode: true, hmr: false, ws: false },
  appType: 'custom',
  optimizeDeps: { noDiscovery: true, include: [] },
  plugins: [{ name: 'offline-component-fixtures', enforce: 'pre',
    resolveId(source) {
      const name = source.split('/').at(-1).replace(/\.tsx?$/, '');
      if (name in mocks) return `\0offline:${name}`;
    },
    load(id) { if (id.startsWith('\0offline:')) return mocks[id.slice('\0offline:'.length)]; },
  }],
  esbuild: { jsx: 'automatic' },
});
after(async () => { delete globalThis.__misgastosFinancialFixture; await server.close(); });
const { editableFundingBudgets, draftBudgetTotal, fundingBudgetParameters, fundingBudgetDraft, budgetProgress } = await server.ssrLoadModule('/src/lib/fundingBudgets.ts');
const { completeXlsxSheets } = await server.ssrLoadModule('/src/lib/dataExport.ts');
const { BudgetDetail } = await server.ssrLoadModule('/src/components/BudgetDetail.tsx');
const { HomePage } = await server.ssrLoadModule('/src/pages/HomePage.tsx');
const { FundingBudgetsForm } = await server.ssrLoadModule('/src/components/FundingBudgetsForm.tsx');
const { HistoricalFundingBudgets } = await server.ssrLoadModule('/src/components/HistoricalFundingBudgets.tsx');
const { MovementForm } = await server.ssrLoadModule('/src/components/MovementForm.tsx');
const render = (Component, props) => renderToStaticMarkup(createElement(MemoryRouter, null, createElement(Component, props)));
const available = { funding_type: 'available', external_source_id: null, name: 'Disponible', is_active: true, budget_amount: '2000.00', spent: '300.00', remaining: '1700.00' };
const external = { funding_type: 'external', external_source_id: 'source', name: 'Itaú', is_active: true, budget_amount: '500.00', spent: '650.00', remaining: '-150.00' };
const rows = [available, external];
const period = { id: 'period', version: 7, status: 'open', start_date: '2026-10-01', end_date: '2026-10-31', mode: 'monthly', general_budget: '2000.00', budget_model: 'by_origin' };
const data = { current_period: period, period, as_of_date: '2026-10-29', available: '4700.00', expenses_available_total: '300.00', expenses_total: '950.00', has_external_sources: true, budget_model: 'by_origin', legacy_general_budget: null, funding_budgets: rows, general_budget: '2500.00', general_budget_remaining: '1550.00', income_total: '1000.00', savings_balances: [] };

test('draft total follows 2000+500 → 2700 → 2500, preserving cents exactly', () => {
  const draft = fundingBudgetDraft(rows);
  assert.equal(draftBudgetTotal(rows, draft), '2500.00');
  draft.source = '700';
  assert.equal(draftBudgetTotal(rows, draft), '2700.00');
  draft.available = '1800';
  assert.equal(draftBudgetTotal(rows, draft), '2500.00');
  draft.source = '0,20'; draft.available = '0,10';
  assert.equal(draftBudgetTotal(rows, draft), '0.30');
  assert.deepEqual(fundingBudgetParameters(period.id, period.version, rows, draft), {
    p_period_id: 'period', p_expected_version: 7, p_available_budget: '0.10',
    p_external_budgets: [{ external_source_id: 'source', amount: '0.20' }],
  });
});
test('unassigned, zero, inactive and multiple sources remain distinct', () => {
  assert.equal(draftBudgetTotal(rows, { available: '', source: '' }), null);
  assert.equal(draftBudgetTotal(rows, { available: '0', source: '' }), '0.00');
  assert.throws(() => draftBudgetTotal(rows, { available: '-1', source: '20' }));
  assert.throws(() => draftBudgetTotal(rows, { available: '20.001', source: '20' }));
  const historical = [...rows, { ...external, external_source_id: 'old', name: 'Histórico', is_active: false, budget_amount: null }];
  assert.equal(draftBudgetTotal(historical, fundingBudgetDraft(historical)), '2500.00');
  assert.deepEqual(fundingBudgetParameters('period', 7, historical, fundingBudgetDraft(historical)).p_external_budgets, []);
  assert.deepEqual(fundingBudgetParameters('period', 7, rows, { available: '2000', source: '' }).p_external_budgets, [{ external_source_id: 'source', amount: null }]);
});
test('650/500 renders 130%, 150 above (+30%), red class and visually clamped bar', () => {
  assert.deepEqual(budgetProgress('650', '500', '-150'), { used: 130, exceeded: true, fill: 100, excessPercent: 30 });
  const html = render(BudgetDetail, { spent: '650', budget: '500', remaining: '-150', currency: 'EUR' });
  assert.match(html, /130 % utilizado/);
  assert.match(html, /150,00.*por encima.*\(\+30 %\)/);
  assert.match(html, /budget-progress exceeded/);
  assert.match(html, /value="100"/);
  assert.match(html, /danger-text/);
});
test('no artificial percentage for unassigned or zero budgets; remaining is shown for normal use', () => {
  const unassigned = render(BudgetDetail, { spent: '50', budget: null, remaining: null, currency: 'EUR' });
  assert.match(unassigned, /Sin presupuesto asignado/);
  assert.doesNotMatch(unassigned, /<progress|%|Infinity|NaN/);
  const zero = render(BudgetDetail, { spent: '50', budget: '0', remaining: '-50', currency: 'EUR' });
  assert.match(zero, /importe cero/); assert.match(zero, /50,00.*por encima/);
  assert.doesNotMatch(zero, /%|Infinity|NaN/);
  const regular = render(BudgetDetail, { spent: '300', budget: '2000', remaining: '1700', currency: 'EUR' });
  assert.match(regular, /15 % utilizado/); assert.match(regular, /1700,00.*restantes/);
});
test('Home focuses Gasto on Disponible and presents all consumption below', () => {
  globalThis.__misgastosFinancialFixture = data;
  const html = render(HomePage, {});
  assert.match(html, /<dt>Gasto<\/dt><dd>300,00/);
  assert.match(html, /Gastos por origen/); assert.match(html, /Total de gastos:.*950,00/);
  assert.match(html, /Presupuesto total/); assert.match(html, /Presupuestos por origen/);
  assert.match(html, /Itaú/);
});
test('Disponible-only Home and expense form omit redundant origin UI', () => {
  globalThis.__misgastosFinancialFixture = { ...data, has_external_sources: false, expenses_total: '300.00', funding_budgets: [available], general_budget: '2000.00', budget_model: 'by_origin' };
  const html = render(HomePage, {});
  assert.doesNotMatch(html, /Gastos por origen|Presupuestos por origen/);
  assert.match(html, /Presupuesto/);
  const refs = { categories: [{ id: 'c', name: 'Comida', is_active: true }], methods: [], accounts: [], periods: [period], external_sources: [] };
  const props = { kind: 'expense', refs, onSaved() {}, onConflict() {} };
  assert.doesNotMatch(render(MovementForm, props), /Origen del gasto|Origen externo/);
  const historicalRefs = { ...refs, external_sources: [{ id: 'source', name: 'Itaú', is_active: false }] };
  assert.match(render(MovementForm, { ...props, refs: historicalRefs }), /Origen del gasto/);
});
test('budget editor exposes components and a calculated output, with inactive history retained', () => {
  const summary = { ...data, period, funding_budgets: [available, { ...external, is_active: false }] };
  const html = render(FundingBudgetsForm, { summary, onMessage() {} });
  assert.match(html, /Presupuesto total calculado/);
  assert.match(html, /2500,00/); assert.match(html, /Origen inactivo/);
  assert.equal((html.match(/<input/g) ?? []).length, 2);
  assert.match(html, /Presupuesto de Disponible/); assert.match(html, /Presupuesto de Itaú/);
});
test('complete Excel includes total, origin components and categories as separate dimensions', () => {
  const workbook = completeXlsxSheets({
    settings: { currency: 'EUR', timezone: 'Europe/Madrid' }, range: { as_of_date: '2026-10-29' },
    movements: [], balances: [], savings_accounts: [], categories: [], payment_methods: [], external_sources: [],
    periods: [{ ...period, general_budget: '2500.00', opening_balance: '5000', closing_balance: null, closed_at: null }],
    budgets: [{ period_start: period.start_date, period_end: period.end_date, category: 'Comida', amount: '1500' }],
    funding_budgets: rows.map(row => ({ ...row, period_start: period.start_date, period_end: period.end_date, period_status: 'closed', amount: row.budget_amount })),
  });
  const total = workbook.find(sheet => sheet.sheet === 'Presupuestos').data;
  assert.equal(total[1][0], 'Total'); assert.equal(total[1][4], 2500);
  assert.equal(total[2][0], 'Categoría'); assert.equal(total[2][4], 1500);
  const origins = workbook.find(sheet => sheet.sheet === 'Presupuestos por origen').data;
  assert.equal(origins[1][4], 'Disponible'); assert.equal(origins[1][6], 2000);
  assert.equal(origins[2][4], 'Itaú'); assert.equal(origins[2][6], 500);
  assert.equal(origins[2][2], 'Cerrado');
});
test('legacy closed totals never render as exclusive Disponible limits or Excel allocations', () => {
  const summary = { ...data, budget_model: 'legacy_total', legacy_general_budget: '1500.00',
    general_budget: '1500.00', general_budget_remaining: '550.00',
    period: { ...period, status: 'closed', budget_model: 'legacy_total', general_budget: '1500.00' },
    funding_budgets: rows.map(row => ({ ...row, budget_amount: null, remaining: null })) };
  const html = render(HistoricalFundingBudgets, { summary, currency: 'EUR' });
  assert.match(html, /cubre todos los gastos.*incluidos los externos/);
  assert.doesNotMatch(html, /Presupuestos por origen|<progress|1500,00/);
  assert.ok(editableFundingBudgets(summary).every(row => row.budget_amount === null));
  const workbook = completeXlsxSheets({
    settings: { currency: 'EUR', timezone: 'Europe/Madrid' }, range: { as_of_date: '2026-10-29' },
    movements: [], balances: [], savings_accounts: [], categories: [], payment_methods: [], external_sources: [],
    periods: [{ ...summary.period, opening_balance: '5000', closing_balance: '4700', closed_at: '2026-10-29', available_budget: null }],
    budgets: [], funding_budgets: [],
  });
  const periods = workbook.find(sheet => sheet.sheet === 'Períodos').data;
  assert.equal(periods[1][6], 1500);
  assert.equal(periods[1][9], 'General histórico');
  assert.equal(workbook.find(sheet => sheet.sheet === 'Presupuestos por origen').data.length, 1);
});
test('legacy open editor proposes an explicit conversion using the legacy total, never period.general_budget', () => {
  const legacy = { ...data, budget_model: 'legacy_total', legacy_general_budget: '2000.00', general_budget: '2000.00', general_budget_remaining: '1050.00',
    period: { ...period, general_budget: '999999.00' },
    funding_budgets: rows.map(row => ({ ...row, budget_amount: null, remaining: null })) };
  globalThis.__misgastosFinancialFixture = legacy;
  const home = render(HomePage, {});
  assert.doesNotMatch(home, /Presupuestos por origen/);
  assert.match(home, /Gastos por origen/);
  assert.match(home, /2000,00/); // canonical summary total, regardless of stored period field
  const proposal = editableFundingBudgets(legacy);
  assert.equal(proposal[0].budget_amount, '2000.00');
  assert.equal(legacy.funding_budgets[0].budget_amount, null); // read model unchanged
  const draft = fundingBudgetDraft(proposal); draft.source = '500';
  const params = fundingBudgetParameters(period.id, period.version, proposal, draft);
  assert.equal(params.p_available_budget, '2000.00');
  assert.equal(draftBudgetTotal(proposal, draft), '2500.00');
  const html = render(FundingBudgetsForm, { summary: legacy, onMessage() {} });
  assert.match(html, /El presupuesto actual es general y cuenta todos los gastos/);
  assert.match(html, /value="2000,00"/);
  assert.doesNotMatch(html, /999999/);
});
// Optional local review artifact; no user data, generated only when requested.
if (process.env.MISGASTOS_PREVIEW_HTML) {
  globalThis.__misgastosFinancialFixture = data;
  writeFileSync(process.env.MISGASTOS_PREVIEW_HTML, `<!doctype html><html lang="es"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>MisGastos · Presupuestos</title><style>${readFileSync(new URL('../src/styles/global.css', import.meta.url), 'utf8')}main{max-width:780px;margin:auto;padding:20px}</style><main>${render(HomePage, {})}${render(FundingBudgetsForm, { summary: data, onMessage() {} })}</main><script>document.querySelectorAll('details').forEach(e=>e.open=true)</script></html>`);
}
