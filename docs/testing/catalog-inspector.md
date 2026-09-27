# 资料详情窄窗口与阅读记录可访问性

2026-09-26。实际Mac验收发现资料详情约470 px宽时，默认Form的标签列截掉长字段名；相邻阅读记录的页码、manual和完整设备UUID被辅助功能树合并，难以区分。

## 实现范围

修改限定在 `clients/Shared/CatalogViews.swift`。详情改用grouped Form，元数据、页码和摘录字段采用可换行的上方标签、下方输入；静态原文件名/本机状态/同步状态也上下排列，长原文件名可换行。输入控件保留完整辅助功能标签，避免因为隐藏默认左列而丢失名称。没有提高sheet最小宽度来绕开窄布局。

阅读位置按记录分别显示来源、页码和更新时间，每条拥有独立辅助功能label/value及基于原deviceID的identifier，外层容器保留子元素。手动记录优先称为“手动记录”；匹配宿主deviceID的记录称为“本机自动记录”；其他设备显示“其他设备 · 标识前8位”。没有宿主身份时仅显示“设备记录”，不推断它一定来自另一设备。完整UUID不再挤占页码列，同页的手动/本机/其他设备记录仍使用各自稳定身份。

`CatalogWorkspaceView` 与 `CatalogInspectorView` 增加可选 `currentDeviceID` 参数；workspace会传给内部详情。主验收已在Root的资料库、Markdown详情、PDF详情三个宿主入口传入 `model.deviceId`。本专项布局修改限定CatalogViews，宿主集成与实际窗口验证由主验收执行。

## 自动验证

在 `clients/` 执行：

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/tokenlibrary-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/tokenlibrary-module-cache \
swift test --disable-sandbox --skip-update \
  --cache-path /private/tmp/tokenlibrary-spm-cache \
  --filter CatalogInspectorPresentationTests
```

`2026-09-26 23:36:45`专项2项通过、0失败、0跳过，macOS Shared编译成功，日志 `/private/tmp/tokenlibrary-catalog-inspector-tests.log`。随后包含此2项的完整客户端51项于23:56:18通过、0失败/跳过（2.695秒），日志 `/tmp/tokenlibrary-client-model-all-20260926-2356.log`；亦包含于00:14的56项及00:44的68项及00:53的72项记录（跨度3.910秒）、01:25最新84项（跨度5.025秒），见[模型测试](app-model.md)。后者另增加4项详情草稿/离开保护，与本页2项布局测试分开计数。

- 同页的手动、本机、其他设备记录各有独立身份；UUID大小写不误判本机，页码/更新时间不丢失。
- 未传宿主身份时不冒称本机或其他设备；manual即使与传入字符串相同也保留手动记录含义。

这两项是文案/身份语义回归，不证明像素布局或真实读屏结果。没有针对简单布局写实现镜像测试。

## 后续实际原生验证

主验收已在Mac约470px宽详情窗口看到长字段标签完整可读，输入位于标签下方；阅读位置的三条记录具有独立AX元素，手动、本机与其他设备可区分。手动或另端新位置到达时保留当前页，不强制跳页；“保持当前页”与显式“继续阅读”按各自语义工作。此处是新构建实际窗口/AX证据，不再列为仅模型通过。

iOS23:55签名更新包已运行，23:57 Beta来源首次打开准确到2/3；23:58资料详情中的本机记录为2/3，Mac与手动记录各1/3仍分别保留。23:59大PDF从1页选择另一设备继续到8页，再查询Large PDF Anchor 7唯一命中并到7页、自动收键盘。iOS来源定位/页码语义已通过这些限定片段，不能把Device Hub未暴露全部导航/WK元素的AX当作VoiceOver已通过或控件不存在。

## iOS 详情草稿与未提交评论保护

2026-09-27 00:58—01:00，更新后的navigation包实际打开层级验收笔记254e29af…的详情。标题改为“iOS 资料编辑保护验收”、年份输入abc，Done/保存继续明确报“未能保存”并保留输入；修正2026后保存关闭，重开仍为正确标题/年份。此段验证真实表单校验失败后的留存，不冒充底层磁盘不可写。

随后仅在评论框用真实软键盘输入draft，Done显示“未加入笔记”并提供放弃动作；取消退出动作后AX与截图仍显示draft，再Done并放弃，未点击创建笔记。没有把只输入评论的草稿静默当成已保存资料，也未意外创建摘录。

独立只读证据 `/tmp/tokenlibrary-ios-inspector-dirty-proof.json` 于01:01:02核对iOS/服务器revision6、完整snapshot一致。相对显式移动完成后的revision5，仅metadata.title和year改变；正文仍 `# 新笔记\n\n`，SHA-256 `b649b90a28e7265793b69bb7cadae9d010e0272eeeadbc82d0398bfe504fb34d`。excerpts/sourceIDs为空、队列0，全库对象仍650且升级后没有create操作，没有新阅读笔记或意外副本。

本次覆盖无效年份留输入、成功保存/重开、只有评论时离开提示/取消继续/放弃。并发更新、切库、磁盘错误与全部资料表单字段仍按各自测试边界记录，不由此声明全部草稿场景通过。

01:07装入常驻footer/顶部保存的新包后，原生在同笔记填写作者Synthetic Author，点击顶部“保存资料信息”后按钮禁用且留在当前详情。01:10真实软键盘依次输入D、r并两次删除，画面保持同一评论位置，没有动态section插入导致的视口跳动，也未点击创建笔记。模拟器软键盘此前隐藏，经系统Device→Keyboard恢复显示，不当作应用故障。01:11:08只读 `/tmp/tokenlibrary-ios-related-trash-prelink.json` 显示A为revision7，相对此前revision6仅authors新增这一值；正文hash不变、excerpts/sourceIDs仍空、队列0。此段关闭顶部保存与该短评论输入样本的视口复验，不推断长文输入/所有动态字体均通过。

主验收逐步证据见 [原生记录](native-ui-validation.md)。约470px通过不代表所有支持宽度/动态字体，三条独立AX不代表真实VoiceOver顺序与朗读全部完成。仍需：

1. 最窄支持窗口及iPhone大字模式下长标题、原文件名、所有输入和保存/关闭入口可达。
2. 全表单Tab/Shift-Tab焦点、编辑保存和关闭再开的键盘流程；没有把模型身份测试当焦点测试。
3. 实际VoiceOver逐条阅读来源/页码/更新时间与标签，确认顺序和提示不重复。
4. PDF文件版本变化后的进度失效、更多跨端交错与新包重开全流程，仍由对应专项继续记录。

01:14—19主验收通过iOS系统字号设置4次增大、4次减小恢复，实际观察Form、Catalog和筛选页面未重叠，入口仍可见。此为指定设备与该组字号的原生样本；未验证所有支持字号、极长输入或VoiceOver，不撤销上述剩余范围。
