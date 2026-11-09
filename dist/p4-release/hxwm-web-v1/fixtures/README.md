# hxwm-web-v1 测试夹具（真实/修改隔离）

分类遵守 K14/S-V04：`real/` 为真实原件（wire 形态逐字节保留，`.raw` 扩展避免被格式化），
`modified/` 为人工构造负例（明确合成，不冒充官方事件）。全部离线取得，银行请求数 0。

## real/（真实原件）

| 文件                              | 来源（主仓只读）                                                   | 抓取时间   | 原件 SHA-256（本文件字节）                                       | 说明                                                                                                      |
| --------------------------------- | ------------------------------------------------------------------ | ---------- | ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| catalog-gmcpxx.raw                | `apps/collector/fixtures/hxwm-catalog.raw`（官网目录 NDJSON 截选） | 2026-11-03 | 9b84bb412b540f87c4f69bfa85e87d09f2ceb0f9205cb4468be23836db45b482 | 9 行：同 Z7 三份额 2119187301A/B/C、封闭式 96 天 26111178B、现金管理类 25012109B、高风险权益 25802125A 等 |
| navindex-gmjzbg.raw               | `apps/collector/fixtures/hxwm-navindex.raw`（jzbgData 索引截选）   | 2026-11-03 | 9a5a59e41f54b0b9e324ef259a8ac15951c546c5b1ad7aa11bfce794a62e9a77 | 含同 id 双 js 条目（最新优选）、xlsx 旧格式条目与 xlsx-only id                                            |
| nav-1910621000202.raw             | `apps/collector/fixtures/hxwm-nav-1910621000202.raw`               | 2026-11-03 | 00fa616d2e46bdde424315efbbdba2032f5e1b67b514344195942f116782ce34 | 龙盈固收半年定开006号（Z7003921000431）439 行自成立全量，2019-03-29 → 2026-10-23（约 7.6 年）             |
| nav-26111178B.raw                 | `apps/collector/fixtures/hxwm-nav-26111178B.raw`                   | 2026-11-03 | 6e4514d7ed1abbafa2033e31bed60559b6167bea20b47ee8b7f96498d958b9dc | 固收纯债封闭式474号96天B（Z7003926001047）2 行，2026-10-16 → 2026-10-23（短历史封闭式）                   |
| nav-25012109B-excerpt.raw         | `apps/collector/fixtures/hxwm-nav-25012109B-excerpt.raw`           | 2026-11-03 | 9028ee3df65e8ad2bb18ec009618529620f430be36ee9fa69505b0eed61fb5fc | 现金109号B 混合披露截选 6 行：3 行万份收益式（shareNetVal 空）＋3 行单位净值式                            |
| nav-variant-22115005N-excerpt.raw | `apps/collector/fixtures/hxwm-nav-variant-22115005N-excerpt.raw`   | 2026-11-03 | d688ef3fcebe665663ff92de325000a0d1ab5d3a2bd0e967cb66041fc8cd59a1 | 旧格式报告变体 `var jzbg_data={...}`（中文键）截选 3 行（索引不可见的历史遗留形态，K14 兼容）             |

目录/索引全量原件（5.4 MB/2.6 MB）不入库，保留在主仓私有 `.local/nav-onboarding/hxwm/`；
字段级映射与请求证据见[华夏理财准入记录](../../../docs/reference/evidence/2026-11-03/nav-onboarding/hxwm.md)。

## modified/（合成负例，非官方事件）

| 文件                       | 构造方法（相对 real/ 原型）                | 验证目标                                     |
| -------------------------- | ------------------------------------------ | -------------------------------------------- |
| catalog-truncated.raw      | 目录 NDJSON 截取前半（行未完）             | 坏行：bad_ndjson_line                        |
| catalog-duplicate-code.raw | 首行复制追加                               | 目录行主键重复：duplicate_share_code 拒绝    |
| navindex-wrong-var.raw     | 变量名改为 otherData                       | 索引封套：not_nav_index                      |
| navindex-ambiguous-tie.raw | 26111178B 同 date 追加不同 uuid 的 js 地址 | 同 id 同 date 歧义：ambiguous_index_tie 拒绝 |
| nav-foreign-subshare.raw   | 26111178B 报告全部 subShareCode 改为其他码 | 身份回显：share_mismatch 拒绝                |
| nav-non-cny.raw            | 26111178B 报告首行 currency 改 USD         | 币种：not_cny_row 拒绝                       |

样本背景（风险文本映射、2099-12-01 无固定期限哨兵、subShareCode=NA 占位、报告覆盖式全量快照）
见来源报告 `docs/reference/rebuild-p4-source-hxwm-web-v1-report.md`。银行请求计数：0。
