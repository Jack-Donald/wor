# cmb-web-v1 测试夹具（真实/修改隔离）

分类遵守 K14/S-V04：`real/` 为真实原件（wire 形态逐字节保留，`.raw` 扩展避免被格式化），
`modified/` 为人工构造负例（明确合成，不冒充官方事件）。全部离线取得，银行请求数 0。

## real/（真实原件）

来源：主仓只读 `apps/collector/fixtures/`（旧系统 2026-10-30 在产适配器捕获）＋
`.local/cmb-expander/`（2026-10-30 招行渠道扩容研究）。登记编码证据（说明书 PDF 展示层
人工核验，如 107514→Z7001621000276）见主仓 `.local/cmb-expander/overview-fields.json`。

| 文件                   | 说明（旧仓原名）                                                            | 抓取时间   | 原件 SHA-256（本文件字节）                                       |
| ---------------------- | --------------------------------------------------------------------------- | ---------- | ---------------------------------------------------------------- |
| detail-107381A.raw     | cmb-detail-107381A：招睿添利7天持有期1A（持有型）                           | 2026-10-30 | 169f27cc95fe8e7b639d1f6d3b3be82f1e539a92bfcfecbd834d692c3bd07394 |
| detail-107507.raw      | cmb-detail-107507：丰和短债7天持有期1号（登记 Z7001621000275）              | 2026-10-30 | ea6c13aaf7bbfcc2926ed73b4edd2c0a814f02b807e6d1e529bb2a112c3f578b |
| detail-110408B.raw     | cmb-detail-110408B：招睿日开14天滚动持有-B（"每7天可赎"周期型真实形态）     | 2026-10-30 | cb13e8e291b78bdea9b3331836896604631e38783d7f01b35a870e7b9f58d155 |
| detail-120015A.raw     | cmb-detail-120015A：招睿添金（和享）7天持有期5A（登记 Z7001625000014）      | 2026-10-30 | 8492445bf1b0bcdb1c6ed1a84c93ef0044dcdfb69c21f9b8767f344ced229b15 |
| detail-120015S.raw     | cmb-detail-120015S：同产品 5S 份额（与 120015A 同登记编码——多份额隔离样本） | 2026-10-30 | 974a63f32434037d1e718e9f33a5c6e84e696be50bb3e9f4ce6b5a3d665e6a21 |
| nav-107381A-p1/2.raw   | cmb-nav-107381A-1/2：游标第 1/2 页（各 30 行降序）                          | 2026-10-30 | e13c0ea3…/08a7265d…（全值见下）                                  |
| nav-107507-p1/2/3.raw  | cmb-nav-107507-1/2/3：三页连续（09-14→10-29 窗口 90 行）                    | 2026-10-30 | 5a07f43e…/0165642c…/c7968637…                                    |
| nav-110408B-p1/2.raw   | cmb-nav-110408B-1/2                                                         | 2026-10-30 | d6a4a818…/727c7061…                                              |
| nav-120015A-p1/2/3.raw | cmb-nav-120015A-1/2/3                                                       | 2026-10-30 | 68ca3b81…/3dfd8d46…/18c99233…                                    |
| nav-120015S-p1/2/3.raw | cmb-nav-120015S-1/2/3                                                       | 2026-10-30 | cce8fa41…/20dcd389…/8da051c8…                                    |

净值页 SHA-256 全值：
e13c0ea3d49550215436341a2511062d42887b5ca5752b402d7cf964967db223（107381A p1）、
08a7265dcba67ebfec94f9d79338fab72d85d0617ed7488559ebe78188f4b5dd（107381A p2）、
5a07f43e05fb5b1e6c20579ab16281466524c4f186eeef17526474122b232d2b（107507 p1）、
0165642c1e5f5923e5dd0881d5cbcaff63a8c3116a1afb743dcac2cea353e19e（107507 p2）、
c79686376cf694a0ab158c73127014b6e0ae4ef09c9116b2a8ea5c5cd9442364（107507 p3）、
d6a4a818c9d4e00068f3ffdc1f89b9c30c65eb1acdcf26ac6c95eacb98903142（110408B p1）、
727c7061838df9c66233878c19b3e9c330d1f3a9fe63601df91459a0aeb8bb7a（110408B p2）、
68ca3b81d1472a5bf52d9038b42419211ec93b6daeb36610abdb37c745b3c0a1（120015A p1）、
3dfd8d469748d4a26c3ed8d8338846d4821c6ce3441c2e738b8c420625fe681b（120015A p2）、
18c99233eb281a87ac20fbe76d568c4148be4d8cba3e9af034ee98e1610c2252（120015A p3）、
cce8fa416249b2a9e574753b5feeb9ced9a45dcd12979aefa9f0c48361a3e1c1（120015S p1）、
20dcd389fef6bb805bcc36bb8c9fe9f8c4cf3800a8aa41b349103474224b48cc（120015S p2）、
8da051c80f46084a0773b3942112e2f81e90fa596fcba2a712b734f6fd5fa9ac（120015S p3）。

## modified/（合成负例，非官方事件）

| 文件                        | 构造方法（相对 real/ 原型）                | 验证目标                         |
| --------------------------- | ------------------------------------------ | -------------------------------- |
| detail-navtyp-cash.raw      | detail-107381A navTyp N→C                  | 现金管理类产品拒绝               |
| detail-quainv-qualified.raw | detail-107381A quaInv N→Y                  | 仅限合格投资者（非公众）拒绝     |
| detail-non-cny.raw          | detail-107381A ccyNbr 元→美元              | 非人民币拒绝                     |
| detail-wrong-share.raw      | detail-107381A ripInn/ripNbr→OTHER         | 份额身份错配 fail-closed         |
| detail-term-unknown.raw     | detail-107381A terDay 持有7天…→每日可赎    | 期限未知（不猜，null）           |
| nav-foreign-cursor.raw      | nav-107507-p1 yFndInn→OTHER                | 游标份额错配整页拒绝             |
| nav-truncated.raw           | nav-107507-p1 前 2000 字节                 | 坏 JSON：not_json                |
| nav-business-error.raw      | nav-107507-p1 bizResult.code 200→500       | 业务错误封套拒绝                 |
| nav-duplicate-date.raw      | nav-107507-p1 第 2 行日期改为与第 1 行相同 | 重复/乱序日期整页拒绝（30 行内） |

样本背景（登记证据、120015A/S 多份额、robots 豁免范围）见来源报告
`docs/reference/rebuild-p4-source-cmb-web-v1-report.md`。银行请求计数：0。
