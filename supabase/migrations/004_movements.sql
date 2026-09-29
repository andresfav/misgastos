-- MisGastos 004: movimientos. Aplicar como propietario de 001–003.
-- Semántica DATE: neto al cierre diario, sin orden intradía.
-- Disponible puede ser negativo salvo al cierre de días con disponible -> ahorro.
-- Ahorro no puede ser negativo en ningún cierre diario afectado.
-- Las RPC son VOLATILE (default): en READ COMMITTED sus consultas tras esperar
-- el advisory lock ven los commits anteriores. Usar READ COMMITTED; en niveles
-- superiores se rechaza la llamada: un snapshot anterior al lock no es seguro.
BEGIN;

CREATE FUNCTION private.movement_amount(p_amount numeric) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE SECURITY INVOKER SET search_path = ''
AS $$
BEGIN
    IF p_amount IS NULL OR p_amount::text IN ('NaN', 'Infinity', '-Infinity')
        OR p_amount <= 0 OR p_amount <> pg_catalog.trunc(p_amount, 2)
        OR p_amount >= 1000000000000000000::numeric THEN
        RAISE EXCEPTION 'Importe inválido: positivo, numeric(20,2), sin redondeo' USING ERRCODE = '22023';
    END IF;
    RETURN p_amount::numeric(20,2);
END;
$$;
REVOKE ALL ON FUNCTION private.movement_amount(numeric) FROM PUBLIC, anon, authenticated;

-- Solo se llama bajo lock_current_user; NULL significa petición todavía ausente.
CREATE FUNCTION private.movement_retry(p_request_id uuid, p_operation text, p_hash text)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
DECLARE
    v_operation public.financial_operations;
BEGIN
    IF p_request_id IS NULL THEN
        RAISE EXCEPTION 'request_id es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'Las RPC de movimientos requieren READ COMMITTED' USING ERRCODE = '25001';
    END IF;
    SELECT * INTO v_operation FROM public.financial_operations
        WHERE user_id = auth.uid() AND idempotency_key = p_request_id;
    IF FOUND THEN
        IF v_operation.operation_type <> p_operation OR v_operation.request_hash <> p_hash THEN
            RAISE EXCEPTION 'request_id reutilizado con otra petición' USING ERRCODE = '22023';
        END IF;
        RETURN v_operation.result;
    END IF;
    RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION private.movement_retry(uuid, text, text) FROM PUBLIC, anon, authenticated;

-- Se utiliza también al borrar, con la fecha original. Nunca recibe período del cliente.
CREATE FUNCTION private.movement_period(p_date date) RETURNS public.budget_periods
LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
DECLARE
    v_period public.budget_periods;
    v_timezone text;
BEGIN
    SELECT timezone INTO v_timezone FROM public.user_settings WHERE user_id = auth.uid();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Configuración inexistente' USING ERRCODE = 'P0002';
    END IF;
    IF p_date IS NULL OR NOT pg_catalog.isfinite(p_date)
        OR p_date > (pg_catalog.clock_timestamp() AT TIME ZONE v_timezone)::date THEN
        RAISE EXCEPTION 'Fecha inválida o futura' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_period FROM public.budget_periods
        WHERE user_id = auth.uid() AND status = 'open';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe período abierto' USING ERRCODE = 'P0002';
    END IF;
    IF p_date < v_period.start_date OR (v_period.end_date IS NOT NULL AND p_date > v_period.end_date) THEN
        RAISE EXCEPTION 'Fecha fuera del período abierto' USING ERRCODE = '22023';
    END IF;
    RETURN v_period;
END;
$$;
REVOKE ALL ON FUNCTION private.movement_period(date) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION private.expense_references(
    p_category uuid, p_payment uuid, p_old_category uuid, p_old_payment uuid
) RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.categories WHERE id = p_category AND user_id = auth.uid()
        AND (is_active OR id = p_old_category)) THEN
        RAISE EXCEPTION 'Categoría inexistente, ajena o inactiva' USING ERRCODE = '22023';
    END IF;
    IF p_payment IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.payment_methods WHERE id = p_payment AND user_id = auth.uid()
            AND (is_active OR id = p_old_payment)
    ) THEN
        RAISE EXCEPTION 'Método inexistente, ajeno o inactivo' USING ERRCODE = '22023';
    END IF;
END;
$$;
REVOKE ALL ON FUNCTION private.expense_references(uuid, uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;

-- p_old_account es la referencia ORIGINAL del mismo campo, no la del otro extremo.
CREATE FUNCTION private.savings_reference(p_account uuid, p_old_account uuid, p_date date)
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
BEGIN
    IF p_account IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.savings_accounts WHERE id = p_account AND user_id = auth.uid()
            AND (is_active OR id = p_old_account) AND start_date <= p_date
    ) THEN
        RAISE EXCEPTION 'Cuenta ajena, inexistente, inactiva o anterior a start_date' USING ERRCODE = '22023';
    END IF;
END;
$$;
REVOKE ALL ON FUNCTION private.savings_reference(uuid, uuid, date) FROM PUBLIC, anon, authenticated;

-- Se agrega por DATE antes de la ventana: ni UUID ni timestamps ordenan el día.
-- La ventana abarca TODO el período; p_since solo filtra los cierres a validar.
CREATE FUNCTION private.check_available(p_period uuid, p_since date) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
BEGIN
    IF EXISTS (
        WITH movements AS (
            SELECT date, amount AS delta, false AS withdrawal FROM public.incomes
                WHERE user_id = auth.uid() AND period_id = p_period AND savings_account_id IS NULL
            UNION ALL
            SELECT date, -amount, false FROM public.expenses
                WHERE user_id = auth.uid() AND period_id = p_period
            UNION ALL
            SELECT date, CASE WHEN from_savings_account_id IS NULL THEN -amount ELSE amount END,
                from_savings_account_id IS NULL
                FROM public.transfers WHERE user_id = auth.uid() AND period_id = p_period
                    AND (from_savings_account_id IS NULL OR to_savings_account_id IS NULL)
        ), daily AS (
            SELECT date, pg_catalog.sum(delta) AS delta, pg_catalog.bool_or(withdrawal) AS withdrawal
                FROM movements GROUP BY date
        ), balances AS (
            SELECT date, withdrawal, pg_catalog.sum(delta) OVER (ORDER BY date ROWS UNBOUNDED PRECEDING)
                + (SELECT opening_balance FROM public.budget_periods
                    WHERE id = p_period AND user_id = auth.uid()) AS balance FROM daily
        ) SELECT 1 FROM balances WHERE date >= p_since AND withdrawal AND balance < 0
    ) THEN
        RAISE EXCEPTION 'Disponible insuficiente al cierre de una fecha con transferencia a ahorro'
            USING ERRCODE = '22023';
    END IF;
END;
$$;
REVOKE ALL ON FUNCTION private.check_available(uuid, date) FROM PUBLIC, anon, authenticated;

-- El ahorro incluye todos los períodos. Los días sin movimientos mantienen saldo.
CREATE FUNCTION private.check_savings(p_account uuid, p_since date) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
BEGIN
    IF p_account IS NULL THEN RETURN; END IF;
    IF EXISTS (
        WITH movements AS (
            -- La fecha afectada se incluye aunque se haya borrado su último movimiento.
            SELECT p_since AS date, 0::numeric AS delta
            UNION ALL
            SELECT date, amount FROM public.incomes
                WHERE user_id = auth.uid() AND savings_account_id = p_account
            UNION ALL
            SELECT date, amount FROM public.transfers
                WHERE user_id = auth.uid() AND to_savings_account_id = p_account
            UNION ALL
            SELECT date, -amount FROM public.transfers
                WHERE user_id = auth.uid() AND from_savings_account_id = p_account
        ), daily AS (
            SELECT date, pg_catalog.sum(delta) AS delta FROM movements GROUP BY date
        ), balances AS (
            SELECT date, pg_catalog.sum(delta) OVER (ORDER BY date ROWS UNBOUNDED PRECEDING)
                + (SELECT opening_balance FROM public.savings_accounts
                    WHERE id = p_account AND user_id = auth.uid()) AS balance FROM daily
        ) SELECT 1 FROM balances WHERE date >= p_since AND balance < 0
    ) THEN
        RAISE EXCEPTION 'Saldo de ahorro negativo en una fecha afectada' USING ERRCODE = '22023';
    END IF;
END;
$$;
REVOKE ALL ON FUNCTION private.check_savings(uuid, date) FROM PUBLIC, anon, authenticated;

-- Campos opcionales: enviar NULL; is_recurring requiere boolean explícito.
CREATE FUNCTION public.create_expense(
    p_date date,
    p_amount numeric,
    p_category_id uuid,
    p_description text,
    p_payment_method_id uuid,
    p_merchant text,
    p_note text,
    p_is_recurring boolean,
    p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_old public.expenses;
    v_row public.expenses;
    v_period public.budget_periods;
    v_amount numeric(20,2);
    v_hash text;
    v_result jsonb;
    v_since date;
BEGIN
    v_amount := private.movement_amount(p_amount);
    v_hash := private.financial_request_hash('create_expense', pg_catalog.jsonb_build_object(
        'date', p_date,
        'amount', v_amount,
        'category_id', p_category_id,
        'description', p_description,
        'payment_method_id', p_payment_method_id,
        'merchant', p_merchant,
        'note', p_note,
        'is_recurring', p_is_recurring
    ));
    v_result := private.movement_retry(p_request_id, 'create_expense', v_hash);
    IF v_result IS NOT NULL THEN RETURN v_result; END IF;
    v_period := private.movement_period(p_date);
    IF p_is_recurring IS NULL THEN
        RAISE EXCEPTION 'is_recurring no puede ser NULL' USING ERRCODE = '22023';
    END IF;
    PERFORM private.expense_references(p_category_id, p_payment_method_id,
        v_old.category_id, v_old.payment_method_id);
    INSERT INTO public.expenses(user_id, period_id, date, amount, category_id, description, payment_method_id, merchant, note, is_recurring)
        VALUES (v_user_id, v_period.id, p_date, v_amount, p_category_id, p_description, p_payment_method_id, p_merchant, p_note, p_is_recurring)
        RETURNING * INTO v_row;
    v_since := LEAST(v_old.date, v_row.date);
    PERFORM private.check_available(v_period.id, v_since);
    v_result := pg_catalog.to_jsonb(v_row);
    INSERT INTO public.financial_operations(user_id, idempotency_key, operation_type, request_hash, result)
        VALUES (v_user_id, p_request_id, 'create_expense', v_hash, v_result);
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.create_expense(date, numeric, uuid, text, uuid, text, text, boolean, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_expense(date, numeric, uuid, text, uuid, text, text, boolean, uuid) TO authenticated;

-- Campos opcionales: enviar NULL; is_recurring requiere boolean explícito.
CREATE FUNCTION public.update_expense(
    p_id uuid,
    p_expected_version bigint,
    p_date date,
    p_amount numeric,
    p_category_id uuid,
    p_description text,
    p_payment_method_id uuid,
    p_merchant text,
    p_note text,
    p_is_recurring boolean,
    p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_old public.expenses;
    v_row public.expenses;
    v_period public.budget_periods;
    v_amount numeric(20,2);
    v_hash text;
    v_result jsonb;
    v_since date;
BEGIN
    v_amount := private.movement_amount(p_amount);
    v_hash := private.financial_request_hash('update_expense', pg_catalog.jsonb_build_object(
        'id', p_id,
        'expected_version', p_expected_version,
        'date', p_date,
        'amount', v_amount,
        'category_id', p_category_id,
        'description', p_description,
        'payment_method_id', p_payment_method_id,
        'merchant', p_merchant,
        'note', p_note,
        'is_recurring', p_is_recurring
    ));
    v_result := private.movement_retry(p_request_id, 'update_expense', v_hash);
    IF v_result IS NOT NULL THEN RETURN v_result; END IF;
    -- El retry precede incluso a la búsqueda: funciona con versión vieja o fila borrada.
    IF p_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'id y expected_version son obligatorios' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_old FROM public.expenses
        WHERE id = p_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Movimiento no encontrado' USING ERRCODE = 'P0002';
    END IF;
    IF v_old.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    v_period := private.movement_period(p_date);
    IF v_period.id <> v_old.period_id THEN
        RAISE EXCEPTION 'El período original debe seguir abierto' USING ERRCODE = '22023';
    END IF;
    IF p_is_recurring IS NULL THEN
        RAISE EXCEPTION 'is_recurring no puede ser NULL' USING ERRCODE = '22023';
    END IF;
    PERFORM private.expense_references(p_category_id, p_payment_method_id,
        v_old.category_id, v_old.payment_method_id);
    UPDATE public.expenses SET date = p_date,
        amount = v_amount,
        category_id = p_category_id,
        description = p_description,
        payment_method_id = p_payment_method_id,
        merchant = p_merchant,
        note = p_note,
        is_recurring = p_is_recurring,
        version = version + 1, updated_at = pg_catalog.clock_timestamp()
        WHERE id = p_id AND user_id = v_user_id RETURNING * INTO v_row;
    v_since := LEAST(v_old.date, v_row.date);
    PERFORM private.check_available(v_period.id, v_since);
    v_result := pg_catalog.to_jsonb(v_row);
    INSERT INTO public.financial_operations(user_id, idempotency_key, operation_type, request_hash, result)
        VALUES (v_user_id, p_request_id, 'update_expense', v_hash, v_result);
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.update_expense(uuid, bigint, date, numeric, uuid, text, uuid, text, text, boolean, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_expense(uuid, bigint, date, numeric, uuid, text, uuid, text, text, boolean, uuid) TO authenticated;

-- Campos opcionales: enviar NULL; is_recurring requiere boolean explícito.
CREATE FUNCTION public.delete_expense(
    p_id uuid,
    p_expected_version bigint,
    p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_old public.expenses;
    v_row public.expenses;
    v_period public.budget_periods;
    v_amount numeric(20,2);
    v_hash text;
    v_result jsonb;
    v_since date;
BEGIN
    v_hash := private.financial_request_hash('delete_expense', pg_catalog.jsonb_build_object(
        'id', p_id,
        'expected_version', p_expected_version
    ));
    v_result := private.movement_retry(p_request_id, 'delete_expense', v_hash);
    IF v_result IS NOT NULL THEN RETURN v_result; END IF;
    -- El retry precede incluso a la búsqueda: funciona con versión vieja o fila borrada.
    IF p_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'id y expected_version son obligatorios' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_old FROM public.expenses
        WHERE id = p_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Movimiento no encontrado' USING ERRCODE = 'P0002';
    END IF;
    IF v_old.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    v_period := private.movement_period(v_old.date);
    IF v_period.id <> v_old.period_id THEN
        RAISE EXCEPTION 'El período original debe seguir abierto' USING ERRCODE = '22023';
    END IF;
    DELETE FROM public.expenses WHERE id = p_id AND user_id = v_user_id;
    v_since := LEAST(v_old.date, v_row.date);
    PERFORM private.check_available(v_period.id, v_since);
    v_result := pg_catalog.jsonb_build_object('deleted', true, 'movement', pg_catalog.to_jsonb(v_old));
    INSERT INTO public.financial_operations(user_id, idempotency_key, operation_type, request_hash, result)
        VALUES (v_user_id, p_request_id, 'delete_expense', v_hash, v_result);
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.delete_expense(uuid, bigint, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_expense(uuid, bigint, uuid) TO authenticated;

-- Campos opcionales: enviar NULL; is_recurring requiere boolean explícito.
CREATE FUNCTION public.create_income(
    p_date date,
    p_amount numeric,
    p_savings_account_id uuid,
    p_description text,
    p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_old public.incomes;
    v_row public.incomes;
    v_period public.budget_periods;
    v_amount numeric(20,2);
    v_hash text;
    v_result jsonb;
    v_since date;
    v_affected record;
BEGIN
    v_amount := private.movement_amount(p_amount);
    v_hash := private.financial_request_hash('create_income', pg_catalog.jsonb_build_object(
        'date', p_date,
        'amount', v_amount,
        'savings_account_id', p_savings_account_id,
        'description', p_description
    ));
    v_result := private.movement_retry(p_request_id, 'create_income', v_hash);
    IF v_result IS NOT NULL THEN RETURN v_result; END IF;
    v_period := private.movement_period(p_date);
    PERFORM private.savings_reference(p_savings_account_id, v_old.savings_account_id, p_date);
    INSERT INTO public.incomes(user_id, period_id, date, amount, savings_account_id, description)
        VALUES (v_user_id, v_period.id, p_date, v_amount, p_savings_account_id, p_description)
        RETURNING * INTO v_row;
    v_since := LEAST(v_old.date, v_row.date);
    IF (v_old.id IS NOT NULL AND v_old.savings_account_id IS NULL)
        OR (v_row.id IS NOT NULL AND v_row.savings_account_id IS NULL) THEN
        PERFORM private.check_available(v_period.id, v_since);
    END IF;
    FOR v_affected IN
        SELECT account_id, min(date) AS since FROM (VALUES
            (v_old.savings_account_id, v_old.date), (v_row.savings_account_id, v_row.date)
        ) AS affected(account_id, date) WHERE account_id IS NOT NULL GROUP BY account_id
    LOOP
        PERFORM private.check_savings(v_affected.account_id, v_affected.since);
    END LOOP;
    v_result := pg_catalog.to_jsonb(v_row);
    INSERT INTO public.financial_operations(user_id, idempotency_key, operation_type, request_hash, result)
        VALUES (v_user_id, p_request_id, 'create_income', v_hash, v_result);
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.create_income(date, numeric, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_income(date, numeric, uuid, text, uuid) TO authenticated;

-- Campos opcionales: enviar NULL; is_recurring requiere boolean explícito.
CREATE FUNCTION public.update_income(
    p_id uuid,
    p_expected_version bigint,
    p_date date,
    p_amount numeric,
    p_savings_account_id uuid,
    p_description text,
    p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_old public.incomes;
    v_row public.incomes;
    v_period public.budget_periods;
    v_amount numeric(20,2);
    v_hash text;
    v_result jsonb;
    v_since date;
    v_affected record;
BEGIN
    v_amount := private.movement_amount(p_amount);
    v_hash := private.financial_request_hash('update_income', pg_catalog.jsonb_build_object(
        'id', p_id,
        'expected_version', p_expected_version,
        'date', p_date,
        'amount', v_amount,
        'savings_account_id', p_savings_account_id,
        'description', p_description
    ));
    v_result := private.movement_retry(p_request_id, 'update_income', v_hash);
    IF v_result IS NOT NULL THEN RETURN v_result; END IF;
    -- El retry precede incluso a la búsqueda: funciona con versión vieja o fila borrada.
    IF p_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'id y expected_version son obligatorios' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_old FROM public.incomes
        WHERE id = p_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Movimiento no encontrado' USING ERRCODE = 'P0002';
    END IF;
    IF v_old.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    v_period := private.movement_period(p_date);
    IF v_period.id <> v_old.period_id THEN
        RAISE EXCEPTION 'El período original debe seguir abierto' USING ERRCODE = '22023';
    END IF;
    PERFORM private.savings_reference(p_savings_account_id, v_old.savings_account_id, p_date);
    UPDATE public.incomes SET date = p_date,
        amount = v_amount,
        savings_account_id = p_savings_account_id,
        description = p_description,
        version = version + 1, updated_at = pg_catalog.clock_timestamp()
        WHERE id = p_id AND user_id = v_user_id RETURNING * INTO v_row;
    v_since := LEAST(v_old.date, v_row.date);
    IF (v_old.id IS NOT NULL AND v_old.savings_account_id IS NULL)
        OR (v_row.id IS NOT NULL AND v_row.savings_account_id IS NULL) THEN
        PERFORM private.check_available(v_period.id, v_since);
    END IF;
    FOR v_affected IN
        SELECT account_id, min(date) AS since FROM (VALUES
            (v_old.savings_account_id, v_old.date), (v_row.savings_account_id, v_row.date)
        ) AS affected(account_id, date) WHERE account_id IS NOT NULL GROUP BY account_id
    LOOP
        PERFORM private.check_savings(v_affected.account_id, v_affected.since);
    END LOOP;
    v_result := pg_catalog.to_jsonb(v_row);
    INSERT INTO public.financial_operations(user_id, idempotency_key, operation_type, request_hash, result)
        VALUES (v_user_id, p_request_id, 'update_income', v_hash, v_result);
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.update_income(uuid, bigint, date, numeric, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_income(uuid, bigint, date, numeric, uuid, text, uuid) TO authenticated;

-- Campos opcionales: enviar NULL; is_recurring requiere boolean explícito.
CREATE FUNCTION public.delete_income(
    p_id uuid,
    p_expected_version bigint,
    p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_old public.incomes;
    v_row public.incomes;
    v_period public.budget_periods;
    v_amount numeric(20,2);
    v_hash text;
    v_result jsonb;
    v_since date;
    v_affected record;
BEGIN
    v_hash := private.financial_request_hash('delete_income', pg_catalog.jsonb_build_object(
        'id', p_id,
        'expected_version', p_expected_version
    ));
    v_result := private.movement_retry(p_request_id, 'delete_income', v_hash);
    IF v_result IS NOT NULL THEN RETURN v_result; END IF;
    -- El retry precede incluso a la búsqueda: funciona con versión vieja o fila borrada.
    IF p_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'id y expected_version son obligatorios' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_old FROM public.incomes
        WHERE id = p_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Movimiento no encontrado' USING ERRCODE = 'P0002';
    END IF;
    IF v_old.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    v_period := private.movement_period(v_old.date);
    IF v_period.id <> v_old.period_id THEN
        RAISE EXCEPTION 'El período original debe seguir abierto' USING ERRCODE = '22023';
    END IF;
    DELETE FROM public.incomes WHERE id = p_id AND user_id = v_user_id;
    v_since := LEAST(v_old.date, v_row.date);
    IF (v_old.id IS NOT NULL AND v_old.savings_account_id IS NULL)
        OR (v_row.id IS NOT NULL AND v_row.savings_account_id IS NULL) THEN
        PERFORM private.check_available(v_period.id, v_since);
    END IF;
    FOR v_affected IN
        SELECT account_id, min(date) AS since FROM (VALUES
            (v_old.savings_account_id, v_old.date), (v_row.savings_account_id, v_row.date)
        ) AS affected(account_id, date) WHERE account_id IS NOT NULL GROUP BY account_id
    LOOP
        PERFORM private.check_savings(v_affected.account_id, v_affected.since);
    END LOOP;
    v_result := pg_catalog.jsonb_build_object('deleted', true, 'movement', pg_catalog.to_jsonb(v_old));
    INSERT INTO public.financial_operations(user_id, idempotency_key, operation_type, request_hash, result)
        VALUES (v_user_id, p_request_id, 'delete_income', v_hash, v_result);
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.delete_income(uuid, bigint, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_income(uuid, bigint, uuid) TO authenticated;

-- Campos opcionales: enviar NULL; is_recurring requiere boolean explícito.
CREATE FUNCTION public.create_transfer(
    p_date date,
    p_amount numeric,
    p_from_savings_account_id uuid,
    p_to_savings_account_id uuid,
    p_description text,
    p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_old public.transfers;
    v_row public.transfers;
    v_period public.budget_periods;
    v_amount numeric(20,2);
    v_hash text;
    v_result jsonb;
    v_since date;
    v_affected record;
BEGIN
    v_amount := private.movement_amount(p_amount);
    v_hash := private.financial_request_hash('create_transfer', pg_catalog.jsonb_build_object(
        'date', p_date,
        'amount', v_amount,
        'from_savings_account_id', p_from_savings_account_id,
        'to_savings_account_id', p_to_savings_account_id,
        'description', p_description
    ));
    v_result := private.movement_retry(p_request_id, 'create_transfer', v_hash);
    IF v_result IS NOT NULL THEN RETURN v_result; END IF;
    v_period := private.movement_period(p_date);
    IF p_from_savings_account_id IS NOT DISTINCT FROM p_to_savings_account_id THEN
        RAISE EXCEPTION 'Extremos inválidos: exige ahorro y cuentas distintas' USING ERRCODE = '22023';
    END IF;
    PERFORM private.savings_reference(p_from_savings_account_id, v_old.from_savings_account_id, p_date);
    PERFORM private.savings_reference(p_to_savings_account_id, v_old.to_savings_account_id, p_date);
    INSERT INTO public.transfers(user_id, period_id, date, amount, from_savings_account_id, to_savings_account_id, description)
        VALUES (v_user_id, v_period.id, p_date, v_amount, p_from_savings_account_id, p_to_savings_account_id, p_description)
        RETURNING * INTO v_row;
    v_since := LEAST(v_old.date, v_row.date);
    IF (v_old.id IS NOT NULL AND (v_old.from_savings_account_id IS NULL OR v_old.to_savings_account_id IS NULL))
        OR (v_row.id IS NOT NULL AND (v_row.from_savings_account_id IS NULL OR v_row.to_savings_account_id IS NULL)) THEN
        PERFORM private.check_available(v_period.id, v_since);
    END IF;
    FOR v_affected IN
        SELECT account_id, min(date) AS since FROM (VALUES
            (v_old.from_savings_account_id, v_old.date), (v_old.to_savings_account_id, v_old.date),
            (v_row.from_savings_account_id, v_row.date), (v_row.to_savings_account_id, v_row.date)
        ) AS affected(account_id, date) WHERE account_id IS NOT NULL GROUP BY account_id
    LOOP
        PERFORM private.check_savings(v_affected.account_id, v_affected.since);
    END LOOP;
    v_result := pg_catalog.to_jsonb(v_row);
    INSERT INTO public.financial_operations(user_id, idempotency_key, operation_type, request_hash, result)
        VALUES (v_user_id, p_request_id, 'create_transfer', v_hash, v_result);
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.create_transfer(date, numeric, uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_transfer(date, numeric, uuid, uuid, text, uuid) TO authenticated;

-- Campos opcionales: enviar NULL; is_recurring requiere boolean explícito.
CREATE FUNCTION public.update_transfer(
    p_id uuid,
    p_expected_version bigint,
    p_date date,
    p_amount numeric,
    p_from_savings_account_id uuid,
    p_to_savings_account_id uuid,
    p_description text,
    p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_old public.transfers;
    v_row public.transfers;
    v_period public.budget_periods;
    v_amount numeric(20,2);
    v_hash text;
    v_result jsonb;
    v_since date;
    v_affected record;
BEGIN
    v_amount := private.movement_amount(p_amount);
    v_hash := private.financial_request_hash('update_transfer', pg_catalog.jsonb_build_object(
        'id', p_id,
        'expected_version', p_expected_version,
        'date', p_date,
        'amount', v_amount,
        'from_savings_account_id', p_from_savings_account_id,
        'to_savings_account_id', p_to_savings_account_id,
        'description', p_description
    ));
    v_result := private.movement_retry(p_request_id, 'update_transfer', v_hash);
    IF v_result IS NOT NULL THEN RETURN v_result; END IF;
    -- El retry precede incluso a la búsqueda: funciona con versión vieja o fila borrada.
    IF p_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'id y expected_version son obligatorios' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_old FROM public.transfers
        WHERE id = p_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Movimiento no encontrado' USING ERRCODE = 'P0002';
    END IF;
    IF v_old.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    v_period := private.movement_period(p_date);
    IF v_period.id <> v_old.period_id THEN
        RAISE EXCEPTION 'El período original debe seguir abierto' USING ERRCODE = '22023';
    END IF;
    IF p_from_savings_account_id IS NOT DISTINCT FROM p_to_savings_account_id THEN
        RAISE EXCEPTION 'Extremos inválidos: exige ahorro y cuentas distintas' USING ERRCODE = '22023';
    END IF;
    PERFORM private.savings_reference(p_from_savings_account_id, v_old.from_savings_account_id, p_date);
    PERFORM private.savings_reference(p_to_savings_account_id, v_old.to_savings_account_id, p_date);
    UPDATE public.transfers SET date = p_date,
        amount = v_amount,
        from_savings_account_id = p_from_savings_account_id,
        to_savings_account_id = p_to_savings_account_id,
        description = p_description,
        version = version + 1, updated_at = pg_catalog.clock_timestamp()
        WHERE id = p_id AND user_id = v_user_id RETURNING * INTO v_row;
    v_since := LEAST(v_old.date, v_row.date);
    IF (v_old.id IS NOT NULL AND (v_old.from_savings_account_id IS NULL OR v_old.to_savings_account_id IS NULL))
        OR (v_row.id IS NOT NULL AND (v_row.from_savings_account_id IS NULL OR v_row.to_savings_account_id IS NULL)) THEN
        PERFORM private.check_available(v_period.id, v_since);
    END IF;
    FOR v_affected IN
        SELECT account_id, min(date) AS since FROM (VALUES
            (v_old.from_savings_account_id, v_old.date), (v_old.to_savings_account_id, v_old.date),
            (v_row.from_savings_account_id, v_row.date), (v_row.to_savings_account_id, v_row.date)
        ) AS affected(account_id, date) WHERE account_id IS NOT NULL GROUP BY account_id
    LOOP
        PERFORM private.check_savings(v_affected.account_id, v_affected.since);
    END LOOP;
    v_result := pg_catalog.to_jsonb(v_row);
    INSERT INTO public.financial_operations(user_id, idempotency_key, operation_type, request_hash, result)
        VALUES (v_user_id, p_request_id, 'update_transfer', v_hash, v_result);
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.update_transfer(uuid, bigint, date, numeric, uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_transfer(uuid, bigint, date, numeric, uuid, uuid, text, uuid) TO authenticated;

-- Campos opcionales: enviar NULL; is_recurring requiere boolean explícito.
CREATE FUNCTION public.delete_transfer(
    p_id uuid,
    p_expected_version bigint,
    p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_old public.transfers;
    v_row public.transfers;
    v_period public.budget_periods;
    v_amount numeric(20,2);
    v_hash text;
    v_result jsonb;
    v_since date;
    v_affected record;
BEGIN
    v_hash := private.financial_request_hash('delete_transfer', pg_catalog.jsonb_build_object(
        'id', p_id,
        'expected_version', p_expected_version
    ));
    v_result := private.movement_retry(p_request_id, 'delete_transfer', v_hash);
    IF v_result IS NOT NULL THEN RETURN v_result; END IF;
    -- El retry precede incluso a la búsqueda: funciona con versión vieja o fila borrada.
    IF p_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'id y expected_version son obligatorios' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_old FROM public.transfers
        WHERE id = p_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Movimiento no encontrado' USING ERRCODE = 'P0002';
    END IF;
    IF v_old.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    v_period := private.movement_period(v_old.date);
    IF v_period.id <> v_old.period_id THEN
        RAISE EXCEPTION 'El período original debe seguir abierto' USING ERRCODE = '22023';
    END IF;
    DELETE FROM public.transfers WHERE id = p_id AND user_id = v_user_id;
    v_since := LEAST(v_old.date, v_row.date);
    IF (v_old.id IS NOT NULL AND (v_old.from_savings_account_id IS NULL OR v_old.to_savings_account_id IS NULL))
        OR (v_row.id IS NOT NULL AND (v_row.from_savings_account_id IS NULL OR v_row.to_savings_account_id IS NULL)) THEN
        PERFORM private.check_available(v_period.id, v_since);
    END IF;
    FOR v_affected IN
        SELECT account_id, min(date) AS since FROM (VALUES
            (v_old.from_savings_account_id, v_old.date), (v_old.to_savings_account_id, v_old.date),
            (v_row.from_savings_account_id, v_row.date), (v_row.to_savings_account_id, v_row.date)
        ) AS affected(account_id, date) WHERE account_id IS NOT NULL GROUP BY account_id
    LOOP
        PERFORM private.check_savings(v_affected.account_id, v_affected.since);
    END LOOP;
    v_result := pg_catalog.jsonb_build_object('deleted', true, 'movement', pg_catalog.to_jsonb(v_old));
    INSERT INTO public.financial_operations(user_id, idempotency_key, operation_type, request_hash, result)
        VALUES (v_user_id, p_request_id, 'delete_transfer', v_hash, v_result);
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.delete_transfer(uuid, bigint, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_transfer(uuid, bigint, uuid) TO authenticated;

-- RLS/SELECT propio de 002 permanece. Se reafirma la prohibición de DML directo.
REVOKE ALL ON TABLE public.expenses, public.incomes, public.transfers FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.expenses, public.incomes, public.transfers TO authenticated;
REVOKE ALL ON TABLE public.financial_operations FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;
COMMIT;
