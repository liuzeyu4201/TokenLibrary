# 排版模式远端更新与持续输入

## 已确认的问题

2026-09-27 的源码双端原生验收通过后，单独检查排版模式发现同类缺陷。旧 `setRich` 用 Milkdown `replaceAll` 替换整个 ProseMirror 文档；即使用户正在输入的 Local 段落没有改变，选区也会被当作删除内容，后续真实按键落到 Tail 段落末尾。源码模式的 textarea 修复不能解决这个路径。

自动复现使用实际 Playwright 键盘事件：将光标定位到 Local 段末，输入 `e`，分别送入正常远端刷新和保存确认返回的 canonical Markdown（只修改 Remote、Tail 两段），再输入 `fghXYZ`。两项都先失败；隐藏排版更新不抢源码焦点的第三项原本通过。

- 初始红测：`/tmp/tokenlibrary-rich-selection-before.log`，2 失败、1 通过。
- 扩展测试另发现段前插入与嵌套列表修改会跨结构覆盖选区；只对 Remote 前缀加粗、使一个 text 节点拆成多个节点，也会把 KEEP 后的光标移到段尾。格式拆分独立红测：`/tmp/tokenlibrary-rich-format-selection-before.log`。

## 修复范围

`editor/src/rich-updates.js` 解析新的 ProseMirror 文档，先以未变子节点对齐，在剩余范围中按兼容节点结构递归比较；文本采用有界字符差异。所有文本替换从末尾向前执行，交给 ProseMirror 正常映射现有选区。纯文本段落先聚合文字再处理 marks，避免加粗、链接等格式拆分文本节点时删除未修改文字；格式用原位 mark steps 更新。

更新事务不调用 focus，不重建 editor state，不整体重置 selection，不调用 scrollIntoView。远端更新设置 `addToHistory: false`；本地撤销保留独立远端变化。生成文档与目标解析结果不一致时不提交事务，沿用已有可见错误及源码保留路径。

`source-selection.js` 仅额外导出已有差异工具和新字符串范围，保留原 textarea 映射行为。`editor.js` 的 rich 更新入口改用局部事务。Swift 存储、同步协议、凭据和运行中的验收资料均未修改。

## 自动验证

2026-09-27 02:09:48 开始完整 Browser 套件，45.721 秒，**45 项通过、0 失败、0 跳过、0 flaky**：`/tmp/tokenlibrary-rich-selection-full-browser.log`。

新增 7 项真实键盘覆盖：

1. clean refresh 后继续输入仍在 Local 段落；
2. canonical save 后继续输入仍在 Local 段落；
3. 段前插入、嵌套列表前项插入及两侧变化后保持当前列表项；
4. 同一行两侧分别变化，反向选择 KEEP 保持范围与方向；
5. 远端加粗拆分 text 节点，继续输入仍紧随 KEEP；
6. 撤销本地输入时保留独立远端变化；
7. 更新隐藏排版编辑器不夺取源码焦点，之后切换排版保留内容。

专项日志：`/tmp/tokenlibrary-rich-selection-boundary-tests.log`，7 项通过（5.9 秒）。打包资源 `editor/dist/editor.js` 与 `clients/editor/editor.js` 的 SHA-256 相同：`313efa95337dc344a766f81e4e11d84ed12ced20372c97a58beb7ec9db7ea921`。

## 原生验收边界与控制计划

封包前此页仅有自动回归；随后02:16—18补入下节iOS排版方向原生证明。自动回归本身不代表所有方向或输入结构已通过。已完成的 iOS/Mac **源码模式**真实键盘及三方逐字证明独立保留在 [native-markdown-interleaving.md](native-markdown-interleaving.md)，旧失败笔记和通过笔记均不改。

下一轮使用全新 `app.tokenlibrary.verification.richselection`、显示名“TokenLibrary 排版验收”和独立空目录，由操作者正常 GUI 登录。iOS 保持现有 verification bundle，以新包更新；本代理只构建，不安装或启动。

控制器 `tests/fixtures/control_markdown_interleaving.py` 仅新增两个明确允许的名称：`双端排版连续输入_iOS.md`、`双端排版连续输入_Mac.md`。两个计划均须显式 `--name`，新的 object ID、固定 operation 和独立证据目录。精确三段基线不变；freeze 仅只读，只有操作者明确“现在提交”后才通过正常 updateDocument API 提交唯一 Remote 修改，提交时允许 Local 已推进到约定目标前缀。不会重新冻结、重用或改写已完成源码计划。

控制器离线守卫回归 9 项通过（0.004 秒）：`/tmp/tokenlibrary-rich-interleaving-control-tests.log`。这些测试不登录、不写数据库、不调用网络。

## 02:13 独立封包

本轮在 `/private/tmp/tokenlibrary-rich-selection-build-m3fp13nf` 完成 macOS 与 iOS Simulator Debug 构建，126 个产品源码文件构建前后哈希一致；两端 `BUILD SUCCEEDED`、`codesign --verify --deep --strict`、打包 editor hash 全部核对成功。

- Mac 原始构建：`macos/DerivedData/Build/Products/Debug/TokenLibrary.app`。
- 用于原生排版验证的新 Mac 副本：`TokenLibraryRichSelectionVerification.app`；bundle `app.tokenlibrary.verification.richselection`，显示名“TokenLibrary 排版验收”；Info 指向新空目录 `/private/tmp/TokenLibrary-RichSelection-20260927-gle7segd`。仅复制应用、签名前改 Info、ad hoc 重签；未复制会话/资料，未启动。
- iOS：`ios/DerivedData/Build/Products/Debug-iphonesimulator/TokenLibrary.app`；保留 `app.tokenlibrary.verification` 与中文显示名；Simulator entitlement `7728J3WTW8.app.tokenlibrary.verification`、局域网用途说明已核对。未安装或启动。

| 产物 | SHA-256 |
| --- | --- |
| Mac 排版验收可执行文件 | `dc4b79d734a222115ff1e400ee4f355e54a71bc96e75f69746cd1035ba4040dc` |
| Mac 排版验收 zip | `c3d6991ed5d7ce8cfc8b33d65d8a8462ff8ae58dc7d3946c3bb143b7bb56c87f` |
| iOS 可执行文件 | `da5c01020f36b40292630b647780baa2df75a8320f9c4c9fdff89eb9e49b4a2d` |
| iOS zip | `0d3227c08ac07ac45d63291ee20c65cb700a06a4849a9efdd2d3bd127a940fe8` |

封包记录：该目录 `verification.json`、`richselection-verification.json`、双端 build 日志和签名日志。此前源码验收封包与运行资料保持原样。Swift 逻辑未改，本轮未重复未受影响的 Core/Model 套件；最近完整客户端模型仍为 84 项，不能把 Browser 45 混记为原生验收通过。

## 02:16—18 iOS排版方向原生通过

主验收正常启动并登录独立RichSelection Mac，02:13:58在原生UI创建 `双端排版连续输入_iOS.md`，ID `1aeacc7a-1a88-45f6-a0c9-d2b2e42052d0`。只读冻结时Mac/云revision3、三段BASE精确相同、待提交0，计划与Mac基线分别保存于 `/tmp/tokenlibrary-native-rich-ios-1aeacc7a/prepared.json` 和 `mac-baseline-proof.json`。iOS更新新排版修复包后仍使用原verification容器/资料库。

iOS保持排版模式和Local段尾选区，真实软键盘a/b/c于02:16:29.636／31.459／33.045输入。主验收明确“现在提交”后，固定operation `43b2c1e2-0196-4a9a-91ed-e570524667f9` 正常API提交：02:16:51.392933发出、51.411094收到committed revision8，replayed=false，专用会话已退出。提交前云端实际已到revision7/Local baseabcd；提交后保留abcd，仅Remote变为 `REMOTE-c17d63507e5a`，未重新冻结或覆盖已输入d。回执为同目录 `attempt-f464b6469774469c8f143e503223db62.json`。

02:16:51.854输入e的原生截图已经显示Remote新标记，Local仍baseabcde。未换焦点或重新定位，继续f/g/h于58.186／59.830／02:17:01.514，X/Y/Z于02:17:11.716／14.316／17.439，全部落在Local段；本轮没有追加空格或Return。02:17:27收键盘后完整三段、待提交0。随后iOS换开f367再返回，02:17:58源码完整；Mac亦换开f367再返回，02:18:00排版三段完整。

独立只读最终证明 `/tmp/tokenlibrary-native-rich-ios-1aeacc7a/final-both-reopened.json` 于 **02:18:18.435858** 取得：iOS、RichSelection Mac的working/remote及云均 **revision15**，精确正文为：

```text
Remote: REMOTE-c17d63507e5a\n\nLocal: baseabcdefghXYZ\n\nTail: keep\n
```

上面`\n`表示实际LF，共5个LF且保留原Tail末LF；没有字面反斜线n、额外空行或行尾空格。SHA-256 **`ad68f2eb221d4d447d7d4b7bc9e341385090109ef9751b3238f72d598ff92aa7`**。两端全库可发送0，目标open/resolving conflict0、editor_drafts0、云open conflict0；名称/父级/metadata/assets/state与基线相同。原c4d失败、f367 iOS源码修复、8e Mac源码修复、2df F13的完整云snapshot及revision分别保持12/17/17/7，未修改旧证据。

该段关闭**iOS排版方向**真实远端显示后继续输入与两端重开收敛。Mac排版持续输入使用另一个新样本，尚未因本段通过而算通过；复杂输入法、结构改动/撤销等自动用例也没有由此扩展为原生全覆盖。

## 02:19—21 Mac排版对称方向原生通过

新原生笔记 `双端排版连续输入_Mac.md`，ID `181fd9c9-7863-4219-8325-88e8f65a8024`。02:18:34主验收保存三段BASE；独立Mac/云只读确认revision3、精确BASE/queue0后，冻结到 `/tmp/tokenlibrary-native-rich-mac-181fd9c9/prepared.json`，没有重用iOS计划。

Mac在排版Local末尾以真实按键输入a/b/c，时点02:19:06.357／07.984／09.512。Root明确提交后，控制器仅提交固定operation `485ce55d-68de-4857-b41a-da3e805361a7`：POST02:19:44.757329、回执44.775939，committed revision9、replayed=false，专用会话正常退出。提交前实际云端已有Local baseabcde；远端操作仅把Remote改为 `REMOTE-049387f3a8c2`，保留已到达的abcde。

02:20:03.666继续输入f时，原生截图已显示Remote新标记，Local仍为baseabcdef。后续g/h/X/Y/Z于02:20:10.369／11.812／13.363／14.934／16.361，全在原Local段，没有重新定位。02:20:27 Mac换开已通过的1ae再返回181，排版完整；02:20:48 iOS同样换开1ae再返回181，源码完整且待提交0。

**02:21:21.047055最终只读证明** `/tmp/tokenlibrary-native-rich-mac-181fd9c9/final-both-reopened.json`：iOS、RichSelection Mac工作正文/remote snapshot与云端全部 **revision15**，精确正文：

```text
Remote: REMOTE-049387f3a8c2\n\nLocal: baseabcdefghXYZ\n\nTail: keep\n
```

5个真实LF、原末LF保留，无新增尾空格或额外空行，SHA-256 **`6b901c3d75273f831d8f50dcca6a6447b989f139c324f769e4f4f8b6e3106f25`**。两端全库可发送0、目标open/resolving conflict0、editor_drafts0，云open conflict0；名称/父级/state/metadata/assets不变。

同一证明还逐值保护5份旧完整snapshot：c4d失败rev12、f367 iOS源码rev17、8e Mac源码rev17、2df F13 rev7、1ae iOS排版rev15全部保持，原材料未重写。两轮控制回执、冻结计划与读取脚本 `/tmp/tokenlibrary-rich-typing-proof.py` 均保留。

截至02:21，源码与排版两种模式在iOS和Mac的**上述限定三段文本交错**均已完成：Remote真正显示后继续输入、原位置正确、双端换文档重开/全文收敛。它不覆盖所有结构、输入法组合、富格式选择或全部F13冲突/恢复草稿分支；这些仍按总账逐项验收。
