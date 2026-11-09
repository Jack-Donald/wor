BEGIN;
SET ROLE wo_owner;
CREATE FUNCTION wo_rpc.wo_apply_policy_v1(canonical text,revision text,expected_revision text,overwrite_drift boolean DEFAULT false)
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
   OR doc->>'protocolVersion' IS DISTINCT FROM 'wo-ingest-v1' OR doc->>'algorithmVersion' IS DISTINCT FROM 'wo-return-v1'
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
     OR (src->>'incomeDenomination'='per_10000_units' AND NOT valid_decimal(src->'stableUnitPrice',true)) THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
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

CREATE FUNCTION wo_rpc.wo_public_metadata_v1() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
BEGIN
 IF policy() IS NULL THEN RAISE EXCEPTION 'unavailable' USING ERRCODE='WO503'; END IF;
 RETURN jsonb_build_object('protocolVersion','wo-ingest-v1','algorithmVersion','wo-return-v1','policyRevision',policy_revision(),'hot',policy()->'hot','page',policy()->'page','metricCodes',metric_codes());
END $$;

CREATE FUNCTION wo_rpc.wo_apply_policy_v1(payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
BEGIN
 IF NOT keys_exact(payload,ARRAY['canonical','revision','expectedRevision','overwriteDrift'])
   OR jsonb_typeof(payload->'canonical') IS DISTINCT FROM 'string'
   OR jsonb_typeof(payload->'overwriteDrift') IS DISTINCT FROM 'boolean'
   OR octet_length(payload::text)*4/3+1024>262144 THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 RETURN wo_rpc.wo_apply_policy_v1(payload->>'canonical',payload->>'revision',payload->>'expectedRevision',(payload->>'overwriteDrift')::boolean);
END $$;

CREATE FUNCTION wo_v2.hot_status(target uuid,evaluation_date date) RETURNS text LANGUAGE plpgsql STABLE SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE src record; point record; s date; e date; lower_date date; inception date; mode text; result jsonb; complete boolean:=false; threshold numeric;
BEGIN
 SELECT inception_date,operating_mode INTO inception,mode FROM shares WHERE id=target;
 lower_date:=(evaluation_date-make_interval(months=>(policy()->'hot'->>'months')::integer))::date;
 threshold:=(policy()->'hot'->>'threshold')::numeric;
 FOR src IN SELECT id FROM sources ORDER BY kind,priority,id LOOP
   FOR point IN SELECT *,lag(value_date) OVER(ORDER BY value_date) previous_date FROM observations WHERE share_id=target AND source_id=src.id AND value_date<=evaluation_date ORDER BY value_date LOOP
     IF point.value_date<=lower_date THEN CONTINUE; END IF;
     s:=CASE WHEN mode='cash_management' THEN point.income_period_start-1 ELSE point.previous_date END;
     IF s IS NULL THEN CONTINUE; END IF;
     result:=interval_value(target,src.id,s,point.value_date,evaluation_date);
     IF result->>'reason' IS NULL AND (result->>'numerator')::numeric*10000 >= threshold*(result->>'denominator')::numeric*((result->>'endDate')::date-(result->>'startDate')::date) THEN RETURN 'qualified'; END IF;
   END LOOP;
   s:=GREATEST(lower_date,inception);
   IF inception IS NULL THEN CONTINUE; END IF;
   e:=due_date(src.id,evaluation_date);
   result:=interval_value(target,src.id,s,e,evaluation_date);
   IF result->>'reason' IS NULL THEN complete:=true; END IF;
 END LOOP;
 RETURN CASE WHEN complete THEN 'unqualified' ELSE 'indeterminate' END;
END $$;

CREATE FUNCTION wo_rpc.wo_apply_evaluation_v1(payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE chunk jsonb:=payload->'chunk'; target uuid:=(chunk->>'shareId')::uuid; state shares%ROWTYPE; status text; result jsonb; evaluation_date date;
BEGIN
 IF NOT is_maintainer() THEN RAISE EXCEPTION 'source_forbidden' USING ERRCODE='WO005'; END IF;
 IF NOT keys_exact(payload,ARRAY['chunk','evaluationDate','conclusion']) OR payload->>'conclusion' IS NULL OR payload->>'conclusion' NOT IN ('qualified','unqualified','indeterminate') OR NOT valid_date(payload->>'evaluationDate') OR chunk->>'mode' IS DISTINCT FROM 'admission' THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 PERFORM validate_chunk(chunk);
 evaluation_date:=(payload->>'evaluationDate')::date;
 IF evaluation_date IS DISTINCT FROM business_today() THEN RAISE EXCEPTION 'evidence_incomplete' USING ERRCODE='WO008'; END IF;
 PERFORM pg_advisory_xact_lock(1464819506,1);
 SELECT * INTO state FROM shares WHERE id=target FOR UPDATE;
 IF state.collection_epoch IS DISTINCT FROM (chunk->>'expectedEpoch')::uuid THEN RAISE EXCEPTION 'stale_epoch' USING ERRCODE='WO004'; END IF;
 IF payload->>'conclusion'='indeterminate' THEN RETURN jsonb_build_object('conclusion','indeterminate','nextEpoch',state.collection_epoch); END IF;
 IF state.collection_capability<>'available' OR state.lifecycle_state='ended' THEN RAISE EXCEPTION 'source_forbidden' USING ERRCODE='WO005'; END IF;
 INSERT INTO inclusion_reasons VALUES(target,'hot') ON CONFLICT DO NOTHING;
 chunk:=jsonb_set(chunk,'{expectedEpoch}',(SELECT to_jsonb(collection_epoch) FROM shares WHERE id=target));
 result:=wo_rpc.wo_ingest_chunk_v1(chunk);
 status:=hot_status(target,evaluation_date);
 IF status IS DISTINCT FROM payload->>'conclusion' THEN RAISE EXCEPTION 'evidence_incomplete' USING ERRCODE='WO008'; END IF;
 IF status='unqualified' THEN DELETE FROM inclusion_reasons WHERE share_id=target AND reason_type='hot'; END IF;
 RETURN jsonb_build_object('conclusion',status,'nextEpoch',(SELECT collection_epoch FROM shares WHERE id=target));
END $$;

GRANT EXECUTE ON FUNCTION wo_rpc.wo_apply_policy_v1(text,text,text,boolean),wo_rpc.wo_apply_policy_v1(jsonb),wo_rpc.wo_apply_evaluation_v1(jsonb) TO wo_maintainer;
GRANT EXECUTE ON FUNCTION wo_rpc.wo_public_metadata_v1() TO wo_reader,wo_collector,wo_maintainer;
RESET ROLE;
COMMIT;
