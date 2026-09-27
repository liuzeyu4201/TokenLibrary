# PDF 夹具与 SDK 验收

更新：2026-09-27。F06/F10/F18/F20/L02/L22 的分层证据；本页区分 CLI 调用真实 PDFKit、外部阅读器校验与 Mac/iOS 已实际执行的限定原生旅程；任何一层都不能代替另一层的未验范围。

## 合成夹具

生成脚本：[generate_ui_fixtures.py](../../tests/fixtures/generate_ui_fixtures.py)。所有内容自行合成，无下载资料、用户数据或真实凭据。输出目录 `/tmp/tokenlibrary-ui-fixtures`，完整清单在 manifest.json。

| 文件 | 页数 | 字节 | SHA-256 |
| --- | --- | --- | --- |
| large-near-50mb.pdf | 8 | 49,745,911 | dd66f1e4375fe2f588f1cf8abc9f6d522c52f739154e93be9d9ae0ff130ef104 |
| research-three-pages.pdf | 3 | 74,791 | 5e75077459f63545f07f55a4862c27275a218a41635f50ddfa6635eb3759f424 |
| scanned-no-text.pdf | 1 | 84,240 | 80a973b9768ae1b1182fc2375c3b228fac646b3d067b89038e2c51a6665deedd |
| fixture-diagram.png | — | 50,786 | 2a85488c6ed062f681b3fc4f518777f00f22389f6f1be7cdac2aeffe73148393 |
| research-notebook.md | — | 1,416 | 42747f1d655f936ba3d700dd8416c5143e8f820b2304dd527ce023e51b9dde92 |

大文件是 8 张独立、实际显示的 1800×1150 RGB 无损图像，配有中英文可选择文字。文件主体来自真实图像流，未追加填充、无效字节或未引用对象；49,745,911 B 小于 50,000,000 B。小 PDF 是 3 页双语研究资料；扫描件只有图像，PDFKit 和 pypdf 的文本提取均为空。Markdown 包含 GFM 表格/任务/代码、行内与块公式、Mermaid 和相对图片 media/fixture-diagram.png。

## 测量方法与结果

工具为 macOS 27.0 (26A428)、Swift 6.4 / Xcode 27、系统 PDFKit；外部校验使用 pypdf 6.10.0 与本机 Poppler。Python 由 workspace dependencies 提供，未安装系统依赖。

每份 PDF 单独进程，5 次顺序打开/提取/双语查找；先进行可读性与命中数断言，再渲染所有页、添加高亮与中英 emoji 备注、导出、重开检查。导出编译仓库实际 PDFAnnotations.swift / PDFKitExport.swift，未复制另一份导出实现。原件前后 SHA-256 相同。

**时延是本机诊断数据，非性能门槛通过声明。** 同机存在 Xcode/SwiftPM 构建，首样本还包含 PDFKit 启动；5 个样本的 p95 实际为最大样本，不能当作统计稳定的线上 p95。每个进程串行执行，未同时运行三个 PDF 测量进程。

| Fixture | Open median / p95 ms | Full text median / p95 ms | Search median / p95 ms | Render all pages ms | Serialize / write ms | Peak RSS MiB |
| --- | --- | --- | --- | --- | --- | --- |
| large-near-50mb | 0.130 / 47.964 | 3.554 / 13.269 | 0.161 / 1.066 | 76.866 | 58.205 / 17.835 | 305.00 |
| research-three-pages | 0.116 / 48.682 | 1.887 / 4.892 | 0.106 / 0.437 | 21.311 | 31.473 / 0.986 | 61.53 |
| scanned-no-text | 0.371 / 91.729 | 0.326 / 5.850 | 0.022 / 0.105 | 44.269 | 36.639 / 1.076 | 58.59 |

RSS 为整个进程最高驻留内存，包含框架、图像解码、缩略图、原文件和导出 Data，不是增量内存。/usr/bin/time -l 同时记录 physical footprint；不能将 RSS 直接等同 iPhone 内存开销。

大 PDF 英文与中文检索各 8 个命中，小 PDF 指定 Beta/乙各 1 个，扫描件 0 个。各页渲染为 612×792 SDK 缩略图，并强制取得 TIFF 数据，避免只测惰性句柄。原文件保持不变、页数保持、原文字层仍可搜索。

## 导出兼容性与回归

首次外部校验发现 FreeText 字体流缺 /Length、/DA 类型错误；随后目视发现 Highlight 坐标重复位移。修复说明见 [PDF 批注实现](../implementation/pdf-annotations.md)。Helvetica 单独替换仍会在中文后备字体中复现问题，没有作为最终解决。

最终导出在 final-results/。严格校验会遍历全部间接对象并解码所有流，不能只调用 PdfReader 构造器。大/小/扫描 PDF 分别通过 24/11/6 个流；检查真实 FreeText、Highlight、Unicode 内容、DA String 和位于 Rect 内的 QuadPoints；Poppler 共 12 页渲染成功且 stderr 为空。已目视大 PDF 第 1 页、小 PDF 第 1/2 页及扫描页，中文“文字备注、读书研究”、英文、📚 ✅ 均可读，黄色高亮准确落于选区。

Core 的 PDFAnnotationTests 10 项已包含在 19:12:23 的 179 项及23:59:14的204项完整回归（均0失败、0跳过，隔离服务51525）；其中第9项直接验证导出高亮坐标，第10项验证本应用导出PDF作为新原件导入后，原有批注在显示和再次导出中仍保留。另覆盖第三方原注释、重复导出幂等、managed对象身份稳定、重复项清理、legacy解码与needs_review/原件版本不匹配拒绝绘制。后续增加序列化结构10项，与其他新增内容于00:48:50在最新隔离56881完成218项全套、0失败/跳过；见[客户端同步验证](client-sync.md)。

## iOS 原生导出与平台序列化缺陷

00:32—35，主验收在iOS新导入的 `research-three-pages_2.pdf` 上搜索Beta并添加高亮，改绿色和文字 `Research Anchor Beta iOS`；清除选区、翻第3页后添加 `iOS 第三页备注 🧪`。00:33:50独立核对iOS/云revision7、两个独立annotationID、queue0，原件仍74,791 B及上述5e7507…hash。证据 `/tmp/tokenlibrary-ios-native-pdf-annotation-baseline.json`。

通过实际系统Files导出后，应用外QuickLook能看到绿色高亮与中文备注；独立Poppler渲染也确认🧪外观。但该83,728 B原生文件的严格全对象遍历失败：不存在的object6在xref标记为offset0且in-use，两条批注 `/NM` 丢失。剩余11个流可解码，真实Highlight/FreeText和Unicode内容均在；原页面没有被扁平化。原生产物为 `/tmp/tokenlibrary-ui-fixtures/ios-native-annotated-export.pdf`，SHA-256 `7491fc364f9975cbbe0511a8033490e28e4a0c1345bfcb05718db73a3dad7ae9`，完整证据 `/tmp/tokenlibrary-ios-native-pdf-export-proof.json`。**原生能显示没有被记录为严格结构验收通过。**

独立iOS SDK探针随后比较6种官方批注标识写法、无批注baseline及3种保存/再保存方式；21份输出都复现该xref缺陷，6种标识写法内存可读、落盘全部丢失。当前修复为受限的PDFKit输出结构校验和标识保留，配套真实iOS/Mac SDK、全对象/流及Poppler检查见[iOS导出结构回归](ios-pdf-export-serialization.md)。当时仍要求换包再次Files导出，没有用SDK结果代替该最后旅程。

该原生复测随后于01:01—01:02完成：00:55 navigation签名包通过实际Files另存 `Fixed.pdf`，84,144 B、SHA-256 `836cee8aed5e0617211c85dc5a620d186e1e4127a0685166f2af19b3e21d7569`。独立全部xref对象严格读取、11流解码、3页Poppler无警告；两条NM与当前annotationID完全一致，中文与🧪外观保留，object6为free。原文档仍revision7且74,791 B原件与最初输入逐字节相同。应用外系统Preview实际显示绿色高亮与中文备注。证据 `/private/tmp/tokenlibrary-native-pdf-final-17pl2d7t/proof.json`，详见上述专项；旧缺陷导出仍保留作对照，没有覆盖。此项关闭修后实际iOS导出结构，回导后编辑/删除等旅程另记。

随后原生把Fixed回导为独立d77981c1…，再导出Repeat.pdf。01:06:13独立严格核验81,348 B、SHA-256 `5e2d7a316c4a940e0ac4ca34f6ff5e96291f88e99a1575f57654de8281fdeef3`，3页/10流/两条原NM均保留，全部渲染无警告，没有批注增殖；证据 `/private/tmp/tokenlibrary-native-pdf-final-jnq4wo4j/proof.json`。回导本机/服务器原件与首次Fixed逐字节相同，本库新增批注metadata仍零；原afec…输入原件与两条metadata批注也不变。原件自带批注没有自动变为本库可编辑记录，空态文案已澄清该区别。此段关闭回导后显示及再次导出保留；新增/删除本库批注的混合原件更多操作仍有独立边界。

另00:36—37从此PDF的Gamma第3页新建阅读笔记，评论 `mobile note`。00:41:18只读确认独立笔记1303abc2…的iOS/云revision1、完整正文与metadata一致、单一excerptID、页码2（零基）及原件hash正确，队列0，证据 `/tmp/tokenlibrary-ios-native-excerpt-proof.json`。此项覆盖新建摘录，没有执行失败重试或双击幂等。

## 原生 Mac 导出的独立外部验证

2026-09-26 19:03，主验收从隔离 Mac 应用通过系统保存面板生成 `/tmp/tokenlibrary-ui-fixtures/native-annotated-export.pdf`。该文件是实际 UI 产物，不是 SDK 探针生成。随后独立运行严格解析及 Poppler 渲染，结果为 103,013 B、3 页、11 个流全部可解码、3 页渲染零警告，恰好 1 个 Highlight 与 1 个 FreeText。SHA-256 为 `79e0d2f39f87a02061de04b67ec50c0383dd93d9aff39bb64118e585f1c76ae9`。

目视第 2 页的 Research Anchor Beta 黄色高亮和第 3 页“文字备注、读书研究 📚 ✅ — exported comment.” 两行文字，均显示正确。主验收同时记录来源链接跳第 2 页、页码前往第 3 页、修改后 AX 仅有一个高亮对象，独立外部文件也没有重复批注。

只读查询隔离验证库中 `32e7f3ee-db86-42dc-94d0-34c90c07fad7` 的 pdf_path 后，对库内实际原件逐字节比较输入夹具：均为 74,791 B、SHA-256 `5e75077459f63545f07f55a4862c27275a218a41635f50ddfa6635eb3759f424`，完全一致。未读写真实资料库。

证据：`/tmp/tokenlibrary-native-pdf-external.json`、对应 errors.log（空），以及 `/tmp/tokenlibrary-ui-fixtures/native-rendered/native-annotated-export-{1,2,3}.png`。此项关闭 Mac 本次中文批注外部导出旅程，不代表所有 Mac/iPhone PDF 交互或 50 MB 原生验收均已完成。

## 接近 50 MB 的 Mac 原生导入与附件核验

2026-09-26 19:20:58，主验收在恢复后的53056库通过系统 Open 导入 large-near-50mb.pdf，界面显示资料与附件已同步、待提交0；实际打开8页及RGB图像，查找 `Large PDF Anchor 8` 唯一命中并跳到8/8。UI操作证据由主验收记录于 [原生记录](native-ui-validation.md)。

独立只读查询并核验对象 `2e8f590b-c345-4634-b34e-b493d98e8489`、blob `5614bee4-fb98-440f-aa64-54cd040cfe9c`：输入夹具、本机PDF、服务器对象文件、独立HTTP下载均为49,745,911 B，SHA-256均为 `dd66f1e4375fe2f588f1cf8abc9f6d522c52f739154e93be9d9ae0ff130ef104`。上传记录为complete，48块、索引0—47、各块大小合计49,745,911 B。本机记录revision2/已同步，下载HTTP200、Content-Length与X-Content-SHA256一致，下载文件仍为8页。辅助校验会话已正常logout。

证据 `/tmp/tokenlibrary-native-large-file-proof.json`，下载产物 `/tmp/tokenlibrary-ui-fixtures/native-large-http-download.pdf`。单次本机loopback下载加写盘耗时0.059781秒，仅为该次传输；系统Open点击至AX/截图工具返回3.714秒、文档截图1.36秒包含工具开销，均不是纯导入耗时、稳定p95或公网性能。19:20时尚未做第二原生客户端全库下载；后续iOS证据见下段。本样本在19:14备份之后导入，不属于该备份的28附件。

23:40，iOS首次同步后的21/21附件实际文件大小/hash均与下载记录相同，包括此49,745,911 B原件，见[iOS首次同步证明](ios-first-sync-proof.md)。23:59，更新后的签名验证包原生打开此8页PDF，从第1页点击“另一设备继续阅读”到第8页，再查找 `Large PDF Anchor 7`，显示1/1并跳到第7页，搜索完成自动收键盘。此项关闭该模拟器样本的完整下载、打开、继续阅读与查询跳页；没有测得稳定交互p95、持续滚动帧率或真机内存。

## 复现

先通过 workspace dependencies 找到含 reportlab、Pillow、pypdf 的 Python，赋给 TASK_PYTHON；无须安装依赖。从仓库根目录执行：

```sh
"$TASK_PYTHON" tests/fixtures/generate_ui_fixtures.py
swiftc clients/LibraryCore/Sources/LibraryCore/PDFAnnotations.swift \
  clients/LibraryCore/Sources/LibraryCore/PDFKitExport.swift \
  clients/LibraryCore/Sources/LibraryCore/PDFExportSerialization.swift \
  tests/fixtures/benchmark_pdfkit.swift -o /tmp/tokenlibrary-pdf-probe
/usr/bin/time -l /tmp/tokenlibrary-pdf-probe \
  /tmp/tokenlibrary-ui-fixtures/large-near-50mb.pdf \
  /tmp/tokenlibrary-ui-fixtures/final-results
"$TASK_PYTHON" tests/fixtures/verify_pdf_exports.py \
  /tmp/tokenlibrary-ui-fixtures/final-results/large-near-50mb-annotated.pdf \
  --render /tmp/tokenlibrary-ui-fixtures/final-results/rendered
```

另两个输入按同样命令逐个执行。Core 测试命令为 `swift test --package-path clients/LibraryCore --filter PDFAnnotationTests`。字体失败探针 tests/fixtures/probe_pdf_annotation_fonts.swift 仅用于复现旧问题，其生成 PDF 不属于最终成功产物。

临时原始证据：/tmp/tokenlibrary-pdf-portable-tests.log、/tmp/tokenlibrary-{large-near-50mb,research-three-pages,scanned-no-text}-final-benchmark.log、/tmp/tokenlibrary-pdf-final-external.json 及对应 errors.log（空）。SDK 产物 JSON 保存每个样本时延、字节与哈希。

尚需原生验证：iOS删除批注/扫描备注、大文件持续滚动与真机内存；Mac大PDF批注交互、持续滚动与精确卡顿测量；双端并发换版与用户重新定位待核对批注。iOS系统导入/拒绝、新建两种批注、修改高亮、修复后系统导出严格结构/应用外显示与新阅读摘录已有上述限定证据；未从可视外观推断内部结构通过。见[原生界面记录](native-ui-validation.md)。

01:19主验收在Fixed.pdf第3页仍见内嵌蓝色备注，管理批注实际显示“暂无本库新增批注”及“原件自带批注仍保留在PDF中”的说明。该文案已在新签名包复验，说明列表管理metadata新增批注，不表示原件批注被删除。实际PDF换版的下一步已有[正常API控制方案](pdf-version-control.md)，01:28已授权通过正常API换到新blob，原件hash不变、2旧批注needs_review；随后指定iOS对象已完成待核对/旧来源禁止跳页/真实导出零旧批注与API明确恢复闭环，详见换版文档；不扩展为双端或替换原件GUI通过。
