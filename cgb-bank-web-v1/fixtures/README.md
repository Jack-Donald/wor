# cgb-bank-web-v1 fixtures

夹具分两类（真实原件与合成样本隔离，S-V04）：

- `real/`：真实官方原件。对公目录页 1/98 与最新净值页 2 份为主仓
  `.local/new-source-runs/` 受控来源观测录制的**原始 GBK 字节**（复制后字节不变，
  SHA-256 与录制元数据一致）；个人目录 2 份因旧工具保存的是解码后 UTF-8 文本，
  以 **GB18030 回编字节**入库（原始字节未保留，回编文本来自真实页面逐字保存，
  fixtures/README 如实标注该差异）。
- `modified/`：合成负例——基于真实原件改造，只用于离线负路径验证。

## real/ 清单

| 文件                           | 内容                                                             | 来源/SHA-256（前 16 位）  |
| ------------------------------ | ---------------------------------------------------------------- | ------------------------- |
| corporate-catalog-page1.raw    | 对公目录页 1（12 行满页，total=1171/98 页，GBK 字节）            | 录制原件 149db149b726f116 |
| corporate-catalog-page98.raw   | 对公目录末页（7 行尾页）                                         | 录制原件 e072be4a9581c32a |
| retail-catalog-gbwm-page1.raw  | 个人目录"广银理财"筛选页 1（total=2297/192 页，GB18030 回编）    | 回编 c77b438e880b4caf     |
| retail-catalog-empty-codeB.raw | 个人目录按代码 TLDCLCY14D01B 检索 0 行（合法空态，GB18030 回编） | 回编 39018b1369074c06     |
| latest-XFTLCY0103B.raw         | 最新净值页（2026-10-30，1.04480000，GBK 字节）                   | 录制原件 6f4efec8273d6bba |
| latest-XFTLCY0101A.raw         | 最新净值页（2026-10-30，1.10030000，字段顺序变体，GBK 字节）     | 录制原件 115461ca028a1200 |

未入库：对公目录全部 98 页录制（主仓 `.local/new-source-runs/2026-11-02T00-30-38.983Z-cgb-bank-catalog-7c3e9162-*`，逐页带 bodySha256）；分页装配测试在测试内以真实行构造页壳（不作为原件）。

## modified/ 清单

| 文件                            | 构造方式                 | 验证目标                          |
| ------------------------------- | ------------------------ | --------------------------------- |
| corporate-columns-changed.raw   | 表头"币种"改"货币"       | 表头漂移整页拒绝                  |
| latest-name-mismatch.raw        | h2 产品名改第 9 号       | 名称不一致拒绝                    |
| latest-bbb-mismatch.raw         | var bbb 改其他代码       | 身份不一致拒绝                    |
| latest-bad-nav.raw              | 最新净值改 0.00000000    | 无效净值（无有效数字）拒绝        |
| retail-invalid-gbk-sequence.raw | 真实页插入孤立 0x80 字节 | 非法 GB18030 序列解码 fail-closed |

无密钥、无 Cookie、无完整请求头；原件仅含公开产品数据。
