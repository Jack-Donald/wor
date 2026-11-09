BEGIN;
SET ROLE wo_owner;
-- R04（P5 退回整改）：维护通道辅助函数补显式 EXECUTE 授权。
-- 背景：CR-P5-002（迁移 202611080015）撤销了 wo_rpc/wo_v2 全部函数的 PUBLIC EXECUTE
-- 并收紧默认权限；CR-P5-003（202611080016）只为 wo_maintainer 恢复了
-- policy_revision()/policy() 两个直读接口。其余原先依赖 PUBLIC EXECUTE 的只读辅助
-- 函数在撤销后只剩属主可执行——生产采集/查询链路不受影响（全部经 SECURITY DEFINER
-- 的 wo_rpc 函数，内部以属主身份执行），但"维护角色直连 SQL 通道"（人工验收环境
-- seed/probe 的锚点读数：业务今日/应披露日历/披露判定/区间指标计算）在 00015 落地
-- 后实际失效。该缺陷在 P5 第一轮未被发现的成因：U05 启动链验证发生在 00015/00016
-- 合入之前（当时 14 份迁移），此后验收环境链未复跑——本次 R04 在独占自建环境逐条
-- 执行 start→seed 时真实暴露（permission denied for function business_today）。
-- 修复：为维护通道实际直调的只读辅助函数补显式 GRANT（与 00016 的最小授权先例
-- 一致；不恢复 PUBLIC、不扩大到 wo_reader——读方一律经 SECURITY DEFINER 查询
-- RPC）。授权集＝seed/probe 四个直调入口（business_today/due_date/discloses/
-- interval_value）＋它们以 SECURITY INVOKER 内联调用的辅助闭包（对函数体静态
-- 扫描求出：divide 数值除法、source_config 来源策略只读配置；policy()/policy_
-- revision() 已由 00016 授权）。SQL 语言函数按调用者权限执行内部调用，闭包不齐
-- 时被调方会在入口已授权的情况下仍然拒绝：
--   business_today()                    ——业务今日（北京时区日历锚点）；
--   due_date(source_key,as_of)          ——来源应披露进度（内部调 source_config）；
--   discloses(source_key,business_date) ——某业务日该来源是否披露（内部调
--                                         source_config）；
--   interval_value(...)                 ——区间收益计算（内部调 divide）；
--   divide(n,d)                         ——数值除法（NULL/除零安全）；
--   source_config(source_key)           ——来源策略只读配置。
-- 全部为无副作用的 STABLE 计算函数，授权只允许"调用计算"，不产生任何数据变更面。
GRANT EXECUTE ON FUNCTION wo_v2.business_today(),
  wo_v2.due_date(source_key text, as_of date),
  wo_v2.discloses(source_key text, business_date date),
  wo_v2.interval_value(target uuid, src text, requested_start date, requested_end date, as_of date),
  wo_v2.divide(n numeric, d numeric),
  wo_v2.source_config(source_key text)
  TO wo_maintainer;
RESET ROLE;
COMMIT;
