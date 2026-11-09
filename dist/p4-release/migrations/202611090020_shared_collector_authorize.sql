-- 00020：采集授权简化——共享 wo_collector 组权限（维护者 2026-11-09 裁定）。
-- 背景：Supabase 适配（00019）只允许 authenticator 按 JWT 切换 wo_anonymous/wo_reader/
-- wo_collector/wo_maintainer 四个组角色；而本函数原实现要求 principal() 精确命中
-- source_config(src)->'principals'，且策略校验禁止把组角色名写进 principals——两者叠加
-- 导致 wo_collector JWT 的采集写路径在 Supabase 上永远被拒（R2 首次触达写入路径暴露）。
-- 维护者裁定：采集器不再按源细分权限，全部共用 wo_collector 组权限。
-- 新语义：daily 模式写入放行条件＝principal() 是 wo_collector 组成员（自含：JWT 的
-- role=wo_collector 命中自身；独立 PostgREST 的 per-source 登录角色因挂靠 wo_collector
-- 组同样命中）。修复（repair/admission 等 mode<>'daily'）仍仅限维护者，与原语义一致。
-- sources[].principals 保留为登记性字段（策略校验不变），授权不再依赖它。
-- 关联：docs/decisions/ADR-20261109-shared-collector-authorization.md。
BEGIN;
SET ROLE wo_owner;
CREATE OR REPLACE FUNCTION wo_v2.authorize(src text,mode text) RETURNS void LANGUAGE plpgsql STABLE SET search_path=pg_catalog,wo_v2,pg_temp AS $$
BEGIN
 IF NOT is_maintainer() AND (mode<>'daily' OR NOT pg_has_role(principal(),'wo_collector','member')) THEN
   RAISE EXCEPTION 'source_forbidden' USING ERRCODE='WO005';
 END IF;
 IF source_config(src) IS NULL THEN RAISE EXCEPTION 'source_forbidden' USING ERRCODE='WO005'; END IF;
END $$;
RESET ROLE;
COMMIT;