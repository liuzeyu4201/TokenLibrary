import Foundation

public struct PDFTextAnnotation: Codable, Equatable, Sendable {
    public var id: String
    public var type: String
    public var pageIndex: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var color: String
    public var text: String
    public var pdfBlobId: String?
    public var placementState: String

    public init(id: String = UUID().uuidString.lowercased(), type: String, pageIndex: Int, x: Double, y: Double, width: Double, height: Double, color: String, text: String, pdfBlobId: String? = nil, placementState: String = "attached") {
        self.id = id
        self.type = type
        self.pageIndex = pageIndex
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.color = color
        self.text = text
        self.pdfBlobId = pdfBlobId
        self.placementState = placementState
    }

    /// Legacy unbound annotations remain readable. Bound annotations require a
    /// known matching original; unrecognized placement states fail closed.
    public func needsPlacementReview(for currentPDFBlobId: String?) -> Bool {
        placementState != "attached" || (pdfBlobId != nil && pdfBlobId != currentPDFBlobId)
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, pageIndex, x, y, width, height, color, text, pdfBlobId, placementState
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), type: try c.decode(String.self, forKey: .type),
                  pageIndex: try c.decode(Int.self, forKey: .pageIndex),
                  x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y),
                  width: try c.decode(Double.self, forKey: .width), height: try c.decode(Double.self, forKey: .height),
                  color: try c.decode(String.self, forKey: .color), text: try c.decode(String.self, forKey: .text),
                  pdfBlobId: try c.decodeIfPresent(String.self, forKey: .pdfBlobId),
                  placementState: try c.decodeIfPresent(String.self, forKey: .placementState) ?? "attached")
    }
}

public enum PDFMerge {
    public static func mergeAdds(base: [PDFTextAnnotation], local: [PDFTextAnnotation], remote: [PDFTextAnnotation]) -> (merged: [PDFTextAnnotation], conflict: Bool) {
        // Absence is a deletion. A one-sided deletion wins over an unchanged
        // peer, while editing a deleted annotation requires a user decision.
        let baseMap = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let localMap = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let remoteMap = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let ids = Set(baseMap.keys).union(localMap.keys).union(remoteMap.keys)
        var merged: [PDFTextAnnotation] = []
        var conflict = false
        for id in ids.sorted() {
            let b = baseMap[id], l = localMap[id], r = remoteMap[id]
            let value: PDFTextAnnotation?
            if l == r { value = l }
            else if l == b { value = r }
            else if r == b { value = l }
            else {
                conflict = true
                // Retain the local material for the conflict UI; never claim a merge.
                value = l ?? r
            }
            if let value { merged.append(value) }
        }
        return (merged, conflict)
    }

    public static func replaceConflict(baseBlob: String, localBlob: String, remoteBlob: String) -> Bool {
        localBlob != remoteBlob && localBlob != baseBlob && remoteBlob != baseBlob
    }
}

