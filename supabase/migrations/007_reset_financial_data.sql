-- MisGastos 007: empezar de cero conservando la cuenta de Auth.
-- Ejecutar como el mismo propietario que 001–006.
BEGIN;

CREATE FUNCTION public.reset_financial_data(p_confirmation text)
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

COMMIT;
