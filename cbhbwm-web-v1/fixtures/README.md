# cbhbwm-web-v1 测试夹具（真实/修改隔离）

分类遵守 K14/S-V04：`real/` 为真实原件（wire 形态逐字节保留，`.raw` 扩展避免被格式化），
`modified/` 为人工构造负例（明确合成，不冒充官方事件）。全部离线取得，银行请求数 0。

## real/（真实原件）

| 文件                       | 来源（主仓只读）                                                     | 抓取时间         | 原件 SHA-256（本文件字节）                                       | 说明                                                                                                    |
| -------------------------- | -------------------------------------------------------------------- | ---------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| catalog-page1.raw          | `apps/collector/fixtures/cbhbwm-catalog-page1.raw`                   | 2026-11-03 16:31 | 0af5cd5ec26a0b3b9f857e2d8ddb709b59b8f53933a779b7e84faf9b51e7ce98 | queryGPro 首页 10 行：totalRecords=2810/totalPages=281；CFTY6M045A（封闭 197 天，endDate 2027-05-26）等 |
| catalog-chenxiying13.raw   | `apps/collector/fixtures/cbhbwm-catalog-chenxiying13.raw`            | 2026-11-03 16:31 | 093a15a480131f497b310d58a10fa5b082299894272b5fc931db9490372b49de | searchStr=晨夕盈13：4 行 LCYSRK13A–D，全部 Z7008425000081、成立 2025-03-07（补齐调研遗留的销售代码）    |
| detail-LCYSRK13A.raw       | `apps/collector/fixtures/cbhbwm-detail-LCYSRK13A.raw`                | 2026-11-03 16:31 | ebe959427287e07ab835e843d5bac38306684bb5d9b6b3a63dc9e330c3b4f377 | getDetail 单行回填：shareName=A、est 20250307、endDate 99991231（开放类）、qiriFlag=0                   |
| detail-LCYSRK50A.raw       | `apps/collector/fixtures/cbhbwm-detail-LCYSRK50A.raw`                | 2026-11-03 16:31 | 05c96f74e688e539d425a373dfd981e8893fc99f4b4d0452376c82951aff9065 | 同上（LCYSRK50A，Z7008426000239，成立 2026-04-15）                                                      |
| nav-LCYSRK13A-default.raw  | `apps/collector/fixtures/cbhbwm-nav-LCYSRK13A.raw`                   | 2026-11-03 16:31 | 44f8e0dc2f0097f32075b638e94dee5f6cf18dcc4ec075f2ccbf86b4562db02f | queryProJz 默认窗口（日期留空）241 行：2025-11-03 → 2026-10-30——静默截断实证（约 12 个月）              |
| nav-LCYSRK13A-windowed.raw | `apps/collector/fixtures/cbhbwm-nav-LCYSRK13A-20250307-20250930.raw` | 2026-11-03 16:32 | 0758af18002a302e4eaab6a2970d37b37a8ac2c8734d0d344a36ddeb777b04e2 | 显式窗口 2025-03-07 → 2025-09-30（约 6.8 个月跨度被服务端接受）143 行，回溯至成立日                     |
| nav-LCYSRK50A.raw          | `apps/collector/fixtures/cbhbwm-nav-LCYSRK50A.raw`                   | 2026-11-03 16:32 | 88ccf7f84f6cdfe30733379e90907dc61507b947255c0e82412b65377773c7cb | LCYSRK50A 默认窗口 133 行：2026-04-15 → 2026-10-30（自成立全覆盖——该样本成立晚于截断线）                |

原始响应亦存主仓私有 `.local/nav-onboarding/cbhbwm/`；字段级映射与请求证据见
[渤银理财准入记录](../../../docs/reference/evidence/2026-11-03/nav-onboarding/cbhbwm.md)。

## modified/（合成负例，非官方事件）

| 文件                        | 构造方法（相对 real/ 原型）                     | 验证目标                                 |
| --------------------------- | ----------------------------------------------- | ---------------------------------------- |
| catalog-business-error.raw  | 外层 success 改 false                           | 业务失败：business_error                 |
| catalog-bad-inner-json.raw  | 外层 data 改非法 JSON 字符串                    | 二次信封：bad_inner_json                 |
| catalog-truncated.raw       | 首页截取前 3000 字节                            | 坏 JSON：not_json                        |
| detail-foreign-salecode.raw | 详情单行 saleCode 改 LCYSRK50A                  | 身份错配：share_mismatch                 |
| nav-cash-qiriflag.raw       | 净值响应 qiriFlag 改 1（万份收益/七日年化标签） | 现金类口径：cash_product_series 整页拒绝 |
| nav-foreign-salecode.raw    | 净值首行 salecode 改 LCYSRK50A                  | 行级份额校验：share_mismatch             |
| nav-duplicate-date.raw      | 净值首行复制                                    | 重复业务日期：duplicate_date 拒绝        |

样本背景（双层信封、prodFlag=1 缺省字段形态、2023 年成立产品深度未测等）见来源报告
`docs/reference/rebuild-p4-source-cbhbwm-web-v1-report.md`。银行请求计数：0。
