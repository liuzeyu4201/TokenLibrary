# Markdown 与本地图片、语音导入

实现日期：2026-09-26。

## API 与结果

`DocumentStore.importMarkdownFile(url:parentID:) -> MarkdownImportResult` 返回实际创建的 `document` 和需要向用户显示的 `warnings`。文件选择器可选择单个 Markdown，或先选择包含 Markdown 及附件的文件夹；后一种方式在导入完成前保持文件夹 security scope。Core 只使用当前系统授予的权限，读取失败会给出附件缺失或文件夹授权的可操作提示。

新笔记保留原始文件名、原始文件字节 SHA-256、导入时间，并归为笔记、进入收件箱。命名与目标父目录使用 `createDocument` 的原子校验：不会落到已经回收、删除或变成专题的旧界面目录，也不会覆盖现有 ID。

## 哪些资源会被带入

- 真正的 Markdown 图片节点：PNG、JPEG、GIF、WebP；扩展名与 ImageIO 识别出的 MIME 必须一致。
- 真正的 Markdown 音频链接：m4a、mp3、wav、aac；检查容器类型，并由 AVAudioFile 确认存在音频帧。
- 相同实际文件的重复引用共用一个资料库附件。附件使用新的 UUID 和 `media/` 相对路径，正文引用改为对应库内路径。
- 普通相对链接（例如 `.env`、PDF、另一篇 Markdown）不会被读取或复制。保留原链接并提示离线时可能不可用。
- HTTP/HTTPS 图片与音频不下载；原始 HTML 媒体也不自动读取。网络图片、HTML 媒体会给出相应提示。

## 语法与原文保留

使用官方 [Swift Markdown](https://github.com/swiftlang/swift-markdown) 的 GFM 语法树，固定 `swift-markdown` 与 `swift-cmark` 为 0.9.0。仅遍历实际 `Image`、`Link` 节点；代码块、行内代码、未使用引用定义不构成附件请求。支持内联、引用式、折叠引用、快捷引用、尖括号 URL、标题、转义括号、百分号编码路径，以及外链内嵌图片。

只按解析节点的 UTF-8 字节范围改写受影响的引用，其他正文按原字节保留，包括中文、emoji、数学文本、CRLF/CR/LF 和 UTF-8 BOM。引用式附件可转为等价内联形式，其原始定义不会被删除。BOM 在送入解析器前单独处理，映射首行位置时补回偏移。位置语义依据官方 [SourceLocation](https://github.com/swiftlang/swift-markdown/blob/main/Sources/Markdown/Infrastructure/SourceLocation.swift)；避免用字符串字符数处理字节列号。

`BlobSync`、便携 Markdown/ZIP 导出、跨资料库迁入复用这一解析器，防止导入成功后又在同步或导出阶段把示例代码中的 `media/missing.png` 当成必需文件。

Swift Markdown、cmark 和 GRDB 的许可及 NOTICE 随 LibraryCore 资源包分发。

## 文件与事务边界

单个图片限制为 20,000,000 字节，与服务器上传限制一致；Markdown 或音频限制为 50,000,000 字节，全部附件合计限制为 500,000,000 字节。先检查普通文件和大小，再做有上限的读取。

相对附件必须位于笔记所在文件夹或其子文件夹内。拒绝绝对路径、`..`（含百分号编码形式）、反斜线和 NUL。解析符号链接后检查实际包含关系；内部符号链接可用，指向外部的链接拒绝读取。读取时再通过目录描述符逐级 `openat` 和 `O_NOFOLLOW` 防止已解析路径被替换成符号链接。

预检阶段把确认过的附件写到库内独立临时目录。全部必需附件可读且格式正确后，才进入一次 SQLite 写事务：原子校验并创建文档、FTS、待同步操作，安装附件，并记录传输状态。文件安装或数据库写入失败会回滚记录并移除本次已经安装的附件；临时目录始终清理。源 Markdown 与源媒体不会修改。

这保证正常错误返回时不会留下“导入完整”但缺图的资料或待同步操作；进程在文件安装与数据库提交之间异常退出仍可能留下未引用的媒体文件，当前没有宣称跨文件系统与 SQLite 的崩溃原子提交。

## 跨资料库迁入的关联修复

跨库复制同样使用实际 Markdown 节点识别附件，并只改对应引用。提交文档时在写事务内读取最新同级名称，用统一的 NFC/casefold 比较和 `_n` 后缀去重，截短名称主体以保持完整扩展名及 240 字节限制。

复制 PDF 文件时，仅把原来可放置在该原文上的批注绑定到副本 blob。绑定其他版本、未知放置状态和原本待核对的批注保留旧身份并标为 `needs_review`，不会因为文件复制而重新激活。直接修改 JSON 对象的相关字段以保留未来扩展字段；源文档不变。
