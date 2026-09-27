-- Ejecutar únicamente cuando se autorice, sobre una instancia local de Supabase
-- con 001 aplicada y como rol de pruebas capaz de insertar fixtures en auth.users
-- y de omitir RLS (propietario de las tablas o BYPASSRLS).
-- No necesita pgTAP ni funciones auxiliares. Cada fallo esperado comprueba tanto
-- SQLSTATE como el nombre de la restricción, para evitar falsos positivos.
BEGIN;

DO $smoke$
DECLARE
    user_a uuid := gen_random_uuid();
    user_b uuid := gen_random_uuid();
    period_a uuid := gen_random_uuid();
    period_b uuid := gen_random_uuid();
    category_a uuid := gen_random_uuid();
    category_b uuid := gen_random_uuid();
    method_a uuid := gen_random_uuid();
    method_b uuid := gen_random_uuid();
    savings_a uuid := gen_random_uuid();
    savings_a2 uuid := gen_random_uuid();
    savings_b uuid := gen_random_uuid();
    operation_key uuid := gen_random_uuid();
    test_case record;
    table_name text;
    invalid_amount text;
    actual_state text;
    actual_constraint text;
    failed_as_expected boolean;
    checked_count integer := 0;
BEGIN
    -- Verifica las diez FK esperadas por tabla y nombre, incluso si falta alguna.
    FOR test_case IN
        SELECT * FROM (VALUES
            ('expenses', 'expenses_period_fk'),
            ('expenses', 'expenses_category_fk'),
            ('expenses', 'expenses_payment_method_fk'),
            ('incomes', 'incomes_period_fk'),
            ('incomes', 'incomes_savings_account_fk'),
            ('transfers', 'transfers_period_fk'),
            ('transfers', 'transfers_from_savings_fk'),
            ('transfers', 'transfers_to_savings_fk'),
            ('period_category_budgets', 'period_category_budgets_period_fk'),
            ('period_category_budgets', 'period_category_budgets_category_fk')
        ) AS cases(target_table, expected_constraint)
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pg_catalog.pg_constraint AS c
            JOIN pg_catalog.pg_class AS t ON t.oid = c.conrelid
            JOIN pg_catalog.pg_namespace AS n ON n.oid = t.relnamespace
            WHERE n.nspname = 'public' AND t.relname = test_case.target_table
                AND c.conname = test_case.expected_constraint AND c.contype = 'f'
                AND c.condeferrable AND c.condeferred AND c.confdeltype = 'a'
        ) THEN
            RAISE EXCEPTION 'FK ausente o sin NO ACTION DEFERRABLE INITIALLY DEFERRED: %', test_case.expected_constraint;
        END IF;
    END LOOP;

    FOREACH table_name IN ARRAY ARRAY[
        'user_settings', 'categories', 'payment_methods', 'budget_periods', 'expenses',
        'incomes', 'savings_accounts', 'transfers', 'period_category_budgets', 'financial_operations'
    ] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_class AS t
            JOIN pg_catalog.pg_namespace AS n ON n.oid = t.relnamespace
            WHERE n.nspname = 'public' AND t.relname = table_name AND t.relrowsecurity
        ) THEN
            RAISE EXCEPTION 'Tabla ausente o RLS deshabilitado: %', table_name;
        END IF;
    END LOOP;

    -- Usuarios efímeros: toda la prueba, incluidos Auth y sus fixtures, se revierte.
    INSERT INTO auth.users (id) VALUES (user_a), (user_b);
    INSERT INTO public.user_settings (user_id, currency, timezone)
        VALUES (user_a, 'PYG', 'Europe/Madrid'), (user_b, 'EUR', 'Europe/Madrid');
    INSERT INTO public.categories (id, user_id, name)
        VALUES (category_a, user_a, 'Comida'), (category_b, user_b, 'Comida');
    INSERT INTO public.payment_methods (id, user_id, name)
        VALUES (method_a, user_a, 'Tarjeta'), (method_b, user_b, 'Tarjeta');
    INSERT INTO public.savings_accounts (id, user_id, name, start_date, opening_balance)
        VALUES (savings_a, user_a, 'Reserva', '2023-01-01', 100.25),
               (savings_a2, user_a, 'Viaje', '2023-01-01', 0),
               (savings_b, user_b, 'Reserva', '2023-01-01', 100);

    -- Todos los modos; límites contiguos sin solaparse; saldos negativos válidos.
    INSERT INTO public.budget_periods
        (user_id, mode, start_date, end_date, status, opening_balance, closing_balance, closed_at)
        VALUES (user_a, 'annual', '2023-01-01', '2023-12-31', 'closed', 0, -10, now()),
               (user_a, 'monthly', '2024-01-01', '2024-01-31', 'closed', -10, 20, now()),
               (user_a, 'custom', '2024-02-01', '2024-02-29', 'closed', 20, -5, now());
    INSERT INTO public.budget_periods
        (id, user_id, mode, start_date, end_date, opening_balance, general_budget)
        VALUES (period_a, user_a, 'between_paydays', '2024-03-01', NULL, -5, 0),
               (period_b, user_b, 'monthly', '2024-03-01', '2024-03-31', 100, NULL);

    INSERT INTO public.expenses (user_id, period_id, date, amount, category_id, payment_method_id)
        VALUES (user_a, period_a, '2024-03-02', 1.25, category_a, method_a),
               (user_b, period_b, '2024-03-02', 1, category_b, method_b);
    INSERT INTO public.incomes (user_id, period_id, date, amount, savings_account_id, description)
        VALUES (user_a, period_a, '2024-03-02', 50.25, NULL, 'Ingreso a disponible'),
               (user_a, period_a, '2024-03-02', 10.50, savings_a, 'Ingreso a ahorro'),
               (user_b, period_b, '2024-03-02', 10, savings_b, NULL);
    INSERT INTO public.transfers
        (user_id, period_id, date, amount, from_savings_account_id, to_savings_account_id, description)
        VALUES (user_a, period_a, '2024-03-02', 5.25, NULL, savings_a, 'A ahorro'),
               (user_a, period_a, '2024-03-02', 2.25, savings_a, NULL, 'A disponible'),
               (user_a, period_a, '2024-03-02', 1.25, savings_a, savings_a2, 'Entre ahorros'),
               (user_b, period_b, '2024-03-02', 1, NULL, savings_b, NULL);
    INSERT INTO public.period_category_budgets (user_id, period_id, category_id, amount)
        VALUES (user_a, period_a, category_a, 0), (user_b, period_b, category_b, 0);
    INSERT INTO public.financial_operations (user_id, idempotency_key, operation_type, request_hash, result)
        VALUES (user_a, operation_key, 'create_income', 'smoke-hash-a', '{"ok":true}'),
               (user_b, operation_key, 'create_income', 'smoke-hash-b', '{"ok":true}');

    -- Fixtures válidos también comprueban UUID/timestamps/version por defecto.
    FOREACH table_name IN ARRAY ARRAY[
        'user_settings', 'categories', 'payment_methods', 'budget_periods', 'expenses',
        'incomes', 'savings_accounts', 'transfers', 'period_category_budgets'
    ] LOOP
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM public.%I WHERE user_id = $1 AND (version <> 1 OR created_at IS NULL OR updated_at IS NULL))',
            table_name
        ) INTO failed_as_expected USING user_a;
        IF failed_as_expected THEN
            RAISE EXCEPTION 'Defaults incorrectos en %', table_name;
        END IF;
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM public.expenses WHERE user_id = user_a AND amount = 1.25) THEN
        RAISE EXCEPTION 'PYG debe admitir dos decimales';
    END IF;

    -- Todos los caminos de FK internas rechazan referencias de otro usuario.
    -- Fuerza errores dentro de cada caso, en lugar de posponerlos al commit.
    SET CONSTRAINTS ALL IMMEDIATE;
    FOR test_case IN
        SELECT * FROM (VALUES
            ('expenses', 'period_id', period_b, 'expenses_period_fk'),
            ('expenses', 'category_id', category_b, 'expenses_category_fk'),
            ('expenses', 'payment_method_id', method_b, 'expenses_payment_method_fk'),
            ('incomes', 'period_id', period_b, 'incomes_period_fk'),
            ('incomes', 'savings_account_id', savings_b, 'incomes_savings_account_fk'),
            ('transfers', 'period_id', period_b, 'transfers_period_fk'),
            ('transfers', 'from_savings_account_id', savings_b, 'transfers_from_savings_fk'),
            ('transfers', 'to_savings_account_id', savings_b, 'transfers_to_savings_fk'),
            ('period_category_budgets', 'period_id', period_b, 'period_category_budgets_period_fk'),
            ('period_category_budgets', 'category_id', category_b, 'period_category_budgets_category_fk')
        ) AS cases(target_table, target_column, foreign_id, expected_constraint)
    LOOP
        failed_as_expected := false;
        BEGIN
            EXECUTE format('UPDATE public.%I SET %I = $1 WHERE user_id = $2',
                test_case.target_table, test_case.target_column) USING test_case.foreign_id, user_a;
        EXCEPTION WHEN foreign_key_violation THEN
            GET STACKED DIAGNOSTICS actual_constraint = CONSTRAINT_NAME;
            IF actual_constraint <> test_case.expected_constraint THEN RAISE; END IF;
            failed_as_expected := true;
        END;
        IF NOT failed_as_expected THEN RAISE EXCEPTION 'Ownership no protegido: %', test_case.expected_constraint; END IF;
        checked_count := checked_count + 1;
    END LOOP;

    -- Cada caso aísla una restricción; un error distinto también falla la prueba.
    FOR test_case IN
        SELECT * FROM (VALUES
            ('solapamiento con período abierto sin fin', format(
                'INSERT INTO public.budget_periods (user_id,mode,start_date,end_date,status,opening_balance,closing_balance,closed_at) VALUES (%L,''custom'',''2024-04-01'',''2024-04-02'',''closed'',0,0,now())', user_a),
                '23P01', 'budget_periods_no_overlap'),
            ('límites inclusivos', format(
                'INSERT INTO public.budget_periods (user_id,mode,start_date,end_date,status,opening_balance,closing_balance,closed_at) VALUES (%L,''custom'',''2024-02-29'',''2024-02-29'',''closed'',0,0,now())', user_a),
                '23P01', 'budget_periods_no_overlap'),
            ('segundo abierto sin solapamiento', format(
                'INSERT INTO public.budget_periods (user_id,mode,start_date,end_date,opening_balance) VALUES (%L,''monthly'',''2024-04-01'',''2024-04-30'',0)', user_b),
                '23505', 'budget_periods_one_open_key'),
            ('transferencia sin extremos', format(
                'INSERT INTO public.transfers (user_id,period_id,date,amount) VALUES (%L,%L,''2024-03-02'',1)', user_a, period_a),
                '23514', 'transfers_endpoints_check'),
            ('transferencia a la misma cuenta', format(
                'INSERT INTO public.transfers (user_id,period_id,date,amount,from_savings_account_id,to_savings_account_id) VALUES (%L,%L,''2024-03-02'',1,%L,%L)', user_a, period_a, savings_a, savings_a),
                '23514', 'transfers_endpoints_check'),
            ('categoría duplicada normalizada', format('INSERT INTO public.categories (user_id,name) VALUES (%L,'' comida '')', user_a),
                '23505', 'categories_owner_name_key'),
            ('método duplicado normalizado', format('INSERT INTO public.payment_methods (user_id,name) VALUES (%L,'' TARJETA '')', user_a),
                '23505', 'payment_methods_owner_name_key'),
            ('cuenta duplicada normalizada', format('INSERT INTO public.savings_accounts (user_id,name,start_date,opening_balance) VALUES (%L,'' reserva '',''2024-01-01'',0)', user_a),
                '23505', 'savings_accounts_owner_name_key'),
            ('presupuesto duplicado', format('INSERT INTO public.period_category_budgets (user_id,period_id,category_id,amount) VALUES (%L,%L,%L,10)', user_a, period_a, category_a),
                '23505', 'period_category_budgets_owner_period_category_key'),
            ('clave idempotente duplicada', format('INSERT INTO public.financial_operations (user_id,idempotency_key,operation_type,request_hash,result) VALUES (%L,%L,''create_income'',''another-hash'',''{}'')', user_a, operation_key),
                '23505', 'financial_operations_owner_idempotency_key'),
            ('configuración duplicada', format('INSERT INTO public.user_settings (user_id,currency,timezone) VALUES (%L,''USD'',''UTC'')', user_a),
                '23505', 'user_settings_pkey'),
            ('categoría vacía', format('INSERT INTO public.categories (user_id,name) VALUES (%L,''   '')', user_a),
                '23514', 'categories_name_check'),
            ('método vacío', format('INSERT INTO public.payment_methods (user_id,name) VALUES (%L,''   '')', user_a),
                '23514', 'payment_methods_name_check'),
            ('cuenta vacía', format('INSERT INTO public.savings_accounts (user_id,name,start_date,opening_balance) VALUES (%L,''   '',''2024-01-01'',0)', user_a),
                '23514', 'savings_accounts_name_check'),
            ('saldo inicial ahorro negativo', format('UPDATE public.savings_accounts SET opening_balance = -1 WHERE id = %L', savings_a),
                '23514', 'savings_accounts_balance_check'),
            ('presupuesto general negativo', format('UPDATE public.budget_periods SET general_budget = -1 WHERE id = %L', period_a),
                '23514', 'budget_periods_general_budget_check'),
            ('presupuesto categoría negativo', format('UPDATE public.period_category_budgets SET amount = -1 WHERE user_id = %L', user_a),
                '23514', 'period_category_budgets_amount_check'),
            ('período sin fin no permitido', format('INSERT INTO public.budget_periods (user_id,mode,start_date,opening_balance) VALUES (%L,''custom'',''2025-01-01'',0)', user_b),
                '23514', 'budget_periods_end_required_check'),
            ('fin anterior al inicio', format('INSERT INTO public.budget_periods (user_id,mode,start_date,end_date,status,opening_balance,closing_balance,closed_at) VALUES (%L,''custom'',''2025-01-02'',''2025-01-01'',''closed'',0,0,now())', user_b),
                '23514', 'budget_periods_dates_check'),
            ('mes incompleto', format('INSERT INTO public.budget_periods (user_id,mode,start_date,end_date,status,opening_balance,closing_balance,closed_at) VALUES (%L,''monthly'',''2025-01-02'',''2025-01-31'',''closed'',0,0,now())', user_b),
                '23514', 'budget_periods_monthly_check'),
            ('año incompleto', format('INSERT INTO public.budget_periods (user_id,mode,start_date,end_date,status,opening_balance,closing_balance,closed_at) VALUES (%L,''annual'',''2025-01-01'',''2025-12-30'',''closed'',0,0,now())', user_b),
                '23514', 'budget_periods_annual_check'),
            ('cierre incompleto', format('UPDATE public.budget_periods SET status = ''closed'', end_date = ''2024-03-31'' WHERE id = %L', period_a),
                '23514', 'budget_periods_closure_check'),
            ('borrado de método referenciado', format('DELETE FROM public.payment_methods WHERE id = %L', method_a),
                '23503', 'expenses_payment_method_fk')
        ) AS cases(label, command, expected_state, expected_constraint)
    LOOP
        failed_as_expected := false;
        BEGIN
            EXECUTE test_case.command;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS actual_state = RETURNED_SQLSTATE, actual_constraint = CONSTRAINT_NAME;
            IF actual_state <> test_case.expected_state OR actual_constraint <> test_case.expected_constraint THEN
                RAISE EXCEPTION 'Caso %: esperado % / %, recibido % / %', test_case.label,
                    test_case.expected_state, test_case.expected_constraint, actual_state, actual_constraint;
            END IF;
            failed_as_expected := true;
        END;
        IF NOT failed_as_expected THEN RAISE EXCEPTION 'Se aceptó un caso inválido: %', test_case.label; END IF;
        checked_count := checked_count + 1;
    END LOOP;

    -- Cero y negativos en las tres clases de movimientos; NaN tampoco es dinero.
    FOREACH table_name IN ARRAY ARRAY['expenses', 'incomes', 'transfers'] LOOP
        FOREACH invalid_amount IN ARRAY ARRAY['0', '-0.01', 'NaN'] LOOP
            failed_as_expected := false;
            BEGIN
                EXECUTE format('UPDATE public.%I SET amount = $1::numeric WHERE user_id = $2', table_name)
                    USING invalid_amount, user_a;
            EXCEPTION WHEN check_violation THEN
                GET STACKED DIAGNOSTICS actual_constraint = CONSTRAINT_NAME;
                IF actual_constraint <> (table_name || '_amount_check') THEN RAISE; END IF;
                failed_as_expected := true;
            END;
            IF NOT failed_as_expected THEN RAISE EXCEPTION 'Importe % aceptado en %', invalid_amount, table_name; END IF;
            checked_count := checked_count + 1;
        END LOOP;
    END LOOP;

    -- Versiones positivas en las nueve tablas editables.
    FOREACH table_name IN ARRAY ARRAY[
        'user_settings', 'categories', 'payment_methods', 'budget_periods', 'expenses',
        'incomes', 'savings_accounts', 'transfers', 'period_category_budgets'
    ] LOOP
        failed_as_expected := false;
        BEGIN
            EXECUTE format('UPDATE public.%I SET version = 0 WHERE user_id = $1', table_name) USING user_a;
        EXCEPTION WHEN check_violation THEN
            GET STACKED DIAGNOSTICS actual_constraint = CONSTRAINT_NAME;
            IF actual_constraint <> (table_name || '_version_check') THEN RAISE; END IF;
            failed_as_expected := true;
        END;
        IF NOT failed_as_expected THEN RAISE EXCEPTION 'Versión cero aceptada en %', table_name; END IF;
        checked_count := checked_count + 1;
    END LOOP;

    -- La cascada desde Auth elimina solo los datos del usuario eliminado.
    -- Difiere las FK internas hasta eliminar todo el grafo y después fuerza
    -- su comprobación antes de verificar qué filas permanecen.
    SET CONSTRAINTS ALL DEFERRED;
    DELETE FROM auth.users WHERE id = user_b;
    SET CONSTRAINTS ALL IMMEDIATE;
    FOREACH table_name IN ARRAY ARRAY[
        'user_settings', 'categories', 'payment_methods', 'budget_periods', 'expenses',
        'incomes', 'savings_accounts', 'transfers', 'period_category_budgets', 'financial_operations'
    ] LOOP
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I WHERE user_id = $1)', table_name)
            INTO failed_as_expected USING user_b;
        IF failed_as_expected THEN RAISE EXCEPTION 'Auth no propagó el borrado a %', table_name; END IF;
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I WHERE user_id = $1)', table_name)
            INTO failed_as_expected USING user_a;
        IF NOT failed_as_expected THEN RAISE EXCEPTION 'El borrado afectó a otro usuario en %', table_name; END IF;
    END LOOP;

    RAISE NOTICE 'Smoke 001 OK: fixtures válidos, % rechazos esperados y cascada Auth aislada.', checked_count;
END;
$smoke$;

ROLLBACK;
