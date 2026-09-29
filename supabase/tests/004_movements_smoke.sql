-- Preparado para 001 + 002 + 003 + 004. NO ejecutado durante su preparación.
-- Ejecutar solo en entorno de pruebas como propietario/BYPASSRLS con SET ROLE.
-- Dos usuarios sintéticos, fechas relativas al día local y ROLLBACK final.
BEGIN ISOLATION LEVEL READ COMMITTED;
DO $smoke$
DECLARE
    user_a uuid := gen_random_uuid();
    user_b uuid := gen_random_uuid();
    today date := (clock_timestamp() AT TIME ZONE 'Pacific/Kiritimati')::date;
    d date := today - 10;
    cat uuid; cat2 uuid; pay uuid; pay2 uuid; acc uuid; acc2 uuid; late uuid;
    cat_b uuid; pay_b uuid; acc_b uuid;
    expense_b jsonb; income_b jsonb; transfer_b jsonb;
    created jsonb; edited jsonb; deleted jsonb; result jsonb; x jsonb; y jsonb;
    req1 uuid; req2 uuid; req3 uuid; bad_req uuid := gen_random_uuid();
    baseline jsonb; after_failure jsonb;
    command text; tbl text;
    failed boolean; fn record; n bigint; checked integer := 0;
BEGIN
    INSERT INTO auth.users(id) VALUES (user_a), (user_b);
    -- Fixtures B: llamadas como cliente, no DML financiero de administrador.
    PERFORM set_config('request.jwt.claim.sub', user_b::text, true);
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',user_b,'role','authenticated')::text,true);
    SET LOCAL ROLE authenticated;
    PERFORM public.configure_user_settings('EUR','Pacific/Kiritimati');
    PERFORM public.create_first_period('custom',d,today,100,gen_random_uuid());
    SELECT id INTO cat_b FROM public.create_category('B categoría');
    SELECT id INTO pay_b FROM public.create_payment_method('B método');
    result := public.create_savings_account('B ahorro',d,100,gen_random_uuid());
    acc_b := (result->>'id')::uuid;
    expense_b := public.create_expense(d,1,cat_b,NULL,pay_b,NULL,NULL,false,gen_random_uuid());
    income_b := public.create_income(d,1,NULL,NULL,gen_random_uuid());
    transfer_b := public.create_transfer(d,1,NULL,acc_b,NULL,gen_random_uuid());
    RESET ROLE;
    PERFORM set_config('request.jwt.claim.sub',user_a::text,true);
    PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',user_a,'role','authenticated')::text,true);
    SET LOCAL ROLE authenticated;
    PERFORM public.configure_user_settings('EUR','Pacific/Kiritimati');
    PERFORM public.create_first_period('custom',d,today,100,gen_random_uuid());
    SELECT id INTO cat FROM public.create_category('A categoría');
    SELECT id INTO cat2 FROM public.create_category('A categoría inactiva');
    SELECT id INTO pay FROM public.create_payment_method('A método');
    SELECT id INTO pay2 FROM public.create_payment_method('A método inactivo');
    result := public.create_savings_account('A ahorro',d,100,gen_random_uuid());
    acc := (result->>'id')::uuid;
    result := public.create_savings_account('A vacío',d,0,gen_random_uuid());
    acc2 := (result->>'id')::uuid;
    result := public.create_savings_account('A tardío',d+2,0,gen_random_uuid());
    late := (result->>'id')::uuid;
    PERFORM public.set_category_active(cat2,false,1);
    PERFORM public.set_payment_method_active(pay2,false,1);
    -- CRUD, versiones y retries de expense. Subtransacción aislada: restaura fixtures al finalizar.
    BEGIN
    req1 := gen_random_uuid(); req2 := gen_random_uuid(); req3 := gen_random_uuid();
    created := public.create_expense(d,10,cat,NULL,pay,NULL,NULL,false,req1);
    IF ((created->>'version')::bigint = 1 AND (created->>'user_id')::uuid = user_a) IS NOT TRUE THEN RAISE EXCEPTION 'expense creación'; END IF;
    result := public.create_expense(d,10,cat,NULL,pay,NULL,NULL,false,req1);
    IF (result = created) IS NOT TRUE THEN RAISE EXCEPTION 'expense retry create'; END IF;
    edited := public.update_expense((created->>'id')::uuid,1,d+1,12,cat,'editado',pay,'comercio','nota',true,req2);
    IF ((edited->>'version')::bigint = 2 AND (edited->>'updated_at')::timestamptz >= (created->>'updated_at')::timestamptz) IS NOT TRUE THEN RAISE EXCEPTION 'expense versión/timestamp'; END IF;
    result := public.update_expense((created->>'id')::uuid,1,d+1,12,cat,'editado',pay,'comercio','nota',true,req2);
    IF (result = edited) IS NOT TRUE THEN RAISE EXCEPTION 'expense retry update con versión vieja'; END IF;
    failed := false;
    BEGIN
        PERFORM public.update_expense((created->>'id')::uuid,1,d+1,12,cat,'editado',pay,'comercio','nota',true,gen_random_uuid());
    EXCEPTION WHEN SQLSTATE '40001' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: expense update obsoleto'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.delete_expense((created->>'id')::uuid,1,gen_random_uuid());
    EXCEPTION WHEN SQLSTATE '40001' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: expense delete obsoleto'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_expense(d+1,12,cat,'editado',pay,'comercio','nota',true,req1);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: expense payload create distinto'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_expense((created->>'id')::uuid,2,d+1,12,cat,'editado',pay,'comercio','nota',true,req2);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: expense payload update distinto'; END IF;
    checked := checked + 1;
    deleted := public.delete_expense((created->>'id')::uuid,2,req3);
    result := public.delete_expense((created->>'id')::uuid,2,req3);
    IF (result = deleted AND (deleted->>'deleted')::boolean) IS NOT TRUE THEN RAISE EXCEPTION 'expense retry delete'; END IF;
    failed := false;
    BEGIN
        PERFORM public.delete_expense((created->>'id')::uuid,3,req3);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: expense payload delete distinto'; END IF;
    checked := checked + 1;
    result := public.update_expense((created->>'id')::uuid,1,d+1,12,cat,'editado',pay,'comercio','nota',true,req2);
    IF (result = edited) IS NOT TRUE THEN RAISE EXCEPTION 'expense retry update tras borrado'; END IF;
    result := public.create_expense(d,10,cat,NULL,pay,NULL,NULL,false,req1);
    IF (result = created) IS NOT TRUE THEN RAISE EXCEPTION 'expense retry create tras borrado'; END IF;
    IF ((SELECT count(*) FROM public.expenses) = 0) IS NOT TRUE THEN RAISE EXCEPTION 'expense no duplicación'; END IF;
    RESET ROLE;
    IF ((SELECT count(*) FROM public.financial_operations WHERE user_id=user_a AND idempotency_key IN (req1,req2,req3)) = 3) IS NOT TRUE THEN RAISE EXCEPTION 'expense journal único'; END IF;
    SET LOCAL ROLE authenticated;
        RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- CRUD, versiones y retries de income. Subtransacción aislada: restaura fixtures al finalizar.
    BEGIN
    req1 := gen_random_uuid(); req2 := gen_random_uuid(); req3 := gen_random_uuid();
    created := public.create_income(d,10,acc2,NULL,req1);
    IF ((created->>'version')::bigint = 1 AND (created->>'user_id')::uuid = user_a) IS NOT TRUE THEN RAISE EXCEPTION 'income creación'; END IF;
    result := public.create_income(d,10,acc2,NULL,req1);
    IF (result = created) IS NOT TRUE THEN RAISE EXCEPTION 'income retry create'; END IF;
    edited := public.update_income((created->>'id')::uuid,1,d+1,12,acc2,'editado',req2);
    IF ((edited->>'version')::bigint = 2 AND (edited->>'updated_at')::timestamptz >= (created->>'updated_at')::timestamptz) IS NOT TRUE THEN RAISE EXCEPTION 'income versión/timestamp'; END IF;
    result := public.update_income((created->>'id')::uuid,1,d+1,12,acc2,'editado',req2);
    IF (result = edited) IS NOT TRUE THEN RAISE EXCEPTION 'income retry update con versión vieja'; END IF;
    failed := false;
    BEGIN
        PERFORM public.update_income((created->>'id')::uuid,1,d+1,12,acc2,'editado',gen_random_uuid());
    EXCEPTION WHEN SQLSTATE '40001' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: income update obsoleto'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.delete_income((created->>'id')::uuid,1,gen_random_uuid());
    EXCEPTION WHEN SQLSTATE '40001' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: income delete obsoleto'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_income(d+1,12,acc2,'editado',req1);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: income payload create distinto'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_income((created->>'id')::uuid,2,d+1,12,acc2,'editado',req2);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: income payload update distinto'; END IF;
    checked := checked + 1;
    deleted := public.delete_income((created->>'id')::uuid,2,req3);
    result := public.delete_income((created->>'id')::uuid,2,req3);
    IF (result = deleted AND (deleted->>'deleted')::boolean) IS NOT TRUE THEN RAISE EXCEPTION 'income retry delete'; END IF;
    failed := false;
    BEGIN
        PERFORM public.delete_income((created->>'id')::uuid,3,req3);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: income payload delete distinto'; END IF;
    checked := checked + 1;
    result := public.update_income((created->>'id')::uuid,1,d+1,12,acc2,'editado',req2);
    IF (result = edited) IS NOT TRUE THEN RAISE EXCEPTION 'income retry update tras borrado'; END IF;
    result := public.create_income(d,10,acc2,NULL,req1);
    IF (result = created) IS NOT TRUE THEN RAISE EXCEPTION 'income retry create tras borrado'; END IF;
    IF ((SELECT count(*) FROM public.incomes) = 0) IS NOT TRUE THEN RAISE EXCEPTION 'income no duplicación'; END IF;
    RESET ROLE;
    IF ((SELECT count(*) FROM public.financial_operations WHERE user_id=user_a AND idempotency_key IN (req1,req2,req3)) = 3) IS NOT TRUE THEN RAISE EXCEPTION 'income journal único'; END IF;
    SET LOCAL ROLE authenticated;
        RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- CRUD, versiones y retries de transfer. Subtransacción aislada: restaura fixtures al finalizar.
    BEGIN
    req1 := gen_random_uuid(); req2 := gen_random_uuid(); req3 := gen_random_uuid();
    created := public.create_transfer(d,10,NULL,acc2,NULL,req1);
    IF ((created->>'version')::bigint = 1 AND (created->>'user_id')::uuid = user_a) IS NOT TRUE THEN RAISE EXCEPTION 'transfer creación'; END IF;
    result := public.create_transfer(d,10,NULL,acc2,NULL,req1);
    IF (result = created) IS NOT TRUE THEN RAISE EXCEPTION 'transfer retry create'; END IF;
    edited := public.update_transfer((created->>'id')::uuid,1,d+1,12,NULL,acc2,'editado',req2);
    IF ((edited->>'version')::bigint = 2 AND (edited->>'updated_at')::timestamptz >= (created->>'updated_at')::timestamptz) IS NOT TRUE THEN RAISE EXCEPTION 'transfer versión/timestamp'; END IF;
    result := public.update_transfer((created->>'id')::uuid,1,d+1,12,NULL,acc2,'editado',req2);
    IF (result = edited) IS NOT TRUE THEN RAISE EXCEPTION 'transfer retry update con versión vieja'; END IF;
    failed := false;
    BEGIN
        PERFORM public.update_transfer((created->>'id')::uuid,1,d+1,12,NULL,acc2,'editado',gen_random_uuid());
    EXCEPTION WHEN SQLSTATE '40001' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: transfer update obsoleto'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.delete_transfer((created->>'id')::uuid,1,gen_random_uuid());
    EXCEPTION WHEN SQLSTATE '40001' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: transfer delete obsoleto'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_transfer(d+1,12,NULL,acc2,'editado',req1);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: transfer payload create distinto'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_transfer((created->>'id')::uuid,2,d+1,12,NULL,acc2,'editado',req2);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: transfer payload update distinto'; END IF;
    checked := checked + 1;
    deleted := public.delete_transfer((created->>'id')::uuid,2,req3);
    result := public.delete_transfer((created->>'id')::uuid,2,req3);
    IF (result = deleted AND (deleted->>'deleted')::boolean) IS NOT TRUE THEN RAISE EXCEPTION 'transfer retry delete'; END IF;
    failed := false;
    BEGIN
        PERFORM public.delete_transfer((created->>'id')::uuid,3,req3);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: transfer payload delete distinto'; END IF;
    checked := checked + 1;
    result := public.update_transfer((created->>'id')::uuid,1,d+1,12,NULL,acc2,'editado',req2);
    IF (result = edited) IS NOT TRUE THEN RAISE EXCEPTION 'transfer retry update tras borrado'; END IF;
    result := public.create_transfer(d,10,NULL,acc2,NULL,req1);
    IF (result = created) IS NOT TRUE THEN RAISE EXCEPTION 'transfer retry create tras borrado'; END IF;
    IF ((SELECT count(*) FROM public.transfers) = 0) IS NOT TRUE THEN RAISE EXCEPTION 'transfer no duplicación'; END IF;
    RESET ROLE;
    IF ((SELECT count(*) FROM public.financial_operations WHERE user_id=user_a AND idempotency_key IN (req1,req2,req3)) = 3) IS NOT TRUE THEN RAISE EXCEPTION 'transfer journal único'; END IF;
    SET LOCAL ROLE authenticated;
        RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- Entrada exacta: mismo validador para los tres tipos de movimiento.
    FOREACH command IN ARRAY ARRAY['0','-1','1.001','''NaN''::numeric','''Infinity''::numeric','''-Infinity''::numeric','1000000000000000000','NULL'] LOOP
    failed := false;
    BEGIN EXECUTE format('SELECT public.create_expense(%L,%s,%L,NULL,NULL,NULL,NULL,false,%L)',d,command,cat,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Importe inválido aceptado en expense: %',command; END IF;
    failed := false;
    BEGIN EXECUTE format('SELECT public.create_income(%L,%s,NULL,NULL,%L)',d,command,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Importe inválido aceptado en income: %',command; END IF;
    failed := false;
    BEGIN EXECUTE format('SELECT public.create_transfer(%L,%s,NULL,%L,NULL,%L)',d,command,acc,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Importe inválido aceptado en transfer: %',command; END IF;
    END LOOP;
    failed := false;
    BEGIN
        PERFORM public.create_expense(today+1,1,cat,NULL,NULL,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: fecha gasto inválida'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_income(today+1,1,NULL,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: fecha ingreso inválida'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_transfer(today+1,1,NULL,acc,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: fecha transferencia inválida'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_expense(d-1,1,cat,NULL,NULL,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: fecha gasto inválida'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_income(d-1,1,NULL,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: fecha ingreso inválida'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_transfer(d-1,1,NULL,acc,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: fecha transferencia inválida'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_expense('infinity'::date,1,cat,NULL,NULL,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: fecha gasto inválida'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_income('infinity'::date,1,NULL,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: fecha ingreso inválida'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_transfer('infinity'::date,1,NULL,acc,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: fecha transferencia inválida'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_expense(NULL::date,1,cat,NULL,NULL,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: fecha gasto inválida'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_income(NULL::date,1,NULL,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: fecha ingreso inválida'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_transfer(NULL::date,1,NULL,acc,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: fecha transferencia inválida'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_expense(d,1,cat_b,NULL,NULL,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_expense(d,1,cat,NULL,pay_b,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_expense(d,1,cat2,NULL,NULL,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_expense(d,1,cat,NULL,pay2,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_expense(d,1,NULL,NULL,NULL,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_expense(d,1,cat,NULL,NULL,NULL,NULL,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_income(d,1,acc_b,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_income(d,1,late,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_transfer(d,1,NULL,NULL,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_transfer(d,1,acc,acc,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_transfer(d,1,acc_b,NULL,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_transfer(d,1,NULL,acc_b,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_transfer(d,1,NULL,late,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_transfer(d,1,late,NULL,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_income(d,1,NULL,NULL,NULL);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    -- Referencias inactivas: conservar campo original, rechazar nueva asignación. Subtransacción aislada: restaura fixtures al finalizar.
    BEGIN
    created := public.create_expense(d,1,cat,NULL,pay,NULL,NULL,false,gen_random_uuid());
    PERFORM public.set_category_active(cat,false,1);
    PERFORM public.set_payment_method_active(pay,false,1);
    edited := public.update_expense((created->>'id')::uuid,1,d,2,cat,NULL,pay,NULL,NULL,false,gen_random_uuid());
    failed := false;
    BEGIN
        PERFORM public.update_expense((created->>'id')::uuid,2,d,2,cat2,NULL,pay,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_expense((created->>'id')::uuid,2,d,2,cat,NULL,pay2,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    x := public.create_income(d,10,acc,NULL,gen_random_uuid());
    y := public.create_transfer(d,10,acc,acc2,NULL,gen_random_uuid());
    PERFORM public.set_savings_account_active(acc,false,1);
    PERFORM public.set_savings_account_active(acc2,false,1);
    PERFORM public.update_income((x->>'id')::uuid,1,d,11,acc,NULL,gen_random_uuid());
    PERFORM public.update_transfer((y->>'id')::uuid,1,d,11,acc,acc2,NULL,gen_random_uuid());
    failed := false;
    BEGIN
        PERFORM public.update_income((x->>'id')::uuid,2,d,11,acc2,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_transfer((y->>'id')::uuid,2,d,11,acc2,acc,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_income(d,1,acc,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_transfer(d,1,NULL,acc,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_transfer(d,1,acc,NULL,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
        RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- A: transferencia día 1 válida y gasto día 2 dejan disponible -30. Subtransacción aislada: restaura fixtures al finalizar.
    BEGIN
    PERFORM public.create_transfer(d+1,80,NULL,acc,NULL,gen_random_uuid());
    PERFORM public.create_expense(d+2,50,cat,NULL,NULL,NULL,NULL,false,gen_random_uuid());
    IF ((SELECT count(*) FROM public.transfers) = 1 AND (SELECT count(*) FROM public.expenses) = 1) IS NOT TRUE THEN RAISE EXCEPTION 'A movimientos presentes'; END IF;
        RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- B: ingreso día 2 ya registrado no rescata transferencia día 1. Subtransacción aislada: restaura fixtures al finalizar.
    BEGIN
    PERFORM public.create_income(d+2,100,NULL,NULL,gen_random_uuid());
    RESET ROLE;
    SELECT jsonb_build_object(
        'expenses', (SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY id),'[]'::jsonb) FROM public.expenses e WHERE user_id=user_a),
        'incomes', (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY id),'[]'::jsonb) FROM public.incomes i WHERE user_id=user_a),
        'transfers', (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]'::jsonb) FROM public.transfers t WHERE user_id=user_a),
        'operations', (SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY id),'[]'::jsonb) FROM public.financial_operations o WHERE user_id=user_a)
    ) INTO baseline;
    SET LOCAL ROLE authenticated;
    failed := false;
    BEGIN
        PERFORM public.create_transfer(d+1,120,NULL,acc,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: B ingreso posterior'; END IF;
    checked := checked + 1;
    RESET ROLE;
    SELECT jsonb_build_object(
        'expenses', (SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY id),'[]'::jsonb) FROM public.expenses e WHERE user_id=user_a),
        'incomes', (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY id),'[]'::jsonb) FROM public.incomes i WHERE user_id=user_a),
        'transfers', (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]'::jsonb) FROM public.transfers t WHERE user_id=user_a),
        'operations', (SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY id),'[]'::jsonb) FROM public.financial_operations o WHERE user_id=user_a)
    ) INTO after_failure;
    SET LOCAL ROLE authenticated;
    IF (baseline = after_failure) IS NOT TRUE THEN RAISE EXCEPTION 'B dejó efectos parciales'; END IF;
        RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- C: gasto retroactivo invalida transferencia posterior; posterior permitido. Subtransacción aislada: restaura fixtures al finalizar.
    BEGIN
    x := public.create_transfer(d+2,80,NULL,acc,NULL,gen_random_uuid());
    RESET ROLE;
    SELECT jsonb_build_object(
        'expenses', (SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY id),'[]'::jsonb) FROM public.expenses e WHERE user_id=user_a),
        'incomes', (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY id),'[]'::jsonb) FROM public.incomes i WHERE user_id=user_a),
        'transfers', (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]'::jsonb) FROM public.transfers t WHERE user_id=user_a),
        'operations', (SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY id),'[]'::jsonb) FROM public.financial_operations o WHERE user_id=user_a)
    ) INTO baseline;
    SET LOCAL ROLE authenticated;
    failed := false;
    BEGIN
        PERFORM public.create_expense(d+1,30,cat,NULL,NULL,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: C gasto retroactivo'; END IF;
    checked := checked + 1;
    RESET ROLE;
    SELECT jsonb_build_object(
        'expenses', (SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY id),'[]'::jsonb) FROM public.expenses e WHERE user_id=user_a),
        'incomes', (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY id),'[]'::jsonb) FROM public.incomes i WHERE user_id=user_a),
        'transfers', (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]'::jsonb) FROM public.transfers t WHERE user_id=user_a),
        'operations', (SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY id),'[]'::jsonb) FROM public.financial_operations o WHERE user_id=user_a)
    ) INTO after_failure;
    SET LOCAL ROLE authenticated;
    IF (baseline = after_failure) IS NOT TRUE THEN RAISE EXCEPTION 'C dejó efectos parciales'; END IF;
    y := public.create_expense(d+3,30,cat,NULL,NULL,NULL,NULL,false,gen_random_uuid());
    RESET ROLE;
    SELECT jsonb_build_object(
        'expenses', (SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY id),'[]'::jsonb) FROM public.expenses e WHERE user_id=user_a),
        'incomes', (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY id),'[]'::jsonb) FROM public.incomes i WHERE user_id=user_a),
        'transfers', (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]'::jsonb) FROM public.transfers t WHERE user_id=user_a),
        'operations', (SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY id),'[]'::jsonb) FROM public.financial_operations o WHERE user_id=user_a)
    ) INTO baseline;
    SET LOCAL ROLE authenticated;
    failed := false;
    BEGIN
        PERFORM public.update_expense((y->>'id')::uuid,1,d+1,30,cat,NULL,NULL,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: C mover gasto hacia atrás'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_transfer((x->>'id')::uuid,1,d+3,80,NULL,acc,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: C mover transferencia a día negativo'; END IF;
    checked := checked + 1;
    RESET ROLE;
    SELECT jsonb_build_object(
        'expenses', (SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY id),'[]'::jsonb) FROM public.expenses e WHERE user_id=user_a),
        'incomes', (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY id),'[]'::jsonb) FROM public.incomes i WHERE user_id=user_a),
        'transfers', (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]'::jsonb) FROM public.transfers t WHERE user_id=user_a),
        'operations', (SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY id),'[]'::jsonb) FROM public.financial_operations o WHERE user_id=user_a)
    ) INTO after_failure;
    SET LOCAL ROLE authenticated;
    IF (baseline = after_failure) IS NOT TRUE THEN RAISE EXCEPTION 'C update cambió versión o journal'; END IF;
        RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- D: ahorro inicial 100, retirar 80 y rechazar otros 30. Subtransacción aislada: restaura fixtures al finalizar.
    BEGIN
    PERFORM public.create_transfer(d+2,80,acc,NULL,NULL,gen_random_uuid());
    RESET ROLE;
    SELECT jsonb_build_object(
        'expenses', (SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY id),'[]'::jsonb) FROM public.expenses e WHERE user_id=user_a),
        'incomes', (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY id),'[]'::jsonb) FROM public.incomes i WHERE user_id=user_a),
        'transfers', (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]'::jsonb) FROM public.transfers t WHERE user_id=user_a),
        'operations', (SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY id),'[]'::jsonb) FROM public.financial_operations o WHERE user_id=user_a)
    ) INTO baseline;
    SET LOCAL ROLE authenticated;
    failed := false;
    BEGIN
        PERFORM public.create_transfer(d+3,30,acc,NULL,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: D ahorro insuficiente'; END IF;
    checked := checked + 1;
    RESET ROLE;
    SELECT jsonb_build_object(
        'expenses', (SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY id),'[]'::jsonb) FROM public.expenses e WHERE user_id=user_a),
        'incomes', (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY id),'[]'::jsonb) FROM public.incomes i WHERE user_id=user_a),
        'transfers', (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]'::jsonb) FROM public.transfers t WHERE user_id=user_a),
        'operations', (SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY id),'[]'::jsonb) FROM public.financial_operations o WHERE user_id=user_a)
    ) INTO after_failure;
    SET LOCAL ROLE authenticated;
    IF (baseline = after_failure) IS NOT TRUE THEN RAISE EXCEPTION 'D dejó efectos parciales'; END IF;
        RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- E: reducir/borrar/mover ingreso invalida salida posterior de ahorro. Subtransacción aislada: restaura fixtures al finalizar.
    BEGIN
    x := public.create_income(d+1,100,acc2,NULL,gen_random_uuid());
    PERFORM public.create_transfer(d+2,80,acc2,NULL,NULL,gen_random_uuid());
    RESET ROLE;
    SELECT jsonb_build_object(
        'expenses', (SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY id),'[]'::jsonb) FROM public.expenses e WHERE user_id=user_a),
        'incomes', (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY id),'[]'::jsonb) FROM public.incomes i WHERE user_id=user_a),
        'transfers', (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]'::jsonb) FROM public.transfers t WHERE user_id=user_a),
        'operations', (SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY id),'[]'::jsonb) FROM public.financial_operations o WHERE user_id=user_a)
    ) INTO baseline;
    SET LOCAL ROLE authenticated;
    failed := false;
    BEGIN
        PERFORM public.update_income((x->>'id')::uuid,1,d+1,70,acc2,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: E ingreso necesario para ahorro'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_income((x->>'id')::uuid,1,d+3,100,acc2,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: E ingreso necesario para ahorro'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_income((x->>'id')::uuid,1,d+1,100,NULL,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: E ingreso necesario para ahorro'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.delete_income((x->>'id')::uuid,1,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: E ingreso necesario para ahorro'; END IF;
    checked := checked + 1;
    RESET ROLE;
    SELECT jsonb_build_object(
        'expenses', (SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY id),'[]'::jsonb) FROM public.expenses e WHERE user_id=user_a),
        'incomes', (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY id),'[]'::jsonb) FROM public.incomes i WHERE user_id=user_a),
        'transfers', (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]'::jsonb) FROM public.transfers t WHERE user_id=user_a),
        'operations', (SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY id),'[]'::jsonb) FROM public.financial_operations o WHERE user_id=user_a)
    ) INTO after_failure;
    SET LOCAL ROLE authenticated;
    IF (baseline = after_failure) IS NOT TRUE THEN RAISE EXCEPTION 'E cambió movimiento, versión, timestamp o journal'; END IF;
        RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- Ingreso disponible y transferencia de entrada necesarios para salida posterior. Subtransacción aislada: restaura fixtures al finalizar.
    BEGIN
    x := public.create_income(d+1,100,NULL,NULL,gen_random_uuid());
    y := public.create_transfer(d+1,50,acc,NULL,NULL,gen_random_uuid());
    PERFORM public.create_transfer(d+2,230,NULL,acc2,NULL,gen_random_uuid());
    RESET ROLE;
    SELECT jsonb_build_object(
        'expenses', (SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY id),'[]'::jsonb) FROM public.expenses e WHERE user_id=user_a),
        'incomes', (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY id),'[]'::jsonb) FROM public.incomes i WHERE user_id=user_a),
        'transfers', (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]'::jsonb) FROM public.transfers t WHERE user_id=user_a),
        'operations', (SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY id),'[]'::jsonb) FROM public.financial_operations o WHERE user_id=user_a)
    ) INTO baseline;
    SET LOCAL ROLE authenticated;
    failed := false;
    BEGIN
        PERFORM public.delete_income((x->>'id')::uuid,1,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_income((x->>'id')::uuid,1,d+3,100,NULL,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.delete_transfer((y->>'id')::uuid,1,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_transfer((y->>'id')::uuid,1,d+1,10,acc,NULL,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    RESET ROLE;
    SELECT jsonb_build_object(
        'expenses', (SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY id),'[]'::jsonb) FROM public.expenses e WHERE user_id=user_a),
        'incomes', (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY id),'[]'::jsonb) FROM public.incomes i WHERE user_id=user_a),
        'transfers', (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]'::jsonb) FROM public.transfers t WHERE user_id=user_a),
        'operations', (SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY id),'[]'::jsonb) FROM public.financial_operations o WHERE user_id=user_a)
    ) INTO after_failure;
    SET LOCAL ROLE authenticated;
    IF (baseline = after_failure) IS NOT TRUE THEN RAISE EXCEPTION 'Retroactividad disponible no atómica'; END IF;
        RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- Cuenta destino antigua también se valida al editar/borrar transferencia. Subtransacción aislada: restaura fixtures al finalizar.
    BEGIN
    x := public.create_transfer(d+1,90,acc,acc2,NULL,gen_random_uuid());
    PERFORM public.create_transfer(d+2,80,acc2,NULL,NULL,gen_random_uuid());
    RESET ROLE;
    SELECT jsonb_build_object(
        'expenses', (SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY id),'[]'::jsonb) FROM public.expenses e WHERE user_id=user_a),
        'incomes', (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY id),'[]'::jsonb) FROM public.incomes i WHERE user_id=user_a),
        'transfers', (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]'::jsonb) FROM public.transfers t WHERE user_id=user_a),
        'operations', (SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY id),'[]'::jsonb) FROM public.financial_operations o WHERE user_id=user_a)
    ) INTO baseline;
    SET LOCAL ROLE authenticated;
    failed := false;
    BEGIN
        PERFORM public.delete_transfer((x->>'id')::uuid,1,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_transfer((x->>'id')::uuid,1,d+2,90,acc,late,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_transfer((x->>'id')::uuid,1,d+1,70,acc,acc2,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
    RESET ROLE;
    SELECT jsonb_build_object(
        'expenses', (SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY id),'[]'::jsonb) FROM public.expenses e WHERE user_id=user_a),
        'incomes', (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY id),'[]'::jsonb) FROM public.incomes i WHERE user_id=user_a),
        'transfers', (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]'::jsonb) FROM public.transfers t WHERE user_id=user_a),
        'operations', (SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY id),'[]'::jsonb) FROM public.financial_operations o WHERE user_id=user_a)
    ) INTO after_failure;
    SET LOCAL ROLE authenticated;
    IF (baseline = after_failure) IS NOT TRUE THEN RAISE EXCEPTION 'Transferencia retroactiva no atómica'; END IF;
        RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- Semántica diaria: neto del mismo día; sin orden artificial. Subtransacción aislada: restaura fixtures al finalizar.
    BEGIN
    PERFORM public.create_income(d+1,30,NULL,NULL,gen_random_uuid());
    PERFORM public.create_transfer(d+1,120,NULL,acc2,NULL,gen_random_uuid());
    failed := false;
    BEGIN
        PERFORM public.create_expense(d+1,11,cat,NULL,NULL,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: Cierre diario disponible negativo'; END IF;
    checked := checked + 1;
    PERFORM public.create_expense(d+1,10,cat,NULL,NULL,NULL,NULL,false,gen_random_uuid());
    PERFORM public.create_transfer(d+1,120,acc2,NULL,NULL,gen_random_uuid());
        RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- Ingreso directo a ahorro no incrementa disponible. Subtransacción aislada: restaura fixtures al finalizar.
    BEGIN
    PERFORM public.create_income(d+1,100,acc2,NULL,gen_random_uuid());
    failed := false;
    BEGIN
        PERFORM public.create_transfer(d+1,101,NULL,acc,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: rechazo esperado'; END IF;
    checked := checked + 1;
        RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- Ediciones: fechas y referencias se vuelven a comprobar en la nueva fila.
    BEGIN
    x := public.create_income(d+2,1,late,NULL,gen_random_uuid());
    y := public.create_transfer(d+2,1,NULL,late,NULL,gen_random_uuid());
    created := public.create_expense(d,1,cat,NULL,pay,NULL,NULL,false,gen_random_uuid());
    failed := false;
    BEGIN PERFORM public.update_income((x->>'id')::uuid,1,d+1,1,late,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Mutación inválida aceptada'; END IF;
    failed := false;
    BEGIN PERFORM public.update_transfer((y->>'id')::uuid,1,d+1,1,NULL,late,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Mutación inválida aceptada'; END IF;
    failed := false;
    BEGIN PERFORM public.update_income((x->>'id')::uuid,1,d+2,1,acc_b,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Mutación inválida aceptada'; END IF;
    failed := false;
    BEGIN PERFORM public.update_transfer((y->>'id')::uuid,1,d+2,1,NULL,acc_b,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Mutación inválida aceptada'; END IF;
    failed := false;
    BEGIN PERFORM public.update_transfer((y->>'id')::uuid,1,d+2,1,NULL,NULL,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Mutación inválida aceptada'; END IF;
    failed := false;
    BEGIN PERFORM public.update_transfer((y->>'id')::uuid,1,d+2,1,acc,acc,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Mutación inválida aceptada'; END IF;
    failed := false;
    BEGIN PERFORM public.update_expense((created->>'id')::uuid,1,d,1,cat_b,NULL,pay,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Mutación inválida aceptada'; END IF;
    failed := false;
    BEGIN PERFORM public.update_expense((created->>'id')::uuid,1,d,1,cat,NULL,pay_b,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Mutación inválida aceptada'; END IF;
    failed := false;
    BEGIN PERFORM public.update_expense((created->>'id')::uuid,1,d-1,1,cat,NULL,pay,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Mutación inválida aceptada'; END IF;
    failed := false;
    BEGIN PERFORM public.update_income((x->>'id')::uuid,1,today+1,1,late,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Mutación inválida aceptada'; END IF;
    failed := false;
    BEGIN PERFORM public.update_transfer((y->>'id')::uuid,1,today+1,1,NULL,late,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Mutación inválida aceptada'; END IF;
    RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE='Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- Fixture administrativo de período cerrado, NO implementa RPC de cierre.
    -- Los retries siguen devolviendo su instantánea; nuevas mutaciones fallan.
    BEGIN
    req1 := gen_random_uuid(); req2 := gen_random_uuid(); req3 := gen_random_uuid();
    created := public.create_expense(d,1,cat,NULL,NULL,NULL,NULL,false,req1);
    x := public.create_income(d,1,NULL,NULL,req2);
    y := public.create_transfer(d,1,NULL,acc,NULL,req3);
    RESET ROLE;
    UPDATE public.budget_periods SET status='closed',closing_balance=99,closed_at=clock_timestamp()
        WHERE user_id=user_a;
    SET LOCAL ROLE authenticated;
    result := public.create_expense(d,1,cat,NULL,NULL,NULL,NULL,false,req1);
    IF result IS DISTINCT FROM created THEN RAISE EXCEPTION 'Retry gasto con período cerrado'; END IF;
    result := public.create_income(d,1,NULL,NULL,req2);
    IF result IS DISTINCT FROM x THEN RAISE EXCEPTION 'Retry ingreso con período cerrado'; END IF;
    result := public.create_transfer(d,1,NULL,acc,NULL,req3);
    IF result IS DISTINCT FROM y THEN RAISE EXCEPTION 'Retry transferencia con período cerrado'; END IF;
    failed := false;
    BEGIN PERFORM public.create_expense(d,1,cat,NULL,NULL,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Mutación inválida aceptada'; END IF;
    failed := false;
    BEGIN PERFORM public.update_expense((created->>'id')::uuid,1,d,1,cat,NULL,NULL,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Mutación inválida aceptada'; END IF;
    failed := false;
    BEGIN PERFORM public.delete_expense((created->>'id')::uuid,1,bad_req);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Mutación inválida aceptada'; END IF;
    failed := false;
    BEGIN PERFORM public.create_income(d,1,NULL,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Mutación inválida aceptada'; END IF;
    failed := false;
    BEGIN PERFORM public.update_income((x->>'id')::uuid,1,d,1,NULL,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Mutación inválida aceptada'; END IF;
    failed := false;
    BEGIN PERFORM public.delete_income((x->>'id')::uuid,1,bad_req);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Mutación inválida aceptada'; END IF;
    failed := false;
    BEGIN PERFORM public.create_transfer(d,1,NULL,acc,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Mutación inválida aceptada'; END IF;
    failed := false;
    BEGIN PERFORM public.update_transfer((y->>'id')::uuid,1,d,1,NULL,acc,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Mutación inválida aceptada'; END IF;
    failed := false;
    BEGIN PERFORM public.delete_transfer((y->>'id')::uuid,1,bad_req);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true; END;
    IF NOT failed THEN RAISE EXCEPTION 'Mutación inválida aceptada'; END IF;
    RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE='Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- B tiene una fila de cada tipo; A no debe verlas ni mutarlas.
    IF ((SELECT count(*) FROM public.expenses) = 0) IS NOT TRUE THEN RAISE EXCEPTION 'expense RLS filtra B'; END IF;
    failed := false;
    BEGIN
        PERFORM public.update_expense((expense_b->>'id')::uuid,1,d,1,cat,NULL,NULL,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: expense update B'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.delete_expense((expense_b->>'id')::uuid,1,bad_req);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: expense delete B'; END IF;
    checked := checked + 1;
    IF ((SELECT count(*) FROM public.incomes) = 0) IS NOT TRUE THEN RAISE EXCEPTION 'income RLS filtra B'; END IF;
    failed := false;
    BEGIN
        PERFORM public.update_income((income_b->>'id')::uuid,1,d,1,NULL,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: income update B'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.delete_income((income_b->>'id')::uuid,1,bad_req);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: income delete B'; END IF;
    checked := checked + 1;
    IF ((SELECT count(*) FROM public.transfers) = 0) IS NOT TRUE THEN RAISE EXCEPTION 'transfer RLS filtra B'; END IF;
    failed := false;
    BEGIN
        PERFORM public.update_transfer((transfer_b->>'id')::uuid,1,d,1,NULL,acc,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: transfer update B'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.delete_transfer((transfer_b->>'id')::uuid,1,bad_req);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: transfer delete B'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM (SELECT count(*) FROM public.financial_operations);
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: journal privado'; END IF;
    checked := checked + 1;
    FOREACH tbl IN ARRAY ARRAY['expenses','incomes','transfers','financial_operations'] LOOP
        FOREACH command IN ARRAY ARRAY[
            format('INSERT INTO public.%I DEFAULT VALUES',tbl),
            format('UPDATE public.%I SET user_id=user_id',tbl),
            format('DELETE FROM public.%I',tbl)
        ] LOOP
            failed := false;
            BEGIN EXECUTE command;
            EXCEPTION WHEN insufficient_privilege THEN failed := true; END;
            IF NOT failed THEN RAISE EXCEPTION 'DML directo autorizado: %',command; END IF;
        END LOOP;
    END LOOP;
    RESET ROLE;
    -- ACL de las nueve RPC y de todos los helpers privados.
    n := 0;
    FOR fn IN SELECT p.oid,p.proname,p.prosecdef,p.proconfig FROM pg_proc p
        JOIN pg_namespace ns ON ns.oid=p.pronamespace
        WHERE ns.nspname='public' AND p.proname = ANY(ARRAY[
            'create_expense','update_expense','delete_expense',
            'create_income','update_income','delete_income',
            'create_transfer','update_transfer','delete_transfer'])
    LOOP
        n := n+1;
        IF NOT fn.prosecdef OR NOT ('search_path=""' = ANY(fn.proconfig))
            OR has_function_privilege('anon',fn.oid,'EXECUTE')
            OR NOT has_function_privilege('authenticated',fn.oid,'EXECUTE')
            OR position('private.lock_current_user()' IN pg_get_functiondef(fn.oid))=0 THEN
            RAISE EXCEPTION 'Seguridad de RPC incorrecta: %',fn.proname;
        END IF;
    END LOOP;
    IF n<>9 THEN RAISE EXCEPTION 'Se esperaban nueve RPC'; END IF;
    FOR fn IN SELECT p.oid FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace WHERE ns.nspname='private' LOOP
        IF has_function_privilege('anon',fn.oid,'EXECUTE') OR has_function_privilege('authenticated',fn.oid,'EXECUTE') THEN
            RAISE EXCEPTION 'Helper privado expuesto';
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM public.financial_operations WHERE user_id=user_a AND idempotency_key=bad_req) THEN
        RAISE EXCEPTION 'Un fallo dejó registro de idempotencia';
    END IF;
    PERFORM set_config('request.jwt.claim.sub','',true);
    PERFORM set_config('request.jwt.claims','{}',true);
    SET LOCAL ROLE anon;

    failed := false;
    BEGIN
        PERFORM public.create_expense(d,1,cat,NULL,NULL,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: anon create_expense'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_expense((expense_b->>'id')::uuid,1,d,1,cat,NULL,NULL,NULL,NULL,false,bad_req);
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: anon update_expense'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.delete_expense((expense_b->>'id')::uuid,1,bad_req);
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: anon delete_expense'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_income(d,1,NULL,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: anon create_income'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_income((income_b->>'id')::uuid,1,d,1,NULL,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: anon update_income'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.delete_income((income_b->>'id')::uuid,1,bad_req);
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: anon delete_income'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_transfer(d,1,NULL,acc,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: anon create_transfer'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_transfer((transfer_b->>'id')::uuid,1,d,1,NULL,acc,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: anon update_transfer'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.delete_transfer((transfer_b->>'id')::uuid,1,bad_req);
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: anon delete_transfer'; END IF;
    checked := checked + 1;
    RESET ROLE;
    SET LOCAL ROLE authenticated;
    failed := false;
    BEGIN
        PERFORM public.create_income(d,1,NULL,NULL,bad_req);
    EXCEPTION WHEN SQLSTATE '28000' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: sesión sin uid'; END IF;
    checked := checked + 1;
    RESET ROLE;
    RAISE NOTICE 'Smoke 004 OK: CRUD, retries, versiones, dinero, fechas, referencias, A–E, atomicidad y seguridad (% rechazos)',checked;
END;
$smoke$;
ROLLBACK;
