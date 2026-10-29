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
    } else {
      await db.exec(fs.readFileSync(join(root, 'supabase/migrations', file), 'utf8'));
    }
    console.log('PASS migration', file);
  }
  // No concurrency tests: one in-memory PostgreSQL connection, locking unchanged.
  const files = fs.readdirSync(join(root, 'supabase/tests')).filter(f => /^(004|005|006|007|008|009|010|011)_.*smoke\.sql$/.test(f)).sort();
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
