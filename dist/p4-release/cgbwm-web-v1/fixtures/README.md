# cgbwm-web-v1 fixtures

夹具分两类，使用方式与 P3/P4 交付标准一致（真实原件与合成样本隔离，S-V04）：

- `real/`：真实官方原件（只读复制，字节不变），来源为主仓 `.local/new-source-runs/`
  的受控来源观测录制（旧系统 `new-sources --source=cgbwm` 产物，每页带请求 URL/
  响应头/SHA-256 元数据）。采集日期 2026-11-01/02（录制元数据 `fetchedAt`）。
  解析测试逐份对照录制元数据中的 `bodySha256` 核验完整性。
- `modified/`：合成负例——基于真实原件改造或显式构造，只用于离线负路径验证，
  文件名带 `-synthetic` 后缀者为完全合成（真实现金类份额历史未录制，按矩阵要求
  以清楚标注的合成负例验证工程分支，不伪造真实官方事件）。

## real/ 清单（SHA-256 与录制元数据一致）

| 文件                            | 内容                                                | SHA-256（前 16 位）                 |
| ------------------------------- | --------------------------------------------------- | ----------------------------------- |
| currency-dict.raw               | 币种字典（人民币=156/美元=840）                     | a3f41dde1284ac65                    |
| catalog-search-XFTLCY7D01A.raw  | 目录精确检索页（totalNum=1，fetchNum=10）           | 2f9f7ff77f270590                    |
| catalog-search-TLDCLCY7D50B.raw | 目录精确检索页（fetchNum=100）                      | 94d1462728bb29b3                    |
| catalog-search-XFTLCY0103B.raw  | 目录精确检索页                                      | 2028d462fad7c99d                    |
| detail-XFTLCY7D01A.raw          | 详情（Z7006622000104，公募，R2）                    | 035e3de9caea0d3a                    |
| detail-TLDCLCY7D50B.raw         | 详情（Z7006626000820，公募，R2）                    | e4f5fcc69f00ed48                    |
| detail-XFTLCY0103B.raw          | 详情（Z7006624000068，公募，R2）                    | 2124eb4fb3e3fce6                    |
| nav-XFTLCY7D01A-page1/2.raw     | 净值历史 2 页（降序，单位+累计）                    | a64d6dccfcc1e74a / 13a760fccf3b7779 |
| nav-TLDCLCY7D50B-page1.raw      | 净值历史 1 页（新份额仅 2 行：1.0000→1.0001）       | 6b0f77f3ada6e0d8                    |
| nav-XFTLCY0103B-page1/2.raw     | 净值历史 2 页（fetchNum=100，totalNum=546，未取满） | 49a62ce41b2c64f7 / 03bb3e15c5c572e8 |

未入库的大页：全量公募目录第 1 页（beginNum=0/fetchNum=100/totalNum=3903，
93,749 字节，bodySha256=8c948f49b535e368aa67df6774b50ae223f9804014f2677bd3727c501ed7bb4b，
2026-11-02 录制）体量过大不入仓库；本机可取（主仓 `.local/new-source-runs/
2026-11-02T01-56-18.413Z-cgbwm-920b694d-c1cf-4c3a-8f58-132b396c63dc/raw/<sha>`），
多行分页装配测试使用真实行拼装页壳在测试内构造（见 cli.test.ts，不作为原件）。

## modified/ 清单

| 文件                            | 构造方式                     | 验证目标                     |
| ------------------------------- | ---------------------------- | ---------------------------- |
| catalog-business-error.raw      | 真实检索页 retCode 改 999999 | 业务错误封套整页拒绝         |
| detail-private-fund.raw         | 真实详情 clcMthCd 改 '1'     | 私募不可准入（private_fund） |
| nav-truncated.raw               | 真实历史页字节中段截断       | not_json 拒绝                |
| nav-cash-manage-synthetic.raw   | 合成 isCashManage='1' 行     | 现金类份额历史明确拒绝       |
| currency-dict-changed.raw       | 合成 人民币=999              | 币种字典漂移拒绝作币种证据   |
| nav-page-overflow-synthetic.raw | 合成 list 行数>fetchNum      | page_overflow 拒绝           |

无密钥、无 Cookie、无完整请求头；原件仅含公开产品数据。
