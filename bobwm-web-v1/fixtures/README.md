# bobwm-web-v1 测试夹具（真实/修改隔离）

分类遵守 K14/S-V04：`real/` 为真实原件（wire 形态逐字节保留，`.raw` 扩展避免被格式化），
`modified/` 为人工构造负例（明确合成，不冒充官方事件）。全部离线取得，银行请求数 0。

## real/（真实原件）

来源：主仓只读 `apps/collector/fixtures/`（旧系统 2026-10-30 在产适配器捕获）＋
`docs/reference/evidence/2026-10-30/eight-sources/bobwm/`（同日来源验证探测）。

| 文件                       | 说明（来源原名）                                                                                                             | 抓取时间   | 原件 SHA-256（本文件字节）                                       |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | ---------- | ---------------------------------------------------------------- |
| search-chengxiang-p1.raw   | search-chengxiang.json：KEY=诚享 第 1 页 60 行父产品行（60/60 带 Z7 登记编码、全人民币、NAV 全 null——募集期形态）            | 2026-10-30 | 5bd340c49c318256348347a5e34d68326caddf3885d53a7795146811228cc4f7 |
| info-YJ01251204A.raw       | bobwm-detail-YJ01251204A：子份额详情（春系列诚享7天持有期29号A，Z7008926000006）                                             | 2026-10-30 | e94438657aad0295046909cdb9ddc326fbe78af25fbfed4a981db30d392ac45d |
| info-parent-YJ01251204.raw | info-YJ01251204.json：父产品 info（PARENT_PROD_CODE 为空——父行不可作份额详情的负样本）                                       | 2026-10-30 | 1a85927163d5fddf6df3e0d8a94fae295766a38025cf8bc379a6070e91e97c55 |
| subs-YJ01251204.raw        | subs-YJ01251204.json：父→子份额连接（data 数组：YJ01251204A / A类份额）                                                      | 2026-10-30 | 3938aa293b3715c2e33522212063e398791e6244abab1e7e30d0dfe016c0fd32 |
| navlist-YJ01251204A-p1.raw | bobwm-nav-YJ01251204A-1：全历史 105 行（2026-05-27→2026-10-29，pageSize=2000 单页；NAV/ACCUMULATIVE_NAV 为 JSON 数字字面量） | 2026-10-30 | 1a28c888a306d010d6c103ab21d7e71e677cab08702a34b463a7385558109c4e |

## modified/（合成负例，非官方事件）

| 文件                             | 构造方法（相对 real/ 原型）                          | 验证目标                            |
| -------------------------------- | ---------------------------------------------------- | ----------------------------------- |
| navlist-foreign-code.raw         | navlist 首行 PROD_CODE→OTHER01                       | 子份额隔离：share_mismatch 整页拒绝 |
| navlist-lexeme-trailing-zero.raw | 附加一行 NAV/ACCUMULATIVE_NAV=1.1000（尾随零字面量） | 数值词法保真（"1.1000" 而非 "1.1"） |
| navlist-truncated.raw            | navlist 前 1500 字节                                 | 坏 JSON：not_json                   |
| info-null-data.raw               | `{"data":null,"state":"ok"}`                         | 空数据封套拒绝                      |
| search-state-error.raw           | search-chengxiang-p1 state ok→error                  | 错误态封套整页拒绝                  |

样本背景（四件套链路、净值挂子份额、域名勘误 boimc=内蒙古银行）见来源报告
`docs/reference/rebuild-p4-source-bobwm-web-v1-report.md`。银行请求计数：0。
