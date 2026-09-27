# 客户端同步、隔离和检索验证

更新：2026-09-26。测试均使用临时目录；HTTP 端到端使用独立临时 PostgreSQL 与 localhost 服务。没有读取真实 `.env` 或连接真实资料库。

## 测试层次

- `ConnectionReliabilityTests`：地址、超时、中文错误、Retry-After、取消、401 不重试、重试请求/operationId 一致。
- `QueueReliabilityTests`：不可变队列、重启、旧迁移、根目录隔离、在途改名/移动、旧回执安全。
- `FullSyncReliabilityTests`：多页失败原子性、游标回滚、墓碑、本机新编辑 rebase、人工冲突、epoch 恢复、旧暂停队列升级、附件损坏、断点上传、确定性拒绝后修改、阅读进度多设备合并。
- `WorkspaceTransferTests`：服务器/库隔离、显式迁入与碰撞、附件重定位、源不变、回收批次、同步 gate 与取消。
- `SearchPerformanceTests`：1000 资料混合中文/英文搜索 p95；100 次 PDF 阅读进度更新只提取一次，重开仍复用，返回正确页号/摘要。
- `FullSyncEndToEndTests`：真实 HTTP 登录、两端同步、独立正文编辑合并、metadata、图片/PDF 上传下载、PDF 批注、服务端冲突材料与人工解决、递归回收/还原；另创建 105 条资料验证首次快照和增量均跨页完整读取。
- `SessionVaultTests`：真实系统 Keychain 随机测试 service 的保存、地址标准化读取、更新、跨 server 隔离、删除；测试结束清理所有测试项。默认跳过，可设置 `TEST_TOKENLIBRARY_KEYCHAIN=1` 启用。
- 完整套件同时运行既有 Core、Catalog、编辑器、PDF 批注与 ZIP 导出 roundtrip 回归。

## 可复现命令

在 `clients/LibraryCore` 运行（模块/包缓存放临时目录，适用于限制主目录写入的环境）：

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/tokenlibrary-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/tokenlibrary-module-cache \
swift test --disable-sandbox --skip-update \
  --cache-path /private/tmp/tokenlibrary-spm-cache
```

真实 HTTP 用例默认跳过。使用专门创建的 localhost 服务时，额外设置 `TEST_TOKENLIBRARY_URL`、`TEST_TOKENLIBRARY_USER`、`TEST_TOKENLIBRARY_PASSWORD` 再运行同一命令；测试拒绝非 localhost 地址。测试服务会产生随机名称资料，必须使用隔离库。不要把生产地址或生产凭据用于此命令。

## 性能记录

本次 macOS/arm64 Debug 临时库实测：1000 资料、100 次查询、每次最多 50 命中，搜索 p95 2.020 ms；100 次 PDF 阅读进度保存 p95 1.019 ms，PDF 提取计数为 1，重开资料库后仍为 1。该数字是本机回归证据，不是所有硬件与任意 PDF 大小的性能保证。

## 上一轮全套结果

2026-09-26 18:25（Asia/Shanghai）：**98 tests，0 failures，0 skipped**，用例执行约 5.43 秒。真实 HTTP 两项分别耗时 2.24 秒（跨页）和 1.34 秒（正文、附件、PDF、冲突、阅读进度、回收/恢复）。测试代码调用真实上传、下载和冲突 API，没有用 mock 代替端到端链路。

完整日志：`/private/tmp/tokenlibrary-client-full-tests.log`。独立 Keychain 日志：`/private/tmp/tokenlibrary-session-vault-test.log`。限制沙盒下 Security API 曾返回 -50；同一随机测试 service 在获准的正常系统环境中通过，未触及真实会话。

本次运行目录为 `clients/LibraryCore`，最终命令（测试凭据通过临时环境变量提供）：

```sh
TEST_TOKENLIBRARY_URL=http://127.0.0.1:60106 \
TEST_TOKENLIBRARY_USER="$ISOLATED_TEST_USER" \
TEST_TOKENLIBRARY_PASSWORD="$ISOLATED_TEST_PASSWORD" \
TEST_TOKENLIBRARY_KEYCHAIN=1 \
CLANG_MODULE_CACHE_PATH=/private/tmp/tokenlibrary-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/tokenlibrary-module-cache \
swift test --disable-sandbox --skip-update \
  --cache-path /private/tmp/tokenlibrary-spm-cache \
  > /private/tmp/tokenlibrary-client-full-tests.log 2>&1
```

60106 是本轮随机临时端口，不是固定开发服务地址。复现时由独立服务启动结果替换。图形界面和 iOS 构建/模拟器测试由主任务另行记录，不能由本页 Core 通过结果推断。

## 编辑并发与原子创建回归

2026-09-26 18:47（Asia/Shanghai）：**141 tests，0 failures，0 skipped**，用例执行约 9.09 秒。覆盖新增编辑草稿 15 项、目录结构并发 6 项、原子创建 7 项、Catalog 26 项和搜索覆盖状态。真实 HTTP 分页 3.02 秒、双端正文/附件/PDF/人工冲突/回收恢复 1.90 秒；真实系统 Keychain 保存、更新、隔离与清理 0.03 秒。

本轮独立服务为 `http://127.0.0.1:62036`，由临时 PostgreSQL 与最新服务端二进制启动。运行命令同上，将 `TEST_TOKENLIBRARY_URL` 换成该隔离服务地址，启用 `TEST_TOKENLIBRARY_KEYCHAIN=1`。完整日志仍为 `/private/tmp/tokenlibrary-client-full-tests.log`。

首次全套回归发现：人工解决冲突时 `writeWorking` 已递增本机 generation，调用方又递增一次，但冻结请求只记录第一次值；回执误判为还有在途编辑，导致冲突或等待状态无法清除。现改为冻结实际写入的 generation，专门断言及真实双端冲突解决均通过。

本轮性能：1000 资料混合全文搜索 p95 **3.841 ms**；100 次 PDF 阅读进度保存 p95 **2.459 ms**，提取计数仍为 1。图形界面通过情况仍须查阅独立的 UI 记录。

## 当前全套结果

2026-09-26 **19:12:23**（Asia/Shanghai）：**179 tests，0 failures，0 skipped**，用例执行约 **15.55 秒**。日志：`/private/tmp/tokenlibrary-client-full-tests.log`。服务使用最新包含短暂 BUSY 恢复语义的独立二进制与临时 PostgreSQL，地址 `http://127.0.0.1:51525`；它是本轮随机端口，复现时替换为新隔离服务启动地址。

覆盖 Catalog 31、旧资料库根兼容 7、编辑草稿 15、原子创建 7、目录结构 6、Markdown 导入 17、PDF 批注/导出 10、跨库迁入 6、连接可靠性 14，以及既有队列、搜索、导出和同步回归。

真实 HTTP 分页用例耗时 **3.917 秒**，两端正文/metadata/附件/PDF/冲突/回收恢复 **2.408 秒**，Markdown 图片与音频导入后上传下载及字节比对 **1.210 秒**。系统 Keychain 随机 service 的保存、读取、更新、跨服务器隔离和删除用例 **0.052 秒**。没有跳过依赖真实系统服务的测试。

性能：1000 条资料筛选排序 p95 **31.533 ms**，全文搜索 p95 **4.281 ms**，100 次 PDF 阅读位置保存 p95 **3.353 ms**，提取计数仍为 1。各数据来自 macOS/arm64 Debug 本机回归，不是所有设备的性能承诺。

19:05 的 168 项运行曾有一次真实 HTTP 分页收到 HTTP 503、Retry-After 30；19:07 的 170 项复跑通过。调查发现后台每 30 秒清理短暂占用写锁时可能返回与长维护相同的等待时间，并有可复现的服务端竞争测试。服务器已把短暂繁忙改为 BUSY + Retry-After 1，真正维护保持 30 秒；客户端保留 HTTP 错误中的 serverCode、statusCode 和 Retry-After，并验证短等待使用完全相同的请求及 operationId 重试，长维护不提前重试。上述最终 179 项在更新后的隔离服务执行。历史 503 的逐请求日志不足以证明该次失败的精确来源，故不把推断写成已捕获的现场结论。

图形界面、两端 SDK 构建和真机后台验收由独立记录报告，不能从 Core 测试通过推断。

## 22:27 当前完整运行

隔离服务 51525，启用真实 HTTP 与 Keychain；LibraryCore 189 项、0 失败/跳过，9.704 秒。日志 `/private/tmp/tokenlibrary-client-full-tests.log`。新增摘录幂等参数校验 4 项、迁入来源重映射 1 项、回收还原边界 5 项。两个 Xcode 目标22:26构建成功，客户端模型/查询/提交反馈21项22:26:59通过。原生旅程仍以单独记录为准。

## 22:57 本批完整运行

2026-09-26 22:57:41（Asia/Shanghai），当时稳定Core在既有隔离服务51525运行：**197 tests、0 failures、0 skipped**，逐项197个passed、无skip标记，命令exit0；用例总耗时16.809秒。日志 `/private/tmp/tokenlibrary-client-full-tests.log`。启用 `TEST_TOKENLIBRARY_KEYCHAIN=1` 和真实loopback HTTP合成凭据；未新建/重置服务，也未使用原生验收的53056资料库。

实际HTTP分页3.422秒，双客户端正文/metadata/附件/PDF/冲突与回收恢复2.657秒，真实系统Keychain隔离保存/更新/读取/删除0.032秒。完整运行包含最新PDFImportValidation五项（损坏/空/无页、实际可读PDF的50,000,000字节边界、读文件失败、需密码与可读加密PDF）以及LibraryExport回归。

本机Debug性能：Catalog千项元数据筛选排序30次p95 **18.207 ms**；千条全文检索100次p95 **2.263 ms**；PDF阅读位置保存100次p95 **1.990 ms**，原件文字提取仍只1次。元数据样本不代表千份真实PDF全文，Core时延不代表原生UI/iPhone卡顿门槛通过。Shared后续工具栏/界面改动不属于这次Core执行范围，需各自构建和原生复测。

## 23:41 NoteBlocks修改后的完整Core回归

2026-09-26 **23:41:03.883**（Asia/Shanghai），当时Core在既有51525隔离服务完成 **197 tests、0 failures、0 skipped**；逐项197个passed，命令exit0。XCTest用例时间合计16.177秒，整套实际跨度 **16.195秒**；构建2.35秒另计。完整日志 `/private/tmp/tokenlibrary-client-full-tests.log`，另保留固定副本 `/private/tmp/tokenlibrary-client-full-tests-20260926-234103.log`，避免后续重跑覆盖本轮证据。

使用本页命令，设置 `TEST_TOKENLIBRARY_URL=http://127.0.0.1:51525`、隔离服务合成凭据及 `TEST_TOKENLIBRARY_KEYCHAIN=1`。运行前ready=true/maintenance=false；没有新建、重置或停止服务，没有操作53056原生验收库。真实HTTP分页 **3.668秒**，双客户端正文/metadata/附件/PDF/冲突/回收恢复 **2.528秒**，Markdown图片与音频实际上传下载及字节比对 **1.875秒**，真实系统Keychain隔离保存/更新/读取/删除 **0.046秒**。

本轮包含更新后的Core `NoteBlocks.swift` 编译与既有197项完整回归；便签空白保留与语音生命周期的新增测试位于 `clients/Tests/StickyNoteTests.swift`，不属于这个Core测试目标，结果见 [iOS便签与语音](ios-notes.md)，不能把本轮197项当作重复执行了这些Shared专项或iOS原生录音。

本机Debug性能：1000条元数据筛选排序30次p95 **33.022 ms**；1000条混合中英文正文查询100次p95 **1.986 ms**；PDF阅读位置保存100次p95 **1.531 ms**，文字提取计数仍为1，重开复用缓存。方法与边界见 [性能记录](performance.md)；不代表千份真实PDF、UI交互或iPhone内存测试通过。

## 23:59 路径迁移修复后的完整Core回归

2026-09-26 **23:59:14.213**（Asia/Shanghai），既有51525隔离服务、真实HTTP及 `TEST_TOKENLIBRARY_KEYCHAIN=1`：**204 tests、0 failures、0 skipped**，逐项204个passed，命令exit0。XCTest用例合计18.419秒，整个All tests跨度 **18.439秒**，构建0.45秒另计。日志 `/private/tmp/tokenlibrary-client-full-tests.log`，固定副本 `/private/tmp/tokenlibrary-client-full-tests-20260926-235914.log`。没有创建、重置、停止服务，本轮未读取或修改53056原生验收库。

相较23:41的197项，本轮新增并执行 `LibraryPathRecoveryTests` **7项**：沙盒目录升级后PDF与搜索恢复并保留冻结队列/文档身份；没有旧标记时从登记blob恢复并补索引；未上传PDF及重复迁移；原文已清理后的旧版本草稿；拒绝符号链接越界和猜测外部文件名；替换PDF与旧版本草稿保持不同文件；相同blobID跨资料库不串用原件。原生新安装包重开是否通过仍由实际UI记录单独确认。

真实HTTP分页 **4.429秒**，双客户端正文/metadata/附件/PDF/冲突及回收恢复 **2.891秒**，Markdown图片/音频真实上传下载 **2.164秒**，系统Keychain隔离保存/更新/读取/删除 **0.043秒**。

本轮p95：Catalog千项筛选排序30次 **17.612 ms**，千条全文查询100次 **2.027 ms**，PDF阅读位置保存100次 **1.419 ms**，提取计数1。方法与原生验收边界继续见 [性能记录](performance.md)，没有用Core通过替代iOS动态字体、录音或实际内存证据。

## 2026-09-27 凭据、书目关系与 PDF 输出合并回归

**00:48:50.660**，最新独立服务 `http://127.0.0.1:56881`（包含 trashed metadata 窄修），真实 localhost HTTP 与独立 Keychain service 开启：**218 tests、0 failures、0 skipped**，全套跨度 **12.695 秒**。日志 `/private/tmp/tokenlibrary-client-full-tests-20260927-final.log`。未使用、重置或停止 53056 原生验收库。

本轮较 204 基线增加异步凭据跨实例条件删除 1 项、失效书目关系恢复 3 项、PDFKit 序列化结构 10 项；对应功能已有独立专项与 SDK 产物检查。客户端模型由另一独立包于 `00:44:23` 完成 68 项。性能记录为千条书目筛选排序 p95 15.408 ms、阅读位置保存 p95 1.461 ms、千条正文检索 p95 2.004 ms；它们是本机自动样本，不代替端到端原生体验或峰值内存结论。

细节参见 [凭据等待与恢复](macos-keychain-startup.md)、[iOS PDF 导出结构](ios-pdf-export-serialization.md)。

## 00:55 合并导航验证包

`00:55:20` 完成新一轮 macOS/iOS 构建、strict/deep 签名、iOS application identifier 与编辑器资源核验；117 个捕获的产品源码/资源文件无构建期间变更。目录 `/private/tmp/tokenlibrary-navigation-build-_mu7mypk` 下包含 `verification.json`、源码 hash、双端 build/signature 日志与两个 ZIP。

- Mac App：`macos/DerivedData/Build/Products/Debug/TokenLibrary.app`；ZIP SHA-256 `8da48073bebedb90adba8b44c178af1fc845788f122b034cb1f6fb0eabdde252`。
- iOS App：`ios/DerivedData/Build/Products/Debug-iphonesimulator/TokenLibrary.app`；ZIP SHA-256 `41dc1694619f42f02a93c34591ae45f854da0b9d356157b7e36b58f3dd8a1cb4`。

此轮含异步凭据等待、rich Mermaid、PDF 序列化、书目离开保护/目标筛选/失效关系清理，以及搜索结果进入文件夹退出搜索、详情与行内移动入口。最新客户端模型 **72 项、0 失败/跳过** 于 `00:53:34.850` 通过，日志 `/tmp/tokenlibrary-folder-move-full-client-tests.log`；Core 仍为上述 **218 项**，后两项导航修改没有改变 Core。00:37 与 00:50 旧包/proof 均保留未覆盖。本段只确认构建与自动验证，由主代理继续安装和原生验收。

## 01:05:50 书目输入位置与批注空态增量包

独立目录 `/private/tmp/tokenlibrary-catalog-footer-build-z_lq8xjq` 的双端 App 均构建及 strict/deep 签名通过，117 个捕获的产品文件与最终构建前 hash 相同。Mac 路径 `macos/DerivedData/Build/Products/Debug/TokenLibrary.app`，iOS 路径 `ios/DerivedData/Build/Products/Debug-iphonesimulator/TokenLibrary.app`；显示名、Bundle ID、iOS application identifier 与编辑器资源均已核验。

本轮包含摘录输入时稳定的 footer、顶部常驻书目保存入口，以及区分原件批注/本库新增批注的空态文案。客户端完整 **72 项、0 失败/跳过** 于 `01:01:43.897` 通过，日志 `/tmp/tokenlibrary-catalog-footer-full-client-tests.log`；随后纯空态文案未添加镜像控件测试，已编译验证。Core 未变，没有重复运行 218 项。

ZIP SHA-256：Mac `a742fd85a34bfb28992b91edeaae4e2ee9d13884b522821c089cf3ec3a8617f8`；iOS `98b3dc1c7998027b4548be80efba98c55fd70c0c966b899a7e3b245b509485b2`。构建日志、签名日志、`verification.json` 与源码 hash 同目录；00:55 及更早已验包未覆盖。

## 03:02 附件路径、恢复副本与稳定 PDF 缓存合并回归

2026-09-27 **03:02:34.137**，现有独立服务 `http://127.0.0.1:56881` ready 后执行最新完整 Core：**234 项、0 失败、0 跳过**，逐项 234 个 passed，命令 exit 0，全套跨度 **15.919 秒**。启用真实 loopback HTTP 和随机测试 service 的 Keychain；日志 `/tmp/tokenlibrary-final-recovery-core-tests.log`。没有新建、重置或停止服务，没有读取真实 `.env`，没有使用 53056/51350 原生验收库。

相比 218 基线，本轮包括附件首次写入 `/private/tmp` 别名 8 项、PDF 换版草稿恢复 hash 1 项、PDF 稳定缓存/引用清理 7 项，合计新增 16 项。相应旧版红测和专项范围继续见 [附件路径](attachment-path-aliases.md)、[草稿原件身份](pdf-draft-recovery.md) 及 [PDF 缓存专项](performance.md)。迁移时复用缓存并校验搜索页完整性，缺少索引行从缓存补齐；不会仅凭相同 signature 跳过需要修复的索引。

真实 HTTP 首次/增量分页 **3.528 秒**，Markdown 图片与音频 roundtrip **1.122 秒**；完整双客户端正文、附件、批注、冲突与回收链也通过。系统 Keychain roundtrip **0.094 秒**，跨适配器旧登出不能删除新会话 **0.042 秒**。56881 仍是此前独立回归服务；服务端本轮批注复合主键修复另有真实 PostgreSQL/HTTP 证据，不由本次地址或 Core 通过推断其已升级。

同轮 `clients` 完整模型/宿主套于 **03:02:28.009** 完成 **103 项、0 失败、0 跳过**，跨度 **4.971 秒**，日志 `/tmp/tokenlibrary-final-recovery-client-tests.log`。包含宿主 13 项（中文分类与失败/重试）、工作区提示 3 项、手输 PDF 页码 3 项；本次是完整执行结果，不是把较早 99 项与重叠专项相加。详细范围见 [宿主生命周期](editor-host-lifecycle.md)。

本机 Debug p95：千条书目筛选排序 **26.110 ms**，PDF 阅读位置保存 **2.045 ms**、提取计数仍为 1，千条正文搜索 **2.076 ms**。这些是自动样本，不代表原生 UI、真机内存或全部多端操作通过。本次之后的独立封包和实际 GUI 复验分别记录，不覆盖此前封存 App。

03:04 后续封包：macOS / iOS 均 build success、strict/deep 签名通过，126 产品源构建前后 hash 相同，证据目录 `/private/tmp/tokenlibrary-final-recovery-build-qb9eifvv`。新 Mac 使用独立 `app.tokenlibrary.verification.finalrecovery` 和新空白目录，iOS 保持原 verification 身份；详见 [宿主专项](editor-host-lifecycle.md)。此包包含稳定 PDF 缓存和中文加载错误，不含其后录音时长修复，也不修改旧封存包。

03:14—03:17 导航意图与录音增量：完整客户端 **111 项、0 失败/跳过** 于 03:14:09.025 通过（5.784 秒），日志 `/tmp/tokenlibrary-navigation-intent-full-tests.log`；Core 未改，完整 234 项保持原执行时点。随后双端构建、签名和 126 产品源 hash 核验通过，包含录音停止后文件帧数时长校验及普通关联导航不继承旧查询定位。目录 `/private/tmp/tokenlibrary-navigation-final-build-77newi2f`；相对 03:04 封包只有 Root/Sticky 两个产品源文件变化，JS/Core 不变，未重复它们的整套测试。路径、原始红测和后续原生边界见 [导航意图专项](navigation-search-intent.md)。
## 03:33 登录页返回本机时的反馈清理

主验收在 03:31 的前序 navigationfinal 包实际发现：健康检查成功后点击登录页“使用本机文档”，本机库底部仍显示“服务器可连接。输入账号密码后登录。”。菜单“本机文档”走 `showLocalLibrary()`，此前已经清理连接归属消息；登录页则走独立 `useOffline()`，漏掉同一清理。这不是服务器同步成功提示再次回归。

当前 `useOffline()` 使用 `cancelConnection(publishNotice:false)` 和现有 `clearConnectionFeedback()`：取消本次连接/恢复等待、清除连接错误及仅属于连接的 banner，再显示已经选中的离线资料。它不更换 store、清空选择/队列或丢弃已有会话；导出/复制等非连接结果和当前本地操作错误保持。系统凭据调用本身仍可能继续，迟到回调受既有 generation 守卫忽略，没有宣称终止系统 API。

新增 3 个模型用例验证真实 SQLite 队列/选中对象保持、已连接工作区与非连接结果保持、注入凭据读取等待取消后迟到结果不会绑定会话或覆写结果。旧码 `/tmp/tokenlibrary-use-offline-feedback-before.log` 为 3 项、5 个失败断言；修复后完整 clients **114 项、0 失败/跳过**，于 **03:33:55.722** 完成，All tests **6.763 秒**，日志 `/tmp/tokenlibrary-use-offline-feedback-full-tests.log`。没有读取真实凭据或连接原生服务。

本修复晚于 `/private/tmp/tokenlibrary-keyboard-final-build-x00cmpkh` 的 03:31 封包；该包只含源码 Tab 修复，不含这里的 useOffline 修改。03:36:59 已与[协议 426 提示](protocol-compatibility.md)和 Tab 修复一起封包，新版本该入口原生复验仍待。

## 03:36 连接提示与键盘组合封包

`/private/tmp/tokenlibrary-connection-final-build-vk07tn8q` 保存 `verification.json`、`source-hashes.json`、`connectionfinal-verification.json`、双端构建/签名日志、完整 ZIP hash，以及本轮 Browser50/clients114/连接与队列34专项日志。127 个产品文件构建前后无变化；与03:31键盘包仅 `TokenLibraryRoot.swift` 和 `ConnectionSupport.swift` 两处产品源码不同。

Mac 独立包 `TokenLibraryConnectionFinalVerification.app`，身份 `app.tokenlibrary.verification.connectionfinal`，显示“TokenLibrary 连接与键盘验收”；新空 base `/private/tmp/TokenLibrary-ConnectionFinal-20260927-cp6d9fur`。主程序 SHA `acd4954b76180801c13ec2117fe15921c7e1ed6fa7d0033b299b3002f9a9fbb4`，实际 debug dylib SHA `279948986a1489368cdaedb432be3273cb389bc39367f6384c0201db91418f4e`，ZIP SHA `2a5a9791b78d8934093a6f2e4844f024fe976bdbf5f1563267985327468482ca`。

iOS 更新包 `ios/DerivedData/Build/Products/Debug-iphonesimulator/TokenLibrary.app`，保留 `app.tokenlibrary.verification`、中文显示名与模拟器 entitlement `7728J3WTW8.app.tokenlibrary.verification`。主程序 SHA `2faea08689d0d807f76b6699afa14c08e2b94dc1619906e6d00de5ad55cd3e1b`，ZIP SHA `61fec07670d638123549ef2119f8596df070a2513bf511ce17820fcbbbcb59ce`。

双端 BUILD SUCCEEDED，strict/deep 签名通过，包内 JS/CSS/HTML 与[键盘专项](keyboard-accessibility.md)一致。复制 DerivedData 后 Xcode 报旧缓存路径超出当前根的 stale-file warning，实际产品和当前源码/资源已分别核验；不将 warning 当作构建失败或因此改动旧封存包。编译人员未安装、启动、访问登录凭据或操作系统设置，原生复验由主验收另记。

03:37—03:40 主验收实际运行此组合 Mac：测试56170健康后进入本机，无残留“服务器可连接”；创建本机笔记后重新测试受控426，版本不兼容说明/更新指引可见，再进入本机时反馈清除、原笔记和 pending1 保留。恢复健康响应后同表单能再次检查成功。此为独立合成健康端点的错误展示与返回本机流程，不等于真实不同版本服务协议互通；主验收[原生记录](native-ui-validation.md)保留完整范围。
