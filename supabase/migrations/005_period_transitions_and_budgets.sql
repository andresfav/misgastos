-- MisGastos 005: transición atómica y presupuestos. Requiere 001–004.
-- Aplicar como el mismo propietario. RPC VOLATILE, siempre bajo lock de usuario.
BEGIN;

-- NULL solo significa ausencia de presupuesto general; el llamador de categoría
-- lo rechaza expresamente. Validación previa al cast, incluido el desbordamiento.
CREATE FUNCTION private.budget_amount(p_amount numeric) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE SECURITY INVOKER SET search_path = ''
AS $$
BEGIN
    IF p_amount IS NOT NULL AND (p_amount::text IN ('NaN','Infinity','-Infinity')
        OR p_amount < 0 OR p_amount <> pg_catalog.trunc(p_amount,2)
        OR p_amount >= 1000000000000000000::numeric) THEN
        RAISE EXCEPTION 'Presupuesto inválido: no negativo, numeric(20,2), sin redondeo'
            USING ERRCODE = '22023';
    END IF;
    RETURN p_amount::numeric(20,2);
END;
$$;
REVOKE ALL ON FUNCTION private.budget_amount(numeric) FROM PUBLIC, anon, authenticated;

-- Fuente común para el cierre y la validación de 004. Incluye el día inicial
-- aunque no haya movimientos. No introduce orden intradía ni filtra la ventana.
CREATE FUNCTION private.available_daily(p_period uuid)
RETURNS TABLE(date date, balance numeric, withdrawal boolean)
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$
    WITH movements AS (
        SELECT start_date AS date, 0::numeric AS delta, false AS withdrawal
            FROM public.budget_periods WHERE user_id = auth.uid() AND id = p_period
        UNION ALL
        SELECT date, amount, false FROM public.incomes
            WHERE user_id = auth.uid() AND period_id = p_period AND savings_account_id IS NULL
        UNION ALL
        SELECT date, -amount, false FROM public.expenses
            WHERE user_id = auth.uid() AND period_id = p_period
        UNION ALL
        SELECT date, CASE WHEN from_savings_account_id IS NULL THEN -amount ELSE amount END,
            from_savings_account_id IS NULL FROM public.transfers
            WHERE user_id = auth.uid() AND period_id = p_period
                AND (from_savings_account_id IS NULL OR to_savings_account_id IS NULL)
    ), daily AS (
        SELECT date, pg_catalog.sum(delta) AS delta, pg_catalog.bool_or(withdrawal) AS withdrawal
            FROM movements GROUP BY date
    )
    SELECT date, pg_catalog.sum(delta) OVER (ORDER BY date ROWS UNBOUNDED PRECEDING)
        + (SELECT opening_balance FROM public.budget_periods
            WHERE id = p_period AND user_id = auth.uid()), withdrawal FROM daily;
$$;
REVOKE ALL ON FUNCTION private.available_daily(uuid) FROM PUBLIC, anon, authenticated;

-- Se reemplaza el helper desde 005, sin editar el archivo de migración 004.
CREATE OR REPLACE FUNCTION private.check_available(p_period uuid, p_since date) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM private.available_daily(p_period)
        WHERE date >= p_since AND withdrawal AND balance < 0) THEN
        RAISE EXCEPTION 'Disponible insuficiente al cierre de una fecha con transferencia a ahorro'
            USING ERRCODE = '22023';
    END IF;
END;
$$;
REVOKE ALL ON FUNCTION private.check_available(uuid, date) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION private.available_at(p_period uuid, p_date date) RETURNS numeric
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$
    SELECT balance FROM private.available_daily(p_period)
        WHERE date <= p_date ORDER BY date DESC LIMIT 1;
$$;
REVOKE ALL ON FUNCTION private.available_at(uuid, date) FROM PUBLIC, anon, authenticated;

-- Solo bajo lock_current_user. Las RPC de planificación también rechazan
-- snapshots anteriores al lock, para ver cierres confirmados por otra petición.
CREATE FUNCTION private.open_budget_period(p_period_id uuid) RETURNS public.budget_periods
LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
DECLARE
    v_period public.budget_periods;
BEGIN
    IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'Las RPC de períodos y presupuestos requieren READ COMMITTED' USING ERRCODE = '25001';
    END IF;
    SELECT * INTO v_period FROM public.budget_periods
        WHERE id = p_period_id AND user_id = auth.uid() AND status = 'open' FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Período abierto no encontrado' USING ERRCODE = 'P0002';
    END IF;
    RETURN v_period;
END;
$$;
REVOKE ALL ON FUNCTION private.open_budget_period(uuid) FROM PUBLIC, anon, authenticated;

-- p_end_date obligatorio como argumento: NULL para between_paydays.
-- p_general_budget omitido/NULL no copia ningún presupuesto anterior.
CREATE FUNCTION public.advance_period(
    p_current_period_id uuid, p_expected_version bigint, p_mode text,
    p_start_date date, p_end_date date, p_request_id uuid,
    p_general_budget numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_old public.budget_periods;
    v_new public.budget_periods;
    v_budget numeric(20,2);
    v_balance numeric;
    v_end date;
    v_today date;
    v_timezone text;
    v_hash text;
    v_result jsonb;
BEGIN
    v_budget := private.budget_amount(p_general_budget);
    v_hash := private.financial_request_hash('advance_period', pg_catalog.jsonb_build_object(
        'current_period_id',p_current_period_id,'expected_version',p_expected_version,
        'mode',p_mode,'start_date',p_start_date,'end_date',p_end_date,'general_budget',v_budget));
    -- Este helper de 004 es genérico: valida request_id, READ COMMITTED y tipo/huella.
    v_result := private.movement_retry(p_request_id,'advance_period',v_hash);
    IF v_result IS NOT NULL THEN RETURN v_result; END IF;
    IF p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'expected_version obligatorio y positivo' USING ERRCODE = '22023';
    END IF;
    v_old := private.open_budget_period(p_current_period_id);
    IF v_old.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    SELECT timezone INTO v_timezone FROM public.user_settings WHERE user_id = v_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Configuración inexistente' USING ERRCODE = 'P0002';
    END IF;
    v_today := (pg_catalog.clock_timestamp() AT TIME ZONE v_timezone)::date;
    IF p_mode IS NULL OR p_mode NOT IN ('monthly','annual','custom','between_paydays')
        OR p_start_date IS NULL OR NOT pg_catalog.isfinite(p_start_date)
        OR p_start_date > v_today
        OR (p_end_date IS NOT NULL AND NOT pg_catalog.isfinite(p_end_date)) THEN
        RAISE EXCEPTION 'Modo o fechas inválidos' USING ERRCODE = '22023';
    END IF;
    IF p_mode = 'between_paydays' THEN
        IF p_end_date IS NOT NULL THEN
            RAISE EXCEPTION 'El nuevo período entre nóminas debe tener final abierto' USING ERRCODE = '22023';
        END IF;
    ELSE
        IF p_end_date IS NULL OR p_end_date < v_today THEN
            RAISE EXCEPTION 'El nuevo período debe contener hoy' USING ERRCODE = '22023';
        END IF;
        IF p_mode = 'monthly' AND (
            p_start_date <> pg_catalog.date_trunc('month',v_today::timestamp)::date
            OR p_end_date <> (pg_catalog.date_trunc('month',v_today::timestamp) + interval '1 month - 1 day')::date
        ) THEN
            RAISE EXCEPTION 'Debe ser el mes natural actual' USING ERRCODE = '22023';
        END IF;
        IF p_mode = 'annual' AND (
            p_start_date <> pg_catalog.date_trunc('year',v_today::timestamp)::date
            OR p_end_date <> (pg_catalog.date_trunc('year',v_today::timestamp) + interval '1 year - 1 day')::date
        ) THEN
            RAISE EXCEPTION 'Debe ser el año natural actual' USING ERRCODE = '22023';
        END IF;
    END IF;
    IF p_start_date <= v_old.start_date THEN
        RAISE EXCEPTION 'El nuevo inicio debe ser posterior al anterior' USING ERRCODE = '22023';
    END IF;
    -- El modo del período ANTERIOR determina si se fija o conserva su final.
    v_end := CASE WHEN v_old.mode = 'between_paydays' THEN p_start_date - 1 ELSE v_old.end_date END;
    IF p_start_date <= v_end THEN
        RAISE EXCEPTION 'El nuevo período solapa el período anterior' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM public.budget_periods
        WHERE user_id = v_user_id AND id <> v_old.id
            AND (end_date IS NULL OR end_date >= p_start_date)) THEN
        RAISE EXCEPTION 'El nuevo período debe seguir a toda la historia existente' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.expenses WHERE user_id = v_user_id AND period_id = v_old.id
            AND (date < v_old.start_date OR date > v_end)
        UNION ALL
        SELECT 1 FROM public.incomes WHERE user_id = v_user_id AND period_id = v_old.id
            AND (date < v_old.start_date OR date > v_end)
        UNION ALL
        SELECT 1 FROM public.transfers WHERE user_id = v_user_id AND period_id = v_old.id
            AND (date < v_old.start_date OR date > v_end)
    ) THEN
        RAISE EXCEPTION 'El cierre dejaría movimientos fuera del período; corrige el historial primero'
            USING ERRCODE = '22023';
    END IF;
    v_balance := private.available_at(v_old.id,v_end);
    IF v_balance IS NULL OR pg_catalog.abs(v_balance) >= 1000000000000000000::numeric THEN
        RAISE EXCEPTION 'Saldo de cierre fuera de numeric(20,2)' USING ERRCODE = '22023';
    END IF;
    UPDATE public.budget_periods SET status = 'closed', end_date = v_end,
        closing_balance = v_balance, closed_at = pg_catalog.clock_timestamp(),
        version = version + 1, updated_at = pg_catalog.clock_timestamp()
        WHERE id = v_old.id AND user_id = v_user_id RETURNING * INTO v_old;
    INSERT INTO public.budget_periods(user_id,mode,start_date,end_date,opening_balance,general_budget)
        VALUES (v_user_id,p_mode,p_start_date,p_end_date,v_balance,v_budget) RETURNING * INTO v_new;
    v_result := pg_catalog.jsonb_build_object('closed_period',pg_catalog.to_jsonb(v_old),
        'opened_period',pg_catalog.to_jsonb(v_new));
    INSERT INTO public.financial_operations(user_id,idempotency_key,operation_type,request_hash,result)
        VALUES (v_user_id,p_request_id,'advance_period',v_hash,v_result);
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.advance_period(uuid,bigint,text,date,date,uuid,numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.advance_period(uuid,bigint,text,date,date,uuid,numeric) TO authenticated;

CREATE FUNCTION public.set_general_budget(p_period_id uuid, p_general_budget numeric, p_expected_version bigint)
RETURNS public.budget_periods
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_row public.budget_periods;
    v_amount numeric(20,2);
BEGIN
    v_amount := private.budget_amount(p_general_budget);
    v_row := private.open_budget_period(p_period_id);
    IF p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'expected_version obligatorio y positivo' USING ERRCODE = '22023';
    END IF;
    IF v_row.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    UPDATE public.budget_periods SET general_budget = v_amount,
        version = version + 1, updated_at = pg_catalog.clock_timestamp()
        WHERE id = v_row.id AND user_id = v_user_id RETURNING * INTO v_row;
    RETURN v_row;
END;
$$;
REVOKE ALL ON FUNCTION public.set_general_budget(uuid,numeric,bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_general_budget(uuid,numeric,bigint) TO authenticated;

CREATE FUNCTION public.create_category_budget(p_period_id uuid, p_category_id uuid, p_amount numeric)
RETURNS public.period_category_budgets
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_row public.period_category_budgets;
    v_amount numeric(20,2);
BEGIN
    v_amount := private.budget_amount(p_amount);
    IF v_amount IS NULL THEN
        RAISE EXCEPTION 'amount obligatorio' USING ERRCODE = '22023';
    END IF;
    PERFORM private.open_budget_period(p_period_id);
    IF NOT EXISTS (SELECT 1 FROM public.categories
        WHERE id = p_category_id AND user_id = v_user_id AND is_active) THEN
        RAISE EXCEPTION 'Categoría inexistente, ajena o inactiva' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.period_category_budgets(user_id,period_id,category_id,amount)
        VALUES (v_user_id,p_period_id,p_category_id,v_amount) RETURNING * INTO v_row;
    RETURN v_row;
END;
$$;
REVOKE ALL ON FUNCTION public.create_category_budget(uuid,uuid,numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_category_budget(uuid,uuid,numeric) TO authenticated;

CREATE FUNCTION public.update_category_budget(p_id uuid, p_expected_version bigint, p_amount numeric)
RETURNS public.period_category_budgets
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_row public.period_category_budgets;
    v_amount numeric(20,2);
BEGIN
    v_amount := private.budget_amount(p_amount);
    IF v_amount IS NULL OR p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'amount y expected_version válidos obligatorios' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_row FROM public.period_category_budgets
        WHERE id = p_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Presupuesto no encontrado' USING ERRCODE = 'P0002'; END IF;
    PERFORM private.open_budget_period(v_row.period_id);
    IF v_row.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    UPDATE public.period_category_budgets SET amount = v_amount,
        version = version + 1, updated_at = pg_catalog.clock_timestamp()
        WHERE id = v_row.id AND user_id = v_user_id RETURNING * INTO v_row;
    RETURN v_row;
END;
$$;
REVOKE ALL ON FUNCTION public.update_category_budget(uuid,bigint,numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_category_budget(uuid,bigint,numeric) TO authenticated;

CREATE FUNCTION public.delete_category_budget(p_id uuid, p_expected_version bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_row public.period_category_budgets;
BEGIN
    IF p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'expected_version obligatorio y positivo' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_row FROM public.period_category_budgets
        WHERE id = p_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Presupuesto no encontrado' USING ERRCODE = 'P0002'; END IF;
    PERFORM private.open_budget_period(v_row.period_id);
    IF v_row.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    DELETE FROM public.period_category_budgets WHERE id = v_row.id AND user_id = v_user_id;
    RETURN pg_catalog.jsonb_build_object('deleted',true,'budget',pg_catalog.to_jsonb(v_row));
END;
$$;
REVOKE ALL ON FUNCTION public.delete_category_budget(uuid,bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_category_budget(uuid,bigint) TO authenticated;

-- Las ACL de tablas y policies de 002 siguen vigentes; ninguna escritura directa.
COMMIT;
