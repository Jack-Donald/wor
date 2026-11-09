# bocom-web-v1 测试夹具（真实/修改隔离）

本目录是 P4 S01 新增的包内夹具，与共享目录 `rebuild/fixtures/bocom/`（P3 既有）并存。
分类遵守 K14/S-V04：`real/` 为真实原件摘录（字段值逐字保留，仅调整 JSON 排版并按需
截取行窗口），`modified/` 为人工构造的负例（明确合成，不冒充官方事件）。真实完整
原件与逐页清单仍在本地缓存包（`.local/rebuild/collection-cache/`，不入库）。

## real/（真实原件摘录）

| 文件                    | 来源原件（只读）                                                                                           | 原件 SHA-256（源字节）                                           | 说明                                                                                            |
| ----------------------- | ---------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| 5811225439-detail.json  | P3 缓存包 `bocom-web-v1-20261104t082550z/pages/share_detail-6eaea108.json`（live，抓取 2026-11-04）        | 9e4e8812bf00cee86ed66b23afade016dbaea1c73f622387b384dfe668d9fab1 | 全字段保留（仅去掉服务端调试字段 realIp）；补齐第 4 个真实份额的详情样本                        |
| 5811225439-nav.json     | 同包 `nav_history-85b3a02e.json`（live，2025-09-10..2026-11-03 共 275 行）                                 | d60172d40f5394c2da2ba01b8bc0adfaeb500e37fe6171d1013e33b8e8d04d8e | 尾部 12 行连续摘录（2026-10-19..2026-11-03），行内容逐字保留                                    |
| catalog-count.json      | 旧研究实捕 `apps/collector/fixtures/bocom-catalog-count.raw`（2026-10-29，POST queryJylcProductInfoCount） | a10e695a9e62df603fa98a47df50c459e8234917921663022dd5059c9421d5e3 | 空关键词全目录计数=3                                                                            |
| catalog-list-page1.json | 旧研究实捕 `bocom-catalog-page1.raw`（同日，queryJylcProductInfo 窗口 1..15）                              | 53f47f67ed732c0a9aa93446b09b094a5f7a0c8510d78b1773b369207cee5637 | 3 行：7 天持有 D 份额（人民币）、现金添利（人民币）、1 个月定开（美元，非人民币负样本为真实行） |
| catalog-list-page2.json | 旧研究实捕 `bocom-catalog-page2.raw`（同日窗口 16..30）                                                    | 9e3c1b3af7a5eb2db69c2a4f49a1694c918fcbe53f7cbf542f7fcefd891942d2 | 空窗口（行数已齐后的尾窗真实形态）                                                              |

## modified/（合成负例，非官方事件）

| 文件                       | 构造方法（相对 real/ 原型）                                       | 验证目标                          |
| -------------------------- | ----------------------------------------------------------------- | --------------------------------- |
| catalog-list-rename.json   | catalog-list-page1.json 复制后改一行 c_fundname（模拟更名后状态） | diffCatalogRows 的 renamed 分支   |
| catalog-list-usd-only.json | catalog-list-page1.json 复制后删掉两行人民币行（仅剩美元行）      | assembleCatalogWindows 计数不匹配 |
| detail-foreign-share.json  | 5811225439-detail.json 复制后改 c_fundcode 为他人代码             | 详情身份错配 fail-closed          |

真实抓取时间与请求形态详见来源报告
`docs/reference/rebuild-p4-source-bocom-web-v1-report.md`。银行请求计数：0（全部离线）。
