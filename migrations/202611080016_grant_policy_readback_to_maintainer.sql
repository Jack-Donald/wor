-- P5 W00 修复(CR-P5-003,随 U07-D01 返派发现):补回 202611080015 收紧后维护通道
-- 直读接口的显式授权。背景:wo_rpc 入口函数全部 SECURITY DEFINER(内部语句以
-- wo_owner 执行,wo_v2 内部链路不受 PUBLIC EXECUTE 收紧影响);但 wo_maintainer
-- (有 wo_v2 USAGE)此前直接调用 wo_v2.policy_revision()/wo_v2.policy() 读取当前
-- 生效策略与 revision——迁移 202611040001 未对这两个内部函数显式授权,历史上
-- 依赖 PUBLIC EXECUTE(内建默认);202611080015 撤销 PUBLIC 后该直读链 42501
-- (p4 policy/verify-f2、b-suite applyPolicy/maintSql、p5 reuse/sources 演练均受影响)。
-- 修复:以 wo_owner 对这两个只读接口补显式 GRANT——wo_maintainer 恢复直读;
-- PUBLIC 收紧与其余 wo_v2 内部函数(仅经 SECURITY DEFINER 入口以 wo_owner 调用)
-- 保持 202611080015 状态不变。
SET ROLE wo_owner;
GRANT EXECUTE ON FUNCTION wo_v2.policy_revision(), wo_v2.policy() TO wo_maintainer;
