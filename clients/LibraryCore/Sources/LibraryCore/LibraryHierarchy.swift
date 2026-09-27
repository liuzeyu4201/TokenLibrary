import Foundation

public enum LibraryHierarchy {
    /// Resolves a real server root, or the virtual local root. Invalid ancestry
    /// is not a library: it must not accidentally compare equal to another root.
    public static func rootID(for id: String, documents: [LibraryDocument], localRootID: String = "root") -> String? {
        guard !id.isEmpty else { return nil }
        var byID: [String: LibraryDocument] = [:]
        for document in documents {
            guard byID.updateValue(document, forKey: document.id) == nil else { return nil }
        }
        var cursor = id, visited = Set<String>()
        while visited.insert(cursor).inserted {
            guard let document = byID[cursor] else { return cursor == localRootID ? cursor : nil }
            if document.parentId.isEmpty { return document.kind == .folder ? cursor : nil }
            if let parent = byID[document.parentId], parent.kind != .folder { return nil }
            cursor = document.parentId
        }
        return nil
    }
}
