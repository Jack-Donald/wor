-- Supabase 兼容适配：独立 PostgREST 使用本工程自建 wo_authenticator 登录身份；
-- Supabase Data API 的会话用户固定为平台 authenticator，PostgREST 按 JWT role 声明切换。
-- principal() 必须同时识别两种入口，否则 RPC 只能看到平台入口身份、无法解析受限业务角色。
BEGIN;
SET ROLE wo_owner;
CREATE OR REPLACE FUNCTION wo_v2.principal() RETURNS text LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT CASE
   WHEN session_user IN ('wo_authenticator','authenticator') THEN current_setting('role',true)
   ELSE session_user::text
 END
$$;
RESET ROLE;

-- 维护者明确授权候选环境采用宽松角色可达性：Supabase authenticator 可按签名 JWT
-- 切换到全部业务组角色。此处不授予表 DML；实际写入仍受 RPC 授权与来源策略约束。
-- 独立 PostgreSQL 没有 Supabase authenticator 时保持无操作，避免破坏本地初始化。
DO $adapter$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'authenticator') THEN
    EXECUTE 'GRANT wo_anonymous, wo_reader, wo_collector, wo_maintainer TO authenticator WITH SET TRUE';
  END IF;
END
$adapter$;
COMMIT;
