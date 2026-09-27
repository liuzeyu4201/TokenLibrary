# 后端同步测试记录（2026-09-26）

合同见 [同步服务实现](../implementation/2026-09-26-sync-server.md)。本次只在专用临时 PostgreSQL、临时数据目录与 loopback HTTP 上创建合成资料，没有读取真实 `.env`、登录或写入真实服务。

## 环境与复现

环境为 macOS arm64，Go 1.25.6、Docker 29.5.3、`postgres:17`。`internal/testdb.Start` 每个 API 测试创建独立随机 loopback 端口容器，创建测试用户名/密码和临时文件目录，在测试清理阶段仅移除自己创建的容器。需要 Docker daemon 可用；没有 Docker 权限时测试会失败，不会被当作通过。[隔离夹具](../../server/internal/testdb/testdb.go)

在项目根目录执行：

```sh
cd server
export GOCACHE=/tmp/tokenlibrary-server-audit-gocache
export GOMODCACHE=/tmp/tokenlibrary-server-audit-gomodcache
go test -count=1 -v ./internal/authn ./internal/merge ./internal/synceng
go test -count=1 -v ./internal/api -run '^Test(SimpleMarkdownUpdate|MermaidEdit|FrozenSnapshotAndIncrementalChanges|AuthorityReceiptMetadataMergeAndReplay|ConflictMaterialsAndResolution|ResumableBlobsAndReferenceIntegrity|ImportIdempotencyAndSubtreeTrashRestore|SubtreeRestoreHonorsDeletionBatchAndSelectedSubtree|OperationValidationAndExpiredHistory|OnlyOneServerOwnsDatabase|ReceiptBaseUsesCommittedRevision)$'
go test -count=1 -v ./internal/api -run '^TestSnapshotAndChangesAt1000Documents$'
go test -count=1 -v ./...
```

整包 `go test -count=1 -v ./...` 已退出0：API13项、authn1项、merge当时12项、synceng1项、jobs当时2项。`TestServerFlows` 的真实备份步骤使用专用测试容器内匹配版本的 pg_dump/pg_restore 并通过。此后新增的 readingPositions/excerpts 合并单测使 merge 总计13项，单独再次全通过。备份恢复roundtrip由运维专项继续验证；备份成功目录不等于恢复验收。

## 已通过的断言

| 测试/范围 | 结果与关键断言 |
| --- | --- |
| authn | 1项通过：密码哈希正确密码通过、错误密码拒绝。 |
| merge | 13项通过：段落独立修改、同一行/Mermaid/公式冲突、PDF替换冲突、批注新增、批注删除vs编辑、嵌套metadata、null/删key、单边Markdown字节保留，以及按设备阅读位置/按ID摘录记录独立合并。 |
| synceng | 1项通过：PDF替换保留旧批注blob绑定且needs_review，不原地污染基准。 |
| `TestSimpleMarkdownUpdate` / `TestMermaidEdit` | 原有真实PG/HTTP更新路径通过。 |
| `TestFrozenSnapshotAndIncrementalChanges` | 创建后并发编辑/新增不改变冻结页；metadata存在、后续变化可取、快照过期410。 |
| `TestAuthorityReceiptMetadataMergeAndReplay` | 双边不同段落/嵌套字段合并；回执是权威snapshot；后续更新后重放仍返回原回执；旧客户端省略metadata不抹除。 |
| `TestConflictMaterialsAndResolution` | base/local/remote完整正文与列表可读；按当前revision解决后没有未解决ID。 |
| `TestResumableBlobsAndReferenceIntegrity` | 1MiB+7B分两块，重复初始化同uploadId，块确认、重复complete、下载字节/哈希一致，当前+历史引用存在，维护时503。 |
| `TestImportIdempotencyAndSubtreeTrashRestore` | 同键同输入复用对象，不同内容409；父子共同删除批次、原parent、恢复递增revision且清空批次。 |
| `TestSubtreeRestoreHonorsDeletionBatchAndSelectedSubtree` | 恢复嵌套文件夹不误恢复外层或此前独立删除子项，失效原父级回退到root。 |
| `TestOperationValidationAndExpiredHistory` | updateDocument同时携带rename/move有效，非法名称/父级拒绝，同名409，过期对象、历史、回执查询及操作重放410。 |
| `TestOnlyOneServerOwnsDatabase` | 同DB第二个Store启动拒绝，保障单实例维护假设。 |
| `TestReceiptBaseUsesCommittedRevision` | 以旧回执为基准时保留已提交远端修改；不信任客户端自报snapshotBytes；省略可选Idempotency-Key头仍返回正确operationId。 |

证据代码：[API回归](../../server/internal/api/sync_v2_test.go)、[合并回归](../../server/internal/merge/metadata_test.go)、[PDF绑定回归](../../server/internal/synceng/annotations_test.go)。整包日志 `/tmp/tokenlibrary-server-all-tests.log`，最新metadata记录合并日志 `/tmp/tokenlibrary-server-metadata-records.log`。此前详细日志位于 `/tmp/tokenlibrary-server-sync-tests.log`、`/tmp/tokenlibrary-server-core-tests.log`、`/tmp/tokenlibrary-server-receipt-tests.log`。这些是临时运行产物，不作为仓库依赖。

## 1000条资料规模实测

`TestSnapshotAndChangesAt1000Documents` 经真实HTTP创建1000个 Markdown 对象，每个正文1075字节，并交替携带书籍/论文/笔记metadata；服务端使用独立 PostgreSQL 17。建立冻结快照后更新其中100条，再翻完整快照及增量页。此测试不计PDF文件传输、客户端渲染、索引或真实移动网络。

| 阶段 | 单项初测 | 后续整包测试 |
| --- | ---: | ---: |
| 1000次顺序创建API | 6.813秒 | 6.245秒 |
| 冻结1001项并返回首100项 | 0.841秒 | 0.825秒 |
| 下载其余10页快照 | 0.029秒 | 0.044秒 |
| 100次顺序更新API | 0.574秒 | 0.921秒 |
| 获取100条增量、4页 | 0.027秒 | 0.034秒 |
| 含临时PG启动的测试 | 9.50秒 | 9.13秒 |

强断言：1001项包含根目录、恰好11页、没有重复对象；所有冻结正文保持原值且revision=1，即使其中100项已经更新。增量恰好100对象、4页、revision=2，最终游标1100。性能数字是当前机器两次观测，不是统计分位数或SLA。日志 `/tmp/tokenlibrary-server-scale-1000.log` 和整包日志，测试均退出码0。

## 跨语言端到端与未覆盖范围

客户端负责的真实 Swift 双客户端 HTTP 测试已在另一份独立临时服务运行通过，覆盖 bootstrap/增量、metadata与段落合并、image/PDF SHA256、批注跨端、冲突读取/解决、文件夹递归回收/恢复。其日志 `/private/tmp/tokenlibrary-sync-e2e.log`。该次服务二进制冻结于后续边界补丁前，因此后补的PDF替换标记与跨端trashBatchId不借此宣称已做原生UI验收。

Root 原生界面验收使用的临时服务会保留至其通知清理；其临时启动脚本为 `/tmp/tokenlibrary-e2e-server.py`，使用新容器、新库、新文件目录和测试凭据。不要复用此临时脚本作为生产部署，不把动态端口或测试凭据写进客户端默认配置。

本记录未宣称通过：真实iOS设备网络与ATS策略、原生UI自动化、HTTPS证书签发、断电/磁盘损坏恢复、千份大PDF吞吐、高并发、多实例部署、WebSocket推送。备份可恢复性/保留清理/HTTPS部署由对应专项记录提供证据。

## 专题删除与认证生命周期补充（18:38）

本次重新运行整个 Go 仓库，使用 `TOKENLIBRARY_JOBS_INTEGRATION=1` 和 PATH 中 PostgreSQL 18 工具启用真实 jobs 测试；API 仍使用各自隔离的 PostgreSQL 17 容器。`go test -count=1 -v ./...` **42 项通过、0 失败、0 跳过，退出码 0**：API 18、jobs 7、merge 13、authn 1、synceng 1、hashcred 2。日志 `/tmp/tokenlibrary-server-after-topic-auth.log`。此后只新增一个媒体恢复测试并单独通过，见 [备份验证](backup-validation.md)，不把两次运行写成同一次套件。

新增 API 回归代码：[topic_trash_test.go](../../server/internal/api/topic_trash_test.go)、[session_lifecycle_test.go](../../server/internal/api/session_lifecycle_test.go)。5 项先单独通过（`/tmp/tokenlibrary-server-auth-topic.log`），然后纳入整包：

- 直接删除专题时，服务端在同一事务重新枚举当前物理直属子项，移到专题父级并对重名使用 `_数字`，保留后代正文/元数据；随后只删除专题。客户端最后同步以后加入的资料也保留，所有移动与删除写入同一增量事件。重复操作不二次移动；原 revision 上的离线正文编辑仍保留服务端救回的位置。
- 普通文件夹递归删除保持原意，内部专题及其物理后代随该物理文件夹进入同一删除批次。
- 89 天 23 小时未活动会话仍可用并续期；超过 90 天 1 秒返回 401 且不续期。退出后同一 token 立即拒绝、另一设备会话不受影响；凭据世代提高后旧会话拒绝、新登录可用。
- 独立上传 Token 更换后旧 Token 拒绝、新 Token 可上传但不能读库；停用上传返回 403，客户端 session 不受影响。
- 在独立测试数据库内用触发器注入写失败：会话续期失败返回 503；logout 撤销写失败返回 503，不假报退出成功。撤销重试成功后旧 token 拒绝。

修复了两处原先忽略数据库错误的认证行为：授权与滑动续期现在通过带过期/撤销/凭据世代条件的原子 UPDATE 完成，存储不可用与无效会话分别报告；logout 只在持久撤销成功后确认。此补充不代表原生登录 UI 或过期离线编辑旅程已经验收。

## 短清理与备份维护的重试分类

旧隔离服务的一次 Core HTTP 分页回归收到 503/Retry-After 30；旧客户端丢失了该分支的 serverCode，不能事后仅凭 nil 断定具体错误来源。只读检查未见 PG 错误记录，代码确认每 30 秒的短清理和真正备份被归为同一维护状态。现已通过可控竞争验证并修复这一稳定性缺口。

[write_contention_test.go](../../server/internal/api/write_contention_test.go) 的 2 项真实 PostgreSQL 测试已通过，日志 `/tmp/tokenlibrary-server-write-contention.log`：

- 持有 libraries 的真实行锁，启动真正的 PurgeExpired，使它占用进程写锁后停在 PG；operations、uploads、complete、curl imports 均返回可重试 BUSY/1 秒。释放行锁后清理正常结束，同一操作提交并重放仅产生 1 个对象、1 条回执。
- 数据库维护标志为 true 时，持有写锁和未持有写锁两种情况都返回 MAINTENANCE/30 秒，保留完整备份窗口语义。

配套客户端验证保留 HTTP 错误码/Retry-After，并验证 BUSY 自动重试使用完全相同的 operationId 与请求字节；它不会提前重试 30 秒维护窗口。

本次服务端回归分两条命令完成，均退出 0：全仓 go test 为 40 通过、5 个 jobs 集成测试因未设置开关跳过；随后显式设置 TOKENLIBRARY_JOBS_INTEGRATION=1 并运行 jobs 全包，8 通过、0 跳过。去重后 **45 项均有当前代码通过证据**（API 20、jobs 8、merge 13、authn 1、synceng 1、hashcred 2），没有剩余未执行测试。不能把它写成一次无跳过的全包运行。日志 `/tmp/tokenlibrary-server-final-busy.log` 与 `/tmp/tokenlibrary-server-final-jobs.log`。

## 回收站资料清理关系时保留身份与期限（2026-09-27）

客户端主动移除关系会同时清理回收站中目标的反向关系。服务端此前把已回收对象物理NULL的parent与公开snapshot中的原父级比较，误判为移动；当原父目录也在回收站中时，普通metadata更新返回422。新增真实PG/HTTP测试在旧实现复现该问题（`/tmp/tokenlibrary-trash-metadata-before.log`）。

现在回收站更新使用original_parent_id作逻辑父级，数据库物理parent仍保持NULL。仅保留身份的正文/metadata更新可提交；move/rename、不同name/parent仍拒绝，desired state=active不能借update还原。删除时间、purgeAt、trashBatchId、原父级不受普通更新影响。

[trash_metadata_test.go](../../server/internal/api/trash_metadata_test.go) 新增2项：目录及子资料共同回收后清除两侧relatedIDs，验证全文、其他metadata、保留期限和数据库物理字段不变；操作重放不重复，省略parent的metadata更新仍正确，恢复后旧关系不会复活。另验证移动/改名/非法父级拒绝，伪造active更新不能恢复。

随后 `go test -count=1 -v ./internal/api ./internal/synceng ./internal/merge` 完整相关回归 **36项通过、0失败、0跳过**；API22项/39.004秒、synceng1项/0.738秒、merge13项/1.553秒，日志 `/tmp/tokenlibrary-server-trash-related-full.log`。新增2项也先专项通过。该命令不包含jobs/authn/hashcred；它们保留上一轮证据，不能合写成一次47项全仓零跳过。

00:48前已构建新二进制，在独立第四测试服务56881及全新PG容器中ready，用于后续跨语言最终回归。原生验收的53056和另外两个旧实例没有替换；其旧二进制不包含此修复，因此不能把旧服务上的原生行为当作修复后的验收。

随后00:48:50，新56881上Core218项真实HTTP/Keychain全过。00:57:06在双方验证应用退出后，原生53056也完成同实例升级，9类公开表摘要、库/epoch、会话非秘密字段及37份媒体bytes/hash前后全部相同，详见[隔离服务升级](restored-service-upgrade.md)。此时才具备最新server原生复验条件；升级ready本身不代替逆关系清理业务旅程。

01:11—01:13原生iOS随后完成该业务闭环：A关联B→删除A父目录→在活跃B详情移除回收站A→还原父目录。只读五阶段确认A在trashed时仅relatedIDs改变，originalParent/physical NULL/删除时间/到期日/batch完全保持；恢复原层级后边不复活，正文、PDF字节与既有Gamma来源摘录不变、队列0。具体ID、revision和附件hash见[iOS关系回收证明](ios-related-trash.md)。这提供了修复后实际客户端到新服务的证据，不再将此iOS样本列为待验。


01:44:42，Jobs完整10项、0失败/跳过通过，新增实际dump排除过期副本和备份后到期再恢复两项，见[备份验证](backup-validation.md)。与本页API22/synceng1/merge13和此前authn1/hashcred2证据合计49个不同用例；这些是多轮包运行，不能标为一次49项全仓零跳过。新Jobs使用临时PG18，未重启四个活动服务或替代历史PG17镜像验收。
