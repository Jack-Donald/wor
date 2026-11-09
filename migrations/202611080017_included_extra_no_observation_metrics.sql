BEGIN;
SET ROLE wo_owner;
-- R02（P5 退回整改）：已收录但尚无任何观测是合法业务状态（收录后、首采前）。
-- 原 wo_v2.included_extra 的 metrics 聚合只从 current_metrics 取行——compute_metrics/
-- recalculate 从未运行的无观测份额在 current_metrics 没有任何行，metrics 输出 []
-- （长度 0），与公开契约 IncludedShareSchema.metrics.length(11) 失配，导致
-- GET /api/v2/shares（列表）、GET /api/v2/shares/:id（详情）与 POST /api/v2/share-summaries
-- 在响应 Schema 校验抛 ZodError → HTTP 500 internal_error。
-- 修复方式：metrics 改为对 wo_v2.metric_codes() 的 11 个规范 metricCode 做左连接投影：
--   - 已有 current_metrics 行：输出与原实现逐字段一致（值/日期/来源/缺值原因/窗口
--     与滞后旗标/sourceConflict 子查询/单位映射/按代码排序），不改变既有份额响应；
--   - 缺行（首次观测前，m.metric_code IS NULL）：metricCode=规范代码，value/startDate/
--     endDate/sourceId 输出 null，unavailableReason='insufficient_history'（与
--     compute_metrics 在无观测时的缺值原因一致），windowAdjusted/delayed/sourceConflict
--     输出 false，unit 按既有 metric_code→单位映射——不虚构观测、不造零收益、不造日期。
-- current_metrics 的 PK(share_id,metric_code) 与 CHECK(metric_code IN 11 规范代码)
-- 保证左连接每代码至多命中一行，输出恒为 11 行；window_adjusted/delayed 为 NOT NULL，
-- COALESCE 对既有行的取值无影响。inclusionReasons 与 latestObservations 聚合保持不变
-- （无观测时 latestObservations 仍为 []）。
-- 该函数被 wo_query_catalog_v1（全部变体）、wo_query_share_detail_v1、
-- wo_query_share_summaries_v1 消费：OR REPLACE 一处修复全部消费面，不改变这些 RPC
-- 的其他行为；不放宽任何 Zod 契约（metrics.length(11) 保持）。
CREATE OR REPLACE FUNCTION wo_v2.included_extra(target uuid) RETURNS jsonb LANGUAGE sql STABLE SET search_path=pg_catalog,wo_v2,pg_temp AS $$
 SELECT jsonb_build_object(
   'inclusionReasons',(SELECT COALESCE(jsonb_agg(reason_type ORDER BY reason_type),'[]'::jsonb) FROM inclusion_reasons WHERE share_id=target),
   'metrics',(SELECT COALESCE(jsonb_agg(jsonb_build_object('metricCode',codes.code,
      'value',CASE WHEN m.value IS NULL THEN NULL ELSE m.value::text END,
      'startDate',m.start_date,'endDate',m.end_date,'sourceId',m.source_id,
      'unavailableReason',CASE WHEN m.metric_code IS NULL THEN 'insufficient_history' ELSE m.unavailable_reason END,
      'windowAdjusted',COALESCE(m.window_adjusted,false),'delayed',COALESCE(m.delayed,false),
      'sourceConflict',CASE WHEN m.metric_code IS NULL THEN false ELSE EXISTS(SELECT 1 FROM observations a JOIN observations b ON a.share_id=b.share_id AND a.value_date=b.value_date AND a.source_id<>b.source_id
        WHERE a.share_id=target AND a.source_id=m.source_id AND a.value_date=m.end_date AND a.unit_nav IS NOT NULL AND b.unit_nav IS DISTINCT FROM a.unit_nav) END,
      'unit',CASE WHEN codes.code IN ('dailyIncomePer10k','averageIncome7d','averageIncome14d') THEN 'CNY_PER_10000_PER_DAY'
        WHEN codes.code='flatDisclosureCountMonth' THEN 'COUNT' ELSE 'RATIO' END) ORDER BY codes.code),'[]'::jsonb)
     FROM unnest(metric_codes()) AS codes(code)
     LEFT JOIN current_metrics m ON m.share_id=target AND m.metric_code=codes.code),
   'latestObservations',COALESCE((SELECT jsonb_agg(jsonb_build_object('valueDate',o.value_date,'sourceId',o.source_id,'incomePeriodStart',o.income_period_start,
      'incomeBasis',o.income_basis,'unitNav',o.unit_nav::text,'cumulativeNav',o.cumulative_nav::text,'incomePer10k',o.income_per_10k::text,
      'officialYield7d',o.official_yield_7d::text,
      'sourceConflict',EXISTS(SELECT 1 FROM observations b WHERE b.share_id=o.share_id AND b.value_date=o.value_date AND b.source_id<>o.source_id AND b.unit_nav IS DISTINCT FROM o.unit_nav))
      ORDER BY o.value_date DESC,o.source_id) FROM (SELECT * FROM observations WHERE share_id=target ORDER BY value_date DESC,source_id LIMIT 100) o),'[]'::jsonb))
$$;
RESET ROLE;
COMMIT;
