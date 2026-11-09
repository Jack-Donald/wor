BEGIN;
SET ROLE wo_owner;
-- P4 W02 整改轮迁移（attempt=3，W09-F02 sources 聚合性能；迁移区间 202611070011–202611070019
-- 内追加，不改写已提交迁移字节）。问题：wo_query_sources_v1 对 16 个来源逐一执行三个相关
-- 子查询，其中 retainedIncludedShareCount（按 source_id 过滤 observations）与
-- conflictingShareCount（observations 自连接）在仅有主键 (share_id,source_id,value_date)
-- 的结构下退化为每来源一次全表扫/自连接——C2（10000/3000，215.5 万观测）并发 1 P95
-- 10.7s、并发 5 全部超 15s 查询端口超时（W09 执行计划证据：c1/c2-sources-agg.txt，
-- temp 溢出 111,945 块）。
-- 优化（不改业务语义——catalogShareCount/retainedIncludedShareCount/conflictingShareCount
-- 口径与名称/角色输出不变）：
-- 1) 两个支撑索引：
--    observations_source_share(source_id,share_id)——覆盖计数 GROUP BY source_id 的
--    索引序（index-only 扫描，无排序无回表）；
--    observations_share_date(share_id,value_date,source_id) INCLUDE (unit_nav,
--    income_per_10k)——冲突窗口 PARTITION BY (share_id,value_date) 的索引序＋行值
--    覆盖（index-only 扫描免排序）。
-- 2) 查询重写（CREATE OR REPLACE wo_query_sources_v1，STABLE/SECURITY DEFINER/
--    search_path/授权不变）：
--    a. retainedIncludedShareCount 改为一次性 GROUP BY source_id（替代 16 次按来源
--       过滤的全表扫）；
--    b. conflictingShareCount 的成对自连接改为窗口聚合：同一 (share_id,value_date) 组
--       内"非空值 min<>max"⟺"组内存在两个不同的非空值"。等价性证明（两方向）：
--       (⇐) 组内非空值集 S 的 min<max ⟹ 至少两个不同值 v≠w；本行值 v 非空时，w 由
--           某行提供且该行来源必然不同（同一 (份额,来源,日期) 由主键唯一，来源相同的
--           行值即 v≠w 不可能），故原"∃ 另一来源双方非空且不同"成立；
--       (⇒) 原 ∃b 条件成立时本行值 v 与 b 行值 w 均非空且 v≠w 同在组内 ⟹ min≠max。
--       窗口 FILTER (非空) 聚合对全组计算，单来源/同值组 min=max（或均为 NULL）不
--       计入；DISTINCT (source_id,share_id) 后按来源计数与原口径一致。
--    c. catalogShareCount 子查询保留原样（external_identifiers 主键前导 source_id 已
--       走索引，量级约万行，非瓶颈）。
--    输出 jsonb 键序/字段/排序（channel→manager、priority、id）与 202611070011 逐字节
--    同构；计数为 bigint（原 count 同型），无观测来源 LEFT JOIN 补 0 与原空集 count=0
--    一致。

CREATE INDEX observations_source_share ON wo_v2.observations(source_id,share_id);
CREATE INDEX observations_share_date ON wo_v2.observations(share_id,value_date,source_id) INCLUDE (unit_nav,income_per_10k);

CREATE OR REPLACE FUNCTION wo_rpc.wo_query_sources_v1() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF policy() IS NULL THEN RAISE EXCEPTION 'unavailable' USING ERRCODE='WO503'; END IF;
 -- 覆盖计数：单次 GROUP BY（observations_source_share 索引序聚合），替代逐来源全表扫；
 -- 该 CTE 仅被引用一次，计划器内联为独立子计划，不物化。
 WITH covered AS (
   SELECT source_id, count(DISTINCT share_id) AS cnt FROM observations GROUP BY source_id
 ),
 -- 冲突窗口：按 (share_id,value_date) 分组取非空值的 min/max（observations_share_date
 -- 索引序，免排序）；"本行值非空且组内 min<>max" 等价于原"与另一来源双方非空且不同"
 -- 成对比较（等价性证明见迁移头注释）。
 flagged AS (
   SELECT share_id, source_id, unit_nav, income_per_10k,
     min(unit_nav) FILTER (WHERE unit_nav IS NOT NULL) OVER grp AS nav_lo,
     max(unit_nav) FILTER (WHERE unit_nav IS NOT NULL) OVER grp AS nav_hi,
     min(income_per_10k) FILTER (WHERE income_per_10k IS NOT NULL) OVER grp AS i10_lo,
     max(income_per_10k) FILTER (WHERE income_per_10k IS NOT NULL) OVER grp AS i10_hi
   FROM observations WINDOW grp AS (PARTITION BY share_id, value_date)
 ),
 -- 冲突计数：先 DISTINCT (来源,份额) 再按来源计数（与原 count(DISTINCT a.share_id) 同口径）。
 conflicting AS (
   SELECT source_id, count(DISTINCT share_id) AS cnt FROM (
     SELECT DISTINCT share_id, source_id FROM flagged
     WHERE (unit_nav IS NOT NULL AND nav_lo <> nav_hi)
        OR (income_per_10k IS NOT NULL AND i10_lo <> i10_hi)
   ) c GROUP BY source_id
 )
 SELECT COALESCE(jsonb_agg(jsonb_build_object(
   'sourceId',s.id,'name',s.name,'kind',s.kind,
   -- 目录关联：经外部标识映射（份额级直接命中；产品级映射到该产品全部份额）去重计数
   -- （保留 202611070011 原子查询：external_identifiers 主键前导 source_id 走索引）。
   'catalogShareCount',(SELECT count(DISTINCT sh.id) FROM external_identifiers ei
     JOIN shares sh ON sh.id=ei.share_id OR sh.product_id=ei.product_id
     WHERE ei.source_id=s.id),
   -- 实际保留观测覆盖的已收录份额数（观测仅存在于收录期间，取消收录即清理）。
   'retainedIncludedShareCount',COALESCE(c.cnt,0),
   -- 冲突份额数：该来源与其他来源在同一业务日"双方均有值且不同"（unit_nav 或
   -- income_per_10k）的份额数（窗口重写，口径不变）。
   'conflictingShareCount',COALESCE(cf.cnt,0))
   ORDER BY CASE WHEN s.kind='channel' THEN 0 ELSE 1 END,s.priority,s.id),'[]'::jsonb)
 INTO result FROM sources s
 LEFT JOIN covered c ON c.source_id=s.id
 LEFT JOIN conflicting cf ON cf.source_id=s.id;
 RETURN jsonb_build_object('data',result);
END $$;

-- 授权与 202611070011 保持一致（函数签名未变，重放环境补授；幂等）。
GRANT EXECUTE ON FUNCTION wo_rpc.wo_query_sources_v1() TO wo_reader,wo_maintainer;
RESET ROLE;
COMMIT;
