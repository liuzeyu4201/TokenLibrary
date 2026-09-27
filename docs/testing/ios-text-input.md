# iOS真实软键盘输入与Mac只打开不回写

2026-09-26 23:49开始，本次使用签名验证版的iPhone 17 Pro / iOS 26.5模拟器，以及Mac隔离验证版。两端连接恢复服务53056的合成库；没有访问真实资料、会话Token或密码。本页依次记录WK编辑器源码输入与后续便签输入；后续操作会继续修改样本，不能把各段revision当作永远不变的当前状态。

## 原生操作与测试方法边界

主验收在iOS创建“iOS原生同步验收.md”，位于“原生移动验收”文件夹。通过WK编辑器源码模式、实际逐个点按英文软键盘，输入 `hello world` 后按Return；不是通过脚本注入正文或改SQLite。确认本机保存、同步待提交0，并在iOS与Mac原生界面看到正文。

Mac已在23:49前切回这篇笔记的排版视图，只打开内容、没有输入。随后独立核对两端SQLite与服务器，确认仅显示同步到达的内容，没有因Markdown排版载入而产生Mac正文写操作或删除末尾换行。

先前两种尝试不混入通过结论：

- 对Device Hub AX群组执行setValue不能证明真实文本控件接收了输入，也不属于此处的逐键软键盘证据。
- 键盘按钮的“下一键盘：English (US)”表示可切换到的下一个键盘，不代表当前已经使用英文。之前当前为中文拼音，空格被用于选词，例如 `a space b` 得到“啊不”、`hello world` 得到连写文本。主验收点按globe切换至实际英文键盘、完成首次引导后重新逐键输入成功。历史连写文本保留在合成样本内，不把它列为产品吞空格故障或英文输入通过证据。

## 独立只读核对

对象ID `5e33316b-2e32-4202-9c1a-4eb7a720b0f9`，父文件夹 `836e9acd-a53f-466e-adc1-425e6f869416`。先读取最多最近30个服务器revision及对应操作，再对照Mac/模拟器本机工作行与冻结请求；未变更数据或服务。

最终快照时间 **2026-09-26 23:49:41.135 +08:00**：

| 核对项 | 结果 |
| --- | --- |
| 服务器、Mac、iOS工作行 | 均revision37，完整正文相同 |
| 正文末尾 | ASCII空格与最后一个换行均保留：`hello world\n` |
| 全文SHA-256 | `1a304c67733c87891a8a00fa7653e30ba725ab98d4f0f9a909927259f603b89a` |
| Mac/iOS本机状态 | 均已同步，目标笔记未完成操作0 |
| Mac目标笔记所有本机操作 | **0条**，只打开排版没有产生写操作 |
| 最新服务器源操作 | `8b33630e-24aa-4757-b302-89d2c2f0b2a3`，23:49:00.938提交 |
| 最新源设备 | iOS `2c829440-24bb-4688-bea3-dbf5e24a6293`，与模拟器冻结请求的deviceId一致 |
| 最新请求正文 | 与服务器及两端工作正文完全一致，状态sent |

完整正文的Python repr（前几行是上述保留的IME探索材料）：

```text
'# 新笔记\n\nhelloworld\nhelloworld\nhelloworld\n啊不\nhello world\n'
```

此前服务器revision31于23:48:53.880已保存尾部 `hello `，revision32—34继续为 `hello w`、`hello wo`、`hello wor`，对应操作均来自iOS设备。最后revision37保留Return。Mac工作行local_generation增加是拉取应用过程，不能仅凭generation递增声称Mac进行了编辑；这里同时检查目标笔记pending_operations总数0。

原始证据 `/tmp/tokenlibrary-ios-whitespace-history-proof.json`；`english_keyboard_final`保留最终两端工作行、服务器最新源操作、请求正文、hash和主验收键盘更正。早期读取期间主验收仍在输入，可能出现不同revision，已经与最终静止快照分开，不能把中间短暂不同当作丢数据。

本次关闭iOS真实英文软键盘源码输入、空格/Return保存同步、Mac排版只打开不回写这一具体旅程。便签多块编辑与图片的后续证据见下节；真实录音播放、复杂输入法组合、双端同时键入与其他异步时序仍须各自记录，未以源码模式一次成功宣布整个编辑器完成。

## 23:51—23:54便签文字、照片与排序

主验收随后在同一iOS笔记进入便签，点文本框真实聚焦后，通过英文软键盘增加前缀 `sticky `，在正文尾部加入 `end ` 后按Return。经PhotosPicker仅选择用simctl addmedia预置的合成 `fixture-diagram.png`，为图片输入 `diagram ` 后按Return；通过图片“向上移动”将它移到第一块，预览实际显示2块，再“完成”关闭，待提交0。此段是真实便签输入和系统照片选择，区别于上一节WK源码模式。

独立核对快照 **23:57:15.459 +08:00**：服务器、Mac、当前模拟器工作行均revision60，完整正文、metadata、assets完全相同，两客户端工作区未完成队列均0。完整序列化正文SHA-256为 `73e9d084aac189e15d964a9fffd398289d480b8083ff3ecf9e6ed2b7a5fd3393`。将只读正文交给当前真实 `NoteBlockCodec.parse`，再serialize，字节完全一致；恰好两个不同ID，顺序和内容为：

| 顺序/类型 | 块ID | 精确文字（repr） |
| --- | --- | --- |
| 1 / image | `335fe2b8-85f1-4c19-9a66-e051e21fe742` | `'diagram \n'` |
| 2 / text | `8c531f64-c4b1-4730-990d-891e80843cab` | `'sticky # 新笔记\n\nhelloworld\nhelloworld\nhelloworld\n啊不\nhello world\nend \n'` |

第二块恰好是 `sticky ` + 上节revision37完整原文 + `end \n`，没有删除原输入或吞掉最后空格/换行。图片路径以实际DB为准：`media/c44901d6-06ac-4be6-adf1-388ee475cf0c.jpg`，全文仅出现一次，三方assets只有一项。

当前设计在PhotosPicker读入后使用 `UIImage.jpegData(compressionQuality:0.9)`。输入PNG不是原样复制：JPEG生成物与PNG不应要求相同hash。实际模拟器文件、Mac同步文件和服务器blob均可完整解码为1600×900 JPEG，均 **99,573 B**，MIME `image/jpeg`，SHA-256均为 `9148530b0a85f35fad7b5b98ab5da2e6033c6f502c988aa1aa78b658f4ddbd17`。输入PNG同为1600×900，选择来源由主验收系统照片操作记录证明。

服务器该hash只有1个blob且ready，只有1次complete上传，当前对象只引用1个图片asset；revision50—60的历史保留引用均指向同一个blob，不是重复上传或重复附件。原“移动后阅读笔记.md” `de82c808-8566-4b03-9d9b-e2351d0de31b` 三方仍revision23，正文、metadata、assets与此前摘录/批注证明一致，正文hash仍为 `a58741f5c3aabbd3a0e8fc7ecab77102322985946a06464e1928a3adc3f858a8`。

证据 `/tmp/tokenlibrary-ios-sticky-image-proof.json`，包含实际数据库路径、三方正文/附件、blob与上传记录、字节hash和真实codec解析结果。核验期间新模拟器安装使验证包数据容器路径从EE8A…变为8CC43…，只读脚本经 `simctl get_app_container` 重新定位；数据仍一致，但不能据容器变化或读到SQLite声称新包重启、重开便签的GUI验收已通过。

本段关闭便签真实英文输入、文本/图片说明尾空白、单图选择、移到第一块、预览及同步完整性这一限定范围。23:57只读快照本身不证明新包重开。

截至2026-09-27 00:07的后续原生记录，主验收已在升级后的iOS包重新打开该便签，实际看到image→text顺序和图片caption保留；首次麦克风权限拒绝后显示明确原因。此为后续GUI证据，区别于上面的只读核验。允许权限后的录制、播放、后台收尾，复杂输入法、迟到照片请求与跨库操作仍按[便签与语音验证](ios-notes.md)的剩余步骤执行。

## 后续认证过期时的便签持久性

2026-09-27 00:13—00:18，主验收在同一笔记完成会话到期、离线添加第三文字块 `offline saved\n`、系统退出应用后重开、离线本机搜索和原库重新登录。最终三方revision61、全文相同，原图片与文字两块逐字节保留，JPEG大小/hash不变，新增块只出现一次且队列0；完整控制边界、各时点快照与新旧会话核对见[会话专项证明](native-session-conflict-control.md)。这不改写上节revision60快照，也不把认证失效当作物理断网测试。
