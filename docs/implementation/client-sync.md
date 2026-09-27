# 客户端双向同步与本机资料库实现

更新：2026-09-26。实现位于 `clients/LibraryCore`。本页说明当前代码行为；协议细节见 [服务端同步实现](2026-09-26-sync-server.md)。

## 同步入口与持久化

UI 调用 `SyncClient.synchronize(store:rootId:)`，返回 `SyncSummary`。首次连接取得冻结全量快照，完整读完全部分页并下载/校验附件后，才在一个 SQLite 事务中安装文档、墓碑、索引与 `atSeq` 游标。分页过期 404/410 最多重新创建一次快照；原本机库和游标不会被清空。随后从该游标拉取增量，每页的对象、删除与游标在同一事务提交。流程顺序为全量（若需要）、增量、提交本机队列、再次增量、冲突材料拉取。

`WorkspaceSyncGate` 按数据库真实路径对 `synchronize`、`flushPending` 和 `resolveConflict` 串行排队，等待可取消；不同资料库互不阻塞。前台、后台和冲突界面调用同一入口即可。

数据库迁移为增量变更，保留旧资料和队列。工作副本与服务器权威快照分表，另存墓碑、游标、冲突材料、附件传输状态、拒绝记录和 PDF 文字缓存。升级旧 `awaiting_remote` 队列后，已登录客户端校验原请求身份，读取完整云端快照并重新合并，能够自动恢复。

## 在途编辑与错误恢复

第一次提交前，将 operationId、完整 desiredSnapshot、baseRevision、epoch、deviceId、server origin 和本机 generation 一并冻结入库。网络失败、503、超时或取消后沿用完全相同的请求重放；用户在途新编辑写到另一个未冻结操作，原请求不可变。回执带完整权威快照，客户端以“已提交内容、本机最新内容、服务器结果”做三方合并。安全合并后下一次提交使用新的权威 revision；重叠编辑保存为人工冲突，保留本机文本和三方材料。

正文按互不重叠的行范围合并。metadata 按字段递归合并；批注/附件按 id/blobId、阅读进度按 deviceID、摘录按 id 合并。删除与并发编辑构成冲突，JSON null 与删除字段有区别。删除云端对象时若有本机修改，保留可查看的删除冲突；选择本机内容会创建新 ID 的恢复副本，避免复活墓碑。

地址仅接受 HTTP(S) origin。请求默认 15 秒超时，幂等请求默认最多 3 次短退避；遵守 Retry-After，较长等待交回界面。401 密码登录不会自动重试。中文错误区分断网、超时、证书、权限、限流、维护和响应格式，并提供可执行的恢复方法。

409 NAME_CONFLICT / 422 VALIDATION 是服务端明确未提交的拒绝，保存为 `needs_edit`，仍计待同步；用户改名、移动或修改后生成新 operationId，原冻结请求保留为拒绝记录。无法确定是否提交的失败不走此路径。

## 附件与回收站

`importAttachment(data:fileName:mime:)` 将附件放入当前库 `media/`，返回 `LibraryAsset`。编辑器可用 `library-asset://<blobId>`；`resolveAttachment(path:)` 和 `assetURL(id:)` 在库根内解析，拒绝路径越界。上传支持 1 MiB 分块、逐块 SHA256、持久 uploadId 与断点续传；下载核验 SHA256（描述符及服务端响应头）和长度，损坏内容不能推进资料游标。服务端附件上限 50 MB。

文件夹回收操作在本机和服务器保留共同 trashBatchId，递归还原本批次；此前独立回收的子项保持回收状态。云端 batch 在权威快照中持久化，因此跨设备离线还原同样有效。

## 会话、资料库隔离与显式迁入

`SessionVault` 使用系统 Keychain 保存 token、epoch、libraryId、rootId、deviceId 与用户名，不保存密码。账号查询键为标准化 server origin；Keychain 项为设备限定、解锁后可访问。`LibraryWorkspaceManager` 以 SHA256(server origin + libraryId) 分目录，数据库重复绑定其他身份会拒绝。独立本机入口为 `localStore()`。

`importLocalLibrary(from:sourceRootID:targetRootID:)` 是显式复制：仅复制源 root 后代；无碰撞保留对象 ID，碰撞产生新 ID；重新定位附件、专题引用、父级与回收批次；目标文档和创建队列在事务中提交。源库、源文件始终保留；文件复制中断可能留下未引用的目标缓存，不能留下半份目标文档事务。

## 全文检索与 PDF 阅读性能

`DocumentStore.searchDetails(query:limit:)` 返回 `LibrarySearchHit { objectId, excerpt, pageIndex }`，PDF 页码从 0 开始，每份资料返回最佳命中。`search(query:)` 保留 ID 列表接口。FTS5 使用中文双字词、单字与英文前缀 AND 查询，不再全表 LIKE 扫描；回收对象不出现在结果中。

PDF 按页提取并缓存，键包含路径、不可变 blobId、文件大小与 mtime。metadata 只索引 `catalog.searchText`，不把设备 ID、阅读页码或内部 JSON 键作为内容。阅读进度改变时既不重新读取/解析 PDF，也不改写内容未变的 FTS 行；缓存跨进程重开可复用。命中摘要只显示原文，不暴露分词串。

## 实际边界

冻结全量快照当前在内存收齐后原子安装；大库需要与可用内存一起评估。文本合并保守处理重叠段，不做语义改写。自动排队不代表系统会无限延长后台执行；平台授予的后台时间耗尽时应取消，已落盘队列和游标可继续恢复。客户端端到端测试只使用独立 localhost 测试服务，未读取真实 `.env` 或用户资料。
