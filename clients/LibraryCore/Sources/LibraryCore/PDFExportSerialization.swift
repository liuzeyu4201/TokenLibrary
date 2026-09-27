import Foundation
import PDFKit

/// Checks PDFKit's own serialized output. In particular, the iOS writer can
/// emit unreferenced, in-use xref slots at offset zero and omit annotation /NM.
/// This is deliberately not an input-PDF repairer: streams are never decoded or
/// searched, and only indexed dictionaries in a complete classic xref are edited.
enum PDFExportSerialization {
    struct Identity {
        let index: Int
        let name: String
        let type: String?
        let contents: String?
        let bounds: CGRect
    }

    static func identities(in document: PDFDocument) -> [[Identity]] {
        (0..<document.pageCount).map { pageIndex in
            (document.page(at: pageIndex)?.annotations ?? []).enumerated().compactMap { index, annotation in
                guard let name = annotation.value(forAnnotationKey: .name) as? String else { return nil }
                return Identity(index: index, name: name, type: annotation.type,
                                contents: annotation.contents, bounds: annotation.bounds)
            }
        }
    }

    static func finish(_ data: Data, identities: [[Identity]]) throws -> Data {
        var file = try IndexedPDF(data)
        let pages = try file.pages()
        guard pages.count == identities.count else { throw Failure.invalidOutput }
        let reopened = PDFDocument(data: data)
        guard reopened?.pageCount == identities.count else { throw Failure.invalidOutput }
        var insertions: [Int: Data] = [:]
        for (pageIndex, expected) in identities.enumerated() where !expected.isEmpty {
            let page = try file.dictionary(pages[pageIndex])
            guard let annotationNode = page["Annots"] else { throw Failure.invalidOutput }
            let nodes = try file.array(annotationNode)
            let annotations = reopened?.page(at: pageIndex)?.annotations ?? []
            for item in expected {
                guard nodes.indices.contains(item.index), annotations.indices.contains(item.index) else { throw Failure.invalidOutput }
                let annotation = annotations[item.index]
                let actual = annotation.bounds
                guard annotation.type == item.type, annotation.contents == item.contents,
                      abs(actual.minX - item.bounds.minX) < 0.02, abs(actual.minY - item.bounds.minY) < 0.02,
                      abs(actual.width - item.bounds.width) < 0.02, abs(actual.height - item.bounds.height) < 0.02 else {
                    throw Failure.invalidOutput
                }
                if let name = annotation.value(forAnnotationKey: .name) as? String {
                    guard name == item.name else { throw Failure.invalidOutput }
                    continue
                }
                let node = try file.resolve(nodes[item.index])
                guard case .dictionary(let values) = node.kind, values["NM"] == nil else { throw Failure.invalidOutput }
                // Hexadecimal UTF-16 strings avoid delimiter/escape ambiguity.
                let units = [UInt16(0xFEFF)] + Array(item.name.utf16)
                let hex = units.map { String(format: "%04X", $0) }.joined()
                let position = node.range.upperBound - 2
                let insertion = Data(" /NM <\(hex)> ".utf8)
                guard insertions[position] == nil || insertions[position] == insertion else { throw Failure.invalidOutput }
                insertions[position] = insertion
            }
        }
        return try file.rewrite(insertions: insertions)
    }

    enum Failure: LocalizedError {
        case invalidOutput
        var errorDescription: String? { "PDF 批注导出未通过文件结构校验。原文件与批注仍保留，请重试导出。" }
    }

    private indirect enum Kind {
        case dictionary([String: Node]), array([Node]), reference(Int, Int), name(String), other
    }
    private struct Node {
        let kind: Kind
        let range: Range<Int>
    }
    private struct Entry {
        let offset: Int
        let generation: Int
        let used: Bool
    }
    private struct IndexedPDF {
        let data: Data
        let bytes: [UInt8]
        let xrefOffset: Int
        let trailer: Node
        let size: Int
        let entries: [Int: Entry]
        let objects: [Int: Node]
        let zeroSlots: Set<Int>

        init(_ data: Data) throws {
            self.data = data
            bytes = Array(data)
            guard let marker = data.range(of: Data("startxref".utf8), options: .backwards) else { throw Failure.invalidOutput }
            var end = Parser(bytes: bytes, index: marker.upperBound)
            xrefOffset = try end.integer()
            guard xrefOffset > 0, xrefOffset < marker.lowerBound else { throw Failure.invalidOutput }
            var parser = Parser(bytes: bytes, index: xrefOffset)
            guard try parser.token() == "xref" else { throw Failure.invalidOutput }
            var table: [Int: Entry] = [:]
            while true {
                parser.space()
                if parser.starts("trailer") { _ = try parser.token(); break }
                let first = try parser.integer(), count = try parser.integer()
                guard first >= 0, count >= 0, first <= 1_000_000, count <= 1_000_000 - first else { throw Failure.invalidOutput }
                for id in first..<(first + count) {
                    let offset = try parser.integer(), generation = try parser.integer(), flag = try parser.token()
                    guard table[id] == nil, offset >= 0, (0...65535).contains(generation), ["n", "f"].contains(flag) else { throw Failure.invalidOutput }
                    table[id] = Entry(offset: offset, generation: generation, used: flag == "n")
                }
            }
            trailer = try parser.value()
            guard try parser.token() == "startxref", try parser.integer() == xrefOffset else { throw Failure.invalidOutput }
            while parser.index < bytes.count && Parser.whitespace(bytes[parser.index]) { parser.index += 1 }
            guard parser.starts("%%EOF") else { throw Failure.invalidOutput }
            parser.index += 5
            while parser.index < bytes.count && Parser.whitespace(bytes[parser.index]) { parser.index += 1 }
            guard parser.index == bytes.count else { throw Failure.invalidOutput }
            guard case .dictionary(let fields) = trailer.kind,
                  let sizeNode = fields["Size"], case .other = sizeNode.kind,
                  let count = Int(String(decoding: bytes[sizeNode.range], as: UTF8.self)),
                  count > 0, count <= 1_000_001, table.keys.allSatisfy({ $0 < count }),
                  fields["Prev"] == nil, fields["XRefStm"] == nil, fields["Encrypt"] == nil else { throw Failure.invalidOutput }
            size = count
            entries = table
            zeroSlots = Set(table.compactMap { $0.value.used && $0.value.offset == 0 ? $0.key : nil })
            var parsed: [Int: Node] = [:]
            let used = table.filter { $0.value.used && $0.value.offset > 0 }.sorted { $0.value.offset < $1.value.offset }
            for (index, pair) in used.enumerated() {
                let boundary = index + 1 < used.count ? used[index + 1].value.offset : xrefOffset
                guard pair.value.offset < boundary, boundary <= xrefOffset else { throw Failure.invalidOutput }
                var object = Parser(bytes: bytes, index: pair.value.offset, limit: boundary)
                guard try object.integer() == pair.key, try object.integer() == pair.value.generation,
                      try object.token() == "obj" else { throw Failure.invalidOutput }
                parsed[pair.key] = try object.value()
            }
            objects = parsed
            // A referenced missing object is not a harmless unused slot. Do not
            // silently turn content loss into a supposedly successful export.
            for node in Array(parsed.values) + [trailer] {
                guard !Self.references(node).contains(where: { zeroSlots.contains($0) }) else { throw Failure.invalidOutput }
            }
            // Use the declared stream length, never an `endstream` byte search:
            // embedded images may contain apparent PDF syntax. This also rejects
            // a damaged xref entry that points into another object's stream.
            for (index, pair) in used.enumerated() {
                let boundary = index + 1 < used.count ? used[index + 1].value.offset : xrefOffset
                let node = parsed[pair.key]!
                var ending = Parser(bytes: bytes, index: node.range.upperBound, limit: boundary)
                let keyword = try ending.token()
                if keyword == "stream" {
                    let fields = try dictionary(node)
                    guard let lengthNode = fields["Length"] else { throw Failure.invalidOutput }
                    let resolved = try resolve(lengthNode)
                    guard case .other = resolved.kind,
                          let length = Int(String(decoding: bytes[resolved.range], as: UTF8.self)), length >= 0 else { throw Failure.invalidOutput }
                    while ending.index < boundary && [9, 32].contains(bytes[ending.index]) { ending.index += 1 }
                    guard ending.index < boundary, [10, 13].contains(bytes[ending.index]) else { throw Failure.invalidOutput }
                    if bytes[ending.index] == 13 {
                        ending.index += 1
                        if ending.index < boundary && bytes[ending.index] == 10 { ending.index += 1 }
                    } else { ending.index += 1 }
                    guard length <= boundary - ending.index else { throw Failure.invalidOutput }
                    ending.index += length
                    guard try ending.token() == "endstream", try ending.token() == "endobj" else { throw Failure.invalidOutput }
                } else if keyword != "endobj" { throw Failure.invalidOutput }
                ending.space()
                guard ending.index == boundary else { throw Failure.invalidOutput }
            }
        }

        private static func references(_ node: Node) -> [Int] {
            switch node.kind {
            case .reference(let id, _): return [id]
            case .array(let values): return values.flatMap(references)
            case .dictionary(let values): return values.values.flatMap(references)
            default: return []
            }
        }
        func resolve(_ node: Node, depth: Int = 0) throws -> Node {
            guard depth < 128 else { throw Failure.invalidOutput }
            if case .reference(let id, let generation) = node.kind {
                guard entries[id]?.generation == generation, let target = objects[id] else { throw Failure.invalidOutput }
                return try resolve(target, depth: depth + 1)
            }
            return node
        }
        func dictionary(_ node: Node) throws -> [String: Node] {
            guard case .dictionary(let fields) = try resolve(node).kind else { throw Failure.invalidOutput }
            return fields
        }
        func array(_ node: Node) throws -> [Node] {
            guard case .array(let values) = try resolve(node).kind else { throw Failure.invalidOutput }
            return values
        }
        func pages() throws -> [Node] {
            let trailerFields = try dictionary(trailer)
            guard let root = trailerFields["Root"], let pageRoot = try dictionary(root)["Pages"] else { throw Failure.invalidOutput }
            var visited = Set<Int>()
            func visit(_ node: Node, depth: Int) throws -> [Node] {
                guard depth < 128 else { throw Failure.invalidOutput }
                let resolved = try resolve(node)
                guard visited.insert(resolved.range.lowerBound).inserted else { throw Failure.invalidOutput }
                let fields = try dictionary(resolved)
                if let type = fields["Type"], case .name("Page") = type.kind { return [resolved] }
                guard let kids = fields["Kids"] else { throw Failure.invalidOutput }
                return try array(kids).flatMap { try visit($0, depth: depth + 1) }
            }
            return try visit(pageRoot, depth: 0)
        }
        mutating func rewrite(insertions: [Int: Data]) throws -> Data {
            guard !zeroSlots.isEmpty || !insertions.isEmpty else { return data }
            let used = entries.filter { $0.value.used && $0.value.offset > 0 }.sorted { $0.value.offset < $1.value.offset }
            guard let first = used.first else { throw Failure.invalidOutput }
            var out = Data(bytes[..<first.value.offset]), offsets: [Int: Int] = [:]
            var remaining = Set(insertions.keys)
            for (index, pair) in used.enumerated() {
                let boundary = index + 1 < used.count ? used[index + 1].value.offset : xrefOffset
                offsets[pair.key] = out.count
                var cursor = pair.value.offset
                for position in insertions.keys.filter({ cursor <= $0 && $0 < boundary }).sorted() {
                    out.append(contentsOf: bytes[cursor..<position])
                    out.append(insertions[position]!)
                    remaining.remove(position)
                    cursor = position
                }
                out.append(contentsOf: bytes[cursor..<boundary])
            }
            guard remaining.isEmpty else { throw Failure.invalidOutput }
            let start = out.count
            out.append(Data("xref\n0 \(size)\n".utf8))
            let free = (0..<size).filter { offsets[$0] == nil }
            let nextFree = Dictionary(uniqueKeysWithValues: free.enumerated().map { ($0.element, $0.offset + 1 < free.count ? free[$0.offset + 1] : 0) })
            for id in 0..<size {
                if let offset = offsets[id] {
                    out.append(Data(String(format: "%010d %05d n \n", offset, entries[id]!.generation).utf8))
                } else {
                    out.append(Data(String(format: "%010d %05d f \n", nextFree[id] ?? 0, id == 0 ? 65535 : entries[id]?.generation ?? 0).utf8))
                }
            }
            out.append(Data("trailer\n".utf8))
            out.append(contentsOf: bytes[trailer.range])
            out.append(Data("\nstartxref\n\(start)\n%%EOF\n".utf8))
            return out
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index: Int
        var limit: Int? = nil
        var end: Int { min(limit ?? bytes.count, bytes.count) }
        static func whitespace(_ byte: UInt8) -> Bool { [0, 9, 10, 12, 13, 32].contains(byte) }
        static func delimiter(_ byte: UInt8) -> Bool { whitespace(byte) || [40,41,60,62,91,93,123,125,47,37].contains(byte) }
        mutating func space() {
            while index < end {
                if Self.whitespace(bytes[index]) { index += 1 }
                else if bytes[index] == 37 {
                    while index < end && bytes[index] != 10 && bytes[index] != 13 { index += 1 }
                } else { break }
            }
        }
        func starts(_ value: String) -> Bool {
            let text = Array(value.utf8)
            return index + text.count <= end && Array(bytes[index..<(index + text.count)]) == text
        }
        mutating func token() throws -> String {
            space(); let start = index
            while index < end && !Self.delimiter(bytes[index]) { index += 1 }
            guard start < index else { throw Failure.invalidOutput }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
        mutating func integer() throws -> Int {
            guard let value = Int(try token()) else { throw Failure.invalidOutput }
            return value
        }
        mutating func value(depth: Int = 0) throws -> Node {
            guard depth < 128 else { throw Failure.invalidOutput }
            space(); let start = index
            guard index < end else { throw Failure.invalidOutput }
            if starts("<<") {
                index += 2; var fields: [String: Node] = [:]
                while true {
                    space()
                    if starts(">>") { index += 2; break }
                    let key = try value(depth: depth + 1)
                    guard case .name(let name) = key.kind, fields[name] == nil else { throw Failure.invalidOutput }
                    fields[name] = try value(depth: depth + 1)
                }
                return Node(kind: .dictionary(fields), range: start..<index)
            }
            if bytes[index] == 91 {
                index += 1; var values: [Node] = []
                while true {
                    space(); guard index < end else { throw Failure.invalidOutput }
                    if bytes[index] == 93 { index += 1; break }
                    values.append(try value(depth: depth + 1))
                }
                return Node(kind: .array(values), range: start..<index)
            }
            if bytes[index] == 40 {
                index += 1; var nesting = 1
                while nesting > 0 && index < end {
                    let byte = bytes[index]; index += 1
                    if byte == 92 { if index < end { index += 1 } }
                    else if byte == 40 { nesting += 1 }
                    else if byte == 41 { nesting -= 1 }
                }
                guard nesting == 0 else { throw Failure.invalidOutput }
            } else if bytes[index] == 60 {
                index += 1
                while index < end && bytes[index] != 62 { index += 1 }
                guard index < end else { throw Failure.invalidOutput }; index += 1
            } else if bytes[index] == 47 {
                index += 1; var name: [UInt8] = []
                while index < end && !Self.delimiter(bytes[index]) {
                    if bytes[index] == 35, index + 2 < end,
                       let byte = UInt8(String(decoding: bytes[(index+1)...(index+2)], as: UTF8.self), radix: 16) {
                        name.append(byte); index += 3
                    } else { name.append(bytes[index]); index += 1 }
                }
                return Node(kind: .name(String(decoding: name, as: UTF8.self)), range: start..<index)
            } else {
                let text = try token()
                if let number = Int(text), number >= 0 {
                    var lookahead = self
                    if let generation = try? lookahead.integer(), generation >= 0,
                       (try? lookahead.token()) == "R" {
                        self = lookahead
                        return Node(kind: .reference(number, generation), range: start..<index)
                    }
                }
            }
            return Node(kind: .other, range: start..<index)
        }
    }
}
