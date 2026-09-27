# 编辑并发回归

更新：2026-09-26。全部测试使用随机临时资料库和合成内容。

`EditorEditTests` 覆盖：

- 两个编辑器基于同一旧正文，独立修改后正文、搜索索引、待同步队列一致。
- 16 个编辑会话并发修改不同段落，所有内容保留。
- Web 编辑器后续输入仍基于已提交文本而非合并后的文本时，使用显式基线继续合并。
- 重叠修改保留最新权威正文，同会话重复冲突仅更新同一恢复草稿；重开数据库后仍可恢复副本。
- 回收、到期清理及远端墓碑后的尾部输入不复活原对象；带待同步修改而保留的墓碑工作行也只写草稿。
- 资料库切换后旧会话仍只写原资料库。
- 队列插入被数据库故障触发器拒绝时，正文和索引一起回滚。
- PDF 独立批注合并、同一批注竞争修改、旧 PDF 换版隔离、原版本副本恢复和原文件缺失时保留草稿。
- 恢复 Markdown 后相对图片仍能读取，并包含在便携 ZIP 导出中。
- 多段差异、边界插入、同位置竞争插入，以及真实根、本机虚拟根、缺父、环路和非法父节点。
- 一万行完全替换使用有界保守合并，保留全部基线、当前正文及草稿，避免差异算法的最坏情况长时间占用界面。

`StructureEditTests` 另覆盖 6 项：正文编辑与改名、移动并发；原冻结请求保持不变而可变尾部始终包含最终正文/名称/位置；自包含与后代环路、无效/已删除/专题目标、跨根与根目录保护；大小写和 NFC 文件名碰撞；240 字节协议边界；认证绑定的虚拟根在首次同步之前仍可离线操作，任意缺父 ID 不会被视为合法根。

`DocumentCreationTests` 覆盖 7 项：过期界面父级已删除时拒绝新建；文件、专题、缺父和失效祖先均不能作为容器；只接受认证绑定根；新 ID 不覆盖已有或已删对象；Unicode/大小写同名去重与长文件名后缀边界；16 个同名并发创建取得不同名称；12 轮“新建子文件”和“回收父目录”并发后不产生仍 active 的孤儿。

复现命令（`clients/LibraryCore`）：

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/tokenlibrary-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/tokenlibrary-module-cache \
swift test --disable-sandbox --skip-update \
  --cache-path /private/tmp/tokenlibrary-spm-cache --filter EditorEditTests
```

2026-09-26 18:47 完整 Core 套件 **141 项、0 失败、0 跳过**，包含本页编辑 15 项、结构 6 项和创建 7 项，也启用了真实 HTTP 和系统 Keychain。完整日志：`/private/tmp/tokenlibrary-client-full-tests.log`；此前独立 20 项验证日志：`/private/tmp/tokenlibrary-editor-structure-tests.log`；创建 7 项独立日志：`/private/tmp/tokenlibrary-creation-tests.log`。这里只证明 Core 事务和恢复逻辑，界面协议、真实 WKWebView 生命周期和原生 UI 的验证由主任务另行记录。
