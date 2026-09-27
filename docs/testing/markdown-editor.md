# Markdown 编辑器验证

更新：2026-09-27。最近完整 Chromium 于 **03:41:51.340** 开始，**51 passed，48.657 秒，0 失败、0 跳过、0 flaky**，结果在 `editor/test-results/results.json` 与封存 `/tmp/tokenlibrary-legacy-read-alt-full-results.json`，日志 `/tmp/tokenlibrary-legacy-read-alt-full-browser.log`。新增旧图未编辑直接阅读描述回归；此前50项中的源码键盘回归红绿、旧图阅读增量与资源身份见[键盘专项](keyboard-accessibility.md)。38/45 项选区修复见[源码交错](native-markdown-interleaving.md)与[排版交错](rich-editor-selection.md)；下文 00:29 的32项与更早29项保留为历史验证范围。Mac03:37—40已通过限定WK源码键盘退出，但不据此宣称旧图最新资源的原生阅读或 VoiceOver 通过。

## 复现

在 `editor/` 运行 `npm ci`，随后 `npm test`。Playwright 使用本机 Google Chrome；其他安装位置可设置 `TL_CHROME`。测试服务仅绑定本机 8766 端口，`test-server.mjs` 提供构建产物。构建还会更新客户端随包资源；不要与 Xcode 复制资源同时执行。

## 00:29 历史32项断言

| 范围 | 已通过断言 |
| --- | --- |
| 输入与模式切换 | 打开不触发自动改写；排版输入和撤销；模式切换保留最后事务和精确源码 |
| 离线阅读 | 公式、Mermaid 的节点文字可见；错误公式/图表显示错误及原文 |
| 排版Mermaid | 原生同一夹具离线生成实际SVG且打开不写回；错误可恢复；切换语言/替换节点后迟到异步结果不复活旧图 |
| 内容过滤 | HTML 脚本、事件处理器、危险协议不执行；内部来源 ID/hash 在排版模式保留 |
| 媒体 | 浏览器图片替身真实解码及重开；原生桥模拟返回相对路径和 scheme；排版 native 导入等待保存回执后关闭；选中文字插图保留前后文及撤销/重做；旧录音块解析成播放器 |
| 图片描述与缩放 | 标准 alt/title 跨排版、源码、阅读、重开保留；真实 accessible name；文件名方括号转义；旧数字 ratio 恢复、实际拖动缩放后重开、caption 编辑不覆盖描述；普通数字描述与显式数字新格式不误判为 legacy |
| 布局 | 390 px 深色界面无水平溢出，保留截图 |
| 保存竞态 | 快速输入串行回执；远端合并后新输入保持正确基准；输入期间 host refresh 不覆盖正文；双页源码空格/尾换行同步至空闲排版端零写回 |
| 输入法组合 | 合成 composition 期间不重赋 textarea、不提交候选；host refresh 延后，旧回执不覆盖候选或修改合并基准；提交后最终中文保留，取消候选后应用延迟远端，未完成候选不能误报 flush 成功 |
| 故障与离开 | 写失败保留文本并可重试；冲突草稿持续保存；关闭等待在途保存及图片导入完成 |
| 归档 | 默认阅读并禁用编辑入口；明确继续编辑后保留同一正文；输入期间归档先收集最后事务 |

测试中的原生回执、图片桥和故障均为可控制替身。真实 SQLite 合并、工作区隔离和恢复草稿由 Core 套件验证；系统文件选择器、WKWebView 桥、系统导出、iPhone 键盘、实际录音播放仍须通过原生旅程。

## 本轮图片回归

旧原生桥测试通过 helper 默认进入源码模式；本轮直接增加排版模式下的 `#image-file` 路径。修复前稳定复现无图片节点，控制台显示 nullable caption 的 schema 错误；选中正文插图另复现 open slice 丢失原子块。修复日志为 `/tmp/tokenlibrary-editor-rich-image-before.log`，第一轮完整修复的 22 项结果为 `/tmp/tokenlibrary-editor-rich-image-full.log`。

随后加入描述保留测试：旧 `0.50` 图片按90px显示，真实拖动至 `0.75` 后保存，再打开为135px；修改caption后alt与比例仍保留。旧笔记刚打开没有tl-change，源码字节不变。元数据注释在阅读模式不可见。新格式的 `1.00` 描述与旧版数字缩放分别验证，整数 `2024` 作为普通描述保留。图片专项10项日志 `/tmp/tokenlibrary-editor-image-alt-focused.log`，已包含在此前25/29项与最新32项全套中。

最新构建已同步 `editor/dist` 与 `clients/editor`；两处 `editor.js` SHA-256均为 `5b14635a1db5bcf068e489fc003f5e4223dbc124725ee296627eb0a2c4c58ddf`，已独立读取核对。此前29项包hash为 `07d7c4bf465cfca141a0dd65ba3890d409cd7086c00f898785f60db1363348ae`，是历史构建身份。新资源冻结后交给Xcode打包，包内hash与原生实际复测另记。

## 输入法并发与普通空白的区别

23:49 主验收确认，早先 iOS 的 `helloworld` 观察来自中文拼音候选选择，AX 的“下一个键盘 English US”表示下一键盘，不表示当前键盘。切换到真实英文软键盘后，`hello world\n` 在 iOS、服务器与 Mac 都完整保留，最终 revision 37、待提交 0；Mac 对这篇笔记没有写操作。证据 `/tmp/tokenlibrary-ios-whitespace-history-proof.json`。不得再把这一现象写为编辑器吞空格。

浏览器新增双页受控回归：A 源码逐键输入 `hello`、空格、`world`、两个 Return，每步发给只保持排版模式的 B，并等待 Milkdown 200 ms debounce 之后检查。A/B 的源码逐字相同，B 没有产生任何自动保存，修复前即通过。

另一个独立失败在合成DOM composition事件中确认：组合输入尚未结束，但中间保存已有回执时，tlAcceptUpdate原先能替换textarea候选文字。修复前日志 `/tmp/tokenlibrary-editor-whitespace-baseline.log` 为普通空白回归通过、composition回归失败。修复后新增3项组合输入测试：期间不重新赋同值textarea、不提交半成品；旧回执与远端更新不会盖掉候选，最终提交使用实际编辑基准；取消候选后可接收延迟和后续远端更新。4项专项日志 `/tmp/tokenlibrary-editor-composition-targeted.log`，包含在29项历史与32项最新完整通过中。

## 排版模式Mermaid停绘修复

2026-09-27 00:23，iOS原生同一 `offline-mermaid-latex.md` 在阅读模式正常显示流程图与公式，但排版模式Mermaid停留等待。使用相同夹具、旧包在浏览器保持5秒仍未呈现，日志 `/tmp/tokenlibrary-rich-mermaid-baseline.log`，证明不能只因阅读模式成功就覆盖排版模式。

Milkdown PreviewPanel会sanitize并复制返回的holder，异步仅修改原holder不会使已挂载副本重绘。现通过提供的applyPreview提交异步结果，等待Vue挂载一帧后检查当前DOM请求标记；节点被替换/删除或切换语言时，迟到结果不应用。新增3项测试覆盖同夹具离线SVG及源码保持、错误恢复、RAF挂起期间改语言后旧图不复活，纳入上述32项。

00:26:50—00:30:49首次受控无响应测试仅进入列表，未作为内容离线通过。随后00:42:45—00:45:57第二轮，在更新包冷启、本机搜索latex后，00:43排版模式实际显示新Mermaid节点与边，00:44—45阅读模式完整显示分支图、两项行内公式和积分分数。服务进程在操作期间保持暂停；恢复后队列0，两文档正文/metadata/assets与此前基线不变。此项关闭该iOS样本的原生离线显示与排版修复复验，详见[有界暂停记录](ios-unresponsive-recovery.md)；不扩展为双端离线编辑或所有公式语法通过。

合成 composition 事件验证编辑器 JS 与保存桥的协议，不等同真实 iOS 输入法会话。新包仍须原生验证拼音候选、取消、远端刷新和离开行为；本轮没有依据 AX setValue 单独变化宣称真实输入成功。

## 已知原生发现

Mac 实际运行已发现并修复 Mermaid 空节点文字，以及排版来源链接被上游 schema 过滤的问题。重启后图表节点可见，点击含 hash 的来源链接已真实返回 PDF 第 2 页。含图片的笔记经过文件夹选择、导入、阅读渲染与系统 ZIP 导出，导出媒体 hash 与输入一致。

23:02—23:04 的隔离 Mac 应用已实际完成“图片”按钮 → 系统选择器 → 选择 fixture-diagram.png → 排版显示图像 → 本机保存 → 同步归零。Command-Z 只撤销图片且保留原文，Command-Shift-Z 恢复图片；再次打开选择器后取消，没有新提交。导出的 `native-source-note-with-image.zip` 为 53,926 B，CRC 通过，50,786 B 图片与输入 hash 相同。在 VS Code 的 Markdown Preview Enhanced 中实际打开解包正文，图片完整可见，来源说明的页码/hash/原文/个人评论可读。原 PDF 未随包复制，专用来源链接仍需原资料库。证据为 `/tmp/tokenlibrary-native-source-export-proof.json`。

上述原生段落使用上一轮插图修复，此时 alt 仍为旧版 `1.00`。**这段 23:02—23:04 证据不包含新 alt/ratio 实现，不能据此宣布新版本原生重开、VoiceOver 或 L30 全部通过。** 实际 VoiceOver、iOS 对应旅程与新构建后验证由[原生验证记录](native-ui-validation.md)继续记录。

后续23:17原生已把图片alt改成“阅读、思考与保存的流程图”，23:31 Mac重开仍保留；iOS读取该图、Files外部预览与目录回导的新副本图片也分别验证，见[iOS导出回导证明](ios-export-reimport-proof.md)。这些后续结果不改写23:02—23:04历史包身份，且仍不等于VoiceOver朗读通过。
