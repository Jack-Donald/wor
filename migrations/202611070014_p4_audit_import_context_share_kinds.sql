BEGIN;
SET ROLE wo_owner;
-- P4 审查整改 D1（CR-R2，A02 三 required 源目录身份链）：导入上下文份额 kind 泛化。
-- 缺陷：psbc/cibwm/bocwm 的目录同步条目登记源专属份额 kind（share:psbc_sales_code /
-- share:cibwm_share_code / share:bocwm_share_code——各 collector 的 shareCodeExternalId），
-- 而本函数（https 目标的份额身份解析 RPC）只认 kind='share:fundcode'，导致 catalog
-- apply 建好 share＋源专属标识后，import context 恒返回 shareId=null（R04 真实库复现）。
-- 修复：JOIN 条件由 kind='share:fundcode' 扩为同 source_id 下任意 kind LIKE 'share:%'
--（表 CHECK 保证 share:% kind 必挂 share_id，product:% kind 天然不命中）：
--   - fundcode 精确命中优先（ORDER BY 布尔 DESC）——旧源（bocom 等）行为不变；
--   - 多 kind 同值映射同一 share 时取其一（LATERAL ... LIMIT 1 保证每代码单行确定性，
--     不因行倍增产生重复聚合项）；(source_id,kind,value) 主键保证来源内唯一；
--   - 不伪造 fundcode 别名（psbc 销售码≠份额主码，别名方向语义错误）。
-- 其余语义（只读 STABLE／维护身份专属校验／入参严格受限／search_path／权限授予）与
-- 202611060013 原函数一致。psql 直连路径（evaluate/catalog/import-local/repair）的
-- 同口径泛化见 scripts/p4 各脚本的 shareIdentitySql。
CREATE OR REPLACE FUNCTION wo_rpc.wo_p3_import_context_v1(payload jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE src text; codes jsonb;
BEGIN
 IF NOT is_maintainer() THEN RAISE EXCEPTION 'source_forbidden' USING ERRCODE='WO005'; END IF;
 IF NOT keys_exact(payload,ARRAY['protocolVersion','sourceId','shareCodes'])
   OR payload->>'protocolVersion' IS DISTINCT FROM 'wo-ingest-v2'
   OR source_config(payload->>'sourceId') IS NULL
   OR jsonb_typeof(payload->'shareCodes')<>'array' OR jsonb_array_length(payload->'shareCodes')<1
   OR jsonb_array_length(payload->'shareCodes')>20
   OR EXISTS(SELECT 1 FROM jsonb_array_elements(payload->'shareCodes') e
       WHERE jsonb_typeof(e)<>'string' OR length(e #>> '{}') NOT BETWEEN 1 AND 128)
 THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 src:=payload->>'sourceId'; codes:=payload->'shareCodes';
 RETURN jsonb_build_object(
   'protocolVersion','wo-ingest-v2',
   'policyRevision',policy_revision(),
   'shares',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
       'shareCode',code,
       'shareId',i.share_id,
       'included',i.share_id IS NOT NULL AND EXISTS(SELECT 1 FROM inclusion_reasons r WHERE r.share_id=i.share_id)
     ) ORDER BY code),'[]'::jsonb)
     FROM jsonb_array_elements_text(codes) code
     LEFT JOIN LATERAL (
       SELECT e.share_id FROM external_identifiers e
       WHERE e.source_id=src AND e.kind LIKE 'share:%' AND e.value=code
       ORDER BY e.kind='share:fundcode' DESC
       LIMIT 1
     ) i ON true));
END $$;
GRANT EXECUTE ON FUNCTION wo_rpc.wo_p3_import_context_v1(jsonb) TO wo_maintainer;
RESET ROLE;
COMMIT;
