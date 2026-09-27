# Catalog 组合筛选、关联改名与摘录验收夹具

2026-09-27 03:05：本节仅为正常 API 准备及真实 Core 查询预验证，原生操作结果需后续追加，不能由准备成功推断。

在53056合成库正常登录，通过3个 `createMarkdown` 和2个 `updateDocument` metadata操作创建独立资料，随后正常logout。库/epoch/root严格匹配既有合成服务；未触碰其他资料。`/tmp/tokenlibrary-u7-fixture-20260927/proof.json`保存完整正文、metadata、5个operation ID与回执、之前/之后对象计数及既有对象逐字段不变的摘要；脚本 `/tmp/tokenlibrary-prepare-u7.py`，重复执行已完成plan会拒绝。

| 标识 | ID | 文件名 | revision | 年份 | 完整标签 | 阅读状态 |
| --- | --- | --- | --- | --- | --- | --- |
| A | `26a68129-81f7-4a15-80ab-346058655c55` | `U7A_20260927.md` | 2 | 2024 | `U7完整标签20260927`、`U7前期` | 待读 |
| B | `d13dbd84-0354-4276-afdb-97d01f9684e1` | `U7B_20260927.md` | 2 | 2025 | `U7完整标签20260927`、`U7核心` | 在读 |
| C | `a138f82d-b63a-4b0f-be75-afa3ddad74b5` | `U7C_20260927.md` | 1 | 2026 | `U7完整标签20260927后缀`、`U7对照` | 已读 |

三者category=note、inbox=false、archived=false，**不含metadata.title**，因此文件改名会直接反映在资料标题。A/B互相存relatedIDs，C无关联；均无sourceIDs、excerpts。正文包含唯一 `U7Fixture20260927` 和各自字母anchor，都是合成文字，无附件或真实资料。

按当前 `CatalogMetadata` 的枚举raw值、`CatalogQuery` 完整标签匹配和年份/阅读状态组合语义构造。独立SDK probe读取实际API结果，调用真实Core `CatalogQuery`，`core-query-proof.json`断言全部通过：

1. 搜索 `U7Fixture20260927`：3条。
2. 加完整标签 `U7完整标签20260927`：A/B两条；C虽包含相同前缀，也必须排除。
3. 保留标签，年份2025—2026：只B。
4. 再加“在读”：仍B；切“待读”：0条。
5. 重置条件仍保留搜索：3条；年份从新到旧：C/B/A。

此probe使用先前封存真实Core静态模块，不写本机App库、不操作GUI、不占最新SwiftPM构建，也不代表新完整Core总套测试。

## Root最短原生步骤（准备时仍待执行）

1. 从A资料详情打开相关B，返回后给B**文件**改名 `U7B_改名验收.md`（不要另填书目标题）；回A相关行应显示新文件名，并仍打开原B ID/正文。
2. Catalog执行上述3→2→1与阅读状态/重置/年份排序；记录实际显示的名称和结果数，不仅看筛选控件值。
3. 使用C作摘录目标，输入唯一quote/comment标记；实际提交与再次点击须按UI允许时机观察，随后核对稳定excerptID、正文只追加一次、文档总数没有多建。此步骤不因夹具准备通过而预标幂等原生完成。

原生之后须记录新revision及允许的rename/metadata/excerpt变化，不要求与准备前metadata整块字节保持；原未修改的正文和关联身份应继续核对。

## 03:08—03:10 iOS 关联改名与双向移除

Root 在03:05:27安装的新finalrecovery包中实际从搜索打开A，详情相关B→打开B；03:09文件改名为 `U7B_改名验收.md`。B详情显示新名且相关A可打开；A详情相关行也更新为B新名并可再次打开同一B。03:10在B明确移除与A的关系，相关行消失。

03:10:54只读证明 `/tmp/tokenlibrary-u7-fixture-20260927/renamed-unlinked.json`，脚本 `/tmp/tokenlibrary-u7-proof.py`：动态定位当前iOS容器；A/B/C工作行、remote快照与PG正文/metadata/revision均一致。A为rev3、B为rev4、C仍rev1；三个ID、原父级和正文hash保持，A/B的relatedIDs均为空，来源/摘录仍为空，除B文件名和双向relatedIDs外没有其他语义或编码字段变化。全库666个对象ID精确等于setup结束时集合，没有多建；可发送队列0。

本段关闭“相关对象改名后名称更新/同ID导航”和“从反向详情移除双向边”的限定iOS旅程。组合筛选、阅读状态、排序与新摘录重复提交此时仍待原生，不由本段或Core预查询自动通过。

## 03:10—03:13 iOS 组合筛选实际顺序

Root实际在Catalog搜索 `U7Fixture20260927`，得到A/B/C三条。iOS搜索激活时系统隐藏工具栏，不能把本次结果记为“保持搜索词时打开筛选”：实际关闭搜索后回到全库646资料，再打开筛选。

1. 选择完整标签 `U7完整标签20260927`，先取消：仍为全库646，未应用草稿。
2. 重新选同一完整标签并应用：2条A/B，不含只有后缀标签的C。
3. 保留标签，加年份2025—2026：1条已改名的B。
4. 再加“在读”：仍1条；改“待读”：空结果，显示清除入口。
5. 清除筛选回到全库646；重新搜索 `U7Fixture20260927` 再得3条。

03:14:11只读证明 `/tmp/tokenlibrary-u7-fixture-20260927/filters-final.json` 与上一阶段 `renamed-unlinked.json` 比较：三篇iOS working完整行、remote完整行、PG完整字段均逐值一致，revision仍3/4/1，正文/书目/标签/状态/关系没有因筛选改变，queue0；全库对象身份集合仍666（其中646资料）。这组原生关闭取消不应用、完整标签匹配、年份与阅读状态组合、空态与清除的限定缺口；未执行原生年份排序，也没有证明搜索激活时筛选工具栏可达。摘录防重复尚未开始。

## 03:15—03:16 iOS 已有目标摘录双击防重复

Root在A详情用真实软键盘输入 `Doubletap`，键盘自动更正后的实际值为 `Double tap`；通过可搜索选择器精确选中原C，对“加入所选笔记”执行真实 `clickCount:2`。表单正常关闭并打开原C，03:15:42待提交0，页面实际渲染原文、一块Double tap及A来源。这里以真实提交后的文本为准，不将输入法自动更正当产品错误。

03:16:40独立证明 `/tmp/tokenlibrary-u7-fixture-20260927/double-submit-final.json`，脚本 `/tmp/tokenlibrary-u7-excerpt-proof.py`，相对于filters-final：

- C仍原ID `a138f82d-b63a-4b0f-be75-afa3ddad74b5`，revision由1到2；原正文作为精确前缀保留，仅追加一次 `> Double tap` 和一次指向A的 `tokenlibrary://document/26a68129-81f7-4a15-80ab-346058655c55`。
- excerpts恰一条，ID `05509d5a-af35-4f6c-adf7-2031fb119a65`，sourceID为A，quote为Double tap，comment为空，sourceTitle为U7A_20260927；sourceIDs只有A。C其他metadata、名称、父级、附件与批注字段保持。
- iOS working、remote快照和PG当前头的revision/完整正文/metadata一致。C仅一条本机sent更新，可发送0，全文SHA256 `d3cb446689de1951e2a0444500a5eda3476324ab7192ec1e03277fb35fd842e3`。
- A/B在本机工作行、remote和PG的全部字段与filters-final完全一致；全库666个对象ID集合也精确保持，没有新建另一个C或阅读笔记。

这关闭“iOS已有笔记目标正常双击提交不重复”的限定原生分支；保存失败重试、新建笔记分支和多端并发提交仍不能据此全部通过。另本轮发现普通关联/来源打开会沿用搜索焦点的问题已独立修复并补3红测，见[导航意图验证](navigation-search-intent.md)；其新包原生复验另记，不能混用本页旧包的关系跳转通过。
