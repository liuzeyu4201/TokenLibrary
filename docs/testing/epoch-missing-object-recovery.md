# 备份恢复后消失对象的冲突处理

## 原生发现与现场保护

2026-09-27 03:41—03:46，独立 57143 合成服务经过真实备份恢复后，原有笔记与备份后新建笔记都保留了本机未提交正文。旧会话收到 401；正常重新登录后，新 epoch 完整快照把原有操作暂停为冲突，未将旧请求盲目重放。

原有笔记在 GUI 中选择“保留本机版本”成功：产生新 epoch、新操作 ID 的更新，原冻结请求转为 `superseded`，其字节未改变。备份后新增笔记因不在备份中，恢复后的服务既没有对象行，也没有删除墓碑；`GET /objects/{id}` 正常返回 `404 / NOT_FOUND`。客户端原来只把 410 交给删除冲突处理，因此该笔记选择保留本机后显示 HTTP 404，表单继续保留。

03:47:27 的只读客户端证据确认，失败没有新建副本或发送恢复操作；完整中文正文、New 标记、两份媒体字节、原操作 payload 和两份冲突材料均未改变。服务端确认发生了失败查询，但没有对应提交回执；“没有回执”不表示“没有请求”。

证据位于：

- `/tmp/tokenlibrary-epoch-native-before-restore-client.json`：两篇完整本机正文、原冻结/未冻结操作、两份媒体。
- `/tmp/tokenlibrary-epoch-native-after401-client.json`：八张相关表及索引、媒体与恢复前一致。
- `/tmp/tokenlibrary-epoch-native-postlogin-client.json`：新 epoch、两个原操作停在 `conflict`，未提交队列为 0，但仍需解决冲突。
- `/tmp/tokenlibrary-epoch-native-after-old-local-client.json`：原有笔记本机选择成功，新操作 `cd6f0aa1-5d34-4479-afc8-118ad06c29ee`；原操作字节保留。
- `/tmp/tokenlibrary-epoch-native-after-missing-local-404-client.json`：新增笔记选择失败后的完整保留现场。

新增笔记有一条 `epoch_changed` 和一条 `deleted` 冲突记录，来源于完整快照与后续缺失对象处理。两者当前显示重复，但保留的是同一正文的历史材料。正常解决一个对象会处理该对象全部未解决记录；本次修复没有删除或合并历史材料。

## 限定修复与自动回归

`LibrarySync.resolveConflictUnlocked` 现在仅在以下条件全部满足时，将 404 交给既有删除冲突处理：

1. HTTP 错误解码为正式 `NOT_FOUND`。
2. 客户端登录 epoch 与本机已经提交的同步 epoch 相同。
3. 持久化的当前冲突仍为 open，类型为 `epoch_changed` 或 `deleted`，其远端材料明确标记相同对象已清除。
4. 当前远端文档缓存中不存在该对象。

代理返回的 HTML 404、其它错误码、旧 epoch、已经重新出现的对象仍报错并保留全部输入。现有 410 行为不变。本机选择仍生成新 UUID 的恢复副本和新的创建请求；服务器选择不重发旧请求；自定义文本用于副本。副本提交失败时，副本及新待提交请求可重开继续处理，旧冲突材料仍保存在数据库历史中。

`MissingObjectConflictTests` 新增 4 项真实 SQLite/URLSession URLProtocol 回归。修复前其中 3 项失败，保护性用例通过；修复后 4 项通过。2026-09-27 03:50:08，与 `FullSyncReliabilityTests` 15 项及 `QueueReliabilityTests` 17 项合计 **36 项通过，0 失败**。

```sh
swift test --package-path clients/LibraryCore \
  --filter 'MissingObjectConflictTests|FullSyncReliabilityTests|QueueReliabilityTests'
```

- 失败证据：`/tmp/tokenlibrary-missing-object-before.log`。
- 修复后：`/tmp/tokenlibrary-missing-object-after.log`。
- `LibrarySync.swift` SHA-256：`b86535530ede6e699457a64290f0e1952bfc47757a9abb8ccad35eaa08a3ad2a`。
- `SyncStore.swift` SHA-256：`2678986aa838d7d2a76907727a1891e5e418e0b0ee0b98b18474e75d935f27c8`。

这组测试没有重跑全部 Core，也不代替修复包的原生重试。独立真实 PostgreSQL 备份恢复联合测试正在补入备份后新增对象分支；完成后另记录实际日志与服务器回执。上述 57143 原生失败现场保持不变，等待正常安装新包后由 GUI 解决。
