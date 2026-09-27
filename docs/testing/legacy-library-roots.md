# 旧版混合本机库根兼容测试

2026-09-26，独立临时 SQLite 资料库，不读取真实偏好、Keychain、用户资料或服务器凭据。

19:11:55 `LegacyLibraryRootsTests` **7 项、0 失败**，具体断言来自 `clients/LibraryCore/Tests/LibraryCoreTests/LegacyLibraryRootsTests.swift`；随后19:12:23的完整Core **179项、0失败/跳过**包含本组，日志 `/private/tmp/tokenlibrary-client-full-tests.log`。最新完整运行结果见 [开发账本](development-status.md)。

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/tokenlibrary-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/tokenlibrary-module-cache \
swift test --package-path clients/LibraryCore --disable-sandbox --skip-update \
  --cache-path /private/tmp/tokenlibrary-spm-cache --filter LegacyLibraryRootsTests
```

| 场景 | 实际断言 |
| --- | --- |
| 混合本机/缺实体的服务端根 | 未登记时资料列为 unresolved；用明确旧根登记后目录与后代归入正确根；本机 root 原有资料仍归原根；随机缺父仍未知 |
| 原库保护与重启 | 登记前后全部文档、pending 操作及冻结 requestJSON 完全一致；server/libraryId/rootId/epoch/cursor 没被偷偷设置；重开和重复登记结果不变 |
| 损坏目录 | 缺父、环路、Markdown 被当成父节点、空父级非文件夹都不能成为可信根；拒绝在未知父目录新建或移动 |
| 无效根身份 | 非 UUID、已有普通文件/非根文件夹、无效 origin 均拒绝，不改队列 |
| 已绑定库隔离 | 不同 server/library/root 提示冲突；同根登记不扩展绑定库边界；绑定库仍不能向虚拟本机 root 新建/移动 |
| 同根可继续工作 | 在登记根下新建/移动、专题关联成功；跨根移动/关联拒绝；并发编辑产生的恢复草稿可保存副本且保留远端原文 |
| 完整复制与损坏登记 | 复制本机 root、真实根与登记虚拟根的每项资料和附件，随机孤儿保留原库并报告；原件字节/queue 不变。损坏登记 JSON 和后来出现的同 ID 非根冲突不会被信任 |

19:13:17客户端模型完整19项也通过，其中AppModel测试实际创建旧base/library.sqlite和独立持久偏好，核对Root启动、根列表、旧目录内新建与未知资料保留。日志 `/tmp/tokenlibrary-ui-model-tests.log`。

原生界面还需核对旧安装启动后根列表、待恢复提示、选择旧资料、复制结果与保留原库的反馈。不能以七项 Core 测试代替该用户旅程。

## 22:27 迁入来源碰撞回归

WorkspaceTransferTests 7 项全通过，并纳入 Core 189 项完整通过结果。新增测试在目标放置同 ID 的无关资料，验证复制后的 sourceIDs、excerpts.sourceID、内联/引用式来源链接全部指向新资料；页号/hash、原文评论和未知字段保留，代码块/行内代码与范围外链接不变，源库文档和待提交队列完全未改。
