-- Preparado para una instancia local con 001 y 002 aplicadas.
-- Ejecutar solo cuando se autorice, como propietario/BYPASSRLS con capacidad
-- de SET ROLE anon/authenticated y de insertar fixtures en auth.users.
-- Las comprobaciones de acceso se hacen realmente bajo esos roles.
BEGIN;
DO $smoke$
DECLARE
    user_a uuid := gen_random_uuid();
    user_b uuid := gen_random_uuid();
    fixture_user uuid;
    fixture_category uuid;
    fixture_method uuid;
    fixture_period uuid;
    fixture_savings uuid;
    category_a uuid;
    category_b uuid;
    method_a uuid;
    method_b uuid;
    item record;
    settings_row public.user_settings;
    catalog_row record;
    table_name text;
    command text;
    failed boolean;
    row_count bigint;
    own_count bigint;
    expected_state text;
    checked integer := 0;
BEGIN
    INSERT INTO auth.users(id) VALUES (user_a), (user_b);
    -- Fixtures financieros solo como administrador: 002 no ofrece estas RPC.
    FOREACH fixture_user IN ARRAY ARRAY[user_a, user_b] LOOP
        INSERT INTO public.categories(user_id,name) VALUES (fixture_user,'Comida') RETURNING id INTO fixture_category;
        INSERT INTO public.payment_methods(user_id,name) VALUES (fixture_user,'Tarjeta') RETURNING id INTO fixture_method;
        INSERT INTO public.budget_periods(user_id,mode,start_date,end_date,opening_balance)
            VALUES (fixture_user,'monthly','2024-01-01','2024-01-31',100) RETURNING id INTO fixture_period;
        INSERT INTO public.savings_accounts(user_id,name,start_date,opening_balance)
            VALUES (fixture_user,'Reserva','2024-01-01',10) RETURNING id INTO fixture_savings;
        INSERT INTO public.expenses(user_id,period_id,date,amount,category_id,payment_method_id)
            VALUES (fixture_user,fixture_period,'2024-01-02',1,fixture_category,fixture_method);
        INSERT INTO public.incomes(user_id,period_id,date,amount)
            VALUES (fixture_user,fixture_period,'2024-01-02',10);
        INSERT INTO public.transfers(user_id,period_id,date,amount,to_savings_account_id)
            VALUES (fixture_user,fixture_period,'2024-01-02',1,fixture_savings);
        INSERT INTO public.period_category_budgets(user_id,period_id,category_id,amount)
            VALUES (fixture_user,fixture_period,fixture_category,0);
        INSERT INTO public.financial_operations(user_id,idempotency_key,operation_type,request_hash,result)
            VALUES (fixture_user,gen_random_uuid(),'fixture','synthetic','{}');
        IF fixture_user = user_a THEN
            category_a := fixture_category; method_a := fixture_method;
        ELSE
            category_b := fixture_category; method_b := fixture_method;
        END IF;
    END LOOP;
    SET CONSTRAINTS ALL IMMEDIATE;

    -- Claims sintéticos locales; ningún token ni credencial real.
    PERFORM set_config('request.jwt.claim.sub', user_b::text, true);
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',user_b,'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT * INTO settings_row FROM public.configure_user_settings('EUR','Europe/Madrid');
    IF settings_row.user_id <> user_b OR settings_row.version <> 1 THEN RAISE EXCEPTION 'Inicialización B incorrecta'; END IF;
    RESET ROLE;
    PERFORM set_config('request.jwt.claim.sub', user_a::text, true);
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',user_a,'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT * INTO settings_row FROM public.configure_user_settings('PYG','America/Asuncion');
    IF settings_row.user_id <> user_a OR settings_row.currency <> 'PYG' OR settings_row.version <> 1 THEN
        RAISE EXCEPTION 'Inicialización A incorrecta';
    END IF;
    SELECT * INTO settings_row FROM public.configure_user_settings('USD','Europe/Madrid',1);
    IF settings_row.currency <> 'USD' OR settings_row.version <> 2 OR settings_row.updated_at < settings_row.created_at THEN
        RAISE EXCEPTION 'Update de configuración incorrecto';
    END IF;

    -- Lecturas propias y ausencia de filas ajenas en las nueve tablas públicas.
    FOREACH table_name IN ARRAY ARRAY['user_settings','categories','payment_methods','budget_periods',
        'expenses','incomes','savings_accounts','transfers','period_category_budgets'] LOOP
        EXECUTE format('SELECT count(*), count(*) FILTER (WHERE user_id = $1) FROM public.%I',table_name)
            INTO row_count, own_count USING user_a;
        IF row_count = 0 OR row_count <> own_count THEN RAISE EXCEPTION 'RLS incorrecto en %',table_name; END IF;
    END LOOP;

    -- Crear y ciclo completo sobre un objeto referenciado por un gasto.
    FOR item IN SELECT * FROM (VALUES
        ('category','categories',category_a), ('payment_method','payment_methods',method_a)
    ) AS cases(entity,target_table,target_id) LOOP
        EXECUTE format('SELECT * FROM public.create_%s($1)',item.entity) INTO catalog_row USING ' Nuevo ';
        IF catalog_row.user_id <> user_a OR catalog_row.name <> 'Nuevo' OR catalog_row.version <> 1 OR NOT catalog_row.is_active THEN
            RAISE EXCEPTION 'Creación incorrecta de %',item.entity;
        END IF;
        EXECUTE format('SELECT * FROM public.rename_%s($1,$2,$3)',item.entity)
            INTO catalog_row USING item.target_id,'Renombrado',1::bigint;
        IF catalog_row.name <> 'Renombrado' OR catalog_row.version <> 2 THEN RAISE EXCEPTION 'Rename incorrecto'; END IF;
        EXECUTE format('SELECT * FROM public.set_%s_active($1,$2,$3)',item.entity)
            INTO catalog_row USING item.target_id,false,2::bigint;
        IF catalog_row.is_active OR catalog_row.version <> 3 THEN RAISE EXCEPTION 'Desactivación incorrecta'; END IF;
        SELECT count(*) INTO row_count FROM public.expenses WHERE user_id = user_a AND category_id = category_a AND payment_method_id = method_a;
        IF row_count <> 1 THEN RAISE EXCEPTION 'Se perdió historial al desactivar'; END IF;
        EXECUTE format('SELECT * FROM public.set_%s_active($1,$2,$3)',item.entity)
            INTO catalog_row USING item.target_id,true,3::bigint;
        IF NOT catalog_row.is_active OR catalog_row.version <> 4 OR catalog_row.updated_at < catalog_row.created_at THEN
            RAISE EXCEPTION 'Restauración incorrecta';
        END IF;
    END LOOP;

    -- Simula el bloqueo que establecerá la futura lógica financiera.
    RESET ROLE;
    UPDATE public.user_settings SET currency_locked_at = clock_timestamp() WHERE user_id = user_a;
    SET LOCAL ROLE authenticated;
    SELECT * INTO settings_row FROM public.configure_user_settings('USD','UTC',2);
    IF settings_row.version <> 3 OR settings_row.timezone <> 'UTC' OR settings_row.currency_locked_at IS NULL THEN
        RAISE EXCEPTION 'No permite actualizar timezone conservando moneda bloqueada';
    END IF;

    FOR item IN SELECT * FROM (VALUES
        ('timezone inválida', 'SELECT public.configure_user_settings(''USD'',''Invalid/Nowhere'',3)', '22023'),
        ('currency inválida', 'SELECT public.configure_user_settings(''GBP'',''UTC'',3)', '22023'),
        ('currency bloqueada', 'SELECT public.configure_user_settings(''EUR'',''UTC'',3)', '22023'),
        ('settings obsoletos', 'SELECT public.configure_user_settings(''USD'',''UTC'',2)', '40001'),
        ('settings sin versión', 'SELECT public.configure_user_settings(''USD'',''UTC'')', '22023'),
        ('categoría vacía', 'SELECT public.create_category(''   '')', '22023'),
        ('método vacío', 'SELECT public.create_payment_method(''   '')', '22023'),
        ('categoría duplicada', 'SELECT public.create_category('' nuevo '')', '23505'),
        ('método duplicado', 'SELECT public.create_payment_method('' nuevo '')', '23505'),
        ('categoría obsoleta', format('SELECT public.rename_category(%L,''Otro'',1)',category_a), '40001'),
        ('método obsoleto', format('SELECT public.rename_payment_method(%L,''Otro'',1)',method_a), '40001'),
        ('estado categoría obsoleto', format('SELECT public.set_category_active(%L,false,1)',category_a), '40001'),
        ('estado método obsoleto', format('SELECT public.set_payment_method_active(%L,false,1)',method_a), '40001'),
        ('categoría ajena', format('SELECT public.rename_category(%L,''Robado'',1)',category_b), 'P0002'),
        ('método ajeno', format('SELECT public.rename_payment_method(%L,''Robado'',1)',method_b), 'P0002'),
        ('estado categoría ajena', format('SELECT public.set_category_active(%L,false,1)',category_b), 'P0002'),
        ('estado método ajeno', format('SELECT public.set_payment_method_active(%L,false,1)',method_b), 'P0002'),
        ('operaciones ocultas', 'SELECT * FROM public.financial_operations', '42501')
    ) AS cases(label,sql_text,sqlstate) LOOP
        failed := false;
        BEGIN
            EXECUTE item.sql_text;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS expected_state = RETURNED_SQLSTATE;
            IF expected_state <> item.sqlstate THEN RAISE; END IF;
            failed := true;
        END;
        IF NOT failed THEN RAISE EXCEPTION 'Caso inválido aceptado: %',item.label; END IF;
        checked := checked + 1;
    END LOOP;

    -- DML directo denegado en las diez tablas, incluidos settings y catálogos.
    FOREACH table_name IN ARRAY ARRAY['user_settings','categories','payment_methods','budget_periods',
        'expenses','incomes','savings_accounts','transfers','period_category_budgets','financial_operations'] LOOP
        FOREACH command IN ARRAY ARRAY[
            format('INSERT INTO public.%I DEFAULT VALUES',table_name),
            format('UPDATE public.%I SET user_id = user_id',table_name),
            format('DELETE FROM public.%I',table_name)
        ] LOOP
            failed := false;
            BEGIN EXECUTE command;
            EXCEPTION WHEN insufficient_privilege THEN failed := true;
            END;
            IF NOT failed THEN RAISE EXCEPTION 'DML directo permitido: %',command; END IF;
            checked := checked + 1;
        END LOOP;
    END LOOP;

    -- Anon no puede consultar ninguna tabla, incluso con un sub sintético.
    RESET ROLE;
    SET LOCAL ROLE anon;
    FOREACH table_name IN ARRAY ARRAY['user_settings','categories','payment_methods','budget_periods',
        'expenses','incomes','savings_accounts','transfers','period_category_budgets','financial_operations'] LOOP
        failed := false;
        BEGIN EXECUTE format('SELECT * FROM public.%I',table_name);
        EXCEPTION WHEN insufficient_privilege THEN failed := true;
        END;
        IF NOT failed THEN RAISE EXCEPTION 'Anon pudo leer %',table_name; END IF;
        IF has_table_privilege(current_user,format('public.%I',table_name),'INSERT,UPDATE,DELETE,TRUNCATE') THEN
            RAISE EXCEPTION 'Anon tiene permisos de escritura en %',table_name;
        END IF;
    END LOOP;
    -- Cada RPC deniega EXECUTE a anon y rechaza auth.uid() nulo aun con EXECUTE.
    RESET ROLE;
    PERFORM set_config('request.jwt.claim.sub','',true);
    PERFORM set_config('request.jwt.claims','{}',true);
    FOR item IN SELECT * FROM (VALUES
        ('SELECT public.configure_user_settings(''EUR'',''UTC'')'),
        ('SELECT public.create_category(''X'')'),
        ('SELECT public.create_payment_method(''X'')'),
        (format('SELECT public.rename_category(%L,''X'',4)',category_a)),
        (format('SELECT public.rename_payment_method(%L,''X'',4)',method_a)),
        (format('SELECT public.set_category_active(%L,false,4)',category_a)),
        (format('SELECT public.set_payment_method_active(%L,false,4)',method_a))
    ) AS cases(sql_text) LOOP
        SET LOCAL ROLE anon;
        failed := false;
        BEGIN EXECUTE item.sql_text;
        EXCEPTION WHEN insufficient_privilege THEN failed := true;
        END;
        IF NOT failed THEN RAISE EXCEPTION 'RPC accesible por anon'; END IF;
        RESET ROLE;
        SET LOCAL ROLE authenticated;
        failed := false;
        BEGIN EXECUTE item.sql_text;
        EXCEPTION WHEN SQLSTATE '28000' THEN failed := true;
        END;
        IF NOT failed THEN RAISE EXCEPTION 'RPC aceptó sesión sin usuario'; END IF;
        RESET ROLE;
    END LOOP;

    -- Los intentos cross-user y sin sesión no alteraron B ni borraron historial.
    IF NOT EXISTS (SELECT 1 FROM public.categories WHERE id = category_b AND name = 'Comida' AND version = 1 AND is_active)
        OR NOT EXISTS (SELECT 1 FROM public.payment_methods WHERE id = method_b AND name = 'Tarjeta' AND version = 1 AND is_active)
        OR (SELECT count(*) FROM public.expenses WHERE user_id IN (user_a,user_b)) <> 2 THEN
        RAISE EXCEPTION 'Los intentos denegados alteraron datos';
    END IF;
    RAISE NOTICE 'Smoke 002 OK: RLS, RPC, catálogos, versiones, sesiones y % rechazos de acceso/validación.',checked;
END;
$smoke$;
ROLLBACK;
