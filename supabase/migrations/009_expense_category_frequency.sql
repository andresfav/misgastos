-- MisGastos 009: categorías para el selector de gastos por uso histórico.
-- Requiere 001–008. Es una lectura derivada: no persiste contadores.
BEGIN;

CREATE FUNCTION public.get_expense_categories(p_current_category_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', ranked.id,
        'name', ranked.name,
        'is_active', ranked.is_active,
        'version', ranked.version,
        'expense_count', ranked.expense_count
    ) ORDER BY CASE WHEN ranked.id = p_current_category_id AND NOT ranked.is_active THEN 0 ELSE 1 END,
        ranked.expense_count DESC,
        pg_catalog.lower(pg_catalog.btrim(ranked.name)), ranked.id), '[]'::jsonb)
    FROM (
        SELECT c.id, c.name, c.is_active, c.version,
            pg_catalog.count(e.id) AS expense_count
        FROM public.categories c
        LEFT JOIN public.expenses e
            ON e.user_id = c.user_id AND e.category_id = c.id
        WHERE c.user_id = auth.uid()
          AND (c.is_active OR c.id = p_current_category_id)
        GROUP BY c.id, c.name, c.is_active, c.version
    ) ranked;
$$;
REVOKE ALL ON FUNCTION public.get_expense_categories(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_expense_categories(uuid) TO authenticated;

-- Si este contrato dejase de ser una lectura segura para authenticated, se
-- aborta toda la migración junto con la creación de la función.
DO $postconditions$
DECLARE
    v_function oid;
BEGIN
    SELECT p.oid INTO v_function
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'get_expense_categories'
      AND pg_catalog.pg_get_function_identity_arguments(p.oid) = 'p_current_category_id uuid';
    IF v_function IS NULL
      OR NOT (SELECT prosecdef FROM pg_catalog.pg_proc WHERE oid = v_function)
      OR NOT (SELECT 'search_path=""' = ANY(proconfig) FROM pg_catalog.pg_proc WHERE oid = v_function)
      OR pg_catalog.has_function_privilege('anon', v_function, 'EXECUTE')
      OR NOT pg_catalog.has_function_privilege('authenticated', v_function, 'EXECUTE') THEN
        RAISE EXCEPTION 'Postcondición 009: contrato de seguridad/ACL incorrecto';
    END IF;
END;
$postconditions$;

COMMIT;
