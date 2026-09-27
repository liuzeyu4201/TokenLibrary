import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), integer(Int64), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var object: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    public var array: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    public var int64: Int64? {
        switch self { case .integer(let value): return value; case .string(let value): return Int64(value); default: return nil }
    }
    public var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    public static func parse(_ text: String) throws -> JSONValue { try JSONDecoder().decode(Self.self, from: Data(text.utf8)) }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    public func jsonString() throws -> String { String(decoding: try encoded(), as: UTF8.self) }
}

public typealias DocumentSnapshot = [String: JSONValue]

public struct SyncSummary: Sendable, Equatable {
    public var downloaded = 0
    public var uploaded = 0
    public var deleted = 0
    public var conflicts = 0
    public var cursor: Int64 = 0
    public init() {}
}

public struct LibraryConflict: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let objectId: String
    public let serverId: String?
    public let kind: String
    public let baseJSON: String
    public let localJSON: String
    public let remoteJSON: String
    public let revision: Int64
    public let state: String
}

public enum ConflictResolution: Sendable {
    case local, remote, customMarkdown(String)
}

public struct SnapshotMergeResult: Sendable {
    public let snapshot: DocumentSnapshot
    public let conflictingFields: [String]
    public var hasConflict: Bool { !conflictingFields.isEmpty }
}

/// Conservative three-way merge: independent field and line changes combine; overlapping changes retain materials.
public enum SnapshotMerger {
    public static func merge(base: DocumentSnapshot, local: DocumentSnapshot, remote: DocumentSnapshot) -> SnapshotMergeResult {
        var conflicts: [String] = []
        var result = mergeObjects(base: base, local: local, remote: remote, prefix: "", conflicts: &conflicts)
        for key in ["id", "revision", "purgeAt", "trashBatchId"] { result[key] = remote[key] }
        return SnapshotMergeResult(snapshot: result, conflictingFields: conflicts)
    }

    private static func mergeObjects(base: DocumentSnapshot, local: DocumentSnapshot, remote: DocumentSnapshot, prefix: String, conflicts: inout [String]) -> DocumentSnapshot {
        var output: DocumentSnapshot = [:]
        for key in Set(base.keys).union(local.keys).union(remote.keys) {
            if prefix.isEmpty && ["id", "revision", "purgeAt", "trashBatchId"].contains(key) { output[key] = remote[key]; continue }
            let b = base[key], l = local[key], r = remote[key]
            if l == r || r == b { output[key] = l; continue }
            if l == b { output[key] = r; continue }
            let field = prefix.isEmpty ? key : prefix + "." + key
            if key == "markdownSource", let b = b?.string, let l = l?.string, let r = r?.string,
               let text = mergeText(base: b, local: l, remote: r) { output[key] = .string(text); continue }
            if let lo = l?.object, let ro = r?.object {
                output[key] = .object(mergeObjects(base: b?.object ?? [:], local: lo, remote: ro, prefix: field, conflicts: &conflicts)); continue
            }
            if ["assets", "annotations", "readingPositions", "excerpts"].contains(key), let la = l?.array, let ra = r?.array,
               let value = mergeRecords(base: b?.array ?? [], local: la, remote: ra, field: field, conflicts: &conflicts) {
                output[key] = .array(value); continue
            }
            conflicts.append(field)
            output[key] = l
        }
        return output
    }

    private static func mergeRecords(base: [JSONValue], local: [JSONValue], remote: [JSONValue], field: String, conflicts: inout [String]) -> [JSONValue]? {
        func records(_ values: [JSONValue]) -> [String: JSONValue]? {
            var result: [String: JSONValue] = [:]
            for value in values {
                guard let object = value.object, let id = object["id"]?.string ?? object["blobId"]?.string ?? object["deviceID"]?.string, result[id] == nil else { return nil }
                result[id] = value
            }
            return result
        }
        guard let b = records(base), let l = records(local), let r = records(remote) else { return nil }
        let merged = mergeObjects(base: b, local: l, remote: r, prefix: field, conflicts: &conflicts)
        return merged.keys.sorted().compactMap { merged[$0] }
    }

    public static func mergeText(base: String, local: String, remote: String) -> String? {
        if local == remote || remote == base { return local }; if local == base { return remote }
        let b = base.components(separatedBy: "\n"), l = local.components(separatedBy: "\n"), r = remote.components(separatedBy: "\n")
        func edit(_ target: [String]) -> (start: Int, end: Int, lines: [String]) {
            var start = 0
            while start < min(b.count, target.count) && b[start] == target[start] { start += 1 }
            var end = b.count, targetEnd = target.count
            while end > start && targetEnd > start && b[end - 1] == target[targetEnd - 1] { end -= 1; targetEnd -= 1 }
            return (start, end, Array(target[start..<targetEnd]))
        }
        let le = edit(l), re = edit(r)
        guard le.end <= re.start || re.end <= le.start,
              !(le.start == le.end && re.start == re.end && le.start == re.start) else { return nil }
        var result = b
        for change in [le, re].sorted(by: { $0.start > $1.start }) { result.replaceSubrange(change.start..<change.end, with: change.lines) }
        return result.joined(separator: "\n")
    }
}

extension LibraryDocument {
    public var syncSnapshot: DocumentSnapshot {
        var value: DocumentSnapshot = ["id": .string(id), "kind": .string(kind.rawValue), "parentId": parentId.isEmpty ? .null : .string(parentId),
                                       "name": .string(name), "state": .string(state), "revision": .string(String(revision)),
                                       "metadata": (try? JSONValue.parse(metadataJSON)) ?? .object([:])]
        if kind == .md { value["markdownSource"] = .string(markdown); value["assets"] = (try? JSONValue.parse(assetsJSON)) ?? .array([]) }
        if kind == .pdf {
            value["pdfBlobId"] = pdfBlobId.map(JSONValue.string) ?? .null
            let annotations = ((try? JSONValue.parse(annotationsJSON))?.array ?? []).map { value -> JSONValue in
                guard var item = value.object else { return value }
                if item["geometry"] == nil {
                    item["geometry"] = .object(Dictionary(uniqueKeysWithValues: ["x", "y", "width", "height"].compactMap { key in item[key].map { (key, $0) } }))
                }
                item["placementState"] = item["placementState"] ?? .string("attached")
                return .object(item)
            }
            value["annotations"] = .array(annotations)
        }
        if let purgeAt { value["purgeAt"] = .string(ISO8601DateFormatter().string(from: purgeAt)) }
        return value
    }
}
