# iOS 专题成员、删除和还原

2026-09-27 01:20—01:36。主验收通过iOS实际UI操作53056合成库；独立核验只读PG、当前模拟器SQLite、原件字节以及新Mac客户端SQLite。覆盖L11/L12/L14的关系成员流程，不代替专题内部物理子项迁移或删除时并发新建子项。

## 对象与五阶段

笔记A为 `254e29af-5a3d-4ebf-96b8-bc368254e562`，文件名iOS层级移动恢复笔记.md，资料标题iOS 资料编辑保护验收；仍位于论文资料目录 `e00967ba-f4d4-4562-a92a-ed4df4f5aaca`。新专题为 `4947e4f8-a359-475d-bae9-dfaaa3d72095`（iOS交叉研究专题），原专题为 `cd142511-0a76-4464-b7e6-ff0cb9d4082f`（原生研究专题）。另只读观察Fixed.pdf `d77981c1-bbd3-4c84-9b91-d3ea1f77d954`，防止把专题删除错误传播到实体目录资料。

| 原生操作 / 独立取样 | A revision / 成员关系 | 新专题 revision / 状态 | 资料 / 活跃对象 / 队列 |
| --- | --- | --- | --- |
| 加入两专题，01:20:49 | 13 / 新+旧 | 1 / active | 633 / 652 / 0 |
| 移出新专题，01:21:43 | 14 / 仅旧 | 1 / active | 633 / 652 / 0 |
| 加回新专题，01:23:42 | 15 / 新+旧 | 1 / active | 633 / 652 / 0 |
| 明确删除专题保留资料，01:34:07 | 15 / 新+旧保留 | 2 / trashed | 633 / 651 / 0 |
| 回收站还原，01:35:26 | 15 / 新+旧保留 | 3 / active | 633 / 652 / 0 |

移出时新专题为空，原专题仍5项并包含A。01:33新包中使用可见更多菜单→删除专题→“删除专题，保留资料”，仅新专题消失。回收站仅列该专题、10月27日期限，没有A或Fixed；01:35还原后回收站空态。重新进入资料库看到总633、两专题，新专题恰好一项原A，作者、年份、已同步与原路径仍可见。

## 独立数据证明

五个快照为 `/tmp/tokenlibrary-ios-topic-{joined,removed,rejoined,deleted,restored}.json`，聚合证明 `/tmp/tokenlibrary-ios-topic-complete-proof.json` 于01:36:25逐字段比较。每次都重新通过simctl获取当前验证App容器，不沿用升级前路径。

- A身份、正文、父目录、除topicIDs外的metadata全程不变；正文SHA-256为 `b649b90a28e7265793b69bb7cadae9d010e0272eeeadbc82d0398bfe504fb34d`。作者Synthetic Author、年份2026、原相关/来源字段保留，删除和还原未重新写A。
- 新专题始终同一个ID，删除时物理parent为NULL、original_parent为库根，保留期限为UTC `2026-10-26T17:33:50.841242+00:00`，即本地10月27日01:33:50。还原后回原根、purge/batch清空。没有新建同名专题代替还原。
- 原专题完整字段保持；Fixed revision5、原件实际字节/hash及metadata全程不变。A、新专题、Fixed三个目标文件名最后各恰好一份。
- 所有阶段iOS/服务器对应revision、状态、正文、元数据和逻辑父目录一致、queue0；文档633与全部对象652保持。只有专题被软删除时活跃对象暂为651。

新Mac客户端 `/private/tmp/TokenLibrary-Concurrent-20260927-a6mu74bv` 在01:34:44收到删除、01:35:47收到还原。独立证明为 `/tmp/tokenlibrary-mac-concurrent-topic-{deleted,restored}.json`，四个目标的逻辑快照与iOS/服务器相同、队列0；最终全部652对象active、633资料。服务端trashed物理parent为NULL，公共snapshot及客户端保留original_parent，这是存储表示差异，核验按逻辑父比较。

此流程证明iOS实际成员开关/移出/加回/删除确认/回收站还原，以及Mac收到这两次状态变化。尚未覆盖原生专题内部物理文件迁移、删除同时另一设备新增实体子项、所有PDF成员组合；对应Core/API自动测试不能冒充这些原生旅程。
