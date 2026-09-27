# Markdown 导入回归

测试文件：`clients/LibraryCore/Tests/LibraryCoreTests/MarkdownImportTests.swift`。全部使用随机临时目录、测试生成的 PNG/WAV 与合成内容，不读取真实配置或用户资料。

## 覆盖范围

1. 图片与语音实际字节复制、收件箱/笔记分类、原始文件名/hash、附件清单与同步操作一并落库。
2. 引用式、折叠、快捷、尖括号、标题、转义、编码路径、重复附件只复制一次。
3. 代码围栏、缩进代码、行内代码、未使用定义不读附件；普通 `.env`、PDF、MD 链接不读文件，保留并提示。
4. 外链内嵌图片与中文、CRLF；只改附件节点。
5. 网络 URL 不请求，HTML 媒体保留并提示。
6. 缺附件、伪图片、未知图片类型、损坏语音失败后无文档、队列、传输记录或已安装媒体。
7. `..`、编码遍历、绝对路径、file URL、逃逸符号链接拒绝；内部符号链接与编码空格可用。
8. 非 UTF-8、无文件访问权限有明确错误；超过 50 MB 的源文件/附件在读完整内容前拒绝，图片另外验证服务器一致的 20 MB 上限。
9. 人为注入附件记录数据库错误，确认文档、FTS/队列及已安装附件一起回滚。
10. 跨库复制和 ZIP 导出不依赖代码样例中的假附件。
11. BOM、多字节 emoji、数学文本，以及 CR 换行与制表符定位保持正文原字节。
12. 音频容器与扩展名不符（WAV 冒充 MP3）拒绝。
13. 独立 localhost HTTP 服务上实际上传/下载 PNG 与 WAV，两端附件字节一致，代码及普通链接不改写，队列清空，ZIP 导出成功。

## 运行

在 `clients/LibraryCore` 运行：

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/tokenlibrary-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/tokenlibrary-module-cache \
swift test --disable-sandbox --skip-update \
  --cache-path /private/tmp/tokenlibrary-spm-cache \
  --filter MarkdownImportTests
```

真实 HTTP 项需要专门隔离的 localhost 服务，设置 `TEST_TOKENLIBRARY_URL`、`TEST_TOKENLIBRARY_USER`、`TEST_TOKENLIBRARY_PASSWORD`；没有环境变量时跳过。全套运行与结果见 [客户端同步验证](client-sync.md)。不要对生产资料库运行测试。

本轮开发回归实际找到并修复 Foundation UTF-8 解码吞掉 BOM，以及直接把 BOM 交给 cmark 后首行范围不一致的问题。测试要求只有附件引用能被改写，正文前缀、后缀及数学内容必须保留，避免“能显示图片但原文被破坏”的假通过。

## 跨资料库补充回归

`WorkspaceTransferTests` 共 6 项。新增验证 240 字节中文名称碰撞、`Straße`/`STRASSE` casefold 去重及连续 `_n` 后缀；PDF 拷贝分别覆盖已知/未知原 blob、匹配批注、旧版批注、未绑定旧数据、`needs_review`、未知 placement 状态和未知 JSON 字段。只有对原文件有效的批注可在新副本上放置，源 JSON 完全保留。

## 分轮自动结果

2026-09-26 19:12:23（Asia/Shanghai）的完整Core回归179项、0失败/跳过，包含本文件的17项Markdown导入测试与6项WorkspaceTransferTests；当轮真实HTTP图片/语音双端上传下载1.210秒，服务为51525。此为历史结果，通用日志路径会被后续运行更新。最新23:59:14完整Core204项、0失败/跳过（跨度18.439秒），同一图片/语音HTTP用例2.164秒；固定日志 `/private/tmp/tokenlibrary-client-full-tests-20260926-235914.log`，见[客户端同步验证](client-sync.md)。

这些结果覆盖Core API、实际附件字节和同步接口；系统选择器授权、媒体显示、播放及原生导出交互按实际UI片段另计。

## iOS目录授权导入（2026-09-27 00:04—00:07）

主验收通过“含附件Markdown”授权Files中刚解包的导出目录，应用列出两个Markdown文件；选择正文后导入新副本并实际显示图片，同时明确提醒普通相对链接未带入（来源说明）。[独立三方证明](ios-export-reimport-proof.md)已确认原笔记仍revision23、新副本dc40为revision3，副本正文仅重写图片路径，三方正文/metadata/assets一致；六处实际PNG字节hash相同，归档/继续编辑不改变副本正文。此段只关闭目录授权、文件选择与图片可见的路径，不能替代单文件“Markdown或PDF文件”入口；后者随后实际发现呈现断路，已修改单fileImporter，00:14完整56项模型通过；00:16双端构建、strict/deep签名与52源码/资源hash核验通过（`/private/tmp/tokenlibrary-import-picker-build-s2z888ay/verification.json`），00:19更新包的iOS单文件选择器实际呈现/取消/重开与合法PDF导入已通过，见[PDF导入记录](pdf-import.md)；此项不扩大为所有Markdown单文件附件与授权失败分支通过。
