-- Preparado para 001 + 002 + 003. NO ejecutar sin autorización.
-- Requiere propietario/BYPASSRLS, inserción de fixtures Auth y SET ROLE.
-- Dos usuarios sintéticos; sin credenciales; todo termina en ROLLBACK.
BEGIN;
DO $smoke$
DECLARE
    user_a uuid := gen_random_uuid();
    user_b uuid := gen_random_uuid();
    period_request uuid := gen_random_uuid();
    savings_request uuid := gen_random_uuid();
    failed_request uuid := gen_random_uuid();
    period_a jsonb;
    period_b jsonb;
    savings_a jsonb;
    savings_b jsonb;
    retry_result jsonb;
    account_row public.savings_accounts;
    settings_row public.user_settings;
    today_a date := (clock_timestamp() AT TIME ZONE 'Pacific/Kiritimati')::date;
    today_b date := (clock_timestamp() AT TIME ZONE 'America/Adak')::date;
    month_start date := date_trunc('month',today_a::timestamp)::date;
    month_end date := (date_trunc('month',today_a::timestamp) + interval '1 month - 1 day')::date;
    item record;
    signature text;
    table_name text;
    command text;
    role_name text;
    function_oid oid;
    actual_state text;
    failed boolean;
    total bigint;
    own bigint;
    checked integer := 0;
BEGIN
    -- Inspección estática de las once RPC mutantes, sin simular concurrencia.
    FOREACH signature IN ARRAY ARRAY[
        'public.configure_user_settings(text,text,bigint)',
        'public.create_category(text)', 'public.rename_category(uuid,text,bigint)',
        'public.set_category_active(uuid,boolean,bigint)',
        'public.create_payment_method(text)', 'public.rename_payment_method(uuid,text,bigint)',
        'public.set_payment_method_active(uuid,boolean,bigint)',
        'public.create_first_period(text,date,date,numeric,uuid,numeric)',
        'public.create_savings_account(text,date,numeric,uuid)',
        'public.rename_savings_account(uuid,text,bigint)',
        'public.set_savings_account_active(uuid,boolean,bigint)'
    ] LOOP
        function_oid := to_regprocedure(signature);
        IF function_oid IS NULL OR position('private.lock_current_user()' IN pg_get_functiondef(function_oid)) = 0 THEN
            RAISE EXCEPTION 'RPC sin bloqueo común: %',signature;
        END IF;
        IF has_function_privilege('anon',function_oid,'EXECUTE')
            OR NOT has_function_privilege('authenticated',function_oid,'EXECUTE') THEN
            RAISE EXCEPTION 'ACL incorrecta: %',signature;
        END IF;
    END LOOP;
    FOREACH signature IN ARRAY ARRAY['private.lock_current_user()','private.financial_request_hash(text,jsonb)'] LOOP
        function_oid := to_regprocedure(signature);
        IF function_oid IS NULL OR has_function_privilege('anon',function_oid,'EXECUTE')
            OR has_function_privilege('authenticated',function_oid,'EXECUTE') THEN
            RAISE EXCEPTION 'Helper ausente o expuesto: %',signature;
        END IF;
    END LOOP;

    INSERT INTO auth.users(id) VALUES (user_a),(user_b);
    PERFORM set_config('request.jwt.claim.sub',user_a::text,true);
    PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',user_a,'role','authenticated')::text,true);
    SET LOCAL ROLE authenticated;
    -- El bloqueo funciona sin settings; las operaciones financieras los exigen.
    FOR item IN SELECT * FROM (VALUES
        (format('SELECT public.create_first_period(''custom'',%L,%L,0,%L)',today_a,today_a,failed_request)),
        (format('SELECT public.create_savings_account(''Reserva'',%L,0,%L)',today_a,failed_request))
    ) AS cases(sql_text) LOOP
        failed := false;
        BEGIN EXECUTE item.sql_text;
        EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
        END;
        IF NOT failed THEN RAISE EXCEPTION 'Se aceptó una creación sin configuración'; END IF;
    END LOOP;
    SELECT * INTO settings_row FROM public.configure_user_settings('PYG','Pacific/Kiritimati');
    IF settings_row.version <> 1 THEN RAISE EXCEPTION 'Configuración inicial incorrecta'; END IF;
    -- Estas validaciones se prueban antes de crear el período para no confundir
    -- el rechazo por fechas/importes con el rechazo por período ya existente.
    FOR item IN SELECT * FROM (VALUES
        ('fecha futura',format('SELECT public.create_first_period(''custom'',%L,%L,0,%L)',today_a+1,today_a+2,failed_request)),
        ('no contiene hoy',format('SELECT public.create_first_period(''custom'',%L,%L,0,%L)',today_a-2,today_a-1,failed_request)),
        ('mes incompleto',format('SELECT public.create_first_period(''monthly'',%L,%L,0,%L)',month_start-1,month_end,failed_request)),
        ('entre nóminas con fin',format('SELECT public.create_first_period(''between_paydays'',%L,%L,0,%L)',today_a,today_a,failed_request)),
        ('budget negativo',format('SELECT public.create_first_period(''custom'',%L,%L,0,%L,-1)',today_a,today_a,failed_request)),
        ('saldo con tres decimales',format('SELECT public.create_first_period(''custom'',%L,%L,1.001,%L)',today_a,today_a,failed_request)),
        ('NaN',format('SELECT public.create_first_period(''custom'',%L,%L,''NaN''::numeric,%L)',today_a,today_a,failed_request)),
        ('request nulo',format('SELECT public.create_first_period(''custom'',%L,%L,0,NULL)',today_a,today_a))
    ) AS cases(label,sql_text) LOOP
        failed := false;
        BEGIN EXECUTE item.sql_text;
        EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
        END;
        IF NOT failed THEN RAISE EXCEPTION 'Período inválido aceptado: %',item.label; END IF;
        checked := checked+1;
    END LOOP;
    RESET ROLE;
    IF EXISTS (SELECT 1 FROM public.financial_operations WHERE user_id = user_a)
        OR EXISTS (SELECT 1 FROM public.budget_periods WHERE user_id = user_a)
        OR EXISTS (SELECT 1 FROM public.user_settings WHERE user_id = user_a AND (currency_locked_at IS NOT NULL OR version <> 1)) THEN
        RAISE EXCEPTION 'Una petición fallida dejó efectos';
    END IF;
    SET LOCAL ROLE authenticated;
    period_a := public.create_first_period('monthly',month_start,month_end,-10,period_request,0);
    retry_result := public.create_first_period('monthly',month_start,month_end,-10.00,period_request,0.00);
    IF period_a IS DISTINCT FROM retry_result OR period_a->>'status' <> 'open'
        OR (period_a->>'opening_balance')::numeric <> -10
        OR (SELECT count(*) FROM public.budget_periods) <> 1 THEN
        RAISE EXCEPTION 'Creación mensual/retry incorrectos';
    END IF;
    SELECT * INTO settings_row FROM public.user_settings;
    IF settings_row.currency_locked_at IS NULL OR settings_row.version <> 2 THEN
        RAISE EXCEPTION 'El primer período no bloqueó moneda/version';
    END IF;

    savings_a := public.create_savings_account(' Reserva ',today_a,12.34,savings_request);
    retry_result := public.create_savings_account('Reserva',today_a,12.340,savings_request);
    IF savings_a IS DISTINCT FROM retry_result OR (savings_a->>'opening_balance')::numeric <> 12.34
        OR savings_a->>'name' <> 'Reserva' OR (SELECT count(*) FROM public.savings_accounts) <> 1 THEN
        RAISE EXCEPTION 'Ahorro decimal/idempotencia incorrectos';
    END IF;
    SELECT * INTO account_row FROM public.rename_savings_account((savings_a->>'id')::uuid,'Viajes',1);
    IF account_row.version <> 2 OR account_row.name <> 'Viajes' THEN RAISE EXCEPTION 'Rename incorrecto'; END IF;
    SELECT * INTO account_row FROM public.set_savings_account_active(account_row.id,false,2);
    IF account_row.version <> 3 OR account_row.is_active THEN RAISE EXCEPTION 'Desactivación incorrecta'; END IF;
    SELECT * INTO account_row FROM public.set_savings_account_active(account_row.id,true,3);
    IF account_row.version <> 4 OR NOT account_row.is_active OR account_row.start_date <> today_a
        OR account_row.opening_balance <> 12.34 OR account_row.updated_at < account_row.created_at THEN
        RAISE EXCEPTION 'Restauración incorrecta o alteró datos iniciales';
    END IF;
    -- El retry mantiene la respuesta original aunque la cuenta haya cambiado.
    retry_result := public.create_savings_account('Reserva',today_a,12.34,savings_request);
    IF retry_result IS DISTINCT FROM savings_a THEN RAISE EXCEPTION 'Retry no devuelve la instantánea original'; END IF;

    -- B crea primero ahorro: también debe bloquear la moneda sin período.
    RESET ROLE;
    PERFORM set_config('request.jwt.claim.sub',user_b::text,true);
    PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',user_b,'role','authenticated')::text,true);
    SET LOCAL ROLE authenticated;
    PERFORM public.configure_user_settings('EUR','America/Adak');
    savings_b := public.create_savings_account('Reserva',today_b,0,savings_request);
    SELECT * INTO settings_row FROM public.user_settings;
    IF settings_row.currency_locked_at IS NULL OR settings_row.version <> 2
        OR EXISTS (SELECT 1 FROM public.budget_periods) THEN RAISE EXCEPTION 'Ahorro no bloqueó moneda independientemente'; END IF;
    -- Los mismos request_id pueden utilizarse por otro usuario.
    period_b := public.create_first_period('custom',today_b-1,today_b+1,0,period_request);
    IF period_b->>'user_id' <> user_b::text OR period_b->>'mode' <> 'custom' THEN
        RAISE EXCEPTION 'Período personalizado incorrecto';
    END IF;
    RESET ROLE;
    PERFORM set_config('request.jwt.claim.sub',user_a::text,true);
    PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',user_a,'role','authenticated')::text,true);
    SET LOCAL ROLE authenticated;

    FOR item IN SELECT * FROM (VALUES
        ('segundo primer período',format('SELECT public.create_first_period(''monthly'',%L,%L,-10,%L,0)',month_start,month_end,failed_request),'22023'),
        ('payload de período distinto',format('SELECT public.create_first_period(''monthly'',%L,%L,-11,%L,0)',month_start,month_end,period_request),'22023'),
        ('payload de ahorro distinto',format('SELECT public.create_savings_account(''Reserva'',%L,12.35,%L)',today_a,savings_request),'22023'),
        ('request compartido entre operaciones',format('SELECT public.create_savings_account(''Otra'',%L,0,%L)',today_a,period_request),'22023'),
        ('ahorro futuro',format('SELECT public.create_savings_account(''Futura'',%L,0,%L)',today_a+1,failed_request),'22023'),
        ('ahorro negativo',format('SELECT public.create_savings_account(''Negativa'',%L,-1,%L)',today_a,failed_request),'22023'),
        ('ahorro precisión',format('SELECT public.create_savings_account(''Precisión'',%L,1.001,%L)',today_a,failed_request),'22023'),
        ('ahorro sin nombre',format('SELECT public.create_savings_account(''  '',%L,0,%L)',today_a,failed_request),'22023'),
        ('nombre duplicado',format('SELECT public.create_savings_account('' VIAJES '',%L,0,%L)',today_a,failed_request),'23505'),
        ('rename obsoleto',format('SELECT public.rename_savings_account(%L,''Otro'',1)',savings_a->>'id'),'40001'),
        ('estado obsoleto',format('SELECT public.set_savings_account_active(%L,false,1)',savings_a->>'id'),'40001'),
        ('rename ajeno',format('SELECT public.rename_savings_account(%L,''Robado'',1)',savings_b->>'id'),'P0002'),
        ('estado ajeno',format('SELECT public.set_savings_account_active(%L,false,1)',savings_b->>'id'),'P0002'),
        ('moneda bloqueada', 'SELECT public.configure_user_settings(''USD'',''Pacific/Kiritimati'',2)','22023'),
        ('registro privado','SELECT * FROM public.financial_operations','42501'),
        ('helper privado','SELECT private.lock_current_user()','42501')
    ) AS cases(label,sql_text,expected_state) LOOP
        failed := false;
        BEGIN EXECUTE item.sql_text;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS actual_state = RETURNED_SQLSTATE;
            IF actual_state <> item.expected_state THEN RAISE; END IF;
            failed := true;
        END;
        IF NOT failed THEN RAISE EXCEPTION 'Caso inválido aceptado: %',item.label; END IF;
        checked := checked+1;
    END LOOP;

    FOREACH table_name IN ARRAY ARRAY['budget_periods','savings_accounts'] LOOP
        EXECUTE format('SELECT count(*),count(*) FILTER (WHERE user_id=$1) FROM public.%I',table_name)
            INTO total,own USING user_a;
        IF total <> 1 OR own <> total THEN RAISE EXCEPTION 'SELECT/RLS incorrecto: %',table_name; END IF;
    END LOOP;
    FOREACH table_name IN ARRAY ARRAY['budget_periods','savings_accounts','financial_operations'] LOOP
        FOREACH command IN ARRAY ARRAY[
            format('INSERT INTO public.%I DEFAULT VALUES',table_name),
            format('UPDATE public.%I SET user_id=user_id',table_name),
            format('DELETE FROM public.%I',table_name)
        ] LOOP
            failed := false;
            BEGIN EXECUTE command;
            EXCEPTION WHEN insufficient_privilege THEN failed := true;
            END;
            IF NOT failed THEN RAISE EXCEPTION 'DML directo permitido: %',command; END IF;
        END LOOP;
    END LOOP;
    RESET ROLE;
    PERFORM set_config('request.jwt.claim.sub','',true);
    PERFORM set_config('request.jwt.claims','{}',true);
    FOR item IN SELECT * FROM (VALUES
        (format('SELECT public.create_first_period(''custom'',%L,%L,0,%L)',today_a,today_a,failed_request)),
        (format('SELECT public.create_savings_account(''X'',%L,0,%L)',today_a,failed_request)),
        (format('SELECT public.rename_savings_account(%L,''X'',4)',savings_a->>'id')),
        (format('SELECT public.set_savings_account_active(%L,false,4)',savings_a->>'id'))
    ) AS cases(sql_text) LOOP
        SET LOCAL ROLE anon;
        failed := false;
        BEGIN EXECUTE item.sql_text;
        EXCEPTION WHEN insufficient_privilege THEN failed := true;
        END;
        IF NOT failed THEN RAISE EXCEPTION 'Anon pudo ejecutar RPC'; END IF;
        RESET ROLE;
        SET LOCAL ROLE authenticated;
        failed := false;
        BEGIN EXECUTE item.sql_text;
        EXCEPTION WHEN SQLSTATE '28000' THEN failed := true;
        END;
        IF NOT failed THEN RAISE EXCEPTION 'RPC aceptó sesión sin usuario'; END IF;
        RESET ROLE;
    END LOOP;

    -- Inspección administrativa del resultado completo y ausencia de movimientos.
    IF (SELECT count(*) FROM public.financial_operations WHERE user_id IN (user_a,user_b)) <> 4
        OR EXISTS (SELECT 1 FROM public.financial_operations WHERE user_id IN (user_a,user_b) AND idempotency_key=failed_request)
        OR EXISTS (SELECT 1 FROM public.user_settings WHERE user_id IN (user_a,user_b) AND version <> 2)
        OR NOT EXISTS (SELECT 1 FROM public.savings_accounts WHERE id=(savings_b->>'id')::uuid AND name='Reserva' AND version=1 AND is_active)
        OR EXISTS (SELECT 1 FROM public.expenses WHERE user_id IN (user_a,user_b))
        OR EXISTS (SELECT 1 FROM public.incomes WHERE user_id IN (user_a,user_b))
        OR EXISTS (SELECT 1 FROM public.transfers WHERE user_id IN (user_a,user_b)) THEN
        RAISE EXCEPTION 'Efectos duplicados, parciales o movimientos ficticios';
    END IF;
    RAISE NOTICE 'Smoke 003 OK: períodos, ahorro, idempotencia, seguridad y % rechazos esperados. Concurrencia real pendiente de 004.',checked;
END;
$smoke$;
ROLLBACK;
