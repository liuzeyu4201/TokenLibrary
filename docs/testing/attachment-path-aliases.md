# 附件路径别名与首次写入

2026-09-27，生成全新合成资料库时确认合法附件首写失败：根目录传入 `/private/tmp/<新目录>`，Foundation 在目录创建后将已有根规范为 `/tmp/<新目录>`，尚不存在的 `media/<文件>` 则仍保留 `/private/tmp/...`。旧 `resolveAttachment` 对两种字符串做前缀比较，误报 `invalidPath`，首次图片导入就失败。该问题与附件内容或凭据无关。

## 复现与修改

仅使用 XCTest 自建 UUID 临时目录；不读取或修改任何已有用户资料库、原生验收库或已封存应用。新增 `AttachmentPathTests.swift` 后先运行旧实现：7 项中 4 项失败，分别为首次导入、两种绝对别名首写、库内符号链接首写、缺失多层目录首写；日志 `/tmp/tokenlibrary-attachment-alias-before.log`（02:23:03）。越界、悬空链接及根目录拒绝原本通过。

产品修改仅在 `clients/LibraryCore/Sources/LibraryCore/AttachmentStore.swift`：

- 根与目标路径使用相同方法。先以 `realpath` 解析最近的已存在祖先，再把尚未创建的路径组件追加到统一的 Foundation URL；不再次规范化整条不存在的路径。
- 上溯只允许 `ENOENT`；`lstat` 已存在但无法解析的链接、权限错误、链接循环和非目录祖先仍然拒绝。外部链接解析后仍须通过当前库的带 `/` 边界前缀检查。
- `registerAttachment` 也使用同一规范根计算相对路径，避免资料库根自身为符号链接时截错目录。

`DocumentStore.root`、数据库工作区 identity、blob ID、附件字节、文档修订和队列语义均未改。正常首次保存允许 media 及多层子目录尚不存在；库内符号链接允许，越界及悬空符号链接不允许。

## 验证结果

02:24:29，新增路径专项 **8 项通过、0 失败、0 跳过**，包含两种 `/tmp` 别名、保存前后路径一致、重新打开、根目录符号链接的相对登记、库内链接、越界/悬空链接，以及 `..`、同前缀兄弟目录和库根拒绝。Core 与 tltool 编译成功。日志：`/tmp/tokenlibrary-attachment-alias-after.log`。

02:24:59，联合路径恢复、Markdown 导入、Markdown ZIP 导出、工作区迁入及编辑草稿恢复：共 60 项，**59 通过、0 失败、1 跳过**（1.441 秒）。跳过项仅 `testRealHTTPImportedImageAndAudioRoundTripWithoutCodeOrPrivateLinkReads`，因为本次没有配置隔离 HTTP 服务；没有把它记录为通过。日志：`/tmp/tokenlibrary-attachment-alias-related-tests.log`。

独立只读复核未发现新的确定路径错误。此轮未重跑完整 Core/Model/Browser，也未重建或替换运行中的 macOS/iOS 原生验收包；当前封包证据继续指向修复前的不可变产物，后续需要新包时由主任务统一安排。

## 02:27 指定 HTTP 补测

按 [客户端同步验证](client-sync.md) 的环境变量和 SwiftPM 命令，仅补跑此前跳过的 `MarkdownImportTests.testRealHTTPImportedImageAndAudioRoundTripWithoutCodeOrPrivateLinkReads`。运行前只读核对已有安全启动脚本 `/private/tmp/tokenlibrary-e2e-server.py` 的合成配置，使用既有 `http://127.0.0.1:56881`；ready 为 200、`maintenance=false`。未读取 `.env`，未创建新服务或操作 53056 原生验收库。

02:27:02.596，**1 项通过、0 失败、0 跳过**，用例 1.006 秒；日志 `/private/tmp/tokenlibrary-attachment-alias-http-test.log`。实际导入图片/音频、上传、第二端下载、逐字节比对、可移植 ZIP 导出以及源码代码块/普通配置链接不读取检查均执行。结合 02:24 的结果，本次相关 60 项均取得通过证据；这不是一次完整 Core 套件重跑。

主任务随后明确要求生成下一轮独立双端验收包。构建于 02:27 开始，与进行中的 iOS 千项性能采样同机重叠；该采样不能据此宣称没有后台编译负载。旧原生包和千项测试 bundle 保持不动。

## 02:28 最新独立验收包

`/private/tmp/tokenlibrary-attachment-paths-build-1wl4gsv9` 双端构建成功，126 个产品源码文件构建前后哈希无漂移；严格签名验证通过，资源仍为已完成排版回归的 `313efa95337dc344a766f81e4e11d84ed12ced20372c97a58beb7ec9db7ea921`。

- Mac：`TokenLibraryAttachmentPathsVerification.app`，bundle `app.tokenlibrary.verification.attachmentpaths`，显示“TokenLibrary 附件验收”，新空绝对目录 `/private/tmp/TokenLibrary-AttachmentPaths-20260927-5n35ttq3`。仅复制构建包、更新 Info、ad hoc 重签；没有复制会话和资料、没有启动。
- iOS：`ios/DerivedData/Build/Products/Debug-iphonesimulator/TokenLibrary.app`，原 `app.tokenlibrary.verification`，Simulator application identifier 和局域网用途说明核对通过。没有安装或启动，没有修改独立千项性能 bundle。

| 产物 | SHA-256 |
| --- | --- |
| Mac 主可执行文件 | `9efc173f211469bd9951aa501d09112286ec1671ede14c7e445d9446922434bc` |
| Mac 实际 Debug dylib | `b7f9e1b37ed593552268080e6acefc1297e3d4e9118c07d5d2a9bc60832eae96` |
| Mac zip | `7560ac0e17431be4a46861790e961e35da8b67a129333a36af17442d5c6a0744` |
| iOS 主可执行文件 | `fd6007edce66b561979cdb12c3b1bee4961026b697c5f11893dc3d2547890b2a` |
| iOS zip | `16d3f9337be31e6b7c408667461dc712695b87af35165e1585cd528b29cc4627` |

完整证明位于该目录 `verification.json`、`attachmentpaths-verification.json` 及双端构建、签名日志。包构建成功不代替后续原生使用验证。
