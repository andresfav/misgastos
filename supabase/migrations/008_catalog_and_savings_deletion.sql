-- MisGastos 008: borrado físico/lógico de catálogos y cuentas de ahorro.
-- Aplicar como el mismo propietario que 001–007. No modifica migraciones previas.
BEGIN;

-- Los nombres borrados lógicamente se pueden reutilizar. La base sigue
-- impidiendo dos nombres activos equivalentes para el mismo usuario.
DROP INDEX public.categories_owner_name_key;
CREATE UNIQUE INDEX categories_owner_name_key
    ON public.categories (user_id, pg_catalog.lower(pg_catalog.btrim(name)))
    WHERE is_active;

DROP INDEX public.payment_methods_owner_name_key;
CREATE UNIQUE INDEX payment_methods_owner_name_key
    ON public.payment_methods (user_id, pg_catalog.lower(pg_catalog.btrim(name)))
    WHERE is_active;

DROP INDEX public.savings_accounts_owner_name_key;
CREATE UNIQUE INDEX savings_accounts_owner_name_key
    ON public.savings_accounts (user_id, pg_catalog.lower(pg_catalog.btrim(name)))
    WHERE is_active;

-- Fuente canónica de los saldos puntuales, agregada en una sola pasada. Tanto
-- la API de lectura como el borrado consumen este helper; el cliente no decide
-- con una fórmula aproximada.
CREATE FUNCTION private.savings_account_balances_at(p_date date)
RETURNS TABLE(account_id uuid, current_balance numeric)
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
        SELECT movements.account_id,pg_catalog.sum(delta) AS delta
        FROM movements GROUP BY movements.account_id
    )
    SELECT a.id,a.opening_balance + coalesce(t.delta,0::numeric)
    FROM public.savings_accounts a LEFT JOIN totals t ON t.account_id=a.id
    WHERE a.user_id=auth.uid();
$$;
REVOKE ALL ON FUNCTION private.savings_account_balances_at(date) FROM PUBLIC, anon, authenticated;

-- Conserva el contrato de 006 y añade metadatos de UX. Una eliminación física
-- es históricamente segura si no hay movimientos y la apertura no alcanza un
-- período ya cerrado. La apertura sola no cuenta como movimiento.
CREATE OR REPLACE FUNCTION private.savings_balances_at(p_date date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = ''
AS $$
    SELECT coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id',a.id,'name',a.name,'start_date',a.start_date,'opening_balance',a.opening_balance,
        'is_active',a.is_active,'version',a.version,
        'current_balance',balance.current_balance,
        'has_history',status.has_history,
        'can_hard_delete',NOT status.has_history AND NOT status.touches_closed_period,
        'can_correct_opening_balance',NOT status.has_history AND NOT status.touches_closed_period
    ) ORDER BY a.is_active DESC,pg_catalog.lower(pg_catalog.btrim(a.name)),a.id),'[]'::jsonb)
    FROM public.savings_accounts a
    JOIN private.savings_account_balances_at(p_date) balance ON balance.account_id=a.id
    CROSS JOIN LATERAL (SELECT
        EXISTS (SELECT 1 FROM public.incomes i
            WHERE i.user_id = a.user_id AND i.savings_account_id = a.id)
        OR EXISTS (SELECT 1 FROM public.transfers t
            WHERE t.user_id = a.user_id
              AND (t.from_savings_account_id = a.id OR t.to_savings_account_id = a.id)) AS has_history,
        EXISTS (SELECT 1 FROM public.budget_periods p
            WHERE p.user_id = a.user_id AND p.status = 'closed'
              AND p.end_date >= a.start_date) AS touches_closed_period
    ) status
    WHERE a.user_id = auth.uid();
$$;
REVOKE ALL ON FUNCTION private.savings_balances_at(date) FROM PUBLIC, anon, authenticated;

-- Lectura específica para Ajustes: solo elementos cotidianos activos, con el
-- dato de uso necesario para escoger la etiqueta Eliminar/Borrar. Las filas
-- inactivas antiguas no se migran ni se exponen como lista normal.
CREATE FUNCTION public.get_catalog_management() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_result jsonb;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Se requiere sesión autenticada' USING ERRCODE = '28000';
    END IF;
    SELECT pg_catalog.jsonb_build_object(
        'categories', coalesce((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'id',c.id,'name',c.name,'is_active',c.is_active,'version',c.version,
            'has_history',
                EXISTS (SELECT 1 FROM public.expenses e
                    WHERE e.user_id = c.user_id AND e.category_id = c.id)
                OR EXISTS (SELECT 1 FROM public.period_category_budgets b
                    WHERE b.user_id = c.user_id AND b.category_id = c.id)
        ) ORDER BY pg_catalog.lower(pg_catalog.btrim(c.name)),c.id)
        FROM public.categories c WHERE c.user_id = v_user_id AND c.is_active),'[]'::jsonb),
        'methods', coalesce((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'id',m.id,'name',m.name,'is_active',m.is_active,'version',m.version,
            'has_history',EXISTS (SELECT 1 FROM public.expenses e
                WHERE e.user_id = m.user_id AND e.payment_method_id = m.id)
        ) ORDER BY pg_catalog.lower(pg_catalog.btrim(m.name)),m.id)
        FROM public.payment_methods m WHERE m.user_id = v_user_id AND m.is_active),'[]'::jsonb)
    ) INTO v_result;
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.get_catalog_management() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_catalog_management() TO authenticated;

CREATE FUNCTION public.delete_category(p_id uuid, p_expected_version bigint)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_row public.categories;
    v_used boolean;
BEGIN
    IF p_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'id y expected_version son obligatorios' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_row FROM public.categories
        WHERE id = p_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Categoría no encontrada' USING ERRCODE = 'P0002';
    END IF;
    IF v_row.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    v_used := EXISTS (SELECT 1 FROM public.expenses
        WHERE user_id = v_user_id AND category_id = v_row.id)
        OR EXISTS (SELECT 1 FROM public.period_category_budgets
            WHERE user_id = v_user_id AND category_id = v_row.id);
    IF NOT v_used THEN
        DELETE FROM public.categories WHERE id = v_row.id AND user_id = v_user_id;
        RETURN pg_catalog.jsonb_build_object('mode','hard_deleted','item',pg_catalog.to_jsonb(v_row));
    END IF;
    IF v_row.is_active THEN
        UPDATE public.categories SET is_active = false, version = version + 1,
            updated_at = pg_catalog.clock_timestamp()
            WHERE id = v_row.id AND user_id = v_user_id RETURNING * INTO v_row;
    END IF;
    RETURN pg_catalog.jsonb_build_object('mode','soft_deleted','item',pg_catalog.to_jsonb(v_row));
END;
$$;
REVOKE ALL ON FUNCTION public.delete_category(uuid, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_category(uuid, bigint) TO authenticated;

CREATE FUNCTION public.delete_payment_method(p_id uuid, p_expected_version bigint)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_row public.payment_methods;
    v_used boolean;
BEGIN
    IF p_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'id y expected_version son obligatorios' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_row FROM public.payment_methods
        WHERE id = p_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Método no encontrado' USING ERRCODE = 'P0002';
    END IF;
    IF v_row.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    v_used := EXISTS (SELECT 1 FROM public.expenses
        WHERE user_id = v_user_id AND payment_method_id = v_row.id);
    IF NOT v_used THEN
        DELETE FROM public.payment_methods WHERE id = v_row.id AND user_id = v_user_id;
        RETURN pg_catalog.jsonb_build_object('mode','hard_deleted','item',pg_catalog.to_jsonb(v_row));
    END IF;
    IF v_row.is_active THEN
        UPDATE public.payment_methods SET is_active = false, version = version + 1,
            updated_at = pg_catalog.clock_timestamp()
            WHERE id = v_row.id AND user_id = v_user_id RETURNING * INTO v_row;
    END IF;
    RETURN pg_catalog.jsonb_build_object('mode','soft_deleted','item',pg_catalog.to_jsonb(v_row));
END;
$$;
REVOKE ALL ON FUNCTION public.delete_payment_method(uuid, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_payment_method(uuid, bigint) TO authenticated;

-- Corrige la única apertura cuando todavía no ha entrado en historia cerrada y
-- no existen movimientos. Es la única implementación de esta corrección.
CREATE FUNCTION public.correct_savings_opening_balance(
    p_id uuid, p_opening_balance numeric, p_expected_version bigint, p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_row public.savings_accounts;
    v_opening numeric(20,2);
    v_hash text;
    v_result jsonb;
BEGIN
    IF p_opening_balance IS NULL OR p_opening_balance::text IN ('NaN','Infinity','-Infinity')
        OR p_opening_balance < 0 OR p_opening_balance <> pg_catalog.trunc(p_opening_balance,2)
        OR p_opening_balance >= 1000000000000000000::numeric THEN
        RAISE EXCEPTION 'Saldo inicial inválido' USING ERRCODE = '22023';
    END IF;
    v_opening := p_opening_balance;
    v_hash := private.financial_request_hash('correct_savings_opening_balance',
        pg_catalog.jsonb_build_object('id',p_id,'opening_balance',v_opening,
            'expected_version',p_expected_version));
    v_result := private.movement_retry(p_request_id,'correct_savings_opening_balance',v_hash);
    IF v_result IS NOT NULL THEN RETURN v_result; END IF;
    IF p_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'id y expected_version son obligatorios' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_row FROM public.savings_accounts
        WHERE id = p_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cuenta no encontrada' USING ERRCODE = 'P0002';
    END IF;
    IF v_row.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.incomes
            WHERE user_id = v_user_id AND savings_account_id = v_row.id)
        OR EXISTS (SELECT 1 FROM public.transfers
            WHERE user_id = v_user_id
              AND (from_savings_account_id = v_row.id OR to_savings_account_id = v_row.id))
        OR EXISTS (SELECT 1 FROM public.budget_periods
            WHERE user_id = v_user_id AND status = 'closed' AND end_date >= v_row.start_date) THEN
        RAISE EXCEPTION 'La apertura ya forma parte del historial' USING ERRCODE = '22023';
    END IF;
    UPDATE public.savings_accounts SET opening_balance = v_opening,
        version = version + 1, updated_at = pg_catalog.clock_timestamp()
        WHERE id = v_row.id AND user_id = v_user_id RETURNING * INTO v_row;
    v_result := pg_catalog.jsonb_build_object('account',pg_catalog.to_jsonb(v_row));
    INSERT INTO public.financial_operations(user_id,idempotency_key,operation_type,request_hash,result)
        VALUES (v_user_id,p_request_id,'correct_savings_opening_balance',v_hash,v_result);
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.correct_savings_opening_balance(uuid, numeric, bigint, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.correct_savings_opening_balance(uuid, numeric, bigint, uuid) TO authenticated;

CREATE FUNCTION public.delete_savings_account(
    p_id uuid, p_expected_version bigint, p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_row public.savings_accounts;
    v_hash text;
    v_result jsonb;
    v_today date;
    v_balance numeric;
    v_has_history boolean;
    v_touches_closed boolean;
BEGIN
    v_hash := private.financial_request_hash('delete_savings_account',
        pg_catalog.jsonb_build_object('id',p_id,'expected_version',p_expected_version));
    v_result := private.movement_retry(p_request_id,'delete_savings_account',v_hash);
    IF v_result IS NOT NULL THEN RETURN v_result; END IF;
    IF p_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'id y expected_version son obligatorios' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_row FROM public.savings_accounts
        WHERE id = p_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cuenta no encontrada' USING ERRCODE = 'P0002';
    END IF;
    IF v_row.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    -- Todo lo dependiente del estado se vuelve a comprobar bajo el lock.
    v_today := private.read_today();
    v_has_history := EXISTS (SELECT 1 FROM public.incomes
            WHERE user_id = v_user_id AND savings_account_id = v_row.id)
        OR EXISTS (SELECT 1 FROM public.transfers
            WHERE user_id = v_user_id
              AND (from_savings_account_id = v_row.id OR to_savings_account_id = v_row.id));
    v_touches_closed := EXISTS (SELECT 1 FROM public.budget_periods
        WHERE user_id = v_user_id AND status = 'closed' AND end_date >= v_row.start_date);
    SELECT current_balance INTO v_balance
        FROM private.savings_account_balances_at(v_today) WHERE account_id=v_row.id;

    IF NOT v_has_history AND NOT v_touches_closed THEN
        DELETE FROM public.savings_accounts WHERE id = v_row.id AND user_id = v_user_id;
        v_result := pg_catalog.jsonb_build_object('mode','hard_deleted',
            'account',pg_catalog.to_jsonb(v_row));
    ELSIF v_balance <> 0 THEN
        -- Resultado tipado para que el cliente no interprete texto SQL. No se
        -- registra: al mover el saldo se puede reintentar con una petición nueva.
        RETURN pg_catalog.jsonb_build_object('mode','blocked','code','ACCOUNT_HAS_BALANCE',
            'balance',v_balance);
    ELSE
        IF v_row.is_active THEN
            UPDATE public.savings_accounts SET is_active = false, version = version + 1,
                updated_at = pg_catalog.clock_timestamp()
                WHERE id = v_row.id AND user_id = v_user_id RETURNING * INTO v_row;
        END IF;
        v_result := pg_catalog.jsonb_build_object('mode','soft_deleted',
            'account',pg_catalog.to_jsonb(v_row));
    END IF;
    INSERT INTO public.financial_operations(user_id,idempotency_key,operation_type,request_hash,result)
        VALUES (v_user_id,p_request_id,'delete_savings_account',v_hash,v_result);
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.delete_savings_account(uuid, bigint, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_savings_account(uuid, bigint, uuid) TO authenticated;

-- Postcondiciones de estructura y referencias: cualquier incumplimiento aborta
-- toda la migración, incluidos los cambios de índices y permisos.
DO $postconditions$
BEGIN
    IF EXISTS (SELECT 1 FROM public.expenses e LEFT JOIN public.categories c
        ON c.user_id=e.user_id AND c.id=e.category_id WHERE c.id IS NULL)
      OR EXISTS (SELECT 1 FROM public.expenses e LEFT JOIN public.payment_methods m
        ON m.user_id=e.user_id AND m.id=e.payment_method_id
        WHERE e.payment_method_id IS NOT NULL AND m.id IS NULL)
      OR EXISTS (SELECT 1 FROM public.incomes i LEFT JOIN public.savings_accounts a
        ON a.user_id=i.user_id AND a.id=i.savings_account_id
        WHERE i.savings_account_id IS NOT NULL AND a.id IS NULL)
      OR EXISTS (SELECT 1 FROM public.transfers t LEFT JOIN public.savings_accounts a
        ON a.user_id=t.user_id AND a.id=t.from_savings_account_id
        WHERE t.from_savings_account_id IS NOT NULL AND a.id IS NULL)
      OR EXISTS (SELECT 1 FROM public.transfers t LEFT JOIN public.savings_accounts a
        ON a.user_id=t.user_id AND a.id=t.to_savings_account_id
        WHERE t.to_savings_account_id IS NOT NULL AND a.id IS NULL)
      OR EXISTS (SELECT 1 FROM public.period_category_budgets b LEFT JOIN public.categories c
        ON c.user_id=b.user_id AND c.id=b.category_id WHERE c.id IS NULL) THEN
        RAISE EXCEPTION 'Postcondición 008: referencias históricas rotas';
    END IF;
    IF (SELECT count(*) FROM pg_catalog.pg_indexes
        WHERE schemaname='public' AND indexname IN
          ('categories_owner_name_key','payment_methods_owner_name_key','savings_accounts_owner_name_key')
          AND indexdef ILIKE '%WHERE is_active%') <> 3 THEN
        RAISE EXCEPTION 'Postcondición 008: índices activos incorrectos';
    END IF;
    IF (SELECT count(*) FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='public' AND p.proname IN
          ('get_catalog_management','delete_category','delete_payment_method',
           'correct_savings_opening_balance','delete_savings_account')) <> 5
      OR EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='public' AND p.proname IN
          ('get_catalog_management','delete_category','delete_payment_method',
           'correct_savings_opening_balance','delete_savings_account')
          AND (NOT p.prosecdef OR ('search_path=""'=ANY(p.proconfig)) IS NOT TRUE
            OR pg_catalog.has_function_privilege('anon',p.oid,'EXECUTE')
            OR NOT pg_catalog.has_function_privilege('authenticated',p.oid,'EXECUTE')))
      OR EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='private' AND p.proname='savings_account_balances_at'
          AND pg_catalog.has_function_privilege('authenticated',p.oid,'EXECUTE')) THEN
        RAISE EXCEPTION 'Postcondición 008: contrato de seguridad/ACL incorrecto';
    END IF;
    IF (SELECT count(*) FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='public' AND c.relname IN
          ('categories','payment_methods','savings_accounts') AND c.relrowsecurity) <> 3 THEN
        RAISE EXCEPTION 'Postcondición 008: RLS no preservada';
    END IF;
END;
$postconditions$;

COMMIT;
