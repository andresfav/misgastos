// Disposable PostgreSQL (PGlite), no Supabase URL, credentials or network access.
// Install PGlite outside this repository; see docs/EXTERNAL_EXPENSES_TESTING.md.
import fs from 'node:fs';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { join, resolve } from 'node:path';
const packageRoot = process.env.PGLITE_PACKAGE_ROOT;
if (!packageRoot) throw new Error('Set PGLITE_PACKAGE_ROOT to the installed @electric-sql/pglite directory');
const { PGlite } = await import(pathToFileURL(join(packageRoot, 'dist/index.js')));
const { btree_gist } = await import(pathToFileURL(join(packageRoot, 'dist/contrib/btree_gist.js')));
const root = fileURLToPath(new URL('../', import.meta.url));
const db = new PGlite({ extensions: { btree_gist } });
try {
  // Minimal Auth harness. The real Supabase Auth integration still requires staging QA.
  await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE SCHEMA auth;
    CREATE TABLE auth.users(id uuid PRIMARY KEY);
    CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
      SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
    GRANT USAGE ON SCHEMA auth TO anon, authenticated;
    GRANT EXECUTE ON FUNCTION auth.uid() TO anon,authenticated;`);
  for (const file of fs.readdirSync(join(root, 'supabase/migrations')).filter(f => f.endsWith('.sql')).sort()) {
    // A real pre-011 expense and recorded idempotent operation survive the upgrade.
    if (file.startsWith('011_')) {
      await db.exec(`INSERT INTO auth.users(id) VALUES('11111111-1111-1111-1111-111111111111');
        SELECT set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
        SELECT public.configure_user_settings('EUR','Europe/Madrid');
        SELECT public.create_first_period('between_paydays',current_date-1,NULL,100,'22222222-2222-2222-2222-222222222222');
        SELECT public.create_category('Anterior a 011');`);
      const { rows } = await db.query(`SELECT id FROM public.categories WHERE name='Anterior a 011'`);
      const category = rows[0].id;
      const call = `SELECT public.create_expense(current_date-1,25,'${category}',NULL,NULL,NULL,NULL,false,'33333333-3333-3333-3333-333333333333') AS result`;
      const before = (await db.query(call)).rows[0].result;
      await db.exec(fs.readFileSync(join(root, 'supabase/migrations', file), 'utf8'));
      const after = (await db.query(call)).rows[0].result;
      if (JSON.stringify(before) !== JSON.stringify(after)) throw new Error('Pre-011 idempotency changed');
      const check = await db.query(`SELECT funding_type, external_source_id FROM public.expenses WHERE id='${before.id}'`);
      if (check.rows[0].funding_type !== 'available' || check.rows[0].external_source_id !== null) throw new Error('Historical expense backfill failed');
      const summary = (await db.query('SELECT public.get_current_financial_state() AS state')).rows[0].state;
      if (Number(summary.available) !== 75) throw new Error('Historical Disponible changed');
      await db.exec(`SELECT public.reset_financial_data('BORRAR'); DELETE FROM auth.users WHERE id='11111111-1111-1111-1111-111111111111'; RESET ALL;`);
      console.log('PASS upgrade 010 → 011: backfill, Disponible and old recorded retry');
    } else if (file.startsWith('012_')) {
      // Upgrade with real open/closed budgets and external expenses from 011.
      const user = '44444444-4444-4444-4444-444444444444';
      await db.exec(`INSERT INTO auth.users(id) VALUES('${user}');
        SELECT set_config('request.jwt.claim.sub','${user}',false);
        SELECT public.configure_user_settings('EUR','Europe/Madrid');`);
      const closed = (await db.query(`SELECT public.create_first_period('between_paydays',current_date-5,NULL,1000,gen_random_uuid(),1500) AS result`)).rows[0].result;
      const category = (await db.query(`SELECT id FROM public.create_category('Antes de 012')`)).rows[0].id;
      const source = (await db.query(`SELECT id FROM public.create_external_expense_source('Externo antes de 012')`)).rows[0].id;
      await db.query(`SELECT public.create_expense_with_funding(current_date-4,50,'${category}',NULL,NULL,NULL,NULL,false,gen_random_uuid(),'external','${source}')`);
      await db.query(`SELECT public.create_expense(current_date-4,10,'${category}',NULL,NULL,NULL,NULL,false,gen_random_uuid())`);
      const opened = (await db.query(`SELECT public.advance_period('${closed.id}',1,'between_paydays',current_date-2,NULL,gen_random_uuid(),2000) AS result`)).rows[0].result.opened_period;
      await db.query(`SELECT public.create_expense_with_funding(current_date-1,50,'${category}',NULL,NULL,NULL,NULL,false,gen_random_uuid(),'external','${source}')`);
      const snapshot = async () => (await db.query(`SELECT jsonb_build_object(
        'periods',(SELECT jsonb_agg(to_jsonb(p) - 'budget_model' ORDER BY p.id) FROM public.budget_periods p WHERE user_id='${user}'),
        'expenses',(SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) FROM public.expenses e WHERE user_id='${user}'),
        'operations',(SELECT jsonb_agg(to_jsonb(o) ORDER BY o.id) FROM public.financial_operations o WHERE user_id='${user}')
      ) AS state`)).rows[0].state;
      const before = await snapshot();
      await db.exec(fs.readFileSync(join(root, 'supabase/migrations', file), 'utf8'));
      if (JSON.stringify(before) !== JSON.stringify(await snapshot())) throw new Error('012 changed historical rows');
      const summary = (await db.query('SELECT public.get_current_financial_state() AS state')).rows[0].state;
      if (Number(summary.general_budget) !== 2000 || Number(summary.available) !== 990) throw new Error('012 changed historical budget or balance');
      const availableBudget = summary.funding_budgets.find(row => row.funding_type === 'available');
      if (summary.budget_model !== 'legacy_total' || summary.legacy_general_budget !== '2000.00' || availableBudget.budget_amount !== null || summary.funding_budgets.some(row => row.budget_amount !== null)) throw new Error('012 reinterpreted a legacy total as an origin limit');
      const historical = (await db.query(`SELECT public.get_period_summary('${closed.id}') AS state`)).rows[0].state;
      if (historical.budget_model !== 'legacy_total' || Number(historical.general_budget) !== 1500 || Number(historical.expenses_total) !== 60 || Number(historical.general_budget_remaining) !== 1440 || historical.funding_budgets.some(row => row.budget_amount !== null)) throw new Error('012 changed historical budget semantics with external expenses');
      let exported = (await db.query('SELECT public.get_data_export() AS data')).rows[0].data;
      const historicalExport = exported.periods.find(row => row.id === closed.id);
      if (historicalExport.general_budget !== '1500.00' || historicalExport.available_budget !== null || historicalExport.budget_model !== 'legacy_total' || exported.funding_budgets.some(row => row.period_id === closed.id)) throw new Error('012 invented historical Disponible allocations in export');
      // An old editor can still edit the single legacy total without converting it.
      await db.query(`SELECT public.set_general_budget('${opened.id}',2100,1)`);
      await db.query(`SELECT public.set_general_budget('${opened.id}',2000,2)`);
      try {
        await db.query(`SELECT public.set_funding_budgets('${opened.id}',1800,'[{"external_source_id":"55555555-5555-5555-5555-555555555555","amount":"500"}]',3,gen_random_uuid())`);
        throw new Error('Invalid conversion unexpectedly succeeded');
      } catch (error) { if (error.code !== '22023') throw error; }
      const notConverted = (await db.query('SELECT public.get_current_financial_state() AS state')).rows[0].state;
      if (notConverted.budget_model !== 'legacy_total' || Number(notConverted.general_budget) !== 2000 || notConverted.current_period.version !== 3) throw new Error('Failed save changed legacy semantics or values');
      const changed = (await db.query(`SELECT public.set_funding_budgets('${opened.id}',2000,'[{"external_source_id":"${source}","amount":"500"}]',3,gen_random_uuid()) AS result`)).rows[0].result;
      if (changed.general_budget !== '2500.00') throw new Error('012 did not preserve original 2000 when adding 500');
      if (changed.budget_model !== 'by_origin') throw new Error('Explicit conversion did not switch budget model');
      try {
        await db.query(`SELECT public.set_general_budget('${opened.id}',2600,${changed.version})`);
        throw new Error('Old editor silently overwrote a distributed budget');
      } catch (error) { if (error.code !== '22023') throw error; }
      const unchanged = (await db.query('SELECT public.get_current_financial_state() AS state')).rows[0].state;
      if (Number(unchanged.general_budget) !== 2500 || unchanged.current_period.version !== changed.version) throw new Error('Rejected old edit changed total or version');
      // The legacy closed period remains general even after converting the open one.
      exported = (await db.query('SELECT public.get_data_export() AS data')).rows[0].data;
      if (exported.funding_budgets.some(row => row.period_id === closed.id)) throw new Error('Conversion leaked into historical allocations');
      await db.exec(`SELECT public.reset_financial_data('BORRAR'); DELETE FROM auth.users WHERE id='${user}'; RESET ALL;`);
      console.log('PASS upgrade 011 → 012: legacy closed/open totals preserved, explicit conversion and old-client overwrite rejected');
    } else {
      await db.exec(fs.readFileSync(join(root, 'supabase/migrations', file), 'utf8'));
    }
    console.log('PASS migration', file);
  }
  // No concurrency tests: one in-memory PostgreSQL connection, locking unchanged.
  const files = fs.readdirSync(join(root, 'supabase/tests')).filter(f => /^(004|005|006|007|008|009|010|011|012)_.*smoke\.sql$/.test(f)).sort();
  for (const file of files) {
    await db.exec(fs.readFileSync(resolve(root, 'supabase/tests', file), 'utf8'));
    console.log('PASS smoke', file);
  }
} catch (error) {
  console.error('FAIL:', error.message, error.where ?? '');
  process.exitCode = 1;
} finally {
  await db.close();
}
