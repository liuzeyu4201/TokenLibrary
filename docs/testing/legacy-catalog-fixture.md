# 独立旧安装混合根夹具

2026-09-27 生成。初始准备仅构造离线数据；**01:24—01:27 已由主代理完成本页末尾限定的 Mac 原生路径**。使用独立 App 和目录，没有复制到现有验证容器、操作 53056，或安装任何凭据。

目录：`/tmp/tokenlibrary-ui-fixtures/TokenLibrary-Legacy-Mixed-20260927`。完整说明与对象清单分别为目录内 `README.md`、`manifest.json`；独立只读证明为 `/tmp/tokenlibrary-legacy-fixture-proof.json`。

## 先区分可用入口

当前用户“导入”只支持 Markdown、PDF，以及含附件 Markdown 目录。没有 SQLite 资料库导入入口，普通文件导入也不生成多个资料库根。因此不能用导入一组文件来证明旧安装多根兼容。

这份数据库用于现有的**旧安装启动路径**：`AppModel` 在 base 已存在 `library.sqlite` 时将其作为旧本机库，读取正式 `legacyLibraryInventory()`。Debug 包已有 `--verification-directory <绝对路径>`，偏好域按目录名隔离；后续只能由主代理在独立验证轮次明确启动，不能覆盖当前验证目录。启动后用户入口是主列表“更多 → 当前库的根目录”，以及“资料库 → 资料详情”的专题、相关资料、摘录目标选择。

夹具目录的 `import-controls` 含普通 Markdown 和三页 PDF，可供后续系统 picker 验证单库导入。它们不带跨库身份，尚未放到模拟器 Files，也没有执行导入。

## 数据与断言

| 项目 | 初始状态 / 预期 |
| --- | --- |
| 库根 | 已明确登记 A=`aaaaaaaa-1000-4000-8000-000000000001`、B=`bbbbbbbb-2000-4000-8000-000000000002`，均无实体 root 文件夹；另有默认 `root` |
| 资料数量 | 9 项：5 Markdown、1 PDF、3 文件夹（其中 2 个专题） |
| A 库原件 | “A库 研究原件”，一条不存在对象的 related ID，用于不可用占位与显式移除 |
| A 的候选 | 仅两篇“同名阅读笔记”，文件名同为 `阅读笔记.md`；分别在 A 根与“A库课程”目录，可通过路径区分 |
| A 的专题 | 仅“A库 专题” |
| 负例 | B 库笔记/专题、默认本机根笔记、未知父目录笔记不能成为 A 的候选 |
| 未知根 | `cccccccc-3000-4000-8000-000000000003` 从未登记；其笔记保留并列入待恢复位置，不得自动把缺父提升为根 |
| 待提交 | 正式 `createDocument` 生成 1 项 A 根笔记创建操作；重新打开库后 operation ID、payload 保留，未冻结/未发送 |
| 凭据/服务器 | 无 server/libraryId/rootId/sessionToken 绑定；没有网络调用或 Keychain 访问 |

PDF 为既有纯合成 `research-three-pages.pdf` 的库内副本：74,791 字节，SHA-256 `5e75077459f63545f07f55a4862c27275a218a41635f50ddfa6635eb3759f424`。使用正式 `importAttachment` 写入相对附件记录，后续更换测试目录时可由现有路径恢复机制定位。源夹具 hash 未变。

SQLite 初始 SHA-256 为 `fecc9b771dcf911152ad61a5c66a07a7aa04f64cc6feca4c4a4a2eb67bbe8838`；已检查 WAL checkpoint、9 项对象、两个实体根缺席、1 个队列操作和无服务器绑定。后续原生操作会改变该 hash，应保存初始 manifest 作为基线，不把可预期编辑认定为损坏。

## 准备脚本

源文件为 `tests/fixtures/generate_legacy_catalog_fixture.swift`，通过当前正式 `DocumentStore`、`registerLegacyLibraryRoot`、`importAttachment`、`saveDocument`、`createDocument` 构造。拒绝已存在目录和非临时目录，避免覆盖已有库。构造旧 records 使用 `saveDocument(enqueue: false)`；只有明确的待提交样本使用正式创建事务。

本机已编译命令行生成器 `/tmp/tokenlibrary-generate-legacy-catalog-fixture`；构建日志 `/tmp/tokenlibrary-legacy-fixture-generator-build.log`，执行日志 `/tmp/tokenlibrary-legacy-fixture-generator-run.log`。重新生成时必须使用新的临时目录：

```sh
/tmp/tokenlibrary-generate-legacy-catalog-fixture \
  /tmp/TokenLibrary-Legacy-Mixed-NewRun \
  /tmp/tokenlibrary-ui-fixtures/research-three-pages.pdf
```

初始生成时未执行原生验收。跨设备回收站反向关系清理使用另一条独立流程：A 先关联 B，删除 A 所在父文件夹，在活跃 B 中移除回收站 A，再还原文件夹确认关联不复活。它需要包含回收站 metadata 更新修复的服务端，不能由本离线夹具代替；独立闭环证据见 [iOS 回收站关系清理](ios-related-trash.md)。

## 01:23 独立 Mac 启动包准备完成

不需要启动参数的独立 Debug App：`/private/tmp/tokenlibrary-legacy-catalog-app-1obvxnzs/TokenLibraryLegacyCatalogVerification.app`，可由主代理使用 `cua.getApp` 的精确 App 路径启动。此准备步骤没有启动 GUI。显示名称为“TokenLibrary 旧库验收”，bundle ID 为 `app.tokenlibrary.verification.legacycatalog`；`Info.plist` 的 `TokenLibraryVerificationDirectory` 指向本页顶部夹具目录。

新增配置只允许 Debug 中的 `app.tokenlibrary.verification.<非空后缀>` 读取绝对路径 Info 值。普通/相似 bundle ID、相对路径均忽略，Release 调用入口编译为 `nil`。原 `app.tokenlibrary.verification` 仍使用原默认验证目录；既有显式绝对路径启动参数仍优先。偏好域和凭据服务按独立目录名隔离；准备时该偏好文件不存在，夹具没有服务器配置，因此初始化不会发起凭据恢复。没有读取、写入或清理 Keychain。

客户端完整 **76 项通过**（新增 4 项覆盖普通 bundle、非法相对路径、Release 边界及原行为），01:19:37.772，日志 `/tmp/tokenlibrary-legacy-launch-full-client-tests.log`。独立源码快照编译成功，ad hoc 签名后 `codesign --verify --deep --strict` 通过。App 二进制 SHA-256 `de83c687c2416db3eb002a29e9a01e16ef199793e2e8d0db785996a9ea4e1156`，Debug dylib `fccc402d66d0a3b28db86fb667677f494ea5377c9a8e594dc8a633ca6cae88c5`；编辑器资源为已验版本 `5b14635a1db5bcf068e489fc003f5e4223dbc124725ee296627eb0a2c4c58ddf`。

`verification.json` 位于 App 同级目录，记录源码、签名、资源和旧库初始 hash。原 footer 验证 App 与夹具 SQLite hash 均未变化。源码快照含顶部保存和固定摘录 footer；不含随后并行开发的后台刷新 F25，后续新包不能沿用本页二进制 hash。本段证明准备与构建，不证明原生候选/关闭/关系操作通过。

## 01:24—01:27 Mac 原生闭环与只读证明

主代理通过上述精确 App 路径启动，界面显示原待提交 1 项和未知根说明；根菜单切换到 A，三页 PDF 可读。资料详情仅显示 A 专题；摘录候选仅两篇 A 的同名阅读笔记，按“A库课程”搜索只剩子目录候选 104。实际加入 Alpha 原文与评论“旧库同名目标验收：只追加到 A库课程。”后，自动打开正确笔记，待提交变为 2。

阅读模式点击带 hash 的来源链接回到 A 原件第 1/3 页，新增本机阅读位置后待提交 3。相关资料选择也只有 A 的两个候选，搜索 B 库无结果。显式移除缺失 `dddd…0004` 关系后占位消失；反链仍能返回子目录 104，摘录与评论完整。B、本机默认根与未知父目录笔记均实际打开，正文未变。正常 Cmd-Q 退出、重新按精确 App 路径启动后，待提交仍为 3，未知根仍保留，子目录 104 的原文、唯一摘录、评论和来源链接均可见。

三个独立只读 SQLite 快照保存在 `/tmp/tokenlibrary-legacy-native-proof.json`（01:25:40、01:26:56、01:27:23）。比较基准为初始 SHA 匹配的主数据库副本 `/tmp/tokenlibrary-legacy-fixture-initial-baseline.sqlite`；当前读取包含 WAL，并在只读事务中取一致快照。没有通过脚本执行 App 导入、编辑或同步。

- 原 A 根笔记 103 的 `b5d68af6-6494-497d-aa78-800e1f0a4963` 待提交操作，所有字段、完整 payload、未冻结 request 均与初始相等。
- 子目录 104 恰有一个摘录 `bc9e467f-e6bd-41bb-9cc6-06e8561b4d13`；来源为 A 原件 101，页 index 0、文件 hash 正确，正文原文及评论各出现一次，链接包含 `page=1&hash=…`，`sourceIDs` 正确。
- PDF metadata 仅有预期的阅读状态、本机位置和缺失关系清空变化；结构、blob、批注以及其他 metadata 不变。其余 7 行完整相等，B、默认根、未知父笔记未被修改或自动迁根。
- PDF 仍为 74,791 字节，SHA 与初始一致。重开后三个待提交操作逐字段与退出前相等，104 完整行也相等。仍只有明确登记的 A/B 两个 legacy 根，没有服务器绑定或凭据。

此证据覆盖 Mac 旧安装多根选择与持久化；不代替 iOS 旧安装、跨设备迁入或 VoiceOver 验收。最初 manifest 的 `nativeVerified: false` 是生成时基线，不回写为操作后的全功能声明。
