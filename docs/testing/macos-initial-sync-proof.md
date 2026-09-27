# 新Mac客户端首次全量同步证明

2026-09-27 01:57。两次均由主验收在独立Mac验证应用正常登录53056合成恢复服务，随后读取SQLite／PG当前公开对象及媒体字节。没有读取Keychain或会话表、改变系统授权、复制旧凭据或修改资料；新客户端登录成功不能证明旧客户端的Keychain等待问题已经解决。

## 01:36 Concurrent首次同步

原生登录后的 `/tmp/tokenlibrary-concurrent-initial-sync-proof.json` 记录01:36:51快照：652对象（620 Markdown、13 PDF、19文件夹）均active；working与remote snapshot对应当时服务器当前头，cursor893、pending0；26/26当前引用媒体的实际bytes、size及SHA-256与服务器相同。服务器39个blob还含未引用历史版本，不要求全新客户端下载全部39个。

库路径：`/private/tmp/TokenLibrary-Concurrent-20260927-a6mu74bv/Libraries/68cc057895d3cd4705929985d80181026cb1778641ffdc666573ae186ae92595/library.sqlite`。该客户端参与此前F12失败样本与F13同段冲突旅程；01:56前换包后等待旧Keychain，已由主验收正常退出，后续输入修复验收不用它充当当前同步端。

## 01:56 Selection首次同步

主验收01:56:19在新bundle `app.tokenlibrary.verification.selection`、应用 `/private/tmp/tokenlibrary-selection-app-dby3uisd/TokenLibrarySelectionVerification.app` 正常登录。独立只读脚本 `/tmp/tokenlibrary-selection-readonly-proof.py` 随后核验；它读取指定临时根，以PG repeatable-read/read-only事务获取服务端对象，以SQLite mode=ro事务取工作区/remote/下载表；不触发下载、登录或同步。

证明 `/tmp/tokenlibrary-selection-initial-sync-proof.json` 于 **01:56:52** 生成：

| 核对项 | 结果 |
| --- | --- |
| 库身份 | library `97c6c216-19ef-4e34-b97f-fecbf4653702`、epoch `08874133-4249-485c-8829-93d98cdb7485`、root `ad5fc36a-8002-4325-a8a7-11f8415e0295`，与恢复实例相同 |
| 对象 | 655＝623 Markdown＋13 PDF＋19文件夹，即636份资料；全部active |
| 内容 | 所有working字段、metadata/批注/附件列表与服务器公开snapshot相等；所有remote snapshot与当前头一致（忽略展示用conflictIds） |
| 同步状态 | 本机cursor与云changeSeq均915，pending0，首次同步已初始化 |
| 当前媒体 | 26/26完整落盘，size/SHA-256及实际bytes均等于服务端；PDF工作路径可读且等于对应下载记录 |
| 已换版又恢复的PDF | afecb79c…仍rev12、原blob5865785e…；不是旧新版本混杂 |

**后续F12最终证明应读取的新Mac根**：

```text
/private/tmp/TokenLibrary-Selection-20260927-9bpirie4/Libraries/68cc057895d3cd4705929985d80181026cb1778641ffdc666573ae186ae92595/library.sqlite
```

差异证明 `/tmp/tokenlibrary-selection-vs-concurrent-proof.json` 比较两份不可变首次同步记录，保存原证明SHA-256：前652个对象的摘要逐项相同，没有删除；新添恰好3个Markdown：

| ID | 名称 | 01:56基线 |
| --- | --- | --- |
| c4d018fc-5b1d-4161-b2d7-ac7f3c4a31fb | 双端连续输入验收.md | rev12，保留最初光标跳尾失败正文，未修补旧证据 |
| 2df4162f-225e-4dce-b774-55557ce43b27 | iOS同段冲突与恢复验收.md | rev7，真实键盘合并及两端重开后的准确正文 |
| f367d811-1434-40bd-8f16-d62df035ceb1 | 双端连续输入验收_修复.md | rev3，SHA-256 `0d715bf02038c037b6f0409dc629a6fac6c71fdc63c8bb53bddf727e01422a89` |

两时点26个当前媒体的ID集合、大小/hash及相对路径完全相同。该比较只证明两份采样记录的内容关系，不代表旧Concurrent进程现在仍运行或仍已同步。新库完整初始副本也不等于F12持续输入修复已经原生通过；后续结果见[交错输入验收](native-markdown-interleaving.md)。
