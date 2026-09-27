# 同地址实际恢复与两个客户端的旧队列

2026-09-27 **02:31:02—02:31:11**，一个独立联合旅程通过：正式备份/验证/恢复命令、PostgreSQL 17、同一个 HTTP 地址、两个真实 Swift Core 客户端和各自持久 SQLite 库。覆盖 F04/F05/F13/F29 的恢复世代协调。没有调用原生 GUI、Keychain，也没有把重新打开 DocumentStore 称为应用进程重启。

这项把此前独立通过的 Core epoch 回归与 Jobs 真实恢复串起来。脚本只创建自己的随机容器、临时目录和 loopback 端口；既有 62036、51525、53056、56881 服务及原生资料库没有被停止、重建或修改。

## 实际流程与结果

| 阶段 | 可复核结果 |
| --- | --- |
| 初始内容 | 1 个目录、2 篇笔记、1 份归档 PDF，另有根目录。笔记共同引用同一 PNG，PDF 为真实可读三页合成论文。两客户端正文/metadata/媒体字节一致、可发送 0 |
| 正式备份 | 正常测试控制 API 触发正式 Jobs.RunBackup，再用 library-admin verify；PG17 custom dump 38,830 B，manifest 另含 PNG 50,786 B 与 PDF 74,791 B |
| 备份之后 | 两篇云端笔记各由 revision 1 推进到 3；随后 A/B 各在不同笔记上保存一个冻结请求，再新增本机尾文。各有 2 个可发送操作：1 个已冻结、1 个尚可改写的尾操作 |
| 同 URL 恢复 | 只停止自有进程，把备份恢复到同一自有 PG17 容器中的全新空数据库和空数据目录，再用相同二进制/端口 `50574` 启动。libraryId/rootId 相同，epoch 改变；恢复后首次登录前旧 sessions/operations 均为 0 |
| 旧会话与重开库 | 两个原 SyncClient 的真实请求均返回 401；重新打开两个 DocumentStore 后，最新正文、冻结 wire 和两条队列分别保持 |
| 重新登录 | 两端正常登录同 URL，接受较低的恢复 revision 1 和 cursor 4；各产生一个 `epoch_changed` 冲突。本机正文保留冻结请求之后的新尾文，旧请求 bytes 未重写且状态为 `conflict`，可发送数为 0 |
| 显式解决 | A 选择本机正文；B 使用自定义 Markdown，加一行独特的恢复说明。两端和服务器精确收敛 revision 2、cursor 6、可发送 0、开放冲突 0；旧冻结和尾操作成为 `superseded`，旧 operation ID 不在恢复服务的新回执中 |
| 媒体及源库 | 两客户端、原媒体目录、恢复媒体目录的 PNG/PDF bytes/size/SHA 相同；归档 PDF 始终 active、purgeAt=nil、归档 metadata 和 blob ID 保持。源库被观察的 library/object/current snapshot/blob/operation IDs 与数量、session 数量在恢复前后完全相等 |

恢复后的“可发送 0”不表示冲突自动解决。第四阶段明确保留两个各自阻塞的冲突；只有显式选择完成后，开放冲突才为 0。无修改的另一篇笔记则正常采用恢复后的较低 revision，不把较高旧 revision 当作不可回退的权威。

原 epoch 为 `5487c5b2-0051-4abc-8696-737c990f6dae`，新 epoch 为 `d043282f-06e0-44ab-817a-4d144826bf9d`，libraryId 为 `e99418d9-3689-4553-8799-099329e2a306`。A 最终正文 SHA-256 为 `d44014cad3239466dd584829eae776cada138393ca7caa282c24cd57460a7d45`，B 为 `dde1f28c4d0f9aabfbb3ad2a4f5681ff9a65af8940dcd7aec6e6b90b8642a689`。完整全文和结构化各阶段证据保存在本次合成输出中。

## 证据与重复执行

输出目录：`/private/var/folders/jd/9gz27bzs5d55xdmkf57mljx00000gn/T/tokenlibrary-epoch-restore-7nflcv9h`。

- `proof.json`：时间、已清理的自有容器、二进制/探针/归档 hash、备份 manifest、原/恢复媒体 hash 和明确的验证范围。
- `01-backup-baseline.json`、`02-advanced-source.json`、`03-restored-before-login.json`、`04-final-server.json`、`05-original-source-retained.json`：只读 PostgreSQL 内容证明，未选择 token/password/hash 列。
- `clients/01-before-backup.json` 至 `clients/05-final.json`：两个客户端逐阶段工作文档、队列状态、冻结 wire、冲突材料与最终服务端正文。
- `build.log`、`source-app.log`、`restored-app.log`、`probe.log`、`probe.stderr`：真实编译、pg 工具、应用和探针记录。结束时本次容器 `tl-epoch-79165effe87c` 与自有应用已清理，输出与备份文件保留。

使用 [Python 编排](../../tests/acceptance/verify_epoch_restore.py) 和 [Swift Core 探针](../../tests/acceptance/verify_epoch_restore.swift)。要求本机已存在 Docker 的 postgres:17、Swift/Go 和项目依赖，不安装系统依赖。先把当前 Debug 静态归档和模块复制到新的临时目录，避免占用其他人的 `.build`；编排拒绝直接使用活跃 `.build` 目录。仅合成资料作为输入：

```sh
python3 tests/acceptance/verify_epoch_restore.py \
  --core-products /var/folders/jd/9gz27bzs5d55xdmkf57mljx00000gn/T/tokenlibrary-epoch-fixed-core-p4sn6vxf/Debug \
  --fixtures /tmp/tokenlibrary-ui-fixtures
```

每次创建新目录、随机服务 URL、唯一容器和全新 restore 数据库。凭据为脚本内专门的合成账号，正常登录 token 只在进程内使用，不写证据。pg_dump/pg_restore 都来自这个自有 PG17 容器；真实启动补备份完成之后才开始业务用例，没有禁用定时器或伪造 jobs 行。

本次 Core 归档 SHA 为 `97917e491bb389ab92198bdef55ec9146d60a9a68a4fc90b00d48f3f69ffda03`，包含 [附件路径别名修复](attachment-path-aliases.md)。服务器 binary SHA 为 `45566091f3540478b8daea9786720e54bbdf6e76608de2b0e6937e4d4df764de`。这是一项独立集成旅程，不改变此前完整 Core218 或 Jobs10 的用例总数。

## 失败记录与剩余边界

编排准备期间的前两轮分别遇到启动补备份尚未完成的真实 `503 MAINTENANCE`、编排 readiness 循环缺少等待；均已清理自有资源。编排已改为只读等待真实启动任务成功和 maintenance=false。之后旧 Core 归档首次导入图片得到 `invalidPath`，证据保留在 `tokenlibrary-epoch-restore-lkj4qx7p/probe.stderr`；这是此前已由专项红测确认的附件路径别名问题。没有预建 media 目录绕开它，而是封存已修复归档后完整重跑联合旅程通过。

本项未操作生产环境；没有验证 GUI 的恢复世代提示/按钮、完整 App 退出重启、Keychain 恢复、同一文档两端同时解决冲突、备份之后才新建且远端完全缺失的文档、`editor_drafts` 恢复入口或客户端墓碑交互。真实03:00、连续7天保留观察与满盘/掉电仍另行验收。源库内容快照一致也不是整个数据库文件的物理位级一致或所有内部时间字段不变。
