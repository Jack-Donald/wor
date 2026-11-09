# hsbank-web-v1 测试夹具（真实/修改隔离）

分类遵守 K14/S-V04：`real/` 为真实原件（wire 形态逐字节保留，`.raw` 扩展避免被格式化），
`modified/` 为人工构造负例（明确合成，不冒充官方事件）。全部离线取得，银行请求数 0。

## real/（真实原件）

来源：主仓（只读）`apps/collector/fixtures/hsbank-*.raw`，2026-11-02/03 实捕字节原样复制
（行尾说明：原捕获字节含 CRLF，入库统一为 LF 规范化形态（哈希为规范化后字节）；抓取过程见主仓 [hsbank 渠道验证](../../../../docs/reference/evidence/2026-11-02/sales-channel-verification/hsbank.md)
与 [hsbank-nav 接入核验](../../../../docs/reference/evidence/2026-11-03/nav-onboarding/hsbank-nav.md)）。

| 文件                                     | 抓取时间         | 原件 SHA-256（本文件字节）                                       | 说明                                                                                                            |
| ---------------------------------------- | ---------------- | ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| catalog-implcprodoct-page1.raw           | 2026-11-02       | 1d4e3d049edc7326ebbbef33aba042428fb31928234fefedfe505f68804728ed | 目录第 1 页（total=6526，10 行）：兴银 9261076D（封闭 749 天 Z 码）/苏银 J31946（无固定期限）/徽银多行多管理人  |
| nav-productNetValue-PNHY200013-1.raw     | 2026-11-02 23:29 | 958bb95cc5d5b25592da69fbe9700634d32d08f3b93504daac74e304169dac2f | 非现金定开（2020-08-19 成立）收益第 1 页：total=370、周频单位净值（2026-10-30 1.004357 起）                     |
| nav-productNetValue-PNHY200013-37.raw    | 2026-11-02 23:30 | 09613805ea6c2bc60936daf4d6f57db3e1523dad3a33bdf7d74786874ccc9b25 | 同产品末页（第 37 页）：sortNum 361..370，最早 2020-08-18（成立前一日占位）——全史保留实证                       |
| nav-productNetValue-PN19000100_A-1.raw   | 2026-11-03 00:29 | 4355807d2825d787e28a26cfc30ac11fe4f319696fb66c834b87f32e8fd1718f | 现金类（whetherCash=1，2019-01-23 成立）第 1 页：total=2819、万份收益日频（2026-10-31 0.2969）＋7 日年化        |
| nav-productNetValue-PN19000100_A-2.raw   | 2026-11-03 00:29 | 1bbe9c333ab1ac979d463f9805a735f202c3fc5b677e744cb706e9f298b2c8ac | 同产品第 2 页：sortNum 11..20 跨页连续性实锤                                                                    |
| nav-productNetValue-PN19000100_A-282.raw | 2026-11-03 00:29 | e108b53f6ad3dfe457efa90b04d88e30d611a25344ee36092c3bac78dfd81257 | 同产品末页（第 282 页）：sortNum 2811..2819，最老 2019-01-22 占位行 tenThousand="0.0000"（序列级口径材料）      |
| nav-productNetValue-J02037-1.raw         | 2026-11-03 00:31 | 880d1b69c103f59c090d12e7f61a73e6f3881d79abc237e6166f77d5f4225a6f | 第三方管理人（苏银理财恒源季开放1号F，2022-01-06 成立）第 1 页：total=155、约周频单位净值——第三方收益存在性补证 |

## modified/（合成负例，非官方事件）

| 文件                        | 构造方法（相对 real/ 原型）                    | 验证目标                           |
| --------------------------- | ---------------------------------------------- | ---------------------------------- |
| nav-foreign-productcode.raw | PN19000100_A 第 1 页第 1 行 productCode 改他码 | 同码隔离：share_mismatch 整页拒绝  |
| nav-truncated.raw           | PN19000100_A 第 1 页截断前 900 字节            | 坏 JSONP：not_jsonp                |
| nav-duplicate-date.raw      | 第 2 行日期改为与第 1 行相同                   | 日期严格递减：dates_not_descending |
| nav-bad-decimal.raw         | 第 1 行 tenThousand 字符串改为 JSON 数字       | 数值保真：not_a_string:tenThousand |

样本背景（登记编码证据、管理人分布、周频/日频口径、占位行）见来源报告
`docs/reference/rebuild-p4-source-hsbank-web-v1-report.md`。银行请求计数：0。
