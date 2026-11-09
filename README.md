# wealth-observer 第二版采集执行仓（wor）

本仓库是 wealth-observer 重构第二版的公开采集执行仓：只承载发行产物、每源独立调度 workflow 与运维说明，不含源码历史、source map、密钥或真实数据包。发行由私有开发仓的 `p4-release` 工具构建，经发布白名单逐文件 SHA-256 核验后完整同步；本仓不手工修改产物文件。

## 当前发行

- runId `20261109T101502Z-rel13`（implementationCommit `1bd0440b4c8cb12143e777d68c8d4f1775e34487`）
- 19 个 collector 包：`dist/p4-release/<collectorId>/`（collector.mjs + p4.mjs + fixtures + config.example.json + licenses + manifest.json + workflow 副本）
- `dist/p4-release/migrations/`：23 份 SQL（新空库按文件名依序重放建库）
- `.github/workflows/`：每 collector 一份独立 workflow（无总任务/矩阵）；workflow 内路径按模板约定写死 `dist/p4-release/<id>/`

## 运行边界

- 定时默认关闭：`config/<collectorId>.schedule.json` 缺失或 `enabled != true` 时，schedule 运行输出跳过原因并直接退出（不请求来源、不写库）。
- 写入需 Secrets：`P4_HTTPS_BEARER`（签名 JWT）与 `P4_HTTPS_API_KEY`（Supabase 网关密钥）；手动 dispatch 默认 `--local-only`（仅保存本地包）。
- 银行来源请求受授权窗口与站点预算约束：每站点每日 ≤20 次（含列表/详情/分页/补采/重试）、并发 1、随机礼貌间隔 1.8–3.2 秒（站点明确要求 T 秒时取 T..T+1.5 秒）。
- `nbcb-archive-v1` 仅为离线版本自检（无网络请求、不引用 Secrets）。
- 公开 runner 只输出 CLI 安全摘要；无 artifact 上传。

## 运维操作（维护者）

- 手动验证：Actions 页对 `p4-nbcb-run`（离线自检）或具体来源 workflow 手动 dispatch；写入验证需先录入 Secrets。
- 启用定时：在授权窗口内提交 `config/<collectorId>.schedule.json`（`{"enabled":true,"mode":"write"|"local-only"}`），窗口结束后关闭。
- 采集运行配置：`config/<collectorId>.run.json`（无秘密；HTTPS 目标 endpoint 指向候选库 RPC）。