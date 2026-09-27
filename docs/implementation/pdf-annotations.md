# PDF 批注与可移植导出

更新：2026-09-26。实现位于 PDFKitExport.swift 与 PDFAnnotations.swift。SDK 与外部阅读器证据见 [PDF 夹具和验收](../testing/pdf-fixtures.md)；原生视图表现仍按 [原生验收](../testing/native-ui-validation.md) 单独记录。

## 修复的实际问题

PDFKit 的 quadrilateralPoints 接收相对于批注原点的点。原实现传了页面坐标，导出时再次加上批注位移；三页研究样本的 /QuadPoints 高度达到 1379 点，已超出 792 点页面。对象存在却不显示高亮。现在写入 `(0, height)`、`(width, height)`、`(0, 0)`、`(width, 0)`，由 PDFKit 转成页面坐标。回归直接检查导出 PDF 的实际 /QuadPoints，并用 Poppler 目视检查黄色区域。

本机 macOS 27 的 PDFKit 为 FreeText 生成系统字体或 Helvetica＋中文后备字体时，会生成部分缺少 /Length 的字体流；仅用 PDFKit 重新打开不能发现这个问题。外部 pypdf 严格解码会失败，Poppler 也会警告。同时 /DA 若以字体名开头，会被 PDFKit 序列化为 Name，违反该字段应为 String 的要求。这是本次环境实际复现的兼容问题，不推定所有 OS 版本都相同。

现在仅给本应用的 FreeText 批注提供自定义 appearance：CoreText 字形轮廓保留英语和中文；包含无法提供轮廓的彩色 emoji 时，使用有像素上限的文字外观图像。批注仍是独立、可更新的 /FreeText 对象，完整 Unicode 内容保留在 /Contents，稳定 ID 保留在 /NM。原页面内容、文字层及第三方批注保持原结构；没有把整页或第三方注释压成图片。默认外观写为合法字符串 `0 g /Helvetica 12 Tf`，正常显示直接使用已有 appearance。

此实现使用 PDFKit 公开的 [自定义绘图接口](https://developer.apple.com/documentation/pdfkit/adding-custom-graphics-to-a-pdf) 与 [defaultAppearance 字段](https://developer.apple.com/documentation/pdfkit/pdfannotationkey/defaultappearance)。外部工具若主动重写或删除 appearance，应自行生成支持所编辑文字的字体资源；本导出保证现有外观和真实批注内容可读，不能保证任意第三方编辑器的重新排版实现。

## 文件版本与更新规则

- PDFTextAnnotation.placementState 缺省为 attached，旧数据可读，重新编码保留服务器的 needs_review。
- needsPlacementReview(for:) 对待核对/未知状态返回 true；带 pdfBlobId 的批注只有当前原件 ID 已知且相同才可定位。旧版无 ID 的记录仍按原兼容行为处理。
- PDFExport.apply、replaceManaged、exportAnnotated 接受 currentPDFBlobId。需要核对的记录不绘制、不导出到当前文件；记录本身留给 UI 核对。UI 创建新批注时必须绑定当前原件 ID。
- replaceManaged 原位更新兼容的同 ID 对象，移除当前会话的重复项、失效位置或已删除 overlay。只有本次元数据明确列出的 ID 才能更新或删除原件中的同 ID 对象。原件既有的其他批注全部保留，包括此前由 TokenLibrary 导出并重新导入的批注；不能仅凭 tokenlibrary: 前缀认定是当前文档的 overlay。

稳定对象更新减少了 PDFView 在重复 remove/add 后缓存旧 accessibility overlay 的机会。19:03 隔离 Mac 原生复测中，编辑后 AX 仅有一个高亮对象；实际系统导出也独立确认只有 1 个 Highlight 与 1 个 FreeText，见 PDF 验收文档。这不代替 iPhone 或其他更新路径的原生验证。

## 原件文字层与系统 Live Text

原生扫描件验证发现：PDF 初次无文字层，但 PDFKit 在用户操作后可识别图像中的文字。这是 Apple [PDFKit Live Text](https://developer.apple.com/videos/play/wwdc2022/10089/) 的按需行为，不能用来承诺全库扫描检索。

阅读器在交给 PDFView 之前保存原件的每页文字快照。应用内查找使用该快照的字符范围，不再调用可能包含临时识别结果的全文件 findString；高亮和直接选区摘录也核对范围及文字仍属于原件文字层。无文字层页面继续支持阅读、文字备注和通过资料详情手动摘录。PDFOriginalTextTests 使用真实文字页加栅格页验证范围与选区；扫描件原生复测单独记录。
