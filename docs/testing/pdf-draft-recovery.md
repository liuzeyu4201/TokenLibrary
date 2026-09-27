# PDF 恢复草稿的原件身份

## 换版后的 hash 回归

2026-09-27 02:44—02:45，使用真实临时 `DocumentStore`、两份不同内容的 PDF 原件及持久化草稿，复现以下链路：旧批注编辑面仍持有旧 blob/path，当前文档已经替换为新 blob/path 和新 `metadata.originalFileHash`；提交旧批注被版本检查拒绝并保存草稿。关闭后重开 Store，再创建恢复副本。

旧实现恢复了旧 PDF blob/path 和批注，却直接继承草稿中来自当前新版的 metadata，导致恢复副本、索引书目和待提交 payload 都带新原件 hash。新增 `EditorEditTests.testPDFVersionDraftRecoveryHashesRecoveredBytesAndPreservesOtherMetadata` 在修复前出现三个断言失败，记录 `/tmp/tokenlibrary-pdf-draft-hash-before.log`。它不是只比较辅助函数输出，而是读回恢复文档、持久化 metadata 与真正的排队 payload。

最小修复位于 [EditorEdits.swift](../../clients/LibraryCore/Sources/LibraryCore/EditorEdits.swift) 的 `recoverEditorDraftAsCopy`：真正创建 PDF 恢复副本时读取被恢复的旧原件字节，只重算 `originalFileHash` 这一 JSON 字段。其余书目与未知扩展键保持，blob/path、恢复批注仍对应旧原件；当前新版文档完全不改。放在恢复阶段可同时纠正此前已经持久化的旧草稿，避免每次旧编辑面失败保存都重复读取大型 PDF。原件读取失败仍保留草稿并报告原件不可用。

02:45:15，`EditorEditTests` **16 项、0 失败**，用例合计 0.321 秒；完整日志 `/tmp/tokenlibrary-pdf-draft-hash-after.log`。新增回归同时验证旧字节/旧 blob、正确 hash、其他 metadata（含未知嵌套字段）保留、当前文档原样、恢复新 ID、草稿移除，以及仅新副本产生一条携正确 hash 的待提交操作。原有缺失文件保留草稿、不同批注合并、同批注冲突、工作区隔离和 Markdown 恢复等回归一并通过。

命令在 `clients/LibraryCore` 执行：

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/tokenlibrary-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/tokenlibrary-module-cache \
swift test --disable-sandbox --skip-update \
  --cache-path /private/tmp/tokenlibrary-spm-cache \
  --filter EditorEditTests
```

本轮未连接服务器、读取真实库或操作 GUI，也没有重新构建原生 App。此 Core 证据不能替代原生“冲突与恢复草稿→恢复为副本”的旅程，原生实际覆盖以 [主记录](native-ui-validation.md) 为准；同批注并发与原文件换版是不同触发条件。

## U4：同批注真实双端并发与恢复副本

这条原生旅程使用合成 53056 验收服务、独立附件验收 Mac 客户端与原 iOS 验收客户端，没有向 `editor_drafts` 注入测试数据。它验证同一原件上的批注内容冲突，不能替代上节不同原件换版的 Core 回归。

Mac 新导入并命名 `U4恢复草稿验收.pdf`（`a49ba379-2ce2-421e-a004-f0489df8c2f7`），在第 1 页创建蓝色备注 `U4_BASE_20260927`。revision 3 的基线见 `/tmp/tokenlibrary-u4-annotation-baseline.json`；原件为真实三页 PDF，74,791 B，SHA-256 `5e75077459f63545f07f55a4862c27275a218a41635f50ddfa6635eb3759f424`。批注 ID `02122104-5d08-4c7e-914f-f57cd7113ff0`。

Mac 管理表单实际粘贴 `U4_LOCAL_20260927`，暂不保存；iOS 用软件键盘给同条备注追加 `ios` 并保存。Mac 正常同步到 revision 4、正文批注为 `U4_BASE_20260927ios` 后，于 02:46 点击原编辑表单的保存，看到明确冲突失败。SQLite 产生独立 PDF 编辑恢复草稿 `pdf-f2d6053652254e6239be589b45d30930941d393bd504079f4a329e8aef26c297`，base 为最初 BASE，proposed 为 LOCAL；当前原文保留 iOS 修改。证据 `/tmp/tokenlibrary-u4-annotation-conflict-draft.json`。这是 `editor_drafts` 的真实持久化，不是服务器 `sync_conflicts` 或仅界面未提交文字。

正常退出并重开 Mac 后，草稿完整字段与此前逐项相同：`/tmp/tokenlibrary-u4-after-restart-draft.json`。02:47:49 通过实际恢复入口生成新 ID `e59b4a84-8d48-43dd-b20e-080c7b9f0dce` 的 `U4恢复草稿验收（恢复副本）.pdf`，本机副本保留 LOCAL 备注，原件仍为 BASEios；恢复草稿在本机新副本与排队操作落盘后删除。

首次同步返回 500，未把本机恢复成功写成跨端通过。`/tmp/tokenlibrary-u4-recovered-pending-500.json` 保存副本 revision 0 和冻结 `createPDF` 操作 `21219ff2-c783-4a73-867a-e00620499cd1` 的原 request/payload。原因是服务端批注表误用全局 `annotations.id` 主键，而恢复副本合法保留同一批注 ID；所有现有批注合并、读取和替换本来按文档处理。PDF 导出的 `/NM=tokenlibrary:<批注ID>` 也只在单个 PDF 内识别，不要求不同副本重新编号。服务端正在将唯一身份收窄为 `(document_id,id)`；修复后应让这份已冻结请求原样重试，不能通过改待提交 payload 或重造副本掩盖兼容问题。

本阶段数据完整、重启保留和本机恢复已证实；最终同步、复合身份隔离及 iOS 副本读取须以后续只读证明和 [原生主记录](native-ui-validation.md) 的实际结果为准。

### 03:00—03:01 修复后重试及两端读取闭环

服务端 02:57:33 在同一个验收实例完成批注复合主键增量迁移，库和 epoch 不变，见 [批注身份服务端回归](pdf-recovery-annotation-identity.md)。没有重写 Mac 的失败操作或重新创建副本。03:00:02 只读证明 `/tmp/tokenlibrary-u4-after-server-fix-proof.json` 确认原 `21219ff2…` 自动重试为 sent，operation ID、payload、request JSON 原字节、createdAt、baseRevision、origin 和 frozenGeneration 都与 500 时一致。原文 revision 4、恢复副本 revision 1，服务端各有一条相同 annotation ID 的独立记录，内容分别为 BASEios 和 LOCAL；Mac 待提交为 0，源草稿已无。

Root 随后实际打开：Mac 03:00:32 恢复副本显示已同步和蓝色 LOCAL 备注；iOS 03:00:55 原 PDF 仍为 BASEios，03:01:07 搜索并打开恢复副本第 1/3 页，03:01:19 在管理批注中看到 `U4_LOCAL_20260927`。这些是原生操作观察，不由只读脚本代替。

03:01:42 最终 `/tmp/tokenlibrary-u4-final-three-client-proof.json` 核对 Mac、iOS 的 working/remote snapshot 与 PostgreSQL 当前 revision，两个文档均一致，两端待提交 0。原文批注未被副本覆盖，恢复副本完整保留原先未能保存的 LOCAL；两边共四次原件文件读取与服务端媒体均为相同 74,791 B 和原始 SHA。书目及未知 metadata 保持；本次观察未产生额外阅读 revision（仍 4 / 1）。脚本为正常阅读 metadata 预留了明确允许范围，没有因此跳过批注、当前完整 snapshot 或文件校验。

结论限于已经实际执行的同批注冲突→持久草稿→正常重启→恢复副本→旧冻结请求兼容重试→两端独立读取。它没有演示真实原文件换版导致的草稿 UI，也没有宣称其他所有恢复类型已原生覆盖；换版 hash 修复仍以上节 16 项 Core 证据为准。
