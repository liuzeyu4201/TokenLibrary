# TokenLibrary 文档中心

更新：2026-09-27。这里按读者和类别指向权威文档，不复制正文。

当前主线：**以书籍、论文和笔记为中心的个人资料库；先把保存、连接、同步、导出做可信，再增加资料组织与研究功能。**

## 按读者

| 你要… | 打开 |
| --- | --- |
| 理解个人图书馆怎么用 | [产品设计](product/personal-library-archive.md) |
| 看当前证据和未关闭项 | [开发与验收状态](testing/development-status.md) |
| 看实施顺序和退出标准 | [实施路线](plans/roadmap.md) |
| 查某类验收记录 | [测试索引](testing/README.md) |
| 看已经落地的改动 | [实施记录](implementation/README.md) |
| 部署、备份、恢复 | [部署与连接排查](operations/deployment.md)、[备份、保留期与隔离恢复](operations/backup-restore.md) |
| 看组件怎么分 | [架构](architecture/README.md) |
| 读 v1 原文 | [功能设计 v1](legacy/功能设计-v1.md)、[技术方案 v1](legacy/技术方案-v1.md) |

## 按类别

| 类别 | 权威文档 | 索引 |
| --- | --- | --- |
| 产品 | [个人图书馆与档案馆](product/personal-library-archive.md) | 本页 |
| 研究 | [体验评估](research/product-experience-audit.md)、[参考产品](research/reference-products.md)、[服务端可靠性调查](research/server-reliability-audit.md) | 本页 |
| 路线 | [实施路线](plans/roadmap.md) | 本页 |
| 架构 | [组件边界](architecture/README.md) | 该页 |
| 实施 | `implementation/` 下各篇记录 | [实施索引](implementation/README.md) |
| 验收 | `testing/` 下各篇证据 | [测试索引](testing/README.md)；完成度看 [总账](testing/development-status.md) |
| 运维 | [部署](operations/deployment.md)、[备份与恢复](operations/backup-restore.md) | 本页 |
| 归档 | [功能设计 v1](legacy/功能设计-v1.md)、[技术方案 v1](legacy/技术方案-v1.md) | 原文只放在 `legacy/` |

## 文档规则

- `product/`：用户场景、信息架构、行为和可验收标准。区分用户已确认与设计建议。
- `research/`：代码证据、问题复现、外部官方来源、未验证假设。代码存在不等于端到端可用。
- `plans/`：按依赖排序的工作、范围、退出标准，不用估算百分比冒充完成度。
- `architecture/`：与当前目录一致的组件边界。已落地的取舍写在对应 `implementation/` 记录里。
- `implementation/`：实际变更、数据兼容、取舍、回退方法与遗留问题。
- `testing/`：命令、环境、自动化结果、双端人工验收与未覆盖范围。
- `operations/`：部署、运行、凭据管理、备份恢复与故障处理；示例不含实际秘密。
- `legacy/`：原始文档原样保留，仅作历史依据；其中「尚未实施」和选型版本不能用来判断当前代码。

状态只使用「建议／待实施／实现中／代码完成／已验证／阻塞」。「已验证」必须指向实际执行证据，明确是单元测试、集成测试、构建还是双端验收；不同层次不能互相替代。

不在文档中保存密码、会话 Token、真实服务器配置或用户资料。现有 F01—F31 的完整交付要求继续保留；工程分组只表示实施顺序，不表示遗漏功能可当作最终交付。
