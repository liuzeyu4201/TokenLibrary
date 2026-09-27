# 2026-09-26：研究与第一批连接、资料保护修复

状态：本轮代码变更已落地，验证结果见[客户端验证记录](../testing/client-validation.md)与[服务端基线](../testing/server-baseline.md)。**这不是完整双向同步或个人图书馆新模型的交付声明。**

## 文档体系

建立 docs/product、research、plans、implementation、testing、legacy。原根目录功能设计与技术方案原样保存到 legacy，根文件改为跳转说明；新的设计区分已确认范围、建议和未完成项。设计以书籍、论文和笔记为主，收件箱、专题、可逆归档共用同一库。

## 连接与反馈

- 移除主界面里写死的服务器和明文默认密码，服务器由用户配置；仅记住服务器、用户名和设备 ID，不在普通偏好存密码或 Token。
- 新增完整地址规范化、只读 GET `/health/ready` 连接测试、15 秒默认请求超时、连接中状态、取消及手动重试。
- 断网、DNS/连接失败、超时、证书、ATS、401/403/409/429/503、无法解析的响应分别提供中文原因和下一步。登录本身不自动重试。
- 幂等提交和健康检查有界重试；默认最多三次，默认退避 0.35/0.7 秒，尊重 Retry-After；超过本轮等待预算交回界面，不提前重发。
- 提交错误不再被 `try?` 隐藏。UI 通过单个工作任务串行提交，期间的新编辑会安排后续轮次；认证失效转为本机使用并提供重新登录入口。
- 健康正常、登录成功、提交确认与全库同步分别表达；界面明确远端下载与附件同步仍未接通。

代码：[ConnectionSupport.swift](../../clients/LibraryCore/Sources/LibraryCore/ConnectionSupport.swift)、[SyncClient.swift](../../clients/LibraryCore/Sources/LibraryCore/SyncClient.swift)、[TokenLibraryRoot.swift](../../clients/Shared/TokenLibraryRoot.swift)。

## 本地队列与数据保护

SQLite 增量迁移增加冻结请求相关列，不重建/清空旧资料：

- 首次发送前把完整 JSON、operationId、base revision、设备、epoch、服务器地址持久化，失败、取消、重启复用相同请求。
- 已冻结的操作不再被后续编辑覆盖。后续编辑建立新的操作，只能合并尚未发送的尾部修改。
- 回执只确认对应操作；不会覆盖本地正在编辑的正文或把后续操作一起标为完成；重复回执不降低版本。
- 同一对象的未解决冲突阻止后续发送。库/设备/世代不匹配时保留原请求并提示，不能换身份后盲发。
- 按登录库 root 过滤待提交对象，避免把未绑定的 `root` 本机文档直接提交到服务器；保留旧库，不进行自动迁移。
- 创建在途期间发生移动/改名，后续操作须保持结构变更语义，不能仅作为正文更新发送。
- 回执表明云端已发生未知版本合并时，冻结操作进入 `awaiting_remote`，重启后仍暂停；在远端拉取与重新合并完整实现前，不盲目提高下一操作的基准去覆盖他端内容。

`awaiting_remote` 是资料保护状态，不是已完成同步。当前版本没有解除该状态的完整流程；本机编辑/导出仍可使用，后续 B 组需取回云端材料并协调本机修改。

升级前 v1 请求没有完整原始字节记录。如果此前已在服务器处理但客户端没收到结果，无法凭空恢复原请求。相关幂等错误会保留资料并报告，不能宣称全部历史异常已经自动修复。

代码：[DocumentStore.swift](../../clients/LibraryCore/Sources/LibraryCore/DocumentStore.swift)、[队列回归测试](../../clients/LibraryCore/Tests/LibraryCoreTests/QueueReliabilityTests.swift)。

## 实际操作流程

- 登录页可进入本机文档；退出登录后仍可使用本地资料。
- 记住最后浏览目录，并提供已保存资料库入口，避免重启后只看见默认 root 而误以为资料丢失。
- 停止自动生成演示数据，移除反复覆盖演示文档的设置按钮；既有演示/用户资料仍保留。
- 新建、改名、移动、删除、还原、正文保存与批注保存错误有提示；导入不再把读取失败或非 UTF-8 当作空正文保存。PDF 校验可读性与 50 MB 上限。
- Markdown 和带批注 PDF 的导出接入系统文件保存流程，取消/失败/成功有不同结果。iOS 保存失败不会继续导出旧内容。
- Markdown 当前只导出源码，按钮明确“不含附件”；图片/语音附件打包仍待实现，不能把源码当作完整迁移备份。
- WebView 使用 JSON 参数传递 Markdown，反引号、`${...}` 和换行不会作为 JavaScript 模板插值执行。
- Xcode 项目补上缺失的 `XCLocalSwiftPackageReference`；原工程直接命令行构建报 Missing package product LibraryCore，修复后两端编译通过。

Debug 构建提供 `--verification-directory <绝对路径>`，使用独立 SQLite 和偏好套件做界面验证；Release 不接受该调试路径。该入口未在真实资料库上使用。

## 本轮未完成的能力

完整远端拉取与附件传输、Keychain 会话续期、首次全库同步/epoch 重建、本机资料显式迁入、冲突解决 UI、正式 Markdown/Mermaid/KaTeX、批注完整改删、带附件 Markdown 导出、备份恢复与 HTTPS 部署，以及书籍/论文元数据和专题关系，均按[实施路线](../plans/roadmap.md)继续。

## 兼容与回退

- 工作目录当前无 Git 元数据，本轮没有创建提交或声称存在可用 commit。
- docs/legacy 保留两份设计原文。真实 `.env`、服务器写入、用户本地文档均未作为测试素材。
- SQLite 升级为 additive migration，但旧 GRDB 迁移器可能拒绝较新 schema。**不能直接用旧二进制打开升级后的库来当回退方案。** 正式升级前应备份 SQLite/附件，在隔离副本完成升级及重启验收；回退必须恢复同一时点的数据副本。
- 部署文件和真实服务本轮未修改/重启；公网只做一次无凭据健康检查。
