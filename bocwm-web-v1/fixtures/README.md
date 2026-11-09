# bocwm-web-v1 测试夹具（真实/修改隔离）

分类遵守 K14/S-V04：`real/` 为真实原件（wire 形态逐字节保留，`.raw` 扩展避免被格式化），
`modified/` 为人工构造负例（明确合成，不冒充官方事件）。全部离线取得（主仓研究材料
只读复制，抓取时间 2026-10-30），银行请求数 0。

## real/（真实原件）

| 文件                              | 来源（主仓只读）                                                                                   | 抓取时间   | 原件 SHA-256（本文件字节）                                       | 说明                                                                                                                        |
| --------------------------------- | -------------------------------------------------------------------------------------------------- | ---------- | ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| catalog-keyword-7tian-page1.raw   | `.local/recon-boc-7天.json`（queryStaticProducts 关键词第 1 页）                                   | 2026-10-30 | c57cad65e1c57ca373a59c8c6d80968a91c712fd8533d199a86617137dd4fafc | 20 行，total=118；productDetailUrl 形如 /4/10268.html                                                                       |
| catalog-keyword-zdunchi-page1.raw | `.local/recon-boc-最短持有期.json`（关键词"最短持有期"第 1 页）                                    | 2026-10-30 | fb62a3d95228a9dc31ac01c5b8843473327020a75a44bd9388aefe31103c8811 | 20 行，total=227；含 FCYQZQ18M02F（/4/9881.html 形态）                                                                      |
| catalog-institutional-page1.raw   | `.local/recon-boc-products.json`（机构范围扫描第 1 页）                                            | 2026-10-30 | a896ed40d3bdee76481ee8c231877bbc39c54ec44e4ebf7780804aacb34a7a27 | 10 行，total=2598；productDetailUrl 形如 /3/10328.html（栏目段与 /4/ 不同）                                                 |
| page-list-183-personal.raw        | `.local/recon-https_www_bocwm_cn_html_1_151_183_index_html`（列表页模板；入库形态 CRLF→LF 规范化） | 2026-10-30 | bf6c25d1078f12ffdcab6abfb14f1b5a2ae690be9e789d15d30b8f79f584aa6b | curCategory=183→个人产品；含 queryStaticProducts POST 构造与 investorRange 映射 JS（主仓原件 CRLF 形态 SHA 2ee5746c…dee33） |
| page-list-184-newarrivals.raw     | `.local/recon-https_www_bocwm_cn_html_1_151_184_index_html`（同上规范化）                          | 2026-10-30 | c2ce065b9993d6df6b4f629d917a57fa5828311ca512cf58c3b2c65ab8a783fa | curCategory=184→新品速递（investorRange 空）；与 183 仅 28 字节差异（curCategory/栏目名）（主仓原件 SHA 55553f73…34b5d1）   |
| page-list-222-institutional.raw   | `.local/recon-https_www_bocwm_cn_html_1_151_222_index_html`（同上规范化）                          | 2026-10-30 | 4108019dfc6c53d822467723a8146df6a73f7bd5ef7e2ab794a6a6d54c58ab9f | curCategory=222→机构产品；主仓原件与 `.local/recon-boc-list.html` 字节一致（主仓原件 SHA 11db5cb4…da9021）                  |
| detail-CYQWFZDJQ7D2A.raw          | `apps/collector/fixtures/boc-detail-CYQWFZDJQ7D2A.raw`                                             | 2026-10-30 | c6d0e7ba9214a71ab91f98fd18f1a937acd5951ada349348ef35efe112b5af7a | 稳富中短久期7天持有期2号；Z7001026000523；成立日 2026-05-29；feclrDate='-'（份额成立日缺失）                                |
| detail-CYQWFZDJQ14DA.raw          | `apps/collector/fixtures/boc-detail-CYQWFZDJQ14DA.raw`                                             | 2026-10-30 | bf7de340258b2c031d84fa08aa43b0ef67a73fe7811f1be0fdcdeb2da5acf64e | 稳富中短久期14天持有期；Z7001026000503；成立日 2026-04-17                                                                   |
| detail-CYQWFXYJX30D8A.raw         | `apps/collector/fixtures/boc-detail-CYQWFXYJX30D8A.raw`                                            | 2026-10-30 | 37200d4516b742ec6b802f7a4d095b2ca6423214bf4e4cdab91e1be69a6967d0 | 稳富信用精选30天持有期8号；Z7001025001237；成立日 2026-02-27；对应身份页 /html/1/4/9274.html（probe 样本同产品）            |
| nav-CYQWFZDJQ7D2A-page1.raw       | `apps/collector/fixtures/boc-nav-CYQWFZDJQ7D2A-1.raw`                                              | 2026-10-30 | b1e9203501fab65133275088a9cdea850ebc57969b6df3c3b51cdff3baf3c1be | 100 行（2026-06-01..10-27），total=101；registrationCode 部分行=Z7001026000523（与详情登记码一致）、部分行 null             |
| nav-CYQWFZDJQ7D2A-page2.raw       | `apps/collector/fixtures/boc-nav-CYQWFZDJQ7D2A-2.raw`                                              | 2026-10-30 | 0a0e56c626733c722ee98d88b0a7bec9851520186a5b530c8cc341986d272cdc | 1 行（2026-05-29）；两页合计=total=101                                                                                      |
| nav-CYQWFXYJX30D8A-page1.raw      | `apps/collector/fixtures/boc-nav-CYQWFXYJX30D8A-1.raw`                                             | 2026-10-30 | 57335797e8e5dee3af4e087f83f4c2f7602677289133146bb87b11b19e1348a5 | 100 行（2026-06-01..10-27），total=162；registrationCode 部分行=Z7001025001237、部分行 null                                 |
| nav-CYQWFXYJX30D8A-page2.raw      | `apps/collector/fixtures/boc-nav-CYQWFXYJX30D8A-2.raw`                                             | 2026-10-30 | cc6ec929ca6b28ad17deeee37bb4e6d32c3a4443c1ad1275d8b610e8d992dc9d | 62 行（2026-02-27..05-29）；两页合计=total=162；首行 2026-02-27=成立日（全历史起点）                                        |

编码事实：历史/目录 JSON 原件的中文字段值（productName/productType）为编码受损形态
（研究抓取时的转码问题，字节原样保留）；解析器身份/数值判定全部依赖 ASCII 字段
（代码/日期/数字），中文值只记录不校验。详情 HTML 原件为干净 UTF-8。

分页语义（实测）：第 1 页含较晚日期段、第 2 页向前补早段，页内升序；装配统一升序输出。

## modified/（合成负例，非官方事件）

| 文件                         | 构造方法（相对 real/ 原型）              | 验证目标                              |
| ---------------------------- | ---------------------------------------- | ------------------------------------- |
| nav-foreign-code.raw         | page1 首行 productCode 改 CYQWFZDJQ7D2B  | 同码隔离：share_mismatch 整页拒绝     |
| nav-truncated.raw            | page1 截断前 5000 字节                   | 坏 JSON：not_json                     |
| nav-business-error.raw       | 封套 code 200→500、result true→false     | 业务错误封套：business_error 整页拒绝 |
| nav-total-drift.raw          | page2 total 101→100                      | 动态总数：pagination_total_drift      |
| nav-usd-currency.raw         | page1 第 2 行 currency null→'USD'        | 非人民币行拒绝（not_cny）             |
| nav-registration-mixed.raw   | 两行分别填两个不同 registrationCode      | 登记层混串：registration_mixed 拒绝   |
| catalog-total-drift.raw      | 7天关键词页 data.total 118→100           | 目录动态总数漂移                      |
| catalog-business-error.raw   | 目录封套 code→500、result→false          | 目录业务错误整页拒绝                  |
| catalog-bad-detail-url.raw   | 首行 productDetailUrl 改 javascript: URI | 详情链接形态白名单：bad_detail_url    |
| detail-xjl-true.raw          | xianjinguanli: false→true                | 现金管理类产品拒绝                    |
| detail-holding-mismatch.raw  | shrtstHoldTerm:'7天'→'30天'              | 页面 data 与产品块期限交叉验证失败    |
| detail-wrong-share-code.raw  | 份额代码全文替换为 CYQWFZDJQ7D2Z         | 身份错配 fail-closed                  |
| detail-foreign-currency.raw  | 起购金额"1.00人民币元"→"1.00美元元"      | 币种证据缺失拒绝                      |
| detail-manager-missing.raw   | 免责声明"管理人中银理财有限责任公司"替换 | 管理人锚点丢失拒绝                    |
| detail-structure-changed.raw | 产品块 v-if 锚点替换                     | 详情结构漂移拒绝                      |

样本背景（三码分层、成立日/份额成立日、旧 boc→bocwm 别名对齐）见来源报告
`docs/reference/rebuild-p4-source-bocwm-web-v1-report.md`。银行请求计数：0。
