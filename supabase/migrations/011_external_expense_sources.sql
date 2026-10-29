-- MisGastos 011: gastos externos. Requiere 001–010. NO aplicar automáticamente.
-- API antigua intacta: crear sin origen usa available; editar conserva el origen.
-- Aplicar migración antes de desplegar frontend. No se crean fuentes del usuario.
BEGIN;
CREATE TABLE public.external_expense_sources (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 name text NOT NULL CHECK (btrim(name) <> ''),
 is_active boolean NOT NULL DEFAULT true,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
 UNIQUE (user_id,id)
);
CREATE UNIQUE INDEX external_expense_sources_owner_name_key
 ON public.external_expense_sources(user_id,lower(btrim(name))) WHERE is_active;
ALTER TABLE public.external_expense_sources ENABLE ROW LEVEL SECURITY;
CREATE POLICY external_expense_sources_select_own ON public.external_expense_sources
 FOR SELECT TO authenticated USING (user_id = auth.uid());
REVOKE ALL ON TABLE public.external_expense_sources FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.external_expense_sources TO authenticated;
ALTER TABLE public.expenses
 ADD COLUMN funding_type text NOT NULL DEFAULT 'available',
 ADD COLUMN external_source_id uuid,
 ADD CONSTRAINT expenses_funding_check CHECK (
   (funding_type = 'available' AND external_source_id IS NULL)
   OR (funding_type = 'external' AND external_source_id IS NOT NULL)),
 ADD CONSTRAINT expenses_external_source_fk FOREIGN KEY (user_id,external_source_id)
 REFERENCES public.external_expense_sources(user_id,id) ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED;
CREATE INDEX expenses_external_source_idx ON public.expenses(user_id,external_source_id)
 WHERE external_source_id IS NOT NULL;


CREATE OR REPLACE FUNCTION public.create_external_expense_source(p_name text)
RETURNS public.external_expense_sources
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_row public.external_expense_sources;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Se requiere sesión autenticada' USING ERRCODE = '28000';
    END IF;
    IF p_name IS NULL OR pg_catalog.btrim(p_name) = '' THEN
        RAISE EXCEPTION 'Nombre vacío' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.external_expense_sources (user_id, name)
        VALUES (v_user_id, pg_catalog.btrim(p_name)) RETURNING * INTO v_row;
    RETURN v_row;
END;
$$;
REVOKE ALL ON FUNCTION public.create_external_expense_source(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_external_expense_source(text) TO authenticated;


CREATE OR REPLACE FUNCTION public.rename_external_expense_source(p_id uuid, p_name text, p_expected_version bigint)
RETURNS public.external_expense_sources
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_row public.external_expense_sources;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Se requiere sesión autenticada' USING ERRCODE = '28000';
    END IF;
    IF p_name IS NULL OR pg_catalog.btrim(p_name) = '' OR p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'Parámetros inválidos' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_row FROM public.external_expense_sources
        WHERE id = p_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Objeto no encontrado' USING ERRCODE = 'P0002';
    END IF;
    IF v_row.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    UPDATE public.external_expense_sources SET name = pg_catalog.btrim(p_name),
        version = version + 1, updated_at = pg_catalog.clock_timestamp()
        WHERE id = p_id AND user_id = v_user_id RETURNING * INTO v_row;
    RETURN v_row;
END;
$$;
REVOKE ALL ON FUNCTION public.rename_external_expense_source(uuid, text, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rename_external_expense_source(uuid, text, bigint) TO authenticated;


CREATE FUNCTION public.delete_external_expense_source(p_id uuid, p_expected_version bigint)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_row public.external_expense_sources;
    v_used boolean;
BEGIN
    IF p_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'id y expected_version son obligatorios' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_row FROM public.external_expense_sources
        WHERE id = p_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Origen externo no encontrado' USING ERRCODE = 'P0002';
    END IF;
    IF v_row.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    v_used := EXISTS (SELECT 1 FROM public.expenses
        WHERE user_id = v_user_id AND external_source_id = v_row.id);
    IF NOT v_used THEN
        DELETE FROM public.external_expense_sources WHERE id = v_row.id AND user_id = v_user_id;
        RETURN pg_catalog.jsonb_build_object('mode','hard_deleted','item',pg_catalog.to_jsonb(v_row));
    END IF;
    IF v_row.is_active THEN
        UPDATE public.external_expense_sources SET is_active = false, version = version + 1,
            updated_at = pg_catalog.clock_timestamp()
            WHERE id = v_row.id AND user_id = v_user_id RETURNING * INTO v_row;
    END IF;
    RETURN pg_catalog.jsonb_build_object('mode','soft_deleted','item',pg_catalog.to_jsonb(v_row));
END;
$$;
REVOKE ALL ON FUNCTION public.delete_external_expense_source(uuid, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_external_expense_source(uuid, bigint) TO authenticated;


CREATE OR REPLACE FUNCTION public.get_catalog_management() RETURNS jsonb
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
        FROM public.payment_methods m WHERE m.user_id = v_user_id AND m.is_active),'[]'::jsonb),
        'external_sources', coalesce((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'id',m.id,'name',m.name,'is_active',m.is_active,'version',m.version,
            'has_history',EXISTS (SELECT 1 FROM public.expenses e
                WHERE e.user_id = m.user_id AND e.external_source_id = m.id)
        ) ORDER BY pg_catalog.lower(pg_catalog.btrim(m.name)),m.id)
        FROM public.external_expense_sources m WHERE m.user_id = v_user_id AND m.is_active),'[]'::jsonb)
    ) INTO v_result;
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.get_catalog_management() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_catalog_management() TO authenticated;


CREATE OR REPLACE FUNCTION private.available_daily(p_period uuid)
RETURNS TABLE(date date, balance numeric, withdrawal boolean)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = ''
AS $$
    WITH movements AS (
        SELECT start_date AS date, 0::numeric AS delta, false AS withdrawal
            FROM public.budget_periods WHERE user_id = auth.uid() AND id = p_period
        UNION ALL
        SELECT date, amount, false FROM public.incomes
            WHERE user_id = auth.uid() AND period_id = p_period AND savings_account_id IS NULL
        UNION ALL
        SELECT date, -amount, false FROM public.expenses
            WHERE user_id = auth.uid() AND period_id = p_period AND funding_type = 'available'
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


CREATE FUNCTION private.expense_funding_reference(p_type text,p_source uuid,p_old_source uuid)
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
 IF p_type IS NULL OR p_type NOT IN ('available','external')
 OR (p_type = 'available' AND p_source IS NOT NULL)
 OR (p_type = 'external' AND p_source IS NULL) THEN
   RAISE EXCEPTION 'Origen del gasto inválido' USING ERRCODE = '22023';
 END IF;
 IF p_source IS NOT NULL AND NOT EXISTS (
   SELECT 1 FROM public.external_expense_sources WHERE user_id=auth.uid() AND id=p_source
     AND (is_active OR id=p_old_source)) THEN
   RAISE EXCEPTION 'Origen externo inexistente, ajeno o inactivo' USING ERRCODE = '22023';
 END IF;
END;
$$;
REVOKE ALL ON FUNCTION private.expense_funding_reference(text,uuid,uuid) FROM PUBLIC,anon,authenticated;


CREATE FUNCTION private.create_expense_core(
    p_date date,
    p_amount numeric,
    p_category_id uuid,
    p_description text,
    p_payment_method_id uuid,
    p_merchant text,
    p_note text,
    p_is_recurring boolean,
    p_request_id uuid,
    p_funding_type text,
    p_external_source_id uuid,
    p_legacy boolean
) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := auth.uid(); -- El wrapper ya adquirió el lock común.
    v_old public.expenses;
    v_row public.expenses;
    v_period public.budget_periods;
    v_amount numeric(20,2);
    v_hash text;
    v_result jsonb;
    v_since date;
    v_funding text;
    v_source uuid;
    v_params jsonb;
BEGIN
    v_amount := private.movement_amount(p_amount);
    v_params := pg_catalog.jsonb_build_object(
        'date', p_date,
        'amount', v_amount,
        'category_id', p_category_id,
        'description', p_description,
        'payment_method_id', p_payment_method_id,
        'merchant', p_merchant,
        'note', p_note,
        'is_recurring', p_is_recurring,
        'funding_type', p_funding_type, 'external_source_id', p_external_source_id
    );
    IF p_legacy THEN v_params := v_params - 'funding_type' - 'external_source_id'; END IF;
    v_hash := private.financial_request_hash('create_expense',v_params);
    v_result := private.movement_retry(p_request_id, 'create_expense', v_hash);
    IF v_result IS NOT NULL THEN RETURN v_result; END IF;
    v_period := private.movement_period(p_date);
    IF p_is_recurring IS NULL THEN
        RAISE EXCEPTION 'is_recurring no puede ser NULL' USING ERRCODE = '22023';
    END IF;
    v_funding := CASE WHEN p_legacy THEN coalesce(v_old.funding_type,'available') ELSE p_funding_type END;
    v_source := CASE WHEN p_legacy THEN v_old.external_source_id ELSE p_external_source_id END;
    PERFORM private.expense_funding_reference(v_funding,v_source,v_old.external_source_id);
    PERFORM private.expense_references(p_category_id, p_payment_method_id,
        v_old.category_id, v_old.payment_method_id);
    INSERT INTO public.expenses(user_id, period_id, date, amount, category_id, description, payment_method_id, merchant, note, is_recurring, funding_type, external_source_id)
        VALUES (v_user_id, v_period.id, p_date, v_amount, p_category_id, p_description, p_payment_method_id, p_merchant, p_note, p_is_recurring, v_funding, v_source)
        RETURNING * INTO v_row;
    v_since := LEAST(v_old.date, v_row.date);
    PERFORM private.check_available(v_period.id, v_since);
    v_result := pg_catalog.to_jsonb(v_row);
    INSERT INTO public.financial_operations(user_id, idempotency_key, operation_type, request_hash, result)
        VALUES (v_user_id, p_request_id, 'create_expense', v_hash, v_result);
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION private.create_expense_core(date, numeric, uuid, text, uuid, text, text, boolean, uuid, text, uuid, boolean) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.create_expense_with_funding(
    p_date date,
    p_amount numeric,
    p_category_id uuid,
    p_description text,
    p_payment_method_id uuid,
    p_merchant text,
    p_note text,
    p_is_recurring boolean,
    p_request_id uuid,
    p_funding_type text,
    p_external_source_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 PERFORM private.lock_current_user();
 RETURN private.create_expense_core(p_date, p_amount, p_category_id, p_description, p_payment_method_id, p_merchant, p_note, p_is_recurring, p_request_id, p_funding_type, p_external_source_id, false);
END;
$$;
REVOKE ALL ON FUNCTION public.create_expense_with_funding(date, numeric, uuid, text, uuid, text, text, boolean, uuid, text, uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.create_expense_with_funding(date, numeric, uuid, text, uuid, text, text, boolean, uuid, text, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.create_expense(
    p_date date,
    p_amount numeric,
    p_category_id uuid,
    p_description text,
    p_payment_method_id uuid,
    p_merchant text,
    p_note text,
    p_is_recurring boolean,
    p_request_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 PERFORM private.lock_current_user();
 RETURN private.create_expense_core(p_date, p_amount, p_category_id, p_description, p_payment_method_id, p_merchant, p_note, p_is_recurring, p_request_id, NULL::text, NULL::uuid, true);
END;
$$;
REVOKE ALL ON FUNCTION public.create_expense(date, numeric, uuid, text, uuid, text, text, boolean, uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.create_expense(date, numeric, uuid, text, uuid, text, text, boolean, uuid) TO authenticated;


CREATE FUNCTION private.update_expense_core(
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
    p_request_id uuid,
    p_funding_type text,
    p_external_source_id uuid,
    p_legacy boolean
) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := auth.uid(); -- El wrapper ya adquirió el lock común.
    v_old public.expenses;
    v_row public.expenses;
    v_period public.budget_periods;
    v_amount numeric(20,2);
    v_hash text;
    v_result jsonb;
    v_since date;
    v_funding text;
    v_source uuid;
    v_params jsonb;
BEGIN
    v_amount := private.movement_amount(p_amount);
    v_params := pg_catalog.jsonb_build_object(
        'id', p_id,
        'expected_version', p_expected_version,
        'date', p_date,
        'amount', v_amount,
        'category_id', p_category_id,
        'description', p_description,
        'payment_method_id', p_payment_method_id,
        'merchant', p_merchant,
        'note', p_note,
        'is_recurring', p_is_recurring,
        'funding_type', p_funding_type, 'external_source_id', p_external_source_id
    );
    IF p_legacy THEN v_params := v_params - 'funding_type' - 'external_source_id'; END IF;
    v_hash := private.financial_request_hash('update_expense',v_params);
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
    v_funding := CASE WHEN p_legacy THEN coalesce(v_old.funding_type,'available') ELSE p_funding_type END;
    v_source := CASE WHEN p_legacy THEN v_old.external_source_id ELSE p_external_source_id END;
    PERFORM private.expense_funding_reference(v_funding,v_source,v_old.external_source_id);
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
        funding_type = v_funding, external_source_id = v_source,
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
REVOKE ALL ON FUNCTION private.update_expense_core(uuid, bigint, date, numeric, uuid, text, uuid, text, text, boolean, uuid, text, uuid, boolean) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.update_expense_with_funding(
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
    p_request_id uuid,
    p_funding_type text,
    p_external_source_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 PERFORM private.lock_current_user();
 RETURN private.update_expense_core(p_id, p_expected_version, p_date, p_amount, p_category_id, p_description, p_payment_method_id, p_merchant, p_note, p_is_recurring, p_request_id, p_funding_type, p_external_source_id, false);
END;
$$;
REVOKE ALL ON FUNCTION public.update_expense_with_funding(uuid, bigint, date, numeric, uuid, text, uuid, text, text, boolean, uuid, text, uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.update_expense_with_funding(uuid, bigint, date, numeric, uuid, text, uuid, text, text, boolean, uuid, text, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.update_expense(
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
    p_request_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 PERFORM private.lock_current_user();
 RETURN private.update_expense_core(p_id, p_expected_version, p_date, p_amount, p_category_id, p_description, p_payment_method_id, p_merchant, p_note, p_is_recurring, p_request_id, NULL::text, NULL::uuid, true);
END;
$$;
REVOKE ALL ON FUNCTION public.update_expense(uuid, bigint, date, numeric, uuid, text, uuid, text, text, boolean, uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.update_expense(uuid, bigint, date, numeric, uuid, text, uuid, text, text, boolean, uuid) TO authenticated;


CREATE FUNCTION private.expense_funding_breakdown(p_period uuid,p_date date,p_category uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path = '' AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object('funding_type',funding_type,
 'external_source_id',external_source_id,'name',name,'amount',amount::text)
 ORDER BY funding_type,name,external_source_id),'[]'::jsonb)
 FROM (
 SELECT e.funding_type,e.external_source_id,
 CASE WHEN e.funding_type='available' THEN 'Disponible' ELSE s.name END AS name,sum(e.amount) AS amount
 FROM public.expenses e LEFT JOIN public.external_expense_sources s
 ON s.user_id=e.user_id AND s.id=e.external_source_id
 WHERE e.user_id=auth.uid() AND e.period_id=p_period AND e.date<=p_date
 AND (p_category IS NULL OR e.category_id=p_category)
 GROUP BY e.funding_type,e.external_source_id,s.name
 ) totals;
$$;
REVOKE ALL ON FUNCTION private.expense_funding_breakdown(uuid,date,uuid) FROM PUBLIC,anon,authenticated;


CREATE OR REPLACE FUNCTION private.period_summary_at(p_period_id uuid, p_today date) RETURNS jsonb
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
        'expenses_funding_breakdown',private.expense_funding_breakdown(v_period.id,v_date),
        'expenses_total',v_expenses,'income_total',v_income_available + v_income_savings,
        'income_to_available',v_income_available,'income_to_savings',v_income_savings,
        'transfer_to_savings_total',v_to_savings,'transfer_from_savings_total',v_from_savings,
        'general_budget',v_period.general_budget,'general_budget_spent',v_expenses,
        'general_budget_remaining',v_period.general_budget - v_expenses);
END;
$$;
REVOKE ALL ON FUNCTION private.period_summary_at(uuid, date) FROM PUBLIC, anon, authenticated;


CREATE OR REPLACE FUNCTION public.get_category_budget_usage(p_period_id uuid) RETURNS jsonb
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
        'funding_breakdown',private.expense_funding_breakdown(p_period_id,private.read_today(),c.id),
        'spent',u.spent,'remaining',u.budget_amount - u.spent
    ) ORDER BY u.spent DESC,pg_catalog.lower(pg_catalog.btrim(c.name)),c.id),'[]'::jsonb)
    INTO v_result FROM usage u JOIN public.categories c ON c.id = u.category_id AND c.user_id = v_user_id;
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.get_category_budget_usage(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_category_budget_usage(uuid) TO authenticated;


CREATE OR REPLACE FUNCTION public.reset_financial_data(p_confirmation text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    -- Obtiene exclusivamente auth.uid() y serializa las mutaciones del usuario,
    -- incluso si ya no existe user_settings.
    v_user_id uuid := private.lock_current_user();
BEGIN
    IF p_confirmation IS DISTINCT FROM 'BORRAR' THEN
        RAISE EXCEPTION 'Confirmación inválida: se requiere BORRAR' USING ERRCODE = '22023';
    END IF;

    -- Hijos antes que padres: no depende de diferir las FK ni de cascadas.
    -- Sin capturar errores: cualquier fallo revierte la llamada completa.
    DELETE FROM public.expenses WHERE user_id = v_user_id;
    DELETE FROM public.external_expense_sources WHERE user_id = v_user_id;
    DELETE FROM public.incomes WHERE user_id = v_user_id;
    DELETE FROM public.transfers WHERE user_id = v_user_id;
    DELETE FROM public.period_category_budgets WHERE user_id = v_user_id;
    DELETE FROM public.budget_periods WHERE user_id = v_user_id;
    DELETE FROM public.savings_accounts WHERE user_id = v_user_id;
    DELETE FROM public.categories WHERE user_id = v_user_id;
    DELETE FROM public.payment_methods WHERE user_id = v_user_id;
    DELETE FROM public.financial_operations WHERE user_id = v_user_id;
    DELETE FROM public.user_settings WHERE user_id = v_user_id;

    RETURN '{"reset": true}'::jsonb;
END;
$$;
REVOKE ALL ON FUNCTION public.reset_financial_data(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reset_financial_data(text) TO authenticated;


CREATE OR REPLACE FUNCTION public.get_data_export(
    p_start_date date DEFAULT NULL,
    p_end_date date DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_today date;
    v_start date;
    v_end date;
    v_currency text;
    v_timezone text;
    v_movements jsonb;
    v_balances jsonb;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Se requiere sesión autenticada' USING ERRCODE = '28000';
    END IF;
    SELECT currency, timezone INTO v_currency, v_timezone
    FROM public.user_settings WHERE user_id = v_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Configura primero moneda y zona horaria' USING ERRCODE = 'P0002';
    END IF;
    v_today := private.read_today();
    IF (p_start_date IS NULL) <> (p_end_date IS NULL)
      OR (p_start_date IS NOT NULL AND (NOT pg_catalog.isfinite(p_start_date)
        OR NOT pg_catalog.isfinite(p_end_date) OR p_start_date > p_end_date
        OR p_end_date > v_today)) THEN
        RAISE EXCEPTION 'Rango de exportación inválido' USING ERRCODE = '22023';
    END IF;

    IF p_start_date IS NULL THEN
        SELECT coalesce(pg_catalog.min(point), v_today) INTO v_start
        FROM (
            SELECT start_date AS point FROM public.budget_periods WHERE user_id = v_user_id
            UNION ALL SELECT start_date FROM public.savings_accounts WHERE user_id = v_user_id
            UNION ALL SELECT date FROM public.expenses WHERE user_id = v_user_id
            UNION ALL SELECT date FROM public.incomes WHERE user_id = v_user_id
            UNION ALL SELECT date FROM public.transfers WHERE user_id = v_user_id
        ) points;
        v_end := v_today;
    ELSE
        v_start := p_start_date;
        v_end := p_end_date;
    END IF;

    WITH movement_rows AS (
        SELECT e.date, 'expense'::text AS kind, e.id, e.created_at,
            e.amount::text AS amount, CASE WHEN e.funding_type='available' THEN 'Disponible' ELSE es.name END AS origin, 'Exterior'::text AS destination,
            c.name AS category, pm.name AS payment_method, e.merchant,
            e.description, e.note, e.is_recurring, p.id AS period_id, p.start_date AS period_start,
            p.end_date AS period_end, p.status AS period_status,
            e.funding_type, es.name AS external_source
        FROM public.expenses e
        JOIN public.budget_periods p ON p.id = e.period_id AND p.user_id = e.user_id
        JOIN public.categories c ON c.id = e.category_id AND c.user_id = e.user_id
        LEFT JOIN public.payment_methods pm ON pm.id = e.payment_method_id AND pm.user_id = e.user_id
        LEFT JOIN public.external_expense_sources es ON es.user_id=e.user_id AND es.id=e.external_source_id
        WHERE e.user_id = v_user_id AND e.date BETWEEN v_start AND v_end
        UNION ALL
        SELECT i.date, 'income', i.id, i.created_at, i.amount::text, 'Exterior',
            coalesce(sa.name, 'Disponible'), NULL, NULL, NULL, i.description, NULL, NULL::boolean,
            p.id, p.start_date, p.end_date, p.status, NULL::text, NULL::text
        FROM public.incomes i
        JOIN public.budget_periods p ON p.id = i.period_id AND p.user_id = i.user_id
        LEFT JOIN public.savings_accounts sa ON sa.id = i.savings_account_id AND sa.user_id = i.user_id
        WHERE i.user_id = v_user_id AND i.date BETWEEN v_start AND v_end
        UNION ALL
        SELECT t.date, 'transfer', t.id, t.created_at, t.amount::text,
            coalesce(source.name, 'Disponible'), coalesce(target.name, 'Disponible'),
            NULL, NULL, NULL, t.description, NULL, NULL::boolean, p.id, p.start_date, p.end_date, p.status, NULL::text, NULL::text
        FROM public.transfers t
        JOIN public.budget_periods p ON p.id = t.period_id AND p.user_id = t.user_id
        LEFT JOIN public.savings_accounts source
            ON source.id = t.from_savings_account_id AND source.user_id = t.user_id
        LEFT JOIN public.savings_accounts target
            ON target.id = t.to_savings_account_id AND target.user_id = t.user_id
        WHERE t.user_id = v_user_id AND t.date BETWEEN v_start AND v_end
    )
    SELECT coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'funding_type',m.funding_type,'external_source',m.external_source,
        'date',m.date,'kind',m.kind,'id',m.id,'amount',m.amount,
        'origin',m.origin,'destination',m.destination,'category',m.category,
        'payment_method',m.payment_method,'merchant',m.merchant,
        'description',m.description,'note',m.note,'is_recurring',m.is_recurring,'period_id',m.period_id,
        'period_start',m.period_start,'period_end',m.period_end,'period_status',m.period_status
    ) ORDER BY m.date,m.created_at,m.id),'[]'::jsonb) INTO v_movements
    FROM movement_rows m;

    WITH overlapping_periods AS (
        SELECT p.*,
            greatest(p.start_date,v_start) AS snapshot_start,
            least(coalesce(p.end_date,v_end),v_end) AS snapshot_end
        FROM public.budget_periods p
        WHERE p.user_id = v_user_id AND p.start_date <= v_end
          AND coalesce(p.end_date,v_end) >= v_start
    ), available_snapshots AS (
        SELECT p.snapshot_start AS date, 'opening'::text AS snapshot_kind,
            'available'::text AS balance_kind, NULL::uuid AS account_id,
            'Disponible'::text AS account_name,
            (CASE WHEN p.snapshot_start = p.start_date THEN p.opening_balance
                ELSE private.available_at(p.id,p.snapshot_start - 1) END)::text AS amount,
            p.id AS period_id,p.start_date AS period_start,p.end_date AS period_end,
            p.status AS period_status
        FROM overlapping_periods p
        UNION ALL
        SELECT p.snapshot_end, 'closing', 'available', NULL, 'Disponible',
            (CASE WHEN p.status = 'closed' AND p.snapshot_end = p.end_date
                THEN p.closing_balance ELSE private.available_at(p.id,p.snapshot_end) END)::text,
            p.id,p.start_date,p.end_date,p.status
        FROM overlapping_periods p
    ), eligible_accounts AS (
        SELECT a.* FROM public.savings_accounts a
        WHERE a.user_id = v_user_id AND a.start_date <= v_end
    ), savings_snapshots AS (
        SELECT greatest(a.start_date,v_start) AS date,
            'opening'::text AS snapshot_kind, 'savings'::text AS balance_kind,
            a.id AS account_id,a.name AS account_name,
            (CASE WHEN a.start_date >= v_start THEN a.opening_balance ELSE
                (SELECT b.current_balance FROM private.savings_account_balances_at(v_start - 1) b
                    WHERE b.account_id = a.id) END)::text AS amount,
            NULL::uuid AS period_id,NULL::date AS period_start,NULL::date AS period_end,
            NULL::text AS period_status
        FROM eligible_accounts a
        UNION ALL
        SELECT v_end,'closing','savings',a.id,a.name,b.current_balance::text,
            NULL,NULL,NULL,NULL
        FROM eligible_accounts a
        JOIN private.savings_account_balances_at(v_end) b ON b.account_id = a.id
    ), snapshots AS (
        SELECT * FROM available_snapshots
        UNION ALL SELECT * FROM savings_snapshots
    )
    SELECT coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'date',s.date,'snapshot_kind',s.snapshot_kind,'balance_kind',s.balance_kind,
        'account_id',s.account_id,'account_name',s.account_name,'amount',s.amount,
        'period_id',s.period_id,'period_start',s.period_start,'period_end',s.period_end,
        'period_status',s.period_status
    ) ORDER BY s.date,CASE s.snapshot_kind WHEN 'opening' THEN 0 ELSE 2 END,
        s.balance_kind,s.account_name,s.account_id),'[]'::jsonb) INTO v_balances
    FROM snapshots s;

    RETURN pg_catalog.jsonb_build_object(
        'range',pg_catalog.jsonb_build_object('start_date',v_start,'end_date',v_end,'as_of_date',v_today),
        'settings',pg_catalog.jsonb_build_object('currency',v_currency,'timezone',v_timezone),
        'movements',v_movements,
        'balances',v_balances,
        'savings_accounts',coalesce((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'id',a.id,'name',a.name,'start_date',a.start_date,
            'opening_balance',a.opening_balance::text,'is_active',a.is_active,
            'current_balance',b.current_balance::text,'version',a.version
        ) ORDER BY pg_catalog.lower(pg_catalog.btrim(a.name)),a.id)
        FROM public.savings_accounts a
        JOIN private.savings_account_balances_at(v_today) b ON b.account_id=a.id
        WHERE a.user_id=v_user_id),'[]'::jsonb),
        'periods',coalesce((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'id',p.id,'mode',p.mode,'start_date',p.start_date,'end_date',p.end_date,
            'status',p.status,'opening_balance',p.opening_balance::text,
            'closing_balance',p.closing_balance::text,'general_budget',p.general_budget::text,
            'closed_at',p.closed_at,'version',p.version
        ) ORDER BY p.start_date,p.id) FROM public.budget_periods p
        WHERE p.user_id=v_user_id),'[]'::jsonb),
        'budgets',coalesce((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'id',b.id,'period_id',b.period_id,'period_start',p.start_date,
            'period_end',p.end_date,'category',c.name,'amount',b.amount::text
        ) ORDER BY p.start_date,pg_catalog.lower(pg_catalog.btrim(c.name)),b.id)
        FROM public.period_category_budgets b
        JOIN public.budget_periods p ON p.id=b.period_id AND p.user_id=b.user_id
        JOIN public.categories c ON c.id=b.category_id AND c.user_id=b.user_id
        WHERE b.user_id=v_user_id),'[]'::jsonb),
        'categories',coalesce((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'id',c.id,'name',c.name,'is_active',c.is_active,'version',c.version
        ) ORDER BY pg_catalog.lower(pg_catalog.btrim(c.name)),c.id)
        FROM public.categories c WHERE c.user_id=v_user_id),'[]'::jsonb),
        'external_sources',coalesce((SELECT jsonb_agg(jsonb_build_object(
            'id',s.id,'name',s.name,'is_active',s.is_active,'version',s.version) ORDER BY s.name,s.id)
            FROM public.external_expense_sources s WHERE s.user_id=v_user_id),'[]'::jsonb),
        'payment_methods',coalesce((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'id',pm.id,'name',pm.name,'is_active',pm.is_active,'version',pm.version
        ) ORDER BY pg_catalog.lower(pg_catalog.btrim(pm.name)),pm.id)
        FROM public.payment_methods pm WHERE pm.user_id=v_user_id),'[]'::jsonb)
    );
END;
$$;


NOTIFY pgrst, 'reload schema';
COMMIT;
