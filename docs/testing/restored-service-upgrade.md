# 隔离恢复库的同实例二进制升级

2026-09-27 00:57，主验收关闭Mac/iOS验证应用后明确授权升级合成53056实例，目的是让后续原生测试使用回收站metadata身份保护修复。没有重建PG、seed资料、恢复旧备份或重置会话。

## 先保护旧监督的清理语义

旧应用PID52493由PID52436监督，来源 `/tmp/tokenlibrary-restore-ui-fixture.py`。审查发现它在子进程退出时无条件删除自己的PG容器，所以不能直接kill应用再重开。升级前先核对PID启动时间、可执行路径、53056监听、容器完整ID、PG17与健康状态，读取公开数据和两个客户端队列快照；保留原二进制和SHA-256。

精确SIGSTOP旧监督，确认T后仅向旧应用发SIGTERM、等待退出；以同URL、数据库、data/backup目录、凭据世代1启动新二进制。新应用ready后核对数据，最后用不执行finally的方式退役已暂停旧监督。新持久监督的退出处理**只关闭自己启动的应用，不删除容器或资料目录**。新版本ready失败或对比失败时自动启动原二进制、同一配置回滚，不需要等待人工操作。

一次前置查询因错误使用不存在的sessions.created_at退出，发生于任何信号发送之前；当时旧应用/监督仍正常，未中断服务。修正为实际schema的非秘密列后才执行成功升级。没有读取token_hash、实际用户配置或真实.env。

## 成功证据

00:57:06新应用ready=true、maintenance=false：URL仍 `http://127.0.0.1:53056`，新应用PID85455，监督PID85408，工具会话handle56515。新二进制 `/private/tmp/tokenlibrary-service-upgrade-qguy5hcp/tokenlibrary-new`；原二进制仍位于原目录 `tokenlibrary-restored-ui-w9jb1nkx/tokenlibrary`，没有覆盖。

升级前后逐项相同：

- libraryId `97c6c216-19ef-4e34-b97f-fecbf4653702`、epoch `08874133-4249-485c-8829-93d98cdb7485`，完整library字段。
- objects、documents、annotations、blob_refs、conflicts、conflict_drafts、revisions、operations、blobs共9类公开表的全量排序JSON摘要与计数。
- session的id/deviceId/libraryId/credentialGeneration/lastSeen/revoked字段；未读取会话令牌或哈希。
- 37份已有媒体实际字节数与SHA-256，均与登记记录相同。

证据目录 `/private/tmp/tokenlibrary-service-upgrade-qguy5hcp` 含 `before.json`、`after.json`、`client-queues-before.json`、`control.json`、`supervisor.json`、新应用日志。升级器 `/tmp/tokenlibrary-upgrade-restored-service.py` 只用于这次已确认身份的隔离实例，不是生产部署脚本；不要再次运行其硬编码旧PID控制段。原恢复目录supervisor.json已更新，旧描述保存在supervisor-before-upgrade.json。

此前00:42第二轮SIGSTOP记录中的52493及恢复守护已结束，不可沿用为新实例故障控制。任何再暂停应重新核对85455当前身份并新建有界恢复守护。新binary已在独立56881服务完成Core218项真实HTTP/Keychain回归；新服务本身另有36项API/synceng/merge测试。保留数据与ready不代替后续原生业务步骤验收。

## 02:57 第二次同实例升级

针对PDF恢复副本的全局批注ID主键冲突，53056再次受控短维护升级到含复合主键迁移的二进制。业务表及42媒体逐字节摘要、库/epoch、session身份/撤销状态保持；app9168、监督9132，证据 `/tmp/tokenlibrary-service-upgrade-kyq69u48/`。没有改客户端固定请求，旧binary仍保留。迁移、旧dump恢复和回放回归见[PDF恢复批注身份专项](pdf-recovery-annotation-identity.md)。
