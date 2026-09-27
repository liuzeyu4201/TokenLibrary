import Foundation

/// search-v1 tokenizer: NFC, lowercase, CJK bigrams, latin tokens, camelCase, digit split.
public enum SearchTokenizer {
    public static let version = "search-v1"

    /// Keep phrase bigrams, and index individual CJK characters so a one-character query also finds word endings.
    public static func indexTokens(in raw: String) -> [String] {
        tokens(in: raw) + raw.precomposedStringWithCanonicalMapping.filter(isCJK).map(String.init)
    }

    public static func tokens(in raw: String) -> [String] {
        let s = raw.precomposedStringWithCanonicalMapping.lowercased()
        var out: [String] = []
        var latin = ""
        var cjk: [Character] = []
        func flushLatin() {
            guard !latin.isEmpty else { return }
            splitLatin(latin, into: &out)
            latin = ""
        }
        func flushCJK() {
            if cjk.count == 1 {
                out.append(String(cjk[0]))
            } else if cjk.count >= 2 {
                for i in 0..<(cjk.count - 1) {
                    out.append(String(cjk[i]) + String(cjk[i + 1]))
                }
            }
            cjk.removeAll()
        }
        for ch in s {
            if isCJK(ch) {
                flushLatin()
                cjk.append(ch)
            } else if ch.isLetter || ch.isNumber {
                flushCJK()
                latin.append(ch)
            } else {
                flushLatin()
                flushCJK()
            }
        }
        flushLatin()
        flushCJK()
        return out
    }

    private static func splitLatin(_ s: String, into out: inout [String]) {
        var buf = ""
        var prevLower = false
        for ch in s {
            if ch.isNumber != (buf.last?.isNumber ?? ch.isNumber) && !buf.isEmpty {
                out.append(buf)
                buf = String(ch)
                prevLower = ch.isLowercase
                continue
            }
            if ch.isUppercase && prevLower && !buf.isEmpty {
                out.append(buf.lowercased())
                buf = String(ch)
                prevLower = false
                continue
            }
            buf.append(ch)
            prevLower = ch.isLowercase
        }
        if !buf.isEmpty { out.append(buf.lowercased()) }
    }

    private static func isCJK(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { sc in
            let v = sc.value
            return (0x4E00...0x9FFF).contains(v)
                || (0x3400...0x4DBF).contains(v)
                || (0x3040...0x30FF).contains(v)
                || (0xAC00...0xD7AF).contains(v)
        }
    }
}
