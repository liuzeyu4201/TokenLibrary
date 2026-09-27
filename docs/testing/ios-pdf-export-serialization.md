# iOS 批注 PDF 导出结构回归

## 真实问题与范围

2026-09-27 原生 iOS 从系统 Files 导出的 `research-three-pages_2.pdf`，保留副本为 `/tmp/tokenlibrary-ui-fixtures/ios-native-annotated-export.pdf`（83,728 B，SHA-256 `7491fc364f9975cbbe0511a8033490e28e4a0c1345bfcb05718db73a3dad7ae9`）。绿色高亮和中英文字、🧪外观均可见，但严格遍历发现 xref 把不存在的 6 号对象标记为 offset 0、in-use；两条批注的 `/NM` 均丢失。仅“能打开、能显示”不足以通过导出验收。

在同一个已启动的 iOS 26.5 simulator 中，使用独立 SDK 命令行测试程序验证，不安装、启动或访问验收 App/凭据，也不操作 GUI：

- `.name`、原始 `NM`、原始 `/NM`、三种 `withProperties` 共六种官方属性写法，内存均可读回，序列化后均丢失 `/NM`。
- `dataRepresentation`、`write(to:)`、重新打开后再次序列化，共 21 份产物出现相同问题。
- 不添加任何批注的 baseline 也产生无效 6 号 xref 槽。因此该索引问题并非自定义 FreeText 外观造成。

API 对照在 `/tmp/tokenlibrary-ios-pdfkit-writer-probe-results/{api-results,external-results}.json`。Apple 文档说明 `setValue(_:forAnnotationKey:)` 设置批注字典，而 PDFKit 支持保存自定义绘制与字典数据；本次 SDK 的真实输出与预期不符。[Apple 属性 API](https://developer.apple.com/documentation/pdfkit/pdfannotation/setvalue(_:forannotationkey:))、[Apple PDFKit 保存说明](https://developer.apple.com/videos/play/wwdc2022/10089/)

## 实现边界

`PDFExportSerialization` 仅检查和修正 **PDFKit 本次完整序列化输出**，不充当任意外部 PDF 修复器。输入原件仍由 PDFKit 打开，导出不覆盖原件或批注元数据。

1. 读取末尾 classic xref，按已索引的对象偏移校验对象号、generation 和边界；解析字典、数组、引用和转义字符串，不以全文正则定位 PDF 对象。
2. 流按 `/Length`（支持间接值）跳过并校验结束位置。图片/字体流的原始字节保持不变，内部即使出现 `xref`、`endobj` 或 `/NM` 字样，也不会当作结构处理。
3. 仅将 **没有引用** 的 offset 0 in-use 槽改为 free，重建完整 xref 与 free list；若该缺失对象确有引用，则明确报错，不能把内容缺失当成成功导出。
4. 导出前捕获所有已命名批注（包含原件自己的标识）。按页和批注顺序匹配，并核对类型、正文及矩形坐标后，补回缺失 `/NM`；使用 UTF-16 十六进制 PDF 字符串，避免转义歧义。两个外观相同的批注保留各自标识，已有不同标识不会被覆盖。
5. 原页面与外观流不扁平化。结构未知、循环页树、错误偏移、引用缺失对象或标识对应不明确时，返回可理解错误；原件、批注仍保留。当前支持 PDFKit 输出的完整 classic xref，不支持把增量 `/Prev`、xref stream 或加密输出猜测改写。

## 自动回归与外部检查

`PDFAnnotationTests` 原 10 项加 `PDFExportSerializationTests` 新 10 项；首轮于 `00:46:14` 执行 **19 项、0 失败**，随后加入截断 trailer 回归，`00:48:50` 已纳入完整 **218 项、0 失败、0 跳过** Core 套，日志 `/tmp/tokenlibrary-pdf-serialization-tests.log`。新增范围包括恢复 Unicode 标识、直接/间接批注数组、流内伪结构保留、已有外部标识、外观相同的独立批注、重复处理字节稳定、真正缺失引用拒绝、错误 stream 长度、循环页树和错误偏移拒绝。

可复用 SDK 程序为 `tests/fixtures/probe_pdf_export_serialization.swift`，和当前 `PDFAnnotations.swift`、`PDFKitExport.swift`、`PDFExportSerialization.swift` 一起编译。它在真实三页夹具与原生保存的两条 metadata records 上分别执行：首次导出、对同一导出再次应用同 ID、把旧导出作为新原件、将一条标注设为需要重新定位。

初轮真实 iOS 结果：四份产物分别保留 2、2、2、1 条批注，标识、中文与表情 Contents 完整；使用 `tests/fixtures/verify_pdf_exports.py` 逐个读取所有 xref 对象、解码全部流并用 Poppler 渲染全部页面，四份均通过且无 Poppler warning。第 2 页高亮位于原选中文字，第 3 页备注位置及中英文、🧪外观与原生未修复产物一致。记录为 `/tmp/tokenlibrary-ios-pdf-export-serialization-proof.json`，图片在同名前缀 `-render/`，SDK 运行日志为 `-run.log`。Mac SDK 同样四份产物均通过外部严格检查和全部页面渲染，记录 `/tmp/tokenlibrary-macos-pdf-export-serialization-proof.json`。最终 Core 218 项包含新 10 个结构用例，日志 `/tmp/tokenlibrary-client-full-tests-20260927-final.log`。

这验证了实际 iOS PDFKit 代码路径和外部阅读器兼容性；当时修复后的应用尚待原生 Files 再导出，该复测现已在下节 01:01—01:02 完成，SDK 与原生证据分别保留。

## 00:50 双端验证包

修复与当轮书目离开保护、失效关系清理一起构建完成。包位于 `/private/tmp/tokenlibrary-pdf-catalog-build-axse18gl/{macos,ios}/DerivedData/Build/Products/` 下的 Debug / Debug-iphonesimulator `TokenLibrary.app`。两个包 strict/deep 签名均通过，50 个捕获的 Swift、plist 和编辑器文本资源 hash 与构建前一致；iOS simulator application identifier 为 `7728J3WTW8.app.tokenlibrary.verification`。

归档 SHA-256：Mac `142f6e3e2865dc10c3e941817bc6f1540133c4a3f1acc54597835c232d8e6c62`；iOS `74e73ba3c95475b998064af6fe9e5a86bb93ea1be80a3ccebe057680569567e6`。`verification.json`、构建与签名日志同目录。00:37 已验包保持不变。这轮尚未包含 00:50 后另行开始的 iOS 搜索结果进入文件夹修复，后续合并包需要另存证据。

## 大文件与现代输入兼容

最终 SDK 测试增加 49,745,911 B、8 页含图片的 PDF，在第 8 页附加中英文与 🧪备注；iOS 单次导出 0.809 秒、输出 49,755,058 B，Mac 单次 0.127 秒、输出 49,762,993 B。两端均逐对象/逐流严格通过、8 页全部 Poppler 渲染无 warning；原输入按字节比对不变。日志 `/tmp/tokenlibrary-{ios,macos}-large-export-serialization.log`；数据已列入两平台前述 proof JSON。这里只记录单次 SDK 耗时，不代替 App 主线程体验或峰值内存测量。

另外通过 `tests/fixtures/generate_xrefstream_variant.py` 把合成三页原件变为 xref stream，并将 Info 字典放入压缩 ObjStm。两端均能从该现代输入执行首次/重复/重新导入/失效标注四路径，8 份输出全部严格逐对象、逐流通过，证明限制的是 **PDFKit 的序列化输出格式**，不是拒绝这类外部 PDF 输入。记录 `/tmp/tokenlibrary-xrefstream-export-proof.json`。

包含相同 PDF 修复和最新搜索/移动入口的后续签名包于 `00:55:20` 交付，见 [00:55 合并导航验证包](client-sync.md#0055-合并导航验证包)。旧 00:50 PDF 包没有被覆盖。

## 01:01—01:02 修复后原生 Files 再导出

主代理使用 00:55 navigation 签名包，从同一 `afecb79c…` PDF 的“更多 → 导出含批注”进入系统 Files，另存为 `ios-import-acceptance/Fixed.pdf`，应用明确提示文件已导出。文件 mtime 为 `01:01:13.548951`；独立只读核验于 **01:02:37.189243 +08:00** 完成。此段是实际应用与系统导出路径，补足此前 SDK 验证。

证据目录 `/private/tmp/tokenlibrary-native-pdf-final-17pl2d7t` 包含原样复制的 `native-export.pdf`、`proof.json` 与全部 3 页 Poppler PNG；只读取指定模拟器 Files 文件和验收 App 的指定 SQLite 行，没有操作 GUI、写应用库或读取会话凭据。

- **84,144 B**，SHA-256 `836cee8aed5e0617211c85dc5a620d186e1e4127a0685166f2af19b3e21d7569`。所有 xref 对象严格读取通过，**11 个流**全部解码；6 号槽明确为 free，不再存在 offset 0/in-use 缺失对象。
- 三页与原始 Alpha/Beta/Gamma 可检索文本保留；全部页面 Poppler 渲染无 warning。目视第 2 页绿色高亮对齐 Beta 文本，第 3 页备注的“iOS 第三页备注 🧪”外观完整，坐标与存储记录一致。
- 两个 `/NM` 精确匹配 `tokenlibrary:cef58e16-ad79-42d3-8464-0af09ad894f5` 和 `tokenlibrary:76ccd9a3-07e6-4c13-a952-9f4caa798294`，分别在第 2 页 Highlight 与第 3 页 FreeText；没有重复或额外批注，Contents 与当前 metadata 相同。
- 工作文档仍 revision **7**、已同步；原件仍 **74,791 B**，SHA-256 `5e75077459f63545f07f55a4862c27275a218a41635f50ddfa6635eb3759f424`，与最初合成导入文件逐字节相同。旧有缺陷导出 `research-three-pages_2.pdf` 仍 83,728 B、原 hash `7491fc36…dad7ae9`，未被本次另存覆盖。

主代理随后于 `01:02` 从 Files 最近项目打开 `Fixed`，在系统 Preview 确認三页可读、第 2 页绿色高亮与第 3 页中文备注可见，没有编辑外部文件。

此证据关闭本次 iOS 原生导出损坏 xref 与丢失 `/NM` 的具体缺陷。重复导出、重新导入后批注更新/删除及大文件结构已有 SDK 回归；主代理正在继续独立原生回导旅程，后续证据另记。

## 01:03—01:08 原生回导与再次导出

主代理将 `Fixed.pdf` 通过系统选择器回导到“论文资料”，生成独立文档 `d77981c1-bbd3-4c84-9b91-d3ea1f77d954`、独立 blob `0635a405-b2ea-4ab0-8f1b-a2e080ad4dcb`。实际打开可见原件高亮与中文备注；这些批注属于不可变原件，本库新增批注 metadata 为零，不能自动转成可管理记录并重写原件。

在该回导副本再次执行“导出含批注”，系统 Files 另存 `Repeat.pdf`，应用提示导出成功、待提交归零。独立证据目录 `/private/tmp/tokenlibrary-native-pdf-final-jnq4wo4j` 保存原样 PDF、3 页 Poppler PNG、`proof.json` 和两个指定文档的只读服务端 snapshot。PDF 核验时点为 **01:06:13**；后续云端 blob 核对另带时戳，且在应用升级导致容器 UUID 更新后重新定位当前测试库，不把旧容器路径失效误报为资料丢失。

- `Repeat.pdf` **81,348 B**，SHA-256 `5e2d7a316c4a940e0ac4ca34f6ff5e96291f88e99a1575f57654de8281fdeef3`。全部 xref 对象严格读取通过，**10 个流**解码通过，3 页全部渲染无 warning，原 Alpha/Beta/Gamma 正文仍可检索。
- 恰好保留首次 `Fixed` 的两个 `/NM`，页码、类型、Contents、坐标均一致，无重复或额外批注。目视第 2 页绿色高亮、第 3 页中文与 🧪外观正确。没有再次操作系统 Preview，外部原生阅读已由首次 `Fixed` 完成。
- 回导本机原件、服务器新 blob、Files 首次 `Fixed` 与首次留存副本逐字节相同：**84,144 B**、hash `836cee8a…d7569`；回导 metadata 新增批注仍为零。取样本机与服务端均 revision **3**。
- 原文档 `afecb79c…` 的本机/服务端 blob 均与最初 **74,791 B** 合成导入原件逐字节相同，原两条 metadata 批注与先前基线一致，取样均 revision **7**。两个指定文档均无待提交操作。后续关系/回收旅程可能继续修改 metadata，本证明不把这些取样 revision 当成永久状态。

回导后“暂无批注”的空态文案会误导读者，以为原件中的批注丢失。本轮仅更正为“暂无本库新增批注”，并说明原件自带批注仍保留、列表管理本库新增高亮与备注；没有自动导入原件批注或修改保存语义。该文案已进入下述 01:05:50 新包。
