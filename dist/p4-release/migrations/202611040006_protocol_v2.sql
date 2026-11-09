BEGIN;
SET ROLE wo_owner;
-- P3: ingest protocol wo-ingest-v2. Adds maintainer-only local_import (insert-missing-only
-- replay of verified local packages). Algorithm stays wo-return-v1; legacy wo-ingest-v1 write
-- payloads are rejected with version_mismatch. Function names keep their v1 RPC labels.
CREATE OR REPLACE FUNCTION wo_v2.validate_chunk(payload jsonb,require_current_version boolean DEFAULT true) RETURNS void LANGUAGE plpgsql STABLE SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE item jsonb; field text; total integer:=0; arr text; mode text:=payload->>'mode';
BEGIN
 IF NOT keys_allowed(payload,ARRAY['protocolVersion','rulesVersion','chunkId','shareId','sourceId','expectedEpoch','mode','observations','adjustments','coverage','deletions','fieldsToClear'])
   OR NOT payload ?& ARRAY['protocolVersion','rulesVersion','chunkId','shareId','sourceId','expectedEpoch','mode','observations','adjustments','coverage','deletions','fieldsToClear']
   OR mode IS NULL OR mode NOT IN ('daily','repair','admission','local_import') THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 FOREACH field IN ARRAY ARRAY['shareId','chunkId','expectedEpoch'] LOOP
   IF jsonb_typeof(payload->field) IS DISTINCT FROM 'string' OR (payload->>field) !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 END LOOP;
 IF payload->>'protocolVersion' IS DISTINCT FROM 'wo-ingest-v2'
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
   OR (mode NOT IN ('repair') AND (jsonb_array_length(payload->'deletions')>0 OR jsonb_array_length(payload->'fieldsToClear')>0)) THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
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

CREATE OR REPLACE FUNCTION wo_rpc.wo_prepare_share_v1(payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF NOT keys_exact(payload,ARRAY['shareId','sourceId','mode']) OR payload->>'mode' IS NULL OR payload->>'mode' NOT IN ('daily','repair','admission','local_import') THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 PERFORM authorize(payload->>'sourceId',payload->>'mode');
 SELECT jsonb_build_object('protocolVersion','wo-ingest-v2','rulesVersion',jsonb_build_object('algorithmVersion','wo-return-v1','policyRevision',policy_revision()),
   'collectionEpoch',s.collection_epoch,'included',EXISTS(SELECT 1 FROM inclusion_reasons WHERE share_id=s.id),'lifecycle',s.lifecycle_state,'operatingMode',s.operating_mode,'inceptionDate',s.inception_date,
   'coverage',COALESCE((SELECT jsonb_agg(jsonb_build_object('sourceId',source_id,'first',first_date,'last',last_date)) FROM (SELECT source_id,min(value_date) first_date,max(value_date) last_date FROM observations WHERE share_id=s.id GROUP BY source_id) coverage),'[]'::jsonb),
   'runtimePolicy',jsonb_build_object('budgets',policy()->'budgets','source',source_config(payload->>'sourceId')))
 INTO result FROM shares s WHERE s.id=(payload->>'shareId')::uuid;
 IF result IS NULL THEN RAISE EXCEPTION 'not_found' USING ERRCODE='WO404'; END IF;
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION wo_rpc.wo_ingest_chunk_v1(payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE target uuid; src text:=payload->>'sourceId'; state shares%ROWTYPE; item jsonb; affected integer; changed boolean:=false; field_name text; table_name text;
 old_proof date; new_proof date; row_date date; after_epoch uuid; accepted integer; mode text:=payload->>'mode';
 existing observations%ROWTYPE; existing_adjustment adjustments%ROWTYPE; conflict_field text;
BEGIN
 PERFORM authorize(src,mode);
 PERFORM validate_chunk(payload);
 PERFORM pg_advisory_xact_lock(1464819506,1);
 PERFORM validate_chunk(payload);
 target:=(payload->>'shareId')::uuid;
 SELECT * INTO state FROM shares WHERE id=target FOR UPDATE;
 IF state.id IS NULL THEN RAISE EXCEPTION 'not_found' USING ERRCODE='WO404'; END IF;
 IF state.collection_epoch IS DISTINCT FROM (payload->>'expectedEpoch')::uuid THEN RAISE EXCEPTION 'stale_epoch' USING ERRCODE='WO004'; END IF;
 IF NOT EXISTS(SELECT 1 FROM inclusion_reasons WHERE share_id=target) THEN RAISE EXCEPTION 'not_included' USING ERRCODE='WO002'; END IF;
 IF state.lifecycle_state='ended' AND mode IN ('daily','local_import') THEN RAISE EXCEPTION 'ended' USING ERRCODE='WO003'; END IF;
 IF mode='daily' AND state.collection_capability<>'available' THEN RAISE EXCEPTION 'source_forbidden' USING ERRCODE='WO005'; END IF;
 IF mode='local_import' THEN
   FOR item IN SELECT value FROM jsonb_array_elements(payload->'observations') LOOP
     SELECT * INTO existing FROM observations WHERE share_id=target AND source_id=src AND value_date=(item->>'valueDate')::date;
     IF existing.value_date IS NULL THEN
       INSERT INTO observations(share_id,source_id,value_date,income_period_start,income_basis,unit_nav,cumulative_nav,income_per_10k,official_yield_7d)
       VALUES(target,src,(item->>'valueDate')::date,(item->>'incomePeriodStart')::date,item->>'incomeBasis',(item->>'unitNav')::numeric,(item->>'cumulativeNav')::numeric,(item->>'incomePer10k')::numeric,(item->>'officialYield7d')::numeric);
       changed:=true;
     ELSIF existing.income_period_start IS DISTINCT FROM (item->>'incomePeriodStart')::date
       OR existing.income_basis IS DISTINCT FROM item->>'incomeBasis'
       OR existing.unit_nav IS DISTINCT FROM (item->>'unitNav')::numeric
       OR existing.cumulative_nav IS DISTINCT FROM (item->>'cumulativeNav')::numeric
       OR existing.income_per_10k IS DISTINCT FROM (item->>'incomePer10k')::numeric
       OR existing.official_yield_7d IS DISTINCT FROM (item->>'officialYield7d')::numeric THEN
       conflict_field:=CASE WHEN existing.income_period_start IS DISTINCT FROM (item->>'incomePeriodStart')::date THEN 'incomePeriodStart'
         WHEN existing.income_basis IS DISTINCT FROM item->>'incomeBasis' THEN 'incomeBasis'
         WHEN existing.unit_nav IS DISTINCT FROM (item->>'unitNav')::numeric THEN 'unitNav'
         WHEN existing.cumulative_nav IS DISTINCT FROM (item->>'cumulativeNav')::numeric THEN 'cumulativeNav'
         WHEN existing.income_per_10k IS DISTINCT FROM (item->>'incomePer10k')::numeric THEN 'incomePer10k'
         ELSE 'officialYield7d' END;
       RAISE EXCEPTION 'local_conflict:%:%',conflict_field,item->>'valueDate' USING ERRCODE='WO009';
     END IF;
   END LOOP;
   FOR item IN SELECT value FROM jsonb_array_elements(payload->'adjustments') LOOP
     SELECT * INTO existing_adjustment FROM adjustments WHERE share_id=target AND source_id=src AND effective_date=(item->>'effectiveDate')::date;
     IF existing_adjustment.effective_date IS NULL THEN
       INSERT INTO adjustments VALUES(target,src,(item->>'effectiveDate')::date,item->>'eventType',(item->>'cashPerUnit')::numeric,(item->>'splitFactor')::numeric);
       changed:=true;
     ELSIF existing_adjustment.event_type IS DISTINCT FROM item->>'eventType'
       OR existing_adjustment.cash_per_unit IS DISTINCT FROM (item->>'cashPerUnit')::numeric
       OR existing_adjustment.split_factor IS DISTINCT FROM (item->>'splitFactor')::numeric THEN
       RAISE EXCEPTION 'local_conflict:adjustment:%',item->>'effectiveDate' USING ERRCODE='WO009';
     END IF;
   END LOOP;
 ELSE
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
 END IF;
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

CREATE OR REPLACE FUNCTION wo_rpc.wo_apply_policy_v1(canonical text,revision text,expected_revision text,overwrite_drift boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE doc jsonb:=canonical::jsonb; before_policy jsonb; src jsonb; pri jsonb; item record; invalidate_all boolean; drift boolean; field text; val jsonb;
BEGIN
 IF NOT is_maintainer() THEN RAISE EXCEPTION 'source_forbidden' USING ERRCODE='WO005'; END IF;
 FOREACH field IN ARRAY ARRAY['hot.months','catalog.maxRestrictionDays','history.backfillMonths','history.retentionMonths','budgets.rows','budgets.bytes','budgets.softMs','budgets.hardMs'] LOOP
   val:=doc #> string_to_array(field,'.');
   IF jsonb_typeof(val) IS DISTINCT FROM 'number' OR (val #>> '{}')::numeric IS DISTINCT FROM trunc((val #>> '{}')::numeric) THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 END LOOP;
 IF octet_length(canonical)*4/3+1024>262144 OR encode(sha256(convert_to(canonical,'UTF8')),'hex') IS DISTINCT FROM revision
   OR NOT keys_exact(doc,ARRAY['protocolVersion','algorithmVersion','hot','catalog','history','budgets','page','sources'])
   OR doc->>'protocolVersion' IS DISTINCT FROM 'wo-ingest-v2' OR doc->>'algorithmVersion' IS DISTINCT FROM 'wo-return-v1'
   OR NOT keys_exact(doc->'hot',ARRAY['months','threshold','newShares'])
   OR NOT keys_exact(doc->'catalog',ARRAY['currency','isPublic','maxRestrictionDays','includeCash'])
   OR NOT keys_exact(doc->'history',ARRAY['backfillMonths','retentionMonths'])
   OR NOT keys_exact(doc->'budgets',ARRAY['rows','bytes','softMs','hardMs'])
   OR NOT keys_allowed(doc->'page',ARRAY['defaultSize','allowedSizes'])
   OR doc->'page' IS DISTINCT FROM '{"defaultSize":50,"allowedSizes":[20,50,100]}'::jsonb
   OR doc->'catalog'->>'currency' IS DISTINCT FROM 'CNY' OR doc->'catalog'->'isPublic' IS DISTINCT FROM 'true'::jsonb
   OR (doc->'catalog'->>'maxRestrictionDays')::integer NOT BETWEEN 0 AND 31
   OR jsonb_typeof(doc->'catalog'->'includeCash') IS DISTINCT FROM 'boolean'
   OR (doc->'hot'->>'months')::integer NOT BETWEEN 1 AND 6 OR NOT valid_decimal(doc->'hot'->'threshold') OR (doc->'hot'->>'threshold')::numeric<0
   OR doc->'hot'->'newShares' IS DISTINCT FROM 'true'::jsonb
   OR (doc->'history'->>'retentionMonths')::integer NOT BETWEEN 3 AND 24
   OR (doc->'history'->>'backfillMonths')::integer NOT BETWEEN 3 AND 24
   OR (doc->'hot'->>'months')::integer>(doc->'history'->>'retentionMonths')::integer
   OR (doc->'budgets'->>'rows')::integer NOT BETWEEN 1 AND 200 OR (doc->'budgets'->>'bytes')::integer NOT BETWEEN 1024 AND 262144
   OR (doc->'budgets'->>'softMs')::integer NOT BETWEEN 1 AND 90000 OR doc->'budgets'->>'hardMs' IS DISTINCT FROM '100000'
   OR jsonb_typeof(doc->'sources') IS DISTINCT FROM 'array' OR jsonb_array_length(doc->'sources')>100 THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 FOR src IN SELECT value FROM jsonb_array_elements(doc->'sources') LOOP
   FOREACH field IN ARRAY ARRAY['id','name','kind','incomeDenomination'] LOOP
     IF jsonb_typeof(src->field) IS DISTINCT FROM 'string' THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
   END LOOP;
   IF jsonb_typeof(src->'priority') IS DISTINCT FROM 'number' OR jsonb_typeof(src->'calendar'->'lagDays') IS DISTINCT FROM 'number'
     OR jsonb_typeof(src->'calendar'->'kind') IS DISTINCT FROM 'string' OR jsonb_typeof(src->'calendar'->'cutoffTime') IS DISTINCT FROM 'string'
     OR (src->'stableUnitPrice' IS DISTINCT FROM 'null'::jsonb AND NOT valid_decimal(src->'stableUnitPrice',true)) THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
   IF NOT keys_exact(src,ARRAY['id','name','kind','priority','principals','calendar','incomeDenomination','stableUnitPrice'])
     OR src->>'id' !~ '^[a-z][a-z0-9_-]{0,62}$' OR src->>'kind' NOT IN ('channel','manager') OR length(src->>'name') NOT BETWEEN 1 AND 200
     OR (src->>'priority')::integer NOT BETWEEN 0 AND 100000 OR jsonb_typeof(src->'principals') IS DISTINCT FROM 'array' OR jsonb_array_length(src->'principals') NOT BETWEEN 1 AND 16
     OR NOT keys_exact(src->'calendar',ARRAY['kind','closedDates','extraDates','lagDays','cutoffTime']) OR src->'calendar'->>'kind' NOT IN ('daily','weekdays','explicit')
     OR src->'calendar'->>'cutoffTime' !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     OR jsonb_typeof(src->'calendar'->'closedDates') IS DISTINCT FROM 'array' OR jsonb_typeof(src->'calendar'->'extraDates') IS DISTINCT FROM 'array'
     OR (src->'calendar'->>'lagDays')::integer NOT BETWEEN 0 AND 14 OR src->>'incomeDenomination' NOT IN ('per_10000_principal','per_10000_units','unknown')
     OR (src->>'incomeDenomination')='per_10000_units' AND NOT valid_decimal(src->'stableUnitPrice',true) THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
   IF jsonb_array_length(src->'calendar'->'closedDates')>1500 OR jsonb_array_length(src->'calendar'->'extraDates')>1500
     OR EXISTS(SELECT 1 FROM jsonb_array_elements((src->'calendar'->'closedDates')||(src->'calendar'->'extraDates')) entry WHERE jsonb_typeof(entry)<>'string' OR NOT valid_date(entry #>> '{}')) THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
   FOR pri IN SELECT value FROM jsonb_array_elements(src->'principals') LOOP
     IF (pri #>> '{}') IN ('wo_owner','wo_maintainer','wo_collector','wo_authenticator','wo_reader','wo_anonymous') OR NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=pri #>> '{}') OR NOT pg_has_role(pri #>> '{}','wo_collector','member') THEN RAISE EXCEPTION 'source_forbidden' USING ERRCODE='WO005'; END IF;
   END LOOP;
 END LOOP;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(doc->'sources') s GROUP BY s->>'id' HAVING count(*)>1)
   OR EXISTS(SELECT 1 FROM jsonb_array_elements(doc->'sources') s CROSS JOIN LATERAL jsonb_array_elements(s->'principals') p GROUP BY p HAVING count(*)>1) THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 PERFORM pg_advisory_xact_lock(1464819506,1);
 IF policy_revision() IS DISTINCT FROM expected_revision THEN RAISE EXCEPTION 'version_mismatch' USING ERRCODE='WO006'; END IF;
 before_policy:=policy();
 SELECT EXISTS(
   SELECT 1 FROM sources actual FULL JOIN jsonb_array_elements(COALESCE(before_policy->'sources','[]')) prior ON actual.id=prior->>'id'
   WHERE actual.id IS NULL OR prior IS NULL OR actual.name IS DISTINCT FROM prior->>'name' OR actual.kind IS DISTINCT FROM prior->>'kind' OR actual.priority IS DISTINCT FROM (prior->>'priority')::integer
 ) INTO drift;
 IF drift AND NOT overwrite_drift THEN RAISE EXCEPTION 'policy_drift' USING ERRCODE='WO007'; END IF;
 IF EXISTS(SELECT 1 FROM sources WHERE NOT EXISTS(SELECT 1 FROM jsonb_array_elements(doc->'sources') s WHERE s->>'id'=sources.id)) THEN RAISE EXCEPTION 'source_removal_requires_migration' USING ERRCODE='WO001'; END IF;
 invalidate_all:=(before_policy->'sources') IS DISTINCT FROM (doc->'sources');
 EXECUTE format('CREATE OR REPLACE FUNCTION wo_v2.policy() RETURNS jsonb LANGUAGE sql STABLE SET search_path=pg_catalog,wo_v2,pg_temp AS %L','SELECT '||quote_literal(doc::text)||'::jsonb');
 EXECUTE format('CREATE OR REPLACE FUNCTION wo_v2.policy_revision() RETURNS text LANGUAGE sql STABLE SET search_path=pg_catalog,wo_v2,pg_temp AS %L','SELECT '||quote_literal(revision)||'::text');
 FOR src IN SELECT value FROM jsonb_array_elements(doc->'sources') LOOP
   INSERT INTO sources VALUES(src->>'id',src->>'name',src->>'kind',(src->>'priority')::integer)
   ON CONFLICT(id) DO UPDATE SET name=excluded.name,kind=excluded.kind,priority=excluded.priority
   WHERE (sources.name,sources.kind,sources.priority) IS DISTINCT FROM (excluded.name,excluded.kind,excluded.priority);
 END LOOP;
 IF invalidate_all THEN FOR item IN SELECT id FROM shares ORDER BY id LOOP PERFORM invalidate(item.id); END LOOP; END IF;
 RETURN jsonb_build_object('revision',revision,'invalidateMetrics',invalidate_all,'requiresExplicitScopeAction',before_policy IS NOT NULL AND (before_policy->'catalog' IS DISTINCT FROM doc->'catalog' OR before_policy->'history' IS DISTINCT FROM doc->'history'));
END $$;

CREATE OR REPLACE FUNCTION wo_rpc.wo_public_metadata_v1() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
BEGIN
 IF policy() IS NULL THEN RAISE EXCEPTION 'unavailable' USING ERRCODE='WO503'; END IF;
 RETURN jsonb_build_object('protocolVersion','wo-ingest-v2','algorithmVersion','wo-return-v1','policyRevision',policy_revision(),'hot',policy()->'hot','page',policy()->'page','metricCodes',metric_codes());
END $$;
RESET ROLE;
COMMIT;
