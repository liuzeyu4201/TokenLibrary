import Foundation

public enum FileNames {
    /// Matches the server's NFC + case-fold collision key.
    public static func comparisonKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// The wire protocol uses a 240-byte UTF-8 name limit, including extension.
    public static func isValidStoredName(_ name: String) -> Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && ![".", ".."].contains(value) && !value.contains("/") && !value.contains("\\") &&
            value.utf8.count <= 240 && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    /// The input must already be valid. Suffixes never push a valid UTF-8 name
    /// beyond the protocol limit; the actual extension stays intact.
    public static func availableName(_ name: String, kind: DocKind, takenKeys: Set<String>) -> String {
        guard takenKeys.contains(comparisonKey(name)) else { return name }
        let ext = kind == .folder ? "" : (name as NSString).pathExtension
        let originalBase = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var index = 1
        while true {
            let suffix = "_\(index)" + (ext.isEmpty ? "" : "." + ext)
            var base = originalBase
            while !base.isEmpty && base.utf8.count + suffix.utf8.count > 240 { base.removeLast() }
            let candidate = base + suffix
            if !takenKeys.contains(comparisonKey(candidate)) { return candidate }
            index += 1
        }
    }

    public static func editingBase(_ name: String, kind: DocKind) -> String {
        switch kind {
        case .md:
            if name.lowercased().hasSuffix(".md") { return String(name.dropLast(3)) }
            return name
        case .pdf:
            if name.lowercased().hasSuffix(".pdf") { return String(name.dropLast(4)) }
            return name
        case .folder:
            return name
        }
    }

    public static func stored(_ input: String, kind: DocKind) -> String {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            switch kind {
            case .folder: return "未命名文件夹"
            case .pdf: return "未命名.pdf"
            case .md: return "未命名.md"
            }
        }
        switch kind {
        case .folder:
            return t
        case .md:
            return t.lowercased().hasSuffix(".md") ? t : t + ".md"
        case .pdf:
            return t.lowercased().hasSuffix(".pdf") ? t : t + ".pdf"
        }
    }
}
