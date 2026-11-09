# hxb-web-v1 测试夹具（真实/修改隔离）

分类遵守 K14/S-V04：`real/` 为真实原件（wire 形态逐字节保留，`.raw` 扩展避免被格式化），
`modified/` 为人工构造负例（明确合成，不冒充官方事件）。全部离线取得，银行请求数 0。

## real/（真实原件）

来源：主仓（只读）`apps/collector/fixtures/hxb-*.raw`，2026-11-02 实捕字节原样复制
（行尾说明：_99.html 原捕获字节含 CRLF，入库统一为 LF 规范化形态；抓取过程见主仓 [hxb 渠道验证](../../../../docs/reference/evidence/2026-11-02/sales-channel-verification/hxb.md)）。

| 文件                           | 抓取时间   | 原件 SHA-256（本文件字节）                                       | 说明                                                                                                  |
| ------------------------------ | ---------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| catalog-get-licai-page1.raw    | 2026-11-02 | ffa0aa1269dd201de55eb78da1a8b285f3e121dd0c7e50cf0e49890140ae1b5b | 目录第 1 页（pretty JSON＋尾逗号 wire 形态，pageCount=424、10 行）：中银美元×2（外币筛除）＋招银 8 行 |
| instruction-10815NJ-99html.raw | 2026-11-02 | 92ecaebd7733cb34ea41c80690b34b60c69d366cb1ae7e90ba6d5227ddb72c6a | `/lcpdf/10815NJ_99.html` 销售文件（610KB，Word 导出 HTML）：含"产品登记编码：Z7001624000731"          |

## modified/（合成负例，非官方事件）

| 文件                    | 构造方法（相对 real/ 原型）       | 验证目标                            |
| ----------------------- | --------------------------------- | ----------------------------------- |
| catalog-truncated.raw   | 目录页 1 截断前 3000 字节         | 坏 JSONP/JSON：not_jsonp / not_json |
| instruction-no-code.raw | 原件删除全部登记编码字样与裸 Z 码 | 身份证据缺失 → null（不猜）         |

样本背景（登记编码文档层提取、外币名称筛选、期限名称口径）见来源报告
`docs/reference/rebuild-p4-source-hxb-web-v1-report.md`。银行请求计数：0。
