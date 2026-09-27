# PDF 导入拒绝与原件保留

2026-09-26 22:49，以下为 Core 与 AppModel 自动测试证据。系统文件选择器与错误弹窗的实际操作由[原生验证记录](native-ui-validation.md)单独记录；本页不将模型测试算作原生验收。

## 修复范围

之前的导入路径将 `PDFDocument.isLocked` 与损坏文件合并为 `fileReadCorruptFile`。现在 [PDFImportValidation.swift](../../clients/LibraryCore/Sources/LibraryCore/PDFImportValidation.swift) 区分需要打开密码、无法解析页面、无法读取文件与超过大小上限；[AppModel](../../clients/Shared/TokenLibraryRoot.swift) 在创建附件或文档之前调用该校验器，并显示中文原因与下一步。

上限为 50,000,000 字节。先检查文件尺寸，实际读取按 1 MiB 分块且最多读取上限加 1 字节，防止文件在尺寸检查后变大而无限读取。导入不重写原件；只有 owner 密码但可直接读取的加密 PDF 仍可导入。需要打开密码的文件明确提示先使用 PDF 阅读器解锁并另存无需打开密码的副本；目前不提供应用内输密码解锁。

PDFKit 可读取至少一页是本地基本校验，不等于对全部 PDF 对象、渲染和第三方兼容性作完整验证。

## 自动回归

执行命令：

```sh
swift test --package-path clients/LibraryCore --filter PDFImportValidationTests
swift test --package-path clients --filter PDFImportModelTests
```

| 范围 | 证据 |
| --- | --- |
| Core 5 项 | 22:48:32 全部通过；需要密码与损坏区分、owner-only 加密可读、空/伪/无页面文件拒绝、目录/缺失文件拒绝、真实可读 PDF 的 50,000,000 / 50,000,001 字节边界 |
| AppModel 2 项 | 22:49:24 全部通过；每类拒绝均保持原选择、文档、待同步队列与媒体目录；可读加密 PDF 导入后原件字节与 hash 保留 |

日志为 `/tmp/tokenlibrary-pdf-import-tests.log` 与 `/tmp/tokenlibrary-pdf-import-model-tests.log`。构造有意损坏 PDF 时 PDFKit 输出一条解析诊断，测试断言它被明确拒绝。模型超限输入使用稀疏文件验证拒绝无副作用；Core 边界使用真实引用的文本流；以下原生夹具使用真实图像页，三者的证据用途不同。

## 原生拒绝夹具

[generate_pdf_rejection_fixtures.py](../../tests/fixtures/generate_pdf_rejection_fixtures.py) 只读取既有合成研究 PDF 和大 PDF，不重新生成或修改它们。使用带 pypdf 的 workspace Python 运行，默认输出到 `/tmp/tokenlibrary-ui-fixtures`：

| 文件 | 字节 | 内容与预期 |
| --- | --- | --- |
| encrypted-password.pdf | 75,935 | 三页合法 AES-256 加密 PDF，打开密码为合成值 `synthetic-reader`；提示需要打开密码，不报损坏 |
| corrupt.pdf | 74 | 有意缺失对象与 trailer；提示可能损坏或不是有效 PDF |
| oversize-valid.pdf | 55,998,421 | 九页合法 PDF，增加的大小来自实际引用的图像页，无 EOF 填充；提示超过 50 MB |

严格解析器已验证加密文件解锁后有三页，超限文件九页均有文字且所有页面内容流与图像流可解码。各文件 hash 与预期保存在同目录 `pdf-rejection-manifest.json`。这一步尚不代替原生弹窗验证。

## 读取时延边界

直接编译仓库当前校验器，对既有 49,745,911 字节夹具连续运行五次：完整读取与首次页面校验耗时为 80.43、9.79、8.62、10.18、9.29 毫秒；超限夹具在尺寸检查处返回，五次均低于 0.03 毫秒。证据为 `/tmp/tokenlibrary-pdf-import-probe.json`。首样本包含 PDFKit 初始化，后续有系统缓存，样本不足以作为稳定性能承诺。

该改动限制读取量，仍沿用现有同步导入调用；上述数字不包含后续 hash、附件落盘、数据库、上传和 UI 响应时间，也未证明 iPhone 的交互与内存表现。

## 原生拒绝后的独立资料库核对（23:05）

主验收已实际尝试导入三份拒绝夹具。23:05对恢复服务53056的PG与其Mac本机SQLite进行只读检查：在所有状态的PDF对象中，按文件名或metadata.originalFilename匹配 `encrypted-password.pdf`、`corrupt.pdf`、`oversize-valid.pdf`，两侧均为0条。全工作区未完成队列也为0。此结果证明本次拒绝没有留下对应的成功文档对象，不将其扩大为对全部历史附件或瞬态文件的审计。

独立证据 `/tmp/tokenlibrary-native-image-export-readonly-proof.json` 的 rejected_pdf_names、rejected_native_objects、rejected_server_objects和unfinished_queue字段。检查未修改数据库、服务或输入夹具。

原生尝试还发现错误反馈问题：本地导入错误原先混入connectionError，会被下一次后台同步成功清除。现已分离本地操作错误、提供关闭入口并补后台成功仍保留损坏原因的真实AppModel调度测试；修复后的27项模型回归是当时记录，23:56完整模型51项及00:14最新56项均通过，见[模型记录](app-model.md)。23:00前后的Mac实际复测已分别显示密码、损坏、超限原因，手动及后台同步成功后本地导入错误仍保留，关闭后清除，见[原生验证记录](native-ui-validation.md)。iOS后续限定结果见下一节。最新23:59:14完整Core204项（含PDF导入5项）通过、0失败/跳过，不代替用户界面证据。

## iOS单文件入口修复、同名导入与三类拒绝（2026-09-27 00:19—00:23）

原生此前发现同视图叠加两个fileImporter导致“Markdown或PDF文件”入口不呈现，目录入口正常。现统一单个呈现器并保存明确请求/模式，00:14完整56项模型通过，00:16双端构建/签名/源码hash核验通过；主验收00:17:45安装新的iOS验证包后实际复验：

| 原生步骤 | 实际观察 |
| --- | --- |
| 00:19打开单文件导入 | 系统文件选择器出现；取消后无错误、待提交0，再次打开成功 |
| 00:19:40合法研究PDF | 实际选择research-three-pages.pdf，导入后3页可读，自动同步归零 |
| 00:20损坏PDF | 显示损坏原因；点击立即同步成功，最近成功推进至00:20:23，但本地导入错误继续保留 |
| 00:20:55需要密码PDF | 明确要求解锁并另存无需打开密码的副本，没有把原因写成损坏 |
| 00:21:07超限PDF | 55,998,421 B输入明确提示50,000,000 B上限；三次拒绝均待提交0，无虚假已导入提示 |

00:23:25独立只读核验，证据 `/tmp/tokenlibrary-ios-pdf-import-proof.json`，可复查脚本 `/tmp/tokenlibrary-verify-ios-pdf-import.py`：

- 新文档为 `afecb79c-e124-4869-bbff-a72bafcbb684`，根目录 `research-three-pages_2.pdf`，revision1；自动后缀避开此前根目录同名和 `_1` 的两份资料，ID独立。
- 输入夹具、iOS实际原件和服务器blob `5865785e-b346-44d5-8643-ef9559b9a386` 均74,791 B，SHA-256 `5e75077459f63545f07f55a4862c27275a218a41635f50ddfa6635eb3759f424`；pypdf strict再次解析为3页。旧11个PDF的ID全部保留，原 `32e7f3ee…` 的本机字节/hash不变。
- 对照00:15既有证明，iOS只新增这1个PDF和1条附件传输记录。按三份拒绝文件名/metadata.originalFilename查询所有状态的PDF对象为0，按名称查询本机待提交及历史操作为0；按三份输入hash查询本机传输表、实际media文件、服务器blob和upload均为0。三份源夹具实际大小/hash仍等于预先保存的manifest。
- iOS全工作区未完成队列0。此时Mac正在换包启动，SQLite尚无新合法PDF，但未完成队列也为0；这一快照只证明iOS与服务器收敛，不把尚未运行客户端未拉取判成同步故障，也不提前宣布三方新PDF已齐。

本段关闭实际iOS单文件选择器呈现/取消/重开、合法同名导入、三类PDF拒绝以及同步成功不清除损坏提示。当前存储检查及前后基线不证明导入过程曾不存在任何瞬态、未登记临时文件；读权限变化、强杀、全部加密变体与iOS带批注PDF导出仍需各自证据。
