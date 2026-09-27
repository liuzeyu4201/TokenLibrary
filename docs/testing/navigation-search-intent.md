# 普通关联导航与搜索定位的区分

2026-09-27，iOS U7 原生旅程中，全局搜索 `U7Fixture20260927` 保持生效；从 A 详情的相关资料打开 B、再从 B 返回 A，均自动切到源码、选中搜索词并弹出软键盘。正文没有变化，但普通阅读跳转被当成搜索定位。

## 原因与本轮边界

此前 `AppModel.selectedId.didSet` 仅凭目标存在于 `searchResults`，便将全局 query 赋给 `navigationSearch`，PDF 还会请求命中页。来源/关联等 `openDocument` 与实际搜索结果选择没有区分。宿主初始化收到该词后调用既有 `tlFind`；JavaScript 对可编辑文档明确切 source、focus 并设置 selection。此行为并非本轮加载提示或排版增量更新引入。

本轮只修 [TokenLibraryRoot.swift](../../clients/Shared/TokenLibraryRoot.swift) 的导航入口：

- 普通 `selectedId` 赋值先清旧文字定位与 PDF 请求；相关、反链、来源、返回笔记继续使用普通 `openDocument`。
- `LibraryView` 保留现有 `NavigationLink`，仅把列表 selection 绑定路由到 `selectLibraryRow`；只有这个真实列表入口、当前有查询并命中有效资料时才传查询词与 PDF 页。
- 普通关联/来源跳转保留全局 query 和搜索结果，方便返回列表；显式来源链接的文件 hash 核验及页码请求保持。

没有修改 JavaScript、搜索内容或排序，也没有清除全局搜索来掩盖问题。从真正搜索结果打开笔记仍使用原有定位语义；本轮不把它重设计为被动高亮。

## 先红后绿与回归

03:13:23 的旧码运行三项真实临时 Store 场景，出现 **8 个断言失败**：关联双方误带查询；普通 PDF 打开误带第 1 页请求；显式来源及返回笔记也误带文字查询。原日志 `/tmp/tokenlibrary-navigation-intent-before.log`。这是代码路径复现，不是代替根任务的 iOS 实际操作。

新增三个 AppModel 入口回归并更新原来的普通打开语义测试：

1. A/B 已有关联，查询均命中；双方普通打开不传高亮，查询、结果、完整文档和真实待提交队列不变。
2. PDF 的实际正文搜索有页命中；普通打开不产生请求，显式文件 hash/页来源仍可定位，返回原笔记不继承查询，数据与队列不变。
3. 显式列表选择保留 Markdown 查询与 PDF 页/hash；同一个 ID 后续普通打开清理旧意图，再从结果选择可继续定位；取消选择、无查询的普通列表选择不会泄露旧定位。

03:14:09.025，完整 `clients` **111 项、0 失败、0 跳过**，跨度 5.784 秒，日志 `/tmp/tokenlibrary-navigation-intent-full-tests.log`。包含录音终结文件新增 5 项及宿主 13 项；Core 未改，最近完整 234 项结果不变。Root 产品 SHA256 `13379a506b45b03489419a35193d38c39d31d2f0059671e75a97674c5bf5e358`。编辑器产物仍 `313efa95337dc344a766f81e4e11d84ed12ced20372c97a58beb7ec9db7ea921`，未为未改动的 JS 重跑 Browser45。

截至这条记录尚未构建新包。原生需要核对：查询保留时 A→B→A 不再弹键盘/切源码；直接点击搜索结果仍能定位；PDF 关联普通打开不误跳旧命中页，明确来源页定位仍有效。不能从 SwiftUI 编译与模型通过推断列表绑定在原生导航中的全部行为已验。

## 03:17 合并封包

完整客户端 111 项通过后，Root 授权合并录音停止后实际文件时长校验。双端 build success、strict/deep 签名及 iOS application identifier 校验通过；126 个产品源文件构建前后 hash 一致。iOS 的 `IOSVoiceAudioBackend` 分支已由此次 UIKit 构建实际编译，尚未据此宣称真实录音权限/后台旅程通过。

- Mac：`/private/tmp/tokenlibrary-navigation-final-build-77newi2f/TokenLibraryNavigationFinalVerification.app`，独立 bundle `app.tokenlibrary.verification.navigationfinal`、新空白 base `/private/tmp/TokenLibrary-NavigationFinal-20260927-ov9kv52m`。主程序 SHA256 `f5081a8f1438c29214b0d4dca27389c78bb0ff3d8c90017827fcc9fcc0f840d0`，Debug dylib `ac58a9dcaa6191844662a83162529acaa9f5309483b5dc483f7782dbeb80ed20`。
- iOS：`/private/tmp/tokenlibrary-navigation-final-build-77newi2f/ios/DerivedData/Build/Products/Debug-iphonesimulator/TokenLibrary.app`，原 `app.tokenlibrary.verification` 更新包；主程序 SHA256 `805292b3603bc4aa88db420469175d3992952a7b79d8a070a5dd074453592707`，ZIP SHA256 `997abca91f05fb4f71224a6fe64f4be5ba5aa0e3f6c5139b900b45cccdd1c4bc`。

构建、签名与源码证明位于 `/private/tmp/tokenlibrary-navigation-final-build-77newi2f` 的 `verification.json`、`navigationfinal-verification.json` 和日志。`comparison-with-finalrecovery.json` 对照 03:04 包，明确只有 `TokenLibraryRoot.swift` 与 `StickyNoteEditor.swift` 两个产品文件变更；Core 和编辑器资源相同，未重跑未改动的 Core/Browser 套。此前准备的中文 Host 故障副本继续对应相同未变的宿主源码，不因导航/音频变化重复造故障包。

封包代理没有安装、启动、操作 GUI 或应用故障；Root 后续独立执行原生复验。旧封存包与已有原生证据均保留，未以此包名的 final 宣称全项目完成。

## 后续设计，未在本轮实施

可以把自动查询高亮与编辑选区分开：阅读层只装饰/滚动不 focus，排版层只增加搜索装饰、保留编辑选区；源码模式保持真实输入光标，通过明确“定位/编辑此处”动作才移动选区。仅删 `focus()` 但继续 `setSelectionRange` 仍会改变下一次续写位置，不能视为完整修复。该设计需另做真实键盘、输入法组合、模式保持和保存操作数回归，不混入本轮导航修复。

## 03:20—03:23 iOS 原生新包复验

Root已03:19:33安装并正常启动03:17包（iOS主程序SHA以805292开头、2707结尾），实际完成两条路径：

1. 全局query为U，真实结果打开C仍切源码、选U并显示键盘；切阅读后点C来源U7A，A以默认排版打开且无选词/键盘；点返回引用笔记C亦排版无键盘；返回搜索列表，query U仍保留。
2. 查询NavIntent20260927得到独立A/B两条；实际搜索A仍带查询定位/源码键盘。从A详情打开相关B、再从B详情打开相关A，均排版且无选词/键盘。返回搜索列表仍保留完整query和两结果，再点真实B搜索结果仍定位查询词/源码键盘。

原生准备的NavIntent A/B通过正式API新建/互相关联，无独立metadata.title/附件；四操作ID和完整API基线在 `/tmp/tokenlibrary-navintent-fixture-20260927/proof.json`，未改变U7已成功样本。

03:23:08独立只读 `/tmp/tokenlibrary-navintent-fixture-20260927/native-final.json`：NavA/B均rev2、U7A rev3/C rev2，服务器全部业务字段逐值等于相应before，四篇iOS working/remote与云端身份、父级、正文、revision和metadata精确一致。U7A/C已有本机before，工作行/remote完整行均不变；新NavA/B未在GUI前另取SQLite快照，因此不声称本机完整before存在，而以服务器完整baseline和两篇零本机operation确认无写入。全库668对象ID集合保持、queue0，全程Root未输入正文。

此段关闭iOS普通来源/返回与Markdown相关跳转不误沿用搜索、真实列表选择仍定位的限定修复。PDF普通关联打开不沿用旧搜索命中页仍有自动回归，未在本段单独做原生PDF分支；Mac对应原生与所有输入模式也不因此一并通过。源码/查询没有为通过测试而改成新的被动高亮设计。

## 03:35—03:36 Mac 普通关联与显式搜索复验

Root在`navigationfinal`新本机根正常登录53056并完整同步后，通过真正搜索结果打开NavIntentA；A详情相关B、B反向相关A均默认排版，无继承旧query抢选区/焦点。返回搜索仍保留查询，实际搜索结果仍按既有语义定位选中query；全过程没有输入正文。

只读`/tmp/tokenlibrary-navintent-mac-baseline.json`与`...-related-final.json`由本代理重新逐值比较：668份文档、5个被观察表、索引计数、29个本机媒体记录/字节SHA、所有冻结请求和可发送列表完全相同，snapshotSHA一致、sendable0。其边界是这份新Mac客户端的同库普通Markdown关联与显式搜索；iOS来源/返回入口已有前节证明，PDF普通关联与历史搜索页的原生组合仍单独验收。

## 03:43—03:47 同一 PDF 搜索结果重复激活的残余缺口

Root随后真实验证查询`Beta`、PDF `09237408-21fb-4b51-85f1-0649c5d60ede`：首次搜索行明确定位第2页，手动回第1页；打开相关Markdown再从资料详情普通打开PDF，仍为第1页，说明普通导航不继承查询已生效。但在PDF仍选中时再次点击侧栏同一条“第2页”结果，实际保持第1页。这一失败保留，不能用前面直接调用模型的成功测试代替真实列表重复点击。

源码检查：PDFReader已经监听带独立UUID的`pdfNavigationRequest`；直接再调`selectLibraryRow`也会发新请求。原生表现与`List(selection:)`同一值不必再次写入绑定一致，定位意图只接在selection setter上不足以表达重复激活。

窄修只让**当前已选中且有页命中的PDF搜索行**使用显式Button，其他行继续原NavigationLink。Button重新核验当前选择、查询命中和存储中的active PDF，发送新请求；phone紧凑导航同时选择detail列，支持从详情Back回结果列表后再次打开同一项。行的文字、路径、命中页和全行点击区域保持；不增加叠加TapGesture、不重置Reader实例、不改普通来源/关联入口。Reader只有实际呈现目标页后才按既有逻辑记录进度。

新增2项真实临时Store/实际三页PDF测试于**03:47:25.741通过，0失败，0.644秒**，日志`/tmp/tokenlibrary-repeat-pdf-result-tests.log`：

- PDF第2页实际文字索引命中，手动阅读进度已保存为第1页；重复激活产生新UUID，前一次回执不能清除新请求；普通同ID打开后再显式激活仍定位，query、结果、完整文档和真实queue不变。
- 已换选Markdown、已清查询但仍持有旧命中、底层PDF已删除但列表快照未更新时，重复激活不发请求、不写入任何内容或队列。

当次Root源码SHA-256 `dd31c2757582b6d470b41b8ebb9b85ed524c322aa886cd157b9358bc35fa6a26`，AppModelTests `da9e26158971212ceac4f2e7bb3106e343732245d61a58fa05e688fad3a7d020`。Shared macOS编译已通过专项，但本段尚未重新封包或操作GUI；新Button的原生重复点击与iPhone折叠返回/重开仍须实际复验。JavaScript未因这次导航改动变化，前一独立旧图alt修复的Browser51结果不被冒用为原生列表验证。
