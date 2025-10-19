BEGIN;

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'person_type') THEN
    CREATE TYPE person_type AS ENUM ('PF','PJ');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'payment_method_type') THEN
    CREATE TYPE payment_method_type AS ENUM ('CREDIT_CARD','PIX','BOLETO');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'delivery_status') THEN
    CREATE TYPE delivery_status AS ENUM (
      'CREATED','PACKED','SHIPPED','IN_TRANSIT','DELIVERED','RETURNED','CANCELED'
    );
  END IF;
END$$;

CREATE TABLE IF NOT EXISTS account (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text        NOT NULL,
  email        text        NOT NULL UNIQUE,
  person_type  person_type NOT NULL,
  cpf          text        NULL,
  cnpj         text        NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT account_pf_pj_exclusive CHECK (
    (person_type = 'PF' AND cpf  IS NOT NULL AND cnpj IS NULL) OR
    (person_type = 'PJ' AND cnpj IS NOT NULL AND cpf  IS NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_account_cpf
  ON account(cpf)  WHERE cpf  IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_account_cnpj
  ON account(cnpj) WHERE cnpj IS NOT NULL;

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END$$;

DROP TRIGGER IF EXISTS trg_account_updated_at ON account;
CREATE TRIGGER trg_account_updated_at
BEFORE UPDATE ON account
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS payment_method (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id   uuid NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  method_type  payment_method_type NOT NULL,
  label        text NOT NULL,
  details      jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_default   boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_payment_method_account
  ON payment_method(account_id);

CREATE UNIQUE INDEX IF NOT EXISTS ux_payment_method_default_per_account
  ON payment_method(account_id)
  WHERE is_default IS TRUE;

CREATE TABLE IF NOT EXISTS "order" (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id         uuid NOT NULL REFERENCES account(id) ON DELETE RESTRICT,
  payment_method_id  uuid NOT NULL REFERENCES payment_method(id) ON DELETE RESTRICT,
  total_amount       numeric(12,2) NOT NULL CHECK (total_amount >= 0),
  created_at         timestamptz   NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_order_account ON "order"(account_id);

CREATE OR REPLACE FUNCTION enforce_order_payment_ownership()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  pm_account uuid;
BEGIN
  SELECT account_id INTO pm_account
  FROM payment_method
  WHERE id = NEW.payment_method_id;

  IF pm_account IS NULL THEN
    RAISE EXCEPTION 'Método de pagamento % inexistente', NEW.payment_method_id;
  END IF;

  IF pm_account <> NEW.account_id THEN
    RAISE EXCEPTION 'payment_method_id não pertence à mesma account do pedido';
  END IF;

  RETURN NEW;
END$$;

DROP TRIGGER IF EXISTS trg_order_payment_ownership ON "order";
CREATE TRIGGER trg_order_payment_ownership
BEFORE INSERT OR UPDATE OF payment_method_id, account_id
ON "order"
FOR EACH ROW EXECUTE FUNCTION enforce_order_payment_ownership();

CREATE TABLE IF NOT EXISTS delivery (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id       uuid NOT NULL REFERENCES "order"(id) ON DELETE CASCADE,
  status         delivery_status NOT NULL,
  tracking_code  text NULL,
  carrier        text NULL,
  shipped_at     timestamptz NULL,
  delivered_at   timestamptz NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT delivery_tracking_required CHECK (
    NOT (status IN ('SHIPPED','IN_TRANSIT','DELIVERED','RETURNED') AND tracking_code IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS ix_delivery_order ON delivery(order_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_delivery_tracking
  ON delivery(tracking_code) WHERE tracking_code IS NOT NULL;

COMMIT;
