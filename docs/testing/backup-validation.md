# 备份、恢复与部署验证

更新：2026-09-27 01:45。只使用独立临时数据库、临时文件和专用容器；未读取真实 `.env`，未部署或恢复实际用户资料。最新Jobs完整10项见文末，早先7项及真实媒体1项保留各自时间，不重复累计。实现与操作见 [备份恢复](../operations/backup-restore.md)、[部署](../operations/deployment.md)。

## 已独立核实的运行证据

`/private/tmp/tokenlibrary-jobs-tests.log` 记录 `tokenlibrary/internal/jobs` **7 项通过，0 失败，0 跳过，3.498 秒**。日志中的 4 个数据库集成用例均实际执行；没有把默认跳过算通过。

| 测试 | 强断言与实际边界 |
| --- | --- |
| `TestScheduledTimeCatchesUpLatestDay` | 北京时间 03:00 的最近应执行时间、启动补最近一天、非法时间拒绝。是确定性时钟测试，不是等待真实一天。 |
| `TestRootAliasesCannotHideOverlappingDirectories` | macOS `/tmp` 与 `/private/tmp` 路径别名不能绕过数据/备份根目录重叠校验。 |
| `TestVerifyBackupRejectsTamperingExpiredAndSymlinks` | 正确清单可验证；未发布 `.partial`、到期、文件篡改、符号链接拒绝。此项使用封装夹具，不冒充数据库恢复。 |
| `TestBackupRestoreRoundTripAndEpochReset` | 启动真实临时 PostgreSQL，执行 pg_dump/pg_restore；资料 UUID 和 libraryId 不变、epoch 更新、原件字节一致、遗漏无引用上传行清除、非空恢复目标拒绝。blob 是任意合成字节，不是可阅读 PDF。 |
| `TestBackupFailureAndTimeoutAlwaysReleaseMaintenance` | 缺原件拒绝发布成功备份；排空写锁超时；两者均解除维护并释放写锁。 |
| `TestPurgeCleansSensitiveCopiesAndKeepsSharedBlob` | 清除过期对象历史 changes/operations/snapshot 的正文，保留墓碑；专属 blob 物理删除、共享 blob 保留；7 天到期备份目录删除。 |
| `TestRetentionExpiresUploadButKeepsResumableUpload` | 到期上传临时文件/记录清理，有效断点租期保留；同一 blob 的旧租期不能误删新有效会话。 |

测试源：[jobs_test.go](../../server/internal/jobs/jobs_test.go)。集成夹具要求 `TOKENLIBRARY_JOBS_INTEGRATION=1`，并在 PATH 中提供相同主版本的 `initdb`、`pg_ctl`、`pg_dump`、`pg_restore`。前一工作段使用本机 PostgreSQL 18 临时集群；该主版本只用于隔离回归，发布镜像仍固定 PG17。

复现（在 `server` 目录，先确保 PATH 指向同一 PG 工具集）：

```sh
TOKENLIBRARY_JOBS_INTEGRATION=1 \
GOCACHE=/tmp/tokenlibrary-jobs-gocache \
go test -count=1 -v ./internal/jobs
```

## 运行镜像与部署脚本

`/private/tmp/tokenlibrary-deployment-build.log` 显示 `tokenlibrary-validation:20260926` 镜像构建完成，包含 Go server、library-admin、固定 PostgreSQL 17 工具和 schema。镜像发布清单 `sha256:f8ddf90bff99b4e142bd291fda8f5e9e6c35408c4ac068f645652fdbd352b875`。这证明该次构建成功，不代表之后任意源码修改自动包含在旧镜像。

前一实施工作段报告以下运行通过，但本次接续审计没有找到其独立持久日志，因而没有重跑，也没有把它们列为本次独立复核通过：

- [test_manage.py](../../deploy/scripts/test_manage.py) 的 10 个部署配置/权限/TLS 检查回归。
- Caddy 域名/IP 两种配置在无网络隔离容器中解析验证。
- [smoke_test.py](../../deploy/scripts/smoke_test.py) 使用专用 Docker 网络与 PG17/app 容器：ready、调度生成真实 custom dump、manifest verify、CLI 恢复空目标库、libraryId 相同/epoch 不同/maintenance=false。夹具为空资料库，不能证明完整媒体资料恢复。

需要重新采集持久证据或源码改变后，使用：

```sh
python3 -m unittest discover -s deploy/scripts -p 'test_manage.py' -v
docker build -f deploy/Dockerfile -t tokenlibrary-validation:20260926 .
python3 deploy/scripts/smoke_test.py --image tokenlibrary-validation:20260926
```

该 smoke 只删除自己随机命名的容器/网络/临时目录；不使用部署 `.env`，也不挂载活动 PG 集群。镜像构建及下载需要可用 Docker 与网络。

## 尚未覆盖

1. 恢复后完整资料集在两端逐项打开、编辑与比对。下文已有真实模型/媒体恢复、Mac重新登录阅读与iOS首次下载代表样本证据；尚不能据此关闭全部批注、专题、冲突和每个附件的双端旅程。
2. 备份前后本机未提交草稿与新 epoch 的协调。Core 现有 epoch 单测不能替代真实恢复联调。
3. 实际 Linux 公网地址的 HTTPS 首次签发/续期、DNS/80/443 回程、长期调度与容量监控。配置解析通过不等于证书已签发。
4. 真实机器断电、磁盘损坏、满盘以及真实用户库迁移演练。本轮没有执行这些破坏性操作。

所有未覆盖项继续保留在 [全范围状态](development-status.md)，不得以“备份文件存在”或“空库恢复成功”关闭完整恢复验收。01:44另新增新备份内容清理/真实恢复与恢复时到期补清理的自动闭环，见末节；该自动证据不替代这些原生/部署缺口。

## 真实媒体与资料模型恢复补充（18:38）

新增 [media_restore_test.go](../../server/internal/jobs/media_restore_test.go) 的 `TestMediaCatalogAndOpenConflictSurviveRealBackupRestore`，独立 PostgreSQL 18 执行真实 pg_dump/pg_restore，**1 项通过、0 跳过，退出码 0**，最新用例 2.05 秒（批注夹具使用协议规定的 x/y/width/height 几何后重跑），日志 `/tmp/tokenlibrary-server-media-restore.log`。运行命令沿用上面的 jobs 命令，增加 `-run TestMediaCatalogAndOpenConflictSurviveRealBackupRestore`。

资料集包含有效单页 PDF（Helvetica 文字层）、可解码 8×8 PNG、论文元数据（作者/年份/DOI）、两个专题、按设备阅读位置、PDF 高亮、带图片和摘录评论的归档笔记，以及同段编辑产生的未解决冲突。文档/版本/冲突通过真实同步引擎创建；blob 在隔离存储中注册，此项不重新测试 HTTP 上传。

恢复到新空库/新目录后，逐项比较四个对象的完整公开 snapshot、PDF/PNG 原始字节与 SHA-256、未解决冲突的 base/local/remote 材料；确认冲突所需 revision 在新 epoch 下可取、libraryId 不变、epoch 改变、maintenance=false。manifest 恰好包含数据库/PDF/PNG 三个文件。

PDF 夹具按测试源函数生成后，另由系统 PDFKit 与 `pdftotext` 实际打开，均确认一页及文字 `Reading fixture`。结果 `/tmp/tokenlibrary-media-fixture-validation-retry.log` 与 `/tmp/tokenlibrary-media-fixture.txt`。第一次 Swift 检查因 `/tmp` 和 `/private/tmp` 模块缓存别名冲突崩溃；统一 canonical 缓存路径后成功，未修改文件内容规避解析错误。

因此18:38时“完整模型与媒体存储恢复”已有直接集成证据，当时尚未开始恢复后的两台原生客户端旅程。后续Mac与iOS已完成下述代表样本；真实公网部署、用户资料恢复及完整双端资料集逐项验收仍未覆盖。

## 原生验收库的真实恢复（19:14）

在主验收结束当前写入、准备退出 Mac 应用时，对其隔离服务 62036 调用真实备份任务，生成 `3f349644-f23d-42a2-8b8b-58f41f66b5fe`，快照时间 2026-09-26 19:14:07.995（上海）。此库包含真实原生导入的三页中英 PDF、PNG/Markdown、两条 UI 批注、摘录来源笔记与文件夹移动，也包含此前 HTTP 回归合成资料。

将备份复制至第三个独立临时目录，用 PostgreSQL 17 容器内同版本 pg_restore 和仓库最新 library-admin 执行 verify、restore。目标数据库与数据目录均为空；旧 62036 与最新回归服务 51525 保留运行，没有替换或清理其资料。

| 核对项 | 实际结果 |
| --- | --- |
| 封装 | 29 文件：1,976,973 B custom db.dump ＋ 28 附件；verify 成功 |
| 对象与资料 | 635 objects、620 documents，全部行内容逐值等于源库 |
| 批注、关系、冲突 | 8 annotations、130 blob_refs、6 conflicts、0 conflict_drafts；四表全部逐值等于源库 |
| 附件 | 28 文件、总 168,989 B，最大 74,791 B；与 manifest 大小/hash、源库原件字节三方一致 |
| 库 ID | 保持 97c6c216-19ef-4e34-b97f-fecbf4653702 |
| 恢复世代 | b1fa67aa-9649-45b8-8adc-4b01c0a3e3cd → 08874133-4249-485c-8829-93d98cdb7485 |
| 旧会话与瞬时状态 | sessions、operations、uploads、sync_snapshots 都清零，maintenance=false |
| 应用启动与首段原生恢复 | 最新 binary 的 53056 ready 成功；Mac 新 workspace 原生登录成功，PDF 恢复到第 3 页，批注列表显示两个真实记录，高亮定位跳回第 2 页 |

证据目录：`/var/folders/jd/9gz27bzs5d55xdmkf57mljx00000gn/T/tokenlibrary-restored-ui-w9jb1nkx`，含 restore.log、restore-proof.json、supervisor.json；任务响应 `/tmp/tokenlibrary-ui-real-backup-result.json`。独立恢复过程脚本 `/tmp/tokenlibrary-restore-ui-fixture.py` 只使用本次已知合成库和随机命名目标，未读取真实 .env 或用户资料。

这项补充证明原生创建的资料确实进入可恢复备份，且在最新服务中保持内容。此快照不包含接近 50 MB 样本，不能替代 F20；原生恢复后读取/来源回跳/附件显示需以 [原生记录](native-ui-validation.md) 为准。不同 URL 的新 workspace 登录也不能替代同一服务地址下旧未提交队列的 epoch 协调验收。

后续主验收已完成上述Mac登录、PDF阅读位置与批注列表/高亮跳页，并从恢复后的摘录来源笔记进入PDF第2页、点击“返回笔记”回到同一正文。随后维护编辑/自动续传和服务无响应时本机重启/恢复同步另有原生证据；近50MB导入及四方hash见[PDF夹具记录](pdf-fixtures.md)。

23:35—23:40，第二原生客户端iOS首次登录同一恢复服务并同步625份资料，独立核对21/21当前下载附件实际bytes/hash一致，代表笔记图片、原文PDF和大PDF可读；23:57更新包来源首次准确到第2页，23:59大PDF继续阅读和检索跳页通过，见[iOS首次同步证明](ios-first-sync-proof.md)。625份资料和21份当前附件是恢复后又经导入/编辑的活动集合，不是19:14备份620份资料/28附件的逐项重验；近50MB样本在备份之后新增。上述分项不能替代恢复后全部附件和模型的双端旅程，或同地址旧队列的epoch协调，也不能据此宣布F29全旅程通过。

## 01:44 新备份清理与恢复后的到期内容闭环

此前测试分别验证清理和正常媒体恢复，但没有直接检查真实custom dump是否已排除过期隐含副本，也没有让一份含回收站资料的有效备份跨过资料期限后再恢复。新增 [retention_restore_test.go](../../server/internal/jobs/retention_restore_test.go) 两项覆盖这两个边界；没有修改产品Jobs实现。

2026-09-27 **01:44:42**，完整Jobs **10项通过、0失败、0跳过，15.841秒**，含7个实际启动临时PostgreSQL的集成用例。环境为Go1.25.6/darwin-arm64、PostgreSQL18.3同版本工具。日志 `/tmp/tokenlibrary-jobs-retention-full-tests.log`，摘要与日志/源码SHA-256为 `/tmp/tokenlibrary-jobs-retention-proof.json`。每项集成自行启动随机loopback端口的临时PG集群，并仅清理自己的目录/进程；未访问四个活动服务、53056业务库、`.env`或真实凭据。

```sh
cd server
PATH=/opt/homebrew/opt/postgresql@18/bin:$PATH \
TOKENLIBRARY_JOBS_INTEGRATION=1 \
GOCACHE=/tmp/tokenlibrary-jobs-gocache \
go test -count=1 -v ./internal/jobs
```

新用例可以加 `-run '^Test(RetentionBackupExcludesExpiredCopiesAndRestoresArchivedMedia|RestorePurgesTrashThatExpiresAfterTheBackupSnapshot)$'` 单独运行。没有安装依赖；运行前应确认同一PG主版本工具已存在。PG18用于此临时自动回归，不将它描述成发布PG17镜像的最新构建验证。

### 清理后的实际备份内容与恢复

`TestRetentionBackupExcludesExpiredCopiesAndRestoresArchivedMedia` 用实际同步引擎创建六个对象：归档专题、归档论文PDF、带图片/来源摘录的归档笔记，以及将过期的两份PDF和一篇笔记。原件为可读单页PDF与实际编码/解码8×8 PNG；四个blob中两份共享PDF/PNG仍由归档对象引用，另外两份PDF/PNG仅属于待删除对象。待删除笔记通过同段编辑产生真实未解决冲突；还加入冲突草稿和同时含归档/待删除资料的冻结页。普通创建、修改、冲突和删除走Engine，仅在该测试私有DB调整purgeAt模拟到期。

1. 到期前真实备份包含 **5文件：custom dump＋4媒体**，可从dump确认独特过期正文标记存在，确保负例材料实际进入备份。
2. 通过正常RunBackup触发到期清理，再次生成 **3文件：custom dump＋2共享媒体**。新清单不含任何独占blob；源库过期objects/documents/revisions/annotations/conflicts清零，conflict_drafts与该对象冻结内容清零，旧回执仅含gone结果，旧changes不再含正文。三个删除墓碑各有独立序号。
3. 在执行RestoreBackup之前，将真实新custom dump展开为SQL检查独特正文标记及其bytea十六进制形式均不存在。这防止“恢复时清空operations/snapshot才隐藏备份泄漏”的错误通过。没有仅搜索压缩二进制文件中的明文。
4. 恢复到独立空DB/新目录后，三个归档对象的完整公开snapshot逐值相等，包括书目信息、专题、来源摘录、图片和PDF高亮；两共享媒体实际bytes/SHA-256相等。两独占媒体在源库和恢复库都无row/文件，三墓碑保留；libraryId不变、epoch改变、maintenance=false，旧会话/上传/回执/分页快照清空。
5. 原旧备份为独立副本，源库清理后custom dump字节未变，旧备份的完整清单/媒体hash仍可验证。以显式时间参数检查其7天期限前1ns可验证、到点拒绝；CleanupExpiredBackups在同一到点时刻删除该真实旧目录，较晚新备份仍可验证。这里是确定性期限测试，不声称真实等待七天。

本项本轮耗时 **1.26秒**。首轮错误来自测试将两次pg_restore的SQL文本整体比较：PG18会生成不同的`\\restrict`保护标记。已改为比较实际不可变custom dump字节，首轮日志保留在 `/tmp/tokenlibrary-retention-restore-first-run.log`；未把这一工具包装差异误判为产品改写备份，也未放宽正文清理断言。

### 备份后到期，恢复时补清理

`TestRestorePurgesTrashThatExpiresAfterTheBackupSnapshot` 使用同一六对象混合模型，将私有夹具的三个trash期限设为8秒后。先完成实际备份，确认5文件及有效trash/旧正文确实存在；**真实等待跨过该短期限**，而备份本身仍远未到七天。

此时直接调用RestoreBackup，不修改或重打包已发布备份。恢复过程先正常验证/复制文件，再执行其正式到期清理：三个过期对象及其旧正文/冲突副本不再可用，独占媒体从恢复目录删除、三墓碑存在，共享PDF/PNG和三个归档snapshot完整保留，旧瞬时状态清零、维护解除。原源DB中的三个trash行仍存在，原备份仍含原5文件/旧正文，证明恢复没有反向修改源库或输入备份。

本项本轮耗时 **9.11秒**，含实际8秒边界等待。该短截止仅是合成夹具，验证正式purgeAt比较与恢复补清理路径，**没有声称等待真实30天**。最新完整10项没有失败或跳过，结束后临时PG/空目标由各测试清理。

本轮新增证据关闭F29/F31中的真实混合新备份内容检查、归档/共享/独占媒体恢复、旧隐含副本移除及恢复前到期补清理的自动层。仍需：两端实际收到墓碑后的原生列表/离线旧副本协调，同地址恢复epoch与未提交草稿，真实03:00系统调度/连续7天保留观察，公网部署、容量/满盘/断电演练。源库和备份清理不承诺撤回离线客户端或已导出副本，也不是取证级物理擦除。


## 02:31 同服务地址的旧队列联合恢复

[两客户端联合证明](epoch-restore-two-clients.md)新增独立PG17实际dump/verify/restore与真实Swift Core HTTP旅程：同URL重启到空库恢复结果，旧会话401；两端各自冻结请求及更新尾文保留、低revision接受、新epoch冲突阻塞，显式local/custom解决后精确收敛且旧op未回放。共享PNG与归档PDF全链路bytes/hash保持，原源库被观察的业务快照不变。仅新建自己的服务并于结束清理，原四服务不变。

因此此前“同地址epoch与未提交队列”缺口的自动层已有证据；原生epoch提示/选择、完整App重启、editor_drafts入口、远端缺失新建文档、两端墓碑和真实定时观察仍未因此关闭。此独立联合旅程不算第11个Jobs用例，也不是将原Jobs10全部在PG17重新执行。

## 02:57 批注身份迁移的两代备份恢复

新增旧全局主键dump→空库恢复自动迁移、复合主键含两个文档同annID→再次实际dump/恢复逐字段保留，见[专项](pdf-recovery-annotation-identity.md)。完整Jobs11、0失败/跳过、17.047秒，日志`/tmp/tokenlibrary-annotation-backup-tests.log`；本轮Jobs仍为隔离PG18，HTTP39另用PG17，不扩大平台范围。

## 2026-09-27 03:39 PG17新边界窄回归

补齐此前Jobs11在本机PG18执行，而新增恢复边界尚未单独跑PG17的主版本证据。本轮将实际Go jobs测试交叉编译为Linux arm64，在本机已存在的`postgres:17`镜像以非root postgres用户执行；容器`--network none`、无host端口、根文件系统只读，仅自己的2GiB临时卷供独立`initdb`集群/备份使用。既有六个合成服务未停止、重建或修改。

03:39:45.431—03:39:55.731，**3项通过、0失败、0跳过**，容器命令跨度10.276秒：

- 旧全局批注主键备份恢复后迁移为文档范围主键，以及再备份/恢复保留两个文档的同ID独立批注（0.76秒）。
- 过期资料、旧回执/快照与独占媒体不进入新custom dump；归档内容和共享媒体保留，真实7天边界比较及旧备份清理（0.72秒）。
- 备份后才实际到达purge期限，再恢复时生成3墓碑、移除2独占媒体、保留2共享媒体和3归档快照，源库保持（8.62秒）。

可重复命令`python3 tests/acceptance/run_jobs_pg17.py`，脚本[run_jobs_pg17.py](../../tests/acceptance/run_jobs_pg17.py)。证据目录`/private/var/folders/jd/9gz27bzs5d55xdmkf57mljx00000gn/T/tokenlibrary-jobs-pg17-kkwy5aej`包含实际test.log、build.log、image/binary/schema SHA和清理proof。测试完成仅删除随机`tl-jobs-pg17-9f8935d49953`容器，未在原生服务读写业务数据。

首轮误设512MiB临时卷，被产品“备份可用空间至少1GiB”检查真实拒绝，3项均在备份之前失败；日志在`tokenlibrary-jobs-pg17-zd0w_2m7/test.log`保留。按要求扩大本轮隔离卷到2GiB后重跑通过，没有关闭容量检查或伪造结果。此三项是既有Jobs11的主版本补证，不新增用例计数，不称Linux部署、实际定时或物理掉电恢复通过。
