# 旧版混合本机库根目录兼容

更新：2026-09-26。针对旧安装直接使用 `base/library.sqlite`、本机 `root` 与服务端 UUID 根资料混存在同一数据库的情况。旧资料可能只有 `parentId=服务端根 UUID`，没有保存根文件夹实体；只遍历真实文件夹或默认 `root` 会让这部分资料无法导航或从“复制本机资料”中遗漏。

## 信任来源与 API

`DocumentStore.registerLegacyLibraryRoot(rootID:server:libraryID:)` 只接收旧安装已经持久化的连接根身份，例如 `connection.rootId`。调用方不得从任意资料的缺失父 ID 推测根。根必须是合法 UUID；现有同 ID 对象必须是活跃、无父级、非专题的文件夹；墓碑根不可登记。提供的服务器地址按 origin 规范化；与数据库已有 server/libraryId/rootId 或同根已有登记证据冲突会明确拒绝。

登记只新增 `sync_state` 下独立 `legacy.root.*` 记录，不调用 `bindWorkspace`，不创建假根实体，不改旧文档、附件、未提交操作、冻结请求、游标或服务器身份。重复相同登记无变化，只可为缺失的身份上下文补充明确值。

`legacyLibraryInventory()` 在一致数据库快照中返回：

- `rootIDs`：默认本机根、真实无父级文件夹根、已保存的同步根，以及通过上述流程登记的根。
- `rootsByDocumentID` / `rootID(for:)`：资料和目录所属可信根；也能直接解析可信虚拟根自身。
- `unresolvedDocumentIDs`：缺父、目录循环、文件被当成父目录等无法安全归属的资料；保留原位置与内容，不能自动当作另一资料库根。

界面应缓存 inventory 用于旧本机库根列表与导航，只按可信 `rootIDs` 发起显式迁入，且报告仍有待恢复资料。只有实际旧 `base/library.sqlite` 存在时才把对应旧偏好作为登记输入；新建资料库不使用全局旧偏好扩充自己的根。

迁入目标已有相同对象 ID 时，复制后的新 ID 同时更新专题/来源/相关资料数组、每条摘录的 `sourceID` 及 Markdown AST 中实际链接的 `tokenlibrary://document/…` 路由。页码、文件 hash、原文、评论与未知 JSON 字段保留；代码示例和迁入范围外的链接不改。否则笔记可能错误跳到目标库中 ID 碰撞的其他资料。

## 本机操作与绑定隔离

未绑定服务器的旧混合本机库，在已登记虚拟根下支持新建、移动、专题、阅读笔记和编辑草稿恢复；操作仍校验当前祖先、同库、专题目标与名称。不同根之间不能直接移动或建立跨库专题关系。

绑定服务器的数据库仍只接受其认证根作为可写虚拟根。旧根登记不能扩充绑定库的创建或恢复目的地，不会把旧队列发给另一个服务器。原有显式复制 API 为目标创建独立操作，源文档、附件和原队列保留。

## 主要代码与边界

- `clients/LibraryCore/Sources/LibraryCore/LegacyLibraryRoots.swift`：登记、身份检查、inventory 和未绑定库的可信虚拟根集合。
- `StructureEdits.swift` / `Catalog.swift` / `EditorEdits.swift`：在当前事务中使用根集合校验目的地。
- [旧库兼容测试](../testing/legacy-library-roots.md)：明确根、未知孤儿、冻结队列、资料复制与恢复草稿。

没有旧身份记录的孤儿资料仍需明确恢复处理。本次不会凭父 ID 自动推断服务器、账号或库绑定，也不把 Core 验证等同真实旧安装的完整双端升级旅程。
