import Foundation

public enum EditorBundle {
    /// Packaged HTML lives in Resources/editor or Resources/dist depending on the copy-folder name.
    public static func indexHTML(in bundle: Bundle) -> URL? {
        for sub in ["editor", "dist"] {
            if let url = bundle.url(forResource: "index", withExtension: "html", subdirectory: sub) {
                return url
            }
        }
        return bundle.url(forResource: "index", withExtension: "html")
    }
}
