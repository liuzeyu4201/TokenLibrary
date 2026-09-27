# iOS 同段冲突、稍后处理与重开证明

2026-09-27 01:53。已证明iOS冲突材料跨退出重开保留，并完成第二轮真实软键盘自定义合并、两端换文档重开及三方精确收敛。**第一轮AX自定义合并输入仍不能判为通过**；保留其实际请求和材料，不以第二轮成功改写历史。

## 环境与证据方法

限定合成恢复服务53056、library `97c6c216-19ef-4e34-b97f-fecbf4653702`、epoch `08874133-4249-485c-8829-93d98cdb7485`。两端使用同一新笔记 `2df4162f-225e-4dce-b774-55557ce43b27`／`iOS同段冲突与恢复验收.md`；Mac为新独立并发验证客户端，iOS为验证应用。没有改真实资料、后台直接写库、撤销会话或用API模拟本轮编辑；退出、重登及两端正文修改均由主验收实际操作应用。

只读采样脚本 `/tmp/tokenlibrary-ios-conflict-proof.py` 每次重新查当前模拟器数据目录，以SQLite只读事务读取目标working/remote、operation、conflict和editor draft，并以PG只读事务取服务端当前revision。目录 `/tmp/tokenlibrary-native-ios-conflict-2df4162f/` 的每个阶段拒绝覆盖。独立摘要 `initial-independent-audit.json` 对七个阶段逐值断言并记录原证据SHA-256；摘要生成器 `/tmp/tokenlibrary-audit-ios-conflict.py` 只读证据文件，未操作服务或资料。

表内正文简写仅省略所有版本都保留的 `\n\nKeep: unchanged\n`，实际正文使用3个LF，没有字面反斜线n。精确字符串/hash保存在原始JSON。

| 时刻（上海）与证据文件 | iOS | Mac／云 | 已核实结果 |
| --- | --- | --- | --- |
| 01:44:57 `baseline-logged-out.json` | rev3，`Conflict: base`，已退出连接 | 同rev3/正文 | 同一对象、无冲突、无待发送操作 |
| 01:45:34 `ios-offline-edit.json` | 真实软键盘改为 `Conflict: baseios`，基准rev3，pending1 | rev3/base | 离线内容仅在本机队列，原云正文不变 |
| 01:45:47 `mac-remote-edit.json` | 保持baseios/pending1 | Mac普通源码编辑为basemac，云rev4 | 两台实际客户端同一段各有修改 |
| 01:46:02 `conflict-created.json` | 工作区保留baseios/rev3，远端快照basemac/rev4；状态存在冲突 | basemac/rev4 | 01:45:57正常重登后生成一个pull_merge冲突，共同base与两份修改均保留 |
| 01:46:59 `deferred-app-closed.json` | 同一conflict/op/正文 | 同rev4 | UI稍后处理、实际AppSwitcher关闭并确认进程退出；没有自动选择某一方 |
| 01:47:52 `restarted-conflict-open.json` | 同一conflict/op/正文，重新打开比较页 | 同rev4 | 冲突JSON与未发送operation逐值等于关闭前，材料持久化成立 |
| 01:48:11 `merged-saved.json` | 已提交baseios，rev5 | 云rev5/baseios；此刻Mac仍rev4 | 第一轮AX试验实际没有提交自定义合并文本，详见下节 |

共同冲突ID `880c4535-e428-4aea-bc12-7e66faf4e6e4`，kind=`pull_merge`、server_id为null，三份材料分别为base/rev3、baseios/rev3、basemac/rev4。该冲突发生在pull/rebase阶段；旧operation `4daee789-8da7-4375-9d33-1ef3f2eb0998` 的request_json、frozen_generation与base_revision仍为null，不能将其描述成服务端拒绝已冻结请求的冲突。

## 待提交0与冲突阻塞是不同状态

[DocumentStore.pending](../../clients/LibraryCore/Sources/LibraryCore/DocumentStore.swift)仅返回 `pending`、`awaiting_remote`、`needs_edit`，AppModel的待提交计数来源于它。`conflict` 状态操作等待用户处理，不会被自动发送；已替代的 `superseded` 是历史记录，也不计入待提交。[SyncStore](../../clients/LibraryCore/Sources/LibraryCore/SyncStore.swift)独立查询open或resolving的冲突；界面还有“存在需要处理的冲突”提示与比较入口。

因此冲突时**待提交0不是已解决**，也不是正文已被服务器接受。初轮冲突阶段实际是一个open conflict、一个conflict operation、零可发送操作。原始采样脚本中的 `allOutstanding` 使用 `state != 'sent'`，包括conflict和superseded，不能拿这个历史字段与UI待提交直接对比。独立摘要分别计算targetSendableCount、openOrResolvingConflicts、各操作状态；初轮其他对象非sent为0，可确认全库可发送计数也为0。

## 01:48 AX设置合并框的结果不确定

主验收用AX setValue把“合并后的Markdown”显示为 `Conflict: basemac + baseios\n\nKeep: unchanged\n`，AX与截图当时显示该值；点击保存后列表为空。但只读结果是：

- 新operation `ded6ac43-85da-4102-8d53-98c68bb7c275` 状态sent，冻结base revision4；**其request_json.desiredSnapshot已经是baseios**，云端与iOS当前rev5精确等于该实际请求。
- 旧operation变为superseded，原冲突变为resolved；除state外，原三方材料、ID、创建时间等逐值保持，未抹去比较依据。
- 保存采样时Mac仍为rev4；这只是该时间点的异步拉取状态，之后01:50的只读阶段已显示Mac收到rev5，不能将前一瞬间误判为同步失败。

[ConflictResolutionView](../../clients/Shared/ConflictResolutionView.swift)将TextEditor绑定到`draft`，保存按钮直接传入`.customMarkdown(draft)`，初始值来自local材料。静态代码未发现提交时改回本机值的分支，但它不能证明AX setter实际触发SwiftUI Binding。因此目前只能定位到**自定义文字未进入请求**；不能证明服务端吞掉合并内容，也不能宣称本轮自定义合并通过或仅凭AX试验确认产品输入bug。后续使用真实软件键盘独立复验，原证据保留。

## 01:50—52真实软件键盘合并闭环

第一次试验后两端已同步到rev5/baseios。主验收在同一笔记继续独立第二轮：iOS正常退出登录，以真实英文软键盘在第一行末追加`new`；Mac实际源码编辑该行为baseiosmac；iOS正常重登后再次比较冲突，以真实软件键盘在合并框现有baseiosnew后追加`mac`，没有使用AX setValue，点击保存。

| 时刻与文件 | 确切结果 |
| --- | --- |
| 01:50:14 `retry-ios-offline.json` | iOS基准rev5/baseiosnew、一个新pending；Mac/云仍rev5/baseios |
| 01:50:29 `retry-mac-remote.json` | Mac/云rev6/baseiosmac；iOS仍保留baseiosnew待提交 |
| 01:51:30 `keyboard-merged-saved.json` | 两端与云rev7/baseiosnewmac；新的冻结请求确实包含该自定义全文 |
| 01:52:42 `final-both-reopened.json` | Mac换开另一文档后返回排版、iOS重新搜索打开源码，实际UI均显示完整正文；三方及两个remote快照仍rev7/全文相同，没有新增目标operation |

最终精确正文为 `Conflict: baseiosnewmac\n\nKeep: unchanged\n`，3个LF（含末尾LF），SHA-256 **`d38d2804a0b75b49f95398609b34425782943445c0a66174ae1b101c7ee54956`**。

第二冲突ID `43fe97d8-529c-45eb-8c75-a807e51b3271`，kind=pull_merge，base/baseios rev5、本机/baseiosnew rev5、远端/baseiosmac rev6均保留。实际合并operation `2c85733e-b845-4af4-91f4-d68d8fccf96c` 以revision6为冻结基准，request中的完整正文精确等于最后云/iOS/Mac，状态sent。第二离线operation变为superseded，第二冲突变为resolved。

独立核验 `/tmp/tokenlibrary-native-ios-conflict-2df4162f/final-independent-audit.json` 与生成器 `/tmp/tokenlibrary-audit-ios-conflict-final.py` 逐值确认：两个客户端工作正文/remote snapshot及云全文、revision一致；名称/父目录/state/metadata/assets与初始基线相同；两端全库可发送0，目标open/resolving冲突0，目标editor_drafts0。iOS仍保留两条superseded和两条resolved历史，第一轮与第二轮三方材料完整；这不表示仍有待发送操作。保存后到两端重开，目标operations与conflicts逐值不变。

## 范围边界

此样本已完成iOS主动退出后离线同段编辑、另一台Mac实际编辑、正常重登形成本地pull_merge冲突、比较共同版本、稍后处理、实际退出重开保留相同材料，以及真实键盘自定义合并/提交/两端重开精确收敛。初轮AX输入路径的不确定性保留。采用服务器／保留本机按钮、服务端冻结请求冲突、解决过程断网、更多版本竞争及恢复草稿editor_drafts专门旅程仍需各自证据。F12持续输入时远端更新的光标问题是独立旅程，见[原生交错与失败记录](native-markdown-interleaving.md)。
