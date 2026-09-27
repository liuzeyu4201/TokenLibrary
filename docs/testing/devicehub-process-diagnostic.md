# Xcode 27 Device Hub 进程绑定诊断

2026-09-26，宿主 macOS 27.0（26A428），Xcode 27（27A266a），Device Hub 27.0（255.2.6.6）。通过 Finder 打开原包内真实程序后，Computer Use 已恢复对 Device Hub 的绑定，并能读取 iOS 26.5 模拟器 SpringBoard 的完整按钮树。本文记录故障证据与本机验证过的恢复步骤，不证明 TokenLibrary 的 iOS 交互已通过。

## 实际证据

Root 在活动监视器正常退出旧 DeviceHub PID 48637，确认进程消失后，再通过官方应用路径调用 Computer Use。调用仍在约 5 秒后超时；新进程是 PID 67817。此次分析只读取进程、LaunchServices 信息、包内容、限定该进程的系统日志，并采样 1 秒，没有自行操作 GUI、结束进程或修改系统设置。

正确应用位置为 `/Applications/Xcode.app/Contents/Applications/DeviceHub.app`，Bundle ID 为 `com.apple.dt.Devices`。外层 `CFBundleExecutable` 是 `DevicesTrampoline`，实际运行文件是同包 `Contents/MacOS/DeviceHub`；两者均为 Apple 签名。扫描 Xcode 包未找到第二个 Simulator/Device Hub 前端应用，嵌套的 `DevicesSystemUpdater.app` 是更新辅助程序。

| 观察 | 结果 |
| --- | --- |
| `ps` | 真实 DeviceHub PID 67817 存在 |
| `lsappinfo info` | 正确 ASN、Bundle ID、路径及 audit token 中 PID；摘要不显示普通 `pid =` 和 check-in 时间 |
| `NSWorkspace.shared.runningApplications` | 此应用 `processIdentifier = -1`、`isFinishedLaunching = true`、`isTerminated = false` |
| `NSRunningApplication(processIdentifier: 67817)` | 能返回此 Bundle 的对象，但对象的 `processIdentifier` 仍为 `-1` |
| 对照 Xcode | 返回真实 PID 52577，`isFinishedLaunching = true` |
| 1 秒主线程采样 | 788/788 样本在 AppKit/CFRunLoop 正常等待下一事件，没有观察到互斥锁、信号量或初始化死锁 |

**更正早先推断：缺少 `lsappinfo` 摘要字段不能证明 Device Hub 没有完成 check-in。** 系统日志显示以下完整启动过程：

1. `23:19:40.801`：LaunchServices 发现同 PID 的 audit token 版本从 `336647` 变为 `336648`，明确记录 `probably re-execed`，随后替换进程信息。
2. `23:19:40.802`：记录 `CHECKIN`。
3. `23:19:40.878`：记录 `SignalApplicationReady`。
4. `23:19:41.164`：SwiftUI 窗口被放到前面，但应用并非 active。
5. `23:19:41.194`：`DevicesAppDelegate: applicationDidFinishLaunching called`。

因此，已定位的具体异常是：真实进程已启动，AppKit 的应用对象却不能提供有效 PID。Apple 文档说明 [`processIdentifier == -1` 表示应用没有可提供的 PID](https://developer.apple.com/documentation/appkit/nsrunningapplication/processidentifier)。若 Computer Use 使用此属性建立 AX 连接，就会得到无效进程号；这一因果链仍属基于证据的推断，因为本次没有读取或修改 Computer Use 实现。

采样文件：`/private/tmp/tokenlibrary-devicehub-67817.sample.txt`。原始系统日志仅保留在临时目录，不将其全量内容复制进仓库。

## 已验证的 GUI 恢复步骤

Root 于 `23:27` 使用 Computer Use 执行以下界面操作，没有修改 Apple 应用、重签名或改变系统设置：

1. 在活动监视器中确认旧 Device Hub 为 PID `67817`，使用正常“退出”，不是强制结束；确认该旧进程消失。
2. 切换到 Finder，按 **Command–Shift–G** 打开“前往文件夹”，输入完整路径 `/Applications/Xcode.app/Contents/Applications/DeviceHub.app/Contents/MacOS/DeviceHub`，按 Return 定位到包内真实程序。
3. 在 Finder 中对已选中的 `DeviceHub` 按 **Command–O** 打开。这里没有调用终端命令启动 GUI，也没有把裸二进制路径传给 `getApp`。
4. 再通过已记录的 API `cua.getApp("com.apple.dt.Devices")` 绑定。此次成功返回 Device Hub 的 AX 管理窗口，显示 **iPhone 17 Pro / iOS 26.5** 和 **Start** 按钮。
5. Root 继续在 Device Hub 点击 **Start**，等待设备画面出现，再通过 Computer Use 点击 **Home**（`app.grid.3x3`）。后续 AX 读取成功返回 iOS 26.5 SpringBoard 的完整按钮，包括地图、日历、照片、设置等，确认实际设备内容可透传，并非只有宿主管理窗口。

随后只读核验得到一致结果：

| 核验 | 恢复后的结果 |
| --- | --- |
| `ps` | 真实 DeviceHub PID `68907` |
| `NSRunningApplication.runningApplications(withBundleIdentifier:)` | `processIdentifier = 68907`、`isFinishedLaunching = true` |
| `NSRunningApplication(processIdentifier: 68907)` | 对象仍返回正确 PID `68907` 与 `com.apple.dt.Devices` |
| `lsappinfo info` | 出现正常 `pid = 68907` 与 `checkin time = 2026/09/26 23:27:49` |

这证明在当前机器与版本中，绕过启动器后 PID 登记恢复，Computer Use 可以绑定宿主并读取 iOS 26.5 设备内容。TokenLibrary 的登录/同步/阅读/编辑等 iOS 用户旅程由 Root 继续验收；SpringBoard 可操作不能代替这些结果。PID 和 ASN 每次启动会变化，复验时应确认当次真实进程，不能机械复用这里的编号。该包内入口不是 Apple 文档保证的稳定接口；后续 Xcode 更新仍需重新验证。

## 启动器机制与未执行的副本方案

包内 `DevicesTrampoline` 的 `_reexec_as_devices_app` 先把目标改为同目录 `DeviceHub`，再固定调用 `posix_spawnattr_setflags(..., 0x40)` 与 `posix_spawnp`。当前 SDK 的 `sys/spawn.h` 将 `0x0040` 定义为 `POSIX_SPAWN_SETEXEC`。检查其完整 `main`、导入符号及字符串，没有发现用于关闭此行为的命令行参数或环境变量；其参数和环境原样传给真实程序。Apple 公布的入口仍是 Xcode 的 Manage Devices 和 Open Developer Tool 菜单，没有查到官方的跳过启动器选项。

上述已执行的 Finder 路径保留原二进制 Apple 签名及框架目录，绕过了这一 re-exec 路径。它在本机成功，不能推断在其他系统与 Xcode 版本中必然有效。

不建议把“复制 app 到 `/tmp`，修改 `CFBundleExecutable`”当作首选修复，具体原因如下：

- **签名布局会变化。** 原应用由 `DevicesTrampoline` 的应用签名封装，`DeviceHub` 是封装中的独立签名 Mach-O。改 Info.plist 并把嵌套程序提升为主程序后，不能假定整个 app 的资源封装、Info.plist 校验和签名仍有效。需要额外验证，不能简单重签来掩盖问题。
- **临时重签不能保留 Apple 的运行身份。** 真实程序带有 library validation、App Sandbox、`com.apple.private.coredevice.client`、私有 HID/TCC 权限及专用 keychain access group。普通或 ad hoc 签名不能授予同样的 Apple 私有能力，可能导致框架加载、设备连接或输入权限失败。没有读取任何钥匙串内容。
- **平面复制会破坏框架定位。** `DeviceKit` 通过 `@rpath` 加载，真实程序包含 `@loader_path/../../../../SharedFrameworks`、`Frameworks`、`InternalFrameworks` 等相对路径。原位置解析为 Xcode 的 `Contents/`，平面 `/tmp/DeviceHub.app` 会解析到另一位置；仅改入口不足以让程序加载。人为拼接仿 Xcode 目录或加入链接又增加封装和资源查找变量。
- **副本不等于独立环境。** 保持同一 Bundle ID 可能共用偏好设置、沙盒容器及设备服务；改 Bundle ID 又与原签名、私有权限身份不一致。删除临时副本也不能据此保证所有运行副作用都已撤销。

当前暴露的 `getApp(name/path/bundle)` 不接受 PID；本次没有尝试未记录的 PID API，也没有执行 `/tmp` 复制或修改入口方案。长期修复仍应检查系统/自动化工具对 re-exec 后进程身份的处理，而不是修改 TokenLibrary 的客户端代码。

**更正版本限制判断：**Apple 工程师在 Accessibility Inspector 的问题回答中要求宿主和目标设备运行 OS 27，并使用 Xcode 27 的 Accessibility Inspector；该回答不能直接套用为本环境 Computer Use 的阻塞条件。实际观察已证实 iOS 26.5 模拟器的 SpringBoard 完整 AX 按钮可以读取，故本轮不再把升级至 iOS 27 列为继续验收的前置条件。[Apple 工程师原回答](https://developer.apple.com/forums/thread/831704)

## 恢复设备操作后发现的验证包签名问题

Root 随后的 iOS 首次登录验收已能操作 TokenLibrary：连接检查成功，错误密码保留表单并提供“重试登录”，但正确密码在保存安全会话时失败。模拟器 `securityd` 明确返回 `-34018`，因为用 `CODE_SIGNING_ALLOWED=NO` 构建的包缺少 `application-identifier` 和 `keychain-access-groups`，这是验证包身份缺失，不是 Device Hub 再次失效或设备需要解锁。

已用独立 DerivedData、`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=` 生成 ad hoc 签名的 `app.tokenlibrary.verification` 包；签名前通过临时 Info.plist 保留“TokenLibrary 验证”显示名。签名与资源校验通过，arm64 模拟器权限节中已包含正确应用身份。构建方法、产物路径和验证边界见 [iOS 模拟器签名说明](ios-simulator-signing.md)。该包于 `23:33:09` 编译时仍可能包含 StickyNoteEditor 并行开发片段，是登录修复验证包，不能当作便签全部修复冻结后的最终产物。Root 随后实际安装并通过 GUI 登录成功，进入“正在同步资料与附件…”，确认 Keychain 阻塞已解除；完整同步及其他 iOS 旅程继续单独验收。

`23:42:16` 已补上包含随后冻结修复与最新权限说明的签名构建，43 个所查源文件在构建前后保持一致，签名校验通过，最新路径见上述签名文档。首轮 iOS 下载的 625 份资料、21 个附件及来源关系只读核验另见 [iOS 首轮同步证明](ios-first-sync-proof.md)。
