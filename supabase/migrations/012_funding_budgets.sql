-- MisGastos 012: presupuestos distribuidos por origen. Requiere 001–011.
-- Aplicar antes del nuevo frontend; no ejecutar automáticamente en producción.
-- Los períodos existentes conservan su presupuesto general (legacy_total).
-- Los nuevos o convertidos explícitamente usan by_origin y un total derivado.
-- No se modifican importes, movimientos, versiones ni timestamps históricos.
BEGIN;

-- DEFAULT de incorporación: todos los períodos anteriores, abiertos y cerrados,
-- conservan el significado original. El default posterior solo afecta a INSERT.
ALTER TABLE public.budget_periods
 ADD COLUMN budget_model text NOT NULL DEFAULT 'legacy_total'
 CONSTRAINT budget_periods_budget_model_check CHECK (budget_model IN ('legacy_total','by_origin'));
ALTER TABLE public.budget_periods ALTER COLUMN budget_model SET DEFAULT 'by_origin';
COMMENT ON COLUMN public.budget_periods.general_budget IS
 'legacy_total: límite general de todos los gastos; by_origin: componente Disponible. Usar private.period_budget_total para el total.';
COMMENT ON COLUMN public.budget_periods.budget_model IS
 'legacy_total preserva el significado previo a 012; solo set_funding_budgets convierte un período abierto a by_origin.';

CREATE TABLE public.period_external_source_budgets (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 period_id uuid NOT NULL,
 external_source_id uuid NOT NULL,
 amount numeric(20,2) NOT NULL CHECK (amount >= 0),
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE (user_id,period_id,external_source_id),
 FOREIGN KEY (user_id,period_id) REFERENCES public.budget_periods(user_id,id)
   ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY (user_id,external_source_id) REFERENCES public.external_expense_sources(user_id,id)
   ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED
);
-- La versión del conjunto (Disponible + fuentes externas) es budget_periods.version.
-- No se editan filas individualmente ni se mantiene un segundo contador de versión.
CREATE INDEX period_external_source_budgets_source_idx
 ON public.period_external_source_budgets(user_id,external_source_id);
ALTER TABLE public.period_external_source_budgets ENABLE ROW LEVEL SECURITY;
CREATE POLICY period_external_source_budgets_select_own ON public.period_external_source_budgets
 FOR SELECT TO authenticated USING (user_id = auth.uid());
REVOKE ALL ON TABLE public.period_external_source_budgets FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.period_external_source_budgets TO authenticated;

-- Fuente única de las asignaciones, incluidas las de períodos cerrados.
CREATE FUNCTION private.period_funding_allocations(p_period uuid)
RETURNS TABLE(funding_type text,external_source_id uuid,amount numeric)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = '' AS $$
 SELECT 'available'::text,NULL::uuid,p.general_budget
 FROM public.budget_periods p WHERE p.user_id=auth.uid() AND p.id=p_period AND p.budget_model='by_origin'
 UNION ALL
 SELECT 'external',b.external_source_id,b.amount
 FROM public.period_external_source_budgets b
 JOIN public.budget_periods p ON p.user_id=b.user_id AND p.id=b.period_id
 WHERE b.user_id=auth.uid() AND b.period_id=p_period AND p.budget_model='by_origin';
$$;
REVOKE ALL ON FUNCTION private.period_funding_allocations(uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.period_budget_total(p_period uuid) RETURNS numeric
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = '' AS $$
 -- El límite histórico cubre TODO el consumo; nunca se reparte retrospectivamente.
 SELECT CASE WHEN p.budget_model='legacy_total' THEN p.general_budget
   ELSE (SELECT sum(amount) FROM private.period_funding_allocations(p.id)) END
 FROM public.budget_periods p WHERE p.user_id=auth.uid() AND p.id=p_period;
$$;
REVOKE ALL ON FUNCTION private.period_budget_total(uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.has_external_expense_sources() RETURNS boolean
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = '' AS $$
 SELECT EXISTS (SELECT 1 FROM public.external_expense_sources WHERE user_id=auth.uid())
 OR EXISTS (SELECT 1 FROM public.expenses WHERE user_id=auth.uid() AND funding_type='external');
$$;
REVOKE ALL ON FUNCTION private.has_external_expense_sources() FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.period_funding_usage_at(p_period uuid,p_date date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = '' AS $$
 WITH allocations AS MATERIALIZED (
   SELECT * FROM private.period_funding_allocations(p_period)
 ), spending AS MATERIALIZED (
   SELECT x.funding_type,x.external_source_id,x.amount
   FROM jsonb_to_recordset(private.expense_funding_breakdown(p_period,p_date))
     AS x(funding_type text,external_source_id uuid,amount numeric)
 ), origins AS (
   SELECT 'available'::text AS funding_type,NULL::uuid AS external_source_id,
     'Disponible'::text AS name,true AS is_active
   UNION ALL
   SELECT 'external',s.id,s.name,s.is_active FROM public.external_expense_sources s
   WHERE s.user_id=auth.uid() AND ((s.is_active AND EXISTS (
     SELECT 1 FROM public.budget_periods p WHERE p.user_id=auth.uid() AND p.id=p_period AND p.status='open'))
     OR EXISTS (SELECT 1 FROM allocations a WHERE a.external_source_id=s.id)
     OR EXISTS (SELECT 1 FROM spending e WHERE e.external_source_id=s.id))
 )
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'funding_type',o.funding_type,'external_source_id',o.external_source_id,
   'name',o.name,'is_active',o.is_active,'budget_amount',a.amount::text,
   'spent',coalesce(e.amount,0::numeric)::text,
   'remaining',(a.amount-coalesce(e.amount,0::numeric))::text
 ) ORDER BY o.funding_type,lower(btrim(o.name)),o.external_source_id),'[]'::jsonb)
 FROM origins o
 LEFT JOIN allocations a ON a.funding_type=o.funding_type
   AND a.external_source_id IS NOT DISTINCT FROM o.external_source_id
 LEFT JOIN spending e ON e.funding_type=o.funding_type
   AND e.external_source_id IS NOT DISTINCT FROM o.external_source_id;
$$;
REVOKE ALL ON FUNCTION private.period_funding_usage_at(uuid,date) FROM PUBLIC,anon,authenticated;

-- Una sola llamada atómica. La lista es un patch: los orígenes omitidos se conservan.
-- amount=null quita una asignación; cero crea un límite explícito de cero.
CREATE FUNCTION public.set_funding_budgets(
 p_period_id uuid,p_available_budget numeric,p_external_budgets jsonb,
 p_expected_version bigint,p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
 v_user uuid := private.lock_current_user();
 v_period public.budget_periods;
 v_available numeric(20,2);
 v_amount numeric(20,2);
 v_source uuid;
 v_item jsonb;
 v_normalized jsonb := '[]'::jsonb;
 v_seen uuid[] := ARRAY[]::uuid[];
 v_hash text;
 v_result jsonb;
BEGIN
 v_available := private.budget_amount(p_available_budget);
 IF p_external_budgets IS NULL OR jsonb_typeof(p_external_budgets)<>'array' THEN
   RAISE EXCEPTION 'Lista de presupuestos por origen inválida' USING ERRCODE='22023';
 END IF;
 FOR v_item IN SELECT value FROM jsonb_array_elements(p_external_budgets) LOOP
   IF jsonb_typeof(v_item)<>'object' OR NOT (v_item ? 'external_source_id' AND v_item ? 'amount')
     OR v_item - 'external_source_id' - 'amount' <> '{}'::jsonb
     OR jsonb_typeof(v_item->'external_source_id')<>'string'
     OR jsonb_typeof(v_item->'amount') NOT IN ('number','string','null') THEN
     RAISE EXCEPTION 'Asignación de presupuesto inválida' USING ERRCODE='22023';
   END IF;
   BEGIN
     v_source := (v_item->>'external_source_id')::uuid;
     v_amount := private.budget_amount((v_item->>'amount')::numeric);
   EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
     RAISE EXCEPTION 'Origen o importe de presupuesto inválido' USING ERRCODE='22023';
   END;
   IF v_source=ANY(v_seen) THEN
     RAISE EXCEPTION 'Origen repetido en presupuestos' USING ERRCODE='22023';
   END IF;
   v_seen := array_append(v_seen,v_source);
   v_normalized := v_normalized || jsonb_build_array(jsonb_build_object(
     'external_source_id',v_source,'amount',v_amount));
 END LOOP;
 SELECT coalesce(jsonb_agg(x ORDER BY x->>'external_source_id'),'[]'::jsonb)
 INTO v_normalized FROM jsonb_array_elements(v_normalized) x;
 v_hash := private.financial_request_hash('set_funding_budgets',jsonb_build_object(
   'period_id',p_period_id,'available_budget',v_available,
   'external_budgets',v_normalized,'expected_version',p_expected_version));
 v_result := private.movement_retry(p_request_id,'set_funding_budgets',v_hash);
 IF v_result IS NOT NULL THEN RETURN v_result; END IF;
 IF p_expected_version IS NULL OR p_expected_version<1 THEN
   RAISE EXCEPTION 'expected_version obligatorio y positivo' USING ERRCODE='22023';
 END IF;
 v_period := private.open_budget_period(p_period_id);
 IF v_period.version<>p_expected_version THEN
   RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE='40001';
 END IF;
 FOR v_item IN SELECT value FROM jsonb_array_elements(v_normalized) LOOP
   v_source := (v_item->>'external_source_id')::uuid;
   v_amount := (v_item->>'amount')::numeric;
   -- Una fuente inactiva puede conservar/corregir/quitar su asignación existente.
   -- No se crean asignaciones nuevas a fuentes inactivas, aunque tengan gastos.
   IF NOT EXISTS (SELECT 1 FROM public.external_expense_sources s
     WHERE s.id=v_source AND s.user_id=v_user AND (s.is_active OR EXISTS (
       SELECT 1 FROM public.period_external_source_budgets b
       WHERE b.user_id=v_user AND b.period_id=p_period_id AND b.external_source_id=s.id))) THEN
     RAISE EXCEPTION 'Origen externo inexistente, ajeno o inactivo' USING ERRCODE='22023';
   END IF;
   IF v_amount IS NULL THEN
     DELETE FROM public.period_external_source_budgets
       WHERE user_id=v_user AND period_id=p_period_id AND external_source_id=v_source;
   ELSE
     INSERT INTO public.period_external_source_budgets(user_id,period_id,external_source_id,amount)
       VALUES(v_user,p_period_id,v_source,v_amount)
     ON CONFLICT(user_id,period_id,external_source_id) DO UPDATE
       SET amount=EXCLUDED.amount,updated_at=clock_timestamp();
   END IF;
 END LOOP;
 UPDATE public.budget_periods SET general_budget=v_available,budget_model='by_origin',version=version+1,
   updated_at=clock_timestamp() WHERE id=p_period_id AND user_id=v_user RETURNING * INTO v_period;
 v_result := jsonb_build_object('period_id',v_period.id,'version',v_period.version,
   'budget_model',v_period.budget_model,'available_budget',v_period.general_budget::text,'general_budget',private.period_budget_total(v_period.id)::text);
 INSERT INTO public.financial_operations(user_id,idempotency_key,operation_type,request_hash,result)
 VALUES(v_user,p_request_id,'set_funding_budgets',v_hash,v_result);
 RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.set_funding_budgets(uuid,numeric,jsonb,bigint,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.set_funding_budgets(uuid,numeric,jsonb,bigint,uuid) TO authenticated;


CREATE OR REPLACE FUNCTION public.set_general_budget(p_period_id uuid, p_general_budget numeric, p_expected_version bigint)
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
    -- Un cliente antiguo no puede expresar una distribución ni aclarar si leyó
    -- el componente almacenado o el total del resumen. Rechazar sin efectos,
    -- incluso para NULL y presupuestos externos de cero. No inferir diferencias.
    IF EXISTS (SELECT 1 FROM public.period_external_source_budgets
        WHERE user_id=v_user_id AND period_id=v_row.id) THEN
        RAISE EXCEPTION 'Presupuesto distribuido: actualiza la aplicación para editarlo'
            USING ERRCODE = '22023';
    END IF;
    UPDATE public.budget_periods SET general_budget = v_amount,
        version = version + 1, updated_at = pg_catalog.clock_timestamp()
        WHERE id = v_row.id AND user_id = v_user_id RETURNING * INTO v_row;
    RETURN v_row;
END;
$$;
REVOKE ALL ON FUNCTION public.set_general_budget(uuid,numeric,bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_general_budget(uuid,numeric,bigint) TO authenticated;


CREATE OR REPLACE FUNCTION private.period_summary_at(p_period_id uuid, p_today date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = ''
AS $$
DECLARE
    v_period public.budget_periods;
    v_date date;
    v_expenses numeric;
    v_available_expenses numeric;
    v_budget_total numeric;
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
    SELECT coalesce(pg_catalog.sum(amount),0::numeric),
        coalesce(pg_catalog.sum(amount) FILTER (WHERE funding_type='available'),0::numeric)
        INTO v_expenses,v_available_expenses
        FROM public.expenses WHERE user_id = auth.uid() AND period_id = v_period.id AND date <= v_date;
    SELECT coalesce(pg_catalog.sum(amount) FILTER (WHERE savings_account_id IS NULL),0::numeric),
        coalesce(pg_catalog.sum(amount) FILTER (WHERE savings_account_id IS NOT NULL),0::numeric)
        INTO v_income_available,v_income_savings
        FROM public.incomes WHERE user_id = auth.uid() AND period_id = v_period.id AND date <= v_date;
    SELECT coalesce(pg_catalog.sum(amount) FILTER (WHERE from_savings_account_id IS NULL),0::numeric),
        coalesce(pg_catalog.sum(amount) FILTER (WHERE to_savings_account_id IS NULL),0::numeric)
        INTO v_to_savings,v_from_savings
        FROM public.transfers WHERE user_id = auth.uid() AND period_id = v_period.id AND date <= v_date;
    v_budget_total := private.period_budget_total(v_period.id);
    RETURN pg_catalog.jsonb_build_object(
        'as_of_date',v_date,'period',pg_catalog.to_jsonb(v_period),
        'budget_model',v_period.budget_model,
        'legacy_general_budget',CASE WHEN v_period.budget_model='legacy_total' THEN v_period.general_budget::text ELSE NULL END,
        'opening_balance',v_period.opening_balance,'closing_balance',v_period.closing_balance,
        'available',private.available_at(v_period.id,v_date),
        'expenses_funding_breakdown',private.expense_funding_breakdown(v_period.id,v_date),
        'expenses_available_total',v_available_expenses::text,
        'has_external_sources',private.has_external_expense_sources(),
        'funding_budgets',private.period_funding_usage_at(v_period.id,v_date),
        'expenses_total',v_expenses,'income_total',v_income_available + v_income_savings,
        'income_to_available',v_income_available,'income_to_savings',v_income_savings,
        'transfer_to_savings_total',v_to_savings,'transfer_from_savings_total',v_from_savings,
        'general_budget',v_budget_total,'general_budget_spent',v_expenses,
        'general_budget_remaining',v_budget_total - v_expenses);
END;
$$;
REVOKE ALL ON FUNCTION private.period_summary_at(uuid, date) FROM PUBLIC, anon, authenticated;


CREATE OR REPLACE FUNCTION public.get_current_financial_state() RETURNS jsonb
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
            'has_external_sources',private.has_external_expense_sources(),
            'budget_model',NULL,'legacy_general_budget',NULL,
            'funding_budgets','[]'::jsonb,'expenses_available_total',NULL,
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


CREATE OR REPLACE FUNCTION public.delete_external_expense_source(p_id uuid, p_expected_version bigint)
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
        WHERE user_id = v_user_id AND external_source_id = v_row.id)
        OR EXISTS (SELECT 1 FROM public.period_external_source_budgets
          WHERE user_id=v_user_id AND external_source_id=v_row.id);
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
                OR EXISTS (SELECT 1 FROM public.period_external_source_budgets b
                  WHERE b.user_id=m.user_id AND b.external_source_id=m.id)
        ) ORDER BY pg_catalog.lower(pg_catalog.btrim(m.name)),m.id)
        FROM public.external_expense_sources m WHERE m.user_id = v_user_id AND m.is_active),'[]'::jsonb)
    ) INTO v_result;
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.get_catalog_management() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_catalog_management() TO authenticated;


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
    DELETE FROM public.period_external_source_budgets WHERE user_id = v_user_id;
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
            'closing_balance',p.closing_balance::text,'general_budget',private.period_budget_total(p.id)::text,
            'budget_model',p.budget_model,
            'available_budget',CASE WHEN p.budget_model='by_origin' THEN p.general_budget::text ELSE NULL END,
            'closed_at',p.closed_at,'version',p.version
        ) ORDER BY p.start_date,p.id) FROM public.budget_periods p
        WHERE p.user_id=v_user_id),'[]'::jsonb),
        'funding_budgets',coalesce((SELECT jsonb_agg(jsonb_build_object(
            'period_id',p.id,'period_start',p.start_date,'period_end',p.end_date,
            'period_status',p.status,'funding_type',a.funding_type,
            'external_source_id',a.external_source_id,
            'name',CASE WHEN a.funding_type='available' THEN 'Disponible' ELSE s.name END,
            'is_active',coalesce(s.is_active,true),'amount',a.amount::text
        ) ORDER BY p.start_date,a.funding_type,s.name,a.external_source_id)
        FROM public.budget_periods p
        CROSS JOIN LATERAL private.period_funding_allocations(p.id) a
        LEFT JOIN public.external_expense_sources s ON s.user_id=p.user_id AND s.id=a.external_source_id
        WHERE p.user_id=v_user_id AND a.amount IS NOT NULL),'[]'::jsonb),
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


-- Las firmas legacy de create_first_period y advance_period permanecen; sus
-- INSERT usan by_origin. set_general_budget solo puede escribir cuando no hay
-- asignaciones externas: entonces el importe es inequívocamente el total.
-- Las lecturas general_budget/remaining y la exportación exponen el TOTAL derivado.
-- Categorías y los helpers financieros de Disponible/Ahorro permanecen intactos.
NOTIFY pgrst, 'reload schema';
COMMIT;
