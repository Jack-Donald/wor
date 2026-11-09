# psbc-web-v1 测试夹具（真实/修改隔离）

分类遵守 K14/S-V04：`real/` 为真实原件（wire 形态逐字节保留，`.raw` 扩展避免被格式化），
`modified/` 为人工构造负例（明确合成，不冒充官方事件）。全部离线取得，银行请求数 0。

## real/（真实原件）

| 文件                             | 来源（主仓只读）                                                                                   | 抓取时间   | 原件 SHA-256（本文件字节）                                       | 说明                                                                                                           |
| -------------------------------- | -------------------------------------------------------------------------------------------------- | ---------- | ---------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| catalog-finquick-7tian-page1.raw | `apps/collector/fixtures/psbc-list-1.raw`（finquick 7天关键词第 1 页 JSONP）                       | 2026-10-29 | bd5ac66e9b973b1c88c8d14b4d69e85d9cb334ffea1e17960c65045c3182f8c7 | 6 行：交银 5811221014（渠道在售他管产品实证）、中邮 2401MB011B 等；totalCount=125/pageCount=21/pageSize=6      |
| catalog-finquick-7tian-page2.raw | 由 `.local/psbc-ccb-expander/catalog/最短持有30天.json`（2026-10-30 全量抓取）真实行拼装的分页外壳 | 2026-10-30 | （拼装件，行字段真实）                                           | 2 行：2503QP002B（CURRENCY=840 美元真实行）+ 2401ME005B（156 人民币）；页壳为离线拼装，仅测解析                |
| history-5811221014-page1.raw     | `apps/collector/fixtures/psbc-nav-1.raw`（financehisnet 20261001–20261029 第 1 页）                | 2026-10-29 | 8a259c70ccff79b7815a8d4562a9b98c1b53d827d596150e44f29e4ed874fb1c | 10 行（降序），totalCount=15/pageCount=2；SECODE=5811221014（交银份额经邮储渠道披露，销售码=管理人份额码实证） |
| history-5811221014-page2.raw     | `apps/collector/fixtures/psbc-nav-2.raw`（同窗口第 2 页）                                          | 2026-10-29 | d50a9b32a1f08ede42bc3d596ddc85a2dc5447d4d626952ba70f69e96c09f6e4 | 5 行（降序），与第 1 页合计 15 行                                                                              |
| detail-2401MB011B.raw            | `apps/collector/fixtures/psbc-detail-2401MB011B.raw`（官网详情摘录：剥注释、截产品段）             | 2026-10-29 | 1cd21ab67291a598802fb2cb521ec2449632d4744083104225bb17214239d4ce | 中邮理财"灵活·鸿运最短持有7天11号B"；原页 html SHA-256 dfdfc69e…374bd7（转换说明见旧 manifest）                |
| detail-A32013.raw                | `apps/collector/fixtures/psbc-detail-A32013.raw`（同上转换）                                       | 2026-10-29 | fa0f9d30e3eb0d8874927f0255edde02726d26adb86966918db6c9eba1ca3ff9 | 南银理财鼎瑞悦稳（最低持有7天）-C份额                                                                          |
| detail-A32042.raw                | `apps/collector/fixtures/psbc-detail-A32042.raw`（同上转换）                                       | 2026-10-29 | d93f6cd27be9284db936c540fbececd97a0ed80af6b09cc023f33a2771b3e67b | 南银理财悦稳最低持有7天4号-B份额；完整原页另存主仓 `.local/psbc-detail-sample.html`（111727 字节）             |

## modified/（合成负例，非官方事件）

| 文件                       | 构造方法（相对 real/ 原型）               | 验证目标                              |
| -------------------------- | ----------------------------------------- | ------------------------------------- |
| history-foreign-secode.raw | 第 1 页复制后把一行 SECODE 改为其他销售码 | 同码隔离：share_mismatch 整页拒绝     |
| history-total-drift.raw    | 第 2 页复制后 totalCount 改为 14          | 动态总数：pagination_total_drift      |
| catalog-non-cny-page.raw   | page2 复制后两行 CURRENCY 均改为 840      | 人民币判定：非 156 行全部隔离         |
| catalog-truncated.raw      | page1 截断前 3000 字节                    | 坏 JSONP：not_json_or_jsonp           |
| catalog-business-error.raw | 封套 retCodeEnum 改为 RET_CODE_ENUM_999   | 业务错误封套：business_error 整页拒绝 |
| detail-cash-management.raw | A32042 详情 cplx1 值 0→1                  | 现金管理类产品拒绝                    |
| detail-wrong-salescode.raw | A32042 详情销售码替换为 A99999            | 身份错配/说明书链接错配 fail-closed   |

样本背景（登记编码证据、管理人分布、销售码≠份额主码）见来源报告
`docs/reference/rebuild-p4-source-psbc-web-v1-report.md`。银行请求计数：0。
