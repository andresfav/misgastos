-- MisGastos: estructura base con RLS habilitado. Sin policies, RPC ni lógica financiera.
-- Las reglas diferidas están documentadas en docs/DATA_MODEL.md.
BEGIN;

-- UUID + igualdad en GiST para excluir períodos solapados por usuario.
-- gen_random_uuid() es nativa de PostgreSQL; no hace falta pgcrypto.
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;
SET LOCAL search_path = pg_catalog, public, extensions;

CREATE TABLE public.user_settings (
    user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    currency text NOT NULL CONSTRAINT user_settings_currency_check
        CHECK (currency IN ('EUR', 'USD', 'PYG')),
    timezone text NOT NULL CONSTRAINT user_settings_timezone_check
        CHECK (btrim(timezone) <> ''),
    currency_locked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CONSTRAINT user_settings_version_check CHECK (version > 0)
);

CREATE TABLE public.categories (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    name text NOT NULL CONSTRAINT categories_name_check CHECK (btrim(name) <> ''),
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CONSTRAINT categories_version_check CHECK (version > 0),
    CONSTRAINT categories_owner_id_key UNIQUE (user_id, id)
);
CREATE UNIQUE INDEX categories_owner_name_key ON public.categories (user_id, lower(btrim(name)));

CREATE TABLE public.payment_methods (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    name text NOT NULL CONSTRAINT payment_methods_name_check CHECK (btrim(name) <> ''),
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CONSTRAINT payment_methods_version_check CHECK (version > 0),
    CONSTRAINT payment_methods_owner_id_key UNIQUE (user_id, id)
);
CREATE UNIQUE INDEX payment_methods_owner_name_key ON public.payment_methods (user_id, lower(btrim(name)));

CREATE TABLE public.budget_periods (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    mode text NOT NULL CONSTRAINT budget_periods_mode_check
        CHECK (mode IN ('monthly', 'annual', 'custom', 'between_paydays')),
    start_date date NOT NULL,
    end_date date,
    status text NOT NULL DEFAULT 'open' CONSTRAINT budget_periods_status_check
        CHECK (status IN ('open', 'closed')),
    opening_balance numeric(20,2) NOT NULL,
    closing_balance numeric(20,2),
    general_budget numeric(20,2),
    closed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CONSTRAINT budget_periods_version_check CHECK (version > 0),
    CONSTRAINT budget_periods_owner_id_key UNIQUE (user_id, id),
    CONSTRAINT budget_periods_dates_check CHECK (
        isfinite(start_date) AND (end_date IS NULL OR (isfinite(end_date) AND end_date >= start_date))
    ),
    CONSTRAINT budget_periods_end_required_check CHECK (
        end_date IS NOT NULL OR (mode = 'between_paydays' AND status = 'open')
    ),
    CONSTRAINT budget_periods_monthly_check CHECK (
        mode <> 'monthly' OR (
            start_date = date_trunc('month', start_date::timestamp)::date
            AND end_date = (start_date + interval '1 month' - interval '1 day')::date
        )
    ),
    CONSTRAINT budget_periods_annual_check CHECK (
        mode <> 'annual' OR (
            start_date = date_trunc('year', start_date::timestamp)::date
            AND end_date = (start_date + interval '1 year' - interval '1 day')::date
        )
    ),
    CONSTRAINT budget_periods_closure_check CHECK (
        (status = 'open' AND closing_balance IS NULL AND closed_at IS NULL)
        OR (status = 'closed' AND end_date IS NOT NULL AND closing_balance IS NOT NULL AND closed_at IS NOT NULL)
    ),
    CONSTRAINT budget_periods_balances_check CHECK (
        opening_balance <> 'NaN'::numeric AND (closing_balance IS NULL OR closing_balance <> 'NaN'::numeric)
    ),
    CONSTRAINT budget_periods_general_budget_check CHECK (
        general_budget IS NULL OR (general_budget >= 0 AND general_budget <> 'NaN'::numeric)
    ),
    CONSTRAINT budget_periods_no_overlap EXCLUDE USING gist (
        user_id WITH =, daterange(start_date, end_date, '[]') WITH &&
    )
);
CREATE UNIQUE INDEX budget_periods_one_open_key ON public.budget_periods (user_id) WHERE status = 'open';
CREATE INDEX budget_periods_owner_start_idx ON public.budget_periods (user_id, start_date);

CREATE TABLE public.savings_accounts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    name text NOT NULL CONSTRAINT savings_accounts_name_check CHECK (btrim(name) <> ''),
    start_date date NOT NULL CONSTRAINT savings_accounts_date_check CHECK (isfinite(start_date)),
    opening_balance numeric(20,2) NOT NULL CONSTRAINT savings_accounts_balance_check
        CHECK (opening_balance >= 0 AND opening_balance <> 'NaN'::numeric),
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CONSTRAINT savings_accounts_version_check CHECK (version > 0),
    CONSTRAINT savings_accounts_owner_id_key UNIQUE (user_id, id)
);
CREATE UNIQUE INDEX savings_accounts_owner_name_key ON public.savings_accounts (user_id, lower(btrim(name)));

CREATE TABLE public.expenses (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    period_id uuid NOT NULL,
    date date NOT NULL CONSTRAINT expenses_date_check CHECK (isfinite(date)),
    amount numeric(20,2) NOT NULL CONSTRAINT expenses_amount_check CHECK (amount > 0 AND amount <> 'NaN'::numeric),
    category_id uuid NOT NULL,
    description text,
    payment_method_id uuid,
    merchant text,
    note text,
    is_recurring boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CONSTRAINT expenses_version_check CHECK (version > 0),
    CONSTRAINT expenses_period_fk FOREIGN KEY (user_id, period_id)
        REFERENCES public.budget_periods(user_id, id) ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT expenses_category_fk FOREIGN KEY (user_id, category_id)
        REFERENCES public.categories(user_id, id) ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT expenses_payment_method_fk FOREIGN KEY (user_id, payment_method_id)
        REFERENCES public.payment_methods(user_id, id) ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX expenses_owner_period_date_idx ON public.expenses (user_id, period_id, date);
CREATE INDEX expenses_owner_category_idx ON public.expenses (user_id, category_id);
CREATE INDEX expenses_owner_payment_method_idx ON public.expenses (user_id, payment_method_id);

CREATE TABLE public.incomes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    period_id uuid NOT NULL,
    date date NOT NULL CONSTRAINT incomes_date_check CHECK (isfinite(date)),
    amount numeric(20,2) NOT NULL CONSTRAINT incomes_amount_check CHECK (amount > 0 AND amount <> 'NaN'::numeric),
    savings_account_id uuid,
    description text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CONSTRAINT incomes_version_check CHECK (version > 0),
    CONSTRAINT incomes_period_fk FOREIGN KEY (user_id, period_id)
        REFERENCES public.budget_periods(user_id, id) ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT incomes_savings_account_fk FOREIGN KEY (user_id, savings_account_id)
        REFERENCES public.savings_accounts(user_id, id) ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX incomes_owner_period_date_idx ON public.incomes (user_id, period_id, date);
CREATE INDEX incomes_owner_savings_date_idx ON public.incomes (user_id, savings_account_id, date);

CREATE TABLE public.transfers (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    period_id uuid NOT NULL,
    date date NOT NULL CONSTRAINT transfers_date_check CHECK (isfinite(date)),
    amount numeric(20,2) NOT NULL CONSTRAINT transfers_amount_check CHECK (amount > 0 AND amount <> 'NaN'::numeric),
    from_savings_account_id uuid,
    to_savings_account_id uuid,
    description text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CONSTRAINT transfers_version_check CHECK (version > 0),
    CONSTRAINT transfers_endpoints_check CHECK (
        (from_savings_account_id IS NOT NULL OR to_savings_account_id IS NOT NULL)
        AND from_savings_account_id IS DISTINCT FROM to_savings_account_id
    ),
    CONSTRAINT transfers_period_fk FOREIGN KEY (user_id, period_id)
        REFERENCES public.budget_periods(user_id, id) ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT transfers_from_savings_fk FOREIGN KEY (user_id, from_savings_account_id)
        REFERENCES public.savings_accounts(user_id, id) ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT transfers_to_savings_fk FOREIGN KEY (user_id, to_savings_account_id)
        REFERENCES public.savings_accounts(user_id, id) ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX transfers_owner_period_date_idx ON public.transfers (user_id, period_id, date);
CREATE INDEX transfers_owner_from_date_idx ON public.transfers (user_id, from_savings_account_id, date);
CREATE INDEX transfers_owner_to_date_idx ON public.transfers (user_id, to_savings_account_id, date);

CREATE TABLE public.period_category_budgets (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    period_id uuid NOT NULL,
    category_id uuid NOT NULL,
    amount numeric(20,2) NOT NULL CONSTRAINT period_category_budgets_amount_check
        CHECK (amount >= 0 AND amount <> 'NaN'::numeric),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CONSTRAINT period_category_budgets_version_check CHECK (version > 0),
    CONSTRAINT period_category_budgets_owner_period_category_key UNIQUE (user_id, period_id, category_id),
    CONSTRAINT period_category_budgets_period_fk FOREIGN KEY (user_id, period_id)
        REFERENCES public.budget_periods(user_id, id) ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT period_category_budgets_category_fk FOREIGN KEY (user_id, category_id)
        REFERENCES public.categories(user_id, id) ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX period_category_budgets_owner_category_idx ON public.period_category_budgets (user_id, category_id);

CREATE TABLE public.financial_operations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    idempotency_key uuid NOT NULL,
    operation_type text NOT NULL CONSTRAINT financial_operations_type_check CHECK (btrim(operation_type) <> ''),
    request_hash text NOT NULL CONSTRAINT financial_operations_hash_check CHECK (btrim(request_hash) <> ''),
    result jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT financial_operations_owner_idempotency_key UNIQUE (user_id, idempotency_key)
);

-- Sin triggers: updated_at/version, cierre, saldos, idempotencia completa y
-- autorización se implementarán en la siguiente migración de lógica backend.
-- Cerradas por defecto para los roles sujetos a RLS, hasta definir las policies.
ALTER TABLE public.user_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_methods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.budget_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.incomes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.savings_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.period_category_budgets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.financial_operations ENABLE ROW LEVEL SECURITY;

COMMIT;
