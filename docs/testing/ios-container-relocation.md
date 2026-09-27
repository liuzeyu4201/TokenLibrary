# iOS 更新后本机 PDF 路径恢复

2026-09-26 原生验收发现：签名验证包覆盖安装、保留原库并恢复登录后，搜索覆盖从仅 1 份无文字层变为 11 份 PDF 尚未下载。同步仍报告资料与附件已完成。

## 只读证据

验证设备 `CDC55D3E-C4BB-43A3-B3C1-8789492A1D08`、验证 bundle `app.tokenlibrary.verification`。升级前数据容器 UUID 为 `E08DE3B6-AF0A-4390-8990-95B42949DF80`，升级后为 `EE8A9191-2CAF-4840-9681-A9D71E6A52D1`。

仅读取合成验证库的 SQLite 与文件存在性，未读取凭据或修改模拟器库：

- `working_documents.pdf_path` 的 11 个 PDF 绝对路径全部仍指旧容器，11 个路径都已不存在。
- 同样的 11 个文件全部存在于新容器中的对应库目录。
- `blob_transfers.local_path` 的 21 条记录均为相对路径，21 个文件均在新容器中。因此附件同步能发现文件已经完整，而 PDF 阅读器与覆盖统计仍使用失效的绝对路径。
- 详细合成路径证据：`/private/tmp/tokenlibrary-ios-container-relocation-proof.json`。

## 修复

`DocumentStore` 完成 schema 迁移后，每次开库执行 `LibraryPathRecovery`，在一个 SQLite 事务内恢复本机路径。新库记录上次自身根目录；没有该记录的旧库通过 PDF 的 blob ID 与已登记、可读的相对附件路径恢复。可确认的旧根也用于迁移尚未上传的本地 PDF。

恢复范围包括 `working_documents.pdf_path` 和持久批注草稿的 `expectedPDFPath`、`originalDocument.pdfPath`。旧版 PDF 草稿始终依据自身版本/路径恢复，不改为当前新版。候选文件必须在当前库内并可读；符号链接逃逸与无法确认的外部路径不猜测重映射。无法定位的文件仍保持缺失状态。

这是本机位置修复，不是资料编辑：不会增加 revision、localGeneration 或待提交操作，不改变冻结请求、草稿 ID、创建/更新时间、批注和资料信息。修复的 PDF 会重新建立正文索引，覆盖之前因旧路径失效而丢失页索引的情况。网络快照与冻结请求原本不包含 `pdf_path`，无需改变它们。

该逻辑每次开库执行，支持之后再次发生容器迁移；不能仅放入只运行一次的 schema 迁移。

## 回归

专项命令：

```sh
cd clients/LibraryCore
swift test --disable-sandbox --skip-update --filter 'LibraryPathRecoveryTests|EditorEditTests|SearchCoverageTests'
```

迁移专项覆盖安装目录搬迁后的 PDF/附件读取与搜索、冻结队列和版本保持、无根标记旧库兼容、未上传 PDF、连续两次搬迁、删除后的批注草稿、旧版/新版文件隔离、两库相同 blob ID/文件名但不同文件内容隔离，以及缺文件/符号链接边界。`23:53:55` 合计 23 项通过、0 失败：7 项路径恢复、15 项编辑、1 项搜索覆盖。测试日志为 `/private/tmp/tokenlibrary-path-recovery-tests.log`。

跨库检查确认映射仅来自当前 `DocumentStore.db` 的附件登记，文件候选只解析到当前 root 内；不会扫描其他库以寻找相同 blob ID。另一个实现代理独立只读复核，未发现确定缺陷。

合并修复验证包：`/private/tmp/tokenlibrary-ios-relocation-signed-ddz11za3/DerivedData/Build/Products/Debug-iphonesimulator/TokenLibrary.app`。最初 `23:52:04` 的路径专项包未安装，等待编辑器冻结后复用相同 DerivedData 重建。`23:55:06` 最终核验通过，包含路径恢复、IME 并发修复与便签文字/图片的 4 行无障碍标识补充，供一次同库覆盖安装验收。

- 严格签名校验通过；Bundle ID `app.tokenlibrary.verification`、中文显示名和局域网说明正确，arm64 模拟器身份节包含正确 application-identifier。
- 109 个 Swift、Info.plist 和编辑器资源构建前后 hash 一致。同目录上方保存 `build.log`、`verification.json`、`source-hashes.json`；之前的 `23:52` 记录以 `before-ime-` 前缀保留。
- 包内 `editor/editor.js` SHA-256：`07d7c4bf465cfca141a0dd65ba3890d409cd7086c00f898785f60db1363348ae`，与通过 29 项浏览器测试的冻结编辑器一致。
- 可执行文件 SHA-256：`18a83d35151f7e06bb50d8842b6a98ea1920325c496f5a4e7d41e6d084843f9a`。
- 完整包归档 `/private/tmp/tokenlibrary-ios-relocation-signed-ddz11za3/TokenLibraryVerification.app.zip` SHA-256：`58479bcc22eeb1e182514713e6f12b1f0aa340207257a14d6729f2533410eb43`。

上述构建任务仅生成产物，没有安装或改写模拟器库。随后 Root 完成下面的原生覆盖安装与复验。

## 覆盖安装后的实际复验

Root 于 `2026-09-26 23:56` 原位安装合并包，保留资料与登录会话。当前容器为 `8CC43DB8-BDB6-4EE6-B9BB-459CD20F44B4`。`2026-09-27 00:15:17 +08:00` 独立只读取样结果保存在 `/private/tmp/tokenlibrary-ios-post-upgrade-export-proof.json`：

| 项目 | 实测 |
| --- | --- |
| PDF 绝对路径 | 11/11 均在当前库根内，文件全部可读 |
| 所有附件 | 23/23 实际字节数、SHA-256 与登记完全一致 |
| 原先下载的 21 份附件 | 与 `23:40` 初次同步证据的实际 hash 全部相同 |
| 当前正文覆盖 | 626/627；待下载 0、待索引 0、无文字层 PDF 1 |
| 编辑草稿 / 开放同步冲突 | 0 / 0 |
| 本轮 PDF、原笔记、回导副本的待提交操作 | 0 |

当前 627 份资料包含之后新增的 iOS 笔记和回导副本，不能直接与最初 625 份的分母混用。取样时 iOS 全库另有 1 条 `5e33316b…` 的本机正文操作，创建于 `00:14:06`，属于 Root 正在进行的会话过期离线编辑验收；不是迁移产生。Mac 全库待提交为 0。该时刻的待提交状态不能被写成“所有客户端始终为 0”。

### 迁移与真实阅读版本分开核对

没有在开库修复结束、任何后续阅读开始之前抓取瞬时 `localGeneration` 快照，因此不伪造逐字段前后证明。自动回归已覆盖版本、generation 和冻结队列保持；实际服务端历史与未操作文档的 `updated_at` 提供以下独立边界证据：

- 9 份未操作 PDF 的 iOS `updated_at` 仍为 `23:35:48`，路径已变为当前容器，没有被路径回填写成一次资料编辑。
- 三页原文 `32e7f3ee…` 的 revision 26（`23:55:22`）是手动位置改到第 1 页；revision 27（`23:55:31`）是 Mac 位置改到第 1 页，均早于覆盖安装。iOS 位置在这两版仍是之前的第 3 页。
- 覆盖安装的 `23:56` 没有产生 PDF 新版本。下一版 revision 28 出现在 `23:57:44`，对应 Root 实际从笔记点击 Beta 第 2 页来源链接；仅 iOS 阅读位置变成第 2 页，Mac 与 manual 仍各自保留第 1 页。
- 大 PDF 的 revision 3/4 出现在 `23:59:15` / `23:59:26`，对应继续阅读与搜索跳页。不能把这些真实交互版本误判为迁移写入。

原生界面复验由 Root 完成：`23:57` 从阅读笔记唯一 Beta 第 2 页链接首次打开原文，画面与页码实际为 **2/3**；`23:58` 资料详情 AX 和截图分别显示 iOS 2/3、Mac 1/3、手动 1/3。此处同时有 GUI 与数据证据，不再仅凭 SQLite 推断视图跳页。

### 接近 50 MB 的 PDF

Root 于 `23:59` 实际打开 8 页大 PDF 的图片第 1 页，使用另一设备位置继续到第 8 页，再搜索 `Large PDF Anchor 7`，结果 1/1 并跳到第 7 页、收起键盘。

本次独立检查 iOS 本机与当前隔离服务的原件均为 **49,745,911 字节**，SHA-256 均为 `dd66f1e4375fe2f588f1cf8abc9f6d522c52f739154e93be9d9ae0ff130ef104`，与既有 `tokenlibrary-native-large-file-proof.json` 一致。

`00:15:17` 验证版 iOS 进程 PID `74634` 的 RSS 为 `95,696 KiB`（约 93.45 MiB）。这是完成大文件操作后、其他验收仍在继续时的单时刻样本，**不是大文件打开/搜索期间的峰值，也不据此判定峰值内存指标达标**。

同次只读取样中的 Files 导出、回导新副本和图片三方一致性见 [iOS 导出与回导证明](ios-export-reimport-proof.md)。
