import Foundation
import XCTest
@testable import LibraryUI

final class LibraryVerificationConfigurationTests: XCTestCase {
    private let temporary = URL(fileURLWithPath: "/tmp/verification-configuration-tests", isDirectory: true)
    private func directory(_ bundle: String?, info: String? = nil, arguments: [String] = ["TokenLibrary"], debug: Bool = true) -> URL? {
        LibraryVerificationConfiguration.directory(arguments: arguments, bundleID: bundle, infoDirectory: info,
            temporaryDirectory: temporary, debugBuild: debug)
    }

    func testExistingVerificationBundleKeepsItsOriginalDefaultAndIgnoresInfoOverride() {
        let expected = temporary.appendingPathComponent("TokenLibrary-UI-verification-20260926", isDirectory: true)
        XCTAssertEqual(directory("app.tokenlibrary.verification"), expected)
        XCTAssertEqual(directory("app.tokenlibrary.verification", info: "/tmp/somewhere-else"), expected)
    }

    func testIndependentVerificationBundleAcceptsOnlyAbsoluteInfoDirectory() {
        let bundle = "app.tokenlibrary.verification.legacycatalog"
        XCTAssertEqual(directory(bundle, info: "/tmp/legacy-fixture"), URL(fileURLWithPath: "/tmp/legacy-fixture", isDirectory: true))
        for invalid in ["", "relative/path", "~/Library", "file:///tmp/fixture", " /tmp/fixture"] {
            XCTAssertNil(directory(bundle, info: invalid), invalid)
        }
        XCTAssertNil(directory(bundle))
    }

    func testOrdinaryOrLookalikeBundleCannotSelectInfoDirectoryAndReleaseIgnoresEverything() {
        for bundle in ["app.tokenlibrary", "app.tokenlibrary.verification-other", "app.tokenlibrary.verification.", "org.example.library"] {
            XCTAssertNil(directory(bundle, info: "/tmp/legacy-fixture"), bundle)
        }
        XCTAssertNil(directory(nil, info: "/tmp/legacy-fixture"))
        for bundle in ["app.tokenlibrary.verification", "app.tokenlibrary.verification.legacycatalog", "app.tokenlibrary"] {
            XCTAssertNil(directory(bundle, info: "/tmp/legacy-fixture", arguments: ["TokenLibrary", "--verification-directory", "/tmp/explicit"], debug: false), bundle)
        }
    }

    func testExistingExplicitArgumentRemainsFirstAndMalformedArgumentDoesNotOverrideSafeConfiguration() {
        XCTAssertEqual(directory("app.tokenlibrary.verification.legacycatalog", info: "/tmp/info",
            arguments: ["TokenLibrary", "--verification-directory", "/tmp/explicit"]), URL(fileURLWithPath: "/tmp/explicit", isDirectory: true))
        XCTAssertEqual(directory("app.tokenlibrary.verification.legacycatalog", info: "/tmp/info",
            arguments: ["TokenLibrary", "--verification-directory"]), URL(fileURLWithPath: "/tmp/info", isDirectory: true))
        XCTAssertEqual(directory("app.tokenlibrary.verification.legacycatalog", info: "/tmp/info",
            arguments: ["TokenLibrary", "--verification-directory", "relative"]), URL(fileURLWithPath: "/tmp/info", isDirectory: true))
    }
}
