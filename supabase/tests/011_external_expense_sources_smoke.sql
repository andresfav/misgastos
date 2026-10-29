-- SOLO BASE DE PRUEBAS. Requiere 001–011; propietario/BYPASSRLS.
-- No ejecutar en Supabase de producción. Fixtures y mutaciones con ROLLBACK.
BEGIN ISOLATION LEVEL READ COMMITTED;
CREATE FUNCTION pg_temp.assert_true(ok boolean, message text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
 IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION '011: %', message; END IF;
END $$;
DO $smoke$
DECLARE
 a uuid := gen_random_uuid(); b uuid := gen_random_uuid();
 d date := (clock_timestamp() AT TIME ZONE 'Europe/Madrid')::date - 5;
 p uuid := gen_random_uuid(); c uuid := gen_random_uuid(); foreign_source uuid := gen_random_uuid();
 savings uuid := gen_random_uuid(); legacy uuid := gen_random_uuid();
 source jsonb; unused jsonb; normal jsonb; external jsonb; result jsonb; summary jsonb; usage jsonb;
 retry uuid := gen_random_uuid(); failed boolean;
BEGIN
 INSERT INTO auth.users(id) VALUES(a),(b);
 INSERT INTO public.user_settings(user_id,currency,timezone) VALUES(a,'EUR','Europe/Madrid'),(b,'EUR','Europe/Madrid');
 INSERT INTO public.budget_periods(id,user_id,mode,start_date,end_date,opening_balance,general_budget)
 VALUES(p,a,'custom',d,d+5,100,150);
 INSERT INTO public.categories(id,user_id,name) VALUES(c,a,'Restaurantes');
 INSERT INTO public.external_expense_sources(id,user_id,name) VALUES(foreign_source,b,'Privado');
 INSERT INTO public.savings_accounts(id,user_id,name,start_date,opening_balance) VALUES(savings,a,'Ahorro',d,0);
 -- 1: fila creada sin las nuevas columnas, como todos los datos de 001–010.
 INSERT INTO public.expenses(id,user_id,period_id,date,amount,category_id) VALUES(legacy,a,p,d,10,c);
 PERFORM pg_temp.assert_true((SELECT funding_type='available' AND external_source_id IS NULL FROM public.expenses WHERE id=legacy),'default de datos anteriores');
 PERFORM set_config('request.jwt.claim.sub',a::text,true);
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
 SET LOCAL ROLE authenticated;
 source := to_jsonb(public.create_external_expense_source('  Itaú  '));
 PERFORM pg_temp.assert_true(source->>'name'='Itaú','normalizar nombre');
 failed := false;
 BEGIN PERFORM public.create_external_expense_source(' itAÚ '); EXCEPTION WHEN unique_violation THEN failed:=true; END;
 PERFORM pg_temp.assert_true(failed,'nombres activos únicos normalizados');
 failed := false;
 BEGIN PERFORM public.create_external_expense_source(' '); EXCEPTION WHEN check_violation OR invalid_parameter_value THEN failed:=true; END;
 PERFORM pg_temp.assert_true(failed,'rechazar nombre vacío');
 source := to_jsonb(public.rename_external_expense_source((source->>'id')::uuid,'Itaú familiar',1));
 failed:=false;
 BEGIN PERFORM public.rename_external_expense_source((source->>'id')::uuid,'Obsoleto',1); EXCEPTION WHEN serialization_failure THEN failed:=true; END;
 PERFORM pg_temp.assert_true(failed,'expected_version catálogo');
 -- 2: firma publicada de 004 sigue funcionando y restando Disponible.
 normal := public.create_expense(d,20,c,NULL,NULL,NULL,NULL,false,gen_random_uuid());
 summary := public.get_current_financial_state();
 PERFORM pg_temp.assert_true((summary->>'available')::numeric=70 AND normal->>'funding_type'='available','gasto disponible y RPC antigua');
 PERFORM public.create_income(d,50,NULL,'Ingreso',gen_random_uuid());
 -- 3, 8: ingreso + externo no resta dos veces ni altera Disponible.
 external := public.create_expense_with_funding(d,40,c,'Externo',NULL,NULL,NULL,false,retry,'external',(source->>'id')::uuid);
 result := public.create_expense_with_funding(d,40,c,'Externo',NULL,NULL,NULL,false,retry,'external',(source->>'id')::uuid);
 PERFORM pg_temp.assert_true(result=external,'retry idempotente');
 failed:=false;
 BEGIN PERFORM public.create_expense_with_funding(d,41,c,'Externo',NULL,NULL,NULL,false,retry,'external',(source->>'id')::uuid); EXCEPTION WHEN invalid_parameter_value THEN failed:=true; END;
 PERFORM pg_temp.assert_true(failed,'idempotencia incluye importe y origen');
 summary := public.get_period_summary(p);
 -- 4, 5: total y presupuesto general incluyen ambos orígenes.
 PERFORM pg_temp.assert_true((summary->>'available')::numeric=120 AND (summary->>'expenses_total')::numeric=70 AND (summary->>'general_budget_spent')::numeric=70 AND (summary->>'general_budget_remaining')::numeric=80,'saldo / consumo / presupuesto general');
 -- 6, 7: categoría y desglose exacto, agrupado por fuente.
 PERFORM public.create_category_budget(p,c,150);
 usage := public.get_category_budget_usage(p)->0;
 PERFORM pg_temp.assert_true((usage->>'spent')::numeric=70 AND (usage->>'remaining')::numeric=80,'presupuesto categoría');
 PERFORM pg_temp.assert_true(EXISTS(SELECT 1 FROM jsonb_array_elements(usage->'funding_breakdown') x WHERE x->>'funding_type'='available' AND (x->>'amount')::numeric=30) AND EXISTS(SELECT 1 FROM jsonb_array_elements(summary->'expenses_funding_breakdown') x WHERE x->>'name'='Itaú familiar' AND (x->>'amount')::numeric=40),'desglose de categoría y período');
 -- 9, 10: cambiar de origen recalcula retrospectivamente.
 external := public.update_expense_with_funding((external->>'id')::uuid,1,d,40,c,'Externo',NULL,NULL,NULL,false,gen_random_uuid(),'available',NULL);
 PERFORM pg_temp.assert_true((public.get_current_financial_state()->>'available')::numeric=80,'external a available');
 external := public.update_expense_with_funding((external->>'id')::uuid,2,d,40,c,'Externo',NULL,NULL,NULL,false,gen_random_uuid(),'external',(source->>'id')::uuid);
 PERFORM pg_temp.assert_true((public.get_current_financial_state()->>'available')::numeric=120,'available a external');
 -- 11: cualquier gasto retroactivo que invalida una retirada posterior falla.
 PERFORM public.create_transfer(d+2,100,NULL,savings,NULL,gen_random_uuid());
 failed:=false;
 BEGIN
  PERFORM public.update_expense_with_funding((external->>'id')::uuid,3,d,40,c,NULL,NULL,NULL,NULL,false,gen_random_uuid(),'available',NULL);
 EXCEPTION WHEN invalid_parameter_value THEN failed:=true; END;
 PERFORM pg_temp.assert_true(failed AND (public.get_current_financial_state()->>'available')::numeric=20,'cambio de origen no invalida transferencia posterior');
 failed:=false;
 BEGIN
  PERFORM public.update_expense((normal->>'id')::uuid,1,d,80,c,NULL,NULL,NULL,NULL,false,gen_random_uuid());
 EXCEPTION WHEN invalid_parameter_value THEN failed:=true; END;
 PERFORM pg_temp.assert_true(failed,'API antigua sigue validando transferencias posteriores');
 failed:=false;
 BEGIN PERFORM public.create_expense_with_funding(d+6,1,c,NULL,NULL,NULL,NULL,false,gen_random_uuid(),'external',(source->>'id')::uuid); EXCEPTION WHEN invalid_parameter_value THEN failed:=true; END;
 PERFORM pg_temp.assert_true(failed,'fechas futuras rechazadas');
 -- 12: fuente ajena rechazada por RPC, no solo por FK.
 failed:=false;
 BEGIN PERFORM public.create_expense_with_funding(d,1,c,NULL,NULL,NULL,NULL,false,gen_random_uuid(),'external',foreign_source); EXCEPTION WHEN invalid_parameter_value THEN failed:=true; END;
 PERFORM pg_temp.assert_true(failed,'ownership fuente');
 -- 15: nunca usado se elimina físicamente.
 unused := to_jsonb(public.create_external_expense_source('Sin uso'));
 result := public.delete_external_expense_source((unused->>'id')::uuid,1);
 PERFORM pg_temp.assert_true(result->>'mode'='hard_deleted' AND NOT EXISTS(SELECT 1 FROM public.external_expense_sources WHERE id=(unused->>'id')::uuid),'hard delete');
 -- 16, 17: usado se desactiva; nombre permanece resoluble.
 result := public.delete_external_expense_source((source->>'id')::uuid,2);
 PERFORM pg_temp.assert_true(result->>'mode'='soft_deleted' AND EXISTS(SELECT 1 FROM public.external_expense_sources WHERE id=(source->>'id')::uuid AND NOT is_active),'soft delete');
 PERFORM pg_temp.assert_true(NOT EXISTS(SELECT 1 FROM jsonb_array_elements(public.get_catalog_management()->'external_sources') x WHERE x->>'id'=source->>'id'),'catálogo activo oculta borrados');
 -- 13: inactivo no se acepta en gastos nuevos.
 failed:=false;
 BEGIN PERFORM public.create_expense_with_funding(d,1,c,NULL,NULL,NULL,NULL,false,gen_random_uuid(),'external',(source->>'id')::uuid); EXCEPTION WHEN invalid_parameter_value THEN failed:=true; END;
 PERFORM pg_temp.assert_true(failed,'rechazar fuente inactiva en altas');
 -- 14: se conserva en edición histórica, incluida firma antigua sin origen.
 external := public.update_expense_with_funding((external->>'id')::uuid,3,d+1,40,c,'Histórico',NULL,NULL,NULL,false,gen_random_uuid(),'external',(source->>'id')::uuid);
 external := public.update_expense((external->>'id')::uuid,4,d+1,40,c,'Histórico editado',NULL,NULL,NULL,false,gen_random_uuid());
 PERFORM pg_temp.assert_true(external->>'funding_type'='external' AND external->>'external_source_id'=source->>'id','edición conserva fuente inactiva y API antigua');
 unused := to_jsonb(public.create_external_expense_source('ITAÚ FAMILIAR'));
 PERFORM pg_temp.assert_true(unused->>'id'<>source->>'id','nombre reutilizable tras soft delete');
 -- 20: exportación muestra origen histórico y saldo canónico.
 result := public.get_data_export();
 PERFORM pg_temp.assert_true(EXISTS(SELECT 1 FROM jsonb_array_elements(result->'movements') x WHERE x->>'id'=external->>'id' AND x->>'funding_type'='external' AND x->>'origin'='Itaú familiar' AND x->>'external_source'='Itaú familiar') AND EXISTS(SELECT 1 FROM jsonb_array_elements(result->'movements') x WHERE x->>'id'=normal->>'id' AND x->>'funding_type'='available' AND x->>'external_source' IS NULL),'export origen financiero e histórico');
 PERFORM pg_temp.assert_true(EXISTS(SELECT 1 FROM jsonb_array_elements(result->'balances') x WHERE x->>'balance_kind'='available' AND x->>'snapshot_kind'='closing' AND (x->>'amount')::numeric=20),'export saldo canónico');
 -- Borrar externo no altera saldo; borrar disponible aumenta saldo.
 PERFORM public.delete_expense((external->>'id')::uuid,5,gen_random_uuid());
 PERFORM pg_temp.assert_true((public.get_current_financial_state()->>'available')::numeric=20,'borrar externo');
 PERFORM public.delete_expense((normal->>'id')::uuid,1,gen_random_uuid());
 PERFORM pg_temp.assert_true((public.get_current_financial_state()->>'available')::numeric=40,'borrar disponible');
 -- 18: RLS y lecturas/mutaciones aíslan al otro usuario.
 PERFORM pg_temp.assert_true(NOT EXISTS(SELECT 1 FROM public.external_expense_sources WHERE id=foreign_source),'RLS select');
 failed:=false;
 BEGIN PERFORM public.delete_external_expense_source(foreign_source,1); EXCEPTION WHEN no_data_found THEN failed:=true; END;
 PERFORM pg_temp.assert_true(failed,'no borrar fuente ajena');
 PERFORM set_config('request.jwt.claim.sub',b::text,true);
 PERFORM pg_temp.assert_true(NOT EXISTS(SELECT 1 FROM public.expenses WHERE user_id=a) AND jsonb_array_length(public.get_catalog_management()->'external_sources')=1,'aislamiento inverso');
 PERFORM set_config('request.jwt.claim.sub',a::text,true);
 -- 19: reset transaccional y Auth intacto, con una dependencia externa viva.
 PERFORM public.create_expense_with_funding(d,5,c,NULL,NULL,NULL,NULL,false,gen_random_uuid(),'external',(unused->>'id')::uuid);
 PERFORM public.reset_financial_data('BORRAR');
 RESET ROLE;
 PERFORM pg_temp.assert_true(NOT EXISTS(SELECT 1 FROM public.external_expense_sources WHERE user_id=a) AND NOT EXISTS(SELECT 1 FROM public.expenses WHERE user_id=a) AND EXISTS(SELECT 1 FROM auth.users WHERE id=a) AND EXISTS(SELECT 1 FROM public.external_expense_sources WHERE id=foreign_source),'reset borra dependencias y conserva Auth / otro usuario');
 -- Las nuevas RPC no son accesibles a anon ni las privadas a authenticated.
 PERFORM pg_temp.assert_true(NOT EXISTS(SELECT 1 FROM pg_proc f JOIN pg_namespace n ON n.oid=f.pronamespace WHERE n.nspname='public' AND f.proname IN ('create_external_expense_source','rename_external_expense_source','delete_external_expense_source','create_expense_with_funding','update_expense_with_funding') AND (NOT f.prosecdef OR has_function_privilege('anon',f.oid,'EXECUTE') OR NOT has_function_privilege('authenticated',f.oid,'EXECUTE') OR ('search_path=""'=ANY(f.proconfig)) IS NOT TRUE)),'ACL y search_path RPC');
 PERFORM pg_temp.assert_true(NOT EXISTS(SELECT 1 FROM pg_proc f JOIN pg_namespace n ON n.oid=f.pronamespace WHERE n.nspname='private' AND f.proname IN ('create_expense_core','update_expense_core','expense_funding_reference','expense_funding_breakdown') AND has_function_privilege('authenticated',f.oid,'EXECUTE')),'helpers privados');
 RAISE NOTICE '011 smoke correcto (20 escenarios + compatibilidad, idempotencia y ACL)';
END;
$smoke$;
ROLLBACK;
