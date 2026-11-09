# cmbcwm-web-v1 测试夹具（真实/修改隔离）

分类遵守 K14/S-V04：`real/` 为真实原件（wire 形态逐字节保留，`.raw` 扩展避免被格式化），
`modified/` 为人工构造负例（明确合成，不冒充官方事件）。全部离线取得，银行请求数 0。

## real/（真实原件）

| 文件                         | 来源（主仓只读）                                       | 抓取时间         | 原件 SHA-256（本文件字节）                                       | 说明                                                                                                                                                |
| ---------------------------- | ------------------------------------------------------ | ---------------- | ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| catalog-page1.raw            | `apps/collector/fixtures/cmbcwm-catalog-page1.raw`     | 2026-11-03 16:29 | abaf5d0197d9495a74ada78e2410796f2cd2ba60645bccb06323e1a371fcbf63 | BTAProductQry 首页 10 行：totalSize=5199；FBAE37404S/FBAG62230D/Q/S（同 Z7007925001263 三份额）、FBAE43526A/B/G/K/Q/S（同 Z7007925000831 六份额）等 |
| catalog-FGAE61002-search.raw | `apps/collector/fixtures/cmbcwm-catalog-FGAE61002.raw` | 2026-11-03 16:29 | a341db4c1520d2be678329a11e4dfdd6399a39771170d8bc56fab2023da6c6ca | code_or_name=FGAE61002 检索：totalSize=1 精确命中 FGAE61002G（Z7007922000054，2022-05-25 成立，91 天持有期机构款）                                  |
| nav-FBAE37404S.raw           | `apps/collector/fixtures/cmbcwm-nav-FBAE37404S.raw`    | 2026-11-03 16:30 | 8f539519762a3a9379f996d267603b7ff401691f3648d73ef061c276f2814c9b | BTADailyQry chart_type=0 全量 191 行，2026-01-13 → 2026-10-29（短样本）                                                                             |
| nav-FGAE61002G.raw           | `apps/collector/fixtures/cmbcwm-nav-FGAE61002G.raw`    | 2026-11-03 16:30 | e0e95559631915a67f8158ed839279d6c31db61b576d12ca0ed697aa58925188 | 全量 1,075 行，2022-05-25 → 2026-10-29（约 53 个月，G2 深度坐实样本；含 0.9992 等低于面值行）                                                       |

原始响应亦存主仓私有 `.local/nav-onboarding/cmbcwm/`；字段级映射与请求证据见
[民生理财准入记录](../../../docs/reference/evidence/2026-11-03/nav-onboarding/cmbcwm.md)。

## modified/（合成负例，非官方事件）

| 文件                       | 构造方法（相对 real/ 原型）   | 验证目标                                            |
| -------------------------- | ----------------------------- | --------------------------------------------------- |
| catalog-business-error.raw | 首页 returnCode 改 IGW0001/E  | 业务错误封套（含瞬态误报形态）：business_error 拒绝 |
| catalog-non-cny-row.raw    | 首页首行 CURR_TYPE 改 840     | 币种行级判定：非 156 行准入时拒绝                   |
| catalog-truncated.raw      | 首页截取前 3000 字节          | 坏 JSON：not_json                                   |
| nav-total-mismatch.raw     | 191 行历史 totalSize 改 190   | 单请求全量契约：incomplete_history 拒绝             |
| nav-duplicate-date.raw     | 首行复制追加                  | 重复业务日期：duplicate_date 拒绝                   |
| nav-value-tampered.raw     | 词素 1.00010000 改 9.99990000 | 词素保真基线（改动应被哈希/断言检出，证明原件未动） |

样本背景（词素保留、前缀检索语义、OPEN_DAYS≠持有期、24 个月窗口 483 行等）见来源报告
`docs/reference/rebuild-p4-source-cmbcwm-web-v1-report.md`。银行请求计数：0。
