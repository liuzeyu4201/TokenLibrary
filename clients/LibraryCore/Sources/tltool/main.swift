import Foundation
import LibraryCore

@main
struct Tool {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            fputs("usage: tltool local-save DIR MARKDOWN\n", stderr)
            exit(2)
        }
        switch args[1] {
        case "local-save":
            let dir = URL(fileURLWithPath: args[2])
            let md = args.count > 3 ? args[3] : "offline-edit"
            let store = try DocumentStore(directory: dir)
            let id = args.count > 4 ? args[4] : UUID().uuidString.lowercased()
            try store.localSaveOffline(markdown: md, id: id, name: "offline.md", parentId: args.count > 5 ? args[5] : "root")
            guard let doc = try store.loadDocument(id: id) else { fatalError("missing") }
            print("SAVED id=\(id) markdown=\(doc.markdown)")
        default:
            fputs("unknown command\n", stderr)
            exit(2)
        }
    }
}
