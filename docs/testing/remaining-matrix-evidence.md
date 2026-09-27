# 第6项剩余矩阵：已有证据与最小原生分支

2026-09-27，只读复核 [next-acceptance-work 第6项](next-acceptance-work.md)。本页没有启动GUI、修改资料/产品代码或新增、重跑开发测试；也没有把源码存在当作原生通过。引用各专项的固定结果，后续自动计数更新由原专项和总账维护。

## 结论与建议次序

| 分支 | 已有证据 | 尚需的最小增量 |
|---|---|---|
| 简单公式/Mermaid编辑后双端往返 | Mac实际输入、重开；双端显示；iOS无响应冷启显示；普通源码/排版双向同步 | 一篇新的合成笔记，iOS与Mac各真正改一次公式和图节点，另一端收到后源码及渲染一致 |
| 冲突“采用服务器版本” | 界面已接`.remote`；共同材料、自定义合并、解决协议已有证据 | 一个新同段冲突，实际点该按钮，核对服务器当前正文、两端收敛及旧材料保留 |
| 冲突“保留本机版本” | Core真实HTTP明确执行`.local`，原生自定义合并已通过 | 另一个新同段冲突，实际点该按钮，核对本机期望全文被提交且两端收敛 |
| 主动删除恢复草稿 | Core显式删除、U4真实产生/重开/恢复为副本 | 新的一次性真实草稿，确认删除先取消一次，再真正删除；仅草稿消失，源资料/队列/媒体不变 |
| iOS旧布局混合根 | Core登记/隔离/复制；AppModel旧偏好登记；Mac混合根UI；iOS单库容器迁移 | 独立iOS容器内旧布局与明确旧根偏好，启动、切根、未知资料保留、原pending保持、正常重开 |
| 已知旧二进制→新二进制升级 | 当前没有对应固定旧包、数据基线和iOS覆盖安装联合证据 | 先明确旧包版本/签名和数据布局；不能拿当前生成的旧布局夹具冒充真实跨版本升级 |

以上均是既定功能的验收差异。公式/图表可以共用一个新样本；两个冲突选项需要两个独立冲突结果，不能把一次自定义合并拆写成两按钮均通过。U4已恢复的PDF、既有F13笔记和旧Mac夹具不改成新试验数据。

## 一、iOS旧安装混合根：三个层次分别计证据

**自动证据已覆盖根信任及数据保护。** [LegacyLibraryRootsTests](../../clients/LibraryCore/Tests/LibraryCoreTests/LegacyLibraryRootsTests.swift)7项验证：只有明确记录的根可登记、未知缺父/循环不提升为根、重复登记/重开不改文档及冻结请求、不同绑定库不扩权、同根编辑与草稿恢复、跨根关系拒绝、复制所有可信根且保留原库。[AppModelTests.testLegacyPersistedRootRemainsNavigableWithoutPromotingUnknownParents](../../clients/Tests/AppModelTests.swift)实际创建旧`base/library.sqlite`和独立`connection.rootId/server`偏好，再初始化模型，验证旧根及嵌套目录可新建、未知根不入菜单、孤儿正文保留。

**Mac原生旧布局已通过。** [01:24—01:27旧库证明](legacy-catalog-fixture.md)包含A/B/默认/未知根可见性、同根候选、PDF/来源、正常退出重开及原操作完整字段保持。`/tmp/tokenlibrary-legacy-native-proof.json`保护原pending ID/payload，最终pending3是原操作、摘录和正常阅读的预期累积。

这里有一条重要限制：[生成器](../../tests/fixtures/generate_legacy_catalog_fixture.swift)预先调用`registerLegacyLibraryRoot`登记A/B，所以Mac原生证明的是**已有明确登记的旧布局导航**；它没有证明由旧偏好自动首次登记，更不是实际旧版二进制升级。

**iOS原生容器搬迁已通过，但不是混合根。** [iOS容器迁移记录](ios-container-relocation.md)有真实同bundle覆盖安装、11/11 PDF新路径、23/23附件字节、原代表笔记/PDF读取，以及未操作PDF没有伪资料版本；对应Core路径恢复7项还保护冻结操作和旧版本草稿。这是服务器单库中的文件路径恢复，不能替代旧`base/library.sqlite`里A/B混存的根选择。

最小补测只需新的独立iOS bundle/container，不覆盖原verification、两性能库或Mac旧库：准备旧布局合成基线、一条原pending、默认根、一条未知孤儿及有明确来源的旧根。若要覆盖首次登记，A不应预登记，应由该隔离偏好域中明确的`connection.rootId`进入正式启动路径；其他根必须同样有明确登记依据。不要猜父ID，不复制会话或用户Keychain。实际启动后依次看原pending、A/默认根及未知提示，打开一篇A笔记和一个PDF；正常结束重开再读。仅看候选数量即可补iOS界面差异，不必重做Mac摘录、缺关系清理、U3复制服务器整条旅程。

取证比较原operation ID、payload/request逐字段，所有正文与媒体SHA、unknown父级、库身份和登记来源；若实际打开PDF产生阅读记录，单独列为预期变化。若没有可确认的历史二进制，结果命名为“iOS合成旧布局兼容”，保留真正版本升级的边界；不以手改schema或普通文件导入替代它。

## 二、两个同步冲突选择按钮

**原生已验内容。** [Mac同段冲突](native-session-conflict-control.md)实际比较、源码差异、自定义合并并收敛；[iOS冲突证明](ios-conflict-recovery.md)01:44—52有真实两端同段修改、重新登录、比较、稍后处理、退出重开材料保持，以及真实软键盘自定义合并后两端重开/三方rev7精确一致。初轮AX setter没有进入实际请求的不确定性已明确保留。它最终偶然等于本机文字，不能冒称点过“保留本机版本”。

**自动证据分清选择与协议。** [FullSyncEndToEndTests.testTwoClientsMetadataMergeAttachmentsConflictsAndRecursiveTrash](../../clients/LibraryCore/Tests/LibraryCoreTests/FullSyncEndToEndTests.swift)经真实HTTP制造带serverId的冲突，执行`resolveConflict(... .local)`并让另一端收到B全文；[A2恢复联合验收](epoch-restore-two-clients.md)也执行`.local`与`.customMarkdown`。[TestConflictMaterialsAndResolution](../../server/internal/api/sync_v2_test.go)验证三份材料和提交`resolved`内容的协议；它不测试原生按钮，也不是客户端`.remote`专用回归。本次查阅现有Swift测试/验收脚本没有找到直接执行`.remote`的专项，不能因Core234整体通过就声称该分支已有独立自动覆盖。

[ConflictResolutionView](../../clients/Shared/ConflictResolutionView.swift)两按钮分别路由`.local`/`.remote`，[LibrarySync](../../clients/LibraryCore/Sources/LibraryCore/LibrarySync.swift)会先取得latest；remote选择这个最新服务端快照，local保留当时本机快照，再通过正式冻结解决操作提交。这里只说明实际路径，没有发现新的确定缺陷，也不因此增加开发测试。

最短原生步骤：用两篇新的短合成笔记，各含`Conflict`与不可变`Keep`两段；按已验退出连接→iOS本机改→Mac正常改→iOS重连产生pull_merge方式，分别点击服务器、本机按钮。此前比较/退出重开的耐久旅程不必再次整段执行。按钮前取确切两份全文与最新revision，期间不再编辑；操作后两端换文档重开，核对所选全文/尾LF、metadata/assets/父级不变、原三方材料仍保留、冲突resolved且可发送0。服务器选择按点击时latest核对，不把旧面板截图当作权威新版本。仍不能顺带宣称服务端冻结冲突、远端删除、断线解决或所有PDF冲突选项均已原生通过。

## 三、草稿主动丢弃：与取消表单和恢复副本不同

[EditorEditTests.testPDFDraftSurvivesMissingFileRecoveryAndCanBeDiscardedExplicitly](../../clients/LibraryCore/Tests/LibraryCoreTests/EditorEditTests.swift)先形成持久草稿，恢复原文件失败仍保留，然后调用`discardEditorDraft`确认草稿列表为空。`EditorEdits.swift`对应API只按ID删除`editor_drafts`；现有这项测试没有单独穷举删除前后所有业务表与队列，不能把断言扩大。[U4](pdf-draft-recovery.md)已经通过真实同批注冲突→持久草稿→正常重启→恢复新副本→双端读取，但成功恢复事务删除原草稿不等于主动丢弃。

资料详情“放弃未保存输入”、Web保存失败重试、同步冲突“采用服务器版本”都不是此动作。真实入口是“冲突与恢复草稿→恢复草稿详情→删除此恢复草稿→永久删除确认→删除草稿”。

只补一个一次性草稿即可。优先沿用U4已证明可稳定触发的机制，但使用新的专用PDF/批注：Mac打开旧批注编辑面实际改本机文字，iOS实际改同条并保存，Mac正常同步后提交旧编辑导致草稿。此处不再恢复副本或重复U4同步500修复。先取消删除确认，只读确认草稿不变；再明确确认删除，详情返回、条目消失，重开应用后不复活。前后仅指定draft行应被移除；原PDF批注保持远端已保存文字，正文、原件字节、metadata和原pending完整保持，不出现新副本或新同步操作。生成草稿不能靠直接INSERT `editor_drafts`；尚未执行本方案。

## 四、一篇笔记补公式与Mermaid双端写入往返

**已有原生足够，无须重复只读渲染。** [主记录](native-ui-validation.md)最初Mac源码实际输入中文、公式和Mermaid，正常重开保留；iOS00:23合法导入后阅读可见图和公式，00:43—45更新包在受控无响应冷启后排版图、阅读图及行内/块积分均可见。双端千项0792也实际显示PNG/Mermaid/KaTeX，但全过程未改正文。[源码/排版交错](rich-editor-selection.md)两方向真实续写与三方收敛的是三段普通文本，不是数学/图表编辑样本。

**自动证据足以支撑解析和普通传输，不冒充编辑UI。** [editor.spec.mjs](../../editor/tests/editor.spec.mjs)覆盖精确源码模式切换、离线图/公式、错误原文保留、异步Mermaid修复/取消/恢复；其中图表更新使用`tlSetMarkdown`，不是实际键入公式的原生证据。Core `testExportContainsSource`保留Mermaid与数学源码；[服务端API测试](../../server/internal/api/api_test.go)保留Mermaid/行内和块公式并验证图块竞争冲突；[merge测试](../../server/internal/merge/merge_test.go)验证受保护块。仍不能把它们组成一个从未实际执行的双端UI往返。

最小样本为新笔记，包含一条行内`$x^2$`、一条块公式`$$\frac{1}{2}$$`、两个节点的`flowchart LR`及不可变尾标记。通过正常源码入口建立；iOS实际把指数2改3及一个图节点标签改为`IOS`，保存同步，Mac打开源码确认并切阅读确认新公式/节点。随后Mac把分子1改2及另一节点改为`MAC`，保存同步，iOS重开确认源码、图和公式。独立三方全文hash/所选标记、原metadata与队列核验跟随两个提交阶段；接收端仅打开不应自动产生写回。用真实键盘或实际进入编辑绑定的粘贴，不能只依AX文字变化判成功。

这一个往返同时补简单公式和Mermaid的编写/同步差异，不需要新增语法、复杂数学、图形可视编辑器、再次断网或重复1000项性能旅程。排版节点内编辑、复杂IME/语法及真正不同版本互传仍按明确需求另列，不能从这个样本自动扩张为穷举要求。
