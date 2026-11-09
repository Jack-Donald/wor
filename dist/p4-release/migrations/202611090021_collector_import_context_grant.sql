-- 00021：采集器身份解析读权限（维护者 2026-11-09 裁定「采集器共用 wo_collector 组权限」的落地）。
-- 背景：collect --write 在 https 目标的身份解析（来源份额码→真实 shareId/included 上下文，
-- F12 跨库身份对账同一口径）调用 wo_rpc.wo_p3_import_context_v1(jsonb)；该函数此前仅
-- 授予 wo_maintainer，wo_collector JWT 执行被拒（42501/403，R2 cibwm 首次 Actions 写入暴露）。
-- 该 RPC 为只读上下文查询（SECURITY DEFINER，单次上限 20 个份额代码），授予 wo_collector
-- 与 ADR-20261109 共享权限裁定一致；写入仍受 prepare/ingest/reconcile 的 epoch 乐观锁与
-- 校验约束。
BEGIN;
SET ROLE wo_owner;
GRANT EXECUTE ON FUNCTION wo_rpc.wo_p3_import_context_v1(jsonb) TO wo_collector;
RESET ROLE;
COMMIT;