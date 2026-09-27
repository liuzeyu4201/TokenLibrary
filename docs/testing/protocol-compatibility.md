# HTTP 426 协议版本不兼容提示

2026-09-27，Root在原生连接错误验收中用正式错误envelope观察到：`HTTP 426`和`PROTOCOL_UNSUPPORTED`只显示通用“服务器拒绝了请求/检查版本”，缺少明确行动说明。本轮限定改动[ConnectionSupport.swift](../../clients/LibraryCore/Sources/LibraryCore/ConnectionSupport.swift)的错误映射，不改协议、同步状态或服务器。

只有这两个条件同时满足才显示：

- 标题：**客户端与服务器版本不兼容**。
- 原因：服务器不支持此客户端使用的同步协议。本机资料和待提交修改仍然保留。
- 建议：更新客户端或服务器至相互兼容的版本后，再重新连接。

保留statusCode、serverCode和Retry-After以便诊断，`isRetryable=false`。未知426、缺错误code、非JSON错误体，或其他HTTP状态即使带同名code，仍按原通用HTTP错误处理。这个映射不把任意Upgrade Required都解释成TokenLibrary协议问题。

## 实际回归

[ConnectionReliabilityTests](../../clients/LibraryCore/Tests/LibraryCoreTests/ConnectionReliabilityTests.swift)新增3项，通过真实URLSession/URLProtocol解码响应而非只调用映射辅助函数：

1. 登录426正式envelope及短Retry-After：明确中文原因/更新建议，只有一个请求、无退避，既有session/epoch不被失败登录替换。
2. 临时真实SQLite保存并冻结一条笔记操作：426不清队列、不改正文或制造冲突/恢复草稿；两次明确调用分别只发一次，operation ID、HTTP请求bytes、payload和冻结字段完全保持。
3. 未知426、无code、非JSON，以及400搭配同code：通用分类保持，不错误推广版本不兼容提示，仍不重试。

旧产品代码运行新增3项：2项失败、5个断言失败，未知分支原本通过，记录`/tmp/tokenlibrary-protocol426-before.log`。修复后03:33:55，连接17项与队列17项合计 **34项通过、0失败**，0.550秒用例时间，日志`/tmp/tokenlibrary-protocol426-related-tests.log`。没有为此重新运行Core全套，也没有用自动测试声称新版原生提示已经复验。

产品文件SHA-256：`00bd28f83d25d2f276b2c7a51cb12345589f7e6eb4a38004fea6b5b38e5f5ca4`；测试文件SHA-256：`3792152bd6469433d113fa207577223e0c45c54c49ace444baaf1cde3effb1d9`。已交给双端合包代理。

不重试的精确范围是**同一次HTTP调用的自动退避重试**。已有前台定时同步、用户重试或重新激活会产生新的同步调用，这个窄改动没有更改这些入口。登录426失败本身不建立新会话；不能把此测试写成系统所有后续同步调用永久停用。
