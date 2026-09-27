import Foundation
import Markdown

/// All attachment consumers share the real GFM syntax tree. Text that happens
/// to resemble a path inside code, escaped text or unused definitions is inert.
struct MarkdownReferences {
    struct Reference {
        let destination: String
        let isImage: Bool
        let range: Range<Int>
        fileprivate let markup: any Markup
    }
    let references: [Reference]
    let hasRawHTML: Bool
    private let bytes: [UInt8]

    var mediaReferences: [Reference] {
        references.filter { reference in
            if reference.isImage || reference.destination.hasPrefix("library-asset://") { return true }
            let path = String(reference.destination.prefix { $0 != "#" && $0 != "?" }).removingPercentEncoding ?? reference.destination
            return ["m4a", "mp3", "wav", "aac"].contains((path as NSString).pathExtension.lowercased())
                || reference.destination.lowercased().hasPrefix("data:audio/")
        }
    }

    init(_ source: String) throws {
        let sourceBytes = Array(source.utf8)
        bytes = sourceBytes
        var starts = [0]
        for (index, byte) in sourceBytes.enumerated() {
            if byte == 10 || (byte == 13 && (index + 1 == sourceBytes.count || sourceBytes[index + 1] != 10)) { starts.append(index + 1) }
        }
        let hasBOM = sourceBytes.starts(with: [0xef, 0xbb, 0xbf])
        func offset(_ location: SourceLocation) throws -> Int {
            guard location.line >= 1, location.line <= starts.count, location.column >= 1 else { throw MarkdownImportError.invalidSyntaxRange }
            // Parse without the BOM so cmark ranges have an unambiguous base;
            // map its first-line columns back onto the untouched source bytes.
            let bomOffset = location.line == 1 && hasBOM ? 3 : 0
            let result = starts[location.line - 1] + location.column - 1 + bomOffset
            guard result <= sourceBytes.count else { throw MarkdownImportError.invalidSyntaxRange }
            return result
        }
        var found: [Reference] = [], html = false
        var stack: [any Markup] = [Document(parsing: hasBOM ? String(source.dropFirst()) : source)]
        while let node = stack.popLast() {
            let destination: String?, image: Bool
            if let value = node as? Image { destination = value.source; image = true }
            else if let value = node as? Link { destination = value.destination; image = false }
            else { destination = nil; image = false }
            if node is HTMLBlock || node is InlineHTML {
                let raw = node.format().lowercased()
                if ["<img", "<audio", "<source", "<video"].contains(where: raw.contains) { html = true }
            }
            if let destination, let range = node.range {
                let lower = try offset(range.lowerBound), upper = try offset(range.upperBound)
                guard lower < upper, upper <= bytes.count else { throw MarkdownImportError.invalidSyntaxRange }
                found.append(Reference(destination: destination, isImage: image, range: lower..<upper, markup: node))
            }
            // Images nested in alt text are not additional rendered resources.
            if !image { stack.append(contentsOf: node.children.reversed()) }
        }
        references = found.sorted { $0.range.lowerBound < $1.range.lowerBound }
        hasRawHTML = html
    }

    func replacingDestinations(_ replacements: [String: String]) throws -> String {
        var selected: [Reference] = []
        for reference in references where replacements[reference.destination] != nil {
            if selected.contains(where: { $0.range.lowerBound <= reference.range.lowerBound && $0.range.upperBound >= reference.range.upperBound }) { continue }
            selected.append(reference)
        }
        var output = bytes
        for reference in selected.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            var rewriter = DestinationRewriter(replacements: replacements)
            guard let node = rewriter.visit(reference.markup) else { throw MarkdownImportError.invalidSyntaxRange }
            let replacement = node.format()
            output.replaceSubrange(reference.range, with: replacement.utf8)
        }
        guard String(bytes: output, encoding: .utf8) != nil else { throw MarkdownImportError.invalidUTF8 }
        return String(decoding: output, as: UTF8.self)
    }
}

private struct DestinationRewriter: MarkupRewriter {
    let replacements: [String: String]
    mutating func visitImage(_ image: Image) -> (any Markup)? {
        var result = image
        if let source = image.source, let replacement = replacements[source] { result.source = replacement }
        return result
    }
    mutating func visitLink(_ link: Link) -> (any Markup)? {
        guard var result = defaultVisit(link) as? Link else { return link }
        if let destination = link.destination, let replacement = replacements[destination] { result.destination = replacement }
        return result
    }
}
