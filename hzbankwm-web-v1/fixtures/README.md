# hzbankwm-web-v1 测试夹具（真实/修改隔离）

分类遵守 K14/S-V04：`real/` 为真实原件（wire 形态逐字节保留，`.raw` 扩展避免被格式化），
`modified/` 为人工构造负例（明确合成，不冒充官方事件）。全部离线取得，银行请求数 0。

## real/（真实原件）

| 文件                     | 来源（主仓只读）                                                                           | 抓取时间   | 原件 SHA-256（本文件字节）                                       | 说明                                                                                                                       |
| ------------------------ | ------------------------------------------------------------------------------------------ | ---------- | ---------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| catalog-product-data.raw | `apps/collector/fixtures/hzbankwm-catalog.raw`（product_data.json 6 行截选，保留顶层结构） | 2026-11-03 | bf449e2aef3b0012e525b4ee9370a6f6bf03ecf58f310f2a784fc31006ce6524 | 6 行：TYGC7D2302F（最低持有 7 天可赎）、TYG6M1802W、FYG25211A 新旧两条快照（同码去重样本）、LQB2001F、TYG6M1802            |
| nav-LQB2001F.raw         | `apps/collector/fixtures/hzbankwm-nav-LQB2001F.raw`                                        | 2026-11-03 | 37a3e564774bad224b72d7933faae6a078628cc6cb56d151c52d406cca30f90e | LQB2001F（Z7002220000004，幸福 99 零钱包 F 款）全历史 1,577 行，2022-07-05 → 2026-11-01（52 个月）                         |
| nav-TYG6M1802.raw        | `apps/collector/fixtures/hzbankwm-nav-TYG6M1802.raw`                                       | 2026-11-03 | c23adcf55d9b032c3812cbea5fef1d9d9dedf994d8a0a4e9f8861b9dba28374d | TYG6M1802（Z7002221000166，幸福 99 半年添益 1802 期）全历史 323 行，2018-11-16 → 2026-10-30（96 个月）；24 个月窗口 117 行 |

全量目录原件（4.6 MB）不入库，保留在主仓私有 `.local/nav-onboarding/hzbankwm/`；
字段级映射与请求证据见[杭银理财准入记录](../../../docs/reference/evidence/2026-11-03/nav-onboarding/hzbankwm.md)。

## modified/（合成负例，非官方事件）

| 文件                           | 构造方法（相对 real/ 原型）                                         | 验证目标                                            |
| ------------------------------ | ------------------------------------------------------------------- | --------------------------------------------------- |
| catalog-truncated.raw          | 目录截取前 2000 字节                                                | 坏 JSON：not_json                                   |
| catalog-stale-tie-conflict.raw | 6 行目录中 FYG25211A 两条快照改为同 jingzhiriqi、不同 danweijingzhi | 同码同日异值：stale_tie_conflict 整文件拒绝         |
| nav-duplicate-date.raw         | TYG6M1802 首行复制一份                                              | 重复业务日期：duplicate_date 拒绝                   |
| nav-empty-array.raw            | 空数组 `[]`                                                         | 合法空历史（未知 code 官方 404，空数组=无历史窗口） |
| nav-numeric-unit.raw           | TYG6M1802 前 5 行 unit_net_value 改为 JSON 数字                     | 数值保真：not_a_string:unit_net_value 拒绝          |

样本背景（期限形态 7–730/182–1120、同 Z7 多份额、无币种字段、canonical 域不可达）见来源报告
`docs/reference/rebuild-p4-source-hzbankwm-web-v1-report.md`。银行请求计数：0。
