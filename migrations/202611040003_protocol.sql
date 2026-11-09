BEGIN;
SET ROLE wo_owner;
CREATE FUNCTION wo_v2.principal() RETURNS text LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT CASE WHEN session_user='wo_authenticator' THEN current_setting('role',true) ELSE session_user::text END
$$;
CREATE FUNCTION wo_v2.is_maintainer() RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,wo_v2,pg_temp AS $$
 SELECT pg_has_role(principal(),'wo_maintainer','member')
$$;
CREATE FUNCTION wo_v2.authorize(src text,mode text) RETURNS void LANGUAGE plpgsql STABLE SET search_path=pg_catalog,wo_v2,pg_temp AS $$
BEGIN
 IF NOT is_maintainer() AND (mode<>'daily' OR NOT COALESCE((source_config(src)->'principals') ? principal(),false)) THEN
   RAISE EXCEPTION 'source_forbidden' USING ERRCODE='WO005';
 END IF;
 IF source_config(src) IS NULL THEN RAISE EXCEPTION 'source_forbidden' USING ERRCODE='WO005'; END IF;
END $$;
CREATE FUNCTION wo_v2.keys_allowed(obj jsonb,allowed text[]) RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 SELECT CASE WHEN jsonb_typeof(obj)='object' THEN NOT EXISTS(SELECT 1 FROM jsonb_object_keys(obj) key WHERE NOT key=ANY(allowed)) ELSE false END
$$;
CREATE FUNCTION wo_v2.keys_exact(obj jsonb,required text[]) RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,wo_v2,pg_temp AS $$
 SELECT COALESCE(keys_allowed(obj,required) AND obj ?& required,false)
$$;
CREATE FUNCTION wo_v2.valid_date(value text) RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog AS $$
BEGIN RETURN COALESCE(value ~ '^\d{4}-\d{2}-\d{2}$' AND value::date BETWEEN '1900-01-01' AND '2199-12-31',false); EXCEPTION WHEN OTHERS THEN RETURN false; END $$;
CREATE FUNCTION wo_v2.valid_decimal(value jsonb,positive boolean DEFAULT false) RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog AS $$
BEGIN RETURN COALESCE(jsonb_typeof(value)='string' AND value #>> '{}' ~ '^-?(0|[1-9][0-9]{0,17})(\.[0-9]{1,36})?$' AND (NOT positive OR (value #>> '{}')::numeric>0),false); EXCEPTION WHEN OTHERS THEN RETURN false; END $$;

CREATE FUNCTION wo_v2.validate_chunk(payload jsonb,require_current_version boolean DEFAULT true) RETURNS void LANGUAGE plpgsql STABLE SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE item jsonb; field text; total integer:=0; arr text; mode text:=payload->>'mode';
BEGIN
 IF NOT keys_allowed(payload,ARRAY['protocolVersion','rulesVersion','chunkId','shareId','sourceId','expectedEpoch','mode','observations','adjustments','coverage','deletions','fieldsToClear'])
   OR NOT payload ?& ARRAY['protocolVersion','rulesVersion','chunkId','shareId','sourceId','expectedEpoch','mode','observations','adjustments','coverage','deletions','fieldsToClear']
   OR mode IS NULL OR mode NOT IN ('daily','repair','admission') THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 FOREACH field IN ARRAY ARRAY['shareId','chunkId','expectedEpoch'] LOOP
   IF jsonb_typeof(payload->field) IS DISTINCT FROM 'string' OR (payload->>field) !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 END LOOP;
 IF payload->>'protocolVersion' IS DISTINCT FROM 'wo-ingest-v1'
   OR NOT keys_allowed(payload->'rulesVersion',ARRAY['algorithmVersion','policyRevision'])
   OR payload->'rulesVersion'->>'algorithmVersion' IS DISTINCT FROM 'wo-return-v1'
   OR (require_current_version AND payload->'rulesVersion'->>'policyRevision' IS DISTINCT FROM policy_revision()) THEN RAISE EXCEPTION 'version_mismatch' USING ERRCODE='WO006'; END IF;
 PERFORM (payload->>'shareId')::uuid,(payload->>'chunkId')::uuid,(payload->>'expectedEpoch')::uuid;
 FOREACH arr IN ARRAY ARRAY['observations','adjustments','coverage','deletions','fieldsToClear'] LOOP
   IF jsonb_typeof(payload->arr)<>'array' THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
   total:=total+jsonb_array_length(payload->arr);
 END LOOP;
 IF total>(CASE WHEN require_current_version THEN LEAST(200,(policy()->'budgets'->>'rows')::integer) ELSE 200 END)
   OR 4*ceil((octet_length(payload::text)+2)::numeric/3)>(CASE WHEN require_current_version THEN LEAST(262144,(policy()->'budgets'->>'bytes')::integer) ELSE 262144 END)
   OR (mode<>'repair' AND (jsonb_array_length(payload->'deletions')>0 OR jsonb_array_length(payload->'fieldsToClear')>0)) THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(payload->'observations') LOOP
   IF NOT keys_allowed(item,ARRAY['valueDate','incomePeriodStart','incomeBasis','unitNav','cumulativeNav','incomePer10k','officialYield7d']) OR NOT valid_date(item->>'valueDate')
     OR NOT (item ?| ARRAY['unitNav','cumulativeNav','incomePer10k','officialYield7d']) THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
   FOREACH field IN ARRAY ARRAY['unitNav','cumulativeNav','incomePer10k','officialYield7d'] LOOP
     IF item ? field AND NOT valid_decimal(item->field,field='unitNav') THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
   END LOOP;
   IF item ? 'incomePeriodStart' AND (NOT valid_date(item->>'incomePeriodStart') OR item->>'incomePeriodStart'>item->>'valueDate') THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
   IF item ? 'incomeBasis' AND (item->>'incomeBasis' IS NULL OR item->>'incomeBasis' NOT IN ('daily','period_total','daily_average')) THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
   IF item ? 'cumulativeNav' AND (item->>'cumulativeNav')::numeric<0 THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
   IF item ? 'incomePer10k' AND (NOT valid_date(item->>'incomePeriodStart') OR item->>'incomeBasis' NOT IN ('daily','period_total','daily_average')) THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(payload->'observations') entry GROUP BY entry->>'valueDate' HAVING count(*)>1) THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(payload->'adjustments') LOOP
   IF NOT keys_exact(item,ARRAY['effectiveDate','eventType','cashPerUnit','splitFactor']) OR NOT valid_date(item->>'effectiveDate')
     OR item->>'eventType' IS NULL OR item->>'eventType' NOT IN ('cash_dividend','share_split','combined') OR NOT valid_decimal(item->'cashPerUnit') OR (item->>'cashPerUnit')::numeric<0 OR NOT valid_decimal(item->'splitFactor',true) THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(payload->'adjustments') entry GROUP BY entry->>'effectiveDate' HAVING count(*)>1) THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(payload->'coverage') LOOP
   IF NOT keys_exact(item,ARRAY['from','through']) OR NOT valid_date(item->>'from') OR NOT valid_date(item->>'through') OR item->>'from'>=item->>'through' THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 END LOOP;
 FOR item IN SELECT value FROM jsonb_array_elements(payload->'deletions') LOOP
   IF NOT keys_exact(item,ARRAY['kind','date']) OR item->>'kind' IS NULL OR item->>'kind' NOT IN ('observation','adjustment') OR NOT valid_date(item->>'date') THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 END LOOP;
 FOR item IN SELECT value FROM jsonb_array_elements(payload->'fieldsToClear') LOOP
   IF NOT keys_exact(item,ARRAY['field','date']) OR item->>'field' IS NULL OR item->>'field' NOT IN ('unitNav','cumulativeNav','incomePer10k','officialYield7d','incomePeriodStart','incomeBasis') OR NOT valid_date(item->>'date') THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 END LOOP;
END $$;

CREATE FUNCTION wo_rpc.wo_prepare_share_v1(payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF NOT keys_exact(payload,ARRAY['shareId','sourceId','mode']) OR payload->>'mode' IS NULL OR payload->>'mode' NOT IN ('daily','repair','admission') THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 PERFORM authorize(payload->>'sourceId',payload->>'mode');
 SELECT jsonb_build_object('protocolVersion','wo-ingest-v1','rulesVersion',jsonb_build_object('algorithmVersion','wo-return-v1','policyRevision',policy_revision()),
   'collectionEpoch',s.collection_epoch,'included',EXISTS(SELECT 1 FROM inclusion_reasons WHERE share_id=s.id),'lifecycle',s.lifecycle_state,'operatingMode',s.operating_mode,'inceptionDate',s.inception_date,
   'coverage',COALESCE((SELECT jsonb_agg(jsonb_build_object('sourceId',source_id,'first',first_date,'last',last_date)) FROM (SELECT source_id,min(value_date) first_date,max(value_date) last_date FROM observations WHERE share_id=s.id GROUP BY source_id) coverage),'[]'::jsonb),
   'runtimePolicy',jsonb_build_object('budgets',policy()->'budgets','source',source_config(payload->>'sourceId')))
 INTO result FROM shares s WHERE s.id=(payload->>'shareId')::uuid;
 IF result IS NULL THEN RAISE EXCEPTION 'not_found' USING ERRCODE='WO404'; END IF;
 RETURN result;
END $$;

CREATE FUNCTION wo_rpc.wo_ingest_chunk_v1(payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE target uuid; src text:=payload->>'sourceId'; state shares%ROWTYPE; item jsonb; affected integer; changed boolean:=false; field_name text; table_name text;
 old_proof date; new_proof date; row_date date; after_epoch uuid; accepted integer;
BEGIN
 PERFORM authorize(src,payload->>'mode');
 PERFORM validate_chunk(payload);
 PERFORM pg_advisory_xact_lock(1464819506,1);
 PERFORM validate_chunk(payload);
 target:=(payload->>'shareId')::uuid;
 SELECT * INTO state FROM shares WHERE id=target FOR UPDATE;
 IF state.id IS NULL THEN RAISE EXCEPTION 'not_found' USING ERRCODE='WO404'; END IF;
 IF state.collection_epoch IS DISTINCT FROM (payload->>'expectedEpoch')::uuid THEN RAISE EXCEPTION 'stale_epoch' USING ERRCODE='WO004'; END IF;
 IF NOT EXISTS(SELECT 1 FROM inclusion_reasons WHERE share_id=target) THEN RAISE EXCEPTION 'not_included' USING ERRCODE='WO002'; END IF;
 IF state.lifecycle_state='ended' AND payload->>'mode'='daily' THEN RAISE EXCEPTION 'ended' USING ERRCODE='WO003'; END IF;
 IF payload->>'mode'='daily' AND state.collection_capability<>'available' THEN RAISE EXCEPTION 'source_forbidden' USING ERRCODE='WO005'; END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(payload->'deletions') LOOP
   table_name:=CASE WHEN item->>'kind'='observation' THEN 'observations' ELSE 'adjustments' END;
   field_name:=CASE WHEN item->>'kind'='observation' THEN 'value_date' ELSE 'effective_date' END;
   EXECUTE format('DELETE FROM wo_v2.%I WHERE share_id=$1 AND source_id=$2 AND %I=$3',table_name,field_name) USING target,src,(item->>'date')::date;
   GET DIAGNOSTICS affected=ROW_COUNT; changed:=changed OR affected>0;
 END LOOP;
 FOR item IN SELECT value FROM jsonb_array_elements(payload->'fieldsToClear') LOOP
   field_name:=CASE item->>'field' WHEN 'unitNav' THEN 'unit_nav' WHEN 'cumulativeNav' THEN 'cumulative_nav' WHEN 'incomePer10k' THEN 'income_per_10k' WHEN 'officialYield7d' THEN 'official_yield_7d' WHEN 'incomePeriodStart' THEN 'income_period_start' WHEN 'incomeBasis' THEN 'income_basis' END;
   EXECUTE format('UPDATE wo_v2.observations SET %I=NULL WHERE share_id=$1 AND source_id=$2 AND value_date=$3 AND %I IS NOT NULL',field_name,field_name) USING target,src,(item->>'date')::date;
   GET DIAGNOSTICS affected=ROW_COUNT; changed:=changed OR affected>0;
 END LOOP;
 FOR item IN SELECT value FROM jsonb_array_elements(payload->'observations') LOOP
   INSERT INTO observations(share_id,source_id,value_date,income_period_start,income_basis,unit_nav,cumulative_nav,income_per_10k,official_yield_7d)
   VALUES(target,src,(item->>'valueDate')::date,(item->>'incomePeriodStart')::date,item->>'incomeBasis',(item->>'unitNav')::numeric,(item->>'cumulativeNav')::numeric,(item->>'incomePer10k')::numeric,(item->>'officialYield7d')::numeric)
   ON CONFLICT(share_id,source_id,value_date) DO UPDATE SET
     income_period_start=CASE WHEN item ? 'incomePeriodStart' THEN excluded.income_period_start ELSE observations.income_period_start END,
     income_basis=CASE WHEN item ? 'incomeBasis' THEN excluded.income_basis ELSE observations.income_basis END,
     unit_nav=COALESCE(excluded.unit_nav,observations.unit_nav),cumulative_nav=COALESCE(excluded.cumulative_nav,observations.cumulative_nav),income_per_10k=COALESCE(excluded.income_per_10k,observations.income_per_10k),official_yield_7d=COALESCE(excluded.official_yield_7d,observations.official_yield_7d)
   WHERE (observations.income_period_start,observations.income_basis,observations.unit_nav,observations.cumulative_nav,observations.income_per_10k,observations.official_yield_7d) IS DISTINCT FROM
     (CASE WHEN item ? 'incomePeriodStart' THEN excluded.income_period_start ELSE observations.income_period_start END,CASE WHEN item ? 'incomeBasis' THEN excluded.income_basis ELSE observations.income_basis END,COALESCE(excluded.unit_nav,observations.unit_nav),COALESCE(excluded.cumulative_nav,observations.cumulative_nav),COALESCE(excluded.income_per_10k,observations.income_per_10k),COALESCE(excluded.official_yield_7d,observations.official_yield_7d));
   GET DIAGNOSTICS affected=ROW_COUNT; changed:=changed OR affected>0;
 END LOOP;
 FOR item IN SELECT value FROM jsonb_array_elements(payload->'adjustments') LOOP
   INSERT INTO adjustments VALUES(target,src,(item->>'effectiveDate')::date,item->>'eventType',(item->>'cashPerUnit')::numeric,(item->>'splitFactor')::numeric)
   ON CONFLICT(share_id,source_id,effective_date) DO UPDATE SET event_type=excluded.event_type,cash_per_unit=excluded.cash_per_unit,split_factor=excluded.split_factor
   WHERE (adjustments.event_type,adjustments.cash_per_unit,adjustments.split_factor) IS DISTINCT FROM (excluded.event_type,excluded.cash_per_unit,excluded.split_factor);
   GET DIAGNOSTICS affected=ROW_COUNT; changed:=changed OR affected>0;
 END LOOP;
 FOR item IN SELECT value FROM jsonb_array_elements(payload->'coverage') ORDER BY value->>'through' LOOP
   row_date:=(item->>'through')::date; new_proof:=(item->>'from')::date;
   IF state.operating_mode='cash_management' OR NOT EXISTS(SELECT 1 FROM observations WHERE share_id=target AND source_id=src AND value_date=row_date AND unit_nav IS NOT NULL) THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
   SELECT min(adjustment_verified_from) INTO old_proof FROM observations WHERE share_id=target AND source_id=src AND value_date>=new_proof AND value_date<=row_date AND adjustment_verified_from IS NOT NULL;
   new_proof:=LEAST(new_proof,old_proof);
   UPDATE observations SET adjustment_verified_from=LEAST(adjustment_verified_from,new_proof) WHERE share_id=target AND source_id=src AND value_date=row_date AND (adjustment_verified_from IS NULL OR adjustment_verified_from>new_proof);
   GET DIAGNOSTICS affected=ROW_COUNT; changed:=changed OR affected>0;
 END LOOP;
 IF changed THEN PERFORM recalculate(target,business_today()); END IF;
 SELECT collection_epoch INTO after_epoch FROM shares WHERE id=target;
 accepted:=jsonb_array_length(payload->'observations')+jsonb_array_length(payload->'adjustments')+jsonb_array_length(payload->'coverage')+jsonb_array_length(payload->'deletions')+jsonb_array_length(payload->'fieldsToClear');
 RETURN jsonb_build_object('outcome',CASE WHEN changed THEN 'applied' ELSE 'unchanged' END,'chunkId',payload->>'chunkId','nextEpoch',after_epoch,'acceptedCount',accepted,
   'unavailableMetrics',COALESCE((SELECT jsonb_agg(metric_code ORDER BY metric_code) FROM current_metrics WHERE share_id=target AND value IS NULL),'[]'::jsonb));
END $$;

CREATE FUNCTION wo_v2.chunk_present(payload jsonb) RETURNS boolean LANGUAGE plpgsql STABLE SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE item jsonb; row_json jsonb; target uuid:=(payload->>'shareId')::uuid; src text:=payload->>'sourceId'; field text; actual jsonb; date_value date;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM inclusion_reasons WHERE share_id=target) THEN RETURN false; END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(payload->'observations') LOOP
   SELECT jsonb_strip_nulls(jsonb_build_object('valueDate',value_date,'incomePeriodStart',income_period_start,'incomeBasis',income_basis,'unitNav',unit_nav::text,'cumulativeNav',cumulative_nav::text,'incomePer10k',income_per_10k::text,'officialYield7d',official_yield_7d::text)) INTO row_json FROM observations WHERE share_id=target AND source_id=src AND value_date=(item->>'valueDate')::date;
   IF row_json IS NULL THEN RETURN false; END IF;
   FOR field,actual IN SELECT key,value FROM jsonb_each(item) LOOP
     IF field IN ('unitNav','cumulativeNav','incomePer10k','officialYield7d') THEN
       IF (row_json->>field)::numeric IS DISTINCT FROM (actual #>> '{}')::numeric THEN RETURN false; END IF;
     ELSIF (row_json->field) IS DISTINCT FROM NULLIF(actual,'null'::jsonb) THEN RETURN false;
     END IF;
   END LOOP;
 END LOOP;
 FOR item IN SELECT value FROM jsonb_array_elements(payload->'adjustments') LOOP
   IF NOT EXISTS(SELECT 1 FROM adjustments WHERE share_id=target AND source_id=src AND effective_date=(item->>'effectiveDate')::date AND event_type=item->>'eventType' AND cash_per_unit=(item->>'cashPerUnit')::numeric AND split_factor=(item->>'splitFactor')::numeric) THEN RETURN false; END IF;
 END LOOP;
 FOR item IN SELECT value FROM jsonb_array_elements(payload->'coverage') LOOP
   IF NOT EXISTS(SELECT 1 FROM observations WHERE share_id=target AND source_id=src AND value_date=(item->>'through')::date AND adjustment_verified_from<=(item->>'from')::date) THEN RETURN false; END IF;
 END LOOP;
 FOR item IN SELECT value FROM jsonb_array_elements(payload->'deletions') LOOP
   date_value:=(item->>'date')::date;
   IF item->>'kind'='observation' AND EXISTS(SELECT 1 FROM observations WHERE share_id=target AND source_id=src AND value_date=date_value) THEN RETURN false; END IF;
   IF item->>'kind'='adjustment' AND EXISTS(SELECT 1 FROM adjustments WHERE share_id=target AND source_id=src AND effective_date=date_value) THEN RETURN false; END IF;
 END LOOP;
 FOR item IN SELECT value FROM jsonb_array_elements(payload->'fieldsToClear') LOOP
   field:=CASE item->>'field' WHEN 'unitNav' THEN 'unit_nav' WHEN 'cumulativeNav' THEN 'cumulative_nav' WHEN 'incomePer10k' THEN 'income_per_10k' WHEN 'officialYield7d' THEN 'official_yield_7d' WHEN 'incomePeriodStart' THEN 'income_period_start' WHEN 'incomeBasis' THEN 'income_basis' END;
   SELECT to_jsonb(o)->field INTO actual FROM observations o WHERE share_id=target AND source_id=src AND value_date=(item->>'date')::date;
   IF actual IS DISTINCT FROM 'null'::jsonb AND actual IS NOT NULL THEN RETURN false; END IF;
 END LOOP;
 RETURN true;
END $$;
CREATE FUNCTION wo_rpc.wo_reconcile_v1(payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
BEGIN
 PERFORM authorize(payload->>'sourceId',payload->>'mode');
 PERFORM validate_chunk(payload,false);
 RETURN jsonb_build_object('state',CASE WHEN chunk_present(payload) THEN 'present'
   WHEN payload->'rulesVersion'->>'policyRevision'=policy_revision() AND EXISTS(SELECT 1 FROM shares WHERE id=(payload->>'shareId')::uuid AND collection_epoch=(payload->>'expectedEpoch')::uuid) AND EXISTS(SELECT 1 FROM inclusion_reasons WHERE share_id=(payload->>'shareId')::uuid) THEN 'retryable' ELSE 'obsolete' END);
END $$;

CREATE FUNCTION wo_rpc.wo_recalculate_v1(target uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
BEGIN
 IF NOT is_maintainer() THEN RAISE EXCEPTION 'source_forbidden' USING ERRCODE='WO005'; END IF;
 PERFORM pg_advisory_xact_lock(1464819506,1); PERFORM 1 FROM shares WHERE id=target FOR UPDATE;
 PERFORM recalculate(target,business_today());
END $$;

GRANT EXECUTE ON FUNCTION wo_rpc.wo_prepare_share_v1(jsonb),wo_rpc.wo_ingest_chunk_v1(jsonb),wo_rpc.wo_reconcile_v1(jsonb) TO wo_collector,wo_maintainer;
GRANT EXECUTE ON FUNCTION wo_rpc.wo_recalculate_v1(uuid) TO wo_maintainer;
RESET ROLE;
COMMIT;
