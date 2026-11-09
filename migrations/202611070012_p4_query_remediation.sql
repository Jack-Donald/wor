BEGIN;
SET ROLE wo_owner;
-- P4 W02 整改轮迁移（attempt=2，CR-008/009/010；迁移区间 202611070011–202611070019 内追加，
-- 不改写已提交迁移字节）。整体替换两个只读函数：
-- 1) CR-008 风险未知哨兵：filter-options 的 riskLevels 以 '__unknown__' 广播空值
--    （risk_level IS NULL）样本——范围内无未知行时不广播（前端按"广播才显示"实现）；
--    目录/已收录查询把 riskLevel 数组中的 '__unknown__' 解释为 risk_level IS NULL，与其他
--    选中值按 OR 组合（A07 同字段多选为或）。原 202611070011 的 'unknown' 哨兵停用。
-- 2) CR-009 期限未知筛选（契约冻结点3）：新增 payload 键 restrictionDaysUnknown（布尔，
--    缺省 null=不过滤）。SQL 语义（与 restrictionDaysMax 组合，"未知选项独立并集"）：
--      未提供        → 不按未知过滤；max 单独给时 days<=max（NULL 天然不命中）；
--      true 单独     → 仅匹配 restriction_days IS NULL 行；
--      true + max    → days<=max OR days IS NULL（未知行独立并入结果集）；
--      false 单独    → 仅匹配 restriction_days IS NOT NULL 行；
--      false + max   → days IS NOT NULL AND days<=max（等价 days<=max）。
-- 3) CR-010 目录升序：catalog scope 的 sortOrder=asc 此前未生效（ORDER BY 固定
--    catalog_updated_at DESC）。修复：asc 时按 catalog_updated_at ASC（shareId 仍为决胜），
--    desc 行为与 011 一致；included scope 的指标升降序不受影响（其 catalog_updated_at
--    仅作同值决胜，保持倒序）。
-- 其余语义（搜索/精确命中优先/多销售 EXISTS 去重/F11 精确总数/分页）与 202611070011 一致。

CREATE OR REPLACE FUNCTION wo_rpc.wo_query_catalog_v1(payload jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE scope text; page_num integer; page_size integer; search_text text; direction text; sort_by text; included_flag text;
 result jsonb; total integer;
BEGIN
 IF policy() IS NULL THEN RAISE EXCEPTION 'unavailable' USING ERRCODE='WO503'; END IF;
 IF NOT keys_allowed(payload,ARRAY['scope','pageNum','pageSize','search','manager','bank','riskLevel','operatingMode','restrictionDaysMax','restrictionDaysUnknown','included','lifecycleState','sortBy','sortOrder'])
   OR payload->>'scope' NOT IN ('catalog','included')
   OR jsonb_typeof(payload->'pageNum')<>'number' OR (payload->>'pageNum')::integer<1
   OR jsonb_typeof(payload->'pageSize')<>'number' OR (payload->>'pageSize')::integer NOT BETWEEN 1 AND 100
   OR payload->>'sortOrder' NOT IN ('asc','desc')
   OR (NULLIF(payload->'search','null'::jsonb) IS NOT NULL AND (jsonb_typeof(payload->'search')<>'string' OR length(payload->>'search')>128))
   OR (NULLIF(payload->'sortBy','null'::jsonb) IS NOT NULL AND jsonb_typeof(payload->'sortBy')<>'string')
   OR (payload->>'scope'='catalog' AND NULLIF(payload->'sortBy','null'::jsonb) IS NOT NULL)
   OR (payload->>'scope'='included' AND NULLIF(payload->'sortBy','null'::jsonb) IS NOT NULL AND payload->>'sortBy' NOT IN (SELECT unnest(metric_codes())))
   OR (NULLIF(payload->'restrictionDaysMax','null'::jsonb) IS NOT NULL AND (jsonb_typeof(payload->'restrictionDaysMax')<>'number' OR (payload->>'restrictionDaysMax')::integer NOT BETWEEN 0 AND 31))
   -- CR-009：restrictionDaysUnknown 必须为布尔（缺省允许）。
   OR (NULLIF(payload->'restrictionDaysUnknown','null'::jsonb) IS NOT NULL AND jsonb_typeof(payload->'restrictionDaysUnknown')<>'boolean') THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
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
     -- CR-008 未知值：riskLevel 哨兵 '__unknown__' 命中空值（未知风险等级），与其他选中值 OR 组合；
     -- 空数组保持"激活且不命中"的既有语义。
     AND (NULLIF(payload->'riskLevel','null'::jsonb) IS NULL OR p.risk_level = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'riskLevel')))
        OR (p.risk_level IS NULL AND '__unknown__' = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'riskLevel')))))
     AND (NULLIF(payload->'operatingMode','null'::jsonb) IS NULL OR s.operating_mode = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'operatingMode'))))
     AND (NULLIF(payload->'lifecycleState','null'::jsonb) IS NULL OR s.lifecycle_state = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'lifecycleState'))))
     -- CR-009 期限未知筛选（tri-state；未知选项独立并集，语义见文件头）。
     AND (CASE
       WHEN NULLIF(payload->'restrictionDaysUnknown','null'::jsonb) IS NULL THEN
         (payload->>'restrictionDaysMax' IS NULL OR s.restriction_days<=(payload->>'restrictionDaysMax')::integer)
       WHEN (payload->>'restrictionDaysUnknown')::boolean THEN
         (s.restriction_days IS NULL OR (payload->>'restrictionDaysMax' IS NOT NULL AND s.restriction_days<=(payload->>'restrictionDaysMax')::integer))
       ELSE
         (s.restriction_days IS NOT NULL AND (payload->>'restrictionDaysMax' IS NULL OR s.restriction_days<=(payload->>'restrictionDaysMax')::integer))
     END)
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
        OR (p.risk_level IS NULL AND '__unknown__' = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'riskLevel')))))
     AND (NULLIF(payload->'operatingMode','null'::jsonb) IS NULL OR s.operating_mode = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'operatingMode'))))
     AND (NULLIF(payload->'lifecycleState','null'::jsonb) IS NULL OR s.lifecycle_state = ANY(ARRAY(SELECT jsonb_array_elements_text(payload->'lifecycleState'))))
     -- CR-009 期限未知筛选（tri-state；未知选项独立并集，语义见文件头）。
     AND (CASE
       WHEN NULLIF(payload->'restrictionDaysUnknown','null'::jsonb) IS NULL THEN
         (payload->>'restrictionDaysMax' IS NULL OR s.restriction_days<=(payload->>'restrictionDaysMax')::integer)
       WHEN (payload->>'restrictionDaysUnknown')::boolean THEN
         (s.restriction_days IS NULL OR (payload->>'restrictionDaysMax' IS NOT NULL AND s.restriction_days<=(payload->>'restrictionDaysMax')::integer))
       ELSE
         (s.restriction_days IS NOT NULL AND (payload->>'restrictionDaysMax' IS NULL OR s.restriction_days<=(payload->>'restrictionDaysMax')::integer))
     END)
 ), ordered AS (
   -- 全局排序：精确命中优先 → 质量分组（正常→变长→滞后→空值）→ 指标值（空值恒最后）
   -- → 目录更新时间（CR-010：catalog scope 按 direction 升/降序；included scope 恒倒序仅作同值决胜）
   -- → 稳定 shareId 决胜；无先限 N 后排序。
   SELECT share_id,row_number() OVER (
     ORDER BY exact_rank ASC,
       quality ASC,
       CASE WHEN scope='included' AND direction='desc' THEN sort_value END DESC NULLS LAST,
       CASE WHEN scope='included' AND direction='asc' THEN sort_value END ASC NULLS LAST,
       CASE WHEN scope='catalog' AND direction='asc' THEN catalog_updated_at END ASC,
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

CREATE OR REPLACE FUNCTION wo_rpc.wo_query_filter_options_v1(scope text) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
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
   -- CR-008 未知值单独表达：范围内存在空风险等级时追加哨兵 '__unknown__'（查询端命中
   -- risk_level IS NULL）；空值本身不进入字典；无未知行时不广播（前端"广播才显示"）。
   'riskLevels',COALESCE((SELECT jsonb_agg(risk ORDER BY risk)
     FROM (SELECT DISTINCT risk FROM (SELECT risk_level AS risk FROM base WHERE risk_level IS NOT NULL
           UNION ALL SELECT '__unknown__' WHERE EXISTS(SELECT 1 FROM base WHERE risk_level IS NULL)) unioned) risks),'[]'::jsonb),
   'operatingModes',COALESCE((SELECT jsonb_agg(DISTINCT operating_mode ORDER BY operating_mode) FROM base),'[]'::jsonb),
   'lifecycleStates',COALESCE((SELECT jsonb_agg(DISTINCT lifecycle_state ORDER BY lifecycle_state) FROM base),'[]'::jsonb)))
 INTO result;
 RETURN result;
END $$;

GRANT EXECUTE ON FUNCTION wo_rpc.wo_query_catalog_v1(jsonb),wo_rpc.wo_query_filter_options_v1(text) TO wo_reader,wo_maintainer;
RESET ROLE;
COMMIT;
