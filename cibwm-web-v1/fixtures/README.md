# cibwm-web-v1 测试夹具（真实/修改隔离）

分类遵守 K14/S-V04：`real/` 为真实原件（wire 形态逐字节保留，`.raw` 扩展避免被格式化），
`modified/` 为人工构造负例（明确合成，不冒充官方事件）。全部离线取得（主仓研究材料
只读复制，抓取时间 2026-10-29/30），银行请求数 0。

## real/（真实原件）

| 文件                                | 来源（主仓只读）                                                                       | 抓取时间   | 原件 SHA-256（本文件字节）                                       | 说明                                                                                                           |
| ----------------------------------- | -------------------------------------------------------------------------------------- | ---------- | ---------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| catalog-fuzzy-7tian-page1.raw       | `.local/cib-onboarding/list-7天-1.raw`（fuzzyStr=7天 第 1 页）                         | 2026-10-30 | af34d5205f060a844857c07ccc20edda860dd13bbb6d96f37ec2186f90f242e7 | 100 行（含 9K41057A），total=276；关键词扫描形态                                                               |
| catalog-filtered-cny-short-term.raw | `.local/cib-onboarding/filtered-1.raw`（productPeriod/productType1/saleCurrency 过滤） | 2026-10-30 | adc764d2af0f4c8cf1c8f5e9a4be7ed9051db9708b4527b2f2d1f79929c71996 | 100 行，total=1471；结构过滤形态（含 invStart="每日可赎"等非持有规则行）                                       |
| catalog-channel-ccb-page1.raw       | `.local/cibwm-expander/catalog/ccb-page1.json`（distributionChannel=建设银行 第 1 页） | 2026-10-30 | 7bd4e4cb0db3609c4a50d1c6bc7e5a7dfc8a6003ec4d3899a135da5476ec7989 | 100 行，total=127；渠道过滤形态（管理人披露渠道对应关系证据，不生成其他银行独立源）                            |
| detail-9K41057A.raw                 | `apps/collector/fixtures/cibwm-detail-9K41057A.raw`                                    | 2026-10-29 | 72ecc860947ff7bca0428b3793fd311e7211cd832a330fe3f4317d19aedd198d | 稳添利ESG周盈57号A；父码 9K410570；Z7002024003330；valueDate=2025-03-07（与旧 identities documentSha256 一致） |
| detail-9K41063A.raw                 | `apps/collector/fixtures/cibwm-detail-9K41063A.raw`                                    | 2026-10-29 | 8ccec6ef8b2cda90063d1a696df6f75067eba0b91454064e9aecbfd9d7289941 | 稳添利周盈63号A；父码 9K410630；Z7002025000570；valueDate=2025-06-18                                           |
| detail-9K41080A.raw                 | `apps/collector/fixtures/cibwm-detail-9K41080A.raw`                                    | 2026-10-29 | 531b02925eca5aa31b6779ada2364f21b4420ef6aa3fc3dc939fddb539c468cf | 稳添利周盈80号A；父码 9K410800；Z7002025001844；valueDate=2025-11-11；6 家披露渠道银行                         |
| nav-9K41057A.raw                    | `apps/collector/fixtures/cibwm-nav-9K41057A.raw`（productVal/page 单页全量）           | 2026-10-29 | 642a8793f16ee0828a6e8785373facb05cb2dfd8aea664bb07a96f4065245860 | 83 行（netvalDt 2026-07-01..10-29），effIopv/effTotNetVal 裸数字含尾零（1.034710000000）                       |
| nav-9K41063A.raw                    | `apps/collector/fixtures/cibwm-nav-9K41063A.raw`                                       | 2026-10-29 | dd86a5c17c440a31ab3f9a3405534a3052f1e48da295227d3c63dcfbb5c6e034 | 83 行同窗口；第二份额历史证据                                                                                  |

成立日语义实证（detail-9K41057A.raw 内字段）：valueDate=2025-03-07 与官方
establishedDays=602（=2025-03-07..2026-10-29 含首日 601+1）自洽；raiseBegin(03-05)
<=raiseEnd(03-06)<valueDate(03-07) 顺序成立。

## modified/（合成负例，非官方事件）

| 文件                         | 构造方法（相对 real/ 原型）                  | 验证目标                              |
| ---------------------------- | -------------------------------------------- | ------------------------------------- |
| nav-foreign-code.raw         | nav-9K41057A 第 4 行 productCode 改 9K41057B | 同码隔离：share_mismatch 整页拒绝     |
| nav-truncated.raw            | nav-9K41057A 截断前 5000 字节                | 坏 JSON：not_json                     |
| nav-business-error.raw       | 封套 status 200→500                          | 业务错误封套：business_error 整页拒绝 |
| nav-duplicate-date.raw       | 第 2 行 netvalDt 改为第 1 行同日             | 同页重复业务日期拒绝                  |
| detail-foreign-currency.raw  | detail-9K41057A saleCurrency 人民币→美元     | 人民币判定：not_cny                   |
| detail-private-placement.raw | detail-9K41057A 公募→私募                    | 公募判定：not_public_offering         |
| detail-xjl-true.raw          | detail-9K41057A xjl false→true               | 现金管理类产品拒绝                    |
| detail-holding-mismatch.raw  | detail-9K41057A productDate 7天→30天         | invStart/productDate 交叉验证失败     |
| catalog-total-drift.raw      | catalog-fuzzy-7tian total 276→270            | 动态总数：pagination_total_drift      |
| catalog-business-error.raw   | catalog-fuzzy-7tian status→500               | 目录业务错误封套整页拒绝              |

样本背景（登记编码/父产品码/披露渠道分布、成立日语义）见来源报告
`docs/reference/rebuild-p4-source-cibwm-web-v1-report.md`。银行请求计数：0。
