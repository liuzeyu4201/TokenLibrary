# 编辑器宿主加载、失败恢复与输入边界

2026-09-27 本轮修复限定于 SwiftUI/WKWebView 宿主、工作区状态提示及 PDF 手输页码。没有修改编辑器 JavaScript 或当前原生验收库，也没有将拖动窗口时的瞬时空白认定为 WebKit 崩溃。

## 编辑器加载与恢复

原实现仅尝试载入 `index.html`，没有缺失资源、导航失败、WebContentProcess 终止的可见恢复状态，重复 `tlReady` 还会再次执行正文初始化。现在 [EditorWebView.swift](../../clients/Shared/EditorWebView.swift) 具有 loading / ready / failed 状态：打开时显示“正在打开笔记”，安装资源缺失、导航失败、JavaScript 初始化失败、20 秒未准备好或真实进程终止回调均显示具体说明和“重试打开”。超时只作用于尚未准备好的本次加载，不会使已打开笔记突然失败。

重试由用户明确触发，只在失败状态创建新的 WKWebView。普通正文刷新、切换编辑模式和前后台变化没有新增重载逻辑。每次加载使用独立 token；重复 ready、上次加载的迟到回调、旧页面迟到的成功 flush 都不能重置正文或触发新页面导航。初始化期间到达的正文更新通过已有 `tlAcceptUpdate` 协议处理，归档只读状态和搜索词也在初始化完成后补齐，不再第二次 `setMarkdown`。

宿主固定绑定原 `DocumentStore`、文档 ID 和 `MarkdownEditSession`。如果已经送到原生的编辑事务写入失败，保留原 base/proposed（含空白），错误页面显示可选择复制的输入；重试必须先把它存入正文或持久恢复草稿。磁盘仍失败时不替换页面；发生重叠修改时只保存冲突草稿，不覆盖远端正文。重试重新读取当前正文，不复活已删除对象。

进程已经结束时，尚未从 JavaScript 送达原生的最后输入无法凭空恢复，界面明确说明这一边界。没有通过自动重载来掩盖失败，也没有声称所有输入在进程被终止时都能保留。

## 工作区提示范围

U3 原生证据发现：服务器同步完成后切到本机文档，旧“资料与附件已同步”仍显示在本机待提交计数下。现在连接检查、登录、退出和同步消息有明确归属，切库时清理这类消息及连接错误；取消旧连接等待不再产生一个新的服务器提示。导入/复制结果和仍属于当前工作区的本地操作错误保持原有语义，原本的工作区错误隔离规则不变。测试保留真实本机队列并核对提示切换，没有连接当前原生服务。

## PDF 手输页码

U6 原生证据发现输入 99 会被内部 `goTo` 静默截断到最后一页。新增 `PDFPageInput` 只接受裁去两端空白后的十进制整数 1…总页数；空值、负数、非数字、小数、超出范围和 `Int` 溢出均显示有效范围，不调用导航、不改变阅读位置。有效页码成功打开后清除提示。已有内部定位路径保留原来的边界策略。

## 验证结果与边界

- 02:44:30，完整 `clients` 模型/宿主套 **99 项通过，0 失败、0 跳过**，5.095 秒：`/tmp/tokenlibrary-host-feedback-full-client-tests.log`。包括当时的 9 项宿主、3 项工作区提示和 3 项手输页码新增回归。
- 此后只追加旧页面迟到 flush 的导航隔离修复及第 10 项宿主回归；02:46:32，`EditorHostLifecycleTests` **10 项通过，0 失败**，0.122 秒：`/tmp/tokenlibrary-editor-host-final-tests.log`。没有将两个结果写成未经运行的完整 100 项通过。
- 宿主测试使用真实临时 SQLite、触发器模拟事务写入失败、持久冲突草稿和独立工作区；覆盖重复 ready、迟到初始化/超时/flush、加载期间同步/归档、错误重试、删除对象与不同库隔离。测试不启动窗口、不终止真实 WebKit 进程。
- PDF 测试核对无效输入前后真实文档 metadata 和待提交队列不变，合法页码才记录位置；不是镜像控件测试。
- JavaScript 产物保持 `313efa95337dc344a766f81e4e11d84ed12ced20372c97a58beb7ec9db7ea921`，本轮未重复未改动的浏览器套。已有 45 项浏览器回归及原生源码/排版持续输入证据仍按各自专项记录。

在 02:51 封包时，原生加载/失败/重试、U3 提示切换与 U6 无效页码复验尚待本轮新包；后续缺资源旅程见下文，不把模型测试当成系统 WebKit 崩溃验收。其他原生结果以 [主记录](native-ui-validation.md) 为准。相关 Core 修复见 [PDF 恢复草稿原件身份](pdf-draft-recovery.md)。

## 本轮独立签名包

02:51 完成 macOS / iOS Simulator Debug 构建和签名核验，126 个产品源文件构建前后 hash 一致；包含本专项全部变更及 Core PDF 旧原件恢复 hash 修复。双方 `editor.js` 仍为上述 `313efa…a921`。没有安装或启动 App，也没有替换正在进行 U4 的附件验收包。

- macOS：`/private/tmp/tokenlibrary-recovery-ui-build-xc3m57_b/TokenLibraryRecoveryUIVerification.app`；bundle `app.tokenlibrary.verification.recoveryui`，显示“TokenLibrary 恢复验收”；全新、封包时为空的数据目录 `/private/tmp/TokenLibrary-RecoveryUI-20260927-jl5wiwpd`。主程序 SHA256 `04fa3f8bc5ea273cd30ac36dd97bc50ce571f890e8d86588ee8a92c201cfee76`；实际 Debug dylib SHA256 `b8512b74d17fb1137f061186863de68cc6794e867d414b6c3bf23a74e0defec6`。
- iOS：`/private/tmp/tokenlibrary-recovery-ui-build-xc3m57_b/ios/DerivedData/Build/Products/Debug-iphonesimulator/TokenLibrary.app`；bundle `app.tokenlibrary.verification`，显示“TokenLibrary 验证”。主程序 SHA256 `42cd98129a2428aecc8eb027b522e822e546188ecda044a0e6814db53b3dff1c`；Simulator `application-identifier` 为 `7728J3WTW8.app.tokenlibrary.verification`。
- 两包通过 `codesign --verify --deep --strict`。证明与完整构建日志位于 `/private/tmp/tokenlibrary-recovery-ui-build-xc3m57_b` 的 `verification.json`、`recoveryui-verification.json`、`macos-build.log` 和 `ios-build.log`；封存 ZIP SHA256 分别为 `271522cc60dfa1ad149919a0418671bab715f22b9e1dec4d741e8e79c4ed9043`（独立 Mac）和 `50149148ae7371d2c141a1822f63af59f51e07fae03938e41a69a03ac4475ad0`（iOS）。

这些是可供后续原生复验的构建证据，不能据此把尚未操作的加载异常、提示切换或页码输入标为原生通过。

## 缺资源原生验收准备（02:53 时尚未执行故障）

02:53 准备了仅离线使用的一次性副本 `/private/tmp/tokenlibrary-editor-host-failure-qcm80quf/TokenLibraryEditorHostFailureVerification.app`，独立 bundle `app.tokenlibrary.verification.editorhostfailure`、空白目录 `/private/tmp/TokenLibrary-EditorHostFailure-20260927-xzvepsap`。复制来自上文封存 recoveryui 包；真正编译代码的 Debug dylib hash 相同，只改副本 Info 后重签。没有复制会话，没有启动或登录。

其 `Contents/Resources/editor/index.html` SHA256 为 `875609f2c49a01c62ccbd5f1a9452505c7ed27fc4b583dbbecc0e2b8f31cd9e3`。同目录 `control_resource.py` 提供只读 status，以及必须显式调用的 remove / restore；remove 必须传已运行此副本的 PID，并核对进程路径、owner、固定包身份、数据目录、二进制、Info、原签名封存和 HTML hash。唯一备份位于副本外的 `control/index.html.original`，restore 只恢复原 hash 且核验原签名，不重新签名、不触 GUI/授权/数据。准备阶段仅编译脚本和执行 status，资源完整、备份不存在、strict 签名有效，尚未执行故障。详见该目录 `README.md` 和 `manifest.json`。

该 HTML 受 CodeResources 封存，移走期间仅这个副本的资源签名暂时无效，操作应在完好包已正常启动后进行、恢复完好前不要重新启动。Bundle 查询可能缓存旧 URL，实际界面可能走缺资源或本地导航失败提示；需记录真实结果，不能预先指定所见文案，更不能把这项验收当成 WebKit 进程崩溃。

## 02:56—02:57 实际缺资源、恢复与继续编辑

Root 在上述一次性离线 Mac 副本正常 GUI 新建笔记并保存后，02:56:37.431 对已经核实的副本 PID 8185 执行受控移走；随后打开笔记，真实显示“编辑器暂时无法打开”、本地 URL 未找到错误、已保存笔记仍在本机说明及“重试”入口。02:56:54.108 恢复同 hash 的原 HTML，原签名验证通过；GUI 点击重试后原正文完整显示，随后继续正常输入并保存。这是资源缺失触发的 WK 导航失败与显式重试，不是 WebContentProcess 崩溃验收。

阶段证明：`/tmp/tokenlibrary-host-resource-baseline.json`、`/tmp/tokenlibrary-host-resource-failure.json` 和 `/tmp/tokenlibrary-host-resource-after-retry.json`；控制器事件为副本目录 `control/events.jsonl`。独立只读比较确认 baseline 与 failure 的两个 working row 和两条 pending 操作完全相同。02:57:24 的 after-retry 已包含正常续写 `RetryContinued20260927`，`exactExpected=true`、仍为两条 pending，笔记 local_generation 从 2 到 6；它证明重试后继续编辑正确持久化，不能把这个已续写快照也称为全量未变化。

## 本地加载错误的中文分类（待下一包原生复验）

上述原生错误暴露了英文系统描述和 `.。` 双标点。后续源码仅为加载错误增加按 NSError domain/code 的分类：URL/Cocoa 文件不存在、读取权限、超时各自给中文行动提示；其他失败使用简短本地加载失败说明。有限深度识别底层错误，不插入 localizedDescription、失败 URL 或文件路径；仅真正 URL cancelled 忽略，其他 domain 即使数字相同也不冒充取消。JavaScript 初始化错误同样不用系统原始描述。

这项文案变化没有改已封存的验收包，真实缺文件时所见英文错误仍保留为原始证据。新中文提示需后续包含当前源码的包再复验；不在此预标通过。

02:59:56.675，`EditorHostLifecycleTests` **13 项、0 失败**（0.163 秒），日志 `/tmp/tokenlibrary-editor-load-localization-tests.log`。新增三项验证 URL/Cocoa 和错误 domain 数字碰撞的分类、包装的权限错误、路径/英文系统说明不进入消息，以及实际 URL 取消不误报、其他 domain 相同数字必须显示失败且真实 Store/队列不变；原十项重试/冲突/迟到回调回归一并通过。没有重跑完整模型套，也没有重新构建原生包。

03:02:28.009 合并 Core 缓存修复后，完整 `clients` **103 项、0 失败、0 跳过**（4.971 秒），包含全部 13 项宿主测试，日志 `/tmp/tokenlibrary-final-recovery-client-tests.log`。03:02:34.137 完整 Core **234 项、0 失败、0 跳过**，真实 HTTP 与隔离 Keychain 开启，详见 [同步验证](client-sync.md)。这更新了最近完整自动套结果，不提前扩展中文提示的原生验收范围。

## 03:04 中文提示与稳定 PDF 缓存合并包

完整 Core234 / clients103 通过后，两端 App 03:04 完成构建及 strict/deep 签名，126 个捕获的产品文件在构建前后无变化。包含 Host 中文错误分类、既有页码/工作区提示以及 PDF 稳定缓存和迁移索引修复；不含其后另行开发的录音时长修复。旧封存包保持。

- 新 Mac：`/private/tmp/tokenlibrary-final-recovery-build-qb9eifvv/TokenLibraryFinalRecoveryVerification.app`，bundle `app.tokenlibrary.verification.finalrecovery`，独立空白 base `/private/tmp/TokenLibrary-FinalRecovery-20260927-laymnvyg`。主程序 SHA256 `db752ede1c06eeb40c6a1b7271633df363ee5f3cc2b1516efe5161caa4162d65`，Debug dylib `02ca0deee718c38289552bf6c07d5141b83304e165d17953c5cc81d73aaaf3eb`。
- iOS：`/private/tmp/tokenlibrary-final-recovery-build-qb9eifvv/ios/DerivedData/Build/Products/Debug-iphonesimulator/TokenLibrary.app`，原 verification bundle 和正确 application-identifier；主程序 SHA256 `b53b3721d043a7b34f41dc5d229a6bb89b825a5ab257950441f40b874c308a4e`。
- 两方编辑器资源仍为 `313efa95337dc344a766f81e4e11d84ed12ced20372c97a58beb7ec9db7ea921`。构建日志、签名、源 hash、ZIP 和验证 JSON 位于 `/private/tmp/tokenlibrary-final-recovery-build-qb9eifvv`；独立 Mac ZIP SHA256 `38d0d83c71b3945dc75ae2b9b25f01da5e6b544bd56a7c62df004776ba08efdc`，iOS ZIP SHA256 `d6a85e7ee1d12f0d7be6d385082c75cc218873bcb3295fde5f63bb8d06dfc755`。

另复制并签名独立副本 `/private/tmp/tokenlibrary-editor-host-localized-t_mvkisg/TokenLibraryLocalizedHostFailureVerification.app`，bundle `app.tokenlibrary.verification.editorhostfailure.localized`，fresh base `/private/tmp/TokenLibrary-LocalizedHostFailure-20260927-ivvlxukl`，编译 Debug dylib 与新 Mac 相同。控制器为该目录 `control_resource.py`，只允许此副本 status / 带精确运行 PID 的 remove / 原 hash restore；原有守卫逻辑已更新固定身份与文件 hash。index SHA256 仍为 `875609f2c49a01c62ccbd5f1a9452505c7ed27fc4b583dbbecc0e2b8f31cd9e3`，备份在副本外 `control/index.html.original`。

03:05 准备阶段只执行脚本编译与只读 status，文件完整、签名有效、备份不存在，没有主动应用故障、安装或启动。中文提示实际效果由 Root 后续操作记录，不由封包提前宣称通过。

## 03:18 中文提示原生复验

Root在独立localized故障副本 `tokenlibrary-editor-host-localized-t_mvkisg`（确切PID13742）正常创建合成笔记和文件夹后切离编辑器。03:18:12受控移走本副本index；再打开笔记，GUI实际显示：“编辑器文件缺失或不可用。请更新或重新安装应用后重试；已保存笔记仍在本机。”以及重试入口。没有显示英文系统URL或文件路径。

03:18:26恢复同HTML字节/hash，原签名验证有效；Root实际重试后中文原文与 `LocalizedHostRecovery20260927` 正常渲染。独立比较 `/tmp/tokenlibrary-host-localized-baseline.json`（03:18:12.567888）与 `/tmp/tokenlibrary-host-localized-retried.json`（03:18:41.626612）：state整体逐字段完全相等，包括全部文档与原两条pending，没有用重试覆盖正文、改身份或生成新操作。故本次中文分类的限定原生分支通过；前文“等待新包”指当时未封包/未执行，不再是本分支当前状态。WebContentProcess崩溃、所有读取权限错误和其他平台分支仍按各自范围另验。
