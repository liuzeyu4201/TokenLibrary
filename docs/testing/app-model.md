# 客户端模型与路由回归测试

更新：2026-09-27；最新完整执行为03:33。

`clients/Package.swift` 将实际 `clients/Shared` 编译为 `LibraryUI`，测试目标 `LibraryUITests` 通过 `@testable import LibraryUI` 调用实际 `AppModel`。依赖为本地 `LibraryCore`（其 GRDB/Markdown 解析依赖由 SwiftPM 锁文件管理），不复制一套 UI 业务逻辑。

所有测试显式注入独立临时目录、唯一 UserDefaults suite，关闭已保存会话恢复。测试不加载用户资料、真实账号或 Keychain；同步调度用 URLProtocol 在进程内模拟离线，不发出网络请求。这里运行的是模型单元测试，未驱动窗口、WKWebView、系统对话框或 Computer Use。

## 执行

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/tokenlibrary-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/tokenlibrary-module-cache \
swift test --package-path clients --disable-sandbox --skip-update \
  --cache-path /private/tmp/tokenlibrary-spm-cache
```

当前结果：**114项测试、0失败、0跳过**，2026-09-27 **03:33:55.722**完成，All tests跨度 **6.763秒**，日志 `/tmp/tokenlibrary-use-offline-feedback-full-tests.log`。逐项核对114个passed，在03:14的111项上新增3项本机入口清理连接反馈/取消凭据等待/晚到结果隔离回归，旧码5个断言失败再转绿。保留当前store、session、选中文档、操作队列与独立本地错误，不把连接提示残留带入本机界面。

此前02:44完整99项、03:02完整103项、03:14完整111项均来自各自完整运行，不能相加作为当前数量。模型不驱动系统窗口、选择器或BGAppRefresh；03:25—34原生发现的本机入口反馈残留，在03:37—40新组合包已实际复验健康/426后进入本机提示清除且原笔记/pending保留，见连接原生专项。已过中文host/非法页码等分支按各专项限定，不因新增模型通过扩大原生范围。

| 测试组 | 项数 |
| --- | --- |
| AppModelTests | 27 |
| CatalogActionFeedbackTests / CatalogSearchTests | 2 / 3 |
| CatalogDocumentSelectionTests / CatalogInspectorPresentationTests | 7 / 2 |
| CatalogInspectorEditingTests / CredentialLifecycleTests | 4 / 7 |
| PDFImportModelTests / PDFOriginalTextTests / PDFReadingTests | 2 / 1 / 11 |
| NoteBlockCodecTests / StickyVoiceSessionTests | 4 / 5 |
| LibraryImportPickerTests | 5 |
| EditorHostLifecycleTests | 13 |
| VoiceRecordingFileTests | 5 |
| LibraryFolderNavigationTests | 4 |
| LibraryVerificationConfigurationTests / BackgroundSyncTests | 4 / 8 |

00:14:07.988前轮56项（跨度2.884秒、用例2.878秒）日志 `/tmp/tokenlibrary-import-picker-full-client-tests.log`；23:56:18.101前轮51项（跨度2.695秒、用例2.689秒）记录在 `/tmp/tokenlibrary-client-model-all-20260926-2356.log`，已逐项核对51个passed；23:37:54的49项（2.673秒）记录在 `/tmp/tokenlibrary-client-model-all-20260926-2338.log`；22:54的27项记录在 `/private/tmp/tokenlibrary-local-operation-error-tests.log`。更早13/16/19项是各阶段基线，不作为当前全套数量。当前114项不包含Core234或浏览器50项，它们是不同目标；后续实现再修改时仍需对应复测。

## 覆盖

- 虚拟本机根与服务端真实根，返回上级不越过真实根，新文件父 ID 有效。
- 旧base/library.sqlite配合明确connection.rootId恢复导航，未知父目录不进根列表，原孤儿资料保留并列入待恢复。
- 来源跳转可回到已改名/移动的阅读笔记，切库后不保留旧返回目标。
- 最近同步成功时间跨重启保存、不同工作区分别读取；失败不更新该时间。
- 不能在专题或刚被另一处删除的文件夹中创建实体子项。
- 移动普通目录、同名冲突、目录循环，失败保留内容和位置。
- 文档移动后，旧详情快照发起改名仍按当前父目录校验。
- 切换资料库后旧 Markdown 编辑会话、PDF 保存仍写入捕获的原库；相同 ID 的新库记录不被改动。
- PDF 文件版本过期的批注保存失败并保留恢复草稿。
- 已归档正文可搜索、回收站排除、待下载覆盖率、搜索选择定位；切库后迟到搜索结果不覆盖新库。
- SQLite 写入故障明确报错、不制造“已新建”条目、不改变选择、不排入未落盘操作。
- 损坏 PDF、非 UTF-8 Markdown 导入无成功假象，随后合法 Markdown 可正确导入并记录来源。
- 旧来源链接从摘录元数据恢复 hash，文件版本变化时不跳旧页码。
- 错密码保留登录页；会话到期保留离线资料。
- 取消旧资料库延迟同步后不会发出旧请求，后续新同步可启动并报告自己的失败。

本组测试实际揭示并验证修复：UI 快照仍认为文件夹 active 时，新建可能产生孤儿文件；移动后旧详情快照的改名可能被旧目录同名资料误挡；同步 Task 创建后立即取消，稍后启动的 Task 仍可能把 `syncing` 设回 true。新建现在由 Core 原子验证父目录与落盘，改名交由 Core 读取当前目录，Task 启动先检查取消和工作区身份。原13项模型基线为上述修复后的完整复跑，随后16项增加旧库、来源返回与成功时间，当前19项再包含本地错误与同步状态分离。

## 资料库异步搜索

`CatalogSearchTests` 另验证三项：取消搜索请求不产生可发布结果，下一请求正常完成；旧库与新库存在相同文档 ID 时，资料库路径身份阻止混用；实际正文索引命中与作者筛选同时生效，归档默认可检索，覆盖统计包含待下载 PDF。界面使用完整请求快照校验结果，并在条件变化后立即隐藏旧快照。


## 本地操作错误与连接状态分离

22:51—22:52原生验收发现：加密PDF的导入错误会被下一次同步成功擦掉；损坏PDF恰遇同步完成时，用户甚至未看到失败原因。AppModel现用独立localOperationError报告导入、落盘、移动等本地操作失败；它不修改connectionError，也不将同步按钮变为“重试同步”。底部可同时显示本地错误和连接/同步状态，提供“关闭本地操作错误提示”入口。显式再次导入替换上次导入提示，同路径资料库重新登录保留提示，切换到另一工作区清除旧提示。导出成功只清除对应导出错误，不抹去网络故障。底部区分“本机文档”和“服务器资料库（离线）”。

新增3项模型回归实际运行scheduled同步成功流程：损坏PDF原因在完整后台同步成功后仍存在，而连接错误清除、成功时间正常更新；关闭/不同操作/同路径重开/切库互不混淆；离线标题不把已下载服务器库称为独立本机库。URLProtocol只提供完整空库同步响应，不使用公网或运行中的UI验收库。PDFImportModel两项继续验证各拒绝原因、选择/队列/媒体不变化与可读加密PDF原件不变。这些已包含在当前111项中。

## 单文件与目录导入呈现

2026-09-27原生iOS发现：“Markdown或PDF文件”点击后没有系统选择器，另一目录导入入口可用；同一视图叠加两个fileImporter使其中一个入口被覆盖。修复统一为单个呈现器，并保存明确mode/request；正常取消不报本地错误，旧回调、切库和目标变化受请求身份守卫。新增LibraryImportPickerTests5项专项00:13:31通过，随后当时完整56项通过。随后00:17:45安装更新包，00:19实际iOS单文件选择器呈现、取消无错误、再次打开及合法PDF导入通过；三类PDF拒绝与同步成功后本地原因保留也已复验，见[PDF导入记录](pdf-import.md)。模型本身仍不替代这些GUI动作，也不代表所有文件授权失败分支已验。

## 独立原生片段与模型边界

主验收另已实际完成Mac三类PDF拒绝、本地原因在手动/自动同步成功后仍保留及关闭入口；约470px资料详情长标签和三条独立AX阅读记录通过。iOS23:57更新包的Beta来源首次准确2/3，23:58详情保留本机2/3、Mac1/3和手动1/3；23:59大PDF1页选择继续到另端8页，检索Large PDF Anchor 7唯一命中并到7页，自动收键盘。这些属于真实UI片段，见[原生记录](native-ui-validation.md)、[PDF阅读](pdf-reading.md)与[详情布局](catalog-inspector.md)，不由模型通过推导。

iOS真实软键盘源码输入、便签文字/照片/排序的三方正文与JPEG字节核对见[iOS输入证明](ios-text-input.md)。后续升级重开保留顺序/caption与麦克风拒绝提示有实际GUI证据；便签音频模型仍使用可控后端，允许权限后的录制/播放、后台/中断和VoiceOver不能由此声明完成。

## 最新表单与凭据生命周期

00:44完整回归包含异步凭据读取期间界面可用、取消/迟到结果不覆盖当前工作区、恢复失败时保留已下载库等模型行为；该组使用注入后端，不读真实Keychain。资料详情保存/取消的草稿保护、未提交摘录的离开保护和同一资料库候选身份守卫也纳入本轮。具体代码与边界见[资料库验证](catalog-library.md)。原生双端换包与离线等待操作由主验收单独记录；测试数量不能代替全部关闭/切库/迟到回调的GUI旅程。

前轮68项于00:44:23.396完成，跨度3.108秒，日志 `/tmp/tokenlibrary-catalog-complete-client-tests.log`。随后真实iOS发现点击搜索命中的文件夹仍停在搜索列表。最新实现绑定搜索呈现状态：成功进入文件夹后清查询、取消迟到查询并退出搜索，显示目的地子项；普通资料保持查询，已删除的陈旧文件夹明确失败并保留搜索。LibraryFolderNavigationTests4项使用真实本机查询验证这些分支，00:51:52.866的72项先通过（3.892秒，`/tmp/tokenlibrary-folder-search-full-client-tests.log`），加入可见移动入口后再次通过上述完整72项；修后搜索导航与移动入口原生复验另记，不由Shared编译与单测推断。

00:57新navigation包实际复验：点击搜索folder退出搜索/收键盘并进入目标，编辑器更多的移动入口可见，显式把分项还原的笔记移回原子目录且队列归零。独立四阶段证明原ID/正文/metadata不变，见[iOS层级恢复](ios-trash-recovery.md)。侧滑入口、移动失败和正在输入的flush分支不由这一更多菜单旅程自动推定通过。

01:01最新72项再次全过，编入详情常驻“保存资料信息”和摘录区固定footer，避免动态插入首section推移评论视口。01:07—10新包顶部保存作者后留当前详情、按钮禁用，短评论输入/删除位置稳定已由主验收实际复验；01:11只读确认仅作者字段保存、无摘录或队列，见[详情记录](catalog-inspector.md)。00:53:34前轮72项3.910秒日志仍保留，不把两个不同构建混作一次。

01:19:37.772的76项（跨度3.979秒、用例3.969秒）日志 `/tmp/tokenlibrary-legacy-launch-full-client-tests.log` 独立保留；新增验证目录只在明确Debug验证bundle/绝对路径下生效，Release与普通bundle忽略。01:25完整84项又纳入后台runner；真实系统后台调度仍未验，不将前后台切换或注入URLProtocol当作系统已调度。Core两项临时Keychain专项不计入此84项，也不改写此前218项完整运行的时间。

02:44追加：EditorHostLifecycleTests9项覆盖载入与保存失败回调、同文/旧会话身份和可重试内容保留；AppModel新增3项限制同步banner仅属于当前库，PDFReading新增3项检查空/非数字/超范围页码不再静默clamp。完整99项来自同一真实Shared编译与日志，不把此前84项与15项相加替代运行。原生已有U3复制和U6回看/删除记录不代表这三个修复的新包复验已通过。

02:46补充：在02:44完整99项之后，新增旧WK迟到flush不得覆盖新导航目标的第10个宿主测试，宿主专项10项于02:46:32.100通过；没有运行完整100项，不能把99全套与1专项相加写作完整100通过。02:51双端签名包已构建，原生范围仍按[宿主专项](editor-host-lifecycle.md)后续记录判断。

02:59宿主专项进一步覆盖中文错误分类，13项于02:59:56.675通过，完整套仍以02:44的99项为准，不写作103项完整通过。02:56—57Mac独立缺index资源→真实WK失败提示→恢复同hash/签名→原生重试恢复正文和合法续写已有[宿主限定证明](editor-host-lifecycle.md)，新中文文案仍待后续封包原生。

03:02最新完整103项已覆盖此前10/13项专项，前述“完整仍99”只描述各专项执行当时。原生证据不由这次完整模型运行替代。

03:07最新完整108项增加真实合成PCM/AAC文件时长/坏文件/短片段/完成回调5项，不创建AVAudioRecorder、不采环境声音。当前原生录音输入隔离限制与新收尾尚待封包范围见[U9专项](ios-recording-validation.md)。前述103与更早99仍为对应时点完整结果。

03:14完整111项已包含新增AppModel三项导航意图回归：明确搜索结果才携带hit/query，普通关联/来源/默认打开不触发旧搜索选区或旧PDF命中页。旧源码3项8个失败断言有日志，修复专项与新包原生范围见[导航验证](navigation-search-intent.md)。03:07的108项保留为之前完整运行，不代表后续原生UI。
