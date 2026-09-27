import Foundation
import XCTest
@testable import LibraryCore

final class EditorScriptTests: XCTestCase {
    func testSourceIsPassedAsJSONIncludingTemplateInterpolationAndLineSeparators() throws {
        let source = "# 标题\n`${window.secret}` \\ path \"quote\"\n\u{2028}\u{2029}</script>"
        let script = EditorScript.setMarkdown(source)
        let prefix = "window.tlSetMarkdown && window.tlSetMarkdown("
        XCTAssertTrue(script.hasPrefix(prefix))
        XCTAssertTrue(script.hasSuffix("[0])"))
        let json = String(script.dropFirst(prefix.count).dropLast(4))
        let decoded = try JSONDecoder().decode([String].self, from: Data(json.utf8))
        XCTAssertEqual(decoded, [source])
    }
}
