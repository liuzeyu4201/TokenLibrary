# 客户端验证记录

日期：2026-09-26。环境：macOS arm64，Xcode 27.0（27A266a），Swift 6 项目模式；最低目标 iOS 17/macOS 14。

## 已执行

| 检查 | 结果 | 覆盖与限制 |
| --- | --- | --- |
| LibraryCore 全量测试（最终） | **54/54 通过，0 失败** | 原有 24 项、连接 12 项、队列 17 项、EditorScript 1 项；包括创建期间移动和未知远端合并暂停 |
| macOS Debug 构建 | BUILD SUCCEEDED | arm64/x86_64 首轮、arm64 后续增量；CODE_SIGNING_ALLOWED=NO，不代表安装/运行验收 |
| iOS Simulator Debug 构建 | BUILD SUCCEEDED | generic simulator arm64/x86_64 编译；未启动模拟器或安装真机 |
| 编辑器 fixture | `editor fixture ok` | `node editor/test-fixture.mjs`，仅基本源码/渲染标记，不代表完整 Mermaid/LaTeX |
| 文档链接 | 本地相对链接检查通过 | 相对本地链接存在，历史文档中的外部网址未批量抓取 |

## 可复现命令

在项目根目录：

```sh
swift test --package-path clients/LibraryCore
node editor/test-fixture.mjs

xcodebuild -project clients/TokenLibrary.xcodeproj \
  -scheme TokenLibrary-macOS -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/tokenlibrary-xcode-check \
  -clonedSourcePackagesDirPath /tmp/tokenlibrary-xcode-packages \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project clients/TokenLibrary.xcodeproj \
  -scheme TokenLibrary-iOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/tokenlibrary-ios-check \
  -clonedSourcePackagesDirPath /tmp/tokenlibrary-xcode-packages \
  CODE_SIGNING_ALLOWED=NO build
```

测试需要编译缓存写入权限；原有两项 Python HTTP 集成测试还需允许本机监听端口。初次沙箱运行的 cache/localhost 失败不算产品逻辑失败；获准扩大工具沙箱后全量测试通过。项目依赖未主动升级。

## 新增回归范围

- 地址规范化和错误输入；健康状态维护标识；非法登录响应；错误分类。
- 503/429 与 Retry-After、有界重试、401 不重试、取消传播、固定 timeout 与相同 operationId/body。
- SQLite v1→v2 数据保留、请求冻结后编辑、重启/断网/取消后原字节重试、旧回执不覆盖新编辑或降低 revision。
- 冲突阻断后续同对象操作、不同 root 隔离与祖先循环保护。
- Markdown 特殊字符通过 JSON 完整传入 WebView。
- 创建在途后的移动/改名，以及未知远端版本后的安全暂停，以上均已包含在最终 54 项中。

## UI 验证尝试与环境限制

使用 Cua Driver 的后台 launch_app 尝试启动独立标识 `app.tokenlibrary.verification` 的临时构建，并指定 `/tmp/tokenlibrary-ui-smoke-20260926` 作为隔离资料目录。工具返回 `APP_NOT_INSTALLED`；即使构建已登记 LaunchServices，仍未成功识别。没有转而启动用户已安装的应用，没有录屏或读取其个人文档。

因此连接页实际点击、错误显示布局、离线导航、系统保存面板、导出外部打开等 **UI 验收尚未执行**。代码审阅和编译不能代替这些结果。

Xcode 另报告：CoreSimulator 已运行版本 1051.55.0 低于本次工具链要求 1171.7.0，以及 CoreDevice 插件符号缺失。generic simulator 编译成功不代表模拟器运行可用；本轮未修改/更新系统工具链。

## 日志

本机临时证据（可能被系统清理）：

- `/tmp/tokenlibrary-baseline/macos-build.log`
- `/tmp/tokenlibrary-baseline/ios-build.log`
- `/tmp/tokenlibrary-baseline/macos-smoke-build.log`
- `/tmp/tokenlibrary-baseline/cua-mcp.log`

正式端到端验收仍须在真实 iPhone/Mac 与测试专用服务完成[验收矩阵](acceptance-matrix.md)，包括首次下载、附件同步、断网恢复、冲突解决和备份恢复。现有测试通过不得写成“三端同步已完成”。

## 最终测试命令与结果

在 `clients/LibraryCore` 执行：

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/tokenlibrary-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/tokenlibrary-module-cache \
swift test --disable-sandbox --skip-update \
  --cache-path /private/tmp/tokenlibrary-spm-cache
```

最后结果：`Executed 54 tests, with 0 failures`。日志：`/private/tmp/tokenlibrary-core-final-tests.log`。`--disable-sandbox` 仅影响 SwiftPM 构建执行环境，用于当前受限测试工具运行，不是关闭应用安全功能。

最终增量构建日志另存：`/tmp/tokenlibrary-baseline/macos-final.log`、`/tmp/tokenlibrary-baseline/ios-final.log`。
