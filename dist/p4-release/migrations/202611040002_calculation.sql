BEGIN;
SET ROLE wo_owner;
CREATE FUNCTION wo_v2.divide(n numeric,d numeric) RETURNS numeric LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog AS $$
 SELECT n::numeric(1000,100)/d::numeric(1000,100)
$$;
CREATE FUNCTION wo_v2.source_config(source_key text) RETURNS jsonb LANGUAGE sql STABLE SET search_path=pg_catalog,wo_v2,pg_temp AS $$
 SELECT item FROM jsonb_array_elements(policy()->'sources') item WHERE item->>'id'=source_key
$$;
CREATE FUNCTION wo_v2.discloses(source_key text,business_date date) RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,wo_v2,pg_temp AS $$
 SELECT CASE
 WHEN (source_config(source_key)->'calendar'->'extraDates') ? business_date::text THEN true
 WHEN (source_config(source_key)->'calendar'->'closedDates') ? business_date::text THEN false
 WHEN source_config(source_key)->'calendar'->>'kind'='daily' THEN true
 WHEN source_config(source_key)->'calendar'->>'kind'='weekdays' THEN extract(isodow FROM business_date)<6
 ELSE false END
$$;
CREATE FUNCTION wo_v2.due_date(source_key text,as_of date) RETURNS date LANGUAGE sql STABLE SET search_path=pg_catalog,wo_v2,pg_temp AS $$
 SELECT as_of-COALESCE((source_config(source_key)->'calendar'->>'lagDays')::integer,0)
   -CASE WHEN as_of=(statement_timestamp() AT TIME ZONE 'Asia/Shanghai')::date
      AND (statement_timestamp() AT TIME ZONE 'Asia/Shanghai')::time<(source_config(source_key)->'calendar'->>'cutoffTime')::time THEN 1 ELSE 0 END
$$;
CREATE FUNCTION wo_v2.interval_value(target uuid,src text,requested_start date,requested_end date,as_of date)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE s date:=requested_start; e date:=requested_end; mode text; conf jsonb; first_row observations%ROWTYPE; last_row observations%ROWTYPE;
 item record; q numeric:=1; cash numeric:=0; numerator numeric; denominator numeric; next_date date; block numeric; total numeric:=0; days integer;
 reason text; adjusted boolean:=false; pending boolean:=false;
BEGIN
 SELECT operating_mode INTO mode FROM shares WHERE id=target;
 conf:=source_config(src);
 IF conf IS NULL THEN reason:='unknown_calendar'; END IF;
 IF requested_end-requested_start>744 THEN reason:='outside_retained_history'; END IF;
 IF requested_end<=requested_start THEN reason:='insufficient_history'; END IF;
 IF reason IS NULL THEN
   WHILE NOT discloses(src,e) OR e>due_date(src,as_of) LOOP
     IF e>due_date(src,as_of) THEN pending:=true; END IF;
     e:=e-1;
     IF e<=s THEN reason:='insufficient_history'; EXIT; END IF;
   END LOOP;
 END IF;
 IF reason IS NULL AND mode='cash_management' THEN
   IF conf->>'incomeDenomination'='unknown' OR (conf->>'incomeDenomination'='per_10000_units' AND conf->>'stableUnitPrice' IS NULL) THEN reason:='unknown_income_basis'; END IF;
   SELECT * INTO first_row FROM observations WHERE share_id=target AND source_id=src AND value_date>s AND value_date<=e AND income_per_10k IS NOT NULL ORDER BY value_date LIMIT 1;
   IF first_row.value_date IS NULL THEN reason:=COALESCE(reason,'insufficient_history');
   ELSIF first_row.income_period_start IS NULL THEN reason:='unknown_income_basis';
   ELSIF first_row.income_period_start>s+1 THEN reason:='missing_disclosure';
   ELSIF first_row.income_period_start<=s THEN s:=first_row.income_period_start-1; END IF;
   next_date:=s+1;
   IF reason IS NULL THEN
     FOR item IN SELECT * FROM observations WHERE share_id=target AND source_id=src AND value_date>s AND value_date<=e AND income_per_10k IS NOT NULL ORDER BY value_date LOOP
       IF item.income_period_start IS DISTINCT FROM next_date OR item.income_basis IS NULL THEN reason:='missing_disclosure'; EXIT; END IF;
       days:=item.value_date-item.income_period_start+1;
       IF item.income_basis='daily' AND days<>1 THEN reason:='unknown_income_basis'; EXIT; END IF;
       block:=item.income_per_10k * CASE WHEN item.income_basis='daily_average' THEN days ELSE 1 END;
       total:=total+block; next_date:=item.value_date+1;
     END LOOP;
     IF reason IS NULL AND next_date<>e+1 THEN reason:='missing_disclosure'; END IF;
   END IF;
   numerator:=total;
   denominator:=10000 * CASE WHEN conf->>'incomeDenomination'='per_10000_units' THEN (conf->>'stableUnitPrice')::numeric ELSE 1 END;
 ELSIF reason IS NULL THEN
   IF NOT discloses(src,s) THEN
     SELECT * INTO first_row FROM observations WHERE share_id=target AND source_id=src AND value_date<=s AND unit_nav IS NOT NULL ORDER BY value_date DESC LIMIT 1;
     s:=first_row.value_date;
   ELSE SELECT * INTO first_row FROM observations WHERE share_id=target AND source_id=src AND value_date=s AND unit_nav IS NOT NULL;
   END IF;
   SELECT * INTO last_row FROM observations WHERE share_id=target AND source_id=src AND value_date=e AND unit_nav IS NOT NULL;
   IF first_row.value_date IS NULL THEN reason:='insufficient_history';
   ELSIF last_row.value_date IS NULL THEN reason:='missing_disclosure';
   ELSIF EXISTS(SELECT 1 FROM generate_series(s+1,e,interval '1 day') day WHERE discloses(src,day::date) AND NOT EXISTS(SELECT 1 FROM observations o WHERE o.share_id=target AND o.source_id=src AND o.value_date=day::date AND o.unit_nav IS NOT NULL)) THEN reason:='missing_disclosure';
   ELSIF NOT EXISTS(SELECT 1 FROM observations WHERE share_id=target AND source_id=src AND value_date>=e AND adjustment_verified_from<=s) THEN reason:='missing_adjustment';
   ELSE
     FOR item IN SELECT * FROM adjustments WHERE share_id=target AND source_id=src AND effective_date>s AND effective_date<=e ORDER BY effective_date LOOP
       cash:=cash+q*item.cash_per_unit; q:=q*item.split_factor;
     END LOOP;
     numerator:=q*last_row.unit_nav+cash-first_row.unit_nav;
     denominator:=first_row.unit_nav;
   END IF;
 END IF;
 adjusted:=s IS DISTINCT FROM requested_start OR e IS DISTINCT FROM requested_end;
 RETURN jsonb_build_object('value',CASE WHEN reason IS NULL THEN divide(numerator,denominator)::text END,
   'numerator',CASE WHEN reason IS NULL THEN numerator::text END,'denominator',CASE WHEN reason IS NULL THEN denominator::text END,
   'reason',reason,'startDate',COALESCE(s,requested_start),'endDate',e,'windowAdjusted',adjusted,'delayed',pending);
END $$;

CREATE FUNCTION wo_v2.metric_codes() RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
SELECT ARRAY['dailyIncomePer10k','averageIncome7d','averageIncome14d','return7d','return14d','annualized7d','annualized14d','annualized1m','annualized3m','flatDisclosureCountMonth','annualizedSinceInception']::text[]
$$;
CREATE FUNCTION wo_v2.compute_metrics(target uuid,as_of date) RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE code text; src record; share_row shares%ROWTYPE; latest observations%ROWTYPE; s date; e date; result jsonb; row_result jsonb; all_results jsonb:='[]';
 val numeric; reason text; count_flat integer; pending boolean;
BEGIN
 SELECT * INTO share_row FROM shares WHERE id=target;
 FOREACH code IN ARRAY metric_codes() LOOP
   row_result:=jsonb_build_object('metricCode',code,'value',NULL,'startDate',NULL,'endDate',NULL,'sourceId',NULL,'unavailableReason','insufficient_history','windowAdjusted',false,'delayed',false);
   FOR src IN SELECT * FROM sources ORDER BY CASE WHEN kind='channel' THEN 0 ELSE 1 END,priority,id LOOP
     SELECT * INTO latest FROM observations WHERE share_id=target AND source_id=src.id AND value_date<=as_of
       AND CASE WHEN share_row.operating_mode='cash_management' THEN income_per_10k IS NOT NULL ELSE unit_nav IS NOT NULL END ORDER BY value_date DESC LIMIT 1;
     IF latest.value_date IS NULL THEN CONTINUE; END IF;
     e:=latest.value_date; reason:=NULL;
     IF code='dailyIncomePer10k' THEN
       IF share_row.operating_mode='cash_management' THEN s:=latest.income_period_start-1;
       ELSE SELECT value_date INTO s FROM observations WHERE share_id=target AND source_id=src.id AND value_date<e AND unit_nav IS NOT NULL ORDER BY value_date DESC LIMIT 1; END IF;
     ELSIF code='flatDisclosureCountMonth' THEN
       IF share_row.operating_mode='cash_management' THEN reason:='not_applicable'; s:=NULL;
       ELSE SELECT value_date INTO s FROM observations WHERE share_id=target AND source_id=src.id AND value_date<date_trunc('month',e)::date AND unit_nav IS NOT NULL ORDER BY value_date DESC LIMIT 1; END IF;
     ELSIF code='annualizedSinceInception' THEN s:=share_row.inception_date; IF s IS NULL THEN reason:='unknown_inception_date'; END IF;
     ELSIF code IN ('annualized1m','annualized3m') THEN s:=(e-CASE WHEN code='annualized1m' THEN interval '1 month' ELSE interval '3 months' END)::date;
     ELSE s:=e-CASE WHEN code LIKE '%14d' THEN 14 ELSE 7 END;
     END IF;
     IF s IS NULL OR s>=e THEN reason:=COALESCE(reason,'insufficient_history'); END IF;
     IF reason IS NULL THEN
       result:=interval_value(target,src.id,s,e,as_of); reason:=result->>'reason';
       IF reason IS NULL THEN
         val:=(result->>'value')::numeric;
         IF code='flatDisclosureCountMonth' THEN
           SELECT count(*) INTO count_flat FROM (
             SELECT value_date,unit_nav,lag(value_date) OVER(ORDER BY value_date) previous_date,lag(unit_nav) OVER(ORDER BY value_date) previous_nav
             FROM observations WHERE share_id=target AND source_id=src.id AND value_date BETWEEN s AND e AND unit_nav IS NOT NULL
           ) points WHERE date_trunc('month',value_date)=date_trunc('month',e) AND unit_nav=previous_nav
             AND NOT EXISTS(SELECT 1 FROM adjustments WHERE share_id=target AND source_id=src.id AND effective_date>points.previous_date AND effective_date<=points.value_date AND (cash_per_unit<>0 OR split_factor<>1));
           val:=count_flat;
         ELSIF code LIKE '%Income%' THEN val:=divide(val*10000,(result->>'endDate')::date-(result->>'startDate')::date);
         ELSIF code LIKE 'annualized%' THEN val:=divide(val*365,(result->>'endDate')::date-(result->>'startDate')::date);
         END IF;
         pending:=EXISTS(SELECT 1 FROM generate_series(e+1,due_date(src.id,as_of),interval '1 day') day WHERE discloses(src.id,day::date));
         row_result:=jsonb_build_object('metricCode',code,'value',round(val,36)::text,'startDate',result->'startDate','endDate',result->'endDate','sourceId',src.id,'unavailableReason',NULL,'windowAdjusted',result->'windowAdjusted','delayed',pending);
         EXIT;
       END IF;
     END IF;
     row_result:=jsonb_build_object('metricCode',code,'value',NULL,'startDate',s,'endDate',e,'sourceId',src.id,'unavailableReason',reason,'windowAdjusted',false,'delayed',false);
   END LOOP;
   all_results:=all_results||jsonb_build_array(row_result);
 END LOOP;
 RETURN all_results;
END $$;

CREATE FUNCTION wo_v2.recalculate(target uuid,as_of date) RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,wo_v2,pg_temp AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM inclusion_reasons WHERE share_id=target) THEN
   INSERT INTO current_metrics(share_id,metric_code,value,start_date,end_date,source_id,unavailable_reason)
   SELECT target,item->>'metricCode',(item->>'value')::numeric,(item->>'startDate')::date,(item->>'endDate')::date,item->>'sourceId',item->>'unavailableReason'
   FROM jsonb_array_elements(compute_metrics(target,as_of)) item
   ON CONFLICT(share_id,metric_code) DO UPDATE SET value=excluded.value,start_date=excluded.start_date,end_date=excluded.end_date,source_id=excluded.source_id,unavailable_reason=excluded.unavailable_reason;
 END IF;
END $$;
RESET ROLE;
COMMIT;
