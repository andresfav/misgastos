-- Smoke 010 para 001–010. SOLO PARA BASE DE PRUEBAS, como propietario/BYPASSRLS.
-- No ejecutarlo en producción. Todos los fixtures se revierten al final.
BEGIN ISOLATION LEVEL READ COMMITTED;

DO $smoke$
DECLARE
    user_a uuid := gen_random_uuid();
    user_b uuid := gen_random_uuid();
    user_empty uuid := gen_random_uuid();
    today date := (pg_catalog.clock_timestamp() AT TIME ZONE 'Pacific/Kiritimati')::date;
    d date := today - 3;
    period_closed uuid := gen_random_uuid();
    period_open uuid := gen_random_uuid();
    period_b uuid := gen_random_uuid();
    category_a uuid := gen_random_uuid();
    category_b uuid := gen_random_uuid();
    method_a uuid := gen_random_uuid();
    savings_a uuid := gen_random_uuid();
    savings_b uuid := gen_random_uuid();
    savings_late uuid := gen_random_uuid();
    result jsonb;
    ranged jsonb;
    row jsonb;
    failed boolean;
BEGIN
    INSERT INTO auth.users(id) VALUES (user_a),(user_b),(user_empty);
    INSERT INTO public.user_settings(user_id,currency,timezone,currency_locked_at)
    VALUES (user_a,'EUR','Pacific/Kiritimati',pg_catalog.clock_timestamp()),
           (user_b,'USD','Pacific/Kiritimati',pg_catalog.clock_timestamp()),
           (user_empty,'EUR','Pacific/Kiritimati',NULL);

    INSERT INTO public.budget_periods(id,user_id,mode,start_date,end_date,status,
        opening_balance,closing_balance,closed_at)
    VALUES (period_closed,user_a,'custom',d,d+1,'closed',100,109,pg_catalog.clock_timestamp()),
           (period_open,user_a,'custom',d+2,today,'open',109,NULL,NULL),
           (period_b,user_b,'custom',d,today,'open',999,NULL,NULL);
    INSERT INTO public.categories(id,user_id,name,is_active)
    VALUES (category_a,user_a,'Categoría histórica',false),(category_b,user_b,'Categoría ajena',true);
    INSERT INTO public.payment_methods(id,user_id,name,is_active)
    VALUES (method_a,user_a,'Método histórico',false);
    INSERT INTO public.savings_accounts(id,user_id,name,start_date,opening_balance,is_active)
    VALUES (savings_a,user_a,'Ahorro A',d,50,true),
           (savings_b,user_a,'Ahorro B',d,7,false),
           (savings_late,user_a,'Ahorro nuevo',d+2,12,true);

    INSERT INTO public.incomes(user_id,period_id,date,amount,savings_account_id,description)
    VALUES (user_a,period_closed,d,20,NULL,'Ingreso disponible'),
           (user_a,period_closed,d,10,savings_a,'Ingreso directo a ahorro'),
           (user_a,period_open,d+2,900719925474099.91,NULL,'Importe exacto'),
           (user_b,period_b,d,77,NULL,'No revelar');
    INSERT INTO public.expenses(user_id,period_id,date,amount,category_id,payment_method_id,merchant,note)
    VALUES (user_a,period_closed,d,5,category_a,method_a,'Comercio, con coma',E'Nota\nmultilínea'),
           (user_b,period_b,d,1,category_b,NULL,'Ajeno',NULL);
    INSERT INTO public.transfers(user_id,period_id,date,amount,from_savings_account_id,to_savings_account_id,description)
    VALUES (user_a,period_closed,d,8,NULL,savings_a,'Disponible a ahorro'),
           (user_a,period_closed,d,2,savings_a,NULL,'Ahorro a disponible'),
           (user_a,period_closed,d,3,savings_a,savings_b,'Entre ahorros');

    PERFORM pg_catalog.set_config('request.jwt.claim.sub',user_a::text,true);
    PERFORM pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object(
        'sub',user_a,'role','authenticated')::text,true);
    SET LOCAL ROLE authenticated;

    result := public.get_data_export();

    -- 1, 4–9, 12: solo movimientos reales, una fila por transferencia y ningún
    -- carryover convertido en ingreso/movimiento.
    IF pg_catalog.jsonb_array_length(result->'movements') <> 7
      OR (SELECT pg_catalog.count(*) FROM pg_catalog.jsonb_array_elements(result->'movements') x
          WHERE x->>'kind'='income') <> 3
      OR (SELECT pg_catalog.count(*) FROM pg_catalog.jsonb_array_elements(result->'movements') x
          WHERE x->>'kind'='expense') <> 1
      OR (SELECT pg_catalog.count(*) FROM pg_catalog.jsonb_array_elements(result->'movements') x
          WHERE x->>'kind'='transfer') <> 3 THEN
        RAISE EXCEPTION 'movimientos reales/carryover incorrectos';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(result->'movements') x
        WHERE x->>'description'='No revelar' OR (x->>'amount')::numeric=77) THEN
        RAISE EXCEPTION 'falló el aislamiento entre usuarios';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(result->'categories') x
        WHERE x->>'id'=category_b::text)
      OR EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(result->'periods') x
        WHERE x->>'id'=period_b::text) THEN
        RAISE EXCEPTION 'se filtraron metadatos de otro usuario';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(result->'movements') x
        WHERE x->>'description'='Ingreso disponible' AND x->>'origin'='Exterior'
          AND x->>'destination'='Disponible')
      OR NOT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(result->'movements') x
        WHERE x->>'description'='Ingreso directo a ahorro' AND x->>'origin'='Exterior'
          AND x->>'destination'='Ahorro A')
      OR NOT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(result->'movements') x
        WHERE x->>'description'='Disponible a ahorro' AND x->>'origin'='Disponible'
          AND x->>'destination'='Ahorro A')
      OR NOT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(result->'movements') x
        WHERE x->>'description'='Ahorro a disponible' AND x->>'origin'='Ahorro A'
          AND x->>'destination'='Disponible')
      OR NOT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(result->'movements') x
        WHERE x->>'description'='Entre ahorros' AND x->>'origin'='Ahorro A'
          AND x->>'destination'='Ahorro B') THEN
        RAISE EXCEPTION 'origen/destino de movimientos incorrecto';
    END IF;

    -- 2: período cerrado conserva opening y closing almacenados.
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(result->'balances') x
        WHERE x->>'period_id'=period_closed::text AND x->>'snapshot_kind'='opening'
          AND x->>'balance_kind'='available' AND x->>'amount'='100.00')
      OR NOT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(result->'balances') x
        WHERE x->>'period_id'=period_closed::text AND x->>'snapshot_kind'='closing'
          AND x->>'amount'='109.00') THEN
        RAISE EXCEPTION 'snapshots de período cerrado incorrectos';
    END IF;

    -- 3, 16: abierto hasta hoy, saldo derivado exacto y numeric entregado como
    -- texto para no cruzar por float/Number en el contrato JSON.
    SELECT x INTO row FROM pg_catalog.jsonb_array_elements(result->'movements') x
        WHERE x->>'description'='Importe exacto';
    IF row->>'amount' <> '900719925474099.91'
      OR NOT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(result->'balances') x
        WHERE x->>'period_id'=period_open::text AND x->>'snapshot_kind'='closing'
          AND (x->>'date')::date=today
          AND (x->>'amount')::numeric=900719925474208.91) THEN
        RAISE EXCEPTION 'período abierto/numeric exacto incorrecto';
    END IF;

    -- 10: apertura de ahorro y saldo reconciliado por el helper canónico.
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(result->'balances') x
        WHERE x->>'account_id'=savings_a::text AND x->>'snapshot_kind'='opening'
          AND x->>'amount'='50.00')
      OR NOT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(result->'balances') x
        WHERE x->>'account_id'=savings_a::text AND x->>'snapshot_kind'='closing'
          AND (x->>'amount')::numeric=63) THEN
        RAISE EXCEPTION 'snapshots de ahorro incorrectos';
    END IF;

    -- 11: rango que cruza períodos. El inicio es anterior a movimientos del
    -- primer día y aparecen ambas fronteras del carryover como Saldo.
    ranged := public.get_data_export(d+1,d+2);
    IF pg_catalog.jsonb_array_length(ranged->'movements') <> 1
      OR NOT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(ranged->'balances') x
        WHERE x->>'period_id'=period_closed::text AND x->>'snapshot_kind'='closing'
          AND (x->>'amount')::numeric=109)
      OR NOT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(ranged->'balances') x
        WHERE x->>'period_id'=period_open::text AND x->>'snapshot_kind'='opening'
          AND (x->>'amount')::numeric=109)
      OR NOT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(ranged->'balances') x
        WHERE x->>'account_id'=savings_a::text AND x->>'snapshot_kind'='opening'
          AND (x->>'amount')::numeric=63)
      OR NOT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(ranged->'balances') x
        WHERE x->>'account_id'=savings_late::text AND x->>'snapshot_kind'='opening'
          AND (x->>'date')::date=d+2 AND (x->>'amount')::numeric=12) THEN
        RAISE EXCEPTION 'rango cruzado/carryover incorrecto';
    END IF;

    -- 13: las referencias inactivas siguen resolviendo su nombre histórico.
    SELECT x INTO row FROM pg_catalog.jsonb_array_elements(result->'movements') x
        WHERE x->>'kind'='expense';
    IF row->>'category' <> 'Categoría histórica' OR row->>'payment_method' <> 'Método histórico'
      OR NOT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(result->'categories') x
        WHERE x->>'id'=category_a::text AND NOT (x->>'is_active')::boolean) THEN
        RAISE EXCEPTION 'referencias históricas inactivas perdidas';
    END IF;

    -- 14: usuario configurado sin movimientos ni períodos.
    RESET ROLE;
    PERFORM pg_catalog.set_config('request.jwt.claim.sub',user_empty::text,true);
    PERFORM pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object(
        'sub',user_empty,'role','authenticated')::text,true);
    SET LOCAL ROLE authenticated;
    result := public.get_data_export();
    IF result->'movements' <> '[]'::jsonb OR result->'balances' <> '[]'::jsonb
      OR result->'periods' <> '[]'::jsonb THEN
        RAISE EXCEPTION 'exportación vacía incorrecta';
    END IF;

    -- 15 y postcondición efectiva: anon no tiene EXECUTE.
    RESET ROLE;
    SET LOCAL ROLE anon;
    failed := false;
    BEGIN
        PERFORM public.get_data_export();
    EXCEPTION WHEN insufficient_privilege THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'anon pudo ejecutar get_data_export'; END IF;

    RAISE NOTICE '010 smoke correcto';
END;
$smoke$;

ROLLBACK;
