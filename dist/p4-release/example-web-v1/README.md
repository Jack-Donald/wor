# example-web-v1 采集器发行包（P4 独立闭合产物）

- runId：2026-11-09T132031Z-rel17
- implementationCommit：bc477f959719e9407741ff0919c243b23eec18e5
- collectorId/sourceId：example-web-v1 / example；parserVersion：example-web/v1
- 内核：p4-orchestration/v1；protocolVersion：wo-ingest-v2；algorithmVersion：wo-return-v1
- 能力声明：catalog=支持；collect=拒绝；evaluate=拒绝；repair=拒绝；importLocal=支持
- 在线主机（仅采集时请求）：（无在线主机：离线示例源）

## 运行要求（外部依赖不在包内）

- Node.js ≥22（Windows/Linux 均可；本包无本机编译依赖）。
- 写库通道三选一：
  1) docker CLI ＋ 目标容器（`docker exec <容器> psql`，容器内提供 psql）；
  2) 本机 psql（原生主机连接；非回环主机必须 PGSSLMODE=verify-full，密码经
     PGPASSWORD/.pgpass 由运行环境提供，不写入任何文件）；
  3) HTTPS PostgREST 受限 RPC（endpoint 写在 config，令牌经 env-runtime.json 或
     P4_HTTPS_BEARER 环境变量提供）。
- 数据库兼容：PostgreSQL 18.4（P2/P3 隔离验证版本；psql 协议兼容性由官方客户端
  保证）；PostgREST 14.5（P2 验证版本）。psql 与 HTTPS 两种传输结果一致（V17 语义）。

## 使用（全部命令零网络即可启动：help/version/parse）

```bash
node collector.mjs --help                                  # 解析器帮助（离线）
node collector.mjs --version                               # 解析器/协议版本
node collector.mjs parse --kind <kind> --page <已保存页面绝对路径>   # 包内 fixtures 可直接重放
node p4.mjs help                                           # 编排 CLI 帮助
node p4.mjs version                                        # 内核与适配器版本
node p4.mjs collect --config run.json --mode daily --local-only   # 无数据库凭据可运行
node p4.mjs import-local --config run.json --bundle <包目录> --preview
```

- run.json 按 `config.example.json` 修改（占位值替换为实际绝对路径；不含任何秘密）。
- 在线 collect 受 config 网络预算与随机礼貌间隔约束（默认 1.8–3.2 秒；站点明确
  要求 T 秒时以站点要求为准，T 至 T+1.5 秒随机）。
- 调度入口：`workflow-example-web-v1.yml`（独立 workflow 模板副本；固定 action
  提交 SHA、最小权限、受控分支；Secrets 只列名称不含值）。
- 文件清单与哈希见 `manifest.json`；本包不含 source map、真实本地包与任何凭据。

## 安全边界

- 本包构建全程无凭据参与（K14 语义）；任何秘密不得写入包文件或命令行参数。
- 公开 runner 只输出安全摘要，不上传真实本地包（PageStore 包留执行机本地）。

