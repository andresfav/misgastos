-- Smoke 009 para 001–009. Ejecutar solo como propietario/BYPASSRLS.
-- Los fixtures se revierten siempre al final.
BEGIN ISOLATION LEVEL READ COMMITTED;

DO $smoke$
DECLARE
    user_a uuid := gen_random_uuid();
    user_b uuid := gen_random_uuid();
    today date := (pg_catalog.clock_timestamp() AT TIME ZONE 'Pacific/Kiritimati')::date;
    cat_ten uuid;
    cat_three uuid;
    cat_alpha uuid;
    cat_zulu uuid;
    cat_historical uuid;
    cat_b uuid;
    cat_b_beta uuid;
    cat_b_alpha uuid;
    expense_id uuid;
    rows jsonb;
    result jsonb;
    n integer;
BEGIN
    INSERT INTO auth.users(id) VALUES (user_a), (user_b);

    PERFORM pg_catalog.set_config('request.jwt.claim.sub', user_b::text, true);
    PERFORM pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object('sub', user_b, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM public.configure_user_settings('EUR', 'Pacific/Kiritimati');
    PERFORM public.create_first_period('custom', today, today, 1000, gen_random_uuid());
    SELECT id INTO cat_b FROM public.create_category('Ajena');
    PERFORM public.create_expense(today, 1, cat_b, NULL, NULL, NULL, NULL, false, gen_random_uuid());

    RESET ROLE;
    PERFORM pg_catalog.set_config('request.jwt.claim.sub', user_a::text, true);
    PERFORM pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object('sub', user_a, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM public.configure_user_settings('EUR', 'Pacific/Kiritimati');
    result := public.create_first_period('custom', today, today, 1000, gen_random_uuid());
    SELECT id INTO cat_ten FROM public.create_category('Diez usos');
    SELECT id INTO cat_three FROM public.create_category('Tres usos');
    SELECT id INTO cat_alpha FROM public.create_category(' Alfa sin usos ');
    SELECT id INTO cat_zulu FROM public.create_category('Zulu sin usos');

    FOR n IN 1..10 LOOP
        result := public.create_expense(today, 1, cat_ten, NULL, NULL, NULL, NULL, false, gen_random_uuid());
        IF n = 1 THEN expense_id := (result->>'id')::uuid; END IF;
    END LOOP;
    FOR n IN 1..3 LOOP
        PERFORM public.create_expense(today, 1, cat_three, NULL, NULL, NULL, NULL, false, gen_random_uuid());
    END LOOP;

    rows := public.get_expense_categories();
    IF (rows->0->>'id')::uuid <> cat_ten
      OR (rows->1->>'id')::uuid <> cat_three
      OR (rows->2->>'id')::uuid <> cat_alpha
      OR (rows->3->>'id')::uuid <> cat_zulu
      OR (rows->0->>'expense_count')::bigint <> 10
      OR (rows->1->>'expense_count')::bigint <> 3
      OR (rows->2->>'expense_count')::bigint <> 0 THEN
        RAISE EXCEPTION 'orden/frecuencia de categorías incorrectos';
    END IF;

    -- El conteo es exclusivamente del usuario autenticado: el gasto de B no
    -- aparece ni altera las categorías de A.
    IF EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(rows) item
        WHERE (item->>'id')::uuid = cat_b) THEN
        RAISE EXCEPTION 'se filtró una categoría de otro usuario';
    END IF;

    -- El siguiente read refleja create, cambio y borrado, sin caché persistente.
    PERFORM public.update_expense(expense_id, 1, today, 1, cat_three,
        NULL, NULL, NULL, NULL, false, gen_random_uuid());
    rows := public.get_expense_categories();
    IF (SELECT (item->>'expense_count')::bigint FROM pg_catalog.jsonb_array_elements(rows) item
        WHERE (item->>'id')::uuid = cat_ten) <> 9
      OR (SELECT (item->>'expense_count')::bigint FROM pg_catalog.jsonb_array_elements(rows) item
        WHERE (item->>'id')::uuid = cat_three) <> 4 THEN
        RAISE EXCEPTION 'el cambio de categoría no actualizó la frecuencia';
    END IF;
    PERFORM public.delete_expense(expense_id, 2, gen_random_uuid());
    rows := public.get_expense_categories();
    IF (SELECT (item->>'expense_count')::bigint FROM pg_catalog.jsonb_array_elements(rows) item
        WHERE (item->>'id')::uuid = cat_ten) <> 8 THEN
        RAISE EXCEPTION 'el borrado de gasto no actualizó la frecuencia';
    END IF;

    -- La categoría inactiva no sale en un gasto nuevo; se conserva solo al
    -- editar el gasto histórico que aún la referencia.
    SELECT id INTO cat_historical FROM public.create_category('Histórica');
    result := public.create_expense(today, 1, cat_historical, NULL, NULL, NULL, NULL, false, gen_random_uuid());
    PERFORM public.delete_category(cat_historical, 1);
    IF EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(public.get_expense_categories()) item
        WHERE (item->>'id')::uuid = cat_historical) THEN
        RAISE EXCEPTION 'una categoría inactiva apareció en un gasto nuevo';
    END IF;
    rows := public.get_expense_categories(cat_historical);
    IF (rows->0->>'id')::uuid <> cat_historical
      OR (rows->0->>'is_active')::boolean THEN
        RAISE EXCEPTION 'la edición no conservó la categoría histórica inactiva';
    END IF;

    -- Usuario sin gastos: orden normalizado alfabético, incluso con categorías
    -- iniciales/activas sin uso.
    RESET ROLE;
    PERFORM pg_catalog.set_config('request.jwt.claim.sub', user_b::text, true);
    PERFORM pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object('sub', user_b, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM public.delete_expense((SELECT id FROM public.expenses WHERE user_id = user_b), 1, gen_random_uuid());
    SELECT id INTO cat_b_beta FROM public.create_category('  Beta nueva ');
    SELECT id INTO cat_b_alpha FROM public.create_category('alfa nueva');
    rows := public.get_expense_categories();
    IF (rows->0->>'id')::uuid <> cat_b_alpha
      OR (rows->1->>'id')::uuid <> cat_b
      OR (rows->2->>'id')::uuid <> cat_b_beta THEN
        RAISE EXCEPTION 'usuario sin gastos no se ordenó alfabéticamente';
    END IF;

    RAISE NOTICE '009 smoke correcto';
END;
$smoke$;

ROLLBACK;
