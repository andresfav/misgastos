-- SOLO BASE DE PRUEBAS. Requiere 001–012, propietario/BYPASSRLS.
-- No ejecutar contra producción. Todas las mutaciones se revierten con ROLLBACK.
BEGIN ISOLATION LEVEL READ COMMITTED;
CREATE FUNCTION pg_temp.assert_012(ok boolean,message text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
 IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION '012: %',message; END IF;
END $$;
DO $smoke$
DECLARE
 a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); h uuid:=gen_random_uuid();
 hp uuid:=gen_random_uuid(); hc uuid:=gen_random_uuid(); hs uuid:=gen_random_uuid();
 hz uuid:=gen_random_uuid(); hn uuid:=gen_random_uuid(); historical_snapshot jsonb;
 today date:=(clock_timestamp() AT TIME ZONE 'Europe/Madrid')::date;
 p uuid; new_p uuid; c uuid; source uuid; other_source uuid; budget_only uuid;
 foreign_source uuid:='ffffffff-ffff-ffff-ffff-ffffffffffff';
 savings uuid; current_version bigint; request_version bigint; request uuid; failed_request uuid:=gen_random_uuid();
 result jsonb; summary jsonb; original jsonb; usage jsonb; before_save jsonb; changed jsonb;
 export_data jsonb; saved_total numeric; failed boolean; bad jsonb;
BEGIN
 INSERT INTO auth.users(id) VALUES(a),(b),(h);
 -- Simular registros cerrados pre-012: el runner añade además un upgrade real.
 INSERT INTO public.user_settings(user_id,currency,timezone) VALUES(h,'EUR','Europe/Madrid');
 INSERT INTO public.categories(id,user_id,name) VALUES(hc,h,'Histórica');
 INSERT INTO public.external_expense_sources(id,user_id,name,is_active) VALUES(hs,h,'Externo histórico',false);
 INSERT INTO public.budget_periods(id,user_id,mode,start_date,end_date,status,
   opening_balance,closing_balance,closed_at,general_budget,budget_model)
 VALUES(hp,h,'custom',today-20,today-19,'closed',1000,900,clock_timestamp(),1500,'legacy_total'),
   (hz,h,'custom',today-18,today-17,'closed',900,900,clock_timestamp(),0,'legacy_total'),
   (hn,h,'custom',today-16,today-15,'closed',900,900,clock_timestamp(),NULL,'legacy_total');
 INSERT INTO public.expenses(user_id,period_id,date,amount,category_id,funding_type,external_source_id)
 VALUES(h,hp,today-20,100,hc,'available',NULL),(h,hp,today-20,650,hc,'external',hs);
 SELECT to_jsonb(x) INTO historical_snapshot FROM public.budget_periods x WHERE id=hp;
 INSERT INTO public.external_expense_sources(id,user_id,name) VALUES(foreign_source,b,'Ajeno');
 PERFORM set_config('request.jwt.claim.sub',a::text,true);
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
 SET LOCAL ROLE authenticated;
 PERFORM public.configure_user_settings('EUR','Europe/Madrid');
 result:=public.create_first_period('between_paydays',today-10,NULL,5000,gen_random_uuid(),2000);
 p:=(result->>'id')::uuid;
 SELECT id INTO c FROM public.create_category('Restaurantes');
 result:=public.create_savings_account('Ahorro',today-10,100,gen_random_uuid());
 savings:=(result->>'id')::uuid;
 -- 1: legacy Disponible y sin fuentes: idéntico total, sin desglose redundante.
 summary:=public.get_current_financial_state();
 PERFORM pg_temp.assert_012((summary->>'general_budget')::numeric=2000
   AND (summary->>'available')::numeric=5000 AND NOT (summary->>'has_external_sources')::boolean
   AND jsonb_array_length(summary->'funding_budgets')=1,'usuario solo Disponible');
 PERFORM public.set_general_budget(p,2100,1);
 PERFORM public.set_general_budget(p,2000,2);
 SELECT id INTO source FROM public.create_external_expense_source('Itaú');
 SELECT id INTO other_source FROM public.create_external_expense_source('Empresa');
 current_version:=3;
 -- 2: 2000+500=2500; no se toca el componente original al añadir uno externo.
 result:=public.set_funding_budgets(p,2000,jsonb_build_array(jsonb_build_object('external_source_id',source,'amount','500')),current_version,gen_random_uuid());
 current_version:=(result->>'version')::bigint;
 PERFORM pg_temp.assert_012((result->>'general_budget')::numeric=2500
   AND (SELECT general_budget=2000 FROM public.budget_periods WHERE id=p),'2000+500');
 -- 3: 2000+700=2700, después 1800+700=2500.
 result:=public.set_funding_budgets(p,2000,jsonb_build_array(jsonb_build_object('external_source_id',source,'amount',700)),current_version,gen_random_uuid());
 current_version:=(result->>'version')::bigint;
 PERFORM pg_temp.assert_012((result->>'general_budget')::numeric=2700,'modificar externo actualiza total');
 result:=public.set_funding_budgets(p,1800,'[]',current_version,gen_random_uuid());
 current_version:=(result->>'version')::bigint;
 PERFORM pg_temp.assert_012((result->>'general_budget')::numeric=2500,'modificar Disponible conserva externos omitidos');
 -- 7: múltiples fuentes, valores text/numeric y orden normalizados para retry.
 request:=gen_random_uuid();
 request_version:=current_version;
 original:=public.set_funding_budgets(p,1800,jsonb_build_array(
   jsonb_build_object('external_source_id',source,'amount',500),
   jsonb_build_object('external_source_id',other_source,'amount','300.00')),current_version,request);
 result:=public.set_funding_budgets(p,1800,jsonb_build_array(
   jsonb_build_object('external_source_id',other_source,'amount',300),
   jsonb_build_object('external_source_id',source,'amount','500.0')),current_version,request);
 PERFORM pg_temp.assert_012(result=original AND (result->>'general_budget')::numeric=2600,'múltiples orígenes/retry normalizado');
 current_version:=(result->>'version')::bigint;
 -- 4, 5, 6: consumo total y por origen; Disponible financiero permanece correcto.
 PERFORM public.create_expense(today-5,300,c,NULL,NULL,NULL,NULL,false,gen_random_uuid());
 PERFORM public.create_expense_with_funding(today-5,650,c,NULL,NULL,NULL,NULL,false,gen_random_uuid(),'external',source);
 PERFORM public.create_expense_with_funding(today-5,25,c,NULL,NULL,NULL,NULL,false,gen_random_uuid(),'external',other_source);
 PERFORM public.create_category_budget(p,c,1500);
 summary:=public.get_current_financial_state();
 usage:=public.get_category_budget_usage(p)->0;
 PERFORM pg_temp.assert_012((summary->>'available')::numeric=4700
   AND (summary->>'expenses_available_total')::numeric=300
   AND (summary->>'expenses_total')::numeric=975
   AND (summary->>'general_budget_spent')::numeric=975
   AND (summary->>'general_budget_remaining')::numeric=1625
   AND (usage->>'spent')::numeric=975 AND (usage->>'remaining')::numeric=525,'saldo y consumo de ambas dimensiones');
 PERFORM pg_temp.assert_012((SELECT sum((x->>'spent')::numeric) FROM jsonb_array_elements(summary->'funding_budgets') x)=975
   AND EXISTS(SELECT 1 FROM jsonb_array_elements(summary->'funding_budgets') x
     WHERE x->>'external_source_id'=source::text AND (x->>'spent')::numeric=650
     AND (x->>'budget_amount')::numeric=500 AND (x->>'remaining')::numeric=-150),'desglose exacto y exceso 650/500');
 PERFORM pg_temp.assert_012(EXISTS(SELECT 1 FROM jsonb_array_elements(summary->'savings_balances') x
   WHERE x->>'id'=savings::text AND (x->>'current_balance')::numeric=100),'presupuestos no alteran Ahorro');
 -- 11: un segundo editor con la misma versión no sobrescribe el primer guardado.
 failed:=false;
 BEGIN PERFORM public.set_funding_budgets(p,10,'[]',current_version-1,gen_random_uuid());
 EXCEPTION WHEN serialization_failure THEN failed:=true; END;
 PERFORM pg_temp.assert_012(failed,'versión obsoleta de segundo editor');
 failed:=false;
 BEGIN PERFORM public.set_general_budget(p,10,current_version-1);
 EXCEPTION WHEN serialization_failure THEN failed:=true; END;
 PERFORM pg_temp.assert_012(failed,'editor antiguo respeta versión del conjunto');
 failed:=false;
 BEGIN PERFORM public.set_funding_budgets(p,11,'[]',current_version,request);
 EXCEPTION WHEN invalid_parameter_value THEN failed:=true; END;
 PERFORM pg_temp.assert_012(failed,'clave de idempotencia no se reutiliza para otra petición');
 -- El origen válido se escribe antes del ajeno (UUID ffff último); todo revierte.
 before_save:=public.get_period_summary(p);
 failed:=false;
 BEGIN PERFORM public.set_funding_budgets(p,1,jsonb_build_array(
   jsonb_build_object('external_source_id',source,'amount',1),
   jsonb_build_object('external_source_id',foreign_source,'amount',1)),current_version,failed_request);
 EXCEPTION WHEN invalid_parameter_value THEN failed:=true; END;
 changed:=public.get_period_summary(p);
 PERFORM pg_temp.assert_012(failed AND before_save=changed,'atomicidad: fallo parcial no cambia ningún presupuesto ni versión');
 -- Errores de estructura, negativos, decimales adicionales y duplicados.
 FOR bad IN SELECT value FROM jsonb_array_elements(jsonb_build_array(
   'null'::jsonb,
   jsonb_build_array(jsonb_build_object('external_source_id',source,'amount',-1)),
   jsonb_build_array(jsonb_build_object('external_source_id',source,'amount',1.001)),
   jsonb_build_array(jsonb_build_object('external_source_id',source)),
   jsonb_build_array(jsonb_build_object('external_source_id',source,'amount',1),jsonb_build_object('external_source_id',source,'amount',2))
 )) LOOP
   failed:=false;
   BEGIN PERFORM public.set_funding_budgets(p,1800,bad,current_version,gen_random_uuid());
   EXCEPTION WHEN invalid_parameter_value THEN failed:=true; END;
   PERFORM pg_temp.assert_012(failed,'rechazar payload inválido');
 END LOOP;
 -- Sin asignar y cero son distintos; no se suma ninguna categoría al total.
 result:=public.set_funding_budgets(p,NULL,jsonb_build_array(
   jsonb_build_object('external_source_id',source,'amount',NULL),
   jsonb_build_object('external_source_id',other_source,'amount',NULL)),current_version,gen_random_uuid());
 current_version:=(result->>'version')::bigint;
 PERFORM pg_temp.assert_012(result->>'general_budget' IS NULL,'ninguna asignación: total null');
 result:=public.set_funding_budgets(p,0,'[]',current_version,gen_random_uuid());
 current_version:=(result->>'version')::bigint;
 PERFORM pg_temp.assert_012((result->>'general_budget')::numeric=0,'cero es presupuesto configurado');
 result:=public.set_funding_budgets(p,0,jsonb_build_array(jsonb_build_object('external_source_id',other_source,'amount',0)),current_version,gen_random_uuid());
 current_version:=(result->>'version')::bigint;
 failed:=false;
 BEGIN PERFORM public.set_general_budget(p,2600,current_version);
 EXCEPTION WHEN invalid_parameter_value THEN failed:=true; END;
 PERFORM pg_temp.assert_012(failed AND (public.get_period_summary(p)->>'general_budget')::numeric=0,'RPC antigua bloqueada incluso con asignación externa cero');
 result:=public.set_funding_budgets(p,0,jsonb_build_array(jsonb_build_object('external_source_id',other_source,'amount',NULL)),current_version,gen_random_uuid());
 current_version:=(result->>'version')::bigint;
 -- Sin asignaciones externas vuelve a ser inequívoca: sigue funcionando.
 PERFORM public.set_general_budget(p,100,current_version);
 current_version:=current_version+1;
 PERFORM pg_temp.assert_012((public.get_period_summary(p)->>'general_budget')::numeric=100,'compatibilidad sin asignaciones externas');
 result:=public.set_funding_budgets(p,2000,jsonb_build_array(jsonb_build_object('external_source_id',source,'amount',500)),current_version,gen_random_uuid());
 current_version:=(result->>'version')::bigint;
 -- La API antigua no sabe si el importe es total o componente. Se rechaza
 -- íntegramente cuando hay asignaciones externas, incluso con versión vigente.
 before_save:=public.get_period_summary(p);
 failed:=false;
 BEGIN PERFORM public.set_general_budget(p,2600,current_version);
 EXCEPTION WHEN invalid_parameter_value THEN failed:=true; END;
 PERFORM pg_temp.assert_012(failed AND public.get_period_summary(p)=before_save
   AND (SELECT general_budget=2000 AND version=current_version FROM public.budget_periods WHERE id=p),
   'RPC antigua no convierte 2000+500 en 2600+500=3100');
 failed:=false;
 BEGIN PERFORM public.set_general_budget(p,NULL,current_version);
 EXCEPTION WHEN invalid_parameter_value THEN failed:=true; END;
 PERFORM pg_temp.assert_012(failed AND public.get_period_summary(p)=before_save,'RPC antigua no borra un componente oculto');
 -- El editor nuevo sí puede cambiar Disponible a 1800, explícitamente.
 result:=public.set_funding_budgets(p,1800,'[]',current_version,gen_random_uuid());
 current_version:=(result->>'version')::bigint;
 PERFORM pg_temp.assert_012((result->>'general_budget')::numeric=2300,'editor explícito conserva externos');
 -- 8: una fuente usada únicamente en presupuesto se borra lógicamente.
 SELECT id INTO budget_only FROM public.create_external_expense_source('Solo presupuesto');
 result:=public.set_funding_budgets(p,1800,jsonb_build_array(jsonb_build_object('external_source_id',budget_only,'amount',0)),current_version,gen_random_uuid());
 current_version:=(result->>'version')::bigint;
 PERFORM pg_temp.assert_012(EXISTS(SELECT 1 FROM jsonb_array_elements(public.get_catalog_management()->'external_sources') x WHERE x->>'id'=budget_only::text AND (x->>'has_history')::boolean),'uso en presupuesto cuenta como historial');
 result:=public.delete_external_expense_source(budget_only,1);
 PERFORM pg_temp.assert_012(result->>'mode'='soft_deleted','borrado conserva asignaciones');
 result:=public.set_funding_budgets(p,1800,jsonb_build_array(jsonb_build_object('external_source_id',budget_only,'amount',100)),current_version,gen_random_uuid());
 current_version:=(result->>'version')::bigint;
 PERFORM public.delete_external_expense_source(source,1);
 summary:=public.get_period_summary(p);
 PERFORM pg_temp.assert_012(EXISTS(SELECT 1 FROM jsonb_array_elements(summary->'funding_budgets') x WHERE x->>'external_source_id'=source::text AND x->>'name'='Itaú' AND NOT (x->>'is_active')::boolean),'nombre histórico y presupuesto de fuente inactiva');
 -- 9: cierre conserva todas las asignaciones; nuevo período no copia ninguna.
 saved_total:=(summary->>'general_budget')::numeric;
 result:=public.advance_period(p,current_version,'between_paydays',today,NULL,gen_random_uuid());
 new_p:=(result->'opened_period'->>'id')::uuid;
 summary:=public.get_period_summary(p);
 PERFORM pg_temp.assert_012((summary->>'general_budget')::numeric=saved_total AND (summary->'period'->>'status')='closed','presupuesto cerrado conservado');
 summary:=public.get_current_financial_state();
 PERFORM pg_temp.assert_012(summary->>'general_budget' IS NULL
   AND (summary->>'available')::numeric=4700
   AND (summary->>'expenses_available_total')::numeric=0
   AND (summary->>'has_external_sources')::boolean,'nuevo período sin presupuestos conserva arrastre e historial externo');
 failed:=false;
 BEGIN PERFORM public.set_funding_budgets(p,1,'[]',current_version+1,gen_random_uuid());
 EXCEPTION WHEN no_data_found THEN failed:=true; END;
 PERFORM pg_temp.assert_012(failed,'período cerrado inmutable');
 failed:=false;
 BEGIN PERFORM public.set_funding_budgets(new_p,1,jsonb_build_array(jsonb_build_object('external_source_id',source,'amount',1)),1,gen_random_uuid());
 EXCEPTION WHEN invalid_parameter_value THEN failed:=true; END;
 PERFORM pg_temp.assert_012(failed,'no crear asignación nueva a fuente inactiva histórica');
 -- Un retry de un guardado confirmado devuelve el mismo recibo tras el cierre,
 -- sin reabrir el período ni restaurar presupuestos que luego cambiaron.
 result:=public.set_funding_budgets(p,1800,jsonb_build_array(
   jsonb_build_object('external_source_id',source,'amount',500),
   jsonb_build_object('external_source_id',other_source,'amount',300)),request_version,request);
 PERFORM pg_temp.assert_012(result=original AND (public.get_period_summary(p)->>'general_budget')::numeric=saved_total,'retry tras cierre conserva recibo e historia');
 -- 10: RLS, permisos y aislamiento en ambos sentidos.
 failed:=false;
 BEGIN DELETE FROM public.period_external_source_budgets WHERE period_id=p;
 EXCEPTION WHEN insufficient_privilege THEN failed:=true; END;
 PERFORM pg_temp.assert_012(failed,'DML directo bloqueado');
 PERFORM set_config('request.jwt.claim.sub',b::text,true);
 PERFORM pg_temp.assert_012(NOT EXISTS(SELECT 1 FROM public.period_external_source_budgets),'RLS usuario B');
 failed:=false;
 BEGIN PERFORM public.set_funding_budgets(new_p,1,'[]',1,gen_random_uuid());
 EXCEPTION WHEN no_data_found THEN failed:=true; END;
 PERFORM pg_temp.assert_012(failed,'no mutar período ajeno');
 PERFORM set_config('request.jwt.claim.sub',a::text,true);
 -- 12: exportación conserva total, partes, categorías y datos históricos.
 export_data:=public.get_data_export();
 PERFORM pg_temp.assert_012(EXISTS(SELECT 1 FROM jsonb_array_elements(export_data->'periods') x
   WHERE x->>'id'=p::text AND (x->>'general_budget')::numeric=saved_total AND (x->>'available_budget')::numeric=1800)
   AND (SELECT sum((x->>'amount')::numeric) FROM jsonb_array_elements(export_data->'funding_budgets') x WHERE x->>'period_id'=p::text)=saved_total
   AND EXISTS(SELECT 1 FROM jsonb_array_elements(export_data->'funding_budgets') x WHERE x->>'external_source_id'=source::text AND x->>'name'='Itaú' AND x->>'period_status'='closed')
   AND (export_data->'budgets'->0->>'amount')::numeric=1500,'exportación de total y todas sus partes');
 RESET ROLE;
 PERFORM pg_temp.assert_012(NOT EXISTS(SELECT 1 FROM public.financial_operations WHERE idempotency_key=failed_request),'error no deja recibo');
 SET LOCAL ROLE authenticated;
 PERFORM public.reset_financial_data('BORRAR');
 RESET ROLE;
 PERFORM pg_temp.assert_012(NOT EXISTS(SELECT 1 FROM public.period_external_source_budgets WHERE user_id=a)
   AND NOT EXISTS(SELECT 1 FROM public.budget_periods WHERE user_id=a)
   AND EXISTS(SELECT 1 FROM auth.users WHERE id=a)
   AND EXISTS(SELECT 1 FROM public.external_expense_sources WHERE id=foreign_source),'reset y aislamiento');
 PERFORM pg_temp.assert_012(NOT EXISTS(SELECT 1 FROM public.financial_operations WHERE idempotency_key=failed_request),'error no deja recibo');
 PERFORM pg_temp.assert_012(NOT has_function_privilege('anon','public.set_funding_budgets(uuid,numeric,jsonb,bigint,uuid)','EXECUTE')
   AND has_function_privilege('authenticated','public.set_funding_budgets(uuid,numeric,jsonb,bigint,uuid)','EXECUTE'),'ACL API');
 PERFORM pg_temp.assert_012((SELECT prosecdef AND ('search_path=""'=ANY(proconfig)) FROM pg_proc WHERE oid='public.set_funding_budgets(uuid,numeric,jsonb,bigint,uuid)'::regprocedure),'search_path y SECURITY DEFINER');
 PERFORM pg_temp.assert_012(NOT EXISTS(SELECT 1 FROM pg_proc f JOIN pg_namespace n ON n.oid=f.pronamespace WHERE n.nspname='private' AND f.proname IN ('period_funding_allocations','period_budget_total','period_funding_usage_at','has_external_expense_sources') AND has_function_privilege('authenticated',f.oid,'EXECUTE')),'helpers privados');
 -- Regresión: el límite general histórico incluye ambos tipos de gasto.
 PERFORM set_config('request.jwt.claim.sub',h::text,true);
 SET LOCAL ROLE authenticated;
 summary:=public.get_period_summary(hp);
 PERFORM pg_temp.assert_012(summary->>'budget_model'='legacy_total'
   AND (summary->>'general_budget')::numeric=1500
   AND (summary->>'legacy_general_budget')::numeric=1500
   AND (summary->>'expenses_total')::numeric=750
   AND (summary->>'general_budget_remaining')::numeric=750
   AND (summary->>'available')::numeric=900
   AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(summary->'funding_budgets') x WHERE x->>'budget_amount' IS NOT NULL),
   'histórico externo conserva límite general, nunca límite de Disponible');
 PERFORM pg_temp.assert_012((public.get_period_summary(hz)->>'general_budget')::numeric=0
   AND public.get_period_summary(hn)->>'general_budget' IS NULL,'históricos cero y sin presupuesto');
 export_data:=public.get_data_export();
 PERFORM pg_temp.assert_012(EXISTS(SELECT 1 FROM jsonb_array_elements(export_data->'periods') x
   WHERE x->>'id'=hp::text AND x->>'budget_model'='legacy_total'
   AND (x->>'general_budget')::numeric=1500 AND x->>'available_budget' IS NULL)
   AND export_data->'funding_budgets'='[]'::jsonb,'exportación histórica sin asignaciones ficticias');
 failed:=false;
 BEGIN PERFORM public.set_funding_budgets(hp,1500,'[]',1,gen_random_uuid());
 EXCEPTION WHEN no_data_found THEN failed:=true; END;
 PERFORM pg_temp.assert_012(failed AND (SELECT to_jsonb(x)=historical_snapshot FROM public.budget_periods x WHERE id=hp),
   'cerrado legacy no convertible y fila almacenada intacta');
 RESET ROLE;
 RAISE NOTICE '012 smoke correcto: escenarios de origen, compatibilidad e históricos';
END;
$smoke$;
ROLLBACK;
