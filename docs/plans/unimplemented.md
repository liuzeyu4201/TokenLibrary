# 待实现

更新：2026-09-27。这一页按设计文档对照当前代码，不把「还没做完原生验收」写成「还没实现」。

## 对照了哪些文档

| 文档 | 用它判断什么 |
| --- | --- |
| [功能设计 v1](../legacy/功能设计-v1.md) | 已确认的 F01—F31，以及标成设计默认的 D01—D08 |
| [技术方案 v1](../legacy/技术方案-v1.md) | 接口、同步通知、上传权限、文件校验和登录限制 |
| [个人图书馆与档案馆](../product/personal-library-archive.md) | 后来确认的书籍、论文、笔记方向，以及尚未决定的扩展 |
| [实施路线](roadmap.md) | 哪些扩展明确暂缓 |
| [开发与验收状态](../testing/development-status.md) | 区分「代码已经有」和「某次旅程还没验」 |

技术方案里写着「尚未实施」的段落只作历史合同，不直接当成今天的代码现状。产品设计第 2 节是 2026-09-26 修改前的基线，同步、书目和专题后来已经有实现，也不再整节抄进本页。

判定规则：

- 设计要求在当前代码里没有对应入口或合同行为，才写入下面的表。
- 代码已经有、只差 iPhone、Mac、公网或长时间观察的证据，留在验收账本，不记成待实现。
- 产品设计写了、但这次没有逐个界面核对的字段和视图，不写成已经确认缺失。

## 功能设计里已补上的行为

功能设计的 F01—F31 大多已经有代码。下面两项原先缺入口或合同行为，2026-09-27 已补上，不再当作缺口。

| 来源 | 现在的行为 | 测试 |
| --- | --- | --- |
| 功能设计 3.3；产品设计 4.1、旅程 E | 资料详情的「更换 PDF 原件」把新文件接到同一条目。旧批注标为 `needs_review`，摘录哈希不再匹配，上一份原件留在本机。同名导入仍使用 `_数字` 后缀。 | `swift test --filter testReplacingPDFOriginalKeepsTheItemAndMarksOldCoordinatesForReview` |
| 功能设计 F26、7.4；技术方案 6.3 | `GET /api/v1/imports/{operationId}` 只返回该上传的处理状态和新条目身份。会话操作返回 404。`GET /api/v1/objects/:id` 对上传令牌仍是 401。 | `go test -count=1 ./internal/api -run TestUploadTokenImportStatus` |

同名文件使用 `_数字` 后缀、不覆盖原件，这是 F17 已经确认并且已经实现的行为。产品设计里的「提示已在库中并打开旧资料」是后来的建议，不能把它写成 F17 没做。

## 技术方案里已补上的行为

| 来源 | 现在的行为 | 测试 |
| --- | --- | --- |
| 技术方案 4.7 | 已登录连接升级为 WebSocket。服务器发送 `changes_available`，只含 epoch 和最新序号，并回答 ping。断开后重连仍能收到后续通知。通知丢失时 `GET /api/v1/sync/changes` 仍能拉到期间的变更。 | `go test -count=1 ./internal/api -run TestChangesAvailableDoesNotReplaceHTTPPull` |
| 技术方案 8.1 | 同一连接地址 15 分钟内最多 10 次登录失败。未配置 `TRUSTED_PROXY_CIDRS` 时不采用 `X-Forwarded-For` 或 `X-Real-IP`。同时最多两次口令校验，超出的请求返回 429，不把账号永久锁死。 | `go test -count=1 ./internal/api -run 'TestServerContractGaps|TestLoginLimitUsesTheConnectionPeer'` 与 `go test -count=1 ./internal/authn -run TestLoginGateRejectsExcessFailuresAndConcurrentVerifies` |
| 技术方案 7.2 | `POST /api/v1/blobs/{id}/repair` 只接受状态为 `unavailable`、且字节与原哈希和大小一致的内容。不一致时不改状态。 | 同上 `TestServerContractGaps` |
| 技术方案 7.1 | 服务端识别 PDF 头和 `/Encrypt`。需要打开密码的文件在 `blobs.password_required` 标为真。客户端仍会在导入前拒绝这类文件。本环境没有把 qpdf 当作必须的外部进程。 | `go test -count=1 ./internal/pdfcheck -run TestPasswordProtectedPDFIsMarked` 与 `TestServerContractGaps` |

下载接口已经声明 `ETag` 和 `Accept-Ranges`，并由 Go 的文件响应处理 Range。备份在可用空间低于 1 GiB 时会拒绝。这两项不记成缺失。技术方案里的 500 MiB 上传预留、最多 4 路并行接收、图片 4000 万像素和 SVG 拒绝，这次没有逐项搜索完，先不写成结论。

## 产品设计里尚未决定的扩展

这些在产品设计第 1 节和第 10 节标成尚未确定或更后的优先级。路线也把它们列为暂缓。当前交付不依赖它们。

| 能力 | 文档里的位置 | 状态 |
| --- | --- | --- |
| EPUB 阅读 | 产品设计第 1、10 节 | 建议，待实施。只增加文件后缀不算完成。 |
| BibTeX / RIS 导入导出 | 产品设计第 10 节 | 建议，待实施。不自动下载全文。 |
| DOI、ISBN、arXiv 在线补全 | 产品设计 4.2、第 10 节 | 建议，待实施。必须由用户触发，失败后仍可手填。 |
| 正式引用样式 | 产品设计第 1、10 节 | 建议，待实施。 |
| 智能检索、AI 问答 | 产品设计第 1、7、10 节 | 不作为当前主线。 |
| 扫描件 OCR | 功能设计 F11；产品设计第 10 节 | 已确认不做。现有搜索只使用 PDF 已有文字层。 |
| 保存的搜索、整库或专题导出包、网页收集 | 产品设计第 6、10 节 | 建议，待实施。单篇 Markdown、带批注 PDF 和图片包已经另有实现。 |
| 纸质书只登记、不附全文 | 产品设计第 1、4.1 节 | 尚未确定。这次没有把它写成已经有的「未添加全文」状态。 |

## 设计里明确不做

- 功能设计 F14：不提供把一篇笔记恢复到过去某一稿的界面。内部修订只服务合并和同步。
- 功能设计 F10：不做手写批注。
- 产品设计第 6 节：归档不是删除，也不是备份成功。

## 已经有实现、不要记成待实现

功能设计里的本地副本、离线队列、Markdown 与 PDF、高亮和文字批注、本机搜索、回收站 30 天、每日备份、备份期间暂停云端写入、固定账号，以及产品设计里的书籍、论文、笔记、收件箱、专题、阅读位置、摘录和归档，都已经有代码和分层测试。

公网证书签发、真机后台是否被系统调度、连续多日备份观察，以及尚未跑完的原生旅程，缺的是那一次实际执行。清单在 [开发与验收状态](../testing/development-status.md)。
