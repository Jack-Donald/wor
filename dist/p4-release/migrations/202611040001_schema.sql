BEGIN;
CREATE ROLE wo_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE ROLE wo_maintainer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE ROLE wo_collector NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE ROLE wo_reader NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE ROLE wo_anonymous NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE ROLE wo_authenticator LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE SCHEMA wo_v2 AUTHORIZATION wo_owner;
CREATE SCHEMA wo_rpc AUTHORIZATION wo_owner;
REVOKE ALL ON SCHEMA wo_v2, wo_rpc FROM PUBLIC;
GRANT USAGE ON SCHEMA wo_v2 TO wo_maintainer;
GRANT USAGE ON SCHEMA wo_rpc TO wo_maintainer, wo_collector, wo_reader;
SET ROLE wo_owner;
ALTER DEFAULT PRIVILEGES IN SCHEMA wo_v2 REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA wo_rpc REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE DOMAIN wo_v2.finite_value AS numeric CHECK (VALUE IS NULL OR (VALUE::text NOT IN ('NaN','Infinity','-Infinity') AND abs(VALUE) < 1e18 AND scale(VALUE) <= 36));
CREATE TABLE wo_v2.products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (length(name) BETWEEN 1 AND 300),
  product_code text CHECK (length(product_code) BETWEEN 1 AND 128),
  registration_code text UNIQUE CHECK (length(registration_code) BETWEEN 1 AND 128),
  manager_name text NOT NULL CHECK (length(manager_name) BETWEEN 1 AND 200),
  risk_level text CHECK (length(risk_level) BETWEEN 1 AND 32),
  currency text NOT NULL CHECK (currency='CNY'),
  is_public boolean NOT NULL CHECK (is_public)
);
CREATE UNIQUE INDEX product_code_by_manager ON wo_v2.products(manager_name,product_code) WHERE product_code IS NOT NULL;
CREATE TABLE wo_v2.shares (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES wo_v2.products,
  name text NOT NULL CHECK (length(name) BETWEEN 1 AND 300),
  share_code text CHECK (length(share_code) BETWEEN 1 AND 128),
  is_default boolean NOT NULL DEFAULT false,
  inception_date date CHECK (inception_date BETWEEN '1900-01-01' AND '2199-12-31'),
  lifecycle_state text NOT NULL CHECK (lifecycle_state IN ('active','ended','unknown')),
  operating_mode text NOT NULL CHECK (operating_mode IN ('open','minimum_holding','closed','periodic','cash_management')),
  restriction_days integer NOT NULL CHECK (restriction_days BETWEEN 0 AND 31),
  collection_capability text NOT NULL CHECK (collection_capability IN ('available','unavailable','unknown')),
  catalog_updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  collection_epoch uuid NOT NULL DEFAULT gen_random_uuid()
);
CREATE UNIQUE INDEX one_default_share ON wo_v2.shares(product_id) WHERE is_default;
CREATE UNIQUE INDEX share_code_by_product ON wo_v2.shares(product_id,share_code) WHERE share_code IS NOT NULL;
CREATE INDEX shares_catalog_order ON wo_v2.shares(catalog_updated_at DESC,id);
CREATE INDEX shares_product ON wo_v2.shares(product_id);
CREATE TABLE wo_v2.sales_offerings (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  share_id uuid NOT NULL REFERENCES wo_v2.shares,
  channel_key text NOT NULL CHECK (channel_key ~ '^[a-z][a-z0-9_-]{0,62}$'),
  channel_name text NOT NULL CHECK (length(channel_name) BETWEEN 1 AND 200),
  sales_code text CHECK (length(sales_code) BETWEEN 1 AND 128),
  UNIQUE NULLS NOT DISTINCT (share_id,channel_key,sales_code)
);
CREATE INDEX offerings_channel ON wo_v2.sales_offerings(channel_key,share_id);
CREATE TABLE wo_v2.sources (
  id text PRIMARY KEY CHECK (id ~ '^[a-z][a-z0-9_-]{0,62}$'),
  name text NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
  kind text NOT NULL CHECK (kind IN ('channel','manager')),
  priority integer NOT NULL CHECK (priority BETWEEN 0 AND 100000)
);
CREATE TABLE wo_v2.external_identifiers (
  source_id text NOT NULL REFERENCES wo_v2.sources,
  kind text NOT NULL CHECK (kind ~ '^(product|share):[a-z][a-z0-9_-]{0,62}$'),
  value text NOT NULL CHECK (length(value) BETWEEN 1 AND 256),
  product_id uuid REFERENCES wo_v2.products,
  share_id uuid REFERENCES wo_v2.shares,
  PRIMARY KEY(source_id,kind,value),
  CHECK ((product_id IS NULL) <> (share_id IS NULL)),
  CHECK ((product_id IS NOT NULL) = (kind LIKE 'product:%'))
);
CREATE INDEX identifiers_share ON wo_v2.external_identifiers(share_id) WHERE share_id IS NOT NULL;
CREATE TABLE wo_v2.inclusion_reasons (
  share_id uuid NOT NULL REFERENCES wo_v2.shares,
  reason_type text NOT NULL CHECK (reason_type IN ('hot','manual')),
  PRIMARY KEY(share_id,reason_type)
);
CREATE TABLE wo_v2.observations (
  share_id uuid NOT NULL REFERENCES wo_v2.shares,
  source_id text NOT NULL REFERENCES wo_v2.sources,
  value_date date NOT NULL CHECK (value_date BETWEEN '1900-01-01' AND '2199-12-31'),
  income_period_start date CHECK (income_period_start BETWEEN '1900-01-01' AND value_date),
  income_basis text CHECK (income_basis IN ('daily','period_total','daily_average')),
  unit_nav wo_v2.finite_value CHECK (unit_nav>0),
  cumulative_nav wo_v2.finite_value CHECK (cumulative_nav>=0),
  income_per_10k wo_v2.finite_value,
  official_yield_7d wo_v2.finite_value,
  adjustment_verified_from date CHECK (adjustment_verified_from BETWEEN '1900-01-01' AND value_date),
  PRIMARY KEY(share_id,source_id,value_date),
  CHECK (unit_nav IS NOT NULL OR cumulative_nav IS NOT NULL OR income_per_10k IS NOT NULL OR official_yield_7d IS NOT NULL),
  CHECK (income_per_10k IS NULL OR (income_period_start IS NOT NULL AND income_basis IS NOT NULL)),
  CHECK (income_basis IS DISTINCT FROM 'daily' OR income_period_start=value_date)
);
CREATE TABLE wo_v2.adjustments (
  share_id uuid NOT NULL REFERENCES wo_v2.shares,
  source_id text NOT NULL REFERENCES wo_v2.sources,
  effective_date date NOT NULL CHECK (effective_date BETWEEN '1900-01-01' AND '2199-12-31'),
  event_type text NOT NULL CHECK (event_type IN ('cash_dividend','share_split','combined')),
  cash_per_unit wo_v2.finite_value NOT NULL CHECK (cash_per_unit>=0),
  split_factor wo_v2.finite_value NOT NULL CHECK (split_factor>0),
  PRIMARY KEY(share_id,source_id,effective_date),
  CHECK (event_type<>'cash_dividend' OR split_factor=1),
  CHECK (event_type<>'share_split' OR cash_per_unit=0)
);
CREATE TABLE wo_v2.current_metrics (
  share_id uuid NOT NULL REFERENCES wo_v2.shares,
  metric_code text NOT NULL CHECK (metric_code IN ('dailyIncomePer10k','averageIncome7d','averageIncome14d','return7d','return14d','annualized7d','annualized14d','annualized1m','annualized3m','flatDisclosureCountMonth','annualizedSinceInception')),
  value wo_v2.finite_value,
  start_date date,
  end_date date,
  source_id text REFERENCES wo_v2.sources,
  unavailable_reason text CHECK (unavailable_reason IN ('insufficient_history','missing_disclosure','missing_adjustment','not_applicable','unknown_income_basis','unsupported_adjustment_ratio','outside_retained_history','unknown_inception_date','requires_recalculation','unknown_calendar')),
  PRIMARY KEY(share_id,metric_code),
  CHECK ((value IS NULL)=(unavailable_reason IS NOT NULL)),
  CHECK (value IS NULL OR (start_date IS NOT NULL AND end_date IS NOT NULL AND source_id IS NOT NULL))
);
CREATE INDEX metrics_order ON wo_v2.current_metrics(metric_code,value DESC NULLS LAST,share_id);

CREATE FUNCTION wo_v2.policy() RETURNS jsonb LANGUAGE sql STABLE SET search_path=pg_catalog,wo_v2,pg_temp AS $$ SELECT NULL::jsonb $$;
CREATE FUNCTION wo_v2.policy_revision() RETURNS text LANGUAGE sql STABLE SET search_path=pg_catalog,wo_v2,pg_temp AS $$ SELECT NULL::text $$;
CREATE FUNCTION wo_v2.business_today() RETURNS date LANGUAGE sql STABLE SET search_path=pg_catalog AS $$ SELECT (statement_timestamp() AT TIME ZONE 'Asia/Shanghai')::date $$;
CREATE FUNCTION wo_v2.latch() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
BEGIN
  IF current_setting('transaction_isolation') <> 'read committed' THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
  PERFORM pg_advisory_xact_lock(1464819506,1);
  RETURN NULL;
END $$;
CREATE FUNCTION wo_v2.invalidate(target uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
BEGIN
  UPDATE shares SET collection_epoch=gen_random_uuid() WHERE id=target;
  UPDATE current_metrics SET value=NULL,unavailable_reason='requires_recalculation'
  WHERE share_id=target AND (value IS NOT NULL OR unavailable_reason IS DISTINCT FROM 'requires_recalculation');
END $$;

CREATE FUNCTION wo_v2.protect_row() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE target uuid; src text; fact_date date; item record; old_json jsonb; new_json jsonb; business_change boolean;
BEGIN
  IF TG_OP='UPDATE' AND to_jsonb(OLD)=to_jsonb(NEW) THEN RETURN NEW; END IF;
  old_json := CASE WHEN TG_OP='INSERT' THEN '{}'::jsonb ELSE to_jsonb(OLD) END;
  new_json := CASE WHEN TG_OP='DELETE' THEN '{}'::jsonb ELSE to_jsonb(NEW) END;
  IF TG_WHEN='BEFORE' THEN
  IF TG_OP='UPDATE' THEN
    IF (old_json->'id') IS DISTINCT FROM (new_json->'id') OR
       (old_json->'share_id') IS DISTINCT FROM (new_json->'share_id') OR
       (old_json->'product_id') IS DISTINCT FROM (new_json->'product_id') OR
       (old_json->'source_id') IS DISTINCT FROM (new_json->'source_id') OR
       (old_json->'value_date') IS DISTINCT FROM (new_json->'value_date') OR
       (old_json->'effective_date') IS DISTINCT FROM (new_json->'effective_date') OR
       (TG_TABLE_NAME='external_identifiers' AND (old_json->'kind') IS DISTINCT FROM (new_json->'kind')) OR
       (old_json->'value') IS DISTINCT FROM (new_json->'value') OR
       (old_json->'reason_type') IS DISTINCT FROM (new_json->'reason_type') THEN
      RAISE EXCEPTION 'immutable_identity' USING ERRCODE='WO001';
    END IF;
  END IF;
  IF TG_TABLE_NAME='shares' THEN
    IF TG_OP='UPDATE' AND (old_json-'collection_epoch'-'catalog_updated_at') IS DISTINCT FROM (new_json-'collection_epoch'-'catalog_updated_at') THEN
      NEW.collection_epoch:=gen_random_uuid(); NEW.catalog_updated_at:=clock_timestamp();
      IF (old_json-'name'-'share_code'-'collection_epoch'-'catalog_updated_at') IS DISTINCT FROM (new_json-'name'-'share_code'-'collection_epoch'-'catalog_updated_at') THEN
        UPDATE current_metrics SET value=NULL,unavailable_reason='requires_recalculation' WHERE share_id=NEW.id;
      END IF;
    END IF;
    RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
  END IF;
  IF TG_TABLE_NAME IN ('observations','adjustments') AND TG_OP<>'DELETE' THEN
    IF NOT EXISTS(SELECT 1 FROM inclusion_reasons WHERE share_id=NEW.share_id) THEN RAISE EXCEPTION 'not_included' USING ERRCODE='WO002'; END IF;
    IF TG_TABLE_NAME='observations' AND (old_json-'adjustment_verified_from') IS DISTINCT FROM (new_json-'adjustment_verified_from') THEN NEW.adjustment_verified_from:=NULL; END IF;
  END IF;
  RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
  END IF;
  IF TG_TABLE_NAME='shares' THEN RETURN NULL; END IF;
  IF TG_TABLE_NAME IN ('products','sources') THEN
    FOR item IN SELECT id FROM shares WHERE TG_TABLE_NAME='sources' OR product_id=(CASE WHEN TG_TABLE_NAME='products' THEN COALESCE(new_json->>'id',old_json->>'id')::uuid END) ORDER BY id LOOP
      PERFORM invalidate(item.id);
      IF TG_TABLE_NAME='products' THEN UPDATE shares SET catalog_updated_at=clock_timestamp() WHERE id=item.id; END IF;
    END LOOP;
  ELSIF TG_TABLE_NAME='external_identifiers' THEN
    target:=COALESCE((new_json->>'share_id')::uuid,(old_json->>'share_id')::uuid);
    IF target IS NOT NULL THEN PERFORM invalidate(target); END IF;
  ELSE
    target:=COALESCE((new_json->>'share_id')::uuid,(old_json->>'share_id')::uuid);
    PERFORM 1 FROM shares WHERE id=target FOR UPDATE;
    IF TG_TABLE_NAME IN ('observations','adjustments') THEN
      IF TG_OP<>'DELETE' AND NOT EXISTS(SELECT 1 FROM inclusion_reasons WHERE share_id=target) THEN RAISE EXCEPTION 'not_included' USING ERRCODE='WO002'; END IF;
      src:=COALESCE(new_json->>'source_id',old_json->>'source_id');
      fact_date:=COALESCE((new_json->>'value_date')::date,(old_json->>'value_date')::date,(new_json->>'effective_date')::date,(old_json->>'effective_date')::date);
      business_change := (old_json-'adjustment_verified_from') IS DISTINCT FROM (new_json-'adjustment_verified_from');
      IF business_change THEN
        UPDATE observations SET adjustment_verified_from=NULL
        WHERE share_id=target AND source_id=src AND adjustment_verified_from IS NOT NULL
          AND (TG_TABLE_NAME<>'observations' OR value_date<>fact_date)
          AND value_date>=fact_date AND adjustment_verified_from<=fact_date;
      END IF;
      PERFORM invalidate(target);
    ELSE
      PERFORM invalidate(target);
      UPDATE shares SET catalog_updated_at=clock_timestamp() WHERE id=target;
    END IF;
  END IF;
  RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;

CREATE FUNCTION wo_v2.after_reason() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM inclusion_reasons WHERE share_id=OLD.share_id) THEN
    DELETE FROM observations WHERE share_id=OLD.share_id;
    DELETE FROM adjustments WHERE share_id=OLD.share_id;
    DELETE FROM current_metrics WHERE share_id=OLD.share_id;
  END IF;
  RETURN NULL;
END $$;

DO $$ DECLARE tab text; BEGIN
  FOREACH tab IN ARRAY ARRAY['products','shares','sales_offerings','sources','external_identifiers','inclusion_reasons','observations','adjustments'] LOOP
    EXECUTE format('CREATE TRIGGER business_latch BEFORE INSERT OR UPDATE OR DELETE ON wo_v2.%I FOR EACH STATEMENT EXECUTE FUNCTION wo_v2.latch()',tab);
    EXECUTE format('CREATE TRIGGER protect_row BEFORE INSERT OR UPDATE OR DELETE ON wo_v2.%I FOR EACH ROW EXECUTE FUNCTION wo_v2.protect_row()',tab);
    EXECUTE format('CREATE TRIGGER protect_after AFTER INSERT OR UPDATE OR DELETE ON wo_v2.%I FOR EACH ROW EXECUTE FUNCTION wo_v2.protect_row()',tab);
    EXECUTE format('ALTER TABLE wo_v2.%I ENABLE ROW LEVEL SECURITY',tab);
    EXECUTE format('CREATE POLICY maintenance ON wo_v2.%I TO wo_maintainer USING (true) WITH CHECK (true)',tab);
    EXECUTE format('GRANT SELECT, DELETE ON wo_v2.%I TO wo_maintainer',tab);
    IF tab='shares' THEN
      GRANT INSERT(id,product_id,name,share_code,is_default,inception_date,lifecycle_state,operating_mode,restriction_days,collection_capability) ON wo_v2.shares TO wo_maintainer;
      GRANT UPDATE(name,share_code,is_default,inception_date,lifecycle_state,operating_mode,restriction_days,collection_capability) ON wo_v2.shares TO wo_maintainer;
    ELSIF tab='observations' THEN
      GRANT INSERT(share_id,source_id,value_date,income_period_start,income_basis,unit_nav,cumulative_nav,income_per_10k,official_yield_7d) ON wo_v2.observations TO wo_maintainer;
      GRANT UPDATE(income_period_start,income_basis,unit_nav,cumulative_nav,income_per_10k,official_yield_7d) ON wo_v2.observations TO wo_maintainer;
    ELSE EXECUTE format('GRANT INSERT, UPDATE ON wo_v2.%I TO wo_maintainer',tab);
    END IF;
  END LOOP;
END $$;
CREATE TRIGGER cleanup_last_reason AFTER DELETE ON wo_v2.inclusion_reasons FOR EACH ROW EXECUTE FUNCTION wo_v2.after_reason();
ALTER TABLE wo_v2.current_metrics ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON wo_v2.current_metrics TO wo_maintainer;
CREATE POLICY maintenance ON wo_v2.current_metrics FOR SELECT TO wo_maintainer USING (true);
GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA wo_v2 TO wo_maintainer;
RESET ROLE;
COMMIT;
