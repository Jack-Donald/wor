BEGIN;
SET ROLE wo_owner;
-- P3 整改迁移（复核 F01/F08/F11）：
-- F01 catalog_row 此前未输出契约必填的 shareCode，导致业务 API 对合法请求误报 400。
--     此处以 CREATE OR REPLACE 补齐 shareCode 输出（详情/相关份额行同受影响，一并修复）。
-- F11 目录总数此前取 MAX(page.total_count)：翻到空页时精确总数归零。改为在 matched
--     全量集合上单独计数，与当前页是否为空无关；同时保留同值稳定 ID 决胜（share_id ASC）。
-- F08 restriction_days 允许 NULL：区分"已核实的 0"与"未知"。CHECK 约束对 NULL 通过，
--     仅去掉 NOT NULL；具体写入路径（目录同步）在 202611060012 中修正为不造默认值。
-- 只追加不改写既有迁移历史（P2/P3 既有迁移字节保持不变）。
ALTER TABLE wo_v2.shares ALTER COLUMN restriction_days DROP NOT NULL;

-- 行投影：目录/详情/相关份额共用的只读行构造。补 shareCode（F01），restrictionDays
-- 直接透传（可为 NULL，表示期限未知），其余字段语义与 202611040010 一致。
CREATE OR REPLACE FUNCTION wo_v2.catalog_row(s wo_v2.shares) RETURNS jsonb LANGUAGE sql STABLE SET search_path=pg_catalog,wo_v2,pg_temp AS $$
 SELECT jsonb_build_object('shareId',s.id,'productId',s.product_id,'productName',p.name,'shareName',s.name,'productCode',p.product_code,
   'registrationCode',p.registration_code,'shareCode',s.share_code,'manager',p.manager_name,'riskLevel',p.risk_level,'currency','CNY','isPublic',true,
   'operatingMode',s.operating_mode,'restrictionDays',s.restriction_days,'lifecycleState',s.lifecycle_state,'collectionCapability',s.collection_capability,
   'included',EXISTS(SELECT 1 FROM inclusion_reasons r WHERE r.share_id=s.id),
   'catalogUpdatedAt',to_char(s.catalog_updated_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
   'salesOfferings',COALESCE((SELECT jsonb_agg(jsonb_build_object('channelKey',o.channel_key,'channelName',o.channel_name,'salesCode',o.sales_code) ORDER BY o.channel_key,o.sales_code NULLS FIRST) FROM sales_offerings o WHERE o.share_id=s.id),'[]'::jsonb))
 FROM products p WHERE p.id=s.product_id $$;

-- 目录/已收录列表 RPC：仅改总数来源与注释语义；过滤、稳定排序（含同值 share_id ASC 决胜）、
-- 分页窗口、输入校验与 202611040010 保持一致。
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
 -- F11：总数在 matched 全量一致读取中统计（count(*) OVER () 依赖窗口会被空页丢掉）。
 SELECT count(*) INTO total FROM (
   SELECT s.id
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
 ) matched_total;
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
   SELECT share_id,row_number() OVER (
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
   'totalCount',total,'pageNum',page_num,'pageSize',page_size)
 INTO result
 FROM page JOIN shares s ON s.id=page.share_id;
 RETURN result;
END $$;
RESET ROLE;
COMMIT;
