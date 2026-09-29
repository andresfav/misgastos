-- MisGastos 006: API derivada de lectura. Aplicar como propietario de 001–005.
-- Sin tablas, índices, escrituras de datos ni locks de usuario.
BEGIN;

-- Único ajuste a funciones anteriores: sus cuerpos/ACL no cambian.
-- Ambas solo hacen SELECT. STABLE permite compartir el snapshot de la RPC de
-- lectura, sin que un helper VOLATILE tome otro snapshot a mitad del resultado.
-- Las mutaciones siguen VOLATILE: sus consultas posteriores al lock y al DML
-- adquieren un snapshot nuevo. Estos helpers ven el de ESA consulta posterior,
-- incluido el DML provisional, no el snapshot inicial de la RPC mutante.
ALTER FUNCTION private.available_daily(uuid) STABLE;
ALTER FUNCTION private.available_at(uuid, date) STABLE;

-- Fecha de la sentencia, no del inicio de una transacción larga ni del servidor.
CREATE FUNCTION private.read_today() RETURNS date
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_timezone text;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Se requiere sesión autenticada' USING ERRCODE = '28000';
    END IF;
    SELECT timezone INTO v_timezone FROM public.user_settings WHERE user_id = v_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Configura primero moneda y zona horaria' USING ERRCODE = 'P0002';
    END IF;
    RETURN (pg_catalog.statement_timestamp() AT TIME ZONE v_timezone)::date;
END;
$$;
REVOKE ALL ON FUNCTION private.read_today() FROM PUBLIC, anon, authenticated;

-- Una agregación para todas las cuentas, sin SELECT por cuenta ni bucle N+1.
-- Incluye todo el historial hasta p_date, sin reiniciar el ahorro por período.
CREATE FUNCTION private.savings_balances_at(p_date date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = ''
AS $$
    WITH movements AS (
        SELECT savings_account_id AS account_id, amount AS delta FROM public.incomes
            WHERE user_id = auth.uid() AND savings_account_id IS NOT NULL AND date <= p_date
        UNION ALL
        SELECT to_savings_account_id, amount FROM public.transfers
            WHERE user_id = auth.uid() AND to_savings_account_id IS NOT NULL AND date <= p_date
        UNION ALL
        SELECT from_savings_account_id, -amount FROM public.transfers
            WHERE user_id = auth.uid() AND from_savings_account_id IS NOT NULL AND date <= p_date
    ), totals AS (
        SELECT account_id, pg_catalog.sum(delta) AS delta FROM movements GROUP BY account_id
    )
    SELECT coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id',a.id,'name',a.name,'start_date',a.start_date,'opening_balance',a.opening_balance,
        'is_active',a.is_active,'version',a.version,
        'current_balance',a.opening_balance + coalesce(t.delta,0::numeric)
    ) ORDER BY a.is_active DESC,pg_catalog.lower(pg_catalog.btrim(a.name)),a.id),'[]'::jsonb)
    FROM public.savings_accounts a LEFT JOIN totals t ON t.account_id = a.id
    WHERE a.user_id = auth.uid();
$$;
REVOKE ALL ON FUNCTION private.savings_balances_at(date) FROM PUBLIC, anon, authenticated;

-- Compartido por estado actual y resumen. Ownership comprobado incluso al ser
-- llamado desde SECURITY DEFINER. No expone ni consulta financial_operations.
CREATE FUNCTION private.period_summary_at(p_period_id uuid, p_today date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = ''
AS $$
DECLARE
    v_period public.budget_periods;
    v_date date;
    v_expenses numeric;
    v_income_available numeric;
    v_income_savings numeric;
    v_to_savings numeric;
    v_from_savings numeric;
BEGIN
    SELECT * INTO v_period FROM public.budget_periods
        WHERE id = p_period_id AND user_id = auth.uid();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Período no encontrado' USING ERRCODE = 'P0002';
    END IF;
    v_date := CASE WHEN v_period.status = 'closed' THEN v_period.end_date ELSE p_today END;
    SELECT coalesce(pg_catalog.sum(amount),0::numeric) INTO v_expenses
        FROM public.expenses WHERE user_id = auth.uid() AND period_id = v_period.id AND date <= v_date;
    SELECT coalesce(pg_catalog.sum(amount) FILTER (WHERE savings_account_id IS NULL),0::numeric),
        coalesce(pg_catalog.sum(amount) FILTER (WHERE savings_account_id IS NOT NULL),0::numeric)
        INTO v_income_available,v_income_savings
        FROM public.incomes WHERE user_id = auth.uid() AND period_id = v_period.id AND date <= v_date;
    SELECT coalesce(pg_catalog.sum(amount) FILTER (WHERE from_savings_account_id IS NULL),0::numeric),
        coalesce(pg_catalog.sum(amount) FILTER (WHERE to_savings_account_id IS NULL),0::numeric)
        INTO v_to_savings,v_from_savings
        FROM public.transfers WHERE user_id = auth.uid() AND period_id = v_period.id AND date <= v_date;
    RETURN pg_catalog.jsonb_build_object(
        'as_of_date',v_date,'period',pg_catalog.to_jsonb(v_period),
        'opening_balance',v_period.opening_balance,'closing_balance',v_period.closing_balance,
        'available',private.available_at(v_period.id,v_date),
        'expenses_total',v_expenses,'income_total',v_income_available + v_income_savings,
        'income_to_available',v_income_available,'income_to_savings',v_income_savings,
        'transfer_to_savings_total',v_to_savings,'transfer_from_savings_total',v_from_savings,
        'general_budget',v_period.general_budget,'general_budget_spent',v_expenses,
        'general_budget_remaining',v_period.general_budget - v_expenses);
END;
$$;
REVOKE ALL ON FUNCTION private.period_summary_at(uuid, date) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.get_current_financial_state() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_today date;
    v_period_id uuid;
    v_result jsonb;
BEGIN
    -- read_today rechaza uid ausente y configuración ausente, sin adquirir lock.
    v_today := private.read_today();
    SELECT id INTO v_period_id FROM public.budget_periods
        WHERE user_id = v_user_id AND status = 'open';
    IF FOUND THEN
        v_result := private.period_summary_at(v_period_id,v_today);
        v_result := (v_result - 'period') || pg_catalog.jsonb_build_object('current_period',v_result->'period');
    ELSE
        -- NULL distingue ausencia de período de un período cuyo total es cero.
        v_result := pg_catalog.jsonb_build_object(
            'as_of_date',v_today,'current_period',NULL,'opening_balance',NULL,'closing_balance',NULL,
            'available',NULL,'expenses_total',NULL,'income_total',NULL,
            'income_to_available',NULL,'income_to_savings',NULL,
            'transfer_to_savings_total',NULL,'transfer_from_savings_total',NULL,
            'general_budget',NULL,'general_budget_spent',NULL,'general_budget_remaining',NULL);
    END IF;
    RETURN v_result || pg_catalog.jsonb_build_object('savings_balances',private.savings_balances_at(v_today));
END;
$$;
REVOKE ALL ON FUNCTION public.get_current_financial_state() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_current_financial_state() TO authenticated;

CREATE FUNCTION public.get_savings_balances() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    -- auth.uid y settings se validan en read_today; el helper filtra por auth.uid.
    RETURN private.savings_balances_at(private.read_today());
END;
$$;
REVOKE ALL ON FUNCTION public.get_savings_balances() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_savings_balances() TO authenticated;

CREATE FUNCTION public.get_period_summary(p_period_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    RETURN private.period_summary_at(p_period_id,private.read_today());
END;
$$;
REVOKE ALL ON FUNCTION public.get_period_summary(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_period_summary(uuid) TO authenticated;

CREATE FUNCTION public.get_category_budget_usage(p_period_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_result jsonb;
BEGIN
    PERFORM private.read_today();
    IF NOT EXISTS (SELECT 1 FROM public.budget_periods WHERE id = p_period_id AND user_id = v_user_id) THEN
        RAISE EXCEPTION 'Período no encontrado' USING ERRCODE = 'P0002';
    END IF;
    WITH spent AS (
        SELECT category_id,pg_catalog.sum(amount) AS amount FROM public.expenses
            WHERE user_id = v_user_id AND period_id = p_period_id GROUP BY category_id
    ), budgets AS (
        SELECT id,category_id,amount,version FROM public.period_category_budgets
            WHERE user_id = v_user_id AND period_id = p_period_id
    ), usage AS (
        SELECT coalesce(s.category_id,b.category_id) AS category_id,b.id AS budget_id,
            b.amount AS budget_amount,b.version AS budget_version,coalesce(s.amount,0::numeric) AS spent
            FROM spent s FULL JOIN budgets b ON b.category_id = s.category_id
    )
    SELECT coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'category_id',c.id,'category_name',c.name,'category_is_active',c.is_active,
        'budget_id',u.budget_id,'budget_amount',u.budget_amount,'budget_version',u.budget_version,
        'spent',u.spent,'remaining',u.budget_amount - u.spent
    ) ORDER BY u.spent DESC,pg_catalog.lower(pg_catalog.btrim(c.name)),c.id),'[]'::jsonb)
    INTO v_result FROM usage u JOIN public.categories c ON c.id = u.category_id AND c.user_id = v_user_id;
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.get_category_budget_usage(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_category_budget_usage(uuid) TO authenticated;

COMMIT;
