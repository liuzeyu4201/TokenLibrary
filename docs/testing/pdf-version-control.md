# PDF 换版：正常 API 控制方案

准备时间：2026-09-27 01:20—01:27。准备阶段只完成只读基线、合成新版文件、脚本静态检查和无网络预览。随后主验收明确授权，01:28正常API换版已committed；01:28—32指定iOS对象的换版提示、来源保护、导出过滤与明确API恢复闭环已完成，见末节。 适用 L08/L22；主验收控制 GUI，执行步骤须与其当前文档状态协调。

## 目标与文件

仅允许恢复服务 `http://127.0.0.1:53056`，库 `97c6c216-19ef-4e34-b97f-fecbf4653702`，epoch `08874133-4249-485c-8829-93d98cdb7485`。不暂停服务、不读原生凭据、不直接写 SQLite/PG。脚本用专属合成 deviceId 登录，并在结束时注销自己的会话，原生 Mac/iOS 会话不受影响。

目标 B 为 `afecb79c-e124-4869-bbff-a72bafcbb684`（research-three-pages_2.pdf），冻结 revision7，含两条本库批注和一份 Gamma 来源笔记。旧主原文32e7关联原阅读笔记的三条摘录，影响更大；Fixed只有嵌入原件的批注、没有metadata批注或来源笔记，不能验证待核对状态。B是现有合成资料中范围最小且覆盖完整的目标。

| 文件 | 字节 / 页数 | SHA-256 |
| --- | --- | --- |
| 原件备份 original-three-pages.pdf | 74,791 / 3 | `5e75077459f63545f07f55a4862c27275a218a41635f50ddfa6635eb3759f424` |
| 新版 research-revised-three-pages.pdf | 52,685 / 3 | `5ec4987495ec30af9737f6074306acc22ef08b460e7261a234f7af7ac5e94f37` |

两文件位于 `/tmp/tokenlibrary-native-pdf-version-control/`。新版由 [可重复生成脚本](../../tests/fixtures/generate_pdf_revision_fixture.py) 制作，包含真实中英文本与 Revision Two Alpha/Beta/Gamma 锚点；没有嵌入批注。pypdf严格逐对象解析、5个stream解码、三页Poppler渲染均通过，stderr为空；第一页另作图像目视检查。原件为输入字节的完整复制，不以无效填充制造新版。

冻结基线为同目录 `prepared.json`：完整原snapshot、revision、文件hash、专属deviceId、固定新blobId、switch/rollback operationId。旧blob为 `5865785e-b346-44d5-8643-ef9559b9a386`；新blob预留 `6bd05e81-7093-4e73-876d-ef741c8d792c`。准备时仅预留标识，01:28授权执行后已正常上传并切换到此blob。

## 可执行步骤与守卫

[控制脚本](../../tests/fixtures/control_pdf_version.py) 默认只预览，**不访问网络**：

```sh
/Users/token/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 \
  tests/fixtures/control_pdf_version.py \
  /tmp/tokenlibrary-native-pdf-version-control/prepared.json
```

主验收决定开始后，在仅含合成测试凭据的 `TEST_TOKENLIBRARY_USER` / `TEST_TOKENLIBRARY_PASSWORD` 环境中执行。脚本不打印密码/token，不读取 `.env`、原生Keychain或已存会话。下列switch参数已在01:28明确授权后执行一次：

```sh
/Users/token/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 \
  tests/fixtures/control_pdf_version.py \
  /tmp/tokenlibrary-native-pdf-version-control/prepared.json \
  --execute switch --confirm-object afecb79c-e124-4869-bbff-a72bafcbb684
```

执行时核对固定origin/library/epoch/device、非维护、active且无冲突、revision7及完整业务snapshot完全等于基线；任一变化即停，不自动重建基线。通过正常uploads API上传分块并核对服务端下载字节/hash，再次确认对象未变化，用固定operationId和base revision发送 `updateDocument`，desired只含 `pdfBlobId`。服务端保留metadata、原批注内容/坐标/旧pdfBlobId，将两条placementState改为needs_review。旧blob上传前后都下载核对hash。

请求在发送前冻结为 `switch-request.json`（0600）；成功响应和前后snapshot写入 `switch-result.json`。超时/503不造新operation；重新运行先查原回执。已committed则不重复写入；冲突、非预期字段变化或基准过时停止，留下请求供审查。上传是幂等同blob/同bytes；不会清理历史blob。

## 原生应观察的内容

1. 先离开B阅读器并确认queue0，再执行switch，等待正常同步下载新版；重新打开可见新版英文/中文3页。旧阅读位置绑定旧hash，不自动跳旧第3页，应显示“已有阅读位置的文件版本无法匹配，未自动恢复旧页码。”。
2. 两条旧批注保留，列表显示“待核对 · 原第 n 页”，不提供跳旧坐标的按钮；新版不出现旧绿色高亮或蓝色备注。阅读器提示原文件已变化、旧批注位置需要核对。不要编辑/删除批注，否则严格回滚会拒绝覆盖新工作。
3. 从Gamma阅读笔记 `1303abc2-40a3-462e-9e4e-9ff7348da29e` 检查来源，显示版本变化；旧hash来源链接不能直接跳到新版第3页。笔记原文、mobile note评论、摘录ID和旧hash均保留。
4. 可导出新版含批注PDF并独立解析：新版3页、无误绘的旧坐标。不能将UI显示或自动测试直接当成外部导出结构证明。
5. 打开新版可能正常保存新的readingPositions/readingStatus，使对象revision增加。这是阅读行为，不是控制脚本修改书目信息。originalFileHash仍是导入时原始文件的元数据；当前阅读版本判断使用实际本机PDF文件hash。

实现核对点：`server/internal/synceng/annotations.go` 的bindAnnotations；`clients/LibraryCore/Sources/LibraryCore/PDFAnnotations.swift` 版本判定；阅读器/来源路由和阅读恢复见 [PDF阅读验证](pdf-reading.md)、[批注与导出证据](pdf-fixtures.md)。

## 恢复测试现场

**仅换回旧blob不会自动把needs_review改回attached。** 这是服务端保留待核对状态的既定行为，不应以自动恢复旧批注为预期。本控制脚本提供明确的测试现场恢复操作：恢复原blob、原两条完整attached批注及基线readingPositions/readingStatus。它不是产品中的用户重新定位操作。

```sh
/Users/token/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 \
  tests/fixtures/control_pdf_version.py \
  /tmp/tokenlibrary-native-pdf-version-control/prepared.json \
  --execute rollback --confirm-object afecb79c-e124-4869-bbff-a72bafcbb684
```

回滚要求switch已有committed回执，目标仍为预期新blob；除readingPositions/readingStatus外，正文、位置、名称、书目、关系、批注ID/内容/坐标必须仍等于预期换版结果。任何新用户编辑使脚本拒绝覆盖，不能绕过守卫。回滚使用当前revision、冻结独立operationId和请求，不改来源笔记。恢复后检查旧文件hash、两条attached、原页码/来源链接、queue0。保留两份文件及两个历史blob，避免损失验收材料。

当前证据边界：生成夹具严格解析/渲染及指定iOS对象的正常API换版/原生观察/明确恢复闭环已完成；不等于存在原件替换GUI，也不覆盖双端同时换版或用户重新定位旧批注。

## 01:28 实际正常API换版

主验收确认iOS停在专题列表、B无编辑且queue0，明确授权switch；另一代理独立只读复核脚本/API协议及回滚附着语义后执行。2026-09-27 01:28:17.963，固定operation `65e020fe-5516-4825-904e-3c34b6f00503` committed，B revision7→8，新blob及52,685B实际下载SHA-256均等于上表。回执inputHash为 `304a12cce5054739151b18574f56f4c429f58a1f8acbbc9088820cc985acff16`。

两条annotation IDs `76ccd9a3-07e6-4c13-a952-9f4caa798294`、`cef58e16-ad79-42d3-8464-0af09ad894f5` 保留原pdfBlobId、文字、页码和几何，placementState均为needs_review；metadata完整等于基线。旧74,791B blob实际下载hash未变。专属控制会话结束时正常logout，没有使用原生会话。

证据为同目录 `switch-request.json`、`switch-result.json`。01:28:47另以只读PG比较 `switch-isolation-proof.json`：A、新旧两个专题、Fixed的完整业务字段与01:23 rejoined快照一致；Gamma来源笔记仍revision1，正文hash `8dd456064f05caf0172c1ddda1593fb6ecf654ab6b05fcb3588279d65b963df0`。没有波及专题或来源正文。

01:28完成API时保留新版供原生验证，未立即rollback；后续原生观察和01:31明确恢复见下节。API返回needs_review本身不代替原生观察。rollback的post-check允许阅读状态在原生正常读页时变化，最终应以保存的完整after快照报告实际阅读记录，不声称任意并发读页也精确复原。

## 01:28—01:30 原生显示与真实导出

主验收在iOS重新打开B，首开为1/3，明确提示文件版本不匹配、未恢复旧页码；待核对列表保留两条原文字，无跳页按钮。实际翻至新版2/3、3/3没有旧绿高亮/蓝备注覆盖。此段是GUI操作证据，不由API状态推断。

01:29通过系统fileExporter保存Version.pdf到Files的ios-import-acceptance目录，01:30:14独立读取真实产物，保留为同控制目录 `native-Version.pdf`。它为45,502B，SHA-256 `d6fed7e4bec10f92f1933b6287cfc438f84e5e2c607119f7009f1936b2241fa8`：3页、18个对象、6个stream严格解码，所有页零annotations、所有对象无NM，三个新版锚点均可提取。Poppler渲染三页无警告，第2/3页另目视无旧覆盖、中英文字完整。

`native-version-export-proof.json` 同时核对新版fixture/iOS本机/服务器52,685B字节相同，旧blob74,791B仍与保留原件相同；两条本机metadata批注仍needs_review且绑定旧blob，队列0。导出没有把待核对旧坐标写进新版，也没有修改两版PDF输入字节。Gamma来源保护与恢复随后在01:30—32完成，见下节。

## 01:30—01:32 来源保护与恢复闭环

01:30—31，主验收打开Gamma阅读笔记的旧第3页来源链接，B提示“原文件已经变化…未跳转旧页码”。为排除碰巧已停第3页，将新版显式停在第1页、返回Gamma再点旧链接，实际仍1/3并显示相同提示。来源详情保留原quote、mobile note及橙色“来源版本已变化，位置待核对”，没有修改笔记。

主验收离开B后明确授权恢复。01:31:27.851，正常API rollback operation `ea2fc4a3-597a-4d1e-972d-754e73560757` committed，revision11→12：恢复原blob、原2条完整attached批注及冻结阅读记录。新版期间revision9—11为正常读页记录变化，不当作控制脚本编辑正文。回滚前守卫检查除此以外全部字段与预期换版结果相符。

01:32:14只读 `rollback-convergence-proof.json` 核对iOS/服务器均revision12，PDF及metadata/annotations一致、queue0；原74,791B本机/云字节等于原hash，新52,685B blob仍完整保留。实际阅读记录精确等于冻结的旧hash第3页基线。Gamma仍revision1、完整正文/metadata不变；A、新旧专题和Fixed也保持原快照。两个专属控制session均已revoked，没有复活或撤销原生会话。

01:32主验收再从Gamma来源首次打开旧PDF，准确3/3，原中文蓝色备注可见，版本变化banner消失；管理列表两条均显示前往原第3/2页按钮，不再待核对，原文字和绿/蓝外观保留。聚合索引 `complete-proof.json` 明确区分主验收GUI观察与独立数据/结构证明。

该闭环覆盖一个指定iOS合成PDF的旧页码保护、待核对显示/不误绘、旧来源阻止跳页、真实导出过滤和明确恢复后来源/批注恢复。仍不覆盖原件替换GUI（当前无此入口）、双端并发换版或产品内用户重新定位/确认待核对批注；API恢复属于合成验收现场恢复。
