# hzbank-web-v1 测试夹具（真实/修改隔离）

分类遵守 K14/S-V04：`real/` 为真实原件（wire 形态逐字节保留，`.raw` 扩展避免被格式化；
PDF 为二进制，测试以 latin1 读入保证字节往返），`modified/` 为人工构造负例（明确合成，
不冒充官方事件）。全部离线取得，银行请求数 0。

## real/（真实原件）

来源：主仓（只读）`apps/collector/fixtures/hzbank-*.raw`，2026-11-02 实捕字节原样复制
（抓取过程见主仓 [hzbank 渠道验证](../../../../docs/reference/evidence/2026-11-02/sales-channel-verification/hzbank.md)）。

| 文件                         | 抓取时间   | 原件 SHA-256（本文件字节）                                       | 说明                                                                                                                             |
| ---------------------------- | ---------- | ---------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| catalog-issw0001-page1.raw   | 2026-11-02 | ff3110c2129469d6e7d1a70b3f814ae9cddcbfa53cda50ff00b09dffe0549f54 | 目录第 1 页（total=4997/totalPages=500，10 行）：ZYHQ2201 幸福99卓越混合 365 天持有期（在售/人民币/redTimeExplain 官方赎回说明） |
| detail-issw0002-ZYHQ2201.raw | 2026-11-02 | b34d41fde677597dee21fe53f35af132584db76391b8b04c59426c97e07158b5 | ISSW0002 详情 JSON：fileInfo.产品说明书 同域直链（iibsp filesharepublic）——三跳第二跳                                            |
| instruction-ZYHQ2201-pdf.raw | 2026-11-02 | 0bd032cf274557dc119d95fd9eb13baa833175314acdf4780289927880ce7242 | 说明书合同 PDF（340KB 二进制）：纯 Node inflate 提取登记编码 Z7002222000062——三跳第三跳实证                                      |

## modified/（合成负例，非官方事件）

| 文件                                | 构造方法（相对 real/ 原型）                 | 验证目标                                    |
| ----------------------------------- | ------------------------------------------- | ------------------------------------------- |
| catalog-duplicate-page1.raw         | 目录页 1 整页复制（活列表整页重复形态）     | 容错去重：duplicateRows 计数、不整轮失败    |
| detail-business-error.raw           | 详情 success=false/errorCode=9999999999     | 业务错误封套：business_error 整页拒绝       |
| instruction-ambiguous-two-codes.raw | 原 PDF 末尾追加一个含另一 Z 码的 deflate 流 | 登记编码歧义：多码 → null（pending 不猜测） |

样本背景（三跳链路、异域白名单、prodTerm 弃用、在售口径）见来源报告
`docs/reference/rebuild-p4-source-hzbank-web-v1-report.md`。银行请求计数：0。
