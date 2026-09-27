# Markdown 导出与来源说明回归

2026-09-26 22:49:53（Asia/Shanghai），专项 **7 项通过，0 失败、0 跳过**：`LibraryExportTests` 6 项，加 `MarkdownImportTests.testCrossWorkspaceCopyAndPortableExportIgnoreCodeOnlyMedia` 1 项。没有重复运行完整 Core 套件。

日志：`/private/tmp/tokenlibrary-markdown-export-tests.log`。

## 实际验证

- 生成真实可解码 PNG，导出后通过系统工具解包，附件字节与原件完全一致。
- 旧 `library-asset://` 图片在离线导出副本中变为相对路径；代码块中不存在的媒体样例不会读取，也不被改写。
- 阅读笔记在来源原件缺失时仍导出可读的标题、第 8 页、原文、评论和版本记录。
- 正文明示应用内来源链接的外部限制，并链接到 `来源说明.md`；笔记本身叫同名时使用 `来源说明_1.md`。
- 引用原文内有三反引号和 Markdown 图片语法时，来源说明仍按纯文字呈现，不引入附件请求。
- 没有 Catalog 快照的旧应用链接仍获得限制说明，不假造来源资料。
- 导出前后库内正文、元数据、附件字节、同步队列不变；简单 Markdown 仍是单文件，缺少实际媒体明确失败。
- 原有 ZIP 路径遍历、重复条目拒绝与 CRC 校验保持通过。

使用 macOS `/usr/bin/ditto -x -k` 实际解包并读取中文文件名和媒体；同时保留 `/usr/bin/unzip -t` 结构校验。初轮用系统旧 Info-ZIP `unzip -p` 精确匹配中文条目失败，该构建的编译选项未列出 Unicode support；改为系统解包器验证实际中文路径后通过，没有为绕过失败更改文件名或移除中文断言。

## 复现

在项目根目录运行：

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/tokenlibrary-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/tokenlibrary-module-cache \
swift test --package-path clients/LibraryCore --disable-sandbox --skip-update \
  --cache-path /private/tmp/tokenlibrary-spm-cache \
  --filter 'LibraryExportTests|MarkdownImportTests.testCrossWorkspaceCopyAndPortableExportIgnoreCodeOnlyMedia'
```

以上证明 Core 导出文件、实际解包内容和来源说明；不等同 macOS/iOS 保存面板或所有第三方 Markdown 应用的操作均已验收。

## 原生插图、撤销重做与实际 ZIP 产物（23:02—23:05）

主验收在Mac原生编辑器对“移动后阅读笔记.md”（`de82c808-8566-4b03-9d9b-e2351d0de31b`）于23:02插入fixture-diagram.png，23:03实际撤销/重做后同步归零；23:04通过系统保存面板生成 `/tmp/tokenlibrary-ui-fixtures/native-source-note-with-image.zip`。此文件是实际UI产物。

23:05独立PG只读事务/SQLite mode=ro和文件读取确认：本机与服务器均revision13，完整正文逐字符一致、状态已同步，SHA-256为 `4cc53af6aad1aea293d9baad7941009d7b1a20cc5b786bbaea4402668ef5c53d`，本机与服务端assets记录相同。原始夹具、本机media、服务器实际blob、ZIP内图片均为50,786 B，逐字节相同、SHA-256均为 `2a85488c6ed062f681b3fc4f518777f00f22389f6f1be7cdac2aeffe73148393`。blob为ready；媒体路径为 `media/ba40e80b-9c01-4177-a1ac-e28af2d302b4.png`，全工作区未完成队列为0。

ZIP为53,926 B，CRC独立复核通过、恰好4条目：正文、metadata.json、来源说明.md和上述PNG。导出正文以当前库内全文为精确前缀，随后增加只在导出副本中的来源限制说明；库内正文没有该附加说明。来源说明包含研究PDF标题、第2页、Research Anchor Beta、评论和来源版本hash。ZIP metadata与当前本机/服务器metadata语义完全一致，规范JSON的SHA-256为 `da198d271e4b532b34f11cb777b54f5b8d7ea843fc2f750e1850b09c317d7930`。

这是导出后现状的一致性核对，没有独立保存本次原生导出前快照，因此不能由此声称对该次UI操作完成了“导出前后未改库”的直接比对；导出不改正文/metadata/队列的前后断言来自上文自动回归。其他Markdown阅读器的交互未在此次只读检查中执行。

原始UI产物清单 `/tmp/tokenlibrary-native-source-export-proof.json`；独立核对 `/tmp/tokenlibrary-native-image-export-readonly-proof.json` 和PG只读材料 `/tmp/tokenlibrary-native-image-server-readonly.json`。最新23:59:14完整Core204项、0失败/跳过记录见[客户端同步验证](client-sync.md)。

## iOS系统Files导出与外部阅读（2026-09-27 00:04—00:07）

主验收在原de82阅读笔记实际打开fileExporter，首次取消没有生成文件；第二次保存 `移动后阅读笔记.zip` 至Files“我的iPhone”。用Files解包后显示正文Markdown、来源说明、media目录和metadata四项。来源说明在系统预览中完整显示标题、页号、hash、引文与评论，PNG在外部预览中图像完整。该段证明实际系统保存/取消与外部可读性；后续[独立三方证明](ios-export-reimport-proof.md)已核对实际ZIP四条目CRC、解包文件、六处PNGhash一致，原de82仍revision23且正文/metadata/assets未变。回导副本独立ID、正文只重写图片路径；这不替代iOS带批注PDF导出。
