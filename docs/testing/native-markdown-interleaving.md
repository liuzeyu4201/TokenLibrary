# F12 原生持续输入与远端更新交错控制

2026-09-27。首次原生交错暴露源码光标跳转缺陷，失败现场保留。修复后用另一新笔记完成 **iOS 源码持续输入与远端更新交错、iOS/新 Mac 重开及三方精确正文核对**，02:00:01 限定通过。不能由此宣称 Mac 持续输入或富文本持续编辑通过。控制执行者不操作 GUI。

控制器：[control_markdown_interleaving.py](../../tests/fixtures/control_markdown_interleaving.py)。固定 53056 合成恢复服务、库 `97c6c216-19ef-4e34-b97f-fecbf4653702`、epoch `08874133-4249-485c-8829-93d98cdb7485`；提交仅允许独立 `e2e` 会话。不会读取原生 Keychain、写 SQLite/PG、暂停服务或自动解决冲突。

## 正常操作顺序

1. Mac 原生新建笔记，使用源码模式保存以下精确内容，等待同步 0。iOS 同步并打开同一新对象，记录其 ID。最后一行末尾包含 LF。

   ```markdown
   Remote: base

   Local: base

   Tail: keep
   ```

2. 主验收给出对象 ID 后，控制器只读冻结该对象当前 revision 和不可变快照。检查名称、正文、库/epoch 均符合夹具；新 `/tmp` 证据目录禁止覆盖旧计划。

   ```sh
   python3 tests/fixtures/control_markdown_interleaving.py freeze \
     --object-id <新对象UUID> --directory /tmp/tokenlibrary-native-typing-<独立后缀>
   ```

   生成 `prepared.json` 和 `operation-request.json`；冻结的正常 `updateDocument` 请求仅包含改变第一段的 `markdownSource`。随机 `REMOTE-…` 标记、deviceId、operationId、base revision 和请求 SHA256 一次确定。`preview prepared.json` 仅离线读取。

3. iOS 保持原编辑器和源码模式，英文键盘，在 `Local: base` 后分批追加 `-01`、`-02`、…、`-08`，最后追加 `-XYZ ` 和 LF。最终局部文本为 `Local: base-01-02-03-04-05-06-07-08-XYZ \n`，其中 `\n` 表示实际换行；原有段落分隔和 `Tail: keep` 不变。可在 freeze 时用 `--local-target` 指定其他确切追加序列，冻结后不改目标。

4. 第三批输入之后，由主验收明确发送“现在提交”。辅助执行者才调用 `submit prepared.json --confirm-object <同一UUID>`；`TEST_TOKENLIBRARY_USER/PASSWORD` 仅在进程环境提供合成账号。控制器先读取当前对象，允许其 revision 大于冻结 r，但正文只能是预定 Local 目标的追加前缀，其他业务字段必须与基准一致。仍以冻结 r 提交 Remote 变化，让正常三方合并保留已提交的 Local 更新。**不能改为“当前 revision 必须等于 r”的旧冲突守卫，否则真正的自动保存交错会被提前阻断。**

5. 提交期间 iOS 继续输入。记录实际输入批次时间，观察同一编辑器的 `REMOTE-…` 在最后 `XYZ` 输入前是否已可见；随后继续到约定最终文本。原生正在编辑时不得用 GUI 替换整个文本框来伪造逐批输入。若网络较慢，保持输入批次间有操作记录，不能仅依据两个提交时间接近就声称看到远端应用交错。

6. 两端正常同步到待提交 0，换开另一资料再返回；只读核对新 Mac/iOS SQLite 与云端对象均有完整 Remote、Local、Tail，空格和最后 LF 保留、没有额外冲突。回执、远端标记和三方实际正文 hash 记录在同一证据目录。原笔记、其他资料均不参与本次控制。

## 故障与证明边界

- 每次提交只使用专用 HTTP 会话，结束即 logout；不输出或持久化 token。代理和重定向关闭，请求只发固定 loopback origin。
- 先查询固定 operation 的回执；已经 committed 时不再写。没有回执才发冻结字节；失败后也不能生成新 operation 或悄悄抬高基准。
- 正文其他段落、Local 非约定前缀、名称、目录、metadata、附件、删除/冲突状态变化均停止，不强制覆盖。
- `attempt-<UUID>.json` 保存提交前/后快照、提交/收到回执时间、回执及专用会话注销结果。提交后再次核对 Remote 标记和 Local 不回退；检查失败只留证据停止，不发补救写入。
- 如果 Remote 仅在最后输入完成后才被原生显示，只能记录“不同段三方合并通过”，不能记录“在途最后输入不丢失”。手工调用 API 也不代表第二原生客户端已编辑过该段；两端重开仍需实际原生操作。
- 本路线预期独立段落自动合并，不应为了凑冲突而换成同段输入。F13 同段冲突及持久恢复草稿是独立旅程。

## 准备阶段验证

主验收 01:40:32 完成 Mac 正常创建/改名/精确基线输入，随后只读查询 53056 隔离 PG 和新 Concurrent Mac 库：精确名称匹配唯一对象 `c4d018fc-5b1d-4161-b2d7-ac7f3c4a31fb`，两端基准 revision=3、正文完全一致；Mac 目标及全库 pending 均为 0。冻结目录 `/tmp/tokenlibrary-native-typing-c4d018fc`，含 `prepared.json`、`operation-request.json` 和 `mac-baseline-proof.json`。此后必须使用该计划，不能重新生成。

本轮按主验收便于软键盘输入的选择，将约定目标改为 `Local: baseabcdefghXYZ \n`（末尾空格+实际 LF），分批 a/b/c/d/e/f/g/h/XYZ。远端标记为 `REMOTE-ccf40091a386`，固定 operationId=`d9a94d9e-e528-4045-a3f5-cd7abe6f5136`。本步骤仅只读 PG/SQLite 与写隔离证据文件，没有 HTTP 登录或提交；须等主验收明确“现在提交”。

## 唯一远端提交

主验收报告 iOS 同一源码编辑器的实际软键盘 a/b/c 输入时间分别为 01:41:24.386、01:41:29.597、01:41:33.348，截图仍显示 Remote base/Local baseabc、光标未离开。随后明确“现在提交”，控制器在 **01:41:56.620923** 开始发固定请求、**01:41:56.640458** 收到 `committed`，revision=8。读取当前版本时允许预期 Local 前缀推进，但请求基准始终为冻结 revision=3。

`/tmp/tokenlibrary-native-typing-c4d018fc/attempt-17530cc25bea4b90b3c591cd546a7648.json` 保存前后快照、完整回执与时点；后置 Remote 标记/Local 不回退守卫通过，专用 HTTP 会话成功 logout。主验收随后重复发送提交通知时，仅回报已有结果，没有再次登录或发送请求。此记录本身尚不证明 iOS 在 XYZ 前实际显示了 Remote，也不替代最终空格/LF、两端重开及三方正文核对。

## 首次原生失败：远端更新后光标跳至文末

控制器提交前服务器已到 revision=7、`Local: baseabcd`；基于冻结 r=3 的远端请求成功合并到 r=8，Remote 标记改变、abcd 保留。主验收 01:42:01.925 输入 e 后，同一 iOS 源码编辑器截图显示 Remote 标记与 `Local: baseabcde`。继续实际软键盘 f/g/h（01:42:13.786/14.957/16.172）却落到 `Tail: keep` 之后；没有主动移动光标，预测栏仍显示完整本机词。主验收立即停止 XYZ，保留原样。

01:42:51.457652，只读 iOS、新 Concurrent Mac 与服务器均为 revision=12，正文完全相同：

```markdown
Remote: REMOTE-ccf40091a386

Local: baseabcde

Tail: keep
fgh
```

实际文件在 fgh 后没有末尾 LF。正文 SHA256=`fd1f6133a7228b9514e5a201df4fe52e4f36181bb234119ba425570d66309836`。证据 `/tmp/tokenlibrary-native-typing-c4d018fc/selection-jump-proof.json` 保留准确字符串、三方 revision/hash 及两端对象操作记录。这是字符被插入错误位置；不能因三方一致或字符仍在就判 F12 通过。

定位到 `editor/src/editor.js` 的 `tlSetMarkdown` 直接给 `textarea.value` 赋新文本，浏览器会把选区放到末尾。clean remote 的 `tlAcceptUpdate` 和保存回执 canonical 合并都调用此方法；因此正文保存协议本身能收敛，而继续打字的位置已变。

新增 `source-selection.js` 对更新前后未变行进行匹配、在变化间隙做有界字符级细化，按差异映射 textarea 的 UTF-16 selectionStart/End，保留反向选择与滚动；相同值完全不重设选区。大文档使用有序唯一行锚点限制矩阵内存。多个远端修改之间的未变段落不会因为全文长度差而被整体挪走。同一行两处独立变化也需保留中间光标，独立 review 的 `aaa KEEP zzz` → `aaaaaaaa KEEP ZZZ` 边界已补修、加回归。原有输入法组合期间禁止替换、single-flight 保存与冲突保护逻辑保留。

先在旧代码运行 4 项真实键盘浏览器回归，4 项全部复现失败：`/tmp/tokenlibrary-source-selection-before.log`。修复后同 4 项通过：`/tmp/tokenlibrary-source-selection-tests.log`。覆盖 canonical/clean refresh 后续 fghXYZ 空格 LF、选区前后同时变更/中文 emoji/反向方向、下方变更与同值 ack 的光标/滚动稳定。另补大文档前删/后改和同一行双侧变化，共新增 6 项。

最终全 Browser **38/38** 通过，0 失败/跳过/flaky，开始于 01:50:40.344、耗时 47.405 秒：`/tmp/tokenlibrary-source-selection-full-browser.log`。`editor/dist/editor.js` 与 `clients/editor/editor.js` 一致 SHA256=`aadd53ea0600d7d6be091800c106d66c33442234e87a3ee6e34e0d1f48ff61b2`。浏览器通过不替代 iOS 新夹具复测。

修复后原生使用另一新笔记 `双端连续输入验收_修复.md`；freeze 必须显式传 `--name 双端连续输入验收_修复.md` 及新对象 ID、证据目录。控制器只允许原名和该修复名，不接受任意资料；原失败计划/正文保留。新增兼容旧计划与显式修复名称守卫后，离线控制测试为 7 项通过。

## 修复验证包

01:53:09 完成新独立产物 `/private/tmp/tokenlibrary-source-selection-build-ge83nuwr`，双端 `BUILD SUCCEEDED`、签名 deep/strict 验证通过，125 个产品源码/资源文件构建前后 hash 一致。`verification.json` 保存一般 verification 包的路径/hash/签名，`concurrent-verification.json` 保存主验收实际要替换的并发 Mac 副本。

- Mac 并发替换包：`TokenLibraryConcurrentVerification.app`。ID 仍为 `app.tokenlibrary.verification.concurrent`，显示名仍为 `TokenLibrary 并发验收`，Info 指向原独立 base `/private/tmp/TokenLibrary-Concurrent-20260927-a6mu74bv`；只复制到新产物目录、修改 Info 后 ad-hoc 重签，未覆盖运行包。归档 SHA256=`c3c0ff1d4ee7b27c9172a603dd711c3019c84a6ecb127209812615291bbeca7f`。
- iOS 包：`ios/DerivedData/Build/Products/Debug-iphonesimulator/TokenLibrary.app`，ID `app.tokenlibrary.verification`、中文显示名和模拟器 application-identifier 均按前次正常方案验证。

两者编辑器资源均为上述 `aadd53…61b2`。安装、Quit/启动与后续新夹具复测由主验收正常 GUI 执行，构建执行者未操作 GUI/旧 Keychain/系统安全界面；没有覆盖旧失败文档或历史验收包。

## 修复后新夹具只读冻结

主验收 01:53:26 报告 Mac 正常 UI 已创建 `双端连续输入验收_修复.md` 并保存精确三段基线。随后只读确认精确名称的 active 对象唯一，ID=`f367d811-1434-40bd-8f16-d62df035ceb1`，Mac/服务器均 revision=3、正文一致、该对象待提交 0。

新计划独立保存在 `/tmp/tokenlibrary-native-typing-repaired-f367d811`，Remote 标记=`REMOTE-a27ec181720d`，operationId=`cef2fcff-d502-4085-b9ba-979889520a42`，目标 Local 仍为 `Local: baseabcdefghXYZ \n`。仅冻结与保存 Mac/服务器只读基线，没有登录或提交 API。主验收换包后输入到 c 并明确“现在提交”之前，不执行 submit。旧失败对象及其计划完全保留。

## 修复后 iOS 源码原生复测：限定通过

两端已运行编辑器 `aadd53…61b2`。旧 Concurrent 更新后发生安全凭据等待，主验收正常 Quit，没有操作系统授权；后续 Mac 证据使用正常 UI 新登录的 `app.tokenlibrary.verification.selection`、base `/private/tmp/TokenLibrary-Selection-20260927-9bpirie4`，不是已退出的旧 Concurrent。它的首次同步独立证据为 `/tmp/tokenlibrary-selection-initial-sync-proof.json`（655 对象、26 当前引用附件、cursor915、pending0）。

主验收 iOS 同一源码编辑器软键盘 a/b/c 时点为 01:57:46.077/47.947/49.177，光标在 Local 尾部。明确“现在提交”后，控制器仅发冻结 op：01:58:00.792698 开始 POST、01:58:00.809964 收到 committed revision7，专用会话 logout 确认；`attempt-b853f644922e432c9da94b3e12e50607.json` 保存完整回执。

01:58:01.263 实际输入 d 时，原生截图已同时显示 `REMOTE-a27ec181720d` 与 `Local: baseabcd`，光标仍在 Local 尾部。随后未离开编辑器或重定位，e/f/g/h 在 01:58:19.688/20.894/22.081/23.303 输入，X/Y/Z 在 01:58:33.221/35.610/38.062 输入，空格 01:58:47.016、LF 01:58:48.750。实际原生截图确认它们仍在 Local 段落，形成“Remote 已实际出现后仍持续输入”的交错证据。

01:59:02 第一次只读快照中 iOS/server 已 revision17、完整空格/LF 正确；Selection Mac 暂为 revision16，尚差最后 LF。保留该快照 `final-proof-015902.json`，没有把暂未收敛判为丢失，也没有用写库修正。主验收随后两端换开另一笔记再重新打开 f367：iOS 三段与额外空行完整；Mac 01:59:48 源码 AX 显示 Local 尾空格、三 LF 和 Tail 尾 LF，待提交0。

**02:00:01.213028 最终只读证明**：iOS、新 Selection Mac、服务器均 revision17，实际正文精确为：

```text
Remote: REMOTE-a27ec181720d\n\nLocal: baseabcdefghXYZ \n\n\nTail: keep\n
```

此处 `\n` 表示实际 LF，XYZ 后有一个真实空格。三方 SHA256=`5e3f7f5818786abdaa79fae1a9bcbfaba1a3be5e81814e43aef09bde6da1f5bc`；两本机可发送队列0、open sync_conflicts0、editor_drafts0，服务器 open conflicts0。旧失败 c4d 仍 revision12、原失败正文 SHA `fd1f…9836` 未变。最终 proof：`/tmp/tokenlibrary-native-typing-repaired-f367d811/final-proof-020001.json`。

接下来 Mac 对称持续输入拟用新笔记 `双端连续输入验收_Mac.md`；控制器已仅增加该精确允许名，须显式 `--name`，原两个计划/对象不变。离线守卫现 8 项通过。本文不将计划当作原生完成，也不扩展本次源码通过到富文本编辑。

`python3 -m unittest discover -s tests/fixtures -p 'test_control_markdown_interleaving.py' -v`：6 项通过，0 失败，0.004 秒，日志 `/tmp/tokenlibrary-interleaving-control-tests.log`。覆盖推进版本但只追加 Local、所有约定字符前缀、非追加/其他段落与 metadata/目录/身份/删除/冲突拒绝、Remote 标记、末尾空格/LF、固定旧基准和请求文件不可覆盖。测试完全离线，不调用 DB 或网络。这不是原生 F12 已验收声明。

## 修复后Mac源码对称复测：限定通过

主验收在新Selection Mac正常UI创建 `双端连续输入验收_Mac.md`，ID `8e158bae-b7a2-40e2-87dc-97a5019acdd1`。02:01:08独立基线为revision3，准确三段正文、待提交0；计划 `/tmp/tokenlibrary-native-typing-mac-8e158bae/prepared.json` 冻结Remote标记 `REMOTE-c4e85fd90af3`，operation `0e7ba0d9-dc08-4d50-9f1a-7ce8e6d81bc1`，旧失败/iOS修复/F13对象均不参与控制。

本次正文输入使用Mac真实pressKey，不使用AX setValue。在Local尾部输入a/b/c的时间为02:01:35.453／36.685／37.873，d为02:01:48.429。主验收授权的正常API冻结操作在02:01:52.420312提交，02:01:52.435263收到committed revision8；此时合并快照同时含Remote新值和Local baseabcd，专用会话正常退出。回执保存在 `attempt-d2ed89f26b4f44b2b86fc5480976fb8e.json`，没有直接写本机或服务端数据库。

02:01:54.609输入e后，原生截图已显示 `REMOTE-c4e85fd90af3` 与 `Local: baseabcde`，光标仍在Local尾部。没有离开或重定位，继续f/g/h于02:02:14.644／15.956／17.243，X/Y/Z于18.532／19.795／21.103，真实空格于27.593、Return于29.444，截图显示后续内容仍在Local段，未跳到Tail。

随后02:02:48 Mac换开f367再返回8e，源码AX保持精确尾空格/Local后三LF；02:03:42 iOS亦换开f367再返回8e，收键盘后截图完整显示Remote、Local与Tail且待提交0。因此本轮包含“远端值已在正在输入的编辑器出现、随后继续输入”，不只是最终正文自动合并。

只读脚本 `/tmp/tokenlibrary-mac-typing-readonly-proof.py` 动态取得iOS当前容器，并读取新Selection Mac库：

```text
/private/tmp/TokenLibrary-Selection-20260927-9bpirie4/Libraries/68cc057895d3cd4705929985d80181026cb1778641ffdc666573ae186ae92595/library.sqlite
```

第一次核对 `typed-complete.json` 于02:03:56生成，最后独立 `final-both-reopened.json` 于 **02:04:09.770552** 生成；均位于 `/tmp/tokenlibrary-native-typing-mac-8e158bae/`。两个客户端working/remote与云端均 **revision17**，正文准确为：

```text
Remote: REMOTE-c4e85fd90af3\n\nLocal: baseabcdefghXYZ \n\n\nTail: keep\n
```

这里 `\n` 表示实际LF；XYZ后一个真实空格、Local后三个连续LF、Tail后末尾LF均保持。三方SHA-256 **`f53506e66070caddef0995dc520be5d72420f2b148839cf08dad87aaf9533619`**。两端全库可发送操作0、目标open/resolving conflict0、editor_drafts0，服务端目标open conflict0；名称/父目录/state/metadata/assets等基线字段不变。

同一只读事务还取三份旧验收资料：c4d失败样本保持revision12及完整旧snapshot，f367 iOS修复保持revision17，2df F13保持revision7，均逐值等于各自之前的最终证据。没有为了本轮通过修补旧失败正文，历史superseded操作不计可发送队列。

截至02:04，**源码模式的iOS与Mac对称持续输入、远端显示后继续输入、两端重开三方收敛已限定通过**。排版模式在随后独立review/真实键盘浏览器红测中暴露选区跳尾风险，正在修复；不能将源码两端通过、38项历史浏览器套件或只读全文一致扩展成F12所有编辑模式均已通过。其新回归/资源包及原生复验另行记录。
