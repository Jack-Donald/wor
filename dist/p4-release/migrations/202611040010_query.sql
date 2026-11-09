BEGIN;
SET ROLE wo_owner;
-- P3: public read-only query functions backing GET /api/v2/catalog, /shares, /shares/:id and
-- /shares/:id/observations. All filtering, stable sorting, pagination and same-response totals
-- happen inside one database read. Granted to wo_reader only; no write paths reachable.
CREATE FUNCTION wo_v2.catalog_row(s wo_v2.shares) RETURNS jsonb LANGUAGE sql STABLE SET search_path=pg_catalog,wo_v2,pg_temp AS $$
 SELECT jsonb_build_object('shareId',s.id,'productId',s.product_id,'productName',p.name,'shareName',s.name,'productCode',p.product_code,
   'registrationCode',p.registration_code,'manager',p.manager_name,'riskLevel',p.risk_level,'currency','CNY','isPublic',true,
   'operatingMode',s.operating_mode,'restrictionDays',s.restriction_days,'lifecycleState',s.lifecycle_state,'collectionCapability',s.collection_capability,
   'included',EXISTS(SELECT 1 FROM inclusion_reasons r WHERE r.share_id=s.id),
   'catalogUpdatedAt',to_char(s.catalog_updated_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
   'salesOfferings',COALESCE((SELECT jsonb_agg(jsonb_build_object('channelKey',o.channel_key,'channelName',o.channel_name,'salesCode',o.sales_code) ORDER BY o.channel_key,o.sales_code NULLS FIRST) FROM sales_offerings o WHERE o.share_id=s.id),'[]'::jsonb))
 FROM products p WHERE p.id=s.product_id $$;

CREATE FUNCTION wo_v2.included_extra(target uuid) RETURNS jsonb LANGUAGE sql STABLE SET search_path=pg_catalog,wo_v2,pg_temp AS $$
 SELECT jsonb_build_object(
   'inclusionReasons',(SELECT COALESCE(jsonb_agg(reason_type ORDER BY reason_type),'[]'::jsonb) FROM inclusion_reasons WHERE share_id=target),
   'metrics',(SELECT COALESCE(jsonb_agg(jsonb_build_object('metricCode',metric_code,'value',CASE WHEN value IS NULL THEN NULL ELSE value::text END,
      'startDate',start_date,'endDate',end_date,'sourceId',source_id,'unavailableReason',unavailable_reason,'windowAdjusted',window_adjusted,'delayed',delayed,
      'sourceConflict',EXISTS(SELECT 1 FROM observations a JOIN observations b ON a.share_id=b.share_id AND a.value_date=b.value_date AND a.source_id<>b.source_id
        WHERE a.share_id=target AND a.source_id=current_metrics.source_id AND a.value_date=end_date AND a.unit_nav IS NOT NULL AND b.unit_nav IS DISTINCT FROM a.unit_nav),
      'unit',CASE WHEN metric_code IN ('dailyIncomePer10k','averageIncome7d','averageIncome14d') THEN 'CNY_PER_10000_PER_DAY'
        WHEN metric_code='flatDisclosureCountMonth' THEN 'COUNT' ELSE 'RATIO' END) ORDER BY metric_code),'[]'::jsonb) FROM current_metrics WHERE share_id=target),
   'latestObservations',COALESCE((SELECT jsonb_agg(jsonb_build_object('valueDate',o.value_date,'sourceId',o.source_id,'incomePeriodStart',o.income_period_start,
      'incomeBasis',o.income_basis,'unitNav',o.unit_nav::text,'cumulativeNav',o.cumulative_nav::text,'incomePer10k',o.income_per_10k::text,
      'officialYield7d',o.official_yield_7d::text,
      'sourceConflict',EXISTS(SELECT 1 FROM observations b WHERE b.share_id=o.share_id AND b.value_date=o.value_date AND b.source_id<>o.source_id AND b.unit_nav IS DISTINCT FROM o.unit_nav))
      ORDER BY o.value_date DESC,o.source_id) FROM (SELECT * FROM observations WHERE share_id=target ORDER BY value_date DESC,source_id LIMIT 100) o),'[]'::jsonb))
$$;

CREATE FUNCTION wo_rpc.wo_query_catalog_v1(payload jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE scope text; page_num integer; page_size integer; search_text text; direction text; sort_by text; included_flag text;
 result jsonb; total integer;
BEGIN
 IF policy() IS NULL THEN RAISE EXCEPTION 'unavailable' USING ERRCODE='WO503'; END IF;
 IF NOT keys_allowed(payload,ARRAY['scope','pageNum','pageSize','search','manager','bank','riskLevel','operatingMode','restrictionDaysMax','included','lifecycleState','sortBy','sortOrder'])
   OR payload->>'scope' NOT IN ('catalog','included')
   OR jsonb_typeof(payload->'pageNum')<>'number' OR (payload->>'pageNum')::integer<1
   OR jsonb_typeof(payload->'pageSize')<>'number' OR (payload->>'pageSize')::integer NOT BETWEEN 1 AND 100
   OR payload->>'sortOrder' NOT IN ('asc','desc')
   OR (NULLIF(payload->'search','null'::jsonb) IS NOT NULL AND (jsonb_typeof(payload->'search')<>'string' OR length(payload->>'search')>128))
   OR (NULLIF(payload->'sortBy','null'::jsonb) IS NOT NULL AND jsonb_typeof(payload->'sortBy')<>'string')
   OR (payload->>'scope'='catalog' AND NULLIF(payload->'sortBy','null'::jsonb) IS NOT NULL)
   OR (payload->>'scope'='included' AND NULLIF(payload->'sortBy','null'::jsonb) IS NOT NULL AND payload->>'sortBy' NOT IN (SELECT unnest(metric_codes())))
   OR (NULLIF(payload->'restrictionDaysMax','null'::jsonb) IS NOT NULL AND (jsonb_typeof(payload->'restrictionDaysMax')<>'number' OR (payload->>'restrictionDaysMax')::integer NOT BETWEEN 0 AND 31)) THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 scope:=payload->>'scope'; page_num:=(payload->>'pageNum')::integer; page_size:=(payload->>'pageSize')::integer;
 search_text:=NULLIF(payload->>'search',''); direction:=payload->>'sortOrder';
 sort_by:=COALESCE(NULLIF(payload->>'sortBy',''),CASE WHEN scope='included' THEN 'dailyIncomePer10k' END);
 IF scope='included' THEN included_flag:='true'; ELSE included_flag:=NULLIF(payload->>'included',''); END IF;
 WITH matched AS (
   SELECT s.id AS share_id,
     CASE WHEN scope='included' THEN
       CASE WHEN m.value IS NULL THEN 3 WHEN m.delayed THEN 2 WHEN m.window_adjusted THEN 1 ELSE 0 END
     ELSE 0 END AS quality,
     m.value AS sort_value,
     s.catalog_updated_at
   FROM shares s
   JOIN products p ON p.id=s.product_id
   LEFT JOIN current_metrics m ON m.share_id=s.id AND m.metric_code=sort_by
   WHERE (included_flag IS NULL OR (included_flag='true')=EXISTS(SELECT 1 FROM inclusion_reasons r WHERE r.share_id=s.id))
     AND (search_text IS NULL OR p.name ILIKE '%'||search_text||'%' OR s.name ILIKE '%'||search_text||'%' OR p.product_code ILIKE '%'||search_text||'%'
        OR p.registration_code ILIKE '%'||search_text||'%' OR s.share_code ILIKE '%'||search_text||'%'
        OR EXISTS(SELECT 1 FROM sales_offerings o WHERE o.share_id=s.id AND o.channel_name ILIKE '%'||search_text||'%'))
     AND (NULLIF(payload->'manager','null'::jsonb) IS NULL OR p.manager_name = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'manager'))))
     AND (NULLIF(payload->'bank','null'::jsonb) IS NULL OR EXISTS(SELECT 1 FROM sales_offerings o WHERE o.share_id=s.id AND o.channel_key = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'bank')))))
     AND (NULLIF(payload->'riskLevel','null'::jsonb) IS NULL OR p.risk_level = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'riskLevel'))))
     AND (NULLIF(payload->'operatingMode','null'::jsonb) IS NULL OR s.operating_mode = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'operatingMode'))))
     AND (NULLIF(payload->'lifecycleState','null'::jsonb) IS NULL OR s.lifecycle_state = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'lifecycleState'))))
     AND (payload->>'restrictionDaysMax' IS NULL OR s.restriction_days<=(payload->>'restrictionDaysMax')::integer)
 ), ordered AS (
   SELECT share_id,count(*) OVER () AS total_count,row_number() OVER (
     ORDER BY quality ASC,
       CASE WHEN scope='included' AND direction='desc' THEN sort_value END DESC NULLS LAST,
       CASE WHEN scope='included' AND direction='asc' THEN sort_value END ASC NULLS LAST,
       catalog_updated_at DESC, share_id ASC
   ) AS rn
   FROM matched
 ), page AS (
   SELECT * FROM ordered WHERE rn BETWEEN (page_num-1)*page_size+1 AND page_num*page_size
 )
 SELECT jsonb_build_object('rows',COALESCE(jsonb_agg(CASE WHEN scope='included' THEN catalog_row(s)||included_extra(s.id) ELSE catalog_row(s) END ORDER BY page.rn),'[]'::jsonb),
   'totalCount',COALESCE(MAX(page.total_count),0),'pageNum',page_num,'pageSize',page_size)
 INTO result
 FROM page JOIN shares s ON s.id=page.share_id;
 RETURN result;
END $$;

CREATE FUNCTION wo_rpc.wo_query_share_detail_v1("shareId" uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE state shares%ROWTYPE; row jsonb; related jsonb;
BEGIN
 IF policy() IS NULL THEN RAISE EXCEPTION 'unavailable' USING ERRCODE='WO503'; END IF;
 SELECT * INTO state FROM shares WHERE id="shareId";
 IF state.id IS NULL THEN RETURN jsonb_build_object('notFound',true,'share',NULL,'relatedShares','[]'::jsonb); END IF;
 row:=catalog_row(state);
 IF EXISTS(SELECT 1 FROM inclusion_reasons WHERE share_id="shareId") THEN row:=row||included_extra("shareId"); END IF;
 SELECT COALESCE(jsonb_agg(catalog_row(s) ORDER BY s.share_code NULLS LAST,s.id),'[]'::jsonb) INTO related
   FROM shares s WHERE s.product_id=state.product_id AND s.id<>"shareId";
 RETURN jsonb_build_object('notFound',false,'share',row,'relatedShares',related);
END $$;

CREATE FUNCTION wo_rpc.wo_query_history_v1(payload jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE target uuid; start_date date; end_date date; page_num integer; page_size integer; state shares%ROWTYPE;
 rows jsonb; total integer; gaps jsonb; bounded boolean;
BEGIN
 IF policy() IS NULL THEN RAISE EXCEPTION 'unavailable' USING ERRCODE='WO503'; END IF;
 IF NOT keys_exact(payload,ARRAY['shareId','start','end','pageNum','pageSize'])
   OR NOT valid_date(payload->>'start') OR NOT valid_date(payload->>'end') OR payload->>'start'>payload->>'end'
   OR jsonb_typeof(payload->'pageNum')<>'number' OR (payload->>'pageNum')::integer<1
   OR jsonb_typeof(payload->'pageSize')<>'number' OR (payload->>'pageSize')::integer NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 target:=(payload->>'shareId')::uuid; start_date:=(payload->>'start')::date; end_date:=(payload->>'end')::date;
 page_num:=(payload->>'pageNum')::integer; page_size:=(payload->>'pageSize')::integer;
 bounded:=end_date-start_date<=2500;
 SELECT * INTO state FROM shares WHERE id=target;
 IF state.id IS NULL THEN RETURN jsonb_build_object('notFound',true,'notIncluded',false,'rows','[]'::jsonb,'totalCount',0,'gaps','[]'::jsonb); END IF;
 IF NOT EXISTS(SELECT 1 FROM inclusion_reasons WHERE share_id=target) THEN
   RETURN jsonb_build_object('notFound',false,'notIncluded',true,'rows','[]'::jsonb,'totalCount',0,'gaps','[]'::jsonb);
 END IF;
 SELECT count(*) INTO total FROM observations WHERE share_id=target AND value_date BETWEEN start_date AND end_date;
 SELECT COALESCE(jsonb_agg(jsonb_build_object('valueDate',page.value_date,'sourceId',page.source_id,'incomePeriodStart',page.income_period_start,'incomeBasis',page.income_basis,
   'unitNav',page.unit_nav::text,'cumulativeNav',page.cumulative_nav::text,'incomePer10k',page.income_per_10k::text,'officialYield7d',page.official_yield_7d::text,
   'sourceConflict',EXISTS(SELECT 1 FROM observations b WHERE b.share_id=page.share_id AND b.value_date=page.value_date AND b.source_id<>page.source_id AND b.unit_nav IS DISTINCT FROM page.unit_nav))
   ORDER BY page.value_date DESC,page.source_id),NULL)
 INTO rows FROM (SELECT * FROM observations WHERE share_id=target AND value_date BETWEEN start_date AND end_date ORDER BY value_date DESC,source_id LIMIT page_size OFFSET (page_num-1)*page_size) page;
 WITH present_sources AS (SELECT DISTINCT source_id FROM observations WHERE share_id=target)
 SELECT COALESCE(jsonb_agg(jsonb_build_object('sourceId',source_id,'date',day) ORDER BY day DESC,source_id),'[]'::jsonb)
 INTO gaps FROM (SELECT ps.source_id,d.day::date AS day FROM present_sources ps CROSS JOIN generate_series(start_date,end_date,interval '1 day') AS d(day)
   WHERE bounded AND discloses(ps.source_id,d.day::date)
     AND NOT EXISTS(SELECT 1 FROM observations x WHERE x.share_id=target AND x.source_id=ps.source_id AND x.value_date=d.day::date)
   ORDER BY d.day DESC,ps.source_id LIMIT 800) bounded_gaps;
 RETURN jsonb_build_object('notFound',false,'notIncluded',false,'rows',COALESCE(rows,'[]'::jsonb),'totalCount',total,'gaps',gaps);
END $$;
GRANT EXECUTE ON FUNCTION wo_rpc.wo_query_catalog_v1(jsonb) TO wo_reader,wo_maintainer;
GRANT EXECUTE ON FUNCTION wo_rpc.wo_query_share_detail_v1(uuid) TO wo_reader,wo_maintainer;
GRANT EXECUTE ON FUNCTION wo_rpc.wo_query_history_v1(jsonb) TO wo_reader,wo_maintainer;
RESET ROLE;
COMMIT;
