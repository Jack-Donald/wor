# icbcwm-web-v1 测试夹具（真实/修改隔离）

分类遵守 K14/S-V04：`real/` 为真实原件（wire 形态逐字节保留，`.raw` 扩展避免被格式化），
`modified/` 为人工构造负例（明确合成，不冒充官方事件）。全部离线取得，银行请求数 0。

## real/（真实原件）

来源：主仓只读 `apps/collector/fixtures/`（旧系统 2026-10-30 在产适配器捕获）＋
`docs/reference/evidence/2026-10-30/eight-sources/icbcwm/`（同日来源验证探测）。

| 文件                          | 说明（来源原名）                                                                                                          | 抓取时间   | 原件 SHA-256（本文件字节）                                       |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------- | ---------- | ---------------------------------------------------------------- |
| lookup-114002-25G2955J.raw    | icbcwm-catalog-25G2955J：114002 销售码过滤查询（total=1，prod_id 20 位）                                                  | 2026-10-30 | 873ca7c320ccfbc452642bb683a43b92e92ae55ad0b58bf3f238a5f4836cb1ab |
| lookup-114002-page1.raw       | catalog-114002-p1：未过滤第 1 页 10 行（total=7636；真实 '0,2' 混合销售目标行与 '6' 已到期行）                            | 2026-10-30 | e3e8a7bab2c87e0dd1646c95e94986db907612a849f6a95b4d6c83263f79f635 |
| detail-114003-25G2955J.raw    | icbcwm-detail-25G2955J：114003 详情（Z7000825001384、setup 20250929、父码 25GS2955、rows_history 9 行无 sales_code 字段） | 2026-10-30 | efb4fc927376e7de848a9345254a7fb94d06a0e27354afc195e3db3ab33fd7db |
| navindex-112901-25GS2955.raw  | icbcwm-navindex-25GS2955：112901 净值索引（networth_id 2025100103300500008219）                                           | 2026-10-30 | 310e113f1b9a2c9cc2a4ccce6b1ca64716c84ac9e053c228251af0635e8d68a0 |
| nav-112902-25G2955J-p1.raw    | icbcwm-nav-25G2955J-1：112902 第 1 页 20 行（total=258；date=净值日期与 disclose_date=披露日期并存——业务日期语义样本）    | 2026-10-30 | 307a824aa33e4e56864b3c7739fb366bc92b9eb9b5b116f427aac834a1e94546 |
| nav-112902-pagesize-error.raw | navhistory-112902-empty-pagesize2000：page_size=2000 → succ:false '0003'（真实业务错误负例）                              | 2026-10-30 | 38a76ac2b1607050db8efd48f0c557a530819797c6f0628d0006624c71da275c |

## modified/（合成负例，非官方事件）

| 文件                          | 构造方法（相对 real/ 原型）                     | 验证目标                              |
| ----------------------------- | ----------------------------------------------- | ------------------------------------- |
| nav-foreign-salescode.raw     | nav 第 1 行 sales_code→OTHER1                   | 销售码过滤：外资行跳过（19/20 行）    |
| lookup-corporate-only.raw     | lookup page1 一条在售个人行 sell_target '1'→'2' | 个人公募池排除（法人/机构目标不混入） |
| detail-status-not-on-sale.raw | detail prod_status '1'→'4'                      | 非在售/存续拒绝                       |
| detail-bad-registration.raw   | detail prod_reg_code Z7000825001384→BAD123      | 登记编码损坏拒绝                      |
| navindex-wrong-product.raw    | navindex product_code 25GS2955→OTHER            | 索引无命中拒绝                        |
| lookup-truncated.raw          | lookup-114002-25G2955J 前 900 字节              | 坏 JSON：not_json                     |

样本背景（四步交易码链、TLS/curl 路由、深翻页 504）见来源报告
`docs/reference/rebuild-p4-source-icbcwm-web-v1-report.md`。银行请求计数：0。
