# 测试索引

本页只列出现有验收记录，每篇只出现在一个分组里。完成度看总账的前两篇。

## 总账

| 记录 | 文件 |
| --- | --- |
| 全范围开发与验收状态 | [development-status.md](development-status.md) |
| 测试策略与验收矩阵 | [acceptance-matrix.md](acceptance-matrix.md) |
| 本轮剩余验收有限快照 | [next-acceptance-work.md](next-acceptance-work.md) |
| 第6项剩余矩阵：已有证据与最小原生分支 | [remaining-matrix-evidence.md](remaining-matrix-evidence.md) |
| 剩余原生验收：下一组可执行步骤 | [remaining-native-acceptance.md](remaining-native-acceptance.md) |
| 原生界面验证记录 | [native-ui-validation.md](native-ui-validation.md) |

## 同步、连接与恢复

| 记录 | 文件 |
| --- | --- |
| 客户端同步、隔离和检索验证 | [client-sync.md](client-sync.md) |
| 后端同步测试记录（2026-09-26） | [server-sync.md](server-sync.md) |
| 服务端测试基线 | [server-baseline.md](server-baseline.md) |
| 客户端验证记录 | [client-validation.md](client-validation.md) |
| iOS 后台恢复与同步生命周期 | [background-sync-runner.md](background-sync-runner.md) |
| 连接错误分类的原生有限验证 | [connection-error-native.md](connection-error-native.md) |
| HTTP 426 协议版本不兼容提示 | [protocol-compatibility.md](protocol-compatibility.md) |
| 原生会话过期与同段冲突：隔离控制方案 | [native-session-conflict-control.md](native-session-conflict-control.md) |
| 同地址实际恢复与两个客户端的旧队列 | [epoch-restore-two-clients.md](epoch-restore-two-clients.md) |
| 同地址恢复的原生验收准备 | [native-epoch-restore.md](native-epoch-restore.md) |
| 备份恢复后消失对象的冲突处理 | [epoch-missing-object-recovery.md](epoch-missing-object-recovery.md) |
| 附件下载失败、保留本机内容与正常重试 | [attachment-download-recovery.md](attachment-download-recovery.md) |
| 附件路径别名与首次写入 | [attachment-path-aliases.md](attachment-path-aliases.md) |
| 新Mac客户端首次全量同步证明 | [macos-initial-sync-proof.md](macos-initial-sync-proof.md) |
| iOS 首轮资料与附件同步：只读核验 | [ios-first-sync-proof.md](ios-first-sync-proof.md) |
| iOS 更新后本机 PDF 路径恢复 | [ios-container-relocation.md](ios-container-relocation.md) |
| 隔离恢复库的同实例二进制升级 | [restored-service-upgrade.md](restored-service-upgrade.md) |
| Mac 钥匙串等待造成启动界面阻塞 | [macos-keychain-startup.md](macos-keychain-startup.md) |
| iOS 模拟器验证包签名与 Keychain | [ios-simulator-signing.md](ios-simulator-signing.md) |
| Xcode 27 Device Hub 进程绑定诊断 | [devicehub-process-diagnostic.md](devicehub-process-diagnostic.md) |

## 编辑器与 Markdown

| 记录 | 文件 |
| --- | --- |
| Markdown 编辑器验证 | [markdown-editor.md](markdown-editor.md) |
| Markdown 导入回归 | [markdown-import.md](markdown-import.md) |
| Markdown 导出与来源说明回归 | [markdown-export.md](markdown-export.md) |
| 编辑并发回归 | [editor-concurrency.md](editor-concurrency.md) |
| 编辑器宿主加载、失败恢复与输入边界 | [editor-host-lifecycle.md](editor-host-lifecycle.md) |
| F12 原生持续输入与远端更新交错控制 | [native-markdown-interleaving.md](native-markdown-interleaving.md) |
| 排版模式远端更新与持续输入 | [rich-editor-selection.md](rich-editor-selection.md) |
| U8 键盘路线与读屏证据边界 | [keyboard-accessibility.md](keyboard-accessibility.md) |
| iOS真实软键盘输入与Mac只打开不回写 | [ios-text-input.md](ios-text-input.md) |

## PDF

| 记录 | 文件 |
| --- | --- |
| PDF 导入拒绝与原件保留 | [pdf-import.md](pdf-import.md) |
| PDF 阅读位置验证 | [pdf-reading.md](pdf-reading.md) |
| PDF 夹具与 SDK 验收 | [pdf-fixtures.md](pdf-fixtures.md) |
| PDF 恢复草稿的原件身份 | [pdf-draft-recovery.md](pdf-draft-recovery.md) |
| PDF 恢复副本的批注身份与同步修复 | [pdf-recovery-annotation-identity.md](pdf-recovery-annotation-identity.md) |
| PDF 换版：正常 API 控制方案 | [pdf-version-control.md](pdf-version-control.md) |
| iOS 批注 PDF 导出结构回归 | [ios-pdf-export-serialization.md](ios-pdf-export-serialization.md) |

## 资料库、导入导出与回收站

| 记录 | 文件 |
| --- | --- |
| 个人资料库测试记录 | [catalog-library.md](catalog-library.md) |
| Catalog 组合筛选、关联改名与摘录验收夹具 | [catalog-combined-native.md](catalog-combined-native.md) |
| 资料关联与摘录目标选择 | [catalog-document-selection.md](catalog-document-selection.md) |
| 资料详情窄窗口与阅读记录可访问性 | [catalog-inspector.md](catalog-inspector.md) |
| 普通关联导航与搜索定位的区分 | [navigation-search-intent.md](navigation-search-intent.md) |
| 旧版混合本机库根兼容测试 | [legacy-library-roots.md](legacy-library-roots.md) |
| 独立旧安装混合根夹具 | [legacy-catalog-fixture.md](legacy-catalog-fixture.md) |
| 本机资料显式复制：原生与内容证明 | [local-library-copy-native.md](local-library-copy-native.md) |
| Markdown 导入与系统保存错误：原生验收夹具 | [import-export-errors.md](import-export-errors.md) |
| iOS 系统导出、Files 预览与目录回导 | [ios-export-reimport-proof.md](ios-export-reimport-proof.md) |
| iOS 多级目录、分项还原与显式移动 | [ios-trash-recovery.md](ios-trash-recovery.md) |
| iOS 在回收站中移除反向关系并恢复 | [ios-related-trash.md](ios-related-trash.md) |
| iOS 专题成员、删除和还原 | [ios-topic-membership.md](ios-topic-membership.md) |

## 便签、冲突、备份、性能与模型

| 记录 | 文件 |
| --- | --- |
| iOS 便签与语音验证 | [ios-notes.md](ios-notes.md) |
| U9：录音输入隔离、收尾时长与验收边界 | [ios-recording-validation.md](ios-recording-validation.md) |
| iOS 同段冲突、稍后处理与重开证明 | [ios-conflict-recovery.md](ios-conflict-recovery.md) |
| iOS服务无响应时的离线内容与恢复 | [ios-unresponsive-recovery.md](ios-unresponsive-recovery.md) |
| 备份、恢复与部署验证 | [backup-validation.md](backup-validation.md) |
| 性能实测与证据边界 | [performance.md](performance.md) |
| 客户端模型与路由回归测试 | [app-model.md](app-model.md) |
