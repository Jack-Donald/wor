BEGIN;
SET ROLE wo_owner;
-- P3 整改补充迁移：导入上下文只读 RPC。发行包（p3.mjs）在无 psql/docker 的环境（如
-- Linux 容器经 HTTPS 写入）需要同边界的读通道：按来源+份额代码批量解析目标 shareId、
-- 收录状态并回带当前策略版本。只读（STABLE）、维护身份专属、入参严格受限（≤20 个
-- 份额代码），不暴露任何业务事实数据——覆盖读取继续使用既有 wo_read_coverage_v1
--（collector/maintainer 均可）。
CREATE FUNCTION wo_rpc.wo_p3_import_context_v1(payload jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
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
     LEFT JOIN external_identifiers i ON i.source_id=src AND i.kind='share:fundcode' AND i.value=code));
END $$;
GRANT EXECUTE ON FUNCTION wo_rpc.wo_p3_import_context_v1(jsonb) TO wo_maintainer;
RESET ROLE;
COMMIT;
