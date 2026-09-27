import Foundation

public enum NoteBlockKind: String, Codable, Sendable { case text, image, voice }

public struct NoteBlock: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: NoteBlockKind
    /// Caption / body. Every sticky can hold text, including image and voice.
    public var text: String
    public var path: String?
    public var duration: Double?

    public init(id: String = UUID().uuidString.lowercased(), kind: NoteBlockKind, text: String = "", path: String? = nil, duration: Double? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.path = path
        self.duration = duration
    }
}

public enum NoteBlockCodec {
    /// Persisted in the note's markdown. Block order in the file is screen order.
    ///
    /// Text:
    /// <!--tl:text id="uuid"-->
    /// body
    /// <!--/tl:text-->
    ///
    /// Image (caption is optional body after the image line):
    /// <!--tl:image id="uuid"-->
    /// ![](media/file.jpg)
    /// caption
    /// <!--/tl:image-->
    ///
    /// Voice:
    /// <!--tl:voice id="uuid" duration="1.5"-->
    /// [voice](media/file.m4a)
    /// caption
    /// <!--/tl:voice-->
    public static func parse(_ markdown: String) -> [NoteBlock] {
        guard !markdown.isEmpty else { return [NoteBlock(kind: .text)] }
        let ns = markdown as NSString
        let full = NSRange(location: 0, length: ns.length)
        let expression = try! NSRegularExpression(
            pattern: #"<!--tl:(text|image|voice) id="([^"]+)"(?: duration="([^"]+)")?-->(.*?)<!--/tl:\1-->"#,
            options: [.dotMatchesLineSeparators])
        var blocks: [NoteBlock] = []
        var cursor = markdown.startIndex
        for match in expression.matches(in: markdown, range: full) {
            guard let range = Range(match.range, in: markdown) else { continue }
            let kind = NoteBlockKind(rawValue: ns.substring(with: match.range(at: 1)))!
            let id = ns.substring(with: match.range(at: 2))
            let body = removeFramingNewlines(ns.substring(with: match.range(at: 4)))
            let block: NoteBlock
            if kind == .text {
                block = NoteBlock(id: id, kind: kind, text: body)
            } else {
                // The first line is the generated media link. Everything after
                // its single delimiter belongs to the user, including whitespace.
                let lineEnd = body.firstIndex(where: { $0 == "\n" || $0 == "\r\n" })
                let line = lineEnd.map { String(body[..<$0]) } ?? body
                let caption = lineEnd.map { String(body[body.index(after: $0)...]) } ?? ""
                let pattern = kind == .image ? #"^!\[([^\]]*)\]\(([^)]+)\)$"# : #"^\[(voice)\]\(([^)]+)\)$"#
                let link = try! NSRegularExpression(pattern: pattern)
                let lineNS = line as NSString
                guard let media = link.firstMatch(in: line, range: NSRange(location: 0, length: lineNS.length)) else { continue }
                let alt = lineNS.substring(with: media.range(at: 1))
                let path = lineNS.substring(with: media.range(at: 2))
                let duration = match.range(at: 3).location == NSNotFound ? nil : Double(ns.substring(with: match.range(at: 3)))
                block = NoteBlock(id: id, kind: kind, text: kind == .image && caption.isEmpty ? alt : caption,
                                  path: path, duration: duration)
            }
            if cursor < range.lowerBound {
                let prefix = String(markdown[cursor..<range.lowerBound])
                // Only the exact separator between encoded blocks is framing.
                // Raw Markdown before/after blocks keeps its original whitespace.
                if !blocks.isEmpty && (prefix == "\n\n" || prefix == "\r\n\r\n") {} else {
                    blocks.append(NoteBlock(kind: .text, text: prefix))
                }
            }
            blocks.append(block)
            cursor = range.upperBound
        }
        if cursor < markdown.endIndex {
            blocks.append(NoteBlock(kind: .text, text: String(markdown[cursor...])))
        }
        return blocks.isEmpty ? [NoteBlock(kind: .text, text: markdown)] : blocks
    }

    private static func removeFramingNewlines(_ value: String) -> String {
        let text = value as NSString
        let framing: String
        if text.hasPrefix("\r\n") { framing = "\r\n" }
        else if text.hasPrefix("\n") { framing = "\n" }
        else { return value }
        let width = (framing as NSString).length
        let trailing = text.hasSuffix(framing) && text.length >= width * 2 ? width : 0
        // Use UTF-16 offsets: a user-entered final CR plus our framing LF is
        // one Swift Character, but only the encoder's LF should be removed.
        return text.substring(with: NSRange(location: width, length: text.length - width - trailing))
    }

    public static func serialize(_ blocks: [NoteBlock]) -> String {
        blocks.map { b in
            switch b.kind {
            case .text:
                return "<!--tl:text id=\"\(b.id)\"-->\n\(b.text)\n<!--/tl:text-->"
            case .image:
                let path = b.path ?? ""
                let cap = b.text
                if cap.isEmpty {
                    return "<!--tl:image id=\"\(b.id)\"-->\n![](\(path))\n<!--/tl:image-->"
                }
                return "<!--tl:image id=\"\(b.id)\"-->\n![](\(path))\n\(cap)\n<!--/tl:image-->"
            case .voice:
                let dur = b.duration.map { String(format: "%.1f", $0) } ?? "0"
                let path = b.path ?? ""
                let cap = b.text
                if cap.isEmpty {
                    return "<!--tl:voice id=\"\(b.id)\" duration=\"\(dur)\"-->\n[voice](\(path))\n<!--/tl:voice-->"
                }
                return "<!--tl:voice id=\"\(b.id)\" duration=\"\(dur)\"-->\n[voice](\(path))\n\(cap)\n<!--/tl:voice-->"
            }
        }.joined(separator: "\n\n")
    }

    public static func insert(_ block: NoteBlock, into blocks: inout [NoteBlock], after focused: String?) {
        if let focused, let i = blocks.firstIndex(where: { $0.id == focused }) {
            blocks.insert(block, at: i + 1)
        } else {
            blocks.append(block)
        }
    }

    public static func move(_ blocks: inout [NoteBlock], fromOffsets: IndexSet, toOffset: Int) {
        let moving = fromOffsets.sorted().map { blocks[$0] }
        for i in fromOffsets.sorted().reversed() {
            blocks.remove(at: i)
        }
        var dest = toOffset
        for i in fromOffsets.sorted() where i < toOffset {
            dest -= 1
        }
        dest = min(max(dest, 0), blocks.count)
        blocks.insert(contentsOf: moving, at: dest)
    }
}
