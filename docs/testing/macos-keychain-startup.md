# Mac 钥匙串等待造成启动界面阻塞

## 2026-09-27 的实际诊断

`00:18` 将单 importer 修复包覆盖到隔离验证路径后，CUA 两次绑定超时。只读检查确认应用实际上已经运行：PID `77314`，启动时间 `00:18:25`；`NSRunningApplication` 的 `isFinishedLaunching=true`，没有对应 TokenLibrary 崩溃报告。

包内可执行文件与构建源产物 hash 一致，`codesign --verify --deep --strict` 通过。entitlements 只有 `get-task-allow`，没有 app sandbox。不能据 CUA 超时判定签名阻止启动或容器路径迁移死锁。

`00:21:10` 进行 1 秒只读采样，主线程 887/887 个样本停在：

```text
AppModel.init
  SessionVault.load(server:)
    SecItemCopyMatching
      SecurityServer decrypt → mach_msg 等待
```

系统日志进一步明确了原因：`00:18:26`，securityd 为该 PID 显示钥匙串授权提示。原条目 ACL 绑定的旧 `cdhash` 是 `9ebeddc4f36c7180b4ce11a3375ce05c4ad7faed`；新手动 ad hoc 签名包是 `6a6ed948be3ba313241bf5bd0359c63da6615b57`，不再满足旧授权。SecurityAgent 当时 PID `77328` 存在。

证据文件：`/private/tmp/tokenlibrary-mac-startup-sample-77314.txt`、`/private/tmp/tokenlibrary-mac-keychain-startup.log`。检查没有读取凭据值、清理钥匙串或修改 ACL。Root 对 SecurityAgent 的 CUA 操作被自动安全审核拒绝后，没有改用其他入口绕过；`00:26:59` 只通过 Activity Monitor 结束已确认挂起的验证应用。其他应用、模拟器与服务保留。

## 为什么恢复旧构建选项不等于恢复身份

另用原 `CODE_SIGNING_ALLOWED=NO` 构建方式生成了候选：

`/private/tmp/tokenlibrary-macos-legacy-signature-945zi_z4/DerivedData/Build/Products/Debug/TokenLibrary.app`

该包构建成功，但 linker-signed `cdhash` 是 `6b5035cee4298650a8114fec881c82c4de2d3aa3`，仍与原 ACL 不同。没有启动该候选，也没有把它当成无需授权的修复方案。相同 Bundle ID 或构建选项不能替代实际签名身份核验。

## 产品修复

安全凭据仍保存在 Keychain，使用原服务名与查询范围。新增 `SessionCredentialStore` 异步接口和默认 `AsyncSessionVault`，在专用串行队列执行读取、保存、删除。同一 service 的队列在进程内跨实例共享，Mac 多个窗口也不会将条件读取/删除与另一个窗口的保存交错。等待调用不会占据主线程；取消会跳过尚未开始的请求，已进入系统 API 的调用不能被应用强行中止。

AppModel 先打开已选择的离线库并显示资料，再进行一次安全会话恢复。恢复期间可编辑、切换选择或停止等待；返回结果校验请求 ID、原 store 身份与服务器地址。迟到结果不能把用户拉回旧库，也不清空等待期间产生的队列和选中项。

显式登录只有在安全保存成功后才绑定新会话；保存等待有可见状态和停止按钮。停止后系统保存仍可能完成，因此清理仅针对那次被取消的 token，不能删除随后登录的新 token。退出立即停止本机同步，后台条件删除对应 token；迟到的退出结果不能覆盖新会话或界面状态。保存、删除失败会明确显示，不能把失败当作成功。

没有使用全局 `SecKeychainSetUserInteractionAllowed`，没有迁移到其他凭据存储或跳过系统访问控制。Apple 的 `SecItemCopyMatching` 文档明确说明此调用会阻塞调用线程，不能放在主线程；现有旧式 macOS Keychain 条目与 Data Protection Keychain 也不能简单混用。[Apple API 文档](https://developer.apple.com/documentation/security/secitemcopymatching(_:_:))、[Apple Keychain 实现说明](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)

本机 SDK 的 `SecItem.h` 注明旧 no-authentication-UI 选项不能保证抑制 legacy Keychain 提示；`kSecUseAuthenticationUIFail` 已建议改用 `LAContext.interactionNotAllowed`。因此不能只加一个参数就声称本例旧 ACL 一定立即失败。此修复保证离线 UI 不被堵住、等待可退出和结果不会串入新会话，不宣称能取消系统中的授权流程。

## 回归

新增 `CredentialLifecycleTests` 于 `00:30:40` 执行 6 项、0 失败，采用可控制完成时机的合成凭据接口和隔离 HTTP 响应：

1. 延迟恢复期间本机可编辑，完成后保留当前目录、选择与待提交正文。
2. 切库后晚到的恢复不会替换当前库/新会话。
3. 恢复失败可见，保留队列且不自动重复访问凭据。
4. 安全保存失败不能宣称登录成功或切库。
5. 取消保存后晚到的完成不能覆盖新登录或删除新 token。
6. 旧退出晚到不能删除、覆盖后来登录的会话。

日志为 `/private/tmp/tokenlibrary-credential-lifecycle-tests.log`。另一个实现代理只读复核竞态边界后，补充了跨窗口共享队列，以及已收到登录响应但请求已取消时撤销那次未绑定的服务器会话。

完整客户端模型回归于 `00:33:13` 执行 **62 项、0 失败、0 跳过**，日志 `/private/tmp/tokenlibrary-credential-all-model-tests.log`。自动测试不能代替新包遇到真实系统授权等待时的 GUI 复验。

新增真实 Keychain 专项使用唯一临时测试 service，不访问验证应用或用户凭据。`SessionVaultTests` 于 `00:34:45` 执行 **2 项、0 失败、0 跳过**，其中新增跨两个 `AsyncSessionVault` 实例的旧 token 条件删除回归：保存新 token 后，旧退出不能删除新 token。日志 `/private/tmp/tokenlibrary-async-vault-keychain-tests.log`。这里是 Core 专项；没有据此声称新增后完整 Core 套已重跑。

## 本次验证包

双端 Debug 包均构建成功，`00:37:00` 核对 111 个产品源码/资源 hash 与构建前完全一致，两个包的 `codesign --verify --deep --strict` 均通过。Bundle ID 为 `app.tokenlibrary.verification`，显示名为 `TokenLibrary 验证`。iOS simulator 内嵌 `application-identifier` 为 `7728J3WTW8.app.tokenlibrary.verification`。

- Mac：`/private/tmp/tokenlibrary-credential-recovery-build-4rfmv37z/macos/DerivedData/Build/Products/Debug/TokenLibrary.app`。归档 SHA-256：`fbc663a93c1935187d5027afac784edc0badff61f6cc437a0c0b1c4240555bf6`。
- iOS：`/private/tmp/tokenlibrary-credential-recovery-build-4rfmv37z/ios/DerivedData/Build/Products/Debug-iphonesimulator/TokenLibrary.app`。归档 SHA-256：`472c96ecc9951c7d2374593cb47476ea966a87a9370dae167a3fc68da146c8fb`。

两个包的编辑器资源均为 `5b14635a1db5bcf068e489fc003f5e4223dbc124725ee296627eb0a2c4c58ddf`，包含 IME 与 rich Mermaid 修复。构建日志、签名日志和 `verification.json` 位于该构建目录。此轮没有安装或启动应用，也没有操作系统授权界面；原生验证由主代理继续。此 Mac 签名仍可能需要旧 Keychain ACL 的系统授权，不能把签名验证通过解释为已取得该授权。

## 新包原生复验

主代理于 `00:38` 安装本轮新 Mac 包后实际启动：应用立即显示已选择的离线库以及恢复会话/停止等待提示；打开原阅读笔记时，正文、图片和三条来源均正常。等待期间新建 `未命名_1.md`，输入真实正文并得到“已保存到本机”、待提交 1 条。点击“停止等待”即时更新提示，正文和队列保留，最近成功同步仍显示旧的 `00:18`，没有虚报新的成功同步。该验证没有操作 SecurityAgent、输入钥匙串密码或改变访问控制。正常退出后重启持久性及后续新包验证由主代理继续记录。
