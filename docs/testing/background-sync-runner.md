# iOS 后台恢复与同步生命周期

2026-09-27。范围为 F25 后台任务真正进入同步、系统取消和凭据读取等待；不把自动化调用等同于 iOS 已实际调度 BGAppRefresh。

## 发现与修复

异步 Keychain 恢复上线后，旧 `TokenLibraryApp.backgroundSync` 在 MainActor 创建 `AppModel`，随即检查 `model.client`。初始化只排入恢复 Task，没有等待；同一 MainActor 尚未让出时 client 必为空，后台任务直接返回。因此先前“注册了 BGAppRefresh”不能证明后台同步实际运行。

现由 `AppModel.synchronizeInBackground` 读取连接配置快照，明确 await 独立 `BackgroundSyncRunner`。它不构造前台 AppModel，不触发前台恢复完成后的 `requestSync`，每次后台机会只有一轮 `SyncClient.synchronize`，仍使用原有每库 FIFO gate、分页持久化、幂等操作和附件校验。

后台凭据查询通过 `LAContext.interactionNotAllowed = true` 与 `kSecUseAuthenticationContext` 禁止交互授权。依据为本机 Xcode SDK 的 `LAContext.h` 注释和 `SecItem.h` 支持的替代接口；未修改凭据可访问等级、ACL 或存储位置。前台恢复、显式登录的保存和登出删除仍保持原交互策略。这里不声称改变 macOS 旧式登录钥匙串的系统授权行为。

凭据等待默认最多 3 秒，整轮后台使用默认 25 秒的协作式预算；系统取消可提前结束，但同步 SQLite/文件哈希片段不能即时中断，25 秒不是严格墙钟截止承诺。安全服务已开始的同步调用不能被 Swift 真正终止，因此凭据读取单独持有一次性 continuation：超时/取消先结束等待，迟到结果仅被丢弃，不允许它随后开库、联网或写成功时间。若读取仍排在另一凭据操作后，其取消标记也会阻止排队操作开始。

整个同步的预算与取消会传播到 URLSession 和每库 gate；已经持久化的页、附件和待提交操作保留。缺失凭据、配置与保存会话的库不匹配、凭据拒绝、HTTP 401、网络失败、预算到期分别返回明确结果；HTTP 401 留待前台重新登录，后台不自动删除可能属于新登录的凭据。只有完整同步返回成功且调用任务仍未取消，才按实际同步库目录的作用域记录“最近成功同步”。不改变前台库选择、正文或导航。

SwiftUI `.backgroundTask(.appRefresh)` 的 async handler await 该结果后返回，再安排下次机会；无需另建脱离 handler 的同步 Task。系统负责此注册形式的任务完成生命周期，仍不承诺固定运行时间或真实设备一定调度。

## 自动化证据

`clients/Tests/BackgroundSyncTests.swift` 使用临时真实 SQLite 资料库、隔离 UserDefaults、可控制且故意不响应取消的凭据读取、真实 SyncClient + URLProtocol；不读取产品账号或现有资料。

- 延迟凭据期间零 HTTP；恢复后一次同步的两次 changes 读取，并等待超过前台 500 ms 延迟确认没有额外同步；成功时间只写目标库，另一个正在编辑的本机库选择和队列不变。
- 缺失或拒绝凭据均零 HTTP、原成功时间/队列不变；后台读取明确收到 `interactionAllowed=false`。
- 凭据超时和系统取消在晚到系统读取之前返回；晚到成功不触发 HTTP。
- 保存会话换成另一库时不创建/绑定另一库。
- HTTP 401 只请求一次，不删凭据，不清离线队列、不记成功。
- 总预算结束会取消正在等待的 HTTP；系统取消后下一刷新能取得同一 workspace gate 并成功。

01:25:28，8 项专项全部通过，0 失败/跳过，1.068 秒：`/tmp/tokenlibrary-background-sync-tests.log`。首次执行暴露的是测试夹具将旧时间设在未来、Date 经 UserDefaults Double 往返存在亚微秒精度差，已修为历史基准与 1 微秒容差；没有用放宽产品失败条件掩盖问题。

01:25:57 完整客户端套 84 项通过，0 失败/跳过，5.025 秒：`/tmp/tokenlibrary-background-full-client-tests.log`，包括此前凭据晚到登录/登出和最新 Catalog/隔离启动配置。01:25:53 临时独立 Keychain service 的 2 项测试通过，0 失败/跳过，新增非交互读取同一 item 的断言：`/tmp/tokenlibrary-background-keychain-tests.log`。没有重复声称全 Core 218 项在此次变更后重跑。

## 合并构建

01:29:01，独立产物 `/private/tmp/tokenlibrary-background-sync-build-04ezwz61` 双端构建成功，`codesign --verify --deep --strict` 均通过。118 个产品源码/资源文件构建前后 hash 一致。包同时包含本修复、隔离验证目录配置和 Catalog 显式“更多”菜单；未覆盖旧验收包，本次执行者未安装/启动 GUI。

| 平台 | `.app` 相对产物根路径 | ZIP SHA256 |
| --- | --- | --- |
| macOS | `macos/DerivedData/Build/Products/Debug/TokenLibrary.app` | `10a6e2fe132e4806e29d080fc6acb91acf1d00e587969a6e46a5002bd4d1764f` |
| iOS Simulator | `ios/DerivedData/Build/Products/Debug-iphonesimulator/TokenLibrary.app` | `1ad9418c1216882661260c5d2db6528f774733c6c2517a7b83f46bb27f6b0aba` |

`verification.json` 保存准确路径、构建/签名、二进制/归档/资源 hash。两端 bundle 为 `app.tokenlibrary.verification`，中文显示名 `TokenLibrary 验证`；iOS 模拟器内嵌 application-identifier 为 `7728J3WTW8.app.tokenlibrary.verification`。编辑器资源仍为已验证 Mermaid/IME 版本 SHA256 `5b14635a1db5bcf068e489fc003f5e4223dbc124725ee296627eb0a2c4c58ddf`。

## 尚需原生验收

真实系统调度、真实设备后台预算和节能策略未在此专项验收。可在独立合成库中保持一个待同步修改，应用进入后台后记录系统真实调度与时间戳；重新前台必须 reload 已落盘进度并继续补齐。仅“切到后台再回来”不能证明系统执行过 BGAppRefresh，更不能替代本专项的取消/迟到故障注入。
