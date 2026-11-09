BEGIN;
SET ROLE wo_owner;
-- P4 W02 只读查询迁移（迁移区间 202611070011–202611070019 的首笔，只追加不改写既有迁移）。
-- 内容：
-- 1) CREATE OR REPLACE wo_query_catalog_v1：复核修正（A06/A07 对齐）——
--    a. 搜索字段收敛为 产品名/份额名/产品代码/登记编码/份额代码/销售代码（包含匹配），
--       移除越权的渠道名称搜索；
--    b. 代码精确命中优先：五类代码与 search 全等（区分大小写的全等）时进入第一优先组，
--       组内沿用既有质量分组（正常→变长→滞后→空值）、指标值升降、catalogUpdatedAt、shareId 决胜；
--    c. riskLevel 筛选支持哨兵 'unknown'：命中 risk_level 为空（未知风险等级）的份额。
--    其余语义（included 作用域强制、多销售 EXISTS 去重不重复份额、F11 精确总数与页面无关）不变。
-- 2) CREATE OR REPLACE wo_query_history_v1：行序与缺口序改为业务日期升序（A-设计路由表
--    "真实业务日期升序"）；其余校验/分页（默认 100、最大 500）、保留窗口语义不变
--    （库中只存在保留窗口内真实数据，不补零、不伪造）。
-- 3) 六个新只读 RPC：wo_query_observation_sources_v1 / wo_query_interval_return_v1 /
--    wo_query_share_summaries_v1 / wo_query_filter_options_v1 / wo_query_sources_v1 /
--    wo_query_stats_v1。均为 STABLE、SECURITY DEFINER、固定 search_path，仅授予
--    wo_reader/wo_maintainer；策略未初始化（policy() 为空）时抛 WO503，与既有查询一致。

-- ---------------------------------------------------------------------------
-- 1) 目录/已收录列表（复核修正版）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION wo_rpc.wo_query_catalog_v1(payload jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
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
 -- F11：精确总数在 matched 全量一致读取中单独统计，与当前页是否为空无关。
 SELECT count(*) INTO total FROM (
   SELECT s.id
   FROM shares s
   JOIN products p ON p.id=s.product_id
   LEFT JOIN current_metrics m ON m.share_id=s.id AND m.metric_code=sort_by
   WHERE (included_flag IS NULL OR (included_flag='true')=EXISTS(SELECT 1 FROM inclusion_reasons r WHERE r.share_id=s.id))
     -- A06 搜索：名称包含＋五类代码包含（销售代码经销售关系 EXISTS，不产生重复份额行）
     AND (search_text IS NULL OR p.name ILIKE '%'||search_text||'%' OR s.name ILIKE '%'||search_text||'%' OR p.product_code ILIKE '%'||search_text||'%'
        OR p.registration_code ILIKE '%'||search_text||'%' OR s.share_code ILIKE '%'||search_text||'%'
        OR EXISTS(SELECT 1 FROM sales_offerings o WHERE o.share_id=s.id AND o.sales_code ILIKE '%'||search_text||'%'))
     AND (NULLIF(payload->'manager','null'::jsonb) IS NULL OR p.manager_name = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'manager'))))
     AND (NULLIF(payload->'bank','null'::jsonb) IS NULL OR EXISTS(SELECT 1 FROM sales_offerings o WHERE o.share_id=s.id AND o.channel_key = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'bank')))))
     -- A07 未知值：riskLevel 哨兵 'unknown' 命中空值（未知风险等级）；空数组保持"激活且不命中"的既有语义
     AND (NULLIF(payload->'riskLevel','null'::jsonb) IS NULL OR p.risk_level = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'riskLevel')))
        OR (p.risk_level IS NULL AND 'unknown' = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'riskLevel')))))
     AND (NULLIF(payload->'operatingMode','null'::jsonb) IS NULL OR s.operating_mode = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'operatingMode'))))
     AND (NULLIF(payload->'lifecycleState','null'::jsonb) IS NULL OR s.lifecycle_state = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'lifecycleState'))))
     AND (payload->>'restrictionDaysMax' IS NULL OR s.restriction_days<=(payload->>'restrictionDaysMax')::integer)
 ) matched_total;
 WITH matched AS (
   SELECT s.id AS share_id,
     -- 代码精确命中优先级：0=精确命中（仅当提供 search 且任一代码字段全等），1=其余
     CASE WHEN search_text IS NULL THEN 1
       WHEN p.product_code IS NOT DISTINCT FROM search_text OR p.registration_code IS NOT DISTINCT FROM search_text
         OR s.share_code IS NOT DISTINCT FROM search_text
         OR EXISTS(SELECT 1 FROM sales_offerings o WHERE o.share_id=s.id AND o.sales_code IS NOT DISTINCT FROM search_text)
       THEN 0 ELSE 1 END AS exact_rank,
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
        OR EXISTS(SELECT 1 FROM sales_offerings o WHERE o.share_id=s.id AND o.sales_code ILIKE '%'||search_text||'%'))
     AND (NULLIF(payload->'manager','null'::jsonb) IS NULL OR p.manager_name = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'manager'))))
     AND (NULLIF(payload->'bank','null'::jsonb) IS NULL OR EXISTS(SELECT 1 FROM sales_offerings o WHERE o.share_id=s.id AND o.channel_key = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'bank')))))
     AND (NULLIF(payload->'riskLevel','null'::jsonb) IS NULL OR p.risk_level = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'riskLevel')))
        OR (p.risk_level IS NULL AND 'unknown' = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'riskLevel')))))
     AND (NULLIF(payload->'operatingMode','null'::jsonb) IS NULL OR s.operating_mode = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'operatingMode'))))
     AND (NULLIF(payload->'lifecycleState','null'::jsonb) IS NULL OR s.lifecycle_state = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'lifecycleState'))))
     AND (payload->>'restrictionDaysMax' IS NULL OR s.restriction_days<=(payload->>'restrictionDaysMax')::integer)
 ), ordered AS (
   -- 全局排序：精确命中优先 → 质量分组（正常→变长→滞后→空值）→ 指标值（空值恒最后）
   -- → 目录更新时间倒序 → 稳定 shareId 决胜；无先限 N 后排序。
   SELECT share_id,row_number() OVER (
     ORDER BY exact_rank ASC,
       quality ASC,
       CASE WHEN scope='included' AND direction='desc' THEN sort_value END DESC NULLS LAST,
       CASE WHEN scope='included' AND direction='asc' THEN sort_value END ASC NULLS LAST,
       catalog_updated_at DESC, share_id ASC
   ) AS rn
   FROM matched
 ), page AS (
   SELECT * FROM ordered WHERE rn BETWEEN (page_num-1)*page_size+1 AND page_num*page_size
 )
 SELECT jsonb_build_object('rows',COALESCE(jsonb_agg(CASE WHEN scope='included' THEN catalog_row(s)||included_extra(s.id) ELSE catalog_row(s) END ORDER BY page.rn),'[]'::jsonb),
   'totalCount',total,'pageNum',page_num,'pageSize',page_size)
 INTO result
 FROM page JOIN shares s ON s.id=page.share_id;
 RETURN result;
END $$;

-- ---------------------------------------------------------------------------
-- 2) 历史观测（复核修正版：业务日期升序）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION wo_rpc.wo_query_history_v1(payload jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
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
 -- 行序改为业务日期升序、来源键决胜（A-设计路由表"真实业务日期升序"）；仅返回真实存在数据。
 SELECT COALESCE(jsonb_agg(jsonb_build_object('valueDate',page.value_date,'sourceId',page.source_id,'incomePeriodStart',page.income_period_start,'incomeBasis',page.income_basis,
   'unitNav',page.unit_nav::text,'cumulativeNav',page.cumulative_nav::text,'incomePer10k',page.income_per_10k::text,'officialYield7d',page.official_yield_7d::text,
   'sourceConflict',EXISTS(SELECT 1 FROM observations b WHERE b.share_id=page.share_id AND b.value_date=page.value_date AND b.source_id<>page.source_id AND b.unit_nav IS DISTINCT FROM page.unit_nav))
   ORDER BY page.value_date ASC,page.source_id),NULL)
 INTO rows FROM (SELECT * FROM observations WHERE share_id=target AND value_date BETWEEN start_date AND end_date ORDER BY value_date ASC,source_id LIMIT page_size OFFSET (page_num-1)*page_size) page;
 WITH present_sources AS (SELECT DISTINCT source_id FROM observations WHERE share_id=target)
 SELECT COALESCE(jsonb_agg(jsonb_build_object('sourceId',source_id,'date',day) ORDER BY day ASC,source_id),'[]'::jsonb)
 INTO gaps FROM (SELECT ps.source_id,d.day::date AS day FROM present_sources ps CROSS JOIN generate_series(start_date,end_date,interval '1 day') AS d(day)
   WHERE bounded AND discloses(ps.source_id,d.day::date)
     AND NOT EXISTS(SELECT 1 FROM observations x WHERE x.share_id=target AND x.source_id=ps.source_id AND x.value_date=d.day::date)
   ORDER BY d.day ASC,ps.source_id LIMIT 800) bounded_gaps;
 RETURN jsonb_build_object('notFound',false,'notIncluded',false,'rows',COALESCE(rows,'[]'::jsonb),'totalCount',total,'gaps',gaps);
END $$;

-- ---------------------------------------------------------------------------
-- 3) observation-sources：某份额某业务日期各来源值＋官方公开链接（当前恒为 null，见 CR-002）
-- ---------------------------------------------------------------------------
CREATE FUNCTION wo_rpc.wo_query_observation_sources_v1(payload jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE target uuid; v_date date; v_metric text; state shares%ROWTYPE; rows jsonb;
BEGIN
 IF policy() IS NULL THEN RAISE EXCEPTION 'unavailable' USING ERRCODE='WO503'; END IF;
 IF NOT (keys_allowed(payload,ARRAY['shareId','date','metricCode']) AND payload ?& ARRAY['shareId','date'])
   OR payload->>'shareId' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   OR NOT valid_date(payload->>'date')
   OR (payload ? 'metricCode' AND (jsonb_typeof(payload->'metricCode')<>'string' OR payload->>'metricCode' NOT IN (SELECT unnest(metric_codes())))) THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 target:=(payload->>'shareId')::uuid; v_date:=(payload->>'date')::date; v_metric:=NULLIF(payload->>'metricCode','');
 SELECT * INTO state FROM shares WHERE id=target;
 -- 未知份额/未收录：data 恒为空数组（含明细数据一律不返回，语义与 history 一致）。
 IF state.id IS NULL THEN RETURN jsonb_build_object('notFound',true,'notIncluded',false,'data','[]'::jsonb); END IF;
 IF NOT EXISTS(SELECT 1 FROM inclusion_reasons WHERE share_id=target) THEN
   RETURN jsonb_build_object('notFound',false,'notIncluded',true,'data','[]'::jsonb);
 END IF;
 -- metricCode 提供时按份额类型选比较字段：现金管理→万份收益，其余→单位净值；
 -- 行仅保留该字段非空的来源；未提供时返回该日全部来源行，冲突对 unit_nav/income_per_10k 任一字段判定。
 SELECT COALESCE(jsonb_agg(jsonb_build_object(
   'valueDate',o.value_date,'sourceId',o.source_id,'incomePeriodStart',o.income_period_start,'incomeBasis',o.income_basis,
   'unitNav',o.unit_nav::text,'cumulativeNav',o.cumulative_nav::text,'incomePer10k',o.income_per_10k::text,'officialYield7d',o.official_yield_7d::text,
   -- 官方公开链接：来源配置尚无可公开链接模板（F2 端口属 W01），当前恒为 null，不公开内部请求参数。
   'officialUrl',NULL,
   'sourceConflict',EXISTS(
     SELECT 1 FROM observations b WHERE b.share_id=o.share_id AND b.value_date=o.value_date AND b.source_id<>o.source_id
       AND (CASE
         WHEN v_metric IS NOT NULL AND state.operating_mode='cash_management'
           THEN b.income_per_10k IS NOT NULL AND b.income_per_10k IS DISTINCT FROM o.income_per_10k
         WHEN v_metric IS NOT NULL
           THEN b.unit_nav IS NOT NULL AND b.unit_nav IS DISTINCT FROM o.unit_nav
         ELSE (b.unit_nav IS NOT NULL AND o.unit_nav IS NOT NULL AND b.unit_nav IS DISTINCT FROM o.unit_nav)
            OR (b.income_per_10k IS NOT NULL AND o.income_per_10k IS NOT NULL AND b.income_per_10k IS DISTINCT FROM o.income_per_10k)
       END)))
   ORDER BY CASE WHEN src.kind='channel' THEN 0 ELSE 1 END,src.priority,src.id),'[]'::jsonb) INTO rows
 FROM observations o JOIN sources src ON src.id=o.source_id
 WHERE o.share_id=target AND o.value_date=v_date
   AND (v_metric IS NULL OR CASE WHEN state.operating_mode='cash_management' THEN o.income_per_10k IS NOT NULL ELSE o.unit_nav IS NOT NULL END);
 RETURN jsonb_build_object('notFound',false,'notIncluded',false,'data',COALESCE(rows,'[]'::jsonb));
END $$;

-- ---------------------------------------------------------------------------
-- 4) interval-return：任意区间收益/折算年化（复用 wo_v2.interval_value 同版本规则）
-- ---------------------------------------------------------------------------
CREATE FUNCTION wo_rpc.wo_query_interval_return_v1(payload jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE target uuid; s date; e date; state shares%ROWTYPE; src record; result jsonb; chosen jsonb; chosen_src text;
 tried boolean:=false; last_reason text:=NULL; last_src text:=NULL;
 numerator numeric; denominator numeric; days integer; value numeric; conflict boolean; out jsonb;
BEGIN
 IF policy() IS NULL THEN RAISE EXCEPTION 'unavailable' USING ERRCODE='WO503'; END IF;
 IF NOT keys_exact(payload,ARRAY['shareId','start','end'])
   OR payload->>'shareId' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   OR NOT valid_date(payload->>'start') OR NOT valid_date(payload->>'end') OR payload->>'start'>=payload->>'end' THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 target:=(payload->>'shareId')::uuid; s:=(payload->>'start')::date; e:=(payload->>'end')::date;
 SELECT * INTO state FROM shares WHERE id=target;
 IF state.id IS NULL THEN RETURN jsonb_build_object('notFound',true,'notIncluded',false,'data',NULL); END IF;
 IF NOT EXISTS(SELECT 1 FROM inclusion_reasons WHERE share_id=target) THEN
   RETURN jsonb_build_object('notFound',false,'notIncluded',true,'data',NULL);
 END IF;
 -- 来源优先级与 compute_metrics 相同（渠道→管理人、priority、id）；仅考察在请求区间
 -- (s,e] 内有相关事实的来源（与 compute_metrics 跳过无数据来源一致）；第一个能完整
 -- 计算的来源胜出；全部失败时沿用回退语义——最后一个有数据来源的缺值原因。
 FOR src IN SELECT * FROM sources ORDER BY CASE WHEN kind='channel' THEN 0 ELSE 1 END,priority,id LOOP
   IF NOT EXISTS(SELECT 1 FROM observations WHERE share_id=target AND source_id=src.id AND value_date>s AND value_date<=e
       AND CASE WHEN state.operating_mode='cash_management' THEN income_per_10k IS NOT NULL ELSE unit_nav IS NOT NULL END) THEN CONTINUE; END IF;
   tried:=true;
   result:=interval_value(target,src.id,s,e,business_today());
   IF result->>'reason' IS NULL THEN chosen:=result; chosen_src:=src.id; EXIT; END IF;
   last_reason:=result->>'reason'; last_src:=src.id;
 END LOOP;
 IF chosen IS NULL THEN
   -- 全部来源不可计算：actual 端点为空、携带缺值原因（无任何数据来源时为 insufficient_history）。
   RETURN jsonb_build_object('notFound',false,'notIncluded',false,'data',jsonb_build_object(
     'requestedStart',s,'requestedEnd',e,'actualStart',NULL,'actualEnd',NULL,'returnRatio',NULL,'annualizedRatio',NULL,'averageIncomePer10k',NULL,
     'sourceId',last_src,'unavailableReason',COALESCE(last_reason,'insufficient_history'),
     'windowAdjusted',false,'endPending',false,'sourceConflict',false));
 END IF;
 numerator:=(chosen->>'numerator')::numeric; denominator:=(chosen->>'denominator')::numeric;
 days:=(chosen->>'endDate')::date-(chosen->>'startDate')::date;
 -- 单次舍入：divide 以 scale 100 工作精度计算，再按契约上限舍入（比率/年化 24 位、元/万元·日 12 位）。
 value:=divide(numerator,denominator);
 -- 冲突：实际终点日存在另一来源的观测且"双方均有值且不同"（unit_nav 或 income_per_10k）。
 conflict:=EXISTS(SELECT 1 FROM observations a JOIN observations b ON a.share_id=b.share_id AND a.value_date=b.value_date AND a.source_id<>b.source_id
   WHERE a.share_id=target AND a.source_id=chosen_src AND a.value_date=(chosen->>'endDate')::date
     AND ((a.unit_nav IS NOT NULL AND b.unit_nav IS NOT NULL AND a.unit_nav IS DISTINCT FROM b.unit_nav)
       OR (a.income_per_10k IS NOT NULL AND b.income_per_10k IS NOT NULL AND a.income_per_10k IS DISTINCT FROM b.income_per_10k)));
 out:=jsonb_build_object('requestedStart',s,'requestedEnd',e,
   'actualStart',chosen->>'startDate','actualEnd',chosen->>'endDate',
   'returnRatio',round(value,24)::text,
   'annualizedRatio',round(divide(numerator*365,denominator*days),24)::text,
   'averageIncomePer10k',round(divide(numerator*10000,denominator*days),12)::text,
   'sourceId',chosen_src,'unavailableReason',NULL,
   'windowAdjusted',(chosen->>'windowAdjusted')::boolean,'endPending',(chosen->>'delayed')::boolean,'sourceConflict',conflict);
 RETURN jsonb_build_object('notFound',false,'notIncluded',false,'data',out);
END $$;

-- ---------------------------------------------------------------------------
-- 5) share-summaries：自选批量（≤100 UUID，逐 ID found/not_found，保持输入顺序）
-- ---------------------------------------------------------------------------
CREATE FUNCTION wo_rpc.wo_query_share_summaries_v1(payload jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE ids text[]; item text; target uuid; state shares%ROWTYPE; row jsonb; results jsonb:='[]'::jsonb;
BEGIN
 IF policy() IS NULL THEN RAISE EXCEPTION 'unavailable' USING ERRCODE='WO503'; END IF;
 IF NOT keys_exact(payload,ARRAY['shareIds']) OR jsonb_typeof(payload->'shareIds')<>'array'
   OR jsonb_array_length(payload->'shareIds') NOT BETWEEN 1 AND 100
   OR EXISTS(SELECT 1 FROM jsonb_array_elements(payload->'shareIds') element
        WHERE jsonb_typeof(element)<>'string' OR element #>> '{}' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 ids:=ARRAY(SELECT jsonb_array_elements_text(payload->'shareIds'));
 FOREACH item IN ARRAY ids LOOP
   target:=item::uuid;
   SELECT * INTO state FROM shares WHERE id=target;
   IF state.id IS NULL THEN
     -- 未知 UUID：单项 not_found，不影响其余 ID。
     results:=results||jsonb_build_object('shareId',target,'state','not_found');
   ELSE
     row:=catalog_row(state);
     -- 已收录附摘要（依据/11 指标/最新观测），未收录仅目录行。
     IF EXISTS(SELECT 1 FROM inclusion_reasons WHERE share_id=target) THEN row:=row||included_extra(target); END IF;
     results:=results||jsonb_build_object('shareId',target,'state','found','share',row);
   END IF;
 END LOOP;
 RETURN jsonb_build_object('data',results);
END $$;

-- ---------------------------------------------------------------------------
-- 6) filter-options：scope=catalog/included 的筛选字典聚合
-- ---------------------------------------------------------------------------
CREATE FUNCTION wo_rpc.wo_query_filter_options_v1(scope text) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF policy() IS NULL THEN RAISE EXCEPTION 'unavailable' USING ERRCODE='WO503'; END IF;
 IF scope NOT IN ('catalog','included') THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 WITH base AS (
   -- 统计集合：catalog=全部目录份额；included=仅有任一有效收录依据的份额。
   SELECT s.id, p.manager_name, p.risk_level, s.operating_mode, s.lifecycle_state
   FROM shares s JOIN products p ON p.id=s.product_id
   WHERE scope='catalog' OR EXISTS(SELECT 1 FROM inclusion_reasons r WHERE r.share_id=s.id)
 )
 SELECT jsonb_build_object('data',jsonb_build_object(
   'scope',scope,
   'managers',COALESCE((SELECT jsonb_agg(DISTINCT manager_name ORDER BY manager_name) FROM base),'[]'::jsonb),
   -- 渠道键为稳定身份；同键多名时取字典序最小名称，保证聚合结果确定。
   'banks',COALESCE((SELECT jsonb_agg(jsonb_build_object('key',channel_key,'name',channel_name) ORDER BY channel_key)
     FROM (SELECT DISTINCT ON (o.channel_key) o.channel_key,o.channel_name
           FROM sales_offerings o JOIN base b ON b.id=o.share_id
           ORDER BY o.channel_key,o.channel_name) banks),'[]'::jsonb),
   -- 未知值单独表达：范围内存在空风险等级时追加哨兵 'unknown'（查询端命中 risk_level IS NULL）；
   -- 空值本身不进入字典。
   'riskLevels',COALESCE((SELECT jsonb_agg(risk ORDER BY risk)
     FROM (SELECT DISTINCT risk FROM (SELECT risk_level AS risk FROM base WHERE risk_level IS NOT NULL
           UNION ALL SELECT 'unknown' WHERE EXISTS(SELECT 1 FROM base WHERE risk_level IS NULL)) unioned) risks),'[]'::jsonb),
   'operatingModes',COALESCE((SELECT jsonb_agg(DISTINCT operating_mode ORDER BY operating_mode) FROM base),'[]'::jsonb),
   'lifecycleStates',COALESCE((SELECT jsonb_agg(DISTINCT lifecycle_state ORDER BY lifecycle_state) FROM base),'[]'::jsonb)))
 INTO result;
 RETURN result;
END $$;

-- ---------------------------------------------------------------------------
-- 7) sources：来源名称/角色/三计数（无最新日期、无任务状态）
-- ---------------------------------------------------------------------------
CREATE FUNCTION wo_rpc.wo_query_sources_v1() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF policy() IS NULL THEN RAISE EXCEPTION 'unavailable' USING ERRCODE='WO503'; END IF;
 SELECT COALESCE(jsonb_agg(jsonb_build_object(
   'sourceId',s.id,'name',s.name,'kind',s.kind,
   -- 目录关联：经外部标识映射（份额级直接命中；产品级映射到该产品全部份额）去重计数。
   'catalogShareCount',(SELECT count(DISTINCT sh.id) FROM external_identifiers ei
     JOIN shares sh ON sh.id=ei.share_id OR sh.product_id=ei.product_id
     WHERE ei.source_id=s.id),
   -- 实际保留观测覆盖的已收录份额数（观测仅存在于收录期间，取消收录即清理）。
   'retainedIncludedShareCount',(SELECT count(DISTINCT o.share_id) FROM observations o WHERE o.source_id=s.id),
   -- 冲突份额数：该来源与其他来源在同一业务日"双方均有值且不同"（unit_nav 或 income_per_10k）。
   'conflictingShareCount',(SELECT count(DISTINCT a.share_id) FROM observations a
     JOIN observations b ON a.share_id=b.share_id AND a.value_date=b.value_date AND a.source_id<>b.source_id
     WHERE a.source_id=s.id
       AND ((a.unit_nav IS NOT NULL AND b.unit_nav IS NOT NULL AND a.unit_nav IS DISTINCT FROM b.unit_nav)
         OR (a.income_per_10k IS NOT NULL AND b.income_per_10k IS NOT NULL AND a.income_per_10k IS DISTINCT FROM b.income_per_10k))))
   ORDER BY CASE WHEN s.kind='channel' THEN 0 ELSE 1 END,s.priority,s.id),'[]'::jsonb)
 INTO result FROM sources s;
 RETURN jsonb_build_object('data',result);
END $$;

-- ---------------------------------------------------------------------------
-- 8) stats：首页五统计（全目录范围；无全站最新数据日期）
-- ---------------------------------------------------------------------------
CREATE FUNCTION wo_rpc.wo_query_stats_v1() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
BEGIN
 IF policy() IS NULL THEN RAISE EXCEPTION 'unavailable' USING ERRCODE='WO503'; END IF;
 RETURN jsonb_build_object('data',jsonb_build_object(
   -- 产品数按目录涉及的产品去重；份额数按 UUID；收录数按有任一依据；管理人按名称去重；渠道按 channel_key 去重。
   'productCount',(SELECT count(DISTINCT product_id) FROM shares),
   'shareCount',(SELECT count(*) FROM shares),
   'includedShareCount',(SELECT count(DISTINCT share_id) FROM inclusion_reasons),
   'managerCount',(SELECT count(DISTINCT p.manager_name) FROM products p WHERE EXISTS(SELECT 1 FROM shares s WHERE s.product_id=p.id)),
   'channelCount',(SELECT count(DISTINCT channel_key) FROM sales_offerings)));
END $$;

GRANT EXECUTE ON FUNCTION wo_rpc.wo_query_catalog_v1(jsonb),wo_rpc.wo_query_history_v1(jsonb) TO wo_reader,wo_maintainer;
GRANT EXECUTE ON FUNCTION wo_rpc.wo_query_observation_sources_v1(jsonb),wo_rpc.wo_query_interval_return_v1(jsonb),
  wo_rpc.wo_query_share_summaries_v1(jsonb),wo_rpc.wo_query_filter_options_v1(text),
  wo_rpc.wo_query_sources_v1(),wo_rpc.wo_query_stats_v1() TO wo_reader,wo_maintainer;
RESET ROLE;
COMMIT;
