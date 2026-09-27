# 服务端测试基线

日期：2026-09-26。代码审阅时的现有实现，不代表完整产品验收。本服务端子任务只变更文档；未运行 `make start`、未读取 `.env`、未操作已有项目容器。本页同时记录主任务执行的无凭据公网健康检查，不复制实际地址。

## 环境与隔离

| 项目 | 实际检查结果 |
| --- | --- |
| Go | `go version go1.25.6 darwin/arm64`；项目要求 Go 1.25.0 |
| Docker | CLI/Server 均为 29.5.3；可用 `postgres:17` 镜像 |
| Git | 命令存在；工作目录不是 Git 仓库，不能记录 commit SHA |
| PostgreSQL 工具 | `pg_dump`、`psql`、`initdb` 命令存在，位于 Homebrew PostgreSQL 18 bin 路径；没有运行本机数据库 |
| 缓存 | `GOCACHE=/tmp/tokenlibrary-server-audit-gocache`；`GOMODCACHE=/tmp/tokenlibrary-server-audit-gomodcache` |
| API 数据库 | 测试自身创建随机本地端口、`tlpg-<port>` 名称、`--rm` 的一次性 postgres:17 容器；每项测试清理自身容器，数据/备份使用 `t.TempDir()` |

隔离实现见 [testdb.go](../../server/internal/testdb/testdb.go)，19–70 行。Docker 镜像检查只读；测试启动不使用项目 Compose、真实数据卷或 `.env`。

首次受限运行失败于默认 Go module cache 不可写；切换 `/tmp` 后网络沙箱阻止 `proxy.golang.org` DNS。首次 Docker 检查也被 socket 权限阻止。这些是工具环境限制，不是产品测试失败。获准扩大工具沙箱后下载公共 Go 依赖并执行同一测试，得到下述最终结果。

## 已执行结果

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| authn 单测 | **通过，1/1** | `TestPasswordRoundTrip`；0.701s |
| merge 单测 | **通过，7/7** | 段落合并、同一行冲突、Mermaid、公式、批注新增、PDF 替换；0.958s |
| API 集成测试 | **通过，3/3** | `TestSimpleMarkdownUpdate`、`TestMermaidEdit`、`TestServerFlows`；5.394s |
| Go 全包编译检查 | **通过** | `go test -run '^$' ./...`；该命令没有执行任何测试 |
| 开发 Compose 语法 | **通过** | 显式占位环境 + `--env-file /dev/null` + `config --quiet` |
| 服务器 Compose 语法 | **通过** | 同上；不启动任何服务 |
| 默认服务地址公网 ready（主任务执行） | **通过** | 无凭据 `GET /health/ready` 返回 HTTP 200、`{"maintenance":false,"ready":true}`；没有登录/写数据 |

## 可复现命令

以下测试命令在 `server/` 目录运行。需要 Go 依赖下载权限；API 测试还需要 Docker 可用。缓存目录可替换为其他专用临时路径。

```sh
GOCACHE=/tmp/tokenlibrary-server-audit-gocache \
GOMODCACHE=/tmp/tokenlibrary-server-audit-gomodcache \
go test -count=1 -v ./internal/authn ./internal/merge

GOCACHE=/tmp/tokenlibrary-server-audit-gocache \
GOMODCACHE=/tmp/tokenlibrary-server-audit-gomodcache \
go test -count=1 -v ./internal/api

GOCACHE=/tmp/tokenlibrary-server-audit-gocache \
GOMODCACHE=/tmp/tokenlibrary-server-audit-gomodcache \
go test -run '^$' ./...
```

在项目根目录可安全校验 Compose 语法。下面的值只是占位参数，不能用于启动；`--env-file /dev/null` 避免读取项目 `.env`。把 `compose.yaml` 换成 `compose.server.yaml` 即检查另一份配置。

```sh
env POSTGRES_PASSWORD=audit-placeholder \
DATA_ROOT=/tmp/tokenlibrary-audit-data \
BACKUP_ROOT=/tmp/tokenlibrary-audit-backup \
ADMIN_USERNAME=audit \
ADMIN_PASSWORD_HASH=audit-placeholder \
UPLOAD_TOKEN_HASH=audit-placeholder \
PUBLIC_BASE_URL=http://127.0.0.1 \
docker compose --env-file /dev/null -f deploy/compose.yaml config --quiet
```

## 当前测试到底证明了什么

[authn_test.go](../../server/internal/authn/authn_test.go) 验证密码摘要生成/校验。[merge_test.go](../../server/internal/merge/merge_test.go) 验证七个特定合并样例，不能据此认定任意复杂 Markdown/PDF 注释合并都正确。

[api_test.go](../../server/internal/api/api_test.go) 的 TestServerFlows 通过 `httptest.NewServer` 创建本机 HTTP 服务，验证：

- ready 与登录、创建目录/Markdown、两个测试 session 的兼容修改合并和 Mermaid 冲突；
- 回收站删除/恢复、同一原始 JSON 正文的操作重放；
- 新键导入、重名后缀、错误 upload token 以及 upload token 不能读对象；
- 备份接口返回 success、maintenance 时操作返回 503、恢复 maintenance 与注销请求。

这条测试路径绕过生产进程 `main`、环境配置 Load、Docker app 镜像、bind mount 权限、Nginx、公网网络和客户端 UI。备份测试只检查 HTTP/status 字段，没有恢复到新库，也没有核对 dump 和全部文件。因此“API 通过”不能写成“iPhone/Mac 同步已修复”“生产部署可用”或“备份可恢复”。

公网健康检查首次在网络沙箱内出现 curl 000，获准扩大工具沙箱后返回上述 200。因此初次 000 不能算作真实服务故障。ready 通过也不覆盖用户设备网络、App Transport Security、真实凭据、会话恢复、上传或双向同步。

测试结束后没有保留测试数据库或资料。测试输出中的 operation/library UUID 属于临时生成数据；未收集真实认证 token。

## 未执行及原因

| 项目 | 状态 / 原因 |
| --- | --- |
| `make start` / 已有容器重启 | **未执行**；会读取真实 `.env` 并停止/重建项目服务，不属于本轮只读调查 |
| 真实服务器登录/写入、端口扫描、TLS 证书验证 | **未执行**；仅主任务执行一次无凭据 ready GET，不能确认两端失败根因 |
| iPhone/Mac UI 连接与重试 | **未执行（本服务端基线）**；由客户端工作项验证 |
| `tests/acceptance/main.go` | **未执行**；会向指定服务写入文档、触发备份/维护，并访问备份路径，不能默认对真实环境运行 |
| Docker app 镜像构建和完整 Compose 启动 | **未执行**；当前结果仅覆盖 Compose 语法与 API 的临时 PG 测试 |
| 断网、掉电、磁盘满、DB 重启与在途请求 | **未执行**；需要专门的隔离故障注入环境 |
| dump + PDF/图片的隔离恢复 | **未执行**；项目尚无完整恢复工具/测试 |
| 大文件/性能 | **未执行**；未导入真实书籍、论文或压测 1000 篇资料 |
| Race / fuzz / 长时间运行 | **未执行**；当前任务优先建立有限的功能基线 |

## 下一轮必要回归场景

按先恢复连接、再保证资料完整的顺序补测；下面是验收计划，不是已通过结果。

| 优先级 | 场景 | 通过条件 |
| --- | --- | --- |
| P1 | 本机 → Mac → iPhone 的同一服务连接 | 每层可独立定位；错误显示原因和重试；成功后实际拿到 meta 并同步一个文档 |
| P1 | 错地址、端口拒绝、DNS、TLS、错误凭据、503 | 客户端显示不同可理解状态；不会把失败显示为已同步；503 尊重重试时间 |
| P1 | 导入首个响应丢失，同键重传 | 返回原对象与最终回执；只存在一份可见文档及必要 blob |
| P1 | 重启后 pending 操作重放 | 相同操作正文与编号重发不会多建文档；冲突不被标为 sent/synced |
| P1 | 新设备与 100 条以上变更 | 完整遍历分页并下载书籍/论文 PDF、Markdown 和图片；游标仅在应用成功后前进 |
| P1 | 备份恢复演练 | 新数据库/新目录恢复后正文、树、批注、冲突、文件哈希一致；恢复切换 epoch |
| P2 | 1 MiB 边界、50 MB PDF、中断传输、hash 错误 | 无损续传/明确失败；半文件不可见；超限准确拒绝；记录时间/内存 |
| P2 | 回收站与备份到期 | 数据库状态与实际磁盘文件共同满足保留规则；共享 blob 不误删 |
| P2 | PDF 替换与旧批注、并发编辑/移动/删除 | 没有静默丢失；无法自动处理的差异进入可恢复的待处理状态 |

相关静态发现和代码证据见 [服务端可靠性调查](../research/server-reliability-audit.md)。
