# iOS 模拟器验证包签名与 Keychain

## 已确认的故障

2026-09-26，iPhone 17 Pro / iOS 26.5 模拟器中，验证版连接探测成功、错误密码提示正确，但输入正确密码后显示无法访问安全登录信息。该包用 `CODE_SIGNING_ALLOWED=NO` 构建。

限定 `TokenLibrary` / `securityd` 的模拟器日志于 `23:30:34.039` 记录 `SecItemUpdate` 返回 `NSOSStatusErrorDomain Code=-34018`，具体原因为：

> Client has neither application-identifier nor keychain-access-groups entitlements

原包检查结果是链接器生成的最低限度 ad hoc 签名：`Identifier=TokenLibrary`、`Info.plist=not bound`、没有应用身份 entitlements 和资源封装。因此本次失败是验证产物缺少 Keychain 身份权限，不能当成密码错误、设备锁定或服务器故障。未修改 `SessionVault`，未将凭据改存 UserDefaults，也未读取、清空或迁移钥匙串内容。

## 最新源码签名构建（23:42 核验）

后续又生成[容器迁移、IME 与便签标识合并修复包](ios-container-relocation.md)，用于同库覆盖安装后检查 PDF 路径恢复。`23:52:04` 的中间包未安装，等待 IME 冻结后于 `23:55:06` 完成合并包核验；严格签名、中文显示名、模拟器应用身份、内嵌编辑器及构建源码/资源 hash 均通过检查。完整包 hash 见链接文档。

当前交给 Root 安装复验的包为：

`/private/tmp/tokenlibrary-ios-final-signed-7j1ht8v_/DerivedData/Build/Products/Debug-iphonesimulator/TokenLibrary.app`

- `build.log`：同目录上方的 `/private/tmp/tokenlibrary-ios-final-signed-7j1ht8v_/build.log`，`BUILD SUCCEEDED`。
- `verification.json`：`23:42:16` 的签名、Info.plist 与模拟器身份核验结果。
- `source-hashes.json`：43 个 Core / Shared / iOS Swift 与源 Info.plist 的构建前 hash；构建后全部一致，没有编译期间混入新的源码修改。
- `codesign --verify --deep --strict --verbose=2` 通过；包含 arm64 和 x86_64。
- Bundle ID 与显示名正确；已签名 Info.plist 包含最新局域网、麦克风、相册用途说明；arm64 的模拟器权限节仍为 `7728J3WTW8.app.tokenlibrary.verification`。

此包包含照片请求归属隔离、失败草稿回显保护、便签空白与录音生命周期修复、PDF 初次布局定位修复、可搜索资料/笔记选择、回前台刷新和后台成功时间记录。构建前已等待这些并行源文件修改完成；最终是否通过相应原生旅程仍由 Root 实际安装后的记录确认，不能仅由编译结果推断。本任务没有安装或启动该包。

## 首次登录修复包（23:33）

独立目录：`/private/tmp/tokenlibrary-ios-signed-6f4qbgkc`。

- 安装候选：`DerivedData/Build/Products/Debug-iphonesimulator/TokenLibrary.app`
- 完整构建日志：`build.log`
- 签名前使用的临时 Info.plist：`Verification-Info.plist`
- Bundle ID：`app.tokenlibrary.verification`
- 显示名称：`TokenLibrary 验证`

`23:33:09` 构建成功（arm64 与 x86_64），`codesign --verify --deep --strict --verbose=2` 成功。签名使用本机 ad hoc “Sign to Run Locally”，Info.plist 和资源已封装；没有请求开发者证书、下载 profile 或访问开发者账号。

模拟器的应用身份由 Xcode 注入 Mach-O 的 `__TEXT,__entitlements` 节；仅运行 `codesign -d --entitlements` 不能完整判断模拟器运行时身份。本次直接读取 arm64 节确认：

```plist
application-identifier = 7728J3WTW8.app.tokenlibrary.verification
```

此值来自项目现有的 App ID prefix。命令行清空 `DEVELOPMENT_TEAM` 仍可完成该模拟器构建，但这不等于真实 iOS 设备或发布签名不需要团队与有效 profile。没有添加 Keychain Sharing 或自定义共享组。[Apple 对签名中应用身份和 Keychain 权限的说明](https://developer.apple.com/library/archive/technotes/tn2318/)

## 复现构建方法

先在独立临时目录复制 `clients/iOS/Info.plist`，仅将其中的 `CFBundleDisplayName` 改为 `TokenLibrary 验证`；保留原来的构建变量、隐私用途说明及 Bundle ID 占位符。将临时文件路径传给本次构建，避免签名后再修改 Info.plist。

在仓库根目录运行（以下路径对应本次验证；后续可换新的独立临时目录）：

```sh
xcodebuild \
  -project clients/TokenLibrary.xcodeproj \
  -scheme TokenLibrary-iOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/tokenlibrary-ios-signed-6f4qbgkc/DerivedData \
  -clonedSourcePackagesDirPath /private/tmp/tokenlibrary-ios-packages \
  PRODUCT_BUNDLE_IDENTIFIER=app.tokenlibrary.verification \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= \
  INFOPLIST_FILE=/private/tmp/tokenlibrary-ios-signed-6f4qbgkc/Verification-Info.plist \
  build
```

`CODE_SIGNING_REQUIRED=NO` 保持项目原有的模拟器设置。不要把此命令换成 `CODE_SIGNING_ALLOWED=NO` 后仍据此验收 Keychain；也不要在签名后改显示名称、Bundle ID 或资源文件。

诊断任务只生成和检查安装候选，没有自行安装、卸载、启动应用或清空模拟器 Keychain。随后 Root 安装该签名包并通过 GUI 使用正确密码登录，界面进入“正在同步资料与附件…”，不再出现 Keychain 错误；这确认安全会话保存路径已恢复，不代表整轮同步和其他 iOS 用户旅程全部完成。

`23:33:09` 产物编译时仍可能包含 StickyNoteEditor 的并行开发片段，属于登录修复验证包；最终交付还需重新包含便签等并行修复冻结后的最新源码。该产物之后，源 Info.plist 又加入局域网用途说明“连接你设置的局域网服务器，同步书籍、论文、笔记和附件。”，后续验证构建应从最新源文件重新生成临时 Info.plist，不能复用旧临时文件漏掉此说明。
