# iOS 系统导出、Files 预览与目录回导

范围限定 `app.tokenlibrary.verification` 的 iPhone 17 Pro / iOS 26.5 模拟器及 `53056` 隔离合成库，不涉及真实 Files、用户库或凭据。原生操作由 Root 完成；本证明于 `2026-09-27 00:15:17 +08:00` 独立只读读取两个客户端的 SQLite、指定 Files ZIP/解压文件及隔离 PostgreSQL/附件文件。未操作 GUI、登录新会话或写入应用数据。

完整证据：`/private/tmp/tokenlibrary-ios-post-upgrade-export-proof.json`。采集脚本：`/private/tmp/tokenlibrary-ios-post-upgrade-proof.py`；后续对比、解压文件和大 PDF 检查结果也保存在同一 JSON。客户端取样和服务端取样各记录时间，不能当成跨三库的原子快照。

## 原生旅程

- `00:04` 原笔记 `移动后阅读笔记.md` 从系统导出界面先取消一次，再成功保存 ZIP 到 Files“我的 iPhone”。
- `00:05` 在 Files 解包，看到正文、来源说明、media、metadata；外部预览来源说明保留标题、页码、hash 和个人评论，PNG 预览正常。
- `00:06:55` 使用“含附件 Markdown”目录选择，应用列出解压目录中的两个 Markdown；选择正文后生成新副本，图片正确渲染。提示明确说明只复制图片/音频，普通相对链接 `来源说明.md` 仍保留原地址。
- `00:11` 新副本归档后只读，搜索仍显示归档标识；随后“继续编辑”解除归档，正文排版与图片保留。原笔记没有被覆盖。

## 实际 ZIP 与解压结果

文件位于已确认的模拟器本地 File Provider：

`/Users/token/Library/Developer/CoreSimulator/Devices/CDC55D3E-C4BB-43A3-B3C1-8789492A1D08/data/Containers/Shared/AppGroup/801FC9C5-DE82-4629-9724-0753EC5BF8DE/File Provider Storage/移动后阅读笔记.zip`

文件修改时间 `00:04:12`，大小 **56,339 字节**；ZIP CRC 检查通过，SHA-256 为 `8289ffb79cef9633ad83116d8be951bd0944bd0af2bcc2ff3d2cf56026d68f1c`。

实际 4 个文件条目：

```text
来源说明.md
移动后阅读笔记.md
metadata.json
media/ba40e80b-9c01-4177-a1ac-e28af2d302b4.png
```

Files 创建的同名解压目录中，这 4 个文件的逐字节 SHA-256 全部与 ZIP 条目相同。导出正文以原笔记的完整正文为精确前缀，导出解释只追加在归档中，没有写回原笔记。

`来源说明.md` 保留 Beta/Gamma/Alpha 的来源标题、第 2/3/1 页、原文 hash、摘录原文及个人评论。文档也明确说明来源 PDF 未打包、网络资源未下载，`tokenlibrary://` 为应用内定位，不能保证外部阅读器跳到原文。只验证普通 Markdown 中可读的来源材料，不宣称外部环境具有应用内跳转能力。

## 原件、新副本与三方一致

| 对象 | ID | iOS / Mac / 服务端 revision |
| --- | --- | --- |
| 原 `移动后阅读笔记.md` | `de82c808-8566-4b03-9d9b-e2351d0de31b` | 23 / 23 / 23 |
| 新 `移动后阅读笔记_1.md` | `dc40cc0d-4fe7-4fce-8176-a845c201ff59` | 3 / 3 / 3 |

两份文档分别在三方的正文、metadata、assets 完全一致。原件还与 `23:57:15` 的既有只读证据比较：revision、正文、metadata 和 assets 均未改变。原件正文 SHA-256 为 `a58741f5c3aabbd3a0e8fc7ecab77102322985946a06464e1928a3adc3f858a8`。

回导副本没有复用原件 ID；新图片 blob 为 `6e006fa9-fd24-4444-9215-88b75954c7aa`，正文引用改为其新 `media/*.png` 路径。**副本正文与导出正文相比，仅图片路径发生这次重写**，其余字符完全一致。副本正文 SHA-256 为 `6694de112017b41c6d07b480672d70abfd0e122550563ac098bfca8937fcacde`。

原图、新图、ZIP 图、解压图以及两个客户端/服务器上的实际图文件均为 **50,786 字节**，SHA-256 相同：

`2a85488c6ed062f681b3fc4f518777f00f22389f6f1be7cdac2aeffe73148393`

服务端历史进一步分开记录了副本的操作：

| 本地时间 | revision | archived | 正文 |
| --- | --- | --- | --- |
| 00:06:55 | 1 | false | 导入正文 |
| 00:11:15 | 2 | true | hash 不变 |
| 00:11:47 | 3 | false | hash 不变 |

原件与新副本取样时均无待提交操作。iOS 全库当时另有一条 `00:14:06` 创建的 `5e33316b…` 便签待提交，属于正在进行的会话过期离线写作验收；不把这一独立操作判定为本轮回导未收敛，也不写成全库队列为零。Mac 全库待提交为零。

## 范围限制

这次目录回导保留正文和图片，并显示普通链接未复制的提示；`来源说明.md`/`metadata.json` 没有被当作资料库备份自动重建成 catalog 关系。来源链接文本本身保留，专用链接在应用内的可用性依赖当前库仍有对应原文。可读导出包、普通 Markdown 回导和完整资料库恢复是不同能力，不能互相替代验收。
