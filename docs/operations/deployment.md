# 部署与连接排查

状态：代码完成，隔离容器启动与备份恢复已验证；尚未替用户申请公网证书或部署到实际服务器。更新：2026-09-26。

## 部署形态

- `DEPLOYMENT=local`：Go 服务与 PostgreSQL 只绑定宿主机 loopback，适合本机开发。真机 iPhone 无法通过自己的 `127.0.0.1` 连接 Mac；两端日常同步应使用同一个公网 HTTPS 地址。
- `DEPLOYMENT=server`：公网只有 Caddy 的 TCP 80/443、UDP 443；app、PostgreSQL 没有公开端口。Caddy 管理 HTTPS/WSS 和证书续期，app 只在内部 HTTP 监听。
- PostgreSQL 与备份工具同为 17，运行镜像和数据库镜像使用同一固定摘要。Caddy 固定 2.11.4 和镜像摘要。升级先在隔离库完成 dump/restore 回归，再一起更新工具与数据库；不能只换 PostgreSQL 主版本。

当前实现用 Caddy 取代历史方案中的 Nginx/Certbot：证书签发、续期、反向代理集中在一个服务；旧 `deploy/nginx.conf` 不再被 Compose 使用。旧部署迁移时应先准备好新镜像和配置，再停止属于本项目的旧 Nginx/Certbot，释放 80/443；不要停止机器上其他项目的代理。

## 首次配置

需要 Docker Engine/Desktop、Docker Compose v2、Make、Python 3.9+（含 IANA 时区数据）。本机生成凭据还需要与 `server/go.mod` 一致的 Go 工具链。

1. 从 `.env.example` 复制 `.env`，限制该文件的读取权限。部署程序按数据解析配置，不执行 `source .env`；不要把命令放进配置值。
2. 设置绝对 `DATA_ROOT`、`BACKUP_ROOT`：两者互不嵌套，不在源码目录内，不使用自建符号链接；备份应放独立持久磁盘或挂载目录。程序不会删除或递归改属主现有目录。
3. `APP_UID`/`APP_GID` 默认 `10001`。新建 `DATA_ROOT/files/objects`、`DATA_ROOT/files/staging`、`DATA_ROOT/runtime/app` 和 `BACKUP_ROOT`，使应用身份能写入。以 root 执行时脚本仅对自己新建的这些目录设属主；已有目录须管理员明确检查。PostgreSQL 数据目录由官方镜像管理，不能递归改成 app 用户。
4. 为数据库设置独立随机 `POSTGRES_PASSWORD`，使用 URL 安全字符（字母、数字、`_ . ~ -`）；不得用示例测试密码。`POSTGRES_DATA_ROOT` 可留空，默认 `DATA_ROOT/postgres`；它也允许恢复时保留原 PostgreSQL 集群路径、单独切换文档文件目录。
5. 运行 `make hashcred`，在隐藏输入提示中输入并确认账号密码；将生成的单引号包裹的 `ADMIN_PASSWORD_HASH` 行写入 `.env`，保留单引号以避免 `$` 被 Compose 插值。密码不放命令参数。若要独立上传密钥，运行 `make hashcred ARGS=--generate-upload-token`，将输出的哈希写配置，将另行显示的随机 Token 交给上传端保存。暂不使用上传时设 `UPLOAD_TOKEN_ENABLED=false`。
6. 设置 `DEPLOYMENT=server`、`PUBLIC_BASE_URL=https://你的公网地址`、`ACME_EMAIL`。域名的 A/AAAA 应指向这台服务器，或使用固定公网 IPv4/IPv6（IPv6 URL 要带方括号）。不要填写 `/api/v1`。开放公网 80/443，确保服务器能访问 ACME 服务。
7. `TOKENLIBRARY_TEST_HOOKS=0`。服务器模式会拒绝启用测试管理端点。`BACKUP_TIME=03:00`、`BACKUP_TIMEZONE=Asia/Shanghai`、`BACKUP_TIMEOUT=20m` 可按容量调整。

使用同一项目配置顺序启动：

```sh
make start mode=middleware
make start
make logs
```

`make start` 默认只启动 service（app/Caddy），先检查现有 PostgreSQL 可用，不替用户启动 middleware。脚本先校验配置、准备镜像，再重建选中服务；镜像构建/拉取失败保留旧容器。停止宽限 30 秒，PG 就绪最多 60 秒，app 最多 90 秒，公网 HTTPS 最多 10 分钟。服务端模式必须通过系统信任根及域名/IP 校验后才报告 HTTPS ready；自签证书、错误地址、证书未取得都会返回失败，容器保留用于排查。

裸 `make` 仅显示用法。`make logs mode=middleware` 查看 PG；`make logs` 查看 app/Caddy，最后 200 行带时间并持续跟随，Ctrl+C 不停止服务。容器日志使用 Docker local 驱动，10 MiB × 5，避免无界占盘。不会使用 `down -v` 或删除持久目录实现重启。

## HTTPS 条件与证据边界

Caddyfile 显式选择 ACME `shortlived` profile，避免 IP 地址默认使用本地 CA。Let’s Encrypt 官方于 2026-01-15 开放公网 IPv4/IPv6 证书，IP 必须使用约 160 小时的短期证书，因此持久保存 Caddy `/data`、保持自动续期和公网挑战可达很关键。[Let’s Encrypt 公网 IP 与短期证书说明](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability)、[Caddy ACME profile 配置](https://caddyserver.com/docs/caddyfile/directives/tls)。访问：2026-09-26。

`ACME_CA` 可指向官方 staging 做隔离签发演练。staging 证书不被系统信任，启动脚本不会将其报告为可用生产 HTTPS；演练完成后切回生产 ACME 并确认真实证书。不要为了通过检查而关闭客户端 TLS 校验。域名/IP 配置已在无网络容器完成解析验证，但真实签发、续期及互联网回程必须在用户的实际地址上验收。

## 常见连接问题

| 现象 | 检查与操作 |
| --- | --- |
| iPhone 连不上 Mac 的 localhost | localhost 指当前设备。日常使用服务器的同一个 HTTPS origin。 |
| app ready，HTTPS 仍失败 | `make logs` 查看 Caddy；核对公网 IP/DNS、A/AAAA、80/443、ACME 限额、系统时间。 |
| middleware 未就绪 | `make logs mode=middleware`；检查磁盘、原 PG 数据目录和主版本，避免换成空目录。 |
| app 权限失败 | 核对 app 的 UID/GID 和文档/备份子目录权限；不要全盘递归 chown。 |
| 503 MAINTENANCE | 备份期间云端写入暂缓；本地编辑仍可继续，正常情况下结束后自动恢复。 |
| 503 BUSY | 短暂清理正在占用写锁，Retry-After 为 1 秒；客户端按相同 operationId 自动重试，通常无需重新登录。持续失败才检查任务/数据库状态。 |
| 备份失败 | 参见 [备份与恢复](backup-restore.md)，检查错误摘要、空间、版本和原件；失败不产生可恢复成功标记。 |
| 改密码后需要登录 | 新凭据配置生效后重新登录；本地资料与待同步编辑应保留。 |

需要撤销已有客户端登录时，在更新账号密码哈希的同时将 `CREDENTIAL_GENERATION` 提高为新的正整数，再重建 app 服务。服务端会拒绝旧世代 session；只修改密码哈希会改变下一次密码校验，但不会自动撤销此前签发的会话。不要降低或复用旧世代。仅更换上传密钥时更新 `UPLOAD_TOKEN_HASH`（或设 `UPLOAD_TOKEN_ENABLED=false` 停用），不必改变客户端凭据世代。

`.env`、用户文件与 Caddy 私钥不属于源码。Docker 构建忽略 `.env`/`.env.*`，只保留无秘密的 `.env.example`。不要把 `docker compose config` 的展开输出贴到工单；本项目校验使用 `config --quiet`。
