import Foundation

/// Pass Markdown as JSON data, never as a JavaScript template literal.
public enum EditorScript {
    public static func setMarkdown(_ source: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [source], options: [.fragmentsAllowed])
        let argument = String(decoding: data, as: UTF8.self)
        return "window.tlSetMarkdown && window.tlSetMarkdown(\(argument)[0])"
    }
}
