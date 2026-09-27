# 连接错误分类的原生有限验证

2026-09-27 03:25—03:34，Root在独立Mac `navigationfinal` 包的登录页实际操作。对应原生主记录见[native-ui-validation.md](native-ui-validation.md)，本文件说明可复用夹具、HTTP事实及没有覆盖的边界。

| 输入 / 响应 | 实际原生结果 |
| --- | --- |
| `not a server address` | 说明应为完整HTTP/HTTPS地址，并说明不可附接口路径、账号或query等规则 |
| 已核对未监听的loopback56171 | “无法连接服务器”，提示检查地址、端口与网络 |
| loopback56170健康JSON | “服务器可连接。输入账号密码后登录。”；仅健康检查，不是账号或整库同步成功 |
| 同端点HTTP200 HTML | “服务响应格式不正确”，说明未返回可识别文档库数据，并提示确认运行TokenLibrary |
| 同端点HTTP426与`PROTOCOL_UNSUPPORTED` | 旧包显示通用“服务器拒绝了请求／HTTP426”，尚未明确版本不兼容；已提出窄修，不把旧截图当修后证据 |
| 改回健康端点 | 03:34再次测试成功；无需重启或清空本机库 |

登录表单Tab由地址到账号、密码、测试、登录，Shift-Tab能反向回测试；这是该表单的有限键盘路径，不是全文编辑器或VoiceOver验收。成功与426后点击使用本机文档曾残留连接反馈，已由3个模型回归先红后绿修复；新组合包原生复验尚待。

## HTTP夹具与精确边界

[connection_error_fixture.py](../../tests/acceptance/connection_error_fixture.py)只绑定loopback，没有账号、会话或业务数据。登录路由立即405并关闭连接，**不读取请求体**；日志仅time/method枚举/route枚举/status/mode，无query、header、body或密码。控制需要随机key、runId及expectedMode，错误模式最多240秒自动回healthy；整服务30分钟有限租约，既有五业务服务不动。

本轮输出 `/private/tmp/tokenlibrary-connection-errors-20260927-0326`，`manifest.json`为非秘密配置，`requests.jsonl`为精确时点。03:29:35 healthy200；03:30:16设HTML、03:30:44实际health200；03:31:09设426、03:31:25实际health426；03:31:42恢复healthy，03:34原生复验由Root确认。单独`health-and-refusal-proof.json`记录初始化HTTP与拒绝连接验证。`owner.json`含控制key，**不将其内容写入文档**。

macOS“绑定但未listen”的端口在准备时产生超时，不能当作拒绝连接。夹具改为先选择空端口再关闭，并在交接前实际核对`ECONNREFUSED`；关闭端口无法长期预留，重用时应立即再次核对，不能声称保留锁。准备阶段旧夹具已精确停止，没有碰任何业务进程。

426的error对象与服务端`errBody`一致，客户端`send`确实从`error.code`提取`PROTOCOL_UNSUPPORTED`；缺省`requestId`不参与其解码。旧通用提示来自`SyncFailure.http`缺少对应分类。**真实服务的426位于同步operation协议版本检查，readiness自身不协商版本**，因此本轮证明相同envelope的错误展示，不能称实际旧服务/新客户端协议往返已验证。真正兼容性和公网DNS/TLS仍另行验收。

截至本文件更新，夹具已经healthy，结束时间03:55:42.471914+08:00。该时点之后的新包复验见下节。

## 03:39 新组合包复验

Root在新`connectionfinal`包实际测试相同426夹具，界面明确“客户端与服务器版本不兼容”，说明服务器不支持本客户端的同步协议、本机资料和待提交修改仍保留，并指引更新到兼容版本再连接。进入本机文档后原新笔记仍在、pending1，连接错误banner消失；健康提示→本机入口清理也已由Root实际验证。随后控制器恢复healthy，Root随后在同一表单再次健康检查成功（正常登录57143之前；以真实03:40前后记录为准，不采用早先口头误估03:42）。

本段是修复后的Mac UI事实；具体修复/3个URLProtocol新增回归见[协议兼容](protocol-compatibility.md)，本机入口清理3个模型新增回归在114项完整运行中通过。健康fixture没有变成真实同步版本协商测试，也没有因文案复验而改写笔记或队列。
