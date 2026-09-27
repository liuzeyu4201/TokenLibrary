# iOS服务无响应时的离线内容与恢复

2026-09-27，限定签名验证版iPhone模拟器和53056隔离合成服务。原生操作由主验收执行；此文记录受控故障方法与随后实际取得的证据。原生步骤尚未记录结果时，不把故障注入成功当作离线功能通过。

## 有界服务无响应控制

控制前验证服务进程PID52493的启动时间与可执行文件：

`/var/folders/jd/9gz27bzs5d55xdmkf57mljx00000gn/T/tokenlibrary-restored-ui-w9jb1nkx/tokenlibrary`

同PID唯一监听 `127.0.0.1:53056`，连接独立PostgreSQL端口53042。数据库容器为 `tl-restored-b399c867c3db`，镜像postgres:17，运行身份为 `1e24d0d6edac6bf53cb851b64156d914d7d77c63dfe495218c512d81d6e6c6c7`；只读确认libraryId与epoch仍是恢复验收库、maintenance=false。暂停前 `/health/ready` 返回200及ready=true。

主验收明确授权本步后，先以独立进程启动恢复守护，确认其ready和同一进程身份，再仅对PID52493发送SIGSTOP。实际暂停时间 **00:26:50.362583 +08:00**，ps确认状态T。自动恢复截止 **00:30:49.302229 +08:00**；守护从准备时计239秒，确保暂停不超过240秒，并在恢复前再次核对PID启动时间和可执行路径，避免向复用PID发送信号。请求提前恢复时由同一守护发送SIGCONT。

守护PID78209。控制与原始记录在 `/private/tmp/tokenlibrary-ios-unresponsive-9ub9dg2k`，包含control.json、watchdog-ready.json、stopped.json和watchdog.log，恢复后另产生resumed.json。控制脚本 `/tmp/tokenlibrary-prepare-controlled-pause.py`。主监督进程PID52436（工具会话handle97542）、PG容器和62036/51525另两隔离服务均未被暂停或停止。

这是**应用服务进程无响应**：监听socket仍存在，客户端会遇到等待/超时；不是系统断网、DNS/TLS故障、connection-refused或维护503。不能把此方法的结果扩展为所有离线网络状态通过。

## 已有内容基线

暂停前，主验收00:23实际导入 `offline-mermaid-latex.md`，iOS WK阅读视图目视显示三步分支流程图、行内 `E=mc²` / `a²+b²=c²` 与块积分；这是在线导入后的原生显示。00:24通过目录模式导入 `voice-synthetic-2s.md` 及176,444 B合成WAV，便签显示0:02和说明，点击播放按钮变为停止；此时尚不声称无响应期间冷启读取或音频连续播放完成。

服务暂停期间，仅从仍运行的PG只读保存两篇已同步文档的完整正文、metadata和assets，记录在同控制目录的 `server-content-baseline.json`：公式文档 `e3bd48da-da42-42f5-adb5-c666ef10512f` 为revision1；音频笔记 `94961bd6-0b5a-4b5a-b486-e3e38e233d15` 为revision1，WAV blob `18874ce5-1bb2-4758-b829-6fdcadb2c50c` 为176,444 B，SHA-256 `2825a70bfe269c65793dc3431f781a1f348a29e40a970d427a07ab3d1f946345`。查询未向已暂停应用发HTTP请求，也未修改正文。

## 本次实际范围与自动恢复

主验收00:28从AppSwitcher关闭验证应用，经Spotlight重新打开；在服务仍暂停时能进入本地列表、聚焦搜索，最近同步成功仍为00:26:43。**没有在恢复截止前完成新公式/音频打开或新增便签**，因此本次不记这些离线内容或编辑旅程通过；此前在线渲染和播放按钮变化不能补作本次离线结果。

独立守护实际于 **00:30:49.485360** 发送SIGCONT，原因 `automatic deadline`，实际暂停 **239.123秒**，未超过240秒上限。00:31:02只读核对PID52493状态S、主监督52436运行，`/health/ready` 返回200/ready=true/maintenance=false，同一PG17容器仍运行；记录为 `resumed.json` 与 `recovery-health.json`。Root00:30:50实际看到恢复后队列0。

本次仅关闭受控服务无响应时的应用退出/重开进入本机列表，以及有界自动恢复后同步正常这一片段。后续如再次暂停，应新建独立控制记录并在实际暂停窗口内完成目标内容操作，不能沿用本次时间来声称公式、流程图或音频已离线验收。

## 第二次冷启：公式、排版图表与本地音频

00:42安装含排版Mermaid修复与异步凭据恢复的新包后，主验收再次关闭应用。独立复核同一进程身份及恢复守护ready，仅暂停应用PID52493；本轮控制目录 `/private/tmp/tokenlibrary-ios-unresponsive-oz36jwh6`，开始 **00:42:45.545052**，守护PID81457，自动截止 **00:46:44.488029**。00:45:48另行ps仍为T，目标内容操作确实发生于服务没有响应的窗口。

- 00:43冷启后本机搜索latex，唯一结果打开；先源码，再排版，新Mermaid节点和边实际出现。
- 00:44阅读模式显示书籍/论文→研究笔记→个人档案，以及 `E=mc²`、`a²+b²=c²`；00:45实际滚动看到积分 `∫₀¹x²dx=1/3`。
- 期间出现明确连接超时原因与“重试同步”，自动重试未更改最近成功时间00:42:31。
- 00:45:35打开合成音频笔记便签，播放按钮变停止，随后自然结束恢复播放。只确认真实播放器状态与本地文件读取，不宣称听觉质量、麦克风录制或所有音频中断场景通过。

主验收00:45:55请求提前恢复；守护于 **00:45:57.880594** 发SIGCONT（`explicit early recovery`），实际暂停192.336秒。00:46:21原生队列0且最近成功前进；00:46:54及00:48:27独立确认ready=true、maintenance=false、同一服务正常运行。

只读证明 `/private/tmp/tokenlibrary-ios-unresponsive-oz36jwh6/content-recovery-proof.json` 记录00:48:27 iOS与服务器两篇均为revision1；正文、metadata、assets精确等于第一轮00:28基线。公式正文SHA-256为 `ddad5902f2b673def24e7ca56948b58689e0ee8252635998deae1d1421c17e78`，音频笔记正文为 `c11678f569e188013c3b24ac5c08d83eb20d2266a35a68c6fe5391b961735104`。iOS与服务器WAV实际文件均176,444 B、hash `2825a70bfe269c65793dc3431f781a1f348a29e40a970d427a07ab3d1f946345`；目标及整库未提交队列均0。

这次关闭该iPhone模拟器新进程在服务无响应时的本地检索、排版Mermaid修复复验、阅读公式及合成音频播放片段。未修改正文，不冒充离线新增/编辑旅程；也不等同物理断网、真机音频或后台预算测试。
