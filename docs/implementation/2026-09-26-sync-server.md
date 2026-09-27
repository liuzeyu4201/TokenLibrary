# 同步服务合同（2026-09-26）

本文记录本轮已接通的 HTTP/数据库行为，协议版本仍为 `protocolVersion: 1`。旧的 [技术方案](../legacy/技术方案-v1.md) 包含更广的目标；其中路径、保留时间和容量设想不能直接当作当前实现合同。验证范围见 [同步测试](../testing/server-sync.md)。

## 通用约定

前缀为 `/api/v1`。客户端接口使用 `Authorization: Bearer <sessionToken>`，由 `POST /auth/login` 获得会话、`libraryId`、`rootId`、`epoch`。请求携带 `X-Library-Epoch`；写入与同步变化流遇到不匹配返回 `409 EPOCH_CHANGED`。UUID 为字符串，公开的 revision/seq/cursor 为十进制字符串；操作 `base.revision` 使用 JSON 整数。

成功体是 `{data: {...}, requestId: "..."}`，错误体是 `{error: {code, message, retryable}, requestId}`。维护写入返回 `503 MAINTENANCE` 和 `Retry-After: 30`；认证失败为 401。`/health/ready` 返回就绪与维护状态；它不替代登录或端到端同步验收。[路由与响应](../../server/internal/api/api.go)

## 首次全量快照与增量

| 请求 | 当前合同 |
| --- | --- |
| `POST /sync/snapshots`，空体或 `{"limit":100}` | 创建冻结清单并返回第一页。包含 active 和尚未过期的 trashed 对象以及根目录。取得库行锁后冻结对象内容与 `atSeq`；后续写入不会改写已冻结内容。 |
| `GET /sync/snapshots/{snapshotId}?after=0&limit=100` | 按固定 ordinal 分页；after 使用上页 `nextCursor`，默认/最大 100 条，每页正文软上限 16 MiB（首条总会返回）。 |
| `GET /sync/changes?after={seq}&limit=100` | 返回固定数据库读取视图中的有序事件。`after` 超出服务端当前序列返回 `409 CURSOR_INVALID`；应重新开始全量快照。 |

全量响应字段：`snapshotId, libraryId, rootId, epoch, atSeq, expiresAt, items, nextCursor, hasMore`。`items` 元素为 `{id, revision, snapshot}`。快照有效一小时，过期或被永久删除流程失效时返回 `410 SNAPSHOT_EXPIRED`；后台删除记录后为404。期间永久删除或到达清除期限的对象不再提供正文。客户端应在全部分页成功落盘后将增量游标设为 `atSeq`，分页404/410重新建快照，失败时保留旧库及旧游标。

增量响应：`{changes, nextCursor, hasMore, latestSeq, epoch}`。每个事件为 `{seq, manifest, objects, deletedIds}`；`objects` 元素同上，`manifest` 保留兼容字段并含相同对象和墓碑列表。一次文件夹删除/恢复可能在一个事件内包含多项对象。未发生事件但有旧序列空洞时，末页 `nextCursor` 推进到 `latestSeq`。旧数据库缺少 purge change 正文时按墓碑的 purge_seq 聚合补发。客户端必须将每页对象修改与游标提交作为本地原子操作。[冻结分页](../../server/internal/api/snapshots.go)、[变化流](../../server/internal/api/changes.go)

## 对象写入与回执

`POST /sync/operations` 请求：

```json
{
  "protocolVersion": 1,
  "operationId": "UUID",
  "epoch": "UUID",
  "deviceId": "UUID",
  "objectId": "UUID",
  "action": "updateDocument",
  "base": {"source": "revision", "revision": 3},
  "desiredSnapshot": {"name": "reading.md", "markdownSource": "...", "metadata": {}}
}
```

动作：`createFolder`, `createMarkdown`, `createPDF`, `updateDocument`, `rename`, `move`, `trash`, `restore`, `resolveConflicts`。`Idempotency-Key` 可省略；若提供，必须与 body.operationId 一致。相同 operationId 必须重发相同原始请求字节；更改字节返回 `409 IDEMPOTENCY_MISMATCH`。操作、修订、引用、变化事件与回执在同一事务提交。所有对象写事务取得库行锁，保证序列顺序与提交一致。

创建返回 201，更新/冲突/重放返回 200。`data` 含 `operationId, status, objectId, revision, changeSeq, epoch, conflictIds, receipt, replayed, snapshot`；`status` 为 committed/no_change/conflict。其中 snapshot 是本次回执的权威状态，重放仍返回原回执快照。客户端据此 rebase 请求发送期间新增的本地编辑，不能只替换 revision。`GET /sync/operations/{operationId}` 查询同一回执；过期/永久清除对象返回 410。

`base.source=receipt` 使用 `{operationId, hash}`，hash 为回执 inputHash；服务端校验操作属于同一对象后按该回执的 result_revision 读取历史基准，不使用当前版本充当旧基准，也不接受客户端自报 snapshotBytes 覆盖权威历史。`GET /objects/{id}` 返回 `{snapshot, hash}`；`GET /objects/{id}/revisions/{revision}` 返回该修订快照。后者缺失返回 `409 BASE_REQUIRED`，对象过期返回 410。[操作与事务](../../server/internal/synceng/engine.go)

公开 snapshot 的公共字段为 `id, revision, kind, name, parentId, state, metadata, conflictIds, trashBatchId`；trashed 时附 `purgeAt`，并保留原 parentId。kind 为 folder/md/pdf。Markdown 另有 `markdownSource, assets`，PDF 另有 `pdfBlobId, annotations`。

## 资料元信息与合并

`metadata` 是通用 JSON 对象，默认 `{}`，上限 256 KiB；客户端模型可新增书籍、论文、笔记、专题、阅读位置、来源关联等字段。嵌套对象按字段三方合并，不同字段的独立修改可同时保留。`readingPositions` 数组按 `deviceID`、`excerpts` 数组按 `id` 合并记录，允许不同设备阅读位置/不同摘录同时新增或修改；相同记录的竞争字段编辑与删除对编辑仍冲突。其他数组按整体值比较。显式 JSON null 与删除键不同。旧客户端省略 metadata/assets/markdownSource/pdfBlobId/annotations 表示沿用基准，避免抹掉新字段。

Markdown 上限 5,000,000 字节；未发生双边修改时保留源字节与末尾换行。双边修改使用已有段落/块合并规则。PDF 批注按 ID 合并；同一批注删除对并发编辑会冲突。[合并实现](../../server/internal/merge/merge.go)、[字段与引用验证](../../server/internal/synceng/blobs.go)

批注格式：`{id, type, pageIndex, geometry:{x,y,width,height}, color, text, placementState, pdfBlobId}`；type 为 highlight/comment，placementState 为 attached/needs_review。替换 PDF 时旧坐标继续绑定旧 pdfBlobId，标记 needs_review；明确绑定新 PDF 的批注保持 attached。缺少绑定的旧批注按基准 PDF 补齐。[PDF 绑定](../../server/internal/synceng/annotations.go)

## 文件、冲突与回收站

| 请求 | 行为 |
| --- | --- |
| `POST /uploads`：`{blobId,size,sha256,mime}` | 返回 uploadId/blobId/state/chunkSize/expiresAt。1 MiB 固定块；同设备以相同 blobId+hash+size+mime 重试返回现有 uploadId。不同字节使用同 blobId 返回409。未完成上传有效24小时。 |
| `GET /uploads/{id}` | 返回已确认的 `chunks:[0,1,...]`。上传属于登录设备。 |
| `PUT /uploads/{id}/chunks/{index}` | 原始二进制，块长必须匹配；推荐携带 `X-Chunk-SHA256`（传入时服务端校验）。可重发块。 |
| `POST /uploads/{id}/complete` | 要求所有连续块齐全，流式校验完整 SHA256/size，文件同步并原子发布后更新 ready；重复完成幂等。 |
| `GET /blobs/{id}` | 需要会话，返回实际 MIME、`ETag: "<sha256>"`、`X-Content-SHA256` 和 Range 支持；客户端校验下载哈希。 |

图片最大 20,000,000 字节，其余文件最大 50,000,000 字节。PDF 快照的 pdfBlobId 和所有 assets/annotation 引用必须指向本库 ready blob；Markdown assets 推荐 `{blobId,path:"media/...",sha256,size,mime}`，兼容 id 作为 blobId。当前对象、每一历史修订、未解决冲突材料分别登记 blob_refs，避免错误回收。[上传下载](../../server/internal/api/uploads.go)

`POST /imports` 保持上传令牌导入入口，支持 md/markdown/pdf。同幂等键同文件同目标返回原对象，不重复导入；不同输入返回409。它与桌面/手机会话的 uploads 接口权限不同。

`GET /conflicts?objectId=UUID` 列出未解决分支；`GET /conflicts/{id}` 返回 revision/currentRevision。`GET /conflicts/{id}/materials/{base|local|remote}` 的 data 同时提供 bytes 与完整 snapshot。解决操作使用 `action: "resolveConflicts"`、`resolution:{conflictIds:[...],revision:"当前修订"}` 与最终 desiredSnapshot；分支不属于对象、已经解决或 revision 过时均返回 `409 CONFLICT_STALE`。[冲突接口](../../server/internal/api/conflicts.go)

trash 普通文件夹只纳入当时 active 后代，同事务写入共同 trashBatchId、原父级与30天期限。**直接删除 metadata.category=topic 的专题时**，服务端先在同一事务枚举并把 active 直属物理子项移到专题父级，重名自动 `_数字`，保留子项的后代和内容，再只删除专题本身。这样旧客户端或另一设备在本机扫描以后加入的资料也不会被专题删除误伤。移动对象各自递增 revision，移动与专题删除在同一增量事件发布；重放同操作不重复移动。若删除的是外层普通文件夹，其中专题与物理后代仍遵守普通递归删除意图。

restore 只恢复选中子树内同批次的对象；此前独立删除项保持在回收站，专题删除时移出的资料不会在恢复专题时被强制移回。原父级不可用时根对象恢复到库根；同名冲突返回409，整个事务回滚。公开快照携带批次供第二台设备离线执行相同语义。

## 会话生命周期

固定账号登录生成设备 session；会话授权与滑动续期在一条数据库 UPDATE 完成，条件包括当前库、凭据世代、未撤销及最近连接未超过90天。匹配不到返回401；数据库续期失败返回可重试503，不能把存储故障误报成密码错误或继续假定续期成功。退出在持久撤销成功后才返回 loggedOut=true；数据库失败返回503供调用方说明未确认远端撤销。

独立上传 Token 仅用于导入，轮换和停用不改变客户端 session。认证生命周期、退出后的旧 Token 拒绝以及触发器注入数据库失败的证据见 [服务端测试补充](../testing/server-sync.md)。本机 Keychain 清除与离线编辑由客户端处理，服务端会话失败不得成为删除本地资料的理由。

## 存储升级和维护边界

保留原始 schema fingerprint，通过独立事务迁移添加 objects.metadata、快照 ordinal 和 app_migrations。已有库无须更换初始 SQL。[迁移](../../server/internal/store/migrations.go)

Store 以持续 PostgreSQL session advisory lock 限制同库同时一个服务实例；连接失去锁通道时健康检查/写入返回不可用。进程内 Writes 门闩协调对象、上传、导入、快照创建与维护。备份/清除由运维实现持有独占门闩；部署与恢复步骤在各自运维文档验收，不由本合同替代。[Store](../../server/internal/store/store.go)

19:10 补充：清理和备份虽然都占用写锁，但重试语义不同。每 30 秒的 retention 短清理曾与同步分页竞争；旧实现统一回复 MAINTENANCE/30 秒，超出客户端短重试预算，导致一次正常同步被中断。现在取得读锁失败时查询实际维护标志：备份仍为 MAINTENANCE/30 秒，非维护的短锁竞争为 BUSY/1 秒；数据库不可用为 UNAVAILABLE，操作路径也使用短重试。对象提交、附件上传/完成和 curl 导入共用此区分。未改变写入排空及备份一致性边界。

客户端保留服务器错误码和 Retry-After，BUSY 在预算内以同一请求、同一 operationId 重试；30 秒维护不会被抢先重试。数据库事务提交失败也返回明确 UNAVAILABLE，不再生成无分类的 503。真实 PG 竞争回归见 [同步验证](../testing/server-sync.md)。

仍需明确的范围：`/ws` 是兼容提示接口，实时同步使用轮询；尚无大文件夹负载/高并发/跨地域网络性能承诺；本文的1000资料测试为正文和元信息的规模测试，不等于1000份50MB PDF吞吐验收。原生 UI 与真机行为由客户端验收单独记录。
