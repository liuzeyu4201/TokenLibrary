# 服务端、部署与同步可靠性调查

调查日期：2026-09-26。对象：书籍、论文、笔记组成的个人资料库，以及“iPhone、Mac 都连不上，缺少错误和重试”的当前反馈。

本文以现有代码、配置和隔离测试为依据，并纳入主任务执行的一次无凭据公网健康检查。没有读取 `.env`、登录真实服务器、重启已有容器或接触真实资料。本文不复制实际公网 IP 或凭据。只修改研究/测试文档。这里的优先级表示产品可靠性影响，不是一次完整安全审计。

## 结论

现有后端的本机 HTTP 登录和基础数据写入可以跑通：认证/合并 8 个单测、API 3 个隔离集成测试均通过，详见 [服务端测试基线](../testing/server-baseline.md)。主任务对源码默认服务地址执行无凭据 `GET /health/ready`，得到 HTTP 200、`{"maintenance":false,"ready":true}`；没有登录或写入数据。因此不能把两个客户端的“连不上”直接归因于服务器宕机或 Go API 全部失效。当前应优先验证客户端传输限制、设备网络及错误被吞掉的路径。

部署存在一个可从代码直接确认的配置差异：`make start` 固定使用开发 Compose，只把应用端口绑定到宿主机 `127.0.0.1:8080`；它没有启动另一份服务器 Compose 中的 Nginx，更没有实现技术方案中的 HTTPS/Certbot。修改 `PUBLIC_BASE_URL` 不会改变监听地址或端口映射。若仅按此默认入口启动且无其他反代，外部 Mac/iPhone 无法直接访问这个端口。这是部署风险，**不是本次用户故障的已证实根因**；上述公网 ready 已通过，表明实际部署至少另有可达入口。

## 哪些能力已接通

| 能力 | 实现与边界 | 代码证据 |
| --- | --- | --- |
| Go 服务启动 | 读取环境配置、连接 PG、校验 schema、启动 jobs 和 HTTP；SIGTERM 后关闭 HTTP | [main.go](../../server/cmd/tokenlibrary/main.go)，18–47 行 |
| 登录与会话 | 一个配置中的管理员；Argon2id 密码摘要；随机 session token，数据库保存 SHA-256；90 天不活跃过期；可注销 | [authn.go](../../server/internal/authn/authn.go)，16–61 行；[api.go](../../server/internal/api/api.go)，102–201 行 |
| 增量同步 API | `GET /sync/changes` 按 seq 分页；操作事务持有 library 行锁，校验 epoch，保存幂等记录 | [api.go](../../server/internal/api/api.go)，314–341 行；[engine.go](../../server/internal/synceng/engine.go)，80–154 行 |
| 冲突处理 | Markdown 三方合并，Mermaid/数学块保护，必要时调用 `git merge-file`；注释按 ID 合并；冲突记录可查询/解决 | [merge.go](../../server/internal/merge/merge.go)，82–106、320–409、422–487 行；[engine.go](../../server/internal/synceng/engine.go)，262–308、382–417 行 |
| PDF/图片文件传输 | 创建 upload、暂存分片、整体长度/SHA-256 校验、临时文件改名发布；下载带 ETag/Range | [api.go](../../server/internal/api/api.go)，458–624 行 |
| 独立导入 | upload token 保护 imports 路由；Markdown/PDF 导入并自动处理重名 | [api.go](../../server/internal/api/api.go)，64–66、136–154、634–717 行 |
| 回收站 | 删除时设 30 天期限；后台清理正文等数据并写 tombstone；支持恢复 | [engine.go](../../server/internal/synceng/engine.go)，311–379 行；[jobs.go](../../server/internal/jobs/jobs.go)，37–75 行 |
| 备份入口 | 定时检查、maintenance 标志、数据库导出、文件复制、备份记录确实存在；完整性和恢复保障不完整 | [jobs.go](../../server/internal/jobs/jobs.go)，23–181 行 |

## 当前连接故障的优先排查

### SR-01 / P1：默认启动入口只服务本机

**静态确认。** [Makefile](../../Makefile) 第 4 行固定 `deploy/compose.yaml`；该 Compose 第 49 行为 `127.0.0.1:8080:8080`。`make start mode=service` 仅 build/stop/up app，ready 检查也只访问本机回环地址（Makefile 29–37 行）。本机 ready 通过不能证明其他设备可访问。

[compose.server.yaml](../../deploy/compose.server.yaml) 第 54–64 行另有 Nginx，宿主机暴露 80；但默认 Makefile 不使用它。两份配置通过语法校验，不代表它们已在真实服务器运行。

**后续实现/验收：**明确一个部署入口及对应客户端基础地址；确认实际使用的 Compose 和端口；本机 ready、同网络设备访问和公网访问分别验收。公网生产入口应完成证书与 HTTPS 后再配置客户端。不要为排障把数据库端口开放到公网。

### SR-02 / P1：技术方案中的 HTTPS/WSS 部署尚未落地

**静态确认。** [nginx.conf](../../deploy/nginx.conf) 第 2–3 行只监听 80，没有 TLS 配置；服务器 Compose 没有 Certbot 服务、443 映射和证书卷。Go 使用 `ListenAndServe`，不是 TLS（[main.go](../../server/cmd/tokenlibrary/main.go)，34–38 行）。`PUBLIC_BASE_URL` 只被读取/校验（[config.go](../../server/internal/config/config.go)，41、80–85 行），没有配置服务监听、反代或证书的功能。

若客户端输入 `https://…` 而实际只运行此 HTTP 入口，不能建立预期 TLS 连接；是否如此发生在用户设备尚未验证。不能以关闭 TLS 校验作为修复方案。

### SR-03 / P1：启动目录权限可能阻止进程就绪

**代码风险，未实机复现。** 应用以 UID/GID 10001 运行（[compose.yaml](../../deploy/compose.yaml)，52 行），Makefile 第 22 行只用调用用户创建目录，没有授予应用用户写权限。服务启动必须创建 data 下多个目录与 backup root，失败直接退出（[store.go](../../server/internal/store/store.go)，62–71 行）。在普通 Linux bind mount 权限下，需要实际检查目录所有权；本轮未读取或修改真实路径。

**后续实现/验收：**部署准备阶段用明确的 UID/权限方案检查 app 可写目录；打印不含凭据的失败路径和原因。在权限不满足时应在停止旧服务前失败。

### SR-04 / P2：服务端诊断信息不足以区分网络、认证与维护失败

**静态确认。** API 使用 `gin.New()` 与 Recovery，没有请求日志中间件（[api.go](../../server/internal/api/api.go)，38–42 行）；`LOG_LEVEL` 虽读取，但没有应用到日志设置。ready 失败只输出 `{"ready":false}`，内部 DB/schema 错误没有记录（79–86 行）；进程主入口仅记录启动/致命错误。`requestId` 存在于响应，但没有配套可关联的服务端请求日志（776–784 行）。

**后续实现/验收：**记录 requestId、路径、状态码、耗时、稳定错误码；隐藏密码/token/正文。客户端分别显示 URL 不合法、DNS/连接失败、TLS 失败、401、503 maintenance 和其他服务端错误；503 已提供 `Retry-After: 30`（255–258 行），可供客户端重试逻辑使用。客户端改动由独立工作项实现。

## 同步协议与资料可靠性缺口

### SR-05 / P1：基础后端流程通过不等于两端完整同步

**静态确认。** `/ws` 只返回普通 HTTP JSON，不做 WebSocket upgrade（[api.go](../../server/internal/api/api.go)，725–726 行），所以目前应以增量轮询为可用机制。[schema/initial.sql](../../server/schema/initial.sql) 有 `sync_snapshots` / `sync_snapshot_items` / `conflict_drafts` / `blob_refs` / `jobs`，但 `server/` 检索未见相应业务读写（除部分表被备份枚举）。不能将“存在数据库表”当成新设备全量快照、草稿同步、文件引用 GC、可靠作业队列已完成。

**后续验收：**新空设备拉取完整目录/正文/注释与所需文件；100 条以上变更翻页；离线队列在重启和重新登录后恢复；断点上传；旧 epoch 不重放；删除与远端变更传播。两端 UI、后台调度和文件下载均需单独验证。

### SR-06 / P1：导入重试的幂等输入不稳定

**静态代码结论，尚未加入自动复现。** `/imports` 接收稳定的 `Idempotency-Key`，但每次请求重新生成 object ID，PDF 还重新生成 blob ID（[api.go](../../server/internal/api/api.go)，640、677、694 行），随后以新 envelope JSON 计算操作 hash；相同 operation ID 的 hash 不同会返回 `IDEMPOTENCY_MISMATCH`（[engine.go](../../server/internal/synceng/engine.go)，92、114–118 行）。第一次成功但响应丢失后，重传同一导入不能按预期返回原结果，PDF 还可能留下多余 blob。

**后续实现/验收：**导入用稳定的文件内容/目标参数请求摘要，在创建对象和写文件之前查询同 operationId 的最终结果；相同请求重放结果，不同请求拒绝。以响应丢失后的同键重传作为回归场景。当前已有 API 测试只覆盖新键导入和重名后缀，没有覆盖这一场景。

### SR-07 / P2：普通操作幂等目前按原始 JSON 字节判断

**静态确认。** API 把原始 body 传入 Apply，Apply 对原始 bytes 求 SHA-256（[api.go](../../server/internal/api/api.go)，222–251 行；[engine.go](../../server/internal/synceng/engine.go)，92 行）。`canon` 已用于快照，却未用于此输入。因此字段顺序/空白不同但语义相同的重试仍会被视为不一致。客户端应持久保存可重放的操作正文，或统一稳定规范化后再校验 hash；验收不能只重发完全相同字符串。

## 备份、恢复和运维边界

### SR-08 / P1：当前备份的 success 不足以承诺可恢复

**静态确认；已有集成测试只断言成功记录。** [jobs.go](../../server/internal/jobs/jobs.go) 中：

- 99–100 行仅设 maintenance 标志；没有等待在途写入结束的独占门闩，分片写入和 complete 路由也未检查 maintenance（[api.go](../../server/internal/api/api.go)，527、556 行）。数据库与文件副本的一致性尚未被证明。
- 114 行忽略 `copyDir` 错误；copyDir 167–168、175–177 行还会吞掉遍历/读取错误。文件缺失仍可能生成成功记录。
- 125–132 行 `pg_dump` 失败后静默改用 logicalDump。fallback 输出 JSON 行，既没有 DDL/INSERT，也不含所有表（135–162 行）；没有配套恢复器。正常 `pg_dump` 也未使用技术方案中的 custom 格式。
- manifest 只有 ID/时间等字段，没有逐文件和 dump 的长度/哈希（115–120 行）；`verified_at` 在写成功记录时直接赋 now，没有执行恢复校验。
- `BackupTimeout` 只解析，未用于运行超时；没有隔离恢复后更换 epoch、撤销会话和恢复校验工具。

**后续实现/验收：**先实现可恢复格式、文件完整性验证、写入协调、超时/取消和失败传播；然后将备份恢复到全新的隔离数据库/目录，核对 Markdown、书籍/论文 PDF、批注、冲突和文件哈希。只有完成该恢复演练，才能把“备份成功”当作资料恢复保障。

### SR-09 / P2：清理与调度只完成基础路径

**静态确认。** `PurgeExpired` 删除对象相关 DB 记录，却不清理 blob/暂存文件；到期备份只删数据库记录，不删目录（[jobs.go](../../server/internal/jobs/jobs.go)，61–75 行）。调度没有持久 job 状态、补跑/失败退避与启动修复；日常循环忽略错误（23–33、78–95 行）。大体积书籍/PDF 使用中，磁盘占用可能持续增长，不能把表中的 expires_at 当作磁盘清理已经落实。

`maybeBackup` 的判断只排除当前分钟大于 m+2，没有排除小于 m；当配置分钟非 00 时，可能在同一小时更早触发（87 行）。默认 03:00 不受这个提前条件影响。

### SR-10 / P2：部署与健康检查尚未覆盖故障恢复

**静态确认。** 默认开发 Compose 未设置 restart policy；server Compose 虽有，但未接 Makefile。readiness 检查 DB/schema/maintenance，未检查文件可写、单实例锁、剩余空间或 backup 状态（[store.go](../../server/internal/store/store.go)，147–159 行）。schema 不一致直接退出，没有迁移流程（78–105 行）。[Dockerfile](../../deploy/Dockerfile) 第 7–8 行还忽略 PostgreSQL client 安装失败，可能把不完整备份 fallback 带入实际运行。

默认开发 Compose 启用 test hooks（42 行），测试路由无 session 中间件（[api.go](../../server/internal/api/api.go)，69–75 行）。任何将该配置改成外部可达的部署都应同时关闭 hooks；服务器 Compose 默认关闭。此处是部署边界提醒，不宣称已验证真实服务器暴露。

## 推荐落地顺序

1. **恢复可诊断的连接链路**：客户端错误/重试与地址校验；明确部署配置、网络入口和 HTTPS；本机、Mac、iPhone 分层验证。
2. **确保资料传输完整**：新设备全量/增量拉取、文件队列、稳定幂等、失败持久化、冲突和 epoch 恢复；优先覆盖真实书籍/论文 PDF 及笔记附件。
3. **让备份承担恢复承诺**：修复复制错误/格式/一致性，再做隔离恢复；实现保留期物理清理和错误可见。
4. **补运行保障**：结构化日志、可写性/磁盘检查、持久 jobs、启动修复与性能基线。不是所有改动都必须阻塞首个连接修复，但都不应被当前测试结果遮盖。

真实部署故障定位仍缺少：当前使用的 Compose/端口、监听与反代配置、客户端实际错误码、两台实际设备到该服务的连接和认证结果。主任务的公网 ready 通过只证明一次进程/数据库就绪响应，不能给出“客户端真实登录和同步已恢复”的结论。
