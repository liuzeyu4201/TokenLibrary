# iOS 在回收站中移除反向关系并恢复

2026-09-27 01:11—01:13，使用更新后的iOS验证包及同库升级后的53056合成服务。GUI由主验收完成，本证明只读PG/SQLite与实际附件字节；没有通过SQL或辅助API代替用户操作。

## 对象与步骤

A为笔记 `254e29af-5a3d-4ebf-96b8-bc368254e562`，标题“iOS 资料编辑保护验收”，位于论文资料目录 `e00967ba-f4d4-4562-a92a-ed4df4f5aaca`；同目录另有回导 `Fixed.pdf`（d77981c1-bbd3-4c84-9b91-d3ea1f77d954）。B为root中的三页原件 `afecb79c-e124-4869-bbff-a72bafcbb684`。01:11基准已包括用户通过顶部保存的作者Synthetic Author，不能要求它退回更早的空作者。

| 原生步骤与只读取样 | A / B / Fixed / folder revision | 关键状态 |
| --- | --- | --- |
| 保存作者后的prelink，01:11:08 | 7 / 7 / 3 / 4 | 均active、relatedIDs空、queue0。 |
| A详情精确选择B并添加，01:11:37 | 8 / 7 / 3 / 4 | A存一条指向B的relatedID；B不复制第二条边，反向入口由查询显示。 |
| UI删除父目录，01:12:17 | 9 / 7 / 4 / 5 | A/Fixed/folder同batch回收；B仍active，A→B仍保留。 |
| B详情移除回收站A，01:12:46 | 10 / 7 / 4 / 5 | UI明确显示A在回收站、关联仍保留，点击移除后行消失；A.relatedIDs空，仍trashed，队列0。 |
| UI还原整个父目录，01:13:17 | 11 / 7 / 5 / 6 | A/Fixed/folder恢复active和原父级，无purgeAt/trashBatchId；关联没有复活，回收站空态。 |

删除批次为 `99d329d9-ee8d-4cc5-8892-f74ae064e5ed`。删除时间2026-09-27 01:11:48.809104 +08:00、期限2026-10-27同一时刻；移除关系时这些字段及physical parent=NULL、originalParent均逐项保持相同。此路径真实执行了原来会把原父级误判为移动并返回422的服务端分支，参见[服务端修复回归](server-sync.md)。

## 完整性证明

总证明 `/tmp/tokenlibrary-ios-related-trash-proof.json` 引用prelink/added/deleted/removed/restored五份快照；另保留更早baseline以记录作者字段的明确修改。各次iOS与服务端ID、revision、metadata、state、正文一致，所有记录队列0。除预期relatedIDs变动，非关系metadata（包括作者）、正文、PDF annotation records与assets在五阶段都未改变。

笔记全文仍 `# 新笔记\n\n`，SHA-256 `b649b90a28e7265793b69bb7cadae9d010e0272eeeadbc82d0398bfe504fb34d`。B的两端实际原件均74,791 B、hash `5e75077459f63545f07f55a4862c27275a218a41635f50ddfa6635eb3759f424`；Fixed的两端实际原件均84,144 B、hash `836cee8aed5e0617211c85dc5a620d186e1e4127a0685166f2af19b3e21d7569`，所有阶段相同。四个目标name/ID各只有一份，旅程开始后无create操作。

主验收同时看到B的Gamma阅读笔记反向引用保留；独立核对笔记1303abc2-40a3-462e-9e4e-9ff7348da29e仍revision1，其全文、metadata、单一excerpt、sourceID、第3页和原件hash与00:41基线完全相同。普通相关关系移除没有清除来源摘录。

本次关闭该iOS样本的反向关系占位/显式移除、回收站父级不变的metadata同步、恢复后关系不复活及原件保留。没有等待30天，也不替代Mac对应GUI、同时离线并发添加/移除或所有未知旧关系形状的验收。[主原生记录](native-ui-validation.md)保留实际界面步骤。
