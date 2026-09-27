-- MisGastos 003: primer período y cuentas de ahorro; sin movimientos.
-- Ejecutar como el mismo propietario que 001/002. No modifica sus archivos.
BEGIN;

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;

-- Una clave bigint derivada del UUID, disponible incluso sin user_settings.
-- Una colisión del hash solo serializa dos usuarios independientes; no mezcla datos.
-- Este espacio de advisory locks queda reservado para las mutaciones de MisGastos.
CREATE FUNCTION private.lock_current_user() RETURNS uuid
LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := auth.uid();
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Se requiere sesión autenticada' USING ERRCODE = '28000';
    END IF;
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_user_id::text, 0));
    RETURN v_user_id;
END;
$$;
REVOKE ALL ON FUNCTION private.lock_current_user() FROM PUBLIC, anon, authenticated;

-- SHA-256 nativo de PostgreSQL: no requiere añadir pgcrypto.
-- El llamador normaliza importes a numeric(20,2) y nombres con btrim.
CREATE FUNCTION private.financial_request_hash(p_operation text, p_parameters jsonb)
RETURNS text LANGUAGE sql IMMUTABLE STRICT SECURITY INVOKER SET search_path = ''
AS $$
    SELECT pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(
        pg_catalog.jsonb_build_object('operation', p_operation, 'parameters', p_parameters)::text,
        'UTF8'
    )), 'hex');
$$;
REVOKE ALL ON FUNCTION private.financial_request_hash(text, jsonb) FROM PUBLIC, anon, authenticated;

-- Mismos contratos y validaciones de 002; solo se añade el bloqueo común
-- como primera acción. Las ACL se vuelven a declarar explícitamente.
CREATE OR REPLACE FUNCTION public.configure_user_settings(
    p_currency text, p_timezone text, p_expected_version bigint DEFAULT NULL
) RETURNS public.user_settings
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
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

CREATE OR REPLACE FUNCTION public.create_category(p_name text)
RETURNS public.categories
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
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

CREATE OR REPLACE FUNCTION public.rename_category(p_id uuid, p_name text, p_expected_version bigint)
RETURNS public.categories
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
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

CREATE OR REPLACE FUNCTION public.set_category_active(p_id uuid, p_is_active boolean, p_expected_version bigint)
RETURNS public.categories
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
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

CREATE OR REPLACE FUNCTION public.create_payment_method(p_name text)
RETURNS public.payment_methods
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
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

CREATE OR REPLACE FUNCTION public.rename_payment_method(p_id uuid, p_name text, p_expected_version bigint)
RETURNS public.payment_methods
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
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

CREATE OR REPLACE FUNCTION public.set_payment_method_active(p_id uuid, p_is_active boolean, p_expected_version bigint)
RETURNS public.payment_methods
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
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

-- p_opening_balance explícito representa la confirmación del saldo inicial.
-- Devuelve la fila creada como JSONB; un retry devuelve la instantánea guardada.
CREATE FUNCTION public.create_first_period(
    p_mode text, p_start_date date, p_end_date date, p_opening_balance numeric,
    p_request_id uuid, p_general_budget numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_settings public.user_settings;
    v_operation public.financial_operations;
    v_period public.budget_periods;
    v_today date;
    v_opening numeric(20,2);
    v_budget numeric(20,2);
    v_hash text;
    v_result jsonb;
BEGIN
    IF p_request_id IS NULL OR p_mode IS NULL OR p_mode NOT IN ('monthly','annual','custom','between_paydays')
        OR p_start_date IS NULL OR NOT pg_catalog.isfinite(p_start_date)
        OR (p_end_date IS NOT NULL AND NOT pg_catalog.isfinite(p_end_date)) THEN
        RAISE EXCEPTION 'Petición o fechas inválidas' USING ERRCODE = '22023';
    END IF;
    -- Validar antes del cast: no redondear silenciosamente ni aceptar NaN/infinito.
    IF p_opening_balance IS NULL OR p_opening_balance::text IN ('NaN','Infinity','-Infinity')
        OR p_opening_balance <> pg_catalog.trunc(p_opening_balance, 2)
        OR (p_general_budget IS NOT NULL AND (
            p_general_budget::text IN ('NaN','Infinity','-Infinity') OR p_general_budget < 0
            OR p_general_budget <> pg_catalog.trunc(p_general_budget, 2))) THEN
        RAISE EXCEPTION 'Importe inválido; máximo dos decimales' USING ERRCODE = '22023';
    END IF;
    v_opening := p_opening_balance;
    v_budget := p_general_budget;
    v_hash := private.financial_request_hash('create_first_period', pg_catalog.jsonb_build_object(
        'mode', p_mode, 'start_date', p_start_date, 'end_date', p_end_date,
        'opening_balance', v_opening, 'general_budget', v_budget
    ));
    SELECT * INTO v_operation FROM public.financial_operations
        WHERE user_id = v_user_id AND idempotency_key = p_request_id;
    IF FOUND THEN
        IF v_operation.operation_type <> 'create_first_period' OR v_operation.request_hash <> v_hash THEN
            RAISE EXCEPTION 'request_id reutilizado con otra petición' USING ERRCODE = '22023';
        END IF;
        RETURN v_operation.result;
    END IF;

    -- Las reglas dependientes del estado/fecha se comprueban después del retry.
    SELECT * INTO v_settings FROM public.user_settings WHERE user_id = v_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Configura primero moneda y zona horaria' USING ERRCODE = 'P0002';
    END IF;
    v_today := (pg_catalog.clock_timestamp() AT TIME ZONE v_settings.timezone)::date;
    IF p_start_date > v_today THEN
        RAISE EXCEPTION 'La fecha inicial no puede ser futura' USING ERRCODE = '22023';
    END IF;
    IF p_mode = 'between_paydays' THEN
        IF p_end_date IS NOT NULL THEN
            RAISE EXCEPTION 'El primer período entre nóminas debe tener final abierto' USING ERRCODE = '22023';
        END IF;
    ELSE
        IF p_end_date IS NULL OR p_end_date < v_today THEN
            RAISE EXCEPTION 'El período debe contener hoy' USING ERRCODE = '22023';
        END IF;
        IF p_mode = 'monthly' AND (
            p_start_date <> pg_catalog.date_trunc('month', v_today::timestamp)::date
            OR p_end_date <> (pg_catalog.date_trunc('month', v_today::timestamp) + interval '1 month - 1 day')::date
        ) THEN
            RAISE EXCEPTION 'Debe ser el mes natural actual' USING ERRCODE = '22023';
        END IF;
        IF p_mode = 'annual' AND (
            p_start_date <> pg_catalog.date_trunc('year', v_today::timestamp)::date
            OR p_end_date <> (pg_catalog.date_trunc('year', v_today::timestamp) + interval '1 year - 1 day')::date
        ) THEN
            RAISE EXCEPTION 'Debe ser el año natural actual' USING ERRCODE = '22023';
        END IF;
    END IF;
    IF EXISTS (SELECT 1 FROM public.budget_periods WHERE user_id = v_user_id) THEN
        RAISE EXCEPTION 'Ya existe un período financiero' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.budget_periods(user_id, mode, start_date, end_date, opening_balance, general_budget)
        VALUES (v_user_id, p_mode, p_start_date, p_end_date, v_opening, v_budget)
        RETURNING * INTO v_period;
    UPDATE public.user_settings SET currency_locked_at = pg_catalog.clock_timestamp(),
        version = version + 1, updated_at = pg_catalog.clock_timestamp()
        WHERE user_id = v_user_id AND currency_locked_at IS NULL;
    v_result := pg_catalog.to_jsonb(v_period);
    INSERT INTO public.financial_operations(user_id, idempotency_key, operation_type, request_hash, result)
        VALUES (v_user_id, p_request_id, 'create_first_period', v_hash, v_result);
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.create_first_period(text, date, date, numeric, uuid, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_first_period(text, date, date, numeric, uuid, numeric) TO authenticated;

CREATE FUNCTION public.create_savings_account(
    p_name text, p_start_date date, p_opening_balance numeric, p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_settings public.user_settings;
    v_operation public.financial_operations;
    v_account public.savings_accounts;
    v_name text := pg_catalog.btrim(p_name);
    v_opening numeric(20,2);
    v_hash text;
    v_result jsonb;
BEGIN
    IF p_request_id IS NULL OR v_name IS NULL OR v_name = '' OR p_start_date IS NULL
        OR NOT pg_catalog.isfinite(p_start_date) THEN
        RAISE EXCEPTION 'Petición, nombre o fecha inválidos' USING ERRCODE = '22023';
    END IF;
    IF p_opening_balance IS NULL OR p_opening_balance::text IN ('NaN','Infinity','-Infinity')
        OR p_opening_balance < 0 OR p_opening_balance <> pg_catalog.trunc(p_opening_balance, 2) THEN
        RAISE EXCEPTION 'Saldo inicial inválido; máximo dos decimales' USING ERRCODE = '22023';
    END IF;
    v_opening := p_opening_balance;
    v_hash := private.financial_request_hash('create_savings_account', pg_catalog.jsonb_build_object(
        'name', v_name, 'start_date', p_start_date, 'opening_balance', v_opening
    ));
    SELECT * INTO v_operation FROM public.financial_operations
        WHERE user_id = v_user_id AND idempotency_key = p_request_id;
    IF FOUND THEN
        IF v_operation.operation_type <> 'create_savings_account' OR v_operation.request_hash <> v_hash THEN
            RAISE EXCEPTION 'request_id reutilizado con otra petición' USING ERRCODE = '22023';
        END IF;
        RETURN v_operation.result;
    END IF;
    SELECT * INTO v_settings FROM public.user_settings WHERE user_id = v_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Configura primero moneda y zona horaria' USING ERRCODE = 'P0002';
    END IF;
    IF p_start_date > (pg_catalog.clock_timestamp() AT TIME ZONE v_settings.timezone)::date THEN
        RAISE EXCEPTION 'La fecha inicial no puede ser futura' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.savings_accounts(user_id, name, start_date, opening_balance)
        VALUES (v_user_id, v_name, p_start_date, v_opening) RETURNING * INTO v_account;
    UPDATE public.user_settings SET currency_locked_at = pg_catalog.clock_timestamp(),
        version = version + 1, updated_at = pg_catalog.clock_timestamp()
        WHERE user_id = v_user_id AND currency_locked_at IS NULL;
    v_result := pg_catalog.to_jsonb(v_account);
    INSERT INTO public.financial_operations(user_id, idempotency_key, operation_type, request_hash, result)
        VALUES (v_user_id, p_request_id, 'create_savings_account', v_hash, v_result);
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.create_savings_account(text, date, numeric, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_savings_account(text, date, numeric, uuid) TO authenticated;

CREATE FUNCTION public.rename_savings_account(p_id uuid, p_name text, p_expected_version bigint)
RETURNS public.savings_accounts
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_row public.savings_accounts;
BEGIN
    IF p_name IS NULL OR pg_catalog.btrim(p_name) = '' OR p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'Parámetros inválidos' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_row FROM public.savings_accounts
        WHERE id = p_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Objeto no encontrado' USING ERRCODE = 'P0002';
    END IF;
    IF v_row.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    UPDATE public.savings_accounts SET name = pg_catalog.btrim(p_name),
        version = version + 1, updated_at = pg_catalog.clock_timestamp()
        WHERE id = p_id AND user_id = v_user_id RETURNING * INTO v_row;
    RETURN v_row;
END;
$$;
REVOKE ALL ON FUNCTION public.rename_savings_account(uuid, text, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rename_savings_account(uuid, text, bigint) TO authenticated;

-- false desactiva; true restaura. Fecha y saldo inicial quedan intactos.
CREATE FUNCTION public.set_savings_account_active(p_id uuid, p_is_active boolean, p_expected_version bigint)
RETURNS public.savings_accounts
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := private.lock_current_user();
    v_row public.savings_accounts;
BEGIN
    IF p_is_active IS NULL OR p_expected_version IS NULL OR p_expected_version < 1 THEN
        RAISE EXCEPTION 'Parámetros inválidos' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_row FROM public.savings_accounts
        WHERE id = p_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Objeto no encontrado' USING ERRCODE = 'P0002';
    END IF;
    IF v_row.version <> p_expected_version THEN
        RAISE EXCEPTION 'Versión obsoleta' USING ERRCODE = '40001';
    END IF;
    UPDATE public.savings_accounts SET is_active = p_is_active,
        version = version + 1, updated_at = pg_catalog.clock_timestamp()
        WHERE id = p_id AND user_id = v_user_id RETURNING * INTO v_row;
    RETURN v_row;
END;
$$;
REVOKE ALL ON FUNCTION public.set_savings_account_active(uuid, boolean, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_savings_account_active(uuid, boolean, bigint) TO authenticated;

-- Se mantienen las ACL y policies SELECT de 002: nada de DML directo ni acceso
-- cliente a financial_operations. No se crean movimientos ni cierres.
COMMIT;
