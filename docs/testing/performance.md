# 性能实测与证据边界

## 当前Core完整回归中的测量

2026-09-27 **00:48:37—00:48:50**（Asia/Shanghai），macOS arm64 Debug，最新56881独立隔离服务和随机临时资料库。新增PDF序列化、异步凭据和资料关系恢复后的完整Core **218项、0失败、0跳过**，XCTest整套跨度 **12.695秒**（用例合计12.675秒），构建2.94秒另计。真实HTTP与Keychain均执行；日志 `/private/tmp/tokenlibrary-client-full-tests-20260927-final.log`。

| 测量 | 样本 | 本轮p95 |
| --- | --- | --- |
| 千条资料元数据筛选排序 | 30次，metadata查询 | **15.408 ms** |
| 千条混合中英文全文检索 | 100次，每次最多50个命中 | **2.004 ms** |
| PDF阅读位置保存 | 100次，提取计数1 | **1.461 ms** |

三个输出来自本次同一218项运行，没有另启性能负载。新服务仅供回归，未替换原生53056；这些数字不测网络公网时延、原生列表帧率、PDFKit渲染或真机资源。

## 23:59完整回归的前轮记录

2026-09-26 **23:58:55—23:59:14**（Asia/Shanghai），macOS arm64 Debug，既有51525隔离服务和随机临时资料库。加入路径迁移7项后的完整Core **204项、0失败、0跳过**，XCTest整套跨度 **18.439秒**，构建0.45秒另计。真实HTTP和Keychain均实际执行。固定日志 `/private/tmp/tokenlibrary-client-full-tests-20260926-235914.log`；完整命令与覆盖见 [客户端同步验证](client-sync.md)。

| 测量 | 样本 | 本轮p95 |
| --- | --- | --- |
| 千条资料元数据筛选排序 | 30次，每次准确返回220个不同ID | **17.612 ms** |
| 千条混合中英文全文检索 | 100次，每次最多50个命中 | **2.027 ms** |
| PDF阅读位置保存 | 100次，提取计数1，重开复用缓存 | **1.419 ms** |

沿用下方说明的测试方法，三个性能输出来自本次同一204项运行。没有另启负载、复测53056或把历史UI截图工具时间换算成性能结果。

## 23:41完整回归的前轮记录与测量方法

2026-09-26 23:40:47—23:41:03（Asia/Shanghai），macOS arm64 Debug，随机临时资料库。完整Core **197项、0失败、0跳过**，XCTest整套跨度16.195秒，构建2.35秒另计。真实HTTP与Keychain均启用，服务为既有loopback隔离实例51525。日志 `/private/tmp/tokenlibrary-client-full-tests-20260926-234103.log`；完整命令与链路结果见 [客户端同步验证](client-sync.md)。

| 测量 | 样本与动作 | 本轮p95 |
| --- | --- | --- |
| 资料库筛选和排序 | 1000条合成元数据，900笔记/100论文类别，按专题、标签、作者、年份过滤后按年份排序；30次，每次准确返回220个不同ID | **33.022 ms** |
| 中英文全文检索 | 1000条合成Markdown，交替执行“图书 Swift”和“资料 999”；100次，每次最多50个命中 | **1.986 ms** |
| PDF阅读位置保存 | 同一原件连续保存100次位置；验证索引行不重建、页码/摘要命中正确、重开Store后复用文字缓存 | **1.531 ms** |

方法来自 `CatalogTests.testThousandRecordCatalogFilterAndSortPerformance` 与 `SearchPerformanceTests`。计时数组升序后，30次取第29项、100次取第95项；不包含测试资料生成成本。资料筛选只处理metadata，不加载100份真实论文原件；全文查询使用已建立的本机索引。PDF保存用例注入可计数的两页文字提取器，计数保持1，证明进度更新不重复提取；该p95不是PDFKit解析或渲染时间。

同日22:57前轮分别为18.207 / 2.263 / 1.990 ms。本轮没有因元数据筛选时延变化改写旧证据，也不由一次Debug运行推断回归原因；这些是各次实际值，受同机负载与缓存影响。自动阈值为元数据筛选p95<500 ms、全文检索p95<1000 ms；PDF保存用例主要验证缓存行为，没有虚构统一设备延迟承诺。

## PDF SDK与原生旅程分开记录

- [PDF夹具与SDK验收](pdf-fixtures.md)已有49,745,911 B、8页真实PDF的PDFKit打开/查找/渲染/批注导出、整个进程最高RSS及外部解析渲染记录。SDK运行不等于原生UI流畅度。
- 同页记录Mac系统导入、8页原件阅读、末页查找和输入/本机/服务器/HTTP下载四方hash一致。单次loopback下载加写盘0.059781秒，系统Open点击到工具AX/截图返回3.714秒，均非稳定p95，也非纯UI导入计时。
- iOS模拟器23:40首次同步已核对大PDF完整落盘，23:59实际打开8页、继续阅读从1到8、查找第7页并自动收键盘；见[iOS首次同步证明](ios-first-sync-proof.md)与[PDF夹具记录](pdf-fixtures.md)。这些行为与字节一致性不等于下载p95、持续滚动帧率或真机峰值内存；1000份真实混合资料原生交互p95、后台资源压力仍须对应测量。最新完成范围以[原生验证记录](native-ui-validation.md)为准，不能由Core或SDK数字直接填写双端全范围通过。

前两轮使用同一51525服务，最新一轮使用包含回收站metadata修复的新56881服务；均未改测量脚本或启动额外性能负载。23:41、23:59和00:48的三项输出分别来自197、204和218项完整运行，不能混为一次测试或据此宣称性能趋势已确认。

## 01:48 后补：真实混合正文夹具与采样工具（未启动原生 App）

新增独立夹具 `/tmp/tokenlibrary-ui-fixtures/TokenLibrary-Mixed1000-20260927`：800 篇 Markdown（700 短、100 长，其中 100 篇含图像/Mermaid/LaTeX）、199 份分别存储的真实三页合成 PDF，以及一份 49,745,911 字节八页 PDF。另有 10 目录和 4 专题。通过正式 `DocumentStore` 与默认 PDFKit 提取器生成，实际索引 605 页 PDF 文本；没有服务器绑定、凭据、待提交操作、App 启动或 53056 写入。199 份 PDF 复用同一合成内容模板，不能描述为 199 篇不同论文或 OCR 样本。

工具与完整命令见 [采样工具说明](../../tests/performance/README.md)。生成器拒绝覆盖已有目录，manifest 保存所有原始时延、媒体大小/hash 和准确命中断言。执行使用低优先级 `nice -n 10`，macOS arm64 Debug，存在同机工作负载；这是一轮 SDK 校准，不能据此判定硬件承诺或性能趋势。

| SDK 测量 | 样本与准确结果 | p95 / 总时间 |
| --- | --- | --- |
| 完整生成与真实首次索引 | 1000 资料，605 页 PDF；不含后续查询采样 | 总计 2,988.548 ms |
| Catalog 完整查询管线：PDF 原文 | `Research Anchor Beta`，199 项；20 次 | 294.994 ms |
| Catalog 完整查询管线：密集笔记命中 | `MixedCorpusNeedle`，800 项；20 次 | 26.240 ms |
| Catalog 完整查询管线：大 PDF 单项 | `Large PDF Anchor 7`，1 项；20 次 | 300.925 ms |
| Catalog 完整查询管线：长笔记尾标记 | `NoteTailMarker00799`，1 项；20 次 | 302.376 ms |
| Catalog 完整查询管线：无匹配 | `AbsentMixedCorpusNeedle`，0 项；20 次 | 319.882 ms |
| 明细 FTS | 同五类，每类 20 次，limit 1000 | 各类 p95 为 12.149 / 32.817 / 0.698 / 7.755 / 0.724 ms |
| 读取所有资料及旧库库存 | 20 次；不包含 SwiftUI 发布与绘制 | 36.402 ms |

Catalog 管线测量包含 `search`、`searchCoverage`、过滤排序及未由索引命中时的正文匹配。稀疏命中会遍历长 Markdown 做大小写/重音不敏感匹配，明显贵于单独 FTS；当前整个管线在 detached task 中，不能把此 CPU 时延写成主线程冻结。源码的 `reload()` 同步读取列表及库存，36 ms 的 SDK 结果提示原生主线程预算仍需观察，但未测绘制帧或 iOS CPU，因此本轮没有据此改写产品数据/搜索语义。

进程 `/usr/bin/time -l` 覆盖生成器加全部 100 次双路径查询：29.85 s wall、27.63 s user，最高 RSS 159,924,224 B。它是 SDK 工具进程，不是 App 内存。完整日志 `/tmp/tokenlibrary-mixed-performance-fixture.log`，原始结果在夹具 `performance-manifest.json`。

独立只读核验 `/tmp/tokenlibrary-mixed-performance-readonly-proof.json` 确认 201 个媒体共 64,680,106 B 全部匹配记录大小/SHA、队列为零，保存生成器/静态 Core 构建 hash。现有目录、相对目录和非临时目录三种生成请求均拒绝，原库 hash 不变；未向应用注入数据。

新增 `tests/performance/sample_native_process.py` 只读读取明确 PID/可执行路径的 CPU 累计时间与 RSS，检查独立验证 bundle 和进程开始时间，进程退出或身份变化就停止。保存原始 JSONL、采样开销及人工阶段标记；后续加入跨进程时钟、阶段 CPU 边界和部分 JSONL 行回归后，共 8 项工具测试通过（`/tmp/tokenlibrary-native-sampler-tests.log`）。没有对正在进行的 F12 窗口注入操作或替换 App。

F19/L28 仍缺的原生证据是：两端同一千项夹具的列表/搜索/长笔记/大 PDF 操作及准确命中，原生 CPU/RSS 曲线，可靠事件到绘制完成的响应 p95、滚动帧时间；首次导入/同步索引、系统内存压力和真机资源须另测。采样 RSS 不是保证捕获峰值或 physical footprint；主 App PID 不包含 WebKit 子进程。人工标记与 CUA 返回耗时不转换为纯 UI p95。

01:54:36 已准备、未启动独立 Mac App：`/private/tmp/tokenlibrary-performance-app-tgdh8opa/TokenLibraryPerformanceVerification.app`。基于最新源码选区修复包，编辑器资源 SHA `aadd53ea0600d7d6be091800c106d66c33442234e87a3ee6e34e0d1f48ff61b2`；bundle 为 `app.tokenlibrary.verification.performance`，显示“TokenLibrary 千项验收”，Debug Info 指向上述离线夹具。ad hoc deep/strict 签名通过，源 App 与夹具 DB hash 未变，没有证书或 Keychain 访问。App 同级 `verification.json` 保存身份、二进制 hash 和采样用精确可执行路径；准备成功不是 GUI 性能验收。


## 02:04—02:15 Mac 千项原生操作与主进程资源

Root 使用 CUA 正常启动上述独立 App，主进程 PID 96587，可执行文件 SHA `02b2fd6715f4be723783c97a249ea58071902a1be64ae4e940d02e762489fcad`。这轮仍是源码选区修复资源 `aadd53ea…`，不包含随后 `313efa…` 富文本选区修复。App 没有服务器或凭据，使用同一千项合成库。

实际界面确认资料库 1000 项；`Research Anchor Beta` 为 199 项，`AbsentMixedCorpusNeedle` 为 0 项，`MixedCorpusNeedle` 为 800 项，`NoteTailMarker00799` 为 1 项。0799 长笔记可打开阅读。49,745,911 B 大 PDF 显示 8 页，查找 `Large PDF Anchor 7` 跳至第 7 页，继续滚至第 8 页。追加搜索 `NoteTailMarker00792` 唯一命中“合成笔记 0792”（ID `f1900000-0000-4000-8000-000000002792`），打开阅读并滚至长文末尾，实际截图同时显示图片、Mermaid“阅读→摘录→复习”和行内公式 E=mc²。原生完整步骤由 [原生验证记录](native-ui-validation.md) 记录；此处仅把已确认操作与采样窗口对应，不补写未操作的帧率或真机结论。

只读采样从 **02:05:12.961 到 02:15:12.970**，请求间隔 1 秒、持续 600 秒，实际 595 点、600.011 秒，正常 `duration-complete` 结束，没有重启或延长。主进程累计 CPU 增加 **31.89 秒**；采样 RSS 最高 **376.422 MiB**，末值 **60.453 MiB**。所有有效 CPU 间隔中位数 0%，p95 47.497%。CPU 100% 表示约使用一个核心，以下 p95 均是**采样区间 CPU 占比**，不是操作响应 p95。

| 人工操作窗口 | 窗口秒数 / 样本 | CPU 中位数 / p95 | RSS 采样最大 / 窗口末值（MiB） |
| --- | --- | --- | --- |
| 打开资料库、浏览、首次查询 | 159.90 / 158 | 0 / 17.763% | 239.203 / 239.203 |
| 稀疏搜索 | 15.98 / 16 | 0.987 / 91.068% | 273.688 / 194.938 |
| 密集搜索 | 14.90 / 15 | 0 / 66.050% | 280.562 / 280.562 |
| 0799 长笔记 | 38.93 / 38 | 0 / 63.240% | 294.719 / 213.500 |
| 大 PDF、查找和翻页 | 56.06 / 55 | 0 / 75.526% | 361.297 / 307.297 |
| PDF 后静置 | 24.91 / 25 | 0 / 6.924% | 363.703 / 303.875 |
| 0792 长文及三种嵌入 | 33.47 / 33 | 3.952 / 68.313% | 376.422 / 158.891 |
| 最后静置至采样结束 | 211.22 / 209 | 0 / 0.993% | 152.688 / 60.453 |

初始独立静置窗口取首 15 秒内的 15 点，实际首末跨度 14.15 秒：CPU 中位数 0%、p95 5.928%，RSS 最大约 163.61 MiB、末值约 137.73 MiB。最后静置阶段主 PID CPU 回落且 RSS 降低；这不能证明 WebKit 子进程没有泄漏，也不能从单次资源波形推断稳定内存上限。

每个阶段排除首个 CPU 间隔，避免它包含前一阶段活动。最终静置没有人为补造 `end` 标记，报告标为 `open-at-last-sample`。阶段边界使用共同 wall clock：实际发现单独工具进程的 monotonic epoch 不同，第一条旧标记若直接按原始 monotonic 比较会落在起点。CPU 计算始终仅用采样进程内部 monotonic 差值；保留原始标记与旧 `summary.json`，以更新分析器生成的 **`report.json`** 为阶段结果，8 项工具回归包含此边界。

原始目录 `/tmp/tokenlibrary-native-perf-20260927-0204` 保存 `manifest.json`、`samples.jsonl`、`markers.jsonl`、`environment.json`、`initial-idle.json`、`summary.json` 和修正后的 `report.json`。`ps` 只读开销 p95 约 9.774 ms、最大 122.136 ms，包含在实际采样间隔中。采样开始时 10 核宿主 load average 为 5.27/5.32/5.88，另外的 Selection Mac、iOS 验证 App 与 Device Hub 仍运行，期间另有 Browser/双端构建任务；不是空载设备。独立只读取证还在 02:10:47.284 起约 0.148 秒、02:12:12.861—13.159 约 0.298 秒扫描了 SQLite 与 64.68 MB 媒体，这两段环境干扰未伪装成 App 自身工作。

`/tmp/tokenlibrary-mixed-gui-final-proof.json` 与前阶段 proof 逐字段/逐字节核验：1000 资料及 201 媒体不变，只有大 PDF 第 8/8 页阅读 metadata、对应本机状态和 1 条待提交操作；正文/原件未变。此证明采用 WAL 感知快照，不能单看主 SQLite 文件 hash 推断“没有阅读位置写入”。详情工具见 [采样说明](../../tests/performance/README.md)。

本轮补齐 **Mac 同一千项真实正文夹具的有限原生旅程和主进程 CPU/RSS**。iOS 同夹具尚待独立容器原生操作；持续滚动帧时间、可靠 UI 事件至绘制的响应 p95、首次网络同步/导入索引、压力与真实 iPhone 资源仍未由本轮证明。CUA 步骤窗口、工具返回时间和本表区间 CPU p95 均不能替代这些测量。


## 02:18 iOS 千项独立容器准备（尚未原生验收）

取得最新富文本选区修复源包后，以相同冻结源码和独立 DerivedData 正常 `xcodebuild PRODUCT_BUNDLE_IDENTIFIER=app.tokenlibrary.verification.performance.ios` 构建，没有修改二进制 entitlement section。产物 `/private/tmp/tokenlibrary-ios-performance-build-hblkujsg/DerivedData/Build/Products/Debug-iphonesimulator/TokenLibrary.app` 显示“TokenLibrary 千项验收”；arm64/x86_64 内嵌 `application-identifier` 均为 `7728J3WTW8.app.tokenlibrary.verification.performance.ios`，ad hoc deep/strict 签名通过。126 个产品源码/资源文件 hash 与构建前一致，editor SHA `313efa95337dc344a766f81e4e11d84ed12ced20372c97a58beb7ec9db7ea921`。这轮 iOS 与 02:04 Mac 包的富文本选区实现不同，不能作为同二进制跨平台性能对照。

仅执行新 bundle 的 `simctl install`，没有 launch 或 GUI 操作。模拟器 `CDC55D3E-C4BB-43A3-B3C1-8789492A1D08` 为它分配独立数据容器 `E9065E80-C4C7-4E15-B468-B951CC492855`；未设置宿主临时目录 Info override，使用容器内 `Library/Application Support/TokenLibrary`。新 bundle 的标准偏好域为空，没有复制偏好、会话或 Keychain；空 server 不会触发会话恢复读取。原 `app.tokenlibrary.verification` 容器与同步库没有被替换。

Mac 600 秒采样结束后才运行生成器，新副本 `/tmp/TokenLibrary-Mixed1000-iOS-20260927-fresh` 的结构/文本/媒体内容与前述规格一致，媒体 UUID 独立，queue 为零。首次尝试 `/private/tmp/TokenLibrary-Mixed1000-iOS-20260927` 在附件路径校验返回 `invalidPath`，保留失败目录，未覆盖重用；使用已验证的 `/tmp/...-fresh` 新目录后完整生成成功。这两次工具执行均在 Mac 捕获结束后，不把与 iOS build 并行的生成器额外时延拿作新的性能基准。

复制完整离线副本至新容器后，只读核对 1014 对象（1000资料、10目录、4专题）、605 页 PDF 文字缓存、201 个媒体大小/SHA、零待提交、无 server/library 绑定。`/private/tmp/tokenlibrary-ios-performance-build-hblkujsg/verification.json` 记录全部媒体、200 个 PDF 的原绝对路径及新容器相对附件对应的预期路径；原 DB 的绝对 PDF 路径仍待首次 App 开库由正式 `recoverRelocatedLibraryPaths()` 恢复。**准备、安装与附件存在性不等于原生打开、路径迁移、帧率或 iPhone 真机验收**。首次启动后应另取 WAL 感知只读快照，确认 200 PDF 路径都指向新库、revision/正文/原件及 queue0 不因路径恢复发生业务修改。


## 02:21—02:32 iOS 模拟器千项原生操作与主进程资源

Root 于 02:21:30 从系统 Home 正常打开独立“TokenLibrary 千项验收”，界面显示本机文档、分组 0—9、待提交 0。采样 App 为上节新 bundle，PID 1563，可执行文件 SHA `fc79a2c4f339004969ff5d05de4a011c1e6a61cb4cd278bf00ec6c46bf30b428`，资源 `313efa…`；iPhone 17 Pro / iOS 26.5 **模拟器**运行在 10 核 macOS 宿主。没有替换原同步验收 App，也没有复制或读取其会话。

02:21:43 的采样前只读检查确认全部 **200 个 PDF 绝对路径迁入当前新容器**，201 媒体大小/SHA 完整，revision/Markdown 不变、queue0。开库因路径身份变化重新生成文字缓存，缓存中保留旧路径条目，因此共 1210 个缓存页（旧 605＋新 605）；**当前 `search_chunks` 仍只有 605 个 PDF 页面**，不是新增或重复资料。早期 proof 的字段 `pdfTextPages` 表示缓存页总和，后续脚本已分别命名 `cachedPDFPagesIncludingPriorPathIdentities` 与 `indexedPDFPages`，原始证据不合并混称。

原生实际完成：资料库 1000 项，PDF 正文 `Research Anchor Beta` 命中 199，`AbsentMixedCorpusNeedle` 为 0，`MixedCorpusNeedle` 为 800；0799 长文阅读至尾。49,745,911 B PDF 显示 8 页，查找唯一第 7 页再触摸滚至第 8 页，待提交显示 1。02:27:29，“合成笔记 0792”末尾截图同时完整显示合成 PNG、Mermaid“阅读→摘录→复习”、KaTeX E=mc² 和 `NoteTailMarker00792`。大量连续快速拖动时曾捕获中间白屏，后续截图恢复正文；没有可靠帧时间或白屏持续时长，因此记录此体验现象，**不宣称连续滚动流畅，也不判定永久卡死**。截图及操作步骤由 [原生验证记录](native-ui-validation.md) 保存。

资源采样在开库迁移和第一次媒体核验完成之后，从 **02:21:53.401 到 02:31:53.416**，595 点、600.016 秒，正常 `duration-complete` 结束，没有延长。主 PID 累计 CPU 增加 **40.21 秒**，所有采样 CPU 区间中位数 0%、p95 **28.764%**；RSS 采样最大 **591.297 MiB**、末值 **141.656 MiB**。初始 15 秒内的 15 点首末跨度 14.175 秒，CPU 中位数 0%、p95 7.890%，RSS 末值 329.297 MiB。

| 人工操作窗口 | 窗口秒数 / 样本 | CPU 中位数 / p95 | RSS 采样最大 / 窗口末值（MiB） |
| --- | --- | --- | --- |
| 资料库及列表 | 31.93 / 32 | 0 / 30.787% | 357.969 / 357.219 |
| 稀疏搜索（199 与 0） | 70.07 / 69 | 0 / 36.587% | 391.875 / 338.078 |
| 密集搜索（800） | 18.85 / 19 | 0 / 28.764% | 338.078 / 327.391 |
| 0799 长笔记 | 64.43 / 64 | 0 / 30.648% | 342.469 / 294.594 |
| 大 PDF、查找和触摸翻页 | 61.52 / 61 | 0.989 / 277.628% | 591.297 / 398.891 |
| 0792 长文及三种嵌入 | 70.31 / 69 | 0.990 / 33.721% | 410.594 / 169.375 |
| 最后静置至采样结束 | 264.16 / 261 | 0 / 1.979% | 153.766 / 141.656 |

CPU 可超过 100%（PDF 工作使用多个核心）；表中 p95 是区间 CPU 占比，窗口时长包含输入、滚动、截图、工具往返和观察，**均不是 UI 响应 p95**。末段 CPU 回落不能证明子进程无泄漏；本采样不包含 WebKit 子进程、WindowServer 或 physical footprint。`ps` 检查开销 p95 约 9.157 ms、最大 74.384 ms。环境快照 load average 为 5.48/6.59/6.79，另有两台 Mac 验证窗口、原 iOS 验证 App 和 Device Hub；期间也有独立 Core 回归工作，不是空载或手机硬件资源测试。

捕获前媒体核验约 0.368 秒，完成后才启动采样。另一次结束核验实际在 **02:31:49.609** 完成、耗时约 **0.667 秒**，比采样真正结束提前约 4 秒；原先描述性 phase 错写为“已结束”，现已在该 proof 中明确更正并保留说明。此 64.68 MB 外部读取会干扰末尾静置样本，报告没有隐去。确认采样进程 `duration-complete` 后，于 **02:32:23.435** 再取独立最终 proof（约 0.560 秒），以该文件作为最终业务数据证据。

- 采样目录：`/tmp/tokenlibrary-ios-native-perf-20260927-0221`，包含身份/原始 CPU 与 RSS、阶段标记、环境、初始静置、原生观察说明、`summary.json` 和 `report.json`。
- 最终只读数据：`/tmp/tokenlibrary-ios-mixed-after-capture-proof.json`。200/200 PDF 路径在当前库，当前 PDF 索引 605 页，201 媒体共 64,680,106 B 全部保持；1000 资料的 Markdown 和 revision 不变。
- 相比生成器副本，除 200 个本机 PDF 路径迁移，唯一业务变化是大 PDF `f1900000-0000-4000-8000-000000001199` 的 readingStatus / 当前设备第 8/8 页进度，以及对应 localGeneration/status/updatedAt。队列仅一条 `updateDocument`，ID `124af452-05a4-432d-8087-d5bcd197e396`；其他正文、metadata 与原件没有改变。

这轮补齐 iOS 模拟器同规格千项混合资料的有限原生旅程、路径恢复及主进程 CPU/RSS。它没有测首次网络同步或批量导入，也没有把开库迁移的首次提取耗时算进采样；两端编辑器版本不同、宿主负载不同，不能直接据 RSS/CPU 差异判平台优劣。真实 iPhone 压力/后台限制、可靠响应 p95、持续滚动帧时间，以及快速拖动的短暂白屏仍需独立测量和定位。

## 02:52 PDF 缓存重复迁移诊断（尚未改产品实现）

针对上节旧 605＋新 605 缓存页，只读源码核对发现 `DocumentStore.reindex` 的页缓存键是 `SHA256(绝对路径 | pdfBlobId | size | mtime)`；库路径恢复在同步 `DocumentStore.init` 中逐份调用 reindex。没有任何 `pdf_page_text_cache` 删除/回收入口，purge 也只移除当前 FTS 和 `search_index_state`。所以根目录变化即便原件字节和版本完全一致，仍重新读取、抽取、缓存全部 PDF，旧缓存持续保留。`AppModel` 的主 actor 初始化同步等待此过程；PDFKit 实际工作可以在 GRDB 的写队列上，但调用方仍被阻塞，不能把它称为后台非阻塞开库。

独立临时 SDK 探针 `/tmp/tokenlibrary-pdf-cache-relocation-probe.swift` 链接 02:45 的 Core 静态产物，生成 12 份真实三页合成 PDF 和一份真实 49.7 MB 八页 PDF，合计 13 文档、44 页。注入的计数器仍执行与产品相同的 `PDFDocument.page.string` 提取，没有用假文本或延时替代。只移动新建 `/tmp/tokenlibrary-pdf-cache-relocation-a411893f-e608-4afa-a82b-96ac78fe1188` 内部目录，不读写前述两套性能库、现有验证容器、网络或凭据。

| 阶段 | 缓存身份 / 缓存页 | 当前索引页 | 本次 PDFKit 抽取 | 主线程调用开库耗时 |
| --- | --- | --- | --- | --- |
| 初始生成 | 13 / 44 | 44 | 13（生成过程） | 不作开库比较 |
| 首次移动 | 26 / 88 | 44 | 13 | 48.330 ms |
| 第二次移动 | 39 / 132 | 44 | 13 | 48.186 ms |
| 第三次移动 | 52 / 176 | 44 | 13 | 47.945 ms |
| 同一路径重开 | 52 / 176 | 44 | 0 | 2.693 ms |

每次迁移的提取阶段约 20 ms，缓存 JSON 字节从 32,597 增至 130,388。全部文档 revision/正文/metadata、原件 hash、零队列保持，只改本机绝对 PDF 路径。完整证据 `/tmp/tokenlibrary-pdf-cache-relocation-proof.json`，运行日志同前缀 `-probe.log`。这是暖文件缓存、合成小样本的确定性增长证明，不外推 200 PDF 冷启动毫秒数或真实 iPhone 时延，也不把已有 600 秒原生采样说成包含本次开库成本。

建议限定后续修复为：库内经路径验证的相对位置＋blob＋size＋mtime 的版本化缓存身份；旧缓存仅在原件实际校验与既有 transfer 身份一致时承继，无法证明则仍抽取。记录每份当前文档使用的缓存身份，在事务完成后清理没有当前引用的旧缓存，或仅保留固定条数/字节上限的历史缓存。不得为复用而只信书目里的 hash、去掉原件变化检查、删除原件或恢复草稿。回归应覆盖反复迁移不再重复抽取/增长、同路径换版仍失效、不同库同 blob 隔离、校验失败不继承，以及旧版草稿恢复与队列/revision 保持。本节记录诊断和方案，封存 App 与 Core 尚未因此变更。

## 03:01 稳定 PDF 缓存与无引用回收修复

后续授权的最小实现已落在 [DocumentStore.swift](../../clients/LibraryCore/Sources/LibraryCore/DocumentStore.swift) 与 [LibraryPathRecovery.swift](../../clients/LibraryCore/Sources/LibraryCore/LibraryPathRecovery.swift)：只有经 `resolveAttachment` 确认可属于当前库的路径使用相对位置；旧库外部原件继续使用绝对位置。缓存身份仍包含 blob ID、实际文件 size、mtime，以及显式 `pdf-text-v2` 格式版本，不只信任书目中的 `originalFileHash`。v11 对旧不透明路径 key 首次重建一次，未实现复杂的旧 key 猜测继承；以后原件、blob 和 stat 相同的容器移动复用缓存。

新增文档→缓存引用表，外键随文档删除清除引用；更新/删除引用的数据库触发器只在最后一个引用消失时回收页文字缓存。两个文档共用原件时，一个被清除不会破坏另一个缓存；最后文档被清除也不删原件文件或 `editor_drafts`，恢复草稿创建副本时可重新提取。历史无引用缓存在 v11 清理，后续新换版缓存由引用变动及时回收，容量随当前被引用的原件数变化，不再随每次搬库无界累加。没有增加定时后台清理或改变同步 payload。

首轮 5 项新回归在旧代码上有 15 个断言失败，`/tmp/tokenlibrary-pdf-cache-before.log`；修后 5 项全过。相关套又发现“旧路径不可用时曾移除 PDF 搜索行”的兼容边界：稳定签名会过早返回。补丁因此仅在路径恢复时验证缓存页对应的 search_chunks/FTS 来源完整性；缺行用已有页文字重建，完整索引不改行 ID，普通阅读保存保留原快速路径。

最终 03:00:47 的 **33 项相关 Core 回归全部通过，0 失败**：新增 PDFTextCache 7、路径恢复 7、编辑恢复 16、搜索覆盖/性能 3。日志 `/tmp/tokenlibrary-pdf-cache-related-final.log`。包含连续三次迁移零重复提取且冻结队列/FTS 行保持、mtime/size/blob 分别失效、不同库同相对路径/ID/size/mtime 隔离、共享引用与清除、恢复旧批注、旧 schema 一次重建、`/tmp` alias、缺失原件和索引补回。已有阅读进度 100 次保存仍只提取一次。此处不把定向 33 项写成未经重跑的完整 Core 总数。

重新链接同一个真实 PDFKit 探针，并生成另一套独立 13 PDF/44 页临时库。`/tmp/tokenlibrary-pdf-cache-relocation-after-proof.json` 显示连续三次移动均 **0 次 PDFKit 重新提取**，缓存恒为 13 身份 / 44 页 / 32,597 B，当前索引恒为 44 页；所有正文/revision/metadata、原件和 queue0 不变。开库耗时依次 7.820、7.292、7.157 ms，同路径重开 2.908 ms。原始与修后均为暖 SDK 小样本，不把这些数字宣称为此前千项原生 App 或真实 iPhone 的新启动性能；封存的 600 秒原生证据不被覆盖。

保留的文件变化边界也必须明确：如果外部程序在原路径、同 blob ID 下替换内容，且刻意保持**字节数和 mtime 都相同**，该 stat 缓存不会逐次读取全部 PDF 来发现它；这与此前同一路径缓存的检查强度一致。本修复没有通过移除变化检查换取复用，也没有以每次阅读重新计算大文件 hash 增加主线程成本。正常导入/下载仍走既有附件 size/SHA 校验，换版 blob 或文件 stat 改变会失效。原生新版需后续独立安装/操作验证。

03:02 后续完整 Core 验证包含这 7 项缓存回归，共 **234 项、0 失败、0 跳过**，证据 `/tmp/tokenlibrary-final-recovery-core-tests.log`；这更新了代码覆盖证据，没有追加原生性能测量。同期 clients 103 项的后续录音文件修复已另跑 108 项，见 [U9 专项](ios-recording-validation.md)，不混为 Core 项数。
