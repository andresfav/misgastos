-- MisGastos 010: modelo de lectura para exportaciones CSV/XLSX.
-- Requiere 001–009. Solo SELECT; no persiste snapshots ni movimientos.
BEGIN;

CREATE FUNCTION public.get_data_export(
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
            e.amount::text AS amount, 'Disponible'::text AS origin, 'Exterior'::text AS destination,
            c.name AS category, pm.name AS payment_method, e.merchant,
            e.description, e.note, e.is_recurring, p.id AS period_id, p.start_date AS period_start,
            p.end_date AS period_end, p.status AS period_status
        FROM public.expenses e
        JOIN public.budget_periods p ON p.id = e.period_id AND p.user_id = e.user_id
        JOIN public.categories c ON c.id = e.category_id AND c.user_id = e.user_id
        LEFT JOIN public.payment_methods pm ON pm.id = e.payment_method_id AND pm.user_id = e.user_id
        WHERE e.user_id = v_user_id AND e.date BETWEEN v_start AND v_end
        UNION ALL
        SELECT i.date, 'income', i.id, i.created_at, i.amount::text, 'Exterior',
            coalesce(sa.name, 'Disponible'), NULL, NULL, NULL, i.description, NULL, NULL::boolean,
            p.id, p.start_date, p.end_date, p.status
        FROM public.incomes i
        JOIN public.budget_periods p ON p.id = i.period_id AND p.user_id = i.user_id
        LEFT JOIN public.savings_accounts sa ON sa.id = i.savings_account_id AND sa.user_id = i.user_id
        WHERE i.user_id = v_user_id AND i.date BETWEEN v_start AND v_end
        UNION ALL
        SELECT t.date, 'transfer', t.id, t.created_at, t.amount::text,
            coalesce(source.name, 'Disponible'), coalesce(target.name, 'Disponible'),
            NULL, NULL, NULL, t.description, NULL, NULL::boolean, p.id, p.start_date, p.end_date, p.status
        FROM public.transfers t
        JOIN public.budget_periods p ON p.id = t.period_id AND p.user_id = t.user_id
        LEFT JOIN public.savings_accounts source
            ON source.id = t.from_savings_account_id AND source.user_id = t.user_id
        LEFT JOIN public.savings_accounts target
            ON target.id = t.to_savings_account_id AND target.user_id = t.user_id
        WHERE t.user_id = v_user_id AND t.date BETWEEN v_start AND v_end
    )
    SELECT coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
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
        'payment_methods',coalesce((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'id',pm.id,'name',pm.name,'is_active',pm.is_active,'version',pm.version
        ) ORDER BY pg_catalog.lower(pg_catalog.btrim(pm.name)),pm.id)
        FROM public.payment_methods pm WHERE pm.user_id=v_user_id),'[]'::jsonb)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.get_data_export(date,date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_data_export(date,date) TO authenticated;

DO $postconditions$
DECLARE v_function oid;
BEGIN
    SELECT p.oid INTO v_function FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='get_data_export'
      AND pg_catalog.pg_get_function_identity_arguments(p.oid)='p_start_date date, p_end_date date';
    IF v_function IS NULL
      OR NOT (SELECT prosecdef FROM pg_catalog.pg_proc WHERE oid=v_function)
      OR NOT (SELECT provolatile='s' FROM pg_catalog.pg_proc WHERE oid=v_function)
      OR NOT (SELECT 'search_path=""'=ANY(proconfig) FROM pg_catalog.pg_proc WHERE oid=v_function)
      OR pg_catalog.has_function_privilege('anon',v_function,'EXECUTE')
      OR NOT pg_catalog.has_function_privilege('authenticated',v_function,'EXECUTE') THEN
        RAISE EXCEPTION 'Postcondición 010: contrato de seguridad/ACL incorrecto';
    END IF;
END;
$postconditions$;

COMMIT;
