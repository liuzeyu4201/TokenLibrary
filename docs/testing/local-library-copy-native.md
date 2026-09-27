# 本机资料显式复制：原生与内容证明

2026-09-27 02:35—02:39（Asia/Shanghai），Root 使用独立 Mac 验证 App 的真实界面创建本机资料、登录既有合成 53056 服务、点击显式复制，并在 iOS 打开副本。核验脚本没有向本机库播种、调用 import API、注入编辑内容或模拟原生点击。

App 为 `/private/tmp/tokenlibrary-attachment-paths-build-1wl4gsv9/TokenLibraryAttachmentPathsVerification.app`，bundle `app.tokenlibrary.verification.attachmentpaths`；独立 base `/private/tmp/TokenLibrary-AttachmentPaths-20260927-5n35ttq3`。该包包含附件路径别名修复，签名和冻结记录为其 build 目录内 `attachmentpaths-verification.json`，未替换其他运行验证 App。

## 原生创建与源库基线

界面创建目录“本机迁入验收_20260927”、笔记“本机迁入笔记.md”、PDF“本机迁入论文.pdf”。笔记真实输入 `LocalTransferAnchor20260927`，插入合成 PNG；从 PDF 详情加入唯一 Alpha 引文、评论 `LocalTransferComment20260927` 和第 1 页来源链接。界面待提交为 3。

02:35:36 在 `Local/library.sqlite` 的只读事务中记录所有 working/remote、pending、blob transfer、draft、conflict 与 sync_state；实际读取两份媒体核对大小/SHA。完整基线 `/tmp/tokenlibrary-u3-local-baseline.json`。

| 资料 | 本机及目标保留的 ID |
| --- | --- |
| 目录 | `14213195-8187-428f-827a-c6fd00eb4e42` |
| 笔记 | `c9cc4b2f-829c-419e-8c3f-d7a3c3a97af1` |
| PDF | `fd7f897a-4a41-474e-82bb-b51a5fa9bb4d` |

源库三条 pending 的 ID 为 `9a0afb3a-8c1e-4c09-9e7c-33125ed6d237`、`9f63300b-3131-45ca-b1f1-c5deafa6395c`、`047fc4b3-1711-46c8-8d74-1191c78b4d57`。基线保存其完整 payload 和 SHA，不只比较数量。

## 显式复制与双端打开

02:35:54，Root 登录 53056 后仅点击一次复制入口；服务器工作区同步到待提交 0，显示三个对象。Mac 实际打开目标笔记，图片、引文和评论完整；02:36:14 来源链接打开目标 PDF 第 1/3 页。随后返回本机库重开原笔记，图片可读，原 pending3 仍保留。

iOS 于 02:37:18 搜索唯一命中并打开服务器副本，阅读模式实际显示完整 PNG、引文和评论；02:37:54 点击来源，正确进入 PDF 第 1/3 页并同步为 0。iOS 新增正常阅读位置，因此 PDF 当前服务器 revision 为 3；目录和笔记仍为 revision1。截图和 CUA 步骤另见 [原生验证记录](native-ui-validation.md)。

## 只读核验结果

02:39:08 的 `/tmp/tokenlibrary-u3-after-copy-proof.json` 证明：

- 源库全部已记录表、sync_state、文档原文/metadata、两媒体和三原 pending ID/payload 与基线逐字段完全相同；原库没有迁移、删除或提交。
- 三个合法且未冲突的 UUID 保留。目标目录父级变为服务器可信 root，两个资料继续归属于该目录。
- 笔记原文仅将 PNG 的 Markdown 目标路径替换为新附件路径。唯一摘录 `9be7848f-b779-4a4f-857e-32539f2c762e` 的 sourceID、pageIndex0、PDF 原件 hash、Alpha 引文和评论保持不变。
- 目标附件使用新 blobID，原本机附件不复用服务器身份。源字节、Mac 目标文件、PG blob 元数据、服务器存储文件和两次 HTTP 200 下载均一致，HTTP `X-Content-SHA256` 也吻合。

| 媒体 | 本机 blob → 目标 blob | 大小与 SHA-256 |
| --- | --- | --- |
| PNG | `63ca1bbe-adf1-44e1-ad95-2d1738c2348e` → `fb50b8a3-2318-4e6b-a381-e2cecdad7ff9` | 50,786 B；`2a85488c6ed062f681b3fc4f518777f00f22389f6f1be7cdac2aeffe73148393` |
| PDF | `3c1a98e3-1f63-470c-b90a-505a91566cc6` → `8a2a9c7b-118e-4480-bf5c-13e0f9775a8b` | 74,791 B；`5e75077459f63545f07f55a4862c27275a218a41635f50ddfa6635eb3759f424` |

HTTP 核验通过一次独立合成账号正常登录，仅 GET 指定两 blob，最后退出该核验会话；token 仅在脚本内存中，不写入 proof。没有访问 App Keychain、读取现有 session 表或修改文档。登录/退出本身是认证状态操作，不能把它说成服务器完全没有任何写入。

Mac 此时已由 Root 切回本机库，其服务器工作区保存的 PDF revision2 不会继续后台追赶 iOS 的后续阅读更新。核验将 Mac working/remote 对应到服务器 **revision2 历史快照**，完全相同；不错误声称这时两端 PDF revision 已一致。

02:39:55 的 `/tmp/tokenlibrary-u3-ios-copy-proof.json` 进一步核对当前原 iOS 验证容器中的三个指定资料及两媒体：目录1、笔记1、PDF3 的 working/remote 与 PG 最新快照一致，附件大小/SHA 与上表一致，sendable queue 为 0。队列沿用产品定义 `pending/awaiting_remote/needs_edit`，历史 `superseded` 行不算待提交。PDF3 相比 Mac 目标快照只多正常 iOS 阅读 metadata；本机源文件和 pending 未受影响。

这是一次本机目录＋笔记＋图片＋PDF＋来源摘录的完整原生显式复制旅程，并以现有完整基线、复制后、iOS 读后证明和 App 冻结记录关联。它不代表重复点击去重、ID 碰撞映射、故障中断/容量极限、回收站或所有旧根分支都已原生验收；这些仍以相应 Core 专项和其他独立原生记录为准。
