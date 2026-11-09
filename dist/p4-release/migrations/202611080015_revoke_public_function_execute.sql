-- P5 W00 修复(U04-F01):对齐迁移 202611040001 第 14–15 行的默认权限意图。
-- 背景:PostgreSQL 18.4 实测 `ALTER DEFAULT PRIVILEGES IN SCHEMA ... REVOKE EXECUTE
-- ON FUNCTIONS FROM PUBLIC`(IN SCHEMA 变体)不产生 pg_default_acl 条目(空操作),
-- 导致 wo_rpc 全部 20 个函数的 ACL 被后续显式 GRANT 物化为含 PUBLIC EXECUTE(=X);
-- 同时 wo_v2 的触发器/辅助函数 proacl 为 NULL(沿用内建默认=PUBLIC EXECUTE)。
-- 实际防线仍然有效(schema USAGE 已对 PUBLIC 撤销 + 函数内 authorize/身份检查,
-- U04 演练实测数据完整性未失守),但 ACL 纵深与迁移意图不符。
-- 修复(以 wo_owner 执行,与 0001 的角色上下文一致):
--   1) 显式撤销 wo_rpc/wo_v2 两个 schema 全部现有函数的 PUBLIC EXECUTE——
--      wo_reader/wo_collector/wo_maintainer 的显式 EXECUTE 授权全部保留,
--      PostgREST 带 JWT 的公开只读链(登录角色为 wo_reader 成员)不受影响;
--      wo_anonymous 本就无 schema USAGE(fail-closed),无需任何新授权;
--   2) 以全局变体补默认权限(未来 wo_owner 新建函数不再默认 PUBLIC EXECUTE,
--      新函数继续按既有模式在各迁移中显式 GRANT 最小角色集)。
SET ROLE wo_owner;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA wo_rpc, wo_v2 FROM PUBLIC;
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
