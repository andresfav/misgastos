-- Smoke 006 para 001–006. Preparado, NO ejecutado durante su creación.
-- Ejecutar solo en pruebas como propietario/BYPASSRLS con SET ROLE.
-- Fixtures sintéticos vía RPC, snapshot de todas las tablas y ROLLBACK final.
-- Un error aborta la transacción y no permite confirmar fixtures.
BEGIN ISOLATION LEVEL READ COMMITTED;
SET LOCAL TIME ZONE 'America/Adak';
DO $smoke$
DECLARE
    user_a uuid := gen_random_uuid(); user_b uuid := gen_random_uuid();
    today date := (statement_timestamp() AT TIME ZONE 'Pacific/Kiritimati')::date;
    d date := today-10;
    pid uuid; pid_b uuid; next_pid uuid;
    cat uuid; cat_idle uuid; cat_unbudgeted uuid; cat_zero uuid; cat_unused uuid; cat_b uuid;
    acc_z uuid; acc_a uuid; acc_empty uuid; acc_b uuid;
    expense_id uuid; income_id uuid; transfer_id uuid;
    result jsonb; summary jsonb; balances jsonb; usage_rows jsonb; transition jsonb;
    baseline jsonb; after_reads jsonb;
    failed boolean; checked integer := 0; fn record; n integer; tbl text; command text;
BEGIN
    INSERT INTO auth.users(id) VALUES (user_a),(user_b);
    PERFORM set_config('request.jwt.claim.sub',user_b::text,true);
    PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',user_b,'role','authenticated')::text,true);
    SET LOCAL ROLE authenticated;
    PERFORM public.configure_user_settings('EUR','Pacific/Kiritimati');
    result := public.create_first_period('between_paydays',d,NULL,10000,gen_random_uuid());
    pid_b := (result->>'id')::uuid;
    SELECT id INTO cat_b FROM public.create_category('B categoría');
    result := public.create_savings_account('B ahorro',d,9000,gen_random_uuid());
    acc_b := (result->>'id')::uuid;
    PERFORM public.create_income(d,5000,NULL,NULL,gen_random_uuid());
    PERFORM public.create_expense(d,700,cat_b,NULL,NULL,NULL,NULL,false,gen_random_uuid());
    PERFORM public.create_category_budget(pid_b,cat_b,800);
    RESET ROLE;
    PERFORM set_config('request.jwt.claim.sub',user_a::text,true);
    PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',user_a,'role','authenticated')::text,true);
    SET LOCAL ROLE authenticated;
    -- Sin settings: error explícito, no fecha del servidor como fallback.

    failed := false;
    BEGIN
        PERFORM public.get_current_financial_state();
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: configuración ausente'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.get_savings_balances();
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: configuración ausente'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.get_period_summary(pid_b);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: configuración ausente'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.get_category_budget_usage(pid_b);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: configuración ausente'; END IF;
    checked := checked + 1;
    PERFORM public.configure_user_settings('EUR','Pacific/Kiritimati');
    result := public.get_current_financial_state();
    IF (result->'current_period'='null'::jsonb AND result->'available'='null'::jsonb AND result->'general_budget_spent'='null'::jsonb AND result->'savings_balances'='[]'::jsonb) IS NOT TRUE THEN RAISE EXCEPTION 'estado sin período ni ahorro'; END IF;
    IF ((result->>'as_of_date')::date=today) IS NOT TRUE THEN RAISE EXCEPTION 'día local de settings, no CURRENT_DATE'; END IF;
    result := public.create_savings_account('Zulu',d,100,gen_random_uuid());
    acc_z := (result->>'id')::uuid;
    result := public.create_savings_account(' alfa ',d,10,gen_random_uuid());
    acc_a := (result->>'id')::uuid;
    result := public.create_savings_account('Beta',d,7,gen_random_uuid());
    acc_empty := (result->>'id')::uuid;
    result := public.get_current_financial_state();
    IF (result->'current_period'='null'::jsonb AND result->'available'='null'::jsonb AND jsonb_array_length(result->'savings_balances')=3) IS NOT TRUE THEN RAISE EXCEPTION 'ahorro sin período'; END IF;
    balances := public.get_savings_balances();
    IF ((SELECT (value->>'current_balance')::numeric FROM jsonb_array_elements(balances) WHERE (value->>'id')::uuid=acc_z)=100) IS NOT TRUE THEN RAISE EXCEPTION 'saldo ahorro acc_z'; END IF;
    IF ((SELECT (value->>'current_balance')::numeric FROM jsonb_array_elements(balances) WHERE (value->>'id')::uuid=acc_a)=10) IS NOT TRUE THEN RAISE EXCEPTION 'saldo ahorro acc_a'; END IF;
    IF ((SELECT (value->>'current_balance')::numeric FROM jsonb_array_elements(balances) WHERE (value->>'id')::uuid=acc_empty)=7) IS NOT TRUE THEN RAISE EXCEPTION 'saldo ahorro acc_empty'; END IF;
    IF ((balances->0->>'id')::uuid=acc_a AND (balances->1->>'id')::uuid=acc_empty AND (balances->2->>'id')::uuid=acc_z) IS NOT TRUE THEN RAISE EXCEPTION 'orden ahorro por nombre normalizado'; END IF;
    result := public.create_first_period('between_paydays',d,NULL,100,gen_random_uuid());
    pid := (result->>'id')::uuid;
    SELECT id INTO cat FROM public.create_category('Gasto presupuestado');
    SELECT id INTO cat_idle FROM public.create_category(' alfa presupuesto ');
    SELECT id INTO cat_unbudgeted FROM public.create_category('Sin presupuesto');
    SELECT id INTO cat_zero FROM public.create_category('Zeta presupuesto cero');
    SELECT id INTO cat_unused FROM public.create_category('No debe aparecer');
    result := public.get_current_financial_state();
    IF ((result->>'available')::numeric=100 AND (result->>'expenses_total')::numeric=0 AND (result->>'income_total')::numeric=0 AND result->'general_budget'='null'::jsonb AND result->'general_budget_remaining'='null'::jsonb AND result->'current_period'->'end_date'='null'::jsonb) IS NOT TRUE THEN RAISE EXCEPTION 'solo opening balance y between_paydays'; END IF;
    IF (public.get_category_budget_usage(pid)='[]'::jsonb) IS NOT TRUE THEN RAISE EXCEPTION 'categorías vacías sin presupuesto ni gasto'; END IF;
    PERFORM public.create_expense(d,20,cat,NULL,NULL,NULL,NULL,false,gen_random_uuid());
    result := public.get_current_financial_state();
    IF ((result->>'available')::numeric=80) IS NOT TRUE THEN RAISE EXCEPTION 'gasto reduce disponible'; END IF;
    PERFORM public.create_income(d,30,NULL,NULL,gen_random_uuid());
    result := public.get_current_financial_state();
    IF ((result->>'available')::numeric=110) IS NOT TRUE THEN RAISE EXCEPTION 'ingreso disponible suma'; END IF;
    PERFORM public.create_income(d,40,acc_z,NULL,gen_random_uuid());
    result := public.get_current_financial_state();
    IF ((result->>'available')::numeric=110) IS NOT TRUE THEN RAISE EXCEPTION 'ingreso a ahorro no suma disponible'; END IF;
    balances := public.get_savings_balances();
    IF ((SELECT (value->>'current_balance')::numeric FROM jsonb_array_elements(balances) WHERE (value->>'id')::uuid=acc_z)=140) IS NOT TRUE THEN RAISE EXCEPTION 'saldo ahorro acc_z'; END IF;
    IF ((SELECT (value->>'current_balance')::numeric FROM jsonb_array_elements(balances) WHERE (value->>'id')::uuid=acc_a)=10) IS NOT TRUE THEN RAISE EXCEPTION 'saldo ahorro acc_a'; END IF;
    IF ((SELECT (value->>'current_balance')::numeric FROM jsonb_array_elements(balances) WHERE (value->>'id')::uuid=acc_empty)=7) IS NOT TRUE THEN RAISE EXCEPTION 'saldo ahorro acc_empty'; END IF;
    PERFORM public.create_transfer(d,25,NULL,acc_z,NULL,gen_random_uuid());
    result := public.get_current_financial_state();
    IF ((result->>'available')::numeric=85) IS NOT TRUE THEN RAISE EXCEPTION 'transferencia a ahorro resta disponible'; END IF;
    balances := public.get_savings_balances();
    IF ((SELECT (value->>'current_balance')::numeric FROM jsonb_array_elements(balances) WHERE (value->>'id')::uuid=acc_z)=165) IS NOT TRUE THEN RAISE EXCEPTION 'saldo ahorro acc_z'; END IF;
    IF ((SELECT (value->>'current_balance')::numeric FROM jsonb_array_elements(balances) WHERE (value->>'id')::uuid=acc_a)=10) IS NOT TRUE THEN RAISE EXCEPTION 'saldo ahorro acc_a'; END IF;
    IF ((SELECT (value->>'current_balance')::numeric FROM jsonb_array_elements(balances) WHERE (value->>'id')::uuid=acc_empty)=7) IS NOT TRUE THEN RAISE EXCEPTION 'saldo ahorro acc_empty'; END IF;
    PERFORM public.create_transfer(d,10,acc_z,NULL,NULL,gen_random_uuid());
    result := public.get_current_financial_state();
    IF ((result->>'available')::numeric=95) IS NOT TRUE THEN RAISE EXCEPTION 'transferencia desde ahorro suma disponible'; END IF;
    balances := public.get_savings_balances();
    IF ((SELECT (value->>'current_balance')::numeric FROM jsonb_array_elements(balances) WHERE (value->>'id')::uuid=acc_z)=155) IS NOT TRUE THEN RAISE EXCEPTION 'saldo ahorro acc_z'; END IF;
    IF ((SELECT (value->>'current_balance')::numeric FROM jsonb_array_elements(balances) WHERE (value->>'id')::uuid=acc_a)=10) IS NOT TRUE THEN RAISE EXCEPTION 'saldo ahorro acc_a'; END IF;
    IF ((SELECT (value->>'current_balance')::numeric FROM jsonb_array_elements(balances) WHERE (value->>'id')::uuid=acc_empty)=7) IS NOT TRUE THEN RAISE EXCEPTION 'saldo ahorro acc_empty'; END IF;
    PERFORM public.create_transfer(d,15,acc_z,acc_a,NULL,gen_random_uuid());
    result := public.get_current_financial_state();
    IF ((result->>'available')::numeric=95) IS NOT TRUE THEN RAISE EXCEPTION 'ahorro entre cuentas no modifica disponible'; END IF;
    balances := public.get_savings_balances();
    IF ((SELECT (value->>'current_balance')::numeric FROM jsonb_array_elements(balances) WHERE (value->>'id')::uuid=acc_z)=140) IS NOT TRUE THEN RAISE EXCEPTION 'saldo ahorro acc_z'; END IF;
    IF ((SELECT (value->>'current_balance')::numeric FROM jsonb_array_elements(balances) WHERE (value->>'id')::uuid=acc_a)=25) IS NOT TRUE THEN RAISE EXCEPTION 'saldo ahorro acc_a'; END IF;
    IF ((SELECT (value->>'current_balance')::numeric FROM jsonb_array_elements(balances) WHERE (value->>'id')::uuid=acc_empty)=7) IS NOT TRUE THEN RAISE EXCEPTION 'saldo ahorro acc_empty'; END IF;
    PERFORM public.create_expense(d,5,cat_unbudgeted,NULL,NULL,NULL,NULL,false,gen_random_uuid());
    result := public.get_current_financial_state();
    IF ((result->>'available')::numeric=90) IS NOT TRUE THEN RAISE EXCEPTION 'gastos suman entre categorías'; END IF;
    IF ((result->>'income_total')::numeric=70 AND (result->>'income_to_available')::numeric=30 AND (result->>'income_to_savings')::numeric=40 AND (result->>'expenses_total')::numeric=25) IS NOT TRUE THEN RAISE EXCEPTION 'ingresos externos y gastos excluyen transferencias'; END IF;
    PERFORM public.set_general_budget(pid,0,1);
    result := public.get_current_financial_state();
    IF ((result->>'general_budget')::numeric=0 AND (result->>'general_budget_spent')::numeric=25 AND (result->>'general_budget_remaining')::numeric=-25 AND (result->>'available')::numeric=90) IS NOT TRUE THEN RAISE EXCEPTION 'presupuesto cero y sobreconsumo'; END IF;
    PERFORM public.set_general_budget(pid,100,2);
    result := public.get_current_financial_state();
    IF ((result->>'general_budget_remaining')::numeric=75 AND (result->>'available')::numeric=90) IS NOT TRUE THEN RAISE EXCEPTION 'presupuesto positivo no cambia disponible'; END IF;
    PERFORM public.create_category_budget(pid,cat,10);
    PERFORM public.create_category_budget(pid,cat_idle,30);
    PERFORM public.create_category_budget(pid,cat_zero,0);
    PERFORM public.set_category_active(cat,false,1);
    PERFORM public.set_savings_account_active(acc_a,false,1);
    usage_rows := public.get_category_budget_usage(pid);
    IF (jsonb_array_length(usage_rows)=4) IS NOT TRUE THEN RAISE EXCEPTION 'unión categorías gastadas o presupuestadas'; END IF;
    IF ((usage_rows->0->>'category_id')::uuid=cat AND (usage_rows->1->>'category_id')::uuid=cat_unbudgeted AND (usage_rows->2->>'category_id')::uuid=cat_idle AND (usage_rows->3->>'category_id')::uuid=cat_zero) IS NOT TRUE THEN RAISE EXCEPTION 'orden gasto descendente y nombre para empates'; END IF;
    IF ((usage_rows->0->>'spent')::numeric=20 AND (usage_rows->0->>'budget_amount')::numeric=10 AND (usage_rows->0->>'remaining')::numeric=-10 AND (usage_rows->0->>'budget_version')::bigint=1 AND usage_rows->0->>'budget_id' IS NOT NULL AND NOT (usage_rows->0->>'category_is_active')::boolean) IS NOT TRUE THEN RAISE EXCEPTION 'presupuesto histórico inactivo y remaining negativo'; END IF;
    IF ((usage_rows->1->>'spent')::numeric=5 AND usage_rows->1->'budget_id'='null'::jsonb AND usage_rows->1->'budget_amount'='null'::jsonb AND usage_rows->1->'budget_version'='null'::jsonb AND usage_rows->1->'remaining'='null'::jsonb) IS NOT TRUE THEN RAISE EXCEPTION 'gasto sin presupuesto'; END IF;
    IF ((usage_rows->2->>'spent')::numeric=0 AND (usage_rows->2->>'remaining')::numeric=30 AND (usage_rows->3->>'remaining')::numeric=0) IS NOT TRUE THEN RAISE EXCEPTION 'presupuestos sin gasto, incluido cero'; END IF;
    balances := public.get_savings_balances();
    IF ((balances->0->>'id')::uuid=acc_empty AND (balances->1->>'id')::uuid=acc_z AND (balances->2->>'id')::uuid=acc_a AND NOT (balances->2->>'is_active')::boolean AND (balances->2->>'version')::bigint=2) IS NOT TRUE THEN RAISE EXCEPTION 'cuenta inactiva presente detrás de activas'; END IF;
    summary := public.get_period_summary(pid);
    IF (summary->'period'->>'status'='open' AND summary->'closing_balance'='null'::jsonb AND (summary->>'as_of_date')::date=today AND (summary->>'available')::numeric=90 AND (summary->>'opening_balance')::numeric=100) IS NOT TRUE THEN RAISE EXCEPTION 'resumen abierto'; END IF;
    IF ((summary->>'transfer_to_savings_total')::numeric=25 AND (summary->>'transfer_from_savings_total')::numeric=10 AND (summary->>'income_total')::numeric=70 AND (summary->>'expenses_total')::numeric=25) IS NOT TRUE THEN RAISE EXCEPTION 'totales de resumen sin transferencias entre ahorros'; END IF;
    -- Un gasto posterior puede dejar negativo el disponible; arrastre negativo.
    BEGIN
        PERFORM public.create_expense(d+1,115.50,cat_unbudgeted,NULL,NULL,NULL,NULL,false,gen_random_uuid());
        result := public.get_current_financial_state();
    IF ((result->>'available')::numeric=-25.50 AND (result->>'general_budget_remaining')::numeric=-40.50) IS NOT TRUE THEN RAISE EXCEPTION 'disponible y remaining negativos'; END IF;
        transition := public.advance_period(pid,3,'between_paydays',today,NULL,gen_random_uuid());
        summary := public.get_period_summary(pid);
    IF ((summary->>'available')::numeric=-25.50 AND (summary->>'closing_balance')::numeric=-25.50) IS NOT TRUE THEN RAISE EXCEPTION 'cierre negativo coincide con 005'; END IF;
        result := public.get_current_financial_state();
    IF ((result->>'opening_balance')::numeric=-25.50 AND (result->>'available')::numeric=-25.50 AND (result->>'expenses_total')::numeric=0) IS NOT TRUE THEN RAISE EXCEPTION 'período nuevo empieza hoy con arrastre negativo'; END IF;
    RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE='Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    transition := public.advance_period(pid,3,'between_paydays',today,NULL,gen_random_uuid());
    next_pid := (transition->'opened_period'->>'id')::uuid;
    summary := public.get_period_summary(pid);
    IF (summary->'period'->>'status'='closed' AND (summary->>'as_of_date')::date=today-1 AND (summary->>'available')::numeric=90 AND (summary->>'closing_balance')::numeric=90) IS NOT TRUE THEN RAISE EXCEPTION 'cierre positivo coincide con 005'; END IF;
    IF ((summary->>'income_to_available')::numeric=30 AND (summary->>'income_to_savings')::numeric=40 AND (summary->>'general_budget_spent')::numeric=25 AND (summary->>'general_budget_remaining')::numeric=75) IS NOT TRUE THEN RAISE EXCEPTION 'resumen cerrado conserva totales'; END IF;
    IF (public.get_category_budget_usage(pid)=usage_rows) IS NOT TRUE THEN RAISE EXCEPTION 'presupuestos cerrados legibles'; END IF;
    result := public.get_current_financial_state();
    IF ((result->>'available')::numeric=90) IS NOT TRUE THEN RAISE EXCEPTION 'período iniciado hoy disponible sin movimientos'; END IF;
    IF ((result->'current_period'->>'id')::uuid=next_pid AND (result->>'expenses_total')::numeric=0 AND (result->>'income_total')::numeric=0 AND result->'general_budget'='null'::jsonb) IS NOT TRUE THEN RAISE EXCEPTION 'estado solo del nuevo período sin copiar presupuestos'; END IF;
    PERFORM public.create_income(today,5,acc_z,NULL,gen_random_uuid());
    PERFORM public.create_transfer(today,2,acc_z,NULL,NULL,gen_random_uuid());
    PERFORM public.create_transfer(today,3,NULL,acc_z,NULL,gen_random_uuid());
    result := public.get_current_financial_state();
    IF ((result->>'available')::numeric=89) IS NOT TRUE THEN RAISE EXCEPTION 'disponible del segundo período'; END IF;
    balances := public.get_savings_balances();
    IF ((SELECT (value->>'current_balance')::numeric FROM jsonb_array_elements(balances) WHERE (value->>'id')::uuid=acc_z)=146) IS NOT TRUE THEN RAISE EXCEPTION 'saldo ahorro acc_z'; END IF;
    IF ((SELECT (value->>'current_balance')::numeric FROM jsonb_array_elements(balances) WHERE (value->>'id')::uuid=acc_a)=25) IS NOT TRUE THEN RAISE EXCEPTION 'saldo ahorro acc_a'; END IF;
    IF ((SELECT (value->>'current_balance')::numeric FROM jsonb_array_elements(balances) WHERE (value->>'id')::uuid=acc_empty)=7) IS NOT TRUE THEN RAISE EXCEPTION 'saldo ahorro acc_empty'; END IF;
    IF (jsonb_array_length(balances)=3 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(balances) WHERE (value->>'id')::uuid=acc_b)) IS NOT TRUE THEN RAISE EXCEPTION 'ahorro cruza períodos sin filtrar B'; END IF;
    IF (result->'savings_balances'=balances) IS NOT TRUE THEN RAISE EXCEPTION 'estado y RPC de ahorro consistentes'; END IF;
    -- Regresión por STABLE: las consultas posteriores al DML provisional ven
    -- create/update/delete de 004. El cierre 005 anterior ya validó el arrastre.
    BEGIN
        result := public.create_expense(today,1,cat_unbudgeted,NULL,NULL,NULL,NULL,false,gen_random_uuid());
        expense_id := (result->>'id')::uuid;
        PERFORM public.update_expense(expense_id,1,today,2,cat_unbudgeted,NULL,NULL,NULL,NULL,false,gen_random_uuid());
    result := public.get_current_financial_state();
    IF ((result->>'available')::numeric=87) IS NOT TRUE THEN RAISE EXCEPTION 'helper ve update expense'; END IF;
        PERFORM public.delete_expense(expense_id,2,gen_random_uuid());
    result := public.get_current_financial_state();
    IF ((result->>'available')::numeric=89) IS NOT TRUE THEN RAISE EXCEPTION 'helper ve delete expense'; END IF;
        result := public.create_income(today,10,NULL,NULL,gen_random_uuid());
        income_id := (result->>'id')::uuid;
        PERFORM public.update_income(income_id,1,today,20,NULL,NULL,gen_random_uuid());
    result := public.get_current_financial_state();
    IF ((result->>'available')::numeric=109) IS NOT TRUE THEN RAISE EXCEPTION 'helper ve update income'; END IF;
        PERFORM public.delete_income(income_id,2,gen_random_uuid());
    result := public.get_current_financial_state();
    IF ((result->>'available')::numeric=89) IS NOT TRUE THEN RAISE EXCEPTION 'helper ve delete income'; END IF;
        result := public.create_transfer(today,89,NULL,acc_z,NULL,gen_random_uuid());
        transfer_id := (result->>'id')::uuid;
    failed := false;
    BEGIN
        PERFORM public.update_transfer(transfer_id,1,today,90,NULL,acc_z,NULL,gen_random_uuid());
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: update transfer debe ver su propio DML'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.create_expense(today,0.01,cat_unbudgeted,NULL,NULL,NULL,NULL,false,gen_random_uuid());
    EXCEPTION WHEN SQLSTATE '22023' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: gasto debe ver su propio DML y cierre diario negativo'; END IF;
    checked := checked + 1;
        PERFORM public.update_transfer(transfer_id,1,today,88,NULL,acc_z,NULL,gen_random_uuid());
    result := public.get_current_financial_state();
    IF ((result->>'available')::numeric=1) IS NOT TRUE THEN RAISE EXCEPTION 'helper ve update transfer aceptado'; END IF;
        PERFORM public.delete_transfer(transfer_id,2,gen_random_uuid());
    result := public.get_current_financial_state();
    IF ((result->>'available')::numeric=89) IS NOT TRUE THEN RAISE EXCEPTION 'helper ve delete transfer'; END IF;
    RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE='Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- Incoherencia administrativa simulada: mostrar ambos valores, sin repararlos.
    BEGIN
        RESET ROLE;
        UPDATE public.budget_periods SET closing_balance=91 WHERE id=pid AND user_id=user_a;
        SET LOCAL ROLE authenticated;
        summary := public.get_period_summary(pid);
    IF ((summary->>'available')::numeric=90 AND (summary->>'closing_balance')::numeric=91 AND (SELECT closing_balance FROM public.budget_periods WHERE id=pid)=91) IS NOT TRUE THEN RAISE EXCEPTION 'incoherencia visible sin corrección silenciosa'; END IF;
    RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE='Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- Exactitud decimal por encima de la precisión de Number de JavaScript.
    BEGIN
        PERFORM public.create_income(today,900719925474099.91,NULL,NULL,gen_random_uuid());
        PERFORM public.create_income(today,0.01,NULL,NULL,gen_random_uuid());
        summary := public.get_period_summary(next_pid);
    IF ((summary->>'income_to_available')::numeric=900719925474099.92 AND (summary->>'available')::numeric=900719925474188.92) IS NOT TRUE THEN RAISE EXCEPTION 'numeric exacto sin float'; END IF;
    RAISE EXCEPTION 'Restaurar escenario' USING ERRCODE='Z0001';
    EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
    END;
    -- Sin efectos: comparar filas completas de A y B, incluidos versiones y timestamps.
    RESET ROLE;
    SELECT jsonb_build_object(
        'user_settings',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.user_settings r WHERE user_id IN (user_a,user_b)),
        'categories',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.categories r WHERE user_id IN (user_a,user_b)),
        'payment_methods',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.payment_methods r WHERE user_id IN (user_a,user_b)),
        'budget_periods',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.budget_periods r WHERE user_id IN (user_a,user_b)),
        'expenses',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.expenses r WHERE user_id IN (user_a,user_b)),
        'incomes',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.incomes r WHERE user_id IN (user_a,user_b)),
        'transfers',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.transfers r WHERE user_id IN (user_a,user_b)),
        'savings_accounts',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.savings_accounts r WHERE user_id IN (user_a,user_b)),
        'period_category_budgets',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.period_category_budgets r WHERE user_id IN (user_a,user_b)),
        'financial_operations',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.financial_operations r WHERE user_id IN (user_a,user_b))
    ) INTO baseline;
    SET LOCAL ROLE authenticated;
    result := public.get_current_financial_state();
    balances := public.get_savings_balances();
    summary := public.get_period_summary(pid);
    PERFORM public.get_period_summary(next_pid);
    PERFORM public.get_category_budget_usage(pid);
    PERFORM public.get_category_budget_usage(next_pid);
    IF ((result->'current_period'->>'user_id')::uuid=user_a AND (summary->'period'->>'user_id')::uuid=user_a) IS NOT TRUE THEN RAISE EXCEPTION 'ownership en resultados'; END IF;
    failed := false;
    BEGIN
        PERFORM public.get_period_summary(pid_b);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: período ajeno o inexistente'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.get_category_budget_usage(pid_b);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: período ajeno o inexistente'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.get_period_summary(gen_random_uuid());
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: período ajeno o inexistente'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.get_category_budget_usage(NULL);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: período ajeno o inexistente'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM (SELECT count(*) FROM public.financial_operations);
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: journal privado'; END IF;
    checked := checked + 1;
    FOREACH tbl IN ARRAY ARRAY['user_settings','categories','payment_methods',
        'budget_periods','expenses','incomes','transfers','savings_accounts',
        'period_category_budgets','financial_operations'] LOOP
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
    RESET ROLE;
    SELECT jsonb_build_object(
        'user_settings',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.user_settings r WHERE user_id IN (user_a,user_b)),
        'categories',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.categories r WHERE user_id IN (user_a,user_b)),
        'payment_methods',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.payment_methods r WHERE user_id IN (user_a,user_b)),
        'budget_periods',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.budget_periods r WHERE user_id IN (user_a,user_b)),
        'expenses',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.expenses r WHERE user_id IN (user_a,user_b)),
        'incomes',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.incomes r WHERE user_id IN (user_a,user_b)),
        'transfers',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.transfers r WHERE user_id IN (user_a,user_b)),
        'savings_accounts',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.savings_accounts r WHERE user_id IN (user_a,user_b)),
        'period_category_budgets',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.period_category_budgets r WHERE user_id IN (user_a,user_b)),
        'financial_operations',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.financial_operations r WHERE user_id IN (user_a,user_b))
    ) INTO after_reads;
    SET LOCAL ROLE authenticated;
    IF (baseline=after_reads) IS NOT TRUE THEN RAISE EXCEPTION 'lecturas cambiaron datos, versiones, updated_at o journal'; END IF;
    RESET ROLE;
    n := 0;
    FOR fn IN SELECT p.oid,p.proname,p.prosecdef,p.provolatile,p.proconfig,p.proargnames,
        p.proacl,p.proowner FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
        WHERE ns.nspname='public' AND p.proname=ANY(ARRAY['get_current_financial_state',
            'get_savings_balances','get_period_summary','get_category_budget_usage'])
    LOOP
        n := n+1;
        IF NOT fn.prosecdef OR fn.provolatile<>'s'
            OR ('search_path=""'=ANY(fn.proconfig)) IS NOT TRUE
            OR has_function_privilege('anon',fn.oid,'EXECUTE')
            OR NOT has_function_privilege('authenticated',fn.oid,'EXECUTE')
            OR EXISTS(SELECT 1 FROM aclexplode(coalesce(fn.proacl,acldefault('f',fn.proowner)))
                WHERE grantee=0 AND privilege_type='EXECUTE')
            OR 'p_user_id'=ANY(fn.proargnames)
            OR position('lock_current_user' IN pg_get_functiondef(fn.oid))>0 THEN
            RAISE EXCEPTION 'Contrato de lectura/ACL incorrecto: %',fn.proname;
        END IF;
    END LOOP;
    IF n<>4 THEN RAISE EXCEPTION 'Se esperaban cuatro RPC sin sobrecargas'; END IF;
    FOR fn IN SELECT p.oid,p.proacl,p.proowner,p.proconfig FROM pg_proc p
        JOIN pg_namespace ns ON ns.oid=p.pronamespace WHERE ns.nspname='private'
    LOOP
        IF has_function_privilege('anon',fn.oid,'EXECUTE')
            OR has_function_privilege('authenticated',fn.oid,'EXECUTE')
            OR ('search_path=""'=ANY(fn.proconfig)) IS NOT TRUE
            OR EXISTS(SELECT 1 FROM aclexplode(coalesce(fn.proacl,acldefault('f',fn.proowner)))
                WHERE grantee=0 AND privilege_type='EXECUTE') THEN
            RAISE EXCEPTION 'Helper privado expuesto';
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
        WHERE ns.nspname='private' AND p.proname=ANY(ARRAY['read_today','savings_balances_at',
            'period_summary_at','available_daily','available_at']) AND p.provolatile<>'s') THEN
        RAISE EXCEPTION 'La cadena de lectura debe ser STABLE';
    END IF;
    -- Las RPC mutantes y el validador conservan VOLATILE y sus snapshots posteriores.
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
        WHERE ((ns.nspname='public' AND p.proname=ANY(ARRAY['create_expense','update_expense',
            'delete_expense','create_income','update_income','delete_income','create_transfer',
            'update_transfer','delete_transfer','advance_period']))
            OR (ns.nspname='private' AND p.proname='check_available')) AND p.provolatile<>'v') THEN
        RAISE EXCEPTION 'Se alteró la volatilidad de una mutación/validación';
    END IF;
    PERFORM set_config('request.jwt.claim.sub','',true);
    PERFORM set_config('request.jwt.claims','{}',true);
    SET LOCAL ROLE anon;
    failed := false;
    BEGIN
        PERFORM public.get_current_financial_state();
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: anon lectura'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.get_savings_balances();
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: anon lectura'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.get_period_summary(pid);
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: anon lectura'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.get_category_budget_usage(pid);
    EXCEPTION WHEN SQLSTATE '42501' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: anon lectura'; END IF;
    checked := checked + 1;
    RESET ROLE;
    SET LOCAL ROLE authenticated;
    failed := false;
    BEGIN
        PERFORM public.get_current_financial_state();
    EXCEPTION WHEN SQLSTATE '28000' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: sesión sin uid'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.get_savings_balances();
    EXCEPTION WHEN SQLSTATE '28000' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: sesión sin uid'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.get_period_summary(pid);
    EXCEPTION WHEN SQLSTATE '28000' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: sesión sin uid'; END IF;
    checked := checked + 1;
    failed := false;
    BEGIN
        PERFORM public.get_category_budget_usage(pid);
    EXCEPTION WHEN SQLSTATE '28000' THEN failed := true;
    END;
    IF NOT failed THEN RAISE EXCEPTION 'Se aceptó: sesión sin uid'; END IF;
    checked := checked + 1;
    RESET ROLE;
    RAISE NOTICE 'Smoke 006 OK: estado, ahorro, períodos, presupuestos, precisión, seguridad y ausencia de efectos (% rechazos)',checked;
END;
$smoke$;
ROLLBACK;
