# U8 键盘路线与读屏证据边界

2026-09-27。只核对已有控件和有限旅程，不修改系统 Full Keyboard Access、TCC 或用户快捷键。原生操作由主验收执行；本文件中的源码审查和浏览器测试不替代 WKWebView 或 VoiceOver。

## 源码区键盘陷阱：红测与修复

旧 `editor/src/editor.js` 对任何 `event.key === 'Tab'` 都阻止默认行为并插入四个空格，包含 Shift-Tab、带系统修饰键的 Tab。真实 Chromium `page.keyboard.press` 复现：Shift-Tab 后焦点仍在源码且正文多了空格；Escape→Tab 也没有出口。

本次仅改源码区：

- 普通 Tab 继续在选区插入四个空格。
- Shift-Tab 与带其他修饰键的 Tab 交给默认焦点/系统行为，不改正文。
- 非输入法组合期间，单独 Escape 使下一次 Tab 交给默认前向焦点导航。标志使用一次后清除；普通按键/输入、失焦、模式切换、实际远端正文更新和重开都不残留该状态。相同正文的回显不会打断已经按下 Escape 的意图。
- 输入法组合期间的 Escape 不阻止、不启动逃逸模式；`isComposing` 和兼容组合键码也受保护。
- 源码区显示简短键盘说明，textarea 通过 `aria-describedby` 引用；说明不进入 Markdown，在其他模式隐藏。

新增 `editor/tests/source-keyboard.spec.mjs` 五项真实按键回归：普通/反向 Tab、失败后实际“重试保存”按钮的前向焦点与返回、五种状态清除、组合状态中的真实 Escape、可访问说明和保存字节保持。组合状态用 DOM composition 事件夹具建立，不能称实际 macOS/iOS 输入法测试。

修复前 `/tmp/tokenlibrary-source-keyboard-before.log` 为 **3 失败、2 通过**；红测截图和结果封存在 `/tmp/tokenlibrary-source-keyboard-before-results`。修复后 `/tmp/tokenlibrary-source-keyboard-after.log` 为 **5 通过，4.8 秒**。完整 Browser 于 **03:28:21.316 开始，50 项通过、0 失败/跳过/flaky，46.053 秒**，日志 `/tmp/tokenlibrary-source-keyboard-full-browser.log`。保留已有源码/排版选区、合并保存、输入法协议、图像、Mermaid、390px 深色回归。

`editor/dist/editor.js` 与 `clients/editor/editor.js` SHA-256 同为 `604deb4f3dfaf88963ba0553a527abc5ebec29a4cf75ac7d82601b02ccc0dfdd`；HTML 同为 `174a686a95001e7151b71196a011a3fd76c89a5eb46bb9712665148d6f41f67b`。本次没有修改 Shared/Core，不重复其完整测试：最近完整基线仍 clients111/Core234。

## Mac 原生最短路线

每段先通过现有 UI 打开目标，再使用真实按键；如果需要点击锚点，明确记为“分段键盘操作”，不能宣称全程键盘贯通。不要用 AX click 代替 Tab/Space/Return 的通过证据，也不要根据 AX 顺序预先规定 Tab 次数。

| 段 | 按键与应观察的结果 | 源码依据/限制 |
| --- | --- | --- |
| 主搜索 | 搜索框聚焦后 Cmd-A、输入独有夹具名，Tab/Shift-Tab；记录焦点轮廓与结果。可观察 Cmd-F 的系统行为，但不预设成功 | `LibraryView.searchable`；Mac App 没有自定义 `.commands` 或搜索快捷键。仅缺自定义绑定不证明系统不可达 |
| 资料库筛选 | 打开“筛选与排序”，作者框起步，Tab 到起始年、结束年、标签，再 Shift-Tab 返回；尝试 Escape 取消/Return 应用，并核实际结果 | 标准 TextField/Picker；取消、应用未显式绑定键盘快捷键，toolbar placement 本身不作为成功证据 |
| PDF 页码/查找 | 页码框 Cmd-A、输入有效页码、Return；Tab 找到查找框后输入唯一词、Return；Shift-Tab 反向核验 | 两字段各有 FocusState 和 onSubmit；页码走范围校验，查找清理输入焦点。不要把一次默认 clamp 当有效校验 |
| 批注编辑/关闭 | 打开“管理批注→编辑文字”，在 TextEditor 中 Tab/Shift-Tab、Escape；观察焦点是否离开、草稿有无新增字符，再明确取消 | 编辑取消/保存及外层完成均无显式快捷键，不凭标准控件推断已通过；确认后再决定是否需窄修 |
| 辅助页稳定出口 | 打开设置、回收站或冲突/恢复草稿，Escape 应关闭 sheet 并保留原选中资料；可搜索资料选择器 Escape 取消 | 已显式 `.keyboardShortcut(.cancelAction)` |
| 修后源码区 | 新一次性笔记中普通 Tab 插入四空格；Shift-Tab 离开且无额外保存。重新聚焦后 Esc→Tab 离开；重进后普通 Tab 仍缩进 | 本次 Browser 已验；新包 WK 原生仍待，不用旧包判断修复 |

普通 macOS Tab 导航不保证包含每个按钮；Apple 将其与 VoiceOver 的控件导航区分。若当前系统模式只遍历文本框/列表，记录实际限制，不切换 Fn-Control-F7 来掩盖结果。[Apple Tab 导航说明](https://support.apple.com/guide/voiceover/tab-key-vo2753/10/mac/27)

## 真实 VoiceOver 可观测路线

本机已安装 `/System/Applications/Utilities/VoiceOver Utility.app`。其 `Visuals-PanelsAndMenusTab.loctable` 的中文项为“显示字幕面板”，提示明确为“在字幕面板中显示所朗读的文本”。本地工具技能只提供按键/截图/AX操作协议，没有把 AX 树转换为 VoiceOver 朗读的能力。

实际操作前记录 VoiceOver/面板原状态。若由主验收开启，官方命令为 Command-F5 开关 VoiceOver，VO 表示 Control-Option；VO-Fn-Command-F10 显示/隐藏字幕面板，功能键是否需要 Fn 取决于键盘当前设置。不要为适配工具更改功能键或 TCC 配置。[Apple 通用命令](https://support.apple.com/guide/voiceover/cpvokys01/mac)、[字幕面板](https://support.apple.com/guide/voiceover/unac078/mac)

用 VO-Left/Right 移动到一条资料、页码框、带明确描述的图片；遇列表/Web 内容组用 VO-Shift-Down 进入、VO-Shift-Up 退出，VO-Space 执行控件默认操作。每个目标保留包含实际目标和 VoiceOver 字幕的截图，确认字幕确实随导航变成对应标题、页码值或图片描述，而不是只抓当前 App AXLabel。不要启用图片识别或自动图像描述来替代产品已有 alt 的验证。[Apple 交互命令](https://support.apple.com/guide/voiceover/cpvokys07/mac)、[导航命令](https://support.apple.com/guide/voiceover/cpvokys04/mac)

字幕能证明 **VoiceOver 生成的朗读文本**；未采集/听辨音频时不能声称发音、音质或实际听觉体验通过。若工具不能发送系统快捷键或看见字幕面板，记录“未取得读屏证据”，不用 AX 树、应用自制文字或 shell 注入冒充。关闭测试时恢复原 VoiceOver/面板状态；Apple 说明 VoiceOver 开关会临时自动选择普通 Keyboard navigation 并在关闭后恢复原值，这与手动启用 Full Keyboard Access 不同。

## 03:31 独立双端封包

构建目录 `/private/tmp/tokenlibrary-keyboard-final-build-x00cmpkh`。`verification.json` 记录 127 个产品文件在构建前后无变化，双端 BUILD SUCCEEDED、strict/deep 签名通过、包内 JS/CSS/HTML 精确等于本轮资源。`browser50-results.json` 和 `browser50.log` 封存此包的自动验证；编译后没有安装或启动。

| 产物 | 身份 |
| --- | --- |
| Mac `TokenLibraryKeyboardFinalVerification.app` | `app.tokenlibrary.verification.keyboardfinal`；显示“TokenLibrary 键盘验收”；新空 base `/private/tmp/TokenLibrary-KeyboardFinal-20260927-kdlmbtp0`；主程序 SHA `0ca4fc0754076ba35f4c3b7b905805d015416e3fed98794878472fff64da5101`；实际 debug dylib SHA `dcd628b2acea54f29b86590f2495a2acae01538fbb5453c3ca020c7dfd0bd51c` |
| iOS `ios/DerivedData/Build/Products/Debug-iphonesimulator/TokenLibrary.app` | 原 `app.tokenlibrary.verification`；中文显示名；模拟器 entitlement `7728J3WTW8.app.tokenlibrary.verification`；主程序 SHA `a948be1b16cd044343e61c35d416dd91e106d8a4d49f855b295b16eebf4e36b2` |

Mac 另有 `keyboardfinal-verification.json` 保存独立副本身份/空目录/重新 ad hoc 签名及 ZIP hash；旧 03:17 navigationfinal 包保留。此包只增加键盘资源，**不含随后 useOffline 连接反馈或协议 426 提示修复**。WK 原生与真实 VoiceOver 状态应由后续实际记录补充，不能以此封包声明通过。

03:36:59 后续组合包 `/private/tmp/tokenlibrary-connection-final-build-vk07tn8q` 同时包含上述两个连接反馈修复，编辑器 JS/CSS/HTML 精确保持本次身份。双端构建、签名、127源文件一致性与独立Mac身份见[同步验证](client-sync.md#0336-连接提示与键盘组合封包)；原03:31包保持不变。两包都没有因编译而被安装或启动。

## 03:37—03:40 Mac WK 原生键盘复验

主验收随后实际启动03:36组合包 `app.tokenlibrary.verification.connectionfinal`，新建独立本机键盘笔记。源码真实 Tab 插入四空格，Shift-Tab 将焦点移到“流程图”按钮并出现轮廓；重新明确聚焦源码后单独 Escape 再 Tab，实际移到侧栏。`/tmp/tokenlibrary-keyboard-native-after-indent.json` 与 `...-after-exit.json` 整体 snapshotSHA 相同，正文和 pending 完整行不变。重新进入源码后普通 Tab 将尾部四空格变为八空格，证实临时退出状态不会持续；键盘说明真实可见。

最初 AX 点击 textarea 未取得输入焦点，随后粘贴工具超时且正文未变；主验收再按截图中文本区域点击后正常输入。此工具焦点失败未记成产品丢字。完整时间线见[原生记录](native-ui-validation.md)。上述关闭的是这个 Mac WK 样本的 Tab/Shift-Tab/Esc→Tab 分支，仍不等于全部控件焦点路线、iOS 外接键盘、真实 IME 或 VoiceOver 通过。

## 旧图只读阅读的描述补齐

03:38:47 只读合成浏览器探针发现：旧版 `![0.50](图片 "流程关系图")` 打开排版已有正确 alt，但不编辑直接切阅读仍显示/暴露“0.50”。`/tmp/tokenlibrary-legacy-read-image-alt-proof.json` 记录 richAlt 为说明、readAlt 与浏览器图像可访问名称为数字，正文完全保持、保存次数0。这是浏览器可访问名称证明，不冒称实际 VoiceOver。

现有旧图回归先缩放/保存再切阅读，未覆盖只读旧文。新增 `legacy image descriptions stay readable when switching rich to read without any edit` 用真实模式按钮重现；旧码红测 `/tmp/tokenlibrary-legacy-read-alt-before.log`，红截图封存在 `/tmp/tokenlibrary-legacy-read-alt-before-results`。修后新增例及原3图例共 **4通过，4.7秒**，日志 `/tmp/tokenlibrary-legacy-read-alt-related.log`。

修复仅在 Marked 的本次阅读 token 流中识别独立图片块及紧随的有效 `tokenlibrary-image:v1` 注释，复用排版端的旧 ratio 判定。没有显式标记的旧 ratio 用 caption 或“图片”作 alt；有显式标记的“1.00”以及普通“2024”描述保持。HTML 实体/引号/尖括号说明正确转义，原媒体链接/正文不改。新回归还覆盖归档后直接只读、所有转换零自动保存。没有扩大为全页正则替换，也没有把代码示例或任意行内数字解释成旧缩放值。

此资源变更晚于03:36组合封包。旧包/当前原生进程不被修改；尚待后续资源增量合包与限定原生阅读复验，不据本次浏览器结果宣称 VoiceOver 或 iOS 通过。

03:41:51.340 开始完整 Browser **51 项、0失败/跳过/flaky，48.657秒**，日志 `/tmp/tokenlibrary-legacy-read-alt-full-browser.log`；结果另封存 `/tmp/tokenlibrary-legacy-read-alt-full-results.json`，不依赖以后被覆盖的测试目录。资源冻结证明 `/tmp/tokenlibrary-legacy-read-alt-freeze.json`：相较03:36组合仅 `editor/src/editor.js`、`editor/src/images.js`、打包 `clients/editor/editor.js` 三个产品文件变化；JS两份SHA均 `18c27fce73c9ceeb0697e53bb79a67985da2f8550b28ecb088730d9a19a672cd`，HTML/CSS及全部 Shared/Core 保持。此阶段没有生成新的原生 App 包。
