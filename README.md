# TokenLibrary

面向 iPhone、Mac 和自建服务器的个人资料库，重点管理书籍、论文、Markdown 笔记与 PDF 批注。

从 [文档中心](docs/README.md) 开始：

- [个人图书馆与档案馆设计](docs/product/personal-library-archive.md)
- [产品体验现状](docs/research/product-experience-audit.md)
- [实施路线](docs/plans/roadmap.md)
- [本轮变更](docs/implementation/2026-09-26-reliability.md)
- [测试与验收](docs/testing/acceptance-matrix.md)

当前已有本地存储、编辑/PDF、连接与提交队列、服务端 API 等实现；完整双向同步和新的书目/专题模型尚未完成，具体边界以实施与测试记录为准。

客户端工程：`clients/TokenLibrary.xcodeproj`。服务端开发入口：在配置好 `.env` 后依次使用 `make start mode=middleware`、`make start`；此默认 Compose 仅向宿主机回环端口暴露服务，不能当作已配置好的公网部署。运行这些命令会启动或重启服务。

原始设计分别保存在 [功能设计 v1](docs/legacy/功能设计-v1.md) 和 [技术方案 v1](docs/legacy/技术方案-v1.md)。
