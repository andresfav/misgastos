-- Preparado para 001–005. NO ejecutado durante su preparación.
-- Solo entorno de pruebas, propietario/BYPASSRLS con SET ROLE.
-- Usuarios sintéticos, fecha local, escenarios aislados y ROLLBACK final.
-- Si una aserción aborta el DO, la transacción queda abortada: no puede confirmar fixtures.
BEGIN ISOLATION LEVEL READ COMMITTED;
DO $smoke$
DECLARE
    user_a uuid := gen_random_uuid(); user_b uuid := gen_random_uuid();
    today date := (clock_timestamp() AT TIME ZONE 'Pacific/Kiritimati')::date;
    ys date := date_trunc('year',today::timestamp)::date;
    ms date := date_trunc('month',today::timestamp)::date;
    ye date := (ys + interval '1 year - 1 day')::date;
    me date := (ms + interval '1 month - 1 day')::date;
    d date := today-10;
    pid uuid; pid_b uuid; cat uuid; cat2 uuid; cat_b uuid; budget_b uuid;
    acc uuid; acc2 uuid; bid uuid; new_id uuid;
    req uuid; bad uuid := gen_random_uuid();
    result jsonb; original jsonb; x jsonb; y jsonb; z jsonb;
    baseline jsonb; after_failure jsonb;
    pr public.budget_periods; br public.period_category_budgets;
    failed boolean; checked integer := 0; n integer; fn record;
    mode_name text; tbl text; command text; amount_text text;
BEGIN
    INSERT INTO auth.users(id) VALUES (user_a),(user_b);
    PERFORM set_config('request.jwt.claim.sub',user_b::text,true);
    PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',user_b,'role','authenticated')::text,true);
    SET LOCAL ROLE authenticated;
    PERFORM public.configure_user_settings('EUR','Pacific/Kiritimati');
    result := public.create_first_period('between_paydays',ys-10,NULL,100,gen_random_uuid());
    pid_b := (result->>'id')::uuid;
    SELECT id INTO cat_b FROM public.create_category('B categoría');
    SELECT id INTO budget_b FROM public.create_category_budget(pid_b,cat_b,20);
    RESET ROLE;
    PERFORM set_config('request.jwt.claim.sub',user_a::text,true);
    PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',user_a,'role','authenticated')::text,true);
    SET LOCAL ROLE authenticated;
    PERFORM public.configure_user_settings('EUR','Pacific/Kiritimati');
    result := public.create_first_period('between_paydays',ys-10,NULL,100,gen_random_uuid());
    pid := (result->>'id')::uuid;
    SELECT id INTO cat FROM public.create_category('A categoría');
    SELECT id INTO cat2 FROM public.create_category('A otra categoría');
    result := public.create_savings_account('A ahorro',ys-10,100,gen_random_uuid());
    acc := (result->>'id')::uuid;
    result := public.create_savings_account('A otro ahorro',ys-10,0,gen_random_uuid());
    acc2 := (result->>'id')::uuid;
    -- Presupuestos: cero, NULL, versiones, categorías inactivas e independencia; subtransacción que restaura fixtures.
    BEGIN
    RESET ROLE;
    SELECT jsonb_build_object(
        'budget_periods',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.budget_periods r WHERE user_id=user_a),
        'period_category_budgets',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.period_category_budgets r WHERE user_id=user_a),
        'expenses',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.expenses r WHERE user_id=user_a),
        'incomes',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.incomes r WHERE user_id=user_a),
        'transfers',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.transfers r WHERE user_id=user_a),
        'financial_operations',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.financial_operations r WHERE user_id=user_a)
    ) INTO baseline;
    SET LOCAL ROLE authenticated;
    SELECT * INTO pr FROM public.set_general_budget(pid,50,1);
    IF (pr.general_budget=50 AND pr.version=2 AND pr.opening_balance=100 AND pr.updated_at>=pr.created_at) IS NOT TRUE THEN RAISE EXCEPTION 'presupuesto general positivo'; END IF;
    SELECT * INTO pr FROM public.set_general_budget(pid,0,2);
    IF (pr.general_budget=0 AND pr.version=3) IS NOT TRUE THEN RAISE EXCEPTION 'presupuesto general cero'; END IF;
    SELECT * INTO pr FROM public.set_general_budget(pid,NULL,3);
    IF (pr.general_budget IS NULL AND pr.version=4) IS NOT TRUE THEN RAISE EXCEPTION 'quitar presupuesto general'; END IF;
    failed := false;
    BEGIN
        PERFORM public.set_general_budget(pid,1,3);
    EXCEPTION WHEN SQLSTATE '40001' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: general obsoleto'; END IF;
    checked := checked + 1;
    SELECT * INTO br FROM public.create_category_budget(pid,cat,0);
    bid := br.id;
    IF (br.version=1 AND br.amount=0) IS NOT TRUE THEN RAISE EXCEPTION 'categoría cero y versión inicial'; END IF;
    failed := false;
    BEGIN
        PERFORM public.create_category_budget(pid,cat,1);
    EXCEPTION WHEN SQLSTATE '23505' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: duplicado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_category_budget(pid,cat_b,1);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: categoría ajena'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_category_budget(pid,cat2,NULL);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: importe categoría NULL'; END IF;
    checked := checked + 1;
    PERFORM public.set_category_active(cat2,false,1);
    failed := false;
    BEGIN
        PERFORM public.create_category_budget(pid,cat2,1);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: categoría inactiva'; END IF;
    checked := checked + 1;
    PERFORM public.set_category_active(cat,false,1);
    SELECT * INTO br FROM public.update_category_budget(bid,1,500);
    IF (br.version=2 AND br.amount=500 AND br.category_id=cat AND br.period_id=pid AND br.updated_at>=br.created_at) IS NOT TRUE THEN RAISE EXCEPTION 'actualizar categoría inactiva'; END IF;
    failed := false;
    BEGIN
        PERFORM public.update_category_budget(bid,1,600);
    EXCEPTION WHEN SQLSTATE '40001' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: update categoría obsoleto'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.delete_category_budget(bid,1);
    EXCEPTION WHEN SQLSTATE '40001' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: delete categoría obsoleto'; END IF;
    checked := checked + 1;
    result := public.delete_category_budget(bid,2);
    IF ((result->>'deleted')::boolean AND NOT EXISTS(SELECT 1 FROM public.period_category_budgets WHERE id=bid)) IS NOT TRUE THEN RAISE EXCEPTION 'borrado físico categoría inactiva'; END IF;
    RESET ROLE;
    SELECT jsonb_build_object(
        'budget_periods',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.budget_periods r WHERE user_id=user_a),
        'period_category_budgets',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.period_category_budgets r WHERE user_id=user_a),
        'expenses',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.expenses r WHERE user_id=user_a),
        'incomes',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.incomes r WHERE user_id=user_a),
        'transfers',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.transfers r WHERE user_id=user_a),
        'financial_operations',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.financial_operations r WHERE user_id=user_a)
    ) INTO after_failure;
    SET LOCAL ROLE authenticated;
    IF ((baseline-'budget_periods')=(after_failure-'budget_periods') AND (SELECT opening_balance FROM public.budget_periods WHERE id=pid)=100) IS NOT TRUE THEN RAISE EXCEPTION 'planificación no cambia movimientos ni journal ni saldo inicial'; END IF;
    RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- Importes inválidos en todas las entradas de presupuesto; subtransacción que restaura fixtures.
    BEGIN
    SELECT id INTO bid FROM public.create_category_budget(pid,cat,1);
    FOREACH amount_text IN ARRAY ARRAY['-1','1.001','''NaN''::numeric','''Infinity''::numeric','''-Infinity''::numeric','1000000000000000000'] LOOP
    failed := false;
    BEGIN
        EXECUTE format('SELECT public.set_general_budget(%L,%s,1)',pid,amount_text);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: importe inválido'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        EXECUTE format('SELECT public.create_category_budget(%L,%L,%s)',pid,cat2,amount_text);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: importe inválido'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        EXECUTE format('SELECT public.update_category_budget(%L,1,%s)',bid,amount_text);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: importe inválido'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        EXECUTE format('SELECT public.advance_period(%L,1,''between_paydays'',%L,NULL,%L,%s)',pid,today,bad,amount_text);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: importe inválido'; END IF;
    checked := checked + 1;
    END LOOP;
    RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- Fórmula completa, sobrepresupuesto permitido, cierre positivo e idempotencia; subtransacción que restaura fixtures.
    BEGIN
    PERFORM public.set_general_budget(pid,0,1);
    SELECT id INTO bid FROM public.create_category_budget(pid,cat,0);
    x := public.create_income(d,30,NULL,NULL,gen_random_uuid());
    PERFORM public.create_income(d,999,acc,NULL,gen_random_uuid());
    y := public.create_transfer(d,20,acc,NULL,NULL,gen_random_uuid());
    PERFORM public.create_transfer(d,40,NULL,acc,NULL,gen_random_uuid());
    PERFORM public.create_transfer(d,25,acc,acc2,NULL,gen_random_uuid());
    z := public.create_expense(d,50,cat,NULL,NULL,NULL,NULL,false,gen_random_uuid());
    req := gen_random_uuid();
    original := public.advance_period(pid,2,'between_paydays',today,NULL,req);
    new_id := (original->'opened_period'->>'id')::uuid;
    IF ((original->'closed_period'->>'closing_balance')::numeric=60 AND (original->'opened_period'->>'opening_balance')::numeric=60) IS NOT TRUE THEN RAISE EXCEPTION 'fórmula 100+30+20-40-50=60'; END IF;
    IF ((original->'closed_period'->>'end_date')::date=today-1 AND original->'opened_period'->>'end_date' IS NULL) IS NOT TRUE THEN RAISE EXCEPTION 'final entre nóminas'; END IF;
    IF (original->'closed_period'->>'closed_at' IS NOT NULL AND (original->'closed_period'->>'version')::bigint=3 AND (original->'opened_period'->>'version')::bigint=1 AND (original->'closed_period'->>'updated_at')::timestamptz >= (original->'closed_period'->>'created_at')::timestamptz) IS NOT TRUE THEN RAISE EXCEPTION 'timestamps y versiones cierre'; END IF;
    IF ((SELECT count(*) FROM public.budget_periods WHERE status='closed')=1 AND (SELECT count(*) FROM public.budget_periods WHERE status='open')=1) IS NOT TRUE THEN RAISE EXCEPTION 'un cerrado y un abierto'; END IF;
    IF (original->'opened_period'->>'general_budget' IS NULL AND NOT EXISTS(SELECT 1 FROM public.period_category_budgets WHERE period_id=new_id)) IS NOT TRUE THEN RAISE EXCEPTION 'no copia presupuestos'; END IF;
    result := public.advance_period(pid,2,'between_paydays',today,NULL,req);
    IF (result=original AND (SELECT count(*) FROM public.budget_periods)=2) IS NOT TRUE THEN RAISE EXCEPTION 'retry estable después del cierre'; END IF;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,2,'between_paydays',today,NULL,req,1);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: clave mismo período distinto payload'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,3,'between_paydays',today,NULL,req);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: clave distinta versión'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.set_general_budget(pid,1,3);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: presupuesto general cerrado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_category_budget(pid,cat2,1);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: crear presupuesto cerrado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_category_budget(bid,1,1);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: actualizar presupuesto cerrado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.delete_category_budget(bid,1);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: borrar presupuesto cerrado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_expense(d,1,cat,NULL,NULL,NULL,NULL,false,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: movimiento de período cerrado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_income(d,1,NULL,NULL,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: movimiento de período cerrado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_transfer(d,1,NULL,acc,NULL,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: movimiento de período cerrado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_expense((z->>'id')::uuid,1,d,1,cat,NULL,NULL,NULL,NULL,false,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: movimiento de período cerrado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.delete_expense((z->>'id')::uuid,1,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: movimiento de período cerrado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_income((x->>'id')::uuid,1,d,1,NULL,NULL,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: movimiento de período cerrado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.delete_income((x->>'id')::uuid,1,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: movimiento de período cerrado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_transfer((y->>'id')::uuid,1,d,1,acc,NULL,NULL,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: movimiento de período cerrado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.delete_transfer((y->>'id')::uuid,1,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: movimiento de período cerrado'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_income((x->>'id')::uuid,1,today,1,NULL,NULL,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: trasladar ingreso cerrado'; END IF;
    checked := checked + 1;
    RESET ROLE;
    IF ((SELECT count(*) FROM public.financial_operations WHERE user_id=user_a AND idempotency_key=req)=1 AND NOT EXISTS(SELECT 1 FROM public.financial_operations WHERE user_id=user_a AND idempotency_key=bad)) IS NOT TRUE THEN RAISE EXCEPTION 'journal único y fallos ausentes'; END IF;
    SET LOCAL ROLE authenticated;
    RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- Cierre 0 y arrastre exacto; subtransacción que restaura fixtures.
    BEGIN
    PERFORM public.create_expense(d,100,cat,NULL,NULL,NULL,NULL,false,gen_random_uuid());
    result := public.advance_period(pid,1,'custom',today,today+5,gen_random_uuid(),0);
    IF ((result->'closed_period'->>'closing_balance')::numeric=0 AND (result->'opened_period'->>'opening_balance')::numeric=0 AND (result->'opened_period'->>'general_budget')::numeric=0) IS NOT TRUE THEN RAISE EXCEPTION 'arrastre exacto y presupuesto cero'; END IF;
    IF ((SELECT count(*) FROM public.incomes)=0 AND (SELECT count(*) FROM public.transfers)=0) IS NOT TRUE THEN RAISE EXCEPTION 'arrastre sin movimientos ficticios'; END IF;
    RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- Cierre -25.50 y arrastre exacto; subtransacción que restaura fixtures.
    BEGIN
    PERFORM public.create_expense(d,125.50,cat,NULL,NULL,NULL,NULL,false,gen_random_uuid());
    result := public.advance_period(pid,1,'custom',today,today+5,gen_random_uuid(),0);
    IF ((result->'closed_period'->>'closing_balance')::numeric=-25.50 AND (result->'opened_period'->>'opening_balance')::numeric=-25.50 AND (result->'opened_period'->>'general_budget')::numeric=0) IS NOT TRUE THEN RAISE EXCEPTION 'arrastre exacto y presupuesto cero'; END IF;
    IF ((SELECT count(*) FROM public.incomes)=0 AND (SELECT count(*) FROM public.transfers)=0) IS NOT TRUE THEN RAISE EXCEPTION 'arrastre sin movimientos ficticios'; END IF;
    RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- Modo mensual y anual naturales actuales, con hueco válido desde período fijo; subtransacción que restaura fixtures.
    BEGIN
    FOREACH mode_name IN ARRAY ARRAY['monthly','annual','custom'] LOOP
    BEGIN
    -- Fixture administrativo de un período fijo ya vencido: create_first_period
    -- exige contener hoy y no permite construir este pasado con las RPC actuales.
    RESET ROLE;
    UPDATE public.budget_periods SET mode='custom',end_date=ys-5 WHERE id=pid AND user_id=user_a;
    SET LOCAL ROLE authenticated;
    result := public.advance_period(pid,1,mode_name,CASE WHEN mode_name='monthly' THEN ms WHEN mode_name='annual' THEN ys ELSE today END,CASE WHEN mode_name='monthly' THEN me WHEN mode_name='annual' THEN ye ELSE today+5 END,gen_random_uuid(),23.45);
    IF ((result->'closed_period'->>'end_date')::date=ys-5 AND (result->'opened_period'->>'general_budget')::numeric=23.45 AND (result->'opened_period'->>'opening_balance')::numeric=100) IS NOT TRUE THEN RAISE EXCEPTION 'modo actual y final fijo conservado'; END IF;
    RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    END LOOP;
    RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- Final fijo conservado incluso al abrir between_paydays; subtransacción que restaura fixtures.
    BEGIN
    RESET ROLE;
    UPDATE public.budget_periods SET mode='custom',end_date=today-3 WHERE id=pid AND user_id=user_a;
    SET LOCAL ROLE authenticated;
    result := public.advance_period(pid,1,'between_paydays',today,NULL,gen_random_uuid());
    IF ((result->'closed_period'->>'end_date')::date=today-3) IS NOT TRUE THEN RAISE EXCEPTION 'conserva hueco y final fijo'; END IF;
    RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- Modos fijos anteriores: preservar mes/año completos sin truncarlos.
    FOREACH mode_name IN ARRAY ARRAY['monthly','annual'] LOOP
    BEGIN
        RESET ROLE;
        UPDATE public.budget_periods SET mode=mode_name,
            start_date=CASE WHEN mode_name='monthly' THEN (ms-interval '1 month')::date ELSE (ys-interval '1 year')::date END,
            end_date=CASE WHEN mode_name='monthly' THEN ms-1 ELSE ys-1 END
            WHERE id=pid AND user_id=user_a;
        SET LOCAL ROLE authenticated;
        result := public.advance_period(pid,1,mode_name,
            CASE WHEN mode_name='monthly' THEN ms ELSE ys END,
            CASE WHEN mode_name='monthly' THEN me ELSE ye END,gen_random_uuid());
        IF ((result->'closed_period'->>'end_date')::date =
            CASE WHEN mode_name='monthly' THEN ms-1 ELSE ys-1 END) IS NOT TRUE THEN
            RAISE EXCEPTION 'Se alteró el final del mes/año anterior';
        END IF;
        RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE='Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    END LOOP;
    -- Rechazos de transición sin efectos: versiones, ownership y modos; subtransacción que restaura fixtures.
    BEGIN
    RESET ROLE;
    SELECT jsonb_build_object(
        'budget_periods',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.budget_periods r WHERE user_id=user_a),
        'period_category_budgets',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.period_category_budgets r WHERE user_id=user_a),
        'expenses',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.expenses r WHERE user_id=user_a),
        'incomes',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.incomes r WHERE user_id=user_a),
        'transfers',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.transfers r WHERE user_id=user_a),
        'financial_operations',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.financial_operations r WHERE user_id=user_a)
    ) INTO baseline;
    SET LOCAL ROLE authenticated;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,2,'between_paydays',today,NULL,bad);
    EXCEPTION WHEN SQLSTATE '40001' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: versión obsoleta'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid_b,1,'between_paydays',today,NULL,bad);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: período ajeno o incorrecto'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.advance_period(gen_random_uuid(),1,'between_paydays',today,NULL,bad);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: período ajeno o incorrecto'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,'custom',today+1,today+5,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: modo o fechas inválidos'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,'custom',today-2,today-1,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: modo o fechas inválidos'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,'monthly',ms-1,me,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: modo o fechas inválidos'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,'annual',ys-1,ye,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: modo o fechas inválidos'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,'monthly',ms,me-1,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: modo o fechas inválidos'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,'annual',ys,ye-1,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: modo o fechas inválidos'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,'custom',ys-10,today,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: modo o fechas inválidos'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,'custom',ys-11,today,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: modo o fechas inválidos'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,'between_paydays',today,today+1,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: modo o fechas inválidos'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,'custom',today,NULL,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: modo o fechas inválidos'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,NULL,today,today,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: modo o fechas inválidos'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,'custom',NULL,today,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: modo o fechas inválidos'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,'custom','infinity'::date,'infinity'::date,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: modo o fechas inválidos'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,NULL,'between_paydays',today,NULL,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: versión NULL'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,'between_paydays',today,NULL,NULL);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: request NULL'; END IF;
    checked := checked + 1;
    RESET ROLE;
    SELECT jsonb_build_object(
        'budget_periods',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.budget_periods r WHERE user_id=user_a),
        'period_category_budgets',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.period_category_budgets r WHERE user_id=user_a),
        'expenses',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.expenses r WHERE user_id=user_a),
        'incomes',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.incomes r WHERE user_id=user_a),
        'transfers',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.transfers r WHERE user_id=user_a),
        'financial_operations',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.financial_operations r WHERE user_id=user_a)
    ) INTO after_failure;
    SET LOCAL ROLE authenticated;
    IF (baseline=after_failure) IS NOT TRUE THEN RAISE EXCEPTION 'fallo de transición cambió períodos, versiones, movimientos o journal'; END IF;
    RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- Solapamiento con final fijo; subtransacción que restaura fixtures.
    BEGIN
    RESET ROLE;
    UPDATE public.budget_periods SET mode='custom',end_date=today WHERE id=pid AND user_id=user_a;
    SET LOCAL ROLE authenticated;
    RESET ROLE;
    SELECT jsonb_build_object(
        'budget_periods',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.budget_periods r WHERE user_id=user_a),
        'period_category_budgets',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.period_category_budgets r WHERE user_id=user_a),
        'expenses',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.expenses r WHERE user_id=user_a),
        'incomes',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.incomes r WHERE user_id=user_a),
        'transfers',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.transfers r WHERE user_id=user_a),
        'financial_operations',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.financial_operations r WHERE user_id=user_a)
    ) INTO baseline;
    SET LOCAL ROLE authenticated;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,'custom',today,today+5,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: solapamiento fijo'; END IF;
    checked := checked + 1;
    RESET ROLE;
    SELECT jsonb_build_object(
        'budget_periods',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.budget_periods r WHERE user_id=user_a),
        'period_category_budgets',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.period_category_budgets r WHERE user_id=user_a),
        'expenses',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.expenses r WHERE user_id=user_a),
        'incomes',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.incomes r WHERE user_id=user_a),
        'transfers',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.transfers r WHERE user_id=user_a),
        'financial_operations',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.financial_operations r WHERE user_id=user_a)
    ) INTO after_failure;
    SET LOCAL ROLE authenticated;
    IF (baseline=after_failure) IS NOT TRUE THEN RAISE EXCEPTION 'solapamiento no atómico'; END IF;
    RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- Movimiento gasto en nuevo inicio o después; subtransacción que restaura fixtures.
    BEGIN
    PERFORM public.create_expense(today,1,cat,NULL,NULL,NULL,NULL,false,gen_random_uuid());
    RESET ROLE;
    SELECT jsonb_build_object(
        'budget_periods',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.budget_periods r WHERE user_id=user_a),
        'period_category_budgets',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.period_category_budgets r WHERE user_id=user_a),
        'expenses',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.expenses r WHERE user_id=user_a),
        'incomes',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.incomes r WHERE user_id=user_a),
        'transfers',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.transfers r WHERE user_id=user_a),
        'financial_operations',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.financial_operations r WHERE user_id=user_a)
    ) INTO baseline;
    SET LOCAL ROLE authenticated;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,'between_paydays',today,NULL,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: movimiento fuera del cierre'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,'between_paydays',today-1,NULL,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: movimiento fuera del cierre'; END IF;
    checked := checked + 1;
    RESET ROLE;
    SELECT jsonb_build_object(
        'budget_periods',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.budget_periods r WHERE user_id=user_a),
        'period_category_budgets',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.period_category_budgets r WHERE user_id=user_a),
        'expenses',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.expenses r WHERE user_id=user_a),
        'incomes',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.incomes r WHERE user_id=user_a),
        'transfers',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.transfers r WHERE user_id=user_a),
        'financial_operations',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.financial_operations r WHERE user_id=user_a)
    ) INTO after_failure;
    SET LOCAL ROLE authenticated;
    IF (baseline=after_failure) IS NOT TRUE THEN RAISE EXCEPTION 'movimiento fuera de límites dejó efectos parciales'; END IF;
    RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- Movimiento ingreso en nuevo inicio o después; subtransacción que restaura fixtures.
    BEGIN
    PERFORM public.create_income(today,1,acc,NULL,gen_random_uuid());
    RESET ROLE;
    SELECT jsonb_build_object(
        'budget_periods',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.budget_periods r WHERE user_id=user_a),
        'period_category_budgets',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.period_category_budgets r WHERE user_id=user_a),
        'expenses',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.expenses r WHERE user_id=user_a),
        'incomes',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.incomes r WHERE user_id=user_a),
        'transfers',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.transfers r WHERE user_id=user_a),
        'financial_operations',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.financial_operations r WHERE user_id=user_a)
    ) INTO baseline;
    SET LOCAL ROLE authenticated;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,'between_paydays',today,NULL,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: movimiento fuera del cierre'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,'between_paydays',today-1,NULL,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: movimiento fuera del cierre'; END IF;
    checked := checked + 1;
    RESET ROLE;
    SELECT jsonb_build_object(
        'budget_periods',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.budget_periods r WHERE user_id=user_a),
        'period_category_budgets',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.period_category_budgets r WHERE user_id=user_a),
        'expenses',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.expenses r WHERE user_id=user_a),
        'incomes',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.incomes r WHERE user_id=user_a),
        'transfers',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.transfers r WHERE user_id=user_a),
        'financial_operations',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.financial_operations r WHERE user_id=user_a)
    ) INTO after_failure;
    SET LOCAL ROLE authenticated;
    IF (baseline=after_failure) IS NOT TRUE THEN RAISE EXCEPTION 'movimiento fuera de límites dejó efectos parciales'; END IF;
    RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- Movimiento transferencia en nuevo inicio o después; subtransacción que restaura fixtures.
    BEGIN
    PERFORM public.create_transfer(today,1,acc,acc2,NULL,gen_random_uuid());
    RESET ROLE;
    SELECT jsonb_build_object(
        'budget_periods',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.budget_periods r WHERE user_id=user_a),
        'period_category_budgets',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.period_category_budgets r WHERE user_id=user_a),
        'expenses',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.expenses r WHERE user_id=user_a),
        'incomes',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.incomes r WHERE user_id=user_a),
        'transfers',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.transfers r WHERE user_id=user_a),
        'financial_operations',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.financial_operations r WHERE user_id=user_a)
    ) INTO baseline;
    SET LOCAL ROLE authenticated;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,'between_paydays',today,NULL,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: movimiento fuera del cierre'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,'between_paydays',today-1,NULL,bad);
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: movimiento fuera del cierre'; END IF;
    checked := checked + 1;
    RESET ROLE;
    SELECT jsonb_build_object(
        'budget_periods',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.budget_periods r WHERE user_id=user_a),
        'period_category_budgets',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.period_category_budgets r WHERE user_id=user_a),
        'expenses',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.expenses r WHERE user_id=user_a),
        'incomes',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.incomes r WHERE user_id=user_a),
        'transfers',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.transfers r WHERE user_id=user_a),
        'financial_operations',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb) FROM public.financial_operations r WHERE user_id=user_a)
    ) INTO after_failure;
    SET LOCAL ROLE authenticated;
    IF (baseline=after_failure) IS NOT TRUE THEN RAISE EXCEPTION 'movimiento fuera de límites dejó efectos parciales'; END IF;
    RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- RLS, ownership, DML y journal privado; subtransacción que restaura fixtures.
    BEGIN
    IF ((SELECT count(*) FROM public.budget_periods)=1 AND NOT EXISTS(SELECT 1 FROM public.budget_periods WHERE id=pid_b) AND NOT EXISTS(SELECT 1 FROM public.period_category_budgets WHERE id=budget_b)) IS NOT TRUE THEN RAISE EXCEPTION 'RLS filtra B'; END IF;
    failed := false;
    BEGIN
        PERFORM public.set_general_budget(pid_b,1,1);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: mutación B'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_category_budget(pid_b,cat,1);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: mutación B'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_category_budget(budget_b,1,1);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: mutación B'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.delete_category_budget(budget_b,1);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: mutación B'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM (SELECT count(*) FROM public.financial_operations);
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: journal privado'; END IF;
    checked := checked + 1;
    FOREACH tbl IN ARRAY ARRAY['budget_periods','period_category_budgets','financial_operations'] LOOP
        FOREACH command IN ARRAY ARRAY[
            format('INSERT INTO public.%I DEFAULT VALUES',tbl),
            format('UPDATE public.%I SET user_id=user_id',tbl),
            format('DELETE FROM public.%I',tbl)
        ] LOOP
    failed := false;
    BEGIN
        EXECUTE command;
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: DML directo'; END IF;
    checked := checked + 1;
        END LOOP;
    END LOOP;
    RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE = 'Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    RESET ROLE;
    n := 0;
    FOR fn IN SELECT p.oid,p.proname,p.prosecdef,p.proconfig FROM pg_proc p
        JOIN pg_namespace ns ON ns.oid=p.pronamespace
        WHERE ns.nspname='public' AND p.proname = ANY(ARRAY[
            'advance_period','set_general_budget','create_category_budget',
            'update_category_budget','delete_category_budget'])
    LOOP
        n := n+1;
        IF NOT fn.prosecdef OR ('search_path=""' = ANY(fn.proconfig)) IS NOT TRUE
            OR has_function_privilege('anon',fn.oid,'EXECUTE')
            OR NOT has_function_privilege('authenticated',fn.oid,'EXECUTE')
            OR position('private.lock_current_user()' IN pg_get_functiondef(fn.oid))=0
            OR EXISTS(SELECT 1 FROM aclexplode((SELECT coalesce(proacl,acldefault('f',proowner)) FROM pg_proc WHERE oid=fn.oid)) WHERE grantee=0 AND privilege_type='EXECUTE') THEN
            RAISE EXCEPTION 'Seguridad de RPC incorrecta: %',fn.proname;
        END IF;
    END LOOP;
    IF n<>5 THEN RAISE EXCEPTION 'Se esperaban cinco RPC sin sobrecargas'; END IF;
    FOR fn IN SELECT p.oid,p.proconfig,p.proacl,p.proowner FROM pg_proc p
        JOIN pg_namespace ns ON ns.oid=p.pronamespace WHERE ns.nspname='private'
    LOOP
        IF has_function_privilege('anon',fn.oid,'EXECUTE')
            OR has_function_privilege('authenticated',fn.oid,'EXECUTE')
            OR ('search_path=""' = ANY(fn.proconfig)) IS NOT TRUE
            OR EXISTS(SELECT 1 FROM aclexplode(coalesce(fn.proacl,acldefault('f',fn.proowner))) WHERE grantee=0 AND privilege_type='EXECUTE') THEN
            RAISE EXCEPTION 'Helper privado expuesto';
        END IF;
    END LOOP;
    PERFORM set_config('request.jwt.claim.sub','',true);
    PERFORM set_config('request.jwt.claims','{}',true);
    SET LOCAL ROLE anon;
    failed := false;
    BEGIN
        PERFORM public.advance_period(pid,1,'between_paydays',today,NULL,bad);
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: anon RPC'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.set_general_budget(pid,1,1);
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: anon RPC'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_category_budget(pid,cat,1);
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: anon RPC'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.update_category_budget(budget_b,1,1);
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: anon RPC'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.delete_category_budget(budget_b,1);
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: anon RPC'; END IF;
    checked := checked + 1;
    RESET ROLE;
    SET LOCAL ROLE authenticated;
    failed := false;
    BEGIN
        PERFORM public.set_general_budget(pid,1,1);
    EXCEPTION WHEN SQLSTATE '28000' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: sesión sin uid'; END IF;
    checked := checked + 1;
    RESET ROLE;
    RAISE NOTICE 'Smoke 005 OK: transiciones, arrastre, modos, presupuestos, inmutabilidad, idempotencia, atomicidad y seguridad (% rechazos)',checked;
END;
$smoke$;
ROLLBACK;
