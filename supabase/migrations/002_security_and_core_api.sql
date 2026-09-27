-- MisGastos 002: lecturas propias y API de configuración/catálogos.
-- Ejecutar como propietario de las tablas. Sin operaciones monetarias.
BEGIN;

REVOKE ALL PRIVILEGES ON TABLE
    public.user_settings, public.categories, public.payment_methods,
    public.budget_periods, public.expenses, public.incomes, public.savings_accounts,
    public.transfers, public.period_category_budgets, public.financial_operations
FROM PUBLIC, anon, authenticated;

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT ON TABLE
    public.user_settings, public.categories, public.payment_methods,
    public.budget_periods, public.expenses, public.incomes, public.savings_accounts,
    public.transfers, public.period_category_budgets
TO authenticated;

CREATE POLICY user_settings_select_own ON public.user_settings
    FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY categories_select_own ON public.categories
    FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY payment_methods_select_own ON public.payment_methods
    FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY budget_periods_select_own ON public.budget_periods
    FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY expenses_select_own ON public.expenses
    FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY incomes_select_own ON public.incomes
    FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY savings_accounts_select_own ON public.savings_accounts
    FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY transfers_select_own ON public.transfers
    FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY period_category_budgets_select_own ON public.period_category_budgets
    FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));

-- SECURITY DEFINER es necesario: el cliente no tiene DML directo.
-- Objetos cualificados y search_path vacío evitan resolver objetos del cliente.
-- Errores: 28000 sin sesión; 22023 entrada inválida/moneda bloqueada;
-- 40001 versión obsoleta; P0002 objeto inexistente o de otro propietario.
-- En todos los updates expected_version es obligatorio. Cada update aceptado
-- incrementa version, incluso si repite el mismo valor.
CREATE FUNCTION public.configure_user_settings(
    p_currency text, p_timezone text, p_expected_version bigint DEFAULT NULL
) RETURNS public.user_settings
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_row public.user_settings;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Se requiere sesión autenticada' USING ERRCODE = '28000';
    END IF;
    IF p_currency IS NULL OR p_currency NOT IN ('EUR', 'USD', 'PYG') THEN
        RAISE EXCEPTION 'Moneda inválida' USING ERRCODE = '22023';
    END IF;
    IF p_timezone IS NULL OR NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = p_timezone
    ) THEN
        RAISE EXCEPTION 'Zona horaria inválida' USING ERRCODE = '22023';
    END IF;

    -- ON CONFLICT resuelve dos inicializaciones simultáneas sin sobrescribir.
    IF p_expected_version IS NULL THEN
        INSERT INTO public.user_settings (user_id, currency, timezone)
        VALUES (v_user_id, p_currency, p_timezone)
        ON CONFLICT (user_id) DO NOTHING RETURNING * INTO v_row;
        IF FOUND THEN RETURN v_row; END IF;
    END IF;
    SELECT * INTO v_row FROM public.user_settings
        WHERE user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Configuración inexistente' USING ERRCODE = 'P0002';
    END IF;
    IF p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'expected_version es obligatorio para actualizar' USING ERRCODE = '22023';
    END IF;
    IF v_row.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    IF v_row.currency_locked_at IS NOT NULL AND v_row.currency <> p_currency THEN
        RAISE EXCEPTION 'La moneda está bloqueada' USING ERRCODE = '22023';
    END IF;
    -- Con moneda bloqueada se permite cambiar timezone conservando currency.
    UPDATE public.user_settings SET currency = p_currency, timezone = p_timezone,
        version = version + 1, updated_at = pg_catalog.clock_timestamp()
        WHERE user_id = v_user_id RETURNING * INTO v_row;
    RETURN v_row;
END;
$$;
REVOKE ALL ON FUNCTION public.configure_user_settings(text, text, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.configure_user_settings(text, text, bigint) TO authenticated;

CREATE FUNCTION public.create_category(p_name text)
RETURNS public.categories
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_row public.categories;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Se requiere sesión autenticada' USING ERRCODE = '28000';
    END IF;
    IF p_name IS NULL OR pg_catalog.btrim(p_name) = '' THEN
        RAISE EXCEPTION 'Nombre vacío' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.categories (user_id, name)
        VALUES (v_user_id, pg_catalog.btrim(p_name)) RETURNING * INTO v_row;
    RETURN v_row;
END;
$$;
REVOKE ALL ON FUNCTION public.create_category(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_category(text) TO authenticated;

CREATE FUNCTION public.rename_category(p_id uuid, p_name text, p_expected_version bigint)
RETURNS public.categories
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_row public.categories;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Se requiere sesión autenticada' USING ERRCODE = '28000';
    END IF;
    IF p_name IS NULL OR pg_catalog.btrim(p_name) = '' OR p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'Parámetros inválidos' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_row FROM public.categories
        WHERE id = p_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Objeto no encontrado' USING ERRCODE = 'P0002';
    END IF;
    IF v_row.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    UPDATE public.categories SET name = pg_catalog.btrim(p_name),
        version = version + 1, updated_at = pg_catalog.clock_timestamp()
        WHERE id = p_id AND user_id = v_user_id RETURNING * INTO v_row;
    RETURN v_row;
END;
$$;
REVOKE ALL ON FUNCTION public.rename_category(uuid, text, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rename_category(uuid, text, bigint) TO authenticated;

CREATE FUNCTION public.set_category_active(p_id uuid, p_is_active boolean, p_expected_version bigint)
RETURNS public.categories
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_row public.categories;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Se requiere sesión autenticada' USING ERRCODE = '28000';
    END IF;
    IF p_is_active IS NULL OR p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'Parámetros inválidos' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_row FROM public.categories
        WHERE id = p_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Objeto no encontrado' USING ERRCODE = 'P0002';
    END IF;
    IF v_row.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    UPDATE public.categories SET is_active = p_is_active,
        version = version + 1, updated_at = pg_catalog.clock_timestamp()
        WHERE id = p_id AND user_id = v_user_id RETURNING * INTO v_row;
    RETURN v_row;
END;
$$;
REVOKE ALL ON FUNCTION public.set_category_active(uuid, boolean, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_category_active(uuid, boolean, bigint) TO authenticated;

CREATE FUNCTION public.create_payment_method(p_name text)
RETURNS public.payment_methods
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_row public.payment_methods;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Se requiere sesión autenticada' USING ERRCODE = '28000';
    END IF;
    IF p_name IS NULL OR pg_catalog.btrim(p_name) = '' THEN
        RAISE EXCEPTION 'Nombre vacío' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.payment_methods (user_id, name)
        VALUES (v_user_id, pg_catalog.btrim(p_name)) RETURNING * INTO v_row;
    RETURN v_row;
END;
$$;
REVOKE ALL ON FUNCTION public.create_payment_method(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_payment_method(text) TO authenticated;

CREATE FUNCTION public.rename_payment_method(p_id uuid, p_name text, p_expected_version bigint)
RETURNS public.payment_methods
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_row public.payment_methods;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Se requiere sesión autenticada' USING ERRCODE = '28000';
    END IF;
    IF p_name IS NULL OR pg_catalog.btrim(p_name) = '' OR p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'Parámetros inválidos' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_row FROM public.payment_methods
        WHERE id = p_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Objeto no encontrado' USING ERRCODE = 'P0002';
    END IF;
    IF v_row.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    UPDATE public.payment_methods SET name = pg_catalog.btrim(p_name),
        version = version + 1, updated_at = pg_catalog.clock_timestamp()
        WHERE id = p_id AND user_id = v_user_id RETURNING * INTO v_row;
    RETURN v_row;
END;
$$;
REVOKE ALL ON FUNCTION public.rename_payment_method(uuid, text, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rename_payment_method(uuid, text, bigint) TO authenticated;

CREATE FUNCTION public.set_payment_method_active(p_id uuid, p_is_active boolean, p_expected_version bigint)
RETURNS public.payment_methods
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_row public.payment_methods;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Se requiere sesión autenticada' USING ERRCODE = '28000';
    END IF;
    IF p_is_active IS NULL OR p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'Parámetros inválidos' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_row FROM public.payment_methods
        WHERE id = p_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Objeto no encontrado' USING ERRCODE = 'P0002';
    END IF;
    IF v_row.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    UPDATE public.payment_methods SET is_active = p_is_active,
        version = version + 1, updated_at = pg_catalog.clock_timestamp()
        WHERE id = p_id AND user_id = v_user_id RETURNING * INTO v_row;
    RETURN v_row;
END;
$$;
REVOKE ALL ON FUNCTION public.set_payment_method_active(uuid, boolean, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_payment_method_active(uuid, boolean, bigint) TO authenticated;

COMMIT;
