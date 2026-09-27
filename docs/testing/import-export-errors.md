# Markdown 导入与系统保存错误：原生验收夹具

2026-09-27 03:26，最初仅准备独立合成文件与只读取证工具，没有执行GUI或访问当前验收库。随后Root于03:32—03:34在独立Mac本机库完成下文原生闭环；本文维护者只读核对其六份快照与摘要，不操作GUI。已有Core234及客户端111证据不重复运行。

## 已验与待验范围

[Markdown 导入回归](markdown-import.md)已有自动验证：非 UTF-8、缺图片失败后没有文档、队列、传输或已安装附件；AppModel验证本地错误提示。此前原生已完成普通单文件/目录导入、损坏/加密/超过50 MB的PDF拒绝，以及成功的ZIP/PDF保存。本轮新增两种Markdown拒绝和系统保存失败后重试的Mac实际操作，按末节证据计；不扩展为iOS对应错误分支已通过。

## 独立夹具

目录：`/tmp/tokenlibrary-ui-fixtures/import-export-errors-20260927-nk09tj02`。`manifest.json`记录全部路径、大小、SHA256及权限；`README.md`包含逐步观察标准和只读取证方案。

| 相对路径 | 字节 | SHA256 | 用途 |
|---|---:|---|---|
| `imports/01-invalid-utf8.md` | 60 | `20db314dc19b02f864ae2d8c1100b9b707e4d607ec81c9c620e27b38d0ce9f60` | 含无效 `ff fe` 字节 |
| `imports/02-missing-relative-png.md` | 234 | `9a63fe2e80d092af5aede3cd6f68fdb98e26ad7feb747b0803174c50ad1d5818` | 有效UTF-8、真实图片节点引用不存在的PNG |
| `imports/03-valid-retry.md` | 223 | `4bd7c0ad0ab9fd472578b27d1dd4492c8e2d3698e82da31751a204c3d3ebbfa1` | 无附件的合法重试对照，含中文、emoji和尾换行 |

缺失图片为 `imports/missing/does-not-exist-20260927.png`；父目录存在，文件明确不存在，没有伪造它的hash。准备时独立检查了实际字节/hash、UTF-8解码结果和文件缺失，不打开资料库。

预期应用提示：

- 无效文本：`导入失败：Markdown 必须是有效的 UTF-8 文本。`
- 缺图：`导入失败：无法读取“missing/does-not-exist-20260927.png”。请确认附件存在，并授予笔记及附件所在文件夹的访问权限后重试。笔记未被导入。`

缺文件与没有目录授权共用后一个错误。单文件选择器拒绝不独立证明究竟是哪条系统授权分支；必要时正常授权整个 `imports` 目录再选同一笔记，仍不得注入文件或更改库。失败后合法对照应可重新选择并导入，按实际结果核验，不预标成功。

## 可恢复的导出目标

同一新目录内有空 `export-denied-mode0555`（权限0555）及 `export-retry`（0700）。准备时有效用户为501，`os.access(W_OK)`分别为false/true；没有实际运行失败写入探针，没有修改真实路径、删除目的父目录或启动故障服务。

Mac保存面板可使用绝对路径进入拒绝目录，尝试新文件名。**系统可能提前禁用保存或报不可写**，此时只算系统拒绝且能取消返回，不算应用收到 `fileExporter` 的failure回调。若提交返回应用，才预期 `导出失败：` 加系统本地化原因；不硬编码或猜测系统后半句。随后重新走导出入口，选择独立可写目录即可恢复，不需更改正文或失败目录权限。

普通所有者可更改权限、提权进程可能绕过限制，因此模式位不能保证任意身份都失败。iOS Files复制可能重设权限，这份Mac目标也不能直接当成iOS保存失败证据。

## 正文与队列保护取证

夹具目录的 `readonly-library-proof.py` 接受显式 `--library-root` 和全新的 `--output`。只允许临时TokenLibrary合成库或指定模拟器的合成验证base；用SQLite `mode=ro`、`query_only`和一致事务读取五张业务表，保存行数、每行hash、正文hash、待提交ID及冻结请求hash，另校验实际media文件。它不读凭据、sessions、sync_state，不创建/迁移/回写数据库；03:26准备阶段仅做语法检查，Root后续实际采样见下节。

在正文保存、同步静置后取baseline，每次失败后取单独after：文档与正文、原pending ID/payload/request、传输、草稿、索引计数及所有媒体bytes/hash应保持，错误Anchor笔记不出现。真正成功的合法重试导入允许新增一篇对照及其正常同步操作；成功导出本身不应改变正文或队列。

数据库事务和媒体读取不具备跨文件原子性，故须在GUI与同步静置时采样；工具对媒体读取前后stat发现变化时要求重取。后台同步若改变状态或收到远端对象，必须单独解释，不能把这些变化归因于导入错误，也不能忽略后硬称完全一致。已有`sent`、`superseded`记录不算待提交，只计`pending`、`awaiting_remote`、`needs_edit`。

## 03:32—03:34 Mac原生错误与恢复闭环

使用独立`navigationfinal`验证App的全新本机库：`/private/tmp/TokenLibrary-NavigationFinal-20260927-ov9kv52m/Local`。Root通过真实系统选择器与保存面板操作，没有通过脚本调用App导入或改数据库；本轮不影响既有服务器资料库。

| 阶段 / 只读时间 | 实际结果 |
|---|---|
| baseline / 03:31:02 | 五张业务表均空，媒体空、无待提交 |
| invalid-utf8 / 03:32:38 | 正确显示UTF-8中文拒绝；库快照hash完全等于空基线 |
| missing-png / 03:33:10 | 正确显示相对PNG路径和“笔记未被导入”；同样没有对象、队列、媒体或索引变化 |
| valid-retry / 03:33:37 | 正常导入唯一笔记`eae97cc2-9f12-4918-b649-dcf2bb7d4b54`，完整中文/emoji/末换行保持；只有一条正常本机pending |
| export-denied / 03:34:02 | 点击Export后实际返回App，显示“导出失败”加系统英文no permission原因；这是failure回调，**不是保存面板提前禁用**；拒绝目录仍空 |
| export-retry / 03:34:28 | 重新选择独立可写目标成功，输出223 B，SHA及全部字节精确等于合法输入；没有修改笔记或原pending |

六份证明为`/tmp/tokenlibrary-file-errors-native-{baseline,invalid-utf8,missing-png,valid-retry,export-denied,export-retry}.json`，汇总为`/tmp/tokenlibrary-file-errors-native-summary.json`。本页维护者独立读取这些文件，确认两次导入错误的五表/媒体/索引及整体snapshot hash均等于空基线；两次导出的snapshot hash均等于合法导入后的基线。原pending `fed374e7-91d8-4110-97ad-56a88e388f02`完整行和冻结字段保持，待提交1是独立本机笔记的正常持久操作，没有为了显示0删除它。

导出SHA-256为`4bd7c0ad0ab9fd472578b27d1dd4492c8e2d3698e82da31751a204c3d3ebbfa1`。根记录中的原生截图/AX负责证明提示和操作实际发生，JSON负责证明数据与字节保持，二者不互相替代。本轮操作闭合了Mac拒绝后继续导入、保存失败后换目标的恢复路径；系统权限详情仍为英文，不声称全部错误原因已中文化，也不泛化到iOS Files权限与任意系统故障。
