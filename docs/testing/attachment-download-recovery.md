# 附件下载失败、保留本机内容与正常重试

2026-09-27 **02:39:38—02:39:51**，独立 PostgreSQL 17 服务、受控 HTTP 代理和两个真实 Swift Core 客户端完成一次联合旅程。源码已有损坏附件拒绝/游标不前进及上传断点回归；本项新增实际请求的连续 503、默认重试预算、内容截断、再次同步、旧资料仍可读和失败期间本机编辑落盘的联合证据。

没有修改产品源码或现有四个服务，也没有通过删本机附件/改 SQLite 制造失败。资料使用真实三页合成 PDF 和 PNG。故障仅作用于这个自有服务中明确登记的单个 blob GET；正常服务依然验证调用者会话，代理取得真实内容并校验其 ID 对应的 size/SHA 后才注入响应。

## 自动旅程结果

| 阶段 | 实际结果 |
| --- | --- |
| 已有本机资料 | 两客户端正常同步“已有离线资料.md”和完整 PNG，客户端 B cursor=1、1 项正文可检索、可发0 |
| PDF 连续 503 | 新 PDF 已通过正常 API 发布；只对它的下载返回 `503 BUSY / Retry-After: 1`。同一轮 Core synchronize 恰好请求3次，间隔约1.036/1.054秒后耗尽默认预算；错误保留 code/Retry-After/可重试提示 |
| 失败中的本机工作 | cursor仍1；未把新 PDF 写成已安装文档/附件。已有 Markdown、实际 PNG bytes和本机搜索均可用；在旧笔记追加中文，重新打开 DocumentStore 后精确保留，可发1 |
| 新一轮恢复 | 同一PDF在下一轮先失败两次，第三次返回完整74,791B；间隔约1.033/1.044秒。PDF字节正确、`Research Anchor Beta`进入本地搜索，旧笔记编辑通过正常队列提交，cursor=3、可发0 |
| 图片内容截断 | 新建另一篇图片笔记，独立blob与旧PNG内容相同。GET返回HTTP200，只给原50,786B中的25,393B；Content-Length声明这个实际短长度，而原服务器SHA保持不变。Core明确报“附件校验失败”，没有提交部分文件/transfer URL/文档，也没有推进cursor3 |
| 正常再次同步 | 同一图片GET完整50,786B，一次成功；两客户端精确正文与图片字节一致，三篇资料正文均可检索、cursor=4、可发0、开放冲突0、待下载/待索引0。以前已下载的PDF和PNG始终保持 |

503阶段的3次属于**同一次同步的自动重试**；第二阶段明确是新一轮 synchronize，不能把6次累计请求称为同一轮预算。图片截断被完整性层拒绝，后续由正常再次同步恢复。这个 HTTP200短内容场景不是 Content-Length 不足的 TCP 中断、系统断网或连接拒绝；没有混称。

本机覆盖统计只针对已经成功应用的资料。失败的新远端资料因为附件尚未验证，整个增量页没有提交，因此不进入工作表；当时 `waitingDownload=0` 不表示云端新增附件已完成下载。可见资料/搜索数量依次为1→2→3，失败中已有资料准确保留。当前 GUI 对应的错误文案、最近成功时间、重试按钮和可继续编辑仍需原生步骤，不能仅凭上述Core结果标为通过。

## 证据与重复运行

目录 `/private/var/folders/jd/9gz27bzs5d55xdmkf57mljx00000gn/T/tokenlibrary-attachment-recovery-i7xoua94`：

- `proof.json`：实际开始/结束、归档与服务器hash、全部故障请求时间/次数、目标ID/hash/大小及范围。
- `clients/01-baseline.json` 至 `05-final.json`：两个SQLite工作文档/队列/游标/覆盖统计，以及错误中文原因和恢复行动；各检查由真实Core API完成。
- `requests.jsonl`、`controls.jsonl`：仅记录单blob响应与控制元数据，不记录 Authorization、登录 token 或密码。
- `control-http-ttl-proof.json`：额外通过真实受保护HTTP控制设置1秒TTL，实际等待后自动回到healthy，无下载和业务修改。
- `probe.log`、`probe.stderr`、`server.log` 与编译日志：原始执行证据。

Core静态归档为 `97917e491bb389ab92198bdef55ec9146d60a9a68a4fc90b00d48f3f69ffda03`，含附件路径别名修复；服务器为 `45566091f3540478b8daea9786720e54bbdf6e76608de2b0e6937e4d4df764de`。这是独立集成旅程，不重命名为完整Core227/其他测试总数。

```sh
python3 tests/acceptance/verify_attachment_recovery.py \
  --core-products /var/folders/jd/9gz27bzs5d55xdmkf57mljx00000gn/T/tokenlibrary-epoch-fixed-core-p4sn6vxf/Debug \
  --fixtures /tmp/tokenlibrary-ui-fixtures
```

默认结束清理自己创建的应用和PG17容器；`--keep-for-native`保留至有限的2小时截止。编排、Swift探针和自有服务启动器位于 `tests/acceptance/`；不用活跃 `.build`、不安装系统依赖、不接受任何现有服务作为上游。

## U5 原生阶段的具体控制方案

本次主任务要求保留同一测试服务供正常GUI登录：前置 `http://127.0.0.1:51350`，合成账号 `e2e`、合成密码 `e2e-password`。后台仍为自有 `51317`/PID5157/容器 `tl-attachment-d585feec36ea`。现正常healthy，不预先让新登录失败。

为允许后续登记新blob，仅替换自有前置代理监督5129→5729，保持51350地址；后端/PG/库/epoch/对象revision/媒体hash/session数量逐项不变，`proxy-upgrade-proof.json`记录约半秒内完成的只读前后核对。没有重启后端、发布资料或开启故障。原自动退役截止仍为 **04:39:51+08:00**；父任务可以在需要时明确安排新有限截止，不无限常驻。`serve_attachment_fixture.py`只管理这一个已核实的自有后端/容器。

完整GUI步骤应使用这个服务**先健康登录并缓存已有资料**，随后发布一个全新的blob。已下载的旧blob会命中正常本机缓存；仅切换代理故障不能证明再下载，更不能删除缓存来冒充用户路径。

两阶段控制器是 [publish_attachment_fixture.py](../../tests/acceptance/publish_attachment_fixture.py) 与对应Swift源；已编译为 `/tmp/tokenlibrary-publish-attachment-fixture`，**截至本文准备时未执行prepare/publish**。

1. Root确认新独立Mac正常登录51350、旧正文/图片可读、queue0之后，执行`prepare`。它通过正常Core登录/下载基线/上传新PDF，但仅在私有producer保存并冻结一条createPDF，没有发布对象。登记新blob时须runId正确、healthy、唯一UUID、明确SHA/size/objectID；会话在退出前注销。
2. Root准备观察错误后，才对输出的`prepared.json`执行`publish`。它先设置新blob的503或短内容故障，再正常flush同一个冻结operation ID；服务器/library/epoch/root和wire hash必须完全符合计划。成功后注销专用会话。重复已完成的publish只返回既有证明，不再创建对象。
3. Root观察旧资料可读/本机编辑、最近成功不前进、具体错误/重试入口。检查目标新的文档尚未假装下载成功。然后显式`healthy`或等最多240秒自动解除，再观察正常同步/新PDF可读可搜/原编辑保留。

```sh
python3 tests/acceptance/publish_attachment_fixture.py prepare \
  --control /private/var/folders/jd/9gz27bzs5d55xdmkf57mljx00000gn/T/tokenlibrary-attachment-recovery-i7xoua94/owner-control.json \
  --expected-origin http://127.0.0.1:51350 \
  --publisher /tmp/tokenlibrary-publish-attachment-fixture \
  --pdf /tmp/tokenlibrary-ui-fixtures/research-three-pages.pdf
```

`publish`使用相同control/origin/publisher，加`--plan <上一步prepared.json> --mode 503 --ttl 240 --failures 100`。单blob预算≤100次、TTL≤240秒，二者任意先到即healthy。正常SDK测试另验证无控制key为403、陈旧mode/陌生blob为409；不得打印 `owner-control.json` 中的随机控制key，它不是用户账号资料。

提前恢复：

```sh
python3 tests/acceptance/control_attachment_fault.py \
  --control /private/var/folders/jd/9gz27bzs5d55xdmkf57mljx00000gn/T/tokenlibrary-attachment-recovery-i7xoua94/owner-control.json \
  --expected-origin http://127.0.0.1:51350 \
  --expected-mode 503 --mode healthy
```

先读取无敏感字段的 `/__fixture/status`；如果TTL已使状态为healthy，则expected-mode应为healthy，不绕过模式守卫。原生步骤尚未执行时保持待验；该方案也不验证公网TLS、物理断网、50MB下载性能或后台系统预算。

## 02:57—03:00 Mac 原生 U5：单个新 PDF 的503与自动恢复

Root 在独立 `51350` fixture 正常 GUI 登录，原三份文档、旧 PNG 可读且队列0；应用库是 `/private/tmp/TokenLibrary-RecoveryUI-20260927-jl5wiwpd/Libraries/f336d1f143b4d152a5cb368b04aea0baa229d7e1befcc7e28d657e0103e4e647/`。没有切换或转发53056的资料。

正常API预先上传唯一新 blob 并冻结创建请求，02:57:56.066开启其 GET 的503/BUSY/Retry-After1故障，同时正常发布 `U5 新PDF下载恢复 5dfb8c97.pdf`。只命中 blob `5f866c8b-c99a-422b-bcb0-15619460e064`，新对象 `5dfb8c97-7849-4957-bd87-7b3eecd3cde8`，74791字节，SHA256 `5e75077459f63545f07f55a4862c27275a218a41635f50ddfa6635eb3759f424`。上限100次、240秒自动恢复；原三文档和其他附件请求继续正常。冻结计划及发布回执在 fixture 输出下的 `u5-plan-9e831fbcce0a/`。

原生实际看到“服务器暂时不可用／重试同步”，最近成功仍2:57:51，新PDF尚未出现在本机；打开旧笔记仍看到PNG，在原文后追加精确 `U5NativeDuring50320260927`，本机保存、待提交1。基线和故障时的 `sync_state` 按key映射完全一致，cursor始终4，不能用SQL行顺序变化误判推进。

Root指令后02:59:20提前解除故障。02:59:40准备点重试时，按钮已自动变“立即同步”、新PDF出现、队列0、最近成功2:59:31，故这是自动重试恢复，不宣称手动重试通过。02:59:49实际原生打开新PDF1/3页、中英文Alpha可读；旧笔记阅读模式仍有PNG和新增标记。

独立只读 `/tmp/tokenlibrary-u5-native-final-proof.json`（03:00:35）：

- 基线与故障cursor4，最终cursor6；可发送队列0。
- 目标精确15次503后1次HTTP200，成功响应完整74791字节，无部分文件冒充完成。
- 旧笔记本机/服务器revision与全文一致，原文只追加本段标记，SHA256 `9f600298ad5e678e750bfcad7bc95cd9454ea01ec7fff57b3e1eb569d220c39d`。
- 本机4份完整媒体与合成服务器storage逐字节/大小/SHA一致；原PNG、原两份资料的内容及PDF批注未改变，新PDF元数据和blob身份准确。
- 原生证据基线 `/tmp/tokenlibrary-u5-native-baseline.json`、故障 `/tmp/tokenlibrary-u5-native-during-503.json`；复核脚本 `/tmp/tokenlibrary-u5-native-final-proof.py`。输入自动化的中间尝试未作为产品缺陷或最终正文证据。

此段只证明Mac新附件503与已缓存内容继续使用及自动恢复。短HTTP200/hash不符分支仍是前述Core真实HTTP自动证据，iOS同旅程、真实网络断开和系统后台下载没有因此通过。服务开关已healthy，有限fixture截止仍有效。
