-- Smoke 007 para 001–007. Preparado, NO ejecutado durante su creación.
-- Ejecutar solo en pruebas como propietario/BYPASSRLS con SET ROLE.
-- Fixtures vía RPC; comprobaciones como propietario para no ocultar filas por RLS.
BEGIN ISOLATION LEVEL READ COMMITTED;
DO $smoke$
DECLARE
    user_a uuid := gen_random_uuid(); user_b uuid := gen_random_uuid();
    uid uuid; pid uuid; cat uuid; method uuid; acc uuid;
    d date := (statement_timestamp() AT TIME ZONE 'UTC')::date - 1;
    tables text[] := ARRAY[
        'expenses', 'incomes', 'transfers', 'period_category_budgets',
        'budget_periods', 'savings_accounts', 'categories', 'payment_methods',
        'financial_operations', 'user_settings'
    ];
    tbl text; confirmation text; phase integer;
    baseline jsonb := '{}'::jsonb; rows_now jsonb; expected jsonb;
    auth_before jsonb; auth_after jsonb;
    settings public.user_settings;
    failed boolean;
BEGIN
    INSERT INTO auth.users(id) VALUES (user_a), (user_b);
    FOREACH uid IN ARRAY ARRAY[user_a, user_b] LOOP
        PERFORM set_config('request.jwt.claim.sub', uid::text, true);
        PERFORM set_config('request.jwt.claims',
            jsonb_build_object('sub', uid, 'role', 'authenticated')::text, true);
        SET LOCAL ROLE authenticated;
        PERFORM public.configure_user_settings('EUR', 'UTC');
        pid := (public.create_first_period('between_paydays', d, NULL, 1000,
            gen_random_uuid(), 500)->>'id')::uuid;
        SELECT id INTO cat FROM public.create_category('Comida');
        SELECT id INTO method FROM public.create_payment_method('Tarjeta');
        acc := (public.create_savings_account('Reserva', d, 100,
            gen_random_uuid())->>'id')::uuid;
        PERFORM public.create_expense(d, 20, cat, NULL, method, NULL, NULL,
            false, gen_random_uuid());
        PERFORM public.create_income(d, 50, acc, NULL, gen_random_uuid());
        PERFORM public.create_transfer(d, 30, NULL, acc, NULL, gen_random_uuid());
        PERFORM public.create_category_budget(pid, cat, 200);
        RESET ROLE;
    END LOOP;
    -- Fuerza las FK también durante los DELETE, aunque 001 las difiere.
    SET CONSTRAINTS ALL IMMEDIATE;
    SELECT jsonb_agg(to_jsonb(u) ORDER BY u.id) INTO auth_before
        FROM auth.users u WHERE id IN (user_a, user_b);
    FOREACH uid IN ARRAY ARRAY[user_a, user_b] LOOP
        FOREACH tbl IN ARRAY tables LOOP
            EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb)
                FROM public.%I t WHERE user_id = $1', tbl) INTO rows_now USING uid;
            IF rows_now = '[]'::jsonb THEN
                RAISE EXCEPTION 'Fixture incompleto: usuario %, tabla %', uid, tbl;
            END IF;
            baseline := baseline || jsonb_build_object(uid::text || '/' || tbl, rows_now);
        END LOOP;
    END LOOP;

    PERFORM set_config('request.jwt.claim.sub', user_a::text, true);
    PERFORM set_config('request.jwt.claims',
        jsonb_build_object('sub', user_a, 'role', 'authenticated')::text, true);
    -- Fases 1–4: confirmaciones inválidas; 5: reset; 6: repetición en vacío.
    FOR phase IN 1..6 LOOP
        SET LOCAL ROLE authenticated;
        IF phase <= 4 THEN
            confirmation := (ARRAY['NO', 'borrar', 'BORRAR ', NULL]::text[])[phase];
            failed := false;
            BEGIN
                PERFORM public.reset_financial_data(confirmation);
            EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
            END;
            IF NOT failed THEN RAISE EXCEPTION 'Se aceptó confirmación inválida: %', confirmation; END IF;
        ELSE
            IF public.reset_financial_data('BORRAR') IS DISTINCT FROM '{"reset":true}'::jsonb THEN
                RAISE EXCEPTION 'Respuesta de reset incorrecta';
            END IF;
        END IF;
        RESET ROLE;
        FOREACH uid IN ARRAY ARRAY[user_a, user_b] LOOP
            FOREACH tbl IN ARRAY tables LOOP
                EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb)
                    FROM public.%I t WHERE user_id = $1', tbl) INTO rows_now USING uid;
                expected := CASE WHEN phase >= 5 AND uid = user_a THEN '[]'::jsonb
                    ELSE baseline->(uid::text || '/' || tbl) END;
                IF rows_now IS DISTINCT FROM expected THEN
                    RAISE EXCEPTION 'Datos incorrectos: fase %, usuario %, tabla %', phase, uid, tbl;
                END IF;
            END LOOP;
        END LOOP;
        SELECT jsonb_agg(to_jsonb(u) ORDER BY u.id) INTO auth_after
            FROM auth.users u WHERE id IN (user_a, user_b);
        IF auth_after IS DISTINCT FROM auth_before THEN
            RAISE EXCEPTION 'Se alteró o eliminó una cuenta de Auth';
        END IF;
    END LOOP;

    SET LOCAL ROLE authenticated;
    SELECT * INTO settings FROM public.configure_user_settings('USD', 'Europe/Madrid');
    IF (settings.user_id = user_a AND settings.currency = 'USD'
        AND settings.timezone = 'Europe/Madrid' AND settings.version = 1
        AND settings.currency_locked_at IS NULL) IS NOT TRUE THEN
        RAISE EXCEPTION 'No se pudo reiniciar la configuración financiera';
    END IF;
    RESET ROLE;

    -- anon carece de EXECUTE incluso si el contexto contiene un uid válido.
    IF has_function_privilege('anon', 'public.reset_financial_data(text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'anon tiene EXECUTE';
    END IF;
    SET LOCAL ROLE anon;
    failed := false;
    BEGIN
        PERFORM public.reset_financial_data('BORRAR');
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'anon pudo ejecutar reset'; END IF;
    RESET ROLE;

    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claims', '{}', true);
    SET LOCAL ROLE authenticated;
    failed := false;
    BEGIN
        PERFORM public.reset_financial_data('BORRAR');
    EXCEPTION WHEN SQLSTATE '28000' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó una sesión sin uid'; END IF;
    RESET ROLE;
    RAISE NOTICE 'Smoke 007 OK: confirmación, reset completo, aislamiento, Auth, repetición, configuración y permisos';
END;
$smoke$;
ROLLBACK;
