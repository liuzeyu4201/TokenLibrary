# iOS 多级目录、分项还原与显式移动

2026-09-27，签名验证版iPhone模拟器、53056恢复后的合成库。GUI由主验收执行，以下证明只读SQLite/PG和已有版本，没有写资料或操纵界面。

## 原生旅程与独立状态

创建 `iOS层级回收验收` → 子目录 `论文资料` → `iOS层级移动恢复笔记.md`，正文保持默认 `# 新笔记\n\n`。三个固定ID：外目录515766a3-6259-4391-97dc-d9fad78348c6，子目录e00967ba-f4d4-4562-a92a-ed4df4f5aaca，笔记254e29af-5a3d-4ebf-96b8-bc368254e562。

| 阶段 | 实际状态与证据 |
| --- | --- |
| 删除子目录后，00:53:07只读快照 | 子目录与笔记均trashed/revision3，共同删除批次及到期时间2026-10-27 00:52:54 +08:00；外目录active/revision2。快照晚于删除，因此创建前父子链取自已有revision1/2，不假称捕获了删除前实时基线。 |
| 只还原笔记，00:53:59 | 主验收回收站仅剩子目录；笔记active/revision4回到可信root，purgeAt清除，子目录仍trashed/revision3并保持原到期日。 |
| 再还原子目录，00:54:46 | 子目录active/revision4回到外目录，笔记仍在root；恢复父目录没有擅自再次移动已经还原的笔记。原生回收站显示空态。 |
| 更新包显式移动，00:57:42 | 编辑器更多→移动到→论文资料（显示外目录路径），笔记revision5进入原子目录；子目录仍revision4，外目录仍revision2，三者active、purgeAt/trashBatchId均空。原生队列从1归零。 |

新包还实际完成：搜索命中的文件夹点击后退出搜索、收起键盘并进入目标目录；编辑器更多菜单的移动入口可见。这是修后原生证据，与LibraryFolderNavigationTests4项/模型72项自动证据分开记录。

## 数据完整性与边界

四次记录的iOS/服务器ID、revision、状态、metadata和正文完全一致。笔记全文SHA-256一直为 `b649b90a28e7265793b69bb7cadae9d010e0272eeeadbc82d0398bfe504fb34d`；三对象metadata各自前后不变，未替换身份或创建副本。最终两侧每个目标name及ID均只有一份，所有记录时点队列均0。

总证明 `/tmp/tokenlibrary-ios-hierarchy-proof.json` 引用 `/tmp/tokenlibrary-ios-hierarchy-{baseline,note-restored,folder-restored,final}.json`；baseline包含此前持久revision。实际恢复与移动不采用SQL修正，数据库查询全部只读。

本次关闭该iOS样本的多级创建/改名、普通子目录递归回收、单独子项还原回退root、父目录还原不回收已还原子项、显式移动回原目录。没有等待30天，不证明到期删除；也未测试同名恢复、目录循环、并发新增子项或所有权限失败分支。主验收详见[原生记录](native-ui-validation.md)。
