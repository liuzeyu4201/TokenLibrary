# 原生界面验证记录

2026-09-26，进行中。此文只记录真实界面操作，不把编译、Core 自动测试或 Chromium 测试等同原生 UI 验收。

## 环境与隔离

- Mac：`app.tokenlibrary.verification` Debug 构建，独立临时资料目录、UserDefaults suite 与 Keychain service；未读取或修改真实资料。
- 应用：`/tmp/tokenlibrary-ui-apps/TokenLibraryVerification.app`，由 Computer Use 原生工具启动与操作。
- 测试服务器：`http://127.0.0.1:62036`，临时 PostgreSQL/文件目录，合成 e2e 账号。
- 19:14 恢复接续环境：62036 的真实备份已恢复到第三个 PG17 实例，最新应用服务为 `http://127.0.0.1:53056`。635 对象/620 文档和批注、关系、冲突表逐值一致，28 附件字节/hash一致，库 ID 保留、epoch 已更换；详见 [恢复证据](backup-validation.md)。随后 Mac 新 workspace 登录、PDF 阅读位置与批注跳页已实际执行，具体范围见下表。51525 是独立 Core 回归服务；三个服务均保留。
- Xcode 初始化组件已完成。macOS/iOS Simulator 两个目标构建曾均通过；每次后续修改需要重新构建，最终版本另记。
- 较早的 Computer Use 应用授权被拒绝；用户更新环境权限后，同一隔离应用路径已成功启动。因此当前不再将工具授权列为阻塞。

## 已实际执行

| 旅程 | 实际结果 | 处理状态 |
| --- | --- | --- |
| 首次启动 → 使用本机文档 | 初次点击仍停登录页；根 View 未订阅 AppModel | 已拆出 ObservedObject 会话路由，重启后真实点击进入空资料库 |
| 本机文档 → 新建笔记 | 出现列表项、编辑器和“待提交 1 项” | 通过该段操作 |
| 源码输入中文、公式、Mermaid | 原生 WKWebView 收到输入并显示“已保存到本机”，退出重开仍保留 | 通过 Mac 本机重启段；双端往返另测 |
| 阅读预览 | 中文和数学显示；Mermaid 初次仅有节点框，无文字 | 修复根级 htmlLabels 配置，Browser 加节点文字断言；Mac 重启后截图确认“书籍 → 论文 → 笔记”可见 |
| 连接地址没有 HTTP scheme | 显示完整地址要求、示例和重试登录 | 通过该错误路径 |
| 正确本机 HTTP 地址 → 测试连接 | 显示服务器可连接，不要求先填密码 | 通过该段操作 |
| 错误密码 → 登录 | 初次错误跳回离线库，有错误文字但无当前表单重试 | 登录错误与已有会话失效分开处理；Mac 复测停留表单，有错误说明与“重试登录” |
| 正确测试账号 → 登录和新建 | 进入服务器库，自动拉取资料；新建笔记进入队列后变成待提交 0 项 | 通过该段操作 |
| 资料详情 → 书目信息 | 保存中文标题、两位作者、年份、DOI 和标签；关闭后显示新标题，最终待提交 0 项 | 通过该段操作 |
| 资料库 → 专题与检索 | 创建“原生研究专题”，搜标题只返回目标文档；设置专题成员与在读状态 | 通过该段操作；筛选扩展和双端展示另测 |
| 摘录 → 新建阅读笔记 | 原文引用、个人理解分开保存；生成笔记并同步 | 通过该段操作 |
| PDF 导入 → 阅读 | 系统文件选择器导入三页中英合成 PDF，原文可选、页数正确、同步完成 | 通过该段操作 |
| PDF 搜索 → 高亮 → 改文 | 查找 Research Anchor Beta 得到 2 个匹配，高亮写入、管理列表编辑中文批注成功；SQLite 只有 1 条记录 | 稳定 ID 原位更新后重启复测，改文字后的 AX 只有 1 条高亮，页面黄色位置正确 |
| PDF 摘录 → 来源笔记 | 将第 2 页选区及个人理解存为阅读笔记，页号与文本正确 | 新版排版链接保留 ID/hash；实际点击打开同一 PDF 第 2 页 |
| PDF 页码跳转 | 页码输入 3 → 点击“前往” | 页面滚动到第 3 页，“下一页”禁用 |
| 原生批注 → 系统导出 → 系统预览 | 添加中文/英文/emoji 备注，系统保存面板导出 native-annotated-export.pdf；在系统预览真实打开并查看第 2、3 页 | 高亮准确，备注完整可读；独立 pypdf 严格解析 11 流、Poppler 3 页零警告，恰好 1 高亮+1备注，输入及库内原件 hash 不变 |
| Markdown 文件夹导入 | 系统选择含笔记/media的文件夹，选择 research-notebook.md | 图片与文字同步成功，原生阅读中公式、流程图节点和图片均已目视可见 |
| Markdown → 系统 ZIP 导出 | 保存 native-research-notebook.zip | ZIP 包含正文、metadata.json、相对 media 图片；图片 hash 与输入一致，外部编辑器完整往返另测 |
| 新建文件夹 → 改名 | 创建文件夹并通过重命名弹窗改为“原生移动验收” | 列表显示正确且待提交归零；随后阅读笔记已实际移入此目录并改为“移动后阅读笔记.md” |
| 真实备份恢复 → 新 workspace 登录 → PDF | 原生登录 53056 恢复实例成功，PDF 恢复至第 3 页；批注列表两个真实记录，高亮跳转回第 2 页 | 通过 Mac 这一段；第二客户端、图片/来源往返和同地址旧队列协调尚未据此验收 |


| 49,745,911 字节 PDF 原生导入 | 系统 Open 导入 large-near-50mb.pdf，自动同步至待提交 0；打开显示 8 页和实际 RGB 图像 | 输入、本机原件、服务器原件、独立 HTTP 下载四方 SHA-256 一致；来源证据 `/tmp/tokenlibrary-native-large-file-proof.json` |
| 大 PDF 末页检索 | 搜索 Large PDF Anchor 8 | 唯一命中，自动跳转 8/8，图像正常；工具调用耗时不能当作精确 UI p95 |
| 来源与笔记往返 | 点击排版中的来源进入 PDF 第 2 页，再点击“返回笔记” | 返回同一原笔记，正文保持 |
| 目录移动与改名 | 右键阅读笔记 → 移动到原生移动验收 → 打开目录 → 改名 | 新目录显示移动后阅读笔记.md；正文与来源保留、同步归零 |
| 维护时编辑 → 自动续传 | 隔离 53056 test/backup/begin 后源码追加中文；本机保存、待提交 1、有维护/不可用原因和重试入口，最近成功时间不变 | end 后 ready=true、maintenance=false；无需点击重试，自动待提交归零，新增文字保留。22:22 实际验证，仅测试库维护标志 |
| 归档 → 搜索 → 继续编辑 | 资料详情归档；正文改为阅读模式、排版/源码禁用；主搜索“维护验收”仍返回含已归档标识的笔记 | 点击继续编辑恢复原正文与排版控件，归档标识清除并同步；专题其他成员的 UI 状态另测 |

批注列表已在新构建核对：每条批注独立页号、编辑、颜色、删除按钮均出现在 AX；点击高亮的第 2 页按钮准确跳转。底部状态已移出内容区域，侧栏可滚动至完整最后一行。移动目录选择器也改为整行可点；22:47 新构建通过 AX 点击可见目标行，成功移动 PDF。

22:20—23:20历史环境状态（23:27已恢复，见后文）：iPhone 17 Pro / iOS 26.5 已启动，隔离 bundle 安装和启动成功。Xcode 27 的 Device Hub 通过 Computer Use 按路径、bundle ID、名称及 Finder 启动均暂时返回 timeoutReached，尚未取得可操作的模拟器 AX 窗口；这不是应用测试通过，也不是用户审批缺失。继续排查并保留 iOS UI 全旅程未验收状态。Device Hub 是当前 Xcode 的模拟设备入口，见 [Apple 官方说明](https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub)。

操作证据位于本线程 Computer Use 返回的 AX 树与截图；本文不声称尚未执行的旅程已通过。

## 扫描件本轮发现

22:28 实际导入 scanned-no-text.pdf，导入完成后自动打开，1页图像与无文字层说明正确；但稍后查找 RasterOnlyAnchor 命中1处，暴露系统 Live Text 与应用检索范围不一致。已按原件文字快照修正，22:31 新构建原生复测 RasterOnlyAnchor 为零匹配并解释无文字层；中文备注添加/同步成功。随后普通 PDF 查找 Research Anchor Gamma 唯一命中第3页，高亮成功。

22:33 通过实际右键删除 scanned-no-text.pdf，活动列表移除；进入回收站并点击还原后重新出现、同步归零。此次暴露回收站未显示保留截止时间、空页无解释且还原按钮 AX 被行合并；已补保留期/空态和独立按钮，22:37新构建复测：空回收站显示30天说明；删除“原生移动验收”文件夹后，父目录与阅读笔记各显示截止日期和独立按钮；先点击笔记还原，仅笔记回到根目录且同步成功，父目录仍在回收站；再还原父目录，回收站清空。打开笔记正文、维护期间新增段落和来源链接均保留。

22:35 资料库组合筛选原生通过：起始2026/结束2020被明确拒绝；修为2026—2026并限定测试作者甲后只显示目标1项；不存在作者产生空结果和清除入口，清除后恢复622项资料。输入后需观察状态并提交焦点，快速连续AX替换可能仅改变原生字段显示，不应当作应用已接收输入。

22:40 受控服务无响应旅程：只对经端口/可执行路径核实的隔离53056服务进程SIGSTOP，外部脚本带180秒自动SIGCONT兜底。原生追加“超时验收”段落显示本机已保存/待提交1；退出并重开应用后该段与队列保留，来源PDF第2页及批注可离线打开。重试预算结束显示“连接超时／服务器未在规定时间内响应／检查网络和服务器运行状态后重试”，最近成功时间未变化。随后显式释放测试暂停，ready=true、maintenance=false；22:40:38 原生已自动补齐为待提交0、资料与附件已同步，新内容仍在。本例是服务器无响应，并非断网或connection refused。

22:47 PDF 移动/改名与来源再验：将 research-three-pages.pdf 改为“移动后的三页研究原文.pdf”，再经右键“移动到…”进入原生移动验收目录；同步归零。点击原笔记中的旧来源链接仍打开同一 PDF 第2页，返回笔记回到原来的根目录及同一正文。书目原文件名仍为导入快照；不会为了改名重写历史引用标题。

22:44 最新状态文案构建在 Mac 实际运行：有会话且空闲显示“服务器资料库”，无错误时按钮为“立即同步”；避免超时情况下仍声称连接成功。22:41 macOS/iOS 两目标构建退出码均0。

22:45 补试 Xcode 的 Run：已实际显示“Running TokenLibrary on iPhone 17 Pro”，但随后 Computer Use 绑定 Device Hub 仍5秒 timeoutReached，尚未取得 iOS 可操作界面。本次只证明 Xcode 启动成功，未证明 iOS 用户旅程。

22:49—22:50 会话闲置过期：仅将53056指定原生session的last_seen_at设为90天1秒前。原生自动出现“需要重新登录”，原笔记仍可编辑；新增“会话过期验收”句后本机保存、待提交1。Quit/重开后正文与队列保留，最近成功仍为22:48:54；重新登录同53056后22:50:31自动归零。独立比对：旧会话仍过期且未被复活，新session为260c1b59-cd0b-4dbb-b7c8-c1b7b529e497；笔记本机/云端revision10、全文SHA256一致。证据见[控制与核验](native-session-conflict-control.md)及`/tmp/tokenlibrary-native-session-expiry-proof.json`。

22:50 原生图片按钮暴露缺失WKUIDelegate：旧版点击无面板；新回调后系统“插入图片”面板可打开并选择夹具。随后排版模式仍未生成图片/Markdown，正在独立修复编辑器图片节点解析；此时不能标插图完成。

22:52 原生PDF拒绝：加密样本显示需要打开密码及另存副本的正确原因；损坏样本恰逢后台同步完成，错误被connectionError共用字段清掉。已将本地操作错误与同步错误拆开，待新构建复测完整三类拒绝与错误持久展示。

22:54 设置页暴露导航死端：工具栏NavigationLink替换详情后缺少返回，换选侧栏仍停设置。正在改为可关闭辅助窗口，保留原选中笔记。

22:59 同段冲突完整段：原生创建独立笔记并同步base版本，退出登录后把同一段改为mac；辅助API按冻结base提交remote，正常注销辅助会话。原生重登后标记冲突。新版整行点击打开比较页，实际显示mac/remote；展开源码差异，显示共同base分别变为两者。手动输入mac + remote后保存，冲突列表显示“没有待处理内容”；完成关闭后回同一选中笔记，正文正确、待提交0。只读独立核对两端revision5及完整SHA256一致，本机pull_merge为resolved且三份材料保留。见[专项核验](native-session-conflict-control.md)。这不替代第二原生客户端或服务端冻结请求冲突分支。

23:00 新构建三类PDF拒绝复测：系统文件选择器分别选择损坏、需要密码、55,998,421B合法超限PDF，各出现对应中文原因；当前笔记和队列不变。损坏提示出现后手动同步成功，最近成功时间前进，但错误仍可见、按钮仍为“立即同步”；关闭本地操作错误提示后消失。超限提示又经历自动同步后仍保留，截图核对显示正确。

23:01 辅助页面返回复测：设置完成关闭、空回收站Escape关闭、冲突处理完成关闭，均回到原选中的同段冲突笔记及相同正文，不再停留无返回详情页。

23:02—23:04 插图与外部导出：Mac最新构建中通过“图片”→系统面板选择fixture-diagram.png，排版显示图片、已保存到本机并同步归零；源码有相对media路径。Command-Z只撤销图片且保留所有原文，Command-Shift-Z恢复图片并同步；再次打开面板后Cancel不产生新提交。已目视实际图像的中英文三步图。图片alt仍被上游序列化为缩放比例1.00，已记录并继续修复，不能据此宣布L30完成。

23:04 实际保存native-source-note-with-image.zip（53,926B），CRC通过，包含正文、来源说明.md、metadata.json和50,786B图片；图片SHA256与输入一致。使用VS Code已有Markdown Preview Enhanced实际打开解包正文，图片完整可见；点击相对来源说明链接，在外部预览读到来源标题、第2页、hash、Research Anchor Beta原文和独立个人评论。明确说明原PDF未随包复制、tokenlibrary链接需原资料库，不宣称外部可直接跳原PDF。证据`/tmp/tokenlibrary-native-source-export-proof.json`。

23:09—23:14 专题交叉组织：创建“原生交叉专题”，把同一“移动后阅读笔记.md”加入该专题和“原生研究专题”，全库仍623项；交叉专题仅1项。右键“移出此专题”后该专题为空，研究专题仍含该笔记。重新加入后删除交叉专题，确认文案明确保留成员；全库仍能搜索到笔记和来源PDF。回收站还原交叉专题后，两专题关系均保留。独立本机/云端核验：交叉专题8454d8dd-f52d-4f55-abf8-6d7b52aeed8c为active/revision3，笔记revision17、两topicIDs无重复，正文/图片hash与23:05基线一致、未提交0。证据`/tmp/tokenlibrary-native-topic-proof.json`；物理子文件迁移、并发删除及iOS不在本段证明内。

23:14 阅读位置提示复现：同一Mac在资料详情手动记录第1页，返回笔记再打开第2页来源，旧构建误称“另一设备读到第1页”。另从来源首次定位第2页后，详情的本机位置仍可能是旧第3页；定位期间PDFKit通知被忽略，正在修复保存与动态提示，不把画面跳页正确等同持久阅读位置正确。

23:15—23:17 PDF批注：在管理列表把第2页高亮改为蓝色，点击其页码打开PDF，截图及AX均确认蓝色/azure Highlight，正文未改变。删除此前为验收创建的第3页Gamma高亮后，仅该行消失，原第2页高亮与第3页中文/emoji备注保留。删除按钮因多个同名AX元素，两次按元素定位失败；根据新截图精确点击该行成功，正在补带页码/类型及稳定ID的无障碍标签。

23:17 图片兼容与重启：23:15 macOS/iOS两目标构建均成功；Mac实际退出换包重开后，原`![1.00]`图片仍显示完整三步图，富文本AX描述为“图片”，单纯打开没有自动改写旧源码。随后在源码填写“阅读、思考与保存的流程图”，切回排版后图片AX名称保留该中文描述。一次工具逐字输入未完整输入中文，立即用完整源码设置恢复并核对全部原段落；不把工具输入失败当成应用保存失败。新描述跨下一次应用重启仍待复核。

23:18—23:19 可搜索关系与摘录选择：相关资料选择页列622项，按“原生移动验收”目录搜索唯一目标PDF，行内同时显示标题、文件名、目录与类型。选择并添加关系后，再搜索该目录为0项，避免重复关联。点击关联打开PDF，原文详情显示反向关联；从原文一侧移除后关联行消失。随后在PDF资料详情填写Gamma原文、独立评论及第3页，在614项可用笔记中按“移动后阅读笔记”文件名找到既有笔记，追加后回同一笔记，旧摘录、图片及新第3页引文/评论同时显示，待提交0。PDF阅读器自己的“摘录到笔记”选择页仍须另测。

23:20 Device Hub环境恢复尝试：通过系统活动监视器正常退出已确认PID48637的Device Hub，随后只读进程检查确认旧进程消失。重新通过官方app路径启动仍返回5秒timeout，未取得可操作iOS窗口。未退出其他服务、未重置模拟器或修改系统安全设置；继续只读分析新进程，不将iOS构建或启动当成UI验收。

## 23:21—23:38 双端原生增量

- 23:21 Mac PDF阅读器“摘录到笔记”第三个搜索选择入口：Alpha第1页选区追加到既有阅读笔记，连续两次点击保存仅一条摘录。23:23独立本机/服务端验证原笔记revision23、3个不同摘录ID及每段正文恰好一次、图片/原PDF字节一致、两条原批注保留、未提交0；证据`/tmp/tokenlibrary-native-excerpt-annotation-proof.json`。
- 23:22—23:26 重复导入同PDF生成research-three-pages.pdf与research-three-pages_1.pdf两个独立UUID，均填写相同测试DOI。默认检索保留归档PDF；仅归档筛选只返回归档项；单独恢复PDF后专题仍归档，未级联改变成员。625项资料未因专题关系重复计数。证据`/tmp/tokenlibrary-native-duplicate-archive-proof.json`。
- 23:26 macOS/iOS两目标构建成功；客户端全套38项0失败/跳过（2.691秒）；浏览器23:11全套25项0失败/跳过（21.504秒）。这些是当时冻结代码，不替代随后便签与资料详情改动的重验。
- 23:27 Device Hub恢复：通过活动监视器正常退出已核实的旧进程，Finder直接打开原Xcode安装包内的已签名DeviceHub可执行文件，NSRunningApplication进程标识恢复有效，取得iPhone17Pro/iOS26.5模拟器的可操作AX与截图。此前timeout环境问题已解决，详见[诊断](devicehub-process-diagnostic.md)。没有重置模拟器或修改系统保护。
- 23:29—23:30 iOS原生测试连接成功，错误密码显示可重试中文原因且保留表单。正确密码在旧未签名验证包中报Keychain错误，securityd实读为-34018（缺application-identifier/keychain-access-groups），不是生产凭据或用户授权问题。重新构建签名验证包、更新安装后23:35登录成功。未降低Keychain安全或清空凭据。
- 23:31 Mac退出/重开后，图片保留中文描述“阅读、思考与保存的流程图”；来源第3页→返回笔记→来源第2页后，本机阅读记录详情实际为2/3。
- 23:34—23:35 Mac当前第2页时，手动记录新位置第3页，返回立即显示“手动记录在第3页”，没有自动跳页。点击保持当前页后提示消失，手动同步刷新后不再出现同一提示；同页重复记录因无变更不更新时间。继续阅读及跨设备新记录仍在继续实测。
- 23:35:49 iOS首次全库同步显示“资料与附件已同步”、待提交0。主搜索覆盖为624/625项正文可检索、1份PDF无文字层；打开原阅读笔记，全部摘录段落与三步图实际可见，PDF原文及中文/emoji批注可打开。
- 23:38 iOS来源定位发现新问题：稳定截图明确点击Beta第2页链接后，PDF仍显示1/3；手动页码前往3则成功并显示第3页正文。已交修复，不把能打开PDF当作来源定位通过。Device Hub当前没有暴露部分导航栏/WK内容的AX，相关动作以新截图坐标执行；不据此声称VoiceOver通过。

23:39 Mac保持第2页时，接收iOS手动前往第3页的新记录后显示“另一设备读到第3页”，自身仍第2页；点击“继续阅读”才变为3/3，提示随之消失。这是两端原生阅读进度到达/选择继续的真实操作，独立持久数据仍另核验。

## 23:40—次日00:07 双端输入、升级与文件闭环

- 23:40—23:49 iOS实际新建、改名“iOS原生同步验收.md”，软件键盘录入并同步；切换正确英文键盘后 `hello world` 的空格、换行均保留。此前拼音候选提交被误看成空格问题，经输入历史核对排除；没有用只改变AX显示的 setValue 作为正文输入证据。独立三方 revision37/body hash 一致，Mac只打开排版未产生本地改写，见 `ios-text-input.md`。
- 23:51—23:54 iOS便签实际输入文字、选择合成测试图片、填写说明并调整次序。最终图像→文字两块，图片说明 `diagram \n` 与文字末尾 `end \n` 保留。23:57独立三方 revision60/hash/附件一致、队列0；原来源笔记未改动。次日00:02升级后的实际重新打开仍显示完整图片、说明和正文，图片与文字AX可辨识。见 `ios-notes.md` 与 `/tmp/tokenlibrary-ios-sticky-image-proof.json`。
- 23:55 Mac资料详情在470px宽度实际核对长字段上下排列；手动记录、本机自动记录、其他设备记录是三条独立AX。新手动第1页建议出现时当前第3页保持，点击继续阅读才到第1页。此前另一设备第3页到达、当前页不被覆盖的旅程仍成立。
- 23:55签名iOS验证包更新导致模拟器应用数据容器路径再次变化。修复已按当前数据库登记的相对附件路径恢复PDF与持久草稿路径，并补7项路径隔离/跨版本回归；不以重下载或清空库掩盖问题。23:57真实打开原PDF成功，点击Beta来源首次准确到第2页；23:58详情本机2/3，同时保留Mac1/3与手动1/3。详见 `ios-container-relocation.md` 与 `pdf-reading.md`。
- 23:59 iOS实际打开49,745,911B、8页大PDF，首图正常；点击另一设备继续阅读到8/8；搜索 `Large PDF Anchor 7` 唯一命中并到7/8，提交后键盘自动收起。原件下载hash已有独立核对。本段不能证明峰值内存、1000项UI p95或真机性能。
- 次日00:02 Mac正常Quit后更新23:56构建，重新启动保持原库、资料与附件已同步/待提交0。当前两端包含IME保护、便签保留空白、PDF来源定位与容器路径修复。冻结代码最新自动回归为Core204、客户端51、编辑器29，全通过且无跳过。
- 00:03 iOS点语音触发真实麦克风权限请求，选择不允许后显示“媒体未完成：没有麦克风权限，请在系统设置中允许录音后重试。”可关闭并继续编辑，无新空语音块。成功录音/后台收尾尚未据此验收；避免采集真实环境音，另行确认模拟器输入隔离。
- 00:04原来源笔记导出：先打开fileExporter并取消，Files仍空；再保存“移动后阅读笔记.zip”，应用显示文件已导出。00:05在Files实际解压得到4项（正文MD、来源说明.md、metadata.json、media），来源说明系统预览显示页号、原件hash、引文及独立个人评论；PNG在外部图像预览中完整显示。来源PDF本身不随笔记包复制。
- 00:06—00:07经iOS“含附件的Markdown（选择文件夹）”系统选择器授权上述解包目录，应用列出两篇MD，选择正文后生成“移动后阅读笔记_1.md”，原件和新副本都可搜索且已同步；新副本图片实际显示。提示明确说明仅复制图片/音频、其他普通相对链接保留原地址（本例含来源说明链接），未虚称这些文件全部被带入。此段是用户可执行的导出→Files解包→目录导入闭环，独立三方数据核验另记。

## 2026-09-27 00:09—00:25 原生故障恢复与导入补齐

- 00:09/00:10旧iOS包两次点击“Markdown或PDF文件”均无系统选择器，目录入口可用。定位同一视图两个fileImporter呈现冲突；统一单个presenter，以请求ID/文件与目录模式路由，取消清理且迟到回调不串库。新增5项回归，完整客户端56项通过；00:17新签名iOS包安装后实际复验。
- 00:11导入副本归档后进入阅读模式，排版/源码禁用；搜索结果仍显示并标已归档；点击继续编辑恢复排版与原图。三方新副本dc40… revision3，归档/解档三版正文hash不变，原de82…仍revision23；见[iOS导出回导证明](ios-export-reimport-proof.md)。
- 00:13:15仅让53056当前iOS会话按90天规则过期，原笔记保持可读，显示服务器库离线和重新登录说明。00:14通过真实软件键盘新增独立文字块 `offline saved\n`，待提交1、最近成功固定00:13:14；独立检查云端与Mac仍revision60。
- 00:15经Controls→App Switcher→关闭“TokenLibrary 验证”，只读进程确认退出；经系统搜索重开，离线队列1与最近成功时间仍在。00:16本机全文搜索 `offline saved`唯一命中；00:17重开便签保留图像、原文字和新第三块。正常连接同一服务器重登后00:17:23自动待提交0；独立三方revision61/body hash完全等于离线pending快照，原两块、图片、元数据不变，新块仅1份；旧会话保持过期。见[精确控制与证明](native-session-conflict-control.md)。这验证认证过期，不称为实际网络断开。
- 00:19新iOS导入器实际呈现系统picker；取消不报错、待提交0，马上重开可用。选择合法research-three-pages.pdf后自动打开3页、同步成功，生成独立research-three-pages_2.pdf（afecb79c-e124-4869-bbff-a72bafcbb684），原件保持74791B及输入hash。
- 00:20损坏PDF被明确拒绝，随后点立即同步成功仍保留本地导入错误；加密PDF提示需解锁另存副本、原件未改；00:21超限55998421B合法PDF提示50000000B上限。三份拒绝样本无文档/排队/附件登记或实际媒体残留，见[pdf-import](pdf-import.md)与`/tmp/tokenlibrary-ios-pdf-import-proof.json`。Mac当时换包等待钥匙串，未把未收到新PDF写成同步失败或三方成功。
- 00:23单文件导入offline-mermaid-latex.md成功；WK阅读模式实际显示书籍/论文→研究笔记→个人档案的流程图，行内平方公式及积分块正常。富文本首次图预览曾显示正在绘制，正在另行核对，不把阅读模式成功等同所有编辑状态通过；离线冷启动另验。
- 00:24新导入器切换目录模式仍正常，选择voice-synthetic-2s.md带入纯合成2秒WAV，原生便签显示时长和说明；点击播放后按钮为停止，结束后自动回播放。样本无麦克风采样，此段只证明导入/播放状态与附件路径，未证明成功录音或后台收尾。
- 00:18新Mac验证构建因签名身份变化触发旧Keychain条目授权；00:21只读线程采样确认AppModel.init同步SecItemCopyMatching等待，导致窗口不响应。系统安全界面不允许工具控制，未通过清凭据/改ACL绕过，正在修复先呈现离线库与异步会话恢复。此构建不能仅因build成功写成Mac原生启动通过。

## 2026-09-27 00:26—00:41 冷启动、批注与凭据等待

- 00:26:50仅暂停隔离53056服务进程，00:30:49看门狗自动恢复，实际239.123秒；PG和监督进程未停。00:28在App Switcher关闭iOS验证应用后重新打开，本地列表可见且能聚焦搜索，最近成功时间仍00:26:43。00:30:50自动同步成功、队列0。没有在暂停截止前打开新公式/音频，因此这两项不记离线通过，也不称物理断网；见[iOS服务无响应记录](ios-unresponsive-recovery.md)。
- 00:32在iOS独立副本`research-three-pages_2.pdf`查找Research Anchor Beta，到2/3页，第1/2处匹配；点击高亮成功。管理批注改绿色，再用真实软键盘追加文字，最终为`Research Anchor Beta iOS`（系统将ios自动纠正为iOS）。批注ID为`cef58e16-ad79-42d3-8464-0af09ad894f5`，点击页码实际返回第二页。
- 00:33清除选区、前往第三页，添加`iOS 第三页备注 🧪`，当前页蓝色备注可见且待提交归零。独立iOS/云核验revision7、两条唯一批注，第二条ID为`76ccd9a3-07e6-4c13-a952-9f4caa798294`。输入/iOS/云原件均74791B、hash一致，见`/tmp/tokenlibrary-ios-native-pdf-annotation-baseline.json`。
- 00:34通过系统fileExporter保存到合成Files目录，显示文件已导出；00:35系统Spotlight最近文件打开`research-three-pages_2`，QuickLook实际可见第2页绿色高亮和第3页蓝色中文备注。独立Poppler渲染中文字及emoji正确，但严格解析发现iOS PDFKit输出的xref存在缺失对象标为in-use的问题，且丢失/NM；正在修复，不能把外观可读记为导出结构全部通过。
- 00:36—00:37在同一PDF查找Research Anchor Gamma唯一命中第三页，摘录到新阅读笔记，实际软件键盘填写独立评论`mobile note`。新笔记显示引用、来源第3页和“我的笔记”；阅读模式点击来源实际到3/3页，工具栏返回笔记后原笔记重新打开。这一段不改动此前de82来源笔记。
- 00:38 Mac换入`tokenlibrary-credential-recovery-build-4rfmv37z`新签名包，系统凭据等待期间立即进入原离线库；实际打开旧阅读笔记，正文、图片及来源可见。随后新建`未命名_1.md`，实际输入中文并显示已保存到本机，待提交1；点击停止等待立即退出等待状态，内容与最近成功00:18保留。
- 00:40 Mac正常Command-Q退出（只读进程确认已退出），重开并点击新笔记，排版中完整保留“凭据等待离线验收／系统凭据等待期间，本机仍可阅读与写作。”及待提交1。只读持久化证据`/tmp/tokenlibrary-macos-credential-wait-offline-proof.json`：新ID`7c47c749-a05d-49d6-b1f1-4ea379ea2e39`、仅1条对应pending createMarkdown；没有改ACL、清凭据或操作系统授权窗口。恢复云会话仍须系统完成授权，本段不虚称已经重新同步。

## 2026-09-27 00:42—00:54 离线内容与层级回收

- 00:42:45仅暂停53056隔离服务进程，iOS验证应用实际关闭后冷启动。00:43在本机搜索并打开合成公式/流程图笔记，排版模式显示完整Mermaid节点与连线；00:44阅读模式可见同一流程图及两条行内公式，00:45滚动后块积分也正常显示。此包包含异步预览修复，原生结果与32项浏览器结果分开记录。
- 服务仍暂停时，界面明确提示连接超时、检查服务器并可重试；最近成功固定00:42:31。00:45:35打开已下载的合成语音便签，播放按钮变停止并自然回到播放；没有采集环境声音，不据按钮状态宣称听觉验收。00:45:48只读进程仍为暂停态。00:45:57经独立看门狗提前恢复，00:46:21界面自动同步成功、队列0，没有手动点重试。
- 第二轮只读证明位于`/private/tmp/tokenlibrary-ios-unresponsive-oz36jwh6/content-recovery-proof.json`：两篇正文、metadata和assets仍revision1且与首次基线相同；iOS/服务器实际WAV均176444B、SHA256相同。见[有界无响应控制](ios-unresponsive-recovery.md)，不将服务暂停描述成物理断网。
- 00:46—00:51在iOS原生创建并重命名外目录`iOS层级回收验收`、内目录`论文资料`和`iOS层级移动恢复笔记.md`，逐层进入与返回正确。搜索folder后点击仍停留搜索结果的问题已复现，已修复共享导航清理query/退出搜索，72项客户端模型通过；当时运行的00:37包尚无此修复，原生换包复验另记。
- 00:52:54将合成内目录移入回收站，目录及其笔记均显示保留至2026年10月27日00:52。00:53单独还原笔记后回收站只剩目录；主搜索结果显示笔记位于Library根目录，打开源码仍为`# 新笔记`。只读中间态确认笔记active/revision4/root，目录仍trashed/revision3、截止时间不变，正文hash与创建历史一致、队列0。
- 00:54单独还原目录后显示回收站空态。目录/笔记最终位置与移动回子目录仍另验。原生操作未永久删除资料；层级证明见`/tmp/tokenlibrary-ios-hierarchy-baseline.json`和`/tmp/tokenlibrary-ios-hierarchy-note-restored.json`，前者实际抓取于删除之后，删除前状态来自合成服务的历史记录。

## 2026-09-27 00:55—01:05 搜索导航、输入保护与PDF闭环

- 00:55安装`tokenlibrary-navigation-build-_mu7mypk`签名包，实际通过Spotlight启动原库。00:56软键盘搜索`ios`并点击合成文件夹，立即收键盘、清搜索并出现其子目录；进入恢复后的论文目录显示空态。普通笔记搜索打开与返回仍保留查询。
- 00:57笔记更多菜单已有可见“移动到…”；选择显示完整路径的论文资料后返回原笔记，搜索结果路径变为`Library / iOS层级回收验收 / 论文资料`，待提交0。层级四阶段证明[已归档](ios-trash-recovery.md)：原ID/正文hash不变、没有复制，单独恢复后父目录未自动拉回笔记，只有本次明确移动才改变位置。row同时提供命名AX移动动作；本段实际操作的是编辑器菜单。
- 00:58详情标题改为`iOS 资料编辑保护验收`，下拉关闭被阻止；完成弹出未保存提示，点外部取消后标题保留。年份填`abc`→保存并继续显示“未能保存”，表单仍在；改`2026`后保存关闭、重开，两值均保留。
- 00:59真实软键盘输入评论`draft`，完成明确提示尚未加入笔记，只允许放弃或取消返回；取消后评论截图/AX仍完整，再明确放弃成功离开。只读[详情证明](catalog-inspector.md)确认正文hash不变、仅title/year元数据变更，没有创建阅读笔记或摘录，队列0。首字输入时Form曾跳到作者/年份，已定位动态顶部Section插入并改稳定footer，另加顶部书目保存入口；修后原生结果另记。
- 01:01在原PDF`afecb79c-e124-4869-bbff-a72bafcbb684`通过原生fileExporter保存独立`Fixed.pdf`，未覆盖旧缺陷导出。01:02在Files最近项打开，系统Preview的1/3、2/3、3/3全部可读，第二页绿色高亮、第三页蓝色中文备注可见。独立实际产物84144B，严格索引/所有流通过，两个NM与本库metadata精确一致，原PDF74791B/hash未变，见[PDF结构回归](ios-pdf-export-serialization.md)。
- 01:03单文件选择器重新导入Fixed到论文目录，生成新ID`d77981c1-bbd3-4c84-9b91-d3ea1f77d954`；点击下一页实际到2/3与3/3，原件内嵌高亮/备注仍可见。管理列表只列本库新增metadata批注，原件自带两条不被变成可编辑记录；旧“暂无批注”空态文案误导，已改为“暂无本库新增批注”及原件保留说明，待下一包确认。
- 01:05从回导副本原生再次导出独立`Repeat.pdf`，显示文件已导出、队列0。独立严格检查、同ID不重复及iOS/server原件hash另由[PDF结构记录](ios-pdf-export-serialization.md)记录；没有以外观可读替代结构验收。

## 2026-09-27 01:07—01:13 表单稳定与回收站反向关联

- 01:07已安装并启动`tokenlibrary-catalog-footer-build-z_lq8xjq`；01:09在详情作者字段填写`Synthetic Author`，点击顶部“保存资料信息”后按钮变为禁用，详情保持打开。01:13恢复后重开仍显示原标题、2026及该作者。
- 模拟器软件键盘曾处于隐藏状态，01:10通过Device Hub的Device→Keyboard→Toggle Software Keyboard恢复显示，Capture Keyboard仍关闭；不是应用搜索失败。随后在评论框真实输入首字`D`、再输入`r`、逐字清空，四个截图均停留同一评论位置，未再跳至作者/年份；未创建阅读笔记。稳定footer修复已在实际应用验证。
- 01:11从A笔记（254e…）详情通过可搜索选择器精确选B PDF（afec…）并添加关联。数据只在A保存relatedID，B通过反向查询可见；不把反向可见写成两份边。
- 删除A所在的`论文资料`目录后，A、回导Fixed与目录一同进入回收站。01:12 B详情显示A名称、“已在回收站，关联仍保留。”和独立移除按钮；点击移除后该行消失，原Gamma阅读笔记回链仍在，队列0。
- 独立removed证明确认A仍trashed，只有relatedIDs清空；originalParent、批次、删除时间和到期时间完全不变，正文及两份PDF字节保持。此次在同地址53056新服务上实际覆盖了trashed parent元数据修改的服务端修复路径。01:13在回收站还原整个目录，空态出现；重开A详情相关区仍空，书目和已同步状态完整。证据汇总以[资料详情](catalog-inspector.md)及独立`/tmp/tokenlibrary-ios-related-trash-*.json`为准。

## 2026-09-27 01:14—01:19 动态字号与批注说明

- 在同一 iPhone 17 Pro / iOS 26.5 模拟器，经 Device → Accessibility → Increase Text Size 连续提高四档。实际逐段滚动资料详情，标题、作者、年份、整理、摘录输入及多行页脚均可读；顶部完成/保存入口保持可达。返回编辑器和目录列表后搜索、同步及文件入口仍可操作，长文件名视觉截断时 AX 保留全名。
- 大字体进入个人资料库与筛选表单：横向分类、统计、列表详情按钮可用，作者/年份/标签说明及阅读状态、归档、本机原件、排序均能滚动到达，没有观察到文字与控件重叠。取消筛选后通过相同菜单降低四档，计数回到零，截图确认恢复原字号。此段是四档字号布局操作证据，不宣称全部动态字号或 VoiceOver 朗读通过。
- 01:19 再次打开回导 Fixed.pdf，仍显示第3页内嵌蓝色备注；进入批注与摘录 → 管理批注，实际显示“暂无本库新增批注”和“原件自带批注仍保留在 PDF 中；这里管理在本库新增的高亮和备注。”新文案已在当前签名包复验。

## 2026-09-27 01:24—01:27 独立旧库混合根验收

- 通过 CUA 精确启动独立 `TokenLibraryLegacyCatalogVerification.app`，库路径为 `/tmp/tokenlibrary-ui-fixtures/TokenLibrary-Legacy-Mixed-20260927`，没有连接服务器或读取原验证应用凭据。启动即显示一项目录待恢复说明、默认根笔记、未知根笔记和原待提交1项；“当前库的根目录”可切换登记的A/B库根。
- A根保留原文件夹、待同步笔记和PDF，原件实际打开3页。PDF详情只显示A专题；摘录目标恰有两篇同名阅读笔记，分别显示根路径和`资料库 / A库课程`。搜索`A库课程`仅保留后者，选中后填写Alpha引文、独立评论与第1页，实际追加到子目录104并自动打开，未另建同名文件。
- 新笔记阅读模式来源链接实际返回A原件1/3页；PDF详情相关资料候选仍只有两篇A库笔记，搜索`B库`显示0项。取消后移除不可用`dddd…`关联，占位消失；“引用此资料的笔记”入口仍可打开104，来源摘录未被清理相关边误伤。
- B库、默认根与未知目录的笔记均实际打开，原正文可读；没有将未知父目录自动升级为可信根或静默移动。01:27正常Command-Q退出，只读进程确认旧库验收进程结束；再由同一精确路径重开，待提交3项保留，切A根→A库课程重开104，唯一引文、评论及来源链接完整显示。
- 独立只读证明`/tmp/tokenlibrary-legacy-native-proof.json`核对原103的operation ID、完整payload与请求字段保持初始值；104仅新增一个指定来源摘录，另7个对象完整保持，原PDF74791B/hash未变。101仅增加本机第一页阅读状态及清空已明确移除的relatedID。此段证明合成旧安装数据的正常启动和操作，不代替真实用户旧安装、跨版本同步或迁入服务器的全部旅程。

## 2026-09-27 01:28—01:32 PDF换版、来源保护与恢复

- 专属合成API会话按固定operation将B原件换成52,685B的合法第二版，保留旧blob和两条批注；脚本细节及回执见[换版控制记录](pdf-version-control.md)。iOS正常同步后首开为1/3，实际显示旧阅读位置版本不匹配、未自动恢复旧页码的说明。
- 查看待核对批注，两条旧高亮/中文备注文字、原第2/3页信息保留，并说明需在当前原文重新选位置、导出不使用旧坐标；没有前往旧页码按钮。实际翻到新版2/3与3/3，没有旧绿色高亮或蓝色备注覆盖。
- 原生fileExporter另存`Version.pdf`到Files合成目录，界面文件已导出/队列0；实际产物独立逐对象/6流严格解析与3页外部渲染通过，所有页0批注、无旧NM，详见专项proof。没有用截图代替文件结构检查。
- Gamma笔记原quote/comment不变。首次旧第3页来源打开新版显示“原文件已经变化，请核对原文；未跳转旧页码。”为排除当前恰在第3页，我将新版手动停在1/3→返回笔记→再次点旧第3页来源，结果仍1/3并保留同一说明。笔记详情的来源摘录另显示“来源版本已变化，位置待核对”，原引文与`mobile note`同时可读。
- 专属正常API恢复原blob及明确冻结的两条attached批注后，01:32旧来源重新准确定位3/3、原蓝色备注可见，版本警告消失；批注列表恢复第2/3页定位按钮且原文字/颜色保留。脚本没有把自动恢复attached当成产品行为。最终B revision12、Gamma revision1、原件hash及其他关系样本不变、队列0；见`complete-proof.json`和`rollback-convergence-proof.json`。

## 2026-09-27 01:19—01:35 iOS专题成员与可见操作入口

- 新建`iOS交叉研究专题`，将A笔记加入它及`原生研究专题`，全库633资料保持；新专题成员1项。01:21关闭新专题开关后新专题空态，旧专题仍含同一A；01:22加回，两开关恢复，正文/原目录不变。
- 旧Catalog行仅长按菜单提供删除专题，缺少直接可发现的操作按钮。补可见“更多”菜单，与原contextMenu共用动作，保留独立详情按钮和删除确认。01:33已由系统界面关闭旧验证App，安装`tokenlibrary-background-sync-build-04ezwz61`后从Spotlight实际启动，原库同步0；该包同时含F25后台runner，不能据启动成功推断系统后台已调度。
- 新包实际点击新专题更多→删除专题→“删除专题，保留资料”，专题列表只剩旧专题；旧专题中仍能打开A，排版正文`新笔记`保持。回收站只有专题和30天期限，没有A或Fixed；01:35还原后回收站为空，再进入专题列表恢复2项，新专题内仅1份A、作者/年份/已同步状态保持。
- 五阶段只读证明显示同一topic ID、A仅topicIDs按加入/移出动作变化，专题删除未删除成员；新Mac并发验证客户端也收到删除/恢复。没有借此声明旧版本物理子项或并发创建子项分支原生通过。专题证明见`/tmp/tokenlibrary-ios-topic-membership-proof.json`及对应阶段文件。
- 01:31另从新的空临时库正常登录Mac并发验收App，实际显示资料与附件已同步、待提交0。此独立客户端未读取或复制原Mac凭据，不代表此前旧Keychain授权等待已恢复。

## 2026-09-27 01:40—01:42 持续输入发现光标漂移

- 新Mac通过实际新建、改名与源码粘贴，创建独立`双端连续输入验收.md`（`c4d018fc-5b1d-4161-b2d7-ac7f3c4a31fb`），基准revision3，正文为Remote/Local/Tail三段。iOS同步后打开相同对象，将光标放在`Local: base`末尾；没有使用数据库写入或整体替换iOS正文模拟输入。
- iOS真实软键盘依次输入a（01:41:24.386）、b（29.597）、c（33.348）、d（42.469）。独立控制器以冻结revision3及同一operation正常提交仅Remote段改变，01:41:56.640收到committed revision8，专用会话随即注销；详见[交错控制](native-markdown-interleaving.md)。
- 01:42:01.925继续按e，原编辑器截图已同时显示`Remote: REMOTE-ccf40091a386`与`Local: baseabcde`，键盘保持打开，未切文档或主动移动光标。随后01:42:13.786/14.957/16.172继续按f/g/h，截图却显示新增字符位于`Tail: keep`后的新行。
- 01:42 Mac实际源码同步显示`Remote: REMOTE-ccf40091a386\n\nLocal: baseabcde\n\nTail: keep\nfgh`，证明不是仅iOS截图滚动造成的误判：字符保留但写入了错误位置。停止原定XYZ和末尾空白输入，保留失败对象原样，正在修复外部正文更新的光标映射；不得把本轮记为F12通过。

## 2026-09-27 01:43—01:52 iOS同段冲突、重启与真实键盘合并

- 新Mac通过正常UI创建`iOS同段冲突与恢复验收.md`（`2df4162f-225e-4dce-b774-55557ce43b27`），共同基准revision3为`Conflict: base\n\nKeep: unchanged\n`。iOS实际打开基准后在设置退出登录，仍可搜索/编辑原服务器离线库；软键盘追加`ios`后本机待提交1，Mac和服务器仍是共同基准。
- Mac正常源码输入`Conflict: basemac`并同步revision4。iOS01:45:57正常重登录同一53056合成服务，明确显示存在冲突；比较页面分别展示baseios/basemac，展开源码差异可见共同base与双方新增内容。点击稍后处理，经App Switcher关闭验证应用，进程检查确认退出；01:47从Spotlight正常重启后同一冲突仍可打开、双方原文和共同基准材料保持。
- 第一次合并框通过AX setValue显示`basemac + baseios`，但保存请求实际仍是原draft baseios。保留该次证据为输入自动化路径未确认，不能把截图变化算作自定义合并成功，也没有依据断言服务端改写了请求。原生TextEditor真实键盘路径另行复验。
- 第二次以revision5的baseios为共同基准，iOS正常退出后软键盘追加new形成baseiosnew，Mac正常编辑为baseiosmac并同步revision6。iOS正常重登录后再次出现同段冲突；在合并框实际聚焦第一段末尾，逐键输入mac，界面为`Conflict: baseiosnewmac`，随后点击保存合并内容，列表显示没有待处理内容。
- 01:51:30只读三方均revision7，正文精确为`Conflict: baseiosnewmac\n\nKeep: unchanged\n`。01:52 Mac换开另一笔记后返回、iOS重新搜索打开，都显示完整合并正文与未变Keep段、待提交0。两条已解决冲突仍保留历史三方材料；superseded历史操作不是待发送队列。阶段原始证据位于`/tmp/tokenlibrary-native-ios-conflict-2df4162f`。这证明实际软键盘自定义解决与未解决冲突跨重启保留，不替代editor_drafts故障恢复、服务器过期冲突或所有解决分支。

## 2026-09-27 01:53—02:00 源码光标修复后的iOS交错输入

- `tlSetMarkdown`原先直接替换textarea.value导致光标跳尾。修复按文本差异映射UTF-16选区，保留方向与滚动，覆盖远端正文和保存回执两条入口；有界行/字符差异与大文档回归已纳入38项全浏览器测试。双端构建与签名通过，编辑器资源hash为`aadd53ea0600d7d6be091800c106d66c33442234e87a3ee6e34e0d1f48ff61b2`。
- 01:53通过Mac正常UI创建新`双端连续输入验收_修复.md`（`f367d811-1434-40bd-8f16-d62df035ceb1`），初始三段基准revision3。旧c4d失败样本不重置。iOS经App Switcher正常关闭后安装新包，并从Spotlight实际启动原库；同bundle Mac更新仍在旧Keychain等待，已正常退出，未操作系统授权或旧凭据。
- 新独立`TokenLibrary 输入验收`客户端（verification.selection）01:56:19正常登录同一合成服务，从空本机库同步655对象/26当前附件；独立全库bytes/hash证明见[Mac首次同步](macos-initial-sync-proof.md)。该新登录不表示旧Mac授权问题恢复。
- iOS保持同一源码编辑器的Local末尾光标，01:57:46—49软键盘逐字输入abc。固定API操作01:58:00.809964提交Remote标记；01:58:01.263继续输入d时截图已显示`REMOTE-a27ec181720d`，Local仍baseabcd且光标在段尾。随后01:58:19—23输入efgh、33—38输入XYZ，全部在正确Local段；47.016输入空格、48.750输入Return。未在远端更新期间切文档、替换iOS全文或手动重新定位光标。
- 01:59两端实际换开另一笔记再返回，iOS源码完整显示Remote/Local/Tail，Mac源码AX也保留Local尾空格与额外空行。02:00:01三方最终均revision17、精确正文`Remote: REMOTE-a27ec181720d\n\nLocal: baseabcdefghXYZ \n\n\nTail: keep\n`，SHA256 `5e3f7f5818786abdaa79fae1a9bcbfaba1a3be5e81814e43aef09bde6da1f5bc`，可发送队列0/开放冲突0/恢复草稿0；旧失败样本revision12/hash不变。证明见[交错记录](native-markdown-interleaving.md)和`/tmp/tokenlibrary-native-typing-repaired-f367d811/final-proof-020001.json`。
- 本段证明iOS源码持续输入时远端更新及后续保存回执不再将末次输入移到尾部，双端重开内容一致；Mac持续输入与排版编辑另验，不能从此片段推定全部编辑模式通过。

## 2026-09-27 02:00—02:04 Mac源码方向的持续输入复验

- 在同一最新Selection Mac包正常UI创建`双端连续输入验收_Mac.md`（`8e158bae-b7a2-40e2-87dc-97a5019acdd1`），共同基准revision3，iOS实际打开相同三段正文。Mac源码Local末尾通过真实按键依次输入abc（02:01:35—37）、d（48.429）；固定API操作02:01:52.435提交仅Remote段改变。
- 02:01:54.609继续输入e时，Mac同一编辑器已经显示`REMOTE-c4e85fd90af3`与Local baseabcde，光标仍在Local段末尾。随后02:02:14—21继续fghXYZ、27.593空格、29.444 Return，均在Local原位置；没有切换文档、重新定位或整体替换正文模拟续写。
- Mac经另一笔记切回并查看源码，iOS也换开f367再返回，02:03:42完整Remote/Local/Tail保持、待提交0。02:04:09独立三方及双端remote缓存均revision17，正文精确`Remote: REMOTE-c4e85fd90af3\n\nLocal: baseabcdefghXYZ \n\n\nTail: keep\n`，SHA256 `f53506e66070caddef0995dc520be5d72420f2b148839cf08dad87aaf9533619`，可发送队列0/开放冲突0/恢复草稿0。
- `final-both-reopened.json`位于`/tmp/tokenlibrary-native-typing-mac-8e158bae`，另核对旧失败c4d、iOS修复f367和F13的完整server快照不变。源码双向原生交错输入已有通过证据；排版编辑的整篇替换另经浏览器实际键盘复现相似光标问题，正在修复，不将本段扩展为所有模式完成。

## 2026-09-27 02:04—02:11 Mac 千项混合资料库实际交互

- 独立 `TokenLibrary 千项验收`（`app.tokenlibrary.verification.performance`，PID 96587）经正常原生启动，Debug base 指向 `/tmp/tokenlibrary-ui-fixtures/TokenLibrary-Mixed1000-20260927`；未连接服务器。包沿用已封存源码选区修复资源 `aadd53ea0600d7d6be091800c106d66c33442234e87a3ee6e34e0d1f48ff61b2`，本轮不是尚在构建的排版选区修复包。
- 工具栏资料库实际显示 **1,000 项资料**，连续滚动显示后续行。`Research Anchor Beta` 命中 **199**、`MixedCorpusNeedle` 命中 **800**，密集结果继续滚动正常；`AbsentMixedCorpusNeedle` 显示无匹配及“本机正文可检索 1000/1000 项”的说明。`NoteTailMarker00799` 与 `Large PDF Anchor 7` 分别准确命中 **1** 项。以上来自真实搜索输入与 AX/截图，不由 SDK 查询结果代填。
- 打开“合成笔记 0799”，切阅读模式，连续滚动到末尾实际看见 `NoteTailMarker00799`。另搜 `NoteTailMarker00792` 唯一命中“合成笔记 0792”，打开并滚过 320 段长文，末尾合成图片、Mermaid“阅读→摘录→复习”、KaTeX 行内公式 `E=mc²` 与尾标记均实际渲染；全过程没有编辑正文。
- 打开“合成论文 199”（49,745,911 B），实际显示 **8 页**及真实图像。页内查找 `Large PDF Anchor 7` 显示“第 1 / 1 处匹配”、跳至 **第7页**并高亮，再滚动至 **第8页**。本机正常保存阅读位置使待提交从0变为1；这是一条离线阅读metadata操作，不清除队列或改写原件来伪造零变更。
- 02:05:12.961—02:15:12.970 独立只读采样按原定600秒结束，595点，主PID CPU累计31.89秒，RSS采样最高376.422 MiB、末值60.453 MiB；末段静置CPU中位0%、区间p95 0.993%。人工阶段仅分隔操作窗口，详见[性能记录](performance.md)及 `/tmp/tokenlibrary-native-perf-20260927-0204/report.json`。CUA返回耗时、人工窗口跨度、CPU/RSS均不当作输入到绘制 p95 或滚动帧时间；WebKit 子进程不在主 PID 统计内。
- 02:12:13最终只读proof确认1014对象（1000资料+14目录/专题）、201媒体共64,680,106B字节/hash全部一致；正文/原件/关系不变，唯一正常业务变化是大PDF第8页阅读位置及其pending操作。生成时基线由仍与manifest相同的原DB只读重建，明确不是补造GUI前现场快照，见 `/tmp/tokenlibrary-mixed-gui-final-proof.json`。
- 本轮夹具此前已用正式 Store 和 PDFKit 建立索引，不能描述为原生首次导入/首次同步索引。199份普通PDF共享一个合成内容模板；iOS千项库、真机内存压力及可靠绘制计时仍须独立完成。

## 2026-09-27 02:13—02:21 排版编辑双向交错输入修复复验

- 浏览器真实键盘先复现排版全文替换导致Local光标跳尾；修复改为ProseMirror局部文本/结构/格式事务并保留原选区映射。新增7项边界及完整Browser **45/45**通过，双端构建与签名完成，资源SHA `313efa95337dc344a766f81e4e11d84ed12ced20372c97a58beb7ec9db7ea921`。代码与测试细节见[排版选区专项](rich-editor-selection.md)。
- 新独立Mac `TokenLibrary 排版验收`（verification.richselection）02:13:27正常GUI登录53056合成服务，base为 `/private/tmp/TokenLibrary-RichSelection-20260927-gle7segd`。iOS经正常App Switcher关闭验证App、安装同bundle新包，再从主屏幕实际启动原库；没有复制凭据、操作系统授权或改写已有失败笔记。
- **iOS方向**：Mac GUI新建`双端排版连续输入_iOS.md`（`1aeacc7a-1a88-45f6-a0c9-d2b2e42052d0`），精确三段基准rev3；iOS实际切排版，在Local末尾软键盘输入abc（02:16:29.636/31.459/33.045）、d（45.741）。固定API操作02:16:51.411提交Remote标记，51.854输入e截图已显示`REMOTE-c17d63507e5a`及Local baseabcde。后续fgh（58.186/59.830/02:17:01.514）、XYZ（11.716/14.316/17.439）始终落在Local，未重新定位、切模式或替换全文模拟续写。
- iOS换开旧修复笔记再返回，Mac也换开其他笔记再返回，均显示完整三段。02:18:18.435858三方working/remote及云端均**rev15**，精确正文为`Remote: REMOTE-c17d63507e5a\n\nLocal: baseabcdefghXYZ\n\nTail: keep\n`，SHA `ad68f2eb221d4d447d7d4b7bc9e341385090109ef9751b3238f72d598ff92aa7`；末LF保留，无额外空格/空行。两端可发送0、目标开放冲突0/draft0，旧c4d/f367/8e/F13完整snapshot不变。证据 `/tmp/tokenlibrary-native-rich-ios-1aeacc7a/final-both-reopened.json`。
- **Mac方向**：GUI新建`双端排版连续输入_Mac.md`（`181fd9c9-7863-4219-8325-88e8f65a8024`），共同基准rev3，iOS实际打开基准。Mac保持排版Local末尾，真实按键abc（02:19:06.357/07.984/09.512）、d（19.016）、e（27.878）；固定API操作02:19:44.775939提交Remote并保留已输入abcde。02:20:03.666输入f时`REMOTE-049387f3a8c2`已实际显示，随后ghXYZ（10.369/11.812/13.363/14.934/16.361）仍在Local原位置。
- Mac切至iOS样本再返回，iOS也切另一笔记再返回，完整正文保持。02:21:21最终三方working/remote及云端均**rev15**，精确正文为`Remote: REMOTE-049387f3a8c2\n\nLocal: baseabcdefghXYZ\n\nTail: keep\n`，SHA `6b901c3d75273f831d8f50dcca6a6447b989f139c324f769e4f4f8b6e3106f25`。可发送0、目标开放冲突0/draft0；既有源码/F13四份及iOS排版1ae完整snapshot均不变。证据 `/tmp/tokenlibrary-native-rich-mac-181fd9c9/final-both-reopened.json`。
- 源码和排版的双向不同段落交错续写已有原生闭环；排版输入没有额外空格/LF，所以不把它冒称源码空白保真测试。复杂嵌套/同段冲突/恢复草稿和全部编辑组合仍按专项与总账限定，不能由这四个续写样本宣布所有编辑路径完成。

## 2026-09-27 02:21—02:32 iOS 千项混合资料库实际交互

- 独立 `app.tokenlibrary.verification.performance.ios` 在 iPhone 17 Pro / iOS 26.5 模拟器从主屏幕正常启动，使用全新离线容器和合成千项库，未复制服务器会话或修改原验证应用。编辑器资源为已封存排版修复 `313efa95337dc344a766f81e4e11d84ed12ced20372c97a58beb7ec9db7ea921`；该包早于附件路径别名修复。安装前证明见 `/tmp/tokenlibrary-ios-mixed-installed-proof.json`。
- 资料库实际显示 **1,000 项**并滚动三个列表屏幕；搜索 `Research Anchor Beta` 为 **199**、`MixedCorpusNeedle` 为 **800**并继续滚动结果。`AbsentMixedCorpusNeedle` 显示无结果及本机正文可检索 **1000/1000**；`NoteTailMarker00799` 和 `Large PDF Anchor 7` 各 **1** 项。查询来自实际原生输入和界面观察。
- 长笔记0799切阅读模式，实际滚动至 `NoteTailMarker00799`。另打开0792，最终截图完整显示合成PNG、Mermaid“阅读→摘录→复习”、KaTeX `E=mc²` 与 `NoteTailMarker00792`。快速批量长距离拖动之后曾短暂出现空白，后续新截图恢复内容；本轮没有帧时间计量，不能描述为全程无白屏或已证明流畅。
- 49,745,911 B 的合成论文199正常打开8页；PDF内查找 `Large PDF Anchor 7` 命中1/1、跳到第7页并收起键盘，实际触摸滚动至第8页，下一页按钮禁用。阅读位置正常落盘产生待提交1项；未编辑正文或清除离线队列。
- 主PID1563采样按计划 **02:21:53.401—02:31:53.416** 自然结束，600.016秒/595点，CPU累计40.21秒、区间中位0%/p95 28.764%，RSS采样最高591.297 MiB、末值141.656 MiB。末段约264秒CPU中位0%/p95 1.979%；02:27—28另有后台双端构建，02:31:49误提前做过0.667秒只读媒体证明，均如实列入环境边界，不称纯空载。数据见 `/tmp/tokenlibrary-ios-native-perf-20260927-0221` 和[性能专项](performance.md)，只代表模拟器主进程，排除WebKit子进程，不能当作真实设备内存、绘制p95或帧率。
- 确认采样结束后02:32:23最终只读 `/tmp/tokenlibrary-ios-mixed-after-capture-proof.json` 证明1000资料/201媒体64,680,106 B的正文、revision和原件hash全保持；200个PDF路径由正常启动迁移到当前容器。当前文档索引605页，历史缓存1210行含迁移前605行，不能误报为新增PDF。唯一业务变化是大PDF第8页、readingStatus及对应本地generation/status和一条pending操作。原始媒体与非阅读metadata保持。
- 这是预索引合成库在独立模拟器的真实UI旅程，不能替代首次同步索引、真机资源压力或连续滚动绘制指标。

## 2026-09-27 02:32—02:39 本机资料显式复制到服务器

- 新独立 `TokenLibrary 附件验收`（`app.tokenlibrary.verification.attachmentpaths`）由空base `/private/tmp/TokenLibrary-AttachmentPaths-20260927-5n35ttq3` 正常启动，包为 `/private/tmp/tokenlibrary-attachment-paths-build-1wl4gsv9/TokenLibraryAttachmentPathsVerification.app`，含已回归的附件路径别名修复。GUI选择使用本机文档，新建目录“本机迁入验收_20260927”，经系统文件选择器导入74791B合成三页PDF并重命名“本机迁入论文”，再新建“本机迁入笔记”。
- 实际源码输入 `LocalTransferAnchor20260927` 和中文说明，通过图片按钮/系统选择器插入50786B合成PNG，阅读模式实际显示图片。第一次AX点击源码后粘贴未获得正确焦点，工具超时且正文未变；截图核实后用真实正文位置聚焦再输入成功，没有将失败操作当成已保存。PDF详情输入Alpha引文、`LocalTransferComment20260927`、第1页，选择已有笔记并加入，生成唯一摘录与版本绑定的来源链接。
- 02:35正常登录53056合成账号，服务器库搜索唯一标记显示无结果，证明连接没有自动迁入。本机完整基线 `/tmp/tokenlibrary-u3-local-baseline.json` 保留3对象、2媒体及3个原pending ID/payload。目录ID `14213195-8187-428f-827a-c6fd00eb4e42`、笔记 `c9cc4b2f-829c-419e-8c3f-d7a3c3a97af1`、PDF `fd7f897a-4a41-474e-82bb-b51a5fa9bb4d`。
- 设置明确说明保留原件、重复复制生成新副本。02:35:54只点击一次“复制本机资料到当前库”，待提交3后归零，新目录及两资料出现。服务器副本阅读模式图片、引文、评论完整，实际点击来源返回PDF第1/3页；切回本机再次打开原笔记，图片/原文保留、原pending3不变。本机界面错误地残留服务器“资料与附件已同步”提示，已记录并进入修复，不将本段称为提示体验全部通过。
- iOS原验证应用02:37恢复前台后正常同步，唯一标记命中1篇，实际打开图片、引文和评论；02:37:54点来源定位服务器副本1/3页。该打开新增正常iOS阅读metadata，不改本机原副本。
- 四方只读证明 `/tmp/tokenlibrary-u3-after-copy-proof.json` 与 `/tmp/tokenlibrary-u3-ios-copy-proof.json` 核对source/目标Mac/服务器storage及HTTP200/iOS的PNG与PDF bytes/hash一致。合法且无冲突的三个文档UUID保留，目录父级转为服务器根，附件换新blob：PNG `fb50b8a3-2318-4e6b-a381-e2cecdad7ff9`，PDF `8a2a9c7b…`（完整ID见proof）。笔记只改图片路径，唯一摘录、来源ID、pageIndex0、原件hash与评论保留。源库3对象/2媒体/3原操作完整逐字段与基线一致；目标可发队列0。Mac暂停在本机时PDFrev2与服务器对应历史一致，iOS随后rev3包含新增设备阅读记录，不能把这项正常变化误判为复制差异。

## 2026-09-27 02:38—02:42 iOS 回读位置与单条批注删除

- 原服务器大PDF `2e8f590b-c345-4634-b34e-b493d98e8489` 的实际GUI从第7页前往8，再输入2前往第2页；打开另一笔记再重新搜索打开PDF，实际恢复2/8，没有选择另一设备保留的第8页记录。基线 `/tmp/tokenlibrary-ios-backward-page-before.json` 保留原49,745,911B、hash `dd66f1e4375fe2f588f1cf8abc9f6d522c52f739154e93be9d9ae0ff130ef104`。
- 手输页码99后点击前往，旧包静默截到8/8、未提示超范围，**此边界未通过**。已通过GUI返回2/8，修复有效范围提示及保留当前位置后另行复验，不能把“没有崩溃”当作正确输入处理。
- 在第2页新增唯一合成备注 `U6DeleteOnlyThis20260927`，蓝色备注实际显示；只读 `/tmp/tokenlibrary-ios-delete-annotation-added.json` 核对rev9、唯一ID `560239e0-404b-477e-93eb-03f84493d416`、pageIndex1/同pdfBlobId。进入管理批注，命名删除按钮只移除此条，出现“暂无本库新增批注”。离开PDF返回列表后重开仍2/8，页面无蓝色测试备注。
- 最终 `/tmp/tokenlibrary-ios-backward-page-after-delete.json` 为rev10、annotations为空、可发队列0，原件bytes/hash及非阅读metadata不变；原另一设备第8页记录逐字段保持，iOS自己的记录为第2页。该PDF原先没有本库批注，所以此段只证明新增唯一备注的删除/重开持久性，不冒称混有其他批注时的全部删除组合。

## 2026-09-27 02:43—02:48 PDF 批注恢复草稿与真实同步失败

- Mac附件验收包通过系统文件选择器重新导入合成PDF，正常命名 `U4恢复草稿验收.pdf`，对象 `a49ba379-2ce2-421e-a004-f0489df8c2f7`。GUI新增第1页蓝色备注 `U4_BASE_20260927`，annotation ID `02122104-5d08-4c7e-914f-f57cd7113ff0`，共同基准rev3、blob `7a63f5d1-0929-4f71-90d2-21da3e6b1e65`；原74791B/hash同合成三页PDF。只读 `/tmp/tokenlibrary-u4-annotation-baseline.json` 保留完整基线。
- Mac进入管理批注→编辑文字，实际聚焦、全选并粘贴 `U4_LOCAL_20260927`，保持表单未保存。iOS正常同步后打开同一PDF/同一条批注，在文本末尾真实软键盘依次输入i/o/s，再保存，得到 `U4_BASE_20260927ios`。Mac正常同步至rev4的远端文字时原本机编辑表单仍保留LOCAL。
- 02:46 Mac点击保存，明确显示“批注未能写入当前文件，文字仍保留”；`/tmp/tokenlibrary-u4-annotation-conflict-draft.json` 确认真正产生一条 `editor_drafts`（`pdf-f2d6053652254e6239be589b45d30930941d393bd504079f4a329e8aef26c297`），保留共同BASE、本机LOCAL和原PDF版本，当前原件仍是iOS文本。没有用sync_conflicts或数据库写入代替这条路径。
- 取消编辑框、关闭管理页后正常Command-Q退出，精确进程检查确认结束。02:47从同一签名包路径重开，正常恢复原连接；冲突与恢复草稿入口仍列出该PDF及具体原因，详情实际显示第1页LOCAL文字。`/tmp/tokenlibrary-u4-after-restart-draft.json` 逐字段核对草稿与退出前完全相同。
- 02:47:49点击“恢复为新副本”，草稿列表变空，新对象 `e59b4a84-8d48-43dd-b20e-080c7b9f0dce` 本机实际显示LOCAL蓝色备注。然而上传出现 **HTTP500**，新对象仍revision0/等待同步1，故本段恢复同步闭环**尚未通过**。固定createPDF operation `21219ff2-c783-4a73-867a-e00620499cd1` 的原始冻结request与完整副本保留于 `/tmp/tokenlibrary-u4-recovered-pending-500.json`，未改请求、清队列或覆盖原件。
- PG日志确认错误为 `annotations_pkey` 重复，恢复副本沿用原annotation ID，而旧服务端错误地按全局ID设主键。当前所有批注读写已按文档作用域进行，正在补文档范围身份与旧库迁移回归；后续须用这条原冻结请求正常重试，并实际跨端打开副本后再判通过。

## 2026-09-27 02:54—02:57 编辑器资源缺失与原生重试

- 独立离线 `TokenLibrary 编辑器故障验收`（`app.tokenlibrary.verification.editorhostfailure`）使用 `/private/tmp/TokenLibrary-EditorHostFailure-20260927-xzvepsap`。正常GUI建笔记 `d42c2586-06e6-4d2c-b8ff-1ea162c00897`，源码保存 `HostRetryBaseline20260927` 和中文正文，然后进入新建空目录离开编辑器。基线 `/tmp/tokenlibrary-host-resource-baseline.json` 包含两个文档与两条原待提交完整行。
- 仅对运行中的一次性副本PID8185，带路径/PID/资源hash守卫的控制器02:56:37暂移唯一`index.html`。重新从GUI打开原笔记实际显示“编辑器暂时无法打开”“编辑器未能载入：The requested URL was not found on this server.。已保存笔记仍在本机。”及“重试打开”，没有无限空白。此英文底层文案和双句号另记改进，不将其描述为理想中文反馈。
- 02:56:54恢复相同资源字节（SHA `875609f2c49a01c62ccbd5f1a9452505c7ed27fc4b583dbbecc0e2b8f31cd9e3`），原签名重新通过，没有重签或操作系统权限变更。故障后只读 `/tmp/tokenlibrary-host-resource-failure.json` 证明所有文档/待提交完整行与基线相同。实际点击“重试打开”后原标题和中文正文完整渲染。
- 随后源码编辑保存带 `RetryContinued20260927` 的完整正文，`/tmp/tokenlibrary-host-resource-after-retry.json` 精确核对落盘文本、原文档ID和待提交仍2。第一次尝试快捷键追加未定位文末，实际插到标题中，随后明确全选保存已核对完整文本；不把该操作描述为选区恢复通过。最后控制器status确认HTML原hash和签名完好，正常Command-Q退出。
- 本轮验证实际本地导航失败→可见错误→恢复资源→原生重试→继续保存；不覆盖WebKit进程崩溃或尚未送到原生层的最后输入恢复。资源移走期间只操作既有运行进程，没有重启失效签名包。

## 2026-09-27 02:57—03:01 原失败恢复副本重试与跨端读取

- 服务端同URL53056于02:57:33完成批注复合主键升级；升级核对业务表、42媒体、library/epoch和全部会话身份不变，未要求客户端重新登录或改写原失败操作。专项见[pdf-recovery-annotation-identity.md](pdf-recovery-annotation-identity.md)。API/synceng/merge39项及含旧备份恢复迁移的jobs11项通过。
- 原冻结createPDF `21219ff2-c783-4a73-867a-e00620499cd1` 由已有同步机制自动重试成功。03:00:02只读 `/tmp/tokenlibrary-u4-after-server-fix-proof.json` 证明operation ID、payload、request_json原字节、createdAt/base/generation保持，只变正常发送状态；Mac可发0、草稿无。原PDF仍rev4及 `U4_BASE_20260927ios`，副本rev1及 `U4_LOCAL_20260927`，同annotation ID按不同document独立存在，原74791B及SHA保持。
- 03:00 Mac附件验收原窗口实际显示恢复副本“已同步”、待提交0、LOCAL蓝色批注。iOS从仍带BASE…ios的原PDF返回搜索，结果实际列出原件与恢复副本，03:01打开副本第1/3页并进入管理批注，实际显示 `U4_LOCAL_20260927` 和同annotation ID的管理控件。本轮没有新建替代副本、重置队列或把修复后请求换ID。
- 03:01:42最终 `/tmp/tokenlibrary-u4-final-three-client-proof.json` 证明Mac/iOS working与remote缓存及PG精确一致，原件rev4保BASE…ios、副本rev1保LOCAL，双端可发0/草稿无；四份客户端读取的PDF与服务器均74791B及原SHA，旧冻结操作有服务端receipt。
- 这是原失败PDF批注恢复路径的自动重试与跨端读取闭环；不扩展为所有草稿丢弃/远端删除/进程崩溃组合均已验证。

## 2026-09-27 02:52—03:00 新PDF下载故障与旧资料持续可用

- 新 `TokenLibrary 恢复验收`（verification.recoveryui）正常GUI登录独立合成服务51350，原三资料和PNG实际可读；新base `/private/tmp/TokenLibrary-RecoveryUI-20260927-jl5wiwpd`，基线 `/tmp/tokenlibrary-u5-native-baseline.json`。02:57:56只给尚未同步的新blob临时返回503/Retry-After1，正常API发布 `U5 新PDF下载恢复 5dfb8c97.pdf`，原三文档和既有附件未注入故障。
- 原生界面实际显示“服务器暂时不可用”、本机数据保留和“重试同步”，最近成功停留2:57:51；新PDF未提前出现。旧笔记PNG继续真实渲染，源码经GUI保存原正文及 `U5NativeDuring50320260927` 后显示本机已保存、待提交1。中途工具输入内容有异常，核对后通过实际GUI改回完整合成预期，再取证；不把错误输入或中间状态当作产品保存失败。
- `/tmp/tokenlibrary-u5-native-during-503.json`证明精确正文落盘，newPDF不存在；sync_state按key映射与基线相同（cursor4），不能用无排序SQL返回数组顺序误判游标变化。02:59:20清除故障，02:59:31客户端自动恢复，在准备点击重试时按钮已变“立即同步”，因此本轮成功路径明确是自动重试。
- 随后GUI新增PDF行、待提交0、资料与附件已同步；实际打开第1/3页，中英Alpha文本完整。旧笔记仍有PNG、原文和新标记。最终 `/tmp/tokenlibrary-u5-native-final-proof.json`确认云/本机同revision和精确全文，cursor6/sendable0，新PDF74791B与原SHA、旧PNG及全部4媒体云/本机字节hash一致；目标请求15次503后1次完整200。HTTP200截断的完整校验另有自动专项，不混称本轮原生验证。
- 03:00用同新包从服务器切回本机，服务器成功banner立即消失；新建本机笔记实际出现“正在打开笔记…”加载反馈，随后正文正常显示；底部“本机文档／待提交1”没有残留服务器“资料与附件已同步”。该本机笔记未显式复制到服务器。

## 2026-09-27 03:03—03:04 Mac 外观选择持久性

- recoveryui独立副本设置中把“跟随系统”改为“夜晚”，完成后正常Command-Q，精确路径进程只读确认0，再从同一签名包正常GUI重开。设置实际显示夜晚Value1、跟随系统Value0，并维持深色界面；不是仅依赖系统当前深色截图推断偏好持久。
- 切“白天”实际观察设置白底深字，再恢复原“跟随系统”并完成；未更改系统外观或用户真实应用偏好。本轮限定外观选项/重启保持，不能替代错误对比度量、VoiceOver朗读或完整键盘焦点顺序。

## 2026-09-27 03:05—03:08 iOS 新包升级与非法页码复验

- 原verification App经Device Hub的App Switcher正常关闭，03:05:27 `simctl install` 安装 `/private/tmp/tokenlibrary-final-recovery-build-qb9eifvv/ios/DerivedData/Build/Products/Debug-iphonesimulator/TokenLibrary.app`，从主屏幕正常启动并恢复原会话/资料。mainSHA `b53b3721d043a7b34f41dc5d229a6bb89b825a5ab257950441f40b874c308a4e`，资源仍313efa…a921；含PDF缓存/host中文/页码输入修复，**不含后来录音收尾和导航意图区分修复**。新container为61CE6333-44E7-4BD1-A922-A5DD79A73085，仍是原库，不复制凭据。
- 打开原大PDF，实际恢复2/8。在页码框分别输入99、0、abc、超出整数范围的长数字、空值并点前往，每次明确显示“请输入 1 至 8 之间的整数页码；当前阅读位置未改变。”，没有静默跳到末页。重新输入有效2并提交后错误消失、键盘收起，仍显示第2页。
- `/tmp/tokenlibrary-ios-pageinput-new-baseline.json` 与 `/tmp/tokenlibrary-ios-pageinput-invalid-proof.json` 的目标working完整行及8条历史operation完整行逐字段相同，revision仍10；非本设备阅读位置也保持。不是只以UI输入框文字代替持久化位置核对。空输入的AX呈现为Value“页码”而非Placeholder，首次查找控件未命中后重新读状态定位，无资料操作。

## 2026-09-27 03:08—03:15 iOS 关联改名、组合筛选与摘录防重复

- 通过正式API准备的独立三笔记A/B/C由正常同步取得，文件名无单独metadata.title，年份2024/2025/2026、待读/在读/已读；A/B有完整标签`U7完整标签20260927`，C只有带“后缀”的不同标签。基线与操作回执 `/tmp/tokenlibrary-u7-fixture-20260927/proof.json`，准备不冒充原生新建。
- 全文搜索`U7Fixture20260927`实际3结果，打开A详情相关B，原生跳至B正文。将B改名 `U7B_改名验收.md`，B详情反向打开A，A详情相关行实际显示B新名并能再打开原B；之后从B只移除与A关联，关系行消失。03:10:54 `/tmp/tokenlibrary-u7-fixture-20260927/renamed-unlinked.json` 证明iOS working/remote与PG一致，A/B/C rev3/4/1，ID/正文SHA/sourceIDs/excerpts/父级保持，只改B名称及两端relatedIDs清空，全库666个ID不增减、queue0。
- 普通关联导航误继承全局搜索query，实际切源码并选词弹键盘；此体验问题已独立记录并进入显式导航意图修复，不将本段称全部导航体验通过。相关资料和正文身份正确，不用清除搜索词掩盖该现象。
- 资料库搜索同query为3项。iOS搜索激活期间系统隐藏顶部筛选入口，实际关闭搜索回646项后再打开筛选：先选完整标签后取消，仍646；重新选并应用得到A/B **2项**，C带后缀不误入；加年份2025—2026得到B **1项**，再加在读仍 **1项**；改待读实际空结果及“清除筛选”入口，清除恢复646，再重新搜索query恢复3。不能写成保持搜索激活同时操作筛选。03:14:11 `filters-final.json` 证明三篇working/remote/PG完整值等于前一proof，没有筛选引起资料改写。
- 从Catalog A详情真实软键盘输入`Doubletap`，键盘提交时正常纠正为`Double tap`，选择已有笔记C为目标；03:15对“加入所选笔记”使用实际双击（clickCount2），表单关闭并打开原C。页面实际显示C原文、单个`Double tap`引文块和来源`U7A_20260927`，03:15:42待提交0。03:16:40 `double-submit-final.json` 独立核对C仍原UUID、rev2，原正文精确prefix保留，只新增一个`> Double tap`和一个来源链接；excerpts恰1（`05509d5a-af35-4f6c-adf7-2031fb119a65`），sourceID为A、comment空。C只有一条sent update，iOS working/remote/PG一致；A/B完整值不变，全库666个ID无增减、queue0。

## 2026-09-27 03:17—03:18 中文编辑器加载错误复验

- 以新Host源码独立签名副本 `/private/tmp/tokenlibrary-editor-host-localized-t_mvkisg/TokenLibraryLocalizedHostFailureVerification.app` 正常启动，全新本机目录`/private/tmp/TokenLibrary-LocalizedHostFailure-20260927-ivvlxukl`。GUI建笔记保存`LocalizedHostRecovery20260927`及中文正文，再建空目录切离编辑器。
- 带精确PID13742/资源hash守卫的控制器03:18:12暂移唯一HTML，GUI重开笔记实际显示“编辑器暂时无法打开”“编辑器文件缺失或不可用。请更新或重新安装应用后重试；已保存笔记仍在本机。”以及“重试打开”；英文底层错误和双句号已消失，没有暴露本机路径。
- 03:18:26恢复原hash HTML并验证原签名，点击重试后原标题和中文正文完整渲染。`/tmp/tokenlibrary-host-localized-baseline.json` 与 `/tmp/tokenlibrary-host-localized-retried.json` 比较两个working行及两个pending完整行全部不变。最终status确认资源原hash、签名有效，正常退出该副本；没有在资源缺失时重启或重签，也不涉及系统权限。
- 此项复验限定缺资源中文错误与恢复，不外推到其他URL错误/进程终止；其余分类已有自动测试。

## 2026-09-27 03:19—03:22 搜索定位与普通关联导航分离

- 原verification App经App Switcher正常关闭，03:19安装 `/private/tmp/tokenlibrary-navigation-final-build-77newi2f/ios/DerivedData/Build/Products/Debug-iphonesimulator/TokenLibrary.app`，mainSHA`805292b3603bc4aa88db420469175d3992952a7b79d8a070a5dd074453592707`，从主屏幕启动恢复同库。该包比03:04包仅改Root导航意图和Sticky录音收尾，JS/Core相同；完整clients111项通过，126产品源构建前后保持。音频分支编译通过不冒充原生录音成功。
- 全局搜索`U`后直接打开U7C，仍按显式搜索行为进入源码、选中匹配并显示键盘。切阅读后点C中的来源链接，U7A正常打开默认排版，没有自动选词或键盘；点击“返回引用笔记”回C也保持普通导航。回列表搜索词`U`仍保留，没有靠清空查询掩盖问题。
- 独立API准备两篇NavIntentA/B（`a481192d-eba6-4483-9431-3168ae5ce75d`、`1bad5262-b746-4db6-9ee5-a7d4691a9742`），均rev2并相互关联，共同正文词`NavIntent20260927`，原668对象基线见`/tmp/tokenlibrary-navintent-fixture-20260927/proof.json`；没有重新加回U7已移除的关系。
- 搜索共同词实际两结果，直接打开A仍显式搜索定位；从A详情相关B跳转时B默认排版且无键盘/选区，再从B详情反向打开A也同样无抢焦点。返回列表保留完整query与两结果，重新直接点击B搜索结果仍进入源码、选中命中词和键盘。本轮全文未编辑。
- 03:23:08 `/tmp/tokenlibrary-navintent-fixture-20260927/native-final.json` 证明四目标服务器完整字段与Nav setup及U7前证据一致，iOS working/remote一致、queue0、全库668ID不增。U7A/C本机完整行保持；NavA/B没有GUI前的本机快照，按真实PG完整基线和零本机operation证明未编辑，不虚构SQLite before。
- 本修复只区分真正搜索结果与普通关联/来源/返回入口，不改变显式搜索的既有定位语义。PDF普通导航不继承旧搜索页有模型回归；本段不冒称所有PDF跳页组合原生完成。

## 2026-09-27 03:25—03:34 Mac 连接分类与文件失败重试

- 独立 `navigationfinal` 新包/本机目录 `/private/tmp/TokenLibrary-NavigationFinal-20260927-ov9kv52m` 的登录页，实际输入无效地址得到完整HTTP/HTTPS格式指引；未监听56171得到“无法连接服务器”及地址、端口、网络检查建议；改到56170健康端点得到“服务器可连接”。此只测试健康接口，没有向夹具登录或发送密码。
- 56170受控HTML200实际显示“服务响应格式不正确”“确认这里运行的是 TokenLibrary 服务”。相同错误envelope的426/PROTOCOL_UNSUPPORTED目前实际显示通用“服务器拒绝了请求／HTTP426”，因此已交付明确版本不兼容提示的窄修，不能把此旧包截图记为修后。真实服务426发生在同步协议检查，健康fixture只验证错误分类展示，不证明真实旧版本兼容往返。
- 登录页按Tab实际由地址到账号、密码、测试、登录，Shift-Tab反向回测试；此仅登录表单，不是全程键盘导航。测试连接后“使用本机文档”会残留连接提示，成功和426两种均实际观察，已交付 `useOffline` 清理修复，等待新组合包复验。
- 空Local库从系统文件选择器导入独立 `01-invalid-utf8.md`，准确显示“导入失败：Markdown 必须是有效的 UTF-8 文本。”；再导入 `02-missing-relative-png.md`，准确显示无法读取相对图片、检查附件与目录权限以及“笔记未被导入”。截图仍为空列表/待提交0；两份只读快照与空库基线全部相同。
- 随后重新选择 `03-valid-retry.md` 正常导入，实际渲染完整中文、emoji和结束锚点，仅产生一个文档 `eae97cc2-9f12-4918-b649-dcf2bb7d4b54` 与一个正常本机待提交。原文UTF-8含末尾换行精确保持，不以渲染文本代替字节校验。
- 导出选择新建只读 `export-denied-mode0555` 并实际点击Export，保存面板关闭，App显示“导出失败：You don’t have permission to save the file…”与具体文件名。这次确实进入应用failure回调；英文是当前系统错误原文，不冒称全部中文，也不是仅系统面板禁用按钮。重新走导出选择可写 `export-retry` 成功，错误提示消失；输出223字节、SHA `4bd7c0ad0ab9fd472578b27d1dd4492c8e2d3698e82da31751a204c3d3ebbfa1` 与输入完全相同，只读目录没有残留文件。
- 六时点 `/tmp/tokenlibrary-file-errors-native-{baseline,invalid-utf8,missing-png,valid-retry,export-denied,export-retry}.json` 和03:34:28汇总 `...-summary.json`：两次失败导入所有表、索引、媒体与基线相同；失败/成功导出所有表与合法导入后的基线相同。此为独立Mac Local的限定失败与重试，未访问原服务器库，不外推iOS保存提供程序行为。

## 2026-09-27 03:35—03:36 Mac 普通关联与显式搜索

- `navigationfinal` 在正常GUI使用合成账号登录53056，本机合法导入笔记仍留在独立Local，没有迁入服务器。同步取得668对象、29媒体，server库基线 `/tmp/tokenlibrary-navintent-mac-baseline.json`；未复制会话或改写客户端数据库。
- 展开主搜索输入 `NavIntent20260927`，实际两结果。直接点击A时进入源码并选中查询；资料详情“相关资料”打开B，默认排版、没有选词，窗口焦点没有被编辑器抢走；B详情返回A同样默认排版。搜索字段始终保留原query及两结果。
- 再次直接点击B搜索行，仍正确切源码并选中 `NavIntent20260927`。整个旅程未编辑正文或关系。
- `/tmp/tokenlibrary-navintent-mac-related-final.json` 与基线的全部业务表、索引、29媒体及整体snapshotSHA完全相同，queue0。此补齐Mac MD关联分支；PDF普通关联不误用旧命中页尚单列，不由此冒称已测。

## 2026-09-27 03:37—03:40 来源返回与连接/键盘修复原生复验

- Mac navigationfinal继续搜索 `U7Fixture20260927`，打开C并切阅读，点来源A实际默认排版、无选区；“返回笔记”回C也默认排版，查询保留。`/tmp/tokenlibrary-navintent-mac-source-return.json` 与03:35基线整体snapshotSHA相同，668对象、媒体、队列均不变。
- 启动新 `/private/tmp/tokenlibrary-connection-final-build-vk07tn8q/TokenLibraryConnectionFinalVerification.app`（connectionfinal，mainSHA `acd4954b76180801c13ec2117fe15921c7e1ed6fa7d0033b299b3002f9a9fbb4`，实际dylibSHA `279948986a1489368cdaedb432be3273cb389bc39367f6384c0201db91418f4e`；JS604deb…dfdd），freshbase `/private/tmp/TokenLibrary-ConnectionFinal-20260927-cp6d9fur`。包含源码Tab、useOffline清反馈及426分类修复；双端构建/签名与127产品文件无漂移证明在同构建目录。
- 测56170健康后进入本机，页面没有残留“服务器可连接”。新建一篇本机笔记后返回表单测试受控426，实际显示“客户端与服务器版本不兼容”“服务器不支持此客户端使用的同步协议。本机资料和待提交修改仍然保留。”“更新客户端或服务器至相互兼容的版本后，再重新连接。”；再进本机原笔记/pending1仍在，错误banner清除。最后恢复healthy，同表单再次成功；此仍是健康fixture错误展示，不冒称旧版真实服务协议互通。
- 新笔记源码写入 `KeyboardNative20260927`，真实Tab插入四个空格；Shift-Tab实际焦点移到“流程图”按钮，有可见轮廓，正文没有变化。从确认有焦点的源码区单独Escape再Tab，焦点离开编辑区到侧栏；`/tmp/tokenlibrary-keyboard-native-after-indent.json` 与 `...-after-exit.json` 的整体snapshotSHA相同，连pending完整行也无变。
- 再点击源码、Command-Right、Tab，末尾从四空格变成八空格，说明退出标志未使后续普通Tab永久失效。源码下方实际显示“Tab 缩进；Shift-Tab 向前移焦；Esc 后按 Tab 可离开源码区。”。初次AX点击textarea没有取得输入焦点，粘贴工具超时且正文未变；随后用截图中实际文字区域点击再输入成功，不把工具无焦点误认产品保存故障。
- 以上是原生WK键盘退出与有限焦点观察；不替代VoiceOver朗读、完整全键盘旅程或真实输入法组合。03:39:56随后正常GUI登录新的57143恢复夹具，Local键盘样本没有迁入服务器。

## 2026-09-27 03:40—03:45 真备份恢复后的原生保护与缺失资料失败

- connectionfinal通过GUI正常登录新隔离服务57143，实际读取原笔记PNG和三页PDF第1页；客户端baseline `/tmp/tokenlibrary-epoch-native-login-baseline.json`为4对象（含root）、2媒体、queue0。服务为独立PG17，身份/备份与恢复守卫见[native-epoch-restore.md](native-epoch-restore.md)，不影响53056等既有服务。
- 03:40:56仅新服务进入240秒维护。GUI分别在旧笔记与备份后新增笔记末尾追加 `EpochNativeLocalOld20260927` / `EpochNativeLocalNew20260927`，原中文、LF和PNG路径完整保留；显示本机已保存、待提交2及维护错误。03:41:52完整只读proof证实旧操作 `3cee5d08-7560-48f9-ba13-086bcf2381a8` 已冻结原epoch/base2，新增资料操作 `53fb108a-3497-416b-b2e5-d480adeebae8`仍未冻结；不声称两操作都曾发送。
- 03:42:48同URL真实还原较早备份，新epoch `bb6ca7dd-892b-406a-aee8-4d928316729c`、同library/root，首次重登前恢复库sessions0/operations0、原库完整保持、PDF/PNG字节不变。原生随后截图明确“需要重新登录”、服务器资料库离线、待提交2，所选新笔记正文和New仍在。AX外层曾保留旧503文本，以当前截图为实际错误证据，不将两种反馈混写。
- Root `/tmp/tokenlibrary-epoch-native-after-401.json`与维护时快照比对working/pending/media完全相同；catalog `...-after401-client.json`进一步核8业务表/原冻结字节/旧epoch与cursor4全部保持。03:44正常GUI重新登录后，两篇均标“存在冲突”，待提交0但banner明确需处理冲突；不是已完成同步。实际冲突列表有3行，新资料同名显示两次；完整proof对应旧epoch_changed一条，新epoch_changed与deleted两条，原材料均保留。
- 打开旧笔记比较：本机含CloudLater和Old，服务器为备份短文。实际点击“保留本机版本”，旧行消失；新operation `cd6f0aa1-5d34-4479-afc8-118ad06c29ee`使用newEpoch/base1成功提交rev2，旧冻结请求字节保持并superseded，PNG/正文完整。源库没有被修改；没有把旧请求换epoch重放。
- 打开新资料第一条同名冲突（使用截图坐标区分；AX重复标签导致一次定位失败），服务器侧显示“未命名”，本机完整New正文。实际点击“保留本机版本”后表单仍在，显示“请求未成功（HTTP404）”。此为确定未通过分支，已交Core修复与真实HTTP回归。03:46云端proof新资料仍不存在、无新receipt；03:47客户端proof正文/附件/两条open冲突/原未冻结operation均保持，没有丢资料，也不能写为恢复成功。

## 2026-09-27 03:42—03:47 PDF 搜索意图与分段键盘操作

- 正式API新增NavPDF笔记/PDF（`714c5b88-b64e-4082-af64-a8b951623059`、`09237408-21fb-4b51-85f1-0649c5d60ede`），74791B原三页PDF及双向关系基线在 `/tmp/tokenlibrary-native-navformula-20260927-ohu5jhca/proof.json`；其余668对象保持，新增不修改U4等已验样本。
- navigationfinal搜索Beta，显式PDF结果实际定位第2/3页；点页码框Command-A、键入1、Return实际跳回第1页。打开关联MD，再由详情普通关联打开同PDF，仍第1页且query Beta保留，截图证实没有继承旧命中页。阶段proof `/tmp/tokenlibrary-navpdf-mac-ordinary-page-one.json`。
- 当前已打开PDF第1页时，再直接点击侧栏同PDF的第2页搜索结果，实际仍第1页；这是另一个确定缺陷，已交显式重复激活修复，不能将本段记为全通过。切换MD后再点可见PDF结果，正常第2页，限定故障为同selectedID重激活。一次离屏AX点击失败后实际滚动目标再点击成功，不把工具离屏限制记为产品失败。
- 主搜索实际Command-A输入Beta，Tab到工具栏溢出按钮，Shift-Tab回搜索且Beta选中。PDF页码框Tab依次到“前往输入页码”“下一页”和PDF查找框，键入Beta、Return实际显示第1/3处匹配。这些是分段键盘操作，不宣称从启动到阅读全程无鼠标。
- 从批注菜单打开“文字备注”新建表单，实际输入 `KeyboardCancelOnly20260927`；Tab到取消，Shift-Tab回文本且未多字符，Escape正常关闭。`/tmp/tokenlibrary-keyboard-pdf-before-cancel.json` 与 `...-after-cancel.json`全部snapshotSHA相同（671对象/30媒体/queue0），没有新增批注或操作。该输入是短备注TextField，不冒称已验管理批注的多行TextEditor。

## 尚待完成的原生旅程

以下仅列尚未被本文限定证据覆盖的范围，已通过的Mac登录/维护/超时/过期/冲突、批注、专题与导出片段不重复标为全部未测。

- 双原生客户端同段冲突的比较/重启/真实键盘合并，以及源码/排版双向续写光标修复已按上文通过；PDF批注恢复草稿已按U4闭环；其余草稿类型、取消/丢弃、远端删除和编辑组合仍待。
- 单文件Markdown含失效相对媒体及导出保存失败重试边界；iOS带批注PDF修后原生导出、外部阅读和回导已按上文限定范围通过，严格产物证据独立记录。
- iOS专题、归档、目录、回收站和版本变化已通过上文限定片段；其余物理子项、并发、失败恢复和跨端组合仍按总账本逐项验证。
- iOS成功录音与前后台生命周期受合成/静音输入条件约束；合成WAV播放已有证据。公式与流程图的离线冷启阅读及双端千项渲染已有限定证明，继续编辑和双端写入往返仍按专项待验。
- Mac/iOS千项库准确搜索、长笔记与大PDF操作已按上文限定通过；两端可靠UI响应/帧时间、其余动态字号/VoiceOver/键盘顺序仍待；四档字号片段已按上文验证，模拟器结果不替代真机性能和系统后台调度。
- 旧安装升级、不同版本往返、备份恢复后本机未提交草稿协调及公网部署环境范围，以总账本逐项说明。

完整范围以[开发与验收账本](development-status.md)为准。
