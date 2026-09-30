-- Preparado para 001–008. Ejecutar solo en una base de pruebas como
-- propietario/BYPASSRLS. Todas las filas sintéticas se revierten al final.
BEGIN ISOLATION LEVEL READ COMMITTED;

DO $smoke$
DECLARE
    user_a uuid := gen_random_uuid();
    user_b uuid := gen_random_uuid();
    user_c uuid := gen_random_uuid();
    today date := (clock_timestamp() AT TIME ZONE 'Pacific/Kiritimati')::date;
    d date := today - 2;
    period_a uuid;
    account_id uuid;
    account_b uuid;
    income_zero uuid;
    transfer_zero uuid;
    balance_account uuid;
    legacy_account uuid;
    corrected_account uuid;
    historical_empty uuid;
    category_unused uuid;
    category_used uuid;
    category_budget uuid;
    method_unused uuid;
    method_used uuid;
    expense_id uuid;
    result jsonb;
    retry jsonb;
    request_id uuid;
    failed boolean;
    old_name text;
BEGIN
    INSERT INTO auth.users(id) VALUES (user_a),(user_b),(user_c);

    -- Usuario B: objeto ajeno para comprobar ownership sin revelar existencia.
    PERFORM set_config('request.jwt.claim.sub',user_b::text,true);
    PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',user_b,'role','authenticated')::text,true);
    SET LOCAL ROLE authenticated;
    PERFORM public.configure_user_settings('EUR','Pacific/Kiritimati');
    PERFORM public.create_first_period('custom',d,today+2,100,gen_random_uuid());
    result := public.create_savings_account('Cuenta B',today,0,gen_random_uuid());
    account_b := (result->>'id')::uuid;

    -- Apertura sin movimientos, pero ya incluida en un contexto cerrado: no se
    -- fuerza hard delete aunque el saldo sea cero.
    RESET ROLE;
    PERFORM set_config('request.jwt.claim.sub',user_c::text,true);
    PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',user_c,'role','authenticated')::text,true);
    SET LOCAL ROLE authenticated;
    PERFORM public.configure_user_settings('EUR','Pacific/Kiritimati');
    RESET ROLE;
    INSERT INTO public.budget_periods(user_id,mode,start_date,end_date,status,
        opening_balance,closing_balance,closed_at)
        VALUES (user_c,'custom',d,today,'closed',0,0,clock_timestamp());
    SET LOCAL ROLE authenticated;
    result := public.create_savings_account('Apertura histórica',today,0,gen_random_uuid());
    historical_empty := (result->>'id')::uuid;
    failed := false;
    BEGIN
        PERFORM public.correct_savings_opening_balance(historical_empty,1,1,gen_random_uuid());
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'se corrigió una apertura en historia cerrada'; END IF;
    result := public.delete_savings_account(historical_empty,1,gen_random_uuid());
    IF result->>'mode' <> 'soft_deleted'
        OR (SELECT is_active FROM public.savings_accounts WHERE id=historical_empty) THEN
        RAISE EXCEPTION 'se forzó hard delete en contexto histórico cerrado';
    END IF;

    RESET ROLE;
    PERFORM set_config('request.jwt.claim.sub',user_a::text,true);
    PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',user_a,'role','authenticated')::text,true);
    SET LOCAL ROLE authenticated;
    PERFORM public.configure_user_settings('EUR','Pacific/Kiritimati');
    result := public.create_first_period('custom',d,today+2,100,gen_random_uuid());
    period_a := (result->>'id')::uuid;

    -- 1, 6: sin movimientos => hard delete; el retry devuelve el comprobante
    -- aun cuando la fila ya no existe.
    result := public.create_savings_account('Error de apertura',today,850,gen_random_uuid());
    account_id := (result->>'id')::uuid;
    request_id := gen_random_uuid();
    result := public.delete_savings_account(account_id,1,request_id);
    retry := public.delete_savings_account(account_id,1,request_id);
    IF result->>'mode' <> 'hard_deleted' OR retry IS DISTINCT FROM result
        OR EXISTS (SELECT 1 FROM public.savings_accounts WHERE id=account_id) THEN
        RAISE EXCEPTION 'hard delete/idempotencia de ahorro incorrectos';
    END IF;
    failed := false;
    BEGIN
        PERFORM public.delete_savings_account(account_id,2,request_id);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'request_id aceptó parámetros distintos'; END IF;
    RESET ROLE;
    IF (SELECT count(*) FROM public.financial_operations
        WHERE user_id=user_a AND idempotency_key=request_id
          AND operation_type='delete_savings_account') <> 1 THEN
        RAISE EXCEPTION 'journal de hard delete incorrecto';
    END IF;
    SET LOCAL ROLE authenticated;

    -- Corrección de apertura: única RPC, con versión e idempotencia.
    result := public.create_savings_account('Corregible',today,9,gen_random_uuid());
    corrected_account := (result->>'id')::uuid;
    request_id := gen_random_uuid();
    result := public.correct_savings_opening_balance(corrected_account,7.50,1,request_id);
    retry := public.correct_savings_opening_balance(corrected_account,7.50,1,request_id);
    IF retry IS DISTINCT FROM result OR (SELECT opening_balance FROM public.savings_accounts WHERE id=corrected_account) <> 7.50
        OR (SELECT version FROM public.savings_accounts WHERE id=corrected_account) <> 2 THEN
        RAISE EXCEPTION 'corrección/idempotencia de apertura incorrectas';
    END IF;
    failed := false;
    BEGIN
        PERFORM public.correct_savings_opening_balance(corrected_account,8,1,gen_random_uuid());
    EXCEPTION WHEN SQLSTATE '40001' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'corrección aceptó expected_version obsoleta'; END IF;

    -- 2, 5, 9: ingreso histórico y saldo cero => soft delete; referencias y
    -- nombre histórico intactos; el nombre se puede reutilizar activo.
    result := public.create_savings_account('Ingreso cero',d,0,gen_random_uuid());
    income_zero := (result->>'id')::uuid;
    PERFORM public.create_income(d,10,income_zero,'Histórico',gen_random_uuid());
    PERFORM public.create_transfer(d+1,10,income_zero,NULL,'Vaciar',gen_random_uuid());
    failed := false;
    BEGIN
        PERFORM public.correct_savings_opening_balance(income_zero,1,1,gen_random_uuid());
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'se corrigió apertura con movimientos'; END IF;
    request_id := gen_random_uuid();
    result := public.delete_savings_account(income_zero,1,request_id);
    retry := public.delete_savings_account(income_zero,1,request_id);
    IF result->>'mode' <> 'soft_deleted' OR retry IS DISTINCT FROM result
        OR (SELECT is_active FROM public.savings_accounts WHERE id=income_zero)
        OR NOT EXISTS (SELECT 1 FROM public.incomes WHERE savings_account_id=income_zero)
        OR NOT EXISTS (SELECT 1 FROM public.transfers WHERE from_savings_account_id=income_zero) THEN
        RAISE EXCEPTION 'soft delete/idempotencia con income incorrecto';
    END IF;
    RESET ROLE;
    IF (SELECT count(*) FROM public.financial_operations
        WHERE user_id=user_a AND idempotency_key=request_id
          AND operation_type='delete_savings_account') <> 1 THEN
        RAISE EXCEPTION 'journal de soft delete incorrecto';
    END IF;
    SET LOCAL ROLE authenticated;
    result := public.create_savings_account(' ingreso CERO ',today,0,gen_random_uuid());
    account_id := (result->>'id')::uuid;
    IF NOT EXISTS (SELECT 1 FROM public.savings_accounts
        WHERE id=account_id AND is_active) THEN
        RAISE EXCEPTION 'nombre de cuenta borrada no reutilizable';
    END IF;
    failed := false;
    BEGIN
        PERFORM public.create_savings_account('INGRESO CERO',today,0,gen_random_uuid());
    EXCEPTION WHEN unique_violation THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'se aceptaron dos nombres de cuenta activos equivalentes'; END IF;

    -- 3: historial compuesto solo por transferencia y saldo cero.
    result := public.create_savings_account('Transferencia cero',d,10,gen_random_uuid());
    transfer_zero := (result->>'id')::uuid;
    PERFORM public.create_transfer(d,10,transfer_zero,NULL,NULL,gen_random_uuid());
    result := public.delete_savings_account(transfer_zero,1,gen_random_uuid());
    IF result->>'mode' <> 'soft_deleted' OR (SELECT is_active FROM public.savings_accounts WHERE id=transfer_zero) THEN
        RAISE EXCEPTION 'soft delete con transferencia incorrecto';
    END IF;

    -- 4: una cuenta con historia y saldo distinto de cero se conserva y
    -- responde mediante código estable, no por texto de excepción.
    result := public.create_savings_account('Con saldo',d,10,gen_random_uuid());
    balance_account := (result->>'id')::uuid;
    PERFORM public.create_income(d,5,balance_account,NULL,gen_random_uuid());
    request_id := gen_random_uuid();
    result := public.delete_savings_account(balance_account,1,request_id);
    IF result->>'mode' <> 'blocked' OR result->>'code' <> 'ACCOUNT_HAS_BALANCE'
        OR (result->>'balance')::numeric <> 15
        OR (SELECT is_active FROM public.savings_accounts WHERE id=balance_account) IS NOT TRUE
        OR (SELECT version FROM public.savings_accounts WHERE id=balance_account) <> 1 THEN
        RAISE EXCEPTION 'bloqueo por saldo incorrecto';
    END IF;
    RESET ROLE;
    IF EXISTS (SELECT 1 FROM public.financial_operations
        WHERE user_id=user_a AND idempotency_key=request_id) THEN
        RAISE EXCEPTION 'bloqueo por saldo quedó registrado como éxito';
    END IF;
    SET LOCAL ROLE authenticated;
    -- Los movimientos no cambian la versión de la cuenta: tras dejarla a cero,
    -- la misma petición lógica puede completarse y queda registrada una sola vez.
    PERFORM public.create_transfer(today,15,balance_account,NULL,'Resolver saldo',gen_random_uuid());
    retry := public.delete_savings_account(balance_account,1,request_id);
    IF retry->>'mode' <> 'soft_deleted'
        OR (SELECT is_active FROM public.savings_accounts WHERE id=balance_account) THEN
        RAISE EXCEPTION 'retry tras resolver saldo no completó el soft delete';
    END IF;
    RESET ROLE;
    IF (SELECT count(*) FROM public.financial_operations
        WHERE user_id=user_a AND idempotency_key=request_id
          AND operation_type='delete_savings_account') <> 1 THEN
        RAISE EXCEPTION 'journal tras resolver saldo incorrecto';
    END IF;
    SET LOCAL ROLE authenticated;

    -- 7: versión obsoleta; 8: usuario ajeno.
    failed := false;
    BEGIN
        PERFORM public.delete_savings_account(balance_account,99,gen_random_uuid());
    EXCEPTION WHEN SQLSTATE '40001' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'se aceptó expected_version incorrecta'; END IF;
    failed := false;
    BEGIN
        PERFORM public.delete_savings_account(account_b,1,gen_random_uuid());
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'se aceptó cuenta ajena'; END IF;

    -- 10: legacy inactive con saldo sigue en la lectura canónica y en el total.
    result := public.create_savings_account('Legacy pendiente',today,7,gen_random_uuid());
    legacy_account := (result->>'id')::uuid;
    PERFORM public.set_savings_account_active(legacy_account,false,1);
    result := public.get_savings_balances();
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(result) item
        WHERE (item->>'id')::uuid=legacy_account AND NOT (item->>'is_active')::boolean
          AND (item->>'current_balance')::numeric=7) THEN
        RAISE EXCEPTION 'legacy inactive con saldo desapareció de la lectura';
    END IF;

    -- 11–17: hard/soft delete de catálogos y conservación de referencias.
    SELECT id INTO category_unused FROM public.create_category('Sin usar');
    result := public.delete_category(category_unused,1);
    IF result->>'mode' <> 'hard_deleted' OR EXISTS (SELECT 1 FROM public.categories WHERE id=category_unused) THEN
        RAISE EXCEPTION 'hard delete de categoría incorrecto';
    END IF;
    SELECT id INTO method_unused FROM public.create_payment_method('Efectivo temporal');
    result := public.delete_payment_method(method_unused,1);
    IF result->>'mode' <> 'hard_deleted' OR EXISTS (SELECT 1 FROM public.payment_methods WHERE id=method_unused) THEN
        RAISE EXCEPTION 'hard delete de método incorrecto';
    END IF;

    SELECT id INTO category_used FROM public.create_category('Histórica');
    SELECT id INTO method_used FROM public.create_payment_method('Visa histórica');
    result := public.create_expense(today,1,category_used,NULL,method_used,NULL,NULL,false,gen_random_uuid());
    expense_id := (result->>'id')::uuid;
    old_name := (SELECT name FROM public.categories WHERE id=category_used);
    result := public.delete_category(category_used,1);
    IF result->>'mode' <> 'soft_deleted' OR (SELECT is_active FROM public.categories WHERE id=category_used)
        OR (SELECT category_id FROM public.expenses WHERE id=expense_id) <> category_used
        OR (SELECT name FROM public.categories WHERE id=category_used) <> old_name THEN
        RAISE EXCEPTION 'soft delete/histórico de categoría incorrecto';
    END IF;
    result := public.delete_payment_method(method_used,1);
    IF result->>'mode' <> 'soft_deleted' OR (SELECT is_active FROM public.payment_methods WHERE id=method_used)
        OR (SELECT payment_method_id FROM public.expenses WHERE id=expense_id) <> method_used
        OR (SELECT name FROM public.payment_methods WHERE id=method_used) <> 'Visa histórica' THEN
        RAISE EXCEPTION 'soft delete/histórico de método incorrecto';
    END IF;
    SELECT id INTO category_unused FROM public.create_category(' HISTÓRICA ');
    SELECT id INTO method_unused FROM public.create_payment_method(' visa HISTÓRICA ');
    IF category_unused = category_used OR method_unused = method_used THEN
        RAISE EXCEPTION 'nombres de catálogos borrados no reutilizables';
    END IF;
    failed := false;
    BEGIN PERFORM public.create_category('histórica');
    EXCEPTION WHEN unique_violation THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'se aceptaron dos categorías activas equivalentes'; END IF;
    failed := false;
    BEGIN PERFORM public.create_payment_method('VISA HISTÓRICA');
    EXCEPTION WHEN unique_violation THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'se aceptaron dos métodos activos equivalentes'; END IF;

    SELECT id INTO category_budget FROM public.create_category('Con presupuesto');
    PERFORM public.create_category_budget(period_a,category_budget,20);
    result := public.delete_category(category_budget,1);
    IF result->>'mode' <> 'soft_deleted' OR (SELECT is_active FROM public.categories WHERE id=category_budget)
        OR NOT EXISTS (SELECT 1 FROM public.period_category_budgets WHERE category_id=category_budget) THEN
        RAISE EXCEPTION 'soft delete de categoría presupuestada incorrecto';
    END IF;

    -- La gestión cotidiana no devuelve inactivos, pero las tablas conservan los
    -- nombres para movimientos/presupuestos históricos.
    result := public.get_catalog_management();
    IF EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(result->'categories') item
        WHERE (item->>'id')::uuid IN (category_used,category_budget))
      OR EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(result->'methods') item
        WHERE (item->>'id')::uuid=method_used) THEN
        RAISE EXCEPTION 'catálogos borrados visibles en gestión normal';
    END IF;

    -- Los helpers y el journal siguen privados; las RPC nuevas no se conceden a anon.
    RESET ROLE;
    PERFORM set_config('request.jwt.claim.sub','',true);
    SET LOCAL ROLE anon;
    failed := false;
    BEGIN PERFORM public.get_catalog_management();
    EXCEPTION WHEN insufficient_privilege THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'anon pudo ejecutar RPC 008'; END IF;

    RAISE NOTICE '008 smoke correcto';
END;
$smoke$;

ROLLBACK;
