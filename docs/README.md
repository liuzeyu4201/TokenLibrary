# TokenLibrary 文档中心

更新：2026-09-27。这里同时管理产品方向、实际缺口、工程实施和验收结果。

当前主线：**以书籍、论文和笔记为中心的个人资料库；先把保存、连接、同步、导出做可信，再增加资料组织与研究功能。**

## 从哪里开始

| 你要了解什么 | 文档 |
| --- | --- |
| 个人图书馆与档案馆是什么、如何使用 | [产品设计](product/personal-library-archive.md) |
| 参考了哪些产品，哪些适合本项目 | [官方产品参考研究](research/reference-products.md) |
| 当前全范围实现和待验收缺口 | [开发与验收状态（F01—F31 / L01—L30）](testing/development-status.md) |
| 最初发现的体验问题 | [产品体验评估（修改前基线）](research/product-experience-audit.md) |
| 连接、部署、服务端与备份有哪些问题 | [服务端可靠性调查](research/server-reliability-audit.md) |
| 如何实施，先后关系与完成标准 | [实施路线](plans/roadmap.md) |
| 实际改了什么 | [基础体验修复](implementation/2026-09-26-reliability.md)、[服务端同步](implementation/2026-09-26-sync-server.md)、[客户端同步](implementation/client-sync.md)、[个人资料库与并发编辑](implementation/catalog-library.md) |
| 功能与故障如何验收 | [测试策略与验收矩阵](testing/acceptance-matrix.md) |
| 当前服务端测试结果 | [同步测试](testing/server-sync.md)、[备份与部署验证](testing/backup-validation.md) |
| 同地址恢复后旧客户端的冻结请求和离线尾文会怎样 | [PG17实际恢复与两个Core客户端联合证明](testing/epoch-restore-two-clients.md) |
| 原生恢复世代与备份后新增资料怎样隔离验收 | [独立原生epoch环境与阶段守卫](testing/native-epoch-restore.md) |
| 源码Tab缩进如何兼顾键盘离开与辅助技术 | [真实键盘红绿、原生与VoiceOver边界](testing/keyboard-accessibility.md) |
| 导入与保存失败怎样只用合成目录重现 | [文件错误临时夹具与验收边界](testing/import-export-errors.md) |
| 地址错误、拒绝连接、非JSON与协议提示如何复验 | [连接原生夹具与实际边界](testing/connection-error-native.md)、[协议兼容提示修复](testing/protocol-compatibility.md) |
| 其余冲突选择、旧安装与图表编辑究竟缺什么证据 | [剩余矩阵分支核对](testing/remaining-matrix-evidence.md) |
| 附件503/截断后是否保留本机资料并恢复 | [真实HTTP失败与重试、受控原生计划](testing/attachment-download-recovery.md) |
| 本机资料显式复制到服务器是否保留原件 | [Mac实际复制与iOS读取的三方证明](testing/local-library-copy-native.md) |
| 当前客户端测试结果 | [客户端同步、隔离和检索验证](testing/client-sync.md)、[资料库与元数据验证](testing/catalog-library.md)、[AppModel 验证](testing/app-model.md)、[原生界面记录](testing/native-ui-validation.md) |
| iOS后台任务是否真正等待凭据并执行一轮同步 | [后台runner、取消预算与系统调度边界](testing/background-sync-runner.md) |
| 剩余工作如何按自动／原生／真实环境分配，以及千项前后怎么核对 | [下一轮具体任务与只读夹具工具](testing/next-acceptance-work.md) |
| 组合筛选、关联改名和摘录怎样用独立三篇资料验收 | [U7正常API夹具与真实Core预验证](testing/catalog-combined-native.md) |
| 下一组原生验收，以及已完成操作的独立数据证明 | [剩余原生验收与限定通过范围](testing/remaining-native-acceptance.md) |
| iOS专题成员移出/加回、删除还原是否保留原件 | [五阶段原生流程与Mac同步证明](testing/ios-topic-membership.md) |
| iOS同段冲突能否跨退出重开，AX显示与真正提交如何区分 | [冲突材料与只读核验](testing/ios-conflict-recovery.md) |
| 关联/来源打开为何不能沿用上一次搜索命中 | [导航意图红测与修复边界](testing/navigation-search-intent.md) |
| 连续输入遇到远端更新时光标是否稳定 | [原生交错控制、失败样本与修复边界](testing/native-markdown-interleaving.md) |
| 会话过期、离线修改与同段冲突如何在隔离库验收 | [原生故障控制方案与实际核验](testing/native-session-conflict-control.md) |
| iOS服务无响应时如何有界测试并自动恢复 | [暂停边界、内容基线与恢复证据](testing/ios-unresponsive-recovery.md) |
| 大资料库如何选择关联/摘录目标，窄窗口如何显示详情 | [可搜索资料选择器](testing/catalog-document-selection.md)、[资料详情布局与阅读记录可访问性](testing/catalog-inspector.md) |
| Markdown 如何保存、并发和离线渲染 | [编辑器实现](implementation/markdown-editor.md)、[50 项浏览器验证](testing/markdown-editor.md) |
| 编辑、同步回执和切库交错时如何保留最新输入 | [编辑并发实现](implementation/editor-concurrency.md)、[编辑并发回归](testing/editor-concurrency.md) |
| Markdown 如何带入图片与语音、如何处理相对链接 | [导入实现](implementation/markdown-import.md)、[导入回归](testing/markdown-import.md) |
| Markdown 如何导出附件与可独立阅读的来源说明 | [导出实现](implementation/markdown-export.md)、[导出回归与实际原生ZIP核验](testing/markdown-export.md) |
| PDF 高亮、中文批注、50 MB 样本和外部导出 | [PDF 批注实现](implementation/pdf-annotations.md)、[合成夹具与 SDK 验收](testing/pdf-fixtures.md) |
| iOS PDFKit 导出能显示却有结构缺陷时如何验证与修复 | [原生产物、SDK对照与严格序列化回归](testing/ios-pdf-export-serialization.md) |
| PDF 损坏/加密/超限拒绝、阅读恢复与来源定位 | [导入校验与拒绝验收](testing/pdf-import.md)、[阅读位置与版本隔离](testing/pdf-reading.md) |
| PDF恢复副本为何曾同步500，旧请求如何原样恢复 | [批注身份迁移、HTTP与两代备份验证](testing/pdf-recovery-annotation-identity.md)、[双端草稿恢复原生证明](testing/pdf-draft-recovery.md) |
| 如何安全准备PDF换版、验证旧批注/来源失效并恢复合成现场 | [正常API换版控制与限定执行记录](testing/pdf-version-control.md) |
| 千条资料检索、PDF位置保存与原生性能证据边界 | [性能实测记录](testing/performance.md) |
| iOS 便签、照片和语音的保存与生命周期 | [便签与语音验证及未覆盖范围](testing/ios-notes.md)、[录音输入隔离与真实文件收尾验证](testing/ios-recording-validation.md) |
| iOS真实软键盘输入是否保留空格，Mac只打开是否回写 | [源码输入、双端同步与只读证据](testing/ios-text-input.md) |
| 新Mac首次全量同步是否完整，输入复验使用哪个隔离根 | [Concurrent／Selection两次只读证明](testing/macos-initial-sync-proof.md) |
| iOS首次同步是否完整，更新包后PDF路径是否有效 | [首次资料与附件同步证明](testing/ios-first-sync-proof.md)、[容器迁移与PDF路径恢复](testing/ios-container-relocation.md) |
| iOS系统Files导出、外部预览和目录回导是否保留原件 | [ZIP、三方正文与图片字节核验](testing/ios-export-reimport-proof.md) |
| 如何准备可登录的iOS验证包与操作Device Hub | [模拟器签名和Keychain故障](testing/ios-simulator-signing.md)、[Device Hub进程绑定诊断](testing/devicehub-process-diagnostic.md) |
| 旧版本混合本机库如何升级 | [可信根兼容实现](implementation/legacy-library-roots.md)、[旧库迁移验证](testing/legacy-library-roots.md) |
| 如何独立准备多根旧安装、同名候选与孤儿资料验收 | [旧安装混合根夹具与Mac原生证明](testing/legacy-catalog-fixture.md) |
| 回收子文件夹、失效父级与同名还原 | [回收还原实现与验证](implementation/trash-recovery.md) |
| iOS分项还原后是否保留身份、显式移动是否恢复原层级 | [原生目录旅程与只读证明](testing/ios-trash-recovery.md) |
| 移除回收站资料的反向关联后，恢复是否会把关系复活 | [iOS关系、原父级和保留期限验证](testing/ios-related-trash.md) |
| 原生测试服务如何保留资料与会话升级二进制 | [隔离恢复实例升级证明](testing/restored-service-upgrade.md) |
| 早期测试和构建基线 | [服务端基线](testing/server-baseline.md)、[客户端基线](testing/client-validation.md) |
| 如何部署、排查和恢复 | [部署与连接排查](operations/deployment.md)、[备份、保留期与隔离恢复](operations/backup-restore.md) |
| 最初的需求与方案 | [功能设计 v1](legacy/功能设计-v1.md)、[技术方案 v1](legacy/技术方案-v1.md) |

## 文档规则

- `product/`：用户场景、信息架构、行为和可验收标准。区分用户已确认与设计建议。
- `research/`：代码证据、问题复现、外部官方来源、未验证假设。代码存在不等于端到端可用。
- `plans/`：按依赖排序的工作、范围、退出标准，不用估算百分比冒充完成度。
- `implementation/`：实际变更、数据兼容、取舍、回退方法与遗留问题。
- `testing/`：命令、环境、自动化结果、双端人工验收与未覆盖范围。
- `operations/`：部署、运行、凭据管理、备份恢复与故障处理；示例不含实际秘密。
- `legacy/`：原始文档原样保留，仅作历史依据；其中“尚未实施”和选型版本不能用来判断当前代码。

状态只使用“建议／待实施／实现中／代码完成／已验证／阻塞”。“已验证”必须指向实际执行证据，明确是单元测试、集成测试、构建还是双端验收；不同层次不能互相替代。

不在文档中保存密码、会话 Token、真实服务器配置或用户资料。现有 F01—F31 的完整交付要求继续保留；工程分组只表示实施顺序，不表示遗漏功能可当作最终交付。
