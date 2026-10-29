// Pure frontend contracts; compile into a disposable directory, with no network client.
// Run: node --test tests/external-expenses.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const temp = mkdtempSync(join(tmpdir(), 'misgastos-contracts-'));
writeFileSync(join(temp, 'package.json'), '{"type":"module"}');
for (const name of ['money', 'movementForm', 'movementHistory', 'dataExport']) {
  const code = stripTypeScriptTypes(readFileSync(new URL(`../src/lib/${name}.ts`, import.meta.url), 'utf8'))
    .replace(/from "\.\/(\w+)"/g, 'from "./$1.js"').replace('from "../types/movements"', 'from "./movementLabels.js"');
  writeFileSync(join(temp, `${name}.js`), code);
}
writeFileSync(join(temp, 'movementLabels.js'), 'export const movementLabels={expense:"Gasto",income:"Ingreso",transfer:"Transferencia"};');
writeFileSync(join(temp, 'supabase.js'), 'export function client(){throw new Error("No network in contract tests")}');
const { movementDraft, movementParameters } = await import(pathToFileURL(join(temp, 'movementForm.js')));
const { expenseOrigin, filterHistory } = await import(pathToFileURL(join(temp, 'movementHistory.js')));
const { exportHistoryRows, serializeCsv } = await import(pathToFileURL(join(temp, 'dataExport.js')));
const refs = { categories: [{ id: 'c', is_active: true }], methods: [{ id: 'm', is_active: true }], accounts: [],
  periods: [{ id: 'p', start_date: '2026-01-01', end_date: null, status: 'open' }],
  external_sources: [{ id: 's', name: 'Itaú', is_active: true }, { id: 'old', name: 'Histórico', is_active: false }] };
const normal = { id: 'e', version: 1, kind: 'expense', period_id: 'p', date: '2026-01-02', amount: '50.00', category_id: 'c', payment_method_id: 'm', funding_type: 'available', external_source_id: null };
const external = { ...normal, id: 'x', funding_type: 'external', external_source_id: 's' };
const parameters = (draft, row) => movementParameters('expense', draft, '2026-01-03', refs, row);
test('new expenses default to Disponible; payment method is independent', () => {
  const draft = { ...movementDraft('2026-01-02'), amount: '50', category: 'c', method: 'm' };
  assert.equal(parameters(draft).p_funding_type, 'available');
  assert.equal(parameters(draft).p_external_source_id, null);
  const funded = parameters({ ...draft, funding: 'external', externalSource: 's' });
  assert.equal(funded.p_payment_method_id, 'm');
  assert.equal(funded.p_external_source_id, 's');
});
test('external source is required and must be active or the original historical source', () => {
  const draft = movementDraft('2026-01-02', external);
  assert.throws(() => parameters({ ...draft, externalSource: '' }));
  assert.throws(() => parameters({ ...draft, externalSource: 'old' }));
  const historical = { ...external, external_source_id: 'old' };
  assert.equal(parameters(movementDraft('2026-01-02', historical), historical).p_external_source_id, 'old');
  assert.equal(parameters({ ...draft, funding: 'available' }, external).p_external_source_id, null);
});
test('editing retains origin and version and prevents future dates', () => {
  const result = parameters(movementDraft('2026-01-02', external), external);
  assert.equal(result.p_funding_type, 'external');
  assert.equal(result.p_expected_version, 1);
  assert.throws(() => parameters({ ...movementDraft('2026-01-02', external), date: '2026-01-04' }, external));
});
test('history filters by Disponible, external, source and searchable source name', () => {
  const filters = { category: '', method: '', funding: '', origin: '', destination: '', from: '', until: '', search: '' };
  for (const funding of ['available', 'external', 's']) {
    const rows = filterHistory([normal, external], 'expense', { ...filters, funding }, refs);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].id, funding === 'available' ? 'e' : 'x');
  }
  assert.equal(expenseOrigin(external, refs), 'Itaú');
  assert.equal(filterHistory([normal, external], 'expense', { ...filters, search: 'itau' }, refs)[0].id, 'x');
});
const exportData = { range: { start_date: '2026-01-01' }, settings: { currency: 'EUR' }, savings_accounts: [],
  movements: [normal, external].map(row => ({ ...row, origin: row.funding_type === 'external' ? 'Itaú' : 'Disponible', external_source: row.funding_type === 'external' ? 'Itaú' : null, destination: 'Exterior', period_start: '2026-01-01', period_status: 'open' })),
  balances: [{ date: '2026-01-03', snapshot_kind: 'closing', balance_kind: 'available', account_name: 'Disponible', amount: '100.00', period_status: 'open' }] };
test('CSV and history XLSX share financial source columns without modifying amounts or balances', () => {
  const rows = exportHistoryRows(exportData, 'all');
  assert.equal(rows[0].origen_gasto, 'Disponible');
  assert.equal(rows[0].origen_externo, '');
  assert.equal(rows[1].origen_gasto, 'Externo');
  assert.equal(rows[1].origen_externo, 'Itaú');
  assert.equal(rows[2].importe, '100.00');
  assert.equal(rows[2].origen_gasto, '');
  assert.match(serializeCsv(rows), /origen_gasto;origen_externo/);
  assert.match(serializeCsv(rows), /Externo;Itaú/);
});
process.on('exit', () => rmSync(temp, { recursive: true, force: true }));
