-- 00022：身份解析读 RPC 的组身份门禁放宽（承接 00020/00021 的共享权限裁定）。
-- 背景：00021 已授予 wo_collector 对 wo_p3_import_context_v1 的 EXECUTE，但函数体
-- 第一行仍要求 is_maintainer()（00020 只放宽了 wo_v2.authorize），collect --write 的
-- https 身份解析被 WO005 拒绝（R2 cibwm 第二次 Actions 写入暴露）。
-- 修复：放行条件从「仅维护者」改为「维护者或 wo_collector 组成员」——与
-- ADR-20261109「采集器共用 wo_collector 组权限」一致。该 RPC 为只读上下文查询
-- （SECURITY DEFINER、入参严格受限、单次 ≤20 代码），无提权面。
-- 其余语义（share:% kind 泛化、fundcode 优先、入参校验）与 202611070014 完全一致。
BEGIN;
SET ROLE wo_owner;
CREATE OR REPLACE FUNCTION wo_rpc.wo_p3_import_context_v1(payload jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE src text; codes jsonb;
BEGIN
 IF NOT is_maintainer() AND NOT pg_has_role(principal(),'wo_collector','member') THEN RAISE EXCEPTION 'source_forbidden' USING ERRCODE='WO005'; END IF;
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
GRANT EXECUTE ON FUNCTION wo_rpc.wo_p3_import_context_v1(jsonb) TO wo_collector;
RESET ROLE;
COMMIT;