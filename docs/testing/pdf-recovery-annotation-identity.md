# PDF 恢复副本的批注身份与同步修复

2026-09-27，隔离合成验收环境；不读取真实用户资料或修改客户端待提交请求。

## 原生发现及根因

02:47—48，Mac 将同条批注并发时保留的 `editor_draft` 恢复为新 PDF 副本，原生可以看到本机的 `U4_LOCAL_20260927`，但同步 HTTP 500、待提交 1。保留的固定 `createPDF` 请求是 `21219ff2-c783-4a73-867a-e00620499cd1`，目标副本 `e59b4a84-8d48-43dd-b20e-080c7b9f0dce`；原件是 `a49ba379-2ce2-421e-a004-f0489df8c2f7`，共用原始 PDF blob `7a63f5d1-0929-4f71-90d2-21da3e6b1e65`。请求和本机证据位于 `/tmp/tokenlibrary-u4-recovered-pending-500.json`。

53056 对应合成 PG 容器日志明确记录 `annotations_pkey` 冲突（SQLSTATE 23505），重复 ID 为 `02122104-5d08-4c7e-914f-f57cd7113ff0`，第一次记录 UTC 18:47:50.232。失败事务没有创建云端副本。这不是已有 blob 不能复用，也不是客户端丢失草稿；恢复后的内容仍在本机副本和冻结请求中。

批注 ID 在一个 PDF 中标识同一条批注。恢复副本、资料复制及导出 PDF 的 `/NM` 有意保留此身份，服务端读取、替换、删除批注也都按 `document_id` 定位。旧版数据库却将 `annotations.id` 单列设为全局主键，导致复制合法内容时失败。

## 修复及兼容

`store.ensureFeatures` 在现有事务/迁移锁内，将旧 `PRIMARY KEY(id)` 改为 `PRIMARY KEY(document_id,id)`，记录 `v3-document-annotation-identity`。保留 baseline `schema/initial.sql` 和其指纹、已有数据、批注 ID、操作 ID、请求字节、资料库/epoch/会话。已是目标复合主键时重复执行安全；出现其他未知主键形状会失败，不猜测迁移。

同一文档内重复的批注 ID 仍非法：提前返回 422，避免 merge 以最后一条覆盖重复输入或数据库报 500；跨文档相同 ID 合法。未改客户端冻结请求或 PDF 的原始字节。

## 自动证据

新增 [真实 HTTP 回归](../../server/internal/api/annotation_identity_test.go) 三项：

1. 两个 PDF 保存同一个批注 ID；编辑和删除副本的批注不影响原件。
2. 同文档重复 ID 的创建/更新均返回 422，原批注、revision 保持，失败创建没有残留对象。
3. 独立 PG17 重建旧单列主键，真实 HTTP 固定请求先 500；重新连接自动迁移两次，原行/库/epoch/root 不变；沿用旧 session 和完全相同 wire/operation ID 成功 201，再重放只返回 receipt，不重复创建。

红测日志 `/tmp/tokenlibrary-annotation-identity-red.log`：跨文档同 ID 500、同文档重复输入被合并成一条、缺迁移三个问题均实际出现。修复后完整 API25 + synceng1 + merge13 共39项，0失败/0跳过，API包43.215秒；日志 `/tmp/tokenlibrary-annotation-identity-full-api.log`。

新增 [两代备份恢复回归](../../server/internal/jobs/annotation_migration_restore_test.go)：真实旧主键 dump 恢复到空库后自动迁移，原批注逐字段保留；新建保留同 ID 的副本，再做复合主键 dump/恢复，两文档批注仍独立、字段完整，恢复按约定换 epoch。完整 Jobs11 项（含8个真实临时PG集成），0失败/0跳过，17.047秒，日志 `/tmp/tokenlibrary-annotation-backup-tests.log`。HTTP测试为隔离 PG17 Docker，Jobs为本机独立 PG18 临时集群；不是所有 Jobs 在 PG17 复跑。

```sh
cd server
GOCACHE=/tmp/tokenlibrary-server-audit-gocache \
GOMODCACHE=/tmp/tokenlibrary-server-audit-gomodcache \
go test -count=1 -v ./internal/api ./internal/synceng ./internal/merge

PATH=/opt/homebrew/opt/postgresql@18/bin:$PATH \
TOKENLIBRARY_JOBS_INTEGRATION=1 \
GOCACHE=/tmp/tokenlibrary-server-audit-gocache \
GOMODCACHE=/tmp/tokenlibrary-server-audit-gomodcache \
go test -count=1 -v ./internal/jobs
```

## 53056 同实例升级

02:57:33 合成实例已完成受控短重启：先短维护阻止自动重试干扰逐表快照，暂停确切旧监督85408、停止其旧服务85455；新二进制成功执行迁移后，同地址恢复健康并解除维护。保留原二进制用于失败回滚，监督不会删除 PG 或数据。

证据目录 `/tmp/tokenlibrary-service-upgrade-kyq69u48/`：`before.json`、`after.json`、`migration.json`、`ready.json`、`control.json`、`supervisor.json`。业务表逐表摘要及42份实际媒体字节一致，库 `97c6c216-19ef-4e34-b97f-fecbf4653702` 和 epoch `08874133-4249-485c-8829-93d98cdb7485` 保持，session身份/凭据世代/撤销状态不变；续期时间单独保留，不冒充所有时间戳冻结。新 app9168、监督9132，旧客户端请求未改写。

原生恢复副本重试、双端最终内容及导出仍由后续 GUI 和只读证明确认，不能仅凭迁移成功宣布完整 U4 通过。

03:00:02独立只读增量：`/tmp/tokenlibrary-u4-after-server-fix-proof.json`确认原operation `21219ff2…`已自动重试为sent，ID/payload/request_json/createdAt/base/frozen_generation逐字未变（wire SHA256 `d8c540b1303da11ff54800a3058ae6073bd11091383055d139574aebc3be98a2`）；Mac可发送0、draft为空。Mac/PG原件revision4保留远端ios批注、副本revision1保留LOCAL批注，同annID按两个document分开，原74791字节/hash不变。此快照iOS字段为null，双端GUI与iOS最终证明尚待，不能扩大。

03:01:42最终增量：Root双端实际打开副本并看到LOCAL批注后，`/tmp/tokenlibrary-u4-final-three-client-proof.json`确认Mac/iOS working+remote与PG当前头完全一致，原件rev4/副本rev1、两端queue0、4份客户端原件字节/hash及服务端相同。详情见[双端草稿恢复证明](pdf-draft-recovery.md)；上节03:00快照未含iOS是历史边界，当前该限定旅程已闭环。
