# 实施记录

这里索引已经落地的变更。每篇记录自己写取舍、兼容和遗留问题；本页不另作完成判断。验收证据在相邻的测试记录里，总账是 [开发与验收状态](../testing/development-status.md)。

| 实施记录 | 对应验收 |
| --- | --- |
| [研究与第一批连接、资料保护修复](2026-09-26-reliability.md) | [客户端验证记录](../testing/client-validation.md)、[服务端测试基线](../testing/server-baseline.md) |
| [同步服务合同](2026-09-26-sync-server.md) | [后端同步测试记录](../testing/server-sync.md) |
| [客户端双向同步与本机资料库](client-sync.md) | [客户端同步、隔离和检索验证](../testing/client-sync.md) |
| [个人资料库实现记录](catalog-library.md) | [个人资料库测试记录](../testing/catalog-library.md) |
| [Markdown 编辑器与保存协议](markdown-editor.md) | [Markdown 编辑器验证](../testing/markdown-editor.md) |
| [Markdown 与本地图片、语音导入](markdown-import.md) | [Markdown 导入回归](../testing/markdown-import.md) |
| [Markdown 与来源说明导出](markdown-export.md) | [Markdown 导出与来源说明回归](../testing/markdown-export.md) |
| [编辑并发与恢复草稿](editor-concurrency.md) | [编辑并发回归](../testing/editor-concurrency.md) |
| [PDF 批注与可移植导出](pdf-annotations.md) | [PDF 夹具与 SDK 验收](../testing/pdf-fixtures.md) |
| [旧版混合本机库根目录兼容](legacy-library-roots.md) | [旧版混合本机库根兼容测试](../testing/legacy-library-roots.md) |
| [回收还原的原子性与范围](trash-recovery.md) | [iOS 多级目录、分项还原与显式移动](../testing/ios-trash-recovery.md)、[iOS 在回收站中移除反向关系并恢复](../testing/ios-related-trash.md) |
